// Runtime gate fixture, not an SDWebImage/Baidu integration test. Only the source
// and helper fingerprint boundaries are substituted; adapter hooks, policy,
// filesystem scope checks, queueing and Objective-C method changes are real.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdatomic.h>
#include <stdio.h>
#include <unistd.h>
#import "AxsCacheKeeperImageLegacySource.h"

static atomic_uint axs_cachekeeper_runtime_writes,axs_cachekeeper_runtime_metadata,axs_cachekeeper_runtime_clears;
static atomic_uint axs_cachekeeper_runtime_source_checks,axs_cachekeeper_runtime_helper_checks;
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
- (instancetype)initWithNamespace:(NSString *)space diskCacheDirectory:(NSString *)directory config:(SDImageCacheConfig *)config {
    if (!(self=[super init])) return nil;
    _config=[config copy];_diskCachePath=[directory stringByAppendingPathComponent:space];
    _ioQueue=dispatch_queue_create("cachekeeper.runtime-source.fixture",DISPATCH_QUEUE_SERIAL);
    _memoryCache=[[SDMemoryCache alloc] initWithConfig:_config];
    _diskCache=[[SDDiskCache alloc] initWithCachePath:_diskCachePath config:_config];return self;
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
    return base==(const void *)_dyld_get_image_header(0) &&
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
#define AxsCacheKeeperImageLegacyHelpersMatch axs_cachekeeper_runtime_helpers_match
#define AxsCacheKeeperImageLegacySourceCheck axs_cachekeeper_runtime_source_check
#import "AxsCacheKeeperImageCache.m"
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
int main(int argc,const char *argv[]) {
    @autoreleasepool {
        axs_cachekeeper_runtime_require(argc==2 && (!strcmp(argv[1],"fingerprint") || !strcmp(argv[1],"pinned")),"one isolated scenario is required");
        axs_cachekeeper_runtime_fingerprinted=!strcmp(argv[1],"fingerprint");
        Method helper=class_getClassMethod(AxsCacheKeeperRuntimeSourceHelper.class,@selector(axs_cachekeeper_sample));
        axs_cachekeeper_runtime_helper_original=method_getImplementation(helper);
        NSString *home=[[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] stringByStandardizingPath];
        NSObject *contextLock=[NSObject new];
        NSMutableDictionary *context=[@{@"valid":@YES,@"appState":@{@"enabled":@YES,@"mode":@"auto",@"autoDiscover":@YES},
            @"selected":@[],@"home":home,@"bundle":@"cachekeeper.owned.runtime.fixture",@"version":@"1",@"installation":@"runtime-fixture",@"reportWritable":@YES} mutableCopy];
        AxsCacheKeeperImageContextProvider provider=^NSDictionary *{@synchronized(contextLock) {return [context copy];}};
        AxsCacheKeeperImageCache *engine=[[AxsCacheKeeperImageCache alloc] initWithContextProvider:provider observer:nil];
        if (!axs_cachekeeper_runtime_fingerprinted) [engine usePinnedLegacySDKForIntegrationTests];
        [engine startObserving];axs_cachekeeper_runtime_refresh(engine);
        NSString *source=axs_cachekeeper_runtime_fingerprinted ? @"imageFingerprint" : @"testPinned";
        axs_cachekeeper_runtime_require([engine.receipt[@"discoveryCheck"][@"source"] isEqual:source],"selected source is published");
        SDImageCache *owner=[[SDImageCache alloc] initWithNamespace:@"images" diskCacheDirectory:[home stringByAppendingPathComponent:@"Library/Caches"] config:[SDImageCacheConfig new]];
        axs_cachekeeper_runtime_refresh(engine);
        axs_cachekeeper_runtime_require([engine.receipt[@"restricted"] unsignedIntegerValue]==1,"actual owner is initially restricted");
        [owner.diskCache setData:[NSData data] forKey:@"initial"];
        [owner.diskCache setExtendedData:[NSData data] forKey:@"initial"];
        axs_cachekeeper_runtime_require(atomic_load(&axs_cachekeeper_runtime_writes)==0 && atomic_load(&axs_cachekeeper_runtime_metadata)==0,"both write hooks initially block");

        dispatch_semaphore_t entered=dispatch_semaphore_create(0),release=dispatch_semaphore_create(0);
        dispatch_async(owner.ioQueue,^{dispatch_semaphore_signal(entered);dispatch_semaphore_wait(release,dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_SEC));});
        axs_cachekeeper_runtime_require(dispatch_semaphore_wait(entered,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0,"owner queue is held");
        [engine didEnterBackgroundWithTime:YES];
        axs_cachekeeper_runtime_wait(engine,^BOOL(NSDictionary *r) {return [r[@"pending"] unsignedIntegerValue]==1;},"cleanup queues before helper mutation");
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
        @synchronized(contextLock) {context[@"appState"]=@{@"enabled":@NO};}
        axs_cachekeeper_runtime_refresh(engine);[owner.diskCache setData:[NSData data] forKey:@"disabled"];
        axs_cachekeeper_runtime_require(atomic_load(&axs_cachekeeper_runtime_writes)==expectedWrites+1,"disable restores the original write chain");
        axs_cachekeeper_runtime_require([NSFileManager.defaultManager removeItemAtPath:home error:nil],"fixture root is removed");
        printf("PASS: image-runtime-source fixture %s\n",argv[1]);
    }
    return 0;
}
