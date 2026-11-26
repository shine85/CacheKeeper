"""保存诊断的离线字段分析回归。新增文件无旧版本可备份。"""
import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts'))
import device_collection_diagnostics as diagnostics
BUNDLES=('com.fixture.a','com.fixture.b','com.fixture.c','com.fixture.d','com.fixture.e')


def source():
    def node(ident,parent,category,size,entries):
        return dict(id=ident,parent=parent,category=category,logicalBytes=size,allocatedBytes=size,entries=entries,secret='DO_NOT_EXPORT')
    nodes=[node(1,0,'unknown',10000,12),node(2,1,'Documents',9000,3),node(3,2,'unknown',8000,1),
           node(4,1,'Library',800,4),node(5,4,'Caches',100,1),node(6,4,'Application Support',600,1),node(7,1,'tmp',50,1)]
    def root(ident,roles,owners,nodes):
        top=nodes[0]
        return dict(id=ident,token='PRIVATE_TOKEN',roles=roles,owners=owners,measurement=dict(state='complete',
            logicalBytes=top['logicalBytes'],allocatedBytes=top['allocatedBytes'],entries=top['entries'],nodes=nodes,
            uniqueInodes=top['entries'],duplicateInodes=0,physicalUniqueBytes='notMeasured',reclaimableBytes='notMeasured',deletionAuthorization='notGranted'))
    roots=[root(1,['home'],[BUNDLES[0]],nodes),root(2,['group'],[BUNDLES[0],'private.other.app'],[node(1,0,'unknown',2000,2),node(2,1,'unknown',1900,1)]),
           root(3,['extension'],[BUNDLES[0]],[node(1,0,'unknown',20,2),node(2,1,'tmp',10,1)])]
    app=dict(bundle=BUNDLES[0],version='1.2',build='3',name='PRIVATE_NAME',scan=dict(state='available',data=dict(bundle=BUNDLES[0],updated=100,complete=True,rows=[])),
        imageDiskCache=dict(state='available',data=dict(updated=101,state='blocked',observed=1,runtimeInfo=dict(packageVersion='0.7.2-214.1'),secret='DO_NOT_EXPORT')),
        gurdCache=dict(state='missing'),cleanup=dict(state='available',data=dict(updated=102,removed=4,bytes=100,cleanupContext=dict(state='recorded',packageVersion='0.7.2-215.1',appVersion='1.2',appBuild='3'))))
    return dict(schemaVersion=1,generatedAt=1234,environment=dict(pluginVersion='0.7.2-215.1',private='DO_NOT_EXPORT'),apps=[app],
        capacityMeasurement=dict(state='complete',totalRoots=3,completedRoots=3,failedRoots=0,entries=[dict(bundle=BUNDLES[0],rootIds=[1,2,3],state='registered'),dict(bundle='private.other.app',rootIds=[2],state='registered')],roots=roots))


