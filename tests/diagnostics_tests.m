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
    printf("PASS: diagnostic scope, privacy, receipts, token sequencing, stop and timeout\n");
}
