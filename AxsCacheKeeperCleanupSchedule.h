#pragma once
#import <Foundation/Foundation.h>
#include <sys/stat.h>
@class AxsCacheKeeperSweep, AxsCacheKeeperCleanupJob;

typedef NS_ENUM(NSInteger, AxsCacheKeeperRangeState) {
    AxsCacheKeeperRangeScan, AxsCacheKeeperRangeUnchanged,
    AxsCacheKeeperRangeMissing, AxsCacheKeeperRangeFailed
};

// Scanner 与原生回归共用的调度契约；设备进程采样仍留在 Scanner 主线程入口。
@interface AxsCacheKeeperCleanupSchedule : NSObject
+ (NSDictionary *)registrationForSweep:(AxsCacheKeeperSweep *)sweep signature:(NSString *)signature now:(NSTimeInterval)now;
+ (AxsCacheKeeperRangeState)checkRoot:(NSString *)root registration:(NSDictionary *)registration signature:(NSString *)signature
                                now:(NSTimeInterval)now stat:(int (^)(const char *, struct stat *))statBlock error:(NSString **)error;
+ (NSDictionary *)carriedReport:(NSDictionary *)registration;
+ (NSDictionary *)summaryForJob:(AxsCacheKeeperCleanupJob *)job directories:(NSDictionary *)directories
              externalFailures:(NSUInteger)externalFailures discoveryComplete:(BOOL)discoveryComplete;
+ (NSTimeInterval)quietIntervalForSummary:(NSDictionary *)summary;
+ (BOOL)retireJob:(AxsCacheKeeperCleanupJob *)job bundle:(NSString *)bundle message:(NSString *)message;
// 只取当前容器内的失败路径；后代路径可加入本轮排除，独立范围继续。
+ (NSArray<NSString *> *)restoreExclusions:(NSDictionary *)restored home:(NSString *)home;
@end
