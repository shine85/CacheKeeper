#import <Foundation/Foundation.h>
#import "../AxsCacheKeeperCapacity.h"
#import "../AxsCacheKeeperScanTask.h"
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/mount.h>
#include <dirent.h>
#include <errno.h>
#import <objc/runtime.h>

// Expected totals come only from explicit fixture paths and independent OS lstat.
// Removing root/directory/link blocks, inode deduplication, byte-preserving
// observation, fail-closed budgets or cancellation must break these behaviors.
static void AxsCacheKeeperCapacityCheck(BOOL value,const char *message) {
    if(!value) {fprintf(stderr,"FAIL: capacity: %s\n",message);exit(1);}
}
static void AxsCacheKeeperCapacityMarker(const char *stage) {
    printf("MARK: capacity: %s\n",stage);fflush(stdout);
}
static void AxsCacheKeeperCapacitySetupCheck(BOOL value,int code,const char *operation) {
    if(!value) {fprintf(stderr,"SETUP-FAIL: capacity: %s errno=%d (%s)\n",operation,code,strerror(code));exit(2);}
}
static void AxsCacheKeeperCapacitySetupRequire(BOOL value,const char *message) {
    if(!value) {fprintf(stderr,"SETUP-FAIL: capacity: %s\n",message);exit(2);}
}
static NSString *AxsCacheKeeperCapacityDirectory(NSString *base,NSString *relative) {
    NSString *path=[base stringByAppendingPathComponent:relative];
    AxsCacheKeeperCapacityCheck([NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil],"fixture directory");
    return path;
}
static void AxsCacheKeeperCapacityFile(NSString *path,NSUInteger length) {
    int fd=open(path.fileSystemRepresentation,O_CREAT|O_EXCL|O_WRONLY,0600);
    AxsCacheKeeperCapacityCheck(fd>=0,"fixture file open");
    NSMutableData *data=[NSMutableData dataWithLength:length];
    if(length) memset(data.mutableBytes,0x5a,length);
    AxsCacheKeeperCapacityCheck(write(fd,data.bytes,data.length)==(ssize_t)data.length && !close(fd),"fixture file write");
}
static struct stat AxsCacheKeeperCapacityStat(NSString *path) {
    struct stat value;AxsCacheKeeperCapacityCheck(!lstat(path.fileSystemRepresentation,&value),"fixture lstat");return value;
}
// Swap only the cursor construction boundary in this isolated fixture. All
// lstat/open/fstat and observations remain production against real directories.
static NSString *AxsCacheKeeperCapacityABAAlias,*AxsCacheKeeperCapacityABAOriginal,*AxsCacheKeeperCapacityABAReplacement;
static NSUInteger AxsCacheKeeperCapacityABARoots,AxsCacheKeeperCapacityABAEntries;
static struct stat AxsCacheKeeperCapacityABAOpened;
@interface AxsCacheKeeperScanCursor (AxsCacheKeeperCapacityABABoundary)
- (instancetype)axs_cachekeeper_capacity_aba_initWithRoot:(NSURL *)root entryLimit:(NSUInteger)limit depthLimit:(NSUInteger)depth
                                      metadataObserver:(AxsCacheKeeperScanMetadataObserver)observer __attribute__((objc_method_family(init)));
