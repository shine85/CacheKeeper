"""Closed output boundary for a temporary authorized metadata window.

This validates shape/privacy, never deletion eligibility or runtime compatibility.
"""
import re

APPS = {
    'com.baidu.netdisk': 'b2b9d30a1caf31b482cac776e7eb2ba1',
    'com.tencent.mqq': 'a0a54fb62ee23508ae266be2c332bbf8',
    'com.ss.iphone.ugc.Aweme': '47e7af231b3a3c4fa46e77a5039433d6',
    'app.swiftgram.ios': '8a80ffd06a813a13b8d695a19097b644',
}
LABELS = {'unknown', 'postbox', 'media', 'cache', 'db', 'logs', 'download', 'model', 'models', 'EffectSDK', 'ByteDownload'}


def _keys(value, keys):
    if not isinstance(value, dict) or value.keys() != set(keys.split()):
        raise ValueError('invalidSchema')


def _count(value, maximum):
    return type(value) is int and 0 <= value <= maximum

def _capability(value,modules):
    _keys(value,'state classes')
    if value['state'] not in ('complete','partial') or not isinstance(value['classes'],list) or len(value['classes'])!=12:raise ValueError('invalidCapabilityMetadata')
    types={'object','block','pointer','selector','void','bool','int32','uint32','int64','uint64','double','float','class','int8','uint8','int16','uint16','cstring','other'}
    for i,row in enumerate(value['classes'],1):
        _keys(row,'id state methods')
        if (type(row['id']) is not int or row['id']!=i or row['state'] not in ('present','absent','unavailable') or
            not isinstance(row['methods'],list) or len(row['methods'])>48 or row['state']!='present' and row['methods'] or
            value['state']=='complete' and row['state']=='unavailable'):raise ValueError('invalidCapabilityClass')
        seen=set()
        for method in row['methods']:
            _keys(method,'id kind arguments types result code')
            if (not _count(method['id'],24) or not method['id'] or method['kind'] not in ('class','instance') or
                not _count(method['arguments'],12) or method['arguments']<2 or not isinstance(method['types'],list) or
                len(method['types'])!=method['arguments'] or any(type(t) is not str or t not in types for t in method['types']) or
                type(method['result']) is not str or method['result'] not in types):raise ValueError('invalidCapabilityMethod')
            key=(method['id'],method['kind'])
            if key in seen:raise ValueError('duplicateCapabilityMethod')
            seen.add(key);frame=method['code'];_keys(frame,'module offset')
            if not _count(frame['module'],len(modules)) or not frame['module'] or type(frame['offset']) is not str or not re.fullmatch(r'0x[0-9a-f]{1,16}',frame['offset']):raise ValueError('invalidCapabilityCode')


def _qq_methods(value,modules,bundle,expected_uuid):
    _keys(value,'schemaVersion scope state reason stoppedAt classes methods')
    if (bundle!='com.tencent.mqq' or type(value['schemaVersion']) is not int or value['schemaVersion']!=1 or
        value['scope']!='SDImageCacheRuntimeTables' or value['state'] not in ('complete','partial','absent','unsupportedIdentity') or
        value['reason'] not in ('none','identity','runtime','classAbsent','deadline','className','classLimit','classCycle','tableLimit','methodLimit','selector','duplicate','abi','source','release') or
        value['stoppedAt'] not in ('none','NSObject','root') or not isinstance(value['classes'],list) or len(value['classes'])>8 or
        not isinstance(value['methods'],list) or len(value['methods'])>256):raise ValueError('invalidQQMethods')
    if value['state']!='unsupportedIdentity' and expected_uuid!='a0a54fb62ee23508ae266be2c332bbf8':raise ValueError('invalidQQIdentity')
    if value['state']=='complete':
        if value['reason']!='none' or value['stoppedAt']=='none' or not value['classes']:raise ValueError('invalidQQComplete')
    elif value['stoppedAt']!='none':raise ValueError('invalidQQStop')
    if value['state'] in ('absent','unsupportedIdentity'):
        if value['reason']!=('classAbsent' if value['state']=='absent' else 'identity') or value['classes'] or value['methods']:raise ValueError('invalidQQUnavailable')
    if value['state']=='partial' and value['reason'] in ('none','identity','classAbsent'):raise ValueError('invalidQQPartial')
    names=set()
    for i,row in enumerate(value['classes'],1):
        _keys(row,'id name')
        if (type(row['id']) is not int or row['id']!=i or type(row['name']) is not str or
            not re.fullmatch(r'[A-Za-z_$][A-Za-z0-9_.$]{0,127}',row['name']) or row['name']=='NSObject' or
            i==1 and row['name']!='SDImageCache' or row['name'] in names):raise ValueError('invalidQQClass')
        names.add(row['name'])
    types={'object','block','pointer','selector','void','bool','int32','uint32','int64','uint64','double','float','class','int8','uint8','int16','uint16','cstring','other'}
    seen=set()
    for row in value['methods']:
        _keys(row,'class kind selector arguments types result code')
        if (not _count(row['class'],len(value['classes'])) or not row['class'] or row['kind'] not in ('class','instance') or
            type(row['selector']) is not str or (not re.fullmatch(r'[A-Za-z_$][A-Za-z0-9_$:]{0,191}',row['selector']) and row['selector'] not in ('.cxx_destruct','.cxx_construct')) or
            not _count(row['arguments'],12) or row['arguments']<2 or not isinstance(row['types'],list) or
            len(row['types'])!=row['arguments'] or any(type(t) is not str or t not in types for t in row['types']) or
            type(row['result']) is not str or row['result'] not in types):raise ValueError('invalidQQMethod')
        key=(row['class'],row['kind'],row['selector'])
        if key in seen:raise ValueError('duplicateQQMethod')
        seen.add(key);code=row['code'];_keys(code,'module offset')
        if not _count(code['module'],len(modules)) or not code['module'] or type(code['offset']) is not str or not re.fullmatch(r'0x[0-9a-f]{1,16}',code['offset']):raise ValueError('invalidQQSource')


