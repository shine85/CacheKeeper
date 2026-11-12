#import "AxsCacheKeeperSweep.h"
#import "AxsCacheKeeperPolicy.h"
#import "AxsCacheKeeperFileAccess.h"
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
@property(nonatomic, readwrite) unsigned long long bytes;
@property(nonatomic, readwrite, copy) NSString *error;
@property(nonatomic, readwrite, copy) NSString *root;
@property(nonatomic, readwrite) BOOL fullClear;
@property(nonatomic, readwrite) BOOL logMode;
@property(nonatomic, readwrite) BOOL purgeMode;
@property(nonatomic) BOOL purgeBlocked;
@property(nonatomic, copy) NSString *purgeEvidence;
@property(nonatomic) dev_t device;
@property(nonatomic) ino_t inode;
@property(nonatomic, strong) NSDirectoryEnumerator *entries;
@property(nonatomic, copy) NSTimeInterval (^clock)(void);
@property(nonatomic, readwrite) BOOL checking;
@property(nonatomic, readwrite) NSUInteger inspected;
@property(nonatomic, readwrite) NSUInteger changedCount;
@property(nonatomic,strong) NSMutableSet<NSString *> *dataDirectories;
@property(nonatomic,strong) NSMutableSet<NSString *> *dataFiles;
@property(nonatomic,copy) NSString *verifyDetail;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSArray *> *directorySnapshots;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSMutableDictionary *> *fileSnapshots;
@property(nonatomic,strong) NSMutableSet<NSString *> *checkedDirectories;
@property(nonatomic,copy) NSArray<NSString *> *rootForms;
@end

