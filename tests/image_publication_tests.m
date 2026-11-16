// Objective-C runtime publication fixture, NOT an SDWebImage SDK integration test.
// The small classes below provide the production admission ABI without file I/O.
// Swizzles run inside the real method_setImplementation publication boundary;
// every assertion uses the production adapter's receipt or its actual call chain.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <string.h>

static NSUInteger axs_cachekeeper_publication_writes,axs_cachekeeper_publication_external_calls;
@interface SDImageCache : NSObject
- (instancetype)initWithNamespace:(id)space diskCacheDirectory:(id)directory config:(id)config;
@end
@implementation SDImageCache
- (instancetype)initWithNamespace:(id)space diskCacheDirectory:(id)directory config:(id)config {
    (void)space;(void)directory;(void)config;return [super init];
}
- (id)diskCache {return nil;}
- (id)diskCachePath {return nil;}
- (id)config {return nil;}
- (id)ioQueue {return nil;}
- (id)memoryCache {return nil;}
@end
@interface SDDiskCache : NSObject
- (void)setData:(id)data forKey:(id)key;
- (id)fileManager;
@end
@implementation SDDiskCache
- (instancetype)initWithCachePath:(id)path config:(id)config {(void)path;(void)config;return [super init];}
- (void)commonInit {}
- (id)diskCachePath {return nil;}
- (id)config {return nil;}
- (id)fileManager {return NSFileManager.defaultManager;}
- (void)removeAllData {}
- (id)cachePathForKey:(id)key {(void)key;return nil;}
- (id)cachePathForKey:(id)key inPath:(id)path {(void)key;(void)path;return nil;}
- (void)setData:(id)data forKey:(id)key {(void)data;(void)key;axs_cachekeeper_publication_writes++;}
- (void)setExtendedData:(id)data forKey:(id)key {(void)data;(void)key;}
@end
@interface SDMemoryCache : NSObject
@end
@implementation SDMemoryCache
- (instancetype)initWithConfig:(id)config {(void)config;return [super init];}
- (void)commonInit {}
- (id)config {return nil;}
@end
@interface SDImageCacheConfig : NSObject <NSCopying>
@end
@implementation SDImageCacheConfig
- (id)fileManager {return nil;}
- (id)ioQueueAttributes {return nil;}
- (Class)diskCacheClass {return SDDiskCache.class;}
- (Class)memoryCacheClass {return SDMemoryCache.class;}
- (id)copyWithZone:(NSZone *)zone {(void)zone;return [SDImageCacheConfig new];}
+ (id)defaultCacheConfig {return [SDImageCacheConfig new];}
@end

static const char *axs_cachekeeper_publication_mode;
static BOOL axs_cachekeeper_publication_injected;
static IMP axs_cachekeeper_publication_external_original;
static IMP axs_cachekeeper_publication_wrapper;
static IMP axs_cachekeeper_publication_getter_original;
static void axs_cachekeeper_publication_foreign_write(id disk,SEL selector,id data,id key) {
    axs_cachekeeper_publication_external_calls++;
    ((void (*)(id,SEL,id,id))axs_cachekeeper_publication_external_original)(disk,selector,data,key);
}
static id axs_cachekeeper_publication_foreign_getter(id disk,SEL selector) {
    axs_cachekeeper_publication_external_calls++;
    return ((id (*)(id,SEL))axs_cachekeeper_publication_getter_original)(disk,selector);
}
// Defined before the macro: these are the real runtime calls, never recursive mocks.
static IMP axs_cachekeeper_publication_set_implementation(Method method,IMP implementation) {
    SEL selector=method_getName(method);
    BOOL write=selector==sel_registerName("setData:forKey:");
    if (!axs_cachekeeper_publication_injected && write && !strcmp(axs_cachekeeper_publication_mode,"original")) {
        axs_cachekeeper_publication_injected=YES;
        axs_cachekeeper_publication_external_original=method_setImplementation(method,(IMP)axs_cachekeeper_publication_foreign_write);
    }
    IMP previous=method_setImplementation(method,implementation);
    if (write) axs_cachekeeper_publication_wrapper=implementation;
    if (!axs_cachekeeper_publication_injected && !strcmp(axs_cachekeeper_publication_mode,"getter")) {
        axs_cachekeeper_publication_injected=YES;
        Method getter=class_getInstanceMethod(SDDiskCache.class,sel_registerName("fileManager"));
        axs_cachekeeper_publication_getter_original=method_setImplementation(getter,(IMP)axs_cachekeeper_publication_foreign_getter);
    }
    if (!axs_cachekeeper_publication_injected && write && !strcmp(axs_cachekeeper_publication_mode,"installed")) {
        axs_cachekeeper_publication_injected=YES;
        axs_cachekeeper_publication_external_original=method_setImplementation(method,(IMP)axs_cachekeeper_publication_foreign_write);
    }
    return previous;
}
#define method_setImplementation axs_cachekeeper_publication_set_implementation
#import "AxsCacheKeeperImageCache.m"
#undef method_setImplementation