def _qq_code(value,modules,bundle,expected_uuid,method_table):
    _keys(value,'schemaVersion scope state reason methods')
    reasons=('none','identity','metadata','module','deadline','methodMissing','abi','implementation','protection','bounds','read','changed')
    if (bundle!='com.tencent.mqq' or type(value['schemaVersion']) is not int or value['schemaVersion']!=1 or
        value['scope']!='fixedSDImageCacheCodeWindows' or value['state'] not in ('complete','partial','unsupportedIdentity') or
        value['reason'] not in reasons or not isinstance(value['methods'],list) or len(value['methods'])>22):
        raise ValueError('invalidQQCode')
    fixed=(('init','0x15f1164',2,('object','selector'),'object'),('dealloc','0x15f1398',2,('object','selector'),'void'),
        ('cachePathForKey:','0x15f1534',3,('object','selector','object'),'object'),('storeKeyWithDataToDisk:','0x15f1670',3,('object','selector','object'),'void'),
        ('notifyDelegate:','0x15f17b0',3,('object','selector','object'),'void'),('queryDiskCacheOperation:','0x15f18e4',3,('object','selector','object'),'void'),
        ('storeImage:imageData:forKey:toDisk:','0x15f1b88',6,('object','selector','object','object','object','bool'),'void'),
        ('storeImage:forKey:','0x15f1c88',4,('object','selector','object','object'),'void'),('syncStoreImage:forKey:','0x15f1cd4',4,('object','selector','object','object'),'void'),
        ('storeImage:forKey:toDisk:','0x15f1d70',5,('object','selector','object','object','bool'),'void'),('imageFromKey:','0x15f1dbc',3,('object','selector','object'),'object'),
        ('imageFromKey:fromDisk:','0x15f1dcc',4,('object','selector','object','bool'),'object'),('queryDiskCacheForKey:delegate:userInfo:','0x15f1eac',5,('object','selector','object','object','object'),'void'),
        ('removeImageForKey:','0x15f204c',3,('object','selector','object'),'void'),('removeImageForKey:fromDisk:','0x15f205c',4,('object','selector','object','bool'),'void'),
        ('clearMemory','0x15f20f8',2,('object','selector'),'void'),('clearDisk','0x15f2130',2,('object','selector'),'void'),('cleanDisk','0x15f21b4',2,('object','selector'),'void'),
        ('getSize','0x15f2424',2,('object','selector'),'int32'),('getDiskCount','0x15f25f4',2,('object','selector'),'int32'),
        ('getMemorySize','0x15f2680',2,('object','selector'),'int32'),('getMemoryCount','0x15f27ec',2,('object','selector'),'int32'))
    expected='a0a54fb62ee23508ae266be2c332bbf8'
    if value['state']=='unsupportedIdentity':
        if expected_uuid==expected or value['reason']!='identity' or value['methods']:
            raise ValueError('invalidQQCodeIdentity')
        return
    if expected_uuid!=expected:raise ValueError('invalidQQCodeIdentity')
    if value['state']=='partial':
        if value['reason'] in ('none','identity') or value['methods']:
            raise ValueError('invalidQQCodePartial')
        return
    if (method_table is None or method_table.get('state')!='complete' or method_table.get('reason')!='none' or
        method_table.get('stoppedAt')=='none' or not method_table.get('classes')):
        raise ValueError('invalidQQCodeMethodTable')
    observed=[row for row in method_table.get('methods',[]) if row['class']==1 and row['kind']=='instance']
    observed_names=[row['selector'] for row in observed]
    if (len(observed_names)!=len(set(observed_names)) or
        any(name not in {row[0] for row in fixed} and name not in ('.cxx_destruct','.cxx_construct') for name in observed_names) or
        any(name not in observed_names for name,_,_,_,_ in fixed)):
        raise ValueError('invalidQQCodeObservedMethodSet')
    observed_by_name={row['selector']:row for row in observed}
    main=[i for i,row in enumerate(modules,1) if row['uuid']==expected and row['role']=='app']
    if len(main)!=1:raise ValueError('invalidQQCodeModule')
    if len(value['methods'])!=len(fixed):raise ValueError('invalidQQCodeCount')
    for i,(row,spec) in enumerate(zip(value['methods'],fixed)):
        _keys(row,'selector arguments types result code')
        selector,offset,arguments,types,result=spec
        method=observed_by_name[selector]
        if (method['arguments']!=arguments or tuple(method['types'])!=types or method['result']!=result or
            method['code']['module']!=main[0] or method['code']['offset']!=offset):
            raise ValueError('invalidQQCodeMethodBinding')
        code=row['code'];_keys(code,'module offset protection windowLength bytesHex sha256Before sha256After')
        length=code['windowLength']
        if (row['selector']!=selector or type(row['arguments']) is not int or row['arguments']!=arguments or
            not isinstance(row['types'],list) or tuple(row['types'])!=types or row['result']!=result or
            type(code['module']) is not int or code['module']!=main[0] or code['offset']!=offset or code['protection']!='r-x' or
            not _count(length,4096) or length<4 or length%4 or
            type(code['sha256Before']) is not str or not re.fullmatch('[0-9a-f]{64}',code['sha256Before']) or
            type(code['bytesHex']) is not str or len(code['bytesHex'])!=length*2 or not re.fullmatch('[0-9a-f]+',code['bytesHex']) or
            type(code['sha256After']) is not str or code['sha256Before']!=code['sha256After']):
            raise ValueError('invalidQQCodeWindow')
        current=int(offset,16)
        planned=(int(fixed[i+1][1],16)-current) if i+1<len(fixed) else 160
        later=[int(item['code']['offset'],16) for item in method_table.get('methods',[])
               if item['code']['module']==main[0] and item['code']['offset']!=offset and
               int(item['code']['offset'],16)>current]
        required=min(planned,min(later)-current if later else planned)
        if length!=required:raise ValueError('invalidQQCodeLength')
    if value['reason']!='none':raise ValueError('invalidQQCodeComplete')


