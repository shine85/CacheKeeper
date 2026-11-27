"""离线报告包文件回归；新文件无旧版本可备份。"""
import base64
import builtins
from collections import Counter
import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts'))
import device_collection_session as session

FOCUS=('com.ss.iphone.ugc.Aweme','com.tencent.mqq','com.baidu.netdisk','com.360buy.jdmobile','app.swiftgram.ios')
NAMES=('SDWebImage YYCache PINCache Kingfisher CocoaLumberjack YYKit Cache DKCache YYWebImage '
       'CITICLog Loggerithm MJFLog VolcBaseLog TTSDKVolcLog TTSDKLivePullVolcLog glog hitlog vllog xlog').split()


def fixture(directory):
    directory=Path(directory);run='20261126T000000Z-12345678';folder=directory/run;folder.mkdir()
    rows=[];objects=[];receipts=[]
    for index,(bundle,state) in enumerate(zip(FOCUS[:4],('completeWithinRequestedSDKMetadata','partial','attemptedOutcomeUnknown','notAttemptedMissingIdentity'))):
        row=dict(bundle=bundle,staticState='failed' if index==3 else 'collected',runtimeState='notAttempted',sdkEvidence=dict(state=state),privateExtra='DO_NOT_EXPORT')
        identity=dict(bundle=bundle,version='1.2',build='3',uuid='11'*16)
        if index!=3:row['identity']=identity
        if index<2:
            data=b'local synthetic technical metadata';sha=hashlib.sha256(data).hexdigest()
            target=folder/('sdk-'+str(index));target.mkdir();obj=target/(sha+'.bin');obj.write_bytes(data);objects.append(obj)
            checks=[dict(sdk=name,presence='absent',state='absent',gaps=[],runtimeABIValidated=False) for name in NAMES]
            if index==1:checks[0].update(presence='inaccessible',state='unavailable')
            evidence=row['sdkEvidence']
            evidence.update(schemaVersion=1,kind='cachekeeper.sdkIncrementalReceipt',bundle=bundle,
                identityBinding=dict(state='matched',expected=identity,observed=dict(version='1.2',build='3',uuid='11'*16)),
                rawBytes=len(data),sdkChecks=checks,receipt='sdk-'+str(index)+'/receipt.json',evidenceSource='fresh',
                uncovered=['containerAssociation','ALogExcluded','unlistedOrStaticallyLinkedSDKs','SDKInstructionBodies','runtimeOwnerAndABI','resourceContract'],
                privateExtra='DO_NOT_EXPORT')
            app=dict(bundle=bundle,state='identityStable',verification=dict(runtimeObserved=False,safeResourceContractEstablished=False),
                     records=[['APP_VERSION','0',base64.b64encode(b'1.2').decode(),'0',base64.b64encode(b'3').decode()],['CONTAINERS_END','notCollected','0']])
            app['records'].extend(['FRAMEWORK_CHECK',check['sdk'],check['presence']] for check in checks)
            image=dict(app=bundle,sdk='PRIMARY',verification=dict(status='completeWithinDeclaredStaticScope',uuid='11'*16,runtimeABIValidated=False),
                       ranges=[dict(kind='header',offset=0,length=len(data),sha256=sha,file=sha+'.bin')])
            receipt=dict(schemaVersion=2,kind='cachekeeper.staticGapReceipt',transport='completeAndByteVerified',
                         membership='singleRequestedRegistration',staticAllComplete=False,apps=[app],images=[image],rawBytes=len(data),
                         coverage=[dict(bundle=bundle,deletionAuthorizedByThisBatch=False,runtimeStatus='notObserved')],
                         arbitraryPrivate='DO_NOT_EXPORT')
            path=target/'receipt.json';path.write_text(json.dumps(receipt),encoding='utf-8');receipts.append(path)
        rows.append(row)
    rows.append(dict(bundle='private.unrelated.app',staticState='failed',runtimeState='notAttempted',sdkEvidence=dict(state='notAttemptedMissingIdentity')))
    original=dict(schemaVersion=1,runID=run,state='partial',scope='allCurrentRegisteredApplicationMetadata',membershipCount=len(rows),apps=rows,
                  sdkCollectionRequested=True,runtimeExecuted=False,appLaunchExecuted=False,resourceDeletionExecuted=False,
                  summary=dict(collected=3,failed=2,attemptedOutcomeUnknown=0,notAttemptedConnection=0,notAttemptedBudget=0),
                  session='SECRET_SESSION_CANARY',arbitraryPrivate='DO_NOT_EXPORT')
    source=folder/'collection.json';source.write_text(json.dumps(original),encoding='utf-8')
    reports=[source]
    for _ in range(2):
        parent=reports[-1];parent_data=json.loads(parent.read_text(encoding='utf-8'));pin=hashlib.sha256(parent.read_bytes()).hexdigest()
        child=copy.deepcopy(parent_data);child.update(runID='resume-'+pin,mode='sdkResume',primaryIdentitySource='parentReport',
            parent=dict(path='../'+parent_data['runID']+'/collection.json',sha256=pin))
        for row in child['apps']:
            evidence=row['sdkEvidence'];evidence['evidenceSource']='historical'
            if 'receipt' in evidence:evidence['historicalReceipt']=dict(runID=parent_data['runID'],sha256=pin,path=evidence.pop('receipt'))
        child['sdkSummary']=dict(Counter(row['sdkEvidence']['state'] for row in child['apps']))
        folder=directory/child['runID'];folder.mkdir();path=folder/'collection.json';path.write_text(json.dumps(child),encoding='utf-8');reports.append(path)
    return reports,receipts,objects