@implementation AxsCacheKeeperSweep
- (instancetype)initWithRoot:(NSString *)root {
    return [self initWithRoot:root clock:^NSTimeInterval { return NSDate.date.timeIntervalSince1970; } fullClear:NO logMode:NO];
}
- (instancetype)initWithRoot:(NSString *)root clock:(NSTimeInterval (^)(void))clock {
    return [self initWithRoot:root clock:clock fullClear:NO logMode:NO];
}
- (instancetype)initWithRoot:(NSString *)root fullClear:(BOOL)fullClear {
    return [self initWithRoot:root clock:^NSTimeInterval { return NSDate.date.timeIntervalSince1970; } fullClear:fullClear logMode:NO];
}
- (instancetype)initWithRoot:(NSString *)root clock:(NSTimeInterval (^)(void))clock fullClear:(BOOL)fullClear {
    return [self initWithRoot:root clock:clock fullClear:fullClear logMode:NO];
}
- (instancetype)initWithRoot:(NSString *)root fullClear:(BOOL)fullClear logMode:(BOOL)logMode {
    return [self initWithRoot:root clock:^NSTimeInterval { return NSDate.date.timeIntervalSince1970; } fullClear:fullClear logMode:logMode purgeMode:NO];
}
- (instancetype)initWithRoot:(NSString *)root clock:(NSTimeInterval (^)(void))clock fullClear:(BOOL)fullClear logMode:(BOOL)logMode {
    return [self initWithRoot:root clock:clock fullClear:fullClear logMode:logMode purgeMode:NO];
}
- (instancetype)initWithRoot:(NSString *)root fullClear:(BOOL)fullClear logMode:(BOOL)logMode purgeMode:(BOOL)purgeMode {
    return [self initWithRoot:root clock:^NSTimeInterval { return NSDate.date.timeIntervalSince1970; } fullClear:fullClear logMode:logMode purgeMode:purgeMode];
}
- (instancetype)initWithRoot:(NSString *)root clock:(NSTimeInterval (^)(void))clock fullClear:(BOOL)fullClear logMode:(BOOL)logMode purgeMode:(BOOL)purgeMode {
    if (!(self = [super init])) return nil;
    _root = [root copy];
    _fullClear = fullClear;
    _logMode = logMode;
    _purgeMode = purgeMode;
    _clock = [clock copy];
    struct stat info;
    if (![root isEqual:[NSURL fileURLWithPath:root].URLByResolvingSymlinksInPath.path] ||
        lstat(root.fileSystemRepresentation, &info) || !S_ISDIR(info.st_mode)) {
        _failed = 1; _complete = YES; _error = @"缓存目录不可访问或包含符号链接";
        return self;
    }
    _device = info.st_dev; _inode = info.st_ino;
    // 删除入口的父路径校验要容忍路径形态差异（解析符号链接前后、标准化前后）：
    // 真机上容器根是解析后的 /private/var/... 形态，枚举条目路径形态可能不同，
    // 字符串直比会把根内文件整批误判为根外（errno 22 全灭，2026-11-11 抖音真机 263 项）。
    NSMutableSet<NSString *> *forms = [NSMutableSet setWithObject:root];
    [forms addObject:root.stringByStandardizingPath];
    NSString *resolvedRoot = [NSURL fileURLWithPath:root].URLByResolvingSymlinksInPath.path;
    if (resolvedRoot) { [forms addObject:resolvedRoot]; [forms addObject:resolvedRoot.stringByStandardizingPath]; }
    _rootForms = forms.allObjects;
    _checking = YES;
    _dataDirectories = [NSMutableSet new];
    _dataFiles = [NSMutableSet new];
    _directorySnapshots = [NSMutableDictionary new];
    _fileSnapshots = [NSMutableDictionary new];
    _directorySnapshots[[self axs_cachekeeper_directory_key:root]]=[self axs_cachekeeper_snapshot:info];
    [self axs_cachekeeper_open_enumerator];
    return self;
}
- (NSArray *)axs_cachekeeper_snapshot:(struct stat)info {
    return @[@(info.st_ino),@(info.st_dev),@(info.st_mtimespec.tv_sec),@(info.st_mtimespec.tv_nsec),
        @(info.st_ctimespec.tv_sec),@(info.st_ctimespec.tv_nsec)];
}
// 目录快照的记录键统一标准化：枚举器给出的目录路径形态（尾随斜杠等）与删除时构造/剥离的形态
// 在真机上可能不一致，键不统一会让复核全灭（31.1 真机 alog 身份核对失败、删除 0）。
- (NSString *)axs_cachekeeper_directory_key:(NSString *)path {
    return path.stringByStandardizingPath;
}
- (void)axs_cachekeeper_open_enumerator {
    __weak typeof(self) weak = self;
    _entries = [NSFileManager.defaultManager enumeratorAtURL:[NSURL fileURLWithPath:self.root isDirectory:YES]
        includingPropertiesForKeys:nil options:0 errorHandler:^BOOL(NSURL *url, NSError *error) {
            typeof(self) strong = weak;
            strong.failed++;
            [strong.dataDirectories addObject:strong.root];
            strong.error = [NSString stringWithFormat:@"无法遍历 %@：%@", url.lastPathComponent, error.localizedDescription];
            return YES;
        }];
    if (!_entries) { _failed = 1; _complete = YES; _error = @"无法打开缓存目录"; }
}
- (BOOL)axs_cachekeeper_is_data_directory:(NSString *)path {
    for (NSString *directory in self.dataDirectories)
        if ([path isEqual:directory] || [path hasPrefix:[directory stringByAppendingString:@"/"]]) return YES;
    return NO;
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
// B 案：全目录内容审查命中数据证据时整根出局（只记首条证据，回执据此定位；不计失败，
// 这是正确拒绝而非故障）。预检未完成（读不到内容）同样视为证据：审不完的目录不删。
- (void)axs_cachekeeper_purge_hit:(NSString *)path {
    if (self.purgeBlocked) return;
    self.purgeBlocked = YES;
    self.purgeEvidence = path;
    NSString *relative = [path hasPrefix:[self.root stringByAppendingString:@"/"]] ?
        [path substringFromIndex:self.root.length + 1] : path.lastPathComponent;
    self.error = [NSString stringWithFormat:@"检出数据证据，本目录不清理：%@", relative];
}
- (void)axs_cachekeeper_inspect:(NSURL *)entry info:(struct stat)info {
    if (S_ISDIR(info.st_mode)) {
        self.directorySnapshots[[self axs_cachekeeper_directory_key:entry.path]]=[self axs_cachekeeper_snapshot:info];
        if (self.purgeMode) {
            if (axs_cachekeeper_data_marker(entry.lastPathComponent)) {
                [self axs_cachekeeper_purge_hit:entry.path];[self.entries skipDescendants];
            }
            return;
        }
        // 全量清理不按名字/文件头把子目录判为数据目录，但仍记录快照供删除前核对变化。
        if (!self.fullClear && axs_cachekeeper_data_marker(entry.lastPathComponent)) {
            [self.dataDirectories addObject:entry.path];[self.entries skipDescendants];
        }
        return;
    }
    if (!S_ISREG(info.st_mode)) return;
    NSString *parent=entry.URLByDeletingLastPathComponent.path;
    if (!self.fileSnapshots[parent]) self.fileSnapshots[parent]=[NSMutableDictionary new];
    self.fileSnapshots[parent][entry.lastPathComponent]=[self axs_cachekeeper_snapshot:info];
    if (self.fullClear) return;
    if (self.purgeMode) {
        // 全目录内容审查：数据标记名、受保护路径成分、数据库头三者任一命中即整根出局；
        // 配置类 .plist/.json 不在证据口径内（见 axs_cachekeeper_purge_evidence_path）。
        NSString *relative=[entry.path hasPrefix:[self.root stringByAppendingString:@"/"]] ?
            [entry.path substringFromIndex:self.root.length + 1] : entry.lastPathComponent;
        if (axs_cachekeeper_data_marker(entry.lastPathComponent) || axs_cachekeeper_purge_evidence_path(relative)) {
            [self axs_cachekeeper_purge_hit:entry.path]; return;
        }
        int directory=axs_cachekeeper_open_directory(parent);
        int file=directory>=0 ? openat(directory,entry.lastPathComponent.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_NONBLOCK) : -1;
        struct stat opened;
        unsigned char signature[16]={0};
        ssize_t count=-1;
        if (file>=0 && !fstat(file,&opened) && S_ISREG(opened.st_mode) && opened.st_ino==info.st_ino && opened.st_dev==info.st_dev)
            count=pread(file,signature,sizeof(signature),0);
        if (count<0 || (count>=15 && !memcmp(signature,"SQLite format 3",15)) || (count>=6 && !memcmp(signature,"bplist",6)))
            [self axs_cachekeeper_purge_hit:entry.path];
        if (file>=0) close(file);
        if (directory>=0) close(directory);
        return;
    }
    // 日志模式下数据保护是文件级的：数据文件只标记自身，不连坐同目录的日志文件
    //（真机 alog 的 ready/ 里日志与数据名文件混放，目录级标记曾使整轮删除 0）；
    // 标准模式维持目录级：数据文件所在目录整体保留（其媒体多为数据附件）。
    if (axs_cachekeeper_data_marker(entry.lastPathComponent)) {
        if (self.logMode) [self.dataFiles addObject:entry.path];
        else [self.dataDirectories addObject:parent];
        return;
    }
    int directory=axs_cachekeeper_open_directory(parent);
    int file=directory>=0 ? openat(directory,entry.lastPathComponent.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_NONBLOCK) : -1;
    struct stat opened;
    unsigned char signature[16]={0};
    ssize_t count=-1;
    if (file>=0 && !fstat(file,&opened) && S_ISREG(opened.st_mode) && opened.st_ino==info.st_ino && opened.st_dev==info.st_dev)
        count=pread(file,signature,sizeof(signature),0);
    if (count<0) {
        if (self.logMode) [self.dataFiles addObject:entry.path];
        else [self.dataDirectories addObject:parent];
        self.failed++;self.error=self.logMode ? @"文件预检未完成，该文件不清理" : @"文件预检未完成，该目录不清理";
    }
    else if ((count>=15 && !memcmp(signature,"SQLite format 3",15)) || (count>=6 && !memcmp(signature,"bplist",6))) {
        if (self.logMode) [self.dataFiles addObject:entry.path];
        else [self.dataDirectories addObject:parent];
    }
    if (file>=0) close(file);
    if (directory>=0) close(directory);
}
- (BOOL)axs_cachekeeper_check_files:(NSString *)directory fd:(int)fd {
    if ([self.checkedDirectories containsObject:directory]) return YES;
    NSDictionary *records=self.fileSnapshots[directory];
    for (NSString *name in records) {
        struct stat info;
        if (fstatat(fd,name.fileSystemRepresentation,&info,AT_SYMLINK_NOFOLLOW) ||
            !S_ISREG(info.st_mode) || ![[self axs_cachekeeper_snapshot:info] isEqual:records[name]]) {
            if (![self.dataDirectories containsObject:directory]) self.changedCount++;
            [self.dataDirectories addObject:directory];self.error=@"预检后文件发生变化，该数据目录已跳过";return NO;
        }
    }
    [self.checkedDirectories addObject:directory];return YES;
}
// 删除前的目录复核。标准/全量模式为目录级稳定性门：目录快照全等且目录内全部预检文件未变。
// 日志模式只核对目录身份（inode/设备）：热日志目录里兄弟文件增删会改目录时间戳，
// 若沿用目录级门会整轮空转（2026-11-11 抖音 alog 真机：14 个目录判变化、删除 0）；
// 文件自身稳定性改由删除时逐文件比对预检记录保证（remove 的日志分支），数据文件保护不受影响。
// 清理模式（purge）同为文件级门：未知目录同样可能热写，整目录连坐会让审查通过的目录也删不动。
// 失败原因写入 verifyDetail（记录缺失/目录已被替换/变化），回执据此定位，不再只有一个笼统结论。
- (BOOL)axs_cachekeeper_verify_directory:(NSString *)path fd:(int)fd {
    struct stat info;
    self.verifyDetail = nil;
    if (fstat(fd, &info)) { self.verifyDetail = @"读取目录状态失败"; return NO; }
    NSArray *record = self.directorySnapshots[[self axs_cachekeeper_directory_key:path]];
    if (!record) { self.verifyDetail = @"预检记录缺失"; return NO; }
    if (!self.logMode && !self.purgeMode) {
        BOOL stable = [[self axs_cachekeeper_snapshot:info] isEqual:record] &&
            [self axs_cachekeeper_check_files:path fd:fd];
        if (!stable) self.verifyDetail = @"目录或其文件已变化";
        return stable;
    }
    BOOL identity = [@(info.st_ino) isEqual:record[0]] && [@(info.st_dev) isEqual:record[1]];
    if (!identity) self.verifyDetail = @"目录已被替换";
    return identity;
}
- (BOOL)axs_cachekeeper_remove:(NSURL *)entry expected:(struct stat)expected {
    self.error = nil;
    NSString *parent = entry.URLByDeletingLastPathComponent.path;
    NSString *matchedForm = [self axs_cachekeeper_matched_root_form:parent];
    if (!matchedForm) {
        self.error = [NSString stringWithFormat:@"删除失败·路径校验（errno %d）", EINVAL];
        errno = EINVAL; return NO;
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
        self.error = [NSString stringWithFormat:@"删除失败·打开缓存根（errno %d，卡在组件 %@）", openError, bad];
        errno = openError; return NO;
    }
    struct stat openedRoot;
    if (fstat(fd, &openedRoot) || openedRoot.st_dev != self.device || openedRoot.st_ino != self.inode) {
        close(fd); errno = ESTALE;
        self.error = [NSString stringWithFormat:@"删除失败·缓存根已变化（errno %d）", ESTALE];
        return NO;
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
            if (self.logMode || self.purgeMode) { close(fd); errno = EBUSY; self.error = [NSString stringWithFormat:@"预检后目录身份发生变化（%@），已跳过该文件", self.verifyDetail ?: @"原因未明"]; return NO; }
            if (![self.dataDirectories containsObject:openedPath]) self.changedCount++;
            [self.dataDirectories addObject:openedPath];close(fd);errno=EBUSY;return NO;
        }
        int child = openat(fd, part.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        int savedError = errno;
        close(fd);
        if (child < 0) {
            self.error = [NSString stringWithFormat:@"删除失败·打开子目录（errno %d）", savedError];
            errno = savedError; return NO;
        }
        fd = child;
        openedPath=[openedPath stringByAppendingPathComponent:part];
        partIndex++;
    }
    struct stat current;
    struct stat parentInfo;
    if (![self axs_cachekeeper_verify_directory:parent fd:fd]) {
        if (self.logMode || self.purgeMode) { close(fd); errno = EBUSY; self.error = [NSString stringWithFormat:@"预检后目录身份发生变化（%@），已跳过该文件", self.verifyDetail ?: @"原因未明"]; return NO; }
        if (![self.dataDirectories containsObject:parent]) self.changedCount++;
        [self.dataDirectories addObject:parent];self.error=@"预检后目录发生变化，已跳过";
        close(fd);errno=EBUSY;return NO;
    }
    const char *name = entry.lastPathComponent.fileSystemRepresentation;
    if (self.logMode || self.purgeMode) {
        // 文件级稳定性门：只比对目标文件自身的预检记录；未预检（预检后新增）或已变化的跳过本文件，
        // 不连坐同目录其他文件。计入变化数而非失败数（errno EBUSY 不计失败）。
        NSArray *record = self.fileSnapshots[parent][entry.lastPathComponent];
        struct stat currentRecord;
        if (!record || fstatat(fd, name, &currentRecord, AT_SYMLINK_NOFOLLOW) ||
            ![[self axs_cachekeeper_snapshot:currentRecord] isEqual:record]) {
            self.changedCount++;
            self.error = @"预检后文件发生变化，已跳过该文件";
            close(fd); errno = EBUSY; return NO;
        }
    }
    BOOL removed = NO;
    int file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    if (file >= 0 && !fstat(file, &current) && S_ISREG(current.st_mode) && current.st_nlink == 1 &&
        current.st_ino == expected.st_ino && current.st_dev == expected.st_dev &&
        axs_cachekeeper_old_enough(current, self.clock())) {
        // 全量清理只核对文件身份与年龄，不按内容分类；
        // 日志模式在数据库/bplist 门槛之上再加文件名日志特征门与数据标记名否决；
        // 清理模式的证据审查已在预检完成（任一证据即整根出局），此处同样只核对身份与年龄；
        // 标准模式保持媒体签名与数据库门槛。
        BOOL contentOK = self.fullClear || self.purgeMode;
        if (!contentOK) {
            unsigned char signature[32] = {0};
            ssize_t readCount = pread(file, signature, sizeof(signature), 0);
            BOOL database = readCount >= 15 && !memcmp(signature, "SQLite format 3", 15);
            BOOL propertyList = readCount >= 6 && !memcmp(signature, "bplist", 6);
            BOOL contentRejected = self.logMode ?
                (!axs_cachekeeper_log_file_name(entry.lastPathComponent) || axs_cachekeeper_data_marker(entry.lastPathComponent)) :
                !axs_cachekeeper_media_signature(signature, (size_t)readCount);
            if (readCount < 0) { self.error = @"无法核对文件内容，保留文件"; }
            else if (database || propertyList || contentRejected) {
                if (database || propertyList) [self.dataDirectories addObject:parent];
                self.protectedCount++; errno = EBUSY;
            }
            else contentOK = YES;
        }
        if (contentOK) {
            struct stat final;
            if (!fstatat(fd, name, &final, AT_SYMLINK_NOFOLLOW) && final.st_ino == current.st_ino &&
                final.st_dev == current.st_dev && axs_cachekeeper_old_enough(final, self.clock())) {
                removed = unlinkat(fd, name, 0) == 0;
                if (!removed) self.error = [NSString stringWithFormat:@"删除失败·删除文件（errno %d）", errno];
            }
            else { errno = ESTALE; self.error = [NSString stringWithFormat:@"删除失败·文件已变化（errno %d）", ESTALE]; }
        }
    } else { errno = ESTALE; self.error = [NSString stringWithFormat:@"删除失败·文件状态已变化（errno %d）", ESTALE]; }
    int savedError = errno;
    if (removed && !fstat(fd,&parentInfo)) self.directorySnapshots[[self axs_cachekeeper_directory_key:parent]]=[self axs_cachekeeper_snapshot:parentInfo];
    if (removed) [self.fileSnapshots[parent] removeObjectForKey:entry.lastPathComponent];
    if (file >= 0) close(file);
    close(fd); errno = savedError;
    return removed;
}
- (void)advance:(NSUInteger)limit shouldContinue:(BOOL (^)(void))shouldContinue {
    if (self.complete || self.cancelled) return;
    self.checkedDirectories=[NSMutableSet new];
    // 枚举器跨批次保留位置，避免每次超时都从头扫描。
    for (NSUInteger index = 0; index < limit; index++) {
        if (!shouldContinue()) { self.cancelled = YES; self.entries = nil; return; }
        struct stat rootInfo;
        if (lstat(self.root.fileSystemRepresentation, &rootInfo) || !S_ISDIR(rootInfo.st_mode) ||
            rootInfo.st_ino != self.inode || rootInfo.st_dev != self.device ||
            ![self.root isEqual:[NSURL fileURLWithPath:self.root].URLByResolvingSymlinksInPath.path]) {
            self.failed++; self.error = @"扫描期间缓存目录已改变"; self.complete = YES; self.entries = nil; return;
        }
        NSURL *entry = self.entries.nextObject;
        if (!entry) {
            if (self.checking && ![self axs_cachekeeper_is_data_directory:self.root]) {
                self.checking=NO;[self axs_cachekeeper_open_enumerator];continue;
            }
            if (self.checking) self.protectedCount++;
            self.complete=YES;self.entries=nil;return;
        }
        struct stat info;
        if (lstat(entry.fileSystemRepresentation, &info)) {
            if (errno != ENOENT) { self.failed++; self.error = @"无法读取缓存文件属性";[self.dataDirectories addObject:entry.URLByDeletingLastPathComponent.path]; }
            continue;
        }
        // URL 枚举器不递归符号链接；对非目录调用 skipDescendants 会影响后续遍历。
        if (S_ISLNK(info.st_mode)) continue;
        if (self.checking) { self.inspected++;[self axs_cachekeeper_inspect:entry info:info]; continue; }
        // 清理模式预检命中数据证据：整根出局，本轮逐项计保护、不删、不计失败；证据路径已记入 error。
        if (self.purgeMode && self.purgeBlocked) {
            self.protectedCount++;if (S_ISDIR(info.st_mode)) [self.entries skipDescendants];continue;
        }
        if ([self axs_cachekeeper_is_data_directory:entry.path]) {
            self.protectedCount++;if (S_ISDIR(info.st_mode)) [self.entries skipDescendants];continue;
        }
        // 日志模式的文件级数据保护：预检已标记的数据文件只跳过自身（同目录日志不受影响）。
        if (self.logMode && [self.dataFiles containsObject:entry.path]) { self.protectedCount++; continue; }
        NSString *relative = [entry.path substringFromIndex:self.root.length + 1];
        // 全量清理的根已由策略层限定为平台缓存契约目录，根内不再按受保护名拦截；清理模式的
        // 证据审查已在预检完成（口径见 purge_evidence_path，配置类 .plist/.json 不算证据），此处同样放行；其余模式不变。
        if (!self.fullClear && !self.purgeMode && axs_cachekeeper_protected_path(relative)) {
            self.protectedCount++;
            if (S_ISDIR(info.st_mode)) [self.entries skipDescendants];
            continue;
        }
        if (S_ISDIR(info.st_mode)) continue;
        if (!S_ISREG(info.st_mode)) continue;
        if (info.st_nlink != 1 || (!self.fullClear && !self.purgeMode && !axs_cachekeeper_ordinary_cache_file(relative))) { self.protectedCount++; continue; }
        if (!axs_cachekeeper_old_enough(info, self.clock())) { self.recentCount++; continue; }
        if ([self axs_cachekeeper_remove:entry expected:info]) { self.removed++; self.bytes += info.st_size; }
        else if (errno != ENOENT && errno != EBUSY) { self.failed++; if (![self.error hasPrefix:@"删除失败·"]) self.error = [NSString stringWithFormat:@"删除失败（errno %d）", errno]; }
    }
}
@end
