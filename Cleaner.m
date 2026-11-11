#import <UIKit/UIKit.h>
#import <libSandy.h>
#import "AxsCacheKeeperPolicy.h"
#import "AxsCacheKeeperNetworkCache.h"
#include <roothide.h>
#include <unistd.h>

static BOOL axs_cachekeeper_access;
static BOOL axs_cachekeeper_previous_prevent;
static BOOL axs_cachekeeper_restore_pending;
static NSString *axs_cachekeeper_previous_message;
static NSDictionary *axs_cachekeeper_pending_network_report;

static void axs_cachekeeper_publish_network_report(NSString *folder, NSString *bundle) {
    if (!axs_cachekeeper_pending_network_report) return;
    NSString *path=[[folder stringByAppendingPathComponent:@"Status"] stringByAppendingPathComponent:[bundle stringByAppendingString:@".network.plist"]];
    NSError *error=nil;
    if (axs_cachekeeper_access && [axs_cachekeeper_pending_network_report writeToURL:[NSURL fileURLWithPath:path] error:&error]) {
        axs_cachekeeper_previous_message=axs_cachekeeper_pending_network_report[@"message"];
        axs_cachekeeper_pending_network_report=nil;
    } else NSLog(@"[CacheKeeper] %@ 网络回执未保存：%@；下次刷新重试",bundle,error ?: @"共享目录访问未获准");
}

static void axs_cachekeeper_refresh_network(void) {
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
    NSString *folder = jbroot(@"/var/mobile/Library/CacheKeeper");
    NSString *statePath = [folder stringByAppendingPathComponent:@"appEnabled.plist"];
    NSDictionary *states = [NSDictionary dictionaryWithContentsOfFile:statePath];
    BOOL readable = axs_cachekeeper_access &&
        (states || ![NSFileManager.defaultManager fileExistsAtPath:statePath]);
    BOOL prevent = readable && axs_cachekeeper_should_prevent(states[bundle]);
    BOOL restoring=axs_cachekeeper_previous_prevent || axs_cachekeeper_restore_pending;
    if (!prevent && !restoring && !(readable && axs_cachekeeper_app_enabled(states[bundle]))) {
        axs_cachekeeper_publish_network_report(folder,bundle);return;
    }
    BOOL applied = axs_cachekeeper_configure_network_cache(prevent);
    axs_cachekeeper_restore_pending = !prevent && !applied;
    NSString *message = !readable ? @"配置不可读，未限制网络缓存" :
        (prevent ? (applied ? @"标准 NSURLCache 磁盘容量已置 0" : @"磁盘容量设置未生效，自动模式仍会退出后清理") :
        (applied ? (restoring ? @"未禁止网络缓存，已恢复 APP 请求的容量" : @"已读取配置；当前模式／选项未请求网络限制") : @"关闭后的容量恢复尚未成功；下次刷新时重试，可重新启动 APP 恢复"));
    if (prevent == axs_cachekeeper_previous_prevent && [message isEqual:axs_cachekeeper_previous_message]) return;
    axs_cachekeeper_previous_prevent = prevent;
    axs_cachekeeper_previous_message=nil;
    axs_cachekeeper_pending_network_report=@{@"pid":@(getpid()), @"updated":NSDate.date, @"prevent":@(prevent),@"applied":@(applied), @"message":message};
    axs_cachekeeper_publish_network_report(folder,bundle);
}
static void axs_cachekeeper_preferences_changed(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{ axs_cachekeeper_refresh_network(); });
}
__attribute__((constructor)) static void Start(void) {
    @autoreleasepool {
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
        if (![NSHomeDirectory() containsString:@"/Containers/Data/Application/"] ||
            ![NSBundle.mainBundle.bundlePath.pathExtension isEqual:@"app"] ||
            !axs_cachekeeper_bundle_id(bundle)) return;
        int access = libSandy_applyProfile("CacheKeeperAccess");
        axs_cachekeeper_access = access == kLibSandySuccess;
        if (!axs_cachekeeper_access) NSLog(@"[CacheKeeper] 共享配置访问失败：%d；自动模式仍可由桌面进程清理", access);
        // 尽早设置共享缓存；尚未读取配置的其他 APP 保持原容量。
        axs_cachekeeper_refresh_network();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            axs_cachekeeper_preferences_changed, (__bridge CFStringRef)AxsCacheKeeperPreferencesChanged, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                axs_cachekeeper_refresh_network();
            }];
        });
    }
}
