"""Actual Bash per-app isolation plus collector/protocol state regressions."""
import base64
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts'))
import device_collection_batch as batch


def header():
    return struct.pack('<8I',0xfeedfacf,0x100000c,2,2,1,24,0,0)+struct.pack('<II',0x1b,24)+bytes.fromhex('11'*16)


class SDKStateTasks:
    """本地协议夹具：真实控制器/解析器运行，不执行传入的设备脚本。"""
    session='1'*32
    bundles=('a.complete','b.failed','c.stop','d.missing','e.pending','f.pending')

    def __init__(self,mode):
        self.mode=mode;self.now=0;self.groups=0;self.sdk_calls=0

    def task(self,script,seconds,*,until=None):
        if script==batch.membership_script():
            return ''.join('CK_BATCH_MEMBER '+b+'\n' for b in self.bundles)+'CK_BATCH_MEMBERS_DONE\n'
        if 'CK_BATCH_APP_BEGIN' in script:
            if self.groups==1 and self.mode=='staticConnection':raise RuntimeError('connectionNotRunning')
            group=self.bundles[self.groups*4:self.groups*4+4];self.groups+=1
            frames=[]
            for index,bundle in enumerate(group):
                frames.append('CK_BATCH_APP_BEGIN '+str(index))
                if bundle!='d.missing':
                    frames.extend(('CK1792_APP_BINDING '+str(index)+' '+bundle+' 1 2 '+base64.b64encode(header()).decode(),
                                   'CK1792_APP_BINDINGS_DONE'))
                frames.append('CK_BATCH_APP_END '+str(index)+(' 1' if bundle=='d.missing' else ' 0'))
            if self.mode=='staticBudget':self.now=1700
            return '\n'.join(frames+['CK_BATCH_GROUP_DONE'])+'\n'
        self.sdk_calls+=1
        if self.sdk_calls==2:
            if self.mode=='budget':self.now=1700
            raise RuntimeError('persistentTaskFailed')
        if self.sdk_calls==3 and self.mode=='connection':raise RuntimeError('connectionNotRunning')
        if self.sdk_calls>3:raise AssertionError('controller attempted SDK after stopping')
        bundle='a.complete' if self.sdk_calls==1 else 'c.stop'
        data=header();encoded=base64.b64encode(data).decode();digest=hashlib.sha256(data).hexdigest()
        frames=['CK_ALLAPP_TECH_136_V2_BEGIN',
                'APP_BEGIN|a0001|'+base64.b64encode(bundle.encode()).decode()+'|'+'0'*64,
                'APP_VERSION|0|MQ==|0|Mg==','INSTALLATION|currentRegistration','CONTAINERS_END|notCollected|0',
                'IMAGE_BEGIN|a0001|PRIMARY','IDENTITY_BEFORE|1|2|33188|56|100|100',
                'RANGE_BEGIN|header|0|56|'+digest,encoded,'RANGE_END|header','UUID|'+'11'*16,
                'IDENTITY_AFTER|1|2|33188|56|100|100','IMAGE_END|headerOnlyStable']
        names=('SDWebImage YYCache PINCache Kingfisher CocoaLumberjack YYKit Cache DKCache YYWebImage '
               'CITICLog Loggerithm MJFLog VolcBaseLog TTSDKVolcLog TTSDKLivePullVolcLog glog hitlog vllog xlog').split()
        frames.extend('FRAMEWORK_CHECK|'+name+'|absent' for name in names)
        return '\n'.join(frames+['APP_END|identityStable','CK_ALLAPP_TECH_136_V2_END|1|1|56'])+'\n'


