// Runtime gate fixture, not an SDWebImage/Baidu integration test. Only the source
// and helper fingerprint boundaries are substituted; adapter hooks, policy,
// filesystem scope checks, queueing and Objective-C method changes are real.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdatomic.h>
#include <stdio.h>
#include <unistd.h>
#include <mach-o/dyld.h>
#include <stdlib.h>
static atomic_uint axs_cachekeeper_runtime_paths,axs_cachekeeper_runtime_headers;
// Reorder real loader rows, preserving their actual headers, names and slides.
// This models RootHide's launcher-before-executable order without inventing code.
static BOOL axs_cachekeeper_runtime_shifted;
static uint32_t axs_cachekeeper_runtime_main_index,axs_cachekeeper_runtime_other_index;
static const void *axs_cachekeeper_runtime_main_header;
static uint32_t axs_cachekeeper_runtime_loader_index(uint32_t index) {
    if (axs_cachekeeper_runtime_shifted) {
        if (index==axs_cachekeeper_runtime_main_index) return axs_cachekeeper_runtime_other_index;
        if (index==axs_cachekeeper_runtime_other_index) return axs_cachekeeper_runtime_main_index;
    }
    return index;
}
static char *axs_cachekeeper_runtime_realpath(const char *path,char *out) {atomic_fetch_add(&axs_cachekeeper_runtime_paths,1);return realpath(path,out);}
static const struct mach_header *axs_cachekeeper_runtime_header(uint32_t index) {atomic_fetch_add(&axs_cachekeeper_runtime_headers,1);return _dyld_get_image_header(axs_cachekeeper_runtime_loader_index(index));}
static const char *axs_cachekeeper_runtime_name(uint32_t index) {return _dyld_get_image_name(axs_cachekeeper_runtime_loader_index(index));}
static intptr_t axs_cachekeeper_runtime_slide(uint32_t index) {return _dyld_get_image_vmaddr_slide(axs_cachekeeper_runtime_loader_index(index));}
#define realpath axs_cachekeeper_runtime_realpath
#define _dyld_get_image_header axs_cachekeeper_runtime_header
#define _dyld_get_image_name axs_cachekeeper_runtime_name
#define _dyld_get_image_vmaddr_slide axs_cachekeeper_runtime_slide
#import "AxsCacheKeeperImageLegacySource.h"
#import "AxsCacheKeeperImageRuntimeSource.h"
#undef realpath
#undef _dyld_get_image_header
#undef _dyld_get_image_name
#undef _dyld_get_image_vmaddr_slide

