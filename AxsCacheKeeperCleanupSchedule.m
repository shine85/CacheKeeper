#import "AxsCacheKeeperCleanupSchedule.h"
#import "AxsCacheKeeperCleanupJob.h"
#import "AxsCacheKeeperSweep.h"
#import "AxsCacheKeeperReceipts.h"
#include <errno.h>
#include <string.h>

static NSArray *AxsCacheKeeperRangeStamp(struct stat info) {
    return @[@(info.st_dev),@(info.st_ino),@(info.st_mtimespec.tv_sec),@(info.st_mtimespec.tv_nsec),
             @(info.st_ctimespec.tv_sec),@(info.st_ctimespec.tv_nsec)];
}

@implementation AxsCacheKeeperCleanupSchedule
+ (NSDictionary *)registrationForSweep:(AxsCacheKeeperSweep *)sweep signature:(NSString *)signature now:(NSTimeInterval)now {
    // 删除会推进目录基线，可能包含未观察的新条目；下个短周期完整观察后再登记。
    if (!sweep.complete || sweep.cancelled || sweep.removed || !sweep.coverageComplete || !sweep.measurementComplete ||
        sweep.failed || sweep.recentCount || sweep.changedCount || sweep.hardLinkRetainedCount ||
        sweep.dependencyInvalidated || sweep.remainingCandidates || sweep.deferredCount) return nil;
    struct stat info;
    if (lstat(sweep.root.fileSystemRepresentation,&info) || !S_ISDIR(info.st_mode) ||
        ![sweep.rootObservationStamp isEqual:AxsCacheKeeperRangeStamp(info)]) return nil;
    NSMutableDictionary *record=[@{@"signature":signature, @"stamp":AxsCacheKeeperRangeStamp(info), @"checkedAt":@(now),
        @"updated":NSDate.date, @"unresolved":@(sweep.unresolvedCount), @"unresolvedBytes":@(sweep.unresolvedBytes),
        @"evidence":sweep.unresolvedEvidence ?: @""} mutableCopy];
    NSDictionary *report=[sweep directoryReport];
    for (NSString *key in @[@"protected",@"retainedSubtreeCount",@"retainedSubtrees",@"appRuleID",@"appRuleSummary",@"appRuleWaitingForExit"]) if (report[key]) record[key]=report[key];
    return record;
}
+ (AxsCacheKeeperRangeState)checkRoot:(NSString *)root registration:(NSDictionary *)registration signature:(NSString *)signature
                                now:(NSTimeInterval)now stat:(int (^)(const char *, struct stat *))statBlock error:(NSString **)error {
    struct stat info;
    int result=statBlock ? statBlock(root.fileSystemRepresentation,&info) : lstat(root.fileSystemRepresentation,&info);
    if (result) {
        int code=errno;
        if (code==ENOENT) return AxsCacheKeeperRangeMissing;
        if (error) *error=[NSString stringWithFormat:@"读取范围失败（errno %d：%s），稍后重试",code,strerror(code)];
        return AxsCacheKeeperRangeFailed;
    }
    if (!S_ISDIR(info.st_mode)) {
        if (error) *error=@"范围已不是普通目录，稍后重新发现";
        return AxsCacheKeeperRangeFailed;
    }
    NSTimeInterval age=now-[registration[@"checkedAt"] doubleValue];
    // 根时间戳不覆盖后代原地改写，最多沿用 30 分钟，之后重新测量。
    if (registration && age>=0 && age<1800 && [registration[@"signature"] isEqual:signature] &&
        [registration[@"stamp"] isEqual:AxsCacheKeeperRangeStamp(info)]) return AxsCacheKeeperRangeUnchanged;
    return AxsCacheKeeperRangeScan;
}
+ (NSArray<AxsCacheKeeperSweep *> *)sweepsForRanges:(NSArray<NSString *> *)ranges home:(NSString *)home
    bundle:(NSString *)bundle version:(NSString *)version state:(NSDictionary *)state signature:(NSString *)signature
    registrations:(NSMutableDictionary *)registrations exclusions:(NSArray<NSString *> *)exclusions
    restoreError:(NSString *)restoreError now:(NSTimeInterval)now diagnostics:(NSMutableDictionary *)diagnostics {
    NSMutableArray *sweeps=[NSMutableArray new];
    for (NSString *relative in ranges) {
        BOOL blocked=NO;
        for (NSString *failedPath in exclusions) if (!failedPath.length || [relative isEqual:failedPath] ||
            [relative hasPrefix:[failedPath stringByAppendingString:@"/"]]) {blocked=YES;break;}
        if (blocked) {
            [registrations removeObjectForKey:relative];
            diagnostics[relative]=@{@"updated":NSDate.date,@"measurementComplete":@NO,@"coverageComplete":@NO,
                @"failed":@1,@"error":restoreError ?: @"旧权限恢复失败"};continue;
        }
        NSString *root=[home stringByAppendingPathComponent:relative],*rangeError=nil;
        AxsCacheKeeperRangeState rangeState=[self checkRoot:root registration:registrations[relative]
            signature:signature now:now stat:nil error:&rangeError];
        if (rangeState==AxsCacheKeeperRangeUnchanged) continue;
        [registrations removeObjectForKey:relative];
        if (rangeState==AxsCacheKeeperRangeMissing) continue;
        if (rangeState==AxsCacheKeeperRangeFailed) {
            diagnostics[relative]=@{@"updated":NSDate.date,@"measurementComplete":@NO,@"coverageComplete":@NO,
                @"failed":@1,@"error":rangeError};continue;
        }
        [sweeps addObject:[[AxsCacheKeeperSweep alloc] initWithRoot:root bundle:bundle version:version containerPath:home state:state]];
    }
    for (NSString *failedPath in exclusions) if (failedPath.length) {
        for (NSString *relative in ranges) if ([failedPath hasPrefix:[relative stringByAppendingString:@"/"]])
            diagnostics[failedPath]=@{@"updated":NSDate.date,@"measurementComplete":@NO,@"coverageComplete":@NO,
                @"failed":@1,@"error":restoreError ?: @"旧权限恢复失败"};
    }
    return sweeps;
}
+ (BOOL)hasWorkForSweeps:(NSArray *)sweeps diagnostics:(NSDictionary *)diagnostics externalFailures:(NSUInteger)failures manual:(BOOL)manual {
    return manual || sweeps.count || diagnostics.count || failures;
}
+ (NSDictionary *)carriedReport:(NSDictionary *)registration {
    NSMutableDictionary *report=[@{@"updated":registration[@"updated"], @"complete":@YES, @"checking":@NO, @"cancelled":@NO,
        @"measurementComplete":@NO, @"coverageComplete":@NO, @"skipped":@YES, @"removed":@0, @"bytes":@0,
        @"unresolved":registration[@"unresolved"], @"unresolvedBytes":registration[@"unresolvedBytes"],
        @"purgeClassification":[registration[@"unresolved"] boolValue] ? @"paused" : @"", @"purgeEvidence":registration[@"evidence"] ?: @"", @"error":@""} mutableCopy];
    for (NSString *key in @[@"protected",@"retainedSubtreeCount",@"retainedSubtrees",@"appRuleID",@"appRuleSummary",@"appRuleWaitingForExit"]) if (registration[key]) report[key]=registration[key];
    return report;
}
+ (NSDictionary *)summaryForJob:(AxsCacheKeeperCleanupJob *)job directories:(NSDictionary *)directories
              externalFailures:(NSUInteger)externalFailures discoveryComplete:(BOOL)discoveryComplete {
    NSUInteger failed=externalFailures, recent=0, changed=0, unresolved=0, remaining=0, hardLinkRetained=0;
    unsigned long long unresolvedBytes=0,hardLinkRetainedBytes=0;
    BOOL coverage=discoveryComplete && !externalFailures;
    for (NSDictionary *report in directories.allValues) {
        failed += [report[@"failed"] unsignedIntegerValue]; recent += [report[@"recent"] unsignedIntegerValue];
        changed += [report[@"changed"] unsignedIntegerValue]; remaining += [report[@"remaining"] unsignedIntegerValue];
        unresolved += [report[@"unresolved"] unsignedIntegerValue]; unresolvedBytes += [report[@"unresolvedBytes"] unsignedLongLongValue];
        hardLinkRetained += [report[@"hardLinkRetained"] unsignedIntegerValue];hardLinkRetainedBytes += [report[@"hardLinkRetainedBytes"] unsignedLongLongValue];
        coverage = coverage && [report[@"coverageComplete"] boolValue];
    }
    AxsCacheKeeperCleanupEndReason reason=job.endReason;
    if (reason==AxsCacheKeeperCleanupEndReasonCompleted && unresolved) reason=AxsCacheKeeperCleanupEndReasonUnresolved;
    return @{@"removed":@(job.removed), @"failed":@(failed), @"recent":@(recent), @"changed":@(changed),
        @"remaining":@(remaining), @"unresolved":@(unresolved), @"unresolvedBytes":@(unresolvedBytes),
        @"hardLinkRetained":@(hardLinkRetained),@"hardLinkRetainedBytes":@(hardLinkRetainedBytes),
        @"endReason":@(reason), @"coverageComplete":@(coverage)};
}
+ (NSTimeInterval)quietIntervalForSummary:(NSDictionary *)summary {
    (void)summary;return 30;
}
+ (BOOL)retireJob:(AxsCacheKeeperCleanupJob *)job bundle:(NSString *)bundle message:(NSString *)message {
    if (!job) return YES;
    [job cancel];
    NSMutableDictionary *directories=[NSMutableDictionary new];
    for (AxsCacheKeeperSweep *sweep in job.sweeps) directories[sweep.relativePath]=[sweep directoryReport];
    return [AxsCacheKeeperReceipts submitRoundForBundle:bundle roundID:job.roundID removed:job.removed bytes:job.bytes
        endReason:job.endReason phase:@"waiting" message:message failed:job.failed effectivePaths:directories.allKeys
        discoveredPaths:nil directories:directories round:@{@"removed":@(job.removed),@"bytes":@(job.bytes)} coverageComplete:NO releaseEvidence:job.releaseEvidence cleanupContext:job.cleanupContext];
}
+ (BOOL)shouldSkipSummary:(NSDictionary *)summary signature:(NSString *)signature now:(NSTimeInterval)now {
    if (![summary[@"signature"] isEqual:signature] || ![summary[@"finishedAt"] isKindOfClass:NSNumber.class]) return NO;
    NSTimeInterval elapsed=now-[summary[@"finishedAt"] doubleValue];
    // 长静默只限制完整遍历；根元数据和发现集仍每短周期核对，避免新增缓存盲等。
    return elapsed>=0 && elapsed<[self quietIntervalForSummary:summary];
}
+ (NSArray<NSString *> *)restoreExclusions:(NSDictionary *)restored home:(NSString *)home {
    NSMutableArray *paths=[NSMutableArray new];
    if (!home.length) return paths;
    NSString *prefix=[home stringByAppendingString:@"/"];
    for (id path in restored[@"failedPaths"]) if ([path isKindOfClass:NSString.class]) {
        if ([path isEqual:home]) [paths addObject:@""];
        else if ([path hasPrefix:prefix]) [paths addObject:[path substringFromIndex:prefix.length]];
    }
    return paths;
}
@end
