#import <Foundation/Foundation.h>
#import "../AxsCacheKeeperDiagnostics.h"

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
    NSString *redacted=inspection[@"largest"][0][@"path"];
    dxcheck([redacted hasSuffix:@".pdf"] && [inspection[@"linkTwins"][0][@"source"] isEqual:redacted],@"保留扩展名及同报告路径关联");
    dxcheck([app[@"cleanup"][@"state"] isEqual:@"missing"],@"缺回执不能伪造零删除");
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
    printf("PASS: diagnostic saved-record aggregation, privacy, fixed progress, missing records and zero filesystem writes\n");
}
