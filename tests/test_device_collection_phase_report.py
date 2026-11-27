"""Regression tests for fixed-field normalization of saved collection stages."""
import json
from pathlib import Path
import sys
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts'))
import device_collection_phase_report as phase
BUNDLES=('com.ss.iphone.ugc.Aweme','com.tencent.mqq','com.baidu.netdisk','com.360buy.jdmobile','app.swiftgram.ios')
def make_report(bundle,mode,attempts,blocked,allowed,enabled=True,identity='verified',reason='none'):
    writer=dict(epochs=[dict(epoch=2,configuration=2,installation=1,mode=mode,enabled=enabled,identityState=identity,data=dict(nonemptyAttempts=attempts,nonemptyBlocked=blocked,nonemptyAllowed=allowed,attempts=attempts,blocked=blocked,allowed=allowed,overflow=False))],truncated=False,droppedEpochs=0)
    app=dict(bundle=bundle,name='SECRET_NAME',version='1',build='2',imageDiskCache=dict(state='available',data=dict(state='disabled' if not enabled else 'available',writeObservation=writer,operationHistory=dict(historyTruncated=False,processes=[dict(events=[dict(reason=reason,trigger='imageLoad',state='finished',eventID=1,started=11,configurationGeneration=2)],actions=[])]))),cleanup=dict(state='available',data=dict(cleanupHistory=dict(rounds=[]))),hostObserved=dict(state='available',data=dict(data=dict(runtimeInfo=dict(packageVersion='0.7.2-216.1'),updated=1))))
    return dict(schemaVersion=2,generatedAt=20,environment=dict(pluginVersion='0.7.2-217.1'),collection=dict(mode='savedRecords',rescanned=False),capacityMeasurement=dict(state='partial',freshness='savedObservationUnverified',installationMatch='notRevalidatedAtExport',sourceSampledAt=1),apps=[app])
class PhaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='phase-',dir=ROOT/'tmp');self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name)
    def write(self,name,value):
        path=self.root/(name+'.json');path.write_text(json.dumps(value),encoding='utf-8');return path
    def test_three_stage_writer_signals_and_disabled_not_triggered(self):
        paths=[self.write('p',make_report('com.baidu.netdisk','prevent',30,29,1)),self.write('c',make_report('com.baidu.netdisk','clean',31,0,31)),self.write('d',make_report('com.baidu.netdisk','clean',0,0,0,False,'notRevalidated','appDisabled'))]
        result=phase.analyze_phase_reports([('prevent',paths[0]),('clean',paths[1]),('disabled',paths[2])],bundles=BUNDLES)
        baidu=next(x for x in result['apps'] if x['bundle']=='com.baidu.netdisk')['stages']
        self.assertEqual(baidu['prevent']['writer']['nonempty'],dict(attempts=30,blocked=29,allowed=1))
        self.assertEqual(baidu['clean']['writer']['nonempty'],dict(attempts=31,blocked=0,allowed=31))
        self.assertEqual(baidu['disabled']['writer']['status'],'notTriggered')
        self.assertEqual(baidu['disabled']['outcome'],'insufficientEvidence')
        self.assertEqual(result['apps'][0]['stages']['prevent']['outcome'],'notObserved')
        self.assertNotIn('SECRET_NAME',json.dumps(result))
    def test_portable_phase_fixtures_have_pinned_hashes_and_reproduce_counts(self):
        base=ROOT/'tests/fixtures/collection-phases'
        manifest=json.loads((base/'manifest.json').read_text(encoding='utf-8'))
        result=phase.analyze_phase_reports([(stage,base/item['file'],item['sha256']) for stage,item in manifest.items()])
        stages=next(x for x in result['apps'] if x['bundle']=='com.baidu.netdisk')['stages']
        self.assertEqual(stages['prevent']['writer']['nonempty'],dict(attempts=30,blocked=29,allowed=1))
        self.assertEqual(stages['clean']['writer']['nonempty'],dict(attempts=31,blocked=0,allowed=31))
        self.assertEqual(stages['disabled']['outcome'],'insufficientEvidence')
        self.assertFalse(result['executionAvailable'])
        self.assertFalse(stages['prevent']['rescanned'])
        douyin=next(x for x in result['apps'] if x['bundle']=='com.ss.iphone.ugc.Aweme')['stages']['prevent']['gurd']
        self.assertEqual(douyin['state'],'savedObservation')
        self.assertTrue(any(op['reason']=='scopeUnproven' and op['submission']=='notSubmitted' for op in douyin['operations']))
    def test_hash_stage_and_bundle_validation(self):
        p=self.write('x',make_report('com.baidu.netdisk','prevent',1,1,0))
        with self.assertRaisesRegex(ValueError,'phaseDuplicateStage'):phase.analyze_phase_reports([('prevent',p),('prevent',p)],bundles=BUNDLES)
        with self.assertRaisesRegex(ValueError,'phaseDuplicateBundle'):phase.analyze_phase_reports([('prevent',p)],bundles=('a','a','b','c','d'))
        with self.assertRaisesRegex(ValueError,'phaseSourceSHA'):phase.analyze_phase_reports([('prevent',p,'0'*64)],bundles=BUNDLES)
    def test_unverified_or_overflow_epoch_is_insufficient(self):
        data=make_report('com.baidu.netdisk','prevent',30,30,0,identity='notRevalidated');data['apps'][0]['imageDiskCache']['data']['writeObservation']['epochs'][0]['data']['overflow']=True
        p=self.write('x',data);w=next(x for x in phase.analyze_phase_reports([('prevent',p)],bundles=BUNDLES)['apps'] if x['bundle']=='com.baidu.netdisk')['stages']['prevent']['writer']
        self.assertEqual(w['status'],'insufficientEvidence');self.assertEqual(w['reason'],'identityUnverifiedOrTruncated')
if __name__=='__main__':unittest.main()
