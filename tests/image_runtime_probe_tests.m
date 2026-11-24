// Reuse established host ABI fixtures; exercise the real engine, coordinator and Runtime.
#define main axs_cachekeeper_probe_existing_fixture_main
#import "image_runtime_source_tests.m"
#undef main
#import <UIKit/UIKit.h>
#import "AxsCacheKeeperInstallation.h"
static NSString *probeHome,*probeFolder,*probeIdentity=@"probe-installation";
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
- (NSString *)bundleIdentifier {return @"cachekeeper.owned.runtime.fixture";}
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
    NSString *bundle=@"cachekeeper.owned.runtime.fixture";
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
int main(int argc,const char *argv[]) {@autoreleasepool {
    axs_cachekeeper_runtime_require(argc==3,"probe scenario and temporary home supplied");probeHome=[NSString stringWithUTF8String:argv[2]];probeFolder=[probeHome stringByAppendingPathComponent:@"shared"];
    axs_cachekeeper_runtime_require([NSFileManager.defaultManager createDirectoryAtPath:[probeFolder stringByAppendingPathComponent:@"Status"] withIntermediateDirectories:YES attributes:nil error:nil],"probe configuration directory created");
    for(uint32_t i=0;i<_dyld_image_count();i++) if(_dyld_get_image_header(i)->filetype==MH_EXECUTE) axs_cachekeeper_runtime_main_header=_dyld_get_image_header(i);
    axs_cachekeeper_runtime_fingerprinted=YES;axs_cachekeeper_runtime_helper_original=method_getImplementation(class_getClassMethod(AxsCacheKeeperRuntimeSourceHelper.class,@selector(axs_cachekeeper_sample)));
    probeWrite(YES,@[@"Library/Caches"]);axs_cachekeeper_configure_image_cache(YES,YES);probePump(.25);
    AxsCacheKeeperImageCache *engine=axs_cachekeeper_image_engine;
    __attribute__((objc_precise_lifetime)) SDImageCache *owner=[[SDImageCache alloc] initWithNamespace:@"probe" diskCacheDirectory:[probeHome stringByAppendingPathComponent:@"Library/Caches"] config:[SDImageCacheConfig new]];
    probeAwait(^BOOL {return [engine.receipt[@"eligible"] unsignedIntegerValue]==1;},"probe actual host owner is admitted");
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
