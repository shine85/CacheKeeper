#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import "AxsCacheKeeperWebKitCache.h"
#import "AxsCacheKeeperWebKitObservation.h"
#import "AxsCacheKeeperInstallation.h"
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
static BOOL axs_cachekeeper_webkit_foreground_seen;
static BOOL axs_cachekeeper_webkit_background_seen;
static BOOL axs_cachekeeper_webkit_launch_pending;
static NSUInteger axs_cachekeeper_webkit_lifecycle;
static UIBackgroundTaskIdentifier axs_cachekeeper_webkit_background=UIBackgroundTaskInvalid;
// The following fields belong only to the serial IO queue.
static NSDictionary *axs_cachekeeper_webkit_installation;
static NSDictionary *axs_cachekeeper_webkit_pending_report;
static BOOL axs_cachekeeper_webkit_report_writable=YES;

static NSString *axs_cachekeeper_webkit_folder(void) {
    return jbroot(@"/var/mobile/Library/CacheKeeper");
}
static void axs_cachekeeper_webkit_flush_report(BOOL access) {
    if (!axs_cachekeeper_webkit_pending_report) return;
    NSString *bundle=NSBundle.mainBundle.bundleIdentifier;
    NSString *path=[[axs_cachekeeper_webkit_folder() stringByAppendingPathComponent:@"Status"] stringByAppendingPathComponent:[bundle stringByAppendingString:@".webkit.plist"]];
    NSError *error=nil;
    axs_cachekeeper_webkit_report_writable=access && [axs_cachekeeper_webkit_pending_report writeToURL:[NSURL fileURLWithPath:path] error:&error];
    if (axs_cachekeeper_webkit_report_writable) axs_cachekeeper_webkit_pending_report=nil;
    else NSLog(@"[CacheKeeper] 网页缓存回执保存失败，保留最新结果等待重试（code=%ld）",(long)error.code);
}
static NSString *axs_cachekeeper_webkit_process(void) {
    int pid=getpid(),mib[4]={CTL_KERN,KERN_PROC,KERN_PROC_PID,pid};
    struct kinfo_proc info;memset(&info,0,sizeof(info));size_t size=sizeof(info);
    if (sysctl(mib,4,&info,&size,NULL,0) || size!=sizeof(info) || !info.kp_proc.p_starttime.tv_sec) return @"";
    return [NSString stringWithFormat:@"%d:%lld.%06d",pid,(long long)info.kp_proc.p_starttime.tv_sec,(int)info.kp_proc.p_starttime.tv_usec];
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
        if (!axs_cachekeeper_webkit_installation || !axs_cachekeeper_validate_installation_snapshot(axs_cachekeeper_webkit_installation,bundleURL,version,&installationError)) {
            installationError=nil;
            axs_cachekeeper_webkit_installation=axs_cachekeeper_installation_snapshot(bundleURL,NSBundle.mainBundle.bundleIdentifier,version,&installationError);
        }
        BOOL verified=[axs_cachekeeper_webkit_installation[@"installationState"] isEqual:@"verified"];
        if (verified)
            installation=axs_cachekeeper_webkit_installation[@"fingerprint"] ?: @"";
        // Never persist NSError descriptions, bundle paths or version strings in runtime receipts.
        NSInteger code=[installationError.domain isEqual:@"dev.local.cachekeeper.installation"] && installationError.code>=1 && installationError.code<=7 ? installationError.code : 0;
        installationCheck=@{@"state":verified ? @"verified" : axs_cachekeeper_webkit_installation ? @"versionUnknown" : @"failed",@"errorCode":@(code)};
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
static void axs_cachekeeper_webkit_end_background(void) {
    if (axs_cachekeeper_webkit_background==UIBackgroundTaskInvalid) return;
    UIBackgroundTaskIdentifier task=axs_cachekeeper_webkit_background;axs_cachekeeper_webkit_background=UIBackgroundTaskInvalid;
    [UIApplication.sharedApplication endBackgroundTask:task];
}
static BOOL axs_cachekeeper_webkit_has_time(void) {
    return axs_cachekeeper_webkit_background!=UIBackgroundTaskInvalid && UIApplication.sharedApplication.applicationState==UIApplicationStateBackground && UIApplication.sharedApplication.backgroundTimeRemaining>1;
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

static void axs_cachekeeper_webkit_refresh(void (^completion)(void)) {
    BOOL access=axs_cachekeeper_webkit_access;
    NSUInteger generation=axs_cachekeeper_webkit_observation.generation;
    dispatch_async(axs_cachekeeper_webkit_io,^{
        NSDictionary *context=axs_cachekeeper_webkit_read_context(access);
        dispatch_async(dispatch_get_main_queue(),^{
            if ([axs_cachekeeper_webkit_observation applyContext:context forGeneration:generation] && completion) completion();
        });
    });
}
static void axs_cachekeeper_webkit_enter_background(void) {
    if (axs_cachekeeper_webkit_background_seen) return;
    axs_cachekeeper_webkit_background_seen=YES;
    // Disabled/unobserved apps must not acquire background execution just to discover a cache.
    if (!axs_cachekeeper_webkit_foreground_seen || !axs_cachekeeper_webkit_observation.observing || ![axs_cachekeeper_webkit_engine.receipt[@"persistentStores"] unsignedIntegerValue]) {
        [axs_cachekeeper_webkit_engine didEnterBackgroundWithTime:NO];return;
    }
    NSUInteger lifecycle=++axs_cachekeeper_webkit_lifecycle;
    axs_cachekeeper_webkit_launch_pending=YES;
    if (axs_cachekeeper_webkit_background==UIBackgroundTaskInvalid) {
        axs_cachekeeper_webkit_background=[UIApplication.sharedApplication beginBackgroundTaskWithName:@"CacheKeeper.WebKitDiskCache" expirationHandler:^{
            axs_cachekeeper_webkit_launch_pending=NO;
            [axs_cachekeeper_webkit_engine expireBackgroundTime];axs_cachekeeper_webkit_end_background();
        }];
    }
    axs_cachekeeper_webkit_refresh(^{
        if (lifecycle!=axs_cachekeeper_webkit_lifecycle) return;
        axs_cachekeeper_webkit_launch_pending=NO;
        [axs_cachekeeper_webkit_engine didEnterBackgroundWithTime:axs_cachekeeper_webkit_has_time()];
    });
}
void axs_cachekeeper_configure_webkit(BOOL containerEligible, BOOL configurationAccess, BOOL diskCacheAuthorized) {
    if (!containerEligible) return;
    void (^configure)(void)=^{
        axs_cachekeeper_webkit_access=configurationAccess;
        ++axs_cachekeeper_webkit_lifecycle;axs_cachekeeper_webkit_launch_pending=NO;
        if (!axs_cachekeeper_webkit_engine) {
            axs_cachekeeper_webkit_io=dispatch_queue_create("dev.local.cachekeeper.webkit",DISPATCH_QUEUE_SERIAL);
            axs_cachekeeper_webkit_engine=[[AxsCacheKeeperWebKitCache alloc] initWithPreparation:^(void (^reply)(NSDictionary *,BOOL)) {
                BOOL access=axs_cachekeeper_webkit_access;
                NSUInteger generation=axs_cachekeeper_webkit_observation.generation;
                dispatch_async(axs_cachekeeper_webkit_io,^{
                    NSDictionary *context=axs_cachekeeper_webkit_read_context(access);
                    dispatch_async(dispatch_get_main_queue(),^{
                        if ([axs_cachekeeper_webkit_observation applyContext:context forGeneration:generation])
                            reply(context,axs_cachekeeper_webkit_has_time());
                    });
                });
            } clock:^{return NSProcessInfo.processInfo.systemUptime;} observer:^(NSDictionary *receipt) {
                BOOL access=axs_cachekeeper_webkit_access;
                dispatch_async(axs_cachekeeper_webkit_io,^{axs_cachekeeper_webkit_pending_report=receipt;axs_cachekeeper_webkit_flush_report(access);});
                // Defer until a synchronous completion has had a chance to queue the next store.
                dispatch_async(dispatch_get_main_queue(),^{
                    NSDictionary *current=axs_cachekeeper_webkit_engine.receipt;
                    if (!axs_cachekeeper_webkit_launch_pending && ![current[@"pending"] boolValue] && ![current[@"state"] isEqual:@"queued"])
                        axs_cachekeeper_webkit_end_background();
                });
            }];
            axs_cachekeeper_webkit_observation=[[AxsCacheKeeperWebKitObservation alloc] initWithCache:axs_cachekeeper_webkit_engine];
            // The constructor installs creation capture synchronously; UIKit lifecycle setup waits.
            dispatch_async(dispatch_get_main_queue(),^{
            [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                (void)note;++axs_cachekeeper_webkit_lifecycle;axs_cachekeeper_webkit_launch_pending=NO;
                axs_cachekeeper_webkit_foreground_seen=YES;axs_cachekeeper_webkit_background_seen=NO;
                [axs_cachekeeper_webkit_engine didBecomeActive];axs_cachekeeper_webkit_end_background();axs_cachekeeper_webkit_refresh(nil);
            }];
            [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                (void)note;axs_cachekeeper_webkit_enter_background();
            }];
            if (UIApplication.sharedApplication.applicationState==UIApplicationStateActive) {
                axs_cachekeeper_webkit_foreground_seen=YES;[axs_cachekeeper_webkit_engine didBecomeActive];
            }
            });
        }
        [axs_cachekeeper_webkit_observation beginConfigurationWithAuthorization:diskCacheAuthorized];
        if (diskCacheAuthorized && !axs_cachekeeper_webkit_hooks &&
            [WKWebView instancesRespondToSelector:@selector(initWithFrame:configuration:)] &&
            [WKWebView instancesRespondToSelector:@selector(initWithCoder:)]) {
            axs_cachekeeper_webkit_hooks=YES;
            %init(AxsCacheKeeperWebKitObservation);
        }
        axs_cachekeeper_webkit_refresh(nil);
    };
    if (NSThread.isMainThread) configure();else dispatch_async(dispatch_get_main_queue(),configure);
}
