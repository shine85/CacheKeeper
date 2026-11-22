#include <math.h>
#import <Foundation/Foundation.h>
#import "../AxsCacheKeeperDiagnostics.h"
#import "../AxsCacheKeeperCleanupHistory.h"

static void dxcheck(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr,"FAIL: diagnostics: %s\n",message.UTF8String);exit(1); }
}
static void dxwrite(NSString *folder,NSString *file,NSDictionary *value) {
    dxcheck([value writeToFile:[folder stringByAppendingPathComponent:file] atomically:YES],@"写入诊断夹具");
}
static NSDictionary *dxapp(NSDictionary *report,NSString *bundle) {
    for (NSDictionary *app in report[@"apps"]) if ([app[@"bundle"] isEqual:bundle]) return app;
    return nil;
}
static NSDictionary *dxfiles(NSString *folder) {
    NSMutableDictionary *files=[NSMutableDictionary new];
    for (NSString *path in [NSFileManager.defaultManager subpathsAtPath:folder]) {
        NSString *full=[folder stringByAppendingPathComponent:path];
        NSDictionary *attributes=[NSFileManager.defaultManager attributesOfItemAtPath:full error:nil];
        if ([attributes[NSFileType] isEqual:NSFileTypeRegular])
            files[path]=@[[NSData dataWithContentsOfFile:full],attributes[NSFileModificationDate]];
    }
    return files;
}
static void dxruntime_receipts(Class cls,NSString *fixture) {
    NSString *folder=[fixture stringByAppendingPathComponent:@"diagnostics-runtime-receipts"];
    dxcheck([NSFileManager.defaultManager createDirectoryAtPath:[folder stringByAppendingPathComponent:@"Status"] withIntermediateDirectories:YES attributes:nil error:nil],@"创建运行回执导出夹具");
    dxwrite(folder,@"appEnabled.plist",@{@"test.runtime":@YES});
    AxsCacheKeeperDiagnostics *session=[[cls alloc] initWithFolder:folder];
    NSDictionary *environment=@{@"pluginVersion":@"0.7.2-999.1"};
    NSDictionary *runtime=@{@"schemaVersion":@1,@"packageVersion":@"0.7.2-154.1",@"firstObserved":@90.25};
    NSDictionary *discovery=@{@"schemaVersion":@1,@"stage":@"method",@"classMask":@15,@"imageKind":@"main",
        @"source":@"imageUUID",@"methodIndex":@25,@"failure":@"argumentType"};
    NSDictionary *web=@{@"schemaVersion":@1,@"requested":@YES,@"timedOut":@NO,@"state":@"blocked",@"reason":@"installationUnverified",
        @"persistentStores":@1,@"nonPersistentStores":@0,@"submitted":@0,@"completed":@0,@"pending":@0,
        @"updated":[NSDate dateWithTimeIntervalSince1970:100],@"bytesState":@"notMeasured"};
    NSDictionary *image=@{@"schemaVersion":@1,@"sdk":@"SDWebImage",@"state":@"unsupported",@"reason":@"unsupportedSDK",
        @"observed":@0,@"eligible":@0,@"restricted":@0,@"writesBlocked":@0,@"queued":@0,@"submitted":@0,
        @"apiCompleted":@0,@"skipped":@0,@"pending":@0,@"updated":[NSDate dateWithTimeIntervalSince1970:120],@"bytesState":@"notMeasured"};
    NSArray *resamples=@[
        @{@"fdErrno":@0,@"pathErrno":@0,@"fdDifferenceMask":@0,@"pathDifferenceMask":@4,@"pathFDDifferenceMask":@0},
        @{@"fdErrno":@5,@"pathErrno":@0,@"pathDifferenceMask":@4},
        @{@"fdErrno":@0,@"pathErrno":@2,@"fdDifferenceMask":@0},
        @{@"fdErrno":@5,@"pathErrno":@2}];
    // Removing new fields from either production projection/export must fail these saved-file fixtures.
    // Expected values come from the literal contract, never from a projection helper.
    for (NSArray *source in @[@[@"webkit",@"webKitDiskCache",web,@100],@[@"imagecache",@"imageDiskCache",image,@120]]) {
        NSString *file=[NSString stringWithFormat:@"Status/test.runtime.%@.plist",source[0]],*exportKey=source[1];
        BOOL isImage=[exportKey isEqual:@"imageDiskCache"];
        NSMutableDictionary *record=[source[2] mutableCopy];record[@"runtimeInfo"]=runtime;
        if (isImage) record[@"discoveryCheck"]=discovery;
        for (NSDictionary *resample in resamples) {
            NSDictionary *check=@{@"state":@"failed",@"errorCode":@2,@"detail":@{@"target":@"root",@"operation":@"openIdentity",@"errno":@0,
                @"identity":@{@"schemaVersion":@1,@"comparison":@"pathToFD",@"differenceMask":@4,@"resample":resample}}};
            record[@"installationCheck"]=check;
            dxwrite(folder,file,record);
            NSDictionary *before=dxfiles(folder),*report=[session reportWithApps:@[] environment:environment];
            NSMutableDictionary *expected=[record mutableCopy];expected[@"updated"]=source[3];
            NSDictionary *exported=dxapp(report,@"test.runtime")[exportKey];
            dxcheck([exported isEqual:@{@"state":@"available",@"data":expected}],
                @"新运行回执通过真实导出保留身份差异、各补采结果和代码来源，不被面板版本覆盖");
            NSData *json=[NSJSONSerialization dataWithJSONObject:report options:0 error:nil];
            NSDictionary *decoded=json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
            dxcheck([dxapp(decoded,@"test.runtime")[exportKey] isEqual:exported],@"运行回执的固定投影完整进入最终 JSON");
            dxcheck([before isEqual:dxfiles(folder)],@"导出新增运行证据不改写已有回执或配置");
        }
        NSArray *paths=@[@[],@[@"runtimeInfo"],@[@"installationCheck"],@[@"installationCheck",@"detail"],
            @[@"installationCheck",@"detail",@"identity"],@[@"installationCheck",@"detail",@"identity",@"resample"]];
        if (isImage) paths=[paths arrayByAddingObject:@[@"discoveryCheck"]];
        for (NSArray *path in paths) {
            NSMutableDictionary *invalid=[record mutableCopy],*leaf=invalid;
            for (NSString *key in path) {
                NSMutableDictionary *child=[leaf[key] mutableCopy];leaf[key]=child;leaf=child;
            }
            leaf[@"privatePath"]=@"private-runtime-export-canary";
            dxwrite(folder,file,invalid);
            NSDictionary *report=[session reportWithApps:@[] environment:environment];
            NSData *json=[NSJSONSerialization dataWithJSONObject:report options:0 error:nil];
            NSString *text=json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : nil;
            dxcheck([dxapp(report,@"test.runtime")[exportKey] isEqual:@{@"state":@"invalid"}] && text &&
                ![text containsString:@"private-runtime-export-canary"],@"任一新增回执层级混入私密额外字段均拒绝整个来源且不泄漏 JSON");
        }
        for (NSString *key in isImage ? @[@"runtimeInfo",@"installationCheck",@"discoveryCheck"] : @[@"runtimeInfo",@"installationCheck"]) {
            NSMutableDictionary *invalid=[record mutableCopy];invalid[key]=@"private-runtime-export-canary";
            dxwrite(folder,file,invalid);
            NSDictionary *report=[session reportWithApps:@[] environment:environment];
            NSData *json=[NSJSONSerialization dataWithJSONObject:report options:0 error:nil];
            NSString *text=json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : nil;
            dxcheck([dxapp(report,@"test.runtime")[exportKey] isEqual:@{@"state":@"invalid"}] && text &&
                ![text containsString:@"private-runtime-export-canary"],@"新增证据坏容器不得静默降级为有效旧回执或泄漏原始文本");
        }
        NSDictionary *oldCheck=@{@"state":@"failed",@"errorCode":@2,@"detail":@{@"target":@"root",@"operation":@"openIdentity",@"errno":@0}};
        NSMutableDictionary *legacy=[source[2] mutableCopy];legacy[@"installationCheck"]=oldCheck;
        dxwrite(folder,file,legacy);
        NSMutableDictionary *expected=[legacy mutableCopy];expected[@"updated"]=source[3];
        dxcheck([dxapp([session reportWithApps:@[] environment:environment],@"test.runtime")[exportKey] isEqual:@{@"state":@"available",@"data":expected}],
            @"旧安装失败详情完整可读且不补造 identity、补采、构建来源或 SDK 发现");
        dxwrite(folder,file,source[2]);expected=[source[2] mutableCopy];expected[@"updated"]=source[3];
        dxcheck([dxapp([session reportWithApps:@[] environment:environment],@"test.runtime")[exportKey] isEqual:@{@"state":@"available",@"data":expected}],
            @"同一会话重读旧回执不沿用新证据，不补造安装检查、构建来源或 SDK 发现");
    }
}
static void dxinventory(Class cls,NSString *fixture) {
    NSString *folder=[fixture stringByAppendingPathComponent:@"diagnostics-install-union"];
    dxcheck([NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil],@"创建安装集合夹具");
    NSDictionary *states=@{@"test.inventory.configured":@YES,@"test.inventory.overlap":@NO,@"../invalid":@YES};
    dxwrite(folder,@"appEnabled.plist",states);
    dxwrite(folder,@"directories.plist",@{@"test.inventory.paths":@[@"Library/Caches"]});
    NSArray *apps=@[@{@"id":@"test.inventory.overlap",@"name":@"已配置"},
        @{@"id":@"test.inventory.new",@"name":@"新安装",@"version":@"2.0",@"build":@"200"},
        @{@"id":@"test.inventory.new",@"name":@"重复安装条目"},
        @{@"id":@"test.inventory.named",@"name":@42,@"version":@[],@"build":@{}}];
    AxsCacheKeeperDiagnostics *session=[[cls alloc] initWithFolder:folder];
    NSDictionary *before=dxfiles(folder);
    NSSet *beforePaths=[NSSet setWithArray:[NSFileManager.defaultManager subpathsAtPath:folder]];
    // 旧实现只遍历 init 的配置键：这里的新安装 APP 会缺席，形成针对真实报告的红灯。
    for (NSUInteger round=0;round<2;round++) {
        __block NSUInteger callbacks=0;
        NSDictionary *report=[session reportWithApps:apps environment:@{} progress:^(NSUInteger completed,NSUInteger total) {
            dxcheck(total==5 && completed==callbacks,@"安装配置并集的进度每轮固定为 0 至 5");callbacks++;
        }];
        dxcheck([[report[@"apps"] valueForKey:@"bundle"] isEqual:@[@"test.inventory.configured",@"test.inventory.named",@"test.inventory.new",@"test.inventory.overlap",@"test.inventory.paths"]],@"新安装未配置 APP 出现在去重排序的报告中，安装与配置重叠只出现一次");
        dxcheck(callbacks==6 && [report[@"collection"][@"completed"] isEqual:@5],@"重复采集不累积进度与任务");
        NSDictionary *fresh=dxapp(report,@"test.inventory.new");
        dxcheck([fresh[@"configuration"][@"enabled"] isEqual:@NO] && [fresh[@"configurationPresent"] isEqual:@NO] &&
            [fresh[@"configurationState"] isEqual:@"missing"] && [fresh[@"selectionState"] isEqual:@"missing"],@"新安装缺配置必须禁用并保留逐 APP 缺失状态");
        dxcheck([fresh[@"installedMetadataAvailable"] isEqual:@YES] && [fresh[@"installedMetadataState"] isEqual:@"available"] &&
            [fresh[@"name"] isEqual:@"新安装"] && [fresh[@"version"] isEqual:@"2.0"] && [fresh[@"build"] isEqual:@"200"],@"保留有效安装身份以及实际提供的名称版本构建");
        NSDictionary *unknown=dxapp(report,@"test.inventory.named");
        dxcheck(!unknown[@"name"] && !unknown[@"version"] && !unknown[@"build"],@"未知或坏类型安装字段不伪造值");
        NSDictionary *retained=dxapp(report,@"test.inventory.configured");
        dxcheck([retained[@"configuration"][@"enabled"] isEqual:@YES] && [retained[@"installedMetadataAvailable"] isEqual:@NO] &&
            [retained[@"installedMetadataState"] isEqual:@"notInSnapshot"],@"不在传入快照的已有配置仍保留，只描述快照缺条目");
        dxcheck([report[@"sourceStates"][@"installedApplications"] isEqual:@"available"] &&
            [report[@"collection"][@"rescanned"] isEqual:@NO] && !report[@"collection"][@"tasks"],@"有效安装快照仅参与内存汇总，不能触发扫描队列");
        dxcheck([NSJSONSerialization dataWithJSONObject:report options:0 error:nil]!=nil,@"安装并集报告可序列化");
    }
    dxcheck([before isEqual:dxfiles(folder)] && [beforePaths isEqual:[NSSet setWithArray:[NSFileManager.defaultManager subpathsAtPath:folder]]],@"安装未配置 APP 汇总零配置或请求改写、零新文件");
    NSMutableDictionary *changed=[states mutableCopy];changed[@"test.inventory.later"]=@NO;
    dxwrite(folder,@"appEnabled.plist",changed);
    dxwrite(folder,@"directories.plist",@{@"test.inventory.paths":@[@"Library/Caches"],@"test.inventory.laterpaths":@[@"tmp"]});
    NSDictionary *refreshed=[session reportWithApps:apps environment:@{}];
    dxcheck([refreshed[@"collection"][@"total"] isEqual:@7] && dxapp(refreshed,@"test.inventory.later") && dxapp(refreshed,@"test.inventory.laterpaths"),@"同会话重采使用当前两种配置键，不沿用 init 快照");

    NSDictionary *unreadableInstallation=[session reportWithApps:@[@{@"id":@"test.inventory.new",@"installationState":@"unavailable",@"installationError":@"private-user/path"},
        @{@"id":@"test.inventory.named",@"installationState":@"private-state"}] environment:@{}];
    NSDictionary *unreadableApp=dxapp(unreadableInstallation,@"test.inventory.new");
    dxcheck([unreadableApp[@"installedMetadataState"] isEqual:@"available"] && [unreadableApp[@"installationState"] isEqual:@"unavailable"] && !unreadableApp[@"installationError"],
        @"系统列表有APP与安装文件核验失败分开，不泄露原始错误");
    dxcheck(!dxapp(unreadableInstallation,@"test.inventory.named")[@"installationState"],@"任意安装状态文本不进入导出");

    for (id unavailable in @[NSNull.null,@42,@{},@"bad snapshot"]) {
        NSDictionary *report=[session reportWithApps:unavailable==NSNull.null ? nil : unavailable environment:@{}];
        NSDictionary *configured=dxapp(report,@"test.inventory.configured");
        dxcheck([report[@"apps"] count]==5 && [report[@"sourceStates"][@"installedApplications"] isEqual:@"unavailable"] &&
            [configured[@"installedMetadataState"] isEqual:@"unavailable"] && [configured[@"installedMetadataAvailable"] isEqual:@NO],@"nil 和坏形状快照无法判定安装缺席，配置仍保留");
    }
    NSArray *invalidApps=@[@42,@"not a dictionary",NSNull.null,@{},@{@"id":@42},@{@"id":@""},@{@"id":@"../escape"},
        @{@"id":@"test.inventory.valid",@"name":@"有效条目"}];
    NSDictionary *partial=[session reportWithApps:(id)invalidApps environment:@{}];
    dxcheck([[partial[@"apps"] valueForKey:@"bundle"] isEqual:@[@"test.inventory.configured",@"test.inventory.later",@"test.inventory.laterpaths",@"test.inventory.overlap",@"test.inventory.paths",@"test.inventory.valid"]],@"坏安装字典或 ID 被拒绝，有效条目仍纳入");
    dxcheck([dxapp(partial,@"test.inventory.valid")[@"installedMetadataState"] isEqual:@"available"] &&
        [dxapp(partial,@"test.inventory.configured")[@"installedMetadataState"] isEqual:@"unavailable"] &&
        [partial[@"sourceStates"][@"installedApplications"] isEqual:@"unavailable"],@"部分坏快照不能用于缺席结论，有效安装条目仍有元数据");
    NSDictionary *absent=[session reportWithApps:@[] environment:@{}];
    dxcheck([dxapp(absent,@"test.inventory.configured")[@"installedMetadataState"] isEqual:@"notInSnapshot"] &&
        [absent[@"sourceStates"][@"installedApplications"] isEqual:@"available"],@"有效空快照与未知安装来源分开");

    dxcheck([[@"invalid plist" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:[folder stringByAppendingPathComponent:@"appEnabled.plist"] atomically:YES],@"写入坏配置来源");
    NSDictionary *damaged=[session reportWithApps:@[@{@"id":@"test.inventory.new"}] environment:@{}];
    dxcheck([damaged[@"sourceStates"][@"configuration"] isEqual:@"invalid"] &&
        [dxapp(damaged,@"test.inventory.new")[@"configurationState"] isEqual:@"invalid"] &&
        [dxapp(damaged,@"test.inventory.new")[@"configuration"][@"enabled"] isEqual:@NO],@"坏配置来源区别于未配置，新安装仍禁用");
    dxcheck([damaged[@"apps"] count]==3 && !dxapp(damaged,@"test.inventory.configured"),@"当前配置不可读时不冒充旧 init 配置仍有效");
    NSString *missing=[fixture stringByAppendingPathComponent:@"diagnostics-installed-without-files"];
    AxsCacheKeeperDiagnostics *empty=[[cls alloc] initWithFolder:missing];
    NSDictionary *emptyReport=[empty reportWithApps:@[@{@"id":@"test.inventory.new"}] environment:@{}];
    dxcheck([emptyReport[@"apps"] count]==1 && [dxapp(emptyReport,@"test.inventory.new")[@"configurationState"] isEqual:@"missing"] &&
        [dxapp(emptyReport,@"test.inventory.new")[@"configuration"][@"enabled"] isEqual:@NO] &&
        ![NSFileManager.defaultManager fileExistsAtPath:missing],@"全无配置文件仍汇总已安装 APP，但不创建配置目录或开关");
    NSString *fixedFolder=[fixture stringByAppendingPathComponent:@"diagnostics-fixed-install-union"];
    dxcheck([NSFileManager.defaultManager createDirectoryAtPath:fixedFolder withIntermediateDirectories:YES attributes:nil error:nil],@"创建集合冻结夹具");
    dxwrite(fixedFolder,@"appEnabled.plist",@{@"test.fixed.original":@NO});
    AxsCacheKeeperDiagnostics *fixed=[[cls alloc] initWithFolder:fixedFolder];
    __block NSUInteger fixedCallbacks=0;
    NSArray *fixedApps=@[@{@"id":@"test.fixed.installed"}];
    NSDictionary *first=[fixed reportWithApps:fixedApps environment:@{} progress:^(NSUInteger completed,NSUInteger total) {
        dxcheck(total==2 && completed==fixedCallbacks,@"回调期间新增配置不能扩张本轮集合与总数");
        if (!completed) dxwrite(fixedFolder,@"appEnabled.plist",@{@"test.fixed.original":@NO,@"test.fixed.added":@YES});
        fixedCallbacks++;
    }];
    dxcheck(fixedCallbacks==3 && [first[@"apps"] count]==2 && !dxapp(first,@"test.fixed.added"),@"本轮完整使用初始配置与安装集合");
    NSDictionary *next=[fixed reportWithApps:fixedApps environment:@{}];
    dxcheck([next[@"apps"] count]==3 && [dxapp(next,@"test.fixed.added")[@"configuration"][@"enabled"] isEqual:@YES],@"回调期间保存的配置只在下一轮汇总出现");
}
void axs_cachekeeper_run_diagnostics_tests(NSString *fixture) {
    Class cls=NSClassFromString(@"AxsCacheKeeperDiagnostics");
    dxcheck(cls!=Nil,@"应提供可调用的诊断采集实现");
    dxinventory(cls,fixture);
    dxruntime_receipts(cls,fixture);
    NSString *folder=[fixture stringByAppendingPathComponent:@"diagnostics"];
    dxcheck([NSFileManager.defaultManager createDirectoryAtPath:[folder stringByAppendingPathComponent:@"Status"] withIntermediateDirectories:YES attributes:nil error:nil],@"创建夹具");
    NSDictionary *states=@{@"test.active":@{@"enabled":@YES,@"mode":@"auto"},@"test.disabled":@{@"enabled":@NO},@"../invalid":@YES};
    dxwrite(folder,@"appEnabled.plist",states);
    dxwrite(folder,@"directories.plist",@{@"test.paths":@[@"Library/Caches"]});
    NSString *secret=@"我的私人报告.pdf";
    NSString *path=[@"account-123456789/postbox/media/" stringByAppendingString:secret];
    dxwrite(folder,@"snapshots.plist",@{@"test.active":@{@"home":@"/private/var/mobile/Containers/Data/Application/private-UUID",@"updated":NSDate.date,@"rows":@[@{@"path":@"Library/Caches",@"bytes":@100,@"complete":@NO}]}});
    dxwrite(folder,@"Status/test.active.inspection.plist",@{@"reports":@{@"Library/Caches":@{@"path":@"Library/Caches",@"complete":@YES,@"coverageComplete":@NO,@"twinDisplayTruncated":@YES,@"bytes":@100,@"error":@"private-user https://secret.example/token",@"largest":@[@{@"path":path,@"bytes":@83,@"type":@"未知二进制"}],@"linkTwins":@[@{@"source":path,@"twin":[@"容器/Library/Caches/" stringByAppendingString:path],@"bytes":@83}]}}});
    AxsCacheKeeperDiagnostics *session=[[cls alloc] initWithFolder:folder];
    dxcheck([session.bundles isEqual:@[@"test.active",@"test.disabled",@"test.paths"]],@"配置并集包含关闭项，拒绝越界键");
    NSDictionary *report=[session reportWithApps:@[@{@"id":@"test.active",@"name":@"测试",@"version":@"1.0"},@{@"id":@"test.unconfigured",@"name":@"新装未配置"}] environment:@{@"os":@"16.2",@"deviceName":@"private-device"}];
    NSData *json=[NSJSONSerialization dataWithJSONObject:report options:0 error:nil];
    dxcheck(json!=nil,@"报告可序列化 JSON");
    NSString *text=[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    for (NSString *private in @[secret,@"123456789",@"private-UUID",@"private-user",@"secret.example",@"private-device"])
        dxcheck(![text containsString:private],@"输出不得包含私人路径、文本或设备标识");
    NSDictionary *app=report[@"apps"][0];
    NSDictionary *inspection=app[@"inspection"][@"data"][@"reports"][0];
    dxcheck([inspection[@"bytes"] intValue]==100 && ![inspection[@"coverageComplete"] boolValue] && [inspection[@"twinDisplayTruncated"] boolValue],@"保留字节和覆盖/截断状态");
    dxcheck(!inspection[@"inspectionReadFailure"],@"旧深检回执无结构化详情时不从自由文本猜测");
    NSDictionary *readFailure=@{@"stage":@"openRoot",@"errorDomain":@"posix",@"errorCode":@13};
    dxwrite(folder,@"Status/test.active.inspection.plist",@{@"reports":@{@"Library/Caches":@{@"failures":@1,@"coverageComplete":@NO,
        @"error":@"读取 private-inspection-canary",@"inspectionReadFailure":readFailure}}});
    NSDictionary *failureExport=dxapp([session reportWithApps:@[] environment:@{}],@"test.active")[@"inspection"][@"data"][@"reports"][0];
    dxcheck([failureExport[@"inspectionReadFailure"] isEqual:readFailure] && [failureExport[@"errorCategories"] containsObject:@"读取"] &&
        [failureExport[@"failures"] isEqual:@1] && [failureExport[@"coverageComplete"] isEqual:@NO],
        @"固定openRoot详情贯通真实报告导出并保持旧错误类别和覆盖状态");
    for (NSDictionary *detail in @[
        @{@"stage":@"enumerate",@"errorDomain":@"posix",@"errorCode":@5},
        @{@"stage":@"openFile",@"errorDomain":@"posix",@"errorCode":@13},
        @{@"stage":@"readHeader",@"errorDomain":@"posix",@"errorCode":@5},
        @{@"stage":@"rootRecheck",@"errorDomain":@"identity",@"errorCode":@0},
        @{@"stage":@"ancestorRecheck",@"errorDomain":@"identity",@"errorCode":@0},
        @{@"stage":@"fileRecheck",@"errorDomain":@"identity",@"errorCode":@0},
        @{@"stage":@"shortRead",@"errorDomain":@"read",@"errorCode":@0},
        @{@"stage":@"depthLimit",@"errorDomain":@"limit",@"errorCode":@0}]) {
        dxwrite(folder,@"Status/test.active.inspection.plist",@{@"reports":@{@"SystemData":@{
            @"coverageComplete":@NO,@"inspectionReadFailure":detail}}});
        NSDictionary *detailExport=dxapp([session reportWithApps:@[] environment:@{}],@"test.active")[@"inspection"][@"data"][@"reports"][0];
        dxcheck([detailExport[@"inspectionReadFailure"] isEqual:detail] && ![detailExport[@"coverageComplete"] boolValue],
            @"FD深检失败阶段完整导出，身份变化和短读不伪装成errno");
    }
    NSMutableArray *badReadFailures=[NSMutableArray new];
    for (id code in @[@YES,@0,@(-1),@1.5,@(NAN),@(INFINITY),@"13",@[]]) {
        NSMutableDictionary *bad=[readFailure mutableCopy];bad[@"errorCode"]=code;[badReadFailures addObject:bad];
    }
    for (NSDictionary *change in @[@{@"stage":@"private-inspection-canary"},@{@"errorDomain":@"private-inspection-canary"},
        @{@"path":@"private-inspection-canary"},@{@"state":@"notRecorded"},@{@"stage":@42}]) {
        NSMutableDictionary *bad=[readFailure mutableCopy];[bad addEntriesFromDictionary:change];[badReadFailures addObject:bad];
    }
    [badReadFailures addObjectsFromArray:@[@42,@"private-inspection-canary",@[],@{},@{@"state":@"invalid"}]];
    [badReadFailures addObjectsFromArray:@[
        @{@"stage":@"openRoot",@"errorDomain":@"identity",@"errorCode":@0},
        @{@"stage":@"rootRecheck",@"errorDomain":@"identity",@"errorCode":@1},
        @{@"stage":@"rootRecheck",@"errorDomain":@"identity",@"errorCode":@NO},
        @{@"stage":@"shortRead",@"errorDomain":@"posix",@"errorCode":@5},
        @{@"stage":@"depthLimit",@"errorDomain":@"read",@"errorCode":@0}]];
    for (id bad in badReadFailures) {
        dxwrite(folder,@"Status/test.active.inspection.plist",@{@"reports":@{@"Library/Caches":@{@"inspectionReadFailure":bad}}});
        NSDictionary *badFailureExport=dxapp([session reportWithApps:@[] environment:@{}],@"test.active")[@"inspection"][@"data"][@"reports"][0];
        NSData *badFailureJSON=[NSJSONSerialization dataWithJSONObject:badFailureExport options:0 error:nil];
        dxcheck([badFailureExport[@"inspectionReadFailure"] isEqual:@{@"state":@"invalid"}] && badFailureJSON &&
            ![[[NSString alloc] initWithData:badFailureJSON encoding:NSUTF8StringEncoding] containsString:@"private-inspection-canary"],
            @"深检失败详情拒绝坏类型、BOOL、无效数值、未知阶段和字段，路径原文不泄漏");
    }
    dxwrite(folder,@"Status/test.active.inspection.plist",@{@"reports":@{@"Library/Caches":@{@"failures":@1,@"inspectionReadFailure":@{@"state":@"notRecorded"}}}});
    NSDictionary *unrecordedFailure=dxapp([session reportWithApps:@[] environment:@{}],@"test.active")[@"inspection"][@"data"][@"reports"][0];
    dxcheck([unrecordedFailure[@"inspectionReadFailure"] isEqual:@{@"state":@"notRecorded"}],@"未覆盖的读取阶段明确notRecorded，不冒充精确POSIX诊断");
    NSString *redacted=inspection[@"largest"][0][@"path"];
    dxcheck([redacted hasSuffix:@".pdf"] && [inspection[@"linkTwins"][0][@"source"] isEqual:redacted],@"保留扩展名及同报告路径关联");
    dxcheck([app[@"cleanup"][@"state"] isEqual:@"missing"],@"缺回执不能伪造零删除");
    // Preserve real cleanup phases while keeping arbitrary status text out of exports.
    for (NSString *phase in @[@"waiting",@"cleaning",@"complete",@"error"]) {
        dxwrite(folder,@"Status/test.active.auto.plist",@{@"phase":phase,@"lastRemoved":@0,@"lastBytes":@0,@"coverageComplete":@NO});
        NSDictionary *phaseExport=dxapp([session reportWithApps:@[] environment:@{}],@"test.active")[@"cleanup"][@"data"];
        dxcheck([phaseExport[@"phase"] isEqual:phase] && [phaseExport[@"lastRemoved"] isEqual:@0] &&
            [phaseExport[@"lastBytes"] isEqual:@0] && [phaseExport[@"coverageComplete"] isEqual:@NO],
            @"生产清理阶段原样导出，不把 cleaning 变 unknown 或改写历史轮次和覆盖");
    }
    dxwrite(folder,@"Status/test.active.auto.plist",@{@"phase":@"private-phase-account-123456789"});
    NSDictionary *unknownPhase=dxapp([session reportWithApps:@[] environment:@{}],@"test.active")[@"cleanup"][@"data"];
    dxcheck([unknownPhase[@"phase"] isEqual:@"unknown"],@"清理阶段仍为封闭集合，任意文本不能进入导出");
    dxwrite(folder,@"Status/test.active.auto.plist",@{@"phase":@42});
    NSDictionary *invalidPhase=dxapp([session reportWithApps:@[] environment:@{}],@"test.active")[@"cleanup"][@"data"];
    dxcheck([invalidPhase[@"invalidRecord"] boolValue] && [invalidPhase[@"invalidFields"] containsObject:@"phase"] &&
        !invalidPhase[@"phase"],@"清理阶段坏类型明确标记，不伪造有效阶段");
    dxwrite(folder,@"Status/test.active.auto.plist",@{@"directories":@{@"Library/alog":@{@"appRuleID":@"douyin-alog",@"appRuleWaitingForExit":@YES,@"appRuleSummary":@"private-summary",@"removed":@0}}});
    NSDictionary *ruleExport=[session reportWithApps:@[] environment:@{}][@"apps"][0][@"cleanup"][@"data"][@"directories"][0];
    dxcheck([ruleExport[@"appRuleID"] isEqual:@"douyin-alog"] && [ruleExport[@"appRuleWaitingForExit"] boolValue] && !ruleExport[@"appRuleSummary"],@"导出保留固定规则ID和等待状态，不导出任意规则说明原文");
    dxcheck([[NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:@"appEnabled.plist"]] isEqual:states],@"导出不写配置");
    // 大批量采集只汇总已保存记录，完成数按 APP 固定，不以目录扩张任务。
    NSString *largeFolder=[fixture stringByAppendingPathComponent:@"diagnostics-126-apps"];
    dxcheck([NSFileManager.defaultManager createDirectoryAtPath:largeFolder withIntermediateDirectories:YES attributes:nil error:nil],@"创建批量报告夹具");
    NSMutableDictionary *largeStates=[NSMutableDictionary new];
    for (NSUInteger i=0;i<126;i++) largeStates[[NSString stringWithFormat:@"test.app%03lu",(unsigned long)i]]=@{@"enabled":@(i<19)};
    dxwrite(largeFolder,@"appEnabled.plist",largeStates);
    AxsCacheKeeperDiagnostics *large=[[cls alloc] initWithFolder:largeFolder];
    NSDictionary *largeReport=[large reportWithApps:@[] environment:@{}];
    NSDictionary *collection=largeReport[@"collection"];
    dxcheck([largeReport[@"apps"] count]==126 && [collection[@"total"] unsignedIntegerValue]==126 &&
        [collection[@"completed"] unsignedIntegerValue]==126 && [collection[@"phase"] isEqual:@"complete"] &&
        [collection[@"mode"] isEqual:@"savedRecords"],@"126 个 APP 应一次汇总完成，固定 126/126，不能启动深度任务队列");
    // 已有扫描请求不属于报告生成器；忙碌、损坏、取消等状态都不能被汇总动作改写。
    NSDictionary *request=@{@"bundle":@"test.other",@"token":@"existing",@"path":@"tmp",@"cancel":@NO};
    NSMutableDictionary *beforeRequests=[NSMutableDictionary new];
    for (NSString *name in @[@"request.plist",@"inspectionRequest.plist",@"batch.plist"]) {
        dxwrite(largeFolder,name,request);
        beforeRequests[name]=[NSData dataWithContentsOfFile:[largeFolder stringByAppendingPathComponent:name]];
    }
    NSMutableDictionary *snapshots=[NSMutableDictionary new];
    NSMutableDictionary *reports=[NSMutableDictionary new];
    NSMutableArray *rows=[NSMutableArray new];
    NSDate *oldDate=[NSDate dateWithTimeIntervalSince1970:100];
    for (NSUInteger i=0;i<12;i++) {
        NSString *path=[NSString stringWithFormat:@"Library/fixture%lu",(unsigned long)i];
        NSMutableArray *largest=[NSMutableArray new];
        for (NSUInteger j=0;j<10;j++) [largest addObject:@{@"path":[NSString stringWithFormat:@"account-123456789/resource-%lu.pdf",(unsigned long)j],@"bytes":@(j+100)}];
        reports[path]=@{@"updated":oldDate,@"complete":@YES,@"coverageComplete":@NO,@"largest":largest,@"files":@10,@"bytes":@1045};
        [rows addObject:@{@"path":path,@"bytes":@1045,@"complete":@YES}];
    }
    dxcheck([NSFileManager.defaultManager createDirectoryAtPath:[largeFolder stringByAppendingPathComponent:@"Status"] withIntermediateDirectories:YES attributes:nil error:nil],@"创建已有状态目录");
    for (NSString *bundle in large.bundles) {
        snapshots[bundle]=@{@"updated":oldDate,@"rows":rows};
        dxwrite(largeFolder,[NSString stringWithFormat:@"Status/%@.inspection.plist",bundle],@{@"reports":reports});
    }
    dxwrite(largeFolder,@"snapshots.plist",snapshots);
    NSArray *beforeFiles=[NSFileManager.defaultManager subpathsAtPath:largeFolder];
    __block NSUInteger callbacks=0;
    NSTimeInterval began=NSProcessInfo.processInfo.systemUptime;
    NSDictionary *fixed=[large reportWithApps:@[] environment:@{} progress:^(NSUInteger completed,NSUInteger total) {
        dxcheck(total==126 && completed==callbacks,@"固定 APP 总数，进度从 0 到 126 逐项增加");callbacks++;
    }];
    NSData *fixedJSON=[NSJSONSerialization dataWithJSONObject:fixed options:0 error:nil];
    NSTimeInterval elapsed=NSProcessInfo.processInfo.systemUptime-began;
    dxcheck(callbacks==127 && fixedJSON && [fixed[@"schemaVersion"] isEqual:@2],@"批量汇总返回完整内存报告与版本 2 元数据");
    dxcheck([fixed[@"collection"][@"rescanned"] isEqual:@NO] && !fixed[@"collection"][@"tasks"],@"不把已有记录汇总伪装成新扫描或创建任务队列");
    dxcheck([fixed[@"apps"][0][@"inspection"][@"data"][@"reports"] count]==12 && [fixed[@"apps"][0][@"scan"][@"data"][@"updated"] isEqual:@100],@"保留旧深度记录和原始时间，不伪造新鲜度");
    for (NSString *name in @[@"request.plist",@"inspectionRequest.plist",@"batch.plist"])
        dxcheck([[NSData dataWithContentsOfFile:[largeFolder stringByAppendingPathComponent:name]] isEqual:beforeRequests[name]],@"已有请求字节不变，不取消、不改写、不补扫");
    dxcheck([[NSSet setWithArray:beforeFiles] isEqual:[NSSet setWithArray:[NSFileManager.defaultManager subpathsAtPath:largeFolder]]],@"采集只返回内存报告，不自动生成本地文件");
    NSDictionary *again=[large reportWithApps:@[] environment:@{}];
    dxcheck([again[@"collection"][@"completed"] isEqual:@126] && [again[@"apps"] count]==126,@"重复采集不累积任务或 APP");
    printf("PASS: saved-record report: 126 apps, 1512 saved inspections, %lu JSON bytes, %.3f seconds, zero writes\n",(unsigned long)fixedJSON.length,elapsed);

    dxwrite(folder,@"Status/test.disabled.auto.plist",@{@"directories":@{@"Library/Caches":@42}});
    dxwrite(folder,@"Status/test.active.inspection.plist",@{@"reports":@[@"bad-shape"]});
    dxwrite(folder,@"Status/test.active.network.plist",@{@"prevent":@YES,@"applied":@NO});
    dxwrite(folder,@"batch.plist",@{@"remaining":@12});
    NSDictionary *badReport=[session reportWithApps:@[] environment:@{}];
    dxcheck([NSJSONSerialization dataWithJSONObject:badReport options:0 error:nil]!=nil,@"损坏嵌套记录仍可导出诊断");
    dxcheck([badReport[@"apps"][0][@"inspection"][@"data"][@"invalidRecord"] boolValue],@"损坏 reports 不能伪装为空档案");
    dxcheck([badReport[@"apps"][1][@"cleanup"][@"data"][@"directories"][0][@"invalidRecord"] boolValue],@"损坏目录记录明确标记");
    dxcheck([badReport[@"apps"][0][@"network"][@"data"][@"prevent"] isEqual:@YES] && [badReport[@"apps"][0][@"network"][@"data"][@"applied"] isEqual:@NO],@"网络限制请求和实际生效结果保留");
    dxcheck([badReport[@"batch"][@"state"] isEqual:@"invalid"],@"损坏扫描批次仍可汇总并明确标识");
    NSMutableDictionary *webKit=[@{@"schemaVersion":@1,@"requested":@YES,@"timedOut":@NO,
        @"state":@"completed",@"reason":@"none",@"persistentStores":@1,@"nonPersistentStores":@0,
        @"submitted":@1,@"completed":@1,@"pending":@0,@"bytesState":@"notMeasured",@"updated":oldDate} mutableCopy];
    dxwrite(folder,@"Status/test.active.webkit.plist",webKit);
    NSDictionary *webKitReport=[session reportWithApps:@[] environment:@{}];
    NSDictionary *webKitExport=dxapp(webKitReport,@"test.active")[@"webKitDiskCache"];
    dxcheck([webKitExport[@"state"] isEqual:@"available"] && [webKitExport[@"data"][@"state"] isEqual:@"completed"] &&
        [webKitExport[@"data"][@"updated"] isEqual:@100] && [webKitExport[@"data"][@"bytesState"] isEqual:@"notMeasured"] &&
        !webKitExport[@"data"][@"bytes"],@"网页原生回调与原始时间完整导出且不虚构释放字节");
    dxcheck([NSJSONSerialization dataWithJSONObject:webKitReport options:0 error:nil]!=nil,@"网页回执导出将日期转换为JSON数值");
    NSMutableDictionary *imageCache=[@{@"schemaVersion":@1,@"sdk":@"SDWebImage",@"state":@"apiCompleted",@"reason":@"none",
        @"observed":@2,@"eligible":@1,@"restricted":@1,@"writesBlocked":@4,@"queued":@2,@"submitted":@1,
        @"apiCompleted":@1,@"skipped":@1,@"pending":@0,@"updated":oldDate,@"bytesState":@"notMeasured"} mutableCopy];
    dxwrite(folder,@"Status/test.active.imagecache.plist",imageCache);
    NSDictionary *imageExport=dxapp([session reportWithApps:@[] environment:@{}],@"test.active")[@"imageDiskCache"];
    dxcheck([imageExport[@"state"] isEqual:@"available"] && [imageExport[@"data"][@"updated"] isEqual:@100] &&
        [imageExport[@"data"][@"writesBlocked"] isEqual:@4] && [imageExport[@"data"][@"apiCompleted"] isEqual:@1] &&
        [imageExport[@"data"][@"skipped"] isEqual:@1] && !imageExport[@"data"][@"bytes"] &&
        [NSJSONSerialization dataWithJSONObject:imageExport options:0 error:nil]!=nil,
        @"图片缓存导出区分写入拦截、API完成与执行前取消，不虚构删除文件数和释放字节");
    for (NSDictionary *change in @[@{@"url":@"private-image-canary"},@{@"pending":@1},@{@"writesBlocked":@YES},@{@"eligible":@3}]) {
        NSMutableDictionary *invalidImage=[imageCache mutableCopy];[invalidImage addEntriesFromDictionary:change];
        dxwrite(folder,@"Status/test.active.imagecache.plist",invalidImage);
        NSDictionary *report=[session reportWithApps:@[] environment:@{}];
        NSData *json=[NSJSONSerialization dataWithJSONObject:report options:0 error:nil];
        dxcheck([dxapp(report,@"test.active")[@"imageDiskCache"][@"state"] isEqual:@"invalid"] &&
            ![[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] containsString:@"private-image-canary"],
            @"图片回执拒绝私有内容、计数不一致和坏类型");
    }
    dxwrite(folder,@"Status/test.active.imagecache.plist",imageCache);
    NSMutableDictionary *installationFailure=[webKit mutableCopy];
    installationFailure[@"state"]=@"blocked";installationFailure[@"reason"]=@"installationUnverified";
    installationFailure[@"submitted"]=@0;installationFailure[@"completed"]=@0;
    installationFailure[@"installationCheck"]=@{@"state":@"failed",@"errorCode":@3};
    dxwrite(folder,@"Status/test.active.webkit.plist",installationFailure);
    NSDictionary *installationExport=dxapp([session reportWithApps:@[] environment:@{}],@"test.active")[@"webKitDiskCache"];
    dxcheck([installationExport[@"data"][@"installationCheck"] isEqual:installationFailure[@"installationCheck"]],@"安装预检失败代码完整进入真实诊断导出");
    installationFailure[@"installationCheck"]=@{@"state":@"failed",@"errorCode":@3,
        @"detail":@{@"target":@"main",@"operation":@"stat",@"errno":@2}};
    dxwrite(folder,@"Status/test.active.webkit.plist",installationFailure);
    installationExport=dxapp([session reportWithApps:@[] environment:@{}],@"test.active")[@"webKitDiskCache"];
    dxcheck([installationExport[@"data"][@"installationCheck"] isEqual:installationFailure[@"installationCheck"]] &&
        [NSJSONSerialization dataWithJSONObject:installationExport options:0 error:nil]!=nil,@"具体安装阶段与 errno 完整导出为 JSON，旧二字段回执仍兼容");
    for (NSDictionary *detail in @[@{@"target":@"main",@"operation":@"stat",@"errno":@2,@"path":@"private-install-canary"},
        @{@"target":@"main",@"operation":@"private-install-canary",@"errno":@2},
        @{@"target":@"main",@"operation":@"openIdentity",@"errno":@2}]) {
        installationFailure[@"installationCheck"]=@{@"state":@"failed",@"errorCode":@3,@"detail":detail};
        dxwrite(folder,@"Status/test.active.webkit.plist",installationFailure);
        NSDictionary *report=[session reportWithApps:@[] environment:@{}];
        NSData *json=[NSJSONSerialization dataWithJSONObject:report options:0 error:nil];
        dxcheck([dxapp(report,@"test.active")[@"webKitDiskCache"][@"state"] isEqual:@"invalid"] &&
            ![[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] containsString:@"private-install-canary"],
            @"安装错误拒绝私有路径、任意阶段和残留 errno，不能静默当成有效旧回执");
    }
    dxwrite(folder,@"Status/test.active.webkit.plist",webKit);
    webKit[@"submitted"]=@2;
    dxwrite(folder,@"Status/test.active.webkit.plist",webKit);
    dxcheck([dxapp([session reportWithApps:@[] environment:@{}],@"test.active")[@"webKitDiskCache"][@"state"] isEqual:@"invalid"],@"网页回执丢失已提交请求不能伪装完成");
    webKit[@"submitted"]=@1;
    webKit[@"url"]=@"https://private-canary.example/account-secret";
    dxwrite(folder,@"Status/test.active.webkit.plist",webKit);
    NSDictionary *unsafeWebKit=[session reportWithApps:@[] environment:@{}];
    NSData *unsafeJSON=[NSJSONSerialization dataWithJSONObject:unsafeWebKit options:0 error:nil];
    dxcheck([dxapp(unsafeWebKit,@"test.active")[@"webKitDiskCache"][@"state"] isEqual:@"invalid"] &&
        ![[[NSString alloc] initWithData:unsafeJSON encoding:NSUTF8StringEncoding] containsString:@"private-canary"],@"网页回执拒绝未知字段且不泄漏URL");
    [webKit removeObjectForKey:@"url"];webKit[@"pending"]=@"1";
    dxwrite(folder,@"Status/test.active.webkit.plist",webKit);
    dxcheck([dxapp([session reportWithApps:@[] environment:@{}],@"test.active")[@"webKitDiskCache"][@"state"] isEqual:@"invalid"],@"网页回执坏类型不能伪装完成");
    dxcheck([[NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:@"appEnabled.plist"]] isEqual:states],@"整个汇总流程不修改开关");
    dxwrite(folder,@"appEnabled.plist",@{@"test.active":@{@"enabled":@YES,@"mode":@42},@"test.disabled":@"invalid"});
    dxwrite(folder,@"directories.plist",@{@"test.active":@42,@"test.paths":@[@"Library/Caches",@42]});
    NSDictionary *invalidSelection=[session reportWithApps:@[] environment:@{}];
    dxcheck([invalidSelection[@"apps"][0][@"configurationState"] isEqual:@"invalid"] &&
        [invalidSelection[@"apps"][0][@"configuration"][@"invalidFields"] containsObject:@"mode"],@"配置字符串字段坏类型明确标记");
    dxcheck([invalidSelection[@"apps"][1][@"configurationState"] isEqual:@"invalid"],@"单 APP 配置坏类型不能伪装有效");
    dxcheck([invalidSelection[@"apps"][0][@"selectionState"] isEqual:@"invalid"] &&
        [invalidSelection[@"apps"][2][@"selectionState"] isEqual:@"invalid"],@"目录选择坏容器和坏元素明确标记");
    dxcheck([invalidSelection[@"apps"][1][@"selectionState"] isEqual:@"missing"] &&
        [invalidSelection[@"apps"][2][@"configurationState"] isEqual:@"missing"],@"逐 APP 缺失与损坏分别标记");
    dxwrite(folder,@"directories.plist",@{@"test.paths":@[@"Library/Caches"]});
    dxcheck([[@"invalid plist" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:[folder stringByAppendingPathComponent:@"appEnabled.plist"] atomically:YES],@"写入损坏配置夹具");
    AxsCacheKeeperDiagnostics *damaged=[[cls alloc] initWithFolder:folder];
    NSDictionary *damagedReport=[damaged reportWithApps:@[] environment:@{}];
    dxcheck([damagedReport[@"sourceStates"][@"configuration"] isEqual:@"invalid"] && [damagedReport[@"apps"] count]==1,@"配置损坏明确标识，仍汇总独立目录配置已有 APP");
    AxsCacheKeeperDiagnostics *empty=[[cls alloc] initWithFolder:[fixture stringByAppendingPathComponent:@"no-config"]];
    NSDictionary *emptyReport=[empty reportWithApps:@[] environment:@{}];
    dxcheck([emptyReport[@"collection"][@"total"] isEqual:@0] && [emptyReport[@"sourceStates"][@"configuration"] isEqual:@"missing"],@"无配置报告保留缺失状态");
    NSMutableDictionary *role=[@{@"state":@"available",@"registeredURLCount":@1,@"associationCount":@1} mutableCopy];
    for (NSString *key in @[@"observedSourceCount",@"missingSelectorCount",@"notProvidedCount",@"invalidSourceCount",@"invalidAssociationCount",@"ownerMismatchCount",@"unavailableOwnerCount",@"truncatedCount"]) role[key]=@0;
    role[@"observedSourceCount"]=@1;role[@"rawPluginIdentifier"]=@"private-plugin-id";
    NSMutableDictionary *coverage=[@{@"schemaVersion":@1,@"state":@"available",@"sourceState":@"available",@"observedRegistrations":@1,
        @"invalidRegistrationCount":@0,@"truncatedRegistrationCount":@0,@"allRolesUniqueRegisteredURLCount":@1,@"countsAreLowerBounds":@NO,
        @"home":role,@"group":role,@"extension":role,@"path":@"/private/secret-container"} mutableCopy];
    NSDictionary *(^project)(void)=^NSDictionary *{return [empty reportWithApps:nil environment:@{@"containerCoverage":coverage}][@"containerCoverage"];};
    NSDictionary *projected=project();
    dxcheck([projected[@"state"] isEqual:@"available"] && !projected[@"path"] && !projected[@"extension"][@"rawPluginIdentifier"],@"容器诊断固定白名单丢弃恶意路径和插件ID");
    coverage[@"schemaVersion"]=@2;dxcheck([project()[@"state"] isEqual:@"invalid"],@"未知容器摘要版本明确invalid");coverage[@"schemaVersion"]=@1;
    coverage[@"observedRegistrations"]=@YES;dxcheck([project()[@"state"] isEqual:@"invalid"],@"布尔不能冒充容器登记计数");coverage[@"observedRegistrations"]=@1;
    coverage[@"countsAreLowerBounds"]=@1;dxcheck([project()[@"state"] isEqual:@"invalid"],@"整数不能冒充lowerBounds布尔");coverage[@"countsAreLowerBounds"]=@NO;
    role[@"invalidSourceCount"]=@1;dxcheck([project()[@"state"] isEqual:@"invalid"],@"含无效来源的角色不能伪装完整available");role[@"invalidSourceCount"]=@0;
    role[@"registeredURLCount"]=@3;dxcheck([project()[@"state"] isEqual:@"invalid"],@"登记URL数不得超过角色关联数");role[@"registeredURLCount"]=@1;
    // Each role gets an independent fixture so an impossible count cannot hide in another role.
    for (NSString *name in @[@"home",@"group",@"extension"]) coverage[name]=[role mutableCopy];
    for (NSString *name in @[@"home",@"group",@"extension"]) {
        NSMutableDictionary *candidate=coverage[name];candidate[@"registeredURLCount"]=@0;
        NSDictionary *rejected=project();
        dxcheck([rejected[@"state"] isEqual:@"invalid"] && !rejected[@"home"] && !rejected[@"observedRegistrations"],@"每个角色零URL正关联均拒绝且不输出可信计数");
        candidate[@"registeredURLCount"]=@1;
    }
    NSMutableDictionary *homeRole=coverage[@"home"];
    homeRole[@"notProvidedCount"]=@2;
    dxcheck([project()[@"state"] isEqual:@"invalid"],@"home未提供数量不得超过已观察来源");
    homeRole[@"notProvidedCount"]=@1;
    dxcheck([project()[@"state"] isEqual:@"invalid"],@"home关联加未提供数量不得超过来源");
    homeRole[@"notProvidedCount"]=@0;
    coverage[@"observedRegistrations"]=@2;
    homeRole[@"observedSourceCount"]=@2;
    dxcheck([project()[@"state"] isEqual:@"available"],@"重复APP登记去重后home关联加未提供可小于来源");
    homeRole[@"notProvidedCount"]=@1;
    dxcheck([project()[@"state"] isEqual:@"available"],@"home关联加未提供等于来源为合法边界");
    homeRole[@"notProvidedCount"]=@0;homeRole[@"observedSourceCount"]=@1;coverage[@"observedRegistrations"]=@1;
    for (NSNumber *bad in @[@(NAN),@(-1),@0.5]) {
        coverage[@"observedRegistrations"]=bad;
        dxcheck([project()[@"state"] isEqual:@"invalid"],@"顶层计数拒绝NaN、负数和小数");
        coverage[@"observedRegistrations"]=@1;
        for (NSString *name in @[@"home",@"group",@"extension"]) {
            NSMutableDictionary *candidate=coverage[name];candidate[@"associationCount"]=bad;
            dxcheck([project()[@"state"] isEqual:@"invalid"],@"各角色计数拒绝NaN、负数和小数");
            candidate[@"associationCount"]=@1;
        }
    }
    for (NSString *name in @[@"home",@"group",@"extension"]) coverage[name]=role;
    role[@"state"]=@"unavailable";role[@"observedSourceCount"]=@0;
    dxcheck([project()[@"state"] isEqual:@"invalid"],@"来源不可用不接受伪造零计数");
    dxwrite(folder,@"Status/test.active.auto.plist",@{@"directories":@{@"Library/Caches":@{@"hardLinkRetained":@2,@"hardLinkRetainedBytes":@26,@"changed":@0,@"hardLinkRetentionReason":@"multipleLinks"}}});
    NSDictionary *retained=[session reportWithApps:@[@{@"id":@"test.active"}] environment:@{}][@"apps"][0][@"cleanup"][@"data"][@"directories"][0];
    dxcheck([retained[@"hardLinkRetained"] isEqual:@2] && [retained[@"hardLinkRetainedBytes"] isEqual:@26] &&
        [retained[@"changed"] isEqual:@0] && [retained[@"hardLinkRetentionReason"] isEqual:@"multipleLinks"],@"硬链接保留计数、逻辑字节和固定原因由已有诊断导出保留");
    NSString *releaseRound=@"A0274912-2134-4AD8-8E0A-C91B9DCB104F";
    NSDictionary *release=@{@"schemaVersion":@1,@"roundID":releaseRound,@"revision":@1,@"state":@"finished",
        @"attempts":@1,@"succeeded":@1,@"failed":@0,@"postMissing":@0,@"detailsOmitted":@0,@"identitiesOmitted":@0,
        @"volumesOmitted":@0,@"overflow":@NO,@"uniqueExtents":@"notMeasured",@"reclaimedPhysicalBytes":@"notMeasured",@"volumes":@[],
        @"details":@[@{@"attemptID":@1,@"rootID":@1,@"objectID":@1,@"kind":@"ordinary",@"result":@0,@"errno":@0,
            @"pre":@{@"state":@"observed",@"errno":@0,@"size":@12,@"blocks":@8,@"nlink":@1},
            @"post":@{@"state":@"observed",@"errno":@0,@"size":@12,@"blocks":@8,@"nlink":@0},
            @"identityMatch":@"same",@"linkTransition":@"decremented"}]};
    dxwrite(folder,@"Status/test.active.auto.plist",@{@"confirmedRoundID":releaseRound,@"releaseEvidence":release});
    NSDictionary *releaseExport=[session reportWithApps:@[@{@"id":@"test.active"}] environment:@{}][@"apps"][0][@"cleanup"][@"data"][@"releaseEvidence"];
    dxcheck([releaseExport isEqual:release],@"真实诊断导出保留同轮匿名删除证据及未测物理量");
    NSMutableDictionary *badRelease=[release mutableCopy];badRelease[@"rawPath"]=@"private-release-path-canary";
    dxwrite(folder,@"Status/test.active.auto.plist",@{@"confirmedRoundID":releaseRound,@"releaseEvidence":badRelease});
    NSDictionary *badReleaseReport=[session reportWithApps:@[@{@"id":@"test.active"}] environment:@{}];
    NSString *encoded=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:badReleaseReport options:0 error:nil] encoding:NSUTF8StringEncoding];
    dxcheck([badReleaseReport[@"apps"][0][@"cleanup"][@"data"][@"releaseEvidence"] isEqual:@{@"state":@"invalid"}] &&
        ![encoded containsString:@"private-release-path-canary"],@"额外路径拒绝且不进入诊断JSON");
    dxwrite(folder,@"Status/test.active.auto.plist",@{@"confirmedRoundID":@"old-round",@"removed":@1});
    dxcheck([[session reportWithApps:@[@{@"id":@"test.active"}] environment:@{}][@"apps"][0][@"cleanup"][@"data"][@"releaseEvidence"] isEqual:@{@"state":@"notRecorded"}],@"旧清理回执没有释放证据时明确未记录");
    NSDictionary *historyContext=axs_cachekeeper_cleanup_context(@"clean",YES,NO,NO,YES,@"0.7.2-188.1",@"1.0",@"100",@"platform-cache:2",@[@"Library/Caches"],@[],@[]);
    NSDictionary *historyRow=@{@"roundID":releaseRound,@"finishedAt":[NSDate dateWithTimeIntervalSince1970:100],@"removed":@1,
        @"bytes":@12,@"failed":@0,@"endReason":@1,@"coverageComplete":@YES,@"context":historyContext,@"releaseEvidence":release};
    NSDictionary *historyReceipt=@{@"confirmedRoundID":releaseRound,@"cleanupContext":historyContext,@"lastEffectiveCleanup":historyRow,
        @"cleanupHistory":@{@"schemaVersion":@1,@"state":@"recorded",@"capacity":@16,@"truncatedCount":@0,@"rounds":@[historyRow]}};
    dxwrite(folder,@"Status/test.active.auto.plist",historyReceipt);
    NSDictionary *historyExport=[session reportWithApps:@[@{@"id":@"test.active"}] environment:@{}][@"apps"][0][@"cleanup"][@"data"];
    dxcheck([historyExport[@"lastEffectiveCleanup"][@"context"] isEqual:historyContext] &&
        [historyExport[@"lastEffectiveCleanup"][@"releaseEvidence"] isEqual:release] &&
        [historyExport[@"lastEffectiveCleanup"][@"finishedAt"] isEqual:@100] &&
        [historyExport[@"cleanupHistory"][@"rounds"] count]==1,@"诊断导出保留历史模式版本时间和同轮证据");
    NSMutableDictionary *badHistory=[historyReceipt mutableCopy],*badHistoryContext=[historyContext mutableCopy];
    badHistoryContext[@"installationFingerprint"]=@"private-history-identity-canary";
    badHistory[@"cleanupContext"]=badHistoryContext;
    dxwrite(folder,@"Status/test.active.auto.plist",badHistory);
    NSDictionary *invalidHistoryReport=[session reportWithApps:@[@{@"id":@"test.active"}] environment:@{}];
    NSString *invalidHistoryJSON=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:invalidHistoryReport options:0 error:nil] encoding:NSUTF8StringEncoding];
    dxcheck([invalidHistoryReport[@"apps"][0][@"cleanup"][@"data"][@"cleanupHistory"] isEqual:@{@"state":@"invalid"}] &&
        ![invalidHistoryJSON containsString:@"private-history-identity-canary"],@"新版历史私有额外字段标无效且不进入导出");
    dxwrite(folder,@"Status/test.active.auto.plist",@{@"removed":@900});
    dxcheck([[session reportWithApps:@[@{@"id":@"test.active"}] environment:@{}][@"apps"][0][@"cleanup"][@"data"][@"lastEffectiveCleanup"]
        isEqual:@{@"state":@"notRecorded"}],@"旧累计数据不能导出伪造的最近实际清理");
    printf("PASS: diagnostic saved-record aggregation, privacy, fixed progress, missing records and zero filesystem writes\n");
}
