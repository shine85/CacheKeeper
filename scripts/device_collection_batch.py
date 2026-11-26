"""One-session metadata collection for all current system registrations.

Uses the existing uicache/rootfs/Info.plist/Mach-O binding collector. No app is
launched or attached. Reads are limited to installation Info.plist, exact Mach-O
load commands and requested unencrypted SDK technical metadata; app data is not read.
"""
import argparse
import base64
from collections import Counter
import copy
import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import secrets
import shlex
import sys
import time
from device_collection_sources.report_io import atomic

ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/'scripts/device_collection_sources/resource_app_binding.py'
SOURCE_SHA='b9c921e2c91ef6b0e6845cc7b5b39ca8086c8381ec4d2b55531bb8b2b26290cf'
BUNDLE=re.compile(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,254}')
STATIC_STATES=('collected','failed','attemptedOutcomeUnknown','notAttemptedConnection','notAttemptedBudget')
SDK_PENDING_STATES={'notAttemptedBudget','notAttemptedConnection','notAttemptedLocalPreparationFailure',
                    'notAttemptedLocalReceiptWriteFailure','notAttemptedParentChanged'}
SDK_STATES=SDK_PENDING_STATES|{'notAttempted','notAttemptedUnspecified','notAttemptedMissingIdentity',
                              'completeWithinRequestedSDKMetadata','partial','commandFailed','attemptedOutcomeUnknown',
                              'localPreparationFailed','localReceiptWriteFailed','rejectedIncompleteOrInvalidReceipt'}
RUN_ID=re.compile(r'(?:[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}|resume-[0-9a-f]{64})')
RUNTIME_ADAPTERS={
    'com.ss.iphone.ugc.Aweme':('gurdReadiness','41.2.0','412021','ef0e0cba15dd3f35aab8c9b571693881'),
    'com.tencent.mqq':('qqResourceMetadata',None,None,None),
    'com.baidu.netdisk':('baiduResourceMetadata',None,None,None),
    'app.swiftgram.ios':('swiftgramResourceMetadata',None,None,None),
}


def collector():
    raw=SOURCE.read_bytes()
    if hashlib.sha256(raw).hexdigest()!=SOURCE_SHA:
        raise ValueError('batchCollectorSourceChanged')
    spec=importlib.util.spec_from_file_location('_batch_registered_binding',SOURCE)
    module=importlib.util.module_from_spec(spec);exec(compile(raw,str(SOURCE),'exec'),module.__dict__)
    return module


def membership_script():
    return '''set -euo pipefail
set +x; set +v; export LC_ALL=C
rows=$(timeout --kill-after=2s 20s uicache -l)
printf '%s\\n' "$rows" | awk '
  /^[A-Za-z0-9][A-Za-z0-9_.-]* : \\// {sub(/ : .*/, ""); print "CK_BATCH_MEMBER " $0; next}
  NF {bad=1}
  END {if(bad) exit 41}'
echo CK_BATCH_MEMBERS_DONE
'''


def members(output):
    lines=output.splitlines()
    if not lines or lines[-1]!='CK_BATCH_MEMBERS_DONE':raise ValueError('batchMembershipFrame')
    found=[]
    for line in lines[:-1]:
        if not line.startswith('CK_BATCH_MEMBER '):raise ValueError('batchMembershipFrame')
        bundle=line.removeprefix('CK_BATCH_MEMBER ')
        if not BUNDLE.fullmatch(bundle) or bundle in found:raise ValueError('batchMembershipBinding')
        found.append(bundle)
    if not 1<=len(found)<=2000:raise ValueError('batchMembershipBound')
    return sorted(found)


