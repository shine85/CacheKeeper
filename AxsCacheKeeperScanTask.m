#import "AxsCacheKeeperScanTask.h"
#import "AxsCacheKeeperDirectories.h"
#import "AxsCacheKeeperFileAccess.h"
#import "AxsCacheKeeperRecords.h"
#import "AxsCacheKeeperInspection.h"
#include <dirent.h>
#include <string.h>

static const NSUInteger AxsCacheKeeperScanSliceEntries=512;
static const NSUInteger AxsCacheKeeperScanTaskEntries=2000000;
static const NSUInteger AxsCacheKeeperScanDepth=64;
static const NSUInteger AxsCacheKeeperScanActiveBatch=4;
static const NSTimeInterval AxsCacheKeeperScanTaskSeconds=300;

static BOOL AxsCacheKeeperScanSame(const struct stat *a,const struct stat *b) {
    return S_ISDIR(b->st_mode) && a->st_dev==b->st_dev && a->st_ino==b->st_ino;
}
static BOOL AxsCacheKeeperScanUnchanged(const struct stat *a,const struct stat *b) {
    return AxsCacheKeeperScanSame(a,b) && a->st_mtimespec.tv_sec==b->st_mtimespec.tv_sec &&
        a->st_mtimespec.tv_nsec==b->st_mtimespec.tv_nsec && a->st_ctimespec.tv_sec==b->st_ctimespec.tv_sec &&
        a->st_ctimespec.tv_nsec==b->st_ctimespec.tv_nsec;
}
// One observation set per app task spans all discovered roots. Logical bytes
// remain per path; first-observed regular-file allocation never counts an inode twice.
// A two-element NSArray can hash by count. Hash the identity bytes and still
// compare the full device/inode pair for equality, including across roots.
static NSData *AxsCacheKeeperScanInodeKey(dev_t device,ino_t inode) {
    const uint64_t identity[2]={(uint64_t)device,(uint64_t)inode};
    return [NSData dataWithBytes:identity length:sizeof(identity)];
}
#if defined(AXS_CACHEKEEPER_SCAN_TESTING)
NSUInteger axs_cachekeeper_scan_test_inode_hash(dev_t device,ino_t inode) {
    return AxsCacheKeeperScanInodeKey(device,inode).hash;
}
#endif
@interface AxsCacheKeeperScanAllocation : NSObject
@property(nonatomic,strong) NSMutableDictionary *inodes;
@property(nonatomic) NSUInteger budget,duplicates,untracked;
@property(nonatomic) unsigned long long bytes;
@property(nonatomic,copy) NSString *failure;
- (instancetype)initWithLimit:(NSUInteger)limit;
- (void)observe:(const struct stat *)info;
- (NSDictionary *)snapshotComplete:(BOOL)complete baseline:(NSDictionary *)baseline;
@end
@implementation AxsCacheKeeperScanAllocation
- (instancetype)initWithLimit:(NSUInteger)limit {
    if ((self=[super init])) {_inodes=[NSMutableDictionary new];_budget=MIN(MAX(limit,(NSUInteger)1),(NSUInteger)65536);}
    return self;
}
- (void)observe:(const struct stat *)info {
    NSData *key=AxsCacheKeeperScanInodeKey(info->st_dev,info->st_ino);
    NSArray *sample=@[@(info->st_size),@(info->st_blocks),@(info->st_nlink),@(info->st_mtimespec.tv_sec),
        @(info->st_mtimespec.tv_nsec),@(info->st_ctimespec.tv_sec),@(info->st_ctimespec.tv_nsec)];
    NSArray *old=_inodes[key];
    if (old) {_duplicates++;if (![old isEqual:sample]) _failure=@"invalidMetadata";return;}
    if (info->st_size<0 || info->st_blocks<0 || (uint64_t)info->st_blocks>9007199254740991ULL/512 ||
        _bytes>9007199254740991ULL-(uint64_t)info->st_blocks*512) {
        _failure=@"invalidMetadata";_untracked++;return;
    }
    if (_inodes.count>=_budget) {if (!_failure) _failure=@"inodeLimit";_untracked++;return;}
    _inodes[key]=sample;_bytes+=(uint64_t)info->st_blocks*512;
}
- (NSDictionary *)snapshotComplete:(BOOL)complete baseline:(NSDictionary *)baseline {
    return @{@"schemaVersion":@1,@"scope":@"taskUniqueRegularFileInodeFirstObservation",
        @"state":_failure ?: (complete ? @"complete" : @"partial"),@"inodeBudget":@(_budget),
        @"allocatedBytes":@(_bytes-[baseline[@"allocatedBytes"] unsignedLongLongValue]),
        @"uniqueFiles":@(_inodes.count-[baseline[@"uniqueFiles"] unsignedIntegerValue]),
        @"duplicateFiles":@(_duplicates-[baseline[@"duplicateFiles"] unsignedIntegerValue]),
        @"untrackedFiles":@(_untracked-[baseline[@"untrackedFiles"] unsignedIntegerValue])};
}
@end
#if defined(AXS_CACHEKEEPER_SCAN_TESTING)
NSDictionary *axs_cachekeeper_scan_allocation_test_stats(const struct stat *samples,NSUInteger count,NSUInteger limit) {
    AxsCacheKeeperScanAllocation *allocation=[[AxsCacheKeeperScanAllocation alloc] initWithLimit:limit];
    for(NSUInteger index=0;index<count;index++) [allocation observe:&samples[index]];
    return [allocation snapshotComplete:YES baseline:nil];
}
#endif
@interface AxsCacheKeeperScanCursor ()
- (instancetype)initWithRoot:(NSURL *)root entryLimit:(NSUInteger)limit depthLimit:(NSUInteger)depth allocation:(AxsCacheKeeperScanAllocation *)allocation;
- (instancetype)initWithRoot:(NSURL *)root entryLimit:(NSUInteger)limit depthLimit:(NSUInteger)depth
                 allocation:(AxsCacheKeeperScanAllocation *)allocation metadataObserver:(AxsCacheKeeperScanMetadataObserver)observer;
