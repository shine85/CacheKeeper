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
    // 只暂停纯待识别范围；近期、变化、失败、未删候选都必须进入后续轮次。
    if (!sweep.complete || sweep.cancelled || !sweep.coverageComplete || !sweep.unresolvedCount ||
        sweep.remainingCandidates || sweep.deferredCount) return nil;
    struct stat info;
    if (lstat(sweep.root.fileSystemRepresentation,&info) || !S_ISDIR(info.st_mode)) return nil;
    return @{@"signature":signature, @"stamp":AxsCacheKeeperRangeStamp(info), @"checkedAt":@(now),
        @"updated":NSDate.date, @"unresolved":@(sweep.unresolvedCount), @"unresolvedBytes":@(sweep.unresolvedBytes),
        @"evidence":sweep.unresolvedEvidence ?: @""};
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
+ (NSDictionary *)carriedReport:(NSDictionary *)registration {
    return @{@"updated":registration[@"updated"], @"complete":@YES, @"checking":@NO, @"cancelled":@NO,
        @"measurementComplete":@NO, @"coverageComplete":@NO, @"skipped":@YES, @"removed":@0, @"bytes":@0,
        @"unresolved":registration[@"unresolved"], @"unresolvedBytes":registration[@"unresolvedBytes"],
        @"purgeClassification":@"paused", @"purgeEvidence":registration[@"evidence"] ?: @"", @"error":@""};
}
+ (NSDictionary *)summaryForJob:(AxsCacheKeeperCleanupJob *)job directories:(NSDictionary *)directories
              externalFailures:(NSUInteger)externalFailures discoveryComplete:(BOOL)discoveryComplete {
    NSUInteger failed=externalFailures, recent=0, changed=0, unresolved=0, remaining=0;
    unsigned long long unresolvedBytes=0;
    BOOL coverage=discoveryComplete && !externalFailures;
    for (NSDictionary *report in directories.allValues) {
        failed += [report[@"failed"] unsignedIntegerValue]; recent += [report[@"recent"] unsignedIntegerValue];
        changed += [report[@"changed"] unsignedIntegerValue]; remaining += [report[@"remaining"] unsignedIntegerValue];
        unresolved += [report[@"unresolved"] unsignedIntegerValue]; unresolvedBytes += [report[@"unresolvedBytes"] unsignedLongLongValue];
        coverage = coverage && [report[@"coverageComplete"] boolValue];
    }
    AxsCacheKeeperCleanupEndReason reason=job.endReason;
    if (reason==AxsCacheKeeperCleanupEndReasonCompleted && unresolved) reason=AxsCacheKeeperCleanupEndReasonUnresolved;
    return @{@"removed":@(job.removed), @"failed":@(failed), @"recent":@(recent), @"changed":@(changed),
        @"remaining":@(remaining), @"unresolved":@(unresolved), @"unresolvedBytes":@(unresolvedBytes),
        @"endReason":@(reason), @"coverageComplete":@(coverage)};
}
+ (NSTimeInterval)quietIntervalForSummary:(NSDictionary *)summary {
    return [summary[@"endReason"] integerValue]==AxsCacheKeeperCleanupEndReasonCompleted &&
        ![summary[@"removed"] unsignedIntegerValue] && ![summary[@"failed"] unsignedIntegerValue] &&
        ![summary[@"recent"] unsignedIntegerValue] && ![summary[@"changed"] unsignedIntegerValue] &&
        ![summary[@"remaining"] unsignedIntegerValue] && ![summary[@"unresolved"] unsignedIntegerValue] &&
        [summary[@"coverageComplete"] boolValue] ? 1800 : 30;
}
+ (BOOL)retireJob:(AxsCacheKeeperCleanupJob *)job bundle:(NSString *)bundle message:(NSString *)message {
    if (!job) return YES;
    [job cancel];
    NSMutableDictionary *directories=[NSMutableDictionary new];
    for (AxsCacheKeeperSweep *sweep in job.sweeps) directories[sweep.relativePath]=[sweep directoryReport];
    return [AxsCacheKeeperReceipts submitRoundForBundle:bundle roundID:job.roundID removed:job.removed bytes:job.bytes
        endReason:job.endReason phase:@"waiting" message:message failed:job.failed effectivePaths:directories.allKeys
        discoveredPaths:nil directories:directories round:@{@"removed":@(job.removed),@"bytes":@(job.bytes)} coverageComplete:NO];
}
+ (BOOL)shouldSkipSummary:(NSDictionary *)summary signature:(NSString *)signature now:(NSTimeInterval)now {
    if (![summary[@"signature"] isEqual:signature] || ![summary[@"finishedAt"] isKindOfClass:NSNumber.class]) return NO;
    NSTimeInterval elapsed=now-[summary[@"finishedAt"] doubleValue];
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
