#import "AxsCacheKeeperInspection.h"
#import "AxsCacheKeeperPolicy.h"
#import "AxsCacheKeeperFileAccess.h"
#include <dirent.h>
#include <stddef.h>

static const NSUInteger AxsCacheKeeperInspectionDepthLimit=64;
static const NSUInteger AxsCacheKeeperInspectionFailureLimit=64;
static const NSUInteger AxsCacheKeeperInspectionNameByteLimit=sizeof(((struct dirent *)0)->d_name)-1;

// Private components retain their terminator, so every syscall consumes exactly
// the bytes validated at the dirent boundary, never a presentation roundtrip.
static BOOL axs_cachekeeper_inspection_raw_component(NSData *component) {
    if (![component isKindOfClass:NSData.class] || component.length<2 || component.length>AxsCacheKeeperInspectionNameByteLimit+1) return NO;
    const char *bytes=component.bytes;size_t length=component.length-1;
    return bytes[length]==0 && !memchr(bytes,0,length) && !memchr(bytes,'/',length) &&
        !(length==1 && bytes[0]=='.') && !(length==2 && bytes[0]=='.' && bytes[1]=='.');
}
static NSString *axs_cachekeeper_inspection_policy_component(NSData *component) {
    // Policy decoding is independent of display conversion. Preserve valid
    // Unicode case/marker semantics; this text is never used for POSIX lookup.
    NSString *decoded=[[NSString alloc] initWithBytes:component.bytes length:component.length-1 encoding:NSUTF8StringEncoding];
    return decoded ?: @"opaque-component";
}
static BOOL axs_cachekeeper_inspection_raw_hidden(NSArray<NSData *> *components) {
    NSMutableArray *parts=[NSMutableArray new];
    for (NSData *component in components) [parts addObject:axs_cachekeeper_inspection_policy_component(component)];
    return axs_cachekeeper_hidden_directory([parts componentsJoinedByString:@"/"]);
}

static BOOL axs_cachekeeper_inspection_identity(struct stat a,struct stat b) {
    return a.st_dev==b.st_dev && a.st_ino==b.st_ino && (a.st_mode&S_IFMT)==(b.st_mode&S_IFMT);
}
static BOOL axs_cachekeeper_inspection_stable(struct stat a,struct stat b) {
    return axs_cachekeeper_inspection_identity(a,b) && a.st_size==b.st_size && a.st_nlink==b.st_nlink &&
        a.st_mtimespec.tv_sec==b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec==b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec==b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec==b.st_ctimespec.tv_nsec;
}

@interface AxsCacheKeeperInspectionDirectory : NSObject
@property(nonatomic) int descriptor;
@property(nonatomic) DIR *stream;
@property(nonatomic) struct stat identity;
@property(nonatomic,copy) NSString *name;
@property(nonatomic,copy) NSString *relative;
@property(nonatomic,copy) NSData *rawName;
@property(nonatomic,copy) NSArray<NSData *> *rawComponents;
@property(nonatomic) BOOL displayOperable;
- (void)close;
@end
@implementation AxsCacheKeeperInspectionDirectory
- (instancetype)init {self=[super init];if (self) _descriptor=-1;return self;}
- (void)close {
    if (_stream) {closedir(_stream);_stream=NULL;_descriptor=-1;}
    else if (_descriptor>=0) {close(_descriptor);_descriptor=-1;}
}
- (void)dealloc {[self close];}
@end

@interface AxsCacheKeeperInspectionEntry : NSObject
@property(nonatomic,strong) AxsCacheKeeperInspectionDirectory *parent;
@property(nonatomic,copy) NSString *name;
@property(nonatomic,copy) NSString *relative;
@property(nonatomic,copy) NSData *rawName;
@property(nonatomic,copy) NSArray<NSData *> *rawComponents;
@property(nonatomic) BOOL displayOperable;
@end
@implementation AxsCacheKeeperInspectionEntry
@end