class BatchTests(unittest.TestCase):
    def test_membership_closed_shape_and_duplicates(self):
        self.assertEqual(batch.members('CK_BATCH_MEMBER b.app\nCK_BATCH_MEMBER a.app\nCK_BATCH_MEMBERS_DONE\n'),['a.app','b.app'])
        for bad in ('CK_BATCH_MEMBER a.app\nCK_BATCH_MEMBER a.app\nCK_BATCH_MEMBERS_DONE\n',
                    'CK_BATCH_MEMBER a;rm\nCK_BATCH_MEMBERS_DONE\n','CK_BATCH_MEMBERS_DONE\n'):
            with self.assertRaises(ValueError):batch.members(bad)

    def test_actual_bash_failure_isolated_and_registered_metadata_is_parsed(self):
        with tempfile.TemporaryDirectory(prefix='batch-collector-',dir=ROOT/'tmp') as temp:
            work=Path(temp);app=work/'Fixture.app';app.mkdir();(app/'Info.plist').write_bytes(b'fixture');(app/'Main').write_bytes(header()+b'UNRELATED_EXECUTABLE_BYTES_CANARY')
            utilities=work/'bin';utilities.mkdir()
            programs={
                'timeout':'#!/bin/bash\nif [[ $1 == --kill-after=* ]]; then shift; fi; shift; "$@"\n',
                'rootfs':'#!/bin/bash\nprintf "%s\\n" "$1"\n',
                'uicache':'#!/bin/bash\nif [[ $2 == a.bad ]]; then exit 7; fi\nprintf "Path: %s/Fixture.app\\n" "$PWD"\n',
                'plutil':'''#!/bin/bash
case "$2" in CFBundleIdentifier) echo b.good;; CFBundleShortVersionString) echo 1.2;; CFBundleVersion) echo 3;; CFBundleExecutable) echo Main;; *) exit 8;; esac
''',
            }
            for name,content in programs.items():(utilities/name).write_text(content,encoding='utf-8')
            bindings=batch.collector();script=batch.batch_script(bindings,['a.bad','b.good'])
            (work/'batch.sh').write_text(script,encoding='utf-8')
            result=subprocess.run([shutil.which('bash'),'-c','chmod +x bin/*; PATH="$PWD/bin:$PATH" bash batch.sh'],cwd=work,capture_output=True,text=True,timeout=25)
            self.assertEqual(result.returncode,0,result.stderr)
            rows=batch.parse_batch(bindings,['a.bad','b.good'],result.stdout)
            frame=next(line for line in result.stdout.splitlines() if line.startswith('CK1792_APP_BINDING '))
            self.assertEqual(base64.b64decode(frame.split(' ')[-1]),header())
            self.assertEqual(rows[0]['staticState'],'failed');self.assertEqual(rows[0]['exitCode'],7)
            self.assertEqual(rows[1]['staticState'],'collected');self.assertEqual(rows[1]['identity']['uuid'],'11'*16)
            self.assertNotIn('Fixture.app',json.dumps(rows));self.assertFalse(rows[1]['attached'])

    def test_parse_success_and_unsupported_executable_are_independent(self):
        bindings=batch.collector();encoded=base64.b64encode(header()).decode()
        output=('CK_BATCH_APP_BEGIN 0\nCK1792_APP_BINDING 0 a.app 1 2 '+encoded+'\nCK1792_APP_BINDINGS_DONE\nCK_BATCH_APP_END 0 0\n'
                'CK_BATCH_APP_BEGIN 1\nCK1792_APP_BINDING 1 b.app 1 2 AAAA\nCK1792_APP_BINDINGS_DONE\nCK_BATCH_APP_END 1 0\nCK_BATCH_GROUP_DONE\n')
        rows=batch.parse_batch(bindings,['a.app','b.app'],output)
        self.assertEqual(rows[0]['staticState'],'collected');self.assertEqual(rows[1]['reason'],'unsupportedExecutableOrMetadata')

    def test_connection_failure_preserves_completed_group_and_marks_remaining(self):
        encoded=base64.b64encode(header()).decode();calls=[]
        class Tasks:
            session='1'*32
            def task(self,script,seconds,*,until=None):
                calls.append(script)
                if len(calls)==1:return ''.join('CK_BATCH_MEMBER '+b+'\n' for b in ('a.app','b.app','c.app','d.app','e.app'))+'CK_BATCH_MEMBERS_DONE\n'
                if len(calls)==2:
                    return ''.join('CK_BATCH_APP_BEGIN '+str(i)+'\nCK1792_APP_BINDING '+str(i)+' '+b+' 1 2 '+encoded+'\nCK1792_APP_BINDINGS_DONE\nCK_BATCH_APP_END '+str(i)+' 0\n' for i,b in enumerate(('a.app','b.app','c.app','d.app')))+'CK_BATCH_GROUP_DONE\n'
                raise RuntimeError('connectionNotRunning')
        with tempfile.TemporaryDirectory(prefix='batch-report-',dir=ROOT/'tmp') as temp:
            report,path=batch.collect(Tasks(),temp)
            self.assertEqual(report['state'],'interrupted');self.assertEqual(len(calls),3)
            self.assertEqual([r['staticState'] for r in report['apps']],['collected']*4+['attemptedOutcomeUnknown'])
            self.assertEqual(json.loads(path.read_text(encoding='utf-8')),report)
            self.assertFalse(report['runtimeExecuted'])
            self.assertEqual(report['membershipChanged'],'unverified')
            self.assertEqual(report['summary']['attemptedOutcomeUnknown'],1)
            self.assertIn('foregroundQueue',report)

    def test_total_budget_leaves_explicit_pending_receipts(self):
        class Tasks:
            session='1'*32
            def task(self,script,seconds,*,until=None):return 'CK_BATCH_MEMBER a.app\nCK_BATCH_MEMBERS_DONE\n'
        with tempfile.TemporaryDirectory(prefix='batch-budget-',dir=ROOT/'tmp') as temp:
            report,path=batch.collect(Tasks(),temp,seconds=60,clock=lambda:0)
            self.assertEqual(report['state'],'partial');self.assertTrue(report['budgetExhausted'])
            self.assertEqual(report['apps'][0]['staticState'],'notAttemptedBudget')

    def test_initial_enumeration_failure_is_a_saved_batch_result(self):
        class Tasks:
            session='1'*32
            def task(self,*args,**kwargs):raise RuntimeError('connectionNotRunning')
        with tempfile.TemporaryDirectory(prefix='batch-enumeration-',dir=ROOT/'tmp') as temp:
            report,path=batch.collect(Tasks(),temp)
            self.assertEqual(report['state'],'enumerationFailed')
            self.assertIsNone(report['membershipCount']);self.assertEqual(report['apps'],[])
            self.assertEqual(json.loads(path.read_text()),report)
            self.assertEqual(report['foregroundQueue'],[])

    def test_sdk_objects_preserve_exact_bytes_and_do_not_modify_input(self):
        import hashlib
        data=b'closed technical fixture'
        receipt={'images':[{'ranges':[dict(data=data,length=len(data),sha256=hashlib.sha256(data).hexdigest())]}]}
        with tempfile.TemporaryDirectory(prefix='batch-sdk-object-',dir=ROOT/'tmp') as temp:
            path=batch.write_sdk_receipt(Path(temp)/'receipt',receipt)
            saved=json.loads(path.read_text())
            self.assertEqual((path.parent/saved['images'][0]['ranges'][0]['file']).read_bytes(),data)
            self.assertEqual(receipt['images'][0]['ranges'][0]['data'],data)

    def test_failed_sdk_command_does_not_stop_following_app(self):
        import device_sdk_incremental as sdk
        encoded=base64.b64encode(header()).decode();calls=[]
        class Tasks:
            session='1'*32
            def task(self,script,seconds,*,until=None):
                calls.append(script)
                if script==batch.membership_script():return 'CK_BATCH_MEMBER a.app\nCK_BATCH_MEMBER b.app\nCK_BATCH_MEMBERS_DONE\n'
                if script=='SDK':
                    if calls.count('SDK')==1:raise RuntimeError('persistentTaskFailed')
                    return 'fixture-receipt'
                return ''.join('CK_BATCH_APP_BEGIN '+str(i)+'\nCK1792_APP_BINDING '+str(i)+' '+b+' 1 2 '+encoded+'\nCK1792_APP_BINDINGS_DONE\nCK_BATCH_APP_END '+str(i)+' 0\n' for i,b in enumerate(('a.app','b.app')))+'CK_BATCH_GROUP_DONE\n'
        result=dict(state='completeWithinRequestedSDKMetadata',receipt={'images':[]})
        with tempfile.TemporaryDirectory(prefix='batch-sdk-failure-',dir=ROOT/'tmp') as temp:
            with patch.object(sdk,'prepare',return_value={'script':'SDK'}),patch.object(sdk,'parse',return_value=result):
                report,path=batch.collect(Tasks(),temp,include_sdk=True)
            self.assertEqual(calls.count('SDK'),2)
            self.assertEqual(report['apps'][0]['sdkEvidence']['state'],'commandFailed')
            self.assertEqual(report['apps'][1]['sdkEvidence']['state'],'completeWithinRequestedSDKMetadata')
            self.assertEqual(report['state'],'partial')

    def test_sdk_budget_summary_is_separate_from_primary_identity_counts(self):
        tasks=SDKStateTasks('budget')
        with tempfile.TemporaryDirectory(prefix='batch-sdk-budget-',dir=ROOT/'tmp') as temp:
            report,path=batch.collect(tasks,temp,clock=lambda:tasks.now,include_sdk=True)
            self.assertEqual(report['state'],'partial')
            self.assertEqual(report['summary']['collected'],5)
            self.assertEqual(report['summary']['failed'],1)
            self.assertEqual(report.get('sdkSummary'),{'completeWithinRequestedSDKMetadata':1,'commandFailed':1,
                                                     'notAttemptedBudget':3,'notAttemptedMissingIdentity':1})
            self.assertTrue(report.get('budgetExhausted'))
            self.assertEqual(json.loads(path.read_text(encoding='utf-8')),report)
            self.assertEqual(tasks.sdk_calls,2)

    def test_identity_phase_stop_explains_why_sdk_collection_never_started(self):
        for mode,pending_state in (('staticBudget','notAttemptedBudget'),('staticConnection','notAttemptedConnection')):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory(prefix='batch-sdk-unstarted-',dir=ROOT/'tmp') as temp:
                tasks=SDKStateTasks(mode)
                report,path=batch.collect(tasks,temp,clock=lambda:tasks.now,include_sdk=True)
                self.assertEqual([row['sdkEvidence']['state'] for row in report['apps']],
                                 [pending_state]*3+['notAttemptedMissingIdentity']*3)
                self.assertEqual(report['sdkSummary'],{pending_state:3,'notAttemptedMissingIdentity':3})
                self.assertEqual(tasks.sdk_calls,0)
                self.assertEqual(json.loads(path.read_text(encoding='utf-8')),report)

    def test_sdk_early_stop_labels_remaining_without_overwriting_success_or_failure(self):
        import device_sdk_incremental as sdk
        cases=(('connection','attemptedOutcomeUnknown','notAttemptedConnection','interrupted'),
               ('prepare','localPreparationFailed','notAttemptedLocalPreparationFailure','localPreparationFailed'),
               ('write','localReceiptWriteFailed','notAttemptedLocalReceiptWriteFailure','localReceiptWriteFailed'))
        for mode,current_state,pending_state,batch_state in cases:
            with self.subTest(mode=mode),tempfile.TemporaryDirectory(prefix='batch-sdk-stop-',dir=ROOT/'tmp') as temp:
                tasks=SDKStateTasks(mode);snapshots=[];original_receipt={}
                real_prepare=sdk.prepare;real_atomic=batch.atomic
                def prepare(identity,**kwargs):
                    if mode=='prepare' and identity['bundle']=='c.stop':raise ValueError('fixture preparation failure')
                    return real_prepare(identity,**kwargs)
                def atomic(path,value):
                    if mode=='write' and path.name=='receipt.json' and path.parent.name=='sdk-2':
                        raise OSError('fixture receipt failure')
                    real_atomic(path,value)
                    if path.name=='collection.json':
                        snapshots.append(json.loads(path.read_text(encoding='utf-8')))
                    elif path.parent.name=='sdk-0':original_receipt[path]=path.read_text(encoding='utf-8')
                with patch.object(sdk,'prepare',side_effect=prepare),patch.object(batch,'atomic',side_effect=atomic):
                    report,path=batch.collect(tasks,temp,include_sdk=True)
                self.assertEqual(report['state'],batch_state)
                states=[row.get('sdkEvidence',{}).get('state') for row in report['apps']]
                self.assertEqual(states,['completeWithinRequestedSDKMetadata','commandFailed',current_state,
                                         'notAttemptedMissingIdentity',pending_state,pending_state])
                self.assertEqual(report.get('sdkSummary'),{'completeWithinRequestedSDKMetadata':1,'commandFailed':1,
                                                         current_state:1,'notAttemptedMissingIdentity':1,pending_state:2})
                started=next(row for row in snapshots if row['state']=='collectingSDKMetadata')
                self.assertEqual([row.get('sdkEvidence',{}).get('state') for row in started['apps']],
                                 ['notAttempted']*3+['notAttemptedMissingIdentity']+['notAttempted']*2)
                self.assertEqual(report['summary']['collected'],5)
                self.assertEqual(report['summary']['failed'],1)
                self.assertEqual(json.loads(path.read_text(encoding='utf-8')),report)
                self.assertEqual(len(original_receipt),1)
                for receipt,text in original_receipt.items():self.assertEqual(receipt.read_text(encoding='utf-8'),text)
                self.assertEqual(tasks.sdk_calls,2 if mode=='prepare' else 3)

    def test_old_primary_match_does_not_grant_embedded_resource_reuse(self):
        row=dict(bundle='a.app',staticState='collected',identity=dict(version='1',build='2',uuid='a'*32))
        baseline={'a.app':dict(version=dict(status='available',value='1'),build=dict(status='available',value='2'),primaryUUIDs=['a'*32])}
        result=batch.classify_historical(row,baseline)
        self.assertEqual(result['state'],'primaryIdentityMatches');self.assertFalse(result['reused'])

    def test_full_controller_runs_real_bash_membership_and_collector(self):
        with tempfile.TemporaryDirectory(prefix='batch-e2e-',dir=ROOT/'tmp') as temp:
            work=Path(temp);app=work/'Fixture.app';app.mkdir();(app/'Info.plist').write_bytes(b'fixture')
            (app/'Main').write_bytes(header()+b'PRIVATE_EXECUTABLE_TAIL_MUST_NOT_RETURN')
            utilities=work/'bin';utilities.mkdir()
            programs={
                'timeout':'#!/bin/bash\nif [[ $1 == --kill-after=* ]]; then shift; fi; shift; "$@"\n',
                'rootfs':'#!/bin/bash\nprintf "%s\\n" "$1"\n',
                'uicache':'''#!/bin/bash
if [[ $1 == -l ]]; then printf 'b.good : %s/Fixture.app\\n' "$PWD"; else printf 'Path: %s/Fixture.app\\n' "$PWD"; fi
''',
                'plutil':'''#!/bin/bash
if [[ $1 == -help ]]; then echo '-extract'; exit 0; fi
case "$2" in CFBundleIdentifier) echo b.good;; CFBundleShortVersionString) echo 1.2;; CFBundleVersion) echo 3;; CFBundleExecutable) echo Main;; *) exit 8;; esac
'''}
            for name,content in programs.items():(utilities/name).write_text(content,encoding='utf-8')
            test=self;calls=[]
            class Tasks:
                session='a'*32
                def task(self,script,seconds,*,until=None):
                    calls.append((seconds,until));path=work/'current-task.sh';path.write_text(script,encoding='utf-8')
                    result=subprocess.run([shutil.which('bash'),'-c','chmod +x bin/*; PATH="$PWD/bin:$PATH" bash current-task.sh'],cwd=work,capture_output=True,text=True,timeout=25)
                    test.assertEqual(result.returncode,0,result.stderr)
                    return result.stdout
            report,path=batch.collect(Tasks(),work/'reports',include_sdk=True)
            self.assertEqual(report['state'],'declaredStaticScopeComplete');self.assertTrue(report['registrationMembershipStable'])
            self.assertEqual(report['summary']['collected'],1);self.assertEqual(len(calls),4)
            self.assertEqual(report['apps'][0]['sdkEvidence']['state'],'completeWithinRequestedSDKMetadata')
            self.assertTrue(all(until is not None for _,until in calls))
            self.assertNotIn('Fixture.app',path.read_text());self.assertNotIn('PRIVATE_EXECUTABLE',path.read_text())


if __name__=='__main__':unittest.main()
