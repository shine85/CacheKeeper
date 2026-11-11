#pragma once
#import <Foundation/Foundation.h>
#import <objc/message.h>

typedef NS_ENUM(NSInteger, AxsCacheKeeperProcessState) {
    AxsCacheKeeperProcessUnknown, AxsCacheKeeperProcessRunning, AxsCacheKeeperProcessStopped
};

// FrontBoard 16/17 的完整应用进程清单包含启动/退出过程；有记录时宁可等待。
// 空清单只有在系统进程仍有效时才有意义，nil 或不支持接口不能解释成已退出。
static inline AxsCacheKeeperProcessState axs_cachekeeper_process_state(id manager, NSString *bundle, NSString **reason) {
    if (reason) *reason=@"";
    SEL all=NSSelectorFromString(@"allApplicationProcesses"), system=NSSelectorFromString(@"systemApplicationProcess");
    if (![manager respondsToSelector:all] || ![manager respondsToSelector:system]) {
        if (reason) *reason=@"FrontBoard 进程管理接口不可用；请提供 iOS 小版本与插件版本排查兼容性";
        return AxsCacheKeeperProcessUnknown;
    }
    id process=((id(*)(id,SEL))objc_msgSend)(manager,system);
    SEL running=NSSelectorFromString(@"isRunning");
    if (![process respondsToSelector:running] || !((BOOL(*)(id,SEL))objc_msgSend)(process,running)) {
        if (reason) *reason=@"FrontBoard 系统进程尚未就绪；稍后会自动重试";
        return AxsCacheKeeperProcessUnknown;
    }
    id processes=((id(*)(id,SEL))objc_msgSend)(manager,all);
    if (![processes isKindOfClass:NSArray.class] && ![processes isKindOfClass:NSSet.class]) {
        if (reason) *reason=@"FrontBoard 未返回有效进程清单；请提供 iOS 小版本排查";
        return AxsCacheKeeperProcessUnknown;
    }
    for (id item in processes) {
        SEL identifier=NSSelectorFromString(@"bundleIdentifier");
        id value=[item respondsToSelector:identifier] ? ((id(*)(id,SEL))objc_msgSend)(item,identifier) : nil;
        if (![value isKindOfClass:NSString.class] || ![value length]) {
            if (reason) *reason=@"进程清单有无法识别的应用标识，暂不删除；请提供诊断信息排查";
            return AxsCacheKeeperProcessUnknown;
        }
        if ([value isEqual:bundle]) {
            if (reason) *reason=@"FrontBoard 仍有此 APP 的进程记录（含启动、后台或退出中）；退出完成后自动重试";
            return AxsCacheKeeperProcessRunning;
        }
    }
    if (reason) *reason=@"FrontBoard 已就绪，应用进程清单中无此 APP";
    return AxsCacheKeeperProcessStopped;
}
