"""指定 APP 保存诊断的离线分析；仅验证选中字段，无设备或执行器。新文件无旧版本可备份。"""
from collections import defaultdict
import hashlib
import json
import math
from pathlib import Path
import re

LIMIT=128*1024*1024
COMPONENTS=('scan','imageDiskCache','gurdCache','cleanup')
WRAPPERS={'available','missing','invalid','unavailable','readError','notObserved','unsupported','truncated'}
MEASUREMENT_STATES={'running','complete','cancelled','interrupted','timeLimit','entryLimit','depthLimit','inodeLimit','nodeLimit','readError','identityChanged','invalidMetadata','partial'}
VERSION=re.compile(r'[0-9]+(?:\.[0-9]+){0,5}(?:-[0-9]+(?:\.[0-9]+){0,3})?')


def _need(value,reason):
    if not value:raise ValueError(reason)


def _number(value):
    _need(type(value) is int and 0<=value<=2**64-1,'diagnosticCounter')
    return value


def _time(value):
    _need(type(value) in (int,float) and math.isfinite(value) and value>=0,'diagnosticTimestamp')
    return value


def _version(value):
    if value is None:return None
    _need(type(value) is str and len(value)<=64 and VERSION.fullmatch(value) is not None,'diagnosticVersion')
    return value


def _read(path):
    path=Path(path);before=path.stat();_need(before.st_size<=LIMIT,'diagnosticFileBudget')
    raw=path.read_bytes();sha=hashlib.sha256(raw).hexdigest();after=path.stat()
    _need(len(raw)<=LIMIT and (before.st_size,before.st_mtime_ns,before.st_ino)==(after.st_size,after.st_mtime_ns,after.st_ino),'diagnosticSourceChanged')
    with path.open('rb') as handle:_need(hashlib.file_digest(handle,'sha256').hexdigest()==sha,'diagnosticSourceChanged')
    def unique(pairs):
        result={}
        for key,value in pairs:
            _need(key not in result,'diagnosticDuplicateJSONKey');result[key]=value
        return result
    def invalid_constant(value):raise ValueError('diagnosticJSONConstant')
    data=json.loads(raw.decode('utf-8'),object_pairs_hook=unique,parse_constant=invalid_constant)
    _need(type(data) is dict and type(data.get('schemaVersion')) is int and data['schemaVersion']>=1,'diagnosticSchema')
    _time(data['generatedAt']);_version(data.get('environment',{}).get('pluginVersion'))
    _need(type(data['apps']) is list,'diagnosticApps')
    index={}
    for app in data['apps']:
        _need(type(app) is dict and type(app.get('bundle')) is str and app['bundle'] not in index,'diagnosticAppDuplicate')
        index[app['bundle']]=app
    return data,index,sha


def _identity(app):
    if app is None:return None
    version=_version(app.get('version'));build=_version(app.get('build'))
    return dict(version=version,build=build) if version is not None and build is not None else None


def _component(app,name,report_version):
    wrapper=app.get(name,{'state':'notObserved'}) if app else {'state':'notObserved'}
    _need(type(wrapper) is dict and type(wrapper.get('state')) is str and wrapper['state'] in WRAPPERS,'diagnosticWrapper')
    result=dict(wrapperState=wrapper['state'],updated=None,producerVersion=None,producerMatchesReport='unknown',producerInstallationMatch='unknown')
    if wrapper['state']!='available':return result,wrapper
    data=wrapper['data'];_need(type(data) is dict,'diagnosticComponent')
    if 'bundle' in data:_need(data['bundle']==app['bundle'],'diagnosticComponentBundle')
    if 'updated' in data:result['updated']=_time(data['updated'])
    producer=data.get('cleanupContext' if name=='cleanup' else 'runtimeInfo',{})
    _need(type(producer) is dict,'diagnosticProducer')
    result['producerVersion']=_version(producer.get('packageVersion'))
    if name=='cleanup' and producer.get('state')=='recorded':
        identity=_identity(app)
        produced=dict(version=_version(producer.get('appVersion')),build=_version(producer.get('appBuild')))
        if identity is not None and all(value is not None for value in produced.values()):
            result['producerInstallationMatch']='matches' if produced==identity else 'mismatch'
    if result['producerVersion'] is not None and report_version is not None:
        result['producerMatchesReport']=result['producerVersion']==report_version
    return result,wrapper


