#pragma once
#import <Foundation/Foundation.h>
#import <objc/message.h>
#include <sys/sysctl.h>
#include <sys/types.h>

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

// 单个进程对象的实例标识「pid:启动秒.微秒」（取不到返回 nil，不伪造）。
static inline NSString *axs_cachekeeper_identity_for_process(id item) {
    SEL pidSelector=NSSelectorFromString(@"pid");
    if (![item respondsToSelector:pidSelector]) return nil;
    int pid=((int(*)(id,SEL))objc_msgSend)(item,pidSelector);
    if (pid<=0) return nil;
    // 启动时间经 sysctl KERN_PROC_PID 读取（iOS SDK 无 libproc.h，构建 #28 已证伪；
    // sysctl 与 kinfo_proc 为各 SDK 均备的标准头文件路径）。
    int mib[4]={CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    struct kinfo_proc info;
    size_t size=sizeof(info);
    if (sysctl(mib, 4, &info, &size, NULL, 0) || !size) return nil;
    struct timeval start=info.kp_proc.p_starttime;
    if (!start.tv_sec) return nil;
    return [NSString stringWithFormat:@"%d:%lld.%06d", pid,
        (long long)start.tv_sec, (int)start.tv_usec];
}
// 进程实例标识：用于把清理任务绑定到「刚刚退出的那个实例」，防 PID 复用与
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
        return axs_cachekeeper_identity_for_process(item);
    }
    return nil;
}
// 执行状态细分（2026-11-11 用户拍板 A 案）：进程记录存在不等于在执行——APP 被划掉后常被
// 静默推送/后台刷新唤醒，干完活被系统挂起（suspended），记录在 FrontBoard 清单中长留数小时，
// 「有记录即等待」的旧判定会让自动清理无限期停摆（真机抖音 Caches 满置 54 MB 无轮次可证）。
// 本函数在完整清单校验（与状态判定同一套 fail-closed 前提）之上细分五态：
//   Absent    清单中无记录（进程已消失）；
//   Executing 进程状态 taskState=1（RBSProcessTaskStateRunning），正在执行，硬拦；
//   Suspended taskState=2（RBSProcessTaskStateSuspended），内核已冻结、不能执行；
//             是否放行由调用方按「同一实例持续挂起满 60 秒」另行判定，本函数只报事实；
//   Terminated taskState=3（RBSProcessTaskStateTerminated），进程已终止、不能执行、不能恢复为同一实例；
//             调用方可直接按已退出处理，无需 60 秒稳定等待（2026-11-12 真机抖音 taskState=3 实测，
//             划掉约 50 分钟后由挂起转入该态；若为执行中，划掉后的 APP 不可能在后台执行这么久）；
//   Unknown   接口缺失/清单无效/状态读不到/taskState 为其他值——一律不放行（fail-closed），
//             reason 带 taskState 原始值供真机一击定位（-1 表示读不到状态对象）。
typedef NS_ENUM(NSInteger, AxsCacheKeeperExecState) {
    AxsCacheKeeperExecUnknown, AxsCacheKeeperExecAbsent, AxsCacheKeeperExecExecuting, AxsCacheKeeperExecSuspended, AxsCacheKeeperExecTerminated
};
static inline AxsCacheKeeperExecState axs_cachekeeper_process_exec_state(id manager, NSString *bundle, NSString **identity, NSInteger *taskState, NSString **reason) {
    if (identity) *identity = nil;
    if (taskState) *taskState = -1;
    if (reason) *reason = @"";
    SEL all=NSSelectorFromString(@"allApplicationProcesses"), system=NSSelectorFromString(@"systemApplicationProcess");
    if (![manager respondsToSelector:all] || ![manager respondsToSelector:system]) {
        if (reason) *reason=@"FrontBoard 进程管理接口不可用；请提供 iOS 小版本与插件版本排查兼容性";
        return AxsCacheKeeperExecUnknown;
    }
    id process=((id(*)(id,SEL))objc_msgSend)(manager,system);
    SEL running=NSSelectorFromString(@"isRunning");
    if (![process respondsToSelector:running] || !((BOOL(*)(id,SEL))objc_msgSend)(process,running)) {
        if (reason) *reason=@"FrontBoard 系统进程尚未就绪；稍后会自动重试";
        return AxsCacheKeeperExecUnknown;
    }
    id processes=((id(*)(id,SEL))objc_msgSend)(manager,all);
    if (![processes isKindOfClass:NSArray.class] && ![processes isKindOfClass:NSSet.class]) {
        if (reason) *reason=@"FrontBoard 未返回有效进程清单；请提供 iOS 小版本排查";
        return AxsCacheKeeperExecUnknown;
    }
    for (id item in processes) {
        SEL identifier=NSSelectorFromString(@"bundleIdentifier");
        id value=[item respondsToSelector:identifier] ? ((id(*)(id,SEL))objc_msgSend)(item,identifier) : nil;
        if (![value isKindOfClass:NSString.class] || ![value length]) {
            if (reason) *reason=@"进程清单有无法识别的应用标识，暂不删除；请提供诊断信息排查";
            return AxsCacheKeeperExecUnknown;
        }
        if (![value isEqual:bundle]) continue;
        if (identity) *identity = axs_cachekeeper_identity_for_process(item);
        SEL stateSelector=NSSelectorFromString(@"state");
        id state=[item respondsToSelector:stateSelector] ? ((id(*)(id,SEL))objc_msgSend)(item,stateSelector) : nil;
        SEL taskSelector=NSSelectorFromString(@"taskState");
        if (!state || ![state respondsToSelector:taskSelector]) {
            if (reason) *reason=@"FrontBoard 有此 APP 的进程记录，但执行状态无法确认（taskState=-1），暂不删除";
            return AxsCacheKeeperExecUnknown;
        }
        NSInteger raw=((NSInteger(*)(id,SEL))objc_msgSend)(state,taskSelector);
        if (taskState) *taskState = raw;
        if (raw == 1) {
            if (reason) *reason=@"FrontBoard 仍有此 APP 的进程记录（含启动、后台或退出中）；退出完成后自动重试";
            return AxsCacheKeeperExecExecuting;
        }
        if (raw == 2) {
            if (reason) *reason=@"APP 进程已被系统挂起（未在执行）；持续挂起满 60 秒后自动清理";
            return AxsCacheKeeperExecSuspended;
        }
        if (raw == 3) {
            if (reason) *reason=@"APP 进程已终止（taskState=3），按已退出处理";
            return AxsCacheKeeperExecTerminated;
        }
        if (reason) *reason=[NSString stringWithFormat:@"FrontBoard 有此 APP 的进程记录，但执行状态无法确认（taskState=%ld），暂不删除", (long)raw];
        return AxsCacheKeeperExecUnknown;
    }
    if (reason) *reason=@"FrontBoard 已就绪，应用进程清单中无此 APP";
    return AxsCacheKeeperExecAbsent;
}
