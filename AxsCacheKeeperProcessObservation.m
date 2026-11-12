#import "AxsCacheKeeperProcessObservation.h"

// 持续挂起满 60 秒才放行清理（A 案既定规则）。
static const NSTimeInterval AxsCacheKeeperSuspendedStableInterval = 60;

static NSMutableDictionary<NSString *, NSDictionary *> *AxsCacheKeeperSuspendedRecords(void) {
    static NSMutableDictionary<NSString *, NSDictionary *> *records;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ records = [NSMutableDictionary new]; });
    return records;
}

@implementation AxsCacheKeeperProcessObservation

+ (void)observeBundle:(NSString *)bundle state:(AxsCacheKeeperExecState)state identity:(NSString *)identity atMonotonicTime:(NSTimeInterval)now {
    // 仅主线程调用：三个采样点（定时观测、目标构建、门控采样）均在主线程——门控经
    // dispatch_sync 回主队列执行，清理队列只等待结果；快捷方式手动入口同样是主线程回调。
    // 记录不加锁，主线程串行维护（方案原文正确；初版“门控在清理队列”说法有误——漏看
    // 了 sampleGate 内的 dispatch_sync，用户 2026-11-12 22:20 源码核对纠正）。
    NSAssert([NSThread isMainThread], @"AxsCacheKeeperProcessObservation 仅限主线程调用");
    if (!bundle.length) return;
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

@end
