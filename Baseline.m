#import "AxsCacheKeeperSweep.h"
#import "AxsCacheKeeperPolicy.h"
#import "AxsCacheKeeperFileAccess.h"
#import "AxsCacheKeeperCleanupRules.h"
#import "AxsCacheKeeperDependencySnapshot.h"
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>

@interface AxsCacheKeeperSweep ()
@property(nonatomic, readwrite) BOOL complete;
@property(nonatomic, readwrite) BOOL cancelled;
@property(nonatomic, readwrite) NSUInteger removed;
@property(nonatomic, readwrite) NSUInteger failed;
@property(nonatomic, readwrite) NSUInteger protectedCount;
@property(nonatomic, readwrite) NSUInteger recentCount;
@property(nonatomic, readwrite) NSUInteger unresolvedCount;
@property(nonatomic, readwrite) unsigned long long unresolvedBytes;
@property(nonatomic, readwrite, copy) NSString *unresolvedEvidence;
@property(nonatomic, readwrite) BOOL dependencyInvalidated;
@property(nonatomic, readwrite, copy) NSString *invalidEvidence;
@property(nonatomic, readwrite) unsigned long long bytes;
@property(nonatomic, readwrite, copy) NSString *error;
@property(nonatomic, readwrite, copy) NSString *root;
@property(nonatomic, readwrite, copy) NSString *bundle;
@property(nonatomic, readwrite, copy) NSString *version;
@property(nonatomic, readwrite, copy) NSString *containerPath;
@property(nonatomic, readwrite, copy) NSString *relativePath;
@property(nonatomic, copy) NSDictionary *state;
@property(nonatomic, copy) NSArray<NSString *> *rootAliases;
@property(nonatomic) dev_t device;
@property(nonatomic) ino_t inode;
@property(nonatomic, strong) NSDirectoryEnumerator *entries;
@property(nonatomic, copy) NSTimeInterval (^clock)(void);
@property(nonatomic, readwrite) BOOL checking;
@property(nonatomic, readwrite) NSUInteger inspected;
@property(nonatomic, readwrite) NSUInteger changedCount;
@property(nonatomic,copy) NSString *verifyDetail;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSArray *> *directorySnapshots;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSMutableDictionary *> *fileSnapshots;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSMutableDictionary *> *fileFacts;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSMutableDictionary *> *fileDecisions;
@property(nonatomic,strong) NSMutableSet<NSString *> *retentionRanges;
@property(nonatomic,strong) NSMutableArray<NSString *> *deleteCandidates;
@property(nonatomic) NSUInteger deleteCursor;
@property(nonatomic,strong) NSMutableArray<NSString *> *decisionEntries;
@property(nonatomic) NSUInteger decisionCursor;
@property(nonatomic) BOOL enumerationComplete;
@property(nonatomic,readwrite) BOOL measurementComplete;
@property(nonatomic,strong) NSMutableSet<NSString *> *failedCandidates;
@property(nonatomic,strong) NSMutableDictionary<NSString *,AxsCacheKeeperDependencySnapshot *> *dependencySnapshots;
@property(nonatomic,strong) NSMutableArray<NSString *> *dependencyOrder;
@property(nonatomic) NSUInteger dependencyCaptureCursor;
@property(nonatomic) NSUInteger dependencyVerifyCursor;
@property(nonatomic) BOOL verifyingDependencies;
@property(nonatomic,strong) NSMutableSet<NSString *> *invalidDependencies;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *recordedFailures;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *retainedSubtrees;
@property(nonatomic) NSUInteger retainedSubtreeCount;
@property(nonatomic,copy) int (^unlinkFile)(int, const char *);
// 延期类字节累计（任务 5）：近期与变化文件的逻辑占用估计；已消失/非普通文件计 0。
@property(nonatomic) unsigned long long recentBytes;
@property(nonatomic) unsigned long long changedBytes;
@property(nonatomic,copy) NSArray<NSString *> *rootForms;
@end

