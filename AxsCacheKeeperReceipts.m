#import "AxsCacheKeeperReceipts.h"

static dispatch_queue_t AxsCacheKeeperReceiptsQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("dev.local.cachekeeper.receipts", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

static NSString *AxsCacheKeeperReceiptsFolder = nil;
static NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *AxsCacheKeeperReceiptsPending = nil;

@interface AxsCacheKeeperReceipts ()
+ (BOOL)flushQueueForBundle:(NSString *)bundle;
+ (BOOL)attemptSnapshot:(NSDictionary *)snapshot bundle:(NSString *)bundle;
+ (BOOL)writeStatusForBundle:(NSString *)bundle phase:(NSString *)phase message:(NSString *)message failed:(NSUInteger)failed effectivePaths:(NSArray *)effectivePaths discoveredPaths:(NSArray *)discoveredPaths directories:(NSDictionary *)directories;
@end

@implementation AxsCacheKeeperReceipts

+ (void)configureWithStatusFolder:(NSString *)folder {
    dispatch_sync(AxsCacheKeeperReceiptsQueue(), ^{
        AxsCacheKeeperReceiptsFolder = [folder copy];
        if (!AxsCacheKeeperReceiptsPending) AxsCacheKeeperReceiptsPending = [NSMutableDictionary new];
    });
}

+ (void)resetForTesting {
    dispatch_sync(AxsCacheKeeperReceiptsQueue(), ^{
        AxsCacheKeeperReceiptsFolder = nil;
        AxsCacheKeeperReceiptsPending = [NSMutableDictionary new];
    });
}

+ (BOOL)hasPendingForBundle:(NSString *)bundle {
    __block BOOL pending = NO;
    dispatch_sync(AxsCacheKeeperReceiptsQueue(), ^{
        pending = AxsCacheKeeperReceiptsPending[bundle].count > 0;
    });
    return pending;
}

+ (BOOL)flushPendingForBundle:(NSString *)bundle {
    __block BOOL done = NO;
    dispatch_sync(AxsCacheKeeperReceiptsQueue(), ^{
        done = [self flushQueueForBundle:bundle];
    });
    return done;
}

+ (BOOL)submitRoundForBundle:(NSString *)bundle roundID:(NSString *)roundID removed:(NSUInteger)removed bytes:(unsigned long long)bytes endReason:(NSInteger)endReason phase:(NSString *)phase message:(NSString *)message failed:(NSUInteger)failed effectivePaths:(NSArray *)effectivePaths discoveredPaths:(NSArray *)discoveredPaths directories:(NSDictionary *)directories round:(NSDictionary *)round coverageComplete:(BOOL)coverageComplete {
    if (!bundle.length || !roundID.length) return NO;
    NSMutableDictionary *snapshot = [NSMutableDictionary dictionaryWithDictionary:@{@"roundID":roundID, @"removed":@(removed), @"bytes":@(bytes), @"endReason":@(endReason), @"phase":phase ?: @"", @"message":message ?: @"", @"failed":@(failed), @"effectivePaths":effectivePaths ?: @[], @"coverageComplete":@(coverageComplete)}];
    if (discoveredPaths) snapshot[@"discoveredPaths"] = discoveredPaths;
    if (directories) snapshot[@"directories"] = directories;
    if (round) snapshot[@"round"] = round;
    __block BOOL done = NO;
    dispatch_sync(AxsCacheKeeperReceiptsQueue(), ^{
        if (!AxsCacheKeeperReceiptsPending) AxsCacheKeeperReceiptsPending = [NSMutableDictionary new];
        NSMutableArray *queue = AxsCacheKeeperReceiptsPending[bundle];
        if (!queue) { queue = [NSMutableArray new]; AxsCacheKeeperReceiptsPending[bundle] = queue; }
        // 同轮合并：同一 roundID 的快照只留最新累计（原地替换，队列顺序不变）；
        // 不同轮次各占一项——每轮累计量独立核算，跨轮合并会错认已确认量致重复或丢失。
        NSUInteger existing = NSNotFound;
        for (NSUInteger i = 0; i < queue.count; i++) if ([queue[i][@"roundID"] isEqual:roundID]) { existing = i; break; }
        if (existing != NSNotFound) queue[existing] = [snapshot copy];
        else [queue addObject:[snapshot copy]];
        done = [self flushQueueForBundle:bundle];
    });
    return done;
}

+ (BOOL)updateStatusForBundle:(NSString *)bundle phase:(NSString *)phase message:(NSString *)message failed:(NSUInteger)failed effectivePaths:(NSArray *)effectivePaths discoveredPaths:(NSArray *)discoveredPaths directories:(NSDictionary *)directories {
    if (!bundle.length) return NO;
    __block BOOL done = NO;
    dispatch_sync(AxsCacheKeeperReceiptsQueue(), ^{
        done = [self writeStatusForBundle:bundle phase:phase message:message failed:failed effectivePaths:effectivePaths discoveredPaths:discoveredPaths directories:directories];
    });
    return done;
}

#pragma mark - 队列内实现（须在串行队列内调用）

// 按序落盘：队首失败即停，后面的快照下次再试。返回 YES 表示队列已空。
+ (BOOL)flushQueueForBundle:(NSString *)bundle {
    NSMutableArray *queue = AxsCacheKeeperReceiptsPending[bundle];
    while (queue.count) {
        if (![self attemptSnapshot:queue[0] bundle:bundle]) return NO;
        [queue removeObjectAtIndex:0];
    }
    return YES;
}

// 一次读改写：返回 YES 表示已落盘或无需落盘；NO 表示损坏、未配置或写失败。
// 增量按 roundID 核算：与已确认轮次相同只计差额（重复提交为 0），不同轮次计全量。
+ (BOOL)attemptSnapshot:(NSDictionary *)snapshot bundle:(NSString *)bundle {
    if (!AxsCacheKeeperReceiptsFolder.length) return NO;
    NSString *path = [[AxsCacheKeeperReceiptsFolder stringByAppendingPathComponent:bundle] stringByAppendingString:@".auto.plist"];
    NSDictionary *previous = [NSDictionary dictionaryWithContentsOfFile:path];
    if (!previous && [[NSFileManager defaultManager] fileExistsAtPath:path]) {
        // 损坏/不可读的回执：明确失败，永不以累计 0 覆盖。恢复须手动删除损坏文件后重试。
        NSLog(@"[CacheKeeper] 回执文件损坏，拒绝覆盖：%@", path);
        return NO;
    }
    NSString *roundID = snapshot[@"roundID"];
    NSUInteger submittedRemoved = [snapshot[@"removed"] unsignedIntegerValue];
    unsigned long long submittedBytes = [snapshot[@"bytes"] unsignedLongLongValue];
    NSUInteger prevRemoved = [previous[@"removed"] unsignedIntegerValue];
    unsigned long long prevBytes = [previous[@"bytes"] unsignedLongLongValue];
    NSUInteger incrementRemoved;
    unsigned long long incrementBytes;
    if ([previous[@"confirmedRoundID"] isEqual:roundID]) {
        NSUInteger confirmedRemoved = [previous[@"confirmedRemoved"] unsignedIntegerValue];
        unsigned long long confirmedBytes = [previous[@"confirmedBytes"] unsignedLongLongValue];
        incrementRemoved = submittedRemoved > confirmedRemoved ? submittedRemoved - confirmedRemoved : 0;
        incrementBytes = submittedBytes > confirmedBytes ? submittedBytes - confirmedBytes : 0;
    } else {
        incrementRemoved = submittedRemoved;
        incrementBytes = submittedBytes;
    }
    NSDictionary *round = snapshot[@"round"];
    NSArray *known = snapshot[@"discoveredPaths"] ?: (previous[@"discoveredPaths"] ?: @[]);
    NSDictionary *directories = snapshot[@"directories"];
    // 去重：增量为 0、非退役、展示内容未变且 30 秒内写过——不重复落盘（沿用旧 report 的去重语义）。
    // 覆盖完整性变化同样打破去重（任务 5/6：发现不完整时面板须如实展示，不得沿用旧的完整标记）。
    if (!round && !incrementRemoved && !incrementBytes && [previous[@"phase"] isEqual:snapshot[@"phase"]] && [previous[@"message"] isEqual:snapshot[@"message"]] &&
        [previous[@"failed"] unsignedIntegerValue] == [snapshot[@"failed"] unsignedIntegerValue] && [previous[@"effectivePaths"] isEqual:snapshot[@"effectivePaths"]] &&
        [previous[@"discoveredPaths"] isEqual:known] && [previous[@"coverageComplete"] isEqual:snapshot[@"coverageComplete"]] && !directories && -[previous[@"updated"] timeIntervalSinceNow] < 30) return YES;
    NSDictionary *report = @{@"updated":NSDate.date, @"phase":snapshot[@"phase"], @"message":snapshot[@"message"],
        @"removed":@(prevRemoved + incrementRemoved),
        @"bytes":@(prevBytes + incrementBytes), @"failed":snapshot[@"failed"],
        @"lastRemoved":round ? round[@"removed"] : (previous[@"lastRemoved"] ?: @0),
        @"lastBytes":round ? round[@"bytes"] : (previous[@"lastBytes"] ?: @0),
        @"endReason":round ? snapshot[@"endReason"] : (previous[@"endReason"] ?: @0),
        @"confirmedRoundID":roundID, @"confirmedRemoved":@(submittedRemoved), @"confirmedBytes":@(submittedBytes),
        @"coverageComplete":snapshot[@"coverageComplete"] ?: (previous[@"coverageComplete"] ?: @NO),
        @"effectivePaths":snapshot[@"effectivePaths"], @"discoveredPaths":known, @"directories":directories ?: previous[@"directories"] ?: @{}};
    if (![report writeToFile:path atomically:YES]) { NSLog(@"[CacheKeeper] 无法保存 %@ 清理状态", bundle); return NO; }
    return YES;
}

// 展示状态写盘：累计量与已确认轮次原样保留；损坏回执同样明确失败、不覆盖。
+ (BOOL)writeStatusForBundle:(NSString *)bundle phase:(NSString *)phase message:(NSString *)message failed:(NSUInteger)failed effectivePaths:(NSArray *)effectivePaths discoveredPaths:(NSArray *)discoveredPaths directories:(NSDictionary *)directories {
    if (!AxsCacheKeeperReceiptsFolder.length) return NO;
    NSString *path = [[AxsCacheKeeperReceiptsFolder stringByAppendingPathComponent:bundle] stringByAppendingString:@".auto.plist"];
    NSDictionary *previous = [NSDictionary dictionaryWithContentsOfFile:path];
    if (!previous && [[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSLog(@"[CacheKeeper] 回执文件损坏，拒绝覆盖：%@", path);
        return NO;
    }
    NSArray *known = discoveredPaths ?: (previous[@"discoveredPaths"] ?: @[]);
    if ([previous[@"phase"] isEqual:phase] && [previous[@"message"] isEqual:message] &&
        [previous[@"failed"] unsignedIntegerValue] == failed && [previous[@"effectivePaths"] isEqual:(effectivePaths ?: @[])] &&
        [previous[@"discoveredPaths"] isEqual:known] && !directories && -[previous[@"updated"] timeIntervalSinceNow] < 30) return YES;
    NSDictionary *report = @{@"updated":NSDate.date, @"phase":phase ?: @"", @"message":message ?: @"",
        @"removed":previous[@"removed"] ?: @0, @"bytes":previous[@"bytes"] ?: @0, @"failed":@(failed),
        @"lastRemoved":previous[@"lastRemoved"] ?: @0, @"lastBytes":previous[@"lastBytes"] ?: @0,
        @"endReason":previous[@"endReason"] ?: @0,
        @"confirmedRoundID":previous[@"confirmedRoundID"] ?: @"", @"confirmedRemoved":previous[@"confirmedRemoved"] ?: @0, @"confirmedBytes":previous[@"confirmedBytes"] ?: @0,
        @"coverageComplete":previous[@"coverageComplete"] ?: @NO,
        @"effectivePaths":effectivePaths ?: @[], @"discoveredPaths":known, @"directories":directories ?: previous[@"directories"] ?: @{}};
    if (![report writeToFile:path atomically:YES]) { NSLog(@"[CacheKeeper] 无法保存 %@ 清理状态", bundle); return NO; }
    return YES;
}

@end
