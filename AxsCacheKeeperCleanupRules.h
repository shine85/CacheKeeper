#pragma once
#import <Foundation/Foundation.h>

// 清理决定的统一入口（修订方案任务 1，P1-1 重写）：哪些内容可清，只由这里决定。
// 决策优先级：用户排除/已确认保留 → 平台缓存或已验证 APP/用户日志规则 → 未确认。
// 未命中任何规则的未知内容不自动删除；零证据只是诊断结果，不是删除依据。
// 文件“可删依据”和“现在能否删除”分开：本模块只判用途（Delete/Keep/Unresolved）；
// 进程、年龄、身份、预算由 Sweep/Job 处理，不在本模块重复判断。
// 规则注册只维护在这里；APP 专属规则的复杂资源索引读取在其规则实现中拆小文件，
// 不预建通用插件框架或远端规则服务。

typedef NS_ENUM(NSInteger, AxsCacheKeeperCleanupDisposition) {
    AxsCacheKeeperCleanupDelete,     // 已确认可删
    AxsCacheKeeperCleanupKeep,       // 保留（排除/已确认数据/运行必需）
    AxsCacheKeeperCleanupUnresolved, // 用途未确认，不自动删除
    AxsCacheKeeperCleanupDefer       // 读取失败，本轮延期并报告失败
};

typedef NS_ENUM(NSInteger, AxsCacheKeeperCleanupBasis) {
    AxsCacheKeeperCleanupBasisNone,
    AxsCacheKeeperCleanupBasisPlatformCache, // 平台缓存用途约定
    AxsCacheKeeperCleanupBasisAppRule,       // APP 专属规则
    AxsCacheKeeperCleanupBasisUserLog         // 用户/插件日志定级
};

// 不可变决定：预检时产生，删除前只复核依赖，不重算。
@interface AxsCacheKeeperCleanupDecision : NSObject
@property(nonatomic, readonly) AxsCacheKeeperCleanupDisposition disposition;
@property(nonatomic, readonly) AxsCacheKeeperCleanupBasis basis;
@property(nonatomic, readonly, copy) NSString *ruleID;
@property(nonatomic, readonly, copy) NSString *ruleRevision;
@property(nonatomic, readonly, copy) NSString *scopeRelativePath; // 决策覆盖的范围（相对容器）
@property(nonatomic, readonly, copy) NSString *reason;
@property(nonatomic, readonly, copy) NSArray<NSString *> *dependencyPaths; // 相对容器；删除前须复核
- (instancetype)initWithDisposition:(AxsCacheKeeperCleanupDisposition)disposition
                              basis:(AxsCacheKeeperCleanupBasis)basis
                             ruleID:(NSString *)ruleID
                       ruleRevision:(NSString *)ruleRevision
                   scopeRelativePath:(NSString *)scopeRelativePath
                             reason:(NSString *)reason
                    dependencyPaths:(NSArray<NSString *> *)dependencyPaths;
@end

// APP 专属规则：带版本与目录特征；可清资源、保留范围、恢复依赖分开声明。
// 混合数据库不直接删整库；规则须验证删除后可恢复＋草稿完整（任务 10）。
@interface AxsCacheKeeperAppRule : NSObject
@property(nonatomic, readonly, copy) NSString *ruleID;
@property(nonatomic, readonly, copy) NSString *ruleRevision;
@property(nonatomic, readonly, copy) NSString *appVersion; // 适用版本；nil 表示任意版本（仅测试用）
@property(nonatomic, readonly, copy) NSArray<NSString *> *cleanablePaths;  // 相对容器，可清范围
@property(nonatomic, readonly, copy) NSArray<NSString *> *retentionPaths;  // 相对容器，保留范围
@property(nonatomic, readonly, copy) NSArray<NSString *> *dependencyPaths; // 相对容器，规则依赖（资源索引等）
- (instancetype)initWithRuleID:(NSString *)ruleID
                      revision:(NSString *)revision
                    appVersion:(NSString *)appVersion
                cleanablePaths:(NSArray<NSString *> *)cleanablePaths
                retentionPaths:(NSArray<NSString *> *)retentionPaths
               dependencyPaths:(NSArray<NSString *> *)dependencyPaths;
@end

@interface AxsCacheKeeperCleanupRules : NSObject
// 单一决策入口。relativePath 相对 APP 容器（系统重新解析后的容器）；state 为 APP
// 状态字典（excludedPaths/logPaths）；evidence 为预检事实快照：
//   @"hasEvidence"      @(BOOL) 文件有数据证据（数据标记名/受保护路径成分/数据库头）
//   @"hasMediaSignature"@(BOOL) 文件头为可识别媒体签名
//   @"readComplete"     @(BOOL) 内容读取完整（短读/读失败为 NO）
//   @"retentionRanges"  NSArray<NSString *> 预检发现的已确认保留范围（相对容器）
// 字段由生产采集方产生，UI 标签不能伪造可恢复证据。
+ (AxsCacheKeeperCleanupDecision *)decisionForBundle:(NSString *)bundle
                                            version:(NSString *)version
                                       relativePath:(NSString *)relativePath
                                              state:(NSDictionary *)state
                                           evidence:(NSDictionary *)evidence;
// 规则版本（参与 job 签名）：平台规则修订＋已注册 APP 规则的 ID/修订；规则变化使旧 job 失效。
+ (NSString *)rulesVersion;
// 枚举裁剪用：相对路径是否与任一适用 APP 规则的可清范围有交集
//（在可清范围内，或可清范围在其内）。已验证规则优先于名称启发式保留——
// 否则 Downloads 等保留名目录下的已验证资源范围会被整片裁掉、规则永不生效。
+ (BOOL)hasCleanableRangeForBundle:(NSString *)bundle version:(NSString *)version relativePath:(NSString *)relativePath;
// 注册 APP 专属规则（生产规则由内置表注册；测试用本接口注入测试规则）。
+ (void)registerRule:(AxsCacheKeeperAppRule *)rule forBundle:(NSString *)bundle;
// 测试专用：清除全部已注册 APP 规则。内置表在任务 1 为空；任务 10 填充后须改为重建内置表。
+ (void)removeAllRulesForTesting;
@end
