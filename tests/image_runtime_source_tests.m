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
static BOOL axs_cachekeeper_runtime_real_main_gate;
static BOOL axs_cachekeeper_runtime_revoke_after_helper;
static unsigned axs_cachekeeper_runtime_restore_after_main_failure;
static BOOL axs_cachekeeper_runtime_restore_changes_helper;
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
static BOOL axs_cachekeeper_runtime_defer_owner;
extern void axs_cachekeeper_runtime_enqueue_autorelease(id owner);
static void axs_cachekeeper_runtime_deferred_owner(id owner) {
    // A legal SDK getter can create an autoreleased temporary that retains its
    // receiver. Force this boundary so the regression does not depend on ARC's
    // optional return-value optimization on a particular CPU or compiler.
    if (axs_cachekeeper_runtime_defer_owner) axs_cachekeeper_runtime_enqueue_autorelease(owner);
}
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
- (SDDiskCache *)diskCache {axs_cachekeeper_runtime_getter();axs_cachekeeper_runtime_deferred_owner(self);return _diskCache;}
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
static AxsCacheKeeperImageLegacyCheck axs_cachekeeper_runtime_main_layout_check(const void *base,AxsCacheKeeperImageLegacyLayout *layout) {
    if (axs_cachekeeper_runtime_real_main_gate) {
        AxsCacheKeeperImageLegacyCheck check=AxsCacheKeeperImageLegacyMainLayoutCheck(base,layout);
        if (!check.accepted && !strcmp(check.reason,"notMainBase") && axs_cachekeeper_runtime_restore_after_main_failure &&
            --axs_cachekeeper_runtime_restore_after_main_failure==0) {
            // Restore the actual executable only after the production main gate
            // returned its rejection; classification must retain that same view.
            AxsCacheKeeperImageRefreshExecutable();
            if (axs_cachekeeper_runtime_restore_changes_helper)
                method_setImplementation(class_getClassMethod(AxsCacheKeeperRuntimeSourceHelper.class,@selector(axs_cachekeeper_sample)),(IMP)axs_cachekeeper_runtime_changed_helper);
        }
        return check;
    }
    if (base!=axs_cachekeeper_runtime_main_header) return AxsCacheKeeperImageLegacyResult("mainIdentity","notMainBase",0,0);
    layout->base=(uintptr_t)base;return AxsCacheKeeperImageLegacyComplete();
}
static AxsCacheKeeperImageLegacyCheck axs_cachekeeper_runtime_helpers_check(const AxsCacheKeeperImageLegacyLayout *layout) {
    AxsCacheKeeperImageLegacyCheck check=axs_cachekeeper_runtime_helpers_match((const void *)layout->base) ? AxsCacheKeeperImageLegacyComplete() : AxsCacheKeeperImageLegacyResult("helperWindow","changed",0,1);
    if (check.accepted && axs_cachekeeper_runtime_revoke_after_helper) {
        axs_cachekeeper_runtime_revoke_after_helper=NO;
        atomic_fetch_add(&axs_cachekeeper_image_observation_generation,1);
    }
    return check;
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
#define AxsCacheKeeperImageLegacyMainLayoutCheck axs_cachekeeper_runtime_main_layout_check
#define AxsCacheKeeperImageLegacyHelpersCheck axs_cachekeeper_runtime_helpers_check
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
#undef AxsCacheKeeperImageLegacyMainLayoutCheck
#undef AxsCacheKeeperImageLegacyHelpersCheck
#undef AxsCacheKeeperImageLegacyHelpersMatch
#undef AxsCacheKeeperImageLegacySourceCheck

static void axs_cachekeeper_runtime_require(BOOL value,const char *message) {
    if (!value) {fprintf(stderr,"FAIL: image-runtime-source: %s\n",message);exit(1);}
}
static void axs_cachekeeper_runtime_worker_fence(AxsCacheKeeperImageCache *engine) {
    // completion executes inside the preceding work item. This async FIFO item
    // proves that it returned and its per-item autoreleasepool was drained.
    dispatch_semaphore_t done=dispatch_semaphore_create(0);
    dispatch_async(engine.work,^{dispatch_semaphore_signal(done);});
    axs_cachekeeper_runtime_require(!dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)),"worker item and its pool finished");
}
static void axs_cachekeeper_runtime_refresh(AxsCacheKeeperImageCache *engine) {
    dispatch_semaphore_t done=dispatch_semaphore_create(0);
    [engine refreshWithCompletion:^{dispatch_semaphore_signal(done);}];
    axs_cachekeeper_runtime_require(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0,"refresh completes");
    axs_cachekeeper_runtime_worker_fence(engine);
    NSDictionary *receipt=engine.receipt;
    axs_cachekeeper_runtime_require(axs_cachekeeper_image_discovery_projection(receipt[@"discoveryCheck"])!=nil,"receipt discovery remains closed");
    axs_cachekeeper_runtime_require(axs_cachekeeper_image_sdk_rejection_projection(receipt[@"sdkMethodsRejectionObservation"])!=nil,"receipt first SDK rejection remains closed");
    axs_cachekeeper_runtime_require(axs_cachekeeper_image_admission_projection(receipt[@"instanceAdmission"],[receipt[@"observed"] unsignedIntegerValue])!=nil,"receipt initializer accounting remains closed");
    axs_cachekeeper_runtime_require(axs_cachekeeper_operation_history_validate(receipt[@"operationHistory"],@"image")!=nil,"receipt operation history remains closed");
    axs_cachekeeper_runtime_require(axs_cachekeeper_image_cache_projection(receipt)!=nil,"receipt retains the public schema");
}
static void axs_cachekeeper_runtime_wait(AxsCacheKeeperImageCache *engine,BOOL (^condition)(NSDictionary *),const char *message) {
    for (NSUInteger attempt=0;attempt<500;attempt++) {if (condition(engine.receipt)) return;usleep(10000);}
    axs_cachekeeper_runtime_require(NO,message);
}
static void axs_cachekeeper_runtime_released(AxsCacheKeeperImageCache *engine,__weak SDImageCache **owner,NSUInteger count) {
    NSDictionary *r=engine.receipt;
    BOOL live=*owner!=nil;
    if (live || ![r[@"observed"] isEqual:@0] || ![r[@"instanceAdmission"][@"released"] isEqual:@(count)]) {
        fprintf(stderr,"INFO: release live=%d observed=%lu released=%lu expected=%lu\n",live,
            (unsigned long)[r[@"observed"] unsignedIntegerValue],(unsigned long)[r[@"instanceAdmission"][@"released"] unsignedIntegerValue],(unsigned long)count);
    }
    axs_cachekeeper_runtime_require(!live && [r[@"observed"] isEqual:@0] &&
        [r[@"instanceAdmission"][@"released"] isEqual:@(count)],"weak owner release is recorded once without retention");
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
    axs_cachekeeper_runtime_released(engine,&weakOwner,1);
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
    NSDictionary *rejection=engine.receipt[@"sdkMethodsRejectionObservation"];
    axs_cachekeeper_runtime_require([rejection[@"state"] isEqual:@"recorded"] && [rejection[@"initializerOrdinal"] isEqual:@32] &&
        [rejection[@"check"][@"cause"] isEqual:@"implementation"] && [rejection[@"check"][@"methodIndex"] isEqual:@4],"first SDK rejection freezes ordinal and exact method slot");
    dispatch_sync(engine.work,^{[engine axs_cachekeeper_publish];});
    axs_cachekeeper_runtime_require([engine.receipt[@"sdkMethodsRejectionObservation"] isEqual:rejection],"publication does not rerun or overwrite frozen SDK rejection");
    axs_cachekeeper_runtime_require([engine.receipt[@"instanceAdmission"][@"unregisteredReasons"][@"sdkMethodsChanged"] isEqual:@1] &&
        [engine.receipt[@"restricted"] isEqual:@1],"source method rejection cannot overwrite an admitted owner");
    Method laterGetter=class_getInstanceMethod(SDImageCache.class,@selector(diskCache));
    IMP laterOriginal=method_getImplementation(laterGetter);IMP laterForeign=imp_implementationWithBlock(^id(id object) {(void)object;return nil;});
    method_setImplementation(laterGetter,laterForeign);
    calls=atomic_load(&axs_cachekeeper_runtime_getter_calls);
    [engine axs_cachekeeper_observe:next sourceReason:nil attributes:nil contract:AxsCacheKeeperImageContractFixedSerialLegacy];
    axs_cachekeeper_runtime_require(atomic_load(&axs_cachekeeper_runtime_getter_calls)==calls,"later method rejection still occurs before member reads");
    method_setImplementation(laterGetter,laterOriginal);imp_removeBlock(laterForeign);axs_cachekeeper_runtime_refresh(engine);
    axs_cachekeeper_runtime_require([engine.receipt[@"instanceAdmission"][@"unregisteredReasons"][@"sdkMethodsChanged"] isEqual:@2] &&
        [engine.receipt[@"sdkMethodsRejectionObservation"] isEqual:rejection],"later SDK rejection increments counters without replacing first failure");
    dispatch_queue_t nextQueue=next.ioQueue;
    dispatch_semaphore_t entered=dispatch_semaphore_create(0),release=dispatch_semaphore_create(0);
    dispatch_async(nextQueue,^{dispatch_semaphore_signal(entered);dispatch_semaphore_wait(release,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC));});
    axs_cachekeeper_runtime_require(!dispatch_semaphore_wait(entered,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)),"pending owner SDK queue is held");
    [engine didEnterBackgroundWithTime:YES];
    axs_cachekeeper_runtime_wait(engine,^BOOL(NSDictionary *r) {return [r[@"pending"] isEqual:@1];},"real cleanup is queued before owner release");
    axs_cachekeeper_runtime_worker_fence(engine);
    next=nil;
    dispatch_sync(engine.work,^{[engine axs_cachekeeper_publish];});
    axs_cachekeeper_runtime_require([engine.receipt[@"instanceAdmission"][@"released"] isEqual:@2] &&
        [engine.receipt[@"observed"] isEqual:@0] && [engine.receipt[@"pending"] isEqual:@1],"released pending owner preserves its unfinished action");
    dispatch_semaphore_signal(release);
    axs_cachekeeper_runtime_wait(engine,^BOOL(NSDictionary *r) {return [r[@"pending"] isEqual:@0];},"released owner queued cleanup exits safely");
    axs_cachekeeper_runtime_require([engine.receipt[@"submitted"] isEqual:@0] && [engine.receipt[@"skipped"] isEqual:@1] &&
        [engine.receipt[@"instanceAdmission"][@"released"] isEqual:@2],"released owner cannot submit cleanup or double count release");
}
static void axs_cachekeeper_runtime_owner_pool(AxsCacheKeeperImageCache *engine,NSString *home) {
    // Verify the fixture itself really retains until pool exit before exercising
    // the production refresh boundary. This must hold for every compiler/CPU.
    __weak NSObject *probe;
    @autoreleasepool {
        __attribute__((objc_precise_lifetime)) NSObject *object=[NSObject new];probe=object;
        axs_cachekeeper_runtime_enqueue_autorelease(object);object=nil;
        axs_cachekeeper_runtime_require(probe!=nil,"fixture retains its owner until explicit pool exit");
    }
    axs_cachekeeper_runtime_require(probe==nil,"fixture releases its owner exactly at pool exit");
    axs_cachekeeper_runtime_defer_owner=YES;
    __weak SDImageCache *weakOwner;
    dispatch_semaphore_t entered=dispatch_semaphore_create(0),check=dispatch_semaphore_create(0),done=dispatch_semaphore_create(0),finish=dispatch_semaphore_create(0);
    @autoreleasepool {
        __attribute__((objc_precise_lifetime)) SDImageCache *owner=[[SDImageCache alloc] initWithNamespace:@"pool-owner" diskCacheDirectory:[home stringByAppendingPathComponent:@"Library/Caches"] config:[SDImageCacheConfig new]];
        axs_cachekeeper_runtime_refresh(engine);
        dispatch_async(engine.work,^{
            // Hold an explicit outer pool in this one work item. The refresh
            // must close its own SDK temporaries before it returns; neither a
            // thread change nor a libdispatch root drain can satisfy the RED.
            @autoreleasepool {
                NSUInteger event=[engine axs_cachekeeper_begin_event:@"configuration" context:[engine axs_cachekeeper_operation_context] current:YES];
                [engine axs_cachekeeper_refresh_event:event];axs_cachekeeper_operation_finish(engine.operationHistory,event);
                dispatch_semaphore_signal(entered);
                axs_cachekeeper_runtime_require(!dispatch_semaphore_wait(check,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)),"owner release check is permitted");
                [engine axs_cachekeeper_publish];dispatch_semaphore_signal(done);
                axs_cachekeeper_runtime_require(!dispatch_semaphore_wait(finish,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)),"owner pool assertion finished before worker retires");
            }
        });
        axs_cachekeeper_runtime_require(!dispatch_semaphore_wait(entered,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)),"owner pool fence entered after refresh");
        axs_cachekeeper_runtime_require([engine.receipt[@"eligible"] isEqual:@1],"SDK getter with deferred owner remains eligible");
        weakOwner=owner;owner=nil;
    }
    dispatch_semaphore_signal(check);
    axs_cachekeeper_runtime_require(!dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)),"owner pool publication finished");
    axs_cachekeeper_runtime_released(engine,&weakOwner,1);
    dispatch_semaphore_signal(finish);axs_cachekeeper_runtime_worker_fence(engine);
    axs_cachekeeper_runtime_defer_owner=NO;
}
static void axs_cachekeeper_runtime_main_view(AxsCacheKeeperImageCache *engine,NSString *home,NSMutableDictionary *context) {
    dispatch_semaphore_t entered=dispatch_semaphore_create(0),release=dispatch_semaphore_create(0);
    dispatch_async(engine.work,^{dispatch_semaphore_signal(entered);dispatch_semaphore_wait(release,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC));});
    axs_cachekeeper_runtime_require(!dispatch_semaphore_wait(entered,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)),"main view discovery is held before constructor returns");
    axs_cachekeeper_image_runtime_view_changed();
    AxsCacheKeeperImageLegacyLayout layout;
    AxsCacheKeeperImageLegacyCheck stale=AxsCacheKeeperImageLegacyMainLayoutCheck(axs_cachekeeper_runtime_main_header,&layout);
    axs_cachekeeper_runtime_require(!stale.accepted && !strcmp(stale.stage,"mainIdentity") && !strcmp(stale.reason,"notMainBase"),"actual MainLayoutCheck refuses revoked executable before asynchronous discovery");
    SDImageCache *owner=[[SDImageCache alloc] initWithNamespace:@"recover" diskCacheDirectory:[home stringByAppendingPathComponent:@"Library/Caches"] config:[SDImageCacheConfig new]];
    SDDiskCache *disk=owner.diskCache;
    [disk setData:[NSData data] forKey:@"waiting"];[disk setExtendedData:[NSData data] forKey:@"waiting"];
    axs_cachekeeper_runtime_require(!objc_getAssociatedObject(disk,AxsCacheKeeperImageBindingKey) && atomic_load(&axs_cachekeeper_runtime_writes)==1 && atomic_load(&axs_cachekeeper_runtime_metadata)==1,"waiting owner has no binding association and preserves both original writes");
    // Pure discovery used to lose this owner forever. No configuration refresh
    // may substitute for the actual asynchronous discovery completion here.
    [engine requestDiscoveryRefresh];dispatch_semaphore_signal(release);
    axs_cachekeeper_runtime_worker_fence(engine);axs_cachekeeper_runtime_worker_fence(engine);
    axs_cachekeeper_runtime_require([engine.receipt[@"observed"] isEqual:@1] && [engine.receipt[@"restricted"] isEqual:@1],"constructor owner survives revoked main view and is fully readmitted by discovery");
