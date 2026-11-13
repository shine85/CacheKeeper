#import "AxsCacheKeeperProcessObservation.h"

// 持续挂起满 60 秒才放行清理（A 案既定规则）。
static const NSTimeInterval AxsCacheKeeperSuspendedStableInterval = 60;

static NSMutableDictionary<NSString *, NSDictionary *> *AxsCacheKeeperSuspendedRecords(void) {
    static NSMutableDictionary<NSString *, NSDictionary *> *records;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ records = [NSMutableDictionary new]; });
    return records;
}

// 最近一次执行实例（bundle → identity 字符串）；记历史，不随挂起/消失观测清除。
static NSMutableDictionary<NSString *, NSString *> *AxsCacheKeeperExecutingIdentities(void) {
    static NSMutableDictionary<NSString *, NSString *> *identities;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ identities = [NSMutableDictionary new]; });
    return identities;
}

static NSMutableDictionary<NSString *, NSNumber *> *AxsCacheKeeperRevisions(void) {
    static NSMutableDictionary *revisions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ revisions=[NSMutableDictionary new]; });
    return revisions;
}

@implementation AxsCacheKeeperProcessObservation

+ (void)requestRecheckForBundle:(NSString *)bundle {
    NSAssert([NSThread isMainThread], @"AxsCacheKeeperProcessObservation 仅限主线程调用");
    static NSUInteger revision;
    if (bundle.length) AxsCacheKeeperRevisions()[bundle]=@(++revision);
}
+ (NSUInteger)revisionForBundle:(NSString *)bundle {
    NSAssert([NSThread isMainThread], @"AxsCacheKeeperProcessObservation 仅限主线程调用");
    return bundle.length ? [AxsCacheKeeperRevisions()[bundle] unsignedIntegerValue] : 0;
}

+ (void)observeBundle:(NSString *)bundle state:(AxsCacheKeeperExecState)state identity:(NSString *)identity atMonotonicTime:(NSTimeInterval)now {
    // 仅主线程调用：三个采样点（定时观测、目标构建、门控采样）均在主线程——门控经
    // dispatch_sync 回主队列执行，清理队列只等待结果；快捷方式手动入口同样是主线程回调。
    // 记录不加锁，主线程串行维护（方案原文正确；初版“门控在清理队列”说法有误——漏看
    // 了 sampleGate 内的 dispatch_sync，用户 2026-11-12 22:20 源码核对纠正）。
    NSAssert([NSThread isMainThread], @"AxsCacheKeeperProcessObservation 仅限主线程调用");
    if (!bundle.length) return;
    // 所有采样入口的 Executing 都同步记录最新执行实例，供门控实例绑定比对。
    if (state==AxsCacheKeeperExecExecuting) {
        [self requestRecheckForBundle:bundle];
        if (identity.length) AxsCacheKeeperExecutingIdentities()[bundle]=identity;
    }
    if (state==AxsCacheKeeperExecSuspended && identity.length) {
        NSDictionary *record=AxsCacheKeeperSuspendedRecords()[bundle];
        if (![record[@"identity"] isEqual:identity])
            AxsCacheKeeperSuspendedRecords()[bundle]=@{@"identity":identity,@"since":@(now)};
    } else [AxsCacheKeeperSuspendedRecords() removeObjectForKey:bundle];
}

+ (BOOL)allowsSuspendedCleanupForBundle:(NSString *)bundle identity:(NSString *)identity atMonotonicTime:(NSTimeInterval)now {
    NSAssert([NSThread isMainThread], @"AxsCacheKeeperProcessObservation 仅限主线程调用");
    if (!bundle.length || !identity.length) return NO;
    NSDictionary *record=AxsCacheKeeperSuspendedRecords()[bundle];
    return [record[@"identity"] isEqual:identity] && now - [record[@"since"] doubleValue] >= AxsCacheKeeperSuspendedStableInterval;
}

+ (void)invalidateAllBundles {
    // 配置不可读/缺失时无法枚举应观测的 bundle，全部挂起起点与执行实例记录作废，不继承未持续维护的窗口。
    NSAssert([NSThread isMainThread], @"AxsCacheKeeperProcessObservation 仅限主线程调用");
    [AxsCacheKeeperSuspendedRecords() removeAllObjects];
    [AxsCacheKeeperExecutingIdentities() removeAllObjects];
    [AxsCacheKeeperRevisions() removeAllObjects];
}

+ (void)beginCycleWithEnabledBundles:(NSSet<NSString *> *)enabledBundles configurationReadable:(BOOL)readable {
    NSAssert([NSThread isMainThread], @"AxsCacheKeeperProcessObservation 仅限主线程调用");
    if (!readable) { [self invalidateAllBundles]; return; }
    // 差集清理：不在当前启用集合的 bundle，其挂起起点与执行实例记录一并作废。
    // 覆盖配置键直接移除（遍历不到 enabled=false），不只覆盖显式停用。
    for (NSString *bundle in [AxsCacheKeeperSuspendedRecords().allKeys copy])
        if (![enabledBundles containsObject:bundle]) [AxsCacheKeeperSuspendedRecords() removeObjectForKey:bundle];
    for (NSString *bundle in [AxsCacheKeeperExecutingIdentities().allKeys copy])
        if (![enabledBundles containsObject:bundle]) [AxsCacheKeeperExecutingIdentities() removeObjectForKey:bundle];
    for (NSString *bundle in [AxsCacheKeeperRevisions().allKeys copy])
        if (![enabledBundles containsObject:bundle]) [AxsCacheKeeperRevisions() removeObjectForKey:bundle];
}

+ (NSString *)lastExecutingIdentityForBundle:(NSString *)bundle {
    NSAssert([NSThread isMainThread], @"AxsCacheKeeperProcessObservation 仅限主线程调用");
    if (!bundle.length) return nil;
    return AxsCacheKeeperExecutingIdentities()[bundle];
}

@end
