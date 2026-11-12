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
@property(nonatomic, copy) NSArray<NSString *> *rootAliases;
@property(nonatomic, readwrite) BOOL fullClear;
@property(nonatomic, readwrite) BOOL logMode;
@property(nonatomic, readwrite) BOOL purgeMode;
@property(nonatomic) BOOL purgeBlocked;
@property(nonatomic) BOOL purgeMixed;
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
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *recordedFailures;
@property(nonatomic,copy) int (^unlinkFile)(int, const char *);
@property(nonatomic,copy) NSArray<NSString *> *rootForms;
@end

@implementation AxsCacheKeeperSweep
- (instancetype)initWithRoot:(NSString *)root {
    return [self initWithRoot:root clock:^NSTimeInterval { return NSDate.date.timeIntervalSince1970; } fullClear:NO logMode:NO];
}
- (instancetype)initWithRoot:(NSString *)root clock:(NSTimeInterval (^)(void))clock {
    return [self initWithRoot:root clock:clock unlinkFile:^int(int fd,const char *name) { return unlinkat(fd,name,0); }];
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
    // 模式只影响预检/删除阶段（advance/inspect/remove），初始化本体不依赖模式，故先走统一指定初始化器再设模式。
    self=[self initWithRoot:root clock:clock];
    if (self) { _fullClear=fullClear; _logMode=logMode; _purgeMode=purgeMode; }
    return self;
}
- (instancetype)initWithRoot:(NSString *)root clock:(NSTimeInterval (^)(void))clock unlinkFile:(int (^)(int,const char *))unlinkFile {
    if (!(self = [super init])) return nil;
    _root = [root copy];
    _clock = [clock copy];
    _unlinkFile=[unlinkFile copy];_recordedFailures=[NSMutableArray new];
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
// B 案：目录名命中数据证据时整根出局（只记首条证据，回执据此定位；不计失败，
// 这是正确拒绝而非故障）。文件级证据改走混合降级（见 purge_mixed），不再整根出局。
- (void)axs_cachekeeper_purge_hit:(NSString *)path {
    if (self.purgeBlocked) return;
    self.purgeBlocked = YES;
    self.purgeMixed = NO;
    self.purgeEvidence = path;
    NSString *relative = [path hasPrefix:[self.root stringByAppendingString:@"/"]] ?
        [path substringFromIndex:self.root.length + 1] : path.lastPathComponent;
    self.error = [NSString stringWithFormat:@"检出数据证据，本目录不清理：%@", relative];
}
// B 案自动降级（2026-11-12 用户拍板：定级不手动开，插件自己定）：文件级数据证据
// （数据标记名、受保护路径成分、数据库头、读不到内容）只把目录标记为混合，不整根出局；
// 删除时改走日志门，仅删日志特征文件，数据与未知内容保留。首条证据记入回执。
- (void)axs_cachekeeper_purge_mixed:(NSString *)path {
    if (self.purgeMixed || self.purgeBlocked) return;
    self.purgeMixed = YES;
    self.purgeEvidence = path;
    NSString *relative = [path hasPrefix:[self.root stringByAppendingString:@"/"]] ?
        [path substringFromIndex:self.root.length + 1] : path.lastPathComponent;
    self.error = [NSString stringWithFormat:@"检出数据证据，已自动仅清理其中的日志文件：%@", relative];
}
- (void)axs_cachekeeper_inspect:(NSString *)entry info:(struct stat)info {
    if (S_ISDIR(info.st_mode)) {
        self.directorySnapshots[[self axs_cachekeeper_directory_key:entry]]=[self axs_cachekeeper_snapshot:info];
        if (self.purgeMode) {
            // 受保护成分的子目录同样整根出局：仅查数据标记名会漏掉 Preferences 等
            // 受保护目录，其内日志会走混合日志门被删（审计第 1 项）。
            NSString *relative=[entry hasPrefix:[self.root stringByAppendingString:@"/"]] ?
                [entry substringFromIndex:self.root.length + 1] : entry.lastPathComponent;
            if (axs_cachekeeper_data_marker(entry.lastPathComponent) || axs_cachekeeper_protected_path(relative)) {
                [self axs_cachekeeper_purge_hit:entry];[self.entries skipDescendants];
            }
            return;
        }
        // 全量清理不按名字/文件头把子目录判为数据目录，但仍记录快照供删除前核对变化。
        if (!self.fullClear && axs_cachekeeper_data_marker(entry.lastPathComponent)) {
            [self.dataDirectories addObject:entry];[self.entries skipDescendants];
        }
        return;
    }
    if (!S_ISREG(info.st_mode)) return;
    NSString *parent=entry.stringByDeletingLastPathComponent;
    if (!self.fileSnapshots[parent]) self.fileSnapshots[parent]=[NSMutableDictionary new];
    self.fileSnapshots[parent][entry.lastPathComponent]=[self axs_cachekeeper_snapshot:info];
    if (self.fullClear) return;
    if (self.purgeMode) {
        // 全目录内容审查：文件级数据证据（数据标记名、受保护路径成分、数据库头、
        // 读不到内容）只把目录标记为混合，删除时自动降级为日志门，仅删日志特征文件，
        // 数据与未知内容保留，无需手动定级；目录名命中仍整根出局（见上）。
        // 配置类 .plist/.json 不在证据口径内（见 axs_cachekeeper_purge_evidence_path）。
        NSString *relative=[entry hasPrefix:[self.root stringByAppendingString:@"/"]] ?
            [entry substringFromIndex:self.root.length + 1] : entry.lastPathComponent;
        if (axs_cachekeeper_data_marker(entry.lastPathComponent) || axs_cachekeeper_purge_evidence_path(relative)) {
            [self axs_cachekeeper_purge_mixed:entry]; return;
        }
        int directory=axs_cachekeeper_open_directory(parent);
        int file=directory>=0 ? openat(directory,entry.lastPathComponent.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_NONBLOCK) : -1;
        struct stat opened;
        unsigned char signature[16]={0};
        ssize_t count=-1;
        if (file>=0 && !fstat(file,&opened) && S_ISREG(opened.st_mode) && opened.st_ino==info.st_ino && opened.st_dev==info.st_dev)
            count=pread(file,signature,sizeof(signature),0);
        // 正数短读须核对完整性：未读满 min(16, 文件大小) 即未读全，按读失败处理（审计第 3 项）。
        BOOL shortRead = count >= 0 && count < MIN((ssize_t)sizeof(signature), (ssize_t)opened.st_size);
        if (count<0 || shortRead) {
            // 读不到内容的文件须落盘保护（入 dataFiles、计失败），否则混合后日志门
            // 会按名字删掉它（审计第 3 项）；删除阶段亦查 dataFiles（见 advance）。
            [self.dataFiles addObject:entry]; self.failed++;
            [self axs_cachekeeper_purge_mixed:entry];
        }
        else if ((count>=15 && !memcmp(signature,"SQLite format 3",15)) || (count>=6 && !memcmp(signature,"bplist",6)))
            [self axs_cachekeeper_purge_mixed:entry];
        if (file>=0) close(file);
        if (directory>=0) close(directory);
        return;
    }
    // 日志模式下数据保护是文件级的：数据文件只标记自身，不连坐同目录的日志文件
    //（真机 alog 的 ready/ 里日志与数据名文件混放，目录级标记曾使整轮删除 0）；
    // 标准模式维持目录级：数据文件所在目录整体保留（其媒体多为数据附件）。
    if (axs_cachekeeper_data_marker(entry.lastPathComponent)) {
        if (self.logMode) [self.dataFiles addObject:entry];
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
    BOOL shortRead = count >= 0 && count < MIN((ssize_t)sizeof(signature), (ssize_t)opened.st_size);
    if (count<0 || shortRead) {
        if (self.logMode) [self.dataFiles addObject:entry];
        else [self.dataDirectories addObject:parent];
        self.failed++;self.error=self.logMode ? @"文件预检未完成，该文件不清理" : @"文件预检未完成，该目录不清理";
    }
    else if ((count>=15 && !memcmp(signature,"SQLite format 3",15)) || (count>=6 && !memcmp(signature,"bplist",6))) {
        if (self.logMode) [self.dataFiles addObject:entry];
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
- (BOOL)axs_cachekeeper_remove:(NSString *)entry expected:(struct stat)expected {
    self.error = nil;
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
            if (self.logMode || self.purgeMode) { close(fd); errno = EBUSY; self.error = [NSString stringWithFormat:@"预检后目录身份发生变化（%@），已跳过该文件", self.verifyDetail ?: @"原因未明"]; return NO; }
            if (![self.dataDirectories containsObject:openedPath]) self.changedCount++;
            [self.dataDirectories addObject:openedPath];close(fd);errno=EBUSY;return NO;
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
        if (self.logMode || self.purgeMode) { close(fd); errno = EBUSY; self.error = [NSString stringWithFormat:@"预检后目录身份发生变化（%@），已跳过该文件", self.verifyDetail ?: @"原因未明"]; return NO; }
        if (![self.dataDirectories containsObject:parent]) self.changedCount++;
        [self.dataDirectories addObject:parent];self.error=@"预检后目录发生变化，已跳过";
        close(fd);errno=EBUSY;return NO;
    }
    NSString *fileName=entry.lastPathComponent;
    const char *name = fileName.fileSystemRepresentation;
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
    if (file<0) { int code=errno;close(fd);[self axs_cachekeeper_failure:@"openat-file" code:code path:entry detail:@""];return NO; }
    if (fstat(file,&current)) { int code=errno;close(file);close(fd);[self axs_cachekeeper_failure:@"fstat-file" code:code path:entry detail:@""];return NO; }
    if (S_ISREG(current.st_mode) && current.st_nlink == 1 &&
        current.st_ino == expected.st_ino && current.st_dev == expected.st_dev &&
        axs_cachekeeper_old_enough(current, self.clock())) {
        // 全量清理只核对文件身份与年龄，不按内容分类；
        // 日志模式在数据库/bplist 门槛之上再加文件名日志特征门与数据标记名否决；
        // 清理模式零证据时也须复核内容：预检后新增的数据证据须在删除阶段重标混合
        //（审计第 2 项），否则旧文件会按过期零证据分类全删；检出证据的清理目录
        // 自动降级为日志门（仅删日志特征文件，无需手动定级）；
        // 标准模式保持媒体签名与数据库门槛。
        BOOL contentOK = self.fullClear;
        if (!contentOK) {
            NSString *relative=[entry hasPrefix:[self.root stringByAppendingString:@"/"]] ?
                [entry substringFromIndex:self.root.length + 1] : entry.lastPathComponent;
            unsigned char signature[32] = {0};
            ssize_t readCount = pread(file, signature, sizeof(signature), 0);
            // 正数短读须核对完整性：未读满 min(32, 文件大小) 即未读全，按读失败保护（审计第 3 项）。
            BOOL shortRead = readCount >= 0 && readCount < MIN((ssize_t)sizeof(signature), (ssize_t)current.st_size);
            BOOL database = readCount >= 15 && !memcmp(signature, "SQLite format 3", 15);
            BOOL propertyList = readCount >= 6 && !memcmp(signature, "bplist", 6);
            if (readCount < 0) { int code=errno;[self axs_cachekeeper_failure:@"pread" code:code path:entry detail:@""]; }
            else if (shortRead) { [self axs_cachekeeper_failure:@"pread" code:EIO path:entry detail:@"短读：未读满请求长度"]; }
            else if (self.purgeMode && !self.purgeMixed) {
                // 零证据清理：删除时复核证据；任一新证据（数据标记名、受保护路径成分、
                // 数据库/bplist 头）重标混合，本文件改走下方日志门，不再直接删除。
                if (axs_cachekeeper_data_marker(entry.lastPathComponent) || axs_cachekeeper_purge_evidence_path(relative) || database || propertyList) {
                    [self axs_cachekeeper_purge_mixed:entry];
                } else { contentOK = YES; }
            }
            if (!contentOK && readCount >= 0 && !shortRead) {
                // 日志模式与混合清理同为文件级保护：数据文件只否决自身，不连坐同目录的日志文件
                //（目录级连坐曾使热日志目录整轮删除 0；此处若把父目录记入数据目录，枚举顺序在后
                // 的同目录日志会被整目录跳过，混合降级即失效——故文件级模式下不记目录）。
                // 日志门另加两道否决：受保护路径成分（审计第 1 项）与可识别媒体头
                //（photo.log.jpg 这类挂日志名的媒体文件，审计第 3 项）。
                BOOL logGate = self.logMode || (self.purgeMode && self.purgeMixed);
                BOOL contentRejected = logGate ?
                    (!axs_cachekeeper_log_file_name(entry.lastPathComponent) || axs_cachekeeper_data_marker(entry.lastPathComponent) ||
                     axs_cachekeeper_protected_path(relative) || axs_cachekeeper_media_signature(signature, (size_t)readCount)) :
                    !axs_cachekeeper_media_signature(signature, (size_t)readCount);
                if (database || propertyList || contentRejected) {
                    if ((database || propertyList) && !logGate) [self.dataDirectories addObject:parent];
                    self.protectedCount++; errno = EBUSY;
                }
                else contentOK = YES;
            }
        }
        if (contentOK) {
            struct stat final;
            if (fstatat(fd,name,&final,AT_SYMLINK_NOFOLLOW)) {
                int code=errno;[self axs_cachekeeper_failure:@"fstatat-final" code:code path:entry detail:@""];
            } else if (final.st_ino == current.st_ino && final.st_dev == current.st_dev && axs_cachekeeper_old_enough(final, self.clock())) {
                int result=self.unlinkFile(fd,name);int code=result ? errno : 0;
                removed=result==0;
                if (!removed) [self axs_cachekeeper_failure:@"unlinkat" code:code path:entry detail:@"flags=0"];
            } else [self axs_cachekeeper_failure:@"删除前身份/时间核对" code:ESTALE path:entry detail:@""];
        }
    } else [self axs_cachekeeper_failure:@"打开文件身份/时间核对" code:ESTALE path:entry detail:@""];
    int savedError = errno;
    if (removed && !fstat(fd,&parentInfo)) self.directorySnapshots[[self axs_cachekeeper_directory_key:parent]]=[self axs_cachekeeper_snapshot:parentInfo];
    if (removed) [self.fileSnapshots[parent] removeObjectForKey:entry.lastPathComponent];
    if (file >= 0) close(file);
    close(fd); errno = savedError;
    return removed;
}
- (NSArray<NSDictionary *> *)failureDetails { return [self.recordedFailures copy]; }
- (void)axs_cachekeeper_failure:(NSString *)stage code:(int)code path:(NSString *)path detail:(NSString *)detail {
    self.error=[NSString stringWithFormat:@"%@ 失败（errno %d：%s）",stage,code,strerror(code)];
    if (self.recordedFailures.count<8) [self.recordedFailures addObject:@{@"stage":stage,@"code":@(code),@"path":path ?: @"",@"detail":detail ?: @""}];
    errno=code;
}
- (void)advance:(NSUInteger)limit shouldContinue:(BOOL (^)(void))shouldContinue {
    if (self.complete || self.cancelled) return;
    self.checkedDirectories=[NSMutableSet new];
    // 根路径的符号链接解析每调用一次即可：逐文件解析是单周期开销的主要来源之一；
    // 根被替换仍由逐文件的 inode/设备核对捕获，解析比较只负责跨调用的指向变化。
    NSString *resolvedRootPath = [NSURL fileURLWithPath:self.root].URLByResolvingSymlinksInPath.path;
    // 枚举器跨批次保留位置，避免每次超时都从头扫描。
    for (NSUInteger index = 0; index < limit; index++) {
        if (!shouldContinue()) { self.cancelled = YES; self.entries = nil; return; }
        struct stat rootInfo;
        if (lstat(self.root.fileSystemRepresentation, &rootInfo) || !S_ISDIR(rootInfo.st_mode) ||
            rootInfo.st_ino != self.inode || rootInfo.st_dev != self.device ||
            ![self.root isEqual:resolvedRootPath]) {
            self.failed++; self.error = @"扫描期间缓存目录已改变"; self.complete = YES; self.entries = nil; return;
        }
        NSURL *enumerated = self.entries.nextObject;
        if (!enumerated) {
            if (self.checking && ![self axs_cachekeeper_is_data_directory:self.root]) {
                self.checking=NO;[self axs_cachekeeper_open_enumerator];continue;
            }
            if (self.checking) self.protectedCount++;
            self.complete=YES;self.entries=nil;return;
        }
        NSString *entry=axs_cachekeeper_enumerated_path(enumerated.path,self.root,self.rootAliases);
        if (!entry) {
            self.failed++;[self.dataDirectories addObject:self.root];
            [self axs_cachekeeper_failure:@"枚举路径边界" code:EINVAL path:enumerated.path detail:self.root];
            self.complete=YES;self.entries=nil;return;
        }
        struct stat info;
        if (lstat(entry.fileSystemRepresentation, &info)) {
            if (errno != ENOENT) { self.failed++; self.error = @"无法读取缓存文件属性";[self.dataDirectories addObject:entry.stringByDeletingLastPathComponent]; }
            continue;
        }
        // URL 枚举器不递归符号链接；对非目录调用 skipDescendants 会影响后续遍历。
        if (S_ISLNK(info.st_mode)) continue;
        if (self.checking) { self.inspected++;[self axs_cachekeeper_inspect:entry info:info]; continue; }
        // 清理模式目录名命中数据证据：整根出局，本轮逐项计保护、不删、不计失败；证据路径已记入 error。
        // 文件级证据改走混合降级（purgeMixed），不经过此处，删除时按日志门逐文件判定。
        if (self.purgeMode && self.purgeBlocked) {
            self.protectedCount++;if (S_ISDIR(info.st_mode)) [self.entries skipDescendants];continue;
        }
        if ([self axs_cachekeeper_is_data_directory:entry]) {
            self.protectedCount++;if (S_ISDIR(info.st_mode)) [self.entries skipDescendants];continue;
        }
        // 日志模式的文件级数据保护：预检已标记的数据文件只跳过自身（同目录日志不受影响）。
        if ((self.logMode || self.purgeMode) && [self.dataFiles containsObject:entry]) { self.protectedCount++; continue; }
        NSString *relative = [entry substringFromIndex:self.root.length + 1];
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
        else if (errno != ENOENT && errno != EBUSY) self.failed++;
    }
}
@end
