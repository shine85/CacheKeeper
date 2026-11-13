#pragma once
#import <Foundation/Foundation.h>
#import "AxsCacheKeeperProcess.h"

// 进程观测统一记录（审查 P1-2，方案任务 2）：定时观测、目标构建、sweep 门控
// 三处采样共用同一个观测更新入口，防止各自维护 since/identity 再次分叉。
// 同一实例 Suspended 延续起点；首次挂起或实例变化建立新起点；任何非挂起观测
// （Executing/Unknown/Absent/Terminated）或身份缺失立即清除旧挂起窗口——
// 已看到恢复执行，必须使旧证据失效，不能借旧窗口放行。
// 另维护“最近一次执行实例”：所有采样入口的 Executing 都同步记录，供门控的
// 实例绑定比对（新实例运行过则旧 job 过期）；它记历史，不随挂起/消失观测清除，
// 只在启用集合差集清理与全部失效时清除。
// 计时状态只在内存中，SpringBoard 重启后重新观测，不落盘。
// 时间由调用方注入单调秒，不读墙钟（墙钟跳变不影响计时）。
// 仅主线程调用：记录不加锁，主线程串行维护；入口有断言约束后续调用方。
@interface AxsCacheKeeperProcessObservation : NSObject
+ (void)observeBundle:(NSString *)bundle state:(AxsCacheKeeperExecState)state identity:(NSString *)identity atMonotonicTime:(NSTimeInterval)now;
+ (BOOL)allowsSuspendedCleanupForBundle:(NSString *)bundle identity:(NSString *)identity atMonotonicTime:(NSTimeInterval)now;
+ (void)invalidateAllBundles;
// 周期起点：以当前启用集合做差集清理——配置键直接移除的 bundle（遍历不到
// enabled=false）其挂起起点与执行实例记录一并作废；配置不可读时全部作废。
+ (void)beginCycleWithEnabledBundles:(NSSet<NSString *> *)enabledBundles configurationReadable:(BOOL)readable;
// 最近一次观测到的执行实例（无记录时为 nil）；替代 Scanner 独立维护的 seen_instances。
+ (NSString *)lastExecutingIdentityForBundle:(NSString *)bundle;
// 执行活动和用户重检共用修订号；同实例再次活动也使旧静默/未知登记失效。
+ (NSUInteger)revisionForBundle:(NSString *)bundle;
+ (void)requestRecheckForBundle:(NSString *)bundle;
@end
