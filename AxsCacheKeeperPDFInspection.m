#import "AxsCacheKeeperPDFInspection.h"
#import "AxsCacheKeeperPolicy.h"
#include <dirent.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <errno.h>
#include <math.h>
#include <string.h>

enum { AxsCacheKeeperPDFBatchLimit=64,AxsCacheKeeperPDFSampleLimit=4096,AxsCacheKeeperPDFCandidateLimit=10 };
AxsCacheKeeperPDFInspectionLimits axs_cachekeeper_pdf_inspection_limits(void) {
    return (AxsCacheKeeperPDFInspectionLimits){10000,16u*1024u*1024u,5,32,34};
}
static BOOL axs_cachekeeper_pdf_report_integer(id value,uint64_t maximum) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()) return NO;
    double number=[value doubleValue];return isfinite(number) && number>=0 && number<=maximum && floor(number)==number;
}
NSDictionary *axs_cachekeeper_pdf_report_fields(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *words=@{
        @"state":@[@"probing",@"ready",@"running",@"finished",@"unavailable",@"cancelled",@"busy",@"expired",@"rejected"],
        @"stage":@[@"none",@"input",@"selfIdentity",@"peerIdentity",@"lookup",@"send",@"receive",@"containerResolve",@"installation",@"containerOpen",@"directoryOpen",@"identityRecheck",@"busy",@"session",@"cancel",@"candidate"],
        @"inspectionMode":@[@"pdfLocate"],@"stopReason":@[@"running",@"finished",@"entryLimit",@"byteLimit",@"timeLimit",@"cancelled",@"error"],
        @"errorStage":@[@"none",@"input",@"protected",@"depthLimit",@"fdLimit",@"root",@"clock",@"changed",@"ancestor",@"openDirectory",@"openFile",@"fileStat",@"read",@"shortRead",@"enumerate",@"entryName"],
        @"errorDomain":@[@"none",@"policy",@"posix",@"limit",@"identity"]};
    NSArray *booleans=@[@"containerReadable",@"complete",@"coverageComplete",@"pdfCandidatesTruncated"];
    NSArray *numbers=@[@"enumeratedCount",@"sampleBytes",@"regularPathCount",@"pdfPathCount",@"protectedCount",@"symbolicLinkCount",@"specialFileCount",@"failureCount",@"readFailureCount",@"shortReadCount",@"changedCount",@"depthLimitedCount",@"fdLimitedCount",@"openDescriptorCount"];
    NSMutableSet *keys=[NSMutableSet setWithArray:words.allKeys];[keys addObjectsFromArray:booleans];[keys addObjectsFromArray:numbers];[keys addObjectsFromArray:@[@"errorCode",@"durationSeconds",@"pdfCandidates",@"budgets"]];
    NSMutableDictionary *fields=[NSMutableDictionary new];
    for (id key in value) if ([keys containsObject:key]) fields[key]=value[key];
    value=fields;
    if (!value[@"state"] || !value[@"stage"] || !value[@"containerReadable"] || !value[@"errorCode"]) return nil;
    for (NSString *key in words) if (value[key] && ![words[key] containsObject:value[key]]) return nil;
    for (NSString *key in booleans) if (value[key] && (![value[key] isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value[key])!=CFBooleanGetTypeID())) return nil;
    for (NSString *key in numbers) if (value[key] && !axs_cachekeeper_pdf_report_integer(value[key],[key isEqual:@"sampleBytes"] ? 16777216 : 1000000)) return nil;
    id error=value[@"errorCode"];double code=[error isKindOfClass:NSNumber.class] ? [error doubleValue] : NAN;
    if (!isfinite(code) || code<INT32_MIN || code>INT32_MAX || floor(code)!=code || CFGetTypeID((__bridge CFTypeRef)error)==CFBooleanGetTypeID()) return nil;
    if (value[@"durationSeconds"] && (![value[@"durationSeconds"] isKindOfClass:NSNumber.class] || !isfinite([value[@"durationSeconds"] doubleValue]) || [value[@"durationSeconds"] doubleValue]<0)) return nil;
    if (value[@"budgets"] && ![value[@"budgets"] isEqual:@{@"entryLimit":@10000,@"sampleByteLimit":@16777216,@"seconds":@5,@"depthLimit":@32,@"descriptorLimit":@34,@"batchEntries":@64,@"perFileBytes":@4096}]) return nil;
    id candidates=value[@"pdfCandidates"];
    if (candidates) {
        if (![candidates isKindOfClass:NSArray.class] || [candidates count]>10) return nil;
        for (id candidate in candidates) if (![candidate isKindOfClass:NSDictionary.class] || [candidate count]!=3 ||
            !([candidate[@"path"] isKindOfClass:NSString.class] && [candidate[@"path"] lengthOfBytesUsingEncoding:NSUTF8StringEncoding]<=4095) || !axs_cachekeeper_relative_path(candidate[@"path"]) ||
            !axs_cachekeeper_pdf_report_integer(candidate[@"bytes"],INT64_MAX) || !axs_cachekeeper_pdf_report_integer(candidate[@"linkCount"],UINT32_MAX)) return nil;
    }
    return [fields copy];
}
#if !defined(AXS_CACHEKEEPER_PDF_CLIENT)
static BOOL axs_cachekeeper_pdf_identity(struct stat a,struct stat b) {
    return (a.st_mode&S_IFMT)==(b.st_mode&S_IFMT) && a.st_dev==b.st_dev && a.st_ino==b.st_ino;
}
static BOOL axs_cachekeeper_pdf_stable(struct stat a,struct stat b) {
    return axs_cachekeeper_pdf_identity(a,b) && a.st_size==b.st_size && a.st_nlink==b.st_nlink &&
        a.st_mtimespec.tv_sec==b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec==b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec==b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec==b.st_ctimespec.tv_nsec;
}
static BOOL axs_cachekeeper_pdf_relative(NSString *path) {
    if (!axs_cachekeeper_relative_path(path) || [path lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>4095) return NO;
    unichar zero=0;return [path rangeOfString:[NSString stringWithCharacters:&zero length:1]].location==NSNotFound;
}

@interface AxsCacheKeeperPDFDirectory : NSObject
@property(nonatomic) int descriptor;
@property(nonatomic) DIR *stream;
@property(nonatomic,copy) NSString *name;
@property(nonatomic,copy) NSString *relative;
@property(nonatomic) struct stat identity;
@property(nonatomic) BOOL mutationRecorded;
- (void)axs_cachekeeper_pdf_close;
@end
@implementation AxsCacheKeeperPDFDirectory
- (instancetype)init { self=[super init];if (self) _descriptor=-1;return self; }
- (void)axs_cachekeeper_pdf_close {
    if (_stream) {closedir(_stream);_stream=NULL;_descriptor=-1;}
    else if (_descriptor>=0) {close(_descriptor);_descriptor=-1;}
}
- (void)dealloc { [self axs_cachekeeper_pdf_close]; }
@end

@interface AxsCacheKeeperPDFInspection () {
    NSRecursiveLock *_lock;
    atomic_bool _cancelRequested;
    NSMutableArray<AxsCacheKeeperPDFDirectory *> *_chain;
    NSMutableArray<NSDictionary *> *_candidates;
    AxsCacheKeeperPDFInspectionLimits _limits;
    NSTimeInterval (^_clock)(void);
    void (^_beforeRead)(NSString *);
    ssize_t (^_read)(int,void *,size_t);
    NSTimeInterval _started,_lastTime,_finishedTime;
    NSUInteger _selectedChainLength;
    int _activeFile;
    BOOL _done,_coverage;
    NSString *_stopReason,*_errorStage,*_errorDomain;
    int _errorCode;
    NSUInteger _enumerated,_regularPaths,_pdfPaths,_protected,_symlinks,_special;
    NSUInteger _failures,_readFailures,_shortReads,_changed,_depthLimited,_fdLimited;
    uint64_t _sampleBytes;
}
- (void)axs_cachekeeper_pdf_failure:(NSString *)stage code:(int)code;
- (void)axs_cachekeeper_pdf_limit:(NSString *)stage;
- (void)axs_cachekeeper_pdf_finish:(NSString *)reason clear:(BOOL)clear;
- (BOOL)axs_cachekeeper_pdf_checkpoint;
- (void)axs_cachekeeper_pdf_changed:(int)code;
- (BOOL)axs_cachekeeper_pdf_validate_chain;
- (BOOL)axs_cachekeeper_pdf_open_directory:(NSString *)name relative:(NSString *)relative enumerate:(BOOL)enumerate;
- (BOOL)axs_cachekeeper_pdf_file_entry:(NSString *)name parent:(AxsCacheKeeperPDFDirectory *)parent matches:(struct stat)identity;
- (void)axs_cachekeeper_pdf_read_file:(NSString *)name relative:(NSString *)relative parent:(AxsCacheKeeperPDFDirectory *)parent expected:(struct stat)expected;
@end

@implementation AxsCacheKeeperPDFInspection
- (instancetype)initWithContainerFD:(int)containerFD relativeDirectory:(NSString *)relative {
    return [self initWithContainerFD:containerFD relativeDirectory:relative limits:axs_cachekeeper_pdf_inspection_limits() clock:nil beforeRead:nil read:nil];
}
- (instancetype)initWithContainerFD:(int)containerFD relativeDirectory:(NSString *)relative
                             limits:(AxsCacheKeeperPDFInspectionLimits)limits clock:(NSTimeInterval (^)(void))clock
                         beforeRead:(void (^)(NSString *))beforeRead read:(ssize_t (^)(int,void *,size_t))readBlock {
    self=[super init];if (!self) return nil;
    _lock=[NSRecursiveLock new];atomic_init(&_cancelRequested,false);_activeFile=-1;
    _chain=[NSMutableArray new];_candidates=[NSMutableArray new];_coverage=YES;
    _stopReason=@"running";_errorStage=@"none";_errorDomain=@"none";
    AxsCacheKeeperPDFInspectionLimits caps=axs_cachekeeper_pdf_inspection_limits();
    _limits=(AxsCacheKeeperPDFInspectionLimits){MIN(limits.entryLimit,caps.entryLimit),MIN(limits.sampleByteLimit,caps.sampleByteLimit),
        isfinite(limits.seconds) && limits.seconds>=0 ? MIN(limits.seconds,caps.seconds) : 0,
        MIN(limits.depthLimit,caps.depthLimit),MIN(limits.descriptorLimit,caps.descriptorLimit)};
    _clock=clock ? [clock copy] : ^NSTimeInterval{return NSProcessInfo.processInfo.systemUptime;};
    _read=readBlock ? [readBlock copy] : ^ssize_t(int fd,void *buffer,size_t count){return pread(fd,buffer,count,0);};
    _beforeRead=[beforeRead copy];_started=_clock();_lastTime=_started;
    if (!isfinite(_started) || _started<0 || !isfinite(limits.seconds) || limits.seconds<0 || !axs_cachekeeper_pdf_relative(relative)) {
        _started=_lastTime=0;[self axs_cachekeeper_pdf_failure:@"input" code:EINVAL];[self axs_cachekeeper_pdf_finish:@"error" clear:YES];return self;
    }
    // Preserve the complete container-relative prefix, including sensitive parent components.
    if (axs_cachekeeper_protected_path(relative)) {
        _protected++;_coverage=NO;_errorStage=@"protected";_errorDomain=@"policy";[self axs_cachekeeper_pdf_finish:@"error" clear:YES];return self;
    }
    NSArray<NSString *> *components=[relative componentsSeparatedByString:@"/"];
    if (components.count>_limits.depthLimit) {
        _depthLimited++;[self axs_cachekeeper_pdf_limit:@"depthLimit"];[self axs_cachekeeper_pdf_finish:@"error" clear:YES];return self;
    }
    if (![self axs_cachekeeper_pdf_checkpoint]) return self;
    if (!_limits.descriptorLimit) {
        _fdLimited++;[self axs_cachekeeper_pdf_limit:@"fdLimit"];[self axs_cachekeeper_pdf_finish:@"error" clear:YES];return self;
    }
    int duplicate=fcntl(containerFD,F_DUPFD_CLOEXEC,0);struct stat rootInfo;
    if (duplicate<0) { [self axs_cachekeeper_pdf_failure:@"root" code:errno];[self axs_cachekeeper_pdf_finish:@"error" clear:YES];return self; }
    int statResult=fstat(duplicate,&rootInfo);
    if (statResult || !S_ISDIR(rootInfo.st_mode)) {
        int code=statResult ? errno : ENOTDIR;close(duplicate);[self axs_cachekeeper_pdf_failure:@"root" code:code];[self axs_cachekeeper_pdf_finish:@"error" clear:YES];return self;
    }
    AxsCacheKeeperPDFDirectory *root=[AxsCacheKeeperPDFDirectory new];root.descriptor=duplicate;root.identity=rootInfo;root.relative=@"";root.name=@"";[_chain addObject:root];
    NSString *current=@"";
    for (NSString *component in components) {
        if (![self axs_cachekeeper_pdf_checkpoint]) return self;
        current=current.length ? [current stringByAppendingFormat:@"/%@",component] : component;
        if (![self axs_cachekeeper_pdf_open_directory:component relative:current enumerate:NO]) {
            if (!_done) [self axs_cachekeeper_pdf_finish:@"error" clear:YES];return self;
        }
    }
    if (![self axs_cachekeeper_pdf_validate_chain] || ![self axs_cachekeeper_pdf_checkpoint]) return self;
    AxsCacheKeeperPDFDirectory *selected=_chain.lastObject;DIR *stream=fdopendir(selected.descriptor);
    if (!stream) { [self axs_cachekeeper_pdf_failure:@"openDirectory" code:errno];[self axs_cachekeeper_pdf_finish:@"error" clear:YES];return self; }
    selected.stream=stream;_selectedChainLength=_chain.count;return self;
}
- (void)dealloc {
    if (_activeFile>=0) close(_activeFile);
    for (AxsCacheKeeperPDFDirectory *directory in _chain) [directory axs_cachekeeper_pdf_close];
}
- (void)axs_cachekeeper_pdf_failure:(NSString *)stage code:(int)code {
    _failures++;_coverage=NO;_errorStage=stage;_errorDomain=@"posix";_errorCode=code;
}
- (void)axs_cachekeeper_pdf_limit:(NSString *)stage {
    _coverage=NO;_errorStage=stage;_errorDomain=@"limit";_errorCode=0;
}
- (void)axs_cachekeeper_pdf_finish:(NSString *)reason clear:(BOOL)clear {
    _done=YES;_stopReason=reason;_finishedTime=_lastTime;
    if (![reason isEqual:@"finished"]) _coverage=NO;
    if (_activeFile>=0) {close(_activeFile);_activeFile=-1;}
    for (AxsCacheKeeperPDFDirectory *directory in _chain) [directory axs_cachekeeper_pdf_close];
    [_chain removeAllObjects];
    if (clear) {[_candidates removeAllObjects];_pdfPaths=0;}
}
- (BOOL)axs_cachekeeper_pdf_checkpoint {
    if (atomic_load(&_cancelRequested)) { [self axs_cachekeeper_pdf_finish:@"cancelled" clear:YES];return NO; }
    if (_done) return NO;
    NSTimeInterval now=_clock();
    if (!isfinite(now) || now<_lastTime) {
        [self axs_cachekeeper_pdf_failure:@"clock" code:EINVAL];[self axs_cachekeeper_pdf_finish:@"error" clear:YES];return NO;
    }
    _lastTime=now;
    if (now-_started>=_limits.seconds) { [self axs_cachekeeper_pdf_finish:@"timeLimit" clear:NO];return NO; }
    return YES;
}
- (void)axs_cachekeeper_pdf_changed:(int)code {
    _changed++;_coverage=NO;_errorStage=@"changed";_errorDomain=code ? @"posix" : @"identity";_errorCode=code;
}
- (BOOL)axs_cachekeeper_pdf_validate_chain {
    for (NSUInteger i=0;i<_chain.count;i++) {
        if (![self axs_cachekeeper_pdf_checkpoint]) return NO;
        AxsCacheKeeperPDFDirectory *node=_chain[i];struct stat current,entry;
        if (fstat(node.descriptor,&current)) {
            [self axs_cachekeeper_pdf_failure:@"ancestor" code:errno];[self axs_cachekeeper_pdf_finish:@"error" clear:YES];return NO;
        }
        if (![self axs_cachekeeper_pdf_checkpoint]) return NO;
        if (!S_ISDIR(current.st_mode) || !axs_cachekeeper_pdf_identity(current,node.identity)) {
            [self axs_cachekeeper_pdf_changed:0];[self axs_cachekeeper_pdf_finish:@"error" clear:YES];return NO;
        }
        if (i) {
            if (fstatat(_chain[i-1].descriptor,node.name.fileSystemRepresentation,&entry,AT_SYMLINK_NOFOLLOW)) {
                int code=errno;
                if (code==ENOENT || code==ENOTDIR || code==ELOOP) [self axs_cachekeeper_pdf_changed:code];
                else [self axs_cachekeeper_pdf_failure:@"ancestor" code:code];
                [self axs_cachekeeper_pdf_finish:@"error" clear:YES];return NO;
            }
            if (!axs_cachekeeper_pdf_identity(entry,node.identity)) {
                [self axs_cachekeeper_pdf_changed:0];[self axs_cachekeeper_pdf_finish:@"error" clear:YES];return NO;
            }
            if (![self axs_cachekeeper_pdf_checkpoint]) return NO;
        }
        // Changes to directory membership prevent a full-coverage claim; a stable held inode
        // remains usable only while every parent entry still names that same directory.
        if (!node.mutationRecorded && !axs_cachekeeper_pdf_stable(current,node.identity)) {
            node.mutationRecorded=YES;[self axs_cachekeeper_pdf_changed:0];
        }
    }
    return YES;
}
- (BOOL)axs_cachekeeper_pdf_open_directory:(NSString *)name relative:(NSString *)relative enumerate:(BOOL)enumerate {
    if (axs_cachekeeper_protected_path(relative)) { _protected++;_coverage=NO;return NO; }
    if ([relative componentsSeparatedByString:@"/"].count>_limits.depthLimit) { _depthLimited++;[self axs_cachekeeper_pdf_limit:@"depthLimit"];return NO; }
    if (_chain.count>=_limits.descriptorLimit) { _fdLimited++;[self axs_cachekeeper_pdf_limit:@"fdLimit"];return NO; }
    if (![self axs_cachekeeper_pdf_checkpoint] || ![self axs_cachekeeper_pdf_validate_chain]) return NO;
    AxsCacheKeeperPDFDirectory *parent=_chain.lastObject;struct stat before,opened,after;
    if (fstatat(parent.descriptor,name.fileSystemRepresentation,&before,AT_SYMLINK_NOFOLLOW)) { [self axs_cachekeeper_pdf_failure:@"openDirectory" code:errno];return NO; }
    if (![self axs_cachekeeper_pdf_checkpoint]) return NO;
    if (!S_ISDIR(before.st_mode) || before.st_dev!=_chain.firstObject.identity.st_dev) {
        if (S_ISLNK(before.st_mode)) _symlinks++;else _special++;_coverage=NO;return NO;
    }
    int fd=openat(parent.descriptor,name.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if (fd<0) { [self axs_cachekeeper_pdf_failure:@"openDirectory" code:errno];return NO; }
    if (![self axs_cachekeeper_pdf_checkpoint]) {close(fd);return NO;}
    if (fstat(fd,&opened) || fstatat(parent.descriptor,name.fileSystemRepresentation,&after,AT_SYMLINK_NOFOLLOW)) {
        int code=errno;close(fd);[self axs_cachekeeper_pdf_failure:@"openDirectory" code:code];return NO;
    }
    if (!axs_cachekeeper_pdf_identity(before,opened) || !axs_cachekeeper_pdf_identity(opened,after)) {
        close(fd);[self axs_cachekeeper_pdf_changed:0];return NO;
    }
    AxsCacheKeeperPDFDirectory *node=[AxsCacheKeeperPDFDirectory new];node.descriptor=fd;node.identity=opened;node.name=name;node.relative=relative;
    if (enumerate) {
        DIR *stream=fdopendir(fd);
        if (!stream) { [self axs_cachekeeper_pdf_failure:@"openDirectory" code:errno];[node axs_cachekeeper_pdf_close];return NO; }
        node.stream=stream;
    }
    [_chain addObject:node];return [self axs_cachekeeper_pdf_validate_chain] && [self axs_cachekeeper_pdf_checkpoint];
}
- (BOOL)axs_cachekeeper_pdf_file_entry:(NSString *)name parent:(AxsCacheKeeperPDFDirectory *)parent matches:(struct stat)identity {
    struct stat current;
    if (fstatat(parent.descriptor,name.fileSystemRepresentation,&current,AT_SYMLINK_NOFOLLOW)) {
        int code=errno;
        if (code==ENOENT || code==ENOTDIR || code==ELOOP) [self axs_cachekeeper_pdf_changed:code];
        else [self axs_cachekeeper_pdf_failure:@"fileStat" code:code];return NO;
    }
    if (!axs_cachekeeper_pdf_stable(current,identity)) { [self axs_cachekeeper_pdf_changed:0];return NO; }
    return YES;
}
- (void)axs_cachekeeper_pdf_read_file:(NSString *)name relative:(NSString *)relative parent:(AxsCacheKeeperPDFDirectory *)parent expected:(struct stat)expected {
    if (_chain.count+1>_limits.descriptorLimit) { _fdLimited++;[self axs_cachekeeper_pdf_limit:@"fdLimit"];return; }
    if (![self axs_cachekeeper_pdf_checkpoint] || ![self axs_cachekeeper_pdf_validate_chain]) return;
    if (_sampleBytes>=_limits.sampleByteLimit) { [self axs_cachekeeper_pdf_finish:@"byteLimit" clear:NO];return; }
    int fd=openat(parent.descriptor,name.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    if (fd<0) { [self axs_cachekeeper_pdf_failure:@"openFile" code:errno];return; }
    _activeFile=fd;
    @try {
        struct stat opened,after;
        if (fstat(fd,&opened)) { [self axs_cachekeeper_pdf_failure:@"fileStat" code:errno];return; }
        if (!S_ISREG(opened.st_mode) || !axs_cachekeeper_pdf_stable(expected,opened) || opened.st_size<0) { [self axs_cachekeeper_pdf_changed:0];return; }
        if (_beforeRead) _beforeRead(relative);
        if (![self axs_cachekeeper_pdf_checkpoint] || ![self axs_cachekeeper_pdf_validate_chain] ||
            ![self axs_cachekeeper_pdf_file_entry:name parent:parent matches:opened] || ![self axs_cachekeeper_pdf_checkpoint]) return;
        uint64_t remaining=_limits.sampleByteLimit-_sampleBytes;
        size_t wanted=(size_t)MIN(MIN((uint64_t)opened.st_size,(uint64_t)AxsCacheKeeperPDFSampleLimit),remaining);
        unsigned char sample[AxsCacheKeeperPDFSampleLimit]={0};errno=0;
        ssize_t count=wanted ? _read(fd,sample,wanted) : 0;int code=errno;
        if (count>0 && (uint64_t)count<=wanted) _sampleBytes+=(uint64_t)count;
        // Check cancellation/time before examining a sample or committing a late result.
        if (![self axs_cachekeeper_pdf_checkpoint]) return;
        BOOL readFailed=count<0 || (uint64_t)count>wanted;
        if (readFailed) { _readFailures++;[self axs_cachekeeper_pdf_failure:@"read" code:count<0 ? (code ?: EIO) : EIO]; }
        if (![self axs_cachekeeper_pdf_validate_chain] || ![self axs_cachekeeper_pdf_checkpoint]) return;
        if (fstat(fd,&after)) { [self axs_cachekeeper_pdf_failure:@"fileStat" code:errno];return; }
        if (!axs_cachekeeper_pdf_stable(opened,after)) { [self axs_cachekeeper_pdf_changed:0];return; }
        if (![self axs_cachekeeper_pdf_file_entry:name parent:parent matches:after] || ![self axs_cachekeeper_pdf_checkpoint] || readFailed) return;
        if ((size_t)count!=wanted) { _shortReads++;[self axs_cachekeeper_pdf_failure:@"shortRead" code:EIO];return; }
        _regularPaths++;
        if (count>=5 && !memcmp(sample,"%PDF-",5)) {
            _pdfPaths++;[_candidates addObject:@{@"path":relative,@"bytes":@((uint64_t)opened.st_size),@"linkCount":@(opened.st_nlink),
                @"_identity":[NSData dataWithBytes:&opened length:sizeof(opened)]}];
            [_candidates sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){
                NSComparisonResult bySize=[b[@"bytes"] compare:a[@"bytes"]];return bySize==NSOrderedSame ? [a[@"path"] compare:b[@"path"]] : bySize;
            }];
            if (_candidates.count>AxsCacheKeeperPDFCandidateLimit) [_candidates removeLastObject];
        }
        if (_sampleBytes>=_limits.sampleByteLimit) [self axs_cachekeeper_pdf_finish:@"byteLimit" clear:NO];
    } @finally {
        // Reentrant cancel may already have closed the file and cleared this ownership slot.
        if (_activeFile==fd) {close(fd);_activeFile=-1;}
    }
}
- (void)advance:(NSUInteger)limit {
    [_lock lock];
    @try {
        NSUInteger batch=MIN(limit,(NSUInteger)AxsCacheKeeperPDFBatchLimit),processed=0;
        while (!_done && processed<batch) {
            if (![self axs_cachekeeper_pdf_checkpoint]) break;
            if (_enumerated>=_limits.entryLimit) { [self axs_cachekeeper_pdf_finish:@"entryLimit" clear:NO];break; }
            if (_sampleBytes>=_limits.sampleByteLimit) { [self axs_cachekeeper_pdf_finish:@"byteLimit" clear:NO];break; }
            if (![self axs_cachekeeper_pdf_validate_chain]) break;
            AxsCacheKeeperPDFDirectory *parent=_chain.lastObject;errno=0;struct dirent *entry=readdir(parent.stream);int code=errno;
            if (!entry) {
                if (![self axs_cachekeeper_pdf_checkpoint] || ![self axs_cachekeeper_pdf_validate_chain]) break;
                if (code) [self axs_cachekeeper_pdf_failure:@"enumerate" code:code];
                [parent axs_cachekeeper_pdf_close];[_chain removeLastObject];
                if (_chain.count<_selectedChainLength) [self axs_cachekeeper_pdf_finish:code ? @"error" : @"finished" clear:NO];
                continue;
            }
            if (!strcmp(entry->d_name,".") || !strcmp(entry->d_name,"..")) continue;
            _enumerated++;processed++;
            if (![self axs_cachekeeper_pdf_checkpoint] || ![self axs_cachekeeper_pdf_validate_chain]) break;
            size_t length=strnlen(entry->d_name,sizeof(entry->d_name));
            NSString *name=length<sizeof(entry->d_name) ? [NSFileManager.defaultManager stringWithFileSystemRepresentation:entry->d_name length:length] : nil;
            if (!name || !name.length || strlen(name.fileSystemRepresentation)!=length || memcmp(name.fileSystemRepresentation,entry->d_name,length)) {
                [self axs_cachekeeper_pdf_failure:@"entryName" code:EILSEQ];continue;
            }
            NSString *relative=[parent.relative stringByAppendingFormat:@"/%@",name];
            if (!axs_cachekeeper_pdf_relative(relative) || axs_cachekeeper_protected_path(relative)) { _protected++;_coverage=NO;continue; }
            struct stat info;
            if (fstatat(parent.descriptor,name.fileSystemRepresentation,&info,AT_SYMLINK_NOFOLLOW)) { [self axs_cachekeeper_pdf_failure:@"fileStat" code:errno];continue; }
            if (![self axs_cachekeeper_pdf_checkpoint]) break;
            if (S_ISLNK(info.st_mode)) { _symlinks++;_coverage=NO;continue; }
            if (info.st_dev!=_chain.firstObject.identity.st_dev) { _special++;_coverage=NO;continue; }
            if (S_ISDIR(info.st_mode)) { [self axs_cachekeeper_pdf_open_directory:name relative:relative enumerate:YES];continue; }
            if (!S_ISREG(info.st_mode)) { _special++;_coverage=NO;continue; }
            [self axs_cachekeeper_pdf_read_file:name relative:relative parent:parent expected:info];
        }
        if (!_done && [self axs_cachekeeper_pdf_checkpoint] && _enumerated>=_limits.entryLimit) [self axs_cachekeeper_pdf_finish:@"entryLimit" clear:NO];
    } @finally { [_lock unlock]; }
}
- (void)requestCancellation { atomic_store(&_cancelRequested,true); }
- (void)cancel {
    atomic_store(&_cancelRequested,true);[_lock lock];
    @try { [self axs_cachekeeper_pdf_finish:@"cancelled" clear:YES]; } @finally { [_lock unlock]; }
}
- (BOOL)complete { [_lock lock];BOOL value=_done;[_lock unlock];return value; }
- (BOOL)revalidateCandidate:(NSString *)path containerFD:(int)containerFD error:(int *)code {
    if (code) *code=ESTALE;
    [_lock lock];NSData *identity=nil;
    if (!atomic_load(&_cancelRequested)) for (NSDictionary *candidate in _candidates)
        if ([candidate[@"path"] isEqual:path]) {identity=candidate[@"_identity"];break;}
    [_lock unlock];
    if (identity.length!=sizeof(struct stat) || !axs_cachekeeper_pdf_relative(path) || axs_cachekeeper_protected_path(path)) return NO;
    AxsCacheKeeperPDFInspection *check=[[AxsCacheKeeperPDFInspection alloc] initWithContainerFD:containerFD relativeDirectory:path.stringByDeletingLastPathComponent];
    if (check.complete || ![check axs_cachekeeper_pdf_validate_chain]) {if (code) *code=[check.report[@"errorCode"] intValue] ?: ESTALE;[check cancel];return NO;}
    struct stat expected,current;memcpy(&expected,identity.bytes,sizeof(expected));
    AxsCacheKeeperPDFDirectory *parent=check->_chain.lastObject;
    BOOL valid=[check axs_cachekeeper_pdf_file_entry:path.lastPathComponent parent:parent matches:expected];
    errno=0;int fd=valid ? openat(parent.descriptor,path.lastPathComponent.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC) : -1;
    int error=errno;
    valid=valid && fd>=0 && !fstat(fd,&current) && axs_cachekeeper_pdf_stable(expected,current) &&
        [check axs_cachekeeper_pdf_validate_chain] && [check axs_cachekeeper_pdf_file_entry:path.lastPathComponent parent:parent matches:current] && !atomic_load(&_cancelRequested);
    if (fd>=0) close(fd);[check cancel];if (code) *code=valid ? 0 : (error ?: ESTALE);return valid;
}
- (NSDictionary *)report {
    [_lock lock];
    @try {
        NSTimeInterval end=_done ? _finishedTime : _clock();if (!isfinite(end) || end<_started) end=_lastTime;
        NSMutableArray *candidates=[NSMutableArray new];
        for (NSDictionary *candidate in _candidates) [candidates addObject:@{@"path":candidate[@"path"],@"bytes":candidate[@"bytes"],@"linkCount":candidate[@"linkCount"]}];
        return @{@"inspectionMode":@"pdfLocate",@"complete":(_done ? @YES : @NO),@"stopReason":_stopReason,@"coverageComplete":(_done && _coverage ? @YES : @NO),
            @"enumeratedCount":@(_enumerated),@"sampleBytes":@(_sampleBytes),@"durationSeconds":@(MAX(0,end-_started)),
            @"regularPathCount":@(_regularPaths),@"pdfPathCount":@(_pdfPaths),@"pdfCandidates":[candidates copy],@"pdfCandidatesTruncated":(_pdfPaths>_candidates.count ? @YES : @NO),
            @"protectedCount":@(_protected),@"symbolicLinkCount":@(_symlinks),@"specialFileCount":@(_special),
            @"failureCount":@(_failures),@"readFailureCount":@(_readFailures),@"shortReadCount":@(_shortReads),@"changedCount":@(_changed),
            @"depthLimitedCount":@(_depthLimited),@"fdLimitedCount":@(_fdLimited),@"openDescriptorCount":@(_chain.count+(_activeFile>=0 ? 1u : 0u)),
            @"errorStage":_errorStage,@"errorDomain":_errorDomain,@"errorCode":@(_errorCode),
            @"budgets":@{@"entryLimit":@(_limits.entryLimit),@"sampleByteLimit":@(_limits.sampleByteLimit),@"seconds":@(_limits.seconds),
                @"depthLimit":@(_limits.depthLimit),@"descriptorLimit":@(_limits.descriptorLimit),@"batchEntries":@64,@"perFileBytes":@4096}};
    } @finally { [_lock unlock]; }
}
@end

#endif // AXS_CACHEKEEPER_PDF_CLIENT