#if !defined(AXS_CACHEKEEPER_MAIN_VIEW_BASELINE)
    axs_cachekeeper_runtime_require([engine.receipt[@"instanceAdmission"][@"initializerReturns"] isEqual:@1] && [engine.receipt[@"instanceAdmission"][@"registered"] isEqual:@1] && [engine.receipt[@"instanceAdmission"][@"unregistered"] isEqual:@0],"waiting observation closes original initializer accounting without invented retry returns");
    NSDictionary *rejection=engine.receipt[@"sdkMethodsRejectionObservation"];
    axs_cachekeeper_runtime_require([rejection[@"check"][@"helperReason"] isEqual:@"notMainBase"] && [rejection[@"initializerOrdinal"] isEqual:@1],"first synchronous main rejection remains frozen after recovery");
    [disk setData:[NSData data] forKey:@"recovered"];[disk setExtendedData:[NSData data] forKey:@"recovered"];
    axs_cachekeeper_runtime_require(atomic_load(&axs_cachekeeper_runtime_writes)==1 && atomic_load(&axs_cachekeeper_runtime_metadata)==1,"recovered owner blocks both writes only after full admission");
    context[@"appState"]=@{@"enabled":@NO,@"mode":@"auto",@"autoDiscover":@YES};axs_cachekeeper_runtime_refresh(engine);
    [disk setData:[NSData data] forKey:@"disabled"];[disk setExtendedData:[NSData data] forKey:@"disabled"];
    axs_cachekeeper_runtime_require(atomic_load(&axs_cachekeeper_runtime_writes)==2 && atomic_load(&axs_cachekeeper_runtime_metadata)==2 && [engine.receipt[@"restricted"] isEqual:@0],"disabled policy restores both writes after main view recovery");
    context[@"appState"]=@{@"enabled":@YES,@"mode":@"auto",@"autoDiscover":@YES};axs_cachekeeper_runtime_refresh(engine);
    // Policy exclusions block recovery temporarily, not the authentic owner for
    // the rest of its lifetime. The old queue/path/FD snapshot remains required.
    dispatch_semaphore_t scopeEntered=dispatch_semaphore_create(0),scopeRelease=dispatch_semaphore_create(0);
    dispatch_async(engine.work,^{dispatch_semaphore_signal(scopeEntered);dispatch_semaphore_wait(scopeRelease,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC));});
    axs_cachekeeper_runtime_require(!dispatch_semaphore_wait(scopeEntered,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)),"scope recovery worker is held");
    axs_cachekeeper_image_runtime_view_changed();
    SDImageCache *excluded=[[SDImageCache alloc] initWithNamespace:@"policy-scope" diskCacheDirectory:[home stringByAppendingPathComponent:@"Library/Caches"] config:[SDImageCacheConfig new]];
    context[@"appState"]=@{@"enabled":@YES,@"mode":@"auto",@"autoDiscover":@YES,@"excludedPaths":@[@"Library/Caches/policy-scope"]};
    dispatch_semaphore_signal(scopeRelease);axs_cachekeeper_runtime_refresh(engine);
    AxsCacheKeeperImageBinding *waitingScope=nil;for (AxsCacheKeeperImageBinding *item in [engine axs_cachekeeper_bindings]) if (item.owner==excluded) waitingScope=item;
    unsigned beforeExcluded=atomic_load(&axs_cachekeeper_runtime_writes),metadataExcluded=atomic_load(&axs_cachekeeper_runtime_metadata);
    [excluded.diskCache setData:[NSData data] forKey:@"excluded"];[excluded.diskCache setExtendedData:[NSData data] forKey:@"excluded"];
    axs_cachekeeper_runtime_require(waitingScope.awaitingMainView && !waitingScope.invalidated && !waitingScope.eligible && !waitingScope.restricted &&
        !objc_getAssociatedObject(excluded.diskCache,AxsCacheKeeperImageBindingKey) && atomic_load(&axs_cachekeeper_runtime_writes)==beforeExcluded+1 && atomic_load(&axs_cachekeeper_runtime_metadata)==metadataExcluded+1,
        "temporarily excluded waiting owner keeps both original writes without permanent invalidation");
    context[@"appState"]=@{@"enabled":@YES,@"mode":@"auto",@"autoDiscover":@YES};axs_cachekeeper_runtime_refresh(engine);
    [excluded.diskCache setData:[NSData data] forKey:@"scope-restored"];[excluded.diskCache setExtendedData:[NSData data] forKey:@"scope-restored"];
    axs_cachekeeper_runtime_require(!waitingScope.awaitingMainView && !waitingScope.invalidated && waitingScope.eligible && waitingScope.restricted &&
        atomic_load(&axs_cachekeeper_runtime_writes)==beforeExcluded+1 && atomic_load(&axs_cachekeeper_runtime_metadata)==metadataExcluded+1,
        "removing the exclusion fully readmits the same owner with its original identity");
    NSUInteger observedAfterScope=[engine.receipt[@"observed"] unsignedIntegerValue];
    // Once the view is valid, changed constructor members are rejected rather
    // than becoming a fresh trusted baseline. Restoring them cannot retry.
    for (NSString *fault in @[@"queue",@"installation",@"helper",@"rawIMP"]) {
        dispatch_semaphore_t faultEntered=dispatch_semaphore_create(0),faultRelease=dispatch_semaphore_create(0);
        dispatch_async(engine.work,^{dispatch_semaphore_signal(faultEntered);dispatch_semaphore_wait(faultRelease,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC));});
        axs_cachekeeper_runtime_require(!dispatch_semaphore_wait(faultEntered,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)),"rejection recovery worker is held");
        axs_cachekeeper_image_runtime_view_changed();
        SDImageCache *changed=[[SDImageCache alloc] initWithNamespace:fault diskCacheDirectory:[home stringByAppendingPathComponent:@"Library/Caches"] config:[SDImageCacheConfig new]];
        dispatch_queue_t queue=changed.ioQueue;
        Method helper=class_getClassMethod(AxsCacheKeeperRuntimeSourceHelper.class,@selector(axs_cachekeeper_sample));
        Method writer=class_getInstanceMethod(SDDiskCache.class,@selector(setData:forKey:));IMP writerIMP=method_getImplementation(writer);
        if ([fault isEqual:@"queue"]) changed.ioQueue=dispatch_queue_create("cachekeeper.changed.queue",DISPATCH_QUEUE_SERIAL);
        if ([fault isEqual:@"installation"]) context[@"installation"]=@"changed-runtime-fixture";
        if ([fault isEqual:@"helper"]) method_setImplementation(helper,(IMP)axs_cachekeeper_runtime_changed_helper);
        if ([fault isEqual:@"rawIMP"]) method_setImplementation(writer,axs_cachekeeper_image_data_original);
        dispatch_semaphore_signal(faultRelease);axs_cachekeeper_runtime_worker_fence(engine);axs_cachekeeper_runtime_worker_fence(engine);
        AxsCacheKeeperImageBinding *rejected=nil;for (AxsCacheKeeperImageBinding *binding in [engine axs_cachekeeper_bindings]) if (binding.owner==changed) rejected=binding;
        axs_cachekeeper_runtime_require(rejected && rejected.invalidated && !rejected.eligible && !rejected.restricted && !objc_getAssociatedObject(changed.diskCache,AxsCacheKeeperImageBindingKey),"changed source or constructor member stays unassociated and rejected");
        changed.ioQueue=queue;context[@"installation"]=@"runtime-fixture";method_setImplementation(helper,axs_cachekeeper_runtime_helper_original);method_setImplementation(writer,writerIMP);
        axs_cachekeeper_runtime_refresh(engine);
        axs_cachekeeper_runtime_require(rejected.invalidated && !rejected.eligible && !rejected.restricted,"terminal waiting rejection never retries after member restoration");
    }
    // Settle the preceding fault owners before freezing this release baseline.
    // The last loop owner dies after its refresh snapshot; registration would
    // otherwise count that old release together with the temporary below.
    dispatch_semaphore_t entered2=dispatch_semaphore_create(0),release2=dispatch_semaphore_create(0);
    dispatch_async(engine.work,^{[engine axs_cachekeeper_publish];dispatch_semaphore_signal(entered2);dispatch_semaphore_wait(release2,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC));});
    axs_cachekeeper_runtime_require(!dispatch_semaphore_wait(entered2,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)),"release recovery worker is held");
    NSDictionary *beforeRelease=engine.receipt;
    axs_cachekeeper_runtime_require([beforeRelease[@"observed"] isEqual:@(observedAfterScope)] && axs_cachekeeper_image_cache_projection(beforeRelease)!=nil,"release baseline settles prior fault owners with closed accounting");
    NSUInteger releasedBefore=[beforeRelease[@"instanceAdmission"][@"released"] unsignedIntegerValue];
    axs_cachekeeper_image_runtime_view_changed();__weak SDImageCache *weak;
    @autoreleasepool {SDImageCache *temporary=[[SDImageCache alloc] initWithNamespace:@"released" diskCacheDirectory:[home stringByAppendingPathComponent:@"Library/Caches"] config:[SDImageCacheConfig new]];weak=temporary;}
    axs_cachekeeper_runtime_require(!weak,"waiting registry does not retain its owner");
    dispatch_semaphore_signal(release2);axs_cachekeeper_runtime_worker_fence(engine);axs_cachekeeper_runtime_worker_fence(engine);
    dispatch_sync(engine.work,^{[engine axs_cachekeeper_publish];});
    NSDictionary *releasedReceipt=engine.receipt;
    if (![releasedReceipt[@"observed"] isEqual:@(observedAfterScope)] || ![releasedReceipt[@"instanceAdmission"][@"released"] isEqual:@(releasedBefore+1)])
        fprintf(stderr,"INFO: release observed=%lu expected=%lu released=%lu expected=%lu\n",(unsigned long)[releasedReceipt[@"observed"] unsignedIntegerValue],(unsigned long)observedAfterScope,(unsigned long)[releasedReceipt[@"instanceAdmission"][@"released"] unsignedIntegerValue],(unsigned long)(releasedBefore+1));
    axs_cachekeeper_runtime_require([releasedReceipt[@"observed"] isEqual:@(observedAfterScope)] && [releasedReceipt[@"instanceAdmission"][@"released"] isEqual:@(releasedBefore+1)] && axs_cachekeeper_image_cache_projection(releasedReceipt)!=nil,"released waiting owner is counted once and is never readmitted");
    dispatch_sync(engine.work,^{[engine axs_cachekeeper_publish];});
    axs_cachekeeper_runtime_require([engine.receipt[@"instanceAdmission"] isEqual:releasedReceipt[@"instanceAdmission"]],"repeated publication cannot count the same waiting release again");