def batch_script(bindings, bundles):
    if not 1<=len(bundles)<=4 or any(not BUNDLE.fullmatch(b) for b in bundles):raise ValueError('batchTargets')
    bindings.TARGETS=tuple(bundles)
    parts=['set +x; set +v; export LC_ALL=C; set +e']
    for index,bundle in enumerate(bundles):
        # Each app runs in its own bounded subshell; one unavailable registration
        # cannot abort collection of the remaining installed apps.
        body=bindings.script((bundle,))
        # Reuse the existing static collector's 32+sizeofcmds rule, avoiding
        # unrelated executable bytes beyond the Mach-O load commands.
        anchor='  header=$(head -c 65536 "$binary" | base64 | tr -d \'\\r\\n\')'
        replacement='''  words=$(head -c 32 "$binary" | od -An -v -t u4 | tr '\\n' ' ')
  read -r magic cpu subtype kind count extent flags reserved <<< "$words"
  [[ $magic == 4277009103 && $cpu == 16777228 && $count =~ ^[0-9]+$ && $extent =~ ^[0-9]+$ && $count -le 2048 && $extent -le 65504 ]]
  header_bytes=$((32+extent))
  header=$(head -c "$header_bytes" "$binary" | base64 | tr -d '\\r\\n')'''
        if body.count(anchor)!=1:raise ValueError('batchHeaderReadAnchorChanged')
        body=body.replace(anchor,replacement)
        parts += ['printf \'CK_BATCH_APP_BEGIN '+str(index)+'\n\'',
                  'timeout --kill-after=2s 35s bash -c '+shlex.quote(body)+' 2>/dev/null',
                  'rc=$?; printf \'CK_BATCH_APP_END '+str(index)+' %s\\n\' "$rc"']
    parts.append('echo CK_BATCH_GROUP_DONE')
    return '\n'.join(parts)+'\n'


def parse_batch(bindings,bundles,output):
    bindings.TARGETS=tuple(bundles)
    lines=output.splitlines();position=0;result=[]
    for index,bundle in enumerate(bundles):
        if position>=len(lines) or lines[position]!='CK_BATCH_APP_BEGIN '+str(index):raise ValueError('batchAppBegin')
        position+=1;block=[]
        while position<len(lines) and not lines[position].startswith('CK_BATCH_APP_END '):
            block.append(lines[position]);position+=1
        if position>=len(lines):raise ValueError('batchAppEnd')
        match=re.fullmatch(r'CK_BATCH_APP_END '+str(index)+r' ([0-9]{1,3})',lines[position]);position+=1
        if not match or int(match[1])>255:raise ValueError('batchAppExit')
        code=int(match[1]);row=dict(bundle=bundle,staticState='failed',exitCode=code,runtimeState='notAttempted',
                                  appLaunched=False,attached=False,resourceContract='notEstablished',applicationDataRead=False,
                                  technicalMetadataRead=True,maximumExecutableHeaderBytes=65536)
        if code!=0:row['reason']='deadline' if code in (124,137) else 'registrationOrMetadataUnavailable'
        elif len(block)!=2 or block[-1]!='CK1792_APP_BINDINGS_DONE':row['reason']='metadataFrameRejected'
        else:
            try:identity=bindings.parse(block[0],index)
            except ValueError:row['reason']='unsupportedExecutableOrMetadata'
            else:
                row.update(staticState='collected',identity=identity)
                known=RUNTIME_ADAPTERS.get(bundle)
                if known:
                    row['runtimeAdapter']=known[0]
                    exact=known[1:] == (identity['version'],identity['build'],identity['uuid'])
                    row['runtimeState']='pendingForegroundAndAuthorization' if exact else 'pendingAdapterIdentityReview'
                else:row['runtimeState']='noVerifiedPrivateAdapter'
        result.append(row)
    if lines[position:]!=['CK_BATCH_GROUP_DONE']:raise ValueError('batchGroupEnd')
    return result


def historical_index():
    path=ROOT/'packages/device-audit-2026-11-15-complete/technical-index.json'
    if not path.exists():return {},None
    data=json.loads(path.read_text(encoding='utf-8'))
    rows=data.get('apps')
    if type(rows) is not list or len(rows)>2000:raise ValueError('batchHistoricalIndex')
    return {row['bundle']:row for row in rows},hashlib.sha256(path.read_bytes()).hexdigest()


