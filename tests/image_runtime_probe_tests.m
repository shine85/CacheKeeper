// Reuse established host ABI fixtures; exercise the real engine, coordinator and Runtime.
#define main axs_cachekeeper_probe_existing_fixture_main
#import "image_runtime_source_tests.m"
#undef main
#import <UIKit/UIKit.h>
#import "AxsCacheKeeperInstallation.h"
static NSString *probeHome,*probeFolder,*probeIdentity=@"probe-installation";
static NSString *probeBundle=@"cachekeeper.owned.runtime.fixture";
static UIApplicationState probeState=UIApplicationStateActive;
static NSUInteger probeBegins,probeEnds;
static atomic_uint probeIdentityCalls;
NSString *axs_cachekeeper_image_runtime_fixture_folder(void) {return probeFolder;}
static NSString *probeHomeDirectory(void) {return probeHome;}
@interface AxsCacheKeeperProbeBundle : NSObject
+ (instancetype)mainBundle;
@property(nonatomic,readonly) NSString *bundleIdentifier;
@property(nonatomic,readonly) NSURL *bundleURL;
- (id)objectForInfoDictionaryKey:(NSString *)key;
@end
@implementation AxsCacheKeeperProbeBundle
+ (instancetype)mainBundle {static id instance;static dispatch_once_t once;dispatch_once(&once,^{instance=[self new];});return instance;}
- (NSString *)bundleIdentifier {return probeBundle;}
- (NSURL *)bundleURL {return [NSURL fileURLWithPath:probeHome];}
- (id)objectForInfoDictionaryKey:(NSString *)key {(void)key;return @"1";}
@end
NSDictionary *axs_cachekeeper_installation_snapshot_with_context(NSURL *url,NSString *bundle,NSString *version,AxsCacheKeeperInstallationContext kind,NSError **error) {
    (void)url;(void)bundle;(void)version;(void)kind;(void)error;
    axs_cachekeeper_runtime_require(!NSThread.isMainThread,"probe identity collection is off main");atomic_fetch_add(&probeIdentityCalls,1);
    return @{@"installationState":@"verified",@"fingerprint":probeIdentity};
}
BOOL axs_cachekeeper_validate_installation_snapshot_with_context(NSDictionary *value,NSURL *url,NSString *version,AxsCacheKeeperInstallationContext kind,NSError **error) {
    (void)url;(void)version;(void)kind;(void)error;
    axs_cachekeeper_runtime_require(!NSThread.isMainThread,"probe identity validation is off main");atomic_fetch_add(&probeIdentityCalls,1);
    return [value[@"fingerprint"] isEqual:probeIdentity];
}
NSDictionary *axs_cachekeeper_installation_image_observation(NSDictionary *value,NSURL *url,NSString *version) {(void)value;(void)url;(void)version;return @{@"state":@"unreadable"};}
#define NSBundle AxsCacheKeeperProbeBundle
#define NSHomeDirectory probeHomeDirectory
#ifdef AXS_CACHEKEEPER_PROBE_RUNTIME_INCLUDE
#import AXS_CACHEKEEPER_PROBE_RUNTIME_INCLUDE
#else
#import "AxsCacheKeeperImageCacheRuntime.m"
#endif
#undef NSHomeDirectory
#undef NSBundle
const UIBackgroundTaskIdentifier UIBackgroundTaskInvalid=NSUIntegerMax;
NSString * const UIApplicationDidBecomeActiveNotification=@"probe.active";
NSString * const UIApplicationDidEnterBackgroundNotification=@"probe.background";
@implementation UIApplication
+ (instancetype)sharedApplication {static id instance;static dispatch_once_t once;dispatch_once(&once,^{instance=[self new];});return instance;}
- (UIApplicationState)applicationState {return probeState;}
- (NSTimeInterval)backgroundTimeRemaining {return 30;}
- (UIBackgroundTaskIdentifier)beginBackgroundTaskWithName:(NSString *)name expirationHandler:(void (^)(void))expiration {(void)name;(void)expiration;return probeBegins++;}
- (void)endBackgroundTask:(UIBackgroundTaskIdentifier)task {axs_cachekeeper_runtime_require(NSThread.isMainThread && task<probeBegins,"probe exact UIKit task ends on main");probeEnds++;}
@end
static void probePump(NSTimeInterval seconds) {
    NSTimeInterval end=NSProcessInfo.processInfo.systemUptime+seconds;
    while(NSProcessInfo.processInfo.systemUptime<end) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.005]];
}
static void probeAwait(BOOL (^condition)(void),const char *message) {
    NSTimeInterval end=NSProcessInfo.processInfo.systemUptime+8;
    while(!condition() && NSProcessInfo.processInfo.systemUptime<end) probePump(.01);
    axs_cachekeeper_runtime_require(condition(),message);
}
static void probeWrite(BOOL enabled,NSArray *selected) {
    NSString *bundle=probeBundle;
    axs_cachekeeper_runtime_require([@{bundle:@{@"enabled":@(enabled),@"mode":@"auto",@"autoDiscover":@NO}} writeToFile:[probeFolder stringByAppendingPathComponent:@"appEnabled.plist"] atomically:YES] &&
        [@{bundle:selected} writeToFile:[probeFolder stringByAppendingPathComponent:@"directories.plist"] atomically:YES],"probe real policy plists written");
}
static NSUInteger probeConfigurationEvents(void) {
    NSUInteger count=0;for(NSDictionary *process in axs_cachekeeper_image_engine.receipt[@"operationHistory"][@"processes"])
        for(NSDictionary *event in process[@"events"]) if([event[@"trigger"] isEqual:@"configuration"]) count++;
    return count;
}
static void probeBackground(void) {probeState=UIApplicationStateBackground;[NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidEnterBackgroundNotification object:nil];}
static void probeForeground(void) {probeState=UIApplicationStateActive;[NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];}
static void probeReceiptIO(AxsCacheKeeperImageCache *engine,SDImageCache *owner) {
    dispatch_sync(engine.work,^{});
    axs_cachekeeper_runtime_require([engine.receipt[@"restricted"] unsignedIntegerValue]==1,"receipt IO case begins with an active write restriction");
    unsigned writes=atomic_load(&axs_cachekeeper_runtime_writes);
    [owner.diskCache setData:[@"blocked before foreground" dataUsingEncoding:NSUTF8StringEncoding] forKey:@"receipt-io-blocked"];
    axs_cachekeeper_runtime_require(atomic_load(&axs_cachekeeper_runtime_writes)==writes,"actual nonempty SDK write is blocked before foreground revocation");
    void (^original)(NSDictionary *)=[engine.observer copy];
    dispatch_semaphore_t held=dispatch_semaphore_create(0),entered=dispatch_semaphore_create(0);
    dispatch_semaphore_t returned=dispatch_semaphore_create(0),released=dispatch_semaphore_create(0);
    __block BOOL returnedWhileHeld=NO;
    engine.observer=^(NSDictionary *receipt) {dispatch_semaphore_signal(entered);original(receipt);};
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        @synchronized(axs_cachekeeper_image_context_lock) {
            dispatch_semaphore_signal(held);
            returnedWhileHeld=dispatch_semaphore_wait(returned,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC))==0;
        }
        dispatch_semaphore_signal(released);
    });
    axs_cachekeeper_runtime_require(dispatch_semaphore_wait(held,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0,"receipt IO context is held");
    dispatch_async(engine.work,^{[engine axs_cachekeeper_publish];});
    axs_cachekeeper_runtime_require(dispatch_semaphore_wait(entered,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0,"actual Runtime observer reaches held receipt IO");
    // The timeout belongs to the holder: a regressed main-thread call is released
    // and fails explicitly instead of hanging the test process indefinitely.
    probeForeground();
    NSDictionary *snapshot=engine.receipt;
    NSData *payload=[@"foreground write after synchronous revocation" dataUsingEncoding:NSUTF8StringEncoding];
    axs_cachekeeper_runtime_lazy_root=YES;
    [owner.diskCache setData:payload forKey:@"receipt-io-write"];
    dispatch_semaphore_signal(returned);
    axs_cachekeeper_runtime_require(dispatch_semaphore_wait(released,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0,"receipt IO holder finishes");
    axs_cachekeeper_runtime_require(returnedWhileHeld,"foreground and receipt access never wait for receipt IO");
    axs_cachekeeper_runtime_require(snapshot && [[NSData dataWithContentsOfFile:[owner.diskCachePath stringByAppendingPathComponent:@"receipt-io-write"]] isEqual:payload],"foreground revocation reaches original nonempty writer while report IO is held");
    dispatch_sync(engine.work,^{});
    engine.observer=original;
    NSString *path=[[probeFolder stringByAppendingPathComponent:@"Status"] stringByAppendingPathComponent:[probeBundle stringByAppendingString:@".imagecache.plist"]];
    axs_cachekeeper_runtime_require(axs_cachekeeper_image_cache_raw_projection([NSDictionary dictionaryWithContentsOfFile:path])!=nil,"real Runtime observer still persists valid receipt after IO resumes");
}
static void probeReceiptOrder(AxsCacheKeeperImageCache *engine) {
    dispatch_sync(engine.work,^{});
    void (^original)(NSDictionary *)=[engine.observer copy];
    dispatch_semaphore_t first=dispatch_semaphore_create(0),release=dispatch_semaphore_create(0);
    dispatch_semaphore_t attempting=dispatch_semaphore_create(0),second=dispatch_semaphore_create(0);
    dispatch_group_t publishers=dispatch_group_create();
    NSMutableArray<NSDate *> *finished=[NSMutableArray new];
    __block NSUInteger ordinal=0;
    engine.observer=^(NSDictionary *receipt) {
        NSUInteger current;@synchronized(finished) {current=++ordinal;}
        if (current==1) {
            dispatch_semaphore_signal(first);
            axs_cachekeeper_runtime_require(dispatch_semaphore_wait(release,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0,"first receipt publisher released");
        } else dispatch_semaphore_signal(second);
        original(receipt);
        @synchronized(finished) {[finished addObject:receipt[@"updated"]];}
    };
    dispatch_group_async(publishers,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{[engine axs_cachekeeper_publish];});
    axs_cachekeeper_runtime_require(dispatch_semaphore_wait(first,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0,"first receipt observer entered");
    dispatch_group_async(publishers,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{dispatch_semaphore_signal(attempting);[engine axs_cachekeeper_publish];});
    axs_cachekeeper_runtime_require(dispatch_semaphore_wait(attempting,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0,"second receipt publisher starts concurrently");
    BOOL overtook=dispatch_semaphore_wait(second,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0;
    dispatch_semaphore_signal(release);
    axs_cachekeeper_runtime_require(dispatch_group_wait(publishers,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0,"both receipt publishers finish");
    engine.observer=original;
    NSString *path=[[probeFolder stringByAppendingPathComponent:@"Status"] stringByAppendingPathComponent:[probeBundle stringByAppendingString:@".imagecache.plist"]];
    NSDate *saved=[NSDictionary dictionaryWithContentsOfFile:path][@"updated"];
    axs_cachekeeper_runtime_require(!overtook && finished.count==2 && [finished[0] compare:finished[1]]!=NSOrderedDescending && [saved isEqual:finished.lastObject],"receipt callbacks stay ordered and newest snapshot remains on disk");
}
int main(int argc,const char *argv[]) {@autoreleasepool {
    axs_cachekeeper_runtime_require(argc==3,"probe scenario and temporary home supplied");probeHome=[NSString stringWithUTF8String:argv[2]];probeFolder=[probeHome stringByAppendingPathComponent:@"shared"];
    if (!strcmp(argv[1],"collection") || !strcmp(argv[1],"preparation")) probeBundle=@"com.baidu.netdisk";
    axs_cachekeeper_runtime_require([NSFileManager.defaultManager createDirectoryAtPath:[probeFolder stringByAppendingPathComponent:@"Status"] withIntermediateDirectories:YES attributes:nil error:nil],"probe configuration directory created");
    for(uint32_t i=0;i<_dyld_image_count();i++) if(_dyld_get_image_header(i)->filetype==MH_EXECUTE) axs_cachekeeper_runtime_main_header=_dyld_get_image_header(i);
    axs_cachekeeper_runtime_fingerprinted=YES;axs_cachekeeper_runtime_helper_original=method_getImplementation(class_getClassMethod(AxsCacheKeeperRuntimeSourceHelper.class,@selector(axs_cachekeeper_sample)));
    probeWrite(YES,@[@"Library/Caches"]);axs_cachekeeper_configure_image_cache(YES,YES);probePump(.25);
    AxsCacheKeeperImageCache *engine=axs_cachekeeper_image_engine;
    __attribute__((objc_precise_lifetime)) SDImageCache *owner=[[SDImageCache alloc] initWithNamespace:@"probe" diskCacheDirectory:[probeHome stringByAppendingPathComponent:@"Library/Caches"] config:[SDImageCacheConfig new]];
    probeAwait(^BOOL {return [engine.receipt[@"eligible"] unsignedIntegerValue]==1;},"probe actual host owner is admitted");
    if (!strcmp(argv[1],"receipt-io") || !strcmp(argv[1],"receipt-order")) {
        if (!strcmp(argv[1],"receipt-io")) probeReceiptIO(engine,owner);else probeReceiptOrder(engine);
        printf("PASS: image-runtime-probe %s\n",argv[1]);return 0;
    }
    if (!strcmp(argv[1],"preparation")) {
        NSString *receiptPath=[[probeFolder stringByAppendingPathComponent:@"Status"] stringByAppendingPathComponent:[probeBundle stringByAppendingString:@".imagecache.plist"]];
        probeAwait(^BOOL{return [NSDictionary dictionaryWithContentsOfFile:receiptPath][@"eligible"]!=nil;},"real Runtime producer publishes actual shared receipt");
        dispatch_sync(engine.work,^{});
        NSMutableDictionary *aged=[[NSDictionary dictionaryWithContentsOfFile:receiptPath] mutableCopy];aged[@"updated"]=[NSDate dateWithTimeIntervalSinceNow:-601];
        axs_cachekeeper_runtime_require([aged writeToFile:receiptPath atomically:YES],"model elapsed full-capacity wait on producer receipt");
        NSError *error=nil;AxsCacheKeeperImageCollectionSession *session=[[AxsCacheKeeperImageCollectionSession alloc] initWithFolder:probeFolder sessionID:@"dddddddddddddddddddddddddddddddd" error:&error];
        axs_cachekeeper_runtime_require([session prepareBundle:probeBundle error:&error] && [[session refreshPreparation:&error][@"state"] isEqual:@"awaitingRefresh"],"consumer prepares stale producer without bypassing admission");
        NSData *settings=[NSData dataWithContentsOfFile:[probeFolder stringByAppendingPathComponent:@"appEnabled.plist"]];
        axs_cachekeeper_runtime_require(!axs_cachekeeper_image_collection_read(probeFolder,NULL),"selection never sends runtime lease");
        probeForeground();
        probeAwait(^BOOL{return [[session refreshPreparation:NULL][@"state"] isEqual:@"readyToStart"];},"actual foreground producer refresh readies consumer in same session");
        axs_cachekeeper_runtime_require([session startWithBundle:probeBundle error:&error],"explicit confirmation sends freshly bound request");
        axs_cachekeeper_configure_image_cache(YES,YES);
        probeAwait(^BOOL{return [engine.receipt[@"imageCollection"][@"sessionID"] isEqual:@"dddddddddddddddddddddddddddddddd"] && [engine.receipt[@"restricted"] unsignedIntegerValue]==1;},"real Runtime acknowledges fresh prepared request");
        axs_cachekeeper_runtime_require([[NSData dataWithContentsOfFile:[probeFolder stringByAppendingPathComponent:@"appEnabled.plist"]] isEqual:settings],"producer-consumer preparation preserves user configuration");
        printf("PASS: image-runtime-probe preparation\n");return 0;
    }
    if (!strcmp(argv[1],"collection")) {
        NSString *statesPath=[probeFolder stringByAppendingPathComponent:@"appEnabled.plist"];
        NSDictionary *baseState=@{@"enabled":@YES,@"mode":@"prevent",@"autoDiscover":@NO};
        axs_cachekeeper_runtime_require([@{probeBundle:baseState} writeToFile:statesPath atomically:YES],"collection real prevent baseline saved");
        axs_cachekeeper_configure_image_cache(YES,YES);
        probeAwait(^BOOL{return [engine.receipt[@"restricted"] unsignedIntegerValue]==1;},"collection original prevent applied");
        [owner.diskCache setData:[@"old" dataUsingEncoding:NSUTF8StringEncoding] forKey:@"old-count"];
        NSTimeInterval now=NSDate.date.timeIntervalSince1970;
        NSDictionary *base=@{@"bundle":probeBundle,@"appState":baseState,@"selected":@[@"Library/Caches"]};
        NSMutableDictionary *request=[@{@"schemaVersion":@1,@"sessionID":@"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",@"requestID":@"11111111111111111111111111111111",
            @"bundle":probeBundle,@"phase":@"prevent",@"step":@1,@"issuedAt":@(now),@"expiresAt":@(now+1),
            @"baselineSHA256":axs_cachekeeper_image_collection_baseline(base),@"processFirstObserved":axs_cachekeeper_runtime_info()[@"firstObserved"]} mutableCopy];
        axs_cachekeeper_runtime_require(axs_cachekeeper_capacity_atomic_write(request,probeFolder,@"imageCollectionRequest.plist",4096,NULL),"real dedicated lease request saved");
        probeBackground();
        probeAwait(^BOOL{return [engine.receipt[@"imageCollection"][@"requestID"] isEqual:request[@"requestID"]];},"natural background adopts actual image lease");
        NSDictionary *ack=engine.receipt[@"imageCollection"],*first=nil;
        for (NSDictionary *row in engine.receipt[@"writeObservation"][@"epochs"]) if ([ack[@"epochs"] containsObject:row[@"epoch"]]) first=row;
        axs_cachekeeper_runtime_require(first && [first[@"data"][@"nonemptyAttempts"] unsignedIntegerValue]==0,"new same-mode request never borrows prior writer counts");
        probeAwait(^BOOL{return [engine.receipt[@"imageCollection"][@"disposition"] isEqual:@"expired"];},"lease expires and engine re-adopts original configuration");
        axs_cachekeeper_runtime_require([engine.receipt[@"restricted"] unsignedIntegerValue]==1,"expired overlay restores true base prevent rather than permanent fail-open");
        NSString *oldRequest=request[@"requestID"];
        NSData *before=[NSData dataWithContentsOfFile:statesPath];
        request[@"phase"]=@"disabled";request[@"step"]=@3;request[@"requestID"]=@"33333333333333333333333333333333";
        request[@"issuedAt"]=@(NSDate.date.timeIntervalSince1970);request[@"expiresAt"]=@(NSDate.date.timeIntervalSince1970+30);
        axs_cachekeeper_runtime_require(axs_cachekeeper_capacity_atomic_write(request,probeFolder,@"imageCollectionRequest.plist",4096,NULL),"disabled image-only request saved");
        axs_cachekeeper_configure_image_cache(YES,YES);
        probeAwait(^BOOL{return [engine.receipt[@"imageCollection"][@"phase"] isEqual:@"disabled"] && [engine.receipt[@"state"] isEqual:@"disabled"];},"disabled overlay acknowledged");
        NSUInteger newGeneration=engine.generation;
        [engine requestCollectionExpiryRefresh:oldRequest];probePump(.1);
        axs_cachekeeper_runtime_require(engine.generation==newGeneration,"late expiry timer cannot revoke a newer request");
        axs_cachekeeper_runtime_require([engine.context[@"installation"] length]>0 && [[NSData dataWithContentsOfFile:statesPath] isEqual:before],"effective disabled still validates original installation without writing config");
        probeWrite(NO,@[]);axs_cachekeeper_configure_image_cache(YES,YES);
        probeAwait(^BOOL{return [engine.receipt[@"imageCollection"][@"disposition"] isEqual:@"configurationChanged"];},"user base change revokes active overlay");
        axs_cachekeeper_runtime_require([@{probeBundle:baseState} writeToFile:statesPath atomically:YES],"restore original fixture base after revocation");
        axs_cachekeeper_runtime_require([@{probeBundle:@[@"Library/Caches"]} writeToFile:[probeFolder stringByAppendingPathComponent:@"directories.plist"] atomically:YES],"restore original fixture scope");
        axs_cachekeeper_configure_image_cache(YES,YES);probePump(.2);
        axs_cachekeeper_runtime_require([engine.receipt[@"imageCollection"][@"disposition"] isEqual:@"configurationChanged"],"revoked request never reactivates when base changes back");
        NSMutableDictionary *shortLease=[request mutableCopy];
        shortLease[@"sessionID"]=@"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";shortLease[@"requestID"]=@"55555555555555555555555555555555";
        shortLease[@"phase"]=@"prevent";shortLease[@"step"]=@1;
        shortLease[@"issuedAt"]=@(NSDate.date.timeIntervalSince1970);shortLease[@"expiresAt"]=@(NSDate.date.timeIntervalSince1970+.1);
        axs_cachekeeper_runtime_require(axs_cachekeeper_capacity_atomic_write(shortLease,probeFolder,@"imageCollectionRequest.plist",4096,NULL),"short lease saved before delayed adoption");
        __block BOOL holdFirstAdoption=YES;
        engine.provider=^NSDictionary *{
            NSDictionary *context=AxsCacheKeeperImageContext();
            if (holdFirstAdoption && [context[@"imageCollection"][@"disposition"] isEqual:@"applied"]) {
                holdFirstAdoption=NO;[NSThread sleepForTimeInterval:.25];
            }
            return context;
        };
        [engine refreshWithCompletion:nil];
        probeAwait(^BOOL{return [engine.receipt[@"imageCollection"][@"requestID"] isEqual:shortLease[@"requestID"]] &&
            [engine.receipt[@"imageCollection"][@"disposition"] isEqual:@"expired"] && [engine.receipt[@"restricted"] unsignedIntegerValue]==1;},
            "lease expiring before first acknowledgement autonomously restores base without another lifecycle event");
        axs_cachekeeper_runtime_require(!holdFirstAdoption,"expiry fixture actually held a valid incoming provider context");
        printf("PASS: image-runtime-probe collection\n");return 0;
    }
    dispatch_semaphore_t entered=dispatch_semaphore_create(0),release=dispatch_semaphore_create(0);
    dispatch_async(owner.ioQueue,^{dispatch_semaphore_signal(entered);axs_cachekeeper_runtime_require(dispatch_semaphore_wait(release,dispatch_time(DISPATCH_TIME_NOW,8*NSEC_PER_SEC))==0,"probe SDK queue released in budget");});
    axs_cachekeeper_runtime_require(dispatch_semaphore_wait(entered,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC))==0,"probe actual host SDK queue held");
    if(!strcmp(argv[1],"delayed")) {
        // Sample a changed selection off main, queue its main notice, then begin
        // background before letting that notice run. Its policy is already current.
        probeWrite(YES,@[@"Library/Caches/probe"]);axs_cachekeeper_configure_image_cache(YES,YES);
        dispatch_sync(axs_cachekeeper_image_policy_queue,^{});
    }
    if(!strcmp(argv[1],"late-provider")) {
        dispatch_semaphore_t workerEntered=dispatch_semaphore_create(0),workerRelease=dispatch_semaphore_create(0);
        dispatch_async(engine.work,^{dispatch_semaphore_signal(workerEntered);axs_cachekeeper_runtime_require(dispatch_semaphore_wait(workerRelease,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0,"background preparation fence released");});
        axs_cachekeeper_runtime_require(dispatch_semaphore_wait(workerEntered,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC))==0,"old worker held before background trigger");
        probeBackground();probeWrite(YES,@[@"Library/Caches/probe"]);axs_cachekeeper_configure_image_cache(YES,YES);
        dispatch_sync(axs_cachekeeper_image_policy_queue,^{});dispatch_semaphore_signal(workerRelease);
    } else {probeBackground();}
    probeAwait(^BOOL {return [engine.receipt[@"pending"] unsignedIntegerValue]==1;},"probe real Runtime schedules in-flight action");
    NSUInteger generation=engine.generation,events=probeConfigurationEvents(),ended=probeEnds;
    if (!strcmp(argv[1],"same")) {
        NSTimeInterval now=NSDate.date.timeIntervalSince1970;
        NSDictionary *other=@{@"schemaVersion":@1,@"sessionID":@"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",@"requestID":@"11111111111111111111111111111111",
            @"bundle":@"com.baidu.netdisk",@"phase":@"prevent",@"step":@1,@"issuedAt":@(now),@"expiresAt":@(now+60),
            @"baselineSHA256":@"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",@"processFirstObserved":@1};
        axs_cachekeeper_runtime_require(axs_cachekeeper_capacity_atomic_write(other,probeFolder,@"imageCollectionRequest.plist",4096,NULL),"unrelated APP lease fixture written");
        notify_post(AxsCacheKeeperImageCollectionChanged.UTF8String);probePump(.2);
        axs_cachekeeper_runtime_require(engine.generation==generation && probeConfigurationEvents()==events && probeEnds==ended,"other APP collection notification never cancels this APP work");
    }
    for(NSUInteger i=0;i<5;i++) axs_cachekeeper_configure_image_cache(YES,YES);probePump(.3);
    axs_cachekeeper_runtime_require(engine.generation==generation && probeConfigurationEvents()==events && probeEnds==ended,"identical Runtime probe preserves in-flight generation event and UIKit task");
    BOOL changed=!strcmp(argv[1],"changed"),accessChanged=!strcmp(argv[1],"access") || !strcmp(argv[1],"rapid"),installationChanged=!strcmp(argv[1],"installation");
    if(changed) {probeWrite(NO,@[]);axs_cachekeeper_configure_image_cache(YES,YES);}
    if(accessChanged) {
        dispatch_semaphore_t locked=dispatch_semaphore_create(0),unlock=dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@synchronized(axs_cachekeeper_image_context_lock) {
            dispatch_semaphore_signal(locked);axs_cachekeeper_runtime_require(dispatch_semaphore_wait(unlock,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0,"held provider IO released");
        }});
        axs_cachekeeper_runtime_require(dispatch_semaphore_wait(locked,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC))==0,"provider IO lock deliberately held");
        NSTimeInterval start=NSProcessInfo.processInfo.systemUptime;axs_cachekeeper_configure_image_cache(YES,NO);
        axs_cachekeeper_runtime_require(NSProcessInfo.processInfo.systemUptime-start<.2,"access revocation never waits for provider IO lock");
        dispatch_semaphore_signal(unlock);
    }
    if(installationChanged) {probeIdentity=@"probe-new-installation";axs_cachekeeper_configure_image_cache(YES,YES);}
    if(!strcmp(argv[1],"rapid")) {probeWrite(YES,@[]);axs_cachekeeper_configure_image_cache(YES,YES);}
    if(changed || accessChanged || installationChanged) probeAwait(^BOOL {return engine.generation>generation && probeEnds>ended;},"changed Runtime policy cancels pending action and platform time");
    dispatch_semaphore_signal(release);
    probeAwait(^BOOL {return [engine.receipt[@"pending"] unsignedIntegerValue]==0;},"probe actual queued action retires");
    axs_cachekeeper_runtime_require(atomic_load(&axs_cachekeeper_runtime_clears)==((changed || accessChanged || installationChanged) ? 0 : 1),"only unchanged Runtime policy enters host clear");
    if(changed) {unsigned calls=atomic_load(&probeIdentityCalls);for(NSUInteger i=0;i<3;i++) axs_cachekeeper_configure_image_cache(YES,YES);probePump(.15);axs_cachekeeper_runtime_require(atomic_load(&probeIdentityCalls)==calls,"disabled Runtime probes never request identity");}
    probeForeground();(void)owner;printf("PASS: image-runtime-probe %s\n",argv[1]);return 0;
}}
