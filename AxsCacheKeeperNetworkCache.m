#import "AxsCacheKeeperNetworkCache.h"
#import <substrate.h>
#import <objc/runtime.h>

static NSMapTable<NSURLCache *, NSNumber *> *axs_cachekeeper_capacities;
static NSHashTable<NSURLCache *> *axs_cachekeeper_instances;
static NSObject *axs_cachekeeper_cache_lock;
static BOOL axs_cachekeeper_prevent_network;
static void (*axs_cachekeeper_original_set_capacity)(id, SEL, NSUInteger);
static id (*axs_cachekeeper_original_init_path)(id __attribute__((ns_consumed)), SEL, NSUInteger, NSUInteger, NSString *) __attribute__((ns_returns_retained));
static id (*axs_cachekeeper_original_init_url)(id __attribute__((ns_consumed)), SEL, NSUInteger, NSUInteger, NSURL *) __attribute__((ns_returns_retained));
static void (*axs_cachekeeper_original_set_shared)(id, SEL, NSURLCache *);

static void axs_cachekeeper_track_cache(NSURLCache *cache) {
    if (!cache) return;
    @synchronized (axs_cachekeeper_cache_lock) {
        [axs_cachekeeper_instances addObject:cache];
        if (!axs_cachekeeper_prevent_network) return;
        if (![axs_cachekeeper_capacities objectForKey:cache]) [axs_cachekeeper_capacities setObject:@(cache.diskCapacity) forKey:cache];
        if (axs_cachekeeper_prevent_network) axs_cachekeeper_original_set_capacity(cache, @selector(setDiskCapacity:), 0);
    }
}
static void axs_cachekeeper_set_capacity(NSURLCache *cache, SEL selector, NSUInteger capacity) {
    @synchronized (axs_cachekeeper_cache_lock) {
        [axs_cachekeeper_instances addObject:cache];
        if (axs_cachekeeper_prevent_network) [axs_cachekeeper_capacities setObject:@(capacity) forKey:cache];
        axs_cachekeeper_original_set_capacity(cache, selector, axs_cachekeeper_prevent_network ? 0 : capacity);
    }
}
static id axs_cachekeeper_init_path(id object __attribute__((ns_consumed)), SEL selector, NSUInteger memory, NSUInteger disk, NSString *path) __attribute__((ns_returns_retained));
static id axs_cachekeeper_init_path(id object __attribute__((ns_consumed)), SEL selector, NSUInteger memory, NSUInteger disk, NSString *path) {
    id result = axs_cachekeeper_original_init_path(object, selector, memory, disk, path);
    // 只改变磁盘缓存；不改变 Cookie、请求策略或内存容量。
    axs_cachekeeper_track_cache(result);
    return result;
}
static id axs_cachekeeper_init_url(id object __attribute__((ns_consumed)), SEL selector, NSUInteger memory, NSUInteger disk, NSURL *url) __attribute__((ns_returns_retained));
static id axs_cachekeeper_init_url(id object __attribute__((ns_consumed)), SEL selector, NSUInteger memory, NSUInteger disk, NSURL *url) {
    id result = axs_cachekeeper_original_init_url(object, selector, memory, disk, url);
    axs_cachekeeper_track_cache(result);
    return result;
}
static void axs_cachekeeper_set_shared(id object, SEL selector, NSURLCache *cache) {
    axs_cachekeeper_track_cache(cache);
    axs_cachekeeper_original_set_shared(object, selector, cache);
}
BOOL axs_cachekeeper_configure_network_cache(BOOL prevent) {
    // 未启用时连 Hook 和共享缓存都不初始化；关闭后的重复刷新也不重写容量。
    if (!prevent && !axs_cachekeeper_prevent_network && !axs_cachekeeper_capacities.count) return YES;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        axs_cachekeeper_capacities = [NSMapTable weakToStrongObjectsMapTable];
        axs_cachekeeper_instances = [NSHashTable weakObjectsHashTable];
        axs_cachekeeper_cache_lock = [NSObject new];
        MSHookMessageEx(NSURLCache.class, @selector(setDiskCapacity:), (IMP)axs_cachekeeper_set_capacity, (IMP *)&axs_cachekeeper_original_set_capacity);
        MSHookMessageEx(NSURLCache.class, @selector(initWithMemoryCapacity:diskCapacity:diskPath:), (IMP)axs_cachekeeper_init_path, (IMP *)&axs_cachekeeper_original_init_path);
        SEL urlInitializer = @selector(initWithMemoryCapacity:diskCapacity:directoryURL:);
        if ([NSURLCache instancesRespondToSelector:urlInitializer])
            MSHookMessageEx(NSURLCache.class, urlInitializer, (IMP)axs_cachekeeper_init_url, (IMP *)&axs_cachekeeper_original_init_url);
        MSHookMessageEx(object_getClass(NSURLCache.class), @selector(setSharedURLCache:), (IMP)axs_cachekeeper_set_shared, (IMP *)&axs_cachekeeper_original_set_shared);
    });
    if (!axs_cachekeeper_original_set_capacity) return NO;
    // sharedURLCache 可能初始化新实例，先取得对象以避免 registry 枚举期间修改。
    NSURLCache *shared = prevent ? NSURLCache.sharedURLCache : nil;
    @synchronized (axs_cachekeeper_cache_lock) {
        axs_cachekeeper_prevent_network = prevent;
        if (shared) [axs_cachekeeper_instances addObject:shared];
        BOOL applied = YES;
        NSArray *instances = prevent ? axs_cachekeeper_instances.allObjects : axs_cachekeeper_capacities.keyEnumerator.allObjects;
        for (NSURLCache *cache in instances) {
            if (prevent && ![axs_cachekeeper_capacities objectForKey:cache]) [axs_cachekeeper_capacities setObject:@(cache.diskCapacity) forKey:cache];
            NSUInteger desired = prevent ? 0 : [[axs_cachekeeper_capacities objectForKey:cache] unsignedIntegerValue];
            axs_cachekeeper_original_set_capacity(cache, @selector(setDiskCapacity:), desired);
            BOOL matches=cache.diskCapacity == desired;
            applied &= matches;
            if (!prevent && matches) [axs_cachekeeper_capacities removeObjectForKey:cache];
        }
        return applied;
    }
}