#endif
}
#if !defined(AXS_CACHEKEEPER_MAIN_VIEW_BASELINE)
static IMP axs_cachekeeper_runtime_register_original;
static BOOL axs_cachekeeper_runtime_register_reentry;
static BOOL axs_cachekeeper_runtime_register_after(id engine,SEL selector,AxsCacheKeeperImageBinding *binding,NSDictionary *check) {
    BOOL registered=((BOOL (*)(id,SEL,id,id))axs_cachekeeper_runtime_register_original)(engine,selector,binding,check);
    if (axs_cachekeeper_runtime_register_reentry) {
        axs_cachekeeper_runtime_register_reentry=NO;
        // This outcome arrives exactly after the registry transaction but before
        // the outer observe method can execute its next instruction.
        [engine axs_cachekeeper_unregistered:AxsCacheKeeperImageReasonInitializerReturnedNil];
    }
    return registered;
}
static void axs_cachekeeper_runtime_recovery_race(AxsCacheKeeperImageCache *engine,NSString *home,NSDictionary *context) {
    dispatch_semaphore_t entered=dispatch_semaphore_create(0),release=dispatch_semaphore_create(0),done=dispatch_semaphore_create(0),resume=dispatch_semaphore_create(0);
    dispatch_async(engine.work,^{
        dispatch_semaphore_signal(entered);
        dispatch_semaphore_wait(release,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC));
        // Refresh only the real executable cache. The first helper check inside
        // production recovery succeeds, then revokes the view before instance
        // validation repeats it. No recovery method or result is substituted.
        AxsCacheKeeperImageRefreshExecutable();
        axs_cachekeeper_runtime_revoke_after_helper=YES;
        [engine axs_cachekeeper_recoverMainView:context];
        [engine axs_cachekeeper_publish];
        dispatch_semaphore_signal(done);
        dispatch_semaphore_wait(resume,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC));
    });
    axs_cachekeeper_runtime_require(!dispatch_semaphore_wait(entered,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)),"recovery race worker is held");
    axs_cachekeeper_image_runtime_view_changed();
    SEL selector=sel_registerName("axs_cachekeeper_registerBinding:methodsCheck:");
    Method registration=class_getInstanceMethod(AxsCacheKeeperImageCache.class,selector);
    axs_cachekeeper_runtime_require(registration!=NULL,"registration transaction exposes the complete rejection input");
    axs_cachekeeper_runtime_register_original=method_setImplementation(registration,(IMP)axs_cachekeeper_runtime_register_after);
    axs_cachekeeper_runtime_register_reentry=YES;
    SDImageCache *owner=[[SDImageCache alloc] initWithNamespace:@"race" diskCacheDirectory:[home stringByAppendingPathComponent:@"Library/Caches"] config:[SDImageCacheConfig new]];
    method_setImplementation(registration,axs_cachekeeper_runtime_register_original);
    axs_cachekeeper_runtime_require([engine.firstSDKMethodsRejection[@"initializerOrdinal"] isEqual:@1] &&
        [engine.firstSDKMethodsRejection[@"check"][@"helperReason"] isEqual:@"notMainBase"],"reentrant early return cannot steal the waiting rejection ordinal or snapshot");
    AxsCacheKeeperImageBinding *binding=nil;for (AxsCacheKeeperImageBinding *item in [engine axs_cachekeeper_bindings]) if (item.owner==owner) binding=item;
    axs_cachekeeper_runtime_require(binding && binding.awaitingMainView,"race owner starts in weak waiting registry");
    dispatch_semaphore_signal(release);
    axs_cachekeeper_runtime_require(!dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)),"revoked recovery check completes");
    axs_cachekeeper_runtime_require(binding.awaitingMainView && !binding.invalidated && !binding.restricted && !binding.eligible &&
        !objc_getAssociatedObject(owner.diskCache,AxsCacheKeeperImageBindingKey),"a second view revocation between recovery checks keeps the live owner waiting");
    dispatch_semaphore_signal(resume);
    axs_cachekeeper_runtime_refresh(engine);
    axs_cachekeeper_runtime_require(!binding.awaitingMainView && !binding.invalidated && binding.restricted && binding.eligible,
        "stable view after the recovery race fully readmits the same owner");
    // Combining view revocation with a genuine raw-IMP change never gets the
    // retry privilege. Restoring that IMP later cannot readmit this instance.
    dispatch_semaphore_t entered2=dispatch_semaphore_create(0),release2=dispatch_semaphore_create(0),done2=dispatch_semaphore_create(0);
    dispatch_async(engine.work,^{dispatch_semaphore_signal(entered2);dispatch_semaphore_wait(release2,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC));
        AxsCacheKeeperImageRefreshExecutable();axs_cachekeeper_runtime_revoke_after_helper=YES;
        [engine axs_cachekeeper_recoverMainView:context];dispatch_semaphore_signal(done2);});
    axs_cachekeeper_runtime_require(!dispatch_semaphore_wait(entered2,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)),"mixed recovery race worker is held");
    axs_cachekeeper_image_runtime_view_changed();
    SDImageCache *changed=[[SDImageCache alloc] initWithNamespace:@"race-raw" diskCacheDirectory:[home stringByAppendingPathComponent:@"Library/Caches"] config:[SDImageCacheConfig new]];
    AxsCacheKeeperImageBinding *failed=nil;for (AxsCacheKeeperImageBinding *item in [engine axs_cachekeeper_bindings]) if (item.owner==changed) failed=item;
    Method writer=class_getInstanceMethod(SDDiskCache.class,@selector(setData:forKey:));IMP saved=method_setImplementation(writer,axs_cachekeeper_image_data_original);
    dispatch_semaphore_signal(release2);axs_cachekeeper_runtime_require(!dispatch_semaphore_wait(done2,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)),"mixed recovery race completes");
    method_setImplementation(writer,saved);axs_cachekeeper_runtime_refresh(engine);
    axs_cachekeeper_runtime_require(failed.invalidated && !failed.restricted && !failed.eligible && !objc_getAssociatedObject(changed.diskCache,AxsCacheKeeperImageBindingKey),"raw IMP change remains terminal even when the executable view is also revoked");
    for (unsigned checkpoint=1;checkpoint<=3;checkpoint++) {
        dispatch_semaphore_t held=dispatch_semaphore_create(0),go=dispatch_semaphore_create(0);
        dispatch_async(engine.work,^{dispatch_semaphore_signal(held);dispatch_semaphore_wait(go,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC));});
        axs_cachekeeper_runtime_require(!dispatch_semaphore_wait(held,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)),"constructor classification worker is held");
        axs_cachekeeper_image_runtime_view_changed();axs_cachekeeper_runtime_restore_after_main_failure=checkpoint;
        SDImageCache *restored=[[SDImageCache alloc] initWithNamespace:[NSString stringWithFormat:@"restore-%u",checkpoint] diskCacheDirectory:[home stringByAppendingPathComponent:@"Library/Caches"] config:[SDImageCacheConfig new]];
        axs_cachekeeper_runtime_require(!axs_cachekeeper_runtime_restore_after_main_failure,"the actual main rejection restored its executable at the selected constructor checkpoint");
        dispatch_semaphore_signal(go);axs_cachekeeper_runtime_refresh(engine);
        AxsCacheKeeperImageBinding *readmitted=nil;for (AxsCacheKeeperImageBinding *item in [engine axs_cachekeeper_bindings]) if (item.owner==restored) readmitted=item;
        axs_cachekeeper_runtime_require(readmitted && !readmitted.initialReason && !readmitted.invalidated && !readmitted.awaitingMainView && readmitted.eligible && readmitted.restricted,
            "a restored view after the constructor main rejection never freezes a permanent source reason or loses the owner");
    }
    // A genuine helper change at that same restore boundary remains terminal.
    dispatch_semaphore_t held=dispatch_semaphore_create(0),go=dispatch_semaphore_create(0);
    dispatch_async(engine.work,^{dispatch_semaphore_signal(held);dispatch_semaphore_wait(go,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC));});
    axs_cachekeeper_runtime_require(!dispatch_semaphore_wait(held,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)),"helper restoration worker is held");
    NSUInteger unregistered=[engine.receipt[@"instanceAdmission"][@"unregistered"] unsignedIntegerValue];
    axs_cachekeeper_image_runtime_view_changed();axs_cachekeeper_runtime_restore_after_main_failure=1;axs_cachekeeper_runtime_restore_changes_helper=YES;
    SDImageCache *helperChanged=[[SDImageCache alloc] initWithNamespace:@"restore-helper" diskCacheDirectory:[home stringByAppendingPathComponent:@"Library/Caches"] config:[SDImageCacheConfig new]];
    axs_cachekeeper_runtime_restore_changes_helper=NO;dispatch_semaphore_signal(go);axs_cachekeeper_runtime_refresh(engine);
    method_setImplementation(class_getClassMethod(AxsCacheKeeperRuntimeSourceHelper.class,@selector(axs_cachekeeper_sample)),axs_cachekeeper_runtime_helper_original);
    axs_cachekeeper_runtime_refresh(engine);
    axs_cachekeeper_runtime_require(!objc_getAssociatedObject(helperChanged.diskCache,AxsCacheKeeperImageBindingKey) &&
        [engine.receipt[@"instanceAdmission"][@"unregistered"] unsignedIntegerValue]==unregistered+1,
        "helper change during restoration remains a true early rejection after the helper is restored");
}
#endif
int main(int argc,const char *argv[]) {
    @autoreleasepool {
        axs_cachekeeper_runtime_require(argc==2 && (!strcmp(argv[1],"fingerprint") || !strcmp(argv[1],"fingerprint-shifted") || !strcmp(argv[1],"sample") || !strcmp(argv[1],"pinned") || !strcmp(argv[1],"refresh") || !strcmp(argv[1],"admission") || !strcmp(argv[1],"owner-pool") || !strcmp(argv[1],"main-view") || !strcmp(argv[1],"recovery-race")),"one isolated scenario is required");
        axs_cachekeeper_runtime_real_main_gate=!strcmp(argv[1],"main-view") || !strcmp(argv[1],"recovery-race");
        axs_cachekeeper_runtime_shifted=!strcmp(argv[1],"fingerprint-shifted");
        axs_cachekeeper_runtime_fingerprinted=!strcmp(argv[1],"fingerprint") || axs_cachekeeper_runtime_shifted || axs_cachekeeper_runtime_real_main_gate;
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
#if !defined(AXS_CACHEKEEPER_MAIN_VIEW_BASELINE)
        if (!strcmp(argv[1],"recovery-race")) {
            axs_cachekeeper_runtime_recovery_race(engine,home,provider());
            axs_cachekeeper_runtime_require([NSFileManager.defaultManager removeItemAtPath:home error:nil],"recovery race fixture root removed");
            puts("PASS: image-runtime-source fixture recovery-race");return 0;
        }
#endif
        if (!strcmp(argv[1],"main-view")) {
            axs_cachekeeper_runtime_main_view(engine,home,context);
            axs_cachekeeper_runtime_require([NSFileManager.defaultManager removeItemAtPath:home error:nil],"main view fixture root removed");
            puts("PASS: image-runtime-source fixture main-view");return 0;
        }
        if (!strcmp(argv[1],"owner-pool")) {
            axs_cachekeeper_runtime_owner_pool(engine,home);
            axs_cachekeeper_runtime_require([NSFileManager.defaultManager removeItemAtPath:home error:nil],"owner pool fixture root removed");
            puts("PASS: image-runtime-source fixture owner-pool");return 0;
        }
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
