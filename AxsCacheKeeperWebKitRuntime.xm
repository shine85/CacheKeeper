#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import "AxsCacheKeeperWebKitCache.h"
#import "AxsCacheKeeperWebKitObservation.h"
#import "AxsCacheKeeperWebKitCoordinator.h"
#import "AxsCacheKeeperInstallation.h"
#import "AxsCacheKeeperRuntimeBuild.h"
#import "AxsCacheKeeperPolicy.h"
#include <roothide.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <string.h>

static AxsCacheKeeperWebKitCache *axs_cachekeeper_webkit_engine;
static dispatch_queue_t axs_cachekeeper_webkit_io;
static BOOL axs_cachekeeper_webkit_access;
static BOOL axs_cachekeeper_webkit_hooks;
static AxsCacheKeeperWebKitObservation *axs_cachekeeper_webkit_observation;
static AxsCacheKeeperWebKitCoordinator *axs_cachekeeper_webkit_coordinator;
// The following fields belong only to the serial IO queue.
static NSDictionary *axs_cachekeeper_webkit_installation;
static NSMutableDictionary *axs_cachekeeper_webkit_pending_report;
static BOOL axs_cachekeeper_webkit_report_writable=YES;
static BOOL axs_cachekeeper_webkit_history_loaded;

static NSString *axs_cachekeeper_webkit_folder(void) {
    return jbroot(@"/var/mobile/Library/CacheKeeper");
}
static void axs_cachekeeper_webkit_flush_report(BOOL access) {
    if (!axs_cachekeeper_webkit_history_loaded || !axs_cachekeeper_webkit_pending_report) return;
    NSString *bundle=NSBundle.mainBundle.bundleIdentifier;
    NSString *path=[[axs_cachekeeper_webkit_folder() stringByAppendingPathComponent:@"Status"] stringByAppendingPathComponent:[bundle stringByAppendingString:@".webkit.plist"]];
    axs_cachekeeper_operation_save(nil,path,access,&axs_cachekeeper_webkit_pending_report,&axs_cachekeeper_webkit_report_writable);
}
static NSString *axs_cachekeeper_webkit_process(void) {
    return axs_cachekeeper_operation_process()[@"processID"];
}
static NSDictionary *axs_cachekeeper_webkit_read_context(BOOL access) {
    axs_cachekeeper_webkit_flush_report(access);
    NSError *error=nil;
    NSDictionary *states=axs_cachekeeper_read_input([axs_cachekeeper_webkit_folder() stringByAppendingPathComponent:@"appEnabled.plist"],&error);
    id state=states[NSBundle.mainBundle.bundleIdentifier];
    BOOL malformed=([error.domain isEqual:@"dev.local.cachekeeper.configuration"] && error.code==1) ||
        ([error.domain isEqual:NSCocoaErrorDomain] && error.code==NSPropertyListReadCorruptError);
    BOOL readable=access && (states!=nil || malformed);
    BOOL valid=access && states!=nil && !error && axs_cachekeeper_state_valid(state);
    BOOL enabled=valid && axs_cachekeeper_app_enabled(state);
    BOOL requested=valid && axs_cachekeeper_webkit_disk_cache_enabled(state);
    NSString *installation=@"",*process=@"";
    NSDictionary *installationCheck=@{@"state":@"notRequested",@"errorCode":@0};
    if (enabled && requested) {
        NSURL *bundleURL=NSBundle.mainBundle.bundleURL;
        NSString *version=[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
        NSError *installationError=nil;
        if (!axs_cachekeeper_webkit_installation || !axs_cachekeeper_validate_installation_snapshot_with_context(axs_cachekeeper_webkit_installation,bundleURL,version,AxsCacheKeeperInstallationContextHostMainBundle,&installationError)) {
            installationError=nil;
            axs_cachekeeper_webkit_installation=axs_cachekeeper_installation_snapshot_with_context(bundleURL,NSBundle.mainBundle.bundleIdentifier,version,AxsCacheKeeperInstallationContextHostMainBundle,&installationError);
        }
        BOOL verified=[axs_cachekeeper_webkit_installation[@"installationState"] isEqual:@"verified"];
        if (verified)
            installation=axs_cachekeeper_webkit_installation[@"fingerprint"] ?: @"";
        installationCheck=axs_cachekeeper_installation_check_result(YES,axs_cachekeeper_webkit_installation,installationError);
        process=axs_cachekeeper_webkit_process();
    }
    // Preserve private identity across disable/re-enable so configuration changes do not fabricate a new install.
    if (!installation.length && (!enabled || !requested) && [axs_cachekeeper_webkit_installation[@"installationState"] isEqual:@"verified"])
        installation=axs_cachekeeper_webkit_installation[@"fingerprint"] ?: @"";
    if (!process.length) process=axs_cachekeeper_webkit_process();
    NSArray *excluded=[state isKindOfClass:NSDictionary.class] && [state[@"excludedPaths"] isKindOfClass:NSArray.class] ? state[@"excludedPaths"] : @[];
    return @{@"readable":@(readable),@"valid":@(valid),@"enabled":@(enabled),@"requested":@(requested),
        @"excludedPaths":excluded,@"installation":installation,@"installationCheck":installationCheck,@"process":process,@"reportWritable":@(axs_cachekeeper_webkit_report_writable)};
}
static void axs_cachekeeper_webkit_record_view(WKWebView *view) {
    if (!view) return;
    if (NSThread.isMainThread) {
        [axs_cachekeeper_webkit_observation captureCreatedWebView:view];
    } else {
        __weak WKWebView *weakView=view;
        dispatch_async(dispatch_get_main_queue(),^{WKWebView *actual=weakView;if (actual) axs_cachekeeper_webkit_record_view(actual);});
    }
}

%group AxsCacheKeeperWebKitObservation
%hook WKWebView
- (instancetype)initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration *)configuration {
    WKWebView *view=%orig;axs_cachekeeper_webkit_record_view(view);return view;
}
- (instancetype)initWithCoder:(NSCoder *)coder {
    WKWebView *view=%orig;axs_cachekeeper_webkit_record_view(view);return view;
}
%end
%end

