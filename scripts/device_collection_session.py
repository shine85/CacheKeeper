"""五 APP 离线准备报告包；只读本地证据与哈希对象，无设备执行能力。新文件无旧版本可备份。"""
import base64
import hashlib
import io
import json
from pathlib import Path
import re
import zipfile

from device_collection_batch import load_resume_parent
from device_collection_sources.sdk_receipt import SDKS


APPS=(('抖音','com.ss.iphone.ugc.Aweme',('活 owner','初始化与加载终态','真实候选与保留谓词','全部 writer 一致性边界')),
      ('QQ','com.tencent.mqq',('owner 与 consumer','资源范围','聊天与上传保留','同步和异步 writer','完成、取消与恢复')),
      ('百度网盘','com.baidu.netdisk',('实际大占用 owner 与策略','下载与未同步数据保留','失败结果与恢复来源','索引文件一致性')),
      ('京东','com.360buy.jdmobile',('owner、路径与队列','普通与永久资源用途','writer 覆盖','callback 边界','关闭后恢复')),
      ('Swiftgram','app.swiftgram.ios',('Account、MediaBox 与 StorageBox 关系','合法队列与桥接','草稿、上传、离线与唯一副本保留','逐项删除与索引一致性')))
README='''# 五 APP 离线准备报告包

本包只汇总已保存静态与诊断证据，不是手机采集工具。历史身份不表示手机当前实时状态。
手机执行器不可用；本包不包含服务器、设备命令、附加脚本或二进制对象，也不要求逐 APP 操作。
运行时取证和效果验证均未执行。静态范围完成不等于缓存适配完成、删除授权或真实空间效果。
session.json 中的 missingRequirements 是尚待证明的条件，不是已经验证的行为。
capabilityGate 逐 APP 输出 ready/blockedByCapability；缺少私有资源执行器会阻断整批就绪。可选 phaseReports 将已保存的 prevent/clean/disabled 阶段归一化进本包，不会重扫或执行 APP。
manifest.json 记录本包其余两个固定成员的字节长度与 SHA256。
'''


def _need(value,message):
    if not value:raise ValueError(message)


def _safe_path(path):
    path=Path(path).absolute()
    for item in (path,*path.parents):
        _need(not item.is_symlink() and not (hasattr(item,'is_junction') and item.is_junction()),'sessionEvidenceLink')
    return path.resolve(strict=True)


def _file(parent,name,pattern):
    _need(type(name) is str and re.fullmatch(pattern,name) is not None,'sessionEvidencePath')
    path=_safe_path(parent/name)
    _need(path.is_file() and path.is_relative_to(parent.resolve()),'sessionEvidencePath')
    return path


def _json(path):
    _need(path.stat().st_size<=16*1024*1024,'sessionJSONBudget')
    raw=path.read_bytes()
    def unique(pairs):
        result={}
        for key,value in pairs:
            _need(key not in result,'sessionDuplicateJSONKey');result[key]=value
        return result
    def invalid_constant(value):raise ValueError('sessionJSONConstant')
    result=json.loads(raw.decode('utf-8'),object_pairs_hook=unique,parse_constant=invalid_constant)
    _need(type(result) is dict,'sessionJSONObject')
    return result,hashlib.sha256(raw).hexdigest()


def _chain(report_path):
    path=_safe_path(report_path);root=path.parent.parent;chain={};observed={}
    while True:
        _need(len(chain)<32,'sessionReportChainBudget')
        path,report,sha=load_resume_parent(path)
        _need(report['runID'] not in chain,'sessionReportChainCycle')
        _need(_json(path)[1]==sha,'sessionReportChanged')
        chain[report['runID']]=(path,report,sha);observed[path]=sha
        parent=report.get('parent')
        if not parent:break
        parent_run=parent['path'].split('/')[1]
        path=_file(root,parent_run+'/collection.json',r'(?:[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}|resume-[0-9a-f]{64})/collection\.json')
        _need(hashlib.sha256(path.read_bytes()).hexdigest()==parent['sha256'],'sessionParentSHA')
    return chain,observed


