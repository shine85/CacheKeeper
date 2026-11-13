#pragma once
#import <Foundation/Foundation.h>

// 回执唯一写入器（方案任务 4，P2-1）：所有 .auto.plist 的读改写只经此模块，
// 经一条串行队列，观测状态不共享此锁。
// - 每轮固定 roundID，提交本轮累计删除量；同一 roundID 同一累计量重复提交不重复计入。
// - 写失败时快照滞留内存待处理队列，作业替换/取消不清除；落盘后按序补记，不丢不重。
// - 损坏/不可读的回执文件明确失败，永不以累计 0 覆盖。
// - 待处理快照只是内存保证：SpringBoard 在落盘前崩溃仍可能丢失内存数据（已声明）。
// - 调用方按轮次顺序提交；新轮开始后不得重交更早轮。Scanner 串行队列与 pending 暂停共同保证该前提。
// - 本模块不依赖 jbroot/roothide：Status 目录由调用方配置，测试可指向临时目录。
@interface AxsCacheKeeperReceipts : NSObject

// 配置 Status 目录（<CacheKeeper>/Status）。Scanner 启动时调一次；测试指向临时目录。
// 未配置时提交与状态更新均失败（ fail closed）。
+ (void)configureWithStatusFolder:(NSString *)folder;

// 提交一轮的累计删除量（幂等）。removed/bytes 为本轮累计（非增量），roundID 固定于本轮。
// round 非空表示轮次退役（其 removed/bytes 记为上次清理）；其余周期传 nil。
// 返回 YES 表示已落盘（或无需落盘：重复提交/内容无变化）；NO 表示写失败，
// 快照已滞留待处理队列，调用方须暂停该 APP 的进一步删除与新作业。
+ (BOOL)submitRoundForBundle:(NSString *)bundle
                     roundID:(NSString *)roundID
                     removed:(NSUInteger)removed
                       bytes:(unsigned long long)bytes
                   endReason:(NSInteger)endReason
                       phase:(NSString *)phase
                     message:(NSString *)message
                      failed:(NSUInteger)failed
              effectivePaths:(NSArray *)effectivePaths
             discoveredPaths:(NSArray *)discoveredPaths
                 directories:(NSDictionary *)directories
                       round:(NSDictionary *)round
            coverageComplete:(BOOL)coverageComplete;

// 仅更新展示状态（等待/错误等非轮次报告），不改动累计量与已确认轮次。
// 与提交共用同一串行写入器；损坏回执同样明确失败、不覆盖。
+ (BOOL)updateStatusForBundle:(NSString *)bundle
                        phase:(NSString *)phase
                      message:(NSString *)message
                       failed:(NSUInteger)failed
               effectivePaths:(NSArray *)effectivePaths
              discoveredPaths:(NSArray *)discoveredPaths
                  directories:(NSDictionary *)directories;

// 该 APP 是否有未落盘的待处理快照。有则 Scanner 暂停该 APP 的删除与新作业。
+ (BOOL)hasPendingForBundle:(NSString *)bundle;

// 重试该 APP 待处理快照的落盘（按提交顺序）。返回 YES 表示已全部落盘或无待处理。
+ (BOOL)flushPendingForBundle:(NSString *)bundle;
// 每个调度周期独立重试全部待保存回执，与 APP 是否启用/运行无关。
+ (void)flushAllPending;

// 测试用：清空配置与全部待处理队列。
+ (void)resetForTesting;

@end
