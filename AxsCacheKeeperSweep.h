#pragma once
#import <Foundation/Foundation.h>

@interface AxsCacheKeeperSweep : NSObject
@property(nonatomic, readonly, copy) NSString *root;
@property(nonatomic, readonly, copy) NSString *bundle;
@property(nonatomic, readonly, copy) NSString *version;
@property(nonatomic, readonly, copy) NSString *containerPath;
@property(nonatomic, readonly, copy) NSString *relativePath; // root 相对容器
@property(nonatomic, readonly) BOOL complete;
@property(nonatomic, readonly) BOOL cancelled;
@property(nonatomic, readonly) NSUInteger removed;
@property(nonatomic, readonly) NSUInteger failed;
@property(nonatomic, readonly) NSUInteger protectedCount;
@property(nonatomic, readonly) NSUInteger recentCount;
@property(nonatomic, readonly) NSUInteger unresolvedCount;
@property(nonatomic, readonly) unsigned long long unresolvedBytes;
@property(nonatomic, readonly, copy) NSString *unresolvedEvidence; // 首条未确认内容（相对容器）
@property(nonatomic, readonly) BOOL dependencyInvalidated;
@property(nonatomic, readonly, copy) NSString *invalidEvidence; // 依赖失效的首条触发路径（相对容器）
@property(nonatomic, readonly) BOOL checking;
@property(nonatomic, readonly) NSUInteger inspected;
@property(nonatomic, readonly) NSUInteger changedCount;
@property(nonatomic, readonly) unsigned long long bytes;
@property(nonatomic, readonly) BOOL hasDeleteCandidates; // 预检完成且有可删候选（供作业判断是否启动 120 秒计时）
// 剩余可删候选数（任务 5/6 最低残留展示）：预检已确认可删但本轮尚未删除的项数。
// 触顶轮次大于 0（下轮继续），完成轮次为 0；预检完成前为 0。
@property(nonatomic, readonly) NSUInteger remainingCandidates;
@property(nonatomic, readonly) unsigned long long remainingBytes;
@property(nonatomic, readonly) unsigned long long recentBytes;
@property(nonatomic, readonly) unsigned long long changedBytes;
@property(nonatomic, readonly) NSUInteger deferredCount;
@property(nonatomic, readonly) unsigned long long deferredBytes;
@property(nonatomic, readonly, copy) NSString *error;
@property(nonatomic, readonly, copy) NSArray<NSDictionary *> *failureDetails;
// 新构造器（修订方案任务 1）：决策上下文由调用方提供；旧 fullClear/logMode/purgeMode
// 构造器已删除——删除依据只由 CleanupRules 决定，不再由构造参数选择分支。
- (instancetype)initWithRoot:(NSString *)root bundle:(NSString *)bundle version:(NSString *)version containerPath:(NSString *)containerPath state:(NSDictionary *)state;
- (instancetype)initWithRoot:(NSString *)root bundle:(NSString *)bundle version:(NSString *)version containerPath:(NSString *)containerPath state:(NSDictionary *)state clock:(NSTimeInterval (^)(void))clock;
- (instancetype)initWithRoot:(NSString *)root bundle:(NSString *)bundle version:(NSString *)version containerPath:(NSString *)containerPath state:(NSDictionary *)state clock:(NSTimeInterval (^)(void))clock unlinkFile:(int (^)(int, const char *))unlinkFile;
// 预检推进（方案任务 3，P1-3）：只做检查＋统一决策，永不删除。预检完成时 checking 变 NO。
- (void)advancePreflight:(NSUInteger)limit;
// 删除推进（方案任务 3，P1-3）：仅在预检完成后调用；预检未完成时直接返回。
- (void)advanceDeletion:(NSUInteger)limit shouldContinue:(BOOL (^)(void))shouldContinue;
// 取消本根：门控关闭时由作业调用；已完成的根不受影响。
- (void)cancel;
// 单根兼容入口：先预检后删除（测试用；多根作业须用拆分后的接口，以保证全部根预检完成才删除）。
- (void)advance:(NSUInteger)limit shouldContinue:(BOOL (^)(void))shouldContinue;
@end
