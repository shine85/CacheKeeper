"""续采的纯本地控制器回归；无旧文件可备份，不加载 SSH adapter。"""
import base64
import hashlib
import importlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts'))
import device_collection_batch as batch
from tests.test_device_collection_batch import SDKStateTasks


def parent_report():
    rows=[]
    for bundle,state in (('a.complete','completeWithinRequestedSDKMetadata'),('b.failed','commandFailed'),
                         ('c.unknown','attemptedOutcomeUnknown'),('d.partial','partial'),
                         ('e.missing','notAttemptedConnection'),('f.pending','notAttemptedBudget'),
                         ('g.pending','notAttemptedConnection')):
        row=dict(bundle=bundle,staticState='failed' if bundle=='e.missing' else 'collected',
                 runtimeState='notAttempted',sdkEvidence=dict(state=state))
        if row['staticState']=='collected':row['identity']=dict(bundle=bundle,version='1',build='2',uuid='11'*16)
        if state in ('completeWithinRequestedSDKMetadata','partial'):
            row['sdkEvidence'].update(receipt='sdk-'+str(len(rows))+'/receipt.json',evidenceSource='fresh')
        rows.append(row)
    return dict(schemaVersion=1,runID='20261126T000000Z-12345678',state='interrupted',
                scope='allCurrentRegisteredApplicationMetadata',membershipCount=7,apps=rows,
                sdkCollectionRequested=True,runtimeExecuted=False,appLaunchExecuted=False,resourceDeletionExecuted=False,
                summary=dict(collected=6,failed=1,attemptedOutcomeUnknown=0,notAttemptedConnection=0,notAttemptedBudget=0))


def save_parent(directory,report=None):
    report=parent_report() if report is None else report
    run=Path(directory)/report['runID'];run.mkdir()
    path=run/'collection.json';path.write_text(json.dumps(report),encoding='utf-8')
    return path


class ResumeTasks:
    session='2'*32
    def __init__(self,*,interrupt=None,changed=None,parent_to_change=None):
        self.bundles=[];self.interrupt=interrupt;self.changed=changed;self.parent_to_change=parent_to_change

    def task(self,script,seconds,*,until=None):
        if script==batch.membership_script() or 'CK_BATCH_APP_BEGIN' in script:
            raise AssertionError('resume must not enumerate or repeat primary collection')
        bundle=next((b for b in ('f.pending','g.pending') if 'uicache -i '+b+' ' in script),None)
        if bundle is None:raise AssertionError('unexpected SDK scope')
        self.bundles.append(bundle)
        if bundle==self.interrupt:raise RuntimeError('connectionNotRunning')
        if self.parent_to_change is not None:
            self.parent_to_change.write_text(self.parent_to_change.read_text(encoding='utf-8')+' ',encoding='utf-8')
        output=SDKStateTasks('complete').task('SDK',125)
        output=output.replace(base64.b64encode(b'a.complete').decode(),base64.b64encode(bundle.encode()).decode())
        if bundle==self.changed:
            output='\n'.join(output.splitlines()[:5]+['APP_END|installationIdentityChanged','CK_ALLAPP_TECH_136_V2_END|1|0|0'])+'\n'
        return output


