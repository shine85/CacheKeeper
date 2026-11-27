"""Read-only fixed-field normalization for saved multi-stage CacheKeeper reports."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import sys

MAX_BYTES=128*1024*1024
BUNDLE=re.compile(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,254}')
SHA=re.compile(r'[0-9a-f]{64}')
TARGETS=(('抖音','com.ss.iphone.ugc.Aweme'),('QQ','com.tencent.mqq'),('百度网盘','com.baidu.netdisk'),('京东','com.360buy.jdmobile'),('Swiftgram','app.swiftgram.ios'))
STAGES={'baseline','normal','prevent','clean','disabled','after'}
REASONS={'none','appDisabled','unsupportedSDK','scopeUnproven','timeLimit','entryLimit','depthLimit','inodeLimit','readError','identityChanged','invalidMetadata','partial','cancelled','interrupted','timeout','notObserved','unknown'}


def _need(ok,code):
    if not ok: raise ValueError(code)


def _read(path):
    path=Path(path); before=path.stat(); _need(before.st_size<=MAX_BYTES,'phaseSourceSize')
    raw=path.read_bytes(); _need(len(raw)<=MAX_BYTES,'phaseSourceSize')
    def unique(pairs):
        out={}
        for key,value in pairs:
            _need(key not in out,'phaseDuplicateJSONKey'); out[key]=value
        return out
    def invalid(value): raise ValueError('phaseJSONConstant')
    data=json.loads(raw.decode('utf-8'),object_pairs_hook=unique,parse_constant=invalid)
    after=path.stat(); _need((before.st_size,before.st_mtime_ns,before.st_ino)==(after.st_size,after.st_mtime_ns,after.st_ino),'phaseSourceChanged')
    digest=hashlib.sha256(raw).hexdigest()
    with path.open('rb') as handle: _need(hashlib.file_digest(handle,'sha256').hexdigest()==digest,'phaseSourceChanged')
    _need(type(data) is dict and type(data.get('apps')) is list,'phaseReportShape')
    _need(type(data.get('generatedAt')) in (int,float) and math.isfinite(data['generatedAt']),'phaseGeneratedAt')
    collection=data.get('collection'); _need(type(collection) is dict and type(collection.get('rescanned')) is bool,'phaseCollectionState')
    apps={}
    for row in data['apps']:
        _need(type(row) is dict and type(row.get('bundle')) is str and BUNDLE.fullmatch(row['bundle']) is not None,'phaseAppShape')
        _need(row['bundle'] not in apps,'phaseDuplicateBundleInSource'); apps[row['bundle']]=row
    return data,apps,digest


def _wrapped(app,key):
    row=app.get(key,{'state':'notObserved'}) if app else {'state':'notObserved'}
    if type(row) is not dict or type(row.get('state')) is not str: return 'invalid',None
    if row['state']!='available': return row['state'],None
    return ('available',row['data']) if type(row.get('data')) is dict else ('invalid',None)


def _events(app):
    state,data=_wrapped(app,'imageDiskCache')
    if state!='available' or data is None: return dict(state='notObserved',events=[])
    history=data.get('operationHistory')
    if type(history) is not dict or type(history.get('processes')) is not list: return dict(state='notObserved',events=[])
    out=[]
    for process in history['processes']:
        if type(process) is not dict: continue
        for event in process.get('events',[]) if type(process.get('events')) is list else []:
            if type(event) is not dict: continue
            out.append(dict(eventID=event.get('eventID') if type(event.get('eventID')) is int else None,
                configurationGeneration=event.get('configurationGeneration') if type(event.get('configurationGeneration')) is int else None,
                reason=event.get('reason') if event.get('reason') in REASONS else 'unknown',
                trigger=event.get('trigger') if event.get('trigger') in ('foreground','background','imageLoad','manual') else 'unknown',
                state=event.get('state') if event.get('state') in ('finished','running','failed') else 'unknown',
                started=event.get('started') if type(event.get('started')) in (int,float) and math.isfinite(event['started']) else None))
    return dict(state='truncated' if history.get('historyTruncated') is True else 'available',events=out)


def _writer(app,stage):
    state,data=_wrapped(app,'imageDiskCache')
    if state!='available' or data is None: return dict(status='notObserved' if state in ('missing','notObserved','unavailable') else 'insufficientEvidence',reason=state)
    observation=data.get('writeObservation')
    if type(observation) is not dict or type(observation.get('epochs')) is not list: return dict(status='insufficientEvidence',reason='writerObservationMissing')
    if stage=='disabled':
        history=data.get('operationHistory',{}); events=[e for p in history.get('processes',[]) if type(p) is dict for e in p.get('events',[]) if type(e) is dict] if type(history) is dict else []
        return dict(status='notTriggered',reason='noPositiveNonemptyWriteAfterDisable' if any(e.get('reason')=='appDisabled' for e in events) else 'disabledEventMissing')
    target_mode='prevent' if stage=='prevent' else 'clean' if stage=='clean' else None
    candidates=[e for e in observation['epochs'] if type(e) is dict and e.get('mode') in ('prevent','clean','auto') and (target_mode is None or e.get('mode')==target_mode)]
    if not candidates: return dict(status='notObserved',reason='noMatchingModeEpoch')
    epoch=candidates[-1]; counts=epoch.get('data')
    if type(counts) is not dict: return dict(status='insufficientEvidence',reason='writerCountsMissing')
    values={key:counts.get('nonempty'+key.capitalize()) for key in ('attempts','blocked','allowed')}
    if any(type(v) is not int or v<0 for v in values.values()): return dict(status='insufficientEvidence',reason='writerCountsInvalid')
    if epoch.get('identityState')!='verified' or observation.get('truncated') is True or observation.get('droppedEpochs',0)>0 or counts.get('overflow') is True:
        return dict(status='insufficientEvidence',reason='identityUnverifiedOrTruncated',nonempty=values)
    if values['attempts']==0: return dict(status='notTriggered',reason='noNonemptyAttempts',mode=epoch.get('mode'),epoch=epoch.get('epoch'))
    if values['attempts']!=values['blocked']+values['allowed']: return dict(status='insufficientEvidence',reason='writerCountsDoNotReconcile',nonempty=values)
    return dict(status='observed',mode=epoch.get('mode'),epoch=epoch.get('epoch'),configuration=epoch.get('configuration'),installation=epoch.get('installation'),nonempty=values)


def _actions(app):
    state,data=_wrapped(app,'imageDiskCache')
    if state!='available' or data is None: return []
    history=data.get('operationHistory')
    if type(history) is not dict or type(history.get('processes')) is not list: return []
    out=[]
    for process in history['processes']:
        if type(process) is not dict: continue
        for action in process.get('actions',[]) if type(process.get('actions')) is list else []:
            if type(action) is not dict: continue
            effect=action.get('cacheEffect'); effect=effect if type(effect) is dict else {}
            def side(key):
                value=effect.get(key); value=value if type(value) is dict else {}
                return dict(state=value.get('state') if value.get('state') in ('complete','partial','failed','notMeasured') else 'notMeasured',
                    files=value.get('files') if type(value.get('files')) is int and value['files']>=0 else None,
                    logicalBytes=value.get('logicalBytes') if type(value.get('logicalBytes')) is int and value['logicalBytes']>=0 else None)
            out.append(dict(actionID=action.get('actionID') if type(action.get('actionID')) is int else None,
                eventID=action.get('eventID') if type(action.get('eventID')) is int else None,
                state=action.get('state') if action.get('state') in ('apiCompleted','failed','running') else 'unknown',
                scope=effect.get('scope') if effect.get('scope')=='sdkFlatDirectoryEntries' else 'unknown',before=side('before'),after=side('after'),
                physicalRelease=effect.get('physicalRelease') if effect.get('physicalRelease') in ('notMeasured','measured') else 'notMeasured'))
    return out


def _cleanup(app):
    state,data=_wrapped(app,'cleanup')
    if state!='available' or data is None: return dict(state=state,rounds=[])
    history=data.get('cleanupHistory'); rounds=history.get('rounds') if type(history) is dict else None
    if type(rounds) is not list: return dict(state='unavailable',rounds=[])
    out=[]
    for row in rounds:
        if type(row) is not dict: continue
        ctx=row.get('context'); ctx=ctx if type(ctx) is dict else {}; release=row.get('releaseEvidence'); release=release if type(release) is dict else {}
        out.append(dict(roundID=row.get('roundID') if type(row.get('roundID')) is str else None,
            packageVersion=ctx.get('packageVersion') if type(ctx.get('packageVersion')) is str else None,
            mode=ctx.get('mode') if ctx.get('mode') in ('auto','prevent','clean') else 'unknown',
            enabled=ctx.get('enabled') if type(ctx.get('enabled')) is bool else None,
            bytes=row.get('bytes') if type(row.get('bytes')) is int and row['bytes']>=0 else None,
            removed=row.get('removed') if type(row.get('removed')) is int and row['removed']>=0 else None,
            failed=row.get('failed') if type(row.get('failed')) is int and row['failed']>=0 else None,
            coverageComplete=row.get('coverageComplete') if type(row.get('coverageComplete')) is bool else None,
            releaseAttempts=release.get('attempts') if type(release.get('attempts')) is int else None,
            releaseSucceeded=release.get('succeeded') if type(release.get('succeeded')) is int else None,
            physicalRelease=release.get('reclaimedPhysicalBytes') if release.get('reclaimedPhysicalBytes') in ('notMeasured','measured') else 'notMeasured'))
    return dict(state='available',rounds=out)


def _gurd(app):
    state,data=_wrapped(app,'gurdCache')
    if state!='available' or data is None:return dict(state=state,operations=[])
    operations=data.get('operations')
    if type(operations) is not list:return dict(state='invalid',operations=[])
    out=[]
    for operation in operations:
        if type(operation) is not dict:continue
        proof=operation.get('scopeProof');proof=proof if type(proof) is dict else {}
        runtime=operation.get('runtimeInfo');runtime=runtime if type(runtime) is dict else {}
        out.append(dict(event=operation.get('event') if type(operation.get('event')) is int else None,
            phase=operation.get('phase') if operation.get('phase') in ('eligible','samplingBefore','submitted','samplingAfter','completed','skipped','failed','cancelled','interrupted') else 'unknown',
            reason=operation.get('reason') if operation.get('reason') in REASONS else 'unknown',
            submission=operation.get('submission') if operation.get('submission') in ('submitted','notSubmitted') else 'unknown',
            scopeState=proof.get('state') if proof.get('state') in ('complete','partial','scopeUnproven','identityChanged') else 'unknown',
            candidateCount=proof.get('candidateCount') if type(proof.get('candidateCount')) is int and proof['candidateCount']>=0 else None,
            beforeState=operation.get('before',{}).get('state') if type(operation.get('before')) is dict and operation['before'].get('state') in ('complete','partial','notObserved','notRecorded') else 'unknown',
            afterState=operation.get('after',{}).get('state') if type(operation.get('after')) is dict and operation['after'].get('state') in ('complete','partial','notObserved','notRecorded') else 'unknown',
            producerVersion=runtime.get('packageVersion') if type(runtime.get('packageVersion')) is str else None))
    return dict(state='savedObservation',operations=out)


def _host(app):
    state,data=_wrapped(app,'hostObserved')
    if state!='available' or data is None: return dict(state=state,producerVersion=None,updated=None)
    inner=data.get('data') if type(data.get('data')) is dict else {}; runtime=inner.get('runtimeInfo') if type(inner.get('runtimeInfo')) is dict else {}; updated=inner.get('updated')
    return dict(state='available',producerVersion=runtime.get('packageVersion') if type(runtime.get('packageVersion')) is str else None,
        updated=updated if type(updated) in (int,float) and math.isfinite(updated) else None)


def _outcome(stage,writer,capacity,present):
    if not present: return 'notObserved'
    if stage=='disabled': return 'insufficientEvidence'
    if stage=='prevent' and writer['status']=='observed': return 'passed' if writer['nonempty']['blocked']>0 else 'failed'
    if stage=='clean' and writer['status']=='observed': return 'passed' if writer['nonempty']['allowed']>0 else 'failed'
    return writer['status']


def analyze_phase_reports(sources,*,bundles=None):
    """sources are (stage,path[,expected_sha256]); read-only fixed-field projection."""
    targets=tuple(bundle for _,bundle in TARGETS) if bundles is None else tuple(bundles)
    _need(len(targets)==5 and len(set(targets))==5 and all(type(x) is str and BUNDLE.fullmatch(x) for x in targets),'phaseDuplicateBundle')
    _need(type(sources) in (tuple,list) and 1<=len(sources)<=16,'phaseSources')
    loaded={}
    for spec in sources:
        _need(type(spec) in (tuple,list) and len(spec) in (2,3),'phaseSourceSpec'); stage,path=spec[:2]; pin=spec[2] if len(spec)==3 else None
        _need(type(stage) is str and stage in STAGES,'phaseStage'); _need(stage not in loaded,'phaseDuplicateStage')
        data,apps,digest=_read(path)
        if pin is not None: _need(type(pin) is str and SHA.fullmatch(pin) and pin==digest,'phaseSourceSHA')
        cap=data.get('capacityMeasurement'); cap=cap if type(cap) is dict else {}
        _need(type(cap.get('state','notMeasured')) is str,'phaseCapacity')
        collection=data['collection']; loaded[stage]=dict(path=Path(path).name,sha256=digest,generatedAt=data['generatedAt'],
            observation='savedRecords' if collection.get('mode')=='savedRecords' else 'unknown',rescanned=collection['rescanned'],
            capacityState=cap.get('state','notMeasured'),freshness=cap.get('freshness','unknown'),installationMatch=cap.get('installationMatch','unknown'),apps=apps)
    result=[]
    for name,bundle in TARGETS:
        if bundle not in targets: continue
        stage_rows={}
        for stage,source in loaded.items():
            app=source['apps'].get(bundle); writer=_writer(app,stage); present=app is not None
            stage_rows[stage]=dict(outcome=_outcome(stage,writer,source['capacityState'],present),observation=source['observation'],rescanned=source['rescanned'],
                capacityState=source['capacityState'],freshness=source['freshness'],installationMatch=source['installationMatch'],writer=writer,
                events=_events(app),actions=_actions(app),cleanup=_cleanup(app),gurd=_gurd(app),hostObserved=_host(app))
        result.append(dict(name=name,bundle=bundle,stages=stage_rows))
    return dict(schemaVersion=1,scope='fixedFieldSavedPhaseNormalization',validationScope='savedReportFieldsOnly',effectVerification='notPerformed',
        executionAvailable=False,deletionAuthorized=False,sources={stage:{k:v for k,v in source.items() if k!='apps'} for stage,source in loaded.items()},apps=result)


def _parse_stage(value):
    parts=value.split('=',2); _need(len(parts) in (2,3),'phaseStageArgument'); return tuple(parts)


def main(argv=None):
    parser=argparse.ArgumentParser(description='只读归一化多个已保存阶段报告；不连接设备或执行 APP 操作。')
    parser.add_argument('--stage',action='append',required=True,metavar='NAME=JSON[=SHA256]')
    parser.add_argument('--output',type=Path,help='新 JSON 路径；已存在时拒绝覆盖。')
    args=parser.parse_args(argv)
    try:
        result=analyze_phase_reports([_parse_stage(item) for item in args.stage])
        encoded=(json.dumps(result,ensure_ascii=False,indent=2,sort_keys=True)+'\n').encode('utf-8')
        if args.output:
            with args.output.open('xb') as handle: handle.write(encoded)
            print(json.dumps(dict(state='normalized',output=str(args.output),sha256=hashlib.sha256(encoded).hexdigest()),ensure_ascii=False))
        else: sys.stdout.buffer.write(encoded)
    except (OSError,ValueError,UnicodeError) as error:
        print(json.dumps(dict(state='normalizationFailed',error=str(error)),ensure_ascii=False),file=sys.stderr); return 2
    return 0

if __name__=='__main__': raise SystemExit(main())