def _yy_owner(value,modules,bundle):
    fields='state reason identity scope source owners paths events counters'
    if isinstance(value,dict) and 'callDetails' in value:fields+=' callDetails'
    _keys(value,fields)
    if (bundle!='com.ss.iphone.ugc.Aweme' or value['state'] not in ('unavailable','partial','observed','notTriggered') or
        value['reason'] not in ('identity','class','source','entryUnreadable','entryRedirectUnverified','abi','attach','none') or
        value['identity']!='windowPointerAliasOnly' or value['scope']!='fixedYYDiskCacheNaturalCalls'):
        raise ValueError('invalidYYIdentity')
    def frame(row):
        _keys(row,'module offset')
        if not _count(row['module'],len(modules)) or not row['module'] or type(row['offset']) is not str or not re.fullmatch(r'0x[0-9a-f]{1,16}',row['offset']):
            raise ValueError('invalidYYFrame')
    source=value['source']
    if source is not None:
        _keys(source,'write path')
        for name,offset in [('write','0x1563f9f4'),('path','0x12da3ff4')]:
            frame(source[name])
            if source[name]['offset']!=offset or modules[source[name]['module']-1]['uuid']!='cc3b646814e43c7fa8708f1eb5f4adeb':raise ValueError('invalidYYSource')
    if (value['state']=='unavailable') != (source is None) or (value['state']=='unavailable') == (value['reason']=='none'):
        raise ValueError('invalidYYSourceState')
    for name,bound in [('owners',64),('paths',32),('events',64)]:
        if not isinstance(value[name],list) or len(value[name])>bound:raise ValueError('invalidYYBound')
    for i,row in enumerate(value['owners'],1):
        _keys(row,'id')
        if type(row['id']) is not int or row['id']!=i:raise ValueError('invalidYYOwner')
    for i,row in enumerate(value['paths'],1):
        _keys(row,'id scope selectedRootSpelling')
        if (type(row['id']) is not int or row['id']!=i or row['scope'] not in ('caches','tmp','documents','support','mainOther','groupOrOther') or
            type(row['selectedRootSpelling']) is not bool or row['selectedRootSpelling'] and row['scope']!='support'):
            raise ValueError('invalidYYPath')
    c=value['counters'];_keys(c,'calls matched unresolved errors dropped limited reentrant')
    if (any(not _count(c[k],128) for k in ('calls','matched','unresolved','errors','dropped')) or
        not _count(c['limited'],1) or not _count(c['reentrant'],2**53-1) or
        c['calls']!=c['matched']+c['unresolved']+c['errors'] or c['matched']!=len(value['events'])+c['dropped']):raise ValueError('invalidYYCounters')
    if 'callDetails' in value:
        detail=value['callDetails'];_keys(detail,'schemaVersion calls rejections receivers receiverUnavailable receiverDropped sites siteDropped')
        if type(detail['schemaVersion']) is not int or detail['schemaVersion']!=1:raise ValueError('invalidYYCallDetails')
        calls=detail['calls'];_keys(calls,'write path')
        rejected=detail['rejections'];_keys(rejected,'selectorMismatch receiverMismatch ownerLimit pathUnavailable pathLimit')
        if (any(not _count(n,128) for n in list(calls.values())+list(rejected.values())) or
            sum(calls.values())!=c['calls'] or sum(rejected.values())!=c['unresolved'] or
            rejected['pathUnavailable']+rejected['pathLimit']>calls['path'] or
            not isinstance(detail['receivers'],list) or len(detail['receivers'])>16 or
            not _count(detail['receiverUnavailable'],128) or not _count(detail['receiverDropped'],128)):
            raise ValueError('invalidYYCallDetails')
        totals={'write':0,'path':0}
        for row in detail['receivers']:
            _keys(row,'api className relation depth resolvedImplementation calls')
            if (row['api'] not in totals or
                row['className'] is not None and (type(row['className']) is not str or not re.fullmatch(r'[A-Za-z_$][A-Za-z0-9_.$]{0,127}',row['className'])) or
                row['relation'] not in ('subclass','unrelated','depthLimit','unavailable') or
                row['resolvedImplementation'] not in ('pinned','other','absent') or not _count(row['calls'],128) or not row['calls']):
                raise ValueError('invalidYYReceiverDetail')
            if row['relation']=='subclass':
                if not _count(row['depth'],16) or not row['depth']:raise ValueError('invalidYYReceiverDepth')
            elif row['depth'] is not None:raise ValueError('invalidYYReceiverDepth')
            totals[row['api']]+=row['calls']
        if (any(totals[api]>calls[api] for api in totals) or
            sum(totals.values())+detail['receiverUnavailable']+detail['receiverDropped']!=rejected['receiverMismatch']):
            raise ValueError('invalidYYReceiverCounts')
        if not isinstance(detail['sites'],list) or len(detail['sites'])>16 or not _count(detail['siteDropped'],128):raise ValueError('invalidYYSites')
        site_totals={'selectorMismatch':0,'receiverMismatch':0};site_calls={'write':0,'path':0};seen=set()
        for row in detail['sites']:
            _keys(row,'api reason caller calls')
            if row['api'] not in site_calls or row['reason'] not in site_totals or not _count(row['calls'],128) or not row['calls']:raise ValueError('invalidYYSite')
            if row['caller'] is not None:frame(row['caller'])
            key=(row['api'],row['reason'],None if row['caller'] is None else (row['caller']['module'],row['caller']['offset']))
            if key in seen:raise ValueError('duplicateYYSite')
            seen.add(key);site_totals[row['reason']]+=row['calls'];site_calls[row['api']]+=row['calls']
        if (any(site_totals[k]>rejected[k] for k in site_totals) or any(site_calls[k]>calls[k] for k in site_calls) or
            sum(site_totals.values())+detail['siteDropped']!=rejected['selectorMismatch']+rejected['receiverMismatch']):raise ValueError('invalidYYSiteCounts')
    for row in value['events']:
        _keys(row,'api owner path returned caller')
        if (row['api'] not in ('write','path') or not _count(row['owner'],len(value['owners'])) or not row['owner'] or
            row['returned'] is not True):raise ValueError('invalidYYEvent')
        if row['api']=='write':
            if row['path'] is not None:raise ValueError('invalidYYWritePath')
        elif not _count(row['path'],len(value['paths'])) or not row['path']:raise ValueError('invalidYYPathReference')
        if row['caller'] is not None:frame(row['caller'])
    if value['state']=='unavailable' and (value['owners'] or value['paths'] or value['events'] or any(c.values())):raise ValueError('invalidYYUnavailable')
    partial=bool(c['unresolved'] or c['errors'] or c['dropped'] or c['limited'])
    if value['state']!='unavailable' and value['state']!=('partial' if partial else 'observed' if value['events'] else 'notTriggered'):raise ValueError('invalidYYTerminal')