void axs_cachekeeper_configure_webkit(BOOL containerEligible, BOOL configurationAccess, BOOL diskCacheAuthorized) {
    if (!containerEligible) return;
    void (^configure)(void)=^{
        axs_cachekeeper_webkit_access=configurationAccess;
        if (!axs_cachekeeper_webkit_engine) {
            axs_cachekeeper_webkit_io=dispatch_queue_create("dev.local.cachekeeper.webkit",DISPATCH_QUEUE_SERIAL);
            axs_cachekeeper_webkit_coordinator=[[AxsCacheKeeperWebKitCoordinator alloc] initWithReader:^(void (^reply)(NSDictionary *)) {
                BOOL access=axs_cachekeeper_webkit_access;
                dispatch_async(axs_cachekeeper_webkit_io,^{
                    NSDictionary *context=axs_cachekeeper_webkit_read_context(access);
                    dispatch_async(dispatch_get_main_queue(),^{reply(context);});
                });
            } beginBackground:^NSUInteger(void (^expiration)(void)) {
                UIBackgroundTaskIdentifier task=[UIApplication.sharedApplication beginBackgroundTaskWithName:@"CacheKeeper.WebKitDiskCache" expirationHandler:expiration];
                return task==UIBackgroundTaskInvalid ? 0 : (NSUInteger)task+1;
            } endBackground:^(NSUInteger token) {
                [UIApplication.sharedApplication endBackgroundTask:(UIBackgroundTaskIdentifier)(token-1)];
            } backgroundTime:^BOOL(NSUInteger token) {
                return token && UIApplication.sharedApplication.applicationState==UIApplicationStateBackground && UIApplication.sharedApplication.backgroundTimeRemaining>1;
            } clock:^{return NSProcessInfo.processInfo.systemUptime;} scheduler:nil observer:^(NSDictionary *receipt) {
                BOOL access=axs_cachekeeper_webkit_access;
                NSMutableDictionary *record=[receipt mutableCopy];record[@"runtimeInfo"]=axs_cachekeeper_runtime_info();
                NSDictionary *projected=axs_cachekeeper_webkit_raw_projection(record);
                dispatch_async(axs_cachekeeper_webkit_io,^{
                    if (projected) {axs_cachekeeper_webkit_pending_report=[projected mutableCopy];axs_cachekeeper_webkit_flush_report(access);}
                    else {axs_cachekeeper_webkit_report_writable=NO;NSLog(@"[CacheKeeper] 网页操作回执字段无效，保留待写历史");}
                });
            }];
            axs_cachekeeper_webkit_engine=axs_cachekeeper_webkit_coordinator.cache;
            axs_cachekeeper_webkit_observation=axs_cachekeeper_webkit_coordinator.observation;
            dispatch_async(axs_cachekeeper_webkit_io,^{
                NSString *receiptPath=[[axs_cachekeeper_webkit_folder() stringByAppendingPathComponent:@"Status"] stringByAppendingPathComponent:[NSBundle.mainBundle.bundleIdentifier stringByAppendingString:@".webkit.plist"]];
                id previousHistory=axs_cachekeeper_operation_load(receiptPath,@"webkit");
                dispatch_async(dispatch_get_main_queue(),^{
                    [axs_cachekeeper_webkit_engine restoreOperationHistory:previousHistory];
                    BOOL access=axs_cachekeeper_webkit_access;
                    dispatch_async(axs_cachekeeper_webkit_io,^{axs_cachekeeper_webkit_history_loaded=YES;axs_cachekeeper_webkit_flush_report(access);});
                });
            });
            // The constructor installs creation capture synchronously; UIKit lifecycle setup waits.
            dispatch_async(dispatch_get_main_queue(),^{
            [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                (void)note;[axs_cachekeeper_webkit_coordinator didBecomeActive];
            }];
            [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                (void)note;[axs_cachekeeper_webkit_coordinator didEnterBackground];
            }];
            if (UIApplication.sharedApplication.applicationState==UIApplicationStateActive) {
                [axs_cachekeeper_webkit_coordinator didBecomeActive];
            }
            });
        }
        if (diskCacheAuthorized && !axs_cachekeeper_webkit_hooks &&
            [WKWebView instancesRespondToSelector:@selector(initWithFrame:configuration:)] &&
            [WKWebView instancesRespondToSelector:@selector(initWithCoder:)]) {
            axs_cachekeeper_webkit_hooks=YES;
            %init(AxsCacheKeeperWebKitObservation);
        }
        [axs_cachekeeper_webkit_coordinator configureWithAuthorization:diskCacheAuthorized];
    };
    if (NSThread.isMainThread) configure();else dispatch_async(dispatch_get_main_queue(),configure);
}
