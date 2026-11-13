#import "AxsCacheKeeperDependencySnapshot.h"
#import "AxsCacheKeeperFileAccess.h"

@interface AxsCacheKeeperDependencySnapshot ()
@property(nonatomic,copy) NSString *path;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSArray *> *records;
@property(nonatomic,strong) NSDirectoryEnumerator *entries;
@property(nonatomic,copy) NSArray *aliases;
@property(nonatomic) BOOL captured;
@property(nonatomic) BOOL started;
@property(nonatomic) NSUInteger seen;
@property(nonatomic,readwrite) BOOL complete;
@property(nonatomic,readwrite) BOOL valid;
@property(nonatomic,readwrite,copy) NSString *error;
@end

static NSArray *AxsCacheKeeperDependencyStamp(struct stat info) {
    return @[@(info.st_dev),@(info.st_ino),@(info.st_mode),@(info.st_nlink),@(info.st_size),
        @(info.st_mtimespec.tv_sec),@(info.st_mtimespec.tv_nsec),@(info.st_ctimespec.tv_sec),@(info.st_ctimespec.tv_nsec)];
}

@implementation AxsCacheKeeperDependencySnapshot
- (instancetype)initWithPath:(NSString *)path {
    if (!(self=[super init])) return nil;
    _path=[path copy];_records=[NSMutableDictionary new];_valid=YES;
    return self;
}
- (void)axs_cachekeeper_invalidate:(NSString *)reason {
    self.valid=NO;self.complete=YES;self.entries=nil;self.error=reason;
}
- (BOOL)axs_cachekeeper_read:(NSString *)path key:(NSString *)key {
    struct stat info;
    if (lstat(path.fileSystemRepresentation,&info)) {
        [self axs_cachekeeper_invalidate:[NSString stringWithFormat:@"规则依赖读取失败：%@（errno %d）",path,errno]];return NO;
    }
    if ((!S_ISDIR(info.st_mode) && !S_ISREG(info.st_mode)) ||
        ![path isEqual:[NSURL fileURLWithPath:path].URLByResolvingSymlinksInPath.path]) {
        [self axs_cachekeeper_invalidate:@"规则依赖包含链接或非普通文件，不能确认集合"];return NO;
    }
    NSArray *stamp=AxsCacheKeeperDependencyStamp(info);
    if (self.captured && ![self.records[key] isEqual:stamp]) {
        [self axs_cachekeeper_invalidate:[NSString stringWithFormat:@"规则依赖集合已变化：%@",path]];return NO;
    }
    if (!self.captured) self.records[key]=stamp;
    self.seen++;
    return YES;
}
- (NSUInteger)advance:(NSUInteger)limit {
    NSUInteger used=0;
    while (used<limit && !self.complete) {
        used++;
        if (!self.started) {
            self.started=YES;self.seen=0;
            if (![self axs_cachekeeper_read:self.path key:@""]) break;
            mode_t mode=[self.records[@""][2] unsignedIntValue];
            if (S_ISREG(mode)) { self.captured=YES;self.complete=YES;break; }
            self.aliases=axs_cachekeeper_directory_aliases(self.path);
            __weak typeof(self) weak=self;
            self.entries=[NSFileManager.defaultManager enumeratorAtURL:[NSURL fileURLWithPath:self.path]
                includingPropertiesForKeys:nil options:0 errorHandler:^BOOL(NSURL *url,NSError *error) {
                    [weak axs_cachekeeper_invalidate:[NSString stringWithFormat:@"规则依赖枚举失败：%@（%@）",url.path,error.localizedDescription]];return NO;
                }];
            if (!self.entries) [self axs_cachekeeper_invalidate:@"无法枚举规则依赖集合"];
            continue;
        }
        NSURL *next=self.entries.nextObject;
        if (!self.valid) break;
        if (!next) {
            if (self.captured && self.seen!=self.records.count) [self axs_cachekeeper_invalidate:@"规则依赖集合成员已减少"];
            self.complete=YES;self.captured=YES;self.entries=nil;break;
        }
        NSString *entry=axs_cachekeeper_enumerated_path(next.path,self.path,self.aliases);
        if (!entry) { [self axs_cachekeeper_invalidate:@"规则依赖枚举越界"];break; }
        [self axs_cachekeeper_read:entry key:[entry substringFromIndex:self.path.length+1]];
    }
    return used;
}
- (void)beginVerification {
    if (!self.captured || !self.valid) return;
    self.started=NO;self.complete=NO;self.entries=nil;
}
- (BOOL)validateRoot {
    if (!self.valid || !self.captured) return NO;
    return [self axs_cachekeeper_read:self.path key:@""];
}
- (void)didRemovePath:(NSString *)path {
    if (!self.valid || !self.captured) return;
    if ([path isEqual:self.path]) { [self axs_cachekeeper_invalidate:@"依赖文件已被删除"];return; }
    NSString *prefix=[self.path stringByAppendingString:@"/"];
    if (![path hasPrefix:prefix]) return;
    [self.records removeObjectForKey:[path substringFromIndex:prefix.length]];
    NSString *parent=path.stringByDeletingLastPathComponent;
    NSString *key=[parent isEqual:self.path] ? @"" : [parent substringFromIndex:prefix.length];
    struct stat info;
    if (lstat(parent.fileSystemRepresentation,&info)) { [self axs_cachekeeper_invalidate:@"删除后无法更新依赖目录身份"];return; }
    NSArray *before=self.records[key];
    NSArray *after=AxsCacheKeeperDependencyStamp(info);
    if (!before || ![before[0] isEqual:after[0]] || ![before[1] isEqual:after[1]]) {
        [self axs_cachekeeper_invalidate:@"删除后依赖目录身份变化"];return;
    }
    self.records[key]=after;
    // 其他范围可能正在分批复核；重新枚举，避免旧枚举游标/已见计数混入自身删除前的成员。
    if (!self.complete) [self beginVerification];
}
@end
