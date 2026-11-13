#pragma once
#import <Foundation/Foundation.h>

@class AxsCacheKeeperSweep;

// 单轮删除硬上限：全作业共享（方案任务 3，P1-3）。
extern const NSUInteger AxsCacheKeeperCleanupRoundItemCap; // 2000 项
// 删除阶段单调时间期限：从首次真实删除推进起算（方案任务 3，P1-3）。
extern const NSTimeInterval AxsCacheKeeperCleanupDeleteTimeLimit; // 120 秒

typedef NS_ENUM(NSInteger, AxsCacheKeeperCleanupPhase) {
    AxsCacheKeeperCleanupPhaseChecking, // 任一根未完成预检（含统一决策）
    AxsCacheKeeperCleanupPhaseReady,    // 全部预检完成，尚未开始删除
    AxsCacheKeeperCleanupPhaseDeleting, // 删除进行中
    AxsCacheKeeperCleanupPhaseFinished, // 已结束（见 endReason）
};

typedef NS_ENUM(NSInteger, AxsCacheKeeperCleanupEndReason) {
    AxsCacheKeeperCleanupEndReasonNone,         // 未结束
    AxsCacheKeeperCleanupEndReasonCompleted,    // 全部根完成，无未确认内容（失败/变化计入计数，不另立原因）
    AxsCacheKeeperCleanupEndReasonUnresolved,   // 全部根完成，但有未确认内容残留（任务 3 扩展：部分完成）
    AxsCacheKeeperCleanupEndReasonLimitReached, // 2000 项或 120 秒
    AxsCacheKeeperCleanupEndReasonCancelled,    // 门控关闭
    AxsCacheKeeperCleanupEndReasonFailed,       // 预留：回执写失败时轮次暂停而非中止（任务 4），此原因暂不使用
    AxsCacheKeeperCleanupEndReasonChanged,      // 预留：任务 6 发现覆盖不完整中止轮次时用
};

// 一轮清理作业：多根的状态机与预算/期限（方案任务 3，P1-3）。
// - 全部根完成预检（含统一决策）后才进入删除；任一根在预检时，任何根都不删除。
// - 120 秒期限从首次真实删除推进起算，只设一次、永不重置；空根/受保护根/失败根
//   在预检阶段即完成，永不启动计时。
// - 2000 项为全作业共享的删除硬上限；预检不删文件，不计入上限。
// - 门控由调用方（Scanner）按根采样：每周期每根采样一次，周期内不再重采
//   （与旧实现逐根采样一致；逐文件采样曾把单周期拖到约 10 秒，见 #42）。
@interface AxsCacheKeeperCleanupJob : NSObject
- (instancetype)initWithSweeps:(NSArray<AxsCacheKeeperSweep *> *)sweeps
                      signature:(NSString *)signature
                       instance:(NSString *)instance
                          clock:(NSTimeInterval (^)(void))clock;
@property(nonatomic, readonly, copy) NSArray<AxsCacheKeeperSweep *> *sweeps;
@property(nonatomic, readonly, copy) NSString *signature;
@property(nonatomic, readonly, copy) NSString *instance;
// 本轮固定标识（init 时生成 UUID）：回执按 roundID 幂等核算，作业替换不丢未上报增量（任务 4）。
@property(nonatomic, readonly, copy) NSString *roundID;
@property(nonatomic, readonly) AxsCacheKeeperCleanupPhase phase;
@property(nonatomic, readonly) AxsCacheKeeperCleanupEndReason endReason;
@property(nonatomic, readonly) NSUInteger removed;
@property(nonatomic, readonly) NSUInteger failed;
@property(nonatomic, readonly) NSUInteger changedCount;
@property(nonatomic, readonly) NSUInteger protectedCount;
@property(nonatomic, readonly) NSUInteger recentCount;
@property(nonatomic, readonly) NSUInteger inspected;
@property(nonatomic, readonly) unsigned long long bytes;
@property(nonatomic, readonly) BOOL hasUnresolved;
@property(nonatomic, readonly) NSUInteger unresolvedCount;
@property(nonatomic, readonly) unsigned long long unresolvedBytes;
// 部分完成：本轮有未能处理完的范围（失败/变化/未确认）。触顶/取消的轮次不以此判定，
// 它们有自己的结束原因；近期文件只涉及时机（到期后重试），不计入部分完成。
@property(nonatomic, readonly) BOOL partial;
@property(nonatomic, readonly) NSTimeInterval deleteDeadline; // 0 = 尚未进入删除
// 单周期推进：Checking 阶段只预检；Ready 后转入删除并受预算/期限约束。
// gate 每根调用一次；返回 NO 时本轮取消（endReason=Cancelled）。
- (void)advanceCycleWithPerRootLimit:(NSUInteger)perRootLimit gate:(BOOL (^)(void))gate;
// 作业停用、替换与门控取消共用终态入口；调用方随后提交同 roundID 的最终累计。
- (void)cancel;
@end
