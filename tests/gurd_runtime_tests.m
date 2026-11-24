// Runs the real Runtime, Source methods, engine, cursor and atomic report writer.
// The runner replaces only Source's loaded-host ABI authentication boundary.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "AxsCacheKeeperInstallation.h"
#import "AxsCacheKeeperGurdCache.h"
#import "gurd_export_fixture.h"
#include <objc/runtime.h>
#include <stdatomic.h>
#include <unistd.h>

static NSString *fixtureFolder, *fixtureHome, *fixtureRoot, *fixtureFile;
static NSString *identityVersion=@"41.2.0", *identityBuild=@"412021";
static NSString * const fixtureBundle=@"com.ss.iphone.ugc.Aweme";
static _Atomic(unsigned long) snapshots, validations, hostChecks, submissions;
static UIApplicationState applicationState=UIApplicationStateActive;
static NSUInteger taskBegins, taskEnds;
static NSMutableArray<NSNumber *> *endedTaskIdentifiers;
static BOOL failTask, expireSynchronously, flipForeground, expectRestoredBeforeTask, backgroundImmediatelyOnRegistration;
static void (^lastExpiration)(void);
static NSDictionary *savedReceipt;
static _Atomic(BOOL) blockNextIdentityValidation, identityValidationWaiting;
static dispatch_semaphore_t identityValidationEntered, releaseIdentityValidation;

static void require(BOOL value, NSString *message) {
    if (!value) {fprintf(stderr,"FAIL: gurd-runtime: %s\n",message.UTF8String);exit(1);}
}
static void pump(NSTimeInterval seconds) {
    NSTimeInterval end=NSProcessInfo.processInfo.systemUptime+seconds;
    while (NSProcessInfo.processInfo.systemUptime<end)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.005]];
}
static void await(BOOL (^condition)(void), NSString *message) {
    NSTimeInterval end=NSProcessInfo.processInfo.systemUptime+8;
    while (!condition() && NSProcessInfo.processInfo.systemUptime<end) pump(.01);
    require(condition(),message);
}
NSString *axs_cachekeeper_gurd_runtime_fixture_folder(void) {return fixtureFolder;}
static NSString *fixtureHomeDirectory(void) {return fixtureHome;}

@interface AxsCacheKeeperGurdRuntimeFixtureBundle : NSObject
+ (instancetype)mainBundle;
@property(nonatomic,readonly) NSString *bundleIdentifier;
@property(nonatomic,readonly) NSURL *bundleURL;
- (id)objectForInfoDictionaryKey:(NSString *)key;
@end
@implementation AxsCacheKeeperGurdRuntimeFixtureBundle
+ (instancetype)mainBundle {static id bundle;static dispatch_once_t once;dispatch_once(&once,^{bundle=[self new];});return bundle;}
- (NSString *)bundleIdentifier {return fixtureBundle;}
- (NSURL *)bundleURL {return [NSURL fileURLWithPath:fixtureHome];}
- (id)objectForInfoDictionaryKey:(NSString *)key {
    return [key isEqual:@"CFBundleShortVersionString"] ? @"41.2.0" : [key isEqual:@"CFBundleVersion"] ? @"412021" : nil;
}
@end

