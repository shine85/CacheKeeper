#import "AxsCacheKeeperCleanupRules.h"
#import "AxsCacheKeeperPolicy.h"

// 平台缓存规则修订：Library/Caches 与 tmp 按平台缓存用途约定清理；修订变化使旧 job 失效。
static NSString * const AxsCacheKeeperPlatformCacheRuleID = @"platform-cache";
static NSString * const AxsCacheKeeperPlatformCacheRuleRevision = @"2";
static NSString * const AxsCacheKeeperUserLogRuleID = @"user-log";
static NSString * const AxsCacheKeeperUserLogRuleRevision = @"1";

@implementation AxsCacheKeeperCleanupDecision

- (instancetype)initWithDisposition:(AxsCacheKeeperCleanupDisposition)disposition
                              basis:(AxsCacheKeeperCleanupBasis)basis
                             ruleID:(NSString *)ruleID
                       ruleRevision:(NSString *)ruleRevision
                   scopeRelativePath:(NSString *)scopeRelativePath
                             reason:(NSString *)reason
                    dependencyPaths:(NSArray<NSString *> *)dependencyPaths {
    if ((self = [super init])) {
        _disposition = disposition;
        _basis = basis;
        _ruleID = [ruleID copy] ?: @"";
        _ruleRevision = [ruleRevision copy] ?: @"";
        _scopeRelativePath = [scopeRelativePath copy] ?: @"";
        _reason = [reason copy] ?: @"";
        _dependencyPaths = [dependencyPaths copy] ?: @[];
    }
    return self;
}

@end

@implementation AxsCacheKeeperAppRule

- (instancetype)initWithRuleID:(NSString *)ruleID
                      revision:(NSString *)revision
                    appVersion:(NSString *)appVersion
                cleanablePaths:(NSArray<NSString *> *)cleanablePaths
                retentionPaths:(NSArray<NSString *> *)retentionPaths
               dependencyPaths:(NSArray<NSString *> *)dependencyPaths {
    if ((self = [super init])) {
        _ruleID = [ruleID copy] ?: @"";
        _ruleRevision = [revision copy] ?: @"";
        _appVersion = [appVersion copy];
        _cleanablePaths = [cleanablePaths copy] ?: @[];
        _retentionPaths = [retentionPaths copy] ?: @[];
        _dependencyPaths = [dependencyPaths copy] ?: @[];
    }
    return self;
}

@end

// relative 是否等于 scope 或位于 scope 子树内（按路径成分边界比较，不做子串匹配）。
static BOOL AxsCacheKeeperPathUnder(NSString *relative, NSString *scope) {
    if (!relative.length || !scope.length) return NO;
    return [relative isEqual:scope] || [relative hasPrefix:[scope stringByAppendingString:@"/"]];
}

static NSString *AxsCacheKeeperMatchedScope(NSString *relative, NSArray<NSString *> *scopes) {
    if (![scopes isKindOfClass:NSArray.class]) return nil;
    for (id scope in scopes) {
        if (![scope isKindOfClass:NSString.class]) continue;
        if (AxsCacheKeeperPathUnder(relative, scope)) return scope;
    }
    return nil;
}

static NSMutableDictionary<NSString *, NSMutableArray<AxsCacheKeeperAppRule *> *> *AxsCacheKeeperRuleRegistry(void) {
    static NSMutableDictionary<NSString *, NSMutableArray<AxsCacheKeeperAppRule *> *> *registry;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ registry = [NSMutableDictionary new]; });
    return registry;
}

// APP 规则只在 bundle＋版本同时匹配时生效；规则带版本而调用方未提供版本时不匹配
//（无法核验适用性，不能放行）。appVersion 为 nil 的规则匹配任意版本（仅测试用）。
static BOOL AxsCacheKeeperRuleApplies(AxsCacheKeeperAppRule *rule, NSString *version) {
    if (!rule.appVersion.length) return YES;
    return version.length && [rule.appVersion isEqual:version];
}

@implementation AxsCacheKeeperCleanupRules

