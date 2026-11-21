import copy,json,pathlib,shutil,subprocess,unittest
from resource_access_schema import validate


class QQMethodSchemaTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('node'),'Node.js required for probe/schema integration')
    def test_actual_probe_receipts_validate_all_observed_tail_windows(self):
        script=pathlib.Path(__file__).with_name('test_qq_image_code.cjs')
        for mode,length in (('good',160),('compilerBoundary',20),('nearestClassBoundary',4)):
            with self.subTest(mode=mode):
                run=subprocess.run([shutil.which('node'),str(script),'--receipt',mode],
                                   capture_output=True,text=True,timeout=15,check=True)
                x=self.sample();x.update(json.loads(run.stdout));self.check(x)
                self.assertEqual(x['qqImageCode']['methods'][-1]['code']['windowLength'],length)

    def sample(self):
        uuid='a0a54fb62ee23508ae266be2c332bbf8'
        x=dict(schemaVersion=1,scope='privateResourceAccess',bundle='com.tencent.mqq',state='observed',reason='windowEnded',
            modules=[dict(id=1,uuid=uuid,role='app')],nodes=[dict(id=1,role='documents',labels=['unknown'])],
            events=[dict(kind='open',node=1,frames=[dict(module=1,offset='0x100')],result='returned')],
            image=dict(uuid=uuid,fileType=2,dyldIndex=1,bundlePathMatched=True,indexZeroSame=False,processMainSame=False),
            counters=dict(matched=1,dropped=0,objcObserved=0),observation='passiveAppCalls',resourceContract='notGranted',
            physicalRelease='notMeasured',coverage='fixedAPIsAbsolutePathsRenameSourceOnly',
            apiCoverage=[dict(api=name,state='installed') for name in ('open','openat','fopen','unlink','rename','mkdir')],
            queryCoverage='notApplicable',cleanup=dict(state='detached',failures=0),
            ownerIdentity='windowPointerAliasOnly',swiftOwner='blockedABI')
        x['qqImageMethods']={'schemaVersion':1,'scope':'SDImageCacheRuntimeTables','state':'complete','reason':'none','stoppedAt':'NSObject',
            'classes':[{'id':1,'name':'SDImageCache'}],
            'methods':[{'class':1,'kind':'instance','selector':'loadImage:','arguments':3,'types':['object','selector','object'],'result':'object','code':{'module':1,'offset':'0x100'}}]}
        return x

    def check(self,x):return validate(x,x['bundle'],'a0a54fb62ee23508ae266be2c332bbf8')
    def test_valid_current_and_legacy(self):
        x=self.sample();self.check(x);del x['qqImageMethods'];self.check(x)
    def test_closed_shape_and_terminal(self):
        mutations=[lambda d:d.update(scope='other'),lambda d:d.update(raw='PRIVATE'),lambda d:d.update(state='partial'),
            lambda d:d.update(stoppedAt='none'),lambda d:d['classes'][0].update(name='/PRIVATE'),
            lambda d:d['methods'][0].update(selector='/PRIVATE'),lambda d:d['methods'][0].update(arguments=2),
            lambda d:d['methods'][0].update(types=['object','selector','PRIVATE']),
            lambda d:d['methods'][0]['code'].update(module=2),lambda d:d['methods'].append(copy.deepcopy(d['methods'][0]))]
        for i,mutate in enumerate(mutations):
            x=self.sample();mutate(x['qqImageMethods'])
            with self.subTest(i=i),self.assertRaises(ValueError):self.check(x)
    def test_partial_is_not_success(self):
        x=self.sample();x['qqImageMethods'].update(state='partial',reason='deadline',stoppedAt='none')
        with self.assertRaises(ValueError):self.check(x)
        x['state']='partial';self.check(x)
    def test_complete_metadata_accepts_only_two_compiler_selectors(self):
        x=self.sample();row=x['qqImageMethods']['methods'][0]
        row.update(selector='.cxx_destruct',arguments=2,types=['object','selector'],result='void')
        self.check(x)
        for selector in ('.cxx_unknown','.cxx_destructExtra','private.path'):
            candidate=copy.deepcopy(x);candidate['qqImageMethods']['methods'][0]['selector']=selector
            with self.subTest(selector=selector),self.assertRaises(ValueError):self.check(candidate)
    def test_different_executable_cannot_claim_supported_table(self):
        x=self.sample();x['image']['uuid']='ab'*16;x['modules'][0]['uuid']='ab'*16
        with self.assertRaisesRegex(ValueError,'QQIdentity'):
            validate(x,x['bundle'],'ab'*16)
        x['qqImageMethods'].update(state='unsupportedIdentity',reason='identity',stoppedAt='none',classes=[],methods=[])
        x['state']='partial';validate(x,x['bundle'],'ab'*16)

    def test_complete_code_receipt_binds_all_22_bytes_and_fixed_windows(self):
        x=self.sample();x['qqImageMethods'].update(state='complete',reason='none',stoppedAt='NSObject')
        x['qqImageCode']=self.code_receipt()
        x['qqImageCode']['methods'][-1]['code'].update(windowLength=20,bytesHex='a5'*20)
        x['qqImageMethods']['methods']=[{'class':1,'kind':'instance','selector':row['selector'],'arguments':row['arguments'],
            'types':row['types'],'result':row['result'],'code':{'module':row['code']['module'],'offset':row['code']['offset']}}
            for row in x['qqImageCode']['methods']]
        x['qqImageMethods']['methods'] += [
            {'class':1,'kind':'instance','selector':'.cxx_destruct','arguments':2,'types':['object','selector'],'result':'void','code':{'module':1,'offset':'0x15f2800'}},
            {'class':1,'kind':'instance','selector':'.cxx_construct','arguments':2,'types':['object','selector'],'result':'object','code':{'module':1,'offset':'0x15f2810'}}]
        self.check(x)
        self.assertEqual(x['qqImageCode']['methods'][-1]['code']['windowLength'],20)
        candidate=copy.deepcopy(x);candidate['qqImageMethods']['methods'][-2]['code']['offset']='0x15f27f8'
        with self.assertRaisesRegex(ValueError,'invalidQQCodeLength'):self.check(candidate)
        candidate=copy.deepcopy(x);candidate['qqImageMethods']['methods'].append(
            {'class':1,'kind':'class','selector':'sharedStorage','arguments':2,'types':['object','selector'],
             'result':'object','code':{'module':1,'offset':'0x15f27f0'}})
        candidate['qqImageCode']['methods'][-1]['code'].update(windowLength=4,bytesHex='a5'*4)
        self.check(candidate)
        candidate['qqImageCode']['methods'][-1]['code'].update(windowLength=8,bytesHex='a5'*8)
        with self.assertRaisesRegex(ValueError,'invalidQQCodeLength'):self.check(candidate)
        candidate=copy.deepcopy(x);candidate['qqImageCode']['methods'][-1]['code'].update(windowLength=4,bytesHex='a5'*4)
        candidate['qqImageMethods']['methods'][-2]['code']['offset']='0x15f27f0'
        self.check(candidate)
        candidate['qqImageMethods']['methods'][-2]['code']['offset']='0x15f27f8'
        with self.assertRaisesRegex(ValueError,'invalidQQCodeLength'):self.check(candidate)
        mutations=(lambda d:d['methods'][0]['code'].update(protection='rwx'),
                   lambda d:d['methods'][0]['code'].update(bytesHex='zz'*d['methods'][0]['code']['windowLength']),
                   lambda d:d['methods'][0]['code'].update(windowLength=5),
                   lambda d:d['methods'][0]['code'].update(sha256After='0'*64),
                   lambda d:d['methods'][0]['code'].update(offset='0x15f1168'),
                   lambda d:d['methods'][8].update(selector='storeImage:forKey:'),
                   lambda d:d['methods'][-1]['code'].update(windowLength=164),
                   lambda d:d['methods'][0]['code'].update(module=0))
        for mutate in mutations:
            candidate=copy.deepcopy(x);mutate(candidate['qqImageCode'])
            with self.subTest(mutation=mutate),self.assertRaises(ValueError):self.check(candidate)

    def test_partial_code_receipt_is_empty_and_cannot_claim_complete_target(self):
        x=self.sample();x['state']='partial';x['qqImageCode']={'schemaVersion':1,'scope':'fixedSDImageCacheCodeWindows','state':'partial','reason':'deadline','methods':[]}
        self.check(x);x['state']='notTriggered'
        with self.assertRaisesRegex(ValueError,'incompleteQQCode'):self.check(x)

    def test_code_receipt_rejects_contradictory_observed_abi_and_implementation(self):
        x=self.sample();x['qqImageCode']=self.code_receipt()
        x['qqImageMethods']['methods']=[
            {key:copy.deepcopy(row[key]) for key in ('selector','arguments','types','result')} |
            {'class':1,'kind':'instance','code':{'module':row['code']['module'],'offset':row['code']['offset']}}
            for row in x['qqImageCode']['methods']]
        self.check(x)
        mutations=(lambda row:row.update(result='void'),
                   lambda row:row.update(arguments=3,types=['object','selector','object']),
                   lambda row:row.update(types=['object','pointer']),
                   lambda row:row['code'].update(offset='0x15f1160'),
                   lambda row:row['code'].update(module=2))
        for index,mutate in enumerate(mutations):
            candidate=copy.deepcopy(x)
            candidate['modules'].append({'id':2,'uuid':'ab'*16,'role':'other'})
            mutate(candidate['qqImageMethods']['methods'][0])
            with self.subTest(index=index),self.assertRaisesRegex(ValueError,'invalidQQCodeMethodBinding'):
                self.check(candidate)

    def code_receipt(self):
        entries=[('init','0x15f1164',2,['object','selector'],'object'),('dealloc','0x15f1398',2,['object','selector'],'void'),
          ('cachePathForKey:','0x15f1534',3,['object','selector','object'],'object'),('storeKeyWithDataToDisk:','0x15f1670',3,['object','selector','object'],'void'),
          ('notifyDelegate:','0x15f17b0',3,['object','selector','object'],'void'),('queryDiskCacheOperation:','0x15f18e4',3,['object','selector','object'],'void'),
          ('storeImage:imageData:forKey:toDisk:','0x15f1b88',6,['object','selector','object','object','object','bool'],'void'),('storeImage:forKey:','0x15f1c88',4,['object','selector','object','object'],'void'),
          ('syncStoreImage:forKey:','0x15f1cd4',4,['object','selector','object','object'],'void'),('storeImage:forKey:toDisk:','0x15f1d70',5,['object','selector','object','object','bool'],'void'),
          ('imageFromKey:','0x15f1dbc',3,['object','selector','object'],'object'),('imageFromKey:fromDisk:','0x15f1dcc',4,['object','selector','object','bool'],'object'),
          ('queryDiskCacheForKey:delegate:userInfo:','0x15f1eac',5,['object','selector','object','object','object'],'void'),('removeImageForKey:','0x15f204c',3,['object','selector','object'],'void'),
          ('removeImageForKey:fromDisk:','0x15f205c',4,['object','selector','object','bool'],'void'),('clearMemory','0x15f20f8',2,['object','selector'],'void'),
          ('clearDisk','0x15f2130',2,['object','selector'],'void'),('cleanDisk','0x15f21b4',2,['object','selector'],'void'),('getSize','0x15f2424',2,['object','selector'],'int32'),
          ('getDiskCount','0x15f25f4',2,['object','selector'],'int32'),('getMemorySize','0x15f2680',2,['object','selector'],'int32'),('getMemoryCount','0x15f27ec',2,['object','selector'],'int32')]
        rows=[]
        for i,(name,offset,args,types,result) in enumerate(entries):
            length=int(entries[i+1][1],16)-int(offset,16) if i<21 else 160
            digest=f'{i+1:064x}'
            rows.append({'selector':name,'arguments':args,'types':types,'result':result,'code':{'module':1,'offset':offset,'protection':'r-x','windowLength':length,'bytesHex':'a5'*length,'sha256Before':digest,'sha256After':digest}})
        return {'schemaVersion':1,'scope':'fixedSDImageCacheCodeWindows','state':'complete','reason':'none','methods':rows}


if __name__=='__main__':unittest.main(verbosity=2)
