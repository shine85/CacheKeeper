#pragma once
#import <Foundation/Foundation.h>
#import <objc/message.h>
#include <libproc.h>
#include <sys/proc_info.h>

typedef NS_ENUM(NSInteger, AxsCacheKeeperProcessState) {
    AxsCacheKeeperProcessUnknown, AxsCacheKeeperProcessRunning, AxsCacheKeeperProcessStopped
};

// 信号置信分级（对照 AppDataCleaner 方案吸收，2026-11-11）：本插件单一信号源为 FrontBoard 进程清单，
// 其「清单完整且目标消失」属强信号；接口不可用/清单无效属无信号。清理入口显式要求强信号，
// 将来若引入弱信号源（如轮询兜底），不得单独触发清理——在此分级处收口，不分散到调用方。
typedef NS_ENUM(NSInteger, AxsCacheKeeperSignalConfidence) {
    AxsCacheKeeperSignalNone, AxsCacheKeeperSignalStrong
};

// FrontBoard 16/17 的完整应用进程清单包含启动/退出过程；有记录时宁可等待。
// 空清单只有在系统进程仍有效时才有意义，nil 或不支持接口不能解释成已退出。
static inline AxsCacheKeeperProcessState axs_cachekeeper_process_state_confidence(id manager, NSString *bundle, NSString **reason, AxsCacheKeeperSignalConfidence *confidence) {
    if (confidence) *confidence = AxsCacheKeeperSignalNone;
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
            if (confidence) *confidence = AxsCacheKeeperSignalStrong;
            return AxsCacheKeeperProcessRunning;
        }
    }
    if (reason) *reason=@"FrontBoard 已就绪，应用进程清单中无此 APP";
    if (confidence) *confidence = AxsCacheKeeperSignalStrong;
    return AxsCacheKeeperProcessStopped;
}
static inline AxsCacheKeeperProcessState axs_cachekeeper_process_state(id manager, NSString *bundle, NSString **reason) {
    return axs_cachekeeper_process_state_confidence(manager, bundle, reason, NULL);
}

// 进程实例标识「pid:启动秒.微秒」：用于把清理任务绑定到「刚刚退出的那个实例」，防 PID 复用与
// 任务存续期间新实例启停造成的错位清理。取不到启动时间即返回 nil（不绑定，退回仅按状态判定），
// 不用仅 pid 的弱标识冒充绑定。
static inline NSString *axs_cachekeeper_process_identity(id manager, NSString *bundle) {
    SEL all=NSSelectorFromString(@"allApplicationProcesses");
    if (![manager respondsToSelector:all]) return nil;
    id processes=((id(*)(id,SEL))objc_msgSend)(manager,all);
    if (![processes isKindOfClass:NSArray.class] && ![processes isKindOfClass:NSSet.class]) return nil;
    for (id item in processes) {
        SEL identifier=NSSelectorFromString(@"bundleIdentifier");
        id value=[item respondsToSelector:identifier] ? ((id(*)(id,SEL))objc_msgSend)(item,identifier) : nil;
        if (![value isKindOfClass:NSString.class] || ![value isEqual:bundle]) continue;
        SEL pidSelector=NSSelectorFromString(@"pid");
        if (![item respondsToSelector:pidSelector]) return nil;
        int pid=((int(*)(id,SEL))objc_msgSend)(item,pidSelector);
        if (pid<=0) return nil;
        struct proc_taskallinfo info;
        if (proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, sizeof(info)) != (int)sizeof(info)) return nil;
        return [NSString stringWithFormat:@"%d:%llu.%06u", pid,
            (unsigned long long)info.pbsd.pbi_start_tvsec, (unsigned)info.pbsd.pbi_start_tvusec];
    }
    return nil;
}
