#pragma once
#import <Foundation/Foundation.h>

@interface AxsCacheKeeperSweep : NSObject
@property(nonatomic, readonly, copy) NSString *root;
@property(nonatomic, readonly) BOOL fullClear;
@property(nonatomic, readonly) BOOL logMode;
@property(nonatomic, readonly) BOOL purgeMode;
@property(nonatomic, readonly) BOOL purgeBlocked;
@property(nonatomic, readonly) BOOL purgeMixed;
@property(nonatomic, readonly) BOOL purgeInvalid;
@property(nonatomic, readonly) BOOL purgePaused;
@property(nonatomic, readonly) BOOL verifying;
@property(nonatomic, readonly, copy) NSString *purgeEvidence;
@property(nonatomic, readonly) BOOL complete;
@property(nonatomic, readonly) BOOL cancelled;
@property(nonatomic, readonly) NSUInteger removed;
@property(nonatomic, readonly) NSUInteger failed;
@property(nonatomic, readonly) NSUInteger protectedCount;
@property(nonatomic, readonly) NSUInteger recentCount;
@property(nonatomic, readonly) BOOL checking;
@property(nonatomic, readonly) NSUInteger inspected;
@property(nonatomic, readonly) NSUInteger changedCount;
@property(nonatomic, readonly) unsigned long long bytes;
@property(nonatomic, readonly, copy) NSString *error;
@property(nonatomic, readonly, copy) NSArray<NSDictionary *> *failureDetails;
- (instancetype)initWithRoot:(NSString *)root;
- (instancetype)initWithRoot:(NSString *)root clock:(NSTimeInterval (^)(void))clock;
- (instancetype)initWithRoot:(NSString *)root clock:(NSTimeInterval (^)(void))clock unlinkFile:(int (^)(int, const char *))unlinkFile;
- (instancetype)initWithRoot:(NSString *)root fullClear:(BOOL)fullClear;
- (instancetype)initWithRoot:(NSString *)root clock:(NSTimeInterval (^)(void))clock fullClear:(BOOL)fullClear;
- (instancetype)initWithRoot:(NSString *)root fullClear:(BOOL)fullClear logMode:(BOOL)logMode;
- (instancetype)initWithRoot:(NSString *)root clock:(NSTimeInterval (^)(void))clock fullClear:(BOOL)fullClear logMode:(BOOL)logMode;
- (instancetype)initWithRoot:(NSString *)root fullClear:(BOOL)fullClear logMode:(BOOL)logMode purgeMode:(BOOL)purgeMode;
- (instancetype)initWithRoot:(NSString *)root clock:(NSTimeInterval (^)(void))clock fullClear:(BOOL)fullClear logMode:(BOOL)logMode purgeMode:(BOOL)purgeMode;
// 预检推进（方案任务 3，P1-3）：只做检查＋任务 1 验证，永不删除。预检完成时 checking 变 NO。
- (void)advancePreflight:(NSUInteger)limit;
// 删除推进（方案任务 3，P1-3）：仅在预检完成后调用；预检未完成时直接返回。
- (void)advanceDeletion:(NSUInteger)limit shouldContinue:(BOOL (^)(void))shouldContinue;
// 取消本根：门控关闭时由作业调用；已完成的根不受影响。
- (void)cancel;
// 单根兼容入口：先预检后删除（测试用；多根作业须用拆分后的接口，以保证全部根预检完成才删除）。
- (void)advance:(NSUInteger)limit shouldContinue:(BOOL (^)(void))shouldContinue;
@end