@implementation AxsCacheKeeperSweep
- (instancetype)initWithRoot:(NSString *)root bundle:(NSString *)bundle version:(NSString *)version containerPath:(NSString *)containerPath state:(NSDictionary *)state {
    return [self initWithRoot:root bundle:bundle version:version containerPath:containerPath state:state clock:^NSTimeInterval { return NSDate.date.timeIntervalSince1970; }];
}
- (instancetype)initWithRoot:(NSString *)root bundle:(NSString *)bundle version:(NSString *)version containerPath:(NSString *)containerPath state:(NSDictionary *)state clock:(NSTimeInterval (^)(void))clock {
    return [self initWithRoot:root bundle:bundle version:version containerPath:containerPath state:state clock:clock unlinkFile:^int(int fd,const char *name) { return unlinkat(fd,name,0); }];
}
- (instancetype)initWithRoot:(NSString *)root bundle:(NSString *)bundle version:(NSString *)version containerPath:(NSString *)containerPath state:(NSDictionary *)state clock:(NSTimeInterval (^)(void))clock unlinkFile:(int (^)(int,const char *))unlinkFile {
    if (!(self = [super init])) return nil;
    _root = [root copy];
    _bundle = [bundle copy] ?: @"";
    _version = [version copy];
    _containerPath = [containerPath copy] ?: @"";
    _state = [state isKindOfClass:NSDictionary.class] ? [state copy] : @{};
    _clock = [clock copy];
    _unlinkFile=[unlinkFile copy];_recordedFailures=[NSMutableArray new];_retainedSubtrees=[NSMutableArray new];
    // 根可能在调度器检查后消失；失败对象同样需要稳定的回执目录键。
    NSString *containerPrefix = [_containerPath stringByAppendingString:@"/"];
    _relativePath = (_containerPath.length && [root hasPrefix:containerPrefix]) ?
        [root substringFromIndex:containerPrefix.length] : @"";
    if (state && (![state isKindOfClass:NSDictionary.class] || !axs_cachekeeper_state_valid(state))) {
        _failed=1;_complete=YES;_error=@"配置字段无效，未开始清理";
        return self;
    }
    struct stat info;
    if (![root isEqual:[NSURL fileURLWithPath:root].URLByResolvingSymlinksInPath.path] ||
        lstat(root.fileSystemRepresentation, &info) || !S_ISDIR(info.st_mode)) {
        _failed = 1; _complete = YES; _error = @"缓存目录不可访问或包含符号链接";
        return self;
    }
    _device = info.st_dev; _inode = info.st_ino;
    _rootAliases=axs_cachekeeper_directory_aliases(root);
    // 删除入口的父路径校验要容忍路径形态差异（解析符号链接前后、标准化前后）：
    // 真机上容器根是解析后的 /private/var/... 形态，枚举条目路径形态可能不同，
    // 字符串直比会把根内文件整批误判为根外（errno 22 全灭，2026-11-11 抖音真机 263 项）。
    NSMutableSet<NSString *> *forms = [NSMutableSet setWithObject:root];
    [forms addObject:root.stringByStandardizingPath];
    NSString *resolvedRoot = [NSURL fileURLWithPath:root].URLByResolvingSymlinksInPath.path;
    if (resolvedRoot) { [forms addObject:resolvedRoot]; [forms addObject:resolvedRoot.stringByStandardizingPath]; }
    _rootForms = forms.allObjects;
    // 根相对容器的路径：决策入口的相对路径基准。根本身若为已确认保留范围
    //（如整个根是 Preferences），预先记入保留范围（枚举器不输出根自身）。
    _retentionRanges = [NSMutableSet new];
    // 调度器采集的本轮不可访问路径，独立于持久用户排除；仅用于恢复失败子树。
    for (id path in _state[@"unavailablePaths"]) if ([path isKindOfClass:NSString.class] && axs_cachekeeper_relative_path(path)) [_retentionRanges addObject:path];
    // 已验证 APP 可清范围与根有交集时不记入——名称启发式不挡已验证规则。
    if (_relativePath.length && axs_cachekeeper_retention_path(_relativePath) &&
        ![AxsCacheKeeperCleanupRules hasCleanableRangeForBundle:_bundle version:_version relativePath:_relativePath])
        [_retentionRanges addObject:_relativePath];
    _checking = YES;
    _fileFacts = [NSMutableDictionary new];
    _fileDecisions = [NSMutableDictionary new];
    _deleteCandidates = [NSMutableArray new];
    _decisionEntries = [NSMutableArray new];
    _failedCandidates = [NSMutableSet new];
    _dependencySnapshots = [NSMutableDictionary new];
    _dependencyOrder = [NSMutableArray new];
    _invalidDependencies = [NSMutableSet new];
    _directorySnapshots = [NSMutableDictionary new];
    _fileSnapshots = [NSMutableDictionary new];
    _directorySnapshots[[self axs_cachekeeper_directory_key:root]]=[self axs_cachekeeper_snapshot:info];
    [self axs_cachekeeper_open_enumerator];
    return self;
}
- (BOOL)hasDeleteCandidates { return !self.checking && self.deleteCursor < self.deleteCandidates.count; }
- (NSUInteger)remainingCandidates { return self.deleteCandidates.count - self.deleteCursor + self.failedCandidates.count; }
- (unsigned long long)remainingBytes {
    unsigned long long total=0;
    for (NSUInteger i=self.deleteCursor;i<self.deleteCandidates.count;i++)
        total+=[self axs_cachekeeper_snapshot_bytes:self.deleteCandidates[i]];
    for (NSString *entry in self.failedCandidates) total += [self axs_cachekeeper_snapshot_bytes:entry];
    return total;
}
// 延期类（任务 5）：近期与变化合并为一类——同一文件同一轮只计一类，互斥。
- (NSUInteger)deferredCount { return self.recentCount + self.changedCount; }
- (unsigned long long)deferredBytes { return self.recentBytes + self.changedBytes; }
- (BOOL)coverageComplete { return self.measurementComplete && !self.failed && !self.changedCount; }
- (NSDictionary *)directoryReport {
    NSMutableDictionary *report = [@{@"updated":NSDate.date, @"complete":@(self.complete),
        @"checking":@(self.checking), @"cancelled":@(self.cancelled), @"measurementComplete":@(self.measurementComplete),
        @"coverageComplete":@(self.coverageComplete), @"removed":@(self.removed), @"bytes":@(self.bytes),
        @"failed":@(self.failed), @"error":self.error ?: @"", @"failureDetails":self.failureDetails ?: @[],
        @"retainedSubtreeCount":@(self.retainedSubtreeCount), @"retainedSubtrees":[self.retainedSubtrees copy],
        @"purgeClassification":self.dependencyInvalidated ? @"invalid" : self.unresolvedCount ? @"paused" : @"",
        @"purgeEvidence":self.dependencyInvalidated ? (self.invalidEvidence ?: @"") : (self.unresolvedEvidence ?: @"")} mutableCopy];
    NSString *ruleSummary=[AxsCacheKeeperCleanupRules productionRuleSummaryForBundle:self.bundle version:self.version relativePath:self.relativePath];
    if (ruleSummary) {
        report[@"appRuleID"]=@"douyin-alog";
        report[@"appRuleSummary"]=ruleSummary;
        report[@"appRuleWaitingForExit"]=@(![self.state[@"processExited"] boolValue]);
    }
    if (self.measurementComplete) [report addEntriesFromDictionary:@{@"protected":@(self.protectedCount),
        @"recent":@(self.recentCount), @"changed":@(self.changedCount), @"remaining":@(self.remainingCandidates),
        @"remainingBytes":@(self.remainingBytes), @"deferred":@(self.deferredCount), @"deferredBytes":@(self.deferredBytes),
        @"unresolved":@(self.unresolvedCount), @"unresolvedBytes":@(self.unresolvedBytes)}];
    return [report copy];
}
// 预检快照里的文件大小（索引 6）；无快照（预检后新增）返回 0，不伪造。
- (unsigned long long)axs_cachekeeper_snapshot_bytes:(NSString *)entry {
    NSArray *snapshot=self.fileSnapshots[entry.stringByDeletingLastPathComponent][entry.lastPathComponent];
    return snapshot.count>6 ? [snapshot[6] unsignedLongLongValue] : 0;
}
- (NSArray *)axs_cachekeeper_snapshot:(struct stat)info {
    return @[@(info.st_ino),@(info.st_dev),@(info.st_mtimespec.tv_sec),@(info.st_mtimespec.tv_nsec),
        @(info.st_ctimespec.tv_sec),@(info.st_ctimespec.tv_nsec),@(info.st_size)];
}
// 目录快照的记录键统一标准化：枚举器给出的目录路径形态（尾随斜杠等）与删除时构造/剥离的形态
// 在真机上可能不一致，键不统一会让复核全灭（31.1 真机 alog 身份核对失败、删除 0）。
- (NSString *)axs_cachekeeper_directory_key:(NSString *)path {
    return path.stringByStandardizingPath;
}
// 条目绝对路径转相对容器路径（决策入口的输入）。条目已由枚举规范化为根形态，
// 必有根前缀；防御性回退只取文件名（不应发生，相对路径错误时规则不匹配即为未确认）。
- (NSString *)axs_cachekeeper_relative_path:(NSString *)entry {
    NSString *prefix = [self.root stringByAppendingString:@"/"];
    if ([entry hasPrefix:prefix]) {
        NSString *under = [entry substringFromIndex:prefix.length];
        return self.relativePath.length ? [self.relativePath stringByAppendingPathComponent:under] : under;
    }
    return entry.lastPathComponent;
}
- (void)axs_cachekeeper_open_enumerator {
    __weak typeof(self) weak = self;
    _entries = [NSFileManager.defaultManager enumeratorAtURL:[NSURL fileURLWithPath:self.root isDirectory:YES]
        includingPropertiesForKeys:nil options:0 errorHandler:^BOOL(NSURL *url, NSError *error) {
            typeof(self) strong = weak;
            strong.failed++;
            strong.error = [NSString stringWithFormat:@"无法遍历 %@：%@", url.lastPathComponent, error.localizedDescription];
            return YES;
        }];
    if (!_entries) { _failed = 1; _complete = YES; _error = @"无法打开缓存目录"; }
}
// 返回 path 命中的根形态（已标准化），不命中返回 nil；相对路径按命中形态的长度切分。
- (NSString *)axs_cachekeeper_matched_root_form:(NSString *)path {
    NSString *standard = path.stringByStandardizingPath;
    for (NSString *form in self.rootForms) {
        NSString *base = form.stringByStandardizingPath;
        if ([standard isEqual:base] || [standard hasPrefix:[base stringByAppendingString:@"/"]]) return base;
    }
    return nil;
}
// 预检证据采集：文件头 16 字节。证据判断不受年龄/nlink/删除资格过滤——
// 近期文件、硬链接中的证据同样生效（删除资格由决定与删除阶段另行处理）。
// 身份不符（枚举后被替换）或短读/读失败都记为读取不完整，本轮不删除。
- (NSDictionary *)axs_cachekeeper_collect_facts:(NSString *)entry info:(struct stat)info {
    NSString *relative = [self axs_cachekeeper_relative_path:entry];
    BOOL nameEvidence = axs_cachekeeper_data_marker(entry.lastPathComponent) ||
        axs_cachekeeper_purge_evidence_path(relative);
    NSString *parent = entry.stringByDeletingLastPathComponent;
    int directory = axs_cachekeeper_open_directory(parent);
    int file = directory >= 0 ? openat(directory, entry.lastPathComponent.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) : -1;
    struct stat opened;
    unsigned char signature[16] = {0};
    ssize_t count = -1;
    BOOL identityOK = NO;
    if (file >= 0 && !fstat(file, &opened) && S_ISREG(opened.st_mode) &&
        opened.st_ino == info.st_ino && opened.st_dev == info.st_dev) {
        identityOK = YES;
        count = pread(file, signature, sizeof(signature), 0);
    }
    if (file >= 0) close(file);
    if (directory >= 0) close(directory);
    BOOL shortRead = count >= 0 && count < MIN((ssize_t)sizeof(signature), (ssize_t)opened.st_size);
    BOOL readComplete = identityOK && count >= 0 && !shortRead;
    BOOL headerEvidence = readComplete && ((count >= 15 && !memcmp(signature, "SQLite format 3", 15)) ||
        (count >= 6 && !memcmp(signature, "bplist", 6)));
    BOOL mediaSignature = readComplete && axs_cachekeeper_media_signature(signature, (size_t)count);
    return @{@"hasEvidence": @(nameEvidence || headerEvidence),
        @"matureAt":@(MAX(info.st_birthtimespec.tv_sec + info.st_birthtimespec.tv_nsec/1e9,
            MAX(info.st_mtimespec.tv_sec + info.st_mtimespec.tv_nsec/1e9,info.st_ctimespec.tv_sec + info.st_ctimespec.tv_nsec/1e9)) + AxsCacheKeeperMinimumFileAge),
        @"hasMediaSignature": @(mediaSignature),
        @"readComplete": @(readComplete)};
}
// 预检采集：只记录快照与证据事实，不决定删除。保留子树整片裁剪（不枚举其下内容），
// 其余独立范围继续；一个保留标记不让整片父目录永久不处理。
- (void)axs_cachekeeper_record_retained_subtree:(NSString *)relative reason:(NSString *)reason {
    self.retainedSubtreeCount++;
    // 不遍历保留子树，也不把目录当成一个已统计文件；只记录有限的原因样本。
    static const NSUInteger AxsCacheKeeperRetainedSubtreeSampleLimit=8;
    if (self.retainedSubtrees.count<AxsCacheKeeperRetainedSubtreeSampleLimit)
        [self.retainedSubtrees addObject:@{@"path":relative,@"reason":reason}];
}
- (void)axs_cachekeeper_collect:(NSString *)entry info:(struct stat)info {
    if (S_ISDIR(info.st_mode)) {
        self.directorySnapshots[[self axs_cachekeeper_directory_key:entry]]=[self axs_cachekeeper_snapshot:info];
        NSString *relative = [self axs_cachekeeper_relative_path:entry];
        for (NSString *unavailable in self.state[@"unavailablePaths"]) if (axs_cachekeeper_path_inside(relative,unavailable)) {
            [self axs_cachekeeper_record_retained_subtree:relative reason:@"旧权限恢复失败，未遍历"];
            [self.entries skipDescendants]; return;
        }
        // 已验证 APP 可清范围有交集时不裁剪——名称启发式不挡已验证规则。
        if (axs_cachekeeper_retention_path(relative) &&
            ![AxsCacheKeeperCleanupRules hasCleanableRangeForBundle:self.bundle version:self.version relativePath:relative]) {
            [self.retentionRanges addObject:relative];
            [self axs_cachekeeper_record_retained_subtree:relative reason:@"命中保留规则，未遍历内部文件"];
            [self.entries skipDescendants];
        }
        return;
    }
    if (!S_ISREG(info.st_mode)) return;
    NSString *parent=entry.stringByDeletingLastPathComponent;
    if (!self.fileSnapshots[parent]) self.fileSnapshots[parent]=[NSMutableDictionary new];
    self.fileSnapshots[parent][entry.lastPathComponent]=[self axs_cachekeeper_snapshot:info];
    if (!self.fileFacts[parent]) self.fileFacts[parent]=[NSMutableDictionary new];
    self.fileFacts[parent][entry.lastPathComponent]=[self axs_cachekeeper_collect_facts:entry info:info];
    [self.decisionEntries addObject:entry];
    self.inspected++;
}
// 统一决策（预检枚举结束时调用）：对每个已采集文件调用规则入口，产生不可变决定；
// 可删文件进入删除候选列表；保留/未确认文件计数；规则依赖快照同步采集。
// 依赖缺失时决定不成立，相关文件本轮延期（计变化），下轮重新预检时重建决定。
- (void)axs_cachekeeper_decide_entry:(NSString *)entry {
            NSString *parent = entry.stringByDeletingLastPathComponent;
            NSString *name = entry.lastPathComponent;
            NSString *relative = [self axs_cachekeeper_relative_path:entry];
            NSDictionary *facts = self.fileFacts[parent][name] ?: @{};
            NSDictionary *evidence = @{@"hasEvidence": facts[@"hasEvidence"] ?: @NO,
                @"hasMediaSignature": facts[@"hasMediaSignature"] ?: @NO,
                @"readComplete": facts[@"readComplete"] ?: @NO,
                @"retentionRanges": self.retentionRanges.allObjects ?: @[]};
            AxsCacheKeeperCleanupDecision *decision = [AxsCacheKeeperCleanupRules decisionForBundle:self.bundle version:self.version relativePath:relative state:self.state evidence:evidence];
            if (!self.fileDecisions[parent]) self.fileDecisions[parent] = [NSMutableDictionary new];
            self.fileDecisions[parent][name] = decision;
            if (decision.disposition == AxsCacheKeeperCleanupDelete) {
                for (NSString *dep in decision.dependencyPaths) {
                    if (!axs_cachekeeper_relative_path(dep)) {
                        [self.invalidDependencies addObject:dep];
                        self.dependencyInvalidated=YES;self.invalidEvidence=dep;
                        self.error=@"规则依赖路径无效，相关范围本轮延期";continue;
                    }
                    if (!self.dependencySnapshots[dep]) {
                        NSString *depPath = [self.containerPath stringByAppendingPathComponent:dep];
                        self.dependencySnapshots[dep]=[[AxsCacheKeeperDependencySnapshot alloc] initWithPath:depPath];
                        [self.dependencyOrder addObject:dep];
                    }
                }
                if (self.clock() < [facts[@"matureAt"] doubleValue]) {
                    self.recentCount++; self.recentBytes += [self axs_cachekeeper_snapshot_bytes:entry];
                } else [self.deleteCandidates addObject:entry];
            } else if (decision.disposition == AxsCacheKeeperCleanupKeep) {
                self.protectedCount++;
            } else if (decision.disposition == AxsCacheKeeperCleanupDefer) {
                self.failed++; self.changedCount++; self.changedBytes += [self axs_cachekeeper_snapshot_bytes:entry];
                [self axs_cachekeeper_failure:@"read-preflight" code:EIO path:entry detail:decision.reason];
            } else {
                self.unresolvedCount++;
                NSArray *snapshot = self.fileSnapshots[parent][name];
                self.unresolvedBytes += [snapshot[6] unsignedLongLongValue];
                if (!self.unresolvedEvidence) self.unresolvedEvidence = relative;
            }
    // 保持预检枚举顺序；不在收尾做全树排序或再次遍历。
}
// 规则依赖复核：删除前重读每个依赖的快照；变化/缺失使相关范围失效，
// 本轮延期，下轮重建决定；已失效的依赖不再重复核对。无依赖的决定直接通过。
- (BOOL)axs_cachekeeper_dependencies_valid:(AxsCacheKeeperCleanupDecision *)decision {
    for (NSString *dep in decision.dependencyPaths) {
        if ([self.invalidDependencies containsObject:dep]) return NO;
        AxsCacheKeeperDependencySnapshot *record=self.dependencySnapshots[dep];
        if (![record validateRoot]) {
            [self.invalidDependencies addObject:dep];
            if (!self.dependencyInvalidated) {
                self.dependencyInvalidated = YES;
                self.invalidEvidence = dep;
                self.error = record.error ?: @"规则依赖无法确认，相关范围本轮延期";
            }
            return NO;
        }
    }
    return YES;
}
// 删除前的目录复核：只核对目录身份（inode/设备）。目录时间戳会因兄弟文件增删而变，
// 若沿用目录级稳定性门，热写目录会整轮空转（2026-11-11 抖音 alog 真机：14 个目录判
// 变化、删除 0）；文件自身稳定性改由删除时逐文件比对预检记录保证，数据保护不受影响。
// 失败原因写入 verifyDetail（记录缺失/目录已被替换/变化），回执据此定位，不再只有一个笼统结论。
- (BOOL)axs_cachekeeper_verify_directory:(NSString *)path fd:(int)fd {
    struct stat info;
    self.verifyDetail = nil;
    if (fstat(fd, &info)) { self.verifyDetail = @"读取目录状态失败"; return NO; }
    NSArray *record = self.directorySnapshots[[self axs_cachekeeper_directory_key:path]];
    if (!record) { self.verifyDetail = @"预检记录缺失"; return NO; }
    BOOL identity = [@(info.st_ino) isEqual:record[0]] && [@(info.st_dev) isEqual:record[1]];
    if (!identity) self.verifyDetail = @"目录已被替换";
    return identity;
}
- (BOOL)axs_cachekeeper_remove:(NSString *)entry expected:(struct stat)expected willDelete:(BOOL (^)(void))willDelete {
    NSString *parent = entry.stringByDeletingLastPathComponent;
    NSString *matchedForm = [self axs_cachekeeper_matched_root_form:parent];
    if (!matchedForm) {
        [self axs_cachekeeper_failure:@"枚举路径边界" code:EINVAL path:entry detail:[NSString stringWithFormat:@"root=%@; parent=%@",self.root,parent]];return NO;
    }
    // 从已核对身份的缓存根逐级打开，不能靠 realpath 后再打开绝对路径防竞态。
    int fd = axs_cachekeeper_open_directory(self.root);
    if (fd < 0) {
        int openError = errno;
        NSString *bad = @"?";
        NSString *walk = @"";
        for (NSString *part in [self.root componentsSeparatedByString:@"/"]) {
            if (!part.length) continue;
            walk = [walk stringByAppendingPathComponent:part];
            struct stat componentInfo;
            if (lstat(walk.fileSystemRepresentation, &componentInfo) || !S_ISDIR(componentInfo.st_mode)) { bad = part; break; }
        }
        [self axs_cachekeeper_failure:@"open-root" code:openError path:entry detail:[NSString stringWithFormat:@"%@；卡在组件 %@",self.root,bad]];return NO;
    }
    struct stat openedRoot;
    if (fstat(fd,&openedRoot)) {
        int code=errno;close(fd);[self axs_cachekeeper_failure:@"fstat-root" code:code path:entry detail:self.root];return NO;
    }
    if (openedRoot.st_dev != self.device || openedRoot.st_ino != self.inode) {
        close(fd);[self axs_cachekeeper_failure:@"根目录身份核对" code:ESTALE path:entry detail:@""];return NO;
    }
    NSString *relativeParent = [parent.stringByStandardizingPath substringFromIndex:matchedForm.length];
    // 祖先链的记录键取枚举器形态：由 parent 逐级剥组件得到（root 用其自身为键）。
    // 不用 root 拼接的构造形态查记录：构造形态与枚举器给出的目录路径形态在真机上可能不一致，
    // 曾致 30.1/31.1 真机 alog 深层文件全灭（判变化/身份核对失败）。
    NSMutableArray<NSString *> *ancestorKeys = [NSMutableArray new];
    {
        NSMutableArray<NSString *> *stripped = [NSMutableArray new];
        NSString *cursor = parent;
        NSUInteger depth = 0;
        for (NSString *part in [relativeParent componentsSeparatedByString:@"/"]) if (part.length) depth++;
        for (NSUInteger i = 0; i < depth; i++) { [stripped addObject:cursor]; cursor = cursor.stringByDeletingLastPathComponent; }
        for (NSUInteger i = depth; i-- > 1;) [ancestorKeys addObject:stripped[i]];
        // ancestorKeys[0] 对应一级子目录，ancestorKeys[depth-2] 对应 parent 的上一级；parent 本身由下方父目录复核处理。
    }
    NSString *openedPath=self.root;
    NSUInteger partIndex = 0;
    for (NSString *part in [relativeParent componentsSeparatedByString:@"/"]) {
        if (!part.length) continue;
        NSString *verifyKey = partIndex == 0 ? self.root : ancestorKeys[partIndex - 1];
        if (![self axs_cachekeeper_verify_directory:verifyKey fd:fd]) {
            self.changedCount++; self.changedBytes += [self axs_cachekeeper_snapshot_bytes:entry];
            close(fd); errno = EBUSY; self.error = [NSString stringWithFormat:@"预检后目录身份发生变化（%@），已跳过该文件", self.verifyDetail ?: @"原因未明"]; return NO;
        }
        int child = openat(fd, part.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        int savedError = errno;
        close(fd);
        if (child < 0) { [self axs_cachekeeper_failure:@"openat-parent" code:savedError path:entry detail:openedPath];return NO; }
        fd = child;
        openedPath=[openedPath stringByAppendingPathComponent:part];
        partIndex++;
    }
    struct stat current;
    struct stat parentInfo;
    if (![self axs_cachekeeper_verify_directory:parent fd:fd]) {
        self.changedCount++; self.changedBytes += [self axs_cachekeeper_snapshot_bytes:entry];
        close(fd); errno = EBUSY; self.error = [NSString stringWithFormat:@"预检后目录身份发生变化（%@），已跳过该文件", self.verifyDetail ?: @"原因未明"]; return NO;
    }
    NSString *fileName=entry.lastPathComponent;
    const char *name = fileName.fileSystemRepresentation;
    // 文件级稳定性门（通用）：只比对目标文件自身的预检记录；未预检（预检后新增）或已变化的跳过本文件，
    // 不连坐同目录其他文件。计入变化数而非失败数（errno EBUSY 不计失败）。
    NSArray *record = self.fileSnapshots[parent][entry.lastPathComponent];
    struct stat currentRecord;
    if (!record || fstatat(fd, name, &currentRecord, AT_SYMLINK_NOFOLLOW) ||
        ![[self axs_cachekeeper_snapshot:currentRecord] isEqual:record]) {
        self.changedCount++; self.changedBytes += [self axs_cachekeeper_snapshot_bytes:entry];
        self.error = @"预检后文件发生变化，已跳过该文件";
        close(fd); errno = EBUSY; return NO;
    }
    BOOL removed = NO;
    int file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    if (file<0) { int code=errno;close(fd);[self axs_cachekeeper_failure:@"openat-file" code:code path:entry detail:@""];return NO; }
    if (fstat(file,&current)) { int code=errno;close(file);close(fd);[self axs_cachekeeper_failure:@"fstat-file" code:code path:entry detail:@""];return NO; }
    if (S_ISREG(current.st_mode) && current.st_nlink == 1 &&
        current.st_ino == expected.st_ino && current.st_dev == expected.st_dev &&
        axs_cachekeeper_old_enough(current, self.clock())) {
        // 删除依据已由预检阶段的统一规则决定（本文件在删除候选列表内即为 Delete 决定）；
        // 此处只复核身份与年龄，不再按内容重判——内容证据已在预检采集，变化由快照门捕获。
        struct stat final;
        if (fstatat(fd,name,&final,AT_SYMLINK_NOFOLLOW)) {
            int code=errno;[self axs_cachekeeper_failure:@"fstatat-final" code:code path:entry detail:@""];
        } else if (final.st_ino == current.st_ino && final.st_dev == current.st_dev && axs_cachekeeper_old_enough(final, self.clock())) {
            if (!willDelete()) { self.cancelled=YES; close(file); close(fd); errno=ECANCELED; return NO; }
            int result=self.unlinkFile(fd,name);int code=result ? errno : 0;
            removed=result==0;
            if (!removed) [self axs_cachekeeper_failure:@"unlinkat" code:code path:entry detail:@"flags=0"];
        } else [self axs_cachekeeper_failure:@"删除前身份/时间核对" code:ESTALE path:entry detail:@""];
    } else [self axs_cachekeeper_failure:@"打开文件身份/时间核对" code:ESTALE path:entry detail:@""];
    int savedError = errno;
    if (removed && !fstat(fd,&parentInfo)) self.directorySnapshots[[self axs_cachekeeper_directory_key:parent]]=[self axs_cachekeeper_snapshot:parentInfo];
    if (removed) {
        [self.fileSnapshots[parent] removeObjectForKey:entry.lastPathComponent];
        [self updateDependenciesAfterRemovingPath:entry];
        if (self.removalObserver) self.removalObserver(entry);
    }
    if (file >= 0) close(file);
    close(fd); errno = savedError;
    return removed;
}
- (NSArray<NSDictionary *> *)failureDetails { return [self.recordedFailures copy]; }
- (void)updateDependenciesAfterRemovingPath:(NSString *)path {
    for (AxsCacheKeeperDependencySnapshot *snapshot in self.dependencySnapshots.allValues) [snapshot didRemovePath:path];
}
- (void)axs_cachekeeper_failure:(NSString *)stage code:(int)code path:(NSString *)path detail:(NSString *)detail {
    self.error=[NSString stringWithFormat:@"%@ 失败（errno %d：%s）",stage,code,strerror(code)];
    if (self.recordedFailures.count<8) [self.recordedFailures addObject:@{@"stage":stage,@"code":@(code),@"path":path ?: @"",@"detail":detail ?: @""}];
    errno=code;
}
- (void)cancel {
    if (self.complete) return;
    self.cancelled = YES; self.entries = nil;
}

// 拆分 advance（方案任务 3，P1-3）：预检与删除分开推进。多根作业须先让全部根完成
// 预检（含统一决策）再删除；旧的单接口会在首根完成预检时即开始删除，导致 120 秒
// 期限从首根离开预检起算、与其它根的预检重叠（审计 P1-3）。
- (void)advancePreflight:(NSUInteger)limit {
    if (self.complete || self.cancelled || !self.checking) return;
    NSString *resolvedRootPath = [NSURL fileURLWithPath:self.root].URLByResolvingSymlinksInPath.path;
    for (NSUInteger index = 0; index < limit; index++) {
        struct stat rootInfo;
        if (lstat(self.root.fileSystemRepresentation, &rootInfo) || !S_ISDIR(rootInfo.st_mode) ||
            rootInfo.st_ino != self.inode || rootInfo.st_dev != self.device ||
            ![self.root isEqual:resolvedRootPath]) {
            self.failed++; self.error = @"扫描期间缓存目录已改变"; self.complete = YES; self.entries = nil; return;
        }
        if (self.enumerationComplete) {
            if (self.decisionCursor < self.decisionEntries.count) {
                [self axs_cachekeeper_decide_entry:self.decisionEntries[self.decisionCursor++]];
                continue;
            }
            if (self.dependencyCaptureCursor<self.dependencyOrder.count) {
                AxsCacheKeeperDependencySnapshot *snapshot=self.dependencySnapshots[self.dependencyOrder[self.dependencyCaptureCursor]];
                [snapshot advance:1];
                if (snapshot.complete) self.dependencyCaptureCursor++;
                continue;
            }
            if (self.decisionCursor == self.decisionEntries.count) {
                self.checking=NO; self.measurementComplete=YES; self.decisionEntries=nil; return;
            }
            continue;
        }
        NSURL *enumerated = self.entries.nextObject;
        if (!enumerated) {
            // 预检枚举结束：统一决策，产生不可变决定与删除候选列表；删除阶段只遍历候选，
            // 预检后新增的文件不混入旧候选。
            self.enumerationComplete=YES; self.entries=nil;
            if (!self.decisionEntries.count) { self.checking=NO; self.measurementComplete=YES; }
            continue;
        }
        NSString *entry=axs_cachekeeper_enumerated_path(enumerated.path,self.root,self.rootAliases);
        if (!entry) {
            self.failed++;
            [self axs_cachekeeper_failure:@"枚举路径边界" code:EINVAL path:enumerated.path detail:self.root];
            continue;
        }
        struct stat info;
        if (lstat(entry.fileSystemRepresentation, &info)) {
            if (errno != ENOENT) { self.failed++; self.error = @"无法读取缓存文件属性"; }
            continue;
        }
        if (S_ISLNK(info.st_mode)) continue;
        [self axs_cachekeeper_collect:entry info:info];
    }
}

- (void)advanceDeletion:(NSUInteger)limit shouldContinue:(BOOL (^)(void))shouldContinue {
    [self advanceDeletion:limit shouldContinue:shouldContinue willDelete:shouldContinue];
}
- (void)advanceDeletion:(NSUInteger)limit shouldContinue:(BOOL (^)(void))shouldContinue willDelete:(BOOL (^)(void))willDelete {
    if (!limit || self.complete || self.cancelled || self.checking) return;
    if (!shouldContinue()) { self.cancelled=YES;return; }
    if (self.deleteCursor>=self.deleteCandidates.count) { self.complete=YES;return; }
    // 每个删除批次前分批复核完整依赖集合。核验消耗本批额度，尚未 unlink 时不启动期限。
    NSUInteger used=0;
    {
        if (!self.verifyingDependencies) {
            self.verifyingDependencies=YES;self.dependencyVerifyCursor=0;
            for (AxsCacheKeeperDependencySnapshot *snapshot in self.dependencySnapshots.allValues) [snapshot beginVerification];
        }
        while (self.dependencyVerifyCursor<self.dependencyOrder.count && used<limit) {
            if (!shouldContinue()) { self.cancelled=YES;return; }
            AxsCacheKeeperDependencySnapshot *snapshot=self.dependencySnapshots[self.dependencyOrder[self.dependencyVerifyCursor]];
            used += [snapshot advance:1];
            if (snapshot.complete) self.dependencyVerifyCursor++;
        }
        if (self.dependencyVerifyCursor<self.dependencyOrder.count) return;
        self.verifyingDependencies=NO;
    }
    // 核验完成后同次推进处理至少一个候选，不能把完整核验结果留到下一调度周期。
    // 集合核验和成功删除分别受 limit 约束；仍只在真实 unlink 前启动/复核期限。
    NSUInteger deletionLimit=MAX((NSUInteger)1,limit-used);
    NSString *resolvedRootPath = [NSURL fileURLWithPath:self.root].URLByResolvingSymlinksInPath.path;
    for (NSUInteger index = 0; index < deletionLimit; index++) {
        if (!shouldContinue()) { self.cancelled = YES; return; }
        if (self.deleteCursor >= self.deleteCandidates.count) { self.complete=YES; return; }
        struct stat rootInfo;
        if (lstat(self.root.fileSystemRepresentation, &rootInfo) || !S_ISDIR(rootInfo.st_mode) ||
            rootInfo.st_ino != self.inode || rootInfo.st_dev != self.device ||
            ![self.root isEqual:resolvedRootPath]) {
            self.failed++; self.error = @"扫描期间缓存目录已改变"; self.complete = YES; return;
        }
        NSString *entry = self.deleteCandidates[self.deleteCursor++];
        NSString *parent = entry.stringByDeletingLastPathComponent;
        NSString *name = entry.lastPathComponent;
        AxsCacheKeeperCleanupDecision *decision = self.fileDecisions[parent][name];
        // 规则依赖复核：依赖变化使相关范围失效，本轮延期，下轮重建决定；独立范围继续。
        if (!decision || ![self axs_cachekeeper_dependencies_valid:decision]) { self.changedCount++; self.changedBytes += [self axs_cachekeeper_snapshot_bytes:entry]; continue; }
        struct stat info;
        if (lstat(entry.fileSystemRepresentation, &info)) {
            // 预检后被删：计变化，不计失败；其他读取错误计失败。
            if (errno != ENOENT) { self.failed++; [self.failedCandidates addObject:entry]; self.error = @"无法读取缓存文件属性"; }
            else self.changedCount++;
            continue;
        }
        if (S_ISLNK(info.st_mode) || !S_ISREG(info.st_mode)) { self.changedCount++; continue; }
        if (info.st_nlink != 1) { self.changedCount++; self.changedBytes += info.st_size; self.error=@"共享硬链接暂不清理，避免影响根外数据"; continue; }
        if (!axs_cachekeeper_old_enough(info, self.clock())) { self.recentCount++; self.recentBytes += info.st_size; continue; }
        if ([self axs_cachekeeper_remove:entry expected:info willDelete:willDelete]) { self.removed++; self.bytes += info.st_size; }
        else if (self.cancelled) { self.deleteCursor--; return; }
        else if (errno != ENOENT && errno != EBUSY) { self.failed++; [self.failedCandidates addObject:entry]; }
    }
}

// 单根兼容入口（测试用）：单调用只推进一个阶段，恢复旧 advance: 的语义——
// 预检未完成时只做预检，预检完成后才删除。#79 初版在同一调用内连续调预检+删除，
// 抹掉了阶段边界：预检收尾调用已删 1 项，导致“根替换发生在完整预检后且删除前”
// 测试失败（期望预检完成、删除尚未开始时 removed==0）。多根作业须用拆分后的接口。
- (void)advance:(NSUInteger)limit shouldContinue:(BOOL (^)(void))shouldContinue {
    if (self.complete || self.cancelled) return;
    if (self.checking) { [self advancePreflight:limit]; return; }
    [self advanceDeletion:limit shouldContinue:shouldContinue];
}
@end
