#import <Foundation/Foundation.h>
#import "../AxsCacheKeeperDiagnostics.h"

static void dxcheck(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr,"FAIL: diagnostics: %s\n",message.UTF8String);exit(1); }
}
static void dxwrite(NSString *folder,NSString *file,NSDictionary *value) {
    dxcheck([value writeToFile:[folder stringByAppendingPathComponent:file] atomically:YES],@"写入诊断夹具");
}
void axs_cachekeeper_run_diagnostics_tests(NSString *fixture) {
    Class cls=NSClassFromString(@"AxsCacheKeeperDiagnostics");
    dxcheck(cls!=Nil,@"应提供可调用的诊断采集实现");
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
    NSDictionary *report=[session reportWithApps:@[@{@"id":@"test.active",@"name":@"测试",@"version":@"1.0"},@{@"id":@"test.unconfigured",@"name":@"不应导出"}] environment:@{@"os":@"16.2",@"deviceName":@"private-device"}];
    NSData *json=[NSJSONSerialization dataWithJSONObject:report options:0 error:nil];
    dxcheck(json!=nil,@"报告可序列化 JSON");
    NSString *text=[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    for (NSString *private in @[secret,@"123456789",@"private-UUID",@"private-user",@"secret.example",@"private-device",@"test.unconfigured"])
        dxcheck(![text containsString:private],@"输出不得包含私人路径、文本或未配置 APP");
    NSDictionary *app=report[@"apps"][0];
    NSDictionary *inspection=app[@"inspection"][@"data"][@"reports"][0];
    dxcheck([inspection[@"bytes"] intValue]==100 && ![inspection[@"coverageComplete"] boolValue] && [inspection[@"twinDisplayTruncated"] boolValue],@"保留字节和覆盖/截断状态");
    NSString *redacted=inspection[@"largest"][0][@"path"];
    dxcheck([redacted hasSuffix:@".pdf"] && [inspection[@"linkTwins"][0][@"source"] isEqual:redacted],@"保留扩展名及同报告路径关联");
    dxcheck([app[@"cleanup"][@"state"] isEqual:@"missing"],@"缺回执不能伪造零删除");
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
