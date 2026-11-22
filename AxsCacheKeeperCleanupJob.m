#import "AxsCacheKeeperCleanupJob.h"
#import "AxsCacheKeeperCleanupHistory.h"
#import "AxsCacheKeeperSweep.h"
#include <sys/mount.h>
#include <unistd.h>
#include <errno.h>

const NSUInteger AxsCacheKeeperCleanupRoundItemCap = 2000;
const NSTimeInterval AxsCacheKeeperCleanupDeleteTimeLimit = 120;

@interface AxsCacheKeeperCleanupJob ()
@property(nonatomic, readwrite) AxsCacheKeeperCleanupPhase phase;
@property(nonatomic, readwrite) AxsCacheKeeperCleanupEndReason endReason;
@property(nonatomic, readwrite) NSTimeInterval deleteDeadline;
@property(nonatomic, copy) NSTimeInterval (^clock)(void);
@property(nonatomic,copy) NSArray<AxsCacheKeeperHardLinkGroup *> *hardLinkGroups;
@property(nonatomic) NSUInteger hardLinkCursor;
@property(nonatomic) BOOL hardLinkBudgetLimited;
- (void)axs_cachekeeper_release_prepare:(int)parentFD device:(uint64_t)device;
- (void)axs_cachekeeper_release_record:(uint64_t)rootID kind:(AxsCacheKeeperReleaseKind)kind result:(int)result code:(int)code
    pre:(AxsCacheKeeperReleaseStat)pre post:(AxsCacheKeeperReleaseStat)post;
- (void)axs_cachekeeper_release_finalize;
- (void)axs_cachekeeper_advance_cycle:(NSUInteger)limit gate:(BOOL (^)(void))gate;
@end

@implementation AxsCacheKeeperCleanupJob {
    NSMutableData *_releaseStorage;
    AxsCacheKeeperReleaseEvidence *_releaseCore;
    int _releaseVolumeFDs[AXS_CACHEKEEPER_RELEASE_VOLUME_CAP];
    uint64_t _releaseVolumeDevices[AXS_CACHEKEEPER_RELEASE_VOLUME_CAP];
    NSUInteger _releaseDepth;
}