static atomic_uint axs_cachekeeper_runtime_writes,axs_cachekeeper_runtime_metadata,axs_cachekeeper_runtime_clears;
static atomic_uint axs_cachekeeper_runtime_source_checks,axs_cachekeeper_runtime_helper_checks;
// Constructor fixture faults do not replace any IMP or relax an adapter gate.
static unsigned axs_cachekeeper_runtime_constructor_fault;
static atomic_uint axs_cachekeeper_runtime_getter_calls;
static BOOL axs_cachekeeper_runtime_forbid_getters;
static void axs_cachekeeper_runtime_getter(void) {
    atomic_fetch_add(&axs_cachekeeper_runtime_getter_calls,1);
    if (axs_cachekeeper_runtime_forbid_getters) {fputs("FAIL: image-runtime-source: publication must not call an SDK getter\n",stderr);exit(1);}
}
@class SDDiskCache,SDMemoryCache;
@interface SDImageCacheConfig : NSObject <NSCopying>
@end
@interface SDDiskCache : NSObject
@property(nonatomic,copy) NSString *diskCachePath;
@property(nonatomic,strong) SDImageCacheConfig *config;
@property(nonatomic,strong) NSFileManager *fileManager;
- (instancetype)initWithCachePath:(NSString *)path config:(SDImageCacheConfig *)config;
- (void)setData:(id)data forKey:(id)key;
- (void)setExtendedData:(id)data forKey:(id)key;
- (id)cachePathForKey:(id)key;
- (id)cachePathForKey:(id)key inPath:(id)path;
@end
@interface SDMemoryCache : NSObject
@property(nonatomic,strong) SDImageCacheConfig *config;
- (instancetype)initWithConfig:(SDImageCacheConfig *)config;
@end
@interface SDImageCache : NSObject
@property(nonatomic,strong) SDDiskCache *diskCache;
@property(nonatomic,copy) NSString *diskCachePath;
@property(nonatomic,strong) SDImageCacheConfig *config;
@property(nonatomic,strong) dispatch_queue_t ioQueue;
@property(nonatomic,strong) SDMemoryCache *memoryCache;
- (instancetype)initWithNamespace:(NSString *)space diskCacheDirectory:(NSString *)directory config:(SDImageCacheConfig *)config;
@end
@implementation SDImageCacheConfig
- (id)fileManager {return nil;}
- (Class)diskCacheClass {return SDDiskCache.class;}
- (Class)memoryCacheClass {return SDMemoryCache.class;}
- (id)copyWithZone:(NSZone *)zone {(void)zone;return [SDImageCacheConfig new];}
+ (id)defaultCacheConfig {return [SDImageCacheConfig new];}
@end
@implementation SDDiskCache
- (instancetype)initWithCachePath:(NSString *)path config:(SDImageCacheConfig *)config {
    if (!(self=[super init])) return nil;
    _diskCachePath=[path copy];_config=config;_fileManager=NSFileManager.defaultManager;
    if (![_fileManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil]) return nil;
    return self;
}
- (void)commonInit {}
- (void)removeAllData {atomic_fetch_add(&axs_cachekeeper_runtime_clears,1);}
- (id)cachePathForKey:(id)key {return [self cachePathForKey:key inPath:self.diskCachePath];}
- (id)cachePathForKey:(id)key inPath:(id)path {(void)key;return path;}
- (void)setData:(id)data forKey:(id)key {(void)data;(void)key;atomic_fetch_add(&axs_cachekeeper_runtime_writes,1);}
- (void)setExtendedData:(id)data forKey:(id)key {(void)data;(void)key;atomic_fetch_add(&axs_cachekeeper_runtime_metadata,1);}
@end
@implementation SDMemoryCache
- (instancetype)initWithConfig:(SDImageCacheConfig *)config {if ((self=[super init])) _config=config;return self;}
- (void)commonInit {}
@end
@implementation SDImageCache
@synthesize diskCache=_diskCache,diskCachePath=_diskCachePath,config=_config,ioQueue=_ioQueue,memoryCache=_memoryCache;
- (SDDiskCache *)diskCache {axs_cachekeeper_runtime_getter();return _diskCache;}
- (NSString *)diskCachePath {axs_cachekeeper_runtime_getter();return _diskCachePath;}
- (SDImageCacheConfig *)config {axs_cachekeeper_runtime_getter();return _config;}
- (dispatch_queue_t)ioQueue {axs_cachekeeper_runtime_getter();return _ioQueue;}
- (SDMemoryCache *)memoryCache {axs_cachekeeper_runtime_getter();return _memoryCache;}
- (instancetype)initWithNamespace:(NSString *)space diskCacheDirectory:(NSString *)directory config:(SDImageCacheConfig *)config {
    if (!(self=[super init])) return nil;
    if (axs_cachekeeper_runtime_constructor_fault==1) return nil;
    _config=[config copy];_diskCachePath=[directory stringByAppendingPathComponent:space];
    _ioQueue=dispatch_queue_create("cachekeeper.runtime-source.fixture",DISPATCH_QUEUE_SERIAL);
    _memoryCache=[[SDMemoryCache alloc] initWithConfig:_config];
    _diskCache=[[SDDiskCache alloc] initWithCachePath:_diskCachePath config:_config];
    if (axs_cachekeeper_runtime_constructor_fault==2) _diskCache=nil;
    if (axs_cachekeeper_runtime_constructor_fault==3) _config=nil;
    if (axs_cachekeeper_runtime_constructor_fault==4) _ioQueue=nil;
    if (axs_cachekeeper_runtime_constructor_fault==5) _diskCachePath=nil;
    return self;
}
@end
@interface AxsCacheKeeperRuntimeSourceHelper : NSObject
+ (id)axs_cachekeeper_sample;
@end
@implementation AxsCacheKeeperRuntimeSourceHelper
+ (id)axs_cachekeeper_sample {return nil;}
@end
static IMP axs_cachekeeper_runtime_helper_original;
static BOOL axs_cachekeeper_runtime_fingerprinted;
static id axs_cachekeeper_runtime_changed_helper(id object,SEL selector) {(void)object;(void)selector;return nil;}
static BOOL axs_cachekeeper_runtime_helpers_match(const void *base) {
    atomic_fetch_add(&axs_cachekeeper_runtime_helper_checks,1);
    return base==axs_cachekeeper_runtime_main_header &&
        method_getImplementation(class_getClassMethod(AxsCacheKeeperRuntimeSourceHelper.class,@selector(axs_cachekeeper_sample)))==axs_cachekeeper_runtime_helper_original;
}
static BOOL axs_cachekeeper_runtime_source_matches(const void *base,const void *implementations[25]) {
    atomic_fetch_add(&axs_cachekeeper_runtime_source_checks,1);
    return axs_cachekeeper_runtime_fingerprinted && AxsCacheKeeperImageLegacySlotsPresent(implementations) &&
        axs_cachekeeper_runtime_helpers_match(base);
}
static AxsCacheKeeperImageLegacyCheck axs_cachekeeper_runtime_source_check(const void *base,const void *implementations[25]) {
    return axs_cachekeeper_runtime_source_matches(base,implementations) ? AxsCacheKeeperImageLegacyComplete() :
        AxsCacheKeeperImageLegacyResult("mainIdentity","bundle",0,0);
}
static atomic_uint axs_cachekeeper_runtime_home_resolutions;
static atomic_bool axs_cachekeeper_runtime_count_only_home;
@interface NSString (AxsCacheKeeperCountedHomeResolution)
- (NSString *)axs_cachekeeper_countedResolvedHome;
@end
@implementation NSString (AxsCacheKeeperCountedHomeResolution)
- (NSString *)axs_cachekeeper_countedResolvedHome {
    atomic_fetch_add(&axs_cachekeeper_runtime_home_resolutions,1);
    // The measured fixture uses an already canonical home; count calls without
    // making the RED depend on host filesystem latency. open/openat/fstat remain real.
    if (atomic_load(&axs_cachekeeper_runtime_count_only_home)) return self;
    return self.stringByResolvingSymlinksInPath;
}
@end
#define AxsCacheKeeperImageLegacyHelpersMatch axs_cachekeeper_runtime_helpers_match
#define AxsCacheKeeperImageLegacySourceCheck axs_cachekeeper_runtime_source_check
#define stringByResolvingSymlinksInPath axs_cachekeeper_countedResolvedHome
#define _dyld_get_image_header axs_cachekeeper_runtime_header
#define _dyld_get_image_name axs_cachekeeper_runtime_name
#define _dyld_get_image_vmaddr_slide axs_cachekeeper_runtime_slide
#import "AxsCacheKeeperImageCache.m"
#undef _dyld_get_image_header
#undef _dyld_get_image_name
#undef _dyld_get_image_vmaddr_slide
#undef stringByResolvingSymlinksInPath
#undef AxsCacheKeeperImageLegacyHelpersMatch
#undef AxsCacheKeeperImageLegacySourceCheck