class DiagnosticTests(unittest.TestCase):
    def run_analysis(self,data,baseline=None):
        self.assertIsNotNone(diagnostics,'diagnostic analyzer is not implemented')
        with tempfile.TemporaryDirectory(prefix='diagnostic-analysis-',dir=ROOT/'tmp') as temp:
            path=Path(temp)/'current.json';path.write_text(json.dumps(data),encoding='utf-8');before=path.read_bytes()
            previous=None
            if baseline is not None:previous=Path(temp)/'baseline.json';previous.write_text(json.dumps(baseline),encoding='utf-8')
            result=diagnostics.analyze_diagnostics(path,previous,bundles=BUNDLES)
            self.assertEqual(path.read_bytes(),before);self.assertEqual(result['sourceSHA256'],hashlib.sha256(before).hexdigest())
            return result

    def test_home_documents_and_group_stay_separate_without_parent_double_counting(self):
        result=self.run_analysis(source());app=result['apps'][0];roots=app['capacity']['roots']
        self.assertEqual([row['bundle'] for row in result['apps']],list(BUNDLES))
        self.assertEqual(app['identity'],{'version':'1.2','build':'3'})
        self.assertEqual([row['roles'] for row in roots],[['home'],['group'],['extension']])
        self.assertEqual([row['logicalBytes'] for row in roots],[10000,2000,20])
        self.assertEqual(roots[0]['categories']['Documents']['logicalBytes'],9000)
        self.assertEqual(roots[0]['standardCacheLogicalBytes'],150)
        self.assertEqual(roots[1]['ownersCount'],2)
        self.assertEqual(app['capacity']['standardCacheLogicalBytes'],160)
        self.assertEqual(result['scope'],'fiveAppSavedDiagnosticAnalysis');self.assertEqual(result['validationScope'],'selectedFields')
        self.assertEqual(result['effectVerification'],'notPerformed');self.assertEqual(result['observation'],'saved')
        self.assertTrue(result['nonAtomic']);self.assertTrue(result['notRevalidatedAtExport']);self.assertFalse(result['deletionAuthorized'])
        exported=json.dumps(result)
        for private in ('DO_NOT_EXPORT','PRIVATE_TOKEN','PRIVATE_NAME','private.other.app','unknown'):
            if private!='unknown':self.assertNotIn(private,exported)

    def test_partial_capacity_does_not_claim_complete_standard_cache_total(self):
        data=source();data['capacityMeasurement']['state']='partial';data['capacityMeasurement']['completedRoots']=2;data['capacityMeasurement']['failedRoots']=1
        data['capacityMeasurement']['roots'][0]['measurement']['state']='partial'
        result=self.run_analysis(data)
        self.assertIsNone(result['apps'][0]['capacity']['standardCacheLogicalBytes'])
        self.assertIsNone(result['apps'][0]['capacity']['roots'][0]['standardCacheLogicalBytes'])

    def test_components_compare_saved_records_without_claiming_freshness(self):
        baseline=source();data=copy.deepcopy(baseline);data['generatedAt']=9999
        result=self.run_analysis(data,baseline);components=result['apps'][0]['components']
        self.assertEqual(components['imageDiskCache']['comparisonToBaseline'],'unchanged')
        self.assertFalse(components['imageDiskCache']['producerMatchesReport'])
        self.assertTrue(components['cleanup']['producerMatchesReport'])
        self.assertEqual(components['scan']['producerMatchesReport'],'unknown')
        self.assertEqual(components['scan']['updated'],100)
        self.assertTrue(result['notRevalidatedAtExport'])
        data['apps'][0]['imageDiskCache']['data']['observed']=2
        changed=self.run_analysis(data,baseline)['apps'][0]['components']['imageDiskCache']
        self.assertEqual(changed['comparisonToBaseline'],'changed')
        self.assertEqual(changed.get('timestampComparedToBaseline'),'unchanged')
        data['apps'][0]['imageDiskCache']['data']['updated']=99
        self.assertEqual(self.run_analysis(data,baseline)['apps'][0]['components']['imageDiskCache'].get('timestampComparedToBaseline'),'regressed')
        data['apps'][0]['imageDiskCache']['data']['updated']=103
        self.assertEqual(self.run_analysis(data,baseline)['apps'][0]['components']['imageDiskCache'].get('timestampComparedToBaseline'),'advanced')
        baseline['apps'][0]['build']='4'
        baseline['apps'][0]['cleanup']['data']['cleanupContext']['appBuild']='4'
        self.assertEqual(self.run_analysis(data,baseline)['apps'][0]['components']['imageDiskCache']['comparisonToBaseline'],'notComparable')

    def test_missing_capacity_and_apps_are_explicit(self):
        result=self.run_analysis(dict(schemaVersion=1,generatedAt=1234,environment=dict(pluginVersion='0.7.2-215.1'),apps=[]))
        self.assertEqual(len(result['apps']),5)
        self.assertEqual(result['apps'][0]['capacity']['state'],'notObserved')
        self.assertEqual(result['apps'][0]['components']['scan']['wrapperState'],'notObserved')
        self.assertEqual(result['apps'][0]['components']['scan']['comparisonToBaseline'],'noBaseline')

    def test_not_measured_and_unmeasured_planned_roots_remain_explicit(self):
        data=source();data['capacityMeasurement']={'schemaVersion':1,'state':'notMeasured'}
        result=self.run_analysis(data)
        self.assertEqual(result['apps'][0]['capacity']['state'],'notMeasured')
        self.assertIsNone(result['apps'][0]['capacity']['standardCacheLogicalBytes'])
        data=source();capacity=data['capacityMeasurement'];capacity['state']='partial'
        capacity['roots'].pop();capacity['completedRoots']=2
        result=self.run_analysis(data);value=result['apps'][0]['capacity']
        self.assertEqual(value['state'],'partial');self.assertEqual(value['missingRootsCount'],1)
        self.assertEqual(len(value['roots']),2);self.assertIsNone(value['standardCacheLogicalBytes'])

    def test_source_change_during_read_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix='diagnostic-read-race-',dir=ROOT/'tmp') as temp:
            path=Path(temp)/'source.json';path.write_text(json.dumps(source()),encoding='utf-8');real_read=Path.read_bytes
            def changing_read(candidate):
                raw=real_read(candidate)
                if candidate==path:candidate.write_bytes(raw+b' ')
                return raw
            with patch.object(Path,'read_bytes',new=changing_read):
                with self.assertRaises(ValueError):diagnostics.analyze_diagnostics(path,bundles=BUNDLES)

    def test_bad_tree_counts_and_owner_references_fail(self):
        mutations=(lambda d:d['capacityMeasurement']['roots'][0]['measurement']['nodes'][1].update(id=1),
                   lambda d:d['capacityMeasurement']['roots'][0]['measurement']['nodes'][1].update(parent=999),
                   lambda d:d['capacityMeasurement']['roots'][0]['measurement']['nodes'][1].update(logicalBytes=10001),
                   lambda d:d['capacityMeasurement']['roots'][0]['measurement']['nodes'][1].update(logicalBytes=True),
                   lambda d:d['capacityMeasurement']['roots'][0]['measurement']['nodes'][1].update(parent=2),
                   lambda d:d['capacityMeasurement']['roots'][0].update(owners=['private.other.app']),
                   lambda d:d['capacityMeasurement']['entries'][0].update(rootIds=[1,1]),
                   lambda d:d['capacityMeasurement']['entries'][0].update(rootIds=[1,2]),
                   lambda d:d['capacityMeasurement']['entries'][0].update(rootIds=[1,2,3,4]),
                   lambda d:d['capacityMeasurement']['roots'][1].update(id=1))
        for mutate in mutations:
            with self.subTest(mutation=mutate):
                data=source();mutate(data)
                with self.assertRaises(ValueError):self.run_analysis(data)

    def test_older_cleanup_installation_is_retained_without_comparing_as_current(self):
        data=source();data['apps'][0].update(version='2.0',build='4')
        result=self.run_analysis(data,copy.deepcopy(data));cleanup=result['apps'][0]['components']['cleanup']
        self.assertEqual(cleanup.get('producerInstallationMatch'),'mismatch')
        self.assertEqual(cleanup['comparisonToBaseline'],'notComparable')

    def test_duplicate_json_keys_and_oversize_input_fail(self):
        self.assertIsNotNone(diagnostics,'diagnostic analyzer is not implemented')
        with tempfile.TemporaryDirectory(prefix='diagnostic-json-',dir=ROOT/'tmp') as temp:
            path=Path(temp)/'invalid.json';path.write_text('{"apps":[],"apps":[]}',encoding='utf-8')
            with self.assertRaises(ValueError):diagnostics.analyze_diagnostics(path,bundles=BUNDLES)
            with path.open('wb') as handle:handle.truncate(128*1024*1024+1)
            with self.assertRaises(ValueError):diagnostics.analyze_diagnostics(path,bundles=BUNDLES)


if __name__=='__main__':unittest.main()