@end
@implementation AxsCacheKeeperScanCursor (AxsCacheKeeperCapacityABABoundary)
- (instancetype)axs_cachekeeper_capacity_aba_initWithRoot:(NSURL *)root entryLimit:(NSUInteger)limit depthLimit:(NSUInteger)depth
                                      metadataObserver:(AxsCacheKeeperScanMetadataObserver)observer {
    AxsCacheKeeperCapacityCheck(!unlink(AxsCacheKeeperCapacityABAAlias.fileSystemRepresentation) &&
        !symlink(AxsCacheKeeperCapacityABAReplacement.fileSystemRepresentation,AxsCacheKeeperCapacityABAAlias.fileSystemRepresentation),"swap real alias before cursor open");
    // After the method swap this selector calls the original production initializer.
    return [self axs_cachekeeper_capacity_aba_initWithRoot:root entryLimit:limit depthLimit:depth
        metadataObserver:^(const struct stat *info,NSArray<NSData *> *components) {
            if(!components.count) {
                AxsCacheKeeperCapacityABARoots++;AxsCacheKeeperCapacityABAOpened=*info;
                AxsCacheKeeperCapacityCheck(!unlink(AxsCacheKeeperCapacityABAAlias.fileSystemRepresentation) &&
                    !symlink(AxsCacheKeeperCapacityABAOriginal.fileSystemRepresentation,AxsCacheKeeperCapacityABAAlias.fileSystemRepresentation),"restore real alias after actual opened stat");
            } else AxsCacheKeeperCapacityABAEntries++;
            observer(info,components);
        }];
}
@end
// Inject an actual pathname replacement exactly at final validation, after the
// production readdir stack has drained. The validation itself remains production.
@interface AxsCacheKeeperScanCursor (AxsCacheKeeperCapacityValidation)
- (BOOL)axs_cachekeeper_validate;
@end
@interface AxsCacheKeeperCapacityFinalValidationCursor : AxsCacheKeeperScanCursor
@property(nonatomic,copy) NSString *axs_cachekeeper_rootPath;
@property(nonatomic) NSUInteger axs_cachekeeper_validations;
@end
@implementation AxsCacheKeeperCapacityFinalValidationCursor
- (BOOL)axs_cachekeeper_validate {
    self.axs_cachekeeper_validations++;
    if(self.axs_cachekeeper_validations==2 && self.openDirectoryCount==0) {
        NSString *path=self.axs_cachekeeper_rootPath,*moved=[path stringByAppendingString:@"-moved"];
        AxsCacheKeeperCapacityCheck(!rename(path.fileSystemRepresentation,moved.fileSystemRepresentation),"replace root at final validation");
        AxsCacheKeeperCapacityDirectory(path.stringByDeletingLastPathComponent,path.lastPathComponent);
    }
    return [super axs_cachekeeper_validate];
}
@end
static uint64_t AxsCacheKeeperCapacityBlocks(NSString *path) {
    struct stat value=AxsCacheKeeperCapacityStat(path);
    AxsCacheKeeperCapacityCheck(value.st_blocks>=0,"nonnegative OS blocks");return (uint64_t)value.st_blocks*512;
}
static NSUInteger AxsCacheKeeperCapacityDescriptors(void) {
    struct rlimit limit;AxsCacheKeeperCapacityCheck(!getrlimit(RLIMIT_NOFILE,&limit),"descriptor limit");
    // Fixtures open only low descriptors; avoid walking an unlimited RLIMIT.
    NSUInteger count=0;for(int fd=0;fd<(int)MIN(limit.rlim_cur,(rlim_t)4096);fd++) if(fcntl(fd,F_GETFD)!=-1) count++;
    return count;
}
static void AxsCacheKeeperCapacityFinish(AxsCacheKeeperCapacityRoot *root,NSUInteger slice) {
    for(NSUInteger i=0;i<20000 && [root.state isEqual:@"running"];i++) [root advanceEntries:slice seconds:1];
    AxsCacheKeeperCapacityCheck(![root.state isEqual:@"running"],"bounded fixture completes");
}
static void AxsCacheKeeperCapacityClosedResult(NSDictionary *result) {
    NSSet *keys=[NSSet setWithArray:@[@"schemaVersion",@"state",@"logicalBytes",@"allocatedBytes",@"entries",@"uniqueInodes",@"duplicateInodes",@"nodes",@"entryLimit",@"depthLimit",@"inodeLimit",@"nodeLimit",@"deletionAuthorization",@"physicalUniqueBytes",@"reclaimableBytes",@"cursorErrors"]];
    AxsCacheKeeperCapacityCheck([[NSSet setWithArray:result.allKeys] isEqual:keys],"closed result has no identity or path fields");
    NSSet *nodeKeys=[NSSet setWithArray:@[@"id",@"parent",@"category",@"logicalBytes",@"allocatedBytes",@"entries"]];
    NSSet *categories=[NSSet setWithArray:@[@"unknown",@"Documents",@"Library",@"Caches",@"Application Support",@"tmp"]];
    for(NSDictionary *node in result[@"nodes"]) {
        AxsCacheKeeperCapacityCheck([[NSSet setWithArray:node.allKeys] isEqual:nodeKeys] && [categories containsObject:node[@"category"]],"closed anonymous node categories");
    }
    AxsCacheKeeperCapacityCheck([NSJSONSerialization isValidJSONObject:result] &&
        [NSPropertyListSerialization propertyList:result isValidForFormat:NSPropertyListBinaryFormat_v1_0],"result is JSON and plist serializable");
    AxsCacheKeeperCapacityCheck([result[@"deletionAuthorization"] isEqual:@"notGranted"] &&
        [result[@"physicalUniqueBytes"] isEqual:@"notMeasured"] && [result[@"reclaimableBytes"] isEqual:@"notMeasured"],"measurement never grants deletion or physical reclamation");
}
static void AxsCacheKeeperCapacityTotals(NSString *base) {
    NSString *path=AxsCacheKeeperCapacityDirectory(base,@"totals");
    NSString *documents=AxsCacheKeeperCapacityDirectory(path,@"Documents");
    NSString *library=AxsCacheKeeperCapacityDirectory(path,@"Library");
    NSString *caches=AxsCacheKeeperCapacityDirectory(path,@"Library/Caches");
    NSString *temporary=AxsCacheKeeperCapacityDirectory(path,@"tmp");
    NSString *secret=AxsCacheKeeperCapacityDirectory(path,@"private-owner-name");
    NSString *dense=[documents stringByAppendingPathComponent:@"private-document-name"],*alias=[caches stringByAppendingPathComponent:@"alias"];
    NSString *sparse=[temporary stringByAppendingPathComponent:@"sparse"],*empty=[path stringByAppendingPathComponent:@"empty"];
    NSString *other=[secret stringByAppendingPathComponent:@"private-content-name"],*symbol=[path stringByAppendingPathComponent:@"outside-link"];
    AxsCacheKeeperCapacityFile(dense,8192);AxsCacheKeeperCapacityFile(empty,0);AxsCacheKeeperCapacityFile(other,13);
    AxsCacheKeeperCapacityCheck(!link(dense.fileSystemRepresentation,alias.fileSystemRepresentation),"hard link fixture");
    int fd=open(sparse.fileSystemRepresentation,O_CREAT|O_EXCL|O_WRONLY,0600);char page[4096]={1};
    AxsCacheKeeperCapacityCheck(fd>=0 && !ftruncate(fd,8*1024*1024) && pwrite(fd,page,sizeof(page),0)==sizeof(page) && !close(fd),"sparse file fixture");
    NSString *outside=AxsCacheKeeperCapacityDirectory(base,@"outside");AxsCacheKeeperCapacityFile([outside stringByAppendingPathComponent:@"not-in-root"],65536);
    AxsCacheKeeperCapacityCheck(!symlink(outside.fileSystemRepresentation,symbol.fileSystemRepresentation),"external symlink fixture");
    uint64_t expected=0;for(NSString *item in @[path,documents,library,caches,temporary,secret,dense,sparse,empty,other,symbol]) expected+=AxsCacheKeeperCapacityBlocks(item);
    uint64_t logical=2*8192+8*1024*1024+13;
    AxsCacheKeeperCapacityCheck(AxsCacheKeeperCapacityBlocks(dense)>0,"hardlinked dense fixture has real allocated blocks");
    AxsCacheKeeperCapacityCheck(AxsCacheKeeperCapacityBlocks(sparse)<8*1024*1024,"OS sparse blocks differ from logical bytes");
    AxsCacheKeeperCapacityRoot *root=[[AxsCacheKeeperCapacityRoot alloc] initWithRoot:[NSURL fileURLWithPath:path]];
    AxsCacheKeeperCapacityFinish(root,1);NSDictionary *result=root.result;
    AxsCacheKeeperCapacityCheck([result[@"state"] isEqual:@"complete"] && [result[@"allocatedBytes"] unsignedLongLongValue]==expected,"all-entry allocation includes root directories and links once");
    AxsCacheKeeperCapacityCheck([result[@"logicalBytes"] unsignedLongLongValue]==logical && [result[@"entries"] unsignedIntegerValue]==12 && [result[@"uniqueInodes"] unsignedIntegerValue]==11 && [result[@"duplicateInodes"] unsignedIntegerValue]==1,"logical paths and hardlinked inode identities remain distinct measures");
    NSDictionary *rootNode=[result[@"nodes"] firstObject];
    AxsCacheKeeperCapacityCheck([rootNode[@"id"] isEqual:@1] && [rootNode[@"parent"] isEqual:@0] && [rootNode[@"logicalBytes"] unsignedLongLongValue]==logical && [rootNode[@"allocatedBytes"] unsignedLongLongValue]==expected && [rootNode[@"entries"] isEqual:@12],"root aggregation never double counts the root");
    AxsCacheKeeperCapacityCheck([result[@"entryLimit"] isEqual:@2000000] && [result[@"depthLimit"] isEqual:@64] && [result[@"inodeLimit"] isEqual:@262144] && [result[@"nodeLimit"] isEqual:@4096],"reported budgets describe enforced measurement limits");
    AxsCacheKeeperCapacityClosedResult(result);
    NSData *json=[NSJSONSerialization dataWithJSONObject:result options:0 error:nil];NSString *text=[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    AxsCacheKeeperCapacityCheck(![text containsString:@"private-owner-name"] && ![text containsString:@"private-document-name"] && ![text containsString:path],"serialized result never contains fixture names or paths");
    // Existing initializer still measures only ordinary logical paths and regular allocations.
    AxsCacheKeeperScanCursor *cursor=[[AxsCacheKeeperScanCursor alloc] initWithRoot:[NSURL fileURLWithPath:path] entryLimit:100 depthLimit:64];
    for(NSUInteger i=0;i<1000 && [cursor.state isEqual:@"running"];i++) [cursor advanceEntries:1 seconds:1];
    uint64_t regular=AxsCacheKeeperCapacityBlocks(dense)+AxsCacheKeeperCapacityBlocks(sparse)+AxsCacheKeeperCapacityBlocks(empty)+AxsCacheKeeperCapacityBlocks(other);
    AxsCacheKeeperCapacityCheck([cursor.state isEqual:@"complete"] && [cursor.result[@"bytes"] unsignedLongLongValue]==logical && [cursor.result[@"allocationObservation"][@"allocatedBytes"] unsignedLongLongValue]==regular,"legacy scan initializer retains its original regular-file scope");
}
static void AxsCacheKeeperCapacityEmpty(NSString *base) {
    NSString *path=AxsCacheKeeperCapacityDirectory(base,@"empty-root");uint64_t blocks=AxsCacheKeeperCapacityBlocks(path);
    AxsCacheKeeperCapacityRoot *root=[[AxsCacheKeeperCapacityRoot alloc] initWithRoot:[NSURL fileURLWithPath:path]];
    AxsCacheKeeperCapacityFinish(root,1);NSDictionary *result=root.result,*node=[result[@"nodes"] firstObject];
    AxsCacheKeeperCapacityCheck([result[@"state"] isEqual:@"complete"] && [result[@"allocatedBytes"] unsignedLongLongValue]==blocks && [result[@"logicalBytes"] isEqual:@0] && [result[@"entries"] isEqual:@1] && [result[@"uniqueInodes"] isEqual:@1] && [result[@"nodes"] count]==1 && [node[@"allocatedBytes"] unsignedLongLongValue]==blocks && [node[@"entries"] isEqual:@1],"empty root is observed once and has real directory allocation");
}
// APFS accepts valid UTF-8 and preserves its normalization. Use decomposed UTF-8,
// multibyte characters and controls, never require ff/fe filenames on APFS:
// https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/APFS_Guide/FAQ/FAQ.html
static const char AxsCacheKeeperCapacityRawDirectory[]={'d','-','e',(char)0xcc,(char)0x81,'-',(char)0xe4,(char)0xb8,(char)0xad,'\t','\n',0};
static const char AxsCacheKeeperCapacityRawFile[]={'f','-',(char)0xf0,(char)0x9f,(char)0x93,(char)0xa6,'\t','\n',0};
static void AxsCacheKeeperCapacityRawEntry(int fd,const char *name) {
    int copy=dup(fd);AxsCacheKeeperCapacitySetupCheck(copy>=0,errno,"dup raw fixture directory");
    DIR *directory=fdopendir(copy);AxsCacheKeeperCapacitySetupCheck(directory!=NULL,errno,"fdopendir raw fixture directory");
    BOOL found=NO;
    for(;;) {
        errno=0;struct dirent *entry=readdir(directory);int code=errno;
        if(!entry) {AxsCacheKeeperCapacitySetupCheck(!code,code,"readdir raw fixture directory");break;}
        if(!strcmp(entry->d_name,name)) found=YES;
    }
    int result=closedir(directory);AxsCacheKeeperCapacitySetupCheck(!result,errno,"closedir raw fixture directory");
    AxsCacheKeeperCapacitySetupRequire(found,"filesystem must preserve raw fixture name bytes");
}
static NSString *AxsCacheKeeperCapacityRawFixture(NSString *base) {
    NSString *path=AxsCacheKeeperCapacityDirectory(base,@"raw-observer");
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_CLOEXEC);
    AxsCacheKeeperCapacitySetupCheck(fd>=0,errno,"open raw fixture root");
    struct statfs filesystem;int result=fstatfs(fd,&filesystem);
    AxsCacheKeeperCapacitySetupCheck(!result,errno,"fstatfs raw fixture root");
    fprintf(stdout,"FIXTURE: capacity: filesystem=%s directoryBytes=%zu fileBytes=%zu valid UTF8/decomposed/tab/newline\n",
        filesystem.f_fstypename,sizeof(AxsCacheKeeperCapacityRawDirectory)-1,sizeof(AxsCacheKeeperCapacityRawFile)-1);fflush(stdout);
    result=mkdirat(fd,AxsCacheKeeperCapacityRawDirectory,0700);
    AxsCacheKeeperCapacitySetupCheck(!result,errno,"mkdirat raw-byte directory fixture");
    int child=openat(fd,AxsCacheKeeperCapacityRawDirectory,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    AxsCacheKeeperCapacitySetupCheck(child>=0,errno,"openat raw-byte directory fixture");
    int data=openat(child,AxsCacheKeeperCapacityRawFile,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW|O_CLOEXEC,0600);
    AxsCacheKeeperCapacitySetupCheck(data>=0,errno,"openat raw-byte file fixture");
    ssize_t count=write(data,"abc",3);int code=errno;
    AxsCacheKeeperCapacitySetupCheck(count>=0,code,"write raw-byte file fixture");
    AxsCacheKeeperCapacitySetupRequire(count==3,"raw-byte file fixture writes all three bytes");
    result=close(data);AxsCacheKeeperCapacitySetupCheck(!result,errno,"close raw-byte file fixture");
    AxsCacheKeeperCapacityRawEntry(fd,AxsCacheKeeperCapacityRawDirectory);AxsCacheKeeperCapacityRawEntry(child,AxsCacheKeeperCapacityRawFile);
    struct stat info;result=fstatat(child,AxsCacheKeeperCapacityRawFile,&info,AT_SYMLINK_NOFOLLOW);
    AxsCacheKeeperCapacitySetupCheck(!result,errno,"fstatat raw-byte file fixture");
    AxsCacheKeeperCapacitySetupRequire(S_ISREG(info.st_mode) && info.st_size==3,"raw fixture OS metadata");
    result=close(child);AxsCacheKeeperCapacitySetupCheck(!result,errno,"close raw-byte directory fixture");
    result=symlinkat(base.fileSystemRepresentation,fd,"link");AxsCacheKeeperCapacitySetupCheck(!result,errno,"symlinkat fixture");
    result=mkfifoat(fd,"fifo",0600);AxsCacheKeeperCapacitySetupCheck(!result,errno,"mkfifoat fixture");
    result=close(fd);AxsCacheKeeperCapacitySetupCheck(!result,errno,"close raw fixture root");return path;
}
static void AxsCacheKeeperCapacityRawSetup(NSString *base) {(void)AxsCacheKeeperCapacityRawFixture(base);}
static void AxsCacheKeeperCapacityObserver(NSString *base) {
    NSString *path=AxsCacheKeeperCapacityRawFixture(base);
    NSMutableArray *observations=[NSMutableArray new];
    AxsCacheKeeperCapacityMarker("observer valid block init begin");
    AxsCacheKeeperScanCursor *cursor=[[AxsCacheKeeperScanCursor alloc] initWithRoot:[NSURL fileURLWithPath:path] entryLimit:100 depthLimit:64 metadataObserver:^(const struct stat *info,NSArray<NSData *> *components) {
        [observations addObject:@{ @"components":components,@"mode":@(info->st_mode),@"blocks":@(info->st_blocks) }];
    }];
    AxsCacheKeeperCapacityMarker("observer valid block init end; enumeration begin");
    for(NSUInteger i=0;i<1000 && [cursor.state isEqual:@"running"];i++) [cursor advanceEntries:1 seconds:1];
    AxsCacheKeeperCapacityMarker("observer enumeration end");
    NSArray *rawDirectory=@[[NSData dataWithBytes:AxsCacheKeeperCapacityRawDirectory length:sizeof(AxsCacheKeeperCapacityRawDirectory)-1]],
        *rawFile=@[rawDirectory[0],[NSData dataWithBytes:AxsCacheKeeperCapacityRawFile length:sizeof(AxsCacheKeeperCapacityRawFile)-1]];
    BOOL foundDirectory=NO,foundFile=NO,foundLink=NO,foundFIFO=NO;
    for(NSDictionary *observation in observations) {
        mode_t mode=[observation[@"mode"] unsignedIntValue];NSArray *components=observation[@"components"];
        if([components isEqual:rawDirectory] && S_ISDIR(mode)) foundDirectory=YES;
        if([components isEqual:rawFile] && S_ISREG(mode)) foundFile=YES;
        if(S_ISLNK(mode)) foundLink=YES;if(S_ISFIFO(mode)) foundFIFO=YES;
    }
    AxsCacheKeeperCapacityCheck([cursor.state isEqual:@"complete"] && observations.count==5 && [observations[0][@"components"] count]==0 && foundDirectory && foundFile && foundLink && foundFIFO,"observer receives root and every raw-byte entry without following links");
    AxsCacheKeeperCapacityCheck([cursor.result[@"allocationObservation"] count]==0,"observer mode retains no unrelated legacy inode observations");
    AxsCacheKeeperCapacityMarker("observer capacity init begin");
    AxsCacheKeeperCapacityRoot *root=[[AxsCacheKeeperCapacityRoot alloc] initWithRoot:[NSURL fileURLWithPath:path]];
    AxsCacheKeeperCapacityMarker("observer capacity init end; measurement begin");
    AxsCacheKeeperCapacityFinish(root,1);AxsCacheKeeperCapacityCheck([root.state isEqual:@"complete"] && [root.result[@"entries"] isEqual:@5] && [root.result[@"logicalBytes"] isEqual:@3],"raw UTF8/control components need no string decoding to measure");AxsCacheKeeperCapacityClosedResult(root.result);
    AxsCacheKeeperCapacityMarker("observer measurement and closed result end");
}
static NSUInteger AxsCacheKeeperCapacityGlobalObserverCalls;
static void AxsCacheKeeperCapacityObserverOwnership(NSString *base) {
    NSString *path=AxsCacheKeeperCapacityDirectory(base,@"observer-ownership"),*file=[path stringByAppendingPathComponent:@"data"];
    AxsCacheKeeperCapacityFile(file,7);NSURL *url=[NSURL fileURLWithPath:path];
    AxsCacheKeeperCapacityGlobalObserverCalls=0;
    AxsCacheKeeperScanMetadataObserver global=^(const struct stat *info,NSArray<NSData *> *components) {
        if(info && components) AxsCacheKeeperCapacityGlobalObserverCalls++;
    };
    AxsCacheKeeperCapacityMarker("observer ownership global init begin");
    AxsCacheKeeperScanCursor *cursor=[[AxsCacheKeeperScanCursor alloc] initWithRoot:url entryLimit:100 depthLimit:64 metadataObserver:global];
    for(NSUInteger i=0;i<1000 && [cursor.state isEqual:@"running"];i++) [cursor advanceEntries:1 seconds:1];
    AxsCacheKeeperCapacityCheck([cursor.state isEqual:@"complete"] && AxsCacheKeeperCapacityGlobalObserverCalls==2,"global observer receives the opened root and file");
    AxsCacheKeeperCapacityMarker("observer ownership global end");cursor=nil;
    for(NSNumber *copyBefore in @[@NO,@YES]) {
        __block NSUInteger calls=0;__weak NSObject *weakCapture=nil;
        @autoreleasepool {
            NSObject *capture=[NSObject new];weakCapture=capture;
            // The direct capturing literal starts on the stack. The cursor must
            // own a copy; the second variant supplies an explicit heap copy.
            __unsafe_unretained AxsCacheKeeperScanMetadataObserver stack=^(const struct stat *info,NSArray<NSData *> *components) {
                if(capture && info && components) calls++;
            };
            AxsCacheKeeperCapacityMarker(copyBefore.boolValue ? "observer ownership heap init begin" : "observer ownership stack init begin");
            if(copyBefore.boolValue) {
                AxsCacheKeeperScanMetadataObserver heap=[stack copy];
                cursor=[[AxsCacheKeeperScanCursor alloc] initWithRoot:url entryLimit:100 depthLimit:64 metadataObserver:heap];
            } else cursor=[[AxsCacheKeeperScanCursor alloc] initWithRoot:url entryLimit:100 depthLimit:64 metadataObserver:stack];
        }
        AxsCacheKeeperCapacityCheck(weakCapture!=nil && calls==1,"captured observer survives its source autorelease scope");
        AxsCacheKeeperCapacityMarker("observer ownership source scope drained; enumeration begin");
        for(NSUInteger i=0;i<1000 && [cursor.state isEqual:@"running"];i++) [cursor advanceEntries:1 seconds:1];
        AxsCacheKeeperCapacityCheck([cursor.state isEqual:@"complete"] && calls==2,"retained captured observer receives later file metadata");
        cursor=nil;AxsCacheKeeperCapacityCheck(weakCapture==nil,"releasing cursor releases the observer capture");
        AxsCacheKeeperCapacityMarker("observer ownership enumeration and release end");
    }
    AxsCacheKeeperCapacityMarker("observer ownership nil init begin");
    cursor=[[AxsCacheKeeperScanCursor alloc] initWithRoot:url entryLimit:100 depthLimit:64 metadataObserver:nil];
    for(NSUInteger i=0;i<1000 && [cursor.state isEqual:@"running"];i++) [cursor advanceEntries:1 seconds:1];
    AxsCacheKeeperCapacityCheck([cursor.state isEqual:@"complete"] && [cursor.result[@"bytes"] isEqual:@7] &&
        [cursor.result[@"allocationObservation"][@"allocatedBytes"] unsignedLongLongValue]==AxsCacheKeeperCapacityBlocks(file),"nil observer preserves legacy regular-file allocation");
    AxsCacheKeeperCapacityMarker("observer ownership nil end");
}
@interface AxsCacheKeeperCapacityRoot (AxsCacheKeeperCapacityObserverBoundary)
- (void)axs_cachekeeper_observe:(const struct stat *)info components:(NSArray<NSData *> *)components;
@end
static void AxsCacheKeeperCapacityInvalidObserver(NSString *base) {
    // APFS cannot create invalid UTF-8 names. This is only the byte-key observer
    // input boundary, using real OS metadata; it does NOT claim such files exist.
    NSString *path=AxsCacheKeeperCapacityDirectory(base,@"invalid-observer-input");
    NSString *first=AxsCacheKeeperCapacityDirectory(path,@"first"),*second=AxsCacheKeeperCapacityDirectory(path,@"second");
    NSString *file=[first stringByAppendingPathComponent:@"data"];AxsCacheKeeperCapacityFile(file,3);
    struct stat a=AxsCacheKeeperCapacityStat(first),b=AxsCacheKeeperCapacityStat(second),c=AxsCacheKeeperCapacityStat(file);
    const unsigned char firstBytes[]={'d',0xff},secondBytes[]={'d',0xfe},fileBytes[]={'f',0xfd};
    NSData *one=[NSData dataWithBytes:firstBytes length:sizeof(firstBytes)],*two=[NSData dataWithBytes:secondBytes length:sizeof(secondBytes)];
    AxsCacheKeeperCapacityRoot *root=[[AxsCacheKeeperCapacityRoot alloc] initWithRoot:[NSURL fileURLWithPath:path]];
    [root axs_cachekeeper_observe:&a components:@[one]];[root axs_cachekeeper_observe:&b components:@[two]];
    [root axs_cachekeeper_observe:&c components:@[one,[NSData dataWithBytes:fileBytes length:sizeof(fileBytes)]]];
    uint64_t allocated=AxsCacheKeeperCapacityBlocks(path)+AxsCacheKeeperCapacityBlocks(first)+AxsCacheKeeperCapacityBlocks(second)+AxsCacheKeeperCapacityBlocks(file);
    AxsCacheKeeperCapacityCheck([root.state isEqual:@"running"] && [root.result[@"entries"] isEqual:@4] &&
        [root.result[@"nodes"] count]==3 && [root.result[@"logicalBytes"] isEqual:@3] &&
        [root.result[@"allocatedBytes"] unsignedLongLongValue]==allocated,
        "invalid UTF8 observer byte keys stay distinct without filesystem creation");
    [root stopWithState:@"cancelled"];AxsCacheKeeperCapacityClosedResult(root.result);
}
static void AxsCacheKeeperCapacityCategories(NSString *base) {
    NSString *path=AxsCacheKeeperCapacityDirectory(base,@"categories");
    NSArray *directories=@[@"Documents",@"Documents/Library",@"Documents/Library/Caches",@"Library",@"Library/Caches",@"Library/Application Support",@"Library/tmp",@"Library/opaque",@"Library/opaque/Caches",@"tmp",@"opaque",@"opaque/Caches",@"Library/Application Support/secret",@"Library/Application Support/secret/deeper"];
    for(NSString *relative in directories) AxsCacheKeeperCapacityDirectory(path,relative);
    NSString *file=[path stringByAppendingPathComponent:@"Library/Application Support/secret/deeper/opaque-content"];
    AxsCacheKeeperCapacityFile(file,7);
    uint64_t support=0;for(NSString *relative in @[@"Library/Application Support",@"Library/Application Support/secret",@"Library/Application Support/secret/deeper",@"Library/Application Support/secret/deeper/opaque-content"]) support+=AxsCacheKeeperCapacityBlocks([path stringByAppendingPathComponent:relative]);
    AxsCacheKeeperCapacityRoot *root=[[AxsCacheKeeperCapacityRoot alloc] initWithRoot:[NSURL fileURLWithPath:path]];
    AxsCacheKeeperCapacityFinish(root,1);NSMutableDictionary *counts=[NSMutableDictionary new];NSDictionary *supportNode=nil;
    NSMutableSet *ids=[NSMutableSet new];for(NSDictionary *node in root.result[@"nodes"]) {
        NSString *category=node[@"category"];counts[category]=@([counts[category] unsignedIntegerValue]+1);
        AxsCacheKeeperCapacityCheck(![ids containsObject:node[@"id"]],"anonymous node ids unique");[ids addObject:node[@"id"]];
        if([category isEqual:@"Application Support"]) supportNode=node;
    }
    AxsCacheKeeperCapacityCheck([root.state isEqual:@"complete"] && [counts[@"Documents"] isEqual:@1] && [counts[@"Library"] isEqual:@1] && [counts[@"Caches"] isEqual:@1] && [counts[@"Application Support"] isEqual:@1] && [counts[@"tmp"] isEqual:@1] && [counts[@"unknown"] isEqual:@9],"standard categories apply only at their exact container positions");
    AxsCacheKeeperCapacityCheck([root.result[@"nodes"] count]==14 && [supportNode[@"logicalBytes"] isEqual:@7] && [supportNode[@"allocatedBytes"] unsignedLongLongValue]==support && [supportNode[@"entries"] isEqual:@4],"deep entries aggregate into all retained ancestors without extra nodes");
    for(NSDictionary *node in root.result[@"nodes"]) AxsCacheKeeperCapacityCheck([node[@"parent"] isEqual:@0] || [ids containsObject:node[@"parent"]],"every anonymous parent is present");
    AxsCacheKeeperCapacityClosedResult(root.result);
}
static void AxsCacheKeeperCapacitySlices(NSString *base) {
    NSString *path=AxsCacheKeeperCapacityDirectory(base,@"slices");for(NSUInteger i=0;i<600;i++) AxsCacheKeeperCapacityFile([path stringByAppendingPathComponent:[NSString stringWithFormat:@"file-%lu",(unsigned long)i]],1);
    AxsCacheKeeperCapacityRoot *root=[[AxsCacheKeeperCapacityRoot alloc] initWithRoot:[NSURL fileURLWithPath:path]];
    [root advanceEntries:0 seconds:1];AxsCacheKeeperCapacityCheck([root.result[@"entries"] isEqual:@1],"zero-entry advance cannot consume filesystem entries");
    [root advanceEntries:600 seconds:1];NSDictionary *before=root.result;
    AxsCacheKeeperCapacityCheck([root.state isEqual:@"running"] && [before[@"entries"] unsignedIntegerValue]<=513 && [before[@"entries"] unsignedIntegerValue]>1,"single capacity advance respects the production slice entry bound");
    AxsCacheKeeperCapacityFinish(root,1);AxsCacheKeeperCapacityCheck([root.state isEqual:@"complete"] && [root.result[@"entries"] isEqual:@601] && [root.result[@"logicalBytes"] isEqual:@600] && [root.result[@"uniqueInodes"] isEqual:@601],"small slices retain all file observations");
    AxsCacheKeeperCapacityCheck([before[@"entries"] unsignedIntegerValue]<601 && [[[before[@"nodes"] firstObject] objectForKey:@"entries"] isEqual:before[@"entries"]],"published snapshots never change during later slices");
}
static void AxsCacheKeeperCapacityCancellation(NSString *base) {
    NSString *path=AxsCacheKeeperCapacityDirectory(base,@"cancellation");for(NSUInteger i=0;i<10;i++) AxsCacheKeeperCapacityFile([path stringByAppendingPathComponent:[NSString stringWithFormat:@"file-%lu",(unsigned long)i]],4);
    NSUInteger descriptors=AxsCacheKeeperCapacityDescriptors();
    AxsCacheKeeperCapacityRoot *root=[[AxsCacheKeeperCapacityRoot alloc] initWithRoot:[NSURL fileURLWithPath:path]];
    [root advanceEntries:1 seconds:1];[root stopWithState:@"cancelled"];NSDictionary *before=root.result;[root advanceEntries:100 seconds:1];[root stopWithState:@"timeLimit"];
    AxsCacheKeeperCapacityCheck([root.state isEqual:@"cancelled"] && [root.result isEqual:before] && [before[@"entries"] isEqual:@2],"cancelled measurement cannot advance or become complete");
    AxsCacheKeeperCapacityCheck(AxsCacheKeeperCapacityDescriptors()==descriptors,"cancelled measurement releases its actual directory descriptors");
    root=[[AxsCacheKeeperCapacityRoot alloc] initWithRoot:[NSURL fileURLWithPath:path]];[root stopWithState:@"timeLimit"];
    AxsCacheKeeperCapacityCheck([root.state isEqual:@"timeLimit"] && [root.result[@"entries"] isEqual:@1],"caller time budget produces an explicit incomplete state");
    root=[[AxsCacheKeeperCapacityRoot alloc] initWithRoot:[NSURL fileURLWithPath:path]];[root stopWithState:@"complete"];
    AxsCacheKeeperCapacityCheck(![root.state isEqual:@"complete"] && ![root.state isEqual:@"running"],"caller cannot fabricate a successful terminal state");
}
static void AxsCacheKeeperCapacityIdentity(NSString *base) {
    NSString *path=AxsCacheKeeperCapacityDirectory(base,@"identity");AxsCacheKeeperCapacityFile([path stringByAppendingPathComponent:@"a"],3);AxsCacheKeeperCapacityFile([path stringByAppendingPathComponent:@"b"],3);
    AxsCacheKeeperCapacityRoot *root=[[AxsCacheKeeperCapacityRoot alloc] initWithRoot:[NSURL fileURLWithPath:path]];
    [root advanceEntries:1 seconds:1];NSString *moved=[base stringByAppendingPathComponent:@"renamed-root"];
    AxsCacheKeeperCapacityCheck(!rename(path.fileSystemRepresentation,moved.fileSystemRepresentation),"rename actual root");AxsCacheKeeperCapacityDirectory(base,@"identity");
    [root advanceEntries:100 seconds:1];AxsCacheKeeperCapacityCheck([root.state isEqual:@"identityChanged"],"replaced root never completes under its old identity");
    NSString *during=AxsCacheKeeperCapacityDirectory(base,@"during-slice");AxsCacheKeeperCapacityFile([during stringByAppendingPathComponent:@"file"],1);
    __block BOOL changed=NO;AxsCacheKeeperScanCursor *cursor=[[AxsCacheKeeperScanCursor alloc] initWithRoot:[NSURL fileURLWithPath:during] entryLimit:100 depthLimit:64 metadataObserver:^(const struct stat *info,NSArray<NSData *> *components) {
        (void)info;if(components.count && !changed) {changed=YES;AxsCacheKeeperCapacityFile([during stringByAppendingPathComponent:@"new-entry"],1);}
    }];
    [cursor advanceEntries:100 seconds:1];AxsCacheKeeperCapacityCheck(changed && [cursor.state isEqual:@"identityChanged"] && cursor.openDirectoryCount==0,"post-slice validation rejects a root changed during traversal");
    NSString *final=AxsCacheKeeperCapacityDirectory(base,@"final-validation");
    AxsCacheKeeperCapacityFinalValidationCursor *finalCursor=[[AxsCacheKeeperCapacityFinalValidationCursor alloc] initWithRoot:[NSURL fileURLWithPath:final] entryLimit:100 depthLimit:64 metadataObserver:^(const struct stat *info,NSArray<NSData *> *components) {(void)info;(void)components;}];
    finalCursor.axs_cachekeeper_rootPath=final;[finalCursor advanceEntries:100 seconds:1];
    AxsCacheKeeperCapacityCheck(finalCursor.axs_cachekeeper_validations==2 && [finalCursor.state isEqual:@"identityChanged"] && finalCursor.openDirectoryCount==0,"empty-stack final validation still checks the root pathname");
    NSString *alias=[base stringByAppendingPathComponent:@"root-link"];AxsCacheKeeperCapacityCheck(!symlink(moved.fileSystemRepresentation,alias.fileSystemRepresentation),"root symlink fixture");
    root=[[AxsCacheKeeperCapacityRoot alloc] initWithRoot:[NSURL fileURLWithPath:alias]];
    AxsCacheKeeperCapacityCheck([root.state isEqual:@"readError"] && [root.result[@"entries"] isEqual:@0],"root symlink is not traversed or reported as an empty success");
    root=[[AxsCacheKeeperCapacityRoot alloc] initWithRoot:[NSURL fileURLWithPath:[base stringByAppendingPathComponent:@"missing"]]];
    AxsCacheKeeperCapacityCheck([root.state isEqual:@"readError"],"missing root is an explicit read failure");
}
static void AxsCacheKeeperCapacityExpectedIdentity(NSString *base) {
    NSString *original=AxsCacheKeeperCapacityDirectory(base,@"aba-original"),*replacement=AxsCacheKeeperCapacityDirectory(base,@"aba-replacement");
    NSString *rootPath=AxsCacheKeeperCapacityDirectory(original,@"container"),*otherPath=AxsCacheKeeperCapacityDirectory(replacement,@"container");
    NSString *file=[rootPath stringByAppendingPathComponent:@"protected-data"];
    AxsCacheKeeperCapacityFile(file,17);AxsCacheKeeperCapacityFile([otherPath stringByAppendingPathComponent:@"different-data"],31);
    struct stat expected=AxsCacheKeeperCapacityStat(rootPath),other=AxsCacheKeeperCapacityStat(otherPath);
    AxsCacheKeeperCapacityCheck(expected.st_dev!=other.st_dev || expected.st_ino!=other.st_ino,"distinct actual root identities");
    AxsCacheKeeperCapacityABAAlias=[base stringByAppendingPathComponent:@"aba-parent"];
    AxsCacheKeeperCapacityABAOriginal=original;AxsCacheKeeperCapacityABAReplacement=replacement;
    AxsCacheKeeperCapacityCheck(!symlink(original.fileSystemRepresentation,AxsCacheKeeperCapacityABAAlias.fileSystemRepresentation),"initial real alias");
    NSString *aliasPath=[AxsCacheKeeperCapacityABAAlias stringByAppendingPathComponent:@"container"];
    struct stat before=AxsCacheKeeperCapacityStat(aliasPath);
    NSUInteger descriptors=AxsCacheKeeperCapacityDescriptors();
    Method production=class_getInstanceMethod(AxsCacheKeeperScanCursor.class,@selector(initWithRoot:entryLimit:depthLimit:metadataObserver:));
    Method boundary=class_getInstanceMethod(AxsCacheKeeperScanCursor.class,@selector(axs_cachekeeper_capacity_aba_initWithRoot:entryLimit:depthLimit:metadataObserver:));
    AxsCacheKeeperCapacityCheck(production && boundary,"real cursor open-boundary selector");
    method_exchangeImplementations(production,boundary);
    AxsCacheKeeperCapacityRoot *root=[[AxsCacheKeeperCapacityRoot alloc] initWithRoot:[NSURL fileURLWithPath:aliasPath]
        expectedDevice:expected.st_dev expectedInode:expected.st_ino];
    method_exchangeImplementations(production,boundary);
    struct stat after=AxsCacheKeeperCapacityStat(aliasPath);
    AxsCacheKeeperCapacityCheck(before.st_dev==expected.st_dev && before.st_ino==expected.st_ino &&
        after.st_dev==expected.st_dev && after.st_ino==expected.st_ino && AxsCacheKeeperCapacityABARoots==1 &&
        AxsCacheKeeperCapacityABAOpened.st_dev==other.st_dev && AxsCacheKeeperCapacityABAOpened.st_ino==other.st_ino,
        "ABA pre/post pathname checks pass while real opened FD is a different root");
    NSDictionary *rejected=root.result;
    AxsCacheKeeperCapacityCheck([root.state isEqual:@"identityChanged"] && [rejected[@"entries"] isEqual:@0] &&
        [rejected[@"uniqueInodes"] isEqual:@0] && [rejected[@"duplicateInodes"] isEqual:@0] && ![rejected[@"nodes"] count] &&
        [rejected[@"logicalBytes"] isEqual:@0] && [rejected[@"allocatedBytes"] isEqual:@0],
        "opened root expected identity rejects ABA before any metadata accumulation");
    AxsCacheKeeperScanCursor *cursor=[root valueForKey:@"cursor"];
    AxsCacheKeeperCapacityCheck([cursor.state isEqual:@"identityChanged"] && cursor.openDirectoryCount==0 &&
        AxsCacheKeeperCapacityDescriptors()==descriptors,"expected identity rejection closes actual cursor FD during initialization");
    [root advanceEntries:512 seconds:1];
    AxsCacheKeeperCapacityCheck([root.result isEqual:rejected] && !AxsCacheKeeperCapacityABAEntries,"rejected opened root never traverses descendants");
    AxsCacheKeeperCapacityClosedResult(rejected);
    // Exact native types compare each component independently, without sentinels.
    root=[[AxsCacheKeeperCapacityRoot alloc] initWithRoot:[NSURL fileURLWithPath:rootPath]
        expectedDevice:expected.st_dev expectedInode:(ino_t)((uint64_t)expected.st_ino^1ULL)];
    AxsCacheKeeperCapacityCheck([root.state isEqual:@"identityChanged"] && [root.result[@"entries"] isEqual:@0],"expected inode mismatch cannot observe the root");
    root=[[AxsCacheKeeperCapacityRoot alloc] initWithRoot:[NSURL fileURLWithPath:rootPath]
        expectedDevice:(dev_t)((uint64_t)expected.st_dev^1ULL) expectedInode:expected.st_ino];
    AxsCacheKeeperCapacityCheck([root.state isEqual:@"identityChanged"] && [root.result[@"entries"] isEqual:@0],"expected device mismatch cannot observe the root");
    root=[[AxsCacheKeeperCapacityRoot alloc] initWithRoot:[NSURL fileURLWithPath:aliasPath]
        expectedDevice:expected.st_dev expectedInode:expected.st_ino];
    AxsCacheKeeperCapacityFinish(root,1);
    uint64_t allocated=AxsCacheKeeperCapacityBlocks(rootPath)+AxsCacheKeeperCapacityBlocks(file);
    AxsCacheKeeperCapacityCheck([root.state isEqual:@"complete"] && [root.result[@"entries"] isEqual:@2] &&
        [root.result[@"logicalBytes"] isEqual:@17] && [root.result[@"allocatedBytes"] unsignedLongLongValue]==allocated,
        "matching expected opened root uses independent OS stat totals");
    root=[[AxsCacheKeeperCapacityRoot alloc] initWithRoot:[NSURL fileURLWithPath:otherPath]];AxsCacheKeeperCapacityFinish(root,1);
    AxsCacheKeeperCapacityCheck([root.state isEqual:@"complete"] && [root.result[@"logicalBytes"] isEqual:@31],"unbound legacy initializer still accepts its actual root");
}
static void AxsCacheKeeperCapacityMetadata(NSString *base) {
    NSString *path=AxsCacheKeeperCapacityDirectory(base,@"metadata");AxsCacheKeeperCapacityDirectory(path,@"a");AxsCacheKeeperCapacityDirectory(path,@"b");
    NSString *file=[path stringByAppendingPathComponent:@"a/original"],*alias=[path stringByAppendingPathComponent:@"b/alias"];
    AxsCacheKeeperCapacityFile(file,5);AxsCacheKeeperCapacityCheck(!link(file.fileSystemRepresentation,alias.fileSystemRepresentation),"metadata hard link");
    AxsCacheKeeperCapacityRoot *root=[[AxsCacheKeeperCapacityRoot alloc] initWithRoot:[NSURL fileURLWithPath:path]];
    for(NSUInteger i=0;i<100 && [root.result[@"logicalBytes"] unsignedLongLongValue]==0 && [root.state isEqual:@"running"];i++) [root advanceEntries:1 seconds:1];
    AxsCacheKeeperCapacityCheck([root.state isEqual:@"running"] && [root.result[@"logicalBytes"] isEqual:@5],"first hardlinked path observed before mutation");
    int fd=open(file.fileSystemRepresentation,O_WRONLY);AxsCacheKeeperCapacityCheck(fd>=0 && !ftruncate(fd,11) && !close(fd),"mutate real same inode metadata");
    AxsCacheKeeperCapacityFinish(root,1);AxsCacheKeeperCapacityCheck([root.state isEqual:@"invalidMetadata"],"changed same inode metadata cannot finish successfully");
}
static void AxsCacheKeeperCapacityBudgets(NSString *base) {
    NSString *path=AxsCacheKeeperCapacityDirectory(base,@"budgets");AxsCacheKeeperCapacityFile([path stringByAppendingPathComponent:@"a"],1);AxsCacheKeeperCapacityFile([path stringByAppendingPathComponent:@"b"],1);
    AxsCacheKeeperCapacityRoot *root=[[AxsCacheKeeperCapacityRoot alloc] initWithRoot:[NSURL fileURLWithPath:path] entryLimit:2 depthLimit:64 inodeLimit:262144 nodeLimit:4096];
    AxsCacheKeeperCapacityFinish(root,1);AxsCacheKeeperCapacityCheck([root.state isEqual:@"entryLimit"] && [root.result[@"entries"] isEqual:@2],"entry budget includes root and cannot silently complete");
    root=[[AxsCacheKeeperCapacityRoot alloc] initWithRoot:[NSURL fileURLWithPath:path] entryLimit:100 depthLimit:64 inodeLimit:2 nodeLimit:4096];
    AxsCacheKeeperCapacityFinish(root,1);AxsCacheKeeperCapacityCheck([root.state isEqual:@"inodeLimit"] && [root.result[@"uniqueInodes"] isEqual:@2],"inode budget exhaustion remains an incomplete measurement");
    NSString *nodes=AxsCacheKeeperCapacityDirectory(base,@"node-budget");AxsCacheKeeperCapacityDirectory(nodes,@"a");AxsCacheKeeperCapacityDirectory(nodes,@"b");
    root=[[AxsCacheKeeperCapacityRoot alloc] initWithRoot:[NSURL fileURLWithPath:nodes] entryLimit:100 depthLimit:64 inodeLimit:262144 nodeLimit:2];
    AxsCacheKeeperCapacityFinish(root,1);AxsCacheKeeperCapacityCheck([root.state isEqual:@"nodeLimit"] && [root.result[@"nodes"] count]==2,"node budget exhaustion cannot silently truncate a complete hierarchy");
    NSString *deep=AxsCacheKeeperCapacityDirectory(base,@"depth-budget");AxsCacheKeeperCapacityDirectory(deep,@"a/b");AxsCacheKeeperCapacityFile([deep stringByAppendingPathComponent:@"a/b/file"],1);
    root=[[AxsCacheKeeperCapacityRoot alloc] initWithRoot:[NSURL fileURLWithPath:deep] entryLimit:100 depthLimit:2 inodeLimit:262144 nodeLimit:4096];
    AxsCacheKeeperCapacityFinish(root,1);AxsCacheKeeperCapacityCheck([root.state isEqual:@"depthLimit"],"depth budget cannot misreport unvisited descendants as complete");
    NSString *exact=AxsCacheKeeperCapacityDirectory(base,@"exact-budget");AxsCacheKeeperCapacityFile([exact stringByAppendingPathComponent:@"file"],1);
    root=[[AxsCacheKeeperCapacityRoot alloc] initWithRoot:[NSURL fileURLWithPath:exact] entryLimit:2 depthLimit:64 inodeLimit:2 nodeLimit:1];
    AxsCacheKeeperCapacityFinish(root,1);AxsCacheKeeperCapacityCheck([root.state isEqual:@"complete"] && [root.result[@"entries"] isEqual:@2] && [root.result[@"uniqueInodes"] isEqual:@2] && [root.result[@"nodes"] count]==1,"exact entry inode and node limits can complete without overflow");
}
static void AxsCacheKeeperCapacityErrors(NSString *base) {
    NSString *path=[base stringByAppendingPathComponent:@"real-missing-root"];
    AxsCacheKeeperCapacityRoot *root=[[AxsCacheKeeperCapacityRoot alloc] initWithRoot:[NSURL fileURLWithPath:path]];
    NSDictionary *errors=root.result[@"cursorErrors"],*error=[errors[@"errors"] firstObject];
    AxsCacheKeeperCapacityCheck([root.state isEqual:@"readError"] && [error[@"errorCode"] isEqual:@(ENOENT)] &&
        [error[@"stage"] isEqual:@"entryStat"] && [error[@"errorDomain"] isEqual:@"posix"] && [error[@"count"] isEqual:@1],
        "real cursor errno and stage survive capacity wrapper");
    AxsCacheKeeperCapacityCheck(!error[@"scope"] && root.openDirectoryCount==0 && [errors[@"statErrors"] isEqual:@1],
        "wrapper exposes real zero descriptors without inventing a home scope");
    AxsCacheKeeperCapacityFile(path,1);
    root=[[AxsCacheKeeperCapacityRoot alloc] initWithRoot:[NSURL fileURLWithPath:path]];
    error=[root.result[@"cursorErrors"][@"errors"] firstObject];
    AxsCacheKeeperCapacityCheck([error[@"errorCode"] isEqual:@(ENOTDIR)] && [error[@"stage"] isEqual:@"enumerate"],
        "real non-directory cursor error remains distinct");
}
static void AxsCacheKeeperCapacityInvalidRoot(void) {
    // Removing the invalid-input gate must expose the seeded errno and fail.
    for (NSNumber *seed in @[@(EACCES),@(ENOENT)]) {
        errno=seed.intValue;AxsCacheKeeperCapacityRoot *root=[[AxsCacheKeeperCapacityRoot alloc] initWithRoot:nil];
        NSDictionary *result=root.result,*failure=result[@"sourceFailure"];
        AxsCacheKeeperCapacityCheck([root.state isEqual:@"readError"] && !result[@"cursorErrors"] &&
            [failure[@"stage"] isEqual:@"inputValidation"] && [failure[@"reason"] isEqual:@"invalidRoot"] &&
            [failure[@"errorDomain"] isEqual:@"none"] && !failure[@"errorCode"] && !root.cursorCreated && root.openDirectoryCount==0 &&
            [result[@"entries"] isEqual:@0],
            "invalid root never exports seeded errno as observed cursor IO");
    }
}
static void AxsCacheKeeperCapacityPrivateLayout(NSString *base) {
    NSString *path=AxsCacheKeeperCapacityDirectory(base,@"private-layout");
    for (NSString *relative in @[@"PRIVATE_OUTER/PRIVATE_ACCOUNT/postbox/media/cache",@"PRIVATE_OUTER/PRIVATE_ACCOUNT/postbox/db",@"PRIVATE_OUTER/logs",@"other/deep/unclassified/branch/ignored"])
        AxsCacheKeeperCapacityDirectory(path,relative);
    AxsCacheKeeperCapacityFile([path stringByAppendingPathComponent:@"PRIVATE_OUTER/PRIVATE_ACCOUNT/postbox/media/cache/opaque"],17);
    AxsCacheKeeperCapacityFile([path stringByAppendingPathComponent:@"PRIVATE_OUTER/PRIVATE_ACCOUNT/postbox/db/opaque"],31);
    struct stat identity=AxsCacheKeeperCapacityStat(path);
    AxsCacheKeeperCapacityRoot *root=[[AxsCacheKeeperCapacityRoot alloc] initWithRoot:[NSURL fileURLWithPath:path] expectedDevice:identity.st_dev expectedInode:identity.st_ino layout:AxsCacheKeeperResourceLayoutSwiftgramGroup];
    AxsCacheKeeperCapacityFinish(root,1);
    NSMutableDictionary *categories=[NSMutableDictionary new];
    for (NSDictionary *node in root.result[@"nodes"]) categories[node[@"category"]]=node;
    AxsCacheKeeperCapacityCheck([root.state isEqual:@"complete"] && [root.result[@"logicalBytes"] isEqual:@48],"private classification preserves whole-root totals");
    AxsCacheKeeperCapacityCheck([categories[@"postboxDatabase"][@"logicalBytes"] isEqual:@31] && [categories[@"postboxMedia"][@"logicalBytes"] isEqual:@17] && [categories[@"postboxMediaCache"][@"logicalBytes"] isEqual:@17],"private media database and cache use actual independent fixture sizes");
    AxsCacheKeeperCapacityCheck([root.result[@"layoutProfile"] isEqual:@"swiftgramGroupStructureV1"] && [root.result[@"deletionAuthorization"] isEqual:@"notGranted"],"private structural profile never grants cleanup");
    NSData *json=[NSJSONSerialization dataWithJSONObject:root.result options:0 error:nil];
    NSString *text=[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    AxsCacheKeeperCapacityCheck([text rangeOfString:@"PRIVATE_"].location==NSNotFound && [text rangeOfString:@"opaque"].location==NSNotFound,"private layout never exports account or file names");
    AxsCacheKeeperCapacityRoot *standard=[[AxsCacheKeeperCapacityRoot alloc] initWithRoot:[NSURL fileURLWithPath:path]];
    AxsCacheKeeperCapacityFinish(standard,1);AxsCacheKeeperCapacityClosedResult(standard.result);
    AxsCacheKeeperCapacityCheck([standard.result[@"logicalBytes"] isEqual:root.result[@"logicalBytes"]] && [standard.result[@"allocatedBytes"] isEqual:root.result[@"allocatedBytes"]],"classification does not change measured allocation");
    NSUInteger previousNodes=[root.result[@"nodes"] count];
    for (NSUInteger i=0;i<65;i++) {
        NSString *shard=AxsCacheKeeperCapacityDirectory(path,[NSString stringWithFormat:@"PRIVATE_OUTER/PRIVATE_ACCOUNT/postbox/media/PRIVATE_SHARD_%lu/deeper",(unsigned long)i]);
        AxsCacheKeeperCapacityFile([shard stringByAppendingPathComponent:@"opaque"],1);
    }
    // A familiar marker is still only a regular file, not a directory node.
    AxsCacheKeeperCapacityFile([path stringByAppendingPathComponent:@"PRIVATE_OUTER/PRIVATE_ACCOUNT/postbox/logs"],3);
    identity=AxsCacheKeeperCapacityStat(path);
    AxsCacheKeeperCapacityRoot *shards=[[AxsCacheKeeperCapacityRoot alloc] initWithRoot:[NSURL fileURLWithPath:path] expectedDevice:identity.st_dev expectedInode:identity.st_ino layout:AxsCacheKeeperResourceLayoutSwiftgramGroup];
    AxsCacheKeeperCapacityFinish(shards,1);
    AxsCacheKeeperCapacityCheck([shards.state isEqual:@"complete"] && [shards.result[@"nodes"] count]==previousNodes && [shards.result[@"logicalBytes"] isEqual:@116],"unknown media shards and same-named files add bytes without consuming classification nodes");
}
int main(int argc,const char **argv) { @autoreleasepool {
    AxsCacheKeeperCapacityCheck(argc==2 || argc==3,"unique fixture root and optional case");
    NSString *base=[NSString stringWithUTF8String:argv[1]],*selection=argc==3 ? [NSString stringWithUTF8String:argv[2]] : @"all";
    if ([selection isEqual:@"all"] || [selection isEqual:@"private-layout"]) AxsCacheKeeperCapacityPrivateLayout(base);
    if ([selection isEqual:@"private-layout"]) return 0;
    if([selection isEqual:@"all"] || [selection isEqual:@"invalid-root"]) AxsCacheKeeperCapacityInvalidRoot();
    if([selection isEqual:@"invalid-root"]) return 0;
    if([selection isEqual:@"all"] || [selection isEqual:@"cursor-errors"]) AxsCacheKeeperCapacityErrors(base);
    if([selection isEqual:@"cursor-errors"]) return 0;
    NSArray *names=@[@"totals",@"empty",@"observer",@"categories",@"slices",@"cancellation",@"identity",@"metadata",@"budgets",@"expected-identity",@"invalid-observer",@"observer-ownership"];
    void (*cases[])(NSString *)={AxsCacheKeeperCapacityTotals,AxsCacheKeeperCapacityEmpty,AxsCacheKeeperCapacityObserver,AxsCacheKeeperCapacityCategories,AxsCacheKeeperCapacitySlices,AxsCacheKeeperCapacityCancellation,AxsCacheKeeperCapacityIdentity,AxsCacheKeeperCapacityMetadata,AxsCacheKeeperCapacityBudgets,AxsCacheKeeperCapacityExpectedIdentity,AxsCacheKeeperCapacityInvalidObserver,AxsCacheKeeperCapacityObserverOwnership};
    AxsCacheKeeperCapacityCheck([selection isEqual:@"all"] || [selection isEqual:@"raw-setup"] || [names containsObject:selection],"known case selection");
    if([selection isEqual:@"raw-setup"]) {AxsCacheKeeperCapacityMarker("raw-setup begin");AxsCacheKeeperCapacityRawSetup(base);printf("PASS: capacity: raw-setup\n");fflush(stdout);return 0;}
    for(NSUInteger i=0;i<names.count;i++) if([selection isEqual:@"all"] || [selection isEqual:names[i]]) {
        printf("BEGIN: capacity: %s\n",[names[i] UTF8String]);fflush(stdout);
        cases[i](base);printf("PASS: capacity: %s\nEND: capacity: %s\n",[names[i] UTF8String],[names[i] UTF8String]);fflush(stdout);
    }
    return 0;
} }