static void axs_cachekeeper_publication_require(BOOL condition,const char *message) {
    if (!condition) {fprintf(stderr,"FAIL: image-publication: %s\n",message);exit(1);}
}
static void axs_cachekeeper_publication_refresh(AxsCacheKeeperImageCache *engine) {
    dispatch_semaphore_t done=dispatch_semaphore_create(0);
    [engine refreshWithCompletion:^{dispatch_semaphore_signal(done);}];
    axs_cachekeeper_publication_require(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0,"refresh completes");
}
static AxsCacheKeeperImageCache *axs_cachekeeper_publication_engine(void) {
    AxsCacheKeeperImageCache *engine=[[AxsCacheKeeperImageCache alloc] initWithContextProvider:^NSDictionary *{
        return @{@"valid":@YES,@"appState":@{@"enabled":@YES,@"mode":@"prevent"}};
    } observer:nil];
    // Only the source allowlist is bypassed. All production class/method ABI gates run.
    [engine usePinnedSDKForIntegrationTests];[engine startObserving];
    return engine;
}
int main(int argc,const char *argv[]) {
    @autoreleasepool {
        axs_cachekeeper_publication_require(argc==2,"one isolated publication scenario is required");
        axs_cachekeeper_publication_mode=argv[1];
        BOOL clean=!strcmp(argv[1],"clean"),getter=!strcmp(argv[1],"getter");
        BOOL original=!strcmp(argv[1],"original"),installed=!strcmp(argv[1],"installed");
        axs_cachekeeper_publication_require(clean || getter || original || installed,"known scenario");
        AxsCacheKeeperImageCache *engine=axs_cachekeeper_publication_engine();
        axs_cachekeeper_publication_refresh(engine);
        axs_cachekeeper_publication_require(clean || axs_cachekeeper_publication_injected,"external implementation replaced at publication boundary");
        NSString *expected=clean ? @"notObserved" : @"unsupported";
        // This exact assertion is the only accepted RED on the released source.
        axs_cachekeeper_publication_require([[engine receipt][@"state"] isEqual:expected],"unverified publication is refused");
        axs_cachekeeper_publication_refresh(engine);
        axs_cachekeeper_publication_require([[engine receipt][@"state"] isEqual:expected],"refresh does not relearn an unverified implementation");
        AxsCacheKeeperImageCache *replacement=axs_cachekeeper_publication_engine();
        axs_cachekeeper_publication_refresh(replacement);
        axs_cachekeeper_publication_require([[replacement receipt][@"state"] isEqual:expected],"new observer preserves publication refusal");

        SDDiskCache *disk=[SDDiskCache new];
        [disk setData:[NSData data] forKey:@"publication-fixture"];
        axs_cachekeeper_publication_require(axs_cachekeeper_publication_writes==1,"SDK write call chain is preserved");
        if (original || installed)
            axs_cachekeeper_publication_require(axs_cachekeeper_publication_external_calls==1,"external write call chain is preserved");
        Method write=class_getInstanceMethod(SDDiskCache.class,sel_registerName("setData:forKey:"));
        if (installed)
            axs_cachekeeper_publication_require(method_getImplementation(write)==(IMP)axs_cachekeeper_publication_foreign_write,"external installed swizzle is not overwritten");
        if (original) {
            axs_cachekeeper_publication_require(method_getImplementation(write)==axs_cachekeeper_publication_wrapper,"installed wrapper is retained without unsafe rollback");
            // Reinstalling the known wrapper cannot repair its captured foreign call chain.
            method_setImplementation(write,axs_cachekeeper_publication_wrapper);
            axs_cachekeeper_publication_refresh(replacement);
            axs_cachekeeper_publication_require([[replacement receipt][@"state"] isEqual:@"unsupported"],"captured original mismatch stays refused");
        }
        if (getter) {
            Method method=class_getInstanceMethod(SDDiskCache.class,sel_registerName("fileManager"));
            axs_cachekeeper_publication_require(method_getImplementation(method)==(IMP)axs_cachekeeper_publication_foreign_getter,"external getter swizzle is not overwritten");
            axs_cachekeeper_publication_require([disk fileManager]==NSFileManager.defaultManager && axs_cachekeeper_publication_external_calls==1,"external getter call chain is preserved");
            method_setImplementation(method,axs_cachekeeper_publication_getter_original);
        } else if (installed) {
            method_setImplementation(write,axs_cachekeeper_publication_wrapper);
        }
        if (getter || installed) {
            axs_cachekeeper_publication_refresh(replacement);
            axs_cachekeeper_publication_require([[replacement receipt][@"state"] isEqual:@"notObserved"],"restoring verified methods permits rediscovery");
        }
        printf("PASS: image-publication runtime fixture %s\n",argv[1]);
    }
    return 0;
}