NSDictionary *axs_cachekeeper_installation_snapshot_with_context(NSURL *url,NSString *bundle,NSString *version,AxsCacheKeeperInstallationContext kind,NSError **error) {
    (void)error;
    require(!NSThread.isMainThread,@"installation collection stays off notification main thread");
    require([url.path isEqual:fixtureHome] && [bundle isEqual:fixtureBundle] && [version isEqual:@"41.2.0"] &&
        kind==AxsCacheKeeperInstallationContextHostMainBundle,@"Runtime supplies actual bundle metadata and host context");
    atomic_fetch_add(&snapshots,1);
    return @{@"installationState":@"verified",@"version":identityVersion,@"build":identityBuild,@"fingerprint":@"private-owned-installation"};
}
BOOL axs_cachekeeper_validate_installation_snapshot_with_context(NSDictionary *snapshot,NSURL *url,NSString *version,AxsCacheKeeperInstallationContext kind,NSError **error) {
    (void)error;
    require(!NSThread.isMainThread,@"installation validation stays off notification main thread");
    require([url.path isEqual:fixtureHome] && [version isEqual:@"41.2.0"] && kind==AxsCacheKeeperInstallationContextHostMainBundle,
        @"Runtime validates cached identity against current bundle");
    atomic_fetch_add(&validations,1);
    if (atomic_exchange(&blockNextIdentityValidation,NO)) {
        atomic_store(&identityValidationWaiting,YES);dispatch_semaphore_signal(identityValidationEntered);
        require(dispatch_semaphore_wait(releaseIdentityValidation,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0,
            @"blocked installation validation receives its bounded release");
        atomic_store(&identityValidationWaiting,NO);
    }
    return [snapshot[@"fingerprint"] isEqual:@"private-owned-installation"];
}

// Real Source prepare/submit still resolve host classes and call authenticated IMPs.
@interface IESGurdKit : NSObject @end
@implementation IESGurdKit @end
@interface IESGurdFilePaths : NSObject @end
@implementation IESGurdFilePaths @end
static BOOL fixtureHostReady(id object,SEL selector) {(void)object;(void)selector;return YES;}
static id fixtureHostRoot(id object,SEL selector) {(void)object;(void)selector;return fixtureRoot;}
static void fixtureHostClear(id object,SEL selector,BOOL preserveWhitelist) {
    (void)object;
    require(selector==sel_registerName("clearCacheExceptWhitelist:") && preserveWhitelist,@"Source calls whitelist-preserving host ABI");
    atomic_fetch_add(&submissions,1);
    if (access(fixtureFile.fileSystemRepresentation,F_OK)==0)
        require(unlink(fixtureFile.fileSystemRepresentation)==0,@"owned host fixture deletes actual asset");
}
NSString *axs_cachekeeper_gurd_runtime_fixture_host_identity(NSDictionary *context,IMP originals[4]) {
    atomic_fetch_add(&hostChecks,1);
    require(!NSThread.isMainThread,@"Source authentication is off main");
    if (![context[@"bundle"] isEqual:fixtureBundle] || ![context[@"version"] isEqual:@"41.2.0"] || ![context[@"build"] isEqual:@"412021"])
        return @"unsupportedHost";
    require([context[@"installation"] isEqual:@"private-owned-installation"],@"Source receives independently verified identity");
    if (originals) {originals[0]=(IMP)fixtureHostReady;originals[1]=(IMP)fixtureHostReady;originals[2]=(IMP)fixtureHostRoot;originals[3]=(IMP)fixtureHostClear;}
    return nil;
}

// UIKit lifecycle notification boundary: force a background event at the first
// possible observer-registration instant to exercise real restore FIFO ordering.
@interface AxsCacheKeeperGurdRuntimeFixtureNotifications : NSObject
+ (instancetype)defaultCenter;
- (id)addObserverForName:(NSString *)name object:(id)object queue:(NSOperationQueue *)queue usingBlock:(void (^)(NSNotification *))block;
@end
@implementation AxsCacheKeeperGurdRuntimeFixtureNotifications
+ (instancetype)defaultCenter {static id center;static dispatch_once_t once;dispatch_once(&once,^{center=[self new];});return center;}
- (id)addObserverForName:(NSString *)name object:(id)object queue:(NSOperationQueue *)queue usingBlock:(void (^)(NSNotification *))block {
    id observer=[NSNotificationCenter.defaultCenter addObserverForName:name object:object queue:queue usingBlock:block];
    if (backgroundImmediatelyOnRegistration && [name isEqual:UIApplicationDidEnterBackgroundNotification]) {
        backgroundImmediatelyOnRegistration=NO;applicationState=UIApplicationStateBackground;
        [NSNotificationCenter.defaultCenter postNotificationName:name object:nil];
    }
    return observer;
}
@end

#define NSBundle AxsCacheKeeperGurdRuntimeFixtureBundle
#define NSHomeDirectory fixtureHomeDirectory
#define NSNotificationCenter AxsCacheKeeperGurdRuntimeFixtureNotifications
#ifdef AXS_CACHEKEEPER_GURD_RUNTIME_INCLUDE
#import AXS_CACHEKEEPER_GURD_RUNTIME_INCLUDE
#else
#import "AxsCacheKeeperGurdRuntime.m"
#endif
#undef NSHomeDirectory
#undef NSBundle
#undef NSNotificationCenter

const UIBackgroundTaskIdentifier UIBackgroundTaskInvalid=NSUIntegerMax;
NSString * const UIApplicationDidBecomeActiveNotification=@"gurd.fixture.active";
NSString * const UIApplicationDidEnterBackgroundNotification=@"gurd.fixture.background";
@implementation UIApplication
+ (instancetype)sharedApplication {static id app;static dispatch_once_t once;dispatch_once(&once,^{app=[self new];});return app;}
- (UIApplicationState)applicationState {return applicationState;}
- (NSTimeInterval)backgroundTimeRemaining {return 30;}
- (UIBackgroundTaskIdentifier)beginBackgroundTaskWithName:(NSString *)name expirationHandler:(void (^)(void))expiration {
    require(NSThread.isMainThread && [name isEqual:@"CacheKeeper.GurdCache"],@"UIKit task acquisition stays on main");
    if (expectRestoredBeforeTask) {
        NSDictionary *first=[axs_cachekeeper_gurd_engine receipt][@"operations"][0];
        require([first[@"event"] isEqual:@1] && [first[@"runtimeInfo"] isEqual:savedReceipt[@"runtimeInfo"]],@"saved history is restored before lifecycle starts action");
    }
    if (failTask) return UIBackgroundTaskInvalid;
    lastExpiration=[expiration copy];taskBegins++;
    if (expireSynchronously) expiration();
    if (flipForeground) applicationState=UIApplicationStateActive;
    // Zero is a legal UIKit token; Runtime must encode it as nonzero engine token.
    return taskBegins-1;
}
- (void)endBackgroundTask:(UIBackgroundTaskIdentifier)task {
    require(NSThread.isMainThread && task<taskBegins,@"Runtime ends exact valid UIKit task on main");taskEnds++;
    if (!endedTaskIdentifiers) endedTaskIdentifiers=[NSMutableArray new];[endedTaskIdentifiers addObject:@(task)];
}
@end

static NSString *reportPath(void) {return [[fixtureFolder stringByAppendingPathComponent:@"Status"] stringByAppendingPathComponent:[fixtureBundle stringByAppendingString:@".gurd.plist"]];}
static NSDictionary *report(void) {return [NSDictionary dictionaryWithContentsOfFile:reportPath()];}
static NSDictionary *receipt(void) {return [axs_cachekeeper_gurd_engine receipt];}
static NSDictionary *operation(void) {return [receipt()[@"operations"] lastObject];}
static NSDictionary *context(void) {
    __block NSDictionary *result;dispatch_semaphore_t done=dispatch_semaphore_create(0);
    // dispatch_sync onto a global queue may execute inline on the caller. Force
    // an actual asynchronous worker so identity-main-thread assertions are real.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{result=AxsCacheKeeperGurdContext();dispatch_semaphore_signal(done);});
    require(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0,@"bounded off-main context sampling finishes");return result;
}
static void configure(BOOL accessAllowed) {axs_cachekeeper_configure_gurd_cache(YES,accessAllowed);}
static void writeConfiguration(id state,id selected) {
    require([@{fixtureBundle:state} writeToFile:[fixtureFolder stringByAppendingPathComponent:@"appEnabled.plist"] atomically:YES] &&
        [@{fixtureBundle:selected} writeToFile:[fixtureFolder stringByAppendingPathComponent:@"directories.plist"] atomically:YES],@"real config plist written");
}
static NSDictionary *enabledState(void) {return @{@"enabled":@YES,@"mode":@"prevent",@"autoDiscover":@NO};}
static NSArray *selectedRoot(void) {return @[@"Library/Application Support/gurd_cache"];}
static void background(void) {applicationState=UIApplicationStateBackground;[NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidEnterBackgroundNotification object:nil];}
static void foreground(void) {applicationState=UIApplicationStateActive;[NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];}
static void settled(void) {pump(.15);(void)receipt();dispatch_sync(axs_cachekeeper_gurd_report_queue,^{});pump(.03);}
static void initialized(void) {await(^BOOL {return axs_cachekeeper_gurd_engine!=nil;},@"real engine configured");settled();}

static void runEnabled(void) {
    configure(YES);initialized();
    NSDictionary *provider=context();
    require([provider[@"version"] isEqual:@"41.2.0"] && [provider[@"build"] isEqual:@"412021"] &&
        [provider[@"installation"] isEqual:@"private-owned-installation"],@"enabled provider agrees with installation metadata");
    background();await(^BOOL {return atomic_load(&submissions)==1 && [operation()[@"phase"] isEqual:@"submitted"];},@"actual host action submitted");
    NSNumber *activeGeneration=context()[@"configuration"];
    for (NSUInteger i=0;i<4;i++) configure(YES);settled();
    require(atomic_load(&submissions)==1 && [receipt()[@"operations"] count]==1 && [operation()[@"phase"] isEqual:@"submitted"] &&
        [context()[@"configuration"] isEqual:activeGeneration],@"identical configure probes preserve in-flight submitted event");
    await(^BOOL {return [operation()[@"phase"] isEqual:@"observed"] && taskEnds==1;},@"real runtime action and after sample finish");settled();
    require(atomic_load(&submissions)==1 && [operation()[@"logicalDecrease"] unsignedIntegerValue]==16384 &&
        [operation()[@"observation"] isEqual:@"reduced"] && ![NSFileManager.defaultManager fileExistsAtPath:fixtureFile],@"production Source and cursor observe actual fixture file decrease");
    require([operation()[@"hostCompletion"] isEqual:@"notProvided"] && [receipt()[@"restriction"] isEqual:@"unsupported"],@"host submission does not invent completion or restriction");
    require(axs_cachekeeper_gurd_receipt_projection(report())!=nil && [report() isEqual:receipt()],@"actual Runtime report writer persists strict receipt");
    NSDictionary *prior=receipt();NSNumber *generation=context()[@"configuration"];
    for (NSUInteger i=0;i<4;i++) configure(YES);settled();
    require(atomic_load(&submissions)==1 && [receipt()[@"operations"] isEqual:prior[@"operations"]] &&
        [context()[@"configuration"] isEqual:generation],@"identical configure probes do not create event or resubmit");

    writeConfiguration(enabledState(),@[]);configure(YES);
    await(^BOOL {return [operation()[@"event"] unsignedIntegerValue]>1 && [operation()[@"reason"] isEqual:@"scopeNotAuthorized"];},@"changed selection reevaluates background scope");
    require(atomic_load(&submissions)==1,@"removed selection revokes host scope");
    writeConfiguration(enabledState(),selectedRoot());configure(YES);
    await(^BOOL {return atomic_load(&submissions)==2;},@"new selection permits new verified action");
    void (^oldExpiration)(void)=[lastExpiration copy];foreground();
    await(^BOOL {return [operation()[@"phase"] isEqual:@"interruptedAfterSubmission"];},@"foreground revokes submitted operation truthfully");
    NSDictionary *closed=operation();pump(2.1);require([operation() isEqual:closed],@"old delayed sample cannot revive foreground-revoked event");
    writeConfiguration(@{@"enabled":@NO,@"mode":@"prevent"},selectedRoot());configure(YES);settled();
    unsigned long identityCalls=atomic_load(&snapshots)+atomic_load(&validations);
    provider=context();require([provider[@"installation"] isEqual:@""] && identityCalls==atomic_load(&snapshots)+atomic_load(&validations),@"disabled provider never reuses or samples installation identity");
    background();await(^BOOL {return [operation()[@"reason"] isEqual:@"appDisabled"];},@"disabled lifecycle yields explicit skipped receipt");
    require(atomic_load(&submissions)==2 && identityCalls==atomic_load(&snapshots)+atomic_load(&validations),@"disabled lifecycle performs no identity or host action");
    writeConfiguration(enabledState(),selectedRoot());configure(YES);
    await(^BOOL {return atomic_load(&submissions)==3;},@"reenable reevaluates actual config");
    oldExpiration();settled();require([operation()[@"submission"] isEqual:@"submitted"],@"old UIKit expiration cannot cancel current event");
    configure(NO);await(^BOOL {return [operation()[@"reason"] isEqual:@"configurationInvalid"];},@"access change revokes active action");
    require(atomic_load(&submissions)==3,@"lost config access performs no additional host action");
    configure(YES);await(^BOOL {return atomic_load(&submissions)==4;},@"restored config access reevaluates scope");
    foreground();settled();

    // Block the actual Runtime's installation service while its provider holds
    // the IO lock. Main must not read receipt/context until that service returns.
    unsigned long callsBeforeBlocked=atomic_load(&submissions),checksBeforeBlocked=atomic_load(&hostChecks);
    NSUInteger eventsBeforeBlocked=[receipt()[@"operations"] count],endsBeforeBlocked=taskEnds;
    identityValidationEntered=dispatch_semaphore_create(0);releaseIdentityValidation=dispatch_semaphore_create(0);
    atomic_store(&blockNextIdentityValidation,YES);background();NSUInteger blockedTask=taskBegins-1;
    require(dispatch_semaphore_wait(identityValidationEntered,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0,
        @"actual Runtime provider is blocked in installation IO");
    NSTimeInterval revokeStarted=NSProcessInfo.processInfo.systemUptime;configure(NO);
    require(NSProcessInfo.processInfo.systemUptime-revokeStarted<1 && atomic_load(&identityValidationWaiting),
        @"main access revocation returns while installation IO is still blocked");
    require(taskEnds==endsBeforeBlocked+1 && [endedTaskIdentifiers.lastObject isEqual:@(blockedTask)],
        @"blocked-provider access revocation immediately returns only its old UIKit token");
    dispatch_semaphore_signal(releaseIdentityValidation);
    await(^BOOL {return [receipt()[@"operations"] count]>eventsBeforeBlocked && [operation()[@"reason"] isEqual:@"configurationInvalid"];},
        @"released provider settles revoked history and the disabled successor");settled();
    require(atomic_load(&submissions)==callsBeforeBlocked && atomic_load(&hostChecks)==checksBeforeBlocked,
        @"revoked provider never reaches Source or host after installation IO resumes");
    foreground();settled();

    // Access restoration starts one new background event. Hold the production
    // engine FIFO so its semantic notification reaches main before provider B.
    background();await(^BOOL {return [operation()[@"reason"] isEqual:@"configurationInvalid"];},
        @"disabled background event is settled before access restoration");settled();
    NSUInteger eventsBeforeRestore=[receipt()[@"operations"] count],beginsBeforeRestore=taskBegins;
    unsigned long submissionsBeforeRestore=atomic_load(&submissions);
    Ivar queueIvar=class_getInstanceVariable(AxsCacheKeeperGurdCache.class,"_queue");
    require(queueIvar!=NULL,@"production engine FIFO ivar is available to the synchronization fixture");
    dispatch_queue_t engineQueue=(dispatch_queue_t)object_getIvar(axs_cachekeeper_gurd_engine,queueIvar);
    require(engineQueue!=nil,@"production engine FIFO is available to the synchronization fixture");
    dispatch_semaphore_t queueEntered=dispatch_semaphore_create(0),releaseQueue=dispatch_semaphore_create(0);
    dispatch_async(engineQueue,^{dispatch_semaphore_signal(queueEntered);
        require(dispatch_semaphore_wait(releaseQueue,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0,
            @"held engine FIFO receives bounded release");});
    require(dispatch_semaphore_wait(queueEntered,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0,
        @"engine FIFO is held before changed access schedules provider");
    configure(YES);dispatch_sync(axs_cachekeeper_gurd_report_queue,^{});pump(.05);
    require(taskBegins==beginsBeforeRestore+1,
        @"access change and early semantic notice acquire exactly one successor UIKit task");
    dispatch_semaphore_signal(releaseQueue);
    await(^BOOL {return [operation()[@"phase"] isEqual:@"observed"];},@"access restoration successor completes");settled();
    require([receipt()[@"operations"] count]==eventsBeforeRestore+1 && atomic_load(&submissions)==submissionsBeforeRestore+1,
        @"access change and delayed configuration notice create exactly one event and host submission");
    foreground();settled();
}
static void runBlocked(NSString *scenario) {
    if ([scenario isEqual:@"disabled"]) writeConfiguration(@{@"enabled":@NO,@"mode":@"prevent"},selectedRoot());
    if ([scenario isEqual:@"malformed"]) writeConfiguration(@{@"enabled":@YES},@[@"../escape"]);
    if ([scenario isEqual:@"build-mismatch"]) identityBuild=@"other-build";
    if ([scenario isEqual:@"version-mismatch"]) identityVersion=@"other-version";
    configure(YES);initialized();
    NSDictionary *provider=context();
    if ([scenario isEqual:@"disabled"] || [scenario isEqual:@"malformed"])
        require(atomic_load(&snapshots)+atomic_load(&validations)==0 && [provider[@"installation"] isEqual:@""],@"invalid or disabled inputs never request identity");
    else require([provider[@"installation"] isEqual:@""],@"metadata mismatch never authorizes installation fingerprint");
    background();await(^BOOL {return [operation()[@"phase"] isEqual:@"skipped"];},@"blocked Runtime stores skipped action");settled();
    NSString *reason=[scenario isEqual:@"disabled"] ? @"appDisabled" : [scenario isEqual:@"malformed"] ? @"configurationInvalid" : @"installationUnverified";
    require([operation()[@"reason"] isEqual:reason] && atomic_load(&hostChecks)==0 && atomic_load(&submissions)==0,@"blocked Runtime never reaches Source authentication or host action");
}
static void runRestore(void) {
    writeConfiguration(@NO,selectedRoot());savedReceipt=axs_cachekeeper_gurd_export_fixture();
    require([savedReceipt writeToFile:reportPath() atomically:YES],@"saved real receipt written before configure");
    configure(YES);initialized();
    require([receipt()[@"updated"] isEqual:savedReceipt[@"updated"]] && [receipt()[@"runtimeInfo"] isEqual:savedReceipt[@"runtimeInfo"]] &&
        [receipt()[@"operations"] isEqual:savedReceipt[@"operations"]],@"startup restore retains saved producer and evidence timestamp");
    require([report()[@"updated"] isEqual:savedReceipt[@"updated"]] && [report()[@"runtimeInfo"] isEqual:savedReceipt[@"runtimeInfo"]],@"restored Status keeps old producer on disk");
    for(NSUInteger i=0;i<3;i++) configure(YES);settled();
    require([receipt()[@"updated"] isEqual:savedReceipt[@"updated"]],@"same startup configuration cannot refresh saved evidence timestamp");
    writeConfiguration(enabledState(),selectedRoot());configure(YES);settled();expectRestoredBeforeTask=YES;background();
    await(^BOOL {return [operation()[@"phase"] isEqual:@"observed"];},@"restored engine admits next actual lifecycle event");settled();
    require([operation()[@"event"] isEqual:@2] && [receipt()[@"operations"][0][@"runtimeInfo"] isEqual:savedReceipt[@"runtimeInfo"]] &&
        [operation()[@"runtimeInfo"][@"packageVersion"] isEqual:@"0.0.0-0.0"] && [receipt()[@"runtimeInfo"] isEqual:operation()[@"runtimeInfo"]],@"old and new events retain separate producer attribution");
    require(axs_cachekeeper_gurd_receipt_projection(report())!=nil,@"mixed producer history saves with strict schema");
}
static void runRejectedRestore(void) {
    NSMutableDictionary *bad=[axs_cachekeeper_gurd_export_fixture() mutableCopy];bad[@"rawPath"]=fixtureHome;
    require([bad writeToFile:reportPath() atomically:YES],@"malformed saved Status fixture written");
    configure(YES);initialized();await(^BOOL {return [receipt()[@"reason"] isEqual:@"historyRejected"];},@"real restored Status rejects unrecognized fields");settled();
    require([receipt()[@"operations"] count]==0 && atomic_load(&submissions)==0 && axs_cachekeeper_gurd_receipt_projection(report())!=nil,
        @"invalid history neither fabricates old action nor reexports private fields");
    background();await(^BOOL {return [operation()[@"phase"] isEqual:@"observed"];},@"invalid saved history does not prevent fresh validated event");
    require([operation()[@"event"] isEqual:@1],@"rejected history cannot forge event sequence");
}
static void runRestoreOrdering(void) {
    savedReceipt=axs_cachekeeper_gurd_export_fixture();require([savedReceipt writeToFile:reportPath() atomically:YES],@"ordering saved Status fixture written");
    expectRestoredBeforeTask=YES;backgroundImmediatelyOnRegistration=YES;configure(YES);initialized();
    await(^BOOL {return [operation()[@"event"] isEqual:@2] && [operation()[@"phase"] isEqual:@"observed"];},@"earliest lifecycle callback follows saved restore and admits event2");
    require(atomic_load(&submissions)==1 && [receipt()[@"operations"][0][@"runtimeInfo"] isEqual:savedReceipt[@"runtimeInfo"]],@"registration-time lifecycle preserves producer history without duplicate submission");
}
static void runReportFailure(void) {
    configure(YES);initialized();
    // Restoring a validated producer snapshot invokes the actual Runtime observer
    // and attempts its real atomic save; no synthetic writable flag is injected.
    [axs_cachekeeper_gurd_engine restoreReceipt:axs_cachekeeper_gurd_export_fixture()];settled();
    await(^BOOL {return ![context()[@"reportWritable"] boolValue];},@"real missing Status directory fails report write");
    background();await(^BOOL {return [operation()[@"reason"] isEqual:@"reportWriteFailed"];},@"unwritable Runtime blocks action before Source");
    require(atomic_load(&hostChecks)==0 && atomic_load(&submissions)==0,@"report failure never reaches host boundary");
    NSNumber *generation=context()[@"configuration"];NSUInteger events=[receipt()[@"operations"] count];
    require([NSFileManager.defaultManager createDirectoryAtPath:[fixtureFolder stringByAppendingPathComponent:@"Status"] withIntermediateDirectories:YES attributes:nil error:NULL],@"repair owned Status fixture");
    require([context()[@"reportWritable"] boolValue],@"pending real report retries successfully");configure(YES);settled();
    require([context()[@"configuration"] isEqual:generation] && [receipt()[@"operations"] count]==events && atomic_load(&submissions)==0,@"report writability recovery alone is not new configuration");
    foreground();background();await(^BOOL {return [operation()[@"phase"] isEqual:@"observed"];},@"new lifecycle after report repair permits actual action");
}
static void runTask(NSString *scenario) {
    failTask=[scenario isEqual:@"invalid-task"];expireSynchronously=[scenario isEqual:@"sync-expire"];flipForeground=[scenario isEqual:@"foreground-task"];
    configure(YES);initialized();background();
    await(^BOOL {return [operation()[@"phase"] isEqual:@"skipped"];},@"unusable UIKit grant skips action");settled();
    require([operation()[@"reason"] isEqual:@"noBackgroundTime"] && atomic_load(&hostChecks)==0 && atomic_load(&submissions)==0,@"invalid expired or foreground UIKit task never authorizes host");
    require(taskEnds==(failTask ? 0 : 1),@"unusable valid UIKit token is ended exactly once");
}
static void runStrict(void) {
    configure(YES);initialized();background();await(^BOOL {return [operation()[@"phase"] isEqual:@"observed"];},@"strict case has actual producer receipt");settled();
    NSMutableDictionary *private=[receipt() mutableCopy];private[@"home"]=fixtureHome;
    require(!axs_cachekeeper_gurd_receipt_projection(private),@"strict receipt rejects private path key");
    NSMutableDictionary *badOperation=[operation() mutableCopy];badOperation[@"fingerprint"]=@"private-owned-installation";
    private=[receipt() mutableCopy];private[@"operations"]=@[badOperation];
    require(!axs_cachekeeper_gurd_receipt_projection(private),@"strict operation rejects private identity");
    [badOperation removeObjectForKey:@"fingerprint"];[badOperation removeObjectForKey:@"runtimeInfo"];private[@"operations"]=@[badOperation];
    require(!axs_cachekeeper_gurd_receipt_projection(private),@"strict operation requires producer identity");
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:report() format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
    NSString *xml=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    require(![xml containsString:fixtureHome] && ![xml containsString:@"private-owned-installation"],@"persisted receipt excludes paths and fingerprints");
}
int main(int argc,const char *argv[]) {@autoreleasepool {
    require(argc==3 && NSThread.isMainThread,@"scenario and owned fixture directory arguments");
    NSString *scenario=[NSString stringWithUTF8String:argv[1]];fixtureHome=[NSString stringWithUTF8String:argv[2]];
    fixtureFolder=[fixtureHome stringByAppendingPathComponent:@"shared"];fixtureRoot=[fixtureHome stringByAppendingPathComponent:@"Library/Application Support/gurd_cache"];fixtureFile=[fixtureRoot stringByAppendingPathComponent:@"asset"];
    require([NSFileManager.defaultManager createDirectoryAtPath:fixtureRoot withIntermediateDirectories:YES attributes:nil error:NULL] &&
        [NSFileManager.defaultManager createDirectoryAtPath:fixtureFolder withIntermediateDirectories:YES attributes:nil error:NULL],@"owned fixture roots created");
    if (![scenario isEqual:@"report-failure"]) require([NSFileManager.defaultManager createDirectoryAtPath:[fixtureFolder stringByAppendingPathComponent:@"Status"] withIntermediateDirectories:YES attributes:nil error:NULL],@"owned Status directory created");
    require([[NSMutableData dataWithLength:16384] writeToFile:fixtureFile atomically:YES],@"actual fixture asset written");writeConfiguration(enabledState(),selectedRoot());
    if ([scenario isEqual:@"enabled"]) runEnabled();
    else if ([@[@"disabled",@"malformed",@"build-mismatch",@"version-mismatch"] containsObject:scenario]) runBlocked(scenario);
    else if ([scenario isEqual:@"restore"]) runRestore();
    else if ([scenario isEqual:@"restore-invalid"]) runRejectedRestore();
    else if ([scenario isEqual:@"restore-ordering"]) runRestoreOrdering();
    else if ([scenario isEqual:@"report-failure"]) runReportFailure();
    else if ([@[@"invalid-task",@"sync-expire",@"foreground-task"] containsObject:scenario]) runTask(scenario);
    else if ([scenario isEqual:@"strict"]) runStrict();
    else require(NO,@"known scenario");
    printf("PASS: gurd-runtime %s\n",scenario.UTF8String);return 0;
}}
