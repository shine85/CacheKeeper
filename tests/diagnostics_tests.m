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
    dxcheck([session startAt:0]==nil && session.running,@"启动补采");
    [session advanceAt:0];
    NSDictionary *request=[NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:@"request.plist"]];
    dxcheck([request[@"bundle"] isEqual:@"test.active"],@"首先检测第一项配置");
    dxwrite(folder,@"scan.plist",@{@"token":@"old",@"bundle":@"test.active",@"rows":@[]});
    [session advanceAt:1];
    dxcheck(![NSFileManager.defaultManager fileExistsAtPath:[folder stringByAppendingPathComponent:@"inspectionRequest.plist"]],@"旧 token 不推进队列");
    dxwrite(folder,@"scan.plist",@{@"token":request[@"token"],@"bundle":@"test.active",@"rows":@[@{@"path":@"Library/Caches"},@{@"path":@"../escape"},@{@"path":@"Library/Caches"}]});
    // Scanner 已消费请求；夹具只移除自己创建的请求文件。
    [NSFileManager.defaultManager removeItemAtPath:[folder stringByAppendingPathComponent:@"request.plist"] error:nil];
    [session advanceAt:2];[session advanceAt:3];
    NSDictionary *deep=[NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:@"inspectionRequest.plist"]];
    dxcheck([deep[@"path"] isEqual:@"Library/Caches"],@"同 token 后串行补采有效根");
    [session stop];
    dxcheck(!session.running && [[NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:@"inspectionRequest.plist"]][@"cancel"] boolValue],@"停止仅取消本会话深度请求");
    AxsCacheKeeperDiagnostics *timeout=[[cls alloc] initWithFolder:folder];
    dxcheck([timeout startAt:10]==nil,@"已取消请求允许新采集");
    [timeout advanceAt:10];[timeout advanceAt:131];
    dxcheck(!timeout.running && [timeout.status containsString:@"超时"],@"无回执超时停止，不能假报完成");
    dxwrite(folder,@"inspectionRequest.plist",@{@"bundle":@"test.other",@"path":@"tmp",@"token":@"someone-else"});
    [timeout stop];
    dxcheck(![[NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:@"inspectionRequest.plist"]][@"cancel"] boolValue],@"不取消其他会话请求");
    dxwrite(folder,@"Status/test.disabled.auto.plist",@{@"directories":@{@"Library/Caches":@42}});
    dxwrite(folder,@"Status/test.active.inspection.plist",@{@"reports":@[@"bad-shape"]});
    dxwrite(folder,@"Status/test.active.network.plist",@{@"prevent":@YES,@"applied":@NO});
    dxwrite(folder,@"batch.plist",@{@"remaining":@12});
    AxsCacheKeeperDiagnostics *damaged=[[cls alloc] initWithFolder:folder];
    dxcheck([damaged startAt:200]!=nil && !damaged.running,@"损坏批次拒绝启动，不崩溃或覆盖其他请求");
    NSDictionary *badReport=[damaged reportWithApps:@[] environment:@{}];
    dxcheck([NSJSONSerialization dataWithJSONObject:badReport options:0 error:nil]!=nil,@"损坏嵌套记录仍可导出诊断");
    dxcheck([badReport[@"apps"][0][@"inspection"][@"data"][@"invalidRecord"] boolValue],@"损坏 reports 不能伪装为空档案");
    dxcheck([badReport[@"apps"][1][@"cleanup"][@"data"][@"directories"][0][@"invalidRecord"] boolValue],@"损坏目录记录明确标记");
    dxcheck([badReport[@"apps"][0][@"network"][@"data"][@"prevent"] isEqual:@YES] && [badReport[@"apps"][0][@"network"][@"data"][@"applied"] isEqual:@NO],@"网络限制请求和实际生效结果保留");
    dxwrite(folder,@"batch.plist",@{});
    [NSFileManager.defaultManager removeItemAtPath:[folder stringByAppendingPathComponent:@"request.plist"] error:nil];
    dxwrite(folder,@"inspectionRequest.plist",@{@"token":@"broken",@"cancel":@[]});
    dxcheck([damaged startAt:201]!=nil,@"错误类型的 cancel 不能崩溃或被覆盖");
    dxwrite(folder,@"inspectionRequest.plist",@{});
    dxcheck([damaged startAt:202]==nil,@"空闲接口重新开始");
    [damaged advanceAt:202];
    NSDictionary *current=[NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:@"request.plist"]];
    dxwrite(folder,@"scan.plist",@{@"bundle":current[@"bundle"],@"token":current[@"token"],@"complete":@[],@"rows":@[]});
    [damaged advanceAt:203];
    dxcheck(!damaged.running && [damaged.status containsString:@"损坏"],@"回执布尔类型损坏明确停止");
    dxcheck([[NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:@"appEnabled.plist"]] isEqual:states],@"整个补采流程不修改开关");
    NSString *doneFolder=[fixture stringByAppendingPathComponent:@"diagnostics-finished"];
    dxcheck([NSFileManager.defaultManager createDirectoryAtPath:[doneFolder stringByAppendingPathComponent:@"Status"] withIntermediateDirectories:YES attributes:nil error:nil],@"创建完成流程夹具");
    dxwrite(doneFolder,@"appEnabled.plist",@{@"test.done":@YES});
    AxsCacheKeeperDiagnostics *done=[[cls alloc] initWithFolder:doneFolder];
    dxcheck([done startAt:0]==nil,@"开始成功流程");[done advanceAt:0];
    NSDictionary *scanRequest=[NSDictionary dictionaryWithContentsOfFile:[doneFolder stringByAppendingPathComponent:@"request.plist"]];
    dxcheck([scanRequest[@"diagnostic"] boolValue],@"采集目录请求不触发清理重检");
    dxwrite(doneFolder,@"scan.plist",@{@"bundle":@"test.done",@"token":scanRequest[@"token"],@"rows":@[@{@"path":@"tmp"} ]});
    [done advanceAt:1];[done advanceAt:2];
    NSDictionary *inspectRequest=[NSDictionary dictionaryWithContentsOfFile:[doneFolder stringByAppendingPathComponent:@"inspectionRequest.plist"]];
    dxwrite(doneFolder,@"Status/test.done.inspection.plist",@{@"reports":@{@"tmp":@{@"bundle":@"test.done",@"token":inspectRequest[@"token"],@"complete":@YES,@"coverageComplete":@YES}}});
    [done advanceAt:3];[done advanceAt:4];
    NSDictionary *doneReport=[done reportWithApps:@[] environment:@{}];
    dxcheck(!done.running && [doneReport[@"collection"][@"phase"] isEqual:@"complete"] && [doneReport[@"collection"][@"tasks"] count]==2,@"扫描与深度串行结束后准确报告完成");
    printf("PASS: diagnostic scope, privacy, receipts, token sequencing, stop and timeout\n");
}
