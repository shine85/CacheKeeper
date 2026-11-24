#import "AxsCacheKeeperImageCacheRuntime.h"
#import "AxsCacheKeeperImageCache.h"
#import "AxsCacheKeeperInstallation.h"
#import "AxsCacheKeeperRuntimeBuild.h"
#import "AxsCacheKeeperPolicy.h"
#import <UIKit/UIKit.h>
#include <roothide.h>
#include <mach-o/dyld.h>
#include <stdatomic.h>
#include <stdbool.h>

static AxsCacheKeeperImageCache *axs_cachekeeper_image_engine;
static NSObject *axs_cachekeeper_image_context_lock;
static _Atomic(BOOL) axs_cachekeeper_image_access;
static NSDictionary *axs_cachekeeper_image_installation;
static NSMutableDictionary *axs_cachekeeper_image_pending_report;
static BOOL axs_cachekeeper_image_report_writable=YES;
static AxsCacheKeeperImageCoordinator *axs_cachekeeper_image_coordinator;
static atomic_bool axs_cachekeeper_image_discovery_pending;
static dispatch_queue_t axs_cachekeeper_image_policy_queue;
static NSDictionary *axs_cachekeeper_image_policy_snapshot;
static _Atomic(unsigned long) axs_cachekeeper_image_policy_generation;
static NSUInteger axs_cachekeeper_image_notified_policy;
static _Atomic(unsigned long) axs_cachekeeper_image_access_generation;
// UIKit lifecycle owns these values; worker callbacks carry only policy tokens.
static BOOL axs_cachekeeper_image_background;
static NSUInteger axs_cachekeeper_image_lifecycle;
extern void axs_cachekeeper_image_runtime_view_changed(void);