def _descriptor(value,nodes,modules):
    _keys(value,'schemaVersion scope state coverage objects before after apiCoverage counters events')
    if (type(value['schemaVersion']) is not int or value['schemaVersion']!=1 or value['scope']!='selectedRootOpenDescriptors' or
        value['state'] not in ('complete','partial') or value['coverage']!='vnodeFDsAndFixedCallsNotMappingsOrReferences'):
        raise ValueError('invalidDescriptorObservation')
    objects=value['objects']
    if not isinstance(objects,list) or len(objects)>128:raise ValueError('invalidDescriptorObjects')
    for i,row in enumerate(objects,1):
        _keys(row,'id node hint')
        if (type(row['id']) is not int or row['id']!=i or not _count(row['node'],len(nodes)) or not row['node'] or
            row['hint'] not in ('unknown','databaseName','databaseSidecarName','imageName','mediaName','structuredName','logName')):
            raise ValueError('invalidDescriptorObject')
    def association(row):
        if (not _count(row['object'],len(objects)) or not row['object'] or not _count(row['node'],len(nodes)) or
            not row['node'] or objects[row['object']-1]['node']!=row['node']):raise ValueError('invalidDescriptorAssociation')
    for side in ('before','after'):
        row=value[side];_keys(row,'state listed vnode outside unresolved matched errors objects')
        if (row['state'] not in ('complete','partial','unavailable','readError','entryLimit','timeLimit') or
            any(not _count(row[k],2048) for k in ('listed','vnode','outside','unresolved','matched','errors')) or
            row['vnode']>row['listed'] or row['vnode']!=sum(row[k] for k in ('outside','unresolved','matched','errors')) or
            not isinstance(row['objects'],list) or len(row['objects'])>128 or len(row['objects'])!=row['matched'] or
            row['state']=='complete' and (row['errors'] or row['unresolved'])):raise ValueError('invalidDescriptorSnapshot')
        for item in row['objects']:
            _keys(item,'object node sample');association(item);sample=item['sample'];_keys(sample,'logicalBytes allocatedBytes links')
            if (not _count(sample['logicalBytes'],2**53-1) or not _count(sample['allocatedBytes'],2**53-1) or
                sample['allocatedBytes']%512 or not _count(sample['links'],65535)):raise ValueError('invalidDescriptorSample')
    apis=('write','pwrite','writev','mmap','ftruncate');coverage=value['apiCoverage']
    if not isinstance(coverage,list) or len(coverage)>5:raise ValueError('invalidDescriptorCoverage')
    for i,row in enumerate(coverage):
        _keys(row,'api state')
        if row['api']!=apis[i] or row['state'] not in ('installed','missing','installing','failed'):raise ValueError('invalidDescriptorCoverage')
    counters=value['counters'];_keys(counters,'calls reentrant outside unresolved matched errors limited dropped')
    if (any(not _count(counters[k],4096) for k in ('calls','outside','unresolved','matched','errors','dropped')) or
        not _count(counters['reentrant'],2**53-1) or not _count(counters['limited'],1) or
        counters['calls']!=sum(counters[k] for k in ('outside','unresolved','matched','errors'))):raise ValueError('invalidDescriptorCounters')
    events=value['events']
    if not isinstance(events,list) or len(events)>128 or len(events)+counters['dropped']!=counters['matched']:raise ValueError('invalidDescriptorEvents')
    for e in events:
        _keys(e,'api object node frames outcome bytes identityAfter');association(e)
        if (e['api'] not in apis or not any(c['api']==e['api'] and c['state']=='installed' for c in coverage) or
            e['outcome'] not in ('returned','failed','unavailable') or e['identityAfter'] not in ('same','changed','unavailable')):raise ValueError('invalidDescriptorEvent')
        if e['outcome']=='returned' and e['api'] in ('write','pwrite','writev'):
            if not _count(e['bytes'],2**53-1):raise ValueError('invalidDescriptorBytes')
        elif e['bytes'] is not None:raise ValueError('invalidDescriptorBytes')
        if not isinstance(e['frames'],list) or len(e['frames'])>8:raise ValueError('invalidDescriptorFrames')
        for frame in e['frames']:
            _keys(frame,'module offset')
            if (not _count(frame['module'],len(modules)) or not frame['module'] or type(frame['offset']) is not str or
                not re.fullmatch(r'0x[0-9a-f]{1,16}',frame['offset'])):raise ValueError('invalidDescriptorFrames')
    if value['state']=='complete' and (any(value[s]['state']!='complete' for s in ('before','after')) or len(coverage)!=5 or
        any(c['state']!='installed' for c in coverage) or counters['unresolved'] or counters['errors'] or counters['dropped'] or counters['limited']):raise ValueError('incompleteDescriptorCoverage')
    return value


