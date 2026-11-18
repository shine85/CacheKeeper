#import "AxsCacheKeeperImageCacheRuntime.h"
#import "AxsCacheKeeperImageCache.h"
#import "AxsCacheKeeperInstallation.h"
#import "AxsCacheKeeperImageLegacySource.h"
#import "AxsCacheKeeperRuntimeBuild.h"
#import "AxsCacheKeeperPolicy.h"
#import <UIKit/UIKit.h>
#include <roothide.h>
#include <mach-o/dyld.h>
#include <stdatomic.h>
#include <stdbool.h>

static AxsCacheKeeperImageCache *axs_cachekeeper_image_engine;
static NSObject *axs_cachekeeper_image_context_lock;
static BOOL axs_cachekeeper_image_access;
static NSDictionary *axs_cachekeeper_image_installation;
static NSMutableDictionary *axs_cachekeeper_image_pending_report;
static BOOL axs_cachekeeper_image_report_writable=YES;
static UIBackgroundTaskIdentifier axs_cachekeeper_image_background;
static BOOL axs_cachekeeper_image_had_pending;
static atomic_bool axs_cachekeeper_image_discovery_pending;
extern void axs_cachekeeper_image_runtime_view_changed(void);

static NSString *AxsCacheKeeperImageFolder(void) { return jbroot(@"/var/mobile/Library/CacheKeeper"); }
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
            struct mach_header_64 mainHeader;
            BOOL read=AxsCacheKeeperImageLegacyRead((uintptr_t)_dyld_get_image_header(0),&mainHeader,sizeof(mainHeader),VM_PROT_READ) && mainHeader.magic==MH_MAGIC_64;
            context[@"installationImage"]=read ? axs_cachekeeper_installation_image_observation(axs_cachekeeper_image_installation,NSBundle.mainBundle.bundleURL,version,mainHeader.cputype,mainHeader.cpusubtype) :
                @{@"schemaVersion":@1,@"state":@"notVerified",@"reason":@"read",@"mappingBackingIdentity":@"notVerified"};
        }
        return [context copy];
    }
}
static void AxsCacheKeeperImageEndBackground(void) {
    if (axs_cachekeeper_image_background==UIBackgroundTaskInvalid) return;
    UIBackgroundTaskIdentifier task=axs_cachekeeper_image_background;axs_cachekeeper_image_background=UIBackgroundTaskInvalid;
    axs_cachekeeper_image_had_pending=NO;[UIApplication.sharedApplication endBackgroundTask:task];
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
        // UIKit exports this value; initialize it before any observer can finish a task.
        axs_cachekeeper_image_background=UIBackgroundTaskInvalid;
        axs_cachekeeper_image_context_lock=[NSObject new];
        axs_cachekeeper_image_access=configurationAccess;
        axs_cachekeeper_image_engine=[[AxsCacheKeeperImageCache alloc] initWithContextProvider:^NSDictionary *{return AxsCacheKeeperImageContext();}
            observer:^(NSDictionary *receipt) {
                @synchronized(axs_cachekeeper_image_context_lock) {
                    NSMutableDictionary *record=[receipt mutableCopy];record[@"runtimeInfo"]=axs_cachekeeper_runtime_info();
                    NSDictionary *valid=axs_cachekeeper_image_cache_raw_projection(record);
                    if (valid) {axs_cachekeeper_image_pending_report=[valid mutableCopy];AxsCacheKeeperImageFlushReport();}
                    else {axs_cachekeeper_image_report_writable=NO;NSLog(@"[CacheKeeper] 图片操作回执字段无效，保留待写历史");}
                }
                dispatch_async(dispatch_get_main_queue(),^{
                    if ([receipt[@"pending"] unsignedIntegerValue]) axs_cachekeeper_image_had_pending=YES;
                    else if (axs_cachekeeper_image_had_pending || [@[@"disabled",@"blocked",@"unsupported",@"notObserved"] containsObject:receipt[@"state"]])
                        AxsCacheKeeperImageEndBackground();
                });
            }];
        NSString *receiptPath=[[AxsCacheKeeperImageFolder() stringByAppendingPathComponent:@"Status"] stringByAppendingPathComponent:[NSBundle.mainBundle.bundleIdentifier stringByAppendingString:@".imagecache.plist"]];
        [axs_cachekeeper_image_engine loadOperationHistoryFromPath:receiptPath];
        [axs_cachekeeper_image_engine startObserving];
        _dyld_register_func_for_add_image(AxsCacheKeeperImageDidLoad);
        _dyld_register_func_for_remove_image(AxsCacheKeeperImageDidLoad);
        dispatch_async(dispatch_get_main_queue(),^{
            NSNotificationCenter *center=NSNotificationCenter.defaultCenter;
            [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                (void)note;[axs_cachekeeper_image_engine didBecomeActive];AxsCacheKeeperImageEndBackground();
            }];
            [center addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                (void)note;
                if ([axs_cachekeeper_image_engine.receipt[@"eligible"] unsignedIntegerValue] && axs_cachekeeper_image_background==UIBackgroundTaskInvalid)
                    axs_cachekeeper_image_background=[UIApplication.sharedApplication beginBackgroundTaskWithName:@"CacheKeeper.ImageDiskCache" expirationHandler:^{
                        [axs_cachekeeper_image_engine expireBackgroundTime];AxsCacheKeeperImageEndBackground();
                    }];
                BOOL time=axs_cachekeeper_image_background!=UIBackgroundTaskInvalid && UIApplication.sharedApplication.backgroundTimeRemaining>1;
                [axs_cachekeeper_image_engine didEnterBackgroundWithTime:time];
            }];
        });
    });
    @synchronized(axs_cachekeeper_image_context_lock) {axs_cachekeeper_image_access=configurationAccess;}
    [axs_cachekeeper_image_engine refreshWithCompletion:nil];
}