class SessionTests(unittest.TestCase):
    def prepare(self,*args):
        return session.prepare_session(*args)

    def test_chained_sources_make_fixed_chinese_package_without_private_fields(self):
        with tempfile.TemporaryDirectory(prefix='collection-session-',dir=ROOT/'tmp') as temp:
            reports,_,_=fixture(temp);before=[p.read_bytes() for p in reports];output=Path(temp)/'offline.zip'
            summary=self.prepare(reports[-1],output)
            self.assertEqual(summary['state'],'offlinePreparationComplete');self.assertFalse(summary['executionAvailable'])
            self.assertEqual(summary['apps'],5);self.assertEqual(summary['sha256'],hashlib.sha256(output.read_bytes()).hexdigest())
            with zipfile.ZipFile(output) as archive:
                self.assertEqual(archive.namelist(),['session.json','README.md','manifest.json'])
                package=json.loads(archive.read('session.json'));readme=archive.read('README.md').decode('utf-8')
                manifest=json.loads(archive.read('manifest.json'))
                for item in manifest['files']:
                    data=archive.read(item['name']);self.assertEqual(item['length'],len(data));self.assertEqual(item['sha256'],hashlib.sha256(data).hexdigest())
                exported=''.join(archive.read(name).decode('utf-8') for name in archive.namelist())
            self.assertEqual([row['bundle'] for row in package['apps']],list(FOCUS))
            self.assertEqual([row['displayName'] for row in package['apps']],['抖音','QQ','百度网盘','京东','Swiftgram'])
            self.assertEqual([row['sdk']['state'] for row in package['apps']],
                             ['completeWithinRequestedSDKMetadata','partial','attemptedOutcomeUnknown','notAttemptedMissingIdentity','notObservedInReport'])
            self.assertEqual(package['state'],'preparedOnly');self.assertEqual(package['scope'],'scopePreparedOnly')
            self.assertEqual(package['capabilityGate']['state'],'blocked')
            self.assertFalse(package['capabilityGate']['executionAvailable'])
            self.assertEqual(set(package),{'schemaVersion','kind','state','scope','executionAvailable','effectVerification',
                                          'runtimeExecuted','appLaunchExecuted','resourceDeletionExecuted','sourceReportSHA256','apps','capabilityGate'})
            self.assertFalse(package['executionAvailable']);self.assertEqual(package['effectVerification'],'notPerformed')
            self.assertIn('离线准备报告包',readme)
            for key in ('runtimeExecuted','appLaunchExecuted','resourceDeletionExecuted'):self.assertFalse(package[key])
            for value in ('SECRET_SESSION_CANARY','DO_NOT_EXPORT','private.unrelated.app',str(Path(temp)),'sdk-0/receipt.json'):
                self.assertNotIn(value,exported)
            self.assertEqual([p.read_bytes() for p in reports],before)
            self.assertEqual(package['apps'][0]['sdk']['sourceReportSHA256'],hashlib.sha256(reports[0].read_bytes()).hexdigest())
            self.assertEqual(package['apps'][0]['sdk']['verifiedObjectRanges'],1)
            for row in package['apps']:
                self.assertTrue(row['missingRequirements']);self.assertEqual(row['effectVerification'],'notPerformed')

    def test_changed_source_report_fails_before_output(self):
        with tempfile.TemporaryDirectory(prefix='collection-session-report-',dir=ROOT/'tmp') as temp:
            reports,_,_=fixture(temp);reports[0].write_text(reports[0].read_text(encoding='utf-8')+' ',encoding='utf-8')
            output=Path(temp)/'offline.zip'
            with self.assertRaises(ValueError):self.prepare(reports[-1],output)
            self.assertFalse(output.exists())

    def test_wrong_app_or_identity_receipt_and_object_tampering_are_rejected(self):
        for mode in ('bundle','identity','bytes','rangePath','scope','sdkState'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory(prefix='collection-session-invalid-',dir=ROOT/'tmp') as temp:
                reports,receipts,objects=fixture(temp);output=Path(temp)/'offline.zip'
                receipt=json.loads(receipts[0].read_text(encoding='utf-8'))
                if mode=='bundle':receipt['apps'][0]['bundle']='com.wrong.app'
                elif mode=='identity':receipt['images'][0]['verification']['uuid']='22'*16
                elif mode=='rangePath':receipt['images'][0]['ranges'][0]['file']='../outside.bin'
                elif mode=='scope':receipt['staticAllComplete']=True
                elif mode=='sdkState':
                    data=json.loads(reports[-1].read_text(encoding='utf-8'));data['apps'][0]['sdkEvidence']['sdkChecks'][0]['state']='partial'
                    reports[-1].write_text(json.dumps(data),encoding='utf-8')
                else:objects[0].write_bytes(b'tampered')
                receipts[0].write_text(json.dumps(receipt),encoding='utf-8')
                with self.assertRaises(ValueError):self.prepare(reports[-1],output)
                self.assertFalse(output.exists())

    def test_historical_reference_cannot_escape_or_point_at_another_app(self):
        for mode in ('traversal','wrongReceipt','wrongIdentity'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory(prefix='collection-session-history-',dir=ROOT/'tmp') as temp:
                reports,_,_=fixture(temp);data=json.loads(reports[-1].read_text(encoding='utf-8'))
                if mode=='traversal':data['apps'][0]['sdkEvidence']['historicalReceipt']['path']='../../outside.json'
                elif mode=='wrongReceipt':data['apps'][0]['sdkEvidence']['historicalReceipt']['path']='sdk-1/receipt.json'
                else:data['apps'][0]['identity']['uuid']='22'*16
                reports[-1].write_text(json.dumps(data),encoding='utf-8');output=Path(temp)/'offline.zip'
                with self.assertRaises(ValueError):self.prepare(reports[-1],output)
                self.assertFalse(output.exists())

    def test_existing_output_is_never_replaced(self):
        with tempfile.TemporaryDirectory(prefix='collection-session-existing-',dir=ROOT/'tmp') as temp:
            reports,_,_=fixture(temp);output=Path(temp)/'offline.zip';output.write_bytes(b'existing original')
            with self.assertRaises(FileExistsError):self.prepare(reports[-1],output)
            self.assertEqual(output.read_bytes(),b'existing original')

    def test_partial_before_version_observation_is_preserved(self):
        with tempfile.TemporaryDirectory(prefix='collection-session-partial-',dir=ROOT/'tmp') as temp:
            reports,receipts,_=fixture(temp);report=json.loads(reports[0].read_text(encoding='utf-8'))
            evidence=report['apps'][1]['sdkEvidence'];evidence['identityBinding'].update(state='unverifiedOrChanged',observed={});evidence['rawBytes']=0
            for check in evidence['sdkChecks']:check.update(presence='notObserved',state='unavailable')
            receipt=json.loads(receipts[1].read_text(encoding='utf-8'));receipt['apps'][0].update(state='metadataUnavailable',records=[])
            receipt.update(images=[],rawBytes=0);receipts[1].write_text(json.dumps(receipt),encoding='utf-8')
            reports[0].write_text(json.dumps(report),encoding='utf-8');output=Path(temp)/'offline.zip'
            self.prepare(reports[0],output)
            with zipfile.ZipFile(output) as archive:package=json.loads(archive.read('session.json'))
            self.assertEqual(package['apps'][1]['sdk']['state'],'partial')
            self.assertEqual(package['apps'][1]['sdk']['identityBinding'],'unverifiedOrChanged')
            self.assertEqual(package['apps'][1]['sdk']['verifiedObjectRanges'],0)

    def test_one_failed_version_scalar_keeps_only_observed_primary_uuid(self):
        for code_index in (1,3):
            with self.subTest(code_index=code_index),tempfile.TemporaryDirectory(prefix='collection-session-version-',dir=ROOT/'tmp') as temp:
                reports,receipts,_=fixture(temp);report=json.loads(reports[0].read_text(encoding='utf-8'))
                evidence=report['apps'][1]['sdkEvidence'];evidence['identityBinding'].update(state='unverifiedOrChanged',observed={'uuid':'11'*16})
                receipt=json.loads(receipts[1].read_text(encoding='utf-8'));receipt['apps'][0]['state']='installationIdentityChanged'
                receipt['apps'][0]['records'][0][code_index]='1'
                reports[0].write_text(json.dumps(report),encoding='utf-8');receipts[1].write_text(json.dumps(receipt),encoding='utf-8')
                output=Path(temp)/'offline.zip';self.prepare(reports[0],output)
                with zipfile.ZipFile(output) as archive:package=json.loads(archive.read('session.json'))
                self.assertEqual(package['apps'][1]['sdk']['state'],'partial')
                self.assertEqual(package['apps'][1]['sdk']['identityBinding'],'unverifiedOrChanged')

    def test_framework_checks_must_match_receipt_records(self):
        for mode in ('presence','missing','duplicate','unknown','malformed'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory(prefix='collection-session-presence-',dir=ROOT/'tmp') as temp:
                reports,receipts,_=fixture(temp);receipt=json.loads(receipts[0].read_text(encoding='utf-8'))
                records=receipt['apps'][0]['records'];check=next(row for row in records if row[0]=='FRAMEWORK_CHECK')
                if mode=='presence':check[2]='inaccessible'
                elif mode=='missing':records.remove(check)
                elif mode=='duplicate':records.append(check.copy())
                elif mode=='unknown':check[1]='UnknownSDK'
                else:check.pop()
                receipts[0].write_text(json.dumps(receipt),encoding='utf-8');output=Path(temp)/'offline.zip'
                with self.assertRaises(ValueError):self.prepare(reports[-1],output)
                self.assertFalse(output.exists())

    def test_preparation_never_imports_a_transport(self):
        with tempfile.TemporaryDirectory(prefix='collection-session-no-transport-',dir=ROOT/'tmp') as temp:
            reports,_,_=fixture(temp);real_import=builtins.__import__
            def import_guard(name,*args,**kwargs):
                if any(word in name for word in ('transport','persistent_device_ssh','device_ssh')):
                    raise AssertionError('offline preparation imported transport')
                return real_import(name,*args,**kwargs)
            with patch.object(builtins,'__import__',side_effect=import_guard):
                result=self.prepare(reports[-1],Path(temp)/'offline.zip')
            self.assertFalse(result['executionAvailable'])

    def test_symlinked_evidence_directory_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix='collection-session-link-',dir=ROOT/'tmp') as temp:
            reports,receipts,_=fixture(temp);directory=receipts[0].parent;relocated=directory.with_name('outside')
            directory.rename(relocated)
            try:directory.symlink_to(relocated,target_is_directory=True)
            except OSError as error:self.skipTest('local symlink creation unavailable: '+str(error))
            output=Path(temp)/'offline.zip'
            with self.assertRaises(ValueError):self.prepare(reports[-1],output)
            self.assertFalse(output.exists())


if __name__=='__main__':unittest.main()
