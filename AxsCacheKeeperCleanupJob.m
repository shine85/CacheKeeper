#import "AxsCacheKeeperCleanupJob.h"
#import "AxsCacheKeeperSweep.h"

const NSUInteger AxsCacheKeeperCleanupRoundItemCap = 2000;
const NSTimeInterval AxsCacheKeeperCleanupDeleteTimeLimit = 120;

@interface AxsCacheKeeperCleanupJob ()
@property(nonatomic, readwrite) AxsCacheKeeperCleanupPhase phase;
@property(nonatomic, readwrite) AxsCacheKeeperCleanupEndReason endReason;
@property(nonatomic, readwrite) NSTimeInterval deleteDeadline;
@property(nonatomic, copy) NSTimeInterval (^clock)(void);
@end

@implementation AxsCacheKeeperCleanupJob

- (instancetype)initWithSweeps:(NSArray<AxsCacheKeeperSweep *> *)sweeps
                      signature:(NSString *)signature
                       instance:(NSString *)instance
                          clock:(NSTimeInterval (^)(void))clock {
    if ((self = [super init])) {
        _sweeps = [sweeps copy];
        _signature = [signature copy];
        _instance = [instance copy];
        _roundID = NSUUID.UUID.UUIDString;
        _clock = [clock copy];
        _phase = AxsCacheKeeperCleanupPhaseChecking;
        _endReason = AxsCacheKeeperCleanupEndReasonNone;
        _deleteDeadline = 0;
        __weak typeof(self) weak=self;
        for (AxsCacheKeeperSweep *source in _sweeps) {
            __weak AxsCacheKeeperSweep *weakSource=source;
            source.removalObserver=^(NSString *path) {
                for (AxsCacheKeeperSweep *other in weak.sweeps)
                    if (other!=weakSource) [other updateDependenciesAfterRemovingPath:path];
            };
        }
    }
    return self;
}

#pragma mark - 聚合计数（实时汇总各根）

- (NSUInteger)removed { NSUInteger total = 0; for (AxsCacheKeeperSweep *s in self.sweeps) total += s.removed; return total; }
- (NSUInteger)failed { NSUInteger total = 0; for (AxsCacheKeeperSweep *s in self.sweeps) total += s.failed; return total; }
- (NSUInteger)changedCount { NSUInteger total = 0; for (AxsCacheKeeperSweep *s in self.sweeps) total += s.changedCount; return total; }
- (NSUInteger)protectedCount { NSUInteger total = 0; for (AxsCacheKeeperSweep *s in self.sweeps) total += s.protectedCount; return total; }
- (NSUInteger)recentCount { NSUInteger total = 0; for (AxsCacheKeeperSweep *s in self.sweeps) total += s.recentCount; return total; }
- (NSUInteger)inspected { NSUInteger total = 0; for (AxsCacheKeeperSweep *s in self.sweeps) total += s.inspected; return total; }
- (unsigned long long)bytes { unsigned long long total = 0; for (AxsCacheKeeperSweep *s in self.sweeps) total += s.bytes; return total; }
- (BOOL)hasUnresolved { for (AxsCacheKeeperSweep *s in self.sweeps) if (s.unresolvedCount > 0) return YES; return NO; }
- (NSUInteger)unresolvedCount { NSUInteger total = 0; for (AxsCacheKeeperSweep *s in self.sweeps) total += s.unresolvedCount; return total; }
- (unsigned long long)unresolvedBytes { unsigned long long total = 0; for (AxsCacheKeeperSweep *s in self.sweeps) total += s.unresolvedBytes; return total; }
- (BOOL)partial { return self.failed > 0 || self.changedCount > 0 || self.unresolvedCount > 0; }

#pragma mark - 内部

- (BOOL)deadlineHit {
    return self.deleteDeadline > 0 && self.clock() >= self.deleteDeadline;
}

- (void)finishWithReason:(AxsCacheKeeperCleanupEndReason)reason {
    self.endReason = reason;
    self.phase = AxsCacheKeeperCleanupPhaseFinished;
}

- (void)cancelJob {
    for (AxsCacheKeeperSweep *sweep in self.sweeps) if (!sweep.complete) [sweep cancel];
    [self finishWithReason:AxsCacheKeeperCleanupEndReasonCancelled];
}
- (void)cancel {
    if (self.phase != AxsCacheKeeperCleanupPhaseFinished) [self cancelJob];
}