def classify_historical(row,baseline):
    if row['staticState']!='collected':return dict(state='notComparable',reused=False)
    previous=baseline.get(row['bundle']);identity=row['identity']
    if previous is None:return dict(state='newRegistration',reused=False)
    version=previous.get('version',{});build=previous.get('build',{})
    match=(version.get('status')=='available' and build.get('status')=='available' and
           version.get('value')==identity['version'] and build.get('value')==identity['build'] and
           previous.get('primaryUUIDs')==[identity['uuid']])
    # Same primary UUID alone cannot validate embedded framework replacement.
    return dict(state='primaryIdentityMatches' if match else 'identityChanged',reused=False,
                requiredChecks=['embeddedImageIdentity','containerAssociation','resourceSchema'])


def write_sdk_receipt(directory,receipt):
    """Keep original byte ranges and their hashes; JSON points to local objects."""
    directory=Path(directory);directory.mkdir(parents=True,exist_ok=False)
    receipt=copy.deepcopy(receipt)
    for image in receipt.get('images',[]):
        for part in image.get('ranges',[]):
            data=part.pop('data',None)
            if data is None:continue
            if type(data) is not bytes or len(data)!=part['length'] or hashlib.sha256(data).hexdigest()!=part['sha256']:
                raise ValueError('batchSDKRetainedBytes')
            name=part['sha256']+'.bin';path=directory/name
            if not path.exists():
                with path.open('xb') as handle:handle.write(data)
            part['file']=name
    atomic(directory/'receipt.json',receipt)
    return directory/'receipt.json'


def save_report(report,path):
    report['summary']={state:sum(row['staticState']==state for row in report['apps']) for state in STATIC_STATES}
    if report['sdkCollectionRequested']:
        for row in report['apps']:
            row.setdefault('sdkEvidence',dict(state='notAttempted' if row['staticState']=='collected' else 'notAttemptedMissingIdentity'))
        report['sdkSummary']=dict(Counter(row['sdkEvidence']['state'] for row in report['apps']))
        if report.get('mode')=='sdkResume':
            report['sdkSummaryBySource']={source:dict(Counter(row['sdkEvidence']['state'] for row in report['apps']
                                           if row['sdkEvidence'].get('evidenceSource')==source))
                                         for source in ('historical','fresh')}
    report['foregroundQueue']=[dict(bundle=row['bundle'],adapter=row.get('runtimeAdapter'),state=row['runtimeState'])
                              for row in report['apps'] if row['runtimeState'].startswith('pending')]
    atomic(path,report)


def mark_sdk_pending(report,state):
    # 只更新待尝试项；缺主身份、已失败和已保存的成功回执保持原状态。
    for row in report['apps']:
        if row.get('sdkEvidence',{}).get('state')=='notAttempted':row['sdkEvidence']=dict(state=state)


def collect_sdk(tasks,report,output,deadline,clock,save,*,parent_unchanged=None):
    import device_sdk_incremental as sdk
    report['state']='collectingSDKMetadata';save()
    for index,row in enumerate(report['apps']):
        if row['staticState']!='collected' or row['sdkEvidence']['state']!='notAttempted':continue
        if parent_unchanged is not None and not parent_unchanged():
            mark_sdk_pending(report,'notAttemptedParentChanged');report['state']='parentChanged';save();return False
        if deadline-clock()<155:
            mark_sdk_pending(report,'notAttemptedBudget');report['budgetExhausted']=True
            save();break
        try:plan=sdk.prepare(row['identity'],raw_limit=2*1024*1024,seconds=120)
        except (OSError,RuntimeError,ValueError) as error:
            row['sdkEvidence']=dict(state='localPreparationFailed',errorType=type(error).__name__)
            mark_sdk_pending(report,'notAttemptedLocalPreparationFailure')
            report['state']='localPreparationFailed';save();return False
        try:reply=tasks.task(plan['script'],125,until=min(deadline-30,clock()+125))
        except (OSError,RuntimeError,ValueError) as error:
            if isinstance(error,RuntimeError) and str(error)=='persistentTaskFailed':
                row['sdkEvidence']=dict(state='commandFailed',reason='deviceCollectorExitedNonzero',evidenceSource='fresh')
                save();continue
            row['sdkEvidence']=dict(state='attemptedOutcomeUnknown',errorType=type(error).__name__,evidenceSource='fresh')
            mark_sdk_pending(report,'notAttemptedConnection')
            report['state']='interrupted';save();return False
        try:result=sdk.parse(plan,reply)
        except ValueError:
            row['sdkEvidence']=dict(state='rejectedIncompleteOrInvalidReceipt',evidenceSource='fresh');save();continue
        try:receipt_path=write_sdk_receipt(output/('sdk-'+str(index)),result.pop('receipt'))
        except (OSError,RuntimeError,ValueError) as error:
            row['sdkEvidence']=dict(state='localReceiptWriteFailed',errorType=type(error).__name__,evidenceSource='fresh')
            mark_sdk_pending(report,'notAttemptedLocalReceiptWriteFailure')
            report['state']='localReceiptWriteFailed';save();return False
        row['sdkEvidence']=dict(result,receipt=receipt_path.relative_to(output).as_posix(),evidenceSource='fresh')
        save()
    if parent_unchanged is not None and not parent_unchanged():
        mark_sdk_pending(report,'notAttemptedParentChanged');report['state']='parentChanged';save();return False
    return True