// One private walker serves header inspection and twin lookup. A pathname is
// used only to open/revalidate the authorized root; descendants stay fd-relative.
@interface AxsCacheKeeperInspectionWalker : NSObject
@property(nonatomic,copy) NSString *path;
@property(nonatomic) int anchor;
@property(nonatomic) struct stat identity;
@property(nonatomic,strong) NSMutableArray<AxsCacheKeeperInspectionDirectory *> *chain;
@property(nonatomic,copy) void (^failure)(NSString *,NSString *,int);
@property(nonatomic) BOOL complete;
@property(nonatomic) NSUInteger invalidNameRecords;
@property(nonatomic) NSUInteger nameDisplayOmitted;
- (instancetype)initWithPath:(NSString *)path failure:(void (^)(NSString *,NSString *,int))failure;
- (AxsCacheKeeperInspectionEntry *)nextEntry;
- (BOOL)validate;
- (BOOL)validateChain:(NSArray<AxsCacheKeeperInspectionDirectory *> *)chain;
- (BOOL)statEntry:(AxsCacheKeeperInspectionEntry *)entry info:(struct stat *)info;
- (BOOL)entry:(AxsCacheKeeperInspectionEntry *)entry matches:(struct stat)expected;
- (void)descend:(AxsCacheKeeperInspectionEntry *)entry info:(struct stat)expected;
- (BOOL)validateSource:(NSDictionary *)source;
- (void)close;
@end
@implementation AxsCacheKeeperInspectionWalker
- (instancetype)initWithPath:(NSString *)path failure:(void (^)(NSString *,NSString *,int))failure {
    self=[super init];if (!self) return nil;
    _anchor=-1;_chain=[NSMutableArray new];_failure=[failure copy];
    if (![path isKindOfClass:NSString.class] || ![path hasPrefix:@"/"] ||
        [path rangeOfCharacterFromSet:[NSCharacterSet characterSetWithRange:NSMakeRange(0,1)]].location!=NSNotFound) {
        _complete=YES;_failure(@"openRoot",@"posix",EINVAL);return self;
    }
    while (path.length>1 && [path hasSuffix:@"/"]) path=[path substringToIndex:path.length-1];
    _path=[path copy];struct stat before,opened,after;
    if (lstat(path.fileSystemRepresentation,&before)) {
        int code=errno;_complete=YES;_failure(@"openRoot",@"posix",code);return self;
    }
    _anchor=axs_cachekeeper_open_directory(path);
    if (_anchor<0) {int code=errno;_complete=YES;_failure(@"openRoot",@"posix",code);return self;}
    if (fstat(_anchor,&opened) || lstat(path.fileSystemRepresentation,&after)) {
        int code=errno;[self close];_failure(@"rootStat",@"posix",code);return self;
    }
    if (!S_ISDIR(before.st_mode) || !axs_cachekeeper_inspection_identity(before,opened) ||
        !axs_cachekeeper_inspection_identity(opened,after)) {
        [self close];_failure(@"rootRecheck",@"identity",0);return self;
    }
    _identity=opened;
    int duplicate=fcntl(_anchor,F_DUPFD_CLOEXEC,0);
    if (duplicate<0) {int code=errno;[self close];_failure(@"openRoot",@"posix",code);return self;}
    AxsCacheKeeperInspectionDirectory *root=[AxsCacheKeeperInspectionDirectory new];
    root.descriptor=duplicate;root.identity=opened;root.name=@"";root.relative=@"";root.rawComponents=@[];root.displayOperable=YES;
    root.stream=fdopendir(duplicate);
    if (!root.stream) {int code=errno;[root close];[self close];_failure(@"enumerate",@"posix",code);return self;}
    [_chain addObject:root];return self;
}
- (void)closeEntries {for (AxsCacheKeeperInspectionDirectory *node in _chain) [node close];[_chain removeAllObjects];}
- (void)close {[self closeEntries];if (_anchor>=0) {close(_anchor);_anchor=-1;}_complete=YES;}
- (void)dealloc {[self close];}
- (BOOL)stop:(NSString *)stage domain:(NSString *)domain code:(int)code {
    [self close];self.failure(stage,domain,code);return NO;
}
- (BOOL)validate {
    if (_anchor<0) return NO;
    struct stat held,named;
    if (fstat(_anchor,&held)) {int code=errno;return [self stop:@"rootRecheck" domain:@"posix" code:code];}
    if (lstat(_path.fileSystemRepresentation,&named)) {int code=errno;return [self stop:@"rootRecheck" domain:@"posix" code:code];}
    if (!axs_cachekeeper_inspection_identity(held,_identity) || !axs_cachekeeper_inspection_identity(named,_identity))
        return [self stop:@"rootRecheck" domain:@"identity" code:0];
    // The primary anchor survives EOF while twins are searched; later changes
    // to its directory membership invalidate that earlier coverage snapshot.
    if (_complete && !axs_cachekeeper_inspection_stable(held,_identity))
        return [self stop:@"rootRecheck" domain:@"identity" code:0];
    return [self validateChain:_chain];
}
- (BOOL)validateChain:(NSArray<AxsCacheKeeperInspectionDirectory *> *)chain {
    for (NSUInteger index=0;index<chain.count;index++) {
        AxsCacheKeeperInspectionDirectory *node=chain[index];struct stat current,entry;
        if (fstat(node.descriptor,&current)) {int code=errno;return [self stop:@"ancestorRecheck" domain:@"posix" code:code];}
        if (!axs_cachekeeper_inspection_identity(current,node.identity))
            return [self stop:@"ancestorRecheck" domain:@"identity" code:0];
        if (index) {
            if (fstatat(chain[index-1].descriptor,node.rawName.bytes,&entry,AT_SYMLINK_NOFOLLOW)) {
                int code=errno;return [self stop:@"ancestorRecheck" domain:@"posix" code:code];
            }
            if (!axs_cachekeeper_inspection_identity(entry,node.identity))
                return [self stop:@"ancestorRecheck" domain:@"identity" code:0];
        }
    }
    return YES;
}
- (BOOL)validateSource:(NSDictionary *)source {
    if (![self validate]) return NO;
    NSArray<NSData *> *parts=source[@"rawComponents"];
    NSArray<NSArray<NSNumber *> *> *ancestors=source[@"ancestors"];
    if (parts.count!=ancestors.count+1) return [self stop:@"fileRecheck" domain:@"identity" code:0];
    for (NSData *part in parts) if (!axs_cachekeeper_inspection_raw_component(part))
        return [self stop:@"fileRecheck" domain:@"identity" code:0];
    struct stat expected;[source[@"stat"] getValue:&expected size:sizeof(expected)];
    int duplicate=fcntl(_anchor,F_DUPFD_CLOEXEC,0);
    if (duplicate<0) {int code=errno;return [self stop:@"rootRecheck" domain:@"posix" code:code];}
    AxsCacheKeeperInspectionDirectory *root=[AxsCacheKeeperInspectionDirectory new];
    root.descriptor=duplicate;root.identity=_identity;root.name=@"";
    NSMutableArray<AxsCacheKeeperInspectionDirectory *> *parents=[NSMutableArray arrayWithObject:root];
    @try {
        for (NSUInteger index=0;index<ancestors.count;index++) {
            NSData *name=parts[index];struct stat named,opened;
            AxsCacheKeeperInspectionDirectory *parent=parents.lastObject;
            if (fstatat(parent.descriptor,name.bytes,&named,AT_SYMLINK_NOFOLLOW)) {
                int code=errno;return [self stop:@"ancestorRecheck" domain:@"posix" code:code];
            }
            if (!S_ISDIR(named.st_mode) || (unsigned long long)named.st_dev!=[ancestors[index][0] unsignedLongLongValue] ||
                (unsigned long long)named.st_ino!=[ancestors[index][1] unsignedLongLongValue])
                return [self stop:@"ancestorRecheck" domain:@"identity" code:0];
            int fd=openat(parent.descriptor,name.bytes,O_SEARCH|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
            if (fd<0) {int code=errno;return [self stop:@"ancestorRecheck" domain:@"posix" code:code];}
            AxsCacheKeeperInspectionDirectory *node=[AxsCacheKeeperInspectionDirectory new];
            node.descriptor=fd;node.rawName=name;node.identity=named;[parents addObject:node];
            if (fstat(fd,&opened)) {int code=errno;return [self stop:@"ancestorRecheck" domain:@"posix" code:code];}
            if (!axs_cachekeeper_inspection_identity(named,opened))
                return [self stop:@"ancestorRecheck" domain:@"identity" code:0];
        }
        if (![self validate] || ![self validateChain:parents]) return NO;
        struct stat current;
        if (fstatat(parents.lastObject.descriptor,parts.lastObject.bytes,&current,AT_SYMLINK_NOFOLLOW)) {
            int code=errno;return [self stop:@"fileRecheck" domain:@"posix" code:code];
        }
        if (!axs_cachekeeper_inspection_stable(current,expected))
            return [self stop:@"fileRecheck" domain:@"identity" code:0];
        return [self validate] && [self validateChain:parents];
    } @finally {for (AxsCacheKeeperInspectionDirectory *node in parents) [node close];}
}
- (AxsCacheKeeperInspectionEntry *)nextEntry {
    // EOF unwinding and kernel dot entries are bounded by the depth limit. An
    // invalid record returns immediately so advance owns its work/cancel budget.
    for (NSUInteger step=0;step<AxsCacheKeeperInspectionDepthLimit+3 && !_complete && _chain.count;step++) {
        if (![self validate]) return nil;
        AxsCacheKeeperInspectionDirectory *parent=_chain.lastObject;errno=0;
        struct dirent *raw=readdir(parent.stream);int code=errno;
        if (!raw) {
            if (code) {[self stop:@"enumerate" domain:@"posix" code:code];return nil;}
            struct stat final;
            if (fstat(parent.descriptor,&final)) {code=errno;[self stop:@"ancestorRecheck" domain:@"posix" code:code];return nil;}
            if (!axs_cachekeeper_inspection_stable(final,parent.identity)) {
                [self stop:@"ancestorRecheck" domain:@"identity" code:0];return nil;
            }
            [parent close];[_chain removeLastObject];if (!_chain.count) _complete=YES;continue;
        }
        size_t length=raw->d_namlen;
        BOOL bounded=length>0 && length<=AxsCacheKeeperInspectionNameByteLimit && length<sizeof(raw->d_name) &&
            raw->d_reclen<=sizeof(*raw) && offsetof(struct dirent,d_name)+length+1<=raw->d_reclen;
        if (bounded && raw->d_name[length]==0 && !memchr(raw->d_name,0,length) &&
            ((length==1 && raw->d_name[0]=='.') || (length==2 && !memcmp(raw->d_name,"..",2)))) continue;
        NSData *component=bounded ? [NSData dataWithBytes:raw->d_name length:length+1] : nil;
        if (!axs_cachekeeper_inspection_raw_component(component)) {
            self.invalidNameRecords++;self.failure(@"entryName",@"posix",EINVAL);return nil;
        }
        NSString *name=[NSFileManager.defaultManager stringWithFileSystemRepresentation:component.bytes length:length];
        const char *shown=name.length ? name.fileSystemRepresentation : NULL;
        BOOL display=name.length && shown && strlen(shown)==length && !memcmp(shown,component.bytes,length) &&
            ![name containsString:@"/"] && [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location==NSNotFound;
        if (!display) {self.nameDisplayOmitted++;name=@"<名称未展示>";}
        AxsCacheKeeperInspectionEntry *entry=[AxsCacheKeeperInspectionEntry new];entry.parent=parent;entry.name=name;
        entry.rawName=component;entry.rawComponents=[parent.rawComponents arrayByAddingObject:component];
        entry.displayOperable=parent.displayOperable && display;
        entry.relative=parent.relative.length ? [parent.relative stringByAppendingFormat:@"/%@",name] : name;return entry;
    }
    return nil;
}
- (BOOL)statEntry:(AxsCacheKeeperInspectionEntry *)entry info:(struct stat *)info {
    if (![self validate]) return NO;
    if (fstatat(entry.parent.descriptor,entry.rawName.bytes,info,AT_SYMLINK_NOFOLLOW)) {
        int code=errno;self.failure(@"entryStat",@"posix",code);return NO;
    }
    return YES;
}
- (BOOL)entry:(AxsCacheKeeperInspectionEntry *)entry matches:(struct stat)expected {
    if (![self validate]) return NO;
    struct stat current;
    if (fstatat(entry.parent.descriptor,entry.rawName.bytes,&current,AT_SYMLINK_NOFOLLOW)) {
        int code=errno;return [self stop:@"fileRecheck" domain:@"posix" code:code];
    }
    if (!axs_cachekeeper_inspection_stable(current,expected)) return [self stop:@"fileRecheck" domain:@"identity" code:0];
    return YES;
}
- (void)descend:(AxsCacheKeeperInspectionEntry *)entry info:(struct stat)expected {
    if (_chain.count>AxsCacheKeeperInspectionDepthLimit) {self.failure(@"depthLimit",@"limit",0);return;}
    if (![self validate]) return;
    if (expected.st_dev!=_identity.st_dev) {[self stop:@"ancestorRecheck" domain:@"identity" code:0];return;}
    int fd=openat(entry.parent.descriptor,entry.rawName.bytes,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if (fd<0) {int code=errno;self.failure(@"openDirectory",@"posix",code);return;}
    struct stat opened,after;
    if (fstat(fd,&opened) || fstatat(entry.parent.descriptor,entry.rawName.bytes,&after,AT_SYMLINK_NOFOLLOW)) {
        int code=errno;close(fd);self.failure(@"openDirectory",@"posix",code);return;
    }
    if (!S_ISDIR(opened.st_mode) || !axs_cachekeeper_inspection_identity(expected,opened) ||
        !axs_cachekeeper_inspection_identity(opened,after)) {
        close(fd);[self stop:@"ancestorRecheck" domain:@"identity" code:0];return;
    }
    AxsCacheKeeperInspectionDirectory *node=[AxsCacheKeeperInspectionDirectory new];
    node.descriptor=fd;node.name=entry.name;node.relative=entry.relative;node.identity=opened;node.stream=fdopendir(fd);
    node.rawName=entry.rawName;node.rawComponents=entry.rawComponents;node.displayOperable=entry.displayOperable;
    if (!node.stream) {int code=errno;[node close];self.failure(@"enumerate",@"posix",code);return;}
    [_chain addObject:node];[self validate];
}
@end

@interface AxsCacheKeeperInspection ()
@property(nonatomic,copy) NSString *root;
@property(nonatomic,strong) AxsCacheKeeperInspectionWalker *walker;
@property(nonatomic,readwrite) BOOL complete;
@property(nonatomic) BOOL cancelled;
@property(nonatomic) NSUInteger files;
@property(nonatomic) NSUInteger failures;
@property(nonatomic) NSUInteger links;
@property(nonatomic) NSUInteger hidden;
@property(nonatomic) NSUInteger changed;
@property(nonatomic) NSUInteger markers;
@property(nonatomic) unsigned long long bytes;
@property(nonatomic,strong) NSMutableDictionary *types;
@property(nonatomic,strong) NSMutableDictionary *ages;
@property(nonatomic,strong) NSMutableArray *largest;
@property(nonatomic,strong) NSMutableArray *largestHardLinks;
@property(nonatomic,copy) NSString *error;
@property(nonatomic,copy) NSDictionary *readFailure;
@property(nonatomic,copy) NSDictionary *mainReadFailure;
@property(nonatomic,copy) NSDictionary *twinReadFailure;
@property(nonatomic) NSUInteger invalidNameRecords;
@property(nonatomic) NSUInteger twinInvalidNameRecords;
@property(nonatomic) NSUInteger twinNameDisplayOmitted;
@property(nonatomic,strong) NSDate *started;
// 硬链接孪生定位：主枚举只记身份（设备+inode），枚举完成后分批扫搜索根找孪生。
@property(nonatomic,copy) NSArray<NSDictionary *> *searchRoots;
@property(nonatomic,strong) NSMutableArray *linkFiles;
@property(nonatomic,strong) NSMutableDictionary *linkIndex;
@property(nonatomic) NSUInteger hardLinks;
@property(nonatomic) NSUInteger symlinks;
@property(nonatomic) BOOL linkFilesTruncated;
@property(nonatomic) BOOL twinPhase;
@property(nonatomic) NSUInteger searchIndex;
@property(nonatomic) NSUInteger sourceRecheckIndex;
@property(nonatomic,strong) NSDictionary *searchCurrent;
@property(nonatomic,strong) AxsCacheKeeperInspectionWalker *searchWalker;
@property(nonatomic,strong) NSMutableArray *twinEntries;
@property(nonatomic,strong) NSMutableSet *twinnedKeys;
@property(nonatomic,strong) NSMutableSet *seenTwins;
@property(nonatomic,strong) NSMutableDictionary *sourceDisplayCounts;
@property(nonatomic) unsigned long long twinBytes;
@property(nonatomic) NSUInteger twinScanned;
@property(nonatomic) BOOL twinTruncated;
@property(nonatomic) BOOL twinDisplayTruncated;
@property(nonatomic) NSUInteger twinSkipped;
@property(nonatomic) NSUInteger twinHidden;
@property(nonatomic) NSUInteger searchLimit;
@property(nonatomic,copy) int (^searchStat)(const char *,struct stat *);
@end

static NSString *axs_cachekeeper_inode_key(dev_t device, ino_t inode) {
    return [NSString stringWithFormat:@"%llu:%llu",(unsigned long long)device,(unsigned long long)inode];
}

static NSString *axs_cachekeeper_header_kind(const unsigned char *data, NSUInteger length, off_t size) {
    if (!size) return @"空文件";
    if (length>=16 && !memcmp(data,"SQLite format 3\0",16)) return @"SQLite 数据库";
    if (length>=6 && !memcmp(data,"bplist",6)) return @"二进制 plist";
    if (axs_cachekeeper_media_signature(data,length)) return @"媒体文件头";
    if ((length>=4 && !memcmp(data,"PK\003\004",4)) || (length>=2 && data[0]==0x1f && data[1]==0x8b) ||
        (length>=6 && !memcmp(data,"7z\xbc\xaf\x27\x1c",6)) || (length>=4 && !memcmp(data,"Rar!",4)) ||
        (length>=3 && !memcmp(data,"BZh",3)) || (length>=6 && !memcmp(data,"\xfd" "7zXZ\0",6))) return @"归档或压缩文件";
    NSData *sample=[NSData dataWithBytes:data length:length];
    if (size==(off_t)length && [NSJSONSerialization JSONObjectWithData:sample options:NSJSONReadingFragmentsAllowed error:nil]) return @"JSON 数据";
    NSString *text=[[NSString alloc] initWithData:sample encoding:NSUTF8StringEncoding];
    if (text.length && !memchr(data,0,length)) return @"文本头特征（用途未定）";
    return @"未知二进制";
}

@implementation AxsCacheKeeperInspection
- (instancetype)initWithRoot:(NSString *)root {
    return [self initWithRoot:root searchRoots:@[@{@"path":root ?: @"",@"label":@"本目录"}]];
}
- (instancetype)initWithRoot:(NSString *)root searchRoots:(NSArray<NSDictionary *> *)searchRoots {
    return [self initWithRoot:root searchRoots:searchRoots searchLimit:100000 stat:nil];
}
- (instancetype)initWithRoot:(NSString *)root searchRoots:(NSArray<NSDictionary *> *)searchRoots searchLimit:(NSUInteger)searchLimit stat:(int (^)(const char *,struct stat *))statBlock {
    self=[super init];if (!self) return nil;
    _searchLimit=searchLimit;_searchStat=[statBlock copy];
    _root=[root copy];_types=[NSMutableDictionary new];_ages=[NSMutableDictionary new];_largest=[NSMutableArray new];_largestHardLinks=[NSMutableArray new];_started=NSDate.date;
    _searchRoots=[searchRoots count] ? [searchRoots copy] : @[@{@"path":root ?: @"",@"label":@"本目录"}];
    _linkFiles=[NSMutableArray new];_twinEntries=[NSMutableArray new];_twinnedKeys=[NSMutableSet new];_seenTwins=[NSMutableSet new];
    _sourceDisplayCounts=[NSMutableDictionary new];
    __weak typeof(self) weak=self;
    _walker=[[AxsCacheKeeperInspectionWalker alloc] initWithPath:root failure:^(NSString *stage,NSString *domain,int code) {
        [weak axs_cachekeeper_failure:stage domain:domain code:code twin:NO];
    }];
    _root=_walker.path ?: [root copy];if (_walker.complete) [self axs_cachekeeper_finish];
    return self;
}
- (void)axs_cachekeeper_finish {self.complete=YES;[self.walker close];[self.searchWalker close];}
- (void)cancel {self.cancelled=YES;[self axs_cachekeeper_finish];}
- (void)dealloc {[_walker close];[_searchWalker close];}
- (void)axs_cachekeeper_failure:(NSString *)stage domain:(NSString *)domain code:(int)code twin:(BOOL)twin {
    if (twin) self.twinSkipped++;
    else if ([domain isEqual:@"identity"]) self.changed++;
    else self.failures++;
    if (!self.readFailure) self.readFailure=@{@"stage":stage,@"errorDomain":domain,@"errorCode":@(code)};
    NSDictionary *failure=@{@"stage":stage,@"errorDomain":domain,@"errorCode":@(code)};
    if (twin) {if (!self.twinReadFailure) self.twinReadFailure=failure;}
    else if (!self.mainReadFailure) self.mainReadFailure=failure;
    if ([stage isEqual:@"entryName"]) {if (twin) self.twinInvalidNameRecords++;else self.invalidNameRecords++;}
    self.error=[NSString stringWithFormat:@"%@读取未完成：%@（%@/%d）",twin ? @"孪生搜索" : @"目录",stage,domain,code];
    if (!twin && [domain isEqual:@"identity"]) [self axs_cachekeeper_finish];
    if (self.failures+self.twinSkipped>=AxsCacheKeeperInspectionFailureLimit) {
        self.error=@"读取失败次数达到上限，已停止检测";[self axs_cachekeeper_finish];
    }
}
- (void)axs_cachekeeper_record_file:(NSDictionary *)file largest:(NSMutableArray *)largest {
    static const NSUInteger AxsCacheKeeperLargestFileLimit=10;
    [largest addObject:file];
    [largest sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b) { return [b[@"bytes"] compare:a[@"bytes"]]; }];
    if (largest.count>AxsCacheKeeperLargestFileLimit) [largest removeLastObject];
}
- (void)advance:(NSUInteger)limit {
    for (NSUInteger index=0;index<limit && !self.complete;index++) {
        @autoreleasepool {
            if (self.twinPhase) { [self axs_cachekeeper_advance_twin];continue; }
            AxsCacheKeeperInspectionEntry *entry=[self.walker nextEntry];
            if (self.complete) break;
            if (!entry) {
                if (!self.walker.complete) continue;
                if (self.linkFiles.count && self.searchRoots.count) { [self axs_cachekeeper_begin_twin];continue; }
                [self axs_cachekeeper_finish];break;
            }
            NSString *relative=entry.relative;
            if (axs_cachekeeper_inspection_raw_hidden(entry.rawComponents)) {self.hidden++;continue;}
            struct stat info;if (![self.walker statEntry:entry info:&info]) continue;
            if (S_ISLNK(info.st_mode)) { self.links++;self.symlinks++;continue; }
            if (S_ISREG(info.st_mode) && info.st_nlink!=1) {
                if (![self.walker entry:entry matches:info]) continue;
                self.links++;self.hardLinks++;
                // 大文件诊断覆盖所有已枚举硬链接，独立于孪生源的 100 条上限；不读取内容。
                [self axs_cachekeeper_record_file:@{@"path":relative,@"bytes":@(info.st_size),@"nlink":@(info.st_nlink),@"pathOperable":@(entry.displayOperable)} largest:self.largestHardLinks];
                if (self.linkFiles.count<100) {
                    // Only retained sources need later revalidation: one leaf stat
                    // and each ancestor's device/inode; no directory stays open.
                    NSMutableArray *ancestors=[NSMutableArray new];
                    for (NSUInteger depth=1;depth<self.walker.chain.count;depth++) {
                        struct stat ancestor=self.walker.chain[depth].identity;
                        [ancestors addObject:@[@(ancestor.st_dev),@(ancestor.st_ino)]];
                    }
                    [self.linkFiles addObject:@{@"path":relative,@"device":@(info.st_dev),@"inode":@(info.st_ino),@"nlink":@(info.st_nlink),@"bytes":@(info.st_size),
                        @"parentDevice":@(entry.parent.identity.st_dev),@"parentInode":@(entry.parent.identity.st_ino),@"rawName":entry.rawName,
                        @"rawComponents":entry.rawComponents,@"pathOperable":@(entry.displayOperable),
                        @"ancestors":[ancestors copy],@"stat":[NSValue valueWithBytes:&info objCType:@encode(struct stat)]}];
                } else self.linkFilesTruncated=YES;
                continue;
            }
            if (S_ISDIR(info.st_mode)) {
                if (axs_cachekeeper_data_marker(axs_cachekeeper_inspection_policy_component(entry.rawName))) self.markers++;
                [self.walker descend:entry info:info];
                continue;
            }
            if (!S_ISREG(info.st_mode)) continue;
            [self axs_cachekeeper_read_entry:entry info:info];
        }
    }
}
- (void)axs_cachekeeper_read_entry:(AxsCacheKeeperInspectionEntry *)entry info:(struct stat)info {
    if (![self.walker entry:entry matches:info]) return;
    int fd=openat(entry.parent.descriptor,entry.rawName.bytes,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    if (fd<0) {
        int code=errno;[self axs_cachekeeper_failure:@"openFile" domain:@"posix" code:code twin:NO];
        if (!self.complete) [self.walker entry:entry matches:info];return;
    }
    @try {
        struct stat opened,after;
        if (fstat(fd,&opened)) {int code=errno;[self axs_cachekeeper_failure:@"fileStat" domain:@"posix" code:code twin:NO];return;}
        if (!S_ISREG(opened.st_mode) || opened.st_nlink!=1 || opened.st_size<0 || !axs_cachekeeper_inspection_stable(info,opened)) {
            [self axs_cachekeeper_failure:@"fileRecheck" domain:@"identity" code:0 twin:NO];return;
        }
        if (![self.walker entry:entry matches:opened]) return;
        unsigned char sample[4096];ssize_t count=pread(fd,sample,sizeof(sample),0);int readError=count<0 ? errno : 0;
        if (count<0) [self axs_cachekeeper_failure:@"readHeader" domain:@"posix" code:readError twin:NO];
        if (self.complete) return;
        if (fstat(fd,&after)) {int code=errno;[self axs_cachekeeper_failure:@"fileStat" domain:@"posix" code:code twin:NO];return;}
        if (!axs_cachekeeper_inspection_stable(opened,after)) {
            [self axs_cachekeeper_failure:@"fileRecheck" domain:@"identity" code:0 twin:NO];return;
        }
        if (![self.walker entry:entry matches:after] || count<0) return;
        if (count!=MIN(opened.st_size,(off_t)sizeof(sample))) {
            [self axs_cachekeeper_failure:@"shortRead" domain:@"read" code:0 twin:NO];return;
        }
        NSString *kind=axs_cachekeeper_header_kind(sample,(NSUInteger)count,opened.st_size);
        if (axs_cachekeeper_data_marker(axs_cachekeeper_inspection_policy_component(entry.rawName))) {self.markers++;kind=@"数据或登录态名称特征";}
        NSDictionary *old=self.types[kind];
        self.types[kind]=@{@"count":@([old[@"count"] unsignedIntegerValue]+1),@"bytes":@([old[@"bytes"] unsignedLongLongValue]+opened.st_size)};
        self.files++;self.bytes+=opened.st_size;
        NSTimeInterval age=[self.started timeIntervalSince1970]-MAX(opened.st_mtimespec.tv_sec,MAX(opened.st_ctimespec.tv_sec,opened.st_birthtimespec.tv_sec));
        NSString *bucket=age<60 ? @"不足 60 秒" : age<86400 ? @"60 秒至 1 天" : age<30*86400 ? @"1 至 30 天" : @"30 天以上";
        self.ages[bucket]=@([self.ages[bucket] unsignedIntegerValue]+1);
        [self axs_cachekeeper_record_file:@{@"path":entry.relative,@"bytes":@(opened.st_size),@"type":kind,@"pathOperable":@(entry.displayOperable)} largest:self.largest];
    } @finally {close(fd);}
}
- (void)axs_cachekeeper_begin_twin {
    self.twinPhase=YES;
    self.linkIndex=[NSMutableDictionary new];
    for (NSDictionary *record in self.linkFiles) {
        NSString *key=axs_cachekeeper_inode_key([record[@"device"] unsignedLongLongValue],[record[@"inode"] unsignedLongLongValue]);
        NSMutableArray *records=self.linkIndex[key];
        if (!records) { records=[NSMutableArray new];self.linkIndex[key]=records; }
        [records addObject:record];
    }
    self.searchIndex=0;self.sourceRecheckIndex=0;
    [self axs_cachekeeper_open_search_root];
}
- (void)axs_cachekeeper_open_search_root {
    [self.searchWalker close];self.searchWalker=nil;self.searchCurrent=nil;
    while (!self.complete && self.searchIndex<self.searchRoots.count) {
        NSDictionary *candidate=self.searchRoots[self.searchIndex];
        self.searchIndex++;
        NSString *path=[candidate isKindOfClass:NSDictionary.class] ? candidate[@"path"] : nil;
        __weak typeof(self) weak=self;
        AxsCacheKeeperInspectionWalker *walker=[[AxsCacheKeeperInspectionWalker alloc] initWithPath:path failure:^(NSString *stage,NSString *domain,int code) {
            [weak axs_cachekeeper_failure:stage domain:domain code:code twin:YES];
        }];
        if (!walker.complete && !self.complete) {
            self.searchWalker=walker;
            self.searchCurrent=@{@"path":walker.path,@"label":[candidate[@"label"] isKindOfClass:NSString.class] ? candidate[@"label"] : @""};
            return;
        }
    }
}
- (BOOL)axs_cachekeeper_source_current:(NSDictionary *)source {
    if (![self.walker validateSource:source]) {[self axs_cachekeeper_finish];return NO;}
    return YES;
}
- (void)axs_cachekeeper_advance_twin {
    if (![self.walker validate]) {[self axs_cachekeeper_finish];return;}
    if (!self.searchWalker) {
        // Recheck the bounded source list even when no twin matched. One source
        // per advance step keeps cancellation bounded without rescanning a tree.
        if (self.sourceRecheckIndex<self.linkFiles.count)
            [self axs_cachekeeper_source_current:self.linkFiles[self.sourceRecheckIndex++]];
        else [self axs_cachekeeper_finish];
        return;
    }
    if (self.twinScanned>=self.searchLimit) {
        self.twinTruncated=YES;[self.searchWalker close];self.searchWalker=nil;return;
    }
    NSUInteger omitted=self.searchWalker.nameDisplayOmitted,invalid=self.searchWalker.invalidNameRecords;
    AxsCacheKeeperInspectionEntry *entry=[self.searchWalker nextEntry];
    self.twinNameDisplayOmitted+=self.searchWalker.nameDisplayOmitted-omitted;
    if (self.complete) return;
    if (!entry) {
        self.twinScanned+=self.searchWalker.invalidNameRecords-invalid;
        if (self.searchWalker.complete) [self axs_cachekeeper_open_search_root];return;
    }
    self.twinScanned++;
    if (axs_cachekeeper_inspection_raw_hidden(entry.rawComponents)) {self.twinHidden++;return;}
    struct stat info;if (![self.searchWalker statEntry:entry info:&info]) return;
    // Existing callers can still inject a search-stat failure. Its output never
    // replaces the identity established by fstatat against the held parent.
    if (self.searchStat) {
        struct stat supplied;
        const char *root=self.searchWalker.path.fileSystemRepresentation;
        NSMutableData *full=[NSMutableData dataWithBytes:root length:strlen(root)];
        for (NSData *part in entry.rawComponents) {[full appendBytes:"/" length:1];[full appendBytes:part.bytes length:part.length-1];}
        [full appendBytes:"\0" length:1];
        if (self.searchStat(full.bytes,&supplied)) {
            int code=errno;[self axs_cachekeeper_failure:@"entryStat" domain:@"posix" code:code twin:YES];return;
        }
        if (!axs_cachekeeper_inspection_stable(info,supplied)) {
            [self axs_cachekeeper_failure:@"fileRecheck" domain:@"identity" code:0 twin:YES];return;
        }
    }
    if (S_ISDIR(info.st_mode)) {[self.searchWalker descend:entry info:info];return;}
    if (!S_ISREG(info.st_mode) || info.st_nlink==1) return;
    if (![self.searchWalker entry:entry matches:info]) return;
    NSString *key=axs_cachekeeper_inode_key(info.st_dev,info.st_ino);
    NSArray *sources=self.linkIndex[key];
    if (!sources.count) return;
    for (NSDictionary *source in sources) {
        if (![self axs_cachekeeper_source_current:source] || ![self.searchWalker entry:entry matches:info]) return;
        if ([source[@"parentDevice"] unsignedLongLongValue]==(unsigned long long)entry.parent.identity.st_dev &&
            [source[@"parentInode"] unsignedLongLongValue]==(unsigned long long)entry.parent.identity.st_ino && [source[@"rawName"] isEqual:entry.rawName]) continue;
        NSArray *seen=@[source[@"rawComponents"],@(entry.parent.identity.st_dev),@(entry.parent.identity.st_ino),entry.rawName];
        if ([self.seenTwins containsObject:seen]) continue;
        NSUInteger existing=[self.sourceDisplayCounts[source[@"rawComponents"]] unsignedIntegerValue];
        // 展示截断（任务 7）：每源 3 条或总 50 条上限丢掉的孪生须标记，不能静默少报。
        if (existing>=3 || self.twinEntries.count>=50) { self.twinDisplayTruncated=YES;continue; }
        NSString *label=self.searchCurrent[@"label"] ?: @"";
        NSString *shown=[NSString stringWithFormat:@"%@/%@",label,entry.relative];
        [self.twinEntries addObject:@{@"source":source[@"path"],@"twin":shown,@"bytes":source[@"bytes"],
            @"sourceOperable":source[@"pathOperable"],@"twinOperable":@(entry.displayOperable)}];
        [self.seenTwins addObject:seen];
        self.sourceDisplayCounts[source[@"rawComponents"]]=@(existing+1);
        // 关联大小按 (设备, inode) 去重（任务 7）：同一 inode 的多个源路径只计一次，
        // 否则同目录双链接会把同一份数据算两遍。twinBytes 是逻辑关联大小，非实测释放空间。
        if (![self.twinnedKeys containsObject:key]) { [self.twinnedKeys addObject:key];self.twinBytes+=[source[@"bytes"] unsignedLongLongValue]; }
    }
}
- (NSDictionary *)report {
    BOOL covered=self.complete && !self.cancelled && !self.failures && !self.changed;
    // 孪生搜索完整性与主扫描分开报告（任务 7）：主扫描未完成时孪生源清单本身不完整，
    // 不能声称孪生已覆盖；无硬链接时孪生阶段不启动，各项计数为 0，完整性自然成立。
    BOOL twinCovered=covered && !self.twinSkipped && !self.twinHidden && !self.twinTruncated && !self.linkFilesTruncated && !self.twinDisplayTruncated &&
        !self.walker.nameDisplayOmitted && !self.twinNameDisplayOmitted;
    NSString *evidence=@"用途仍未确认；请结合文件类型与实际功能继续核查";
    if (self.markers || self.types[@"SQLite 数据库"] || self.types[@"二进制 plist"] || self.types[@"JSON 数据"])
        evidence=@"检出数据格式或数据名称特征；不代表整个目录都是必需数据，也不能直接清空";
    else if (covered && self.files && [self.types[@"媒体文件头"][@"count"] unsignedIntegerValue]==self.files && !self.hidden && !self.links)
        evidence=@"已读取的文件全部具有媒体头特征；媒体也可能是下载或用户内容，未证明可删";
    NSMutableDictionary *report=[@{@"complete":@(self.complete),@"cancelled":@(self.cancelled),@"coverageComplete":@(covered),@"files":@(self.files),@"bytes":@(self.bytes),
        @"failures":@(self.failures),@"changed":@(self.changed),@"links":@(self.links),@"hidden":@(self.hidden),
        @"hardLinks":@(self.hardLinks),@"symlinks":@(self.symlinks),@"linkTwins":[self.twinEntries copy],@"twinBytes":@(self.twinBytes),
        @"largestHardLinks":[self.largestHardLinks copy],
        @"twinCoverageComplete":@(twinCovered),@"twinFailures":@(self.twinSkipped),@"twinHidden":@(self.twinHidden),
        @"twinScanTruncated":@(self.twinTruncated),@"twinDisplayTruncated":@(self.twinDisplayTruncated),@"linkFilesTruncated":@(self.linkFilesTruncated),@"twinScanned":@(self.twinScanned),
        @"invalidNameRecords":@(self.invalidNameRecords),@"twinInvalidNameRecords":@(self.twinInvalidNameRecords),
        @"nameDisplayOmitted":@(self.walker.nameDisplayOmitted),@"twinNameDisplayOmitted":@(self.twinNameDisplayOmitted),
        @"types":[self.types copy],@"ages":[self.ages copy],@"largest":[self.largest copy],@"evidence":evidence,
        @"error":self.error ?: @"",@"started":self.started,@"updated":NSDate.date} mutableCopy];
    if (self.readFailure) report[@"inspectionReadFailure"]=self.readFailure;
    if (self.mainReadFailure) report[@"mainReadFailure"]=self.mainReadFailure;
    if (self.twinReadFailure) report[@"twinReadFailure"]=self.twinReadFailure;
    return report;
}
@end