def validate(value, bundle, expected_uuid=None):
    expected_uuid = APPS.get(bundle) if expected_uuid is None else expected_uuid
    if not isinstance(expected_uuid,str) or not re.fullmatch('[0-9a-f]{32}',expected_uuid):
        raise ValueError('invalidExpectedImage')
    fields = 'schemaVersion scope bundle state reason modules nodes events image counters observation resourceContract physicalRelease coverage apiCoverage queryCoverage cleanup ownerIdentity swiftOwner'
    if isinstance(value,dict) and 'qqImageMethods' in value:fields+=' qqImageMethods'
    if isinstance(value,dict) and 'qqImageCode' in value:fields+=' qqImageCode'
    if isinstance(value,dict) and 'descriptorObservation' in value:fields+=' descriptorObservation'
    if isinstance(value,dict) and 'capabilityMetadata' in value:fields+=' capabilityMetadata'
    if isinstance(value,dict) and 'yyOwnerObservation' in value:fields+=' yyOwnerObservation'
    if isinstance(value,dict) and 'inputCoverage' in value:
        fields+=' inputCoverage'
        coverage=value['inputCoverage']
        _keys(coverage,'calls reentrant relative outside matched errors limited')
        if (any(not _count(coverage[key],20001) for key in ('calls','relative','outside','matched','errors')) or
                not _count(coverage['reentrant'],2**53-1) or not _count(coverage['limited'],1) or
                coverage['calls']!=sum(coverage[key] for key in ('relative','outside','matched','errors','limited'))):
            raise ValueError('invalidInputCoverage')
    if isinstance(value, dict) and 'queryDiagnostic' in value:
        fields += ' queryDiagnostic'
        diagnostic=value['queryDiagnostic']
        _keys(diagnostic,'phase error methodCount matchedMethods')
        if (bundle!='com.baidu.netdisk' or value.get('queryCoverage')!='installationFailed' or
                value.get('state') not in ('partial','failed') or diagnostic['phase']!='queryAttach' or
                diagnostic['error'] not in ('invalidInstruction','interceptionFailed','wrongSignature','alreadyAttached','codeSigningPolicy','wrongType','unclassified') or
                not _count(diagnostic['methodCount'],4096) or not _count(diagnostic['matchedMethods'],4096)):
            raise ValueError('invalidQueryDiagnostic')
    if isinstance(value, dict) and 'setupDiagnostic' in value:
        fields += ' setupDiagnostic'
        diagnostic = value['setupDiagnostic']
        diagnostic_fields = 'phase error methodCount matchedMethods'
        if isinstance(diagnostic, dict) and 'releaseFailed' in diagnostic:
            diagnostic_fields += ' releaseFailed'
            if diagnostic['releaseFailed'] is not True: raise ValueError('invalidSetupDiagnostic')
        _keys(diagnostic, diagnostic_fields)
        if (value.get('state') != 'failed' or value.get('reason') not in ('setupRejected', 'detachFailed') or
                diagnostic['phase'] not in ('setup', 'queryLookup', 'queryRuntimeAPIs', 'queryList', 'querySelector', 'queryEncoding', 'queryOwner', 'queryAttach', 'queryFree', 'timer') or
                diagnostic['error'] not in ('api', 'null', 'bound', 'methods', 'owner', 'unclassified') or
                not _count(diagnostic['methodCount'], 4096) or not _count(diagnostic['matchedMethods'], 4096)):
            raise ValueError('invalidSetupDiagnostic')
    _keys(value, fields)
    if (bundle not in APPS or value['bundle'] != bundle or type(value['schemaVersion']) is not int or value['schemaVersion'] != 1 or
        value['scope'] != 'privateResourceAccess' or value['observation'] != 'passiveAppCalls' or
        value['resourceContract'] != 'notGranted' or value['physicalRelease'] != 'notMeasured' or
        value['coverage'] != 'fixedAPIsAbsolutePathsRenameSourceOnly' or value['ownerIdentity'] != 'windowPointerAliasOnly' or value['swiftOwner'] != 'blockedABI'):
        raise ValueError('invalidIdentity')
    if value['state'] not in ('observed', 'notTriggered', 'partial', 'failed') or value['reason'] not in (
        'windowEnded', 'eventLimit', 'callLimit', 'detachFailed', 'setupRejected'):
        raise ValueError('invalidTerminal')
    apis = ('open', 'openat', 'fopen', 'unlink', 'rename', 'mkdir')
    if not isinstance(value['apiCoverage'], list) or len(value['apiCoverage']) > 6:
        raise ValueError('invalidCoverage')
    for index, row in enumerate(value['apiCoverage']):
        _keys(row, 'api state')
        if row['api'] != apis[index] or row['state'] not in ('installed', 'missing', 'installing'):
            raise ValueError('invalidCoverage')
    query = value['queryCoverage']
    if query not in ('notApplicable', 'classMissing', 'methodMissing', 'ABIRejected', 'installed', 'installationFailed', 'unsupportedIdentity') or bundle != 'com.baidu.netdisk' and query != 'notApplicable':
        raise ValueError('invalidQueryCoverage')
    if query=='installationFailed' and 'queryDiagnostic' not in value:raise ValueError('missingQueryDiagnostic')
    _keys(value['cleanup'], 'state failures')
    failures = value['cleanup']['failures']
    if not _count(failures, (12 if 'descriptorObservation' in value else 7)+(2 if 'yyOwnerObservation' in value else 0)) or value['cleanup']['state'] != ('failed' if failures else 'detached') or bool(failures) != (value['reason'] == 'detachFailed'):
        raise ValueError('invalidCleanup')
    complete_coverage = len(value['apiCoverage']) == 6 and all(row['state'] == 'installed' for row in value['apiCoverage']) and (bundle != 'com.baidu.netdisk' or query == 'installed')
    if value['state'] in ('observed', 'notTriggered') and not complete_coverage:
        raise ValueError('incompleteCoverage')
    for field, maximum in [('modules', 64), ('nodes', 128), ('events', 512)]:
        if not isinstance(value[field], list) or len(value[field]) > maximum:
            raise ValueError('invalidBound')
    modules = value['modules']
    for index, module in enumerate(modules, 1):
        _keys(module, 'id uuid role origin' if isinstance(module,dict) and 'origin' in module else 'id uuid role')
        if 'origin' in module:
            origin=module['origin'];_keys(origin,'location library')
            if (origin['location'] not in ('unknown','appleSystem','other') or
                    origin['library'] not in ('unknown','sqlite3','postbox','telegramUI','wcdb','mmkv','awemeCore','effectSDK') or
                    origin['library']=='sqlite3' and origin['location']!='appleSystem' or
                    origin['location']=='unknown' and origin['library']!='unknown'):
                raise ValueError('invalidModuleOrigin')
        if type(module['id']) is not int or module['id'] != index or not isinstance(module['uuid'], str) or not re.fullmatch('[0-9a-f]{32}', module['uuid']) or module['role'] not in ('app', 'other'):
            raise ValueError('invalidModule')
        if module['role'] == 'app' and module['uuid'] != expected_uuid:
            raise ValueError('wrongAppImage')
    expected_role = {'com.ss.iphone.ugc.Aweme': 'support', 'app.swiftgram.ios': 'swiftgroup'}.get(bundle, 'documents')
    for index, node in enumerate(value['nodes'], 1):
        _keys(node, 'id role labels')
        if type(node['id']) is not int or node['id'] != index or node['role'] != expected_role or not isinstance(node['labels'], list) or not 1 <= len(node['labels']) <= 4 or any(type(label) is not str or label not in LABELS for label in node['labels']):
            raise ValueError('invalidNode')
    objc = 0
    for event in value['events']:
        if not isinstance(event, dict):
            raise ValueError('invalidEvent')
        if event.get('kind') == 'referenceQuery':
            _keys(event, 'kind owner statusNil databaseNil frames result')
            objc += 1
            if bundle != 'com.baidu.netdisk' or query != 'installed' or not _count(event['owner'], 64) or event['owner'] == 0 or type(event['statusNil']) is not bool or type(event['databaseNil']) is not bool or event['result'] not in ('true', 'falseAmbiguous'):
                raise ValueError('invalidQuery')
        else:
            event_fields = 'kind node frames result'
            if 'access' in event:
                event_fields += ' access'
                access=event['access']
                _keys(access,'api access create truncate append')
                if event.get('kind')!='open' or access['api'] not in ('open','openat','fopen') or access['access'] not in ('readOnly','writeOnly','readWrite','unknown'):
                    raise ValueError('invalidOpenIntent')
                unknown_mode=access['api']=='fopen' and access['access']=='unknown'
                for flag in ('create','truncate','append'):
                    if (access[flag] is not None if unknown_mode else type(access[flag]) is not bool):
                        raise ValueError('invalidOpenIntent')
            _keys(event, event_fields)
            if event['kind'] not in ('open', 'unlink', 'rename', 'mkdir') or not _count(event['node'], len(value['nodes'])) or event['node'] == 0 or event['result'] not in ('returned', 'failed'):
                raise ValueError('invalidAccess')
        if not isinstance(event['frames'], list) or len(event['frames']) > 8:
            raise ValueError('invalidFrames')
        for frame in event['frames']:
            _keys(frame, 'module offset')
            if not _count(frame['module'], len(modules)) or frame['module'] == 0 or type(frame['offset']) is not str or not re.fullmatch(r'0x[0-9a-f]{1,16}', frame['offset']):
                raise ValueError('invalidFrame')
    _keys(value['counters'], 'matched dropped objcObserved')
    if any(not _count(value['counters'][key], 2**53-1) for key in value['counters']) or value['counters']['matched'] != len(value['events']) or value['counters']['objcObserved'] != objc:
        raise ValueError('invalidCounters')
    if 'inputCoverage' in value:
        coverage=value['inputCoverage']
        if coverage['matched']<len(value['events'])-objc or coverage['errors']>value['counters']['dropped']:
            raise ValueError('contradictoryInputCoverage')
    if value['image'] is not None:
        image = value['image']; _keys(image, 'uuid fileType dyldIndex bundlePathMatched indexZeroSame processMainSame')
        if image['uuid'] != expected_uuid or type(image['fileType']) is not int or image['fileType'] != 2 or not _count(image['dyldIndex'], 4095) or image['bundlePathMatched'] is not True or type(image['indexZeroSame']) is not bool or type(image['processMainSame']) is not bool:
            raise ValueError('invalidImage')
    elif value['state'] != 'failed':
        raise ValueError('missingImage')
    descriptor_seen=False
    if 'qqImageMethods' in value:
        _qq_methods(value['qqImageMethods'],modules,bundle,expected_uuid)
        if value['qqImageMethods']['state'] in ('partial','unsupportedIdentity') and value['state'] in ('observed','notTriggered'):raise ValueError('incompleteQQMethods')
    if 'qqImageCode' in value:
        _qq_code(value['qqImageCode'],modules,bundle,expected_uuid,value.get('qqImageMethods'))
        if value['qqImageCode']['state']!='complete' and value['state'] in ('observed','notTriggered'):raise ValueError('incompleteQQCode')
    if 'yyOwnerObservation' in value:
        _yy_owner(value['yyOwnerObservation'],modules,bundle)
        descriptor_seen=bool(value['yyOwnerObservation']['events'])
        if value['yyOwnerObservation']['state'] in ('partial','unavailable') and value['state'] in ('observed','notTriggered'):raise ValueError('incompleteYYOwnerObservation')
    if 'capabilityMetadata' in value:
        _capability(value['capabilityMetadata'],modules)
        if value['capabilityMetadata']['state']!='complete' and value['state'] in ('observed','notTriggered'):raise ValueError('incompleteCapabilityMetadata')
    if 'descriptorObservation' in value:
        descriptor=_descriptor(value['descriptorObservation'],value['nodes'],modules)
        descriptor_seen=descriptor_seen or bool(descriptor['objects'] or descriptor['events'])
        if descriptor['state']!='complete' and value['state'] in ('observed','notTriggered'):raise ValueError('incompleteDescriptorObservation')
    if (value['state'] == 'observed' and (not value['events'] and not descriptor_seen or value['counters']['dropped'] or value['reason'] != 'windowEnded') or
        value['state'] == 'notTriggered' and (value['events'] or descriptor_seen or value['counters']['dropped'] or value['reason'] != 'windowEnded') or
        value['state'] == 'failed' and value['reason'] not in ('setupRejected', 'detachFailed')):
        raise ValueError('contradictoryTerminal')
    return value