def _identity(row):
    return {key:row['identity'][key] for key in ('bundle','version','build','uuid')}


def _source(chain,current,row):
    evidence=row['sdkEvidence'];reference=evidence.get('historicalReceipt')
    if reference:
        _need(reference['runID'] in chain,'sessionHistoricalSourceOutsideChain')
        path,report,sha=chain[reference['runID']]
        _need(sha==reference['sha256'],'sessionHistoricalSHA')
        source=next((item for item in report['apps'] if item['bundle']==row['bundle']),None)
        _need(source is not None and source['staticState']=='collected' and _identity(source)==_identity(row),'sessionHistoricalIdentity')
        old=source['sdkEvidence']
        _need(old.get('receipt')==reference['path'] and 'historicalReceipt' not in old,'sessionHistoricalReceiptBinding')
        ignored={'receipt','historicalReceipt','evidenceSource'}
        _need({k:v for k,v in old.items() if k not in ignored}=={k:v for k,v in evidence.items() if k not in ignored},'sessionHistoricalEvidenceChanged')
        return path.parent,old,sha
    path,_,sha=current
    _need(evidence.get('evidenceSource')!='historical' and 'receipt' in evidence,'sessionReceiptSource')
    return path.parent,evidence,sha


def _receipt(directory,evidence,identity,observed):
    path=_file(directory,evidence['receipt'],r'sdk-[0-9]{1,4}/receipt\.json');receipt,sha=_json(path);observed[path]=sha
    _need(receipt.get('kind')=='cachekeeper.staticGapReceipt' and receipt.get('transport')=='completeAndByteVerified' and
          receipt.get('membership')=='singleRequestedRegistration' and receipt.get('staticAllComplete') is False,'sessionReceiptScope')
    apps=receipt['apps'];_need(type(apps) is list and len(apps)==1 and apps[0]['bundle']==identity['bundle'],'sessionReceiptApp')
    app=apps[0];verification=app['verification']
    _need(verification.get('runtimeObserved') is False and verification.get('safeResourceContractEstablished') is False and 'alog' not in app,'sessionRuntimeScope')
    _need(all(record[0]!='CONTAINER' and not record[0].startswith('ALOG_') for record in app['records']),'sessionDataScope')
    coverage=receipt['coverage']
    _need(len(coverage)==1 and coverage[0]['bundle']==identity['bundle'] and coverage[0]['deletionAuthorizedByThisBatch'] is False and
          coverage[0]['runtimeStatus']=='notObserved','sessionDeletionScope')
    binding=evidence['identityBinding'];_need(binding['expected']==identity,'sessionExpectedIdentity')
    checks=evidence['sdkChecks'];_need(type(checks) is list and [item['sdk'] for item in checks]==SDKS,'sessionSDKScope')
    images=receipt['images'];_need(type(images) is list and len(images)<=20,'sessionImageBudget')
    names=[image['sdk'] for image in images]
    _need(len(set(names))==len(names) and all(name in SDKS+['PRIMARY'] for name in names),'sessionImageScope')
    primary=next((image for image in images if image['sdk']=='PRIMARY'),None)
    versions=[record for record in app['records'] if record[0]=='APP_VERSION']
    _need(len(versions)<=1 and all(len(record)==5 for record in versions),'sessionVersionRecord')
    observed_identity={}
    if versions and versions[0][1]==versions[0][3]=='0':
        observed_identity={key:base64.b64decode(versions[0][position],validate=True).decode('utf-8') for key,position in (('version',2),('build',4))}
    if primary:observed_identity['uuid']=primary['verification'].get('uuid')
    _need(binding['observed']==observed_identity,'sessionObservedIdentity')
    matched=(app['state']=='identityStable' and primary is not None and
             primary['verification']['status']=='completeWithinDeclaredStaticScope' and all(observed_identity.get(key)==identity[key] for key in ('version','build','uuid')))
    _need(binding['state']==('matched' if matched else 'unverifiedOrChanged'),'sessionIdentityBinding')
    presence={}
    for record in app['records']:
        if record[0]!='FRAMEWORK_CHECK':continue
        _need(len(record)==3 and record[1] in SDKS and record[1] not in presence and
              record[2] in ('present','absent','symlink','inaccessible'),'sessionFrameworkRecord')
        presence[record[1]]=record[2]
    sdk=[]
    for check in checks:
        _need(check['presence'] in ('present','absent','symlink','inaccessible','notObserved') and
              check['state'] in ('absent','unavailable','partial','completeWithinDeclaredStaticScope') and check['runtimeABIValidated'] is False,'sessionSDKState')
        _need(check['presence']==presence.get(check['sdk'],'notObserved'),'sessionSDKPresenceRecord')
        image=next((item for item in images if item['sdk']==check['sdk']),None)
        _need((image is not None)==(check['presence']=='present'),'sessionSDKPresence')
        expected='absent' if check['presence']=='absent' else image['verification']['status'] if image else 'unavailable'
        _need(check['state']==expected,'sessionSDKVerification')
        sdk.append(dict(name=check['sdk'],presence=check['presence'],state=check['state']))
    complete=matched and all(check['state'] in ('absent','completeWithinDeclaredStaticScope') for check in checks)
    _need(evidence['state']==('completeWithinRequestedSDKMetadata' if complete else 'partial'),'sessionSDKCompletion')
    ranges=total=0
    for image in images:
        _need(image['app']==identity['bundle'] and image['verification'].get('runtimeABIValidated',False) is False,'sessionImageIdentity')
        for part in image['ranges']:
            _need(type(part['length']) is int and 0<part['length']<=1024*1024 and 'data' not in part,'sessionRangeBudget')
            _need(image['sdk']!='PRIMARY' or part['kind']=='header','sessionPrimaryScope')
            target=_file(path.parent,part['file'],r'[0-9a-f]{64}\.bin')
            _need(target.name==part['sha256']+'.bin' and target.stat().st_size==part['length'],'sessionRangeLength')
            with target.open('rb') as handle:digest=hashlib.file_digest(handle,'sha256').hexdigest()
            _need(digest==part['sha256'],'sessionRangeSHA');observed[target]=digest
            total+=part['length'];ranges+=1;_need(total<=2*1024*1024 and ranges<=4096,'sessionReceiptBudget')
    _need(total==receipt['rawBytes']==evidence['rawBytes'],'sessionRawBytes')
    return dict(receiptSHA256=sha,verifiedObjectRanges=ranges,verifiedBytes=total,identityBinding=binding['state'],checks=sdk)