def load_resume_parent(path):
    """只读取闭合 JSON；不读取回执对象、不加载传输、不追溯父链。"""
    import device_sdk_incremental as sdk
    path=Path(path).absolute()
    if path.name!='collection.json' or path.is_symlink() or path.parent.is_symlink():raise ValueError('resumeParentPath')
    raw=path.read_bytes()
    if len(raw)>16*1024*1024:raise ValueError('resumeParentSize')
    def unique_object(pairs):
        result={}
        for key,value in pairs:
            if key in result:raise ValueError('resumeParentDuplicateKey')
            result[key]=value
        return result
    report=json.loads(raw.decode('utf-8'),object_pairs_hook=unique_object)
    if (type(report) is not dict or report.get('schemaVersion')!=1 or
            type(report.get('runID')) is not str or not RUN_ID.fullmatch(report['runID']) or path.parent.name!=report['runID'] or
            type(report.get('state')) is not str or report['state'] not in {'partial','interrupted','localPreparationFailed','localReceiptWriteFailed',
                                       'metadataComplete','declaredStaticScopeComplete','parentChanged','sdkResumeComplete'} or
            report.get('scope')!='allCurrentRegisteredApplicationMetadata' or report.get('sdkCollectionRequested') is not True or
            any(report.get(key) is not False for key in ('runtimeExecuted','appLaunchExecuted','resourceDeletionExecuted'))):
        raise ValueError('resumeParentReport')
    rows=report.get('apps');count=report.get('membershipCount')
    if type(rows) is not list or type(count) is not int or not 1<=count<=2000 or len(rows)!=count:raise ValueError('resumeParentMembership')
    seen=set()
    for row in rows:
        if (type(row) is not dict or type(row.get('bundle')) is not str or not BUNDLE.fullmatch(row['bundle']) or
                row['bundle'] in seen or row.get('staticState') not in STATIC_STATES or type(row.get('runtimeState')) is not str):
            raise ValueError('resumeParentApp')
        seen.add(row['bundle'])
        if row['staticState']=='collected':
            identity=sdk._identity(row.get('identity'))
            if identity['bundle']!=row['bundle']:raise ValueError('resumeParentIdentity')
        if 'sdkEvidence' not in row:continue
        evidence=row['sdkEvidence']
        if type(evidence) is not dict or type(evidence.get('state')) is not str or evidence['state'] not in SDK_STATES:raise ValueError('resumeParentSDKState')
        if 'evidenceSource' in evidence and evidence['evidenceSource'] not in ('fresh','historical'):raise ValueError('resumeEvidenceSource')
        references=sum(key in evidence for key in ('receipt','historicalReceipt'))
        if references!=(1 if evidence['state'] in ('completeWithinRequestedSDKMetadata','partial') else 0):raise ValueError('resumeReceiptState')
        for key in ('receipt','historicalReceipt'):
            if key not in evidence:continue
            value=evidence[key]
            if key=='historicalReceipt':
                if (type(value) is not dict or set(value)!={'runID','sha256','path'} or
                        type(value['runID']) is not str or not RUN_ID.fullmatch(value['runID']) or
                        type(value['sha256']) is not str or not re.fullmatch('[0-9a-f]{64}',value['sha256'])):
                    raise ValueError('resumeHistoricalReceipt')
                value=value['path']
            if type(value) is not str or not re.fullmatch(r'sdk-[0-9]{1,4}/receipt\.json',value):raise ValueError('resumeReceiptPath')
    expected={state:sum(row['staticState']==state for row in rows) for state in STATIC_STATES}
    if report.get('summary')!=expected:raise ValueError('resumePrimarySummary')
    if 'parent' in report:
        parent=report['parent']
        if (type(parent) is not dict or set(parent)!={'path','sha256'} or type(parent['sha256']) is not str or
                not re.fullmatch('[0-9a-f]{64}',parent['sha256']) or type(parent['path']) is not str or
                not re.fullmatch(r'\.\./(?:[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}|resume-[0-9a-f]{64})/collection\.json',parent['path'])):
            raise ValueError('resumeParentReference')
    if 'sdkSummary' in report and report['sdkSummary']!=dict(Counter(row.get('sdkEvidence',{}).get('state') for row in rows)):
        raise ValueError('resumeSDKSummary')
    return path,report,hashlib.sha256(raw).hexdigest()


