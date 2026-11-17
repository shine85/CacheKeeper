#import <Foundation/Foundation.h>
#import "../AxsCacheKeeperHostEvidence.h"
#import "../AxsCacheKeeperDiagnostics.h"
#import "../AxsCacheKeeperStorageInventory.h"
#import "../AxsCacheKeeperPolicy.h"
#include <notify.h>
#include <math.h>
#include <sys/stat.h>
#include <unistd.h>
static void CKRequire(BOOL value,const char *message) { if (!value) {fprintf(stderr,"FAIL: host evidence: %s\n",message);exit(1);} }
static NSDictionary *CKInfo(NSString *version) {return @{ @"schemaVersion":@1,@"packageVersion":version,@"firstObserved":@1700000000 };}
static NSDictionary *CKSnapshot(void) {return @{ @"schemaVersion":@1,@"source":@"hostAutomatic",@"transportTrust":@"unauthenticated",@"updated":@1800000001,
    @"runtimeInfo":CKInfo(@"0.7.2-167.1"),@"existingContainerGatePassed":@YES,@"authorizationAttempted":@YES,@"sharedAccessGranted":@NO,
    @"authorizationCode":@(-1),@"configurationReadScope":@"appEnabled",@"configurationReadState":@"notPermitted",@"previousPublishState":@"notAttempted",@"previousPublishErrorCode":@0 };}
