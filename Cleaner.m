#import <UIKit/UIKit.h>
#import <libSandy.h>
#import "AxsCacheKeeperPolicy.h"
#import "AxsCacheKeeperNetworkCache.h"
#import "AxsCacheKeeperProbe.h"
#include <roothide.h>
#include <unistd.h>

static BOOL axs_cachekeeper_access;
static int axs_cachekeeper_sandy_status;
static BOOL axs_cachekeeper_container_eligible;
static int axs_cachekeeper_probe_request_token=-1;
static int axs_cachekeeper_probe_response_token=-1;
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

static uint32_t axs_cachekeeper_refresh_network(void) {
    if (!axs_cachekeeper_container_eligible) return axs_cachekeeper_probe_result(8,0);
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
    NSString *folder = jbroot(@"/var/mobile/Library/CacheKeeper");
    NSString *statePath = [folder stringByAppendingPathComponent:@"appEnabled.plist"];
    NSError *readError=nil;
    NSDictionary *states = [NSDictionary dictionaryWithContentsOfURL:[NSURL fileURLWithPath:statePath] error:&readError];
    BOOL readable = axs_cachekeeper_access && states!=nil;
    uint32_t diagnostic=!axs_cachekeeper_access ? axs_cachekeeper_probe_result(1,axs_cachekeeper_sandy_status) :
        (!readable ? axs_cachekeeper_probe_result(2,readError.code) : axs_cachekeeper_probe_result(3,0));
    BOOL prevent = readable && axs_cachekeeper_should_prevent(states[bundle]);
    BOOL restoring=axs_cachekeeper_previous_prevent || axs_cachekeeper_restore_pending;
    if (!prevent && !restoring && !(readable && axs_cachekeeper_app_enabled(states[bundle]))) {
        axs_cachekeeper_publish_network_report(folder,bundle);return diagnostic;
    }
    BOOL applied = axs_cachekeeper_configure_network_cache(prevent);
    axs_cachekeeper_restore_pending = !prevent && !applied;
    NSString *message = !readable ? @"配置不可读，未限制网络缓存" :
        (prevent ? (applied ? @"标准 NSURLCache 磁盘容量已置 0" : @"磁盘容量设置未生效，自动模式仍会退出后清理") :
        (applied ? (restoring ? @"未禁止网络缓存，已恢复 APP 请求的容量" : @"已读取配置；当前模式／选项未请求网络限制") : @"关闭后的容量恢复尚未成功；下次刷新时重试，可重新启动 APP 恢复"));
    if (readable && axs_cachekeeper_app_enabled(states[bundle])) diagnostic=axs_cachekeeper_probe_result(prevent ? (applied ? 5 : 6) : 4,0);
    if (!prevent && !applied) diagnostic=axs_cachekeeper_probe_result(9,0);
    if (prevent == axs_cachekeeper_previous_prevent && [message isEqual:axs_cachekeeper_previous_message]) return diagnostic;
    axs_cachekeeper_previous_prevent = prevent;
    axs_cachekeeper_previous_message=nil;
    axs_cachekeeper_pending_network_report=@{@"pid":@(getpid()), @"updated":NSDate.date, @"prevent":@(prevent),@"applied":@(applied), @"message":message};
    axs_cachekeeper_publish_network_report(folder,bundle);
    return prevent && applied && axs_cachekeeper_pending_network_report ? axs_cachekeeper_probe_result(7,0) : diagnostic;
}
static void axs_cachekeeper_answer_probe(void) {
    uint64_t request=0;
    if (axs_cachekeeper_probe_request_token<0 || axs_cachekeeper_probe_response_token<0 ||
        notify_get_state(axs_cachekeeper_probe_request_token,&request)!=NOTIFY_STATUS_OK ||
        !axs_cachekeeper_probe_fresh(request,NSDate.date.timeIntervalSince1970)) return;
    if (axs_cachekeeper_container_eligible && !axs_cachekeeper_access) {
        axs_cachekeeper_sandy_status=libSandy_applyProfile("CacheKeeperAccess");
        axs_cachekeeper_access=axs_cachekeeper_sandy_status==kLibSandySuccess;
    }
    uint64_t response=(request&0xffffffff00000000ULL)|axs_cachekeeper_refresh_network();
    uint32_t status=notify_set_state(axs_cachekeeper_probe_response_token,response);
    if (status==NOTIFY_STATUS_OK) notify_post(axs_cachekeeper_probe_name(NSBundle.mainBundle.bundleIdentifier,YES).UTF8String);
    else NSLog(@"[CacheKeeper] 网络诊断响应失败：notify %u",status);
}
static void axs_cachekeeper_preferences_changed(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{ axs_cachekeeper_refresh_network(); });
}
__attribute__((constructor)) static void Start(void) {
    @autoreleasepool {
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
        if (![NSBundle.mainBundle.bundlePath.pathExtension isEqual:@"app"] ||
            !axs_cachekeeper_bundle_id(bundle)) return;
        axs_cachekeeper_container_eligible=[NSHomeDirectory() containsString:@"/Containers/Data/Application/"];
        if (axs_cachekeeper_container_eligible) {
            axs_cachekeeper_sandy_status=libSandy_applyProfile("CacheKeeperAccess");
            axs_cachekeeper_access=axs_cachekeeper_sandy_status==kLibSandySuccess;
            if (!axs_cachekeeper_access) NSLog(@"[CacheKeeper] 共享配置访问失败：%d",axs_cachekeeper_sandy_status);
        }
        // 尽早设置共享缓存；尚未读取配置的其他 APP 保持原容量。
        axs_cachekeeper_refresh_network();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            axs_cachekeeper_preferences_changed, (__bridge CFStringRef)AxsCacheKeeperPreferencesChanged, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        dispatch_async(dispatch_get_main_queue(), ^{
            uint32_t responseStatus=notify_register_check(axs_cachekeeper_probe_name(bundle,YES).UTF8String,&axs_cachekeeper_probe_response_token);
            uint32_t requestStatus=notify_register_dispatch(axs_cachekeeper_probe_name(bundle,NO).UTF8String,&axs_cachekeeper_probe_request_token,dispatch_get_main_queue(),^(int token) { axs_cachekeeper_answer_probe(); });
            if (responseStatus!=NOTIFY_STATUS_OK || requestStatus!=NOTIFY_STATUS_OK) NSLog(@"[CacheKeeper] 网络诊断注册失败：%u/%u",requestStatus,responseStatus);
            else axs_cachekeeper_answer_probe();
            [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                axs_cachekeeper_refresh_network();
                axs_cachekeeper_answer_probe();
            }];
        });
    }
}