#pragma mark - 周期推进

- (void)advanceCycleWithPerRootLimit:(NSUInteger)perRootLimit gate:(BOOL (^)(void))gate {
    if (self.phase == AxsCacheKeeperCleanupPhaseFinished) return;
    if (self.phase == AxsCacheKeeperCleanupPhaseChecking) {
        for (AxsCacheKeeperSweep *sweep in self.sweeps) {
            if (sweep.complete) continue;
            if (!gate()) { [self cancelJob]; return; }
            [sweep advancePreflight:perRootLimit];
        }
        BOOL allPreflightDone = YES;
        BOOL anyLive = NO;
        for (AxsCacheKeeperSweep *sweep in self.sweeps) {
            if (!sweep.complete && sweep.checking) allPreflightDone = NO;
            if (!sweep.complete) anyLive = YES;
        }
        if (!allPreflightDone) return;
        // 全部根预检完成。若无存活根（空根/受保护根/失败根在预检即完成），
        // 直接结束：不进入删除、不启动 120 秒计时。
        if (!anyLive) { [self finishWithReason:AxsCacheKeeperCleanupEndReasonCompleted]; return; }
        self.phase = AxsCacheKeeperCleanupPhaseReady;
        return; // 预检周期内不删除；下周期转入删除（每周期只做一个阶段）
    }
    if (self.phase == AxsCacheKeeperCleanupPhaseReady) {
        self.phase = AxsCacheKeeperCleanupPhaseDeleting;
    }
    // Deleting：逐根删除，受共享预算与期限约束。
    for (AxsCacheKeeperSweep *sweep in self.sweeps) {
        if (sweep.complete) continue;
        if ([self deadlineHit] || self.removed >= AxsCacheKeeperCleanupRoundItemCap) {
            [self finishWithReason:AxsCacheKeeperCleanupEndReasonLimitReached];
            return;
        }
        if (!gate()) { [self cancelJob]; return; }
        // 首次真实删除推进：启动 120 秒期限，只设一次、永不重置。
        // 无可删候选的根（空根/全保留/全未确认）不启动计时：它在删除推进时立即完成，不代表删除工作已开始。
        NSUInteger remaining = AxsCacheKeeperCleanupRoundItemCap - self.removed;
        NSUInteger limit = MIN(perRootLimit, remaining);
        // 逐 unlink 本地复核：期限与配额（任务 3 扩展）。门控已按根采样，本根内不再重采
        // （与旧 Scanner 逐根采样一致；逐文件 FrontBoard 查询曾把单周期拖到约 10 秒，见 #42）。
        // 期限到达时不再开始新的 unlink；配额用尽时同样停手。
        [sweep advanceDeletion:limit shouldContinue:^BOOL {
            return ![self deadlineHit] && self.removed < AxsCacheKeeperCleanupRoundItemCap;
        } willDelete:^BOOL {
            NSTimeInterval now = self.clock();
            if (self.deleteDeadline == 0) self.deleteDeadline = now + AxsCacheKeeperCleanupDeleteTimeLimit;
            return now < self.deleteDeadline && self.removed < AxsCacheKeeperCleanupRoundItemCap;
        }];
        if (sweep.cancelled) {
            // 停手原因由作业判定：期限/配额→触顶；其余（门控已在本根采样前判定，不应到此）→取消。
            if ([self deadlineHit] || self.removed >= AxsCacheKeeperCleanupRoundItemCap) [self finishWithReason:AxsCacheKeeperCleanupEndReasonLimitReached];
            else [self cancelJob];
            return;
        }
        if ([self deadlineHit] || self.removed >= AxsCacheKeeperCleanupRoundItemCap) {
            [self finishWithReason:AxsCacheKeeperCleanupEndReasonLimitReached];
            return;
        }
    }
    BOOL allComplete = YES;
    for (AxsCacheKeeperSweep *sweep in self.sweeps) if (!sweep.complete) { allComplete = NO; break; }
    // 全部根完成：有未确认残留→Unresolved（部分完成）；否则 Completed。
    // 失败/变化的范围不阻塞其他已备好的范围，但轮次只报部分完成（见 partial）。
    if (allComplete) [self finishWithReason:self.unresolvedCount > 0 ? AxsCacheKeeperCleanupEndReasonUnresolved : AxsCacheKeeperCleanupEndReasonCompleted];
}

@end