static NSDictionary *CKImage(NSString *version) {NSMutableDictionary *v=[@{@"schemaVersion":@1,@"sdk":@"SDWebImage",@"state":@"unsupported",@"reason":@"unsupportedSDK",@"observed":@0,@"eligible":@0,@"restricted":@0,@"writesBlocked":@0,@"queued":@0,@"submitted":@0,@"apiCompleted":@0,@"skipped":@0,@"pending":@0,@"updated":[NSDate dateWithTimeIntervalSince1970:1700000005],@"bytesState":@"notMeasured"} mutableCopy];if (version) v[@"runtimeInfo"]=CKInfo(version);return v;}
static NSUInteger CKReadCount,CKForbiddenCount,CKCancelCount;
static NSInteger CKRegisterFailAfter=-1;
static int CKFlipAnnounce=-1;static uint64_t CKFlipTag;static NSUInteger CKFlipAfter,CKGetCount;
NSDictionary *axs_cachekeeper_test_host_read(NSString *path,NSError **error) {CKReadCount++;return axs_cachekeeper_read_input(path,error);}
void axs_cachekeeper_test_forbidden_effect(void) {CKForbiddenCount++;}
uint32_t axs_cachekeeper_test_host_register(const char *name,int *token) {if (CKRegisterFailAfter==0) return NOTIFY_STATUS_FAILED;if (CKRegisterFailAfter>0) CKRegisterFailAfter--;return notify_register_check(name,token);}
uint32_t axs_cachekeeper_test_host_get(int token,uint64_t *word) {uint32_t status=notify_get_state(token,word);if (CKFlipAnnounce>=0 && ++CKGetCount==CKFlipAfter) notify_set_state(CKFlipAnnounce,CKFlipTag);return status;}
uint32_t axs_cachekeeper_test_host_cancel(int token) {CKCancelCount++;return notify_cancel(token);}
static NSDictionary *CKWait(AxsCacheKeeperHostEvidenceClient *client) {NSDictionary *r;do {r=[client axs_cachekeeper_poll];if ([r[@"state"] isEqual:@"pending"]) [NSThread sleepForTimeInterval:.01];} while ([r[@"state"] isEqual:@"pending"]);return r;}
static void CKChangeLogical(NSMutableArray *frames,NSUInteger index,uint64_t payload) {
    for (NSUInteger half=0;half<2;half++) {NSUInteger physical=index*2+half;uint64_t original=[frames[physical] unsignedLongLongValue];frames[physical]=@((original&0xffffffff00000000ULL)|(uint32_t)(payload>>(half*32)));}
}
static void CKProtocol(void) {
    uint64_t request=axs_cachekeeper_host_request(42,1800000000);
    CKRequire(request && !axs_cachekeeper_host_request(0,1800000000) && !axs_cachekeeper_host_request(1,NAN) && !axs_cachekeeper_host_request(1,4294967296.0) && !axs_cachekeeper_host_request(1,1.5),"request bounds");
    CKRequire(!axs_cachekeeper_host_request_fresh(request,1799999999) && !axs_cachekeeper_host_request_fresh(request,1800000301) && !axs_cachekeeper_host_request_fresh(42ULL<<32,1),"future and expired requests");
    for (NSString *v in @[@"0.7.2-166.10",@"0.7.2-166.2",@"65536.2.3-999999999999999999999999999999.1"]) CKRequire([axs_cachekeeper_host_version_state(CKInfo(v),@"0.7.2-167.1") isEqual:@"differentVersion"],"different versions never numerically truncate or imply older");
    CKRequire([axs_cachekeeper_host_version_state(nil,@"0.7.2-167.1") isEqual:@"notRecorded"],"missing version remains missing");
    CKRequire([axs_cachekeeper_host_version_state(CKInfo(@"0.7.2-167.1"),@"0.7.2-167.1") isEqual:@"currentVersion"],"complete version comparison");
    NSArray *frames=axs_cachekeeper_host_encode(CKSnapshot(),request);CKRequire(frames.count==24,"fixed complete physical frame count");
    NSDictionary *decoded=axs_cachekeeper_host_decode(frames,request,1800000002);
    CKRequire([decoded[@"runtimeInfo"][@"packageVersion"] isEqual:@"0.7.2-167.1"] && [decoded[@"authorizationCode"] intValue]==-1,"whole version and signed code survive");
    CKRequire(CFGetTypeID((__bridge CFTypeRef)decoded[@"existingContainerGatePassed"])==CFBooleanGetTypeID(),"frame boolean decodes as real CFBoolean");
    CKRequire(!axs_cachekeeper_host_decode(frames,request+1,1800000002),"wrong request rejected");
    for (NSUInteger i=0;i<24;i++) {NSMutableArray *bad=[frames mutableCopy];[bad removeObjectAtIndex:i];CKRequire(!axs_cachekeeper_host_decode(bad,request,1800000002),"every missing frame rejected");}
    for (NSArray *change in @[@[@1,@0],@[@11,@1],@[@3,@(1ULL<<63)],@[@3,@(7ULL<<8)],@[@5,@(UINT64_MAX)],@[@6,@0]]) {NSMutableArray *bad=[frames mutableCopy];CKChangeLogical(bad,[change[0] unsignedIntegerValue],[change[1] unsignedLongLongValue]);CKRequire(!axs_cachekeeper_host_decode(bad,request,1800000002),"malformed header padding flags timestamp version rejected");}
    for (NSUInteger i=0;i<24;i++) {NSMutableArray *bad=[frames mutableCopy];bad[i]=@0;CKRequire(!axs_cachekeeper_host_decode(bad,request,1800000002),"default zero frame rejected before payload interpretation");bad=[frames mutableCopy];bad[i]=@([frames[i] unsignedLongLongValue]^(1ULL<<32));CKRequire(!axs_cachekeeper_host_decode(bad,request,1800000002),"physical marker and index strictly validated");}
    for (NSNumber *code in @[@(INT32_MIN),@0,@(INT32_MAX)]) {NSMutableDictionary *extreme=[CKSnapshot() mutableCopy];extreme[@"authorizationCode"]=code;extreme[@"previousPublishState"]=@"failed";extreme[@"previousPublishErrorCode"]=code;NSDictionary *round=axs_cachekeeper_host_decode(axs_cachekeeper_host_encode(extreme,request),request,1800000002);CKRequire([round[@"authorizationCode"] isEqual:code] && [round[@"previousPublishErrorCode"] isEqual:code],"signed extreme and zero error payloads remain lossless");}
    NSMutableDictionary *unattempted=[CKSnapshot() mutableCopy];unattempted[@"authorizationAttempted"]=@NO;unattempted[@"authorizationCode"]=@0;CKRequire(axs_cachekeeper_host_decode(axs_cachekeeper_host_encode(unattempted,request),request,1800000002)!=nil,"unattempted authorization with zero errors and short version padding remains valid");
    NSMutableDictionary *s=[CKSnapshot() mutableCopy];NSString *v=[@"1.2.3-" stringByAppendingString:[@"" stringByPaddingToLength:40 withString:@"9" startingAtIndex:0]];v=[v stringByAppendingString:@".1"];s[@"runtimeInfo"]=CKInfo(v);
    CKRequire(v.length==48 && [axs_cachekeeper_host_decode(axs_cachekeeper_host_encode(s,request),request,1800000002)[@"runtimeInfo"][@"packageVersion"] isEqual:v],"48 ASCII byte version round trip");
    for (NSString *bad in @[@"1.2.3\n",@"1.2.3-1.2x",@"１.2.3",@"/private/path",[v stringByAppendingString:@"1"]]) {s[@"runtimeInfo"]=CKInfo(bad);CKRequire(!axs_cachekeeper_host_encode(s,request),"bad full versions rejected");}
    s=[CKSnapshot() mutableCopy];NSMutableDictionary *info=[s[@"runtimeInfo"] mutableCopy];info[@"secret"]=@"private";s[@"runtimeInfo"]=info;CKRequire(!axs_cachekeeper_host_projection(s),"nested unknown runtime fields rejected");
    s=[CKSnapshot() mutableCopy];s[@"secretPath"]=@"/private/path";CKRequire(!axs_cachekeeper_host_projection(s)[@"secretPath"],"unknown top-level fields stripped");
    puts("PASS: strict host protocol, malformed frames, whole versions and privacy");
}
static void CKFiles(NSString *folder,NSString *bundle) {
    NSFileManager *fm=NSFileManager.defaultManager;[fm createDirectoryAtPath:[folder stringByAppendingPathComponent:@"Status"] withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *config=[folder stringByAppendingPathComponent:@"appEnabled.plist"],*resource=[folder stringByAppendingPathComponent:@"resource.bin"];
    [@{bundle:@{@"enabled":@NO}} writeToFile:config atomically:YES];[@"user resource" writeToFile:resource atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NSData *before=[NSData dataWithContentsOfFile:config],*resourceBefore=[NSData dataWithContentsOfFile:resource];
    AxsCacheKeeperHostEvidenceServer *server=[[AxsCacheKeeperHostEvidenceServer alloc] initWithBundle:bundle folder:folder runtimeInfo:CKInfo(@"0.7.2-167.1")];
    [server axs_cachekeeper_observeContainer:YES authorizationAttempted:YES authorizationCode:0 sharedAccess:YES];NSDictionary *snapshot=[server axs_cachekeeper_snapshot];
    CKRequire([snapshot[@"configurationReadState"] isEqual:@"readable"] && [snapshot[@"previousPublishState"] isEqual:@"succeeded"],"disabled APP reads and real file write succeeds");
    NSString *host=[folder stringByAppendingPathComponent:[NSString stringWithFormat:@"Status/%@.host.plist",bundle]];
    CKRequire([[NSDictionary dictionaryWithContentsOfFile:host][@"previousPublishState"] isEqual:@"notAttempted"],"file cannot claim its own write success");
    AxsCacheKeeperHostEvidenceClient *client=[[AxsCacheKeeperHostEvidenceClient alloc] initWithBundle:bundle];CKRequire([client axs_cachekeeper_beginWithTimeout:2],"disabled APP request begins");CKRequire([CKWait(client)[@"state"] isEqual:@"observed"],"production callback answers disabled APP");
    NSUInteger reads=CKReadCount;NSData *frozen=[NSData dataWithContentsOfFile:host];NSDictionary *memory=[server axs_cachekeeper_snapshot];
    for (NSUInteger i=0;i<5;i++) notify_post(axs_cachekeeper_host_name(bundle,0,0,0).UTF8String);
    [NSThread sleepForTimeInterval:.15];NSDictionary *after=[server axs_cachekeeper_snapshot];
    CKRequire(CKReadCount==reads && [memory isEqual:after] && [[NSData dataWithContentsOfFile:host] isEqual:frozen],"duplicate request reannounces frozen snapshot without configuration reads or publication");
    CKRequire(!CKForbiddenCount,"readonly callback never executes policy authorization or cache side effects");
    CKRequire([[NSData dataWithContentsOfFile:config] isEqual:before] && [[NSData dataWithContentsOfFile:resource] isEqual:resourceBefore],"business configuration and resource bytes unchanged");
    [server axs_cachekeeper_invalidate];
    // Real write failure: destination is a directory, then remove the obstruction and retry.
    [fm removeItemAtPath:host error:NULL];[fm createDirectoryAtPath:host withIntermediateDirectories:NO attributes:nil error:NULL];
    server=[[AxsCacheKeeperHostEvidenceServer alloc] initWithBundle:bundle folder:folder runtimeInfo:CKInfo(@"0.7.2-167.1")];
    [server axs_cachekeeper_observeContainer:YES authorizationAttempted:YES authorizationCode:0 sharedAccess:YES];CKRequire([[[server axs_cachekeeper_snapshot] objectForKey:@"previousPublishState"] isEqual:@"failed"],"actual atomic replacement failure reported");
    [fm removeItemAtPath:host error:NULL];[server axs_cachekeeper_observeContainer:YES authorizationAttempted:YES authorizationCode:0 sharedAccess:YES];CKRequire([[[server axs_cachekeeper_snapshot] objectForKey:@"previousPublishState"] isEqual:@"succeeded"],"next legal event retries failed publication");
    CKRequire([[NSDictionary dictionaryWithContentsOfFile:host][@"previousPublishState"] isEqual:@"failed"],"next saved event retains previous failed attempt");
    if (geteuid()!=0) {
        CKRequire(chmod(config.fileSystemRepresentation,0000)==0,"actual permission fixture changed");
        [server axs_cachekeeper_observeContainer:YES authorizationAttempted:YES authorizationCode:0 sharedAccess:YES];
        CKRequire([[[server axs_cachekeeper_snapshot] objectForKey:@"configurationReadState"] isEqual:@"unreadable"],"actual EACCES configuration distinct from invalid and missing");
        CKRequire(chmod(config.fileSystemRepresentation,0600)==0,"permission fixture restored");
    } else puts("UNSUPPORTED: EACCES fixture cannot deny a root test process");
    [@"bad plist" writeToFile:config atomically:YES encoding:NSUTF8StringEncoding error:NULL];[server axs_cachekeeper_observeContainer:YES authorizationAttempted:YES authorizationCode:0 sharedAccess:YES];CKRequire([[[server axs_cachekeeper_snapshot] objectForKey:@"configurationReadState"] isEqual:@"invalid"],"real malformed configuration distinguished");
    [fm removeItemAtPath:config error:NULL];[server axs_cachekeeper_observeContainer:YES authorizationAttempted:YES authorizationCode:0 sharedAccess:YES];CKRequire([[[server axs_cachekeeper_snapshot] objectForKey:@"configurationReadState"] isEqual:@"missing"],"real missing configuration distinguished");
    [fm createDirectoryAtPath:config withIntermediateDirectories:NO attributes:nil error:NULL];[server axs_cachekeeper_observeContainer:YES authorizationAttempted:YES authorizationCode:0 sharedAccess:YES];CKRequire([[[server axs_cachekeeper_snapshot] objectForKey:@"configurationReadState"] isEqual:@"invalid"],"nonfile configuration rejected");[server axs_cachekeeper_invalidate];
    NSString *missing=[folder stringByAppendingPathComponent:@"missing-status"];[fm createDirectoryAtPath:missing withIntermediateDirectories:NO attributes:nil error:NULL];
    [@{bundle:@{@"enabled":@NO}} writeToFile:[missing stringByAppendingPathComponent:@"appEnabled.plist"] atomically:YES];
    server=[[AxsCacheKeeperHostEvidenceServer alloc] initWithBundle:bundle folder:missing runtimeInfo:CKInfo(@"0.7.2-167.1")];
    [server axs_cachekeeper_observeContainer:YES authorizationAttempted:YES authorizationCode:0 sharedAccess:YES];
    CKRequire([[[server axs_cachekeeper_snapshot] objectForKey:@"previousPublishState"] isEqual:@"failed"],"actual missing Status publication fails without creating shared directories");[server axs_cachekeeper_invalidate];
    puts("PASS: real readonly callback, unchanged business files, real atomic failure and retry");
}
static void CKExport(NSString *folder,NSString *bundle) {
    NSFileManager *fm=NSFileManager.defaultManager;[fm createDirectoryAtPath:[folder stringByAppendingPathComponent:@"Status"] withIntermediateDirectories:YES attributes:nil error:NULL];
    [@{bundle:@{@"enabled":@NO}} writeToFile:[folder stringByAppendingPathComponent:@"appEnabled.plist"] atomically:YES];
    NSString *(^path)(NSString *)=^NSString *(NSString *type){return [folder stringByAppendingPathComponent:[NSString stringWithFormat:@"Status/%@.%@.plist",bundle,type]];};
    [CKSnapshot() writeToFile:path(@"host") atomically:YES];[CKImage(@"0.7.2-154.1") writeToFile:path(@"imagecache") atomically:YES];
    NSMutableDictionary *network=[@{@"pid":@99,@"updated":[NSDate dateWithTimeIntervalSince1970:1700000007],@"prevent":@NO,@"applied":@YES,@"message":@"private content",@"runtimeInfo":CKInfo(@"0.7.2-154.1")} mutableCopy];[network writeToFile:path(@"network") atomically:YES];
    AxsCacheKeeperDiagnostics *diagnostics=[[AxsCacheKeeperDiagnostics alloc] initWithFolder:folder];
    NSDictionary *(^report)(void)=^NSDictionary *{return [diagnostics reportWithApps:@[@{@"id":bundle}] environment:@{@"pluginVersion":@"0.7.2-167.1"}];};
    NSDictionary *r=report(),*app=[r[@"apps"] firstObject];
    CKRequire([app[@"hostAutomatic"][@"data"][@"runtimeInfo"][@"packageVersion"] isEqual:@"0.7.2-167.1"],"real saved host projects into report");
    CKRequire([app[@"capabilities"][@"network"][@"runtimeVersionState"] isEqual:@"differentVersion"] && [app[@"capabilities"][@"image"][@"runtimeVersionState"] isEqual:@"differentVersion"],"new host never upgrades old network or SDK receipt");
    CKRequire([app[@"capabilities"][@"image"][@"reason"] isEqual:@"unsupportedSDK"] && [app[@"capabilities"][@"image"][@"sourceUpdated"] doubleValue]==1700000005,"SDK rejection and original timestamp preserved");
    NSData *json=[NSJSONSerialization dataWithJSONObject:r options:0 error:NULL];NSString *text=[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    CKRequire(json && ![text containsString:@"private content"] && ![text containsString:folder] && ![text containsString:@"\"pid\""] && ![text containsString:@"nonce"],"actual JSON drops free text paths process IDs and nonce");
    NSMutableDictionary *contract=[CKImage(@"0.7.2-154.1") mutableCopy];contract[@"state"]=@"blocked";contract[@"reason"]=@"installationUnverified";contract[@"installationCheck"]=@{@"state":@"failed",@"errorCode":@2,@"detail":@{@"target":@"root",@"operation":@"openIdentity",@"errno":@0}};[contract writeToFile:path(@"imagecache") atomically:YES];
    app=[report()[@"apps"] firstObject];CKRequire([app[@"capabilities"][@"image"][@"reason"] isEqual:@"installationUnverified"] && [app[@"capabilities"][@"image"][@"installationCheck"][@"state"] isEqual:@"failed"],"contract refusal remains separate from missing SDK and host version");
    [contract removeObjectForKey:@"installationCheck"];contract[@"state"]=@"apiCompleted";contract[@"reason"]=@"none";for (NSString *key in @[@"observed",@"eligible",@"queued",@"submitted",@"apiCompleted"]) contract[key]=@1;[contract writeToFile:path(@"imagecache") atomically:YES];
    NSDictionary *web=@{@"schemaVersion":@1,@"requested":@YES,@"timedOut":@NO,@"state":@"completed",@"reason":@"none",@"persistentStores":@1,@"nonPersistentStores":@0,@"submitted":@1,@"completed":@1,@"pending":@0,@"updated":[NSDate dateWithTimeIntervalSince1970:1700000008],@"bytesState":@"notMeasured",@"runtimeInfo":CKInfo(@"0.7.2-167.1")};[web writeToFile:path(@"webkit") atomically:YES];
    app=[report()[@"apps"] firstObject];CKRequire([app[@"capabilities"][@"image"][@"actionState"] isEqual:@"apiCompleted"] && [app[@"capabilities"][@"webKit"][@"actionState"] isEqual:@"completed"] && [app[@"capabilities"][@"webKit"][@"effectVerification"] isEqual:@"notVerified"] && [app[@"capabilities"][@"image"][@"resourceContract"] isEqual:@"notEstablishedByReceipt"],"API completion does not claim measured effect or private resource authorization");
    [network removeObjectForKey:@"runtimeInfo"];[network writeToFile:path(@"network") atomically:YES];app=[report()[@"apps"] firstObject];CKRequire([app[@"network"][@"state"] isEqual:@"available"] && [app[@"capabilities"][@"network"][@"runtimeVersionState"] isEqual:@"notRecorded"],"old network format readable without fabricated version");
    [CKImage(@"0.7.2-167.1") writeToFile:path(@"imagecache") atomically:YES];NSMutableDictionary *old=[CKSnapshot() mutableCopy];old[@"runtimeInfo"]=CKInfo(@"0.7.2-154.1");[old writeToFile:path(@"host") atomically:YES];app=[report()[@"apps"] firstObject];CKRequire([app[@"capabilities"][@"hostAutomatic"][@"runtimeVersionState"] isEqual:@"differentVersion"] && [app[@"capabilities"][@"image"][@"runtimeVersionState"] isEqual:@"currentVersion"],"old host and current SDK stay independent");
    [fm removeItemAtPath:path(@"host") error:NULL];app=[report()[@"apps"] firstObject];CKRequire([app[@"hostAutomatic"][@"state"] isEqual:@"missing"],"missing host remains missing");
    [@"damaged" writeToFile:path(@"host") atomically:YES encoding:NSUTF8StringEncoding error:NULL];app=[report()[@"apps"] firstObject];CKRequire([app[@"hostAutomatic"][@"state"] isEqual:@"invalid"],"damaged host distinct");
    [fm removeItemAtPath:path(@"host") error:NULL];[fm createDirectoryAtPath:path(@"host") withIntermediateDirectories:NO attributes:nil error:NULL];app=[report()[@"apps"] firstObject];CKRequire([app[@"hostAutomatic"][@"state"] isEqual:@"unreadable"],"unreadable host distinct");
    NSDictionary *legacy=axs_cachekeeper_network_projection(@{@"prevent":@YES,@"applied":@NO});CKRequire(legacy && [legacy[@"updatedState"] isEqual:@"notRecorded"] && !legacy[@"runtimeInfo"],"old unversioned undated network fields retained");
    for (id bad in @[@"/private/scansecret",@{@"packageVersion":@"/private/scansecret",@"unknown":@"private-content"}]) {
        NSDictionary *cap=axs_cachekeeper_capabilities(@{@"standardDirectories":@{@"state":@"available",@"data":@{@"updated":NSDate.date,@"complete":@NO,@"runtimeInfo":bad,@"unknownPath":@"/private/scansecret"}}},@"0.7.2-167.1");
        CKRequire([cap[@"standardDirectories"][@"runtimeVersionState"] isEqual:@"invalid"] && !cap[@"standardDirectories"][@"runtimeInfo"],"standard scan invalid runtime remains invalid without exporting raw data");
        NSData *bytes=[NSJSONSerialization dataWithJSONObject:cap options:0 error:NULL];NSString *rendered=[[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];CKRequire(bytes && ![rendered containsString:@"scansecret"] && ![rendered containsString:@"private-content"],"malicious standard runtime and unknown paths never escape");
    }
    NSDictionary *badScan=axs_cachekeeper_capabilities(@{@"standardDirectories":@{@"state":@"available",@"data":@{@"scanProgress":@{@"state":@"running",@"secret":@"private"}}}},@"0.7.2-167.1");CKRequire([badScan[@"standardDirectories"][@"sourceState"] isEqual:@"invalid"] && !badScan[@"standardDirectories"][@"scanProgress"],"invalid nested scan frame remains invalid");
    puts("PASS: real Diagnostics files to JSON, separate version axes, old format and failures");
}
static NSArray *CKPublish(NSString *bundle,uint64_t request,uint64_t tag,NSArray *frames,BOOL announce) {
    NSMutableArray *tokens=[NSMutableArray new];
    for (NSUInteger i=0;i<frames.count;i++) {int token=-1;CKRequire(notify_register_check(axs_cachekeeper_host_name(bundle,request,tag,(NSInteger)i).UTF8String,&token)==NOTIFY_STATUS_OK,"adversarial real frame registration");[tokens addObject:@(token)];CKRequire(notify_set_state(token,[frames[i] unsignedLongLongValue])==NOTIFY_STATUS_OK,"real frame write");}
    int token=-1;CKRequire(notify_register_check(axs_cachekeeper_host_name(bundle,request,0,0).UTF8String,&token)==NOTIFY_STATUS_OK,"announce registration");[tokens addObject:@(token)];if (announce) notify_set_state(token,tag);return tokens;
}
static void CKMissingPhysical(NSString *bundle) {
    for (NSUInteger omitted=0;omitted<24;omitted++) {
        NSString *target=[bundle stringByAppendingFormat:@".%lu",(unsigned long)omitted];
        AxsCacheKeeperHostEvidenceClient *client=[[AxsCacheKeeperHostEvidenceClient alloc] initWithBundle:target];CKRequire([client axs_cachekeeper_beginWithTimeout:1],"missing-physical request posted");
        int token=-1;notify_register_check(axs_cachekeeper_host_name(target,0,0,0).UTF8String,&token);uint64_t request=0;notify_get_state(token,&request);notify_cancel(token);
        NSMutableDictionary *snapshot=[CKSnapshot() mutableCopy];snapshot[@"updated"]=@(NSDate.date.timeIntervalSince1970);snapshot[@"authorizationCode"]=@0;
        NSArray *frames=axs_cachekeeper_host_encode(snapshot,request);NSMutableArray *tokens=[NSMutableArray new];
        for (NSUInteger i=0;i<frames.count;i++) {if (i==omitted) continue;token=-1;CKRequire(notify_register_check(axs_cachekeeper_host_name(target,request,777,(NSInteger)i).UTF8String,&token)==NOTIFY_STATUS_OK,"real physical frame register");[tokens addObject:@(token)];CKRequire(notify_set_state(token,[frames[i] unsignedLongLongValue])==NOTIFY_STATUS_OK,"real physical frame publication");}
        token=-1;notify_register_check(axs_cachekeeper_host_name(target,request,0,0).UTF8String,&token);[tokens addObject:@(token)];notify_set_state(token,777);
        NSDictionary *result=[client axs_cachekeeper_poll];CKRequire([result[@"state"] isEqual:@"invalidResponse"],"every physical frame must have actually been published");CKRequire(!client.axs_cachekeeper_activeTokenCount,"missing physical frame releases client tokens");for (NSNumber *registered in tokens) notify_cancel(registered.intValue);
    }
    puts("PASS: real notify individually omits every required physical frame including zero payloads");
}
static void CKServerFailures(NSString *folder,NSString *bundle) {
    AxsCacheKeeperHostEvidenceServer *server=[[AxsCacheKeeperHostEvidenceServer alloc] initWithBundle:bundle folder:folder runtimeInfo:CKInfo(@"0.7.2-167.1")];
    AxsCacheKeeperHostEvidenceClient *client=[[AxsCacheKeeperHostEvidenceClient alloc] initWithBundle:bundle];CKRequire([client axs_cachekeeper_beginWithTimeout:2],"server-failure request posted before context");
    [NSThread sleepForTimeInterval:.05];CKRegisterFailAfter=2;NSUInteger cancelled=CKCancelCount;
    [server axs_cachekeeper_observeContainer:NO authorizationAttempted:NO authorizationCode:0 sharedAccess:NO];(void)[server axs_cachekeeper_snapshot];
    CKRequire([[server valueForKey:@"axs_cachekeeper_responseTokens"] count]==0 && CKCancelCount==cancelled+2,"server midpoint registration failure cancels every staged frame");
    CKRegisterFailAfter=-1;notify_post(axs_cachekeeper_host_name(bundle,0,0,0).UTF8String);
    CKRequire([CKWait(client)[@"state"] isEqual:@"observed"],"same request can retry after incomplete publication without false success");
    cancelled=CKCancelCount;NSUInteger held=[[server valueForKey:@"axs_cachekeeper_responseTokens"] count];[server axs_cachekeeper_invalidate];CKRequire([[server valueForKey:@"axs_cachekeeper_responseTokens"] count]==0 && CKCancelCount==cancelled+held+1,"invalidate releases request and all response frames");
    CKRequire(!CKReadCount && !CKForbiddenCount && ![NSFileManager.defaultManager fileExistsAtPath:folder],"unpermitted failure and retry touch no shared files or business effects");
    puts("PASS: actual server callback partial registration failure retry and all-token release");
}
static void CKAdversarial(NSString *bundle) {
    for (NSUInteger scenario=0;scenario<6;scenario++) {
        AxsCacheKeeperHostEvidenceClient *client=[[AxsCacheKeeperHostEvidenceClient alloc] initWithBundle:bundle];CKRequire([client axs_cachekeeper_beginWithTimeout:1],"adversarial request starts");
        int requestToken=-1;notify_register_check(axs_cachekeeper_host_name(bundle,0,0,0).UTF8String,&requestToken);uint64_t request=0;notify_get_state(requestToken,&request);notify_cancel(requestToken);
        NSMutableDictionary *snapshot=[CKSnapshot() mutableCopy];snapshot[@"updated"]=@(NSDate.date.timeIntervalSince1970);NSArray *frames=axs_cachekeeper_host_encode(snapshot,request);
        NSArray *first=CKPublish(bundle,request,111,scenario==0 ? [frames subarrayWithRange:NSMakeRange(0,4)] : frames,YES),*second=nil;
        if (scenario==1) {NSMutableArray *old=[frames mutableCopy];CKChangeLogical(old,0,request+1);second=CKPublish(bundle,request,222,old,YES);}
        if (scenario==2 || scenario==3) {
            NSMutableDictionary *other=[snapshot mutableCopy];other[@"authorizationCode"]=@9;
            second=CKPublish(bundle,request,222,axs_cachekeeper_host_encode(other,request),scenario==2);
            if (scenario==3) {CKFlipAnnounce=[[first lastObject] intValue];CKFlipTag=222;CKGetCount=0;CKFlipAfter=5;}
        }
        if (scenario==5) [client setValue:@(NSProcessInfo.processInfo.systemUptime-1) forKey:@"axs_cachekeeper_deadline"];
        if (scenario==4) { [client axs_cachekeeper_cancel];CKRequire([client axs_cachekeeper_beginWithTimeout:.01],"replacement request changes association");[NSThread sleepForTimeInterval:.02]; }
        NSDictionary *result=[client axs_cachekeeper_poll];CKFlipAnnounce=-1;
        if (scenario<2) CKRequire([result[@"state"] isEqual:@"invalidResponse"],"missing frames and old request never accepted");
        else if (scenario<4) {CKRequire([result[@"state"] isEqual:@"observed"] && [result[@"data"][@"authorizationCode"] intValue]==9,"multiple hosts yield one immutable coherent frame set without post");if (scenario==3) CKRequire([result[@"multipleResponders"] boolValue],"announce change detected and retried");}
        else CKRequire([result[@"state"] isEqual:@"timedOut"],"replacement and perfectly matching late response cannot beat expiry");
        CKRequire(!client.axs_cachekeeper_activeTokenCount,"all adversarial terminal paths release client tokens");for (NSNumber *token in first) notify_cancel(token.intValue);for (NSNumber *token in second) notify_cancel(token.intValue);
    }
    puts("PASS: real notify missing frames old requests multiple hosts torn announce no-post polling and expiry");
}
int main(int argc,char **argv) { @autoreleasepool {
    NSString *mode=argc>1 ? @(argv[1]) : @"protocol";NSString *folder=argc>2 ? @(argv[2]) : @"",*bundle=argc>3 ? @(argv[3]) : @"dev.local.hosttest";
    if ([mode isEqual:@"protocol"]) {CKProtocol();return 0;}
    if ([mode isEqual:@"missingPhysical"]) {CKMissingPhysical(bundle);return 0;}
    if ([mode isEqual:@"serverFailures"]) {CKServerFailures(folder,bundle);return 0;}
    if ([mode isEqual:@"adversarial"]) {CKAdversarial(bundle);return 0;}
    if ([mode isEqual:@"files"]) {CKFiles(folder,bundle);return 0;}
    if ([mode isEqual:@"export"]) {CKExport(folder,bundle);return 0;}
    if ([mode hasPrefix:@"server"]) {
        BOOL noAttempt=[mode isEqual:@"serverNoAttempt"],gate=![mode isEqual:@"serverNoGate"];
        AxsCacheKeeperHostEvidenceServer *server=[[AxsCacheKeeperHostEvidenceServer alloc] initWithBundle:bundle folder:folder runtimeInfo:CKInfo([mode isEqual:@"serverDifferent"] ? @"0.7.2-168.1" : @"0.7.2-167.1")];
        // Deliberate gap proves requests queued before initial context cannot freeze defaults.
        [NSThread sleepForTimeInterval:.1];[server axs_cachekeeper_observeContainer:gate authorizationAttempted:!noAttempt authorizationCode:noAttempt ? 0 : ([mode isEqual:@"serverDifferent"] ? 11 : 7) sharedAccess:NO];
        (void)[server axs_cachekeeper_snapshot];puts("READY");fflush(stdout);
        NSDate *end=[NSDate dateWithTimeIntervalSinceNow:2];while (end.timeIntervalSinceNow>0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
        CKRequire(!CKReadCount && !CKForbiddenCount,"unpermitted production callback has zero config reads and business effects");[server axs_cachekeeper_invalidate];return 0;
    }
    if ([mode hasPrefix:@"client"]) {
        AxsCacheKeeperHostEvidenceClient *client=[[AxsCacheKeeperHostEvidenceClient alloc] initWithBundle:bundle];CKRequire([client axs_cachekeeper_beginWithTimeout:3],"real notify request posted");puts("READY");fflush(stdout);
        NSDictionary *r=CKWait(client);CKRequire([r[@"state"] isEqual:@"observed"],"real separate process callback responded");
        CKRequire([r[@"data"][@"configurationReadState"] isEqual:@"notPermitted"] && ![r[@"data"][@"sharedAccessGranted"] boolValue],"no permission or config access from readonly request");
        if ([mode isEqual:@"clientMulti"]) {int code=[r[@"data"][@"authorizationCode"] intValue];NSString *version=r[@"data"][@"runtimeInfo"][@"packageVersion"];CKRequire((code==7 && [version isEqual:@"0.7.2-167.1"]) || (code==11 && [version isEqual:@"0.7.2-168.1"]),"two real hosts cannot mix version and context frames");}
        else CKRequire([r[@"data"][@"authorizationCode"] intValue]==([mode isEqual:@"clientNoAttempt"] ? 0 : 7),"first response uses actual existing context");
        if ([mode isEqual:@"clientNoGate"]) CKRequire(![r[@"data"][@"existingContainerGatePassed"] boolValue],"failed container gate still responds");
        CKRequire(![NSFileManager.defaultManager fileExistsAtPath:folder] && !client.axs_cachekeeper_activeTokenCount,"no shared directory touch and completion releases tokens");puts("PASS: real two-process notify production readonly callback");return 0;
    }
    if ([mode isEqual:@"timeout"]) {
        AxsCacheKeeperHostEvidenceClient *client=[[AxsCacheKeeperHostEvidenceClient alloc] initWithBundle:bundle];CKRequire([client axs_cachekeeper_beginWithTimeout:.02],"timeout request");[NSThread sleepForTimeInterval:.03];CKRequire([[client axs_cachekeeper_poll][@"state"] isEqual:@"timedOut"] && !client.axs_cachekeeper_activeTokenCount,"deadline checked before any response and tokens released");
        CKRequire([client axs_cachekeeper_beginWithTimeout:1],"replacement request");[client axs_cachekeeper_cancel];CKRequire(!client.axs_cachekeeper_activeTokenCount && [[client axs_cachekeeper_poll][@"state"] isEqual:@"cancelled"],"cancel releases tokens");
        CKRequire([client axs_cachekeeper_beginWithTimeout:1],"wall clock consistency request");
        [client setValue:@(NSDate.date.timeIntervalSince1970-10) forKey:@"axs_cachekeeper_startEpoch"];
        CKRequire([[client axs_cachekeeper_poll][@"state"] isEqual:@"clockChanged"] && !client.axs_cachekeeper_activeTokenCount,"wall clock discontinuity cannot extend or satisfy request");
        CKRequire([client axs_cachekeeper_beginWithTimeout:1],"transport read failure request");[client setValue:@(-1) forKey:@"axs_cachekeeper_announceToken"];
        CKRequire([[client axs_cachekeeper_poll][@"state"] isEqual:@"transportError"] && !client.axs_cachekeeper_activeTokenCount,"actual invalid notify token read fails and releases registered tokens");
        for (NSInteger n=0;n<2;n++) {CKRegisterFailAfter=n;NSUInteger before=CKCancelCount;CKRequire(![client axs_cachekeeper_beginWithTimeout:1] && !client.axs_cachekeeper_activeTokenCount,"partial registration failure releases tokens");CKRequire(CKCancelCount==before+(NSUInteger)n,"exact registered tokens cancelled on failure");}CKRegisterFailAfter=-1;
        puts("PASS: expiry cancellation and mid-registration failure cleanup");return 0;
    }
    return 2;
} }
