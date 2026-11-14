#import <Foundation/Foundation.h>
#import "../AxsCacheKeeperDiagnostics.h"
#include <math.h>

static void axs_cachekeeper_channel_export_check(BOOL condition,NSString *message) {
    if (!condition) {fprintf(stderr,"FAIL: diagnostic channel export: %s\n",message.UTF8String);exit(1);}
}
void axs_cachekeeper_run_diagnostic_channel_export_tests(void) {
    NSString *folder=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    AxsCacheKeeperDiagnostics *session=[[AxsCacheKeeperDiagnostics alloc] initWithFolder:folder];
    NSDictionary *verified=@{@"protocolVersion":@1,@"state":@"verified",@"stage":@"none",@"errorDomain":@"none",
        @"errorCode":@0,@"errorOrigin":@"none",@"selfIdentity":@"verified",@"peerIdentity":@"verified",@"serverRegister":@"verified"};
    NSDictionary *report=[session reportWithApps:@[] environment:@{@"diagnosticChannel":verified}];
    axs_cachekeeper_channel_export_check([report[@"diagnosticChannel"] isEqual:verified],@"握手状态必须进入内存诊断报告");
    NSMutableDictionary *private=[verified mutableCopy];
    for (NSString *key in @[@"auditToken",@"nonce",@"pid",@"executable",@"signingID",@"message"])
        private[key]=@"private-sentinel-do-not-export";
    report=[session reportWithApps:@[] environment:@{@"diagnosticChannel":private}];
    axs_cachekeeper_channel_export_check([report[@"diagnosticChannel"] isEqual:verified],@"身份原文和未知字段不能进入报告");
    NSData *data=[NSJSONSerialization dataWithJSONObject:report options:0 error:nil];
    NSString *json=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    axs_cachekeeper_channel_export_check(data && ![json containsString:@"private-sentinel"],@"只序列化经过投影的状态");
    NSDictionary *unconnected=@{@"protocolVersion":@1,@"state":@"unavailable",@"stage":@"lookup",@"errorDomain":@"mach",
        @"errorCode":@1102,@"errorOrigin":@"local",@"selfIdentity":@"verified",@"peerIdentity":@"notObserved",@"serverRegister":@"notObserved"};
    report=[session reportWithApps:@[] environment:@{@"diagnosticChannel":unconnected}];
    axs_cachekeeper_channel_export_check([report[@"diagnosticChannel"] isEqual:unconnected],@"lookup 失败不得编造远端注册或身份结果");
    report=[session reportWithApps:@[] environment:@{}];
    axs_cachekeeper_channel_export_check([report[@"diagnosticChannel"] isEqual:@{@"state":@"notObserved"}],@"未调用握手与失败必须分开");
    for (id invalid in @[NSNull.null,@42,@[],@"private-sentinel"]) {
        report=[session reportWithApps:@[] environment:@{@"diagnosticChannel":invalid}];
        axs_cachekeeper_channel_export_check([report[@"diagnosticChannel"][@"state"] isEqual:@"invalid"],@"坏形状状态不得冒充未检查或已认证");
    }
    NSDictionary *invalidValues=@{@"protocolVersion":@[@YES,@2,@1.5],@"state":@[@"private-sentinel",@42],
        @"stage":@[@"private-sentinel",@[]],@"errorDomain":@[@"private-sentinel"],@"errorOrigin":@[@"private-sentinel"],
        @"errorCode":@[@"private-sentinel",@YES,@(NAN),@(INFINITY),@0.5,@(INT64_MAX)],
        @"selfIdentity":@[@"private-sentinel"],@"peerIdentity":@[@"private-sentinel"],@"serverRegister":@[@"private-sentinel"]};
    for (NSString *key in invalidValues) {
        NSMutableDictionary *partial=[verified mutableCopy];[partial removeObjectForKey:key];
        report=[session reportWithApps:@[] environment:@{@"diagnosticChannel":partial}];
        axs_cachekeeper_channel_export_check([report[@"diagnosticChannel"][@"state"] isEqual:@"invalid"],@"必需状态字段缺失不能报告已认证");
        for (id value in invalidValues[key]) {
            NSMutableDictionary *damaged=[verified mutableCopy];damaged[key]=value;
            report=[session reportWithApps:@[] environment:@{@"diagnosticChannel":damaged}];
            data=[NSJSONSerialization dataWithJSONObject:report options:0 error:nil];
            json=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            axs_cachekeeper_channel_export_check([report[@"diagnosticChannel"][@"state"] isEqual:@"invalid"] && data && ![json containsString:@"private-sentinel"],@"坏枚举或非有限整数必须拒绝并保持可导出");
        }
    }
    axs_cachekeeper_channel_export_check(![NSFileManager.defaultManager fileExistsAtPath:folder],@"握手状态汇总零新增目录或文件");
    puts("PASS: diagnostic channel export");
}