def _root(root):
    roles=root['roles'];owners=root['owners'];measurement=root['measurement']
    _need(type(roles) is list and roles and len(set(roles))==len(roles) and all(role in ('home','group','extension') for role in roles),'diagnosticRootRole')
    _need(type(owners) is list and owners and len(set(owners))==len(owners) and all(type(owner) is str for owner in owners),'diagnosticRootOwners')
    _need(type(measurement) is dict and measurement.get('state') in MEASUREMENT_STATES,'diagnosticMeasurementState')
    totals={key:_number(measurement[key]) for key in ('logicalBytes','allocatedBytes','entries')}
    if 'uniqueInodes' in measurement or 'duplicateInodes' in measurement:
        _need(_number(measurement['uniqueInodes'])+_number(measurement['duplicateInodes'])==totals['entries'],'diagnosticInodeCounts')
    nodes=measurement['nodes'];_need(type(nodes) is list and len(nodes)<=4096,'diagnosticNodes')
    by_id={};depths={};children=defaultdict(lambda:defaultdict(int));categories={}
    for node in nodes:
        _need(type(node) is dict,'diagnosticNode')
        ident=_number(node['id']);parent=_number(node['parent']);category=node['category']
        _need(ident>0 and ident not in by_id and type(category) is str,'diagnosticNodeIdentity')
        values={key:_number(node[key]) for key in totals};_need(values['entries']>0,'diagnosticNodeEntries')
        if not by_id:_need(ident==1 and parent==0 and category=='unknown' and values==totals,'diagnosticRootNode')
        else:
            _need(parent in by_id,'diagnosticNodeParent')
            for key,value in values.items():
                children[parent][key]+=value
                _need(children[parent][key]<=by_id[parent][key]-(1 if key=='entries' else 0),'diagnosticChildCounts')
        depth=0 if not parent else depths[parent]+1;_need(depth<=64,'diagnosticNodeDepth')
        if category in ('Documents','Library','tmp'):
            _need(depth==1 and parent==1,'diagnosticCategoryPosition');selected=category
        elif category in ('Caches','Application Support'):
            _need(depth==2 and by_id[parent]['category']=='Library','diagnosticCategoryPosition');selected='Library/'+category
        else:selected=None
        if selected:
            _need(selected not in categories,'diagnosticDuplicateCategory')
            categories[selected]={key:values[key] for key in ('logicalBytes','allocatedBytes')}
        by_id[ident]=dict(values,category=category);depths[ident]=depth
    if not nodes:_need(not any(totals.values()) and measurement['state']!='complete','diagnosticMissingNodes')
    errors=measurement.get('cursorErrors',{})
    if measurement['state']=='complete' and errors:
        _need(_number(errors['enumerationErrors'])==_number(errors['statErrors'])==0 and errors['errors']==[] and errors['errorsTruncated'] is False,'diagnosticCompleteErrors')
    cache=sum(categories.get(key,{}).get('logicalBytes',0) for key in ('Library/Caches','tmp')) if measurement['state']=='complete' else None
    return dict(roles=roles,ownersCount=len(owners),state=measurement['state'],logicalBytes=totals['logicalBytes'],
                allocatedBytes=totals['allocatedBytes'],categories=categories,standardCacheLogicalBytes=cache)