@end

@interface AxsCacheKeeperScanFrame : NSObject {
@public DIR *directory;struct stat identity;
}
@property(nonatomic,strong) NSData *name;
@property(nonatomic,copy) NSArray<NSData *> *observerComponents;
@end
@implementation AxsCacheKeeperScanFrame
- (void)dealloc {if(directory) closedir(directory);}
@end

@implementation AxsCacheKeeperScanCursor {
    NSURL *_root;NSMutableArray<AxsCacheKeeperScanFrame *> *_stack;
    NSMutableDictionary *_diagnostics;NSString *_state;struct stat _identity;
    unsigned long long _bytes;NSUInteger _limit,_depth;
    AxsCacheKeeperScanAllocation *_allocation;NSDictionary *_allocationBaseline;
    AxsCacheKeeperScanMetadataObserver _metadataObserver;
}
- (instancetype)initWithRoot:(NSURL *)root entryLimit:(NSUInteger)limit depthLimit:(NSUInteger)depth {
    return [self initWithRoot:root entryLimit:limit depthLimit:depth allocation:[[AxsCacheKeeperScanAllocation alloc] initWithLimit:65536]];
}
- (instancetype)initWithRoot:(NSURL *)root entryLimit:(NSUInteger)limit depthLimit:(NSUInteger)depth metadataObserver:(AxsCacheKeeperScanMetadataObserver)observer {
    // Observer mode has its own all-entry accumulator; do not retain a second
    // regular-file inode table. A nil observer preserves the legacy initializer.
    return [self initWithRoot:root entryLimit:limit depthLimit:depth
        allocation:observer ? nil : [[AxsCacheKeeperScanAllocation alloc] initWithLimit:65536] metadataObserver:observer];
}
#if defined(AXS_CACHEKEEPER_SCAN_TESTING)
- (instancetype)initWithRoot:(NSURL *)root entryLimit:(NSUInteger)limit depthLimit:(NSUInteger)depth allocationLimit:(NSUInteger)allocationLimit {
    return [self initWithRoot:root entryLimit:limit depthLimit:depth allocation:[[AxsCacheKeeperScanAllocation alloc] initWithLimit:allocationLimit]];
}
#endif
- (instancetype)initWithRoot:(NSURL *)root entryLimit:(NSUInteger)limit depthLimit:(NSUInteger)depth allocation:(AxsCacheKeeperScanAllocation *)allocation {
    return [self initWithRoot:root entryLimit:limit depthLimit:depth allocation:allocation metadataObserver:nil];
}
- (instancetype)initWithRoot:(NSURL *)root entryLimit:(NSUInteger)limit depthLimit:(NSUInteger)depth allocation:(AxsCacheKeeperScanAllocation *)allocation metadataObserver:(AxsCacheKeeperScanMetadataObserver)observer {
    if (!(self=[super init])) return nil;
    _allocation=allocation;_allocationBaseline=[allocation snapshotComplete:NO baseline:nil];
    _root=root;_limit=limit;_depth=MIN(MAX(depth,(NSUInteger)1),AxsCacheKeeperScanDepth);
    _stack=[NSMutableArray new];_diagnostics=axs_cachekeeper_scan_diagnostics_new();_state=@"running";
    if([(id)observer isKindOfClass:NSNull.class]) {[self axs_cachekeeper_fail:@"readError" code:EINVAL stat:NO];return self;}
    _metadataObserver=[observer copy];
    struct stat original,opened;
    if (!root.isFileURL || lstat(root.fileSystemRepresentation,&original)) { [self axs_cachekeeper_fail:@"readError" code:errno ?: EINVAL stat:YES];return self; }
    if(_metadataObserver && !S_ISDIR(original.st_mode)) {[self axs_cachekeeper_fail:@"readError" code:ENOTDIR stat:NO];return self;}
    int fd=axs_cachekeeper_open_directory(root.path);
    if(fd<0) { [self axs_cachekeeper_fail:@"readError" code:errno stat:NO];return self; }
    if(fstat(fd,&opened) || !AxsCacheKeeperScanSame(&original,&opened)) {close(fd);[self axs_cachekeeper_fail:@"identityChanged" code:ESTALE stat:NO];return self;}
    if(_metadataObserver && !AxsCacheKeeperScanUnchanged(&original,&opened)) {close(fd);[self axs_cachekeeper_fail:@"identityChanged" code:ESTALE stat:NO];return self;}
    DIR *directory=fdopendir(fd);
    if(!directory) {int code=errno;close(fd);[self axs_cachekeeper_fail:@"readError" code:code stat:NO];return self;}
    _identity=opened;AxsCacheKeeperScanFrame *frame=[AxsCacheKeeperScanFrame new];frame->directory=directory;frame->identity=opened;[_stack addObject:frame];
    if(_metadataObserver) frame.observerComponents=@[];
    if(_metadataObserver) _metadataObserver(&opened,@[]);
    return self;
}
- (void)axs_cachekeeper_fail:(NSString *)state code:(int)code stat:(BOOL)statFailure {
    axs_cachekeeper_scan_count(_diagnostics,statFailure ? @"statErrors" : @"enumerationErrors",1);
    axs_cachekeeper_scan_error(_diagnostics,@"home",statFailure ? @"entryStat" : @"enumerate",
        [state isEqual:@"identityChanged"] ? @"identityChanged" : (code==EACCES || code==EPERM ? @"permissionDenied" : @"readFailure"),@"posix",MAX(0,MIN(code,255)),1);
    [self stopWithState:state];
}
- (BOOL)axs_cachekeeper_validate {
    struct stat current;
    if(lstat(_root.fileSystemRepresentation,&current) || !AxsCacheKeeperScanUnchanged(&_identity,&current)) return NO;
    for(NSUInteger i=0;i<_stack.count;i++) {
        AxsCacheKeeperScanFrame *frame=_stack[i];
        if(fstat(dirfd(frame->directory),&current) || !AxsCacheKeeperScanUnchanged(&frame->identity,&current)) return NO;
        if(i && (fstatat(dirfd(_stack[i-1]->directory),frame.name.bytes,&current,AT_SYMLINK_NOFOLLOW) || !AxsCacheKeeperScanSame(&frame->identity,&current))) return NO;
    }
    return YES;
}
- (void)advanceEntries:(NSUInteger)entries seconds:(NSTimeInterval)seconds {
    if(![_state isEqual:@"running"]) return;
    if(![self axs_cachekeeper_validate]) {[self axs_cachekeeper_fail:@"identityChanged" code:ESTALE stat:NO];return;}
    NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+MAX(0,seconds);
    NSUInteger visited=0;
    while(_stack.count && visited<entries && NSProcessInfo.processInfo.systemUptime<deadline) { @autoreleasepool {
        AxsCacheKeeperScanFrame *frame=_stack.lastObject;errno=0;struct dirent *entry=readdir(frame->directory);
        if(!entry) {
            int code=errno;struct stat current;
            if(code) {[self axs_cachekeeper_fail:@"readError" code:code stat:NO];break;}
            if(fstat(dirfd(frame->directory),&current) || !AxsCacheKeeperScanUnchanged(&frame->identity,&current)) {[self axs_cachekeeper_fail:@"identityChanged" code:ESTALE stat:NO];break;}
            [_stack removeLastObject];continue;
        }
        if(!strcmp(entry->d_name,".") || !strcmp(entry->d_name,"..")) continue;
        if([_diagnostics[@"entriesVisited"] unsignedLongLongValue]>=_limit) {[self stopWithState:@"entryLimit"];break;}
        visited++;axs_cachekeeper_scan_count(_diagnostics,@"entriesVisited",1);
        struct stat info;
        if(fstatat(dirfd(frame->directory),entry->d_name,&info,AT_SYMLINK_NOFOLLOW)) {[self axs_cachekeeper_fail:@"readError" code:errno stat:YES];break;}
        NSArray<NSData *> *components=nil;
        if(_metadataObserver) {
            NSData *name=[NSData dataWithBytes:entry->d_name length:strlen(entry->d_name)];
            components=[frame.observerComponents arrayByAddingObject:name];_metadataObserver(&info,components);
            if(![_state isEqual:@"running"]) break;
        }
        if(S_ISDIR(info.st_mode)) {
            if(_stack.count>=_depth) {[self stopWithState:@"depthLimit"];break;}
            int fd=openat(dirfd(frame->directory),entry->d_name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
            if(fd<0) {[self axs_cachekeeper_fail:@"readError" code:errno stat:NO];break;}
            struct stat opened;
            if(fstat(fd,&opened) || !AxsCacheKeeperScanSame(&info,&opened)) {close(fd);[self axs_cachekeeper_fail:@"identityChanged" code:ESTALE stat:NO];break;}
            if(_metadataObserver && !AxsCacheKeeperScanUnchanged(&info,&opened)) {close(fd);[self axs_cachekeeper_fail:@"identityChanged" code:ESTALE stat:NO];break;}
            DIR *directory=fdopendir(fd);
            if(!directory) {int code=errno;close(fd);[self axs_cachekeeper_fail:@"readError" code:code stat:NO];break;}
            AxsCacheKeeperScanFrame *child=[AxsCacheKeeperScanFrame new];child->directory=directory;child->identity=opened;
            child.name=[NSData dataWithBytes:entry->d_name length:strlen(entry->d_name)+1];[_stack addObject:child];
            if(_metadataObserver) child.observerComponents=components;
        } else if(S_ISREG(info.st_mode)) {
            if(!_metadataObserver) [_allocation observe:&info];
            if(info.st_size<0 || UINT64_MAX-_bytes<(uint64_t)info.st_size) {[self axs_cachekeeper_fail:@"readError" code:EOVERFLOW stat:YES];break;}
            _bytes+=(uint64_t)info.st_size;
        }
    } }
    if([_state isEqual:@"running"]) {
        // Recheck after the last entry too; otherwise a rename during a slice could publish success.
        if(![self axs_cachekeeper_validate]) [self axs_cachekeeper_fail:@"identityChanged" code:ESTALE stat:NO];
        else if(!_stack.count) _state=@"complete";
    }
}
- (void)stopWithState:(NSString *)state {
    if(![_state isEqual:@"running"]) return;
    _state=[state copy];_diagnostics[@"measurementComplete"]=@NO;
    if([state isEqual:@"entryLimit"] || [state isEqual:@"depthLimit"]) _diagnostics[@"entryLimitExceeded"]=@YES;
    if([state isEqual:@"timeLimit"]) _diagnostics[@"timeBudgetExceeded"]=@YES;
    [_stack removeAllObjects];
}
- (NSString *)state {return _state;}
- (NSUInteger)openDirectoryCount {return _stack.count;}
- (NSDictionary *)result {
    NSMutableDictionary *diagnostics=[_diagnostics mutableCopy];diagnostics[@"measurementComplete"]=@([_state isEqual:@"complete"]);
    return @{@"bytes":@(_bytes),@"complete":diagnostics[@"measurementComplete"],@"scanDiagnostics":diagnostics,
        @"allocationObservation":[_allocation snapshotComplete:[_state isEqual:@"complete"] baseline:_allocationBaseline] ?: @{}};
}
@end

@interface AxsCacheKeeperScanTask : NSObject
@property(nonatomic,copy) NSString *bundle;
@property(nonatomic,copy) NSString *token;
@property(nonatomic,copy) NSString *state;
@property(nonatomic,copy) NSString *error;
@property(nonatomic,strong) NSDictionary *context;
@property(nonatomic,strong) NSDictionary *old;
@property(nonatomic,strong) NSDictionary *discovery;
@property(nonatomic,strong) NSArray *candidates;
@property(nonatomic,strong) NSMutableArray *rows;
@property(nonatomic,strong) AxsCacheKeeperScanCursor *cursor;
@property(nonatomic,strong) AxsCacheKeeperScanAllocation *allocation;
@property(nonatomic) NSUInteger index;
@property(nonatomic) NSUInteger slices;
@property(nonatomic) NSUInteger entries;
@property(nonatomic) NSTimeInterval started;
@property(nonatomic) NSTimeInterval lastPublished;
@property(nonatomic) BOOL batch;
- (void)stop:(NSString *)state;
- (NSDictionary *)snapshot;
@end
static NSString *AxsCacheKeeperScanMessage(NSString *state) {
    NSDictionary *messages=@{@"running":@"正在分片计量，当前容量为部分结果",@"partial":@"部分目录无法完整计量，结果不完整",
        @"cancelled":@"检测已取消，保留部分结果",@"superseded":@"已由新请求替换，旧任务停止",@"interrupted":@"检测因服务重启中断，请重新检测",
        @"identityChanged":@"容器或目录在计量期间变化，已停止，需重新检测",@"entryLimit":@"达到条目总上限，保留部分结果",
        @"depthLimit":@"达到目录深度/句柄上限，保留部分结果",@"timeLimit":@"达到本次任务总时间上限，保留部分结果",
        @"readError":@"目录读取失败，保留部分结果",@"saveFailed":@"检测结果保存失败；本次计量已停止，未记为完成"};
    return messages[state] ?: @"";
}
@implementation AxsCacheKeeperScanTask
- (void)stop:(NSString *)state {
    self.state=state;[self.cursor stopWithState:state];
    if(self.cursor) {
        NSMutableDictionary *row=[self.cursor.result mutableCopy];NSDictionary *candidate=self.candidates[self.index];
        row[@"path"]=candidate[@"path"];row[@"manageable"]=@(![candidate[@"readOnly"] boolValue]);
        row[@"scanDiagnostics"]=axs_cachekeeper_scan_scope(row[@"scanDiagnostics"],candidate[@"scope"]);
        [self.rows addObject:row];self.entries+=[row[@"scanDiagnostics"][@"entriesVisited"] unsignedIntegerValue];self.cursor=nil;
    }
}
- (NSDictionary *)snapshot {
    NSMutableArray *rows=[self.rows mutableCopy];NSMutableDictionary *diagnostics=[self.discovery mutableCopy];
    if(self.cursor) {
        NSDictionary *candidate=self.candidates[self.index];NSMutableDictionary *row=[self.cursor.result mutableCopy];
        row[@"path"]=candidate[@"path"];row[@"manageable"]=@(![candidate[@"readOnly"] boolValue]);
        row[@"scanDiagnostics"]=axs_cachekeeper_scan_scope(row[@"scanDiagnostics"],candidate[@"scope"]);[rows addObject:row];
    }
    for(NSDictionary *row in rows) axs_cachekeeper_scan_merge(diagnostics,row[@"scanDiagnostics"]);
    BOOL complete=[self.state isEqual:@"complete"] && [diagnostics[@"measurementComplete"] boolValue];
    diagnostics[@"measurementComplete"]=@(complete);
    if([self.state isEqual:@"entryLimit"] || [self.state isEqual:@"depthLimit"]) diagnostics[@"entryLimitExceeded"]=@YES;
    if([self.state isEqual:@"timeLimit"]) diagnostics[@"timeBudgetExceeded"]=@YES;
    NSString *message=AxsCacheKeeperScanMessage(self.state);
    if(self.error.length) message=[message stringByAppendingFormat:@"%@%@",message.length ? @"；" : @"",self.error];
    NSMutableDictionary *groups=[NSMutableDictionary new];for(NSString *key in self.context[@"groups"]) groups[key]=[self.context[@"groups"][key] path];
    return @{@"bundle":self.bundle,@"token":self.token,@"home":[self.context[@"home"] path] ?: @"",@"groups":groups,
        @"rows":rows,@"previousRows":self.old[@"rows"] ?: @[],@"recentScans":axs_cachekeeper_recent_scans(self.old),
        @"updated":NSDate.date,@"error":message,@"complete":@(complete),@"scanDiagnostics":diagnostics,
        @"allocationObservation":[self.allocation snapshotComplete:complete baseline:nil],
        @"scanProgress":@{@"state":self.state,@"slices":@(self.slices),@"entriesVisited":diagnostics[@"entriesVisited"],
            @"rootsCompleted":@(self.index),@"rootsTotal":@(self.candidates.count),@"entryLimit":@(AxsCacheKeeperScanTaskEntries),
            @"sliceEntryLimit":@(AxsCacheKeeperScanSliceEntries),@"maxOpenDirectories":@(AxsCacheKeeperScanDepth),@"wallTimeLimitSeconds":@(AxsCacheKeeperScanTaskSeconds)}};
}
@end

@implementation AxsCacheKeeperScanService {
    NSString *_folder,*_singleToken,*_batchToken;NSDictionary *(^_resolver)(NSString *);BOOL (^_writer)(NSDictionary *,NSString *);
    AxsCacheKeeperScanTask *_single;NSMutableArray<AxsCacheKeeperScanTask *> *_batchTasks;
    NSUInteger _turn;BOOL _recovered;NSDictionary *_pendingBatch;
    NSData *_historyBytes;NSDictionary *_historyValue;NSUInteger _historyDecodeCount;
    NSTimeInterval _historyPublished;
    NSMutableDictionary *_performance;NSDate *_performanceStarted;
    NSTimeInterval _performanceStart,_performancePublished;BOOL _performanceActive,_performanceHasWork;
}
- (instancetype)initWithFolder:(NSString *)folder resolver:(NSDictionary *(^)(NSString *))resolver writer:(BOOL (^)(NSDictionary *,NSString *))writer {
    if((self=[super init])) {_folder=[folder copy];_resolver=[resolver copy];_writer=[writer copy];_batchTasks=[NSMutableArray new];}return self;
}
- (NSString *)path:(NSString *)name {return [_folder stringByAppendingPathComponent:name];}
- (NSTimeInterval)axs_cachekeeper_now {
#if defined(AXS_CACHEKEEPER_SCAN_TESTING)
    if(self.axs_cachekeeper_clock) return self.axs_cachekeeper_clock();
#endif
    return NSProcessInfo.processInfo.systemUptime;
}
- (void)axs_cachekeeper_count:(NSString *)key amount:(double)amount {
    if(_performance) _performance[key]=@(MIN(9007199254740991.0,MAX(0,[_performance[key] doubleValue]+amount)));
}
- (void)axs_cachekeeper_duration:(NSString *)key since:(NSTimeInterval)start {
    [self axs_cachekeeper_count:key amount:MAX(0,NSProcessInfo.processInfo.systemUptime-start)*1000];
}
- (BOOL)write:(NSDictionary *)record name:(NSString *)name {
    if([name isEqual:@"batch.plist"]) {
        NSMutableDictionary *dated=[record mutableCopy];dated[@"updated"]=NSDate.date;
        if([dated[@"scanState"] isEqual:@"running"] && !dated[@"started"]) dated[@"started"]=dated[@"updated"];
        if([@[@"complete",@"partial",@"cancelled",@"saveFailed"] containsObject:dated[@"scanState"] ?: @""]) dated[@"finished"]=dated[@"updated"];
        record=dated;
    }
    BOOL history=[name isEqual:@"snapshots.plist"];NSTimeInterval start=NSProcessInfo.processInfo.systemUptime;
    BOOL saved=[self axs_cachekeeper_write:record name:name];
    if(history) {
        [self axs_cachekeeper_duration:@"historyWriteMilliseconds" since:start];
        [self axs_cachekeeper_count:saved ? @"historyWrites" : @"historyWriteFailures" amount:1];
        if(saved) _historyPublished=[self axs_cachekeeper_now];
    }
    return saved;
}
- (BOOL)axs_cachekeeper_write:(NSDictionary *)record name:(NSString *)name {
    if(_writer) return _writer(record,[self path:name]);
    NSError *error=nil;BOOL saved=NO;
    if([name isEqual:@"snapshots.plist"]) {
        NSData *data=[NSPropertyListSerialization dataWithPropertyList:record format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
        saved=data && [data writeToFile:[self path:name] options:NSDataWritingAtomic error:&error];
        // Only persisted bytes are reusable. The next read still compares the actual file.
        if(saved) {_historyBytes=data;_historyValue=[record copy];}
    } else saved=[record writeToURL:[NSURL fileURLWithPath:[self path:name]] error:&error];
    if(!saved) NSLog(@"[CacheKeeper] 计量记录保存失败 (%@/%ld)",error.domain,(long)error.code);return saved;
}
- (NSDictionary *)axs_cachekeeper_readHistory:(NSError **)error {
    NSTimeInterval start=NSProcessInfo.processInfo.systemUptime;
    NSDictionary *result=[self axs_cachekeeper_decodeHistory:error];
    [self axs_cachekeeper_duration:@"historyReadMilliseconds" since:start];
    [self axs_cachekeeper_count:@"historyReads" amount:1];
#if defined(AXS_CACHEKEEPER_SCAN_TESTING)
    if(self.axs_cachekeeper_didReadHistory) self.axs_cachekeeper_didReadHistory();
#endif
    return result;
}
- (NSDictionary *)axs_cachekeeper_decodeHistory:(NSError **)error {
    if(error) *error=nil;
    NSString *path=[self path:@"snapshots.plist"];struct stat info;NSError *failure=nil;
    if(stat(path.fileSystemRepresentation,&info)) {
        int code=errno;_historyBytes=nil;_historyValue=nil;
        if(code!=ENOENT && error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
        return nil;
    }
    NSData *data=S_ISREG(info.st_mode) ? [NSData dataWithContentsOfFile:path options:0 error:&failure] : nil;
    [self axs_cachekeeper_count:@"historyBytesRead" amount:data.length];
    if(data && [data isEqualToData:_historyBytes]) return _historyValue;
    _historyBytes=nil;_historyValue=nil;
    id value=nil;
    if(data) {_historyDecodeCount++;[self axs_cachekeeper_count:@"historyDecodes" amount:1];value=[NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:&failure];}
    if(!value || !axs_cachekeeper_records_valid(value,@"snapshots.plist")) {
        if(error) *error=failure ?: [NSError errorWithDomain:@"dev.local.cachekeeper.records" code:1 userInfo:@{NSLocalizedDescriptionKey:@"历史记录不可读或字段损坏，已保留原文件"}];
        return nil;
    }
    _historyBytes=data;_historyValue=value;return value;
}
#if defined(AXS_CACHEKEEPER_SCAN_TESTING)
- (NSUInteger)axs_cachekeeper_historyDecodeCount {return _historyDecodeCount;}
#endif
- (NSDictionary *)context:(NSString *)bundle {
    NSTimeInterval start=NSProcessInfo.processInfo.systemUptime;
    NSDictionary *provided=_resolver(bundle);NSMutableDictionary *context=[NSMutableDictionary new];
    NSURL *home=provided[@"home"];if([home isKindOfClass:NSURL.class] && home.isFileURL) context[@"home"]=home.URLByResolvingSymlinksInPath;
    context[@"groups"]=provided[@"groups"] ?: @{};context[@"homeWasRejected"]=provided[@"homeWasRejected"] ?: @NO;
    NSMutableDictionary *identities=[NSMutableDictionary new];
    NSMutableDictionary *roots=[context[@"groups"] mutableCopy];if(home) roots[@"primary"]=context[@"home"];
    for(NSString *key in roots) {struct stat info;NSURL *url=roots[key];
        if(lstat(url.fileSystemRepresentation,&info) || !S_ISDIR(info.st_mode)) identities[key]=@[];
        else identities[key]=@[@(info.st_dev),@(info.st_ino)];
    }
    context[@"identities"]=identities;
    [self axs_cachekeeper_duration:@"resolveMilliseconds" since:start];
    return context;
}
- (NSDictionary *)interrupted:(NSDictionary *)record {
    if(![record[@"scanProgress"][@"state"] isEqual:@"running"]) return record;
    NSMutableDictionary *result=[record mutableCopy],*progress=[record[@"scanProgress"] mutableCopy],*diagnostics=[record[@"scanDiagnostics"] mutableCopy];
    progress[@"state"]=@"interrupted";result[@"scanProgress"]=progress;result[@"complete"]=@NO;
    diagnostics[@"measurementComplete"]=@NO;result[@"scanDiagnostics"]=diagnostics;result[@"error"]=AxsCacheKeeperScanMessage(@"interrupted");result[@"updated"]=NSDate.date;return result;
}
- (BOOL)recover {
    NSError *error=nil;NSDictionary *saved=[self axs_cachekeeper_readHistory:&error];
    if(error) return NO;
    NSMutableDictionary *history=[saved mutableCopy];BOOL changed=NO;
    for(NSString *bundle in saved) {NSDictionary *result=[self interrupted:saved[bundle]];if(result!=saved[bundle]) {history[bundle]=result;changed=YES;}}
    if(changed && ![self write:history name:@"snapshots.plist"]) return NO;
    NSDictionary *scan=axs_cachekeeper_read_records([self path:@"scan.plist"],&error);if(error) return NO;
    if(scan) {NSDictionary *result=[self interrupted:scan];if(result!=scan && ![self write:result name:@"scan.plist"]) return NO;_singleToken=scan[@"token"];}
    NSDictionary *batch=axs_cachekeeper_read_input([self path:@"batch.plist"],&error);if(error) return NO;
    if([batch[@"scanState"] isEqual:@"running"] && [batch[@"remaining"] count]) {
        NSMutableDictionary *next=[batch mutableCopy];next[@"scanState"]=@"interrupted";next[@"error"]=AxsCacheKeeperScanMessage(@"interrupted");
        if(![self write:next name:@"batch.plist"]) return NO;
    }
    return YES;
}
- (AxsCacheKeeperScanTask *)task:(NSString *)bundle token:(NSString *)token batch:(BOOL)batch {
    _performanceHasWork=YES;
    AxsCacheKeeperScanTask *task=[AxsCacheKeeperScanTask new];task.bundle=bundle;task.token=token;task.batch=batch;task.state=@"running";
    task.started=[self axs_cachekeeper_now];task.rows=[NSMutableArray new];task.allocation=[[AxsCacheKeeperScanAllocation alloc] initWithLimit:65536];task.context=[self context:bundle];
    NSError *error=nil;NSDictionary *history=[self axs_cachekeeper_readHistory:&error];task.old=history[bundle];
    if(error) {task.error=@"历史记录不可读，已保留原文件";task.discovery=axs_cachekeeper_scan_diagnostics_new();task.candidates=@[];[task stop:@"saveFailed"];return task;}
    NSDictionary *diagnostics=nil;
    NSTimeInterval discoveryStart=NSProcessInfo.processInfo.systemUptime;
    task.candidates=axs_cachekeeper_bounded_scan_targets(task.context[@"home"],task.context[@"groups"],[task.context[@"homeWasRejected"] boolValue],&diagnostics);
    [self axs_cachekeeper_duration:@"discoveryMilliseconds" since:discoveryStart];
    task.discovery=diagnostics;
    if(![diagnostics[@"discoveryComplete"] boolValue]) task.error=@"目录发现未完整完成";
    // Bound retained metadata even when a container exposes many independent top-level roots.
    if(task.candidates.count>256) {task.candidates=[task.candidates subarrayWithRange:NSMakeRange(0,256)];task.error=@"候选目录超过 256 项上限，发现不完整";NSMutableDictionary *limited=[diagnostics mutableCopy];limited[@"discoveryComplete"]=@NO;limited[@"measurementComplete"]=@NO;limited[@"entryLimitExceeded"]=@YES;task.discovery=limited;}
    return task;
}
- (BOOL)axs_cachekeeper_candidate_current:(NSDictionary *)candidate {
    NSURL *root=candidate[@"root"],*source=candidate[@"sourceRoot"];struct stat current,parent;
    return [root.path isEqual:root.URLByResolvingSymlinksInPath.path] && !lstat(root.fileSystemRepresentation,&current) &&
        S_ISDIR(current.st_mode) && [candidate[@"identity"] isEqual:@[@(current.st_dev),@(current.st_ino)]] &&
        !lstat(source.fileSystemRepresentation,&parent) && S_ISDIR(parent.st_mode) &&
        [candidate[@"sourceIdentity"] isEqual:axs_cachekeeper_scan_identity(&parent)];
}
- (void)advance:(AxsCacheKeeperScanTask *)task {
    if(![task.state isEqual:@"running"]) return;
    if(![[self context:task.bundle] isEqual:task.context]) {[task stop:@"identityChanged"];return;}
    if([self axs_cachekeeper_now]-task.started>AxsCacheKeeperScanTaskSeconds) {[task stop:@"timeLimit"];return;}
    if(task.index>=task.candidates.count) {task.state=[task.discovery[@"measurementComplete"] boolValue] ? @"complete" : @"partial";return;}
    NSDictionary *candidate=task.candidates[task.index];NSURL *root=candidate[@"root"];
    // Discovered roots cannot acquire an intermediate symlink between discovery and opening.
    if(![self axs_cachekeeper_candidate_current:candidate]) {[task stop:@"identityChanged"];return;}
    NSTimeInterval traversalStart=NSProcessInfo.processInfo.systemUptime;
    if(!task.cursor) task.cursor=[[AxsCacheKeeperScanCursor alloc] initWithRoot:root entryLimit:AxsCacheKeeperScanTaskEntries-task.entries depthLimit:AxsCacheKeeperScanDepth allocation:task.allocation];
    [task.cursor advanceEntries:AxsCacheKeeperScanSliceEntries seconds:.05];task.slices++;
    [self axs_cachekeeper_duration:@"traversalMilliseconds" since:traversalStart];
    [self axs_cachekeeper_count:@"slices" amount:1];
    if(![task.cursor.state isEqual:@"running"]) {
        NSString *state=task.cursor.state;[task stop:state];task.index++;
        if([state isEqual:@"complete"]) {
            task.state=task.index==task.candidates.count ? ([task.discovery[@"measurementComplete"] boolValue] ? @"complete" : @"partial") : @"running";
        }
    }
}
- (NSDictionary *)currentRequest:(AxsCacheKeeperScanTask *)task {
    NSDictionary *request=axs_cachekeeper_read_input([self path:task.batch ? @"batch.plist" : @"request.plist"],NULL);
    return [request[@"token"] isEqual:task.token] && (task.batch ? [request[@"remaining"] containsObject:task.bundle] : [request[@"bundle"] isEqual:task.bundle]) ? request : nil;
}
- (BOOL)current:(AxsCacheKeeperScanTask *)task {
    return [self currentRequest:task]!=nil;
}
- (void)retire:(AxsCacheKeeperScanTask *)task {
    [task stop:@"superseded"];
    NSError *error=nil;NSMutableDictionary *history=[[self axs_cachekeeper_readHistory:&error] mutableCopy];
    if(!error && [history[task.bundle][@"token"] isEqual:task.token]) {
        NSDictionary *result=task.snapshot;
        if(axs_cachekeeper_record_valid(result,0)) {history[task.bundle]=result;[self write:history name:@"snapshots.plist"];}
    }
    // Retiring work never writes the shared single-request receipt.
}
- (BOOL)publish:(AxsCacheKeeperScanTask *)task {
    return [[self publishTasks:@[task]] containsObject:task];
}
- (NSSet *)publishTasks:(NSArray<AxsCacheKeeperScanTask *> *)tasks {
    NSMutableArray<AxsCacheKeeperScanTask *> *current=[NSMutableArray new];
    NSMutableSet *bundles=[NSMutableSet new],*savedTasks=[NSMutableSet new];
    for(AxsCacheKeeperScanTask *task in tasks) {
        if(![self current:task] || [bundles containsObject:task.bundle]) continue;
        if(![task.state isEqual:@"saveFailed"] && ![[self context:task.bundle] isEqual:task.context]) [task stop:@"identityChanged"];
        if([task.state isEqual:@"complete"]) for(NSDictionary *candidate in task.candidates) {
            if(![self axs_cachekeeper_candidate_current:candidate]) {[task stop:@"identityChanged"];break;}
        }
        [current addObject:task];[bundles addObject:task.bundle];
    }
    if(!current.count) return savedTasks;
    NSError *error=nil;NSMutableDictionary *history=[[self axs_cachekeeper_readHistory:&error] mutableCopy];
    if(!history && !error) history=[NSMutableDictionary new];
    // Validate every member again after the single expensive read. Each receipt
    // retains its own request identity, even when the history commit is shared.
    NSMutableArray<AxsCacheKeeperScanTask *> *publishing=[NSMutableArray new];BOOL valid=YES;
    for(AxsCacheKeeperScanTask *task in current) {
        NSDictionary *request=[self currentRequest:task];
        if(!request) continue;
        if([request[@"cancel"] boolValue]) [task stop:@"cancelled"];
        NSDictionary *result=task.snapshot;valid=valid && axs_cachekeeper_record_valid(result,0);
        history[task.bundle]=result;[publishing addObject:task];
    }
    if(!publishing.count) return savedTasks;
    BOOL saved=!error && valid && [self write:history name:@"snapshots.plist"];
    for(AxsCacheKeeperScanTask *task in publishing) {
        if(!saved) [task stop:@"saveFailed"];
        NSDictionary *result=task.snapshot;
        BOOL receiptSaved=task.batch || [self write:result name:@"scan.plist"];
        if(!receiptSaved) {
            [task stop:@"saveFailed"];
            // A dedicated receipt failure cannot leave a successful history row.
            if(!error) {history[task.bundle]=task.snapshot;[self write:history name:@"snapshots.plist"];}
        }
        if(saved && receiptSaved) [savedTasks addObject:task];
        task.lastPublished=[self axs_cachekeeper_now];
    }
    return savedTasks;
}
- (void)finishBatch:(AxsCacheKeeperScanTask *)task saved:(BOOL)saved {
    NSDictionary *current=axs_cachekeeper_read_input([self path:@"batch.plist"],NULL);
    if(![current[@"token"] isEqual:task.token] || ![current[@"remaining"] containsObject:task.bundle]) return;
    NSMutableDictionary *next=[current mutableCopy];
    if(!saved) {next[@"error"]=AxsCacheKeeperScanMessage(@"saveFailed");next[@"scanState"]=@"saveFailed";}
    else if([current[@"cancel"] boolValue] || [task.state isEqual:@"cancelled"]) {
        next[@"scanState"]=@"cancelled";next[@"error"]=AxsCacheKeeperScanMessage(@"cancelled");
    } else {
        NSMutableArray *remaining=[current[@"remaining"] mutableCopy];[remaining removeObject:task.bundle];next[@"remaining"]=remaining;
        next[@"completed"]=@([current[@"completed"] unsignedIntegerValue]+1);
        if(![task.state isEqual:@"complete"]) next[@"partialCount"]=@([current[@"partialCount"] unsignedIntegerValue]+1);
        next[@"scanState"]=remaining.count ? @"running" : ([next[@"partialCount"] unsignedIntegerValue] ? @"partial" : @"complete");
    }
    if(![self write:next name:@"batch.plist"]) _pendingBatch=next;
}
- (BOOL)tick {
    if(!_performanceActive) {
        _performance=[NSMutableDictionary new];_performanceStarted=NSDate.date;
        _performanceStart=NSProcessInfo.processInfo.systemUptime;_performancePublished=0;_performanceHasWork=NO;
    }
    NSTimeInterval start=NSProcessInfo.processInfo.systemUptime;
    BOOL active=[self axs_cachekeeper_tick];
    [self axs_cachekeeper_duration:@"workMilliseconds" since:start];
    NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
    if(_performanceHasWork && (!_performancePublished || !active || now-_performancePublished>=1)) {
        NSMutableDictionary *sample=[NSMutableDictionary new];
        for(NSString *key in @[@"workMilliseconds",@"resolveMilliseconds",@"discoveryMilliseconds",@"traversalMilliseconds",@"historyReadMilliseconds",@"historyWriteMilliseconds",@"historyReads",@"historyDecodes",@"historyWrites",@"historyWriteFailures",@"historyBytesRead",@"slices"])
            sample[key]=@((unsigned long long)[_performance[key] doubleValue]);
        sample[@"scope"]=@"serviceActivity";sample[@"started"]=_performanceStarted;sample[@"updated"]=NSDate.date;
        sample[@"active"]=@(active);sample[@"elapsedMilliseconds"]=@((unsigned long long)(MAX(0,now-_performanceStart)*1000));
        // Includes completed final history writes; excludes this small telemetry write.
        // A service activity can contain overlapping single and batch requests.
        [self write:sample name:@"scanPerformance.plist"];_performancePublished=now;
    }
    _performanceActive=active;return active;
}
- (BOOL)axs_cachekeeper_tick {
    if(!_recovered) {_recovered=[self recover];if(!_recovered) return NO;}
    NSDictionary *request=axs_cachekeeper_read_input([self path:@"request.plist"],NULL);
    if(_single && (![request[@"token"] isEqual:_single.token] || ![request[@"bundle"] isEqual:_single.bundle])) {[self retire:_single];_single=nil;}
    if(request && ![request[@"token"] isEqual:_singleToken]) {
        _singleToken=request[@"token"];
        // Single requests own this app while active. Discard its old batch cursor;
        // the batch member stays pending and starts afresh after the single finishes.
        for(AxsCacheKeeperScanTask *task in [_batchTasks copy]) if([task.bundle isEqual:request[@"bundle"]]) {
            [self retire:task];[_batchTasks removeObject:task];
        }
        _single=[self task:request[@"bundle"] token:_singleToken batch:NO];
        if(![request[@"cancel"] boolValue] && self.acceptedRequest) self.acceptedRequest(request[@"bundle"],[request[@"diagnostic"] boolValue]);
        if([request[@"cancel"] boolValue]) [_single stop:@"cancelled"];
    }
    if(_single && [request[@"cancel"] boolValue]) [_single stop:@"cancelled"];
    NSDictionary *batch=axs_cachekeeper_read_input([self path:@"batch.plist"],NULL);
    if(![batch[@"token"] isEqual:_batchToken]) {
        for(AxsCacheKeeperScanTask *task in _batchTasks) [self retire:task];
        [_batchTasks removeAllObjects];_batchToken=batch[@"token"];_pendingBatch=nil;
    }
    if(_pendingBatch) {
        NSMutableDictionary *pending=[_pendingBatch mutableCopy];
        // Progress belongs to the completed member; control belongs to the current
        // request. A later stop/error must survive retrying an earlier progress write.
        if([batch[@"cancel"] boolValue]) {pending[@"cancel"]=@YES;pending[@"scanState"]=@"cancelled";pending[@"error"]=AxsCacheKeeperScanMessage(@"cancelled");}
        else if([batch[@"error"] length]) {pending[@"error"]=batch[@"error"];if(batch[@"scanState"]) pending[@"scanState"]=batch[@"scanState"];}
        _pendingBatch=pending;
        if([self write:pending name:@"batch.plist"]) {_pendingBatch=nil;batch=pending;}
    }
    if([batch[@"error"] length] || [batch[@"cancel"] boolValue]) {
        for(AxsCacheKeeperScanTask *task in _batchTasks) [task stop:[batch[@"cancel"] boolValue] ? @"cancelled" : @"saveFailed"];
        [self publishTasks:_batchTasks];
        [_batchTasks removeAllObjects];
        if(!_pendingBatch && [batch[@"cancel"] boolValue] && ![batch[@"scanState"] isEqual:@"cancelled"]) {NSMutableDictionary *next=[batch mutableCopy];next[@"scanState"]=@"cancelled";next[@"error"]=AxsCacheKeeperScanMessage(@"cancelled");[self write:next name:@"batch.plist"];}
    } else if(!_pendingBatch && [batch[@"remaining"] count] && [batch[@"token"] length]) {
        for(NSString *bundle in batch[@"remaining"]) {
            if(_batchTasks.count>=AxsCacheKeeperScanActiveBatch) break;
            if(_single && [bundle isEqual:_single.bundle]) continue;
            BOOL present=NO;for(AxsCacheKeeperScanTask *task in _batchTasks) if([task.bundle isEqual:bundle]) present=YES;
            if(!present) {[_batchTasks addObject:[self task:bundle token:_batchToken batch:YES]];if(self.acceptedRequest) self.acceptedRequest(bundle,NO);}
        }
        if(![batch[@"scanState"] isEqual:@"running"]) {NSMutableDictionary *next=[batch mutableCopy];next[@"scanState"]=@"running";if(![self write:next name:@"batch.plist"]) _pendingBatch=next;}
    }
    // One quantum per call; single and batch jobs share the same round-robin lane.
    NSMutableArray *ready=_pendingBatch ? [NSMutableArray new] : [_batchTasks mutableCopy];if(_single) [ready addObject:_single];
    if(!ready.count) return _pendingBatch!=nil;
    AxsCacheKeeperScanTask *task=ready[_turn++%ready.count];
    [self advance:task];
    // First and terminal receipts commit immediately. Intermediate progress
    // shares one service cadence and includes the other active members.
    BOOL terminal=![task.state isEqual:@"running"];
    if(!task.lastPublished || terminal || !_historyPublished || [self axs_cachekeeper_now]-_historyPublished>=1) {
        NSArray *publishing=ready;
        BOOL saved=[[self publishTasks:publishing] containsObject:task];terminal=![task.state isEqual:@"running"];
        if(terminal && task.batch) {[self finishBatch:task saved:saved];[_batchTasks removeObject:task];}
        else if(terminal && saved) _single=nil;
    }
    return _single || _batchTasks.count || [batch[@"remaining"] count];
}
@end
