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
        _clock = [clock copy];
        _phase = AxsCacheKeeperCleanupPhaseChecking;
        _endReason = AxsCacheKeeperCleanupEndReasonNone;
        _deleteDeadline = 0;
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
- (BOOL)hasMixedPurge { for (AxsCacheKeeperSweep *s in self.sweeps) if (s.purgeMixed) return YES; return NO; }
- (NSUInteger)mixedPurgeRemoved { NSUInteger total = 0; for (AxsCacheKeeperSweep *s in self.sweeps) if (s.purgeMixed) total += s.removed; return total; }

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
        // 空根（预检 0 项）不启动计时：它在删除推进时立即完成，不代表删除工作已开始。
        if (self.deleteDeadline == 0 && sweep.inspected > 0) self.deleteDeadline = self.clock() + AxsCacheKeeperCleanupDeleteTimeLimit;
        NSUInteger remaining = AxsCacheKeeperCleanupRoundItemCap - self.removed;
        NSUInteger limit = MIN(perRootLimit, remaining);
        // 门控已按根采样，本根内不再重采（与旧 Scanner 逐根采样一致）。
        [sweep advanceDeletion:limit shouldContinue:^BOOL { return YES; }];
        if (sweep.cancelled) { [self cancelJob]; return; }
        if ([self deadlineHit] || self.removed >= AxsCacheKeeperCleanupRoundItemCap) {
            [self finishWithReason:AxsCacheKeeperCleanupEndReasonLimitReached];
            return;
        }
    }
    BOOL allComplete = YES;
    for (AxsCacheKeeperSweep *sweep in self.sweeps) if (!sweep.complete) { allComplete = NO; break; }
    if (allComplete) [self finishWithReason:AxsCacheKeeperCleanupEndReasonCompleted];
}

@end