def resume(tasks,parent_path,*,seconds=1800,clock=time.monotonic):
    if type(seconds) is not int or not 60<=seconds<=3600:raise ValueError('batchTotalBudget')
    parent_path,parent,parent_sha=load_resume_parent(parent_path)
    def unchanged():
        try:return hashlib.sha256(parent_path.read_bytes()).hexdigest()==parent_sha
        except OSError:return False
    report=copy.deepcopy(parent)
    for row in report['apps']:
        evidence=row.setdefault('sdkEvidence',dict(state='notAttemptedUnspecified'))
        evidence['evidenceSource']='historical'
        if 'receipt' in evidence:
            evidence['historicalReceipt']=dict(runID=parent['runID'],sha256=parent_sha,path=evidence.pop('receipt'))
        if row['staticState']!='collected':evidence['state']='notAttemptedMissingIdentity'
        elif evidence['state'] in SDK_PENDING_STATES:row['sdkEvidence']=dict(state='notAttempted')
        elif evidence['state']=='notAttempted':evidence['state']='notAttemptedUnspecified'
    if not any(row['sdkEvidence']['state']=='notAttempted' for row in report['apps']):raise ValueError('resumeNoPendingSDK')
    if not unchanged():raise ValueError('resumeParentChanged')
    run_id='resume-'+parent_sha;output=parent_path.parent.parent/run_id;output.mkdir(exist_ok=False)
    report.update(runID=run_id,mode='sdkResume',parent=dict(path='../'+parent['runID']+'/collection.json',sha256=parent_sha),
                  primaryIdentitySource='parentReport',
                  session=tasks.session,state='collectingSDKMetadata',controllerWaitBudgetSeconds=seconds,
                  membershipChanged='unverified',registrationMembershipStable='unverified')
    for key in ('budgetExhausted','transportFailureType','addedDuringRun','removedDuringRun'):report.pop(key,None)
    path=output/'collection.json';save=lambda:save_report(report,path)
    if collect_sdk(tasks,report,output,clock()+seconds,clock,save,parent_unchanged=unchanged):
        complete=all(row['staticState']=='collected' and row['sdkEvidence']['state']=='completeWithinRequestedSDKMetadata' for row in report['apps'])
        report['state']='sdkResumeComplete' if complete else 'partial';save()
    return report,path


