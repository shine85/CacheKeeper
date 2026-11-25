#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "../AxsCacheKeeperGurdCache.h"
#import "../AxsCacheKeeperScanTask.h"
#include <unistd.h>
#include <sys/stat.h>
#include <errno.h>
static void check(BOOL ok,NSString *message) {if(!ok) {fprintf(stderr,"FAIL: gurd: %s\n",message.UTF8String);exit(1);}}
#if !defined(AXS_CACHEKEEPER_GURD_FIXED201_SYMLINK)
static IMP axs_cachekeeper_gurd_test_cursor_advance;
static void (^axs_cachekeeper_gurd_test_did_advance)(AxsCacheKeeperScanCursor *cursor);
static void axs_cachekeeper_gurd_test_observe_slice(id cursor,SEL selector,NSUInteger entries,NSTimeInterval seconds) {
 ((void (*)(id,SEL,NSUInteger,NSTimeInterval))axs_cachekeeper_gurd_test_cursor_advance)(cursor,selector,entries,seconds);
 // Observe on the engine queue after real IO; main-thread polling can miss a whole sample.
 if(axs_cachekeeper_gurd_test_did_advance) axs_cachekeeper_gurd_test_did_advance(cursor);
}
static void testProductionPredicateProofProjectionShape(void) {
 NSDictionary *proof=@{@"state":@"complete",@"hostBundle":@"com.ss.iphone.ugc.Aweme",@"hostVersion":@"41.2.0",
  @"hostBuild":@"412021",@"hostIdentity":@"aweme-core-window-set-v1",@"candidateSource":@"productionPredicateV1",
  @"predicateVersion":@"predicate-v1",@"rootIdentity":[@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0],
  @"candidateCount":@2,@"candidateDigest":[@"b" stringByPaddingToLength:64 withString:@"b" startingAtIndex:0],
  @"excludedCount":@1,@"exclusionDigest":[@"c" stringByPaddingToLength:64 withString:@"c" startingAtIndex:0]};
 check(axs_cachekeeper_gurd_scope_proof_projection(proof)!=nil,
  @"complete production predicate proof shape is structurally expressible");
 for(NSString *key in @[@"rootIdentity",@"candidateDigest",@"candidateCount",@"predicateVersion"]) {
  NSMutableDictionary *candidate=[proof mutableCopy];[candidate removeObjectForKey:key];
  check(axs_cachekeeper_gurd_scope_proof_projection(candidate)==nil,
   [NSString stringWithFormat:@"production proof rejects missing field %@",key]);
 }
 for(NSDictionary *change in @[@{@"candidateDigest":@"short"},@{@"exclusionDigest":@"short"},@{@"hostVersion":@"41.2.0.1"}]) {
  NSMutableDictionary *candidate=[proof mutableCopy];[candidate addEntriesFromDictionary:change];
  check(axs_cachekeeper_gurd_scope_proof_projection(candidate)==nil,
   [NSString stringWithFormat:@"production proof rejects invalid field %@",change.allKeys.firstObject]);
 }
}
#endif
@interface AxsCacheKeeperGurdFixtureSource : NSObject <AxsCacheKeeperGurdHostSource>
@property(nonatomic,copy) NSString *root;
@property(nonatomic) NSUInteger prepared,submitted;
@property(nonatomic,copy) void (^duringPrepare)(void);
@property(nonatomic,copy) void (^duringSubmit)(void);
@property(nonatomic,copy) void (^duringAuthorizationValidation)(void);
@property(nonatomic) BOOL authorizing;
@property(nonatomic) BOOL scopeProven;
@property(nonatomic) NSUInteger hostSubmitCalls;
@end
@implementation AxsCacheKeeperGurdFixtureSource
- (NSDictionary *)prepareWithContext:(NSDictionary *)context reason:(NSString **)reason {
 (void)context;(void)reason;_prepared++;if(_duringPrepare) _duringPrepare();
 NSDictionary *binding=axs_cachekeeper_gurd_bind_root(_root,context[@"home"],context[@"installation"],reason);
 if(!binding) return nil;
 NSArray *identity=binding[@"identity"];
 NSString *rootIdentity=[NSString stringWithFormat:@"%lld:%llu",[identity.lastObject[0] longLongValue],[identity.lastObject[1] unsignedLongLongValue]];
 NSMutableDictionary *proof=[@{@"state":_scopeProven ? @"complete" : @"scopeUnproven",
  @"hostBundle":@"com.ss.iphone.ugc.Aweme",@"hostVersion":@"41.2.0",@"hostBuild":@"412021",
  @"hostIdentity":@"aweme-core-window-set-v1",@"candidateSource":_scopeProven ? @"testFixture" : @"unavailable",
  @"predicateVersion":_scopeProven ? @"fixture-v1" : @"",@"rootIdentity":rootIdentity,
  @"candidateCount":_scopeProven ? @1 : @0,@"candidateDigest":_scopeProven ? [@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0] : @"",
  @"excludedCount":@0,@"exclusionDigest":_scopeProven ? [@"b" stringByPaddingToLength:64 withString:@"b" startingAtIndex:0] : @""} mutableCopy];
 NSMutableDictionary *result=[binding mutableCopy];result[@"scopeProof"]=proof;return result;
}
- (NSString *)validateBinding:(NSDictionary *)binding context:(NSDictionary *)context {
 if(!axs_cachekeeper_gurd_scope_proof_projection(binding[@"scopeProof"]) ||
    ![binding[@"scopeProof"][@"state"] isEqual:@"complete"]) return @"scopeUnproven";
 if(_authorizing && _duringAuthorizationValidation) _duringAuthorizationValidation();
 return axs_cachekeeper_gurd_binding_reason(binding,context[@"home"],context[@"installation"]);
}
- (BOOL)submitBinding:(NSDictionary *)binding context:(NSDictionary *)context authorization:(BOOL (^)(void))authorization reason:(NSString **)reason {
 (void)binding;(void)context;(void)reason;_authorizing=YES;BOOL allowed=authorization();_authorizing=NO;if(!allowed) return NO;_submitted++;_hostSubmitCalls++;if(_duringSubmit) _duringSubmit();return YES;
}
@end
static void axs_cachekeeper_gurd_test_wait(BOOL (^condition)(void),const char *expression,int line) {
 NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+12;
 while(!condition() && NSProcessInfo.processInfo.systemUptime<deadline) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
 check(condition(),[NSString stringWithFormat:@"bounded async operation finishes (line %d: %s)",line,expression]);
}
#define waitFor(...) axs_cachekeeper_gurd_test_wait((__VA_ARGS__),#__VA_ARGS__,__LINE__)
int main(int argc,const char *argv[]) {@autoreleasepool {
#if defined(AXS_CACHEKEEPER_GURD_FIXED201_SYMLINK)
 check(argc==2,@"temporary fixture argument");NSString *home=[NSString stringWithUTF8String:argv[1]];
 NSString *root=[home stringByAppendingPathComponent:@"Library/Application Support/gurd_cache"];
 check([NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL],@"symlink fixture root created");
 check([[NSMutableData dataWithLength:32] writeToFile:[root stringByAppendingPathComponent:@"asset"] atomically:YES],@"symlink fixture target created");
 check(symlink("asset",[root stringByAppendingPathComponent:@"link"].fileSystemRepresentation)==0,@"actual descendant symlink fixture created");
 NSDictionary *context=@{@"valid":@YES,@"appState":@{@"enabled":@YES,@"mode":@"prevent",@"autoDiscover":@YES},@"selected":@[],@"installation":@"verified-fixture",@"home":home,@"bundle":@"com.ss.iphone.ugc.Aweme",@"version":@"41.2.0",@"build":@"412021",@"configuration":@1,@"reportWritable":@YES};
 AxsCacheKeeperGurdFixtureSource *source=[AxsCacheKeeperGurdFixtureSource new];source.root=root;source.scopeProven=YES;
 __block BOOL ended=NO;
 AxsCacheKeeperGurdCache *cache=[[AxsCacheKeeperGurdCache alloc] initWithContextProvider:^{return context;} source:source
  beginTask:^NSUInteger(void (^expiration)(void)) {(void)expiration;return 1;}
  endTask:^(NSUInteger token) {check(token==1,@"exact task token ended");ended=YES;} observer:nil];
 [cache didEnterBackground];waitFor(^BOOL {return ended;});
 NSDictionary *operation=[cache.receipt[@"operations"] lastObject];
 check(source.submitted==0 && [operation[@"before"][@"state"] isEqual:@"linkEncountered"],@"real descendant symlink fails sample and blocks call");
 printf("PASS: gurd isolated real-file symlink classification\n");
#else
 testProductionPredicateProofProjectionShape();
 check(argc==2,@"temporary fixture argument");NSString *home=[NSString stringWithUTF8String:argv[1]];
 NSString *root=[home stringByAppendingPathComponent:@"Library/Application Support/gurd_cache"];
 [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL];
 NSString *file=[root stringByAppendingPathComponent:@"asset"];[[NSMutableData dataWithLength:16384] writeToFile:file atomically:YES];
 NSString *nested=[root stringByAppendingPathComponent:@"nested"];[NSFileManager.defaultManager createDirectoryAtPath:nested withIntermediateDirectories:NO attributes:nil error:NULL];
 NSString *nestedA=[nested stringByAppendingPathComponent:@"a"],*nestedB=[nested stringByAppendingPathComponent:@"b"];
 [[NSMutableData dataWithLength:3] writeToFile:nestedA atomically:YES];[[NSMutableData dataWithLength:5] writeToFile:nestedB atomically:YES];
 struct stat assetInfo,nestedAInfo,nestedBInfo;check(!stat(file.fileSystemRepresentation,&assetInfo) && !stat(nestedA.fileSystemRepresentation,&nestedAInfo) &&
  !stat(nestedB.fileSystemRepresentation,&nestedBInfo),@"multi-slice fixture metadata is readable");
 uint64_t expectedAllocated=((uint64_t)assetInfo.st_blocks+(uint64_t)nestedAInfo.st_blocks+(uint64_t)nestedBInfo.st_blocks)*512;
 __block NSDictionary *context=@{@"valid":@YES,@"appState":@{@"enabled":@YES,@"mode":@"prevent",@"autoDiscover":@YES},@"selected":@[],@"installation":@"verified-fixture",@"home":home,@"bundle":@"com.ss.iphone.ugc.Aweme",@"version":@"41.2.0",@"build":@"412021",@"configuration":@1,@"reportWritable":@YES};
 __block NSUInteger ended=0,providerCalls=0;
 __block BOOL taskGranted=NO;
 __block void (^oldExpiration)(void)=nil;
 __block void (^latestExpiration)(void)=nil;
 __block NSDictionary *published=nil;
 AxsCacheKeeperGurdFixtureSource *source=[AxsCacheKeeperGurdFixtureSource new];source.root=root;source.scopeProven=YES;
 AxsCacheKeeperGurdCache *cache=[[AxsCacheKeeperGurdCache alloc] initWithContextProvider:^{check(!NSThread.isMainThread && taskGranted,@"provider IO runs off main after platform task grant");providerCalls++;return context;} source:source beginTask:^NSUInteger(void (^expire)(void)) {if(!oldExpiration) oldExpiration=[expire copy];latestExpiration=[expire copy];taskGranted=YES;return 1;} endTask:^(NSUInteger task) {check(task==1,@"exact task token ended");ended++;} observer:^(NSDictionary *receipt) {published=receipt;}];
 BOOL (^eventFinished)(NSUInteger)=^BOOL(NSUInteger event) {NSDictionary *last=[published[@"operations"] lastObject];return ended==event && [last[@"event"] unsignedIntegerValue]==event && [@[@"observed",@"skipped",@"cancelled",@"interruptedAfterSubmission"] containsObject:last[@"phase"]];};
 source.duringSubmit=^{check([cache.receipt[@"restriction"] isEqual:@"unsupported"],@"receipt callback may read snapshot on engine queue");unlink(file.fileSystemRepresentation);};
 Method advanceMethod=class_getInstanceMethod(AxsCacheKeeperScanCursor.class,@selector(advanceEntries:seconds:));
 check(advanceMethod!=NULL,@"real cursor quantum method exists");
 axs_cachekeeper_gurd_test_cursor_advance=method_setImplementation(advanceMethod,(IMP)axs_cachekeeper_gurd_test_observe_slice);
 __block AxsCacheKeeperScanCursor *firstCursor=nil;
 __block NSUInteger beforeSlices=0;
 axs_cachekeeper_gurd_test_did_advance=^(AxsCacheKeeperScanCursor *cursor) {
  NSDictionary *current=[cache.receipt[@"operations"] lastObject];
  if(![current[@"phase"] isEqual:@"samplingBefore"]) return;
  if(!firstCursor) firstCursor=cursor;
  check(firstCursor==cursor,@"multiple queue slices retain the identical live cursor");beforeSlices++;
 };
 [cache axs_cachekeeper_setSampleSliceEntries:1];[cache didEnterBackground];waitFor(^BOOL {return eventFinished(1);});
 axs_cachekeeper_gurd_test_did_advance=nil;
 check(beforeSlices>=4 && [firstCursor.state isEqual:@"complete"] && firstCursor.openDirectoryCount==0,
  @"real multi-slice sample completes and releases every directory handle");
 check(source.submitted==1,@"verified host boundary submits once");
 NSDictionary *receipt=cache.receipt,*operation=[receipt[@"operations"] lastObject];
 NSDictionary *before=operation[@"before"];
 check([before[@"state"] isEqual:@"complete"] && [before[@"files"] unsignedLongLongValue]==3 &&
  [before[@"entries"] unsignedLongLongValue]==5 && [before[@"logicalBytes"] unsignedLongLongValue]==16392 &&
  [before[@"allocatedBytes"] unsignedLongLongValue]==expectedAllocated,
  @"multi-slice cursor accumulates the unique fixture once without resetting counters");
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
 [cache didBecomeActive];NSMutableDictionary *unprovenContext=[context mutableCopy];unprovenContext[@"appState"]=@{@"enabled":@YES,@"autoDiscover":@NO};unprovenContext[@"selected"]=@[@"Library/Application Support/gurd_cache"];context=unprovenContext;source.scopeProven=NO;
 NSUInteger unprovenCalls=source.hostSubmitCalls;[cache didEnterBackground];waitFor(^BOOL {return eventFinished(4);});operation=[cache.receipt[@"operations"] lastObject];
 check([operation[@"reason"] isEqual:@"scopeUnproven"] && [operation[@"scopeProof"][@"state"] isEqual:@"scopeUnproven"] && source.hostSubmitCalls==unprovenCalls,@"unproven candidate scope never reaches host submit");
 source.scopeProven=YES;
 check(axs_cachekeeper_gurd_receipt_projection(cache.receipt)!=nil,@"actual receipt accepts strict projection");
 NSMutableDictionary *bad=[cache.receipt mutableCopy];bad[@"rawPath"]=root;check(!axs_cachekeeper_gurd_receipt_projection(bad),@"strict projection rejects paths");

 [cache didBecomeActive];NSMutableDictionary *allowed=[context mutableCopy];allowed[@"appState"]=@{@"enabled":@YES,@"autoDiscover":@NO};allowed[@"selected"]=@[];context=allowed;
 NSUInteger preparations=source.prepared;[cache didEnterBackground];waitFor(^BOOL {return eventFinished(5);});
 check(source.prepared==preparations && source.submitted==2,@"no discover and no selection skips getters");
 [cache didBecomeActive];allowed=[context mutableCopy];allowed[@"selected"]=@[@"Library/Application Support/gurd_cache"];context=allowed;
 [cache didEnterBackground];waitFor(^BOOL {return eventFinished(6);});check(source.submitted==3,@"explicit actual private root enables host action");
 [cache didBecomeActive];allowed=[context mutableCopy];allowed[@"reportWritable"]=@NO;context=allowed;
 preparations=source.prepared;[cache didEnterBackground];waitFor(^BOOL {return eventFinished(7);});check(source.prepared==preparations && source.submitted==3,@"unwritable receipt prevents all preparation");
 [cache didBecomeActive];allowed=[context mutableCopy];allowed[@"reportWritable"]=@YES;context=allowed;
 __weak AxsCacheKeeperGurdCache *weakCache=cache;
 source.duringPrepare=^{[weakCache expireBackgroundTime];};[cache didEnterBackground];waitFor(^BOOL {return eventFinished(8);});
 check(source.submitted==3 && [[[cache.receipt[@"operations"] lastObject][@"submission"] description] isEqual:@"notSubmitted"],@"late preparation after expiry never submits");
 [cache didBecomeActive];source.duringPrepare=^{dispatch_sync(dispatch_get_main_queue(),^{[weakCache didBecomeActive];});};
 [cache didEnterBackground];waitFor(^BOOL {return eventFinished(9);});check(source.submitted==3,@"foreground during preparation revokes host submission");
 source.duringPrepare=^{NSMutableDictionary *changed=[context mutableCopy];changed[@"configuration"]=@2;context=changed;};
 [cache didEnterBackground];waitFor(^BOOL {return eventFinished(10);});check(source.submitted==3,@"provider config change after prepare prevents submission without notification");
 [cache didBecomeActive];source.duringPrepare=nil;[[NSMutableData dataWithLength:32] writeToFile:file atomically:YES];
 check(symlink("asset",[root stringByAppendingPathComponent:@"link"].fileSystemRepresentation)==0,@"actual descendant symlink fixture created");
 [cache didEnterBackground];waitFor(^BOOL {return eventFinished(11);});operation=[cache.receipt[@"operations"] lastObject];
 check(source.submitted==3 && [operation[@"before"][@"state"] isEqual:@"linkEncountered"],@"real descendant symlink fails sample and blocks call");
 unlink([root stringByAppendingPathComponent:@"link"].fileSystemRepresentation);[cache didBecomeActive];
 __block AxsCacheKeeperScanCursor *partialCursor=nil;
 axs_cachekeeper_gurd_test_did_advance=^(AxsCacheKeeperScanCursor *cursor) {partialCursor=cursor;};
 [cache axs_cachekeeper_setSampleEntryLimit:2 seconds:4];[cache axs_cachekeeper_setSampleSliceEntries:1];[cache didEnterBackground];
 waitFor(^BOOL {return eventFinished(12);});operation=[cache.receipt[@"operations"] lastObject];axs_cachekeeper_gurd_test_did_advance=nil;
 check(source.submitted==3 && [operation[@"before"][@"state"] isEqual:@"entryLimit"] &&
  [operation[@"before"][@"entries"] unsignedLongLongValue]==3 && [partialCursor.state isEqual:@"entryLimit"] && partialCursor.openDirectoryCount==0,
  @"partial entry-limit sample keeps its lower bound, closes cursor handles and cannot authorize submit");
 [cache didBecomeActive];[cache axs_cachekeeper_setSampleEntryLimit:200000 seconds:0];[cache didEnterBackground];waitFor(^BOOL {return eventFinished(13);});
 operation=[cache.receipt[@"operations"] lastObject];check([operation[@"before"][@"state"] isEqual:@"timeLimit"] && source.submitted==3,@"actual sampler time budget is visible");
 [cache didBecomeActive];[cache axs_cachekeeper_setSampleEntryLimit:200000 seconds:4];
 source.duringSubmit=^{[weakCache expireBackgroundTime];};[cache didEnterBackground];waitFor(^BOOL {return eventFinished(14);});operation=[cache.receipt[@"operations"] lastObject];
 check(source.submitted==4 && [operation[@"phase"] isEqual:@"interruptedAfterSubmission"] && [operation[@"submission"] isEqual:@"submitted"],@"post submission expiry never lies about cancellation");
 [cache didBecomeActive];source.duringSubmit=nil;[cache axs_cachekeeper_setSampleEntryLimit:200000 seconds:4];[cache axs_cachekeeper_setSampleSliceEntries:1];
 [cache didEnterBackground];waitFor(^BOOL {return [cache.receipt[@"operations"] count]>=15 && [[cache.receipt[@"operations"] lastObject][@"phase"] isEqual:@"submitted"];});
 [cache axs_cachekeeper_setSampleEntryLimit:0 seconds:4];waitFor(^BOOL {return eventFinished(15);});operation=[cache.receipt[@"operations"] lastObject];
 check([operation[@"phase"] isEqual:@"interruptedAfterSubmission"] && [operation[@"observation"] isEqual:@"partial"] &&
  [operation[@"after"][@"state"] isEqual:@"entryLimit"] && [operation[@"logicalDecrease"] unsignedLongLongValue]==0 &&
  [operation[@"allocatedDecrease"] unsignedLongLongValue]==0,@"after partial sample never reports observed decrease");
 [cache didBecomeActive];[[NSMutableData dataWithLength:1024] writeToFile:file atomically:YES];[cache axs_cachekeeper_setSampleEntryLimit:200000 seconds:4];[cache axs_cachekeeper_setSampleCounterLimit:100];
 [cache didEnterBackground];waitFor(^BOOL {return eventFinished(16);});operation=[cache.receipt[@"operations"] lastObject];
 check([operation[@"before"][@"state"] isEqual:@"invalidMetadata"] && [operation[@"before"][@"errorCode"] intValue]==EOVERFLOW &&
  source.submitted==5,@"checked cumulative sample overflow preserves EOVERFLOW and blocks submission");
 [cache didBecomeActive];[cache axs_cachekeeper_setSampleCounterLimit:9007199254740991ULL];axs_cachekeeper_scan_test_close_error(EIO);
 [cache didEnterBackground];waitFor(^BOOL {return eventFinished(17);});operation=[cache.receipt[@"operations"] lastObject];
 check([operation[@"before"][@"state"] isEqual:@"closeError"] && [operation[@"before"][@"errorCode"] intValue]==EIO &&
  source.submitted==5,@"sample cursor close failure remains a failed partial and blocks submission");
 [cache didBecomeActive];[cache axs_cachekeeper_setSampleCounterLimit:9007199254740991ULL];[cache axs_cachekeeper_setSampleSliceEntries:1];
 __block BOOL expiredDuringSlice=NO;
 axs_cachekeeper_gurd_test_did_advance=^(AxsCacheKeeperScanCursor *cursor) {
  if(expiredDuringSlice || ![cursor.result[@"scanDiagnostics"][@"entriesVisited"] unsignedIntegerValue]) return;
  expiredDuringSlice=YES;dispatch_sync(dispatch_get_main_queue(),^{latestExpiration();});
 };
 [cache didEnterBackground];waitFor(^BOOL {return eventFinished(18);});operation=[cache.receipt[@"operations"] lastObject];
 axs_cachekeeper_gurd_test_did_advance=nil;method_setImplementation(advanceMethod,axs_cachekeeper_gurd_test_cursor_advance);
 check([operation[@"phase"] isEqual:@"cancelled"] && [operation[@"submission"] isEqual:@"notSubmitted"] &&
  [operation[@"before"][@"state"] isEqual:@"cancelled"] && [operation[@"before"][@"entries"] unsignedIntegerValue]>1 &&
  [operation[@"observation"] isEqual:@"notObserved"] && source.submitted==5 && expiredDuringSlice,
  @"cancelled before sample retains its scanned partial lower bound without authorizing submit");
 [cache didBecomeActive];source.duringSubmit=nil;
 __block NSUInteger synchronousEnded=0;
 AxsCacheKeeperGurdCache *sync=[[AxsCacheKeeperGurdCache alloc] initWithContextProvider:^{return context;} source:source beginTask:^NSUInteger(void (^expiration)(void)) {expiration();return 77;} endTask:^(NSUInteger token) {check(token==77,@"synchronously expired token returned to platform");synchronousEnded++;} observer:nil];
 preparations=source.prepared;[sync didEnterBackground];waitFor(^BOOL {return synchronousEnded==1;});check(source.prepared==preparations && source.submitted==5,@"synchronous expiry during begin denies preparation");
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
 check(oldOperations.count==16,@"eighteen completed events retain the sixteen newest operations before restoration");
 NSUInteger nextEvent=[oldOperations.lastObject[@"event"] unsignedIntegerValue]+1;
 [restored didEnterBackground];waitFor(^BOOL {return [[restored.receipt[@"operations"] lastObject][@"event"] unsignedIntegerValue]==nextEvent;});
 NSArray *restoredOperations=restored.receipt[@"operations"];
 check(restoredOperations.count==16 && [[restoredOperations subarrayWithRange:NSMakeRange(0,15)]
  isEqual:[oldOperations subarrayWithRange:NSMakeRange(1,15)]],@"restored history evicts only the oldest event when a new event reaches its sixteen-operation bound");
 NSDictionary *newOperation=restoredOperations.lastObject;
 check([newOperation[@"phase"] isEqual:@"skipped"] && [newOperation[@"reason"] isEqual:@"noBackgroundTime"] &&
  [newOperation[@"submission"] isEqual:@"notSubmitted"] && axs_cachekeeper_gurd_receipt_projection(restored.receipt),
  @"restored engine publishes the next event with truthful no-background-time completion");
 check([restoredOperations[0][@"runtimeInfo"] isEqual:oldRuntime] && newOperation[@"runtimeInfo"] &&
 ![newOperation[@"runtimeInfo"] isEqual:oldRuntime],@"a new publication never relabels old operation producers");
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
#endif
}return 0;}