def _phase_specs(values):
    result=[]
    for value in values:
        parts=value.split('=',2)
        _need(len(parts) in (2,3),'sessionPhaseArgument')
        result.append(tuple(parts))
    return result


def _capability_gate(apps):
    rows=[]
    for app in apps:
        # Current product exposes only static metadata and unauthenticated host self-report.
        # Neither is a private resource-operation executor for these apps.
        blocked=[dict(requirement=item,state='blockedByCapability') for item in app['missingRequirements']]
        ready=not blocked
        rows.append(dict(bundle=app['bundle'],overall='ready' if ready else 'blockedByCapability',
                         availableEvidence=['savedStaticMetadata','hostSelfReportWhenPresent'],
                         blockedCapabilities=blocked,executionAvailable=ready))
    execution_available=all(row['executionAvailable'] for row in rows)
    return dict(state='ready' if execution_available else 'blocked',executionAvailable=execution_available,apps=rows)


def prepare_session(report_path,output_path,*,diagnostics_path=None,baseline_path=None,phase_reports=()):
    """返回离线 ZIP 摘要。校验失败不创建输出；现有输出由 xb 拒绝覆盖。"""
    output=Path(output_path).absolute()
    if output.exists() or output.is_symlink():raise FileExistsError(output)
    if baseline_path is not None and diagnostics_path is None:raise ValueError('sessionBaselineWithoutDiagnostics')
    try:
        chain,observed=_chain(report_path);current=next(iter(chain.values()));_,report,sha=current;apps=[]
        for name,bundle,requirements in APPS:
            row=next((item for item in report['apps'] if item['bundle']==bundle),None)
            item=dict(displayName=name,bundle=bundle,identitySource='savedReport',identityState='notObservedInReport',
                      sdk=dict(state='notObservedInReport'),missingRequirements=list(requirements),effectVerification='notPerformed')
            if row is not None:
                item['identityState']=row['staticState']
                evidence=row.get('sdkEvidence',{'state':'notAttemptedUnspecified'})
                item['sdk']=dict(state=evidence['state'],sourceReportSHA256=sha,evidenceSource='savedReport')
                if row['staticState']=='collected':
                    identity=_identity(row);item['identity']={key:identity[key] for key in ('version','build','uuid')}
                    if evidence['state'] in ('completeWithinRequestedSDKMetadata','partial'):
                        directory,source,source_sha=_source(chain,current,row)
                        item['sdk'].update(_receipt(directory,source,identity,observed),sourceReportSHA256=source_sha,
                                           evidenceSource='historical' if 'historicalReceipt' in evidence else 'savedReport')
                else:item['sdk']['state']='notAttemptedMissingIdentity'
            apps.append(item)
        document=dict(schemaVersion=1,kind='cachekeeper.offlinePreparation',state='preparedOnly',scope='scopePreparedOnly',
                      executionAvailable=False,effectVerification='notPerformed',runtimeExecuted=False,appLaunchExecuted=False,
                      resourceDeletionExecuted=False,sourceReportSHA256=sha,apps=apps)
        document['capabilityGate']=_capability_gate(apps)
        if phase_reports:
            from device_collection_phase_report import analyze_phase_reports
            document['phaseReports']=analyze_phase_reports(_phase_specs(phase_reports))
        if diagnostics_path is not None:
            from device_collection_diagnostics import analyze_diagnostics
            document['diagnostics']=analyze_diagnostics(diagnostics_path,baseline_path,bundles=[item[1] for item in APPS])
            for item,diagnostic in zip(apps,document['diagnostics']['apps']):
                _need(item['bundle']==diagnostic['bundle'],'sessionDiagnosticBundle')
                saved=item.get('identity');diagnosed=diagnostic.get('identity')
                diagnostic['installationComparedToStaticReport']=(
                    'versionBuildMatchesOnly' if all(saved[k]==diagnosed[k] for k in ('version','build')) else 'versionBuildMismatch'
                ) if saved and diagnosed else 'notComparable'
            # 比较只绑定版本/build；综合报告没有当前SDK镜像身份，不升级为当前安装验证。
            observed[_safe_path(diagnostics_path)]=document['diagnostics']['sourceSHA256']
            if baseline_path is not None:
                observed[_safe_path(baseline_path)]=document['diagnostics']['baselineSHA256']
        encode=lambda value:(json.dumps(value,ensure_ascii=False,indent=2)+'\n').encode('utf-8')
        files={'session.json':encode(document),'README.md':README.encode('utf-8')}
        manifest=dict(schemaVersion=1,files=[dict(name=name,length=len(data),sha256=hashlib.sha256(data).hexdigest()) for name,data in files.items()])
        files['manifest.json']=encode(manifest)
        buffer=io.BytesIO()
        with zipfile.ZipFile(buffer,'w',compression=zipfile.ZIP_DEFLATED) as archive:
            for name,data in files.items():archive.writestr(name,data)
        # 完整构建后复核来源；输出仅记录已有证据，不创建另一份执行状态。
        for path,pin in observed.items():
            _safe_path(path)
            with path.open('rb') as handle:digest=hashlib.file_digest(handle,'sha256').hexdigest()
            _need(digest==pin,'sessionSourceChanged')
        payload=buffer.getvalue()
    except (KeyError,TypeError,AttributeError,IndexError,UnicodeError) as error:
        raise ValueError('sessionMalformedEvidence') from error
    with output.open('xb') as handle:handle.write(payload)
    return dict(state='offlinePreparationComplete',executionAvailable=False,apps=5,output=str(output),sha256=hashlib.sha256(payload).hexdigest())