def _capacity(data,bundles):
    absent={bundle:dict(state='notObserved',roots=[],missingRootsCount=0,standardCacheLogicalBytes=None) for bundle in bundles}
    capacity=data.get('capacityMeasurement')
    if capacity is None:return absent
    _need(type(capacity) is dict,'diagnosticCapacity')
    if 'roots' not in capacity and capacity.get('state') in ('notMeasured','unavailable','notObserved','invalid'):
        return {bundle:dict(value,state=capacity['state']) for bundle,value in absent.items()}
    roots=capacity['roots'];entries=capacity['entries']
    _need(type(roots) is list and type(entries) is list and len(roots)<=4096,'diagnosticCapacityShape')
    by_id={};by_bundle={}
    for root in roots:
        ident=_number(root['id']);_need(ident>0 and ident not in by_id,'diagnosticRootDuplicate');by_id[ident]=root
    for entry in entries:
        bundle=entry['bundle'];_need(type(bundle) is str and bundle not in by_bundle,'diagnosticEntryDuplicate')
        ids=entry['rootIds'];_need(type(ids) is list and all(_number(ident)>0 for ident in ids) and len(set(ids))==len(ids),'diagnosticRootReferences')
        by_bundle[bundle]=entry
    if 'totalRoots' in capacity:
        _need(_number(capacity['totalRoots'])>=len(roots),'diagnosticTotalRoots')
        _need(all(ident<=capacity['totalRoots'] for entry in entries for ident in entry['rootIds']),'diagnosticRootBound')
        completed=sum(root['measurement']['state']=='complete' for root in roots)
        failed=sum(root['measurement']['state'] not in ('complete','running') for root in roots)
        _need(_number(capacity['completedRoots'])==completed and _number(capacity['failedRoots'])==failed,'diagnosticRootCounts')
    result={}
    for bundle in bundles:
        entry=by_bundle.get(bundle)
        if entry is None:result[bundle]=absent[bundle];continue
        ids=entry['rootIds'];state=entry['state']
        _need(state in ('registered','noRegisteredRoots','excluded','sourcePartial'),'diagnosticEntryState')
        _need((state not in ('noRegisteredRoots','excluded') or not ids) and (state!='registered' or ids),'diagnosticEntryRoots')
        _need({ident for ident,root in by_id.items() if bundle in root['owners']}<=set(ids),'diagnosticOwnerClosure')
        selected=[];missing=0
        for ident in ids:
            if ident not in by_id:missing+=1;continue
            root=by_id[ident];_need(bundle in root['owners'],'diagnosticOwnerClosure')
            _need(all(owner in by_bundle and ident in by_bundle[owner]['rootIds'] for owner in root['owners']),'diagnosticSharedOwnerClosure')
            selected.append(_root(root))
        complete=bool(selected) and not missing and state=='registered' and all(root['state']=='complete' for root in selected)
        result[bundle]=dict(state='complete' if complete else 'partial' if selected or missing else 'notObserved',roots=selected,missingRootsCount=missing,
            standardCacheLogicalBytes=sum(root['standardCacheLogicalBytes'] for root in selected) if complete else None)
    return result


def analyze_diagnostics(path,baseline_path=None,*,bundles):
    """固定顺序投影指定五 APP；基线比较只说明保存记录变化，不表示本轮实测。"""
    _need(type(bundles) in (list,tuple) and len(bundles)==5 and all(type(bundle) is str and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,254}',bundle) for bundle in bundles) and len(set(bundles))==5,'diagnosticSelectedBundles')
    try:
        data,index,sha=_read(path);baseline,old,baseline_sha=_read(baseline_path) if baseline_path is not None else (None,{},None)
        report_version=_version(data.get('environment',{}).get('pluginVersion'));capacity=_capacity(data,bundles);apps=[]
        for bundle in bundles:
            app=index.get(bundle);previous=old.get(bundle);identity=_identity(app);old_identity=_identity(previous)
            item=dict(bundle=bundle,capacity=capacity[bundle],components={})
            if identity is not None:item['identity']=identity
            for name in COMPONENTS:
                component,raw=_component(app,name,report_version)
                previous_component,previous_raw=_component(previous,name,_version(baseline.get('environment',{}).get('pluginVersion'))) if baseline else (None,None)
                comparable=(identity is not None and identity==old_identity and component['wrapperState']=='available' and previous_component is not None and previous_component['wrapperState']=='available' and
                            (name!='cleanup' or component['producerInstallationMatch']==previous_component['producerInstallationMatch']=='matches'))
                component['comparisonToBaseline']='noBaseline' if baseline is None else ('unchanged' if raw==previous_raw else 'changed') if comparable else 'notComparable'
                current_time=component['updated'];previous_time=previous_component['updated'] if previous_component else None
                component['timestampComparedToBaseline']='notComparable' if not comparable or current_time is None or previous_time is None else (
                    'unchanged' if current_time==previous_time else 'advanced' if current_time>previous_time else 'regressed')
                item['components'][name]=component
            apps.append(item)
        return dict(sourceSHA256=sha,baselineSHA256=baseline_sha,generatedAt=data['generatedAt'],envPluginVersion=report_version,
            scope='fiveAppSavedDiagnosticAnalysis',validationScope='selectedFields',effectVerification='notPerformed',
            observation='saved',nonAtomic=True,notRevalidatedAtExport=True,deletionAuthorized=False,apps=apps)
    except (KeyError,TypeError,AttributeError,IndexError,UnicodeError) as error:
        raise ValueError('diagnosticMalformedSelectedFields') from error