- (instancetype)initWithSweeps:(NSArray<AxsCacheKeeperSweep *> *)sweeps
                      signature:(NSString *)signature
                       instance:(NSString *)instance
                          clock:(NSTimeInterval (^)(void))clock {
    return [self initWithSweeps:sweeps signature:signature instance:instance cleanupContext:@{@"state":@"notRecorded"} clock:clock];
}
- (instancetype)initWithSweeps:(NSArray<AxsCacheKeeperSweep *> *)sweeps
                      signature:(NSString *)signature
                       instance:(NSString *)instance
                 cleanupContext:(NSDictionary *)cleanupContext
                          clock:(NSTimeInterval (^)(void))clock {
    NSDictionary *context=axs_cachekeeper_cleanup_context_projection(cleanupContext);
    if (!context) return nil;
    if ((self = [super init])) {
        _cleanupContext=context;
        _sweeps = [sweeps copy];
        _signature = [signature copy];
        _instance = [instance copy];
        _roundID = NSUUID.UUID.UUIDString;
        _clock = [clock copy];
        _phase = AxsCacheKeeperCleanupPhaseChecking;
        _endReason = AxsCacheKeeperCleanupEndReasonNone;
        _deleteDeadline = 0;
        for (NSUInteger i=0;i<AXS_CACHEKEEPER_RELEASE_VOLUME_CAP;i++) _releaseVolumeFDs[i]=-1;
        __weak typeof(self) weak=self;
        NSUInteger rootIndex=0;
        for (AxsCacheKeeperSweep *source in _sweeps) {
            uint64_t rootID=++rootIndex;
            source.releaseEvidencePrepare=^(int parentFD,uint64_t device) {
                [weak axs_cachekeeper_release_prepare:parentFD device:device];
            };
            source.releaseEvidenceObserver=^(AxsCacheKeeperReleaseKind kind,int result,int code,
                AxsCacheKeeperReleaseStat pre,AxsCacheKeeperReleaseStat post) {
                [weak axs_cachekeeper_release_record:rootID kind:kind result:result code:code pre:pre post:post];
            };
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
- (NSUInteger)hardLinkRetainedCount { NSUInteger total=0;for (AxsCacheKeeperSweep *s in self.sweeps) total+=s.hardLinkRetainedCount;return total; }
- (unsigned long long)hardLinkRetainedBytes { unsigned long long total=0;for (AxsCacheKeeperSweep *s in self.sweeps) total+=s.hardLinkRetainedBytes;return total; }
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
    [self axs_cachekeeper_release_finalize];
}

#pragma mark - 周期推进

- (void)advanceCycleWithPerRootLimit:(NSUInteger)perRootLimit gate:(BOOL (^)(void))gate {
    _releaseDepth++;
    @try { [self axs_cachekeeper_advance_cycle:perRootLimit gate:gate]; }
    @finally { _releaseDepth--;[self axs_cachekeeper_release_finalize]; }
}
- (void)axs_cachekeeper_advance_cycle:(NSUInteger)perRootLimit gate:(BOOL (^)(void))gate {
    if (!perRootLimit || self.phase == AxsCacheKeeperCleanupPhaseFinished) return;
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
        self.hardLinkGroups=[AxsCacheKeeperSweep closedHardLinkGroupsForSweeps:self.sweeps];
        self.phase = AxsCacheKeeperCleanupPhaseReady;
        return; // 预检周期内不删除；下周期转入删除（每周期只做一个阶段）
    }
    if (self.phase == AxsCacheKeeperCleanupPhaseReady) {
        self.phase = AxsCacheKeeperCleanupPhaseDeleting;
    }
    // Reserve the complete group against the live job total. Group results update every owning
    // sweep immediately; a later per-root loop must never budget or count these paths again.
    if (self.hardLinkCursor<self.hardLinkGroups.count) {
        AxsCacheKeeperHardLinkGroup *group=self.hardLinkGroups[self.hardLinkCursor];
        if ([self deadlineHit] || self.removed>=AxsCacheKeeperCleanupRoundItemCap) {
            [self finishWithReason:AxsCacheKeeperCleanupEndReasonLimitReached];return;
        }
        if (group.memberCount>AxsCacheKeeperCleanupRoundItemCap-self.removed) {
            // Only this group cannot fit; independent ordinary candidates can still use the quota.
            [group retainForBudget];self.hardLinkBudgetLimited=YES;self.hardLinkCursor++;return;
        }
        if (!gate()) {[self cancelJob];return;}
        __block NSUInteger nextGateRemoval=self.removed;
        [group reclaimWithShouldContinue:^BOOL {
            return self.phase!=AxsCacheKeeperCleanupPhaseFinished && ![self deadlineHit];
        } beforeMember:^BOOL {
            // Group setup may traverse many parents. Resample before its first unlink, then
            // no less often than the original per-root batch, even across different roots.
            if (self.removed>=nextGateRemoval) {
                if (!gate()) {[self cancelJob];return NO;}
                nextGateRemoval=self.removed+MAX((NSUInteger)1,perRootLimit);
            }
            return self.phase!=AxsCacheKeeperCleanupPhaseFinished && ![self deadlineHit];
        } willDelete:^BOOL {
            NSTimeInterval now=self.clock();
            if (!self.deleteDeadline) self.deleteDeadline=now+AxsCacheKeeperCleanupDeleteTimeLimit;
            return self.phase!=AxsCacheKeeperCleanupPhaseFinished && now<self.deleteDeadline &&
                self.removed<AxsCacheKeeperCleanupRoundItemCap;
        }];
        self.hardLinkCursor++;
        if (self.phase==AxsCacheKeeperCleanupPhaseFinished) return;
        if ([self deadlineHit] || self.removed>=AxsCacheKeeperCleanupRoundItemCap) {
            [self finishWithReason:AxsCacheKeeperCleanupEndReasonLimitReached];return;
        }
        return; // At most one group per cycle; the group also samples the gate per batch.
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
            return self.phase!=AxsCacheKeeperCleanupPhaseFinished && ![self deadlineHit] && self.removed < AxsCacheKeeperCleanupRoundItemCap;
        } willDelete:^BOOL {
            NSTimeInterval now = self.clock();
            if (self.deleteDeadline == 0) self.deleteDeadline = now + AxsCacheKeeperCleanupDeleteTimeLimit;
            return self.phase!=AxsCacheKeeperCleanupPhaseFinished && now < self.deleteDeadline && self.removed < AxsCacheKeeperCleanupRoundItemCap;
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
    // 全部根已推进：预算保留组→LimitReached；未确认残留→Unresolved；否则 Completed。
    // 失败/变化的范围不阻塞其他已备好的范围，但轮次只报部分完成（见 partial）。
    if (allComplete) [self finishWithReason:self.hardLinkBudgetLimited ? AxsCacheKeeperCleanupEndReasonLimitReached :
        self.unresolvedCount > 0 ? AxsCacheKeeperCleanupEndReasonUnresolved : AxsCacheKeeperCleanupEndReasonCompleted];
}

#pragma mark - Bounded unlink evidence

- (void)axs_cachekeeper_release_ensure {
    if (_releaseCore) return;
    _releaseStorage=[NSMutableData dataWithLength:sizeof(AxsCacheKeeperReleaseEvidence)];
    _releaseCore=_releaseStorage.mutableBytes;
    axs_cachekeeper_release_init(_releaseCore);
}
static AxsCacheKeeperReleaseVolumeSample axs_cachekeeper_job_volume_sample(int fd) {
    AxsCacheKeeperReleaseVolumeSample sample={0};struct statfs info;
    if (fstatfs(fd,&info)) {sample.state=AxsCacheKeeperReleaseUnavailable;sample.error=errno;return sample;}
    sample.state=AxsCacheKeeperReleaseObserved;sample.blockSize=info.f_bsize;
    sample.freeBlocks=info.f_bfree;sample.availableBlocks=info.f_bavail;
    sample.uptime=NSProcessInfo.processInfo.systemUptime;return sample;
}
- (void)axs_cachekeeper_release_prepare:(int)parentFD device:(uint64_t)device {
    [self axs_cachekeeper_release_ensure];
    if (_releaseCore->finished) return;
    for (NSUInteger i=0;i<_releaseCore->volumeCount;i++) if (_releaseVolumeDevices[i]==device) return;
    if (_releaseCore->volumeCount==AXS_CACHEKEEPER_RELEASE_VOLUME_CAP) {
        axs_cachekeeper_release_begin_volume(_releaseCore,(AxsCacheKeeperReleaseVolumeSample){0});return;
    }
    int fd=dup(parentFD);AxsCacheKeeperReleaseVolumeSample sample={0};
    if (fd<0) {sample.state=AxsCacheKeeperReleaseUnavailable;sample.error=errno;}
    else sample=axs_cachekeeper_job_volume_sample(fd);
    size_t volumeID=axs_cachekeeper_release_begin_volume(_releaseCore,sample);
    _releaseVolumeFDs[volumeID-1]=fd;_releaseVolumeDevices[volumeID-1]=device;
}
- (void)axs_cachekeeper_release_record:(uint64_t)rootID kind:(AxsCacheKeeperReleaseKind)kind result:(int)result code:(int)code
    pre:(AxsCacheKeeperReleaseStat)pre post:(AxsCacheKeeperReleaseStat)post {
    [self axs_cachekeeper_release_ensure];
    axs_cachekeeper_release_record(_releaseCore,rootID,kind,result,code,pre,post);
}
- (void)axs_cachekeeper_release_finalize {
    if (_releaseDepth || self.phase!=AxsCacheKeeperCleanupPhaseFinished || !_releaseCore || _releaseCore->finished) return;
    int saved=errno;
    for (NSUInteger i=0;i<_releaseCore->volumeCount;i++) {
        int fd=_releaseVolumeFDs[i];AxsCacheKeeperReleaseVolumeSample after={0};int closeError=0;
        if (fd>=0) {
            after=axs_cachekeeper_job_volume_sample(fd);
            if (close(fd)) closeError=errno;
            _releaseVolumeFDs[i]=-1; // Never retry close: the descriptor number may have been reused.
        } else {
            // No post syscall was possible after dup failed: do not copy a prior errno into it.
            after.state=AxsCacheKeeperReleaseNotRecorded;
        }
        axs_cachekeeper_release_end_volume(_releaseCore,i+1,after,closeError);
    }
    axs_cachekeeper_release_finish(_releaseCore,self.endReason==AxsCacheKeeperCleanupEndReasonCancelled);
    errno=saved;
}
- (void)dealloc {
    for (NSUInteger i=0;i<AXS_CACHEKEEPER_RELEASE_VOLUME_CAP;i++) if (_releaseVolumeFDs[i]>=0) close(_releaseVolumeFDs[i]);
}
static NSDictionary *axs_cachekeeper_job_metadata(AxsCacheKeeperReleaseMetadata m) {
    if (m.state==AxsCacheKeeperReleaseObserved) return @{@"state":@"observed",@"errno":@0,@"size":@(m.size),@"blocks":@(m.blocks),@"nlink":@(m.nlink)};
    return @{@"state":m.state==AxsCacheKeeperReleaseInvalid ? @"invalidMetadata" : @"unavailable",@"errno":@(m.error)};
}
static NSDictionary *axs_cachekeeper_job_volume_metadata(AxsCacheKeeperReleaseVolumeSample m) {
    if (m.state==AxsCacheKeeperReleaseObserved) return @{@"state":@"observed",@"errno":@0,@"blockSize":@(m.blockSize),
        @"freeBlocks":@(m.freeBlocks),@"availableBlocks":@(m.availableBlocks),@"uptime":@(m.uptime)};
    NSString *state=m.state==AxsCacheKeeperReleaseNotRecorded ? @"notRecorded" : m.state==AxsCacheKeeperReleaseInvalid ? @"invalidMetadata" : @"unavailable";
    return @{@"state":state,@"errno":@(m.error)};
}
- (NSDictionary *)releaseEvidence {
    static const AxsCacheKeeperReleaseEvidence empty={0};
    const AxsCacheKeeperReleaseEvidence *e=_releaseCore ?: &empty;
    NSMutableArray *details=[NSMutableArray new],*volumes=[NSMutableArray new];
    for (NSUInteger i=0;i<e->detailCount;i++) {
        const AxsCacheKeeperReleaseDetail *d=&e->details[i];
        NSString *match=d->identityMatch==AxsCacheKeeperReleaseSame ? @"same" : d->identityMatch==AxsCacheKeeperReleaseDifferent ? @"different" : @"notObserved";
        NSString *transition=d->linkTransition==AxsCacheKeeperReleaseLinkDecremented ? @"decremented" :
            d->linkTransition==AxsCacheKeeperReleaseLinkUnchanged ? @"unchanged" : d->linkTransition==AxsCacheKeeperReleaseLinkOther ? @"other" : @"notObserved";
        [details addObject:@{@"attemptID":@(d->attemptID),@"rootID":@(d->rootID),@"objectID":@(d->objectID),
            @"kind":d->kind==AxsCacheKeeperReleaseHardlink ? @"closedHardlink" : @"ordinary",@"result":@(d->result),@"errno":@(d->error),
            @"pre":axs_cachekeeper_job_metadata(d->pre),@"post":axs_cachekeeper_job_metadata(d->post),@"identityMatch":match,@"linkTransition":transition}];
    }
    for (NSUInteger i=0;i<e->volumeCount;i++) {
        const AxsCacheKeeperReleaseVolume *v=&e->volumes[i];
        NSString *state=v->overflow ? @"overflow" : v->paired ? @"observed" :
            v->after.state==AxsCacheKeeperReleaseNotRecorded && !e->finished ? @"recording" : @"unavailable";
        NSMutableDictionary *row=[@{@"volumeID":@(i+1),@"state":state,@"before":axs_cachekeeper_job_volume_metadata(v->before),
            @"after":axs_cachekeeper_job_volume_metadata(v->after),@"closeErrno":@(v->closeError)} mutableCopy];
        if (v->paired) {row[@"freeBytesDelta"]=@(v->freeBytesDelta);row[@"availableBytesDelta"]=@(v->availableBytesDelta);row[@"elapsedSeconds"]=@(v->elapsedSeconds);}
        [volumes addObject:[row copy]];
    }
    NSString *state=!e->attempts ? @"notRecorded" : !e->finished ? @"recording" : e->cancelled ? @"cancelled" : @"finished";
    return @{@"schemaVersion":@1,@"roundID":self.roundID,@"revision":@(e->revision),@"state":state,@"attempts":@(e->attempts),
        @"succeeded":@(e->succeeded),@"failed":@(e->failed),@"postMissing":@(e->postMissing),@"detailsOmitted":@(e->detailsOmitted),
        @"identitiesOmitted":@(e->identitiesOmitted),@"volumesOmitted":@(e->volumesOmitted),@"overflow":@((BOOL)e->overflow),
        @"details":[details copy],@"volumes":[volumes copy],@"uniqueExtents":@"notMeasured",@"reclaimedPhysicalBytes":@"notMeasured"};
}

@end