+ (void)registerRule:(AxsCacheKeeperAppRule *)rule forBundle:(NSString *)bundle {
    if (!rule.ruleID.length || !bundle.length) return;
    NSMutableDictionary *registry = AxsCacheKeeperRuleRegistry();
    if (!registry[bundle]) registry[bundle] = [NSMutableArray new];
    [registry[bundle] addObject:rule];
}

+ (void)removeAllRulesForTesting {
    [AxsCacheKeeperRuleRegistry() removeAllObjects];
}

+ (NSString *)rulesVersion {
    NSMutableString *version = [NSMutableString stringWithFormat:@"%@:%@", AxsCacheKeeperPlatformCacheRuleID, AxsCacheKeeperPlatformCacheRuleRevision];
    for (NSString *bundle in [AxsCacheKeeperRuleRegistry().allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        for (AxsCacheKeeperAppRule *rule in AxsCacheKeeperRuleRegistry()[bundle])
            [version appendFormat:@";%@:%@:%@", bundle, rule.ruleID, rule.ruleRevision];
    }
    return [version copy];
}

+ (BOOL)hasCleanableRangeForBundle:(NSString *)bundle version:(NSString *)version relativePath:(NSString *)relativePath {
    if (!bundle.length || !relativePath.length) return NO;
    for (AxsCacheKeeperAppRule *rule in AxsCacheKeeperRuleRegistry()[bundle]) {
        if (!AxsCacheKeeperRuleApplies(rule, version)) continue;
        for (NSString *cleanable in rule.cleanablePaths) {
            if (AxsCacheKeeperPathUnder(relativePath, cleanable) || AxsCacheKeeperPathUnder(cleanable, relativePath)) return YES;
        }
    }
    return NO;
}

+ (AxsCacheKeeperCleanupDecision *)decisionForBundle:(NSString *)bundle
                                            version:(NSString *)version
                                       relativePath:(NSString *)relativePath
                                              state:(NSDictionary *)state
                                           evidence:(NSDictionary *)evidence {
    // 1. 用户排除：保留决定优先，父范围与模式都不能绕过。
    NSString *excluded = AxsCacheKeeperMatchedScope(relativePath, axs_cachekeeper_exclusions(state));
    if (excluded) return [[AxsCacheKeeperCleanupDecision alloc] initWithDisposition:AxsCacheKeeperCleanupKeep
        basis:AxsCacheKeeperCleanupBasisNone ruleID:@"user-exclusion" ruleRevision:@""
        scopeRelativePath:excluded reason:@"用户已排除该目录" dependencyPaths:@[]];
    // 2. 已确认保留范围：预检发现的保留子树（必要状态目录）与 APP 规则保留范围。
    // 保留子树只裁剪自身，其余已有可靠依据的范围继续，不连坐整个父根。
    NSString *retained = AxsCacheKeeperMatchedScope(relativePath, evidence[@"retentionRanges"]);
    if (retained) return [[AxsCacheKeeperCleanupDecision alloc] initWithDisposition:AxsCacheKeeperCleanupKeep
        basis:AxsCacheKeeperCleanupBasisNone ruleID:@"retention-range" ruleRevision:@""
        scopeRelativePath:retained reason:@"已确认保留范围" dependencyPaths:@[]];
    NSArray<AxsCacheKeeperAppRule *> *rules = bundle.length ? AxsCacheKeeperRuleRegistry()[bundle] : nil;
    for (AxsCacheKeeperAppRule *rule in rules) {
        if (!AxsCacheKeeperRuleApplies(rule, version)) continue;
        NSString *ruleRetained = AxsCacheKeeperMatchedScope(relativePath, rule.retentionPaths);
        if (ruleRetained) return [[AxsCacheKeeperCleanupDecision alloc] initWithDisposition:AxsCacheKeeperCleanupKeep
            basis:AxsCacheKeeperCleanupBasisAppRule ruleID:rule.ruleID ruleRevision:rule.ruleRevision
            scopeRelativePath:ruleRetained reason:@"APP 规则保留范围" dependencyPaths:rule.dependencyPaths];
    }
    // 3. 读取不完整：本轮不删除，下轮重新预检时再判（不静默跳过，也不强行删除）。
    if (evidence[@"readComplete"] && ![evidence[@"readComplete"] boolValue])
        return [[AxsCacheKeeperCleanupDecision alloc] initWithDisposition:AxsCacheKeeperCleanupDefer
            basis:AxsCacheKeeperCleanupBasisNone ruleID:@"read-incomplete" ruleRevision:@""
            scopeRelativePath:relativePath reason:@"内容读取不完整，本轮不删除" dependencyPaths:@[]];
    // 精确 APP 范围先于平台规则，保留其依赖；允许遍历父目录不等于允许删除父树全部内容。
    for (AxsCacheKeeperAppRule *rule in rules) {
        if (!AxsCacheKeeperRuleApplies(rule, version)) continue;
        NSString *cleanable = AxsCacheKeeperMatchedScope(relativePath, rule.cleanablePaths);
        if (cleanable) return [[AxsCacheKeeperCleanupDecision alloc] initWithDisposition:AxsCacheKeeperCleanupDelete
            basis:AxsCacheKeeperCleanupBasisAppRule ruleID:rule.ruleID ruleRevision:rule.ruleRevision
            scopeRelativePath:cleanable reason:@"APP 专属规则：可清资源" dependencyPaths:rule.dependencyPaths];
    }
    NSString *parent = relativePath.stringByDeletingLastPathComponent;
    if (parent.length && axs_cachekeeper_retention_path(parent))
        return [[AxsCacheKeeperCleanupDecision alloc] initWithDisposition:AxsCacheKeeperCleanupKeep
            basis:AxsCacheKeeperCleanupBasisNone ruleID:@"necessary-state" ruleRevision:@""
            scopeRelativePath:parent reason:@"必要状态目录，未命中精确可清资源范围" dependencyPaths:@[]];
    // 4. 平台缓存：Library/Caches 与 tmp 按平台缓存用途约定清理，不按文件类型保留。
    // SQLite/无后缀文件同样可清（格式不单独证明必须保留）；顶层 Cache/Caches/.cache
    // 等同名自建目录不获得平台约定。平台缓存不依赖“全根不存在数据库”，无规则依赖。
    for (NSString *platformRoot in @[@"Library/Caches", @"tmp"]) {
        if (AxsCacheKeeperPathUnder(relativePath, platformRoot))
            return [[AxsCacheKeeperCleanupDecision alloc] initWithDisposition:AxsCacheKeeperCleanupDelete
                basis:AxsCacheKeeperCleanupBasisPlatformCache ruleID:AxsCacheKeeperPlatformCacheRuleID
                ruleRevision:AxsCacheKeeperPlatformCacheRuleRevision scopeRelativePath:platformRoot
                reason:@"平台缓存用途约定" dependencyPaths:@[]];
    }
    // 6. 用户/插件日志定级：日志定级目录内的日志文件，且不命中任何保护事实
    //（数据证据、受保护路径成分、可识别媒体头）。mixed 不再自动意味着“只按 .log
    // 后缀清理全部日志”——日志也须位于已确认范围且不命中保护事实。
    NSString *logScope = AxsCacheKeeperMatchedScope(relativePath, axs_cachekeeper_log_paths(state));
    if (logScope && axs_cachekeeper_log_file_name(relativePath.lastPathComponent) &&
        ![evidence[@"hasEvidence"] boolValue] && ![evidence[@"hasMediaSignature"] boolValue] &&
        !axs_cachekeeper_protected_path(relativePath))
        return [[AxsCacheKeeperCleanupDecision alloc] initWithDisposition:AxsCacheKeeperCleanupDelete
            basis:AxsCacheKeeperCleanupBasisUserLog ruleID:AxsCacheKeeperUserLogRuleID
            ruleRevision:AxsCacheKeeperUserLogRuleRevision scopeRelativePath:logScope
            reason:@"日志定级目录内的日志文件" dependencyPaths:@[]];
    // 7. 未命中任何规则：用途未确认，不自动删除；记录残留占用并进入适配。
    return [[AxsCacheKeeperCleanupDecision alloc] initWithDisposition:AxsCacheKeeperCleanupUnresolved
        basis:AxsCacheKeeperCleanupBasisNone ruleID:@"" ruleRevision:@""
        scopeRelativePath:relativePath reason:@"用途未确认，无清理依据" dependencyPaths:@[]];
}

@end