static NSString *AxsCacheKeeperImageFolder(void) { return jbroot(@"/var/mobile/Library/CacheKeeper"); }
static NSDictionary *AxsCacheKeeperImagePolicy(NSDictionary *context) {
    return [context dictionaryWithValuesForKeys:@[@"valid",@"appState",@"selected",@"home",@"bundle",@"version",@"installation"]];
}
static void AxsCacheKeeperImageFlushReport(void) {
    if (!axs_cachekeeper_image_pending_report) return;
    NSString *bundle=NSBundle.mainBundle.bundleIdentifier;
    NSString *path=[[AxsCacheKeeperImageFolder() stringByAppendingPathComponent:@"Status"] stringByAppendingPathComponent:[bundle stringByAppendingString:@".imagecache.plist"]];
    axs_cachekeeper_operation_save(nil,path,axs_cachekeeper_image_access,&axs_cachekeeper_image_pending_report,&axs_cachekeeper_image_report_writable);
}
static NSDictionary *AxsCacheKeeperImageContext(void) {
    @synchronized(axs_cachekeeper_image_context_lock) {
        AxsCacheKeeperImageFlushReport();
        NSError *stateError=nil,*selectionError=nil;
        NSString *folder=AxsCacheKeeperImageFolder(),*bundle=NSBundle.mainBundle.bundleIdentifier;
        NSDictionary *states=axs_cachekeeper_read_input([folder stringByAppendingPathComponent:@"appEnabled.plist"],&stateError);
        NSDictionary *selected=axs_cachekeeper_read_input([folder stringByAppendingPathComponent:@"directories.plist"],&selectionError);
        id state=states[bundle] ?: @NO;
        BOOL valid=axs_cachekeeper_image_access && !stateError && !selectionError && axs_cachekeeper_state_valid(state);
        NSString *version=[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"],*installation=@"";
        NSError *installationError=nil;
        BOOL installationRequested=valid && axs_cachekeeper_app_enabled(state);
        if (installationRequested) {
            if (!axs_cachekeeper_image_installation || !axs_cachekeeper_validate_installation_snapshot_with_context(axs_cachekeeper_image_installation,NSBundle.mainBundle.bundleURL,version,AxsCacheKeeperInstallationContextHostMainBundle,&installationError)) {
                installationError=nil;
                axs_cachekeeper_image_installation=axs_cachekeeper_installation_snapshot_with_context(NSBundle.mainBundle.bundleURL,bundle,version,AxsCacheKeeperInstallationContextHostMainBundle,&installationError);
            }
            if ([axs_cachekeeper_image_installation[@"installationState"] isEqual:@"verified"])
                installation=axs_cachekeeper_image_installation[@"fingerprint"] ?: @"";
        }
        NSMutableDictionary *context=[@{@"valid":@(valid),@"appState":state,@"selected":selected[bundle] ?: @[],
            @"home":NSHomeDirectory(),@"bundle":bundle ?: @"",@"version":version ?: @"",
            @"installation":installation,@"installationCheck":axs_cachekeeper_installation_check_result(installationRequested,axs_cachekeeper_image_installation,installationError),
            @"reportWritable":@(axs_cachekeeper_image_report_writable)} mutableCopy];
        if (installationRequested) {
            context[@"installationImage"]=axs_cachekeeper_installation_image_observation(
                axs_cachekeeper_image_installation,NSBundle.mainBundle.bundleURL,version);
        }
        // Retry state and sampled diagnostic timestamps are evidence, not policy.
        NSDictionary *policy=AxsCacheKeeperImagePolicy(context);
        if (![axs_cachekeeper_image_policy_snapshot isEqual:policy]) {
            axs_cachekeeper_image_policy_snapshot=policy;
            atomic_fetch_add(&axs_cachekeeper_image_policy_generation,1);
        }
        return [context copy];
    }
}
static void AxsCacheKeeperImageDidLoad(const struct mach_header *header,intptr_t slide) {
    (void)header;(void)slide;
    axs_cachekeeper_image_runtime_view_changed();
    // No Objective-C class discovery or filesystem work while the dyld loader lock is held.
    if (atomic_exchange(&axs_cachekeeper_image_discovery_pending,true)) return;
    dispatch_async(dispatch_get_main_queue(),^{
        atomic_store(&axs_cachekeeper_image_discovery_pending,false);
        [axs_cachekeeper_image_engine requestDiscoveryRefresh];
    });
}
void axs_cachekeeper_configure_image_cache(BOOL containerEligible,BOOL configurationAccess) {
    if (!containerEligible) return;
    static dispatch_once_t once;
    dispatch_once(&once,^{
        axs_cachekeeper_image_context_lock=[NSObject new];
        axs_cachekeeper_image_access=configurationAccess;
        axs_cachekeeper_image_policy_queue=dispatch_queue_create("dev.local.cachekeeper.image.policy",DISPATCH_QUEUE_SERIAL);
        axs_cachekeeper_image_engine=[[AxsCacheKeeperImageCache alloc] initWithContextProvider:^NSDictionary *{return AxsCacheKeeperImageContext();}
            observer:^(NSDictionary *receipt) {
                @synchronized(axs_cachekeeper_image_context_lock) {
                    NSMutableDictionary *record=[receipt mutableCopy];record[@"runtimeInfo"]=axs_cachekeeper_runtime_info();
                    NSDictionary *valid=axs_cachekeeper_image_cache_raw_projection(record);
                    if (valid) {axs_cachekeeper_image_pending_report=[valid mutableCopy];AxsCacheKeeperImageFlushReport();}
                    else {axs_cachekeeper_image_report_writable=NO;NSLog(@"[CacheKeeper] 图片操作回执字段无效，保留待写历史");}
                }
                dispatch_async(dispatch_get_main_queue(),^{
                    [axs_cachekeeper_image_coordinator receiptDidChange];
                });
            }];
        axs_cachekeeper_image_coordinator=[[AxsCacheKeeperImageCoordinator alloc] initWithCache:axs_cachekeeper_image_engine
            beginBackground:^NSUInteger(void (^expiration)(void)) {
                UIBackgroundTaskIdentifier task=[UIApplication.sharedApplication beginBackgroundTaskWithName:@"CacheKeeper.ImageDiskCache" expirationHandler:expiration];
                return task==UIBackgroundTaskInvalid ? 0 : (NSUInteger)task+1;
            } endBackground:^(NSUInteger token) {[UIApplication.sharedApplication endBackgroundTask:(UIBackgroundTaskIdentifier)(token-1)];}
            backgroundTime:^BOOL(NSUInteger token) {return token && UIApplication.sharedApplication.applicationState==UIApplicationStateBackground && UIApplication.sharedApplication.backgroundTimeRemaining>1;}];
        NSString *receiptPath=[[AxsCacheKeeperImageFolder() stringByAppendingPathComponent:@"Status"] stringByAppendingPathComponent:[NSBundle.mainBundle.bundleIdentifier stringByAppendingString:@".imagecache.plist"]];
        [axs_cachekeeper_image_engine loadOperationHistoryFromPath:receiptPath];
        [axs_cachekeeper_image_engine startObserving];
        _dyld_register_func_for_add_image(AxsCacheKeeperImageDidLoad);
        _dyld_register_func_for_remove_image(AxsCacheKeeperImageDidLoad);
        dispatch_async(dispatch_get_main_queue(),^{
            NSNotificationCenter *center=NSNotificationCenter.defaultCenter;
            [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                (void)note;axs_cachekeeper_image_background=NO;axs_cachekeeper_image_lifecycle++;[axs_cachekeeper_image_coordinator didBecomeActive];
            }];
            [center addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                (void)note;axs_cachekeeper_image_background=YES;axs_cachekeeper_image_lifecycle++;
                [axs_cachekeeper_image_coordinator didEnterBackground];
            }];
        });
    });
    // Never wait for provider filesystem/identity IO on a lifecycle caller.
    BOOL accessChanged=atomic_exchange(&axs_cachekeeper_image_access,configurationAccess)!=configurationAccess;
    NSUInteger accessGeneration=accessChanged ? atomic_fetch_add(&axs_cachekeeper_image_access_generation,1)+1 : atomic_load(&axs_cachekeeper_image_access_generation);
    if (accessChanged) {
        [axs_cachekeeper_image_engine refreshWithCompletion:nil];
        void (^revoke)(void)=^{
            if (accessGeneration!=atomic_load(&axs_cachekeeper_image_access_generation)) return;
            [axs_cachekeeper_image_coordinator configurationDidChange];
        };
        if (NSThread.isMainThread) revoke();else dispatch_async(dispatch_get_main_queue(),revoke);
    }
    dispatch_async(axs_cachekeeper_image_policy_queue,^{
        NSUInteger policy;NSDictionary *snapshot;
        @synchronized(axs_cachekeeper_image_context_lock) {
            (void)AxsCacheKeeperImageContext();
            policy=atomic_load(&axs_cachekeeper_image_policy_generation);
            snapshot=axs_cachekeeper_image_policy_snapshot;
        }
        dispatch_async(dispatch_get_main_queue(),^{
            if (policy<=axs_cachekeeper_image_notified_policy) return;
            axs_cachekeeper_image_notified_policy=policy;
            // Inspect the context actually adopted by queued preparation, not a
            // token sampled at UIKit entry or a later SDK execution provider.
            NSUInteger lifecycle=axs_cachekeeper_image_lifecycle;
            [axs_cachekeeper_image_engine performAfterPendingWork:^(NSDictionary *adopted,NSUInteger generation) {
                BOOL applied=[AxsCacheKeeperImagePolicy(adopted) isEqual:snapshot];
                dispatch_async(dispatch_get_main_queue(),^{
                    if (policy!=atomic_load(&axs_cachekeeper_image_policy_generation) || policy!=axs_cachekeeper_image_notified_policy ||
                        lifecycle!=axs_cachekeeper_image_lifecycle || ![axs_cachekeeper_image_engine isCurrentWorkGeneration:generation]) return;
                    if (axs_cachekeeper_image_background && applied) return;
                    [axs_cachekeeper_image_coordinator configurationDidChange];
                    [axs_cachekeeper_image_engine refreshWithCompletion:nil];
                });
            }];
        });
    });
}