class ResumeTests(unittest.TestCase):
    def test_only_explicit_missing_items_are_collected_and_parent_stays_immutable(self):
        with tempfile.TemporaryDirectory(prefix='batch-resume-',dir=ROOT/'tmp') as temp:
            parent=save_parent(temp);before=parent.read_bytes();tasks=ResumeTasks()
            report,path=batch.resume(tasks,parent)
            self.assertEqual(tasks.bundles,['f.pending','g.pending'])
            self.assertEqual(parent.read_bytes(),before)
            self.assertEqual(report['parent']['sha256'],hashlib.sha256(before).hexdigest())
            self.assertEqual(report['parent']['path'],'../'+parent.parent.name+'/collection.json')
            self.assertEqual(report['primaryIdentitySource'],'parentReport')
            self.assertEqual(report['apps'][0]['sdkEvidence']['evidenceSource'],'historical')
            self.assertNotIn('receipt',report['apps'][0]['sdkEvidence'])
            self.assertEqual(report['apps'][0]['sdkEvidence']['historicalReceipt']['path'],'sdk-0/receipt.json')
            self.assertEqual(report['apps'][4]['sdkEvidence']['state'],'notAttemptedMissingIdentity')
            self.assertEqual(report['sdkSummary'],{'completeWithinRequestedSDKMetadata':3,'commandFailed':1,
                                                 'attemptedOutcomeUnknown':1,'partial':1,'notAttemptedMissingIdentity':1})
            self.assertEqual(report['sdkSummaryBySource']['fresh'],{'completeWithinRequestedSDKMetadata':2})
            self.assertEqual(report['state'],'partial')
            self.assertEqual(json.loads(path.read_text(encoding='utf-8')),report)
            with self.assertRaises(FileExistsError):batch.resume(ResumeTasks(),parent)

    def test_second_interruption_is_complete_and_child_report_can_resume(self):
        with tempfile.TemporaryDirectory(prefix='batch-resume-chain-',dir=ROOT/'tmp') as temp:
            parent=save_parent(temp);first=ResumeTasks(interrupt='f.pending')
            report,child=batch.resume(first,parent)
            self.assertEqual(first.bundles,['f.pending'])
            self.assertEqual(report['apps'][5]['sdkEvidence']['state'],'attemptedOutcomeUnknown')
            self.assertEqual(report['apps'][6]['sdkEvidence']['state'],'notAttemptedConnection')
            child_before=child.read_bytes();second=ResumeTasks()
            final,last=batch.resume(second,child)
            self.assertEqual(second.bundles,['g.pending'])
            self.assertEqual(child.read_bytes(),child_before)
            self.assertEqual(final['apps'][5]['sdkEvidence']['state'],'attemptedOutcomeUnknown')
            self.assertEqual(final['apps'][6]['sdkEvidence']['state'],'completeWithinRequestedSDKMetadata')
            self.assertEqual(sum(final['sdkSummary'].values()),7)
            self.assertNotEqual(last,child)

    def test_current_identity_change_never_becomes_success(self):
        with tempfile.TemporaryDirectory(prefix='batch-resume-identity-',dir=ROOT/'tmp') as temp:
            parent=save_parent(temp);tasks=ResumeTasks(changed='f.pending')
            report,_=batch.resume(tasks,parent)
            evidence=report['apps'][5]['sdkEvidence']
            self.assertEqual(evidence['state'],'partial')
            self.assertEqual(evidence['identityBinding']['state'],'unverifiedOrChanged')
            self.assertEqual(report['sdkSummaryBySource']['fresh'],{'partial':1,'completeWithinRequestedSDKMetadata':1})

    def test_invalid_parent_is_rejected_before_tasks_or_child_creation(self):
        mutations=(lambda r:r.update(state='collectingSDKMetadata'),
                   lambda r:r['apps'][1].update(bundle='a.complete'),
                   lambda r:r['apps'][5]['identity'].update(uuid='bad'),
                   lambda r:r['apps'][0]['sdkEvidence'].update(receipt='../outside.json'),
                   lambda r:r['apps'][0]['sdkEvidence'].update(receipt='C:\\outside.json'),
                   lambda r:r.update(membershipCount=8),
                   lambda r:r['summary'].update(collected=7),
                   lambda r:r.update(runtimeExecuted=True),
                   lambda r:r.update(state=[]),
                   lambda r:r['apps'][5]['sdkEvidence'].update(state=[]),
                   lambda r:r['apps'][5].update(sdkEvidence=None),
                   lambda r:r['apps'][5].update(staticState=[]),
                   lambda r:r['apps'][0]['sdkEvidence'].pop('receipt'),
                   lambda r:r['apps'][5]['sdkEvidence'].update(receipt='sdk-5/receipt.json'),
                   lambda r:r.update(parent=dict(path='../../elsewhere/collection.json',sha256='0'*64)))
        for mutate in mutations:
            with self.subTest(mutation=mutate),tempfile.TemporaryDirectory(prefix='batch-resume-invalid-',dir=ROOT/'tmp') as temp:
                report=parent_report();mutate(report);parent=save_parent(temp,report);tasks=ResumeTasks()
                with self.assertRaises(ValueError):batch.resume(tasks,parent)
                self.assertEqual(tasks.bundles,[])
                self.assertEqual(len(list(Path(temp).iterdir())),1)

    def test_unknown_or_unexplained_pending_state_is_not_automatically_retried(self):
        with tempfile.TemporaryDirectory(prefix='batch-resume-unexplained-',dir=ROOT/'tmp') as temp:
            data=parent_report();data['apps'][5]['sdkEvidence']['state']='notAttempted'
            data['apps'][6].pop('sdkEvidence')
            parent=save_parent(temp,data);tasks=ResumeTasks()
            with self.assertRaisesRegex(ValueError,'resumeNoPendingSDK'):batch.resume(tasks,parent)
            self.assertEqual(tasks.bundles,[])

    def test_cli_preflight_rejects_bad_report_before_transport_loading(self):
        cli=importlib.import_module('collect_device')
        transport=importlib.import_module('device_collection_transport')
        with tempfile.TemporaryDirectory(prefix='batch-resume-cli-',dir=ROOT/'tmp') as temp:
            data=parent_report();data['state']='collectingSDKMetadata';parent=save_parent(temp,data)
            def forbidden(*args,**kwargs):raise AssertionError('invalid report loaded transport')
            with patch.object(transport,'load_transport',side_effect=forbidden),patch('sys.stderr',new=io.StringIO()) as stderr:
                self.assertEqual(cli.main(['--resume',str(parent)]),2)
            self.assertEqual(json.loads(stderr.getvalue())['state'],'resumeParentRejected')

    def test_cli_resume_routes_through_fixture_without_full_collection(self):
        cli=importlib.import_module('collect_device');transport=importlib.import_module('device_collection_transport')
        with tempfile.TemporaryDirectory(prefix='batch-resume-cli-route-',dir=ROOT/'tmp') as temp:
            parent=save_parent(temp);tasks=ResumeTasks()
            def forbidden(*args,**kwargs):raise AssertionError('resume started full collection')
            with patch.object(transport,'load_transport',return_value=object()),patch.object(transport,'QueueTasks',return_value=tasks),patch.object(cli,'collect',side_effect=forbidden),patch('sys.stdout',new=io.StringIO()) as stdout:
                self.assertEqual(cli.main(['--resume',str(parent)]),2)
            self.assertEqual(tasks.bundles,['f.pending','g.pending'])
            self.assertEqual(json.loads(stdout.getvalue())['state'],'partial')

    def test_cli_can_display_report_outside_its_checkout(self):
        cli=importlib.import_module('collect_device');transport=importlib.import_module('device_collection_transport')
        with tempfile.TemporaryDirectory(prefix='batch-resume-cli-external-',dir=ROOT/'tmp') as temp:
            parent=save_parent(temp);tasks=ResumeTasks()
            with patch.object(cli,'ROOT',Path(temp)/'different-checkout'),patch.object(transport,'load_transport',return_value=object()),patch.object(transport,'QueueTasks',return_value=tasks),patch('sys.stdout',new=io.StringIO()) as stdout:
                self.assertEqual(cli.main(['--resume',str(parent)]),2)
            output=json.loads(stdout.getvalue())
            self.assertTrue(Path(output['report']).is_absolute())
            self.assertEqual(tasks.bundles,['f.pending','g.pending'])

    def test_parent_change_during_attempt_stops_before_next_task(self):
        with tempfile.TemporaryDirectory(prefix='batch-resume-race-',dir=ROOT/'tmp') as temp:
            parent=save_parent(temp);tasks=ResumeTasks(parent_to_change=parent)
            report,path=batch.resume(tasks,parent)
            self.assertEqual(tasks.bundles,['f.pending'])
            self.assertEqual(report['state'],'parentChanged')
            self.assertEqual(report['apps'][6]['sdkEvidence']['state'],'notAttemptedParentChanged')
            self.assertEqual(sum(report['sdkSummary'].values()),7)
            self.assertEqual(json.loads(path.read_text(encoding='utf-8')),report)


if __name__=='__main__':unittest.main()
