#import <Foundation/Foundation.h>
#import "../AxsCacheKeeperGurdCache.h"
#include <unistd.h>
#include <sys/stat.h>
#include <errno.h>
static void check(BOOL ok,NSString *message) {if(!ok) {fprintf(stderr,"FAIL: gurd: %s\n",message.UTF8String);exit(1);}}
@interface AxsCacheKeeperGurdFixtureSource : NSObject <AxsCacheKeeperGurdHostSource>
@property(nonatomic,copy) NSString *root;
@property(nonatomic) NSUInteger prepared,submitted;
@property(nonatomic,copy) void (^duringPrepare)(void);
@property(nonatomic,copy) void (^duringSubmit)(void);
@property(nonatomic,copy) void (^duringAuthorizationValidation)(void);
@property(nonatomic) BOOL authorizing;
@end
@implementation AxsCacheKeeperGurdFixtureSource
- (NSDictionary *)prepareWithContext:(NSDictionary *)context reason:(NSString **)reason {
 (void)context;(void)reason;_prepared++;if(_duringPrepare) _duringPrepare();
 return axs_cachekeeper_gurd_bind_root(_root,context[@"home"],context[@"installation"],reason);
}
- (NSString *)validateBinding:(NSDictionary *)binding context:(NSDictionary *)context {
 if(_authorizing && _duringAuthorizationValidation) _duringAuthorizationValidation();
 return axs_cachekeeper_gurd_binding_reason(binding,context[@"home"],context[@"installation"]);
}
- (BOOL)submitBinding:(NSDictionary *)binding context:(NSDictionary *)context authorization:(BOOL (^)(void))authorization reason:(NSString **)reason {
 (void)binding;(void)context;(void)reason;_authorizing=YES;BOOL allowed=authorization();_authorizing=NO;if(!allowed) return NO;_submitted++;if(_duringSubmit) _duringSubmit();return YES;
}
@end
static void waitFor(BOOL (^condition)(void)) {
 NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+12;
 while(!condition() && NSProcessInfo.processInfo.systemUptime<deadline) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
 check(condition(),@"bounded async operation finishes");
}
int main(int argc,const char *argv[]) {@autoreleasepool {
 check(argc==2,@"temporary fixture argument");NSString *home=[NSString stringWithUTF8String:argv[1]];
 NSString *root=[home stringByAppendingPathComponent:@"Library/Application Support/gurd_cache"];
 [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL];
 NSString *file=[root stringByAppendingPathComponent:@"asset"];[[NSMutableData dataWithLength:16384] writeToFile:file atomically:YES];
 __block NSDictionary *context=@{@"valid":@YES,@"appState":@{@"enabled":@YES,@"mode":@"prevent",@"autoDiscover":@YES},@"selected":@[],@"installation":@"verified-fixture",@"home":home,@"bundle":@"com.ss.iphone.ugc.Aweme",@"version":@"41.2.0",@"build":@"412021",@"configuration":@1,@"reportWritable":@YES};
 __block NSUInteger ended=0,providerCalls=0;
 __block BOOL taskGranted=NO;
 __block void (^oldExpiration)(void)=nil;
 __block NSDictionary *published=nil;
 AxsCacheKeeperGurdFixtureSource *source=[AxsCacheKeeperGurdFixtureSource new];source.root=root;
 AxsCacheKeeperGurdCache *cache=[[AxsCacheKeeperGurdCache alloc] initWithContextProvider:^{check(!NSThread.isMainThread && taskGranted,@"provider IO runs off main after platform task grant");providerCalls++;return context;} source:source beginTask:^NSUInteger(void (^expire)(void)) {if(!oldExpiration) oldExpiration=[expire copy];taskGranted=YES;return 1;} endTask:^(NSUInteger task) {check(task==1,@"exact task token ended");ended++;} observer:^(NSDictionary *receipt) {published=receipt;}];
 BOOL (^eventFinished)(NSUInteger)=^BOOL(NSUInteger event) {NSDictionary *last=[published[@"operations"] lastObject];return ended==event && [last[@"event"] unsignedIntegerValue]==event && [@[@"observed",@"skipped",@"cancelled",@"interruptedAfterSubmission"] containsObject:last[@"phase"]];};
 source.duringSubmit=^{check([cache.receipt[@"restriction"] isEqual:@"unsupported"],@"receipt callback may read snapshot on engine queue");unlink(file.fileSystemRepresentation);};
 [cache didEnterBackground];waitFor(^BOOL {return eventFinished(1);});
 check(source.submitted==1,@"verified host boundary submits once");
 NSDictionary *receipt=cache.receipt,*operation=[receipt[@"operations"] lastObject];
 check([operation[@"submission"] isEqual:@"submitted"] && [operation[@"hostCompletion"] isEqual:@"notProvided"],@"submission never invents host completion");
 check([operation[@"observation"] isEqual:@"reduced"] && [operation[@"logicalDecrease"] unsignedIntegerValue]==16384,@"real file logical decrease observed");
 check([receipt[@"restriction"] isEqual:@"unsupported"],@"Gurd prevent mode never reports restriction supported");
 NSDate *stamp=cache.receipt[@"updated"];check([stamp isEqual:cache.receipt[@"updated"]],@"reading receipt never refreshes evidence timestamp");check(providerCalls>0,@"actual provider boundary ran");
 [cache didEnterBackground];[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
 check(source.submitted==1,@"same background event never retries zero effect");
 [cache didBecomeActive];source.duringSubmit=nil;[cache didEnterBackground];oldExpiration();waitFor(^BOOL {return eventFinished(2);});
 operation=[cache.receipt[@"operations"] lastObject];check([operation[@"observation"] isEqual:@"unchanged"] && source.submitted==2,@"submitted zero effect stays unchanged");
 [cache refreshForConfiguration:1];[cache refreshForConfiguration:0];
 [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
 check(source.submitted==2 && [cache.receipt[@"operations"] count]==2,@"same or delayed old configuration notification cannot retry a background event");
 [cache didBecomeActive];NSMutableDictionary *excluded=[context mutableCopy];excluded[@"appState"]=@{@"enabled":@YES,@"autoDiscover":@YES,@"excludedPaths":@[@"Library/Application Support/gurd_cache/kept"]};context=excluded;
 [cache didEnterBackground];waitFor(^BOOL {return eventFinished(3);});check(source.submitted==2,@"overlapping descendant exclusion blocks whole host call");
 check(axs_cachekeeper_gurd_receipt_projection(cache.receipt)!=nil,@"actual receipt accepts strict projection");
 NSMutableDictionary *bad=[cache.receipt mutableCopy];bad[@"rawPath"]=root;check(!axs_cachekeeper_gurd_receipt_projection(bad),@"strict projection rejects paths");

 [cache didBecomeActive];NSMutableDictionary *allowed=[context mutableCopy];allowed[@"appState"]=@{@"enabled":@YES,@"autoDiscover":@NO};allowed[@"selected"]=@[];context=allowed;
 NSUInteger preparations=source.prepared;[cache didEnterBackground];waitFor(^BOOL {return eventFinished(4);});
 check(source.prepared==preparations && source.submitted==2,@"no discover and no selection skips getters");
 [cache didBecomeActive];allowed=[context mutableCopy];allowed[@"selected"]=@[@"Library/Application Support/gurd_cache"];context=allowed;
 [cache didEnterBackground];waitFor(^BOOL {return eventFinished(5);});check(source.submitted==3,@"explicit actual private root enables host action");
 [cache didBecomeActive];allowed=[context mutableCopy];allowed[@"reportWritable"]=@NO;context=allowed;
 preparations=source.prepared;[cache didEnterBackground];waitFor(^BOOL {return eventFinished(6);});check(source.prepared==preparations && source.submitted==3,@"unwritable receipt prevents all preparation");
 [cache didBecomeActive];allowed=[context mutableCopy];allowed[@"reportWritable"]=@YES;context=allowed;
 __weak AxsCacheKeeperGurdCache *weakCache=cache;
 source.duringPrepare=^{[weakCache expireBackgroundTime];};[cache didEnterBackground];waitFor(^BOOL {return eventFinished(7);});
 check(source.submitted==3 && [[[cache.receipt[@"operations"] lastObject][@"submission"] description] isEqual:@"notSubmitted"],@"late preparation after expiry never submits");
 [cache didBecomeActive];source.duringPrepare=^{dispatch_sync(dispatch_get_main_queue(),^{[weakCache didBecomeActive];});};
 [cache didEnterBackground];waitFor(^BOOL {return eventFinished(8);});check(source.submitted==3,@"foreground during preparation revokes host submission");
 source.duringPrepare=^{NSMutableDictionary *changed=[context mutableCopy];changed[@"configuration"]=@2;context=changed;};
 [cache didEnterBackground];waitFor(^BOOL {return eventFinished(9);});check(source.submitted==3,@"provider config change after prepare prevents submission without notification");
 [cache didBecomeActive];source.duringPrepare=nil;[[NSMutableData dataWithLength:32] writeToFile:file atomically:YES];
 check(symlink("asset",[root stringByAppendingPathComponent:@"link"].fileSystemRepresentation)==0,@"actual descendant symlink fixture created");
 [cache didEnterBackground];waitFor(^BOOL {return eventFinished(10);});operation=[cache.receipt[@"operations"] lastObject];
 check(source.submitted==3 && [operation[@"before"][@"state"] isEqual:@"linkEncountered"],@"real descendant symlink fails sample and blocks call");
 unlink([root stringByAppendingPathComponent:@"link"].fileSystemRepresentation);[cache didBecomeActive];
 [cache axs_cachekeeper_setSampleEntryLimit:0 seconds:4];[cache didEnterBackground];waitFor(^BOOL {return eventFinished(11);});operation=[cache.receipt[@"operations"] lastObject];
 check(source.submitted==3 && [operation[@"before"][@"state"] isEqual:@"entryLimit"],@"actual cursor entry budget is visible and cannot authorize");
 [cache didBecomeActive];[cache axs_cachekeeper_setSampleEntryLimit:200000 seconds:0];[cache didEnterBackground];waitFor(^BOOL {return eventFinished(12);});
 operation=[cache.receipt[@"operations"] lastObject];check([operation[@"before"][@"state"] isEqual:@"timeLimit"] && source.submitted==3,@"actual sampler time budget is visible");
 [cache didBecomeActive];[cache axs_cachekeeper_setSampleEntryLimit:200000 seconds:4];
 source.duringSubmit=^{[weakCache expireBackgroundTime];};[cache didEnterBackground];waitFor(^BOOL {return eventFinished(13);});operation=[cache.receipt[@"operations"] lastObject];
 check(source.submitted==4 && [operation[@"phase"] isEqual:@"interruptedAfterSubmission"] && [operation[@"submission"] isEqual:@"submitted"],@"post submission expiry never lies about cancellation");
 [cache didBecomeActive];source.duringSubmit=nil;
 __block NSUInteger synchronousEnded=0;
 AxsCacheKeeperGurdCache *sync=[[AxsCacheKeeperGurdCache alloc] initWithContextProvider:^{return context;} source:source beginTask:^NSUInteger(void (^expiration)(void)) {expiration();return 77;} endTask:^(NSUInteger token) {check(token==77,@"synchronously expired token returned to platform");synchronousEnded++;} observer:nil];
 preparations=source.prepared;[sync didEnterBackground];waitFor(^BOOL {return synchronousEnded==1;});check(source.prepared==preparations && source.submitted==4,@"synchronous expiry during begin denies preparation");
 __block NSUInteger begins=0;__block NSMutableArray *endedTokens=[NSMutableArray new];
 __block __weak AxsCacheKeeperGurdCache *weakReentry=nil;
 AxsCacheKeeperGurdCache *reentry=[[AxsCacheKeeperGurdCache alloc] initWithContextProvider:^{return context;} source:source beginTask:^NSUInteger(void (^expiration)(void)) {
  (void)expiration;NSUInteger order=++begins;if(order==1) {[weakReentry didBecomeActive];[weakReentry didEnterBackground];}return order==1 ? 200 : 101;
 } endTask:^(NSUInteger token) {[endedTokens addObject:@(token)];} observer:nil];weakReentry=reentry;
 [reentry didEnterBackground];waitFor(^BOOL {return [endedTokens containsObject:@200] && [reentry.receipt[@"state"] isEqual:@"submitted"] && [reentry.receipt[@"operations"] count]==2;});
 check([reentry.receipt[@"state"] isEqual:@"submitted"] && ![endedTokens containsObject:@101],@"old begin reentry cannot replace successor state or end its token");
 NSArray *reentryOperations=reentry.receipt[@"operations"];
 check(reentryOperations.count==2 && [reentryOperations[0][@"event"] isEqual:@1] && [reentryOperations[1][@"event"] isEqual:@2] &&
 [reentryOperations[0][@"submission"] isEqual:@"notSubmitted"] && [reentryOperations[1][@"submission"] isEqual:@"submitted"],@"reentered events retain request order and separate submission ownership");
 waitFor(^BOOL {return [endedTokens containsObject:@101];});
 check([reentry.receipt[@"state"] isEqual:@"observed"] && axs_cachekeeper_gurd_receipt_projection(reentry.receipt)!=nil,@"successor completes with strict ordered history after begin reentry");
 [[NSMutableData dataWithLength:32] writeToFile:file atomically:YES];check(chmod(file.fileSystemRepresentation,0000)==0,@"unreadable file fixture created");
 __block BOOL deniedFinished=NO;AxsCacheKeeperGurdCache *denied=[[AxsCacheKeeperGurdCache alloc] initWithContextProvider:^{return context;} source:source beginTask:^NSUInteger(void (^expiration)(void)) {(void)expiration;return 9;} endTask:^(NSUInteger token) {check(token==9,@"permission sample token returned");deniedFinished=YES;} observer:nil];
 NSUInteger beforeDenied=source.submitted;[denied didEnterBackground];waitFor(^BOOL {return deniedFinished;});NSDictionary *deniedSample=[denied.receipt[@"operations"] lastObject][@"before"];
 check([deniedSample[@"state"] isEqual:@"readError"] && [deniedSample[@"errorCode"] intValue]==EACCES && source.submitted==beforeDenied,@"real unreadable file preserves EACCES and never fabricates identity change");
 check(chmod(file.fileSystemRepresentation,0600)==0,@"unreadable fixture restored");
 __block BOOL boundaryEnded=NO;__block __weak AxsCacheKeeperGurdCache *weakBoundary=nil;
 AxsCacheKeeperGurdCache *boundary=[[AxsCacheKeeperGurdCache alloc] initWithContextProvider:^{return context;} source:source beginTask:^NSUInteger(void (^expiration)(void)) {(void)expiration;return 10;} endTask:^(NSUInteger token) {check(token==10,@"final authorization token returned");boundaryEnded=YES;} observer:nil];weakBoundary=boundary;
 source.duringAuthorizationValidation=^{[weakBoundary expireBackgroundTime];};NSUInteger beforeBoundary=source.submitted;
 [boundary didEnterBackground];waitFor(^BOOL {return boundaryEnded && [boundary.receipt[@"operations"] count]==1;});source.duringAuthorizationValidation=nil;
 check(source.submitted==beforeBoundary && [[boundary.receipt[@"operations"] lastObject][@"submission"] isEqual:@"notSubmitted"],@"expiration during final identity validation cannot enter revoked host work");
 dispatch_semaphore_t providerEntered=dispatch_semaphore_create(0),releaseProvider=dispatch_semaphore_create(0);
 __block void (^blockedExpiration)(void)=nil;__block BOOL blockedEnded=NO;__block BOOL providerBlocked=NO;
 AxsCacheKeeperGurdCache *blocked=[[AxsCacheKeeperGurdCache alloc] initWithContextProvider:^{
  providerBlocked=YES;dispatch_semaphore_signal(providerEntered);dispatch_semaphore_wait(releaseProvider,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC));return context;
 } source:source beginTask:^NSUInteger(void (^expiration)(void)) {blockedExpiration=[expiration copy];return 11;} endTask:^(NSUInteger token) {check(token==11,@"blocked provider ends only its own token");blockedEnded=YES;} observer:nil];
 [blocked didEnterBackground];check(dispatch_semaphore_wait(providerEntered,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0,@"real engine provider is blocked");
 blockedExpiration();check(providerBlocked && blockedEnded,@"expiration returns platform token immediately while provider IO is still blocked");
 dispatch_semaphore_signal(releaseProvider);waitFor(^BOOL {return [blocked.receipt[@"operations"] count]==1;});
 check(source.submitted==beforeBoundary,@"released expired provider never invokes host");
 NSString *reason=nil;NSDictionary *binding=axs_cachekeeper_gurd_bind_root(root,home,context[@"installation"],&reason);
 check(binding!=nil && reason==nil,@"actual getter root binds main container chain");
 NSString *renamed=[root stringByAppendingString:@"-old"];rename(root.fileSystemRepresentation,renamed.fileSystemRepresentation);
 [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL];
 check([axs_cachekeeper_gurd_binding_reason(binding,home,context[@"installation"]) isEqual:@"rootIdentityChanged"],@"root replacement rejected by actual fd identities");
 AxsCacheKeeperGurdCache *restored=[[AxsCacheKeeperGurdCache alloc] initWithContextProvider:^{return context;} source:source beginTask:nil endTask:nil observer:nil];
 NSMutableDictionary *saved=[cache.receipt mutableCopy];NSDictionary *oldRuntime=@{@"schemaVersion":@1,@"packageVersion":@"0.7.2-200.1",@"firstObserved":@1794799900};
 saved[@"runtimeInfo"]=oldRuntime;NSMutableArray *oldOperations=[NSMutableArray new];
 for(NSDictionary *value in saved[@"operations"]) {NSMutableDictionary *item=[value mutableCopy];item[@"runtimeInfo"]=oldRuntime;[oldOperations addObject:item];}saved[@"operations"]=oldOperations;
 [restored restoreReceipt:saved];waitFor(^BOOL {return [restored.receipt[@"operations"] count]>0;});
 check([restored.receipt[@"operations"] count]==[cache.receipt[@"operations"] count],@"saved receipt operations retain truthful unknown completion");
 check([restored.receipt[@"updated"] isEqual:cache.receipt[@"updated"]],@"restore preserves saved observation timestamp");
 check([restored.receipt[@"runtimeInfo"] isEqual:oldRuntime] && [restored.receipt[@"operations"][0][@"runtimeInfo"] isEqual:oldRuntime],@"restore preserves historical receipt and operation producers across package upgrades");
 [restored didEnterBackground];waitFor(^BOOL {return [restored.receipt[@"operations"] count]==oldOperations.count+1;});
 check([restored.receipt[@"operations"][0][@"runtimeInfo"] isEqual:oldRuntime] &&
 [restored.receipt[@"operations"] lastObject][@"runtimeInfo"] &&
 ![[restored.receipt[@"operations"] lastObject][@"runtimeInfo"] isEqual:oldRuntime],@"a new publication never relabels old operation producers");
 AxsCacheKeeperGurdSource *actual=[AxsCacheKeeperGurdSource new];reason=nil;
 check([actual prepareWithContext:context reason:&reason]==nil && [reason isEqual:@"unsupportedHost"],@"actual production source rejects nonhost process before getters");
 bad=[cache.receipt mutableCopy];bad[@"background"]=@1;check(!axs_cachekeeper_gurd_receipt_projection(bad),@"strict receipt rejects numeric fake Boolean");
 check(axs_cachekeeper_gurd_receipt_projection(cache.receipt)!=nil,@"all terminal receipts retain strict field semantics");
 NSDictionary *emptySample=@{@"state":@"notRecorded",@"files":@0,@"logicalBytes":@0,@"allocatedBytes":@0,@"entries":@0,@"errorCode":@0};
 NSMutableDictionary *badSample=[emptySample mutableCopy];badSample[@"logicalBytes"]=@1;
 check(!axs_cachekeeper_gurd_sample_projection(badSample),@"unrecorded sample cannot invent counters");
 badSample=[emptySample mutableCopy];badSample[@"state"]=@"complete";badSample[@"errorCode"]=@13;
 check(!axs_cachekeeper_gurd_sample_projection(badSample),@"complete sample cannot hide a read error");
 badSample=[emptySample mutableCopy];badSample[@"state"]=@"complete";badSample[@"files"]=@1;
 check(!axs_cachekeeper_gurd_sample_projection(badSample),@"file count cannot exceed observed entries");
 NSDictionary *legacy=@{@"event":@1,@"runtimeInfo":oldRuntime,@"configuration":@0,@"phase":@"legacyUnknown",@"reason":@"notRecorded",@"submission":@"notRecorded",@"hostCompletion":@"notRecorded",@"observation":@"notRecorded",@"before":emptySample,@"after":emptySample,@"logicalDecrease":@0,@"allocatedDecrease":@0,@"physicalUniqueReclaimed":@"notMeasured"};
 NSMutableDictionary *legacyReceipt=[cache.receipt mutableCopy];legacyReceipt[@"operations"]=@[legacy];
 AxsCacheKeeperGurdCache *old=[[AxsCacheKeeperGurdCache alloc] initWithContextProvider:^{return context;} source:source beginTask:nil endTask:nil observer:nil];
 [old restoreReceipt:legacyReceipt];waitFor(^BOOL {return [old.receipt[@"operations"] count]==1;});
 check([old.receipt[@"operations"][0][@"submission"] isEqual:@"notRecorded"] && [old.receipt[@"operations"][0][@"hostCompletion"] isEqual:@"notRecorded"],@"old unknown receipt fields stay unknown");
 NSMutableDictionary *contradiction=[legacy mutableCopy];contradiction[@"submission"]=@"submitted";
 check(!axs_cachekeeper_gurd_operation_projection(contradiction),@"phase and submission contradictions rejected");
 legacyReceipt[@"operations"]=@[legacy,legacy];check(!axs_cachekeeper_gurd_receipt_projection(legacyReceipt),@"duplicate operation IDs rejected");

 printf("PASS: gurd real-files submission, observation, exclusion and lifecycle\n");
}return 0;}
