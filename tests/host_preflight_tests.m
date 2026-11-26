// 新文件无旧版本可备份。真实 Foundation、Darwin notify 客户端/服务端与文件测试。
#import <Foundation/Foundation.h>
#import "../AxsCacheKeeperHostPreflight.h"
#import "../AxsCacheKeeperHostEvidence.h"
#include <notify.h>
#include <string.h>

static NSString *CKFailedBundle;
uint32_t axs_cachekeeper_preflight_test_register(const char *name,int *token) {
    if (CKFailedBundle && strstr(name,CKFailedBundle.UTF8String) && strstr(name,".request")) return NOTIFY_STATUS_FAILED;
    return notify_register_check(name,token);
}
static void CKRequire(BOOL value,const char *message) {
    if (!value) {fprintf(stderr,"FAIL: host preflight: %s\n",message);exit(1);}
}
static NSString *CKStatus(NSString *folder) {
    NSString *status=[folder stringByAppendingPathComponent:@"Status"];
    CKRequire([NSFileManager.defaultManager createDirectoryAtPath:status withIntermediateDirectories:YES attributes:nil error:NULL],"fixture status directory created");
    return status;
}
static void CKWait(AxsCacheKeeperHostPreflight *batch) {
    NSTimeInterval end=NSProcessInfo.processInfo.systemUptime+5;
    while (batch.running && NSProcessInfo.processInfo.systemUptime<end) {[batch poll];[NSThread sleepForTimeInterval:.01];}
    CKRequire(!batch.running,"batch completes within local fixture deadline");
}
static NSArray *CKClients(AxsCacheKeeperHostPreflight *batch) {return [batch valueForKey:@"axs_cachekeeper_clients"];}
static void CKReleased(NSArray *clients) {
    for (AxsCacheKeeperHostEvidenceClient *client in clients) CKRequire(client.axs_cachekeeper_activeTokenCount==0,"every real client releases notify tokens");
}
static NSArray *CKServers(NSString *folder) {
    NSMutableArray *servers=[NSMutableArray new];NSUInteger index=0;
    for (NSDictionary *target in axs_cachekeeper_host_preflight_targets()) {
        NSString *version=index++ ? @"0.7.2-215.1" : @"0.7.2-202.1";
        AxsCacheKeeperHostEvidenceServer *server=[[AxsCacheKeeperHostEvidenceServer alloc] initWithBundle:target[@"bundle"] folder:folder runtimeInfo:@{@"schemaVersion":@1,@"packageVersion":version,@"firstObserved":@(NSDate.date.timeIntervalSince1970-10)}];
        CKRequire(server!=nil,"real host server initialized");
        [server axs_cachekeeper_observeContainer:YES authorizationAttempted:NO authorizationCode:0 sharedAccess:NO];
        CKRequire([server axs_cachekeeper_snapshot]!=nil,"existing server context sampled");[servers addObject:server];
    }
    return servers;
}
static void CKObserved(NSString *folder) {
    NSString *status=CKStatus(folder);NSDictionary *config=@{@"com.tencent.mqq":@NO};
    NSString *configuration=[folder stringByAppendingPathComponent:@"appEnabled.plist"];
    CKRequire([config writeToFile:configuration atomically:YES],"disabled configuration fixture saved");
    NSData *before=[NSData dataWithContentsOfFile:configuration];NSArray *servers=CKServers(folder);
    AxsCacheKeeperHostPreflight *batch=[[AxsCacheKeeperHostPreflight alloc] initWithStatusDirectory:status panelVersion:@"0.7.2-215.1"];
    CKRequire([batch.snapshot[@"total"] isEqual:@5] && [batch.snapshot[@"completed"] isEqual:@0],"initial fixed five targets are idle");
    CKRequire([batch startWithTimeout:2],"start accepts one round");NSArray *clients=CKClients(batch);
    CKRequire(![batch startWithTimeout:2],"running round cannot be replaced");CKWait(batch);
    NSDictionary *snapshot=batch.snapshot;CKRequire([snapshot[@"completed"] isEqual:@5],"five independent peers complete");
    NSMutableArray *saved=[NSMutableArray new];NSUInteger index=0;
    for (NSDictionary *row in snapshot[@"rows"]) {
        CKRequire([row[@"state"] isEqual:@"observed"] && [row[@"saveState"] isEqual:@"succeeded"] && [row[@"saveErrorCode"] isEqual:@0],"observed terminal response saved");
        NSString *path=[status stringByAppendingPathComponent:[row[@"bundle"] stringByAppendingString:@".hostObserved.plist"]];
        NSDictionary *disk=[NSDictionary dictionaryWithContentsOfFile:path];
        CKRequire([disk isEqual:row[@"result"]] && axs_cachekeeper_host_observed_projection(disk)!=nil,"disk contains only original closed observation");
        CKRequire([disk[@"transportTrust"] isEqual:@"unauthenticated"] && ![disk[@"data"][@"authorizationAttempted"] boolValue] && ![disk[@"data"][@"sharedAccessGranted"] boolValue],"readonly self-report does not invent access");
        NSString *version=disk[@"data"][@"runtimeInfo"][@"packageVersion"];
        CKRequire([version isEqual:(index++ ? @"0.7.2-215.1" : @"0.7.2-202.1")],"different host versions stay isolated");
        [saved addObject:[NSData dataWithContentsOfFile:path]];
    }
    [batch poll];[batch retrySaving];index=0;
    for (NSDictionary *row in batch.snapshot[@"rows"]) {
        NSData *bytes=[NSData dataWithContentsOfFile:[status stringByAppendingPathComponent:[row[@"bundle"] stringByAppendingString:@".hostObserved.plist"]]];
        CKRequire([bytes isEqual:saved[index++]],"repeat poll and retry do not replace successful results");
    }
    NSString *firstFile=[status stringByAppendingPathComponent:[axs_cachekeeper_host_preflight_targets()[0][@"bundle"] stringByAppendingString:@".hostObserved.plist"]];
    CKRequire([NSFileManager.defaultManager moveItemAtPath:firstFile toPath:[firstFile stringByAppendingString:@".saved"] error:NULL],"fixture moves a successfully saved result");
    [batch poll];[batch retrySaving];
    CKRequire(![NSFileManager.defaultManager fileExistsAtPath:firstFile],"successful rows never write again after their first terminal save");
    CKRequire([[NSData dataWithContentsOfFile:configuration] isEqual:before],"preflight leaves disabled configuration bytes unchanged");
    CKReleased(clients);for (AxsCacheKeeperHostEvidenceServer *server in servers) [server axs_cachekeeper_invalidate];
}
static void CKTimeoutCancel(NSString *folder) {
    NSString *status=CKStatus(folder);AxsCacheKeeperHostPreflight *batch=[[AxsCacheKeeperHostPreflight alloc] initWithStatusDirectory:status panelVersion:@"0.7.2-215.1"];
    CKRequire([batch startWithTimeout:.01],"timeout round starts");NSArray *first=CKClients(batch);[NSThread sleepForTimeInterval:.03];[batch poll];
    for (NSDictionary *row in batch.snapshot[@"rows"]) CKRequire([row[@"state"] isEqual:@"timedOut"] && [row[@"saveState"] isEqual:@"succeeded"],"timeout remains a saved unknown response cause");
    CKReleased(first);CKRequire([batch startWithTimeout:2],"completed round can restart");NSArray *second=CKClients(batch);
    for (NSDictionary *row in batch.snapshot[@"rows"]) CKRequire([row[@"state"] isEqual:@"pending"] && [row[@"saveState"] isEqual:@"notAttempted"],"new round does not save unfinished records");
    [batch cancel];CKReleased(second);CKRequire(!batch.running && [batch.snapshot[@"completed"] isEqual:@5],"cancel closes whole batch");
    for (NSDictionary *row in batch.snapshot[@"rows"]) CKRequire([row[@"state"] isEqual:@"cancelled"] && [row[@"saveState"] isEqual:@"succeeded"],"cancelled result saved once");
}
static void CKSaveRetry(NSString *folder) {
    NSString *status=[folder stringByAppendingPathComponent:@"MissingStatus"];
    AxsCacheKeeperHostPreflight *batch=[[AxsCacheKeeperHostPreflight alloc] initWithStatusDirectory:status panelVersion:@"0.7.2-215.1"];
    CKRequire([batch startWithTimeout:.01],"missing directory does not suppress observation");NSArray *clients=CKClients(batch);
    [NSThread sleepForTimeInterval:.03];[batch poll];NSDictionary *before=batch.snapshot;
    CKRequire(![NSFileManager.defaultManager fileExistsAtPath:status],"preflight never creates status directories");
    for (NSDictionary *row in before[@"rows"]) CKRequire([row[@"saveState"] isEqual:@"failed"] && [row[@"saveErrorCode"] integerValue]!=0 && row[@"result"],"save failure preserves terminal result and exact error");
    CKRequire([NSFileManager.defaultManager createDirectoryAtPath:status withIntermediateDirectories:YES attributes:nil error:NULL],"external fixture restores status directory");
    [batch poll];for (NSDictionary *row in batch.snapshot[@"rows"]) CKRequire([row[@"saveState"] isEqual:@"failed"],"poll never silently retries a failed write");
    [batch retrySaving];NSUInteger index=0;
    for (NSDictionary *row in batch.snapshot[@"rows"]) {
        CKRequire([row[@"saveState"] isEqual:@"succeeded"] && [row[@"result"] isEqual:before[@"rows"][index++][@"result"]],"explicit save retry preserves the same terminal response");
    }
    CKRequire([CKClients(batch) isEqual:clients],"save retry never constructs or sends another client request");CKReleased(clients);
}
static void CKBeginFailure(NSString *folder) {
    NSArray *servers=CKServers(folder);CKFailedBundle=axs_cachekeeper_host_preflight_targets()[1][@"bundle"];
    AxsCacheKeeperHostPreflight *batch=[[AxsCacheKeeperHostPreflight alloc] initWithStatusDirectory:CKStatus(folder) panelVersion:@"0.7.2-215.1"];
    CKRequire([batch startWithTimeout:2],"mixed start failure creates terminal per-app result");CKFailedBundle=nil;CKWait(batch);
    NSUInteger index=0;for (NSDictionary *row in batch.snapshot[@"rows"]) CKRequire([row[@"state"] isEqual:(index++==1 ? @"transportError" : @"observed")],"one failed begin does not stop remaining apps");
    CKReleased(CKClients(batch));for (AxsCacheKeeperHostEvidenceServer *server in servers) [server axs_cachekeeper_invalidate];
}
int main(int argc,char **argv) {@autoreleasepool {
    if(argc!=3)return 2;NSString *mode=@(argv[1]),*folder=@(argv[2]);
    if([mode isEqual:@"observed"])CKObserved(folder);
    else if([mode isEqual:@"timeoutCancel"])CKTimeoutCancel(folder);
    else if([mode isEqual:@"saveRetry"])CKSaveRetry(folder);
    else if([mode isEqual:@"beginFailure"])CKBeginFailure(folder);else return 2;
    puts("PASS: host preflight real client batch");return 0;
}}