static void axs_cachekeeper_runtime_require(BOOL value,const char *message) {
    if (!value) {fprintf(stderr,"FAIL: image-runtime-source: %s\n",message);exit(1);}
}
static void axs_cachekeeper_runtime_refresh(AxsCacheKeeperImageCache *engine) {
    dispatch_semaphore_t done=dispatch_semaphore_create(0);
    [engine refreshWithCompletion:^{dispatch_semaphore_signal(done);}];
    axs_cachekeeper_runtime_require(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0,"refresh completes");
    axs_cachekeeper_runtime_require(axs_cachekeeper_image_cache_projection(engine.receipt)!=nil,"receipt retains the public schema");
}
static void axs_cachekeeper_runtime_wait(AxsCacheKeeperImageCache *engine,BOOL (^condition)(NSDictionary *),const char *message) {
    for (NSUInteger attempt=0;attempt<500;attempt++) {if (condition(engine.receipt)) return;usleep(10000);}
    axs_cachekeeper_runtime_require(NO,message);
}
static void axs_cachekeeper_runtime_admission(AxsCacheKeeperImageCache *engine,NSString *home) {
    NSDictionary *initial=engine.receipt[@"instanceAdmission"];
    axs_cachekeeper_runtime_require([initial[@"initializerReturns"] isEqual:@0],"untriggered initialization is explicitly zero");
    NSString *root=[home stringByAppendingPathComponent:@"Library/Caches"];
    __weak SDImageCache *weakOwner;
    @autoreleasepool {
    __attribute__((objc_precise_lifetime)) SDImageCache *owner=[[SDImageCache alloc] initWithNamespace:@"admitted" diskCacheDirectory:root config:[SDImageCacheConfig new]];
    axs_cachekeeper_runtime_refresh(engine);
    axs_cachekeeper_runtime_require([engine.receipt[@"eligible"] isEqual:@1],"normal fixture owner remains admitted");
    NSMutableArray *rejected=[NSMutableArray new];
    for (unsigned fault=1;fault<=5;fault++) {
        axs_cachekeeper_runtime_constructor_fault=fault;
        SDImageCache *item=[[SDImageCache alloc] initWithNamespace:[NSString stringWithFormat:@"early-%u",fault] diskCacheDirectory:root config:[SDImageCacheConfig new]];
        if (item) [rejected addObject:item];
    }
    axs_cachekeeper_runtime_constructor_fault=0;axs_cachekeeper_runtime_refresh(engine);
    NSDictionary *admission=engine.receipt[@"instanceAdmission"];
    axs_cachekeeper_runtime_require([admission[@"initializerReturns"] isEqual:@6] && [admission[@"registered"] isEqual:@1] &&
        [admission[@"unregistered"] isEqual:@5] && [engine.receipt[@"restricted"] isEqual:@1],"early returns retain prior live admission and exact counters");
    for (NSString *reason in @[@"initializerReturnedNil",@"diskMissing",@"configurationMissing",@"queueMissing",@"pathMissing"])
        axs_cachekeeper_runtime_require([admission[@"unregisteredReasons"][reason] isEqual:@1],"early return has its own closed reason");
    SDImageCacheConfig *config=owner.config;
    owner.config=[SDImageCacheConfig new];axs_cachekeeper_runtime_refresh(engine);
    axs_cachekeeper_runtime_require([engine.receipt[@"instanceAdmission"][@"liveReasons"][@"configurationIdentity"] isEqual:@1] &&
        [engine.receipt[@"restricted"] isEqual:@0],"configuration mismatch is precise and refuses admission");
    [owner.diskCache setData:[NSData data] forKey:@"unchanged-original"];
    axs_cachekeeper_runtime_require(atomic_load(&axs_cachekeeper_runtime_writes)==1,"refused owner retains original write");
    owner.config=config;axs_cachekeeper_runtime_refresh(engine);
    dispatch_queue_t queue=owner.ioQueue;
    owner.ioQueue=dispatch_queue_create("fixture.changed.queue",DISPATCH_QUEUE_SERIAL);axs_cachekeeper_runtime_refresh(engine);
    axs_cachekeeper_runtime_require([engine.receipt[@"instanceAdmission"][@"liveReasons"][@"queueIdentity"] isEqual:@1] &&
        [engine.receipt[@"eligible"] isEqual:@0],"queue mismatch retains its exact reason");
    owner.ioQueue=queue;axs_cachekeeper_runtime_refresh(engine);
    axs_cachekeeper_runtime_require([engine.receipt[@"restricted"] isEqual:@1] &&
        [engine.receipt[@"instanceAdmission"][@"liveReasons"][@"none"] isEqual:@1],"restoring original identity restores original admission");
    // Hold the old member alive: a weak registry member can outlive its owner's
    // property, so the current getter must determine missing-member diagnostics.
    __attribute__((objc_precise_lifetime)) SDDiskCache *detachedDisk=owner.diskCache;
    owner.diskCache=nil;
    axs_cachekeeper_runtime_require(detachedDisk && !owner.diskCache,"current disk is nil while registered disk remains live");
    axs_cachekeeper_runtime_refresh(engine);
    axs_cachekeeper_runtime_require([engine.receipt[@"instanceAdmission"][@"liveReasons"][@"diskMissing"] isEqual:@1] &&
        [engine.receipt[@"eligible"] isEqual:@0],"released disk member is not misreported as released owner");
    owner.diskCache=detachedDisk;axs_cachekeeper_runtime_refresh(engine);
    axs_cachekeeper_runtime_require([engine.receipt[@"restricted"] isEqual:@1],"restored disk identity is admitted again");
    owner.config=nil;axs_cachekeeper_runtime_refresh(engine);
    axs_cachekeeper_runtime_require(config && [engine.receipt[@"instanceAdmission"][@"liveReasons"][@"configurationMissing"] isEqual:@1] &&
        [engine.receipt[@"eligible"] isEqual:@0],"current configuration is missing while registered configuration remains live");
    owner.config=config;axs_cachekeeper_runtime_refresh(engine);
    axs_cachekeeper_runtime_require([engine.receipt[@"restricted"] isEqual:@1],"restored configuration identity is admitted again");
    detachedDisk=nil;
    weakOwner=owner;owner=nil;
    }
    axs_cachekeeper_runtime_refresh(engine);
    axs_cachekeeper_runtime_require(!weakOwner && [engine.receipt[@"observed"] isEqual:@0] &&
        [engine.receipt[@"instanceAdmission"][@"released"] isEqual:@1],"weak owner release is recorded once without retention");
    axs_cachekeeper_runtime_refresh(engine);
    axs_cachekeeper_runtime_require([engine.receipt[@"instanceAdmission"][@"released"] isEqual:@1],"repeated publication cannot recount release");
    __attribute__((objc_precise_lifetime)) SDImageCache *next=[[SDImageCache alloc] initWithNamespace:@"next" diskCacheDirectory:root config:[SDImageCacheConfig new]];
    axs_cachekeeper_runtime_refresh(engine);
    axs_cachekeeper_runtime_require([engine.receipt[@"instanceAdmission"][@"registered"] isEqual:@2] &&
        [engine.receipt[@"instanceAdmission"][@"released"] isEqual:@1] && [engine.receipt[@"observed"] isEqual:@1],"pruning released binding preserves lifetime totals");
    // The fixture getter bodies count real calls. Do not change IMPs during this
    // check: publication must remain free of SDK reads even with a valid contract.
    dispatch_sync(engine.work,^{
        axs_cachekeeper_runtime_forbid_getters=YES;
        [engine axs_cachekeeper_publish];
        axs_cachekeeper_runtime_forbid_getters=NO;
    });
    axs_cachekeeper_runtime_require([engine.receipt[@"eligible"] isEqual:@1],"cached publication retains admitted state");
    // Concurrent early outcomes must not lose increments or overwrite the live owner.
    dispatch_apply(24,dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^(size_t index) {
        (void)index;[engine axs_cachekeeper_observe:nil sourceReason:nil attributes:nil contract:AxsCacheKeeperImageContractFixedSerialLegacy];
    });
    axs_cachekeeper_runtime_refresh(engine);
    axs_cachekeeper_runtime_require([engine.receipt[@"instanceAdmission"][@"initializerReturns"] isEqual:@31] &&
        [engine.receipt[@"instanceAdmission"][@"unregisteredReasons"][@"initializerReturnedNil"] isEqual:@25] &&
        [engine.receipt[@"eligible"] isEqual:@1],"concurrent early returns close without changing accepted owner");
    Method getter=class_getInstanceMethod(SDImageCache.class,@selector(config));
    IMP original=method_getImplementation(getter);
    IMP foreign=imp_implementationWithBlock(^id(id object) {(void)object;return nil;});
    method_setImplementation(getter,foreign);
    unsigned calls=atomic_load(&axs_cachekeeper_runtime_getter_calls);
    [engine axs_cachekeeper_observe:next sourceReason:nil attributes:nil contract:AxsCacheKeeperImageContractFixedSerialLegacy];
    axs_cachekeeper_runtime_require(atomic_load(&axs_cachekeeper_runtime_getter_calls)==calls,"changed methods are rejected before reading members");
    method_setImplementation(getter,original);imp_removeBlock(foreign);
    axs_cachekeeper_runtime_refresh(engine);
    axs_cachekeeper_runtime_require([engine.receipt[@"instanceAdmission"][@"unregisteredReasons"][@"sdkMethodsChanged"] isEqual:@1] &&
        [engine.receipt[@"restricted"] isEqual:@1],"source method rejection cannot overwrite an admitted owner");
    dispatch_queue_t nextQueue=next.ioQueue;
    dispatch_semaphore_t entered=dispatch_semaphore_create(0),release=dispatch_semaphore_create(0);
    dispatch_async(nextQueue,^{dispatch_semaphore_signal(entered);dispatch_semaphore_wait(release,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC));});
    axs_cachekeeper_runtime_require(!dispatch_semaphore_wait(entered,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)),"pending owner SDK queue is held");
    [engine didEnterBackgroundWithTime:YES];
    axs_cachekeeper_runtime_wait(engine,^BOOL(NSDictionary *r) {return [r[@"pending"] isEqual:@1];},"real cleanup is queued before owner release");
    next=nil;
    dispatch_sync(engine.work,^{[engine axs_cachekeeper_publish];});
    axs_cachekeeper_runtime_require([engine.receipt[@"instanceAdmission"][@"released"] isEqual:@2] &&
        [engine.receipt[@"observed"] isEqual:@0] && [engine.receipt[@"pending"] isEqual:@1],"released pending owner preserves its unfinished action");
    dispatch_semaphore_signal(release);
    axs_cachekeeper_runtime_wait(engine,^BOOL(NSDictionary *r) {return [r[@"pending"] isEqual:@0];},"released owner queued cleanup exits safely");
    axs_cachekeeper_runtime_require([engine.receipt[@"submitted"] isEqual:@0] && [engine.receipt[@"skipped"] isEqual:@1] &&
        [engine.receipt[@"instanceAdmission"][@"released"] isEqual:@2],"released owner cannot submit cleanup or double count release");
}
int main(int argc,const char *argv[]) {
    @autoreleasepool {
        axs_cachekeeper_runtime_require(argc==2 && (!strcmp(argv[1],"fingerprint") || !strcmp(argv[1],"fingerprint-shifted") || !strcmp(argv[1],"sample") || !strcmp(argv[1],"pinned") || !strcmp(argv[1],"refresh") || !strcmp(argv[1],"admission")),"one isolated scenario is required");
        axs_cachekeeper_runtime_shifted=!strcmp(argv[1],"fingerprint-shifted");
        axs_cachekeeper_runtime_fingerprinted=!strcmp(argv[1],"fingerprint") || axs_cachekeeper_runtime_shifted;
        unsigned executables=0;
        for (uint32_t i=0;i<_dyld_image_count();i++) {
            const struct mach_header *header=_dyld_get_image_header(i);
            if (header && header->filetype==MH_EXECUTE) {executables++;axs_cachekeeper_runtime_main_index=i;axs_cachekeeper_runtime_main_header=header;}
        }
        axs_cachekeeper_runtime_require(executables==1,"fixture has one real executable");
        axs_cachekeeper_runtime_other_index=axs_cachekeeper_runtime_main_index==0 ? 1 : 0;
        axs_cachekeeper_runtime_require(_dyld_image_count()>1 && _dyld_get_image_header(axs_cachekeeper_runtime_other_index)->filetype!=MH_EXECUTE,
            "loader fixture swaps executable with a real library");
        Method helper=class_getClassMethod(AxsCacheKeeperRuntimeSourceHelper.class,@selector(axs_cachekeeper_sample));
        axs_cachekeeper_runtime_helper_original=method_getImplementation(helper);
        NSString *home=[[[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] stringByStandardizingPath] stringByResolvingSymlinksInPath];
        if (!strcmp(argv[1],"sample")) {
            axs_cachekeeper_runtime_require([NSFileManager.defaultManager createDirectoryAtPath:home withIntermediateDirectories:YES attributes:nil error:nil],"sample root created");
            NSString *file=[home stringByAppendingPathComponent:@"one"],*link=[home stringByAppendingPathComponent:@"two"];
            NSData *payload=[@"sample" dataUsingEncoding:NSUTF8StringEncoding];
            axs_cachekeeper_runtime_require([payload writeToFile:file atomically:YES] && !linkat(AT_FDCWD,file.fileSystemRepresentation,AT_FDCWD,link.fileSystemRepresentation,0),"two hardlinked sample entries created");
            int fd=open(home.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);struct stat status;
            axs_cachekeeper_runtime_require(fd>=0 && !stat(file.fileSystemRepresentation,&status),"sample descriptors opened");
            AxsCacheKeeperImageSample first=AxsCacheKeeperImageFlatSample(fd),second=AxsCacheKeeperImageFlatSample(fd);
            axs_cachekeeper_runtime_require(first.state==AxsCacheKeeperImageSampleComplete && first.files==2 && first.logicalBytes==12 && first.allocatedBytes==(uint64_t)status.st_blocks*1024,"actual files sampled by directory entries");
            axs_cachekeeper_runtime_require(second.state==AxsCacheKeeperImageSampleComplete && second.files==first.files && second.logicalBytes==first.logicalBytes,"repeated descriptor sampling starts from beginning");
            NSString *symbolic=[home stringByAppendingPathComponent:@"symbolic"];
            axs_cachekeeper_runtime_require(!symlink(file.fileSystemRepresentation,symbolic.fileSystemRepresentation),"sample symlink created");
            axs_cachekeeper_runtime_require(AxsCacheKeeperImageFlatSample(fd).state==AxsCacheKeeperImageSampleNonFlat,"symlink never measured as eligible flat data");
            axs_cachekeeper_runtime_require(!unlink(symbolic.fileSystemRepresentation) && !unlink(file.fileSystemRepresentation) && !unlink(link.fileSystemRepresentation),"owned sample entries removed");
            AxsCacheKeeperImageSample empty=AxsCacheKeeperImageFlatSample(fd);
            axs_cachekeeper_runtime_require(empty.state==AxsCacheKeeperImageSampleComplete && !empty.files && !empty.logicalBytes && !empty.allocatedBytes,"actual emptied directory has measured zero");
            axs_cachekeeper_runtime_require(!close(fd) && AxsCacheKeeperImageFlatSample(-1).state==AxsCacheKeeperImageSampleReadError,"invalid descriptor cannot become empty");
            axs_cachekeeper_runtime_require([NSFileManager.defaultManager removeItemAtPath:home error:nil],"sample root removed");
            puts("PASS: image-runtime-source fixture sample");return 0;
        }
        NSObject *contextLock=[NSObject new];
        NSMutableDictionary *context=[@{@"valid":@YES,@"appState":@{@"enabled":@YES,@"mode":@"auto",@"autoDiscover":@YES},
            @"selected":@[],@"home":home,@"bundle":@"cachekeeper.owned.runtime.fixture",@"version":@"1",@"installation":@"runtime-fixture",@"reportWritable":@YES} mutableCopy];
        AxsCacheKeeperImageContextProvider provider=^NSDictionary *{@synchronized(contextLock) {return [context copy];}};
        AxsCacheKeeperImageCache *engine=[[AxsCacheKeeperImageCache alloc] initWithContextProvider:provider observer:nil];
        if (!axs_cachekeeper_runtime_fingerprinted) [engine usePinnedLegacySDKForIntegrationTests];
        [engine startObserving];axs_cachekeeper_runtime_refresh(engine);
        if (!strcmp(argv[1],"admission")) {
            axs_cachekeeper_runtime_admission(engine,home);
            axs_cachekeeper_runtime_require([NSFileManager.defaultManager removeItemAtPath:home error:nil],"admission fixture root removed");
            puts("PASS: image-runtime-source fixture admission");return 0;
        }
        if (axs_cachekeeper_runtime_shifted) {
            AxsCacheKeeperExecutableImage selected=AxsCacheKeeperImageExecutable();
            axs_cachekeeper_runtime_require(selected.header==axs_cachekeeper_runtime_main_header && selected.index==axs_cachekeeper_runtime_other_index,
                "runtime discovery selects the reordered executable");
            NSDictionary *observation=engine.receipt[@"runtimeSourceObservation"];
            NSUInteger main=[observation[@"mainModule"] unsignedIntegerValue];
            axs_cachekeeper_runtime_require(main>0 && main<=[observation[@"modules"] count] &&
                [observation[@"modules"][main-1][@"dyldIndex"] unsignedIntegerValue]==axs_cachekeeper_runtime_other_index,
                "runtime report preserves the reordered executable identity");
            axs_cachekeeper_runtime_require([engine.receipt[@"discoveryCheck"][@"imageKind"] isEqual:@"main"],
                "runtime discovery preserves main image kind after reordering");
        }
        if (!strcmp(argv[1],"refresh")) {
            // Populate the registry while disabled, so setup does not itself run the
            // deliberately quadratic RED before the measured authorization refresh.
            @synchronized(contextLock) {context[@"appState"]=@{@"enabled":@NO};}
            axs_cachekeeper_runtime_refresh(engine);
            NSMutableArray *owners=[NSMutableArray new];
            for (NSUInteger i=0;i<64;i++) {
                SDImageCache *item=[[SDImageCache alloc] initWithNamespace:[NSString stringWithFormat:@"owner-%lu",(unsigned long)i]
                    diskCacheDirectory:[home stringByAppendingPathComponent:@"Library/Caches"] config:[SDImageCacheConfig new]];
                [owners addObject:item];
            }
            axs_cachekeeper_runtime_refresh(engine);
            @synchronized(contextLock) {context[@"appState"]=@{@"enabled":@YES,@"mode":@"auto",@"autoDiscover":@YES};}
            // Queue-local measurement excludes discovery/owner setup and preserves every FD identity probe.
            dispatch_semaphore_t measured=dispatch_semaphore_create(0);
            __block unsigned resolutions=0;
            dispatch_async(engine.work,^{
                atomic_store(&axs_cachekeeper_runtime_home_resolutions,0);
                atomic_store(&axs_cachekeeper_runtime_count_only_home,true);
                NSUInteger event=[engine axs_cachekeeper_begin_event:@"configuration" context:[engine axs_cachekeeper_operation_context] current:YES];
                [engine axs_cachekeeper_refresh_event:event];
                axs_cachekeeper_operation_finish(engine.operationHistory,event);
                resolutions=atomic_load(&axs_cachekeeper_runtime_home_resolutions);
                atomic_store(&axs_cachekeeper_runtime_count_only_home,false);
                dispatch_semaphore_signal(measured);
            });
            axs_cachekeeper_runtime_require(dispatch_semaphore_wait(measured,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0,"64-owner refresh finishes within unchanged 5s");
            axs_cachekeeper_runtime_require(resolutions<=65,"64-owner refresh resolves home at most once plus 64 FD identity probes");
            axs_cachekeeper_runtime_require(resolutions>=64,"refresh retains each owner filesystem identity probe");
            axs_cachekeeper_runtime_require([engine.receipt[@"restricted"] unsignedIntegerValue]==64,"all 64 real fixture owners are restricted");
            SDImageCache *overflow=[[SDImageCache alloc] initWithNamespace:@"owner-0" diskCacheDirectory:[home stringByAppendingPathComponent:@"Library/Caches"] config:[SDImageCacheConfig new]];
            [owners addObject:overflow];axs_cachekeeper_runtime_refresh(engine);
            axs_cachekeeper_runtime_require([engine.receipt[@"reason"] isEqual:@"observationLimit"] &&
                ![engine.receipt[@"restricted"] unsignedIntegerValue] && ![engine.receipt[@"eligible"] unsignedIntegerValue],"overflow revokes all owners and still completes refresh");
            axs_cachekeeper_runtime_require([engine.receipt[@"instanceAdmission"][@"initializerReturns"] isEqual:@65] &&
                [engine.receipt[@"instanceAdmission"][@"registered"] isEqual:@64] &&
                [engine.receipt[@"instanceAdmission"][@"unregisteredReasons"][@"observationLimit"] isEqual:@1],"registry limit has a bounded diagnostic without new admission");
            axs_cachekeeper_runtime_require([NSFileManager.defaultManager removeItemAtPath:home error:nil],"refresh fixture root is removed");
            printf("PASS: image-runtime-source fixture refresh\n");return 0;
        }
        NSString *source=axs_cachekeeper_runtime_fingerprinted ? @"imageFingerprint" : @"testPinned";
        axs_cachekeeper_runtime_require([engine.receipt[@"discoveryCheck"][@"source"] isEqual:source],"selected source is published");
        SDImageCache *owner=[[SDImageCache alloc] initWithNamespace:@"images" diskCacheDirectory:[home stringByAppendingPathComponent:@"Library/Caches"] config:[SDImageCacheConfig new]];
        NSData *residual=[@"retained" dataUsingEncoding:NSUTF8StringEncoding];
        axs_cachekeeper_runtime_require([residual writeToFile:[owner.diskCachePath stringByAppendingPathComponent:@"residual"] atomically:YES],"no-op SDK residual fixture created");
        axs_cachekeeper_runtime_refresh(engine);
        axs_cachekeeper_runtime_require([engine.receipt[@"restricted"] unsignedIntegerValue]==1,"actual owner is initially restricted");
        [owner.diskCache setData:[NSData data] forKey:@"initial"];
        [owner.diskCache setExtendedData:[NSData data] forKey:@"initial"];
        axs_cachekeeper_runtime_require(atomic_load(&axs_cachekeeper_runtime_writes)==0 && atomic_load(&axs_cachekeeper_runtime_metadata)==0,"both write hooks initially block");
        dispatch_semaphore_t workerEntered=dispatch_semaphore_create(0),workerRelease=dispatch_semaphore_create(0);
        dispatch_async(engine.work,^{dispatch_semaphore_signal(workerEntered);dispatch_semaphore_wait(workerRelease,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC));});
        axs_cachekeeper_runtime_require(dispatch_semaphore_wait(workerEntered,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0,"discovery worker is held");
        axs_cachekeeper_image_runtime_view_changed();
        atomic_store(&axs_cachekeeper_runtime_paths,0);atomic_store(&axs_cachekeeper_runtime_headers,0);
        [owner.diskCache setData:[NSData data] forKey:@"stale"];
        [owner.diskCache setExtendedData:[NSData data] forKey:@"stale"];
        axs_cachekeeper_runtime_require(atomic_load(&axs_cachekeeper_runtime_writes)==1 && atomic_load(&axs_cachekeeper_runtime_metadata)==1,
            "stale executable identity restores both original writes before discovery");
        axs_cachekeeper_runtime_require(!atomic_load(&axs_cachekeeper_runtime_paths) && !atomic_load(&axs_cachekeeper_runtime_headers),
            "both write hooks avoid path resolution and loader enumeration while discovery is held");
        dispatch_semaphore_signal(workerRelease);axs_cachekeeper_runtime_refresh(engine);
        atomic_store(&axs_cachekeeper_runtime_writes,0);atomic_store(&axs_cachekeeper_runtime_metadata,0);
        [owner.diskCache setData:[NSData data] forKey:@"refreshed"];
        [owner.diskCache setExtendedData:[NSData data] forKey:@"refreshed"];
        axs_cachekeeper_runtime_require(!atomic_load(&axs_cachekeeper_runtime_writes) && !atomic_load(&axs_cachekeeper_runtime_metadata),
            "discovery restores both write restrictions after executable validation");

        dispatch_semaphore_t entered=dispatch_semaphore_create(0),release=dispatch_semaphore_create(0);
        dispatch_async(owner.ioQueue,^{dispatch_semaphore_signal(entered);dispatch_semaphore_wait(release,dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_SEC));});
        axs_cachekeeper_runtime_require(dispatch_semaphore_wait(entered,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0,"owner queue is held");
        [engine didEnterBackgroundWithTime:YES];
        axs_cachekeeper_runtime_wait(engine,^BOOL(NSDictionary *r) {return [r[@"pending"] unsignedIntegerValue]==1;},"cleanup queues before helper mutation");
        NSDictionary *flightGeneration=[engine axs_cachekeeper_operation_context];
        axs_cachekeeper_image_runtime_view_changed();[engine requestDiscoveryRefresh];
        dispatch_semaphore_t observed=dispatch_semaphore_create(0);
        dispatch_async(engine.work,^{dispatch_semaphore_signal(observed);});
        axs_cachekeeper_runtime_require(dispatch_semaphore_wait(observed,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0,"pure observation refresh drains");
        axs_cachekeeper_runtime_require([flightGeneration isEqual:[engine axs_cachekeeper_operation_context]] &&
            [engine.receipt[@"pending"] unsignedIntegerValue]==1,"pure view observation leaves legitimate queued flight generation intact");
        method_setImplementation(helper,(IMP)axs_cachekeeper_runtime_changed_helper);
        unsigned sourceChecks=atomic_load(&axs_cachekeeper_runtime_source_checks),helperChecks=atomic_load(&axs_cachekeeper_runtime_helper_checks);
        [owner.diskCache setData:[NSData data] forKey:@"changed"];
        [owner.diskCache setExtendedData:[NSData data] forKey:@"changed"];
        unsigned expectedWrites=axs_cachekeeper_runtime_fingerprinted ? 1 : 0;
        axs_cachekeeper_runtime_require(atomic_load(&axs_cachekeeper_runtime_writes)==expectedWrites,"helper change immediately restores original write");
        axs_cachekeeper_runtime_require(atomic_load(&axs_cachekeeper_runtime_metadata)==expectedWrites,"helper change immediately restores original metadata write");
        axs_cachekeeper_runtime_require(atomic_load(&axs_cachekeeper_runtime_source_checks)==sourceChecks,"write hooks do not rescan primary fingerprints");
        axs_cachekeeper_runtime_require(axs_cachekeeper_runtime_fingerprinted ? atomic_load(&axs_cachekeeper_runtime_helper_checks)>helperChecks : atomic_load(&axs_cachekeeper_runtime_helper_checks)==helperChecks,"only the production fingerprint source checks helpers on writes");
        dispatch_semaphore_signal(release);
        axs_cachekeeper_runtime_wait(engine,^BOOL(NSDictionary *r) {return ![r[@"pending"] unsignedIntegerValue];},"queued operation finishes");
        unsigned expectedClears=axs_cachekeeper_runtime_fingerprinted ? 0 : 1;
        axs_cachekeeper_runtime_require(atomic_load(&axs_cachekeeper_runtime_clears)==expectedClears,"changed production helper cancels the queued SDK call");
        axs_cachekeeper_runtime_require([engine.receipt[@"submitted"] unsignedIntegerValue]==expectedClears,"receipt records only actual SDK submission");
        axs_cachekeeper_runtime_refresh(engine);
        if (axs_cachekeeper_runtime_fingerprinted) {
            axs_cachekeeper_runtime_require([engine.receipt[@"state"] isEqual:@"unsupported"] &&
                [engine.receipt[@"discoveryCheck"][@"source"] isEqual:@"imageFingerprint"] &&
                [engine.receipt[@"discoveryCheck"][@"failure"] isEqual:@"methodsChanged"] &&
                [engine.receipt[@"discoveryCheck"][@"methodIndex"] isEqual:@0],"helper refusal has a precise published diagnosis");
        } else axs_cachekeeper_runtime_require([engine.receipt[@"restricted"] unsignedIntegerValue]==1,"test pin is independent of the production helper");
        AxsCacheKeeperImageCache *next=[[AxsCacheKeeperImageCache alloc] initWithContextProvider:provider observer:nil];
        if (!axs_cachekeeper_runtime_fingerprinted) [next usePinnedLegacySDKForIntegrationTests];
        [next startObserving];axs_cachekeeper_runtime_refresh(next);
        axs_cachekeeper_runtime_require([next.receipt[@"state"] isEqual:axs_cachekeeper_runtime_fingerprinted ? @"unsupported" : @"notObserved"],"new observers cannot relearn a changed helper");

        method_setImplementation(helper,axs_cachekeeper_runtime_helper_original);
        axs_cachekeeper_runtime_refresh(engine);
        axs_cachekeeper_runtime_require([engine.receipt[@"restricted"] unsignedIntegerValue]==1,"restoring the verified helper permits restriction again");
        [owner.diskCache setData:[NSData data] forKey:@"restored"];
        axs_cachekeeper_runtime_require(atomic_load(&axs_cachekeeper_runtime_writes)==expectedWrites,"restored source blocks writes again");
        [engine didEnterBackgroundWithTime:YES];
        axs_cachekeeper_runtime_wait(engine,^BOOL(NSDictionary *r) {return [r[@"apiCompleted"] unsignedIntegerValue]==expectedClears+1;},"restored source can execute a new cleanup");
        axs_cachekeeper_runtime_require(atomic_load(&axs_cachekeeper_runtime_clears)==expectedClears+1,"restored source reaches the original SDK clear");
        NSDictionary *effect=[[engine.receipt[@"operationHistory"][@"processes"] lastObject][@"actions"] lastObject][@"cacheEffect"];
        axs_cachekeeper_runtime_require([effect[@"result"] isEqual:@"residual"] && [effect[@"before"][@"files"] isEqual:@1] &&
            [effect[@"after"][@"logicalBytes"] isEqual:@8],"no-op SDK completion retains actual residual evidence");
        @synchronized(contextLock) {context[@"appState"]=@{@"enabled":@NO};}
        axs_cachekeeper_runtime_refresh(engine);[owner.diskCache setData:[NSData data] forKey:@"disabled"];
        axs_cachekeeper_runtime_require(atomic_load(&axs_cachekeeper_runtime_writes)==expectedWrites+1,"disable restores the original write chain");
        axs_cachekeeper_runtime_require([NSFileManager.defaultManager removeItemAtPath:home error:nil],"fixture root is removed");
        printf("PASS: image-runtime-source fixture %s\n",argv[1]);
    }
    return 0;
}