def collect(tasks,output_directory,*,seconds=1800,clock=time.monotonic,include_sdk=False):
    if type(seconds) is not int or not 60<=seconds<=3600:raise ValueError('batchTotalBudget')
    deadline=clock()+seconds
    bindings=collector()
    baseline,baseline_sha=historical_index()
    run_id=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+secrets.token_hex(4)
    output=Path(output_directory)/run_id;output.mkdir(parents=True,exist_ok=False)
    report=dict(schemaVersion=1,runID=run_id,scope='allCurrentRegisteredApplicationMetadata',session=tasks.session,
                state='enumerating',membershipCount=None,membershipChanged='unverified',registrationMembershipStable='unverified',apps=[],
                controllerWaitBudgetSeconds=seconds,remoteQueueDeadlineEnforced=False,historicalTechnicalIndexSHA256=baseline_sha,
                runtimeExecuted=False,appLaunchExecuted=False,resourceDeletionExecuted=False,sdkCollectionRequested=include_sdk,
                remainingCapabilities=['privateClassAndABI','resourceContract','actualSpaceEffect','dataPreservation'])
    path=output/'collection.json'
    save=lambda:save_report(report,path)
    save()
    try:current=members(tasks.task(membership_script(),25,until=min(deadline,clock()+25)))
    except (OSError,RuntimeError,ValueError) as error:
        report['state']='enumerationFailed';report['transportFailureType']=type(error).__name__
        save();return report,path
    report.update(state='collecting',membershipCount=len(current));save()
    for offset in range(0,len(current),4):
        if deadline-clock()<180:
            report['state']='partial';report['budgetExhausted']=True
            report['apps'].extend(dict(bundle=b,staticState='notAttemptedBudget',runtimeState='notAttempted') for b in current[offset:])
            if include_sdk:mark_sdk_pending(report,'notAttemptedBudget')
            save();return report,path
        group=current[offset:offset+4]
        try:reply=tasks.task(batch_script(bindings,group),150,until=min(deadline-30,clock()+150))
        except (OSError,RuntimeError,ValueError) as error:
            report['state']='interrupted';report['transportFailureType']=type(error).__name__
            report['apps'].extend(dict(bundle=b,staticState='attemptedOutcomeUnknown',runtimeState='notAttempted') for b in group)
            report['apps'].extend(dict(bundle=b,staticState='notAttemptedConnection',runtimeState='notAttempted') for b in current[offset+len(group):])
            if include_sdk:mark_sdk_pending(report,'notAttemptedConnection')
            save();return report,path
        try:rows=parse_batch(bindings,group,reply)
        except ValueError:
            rows=[dict(bundle=b,staticState='failed',reason='batchProtocolRejected',runtimeState='notAttempted') for b in group]
        for row in rows:row['historicalEvidence']=classify_historical(row,baseline)
        report['apps'].extend(rows);save()
    if include_sdk:
        if not collect_sdk(tasks,report,output,deadline,clock,save):return report,path
    try:after=members(tasks.task(membership_script(),25,until=min(deadline,clock()+25)))
    except (OSError,RuntimeError,ValueError):
        report['membershipChanged']='unverified';report['state']='partial'
    else:
        report['membershipChanged']=after!=current
        report['registrationMembershipStable']=after==current
        report['addedDuringRun']=sorted(set(after)-set(current));report['removedDuringRun']=sorted(set(current)-set(after))
        complete=(after==current and all(row['staticState']=='collected' for row in report['apps']))
        if include_sdk:complete=complete and all(row.get('sdkEvidence',{}).get('state')=='completeWithinRequestedSDKMetadata' for row in report['apps'])
        report['state']='declaredStaticScopeComplete' if complete and include_sdk else 'metadataComplete' if complete else 'partial'
    save();return report,path


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--session',required=True)
    parser.add_argument('--transport-adapter',type=Path,help='Existing authenticated queue adapter; never starts SSH.')
    args=parser.parse_args()
    from device_collection_transport import QueueTasks,load_transport
    report,path=collect(QueueTasks(load_transport(args.transport_adapter),args.session),ROOT/'packages/采集报告/批次采集')
    print(json.dumps(dict(state=report['state'],apps=len(report['apps']),output=str(path)),ensure_ascii=False))
    return 0 if report['state']=='metadataComplete' else 2


if __name__=='__main__':raise SystemExit(main())
