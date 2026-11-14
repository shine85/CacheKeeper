#import "AxsCacheKeeperNetworkCache.h"
#import <substrate.h>
#import <objc/runtime.h>
#include <stdatomic.h>

@interface AxsCacheKeeperNetworkCapacity : NSObject
@property(nonatomic) NSUInteger desired;
@property(nonatomic) uint64_t request;
@property(nonatomic) BOOL pending;
@end
@implementation AxsCacheKeeperNetworkCapacity
@end

static NSMapTable<NSURLCache *, AxsCacheKeeperNetworkCapacity *> *axs_cachekeeper_capacities;
static NSObject *axs_cachekeeper_cache_lock;
static BOOL axs_cachekeeper_prevent_network;
static atomic_bool axs_cachekeeper_network_hooks_requested;
static uint64_t axs_cachekeeper_capacity_request;

// 栈帧只保存地址，不持有可能被类簇初始化释放的 receiver；全局链表只在锁内访问。
typedef struct AxsCacheKeeperNetworkInitialization {
    uintptr_t receiver, result;
    NSUInteger forwarded, desired;
    uint64_t beganAtRequest, request;
    BOOL suppressed;
    struct AxsCacheKeeperNetworkInitialization *parent, *next, *root;
} AxsCacheKeeperNetworkInitialization;
static __thread AxsCacheKeeperNetworkInitialization *axs_cachekeeper_thread_initialization;
static AxsCacheKeeperNetworkInitialization *axs_cachekeeper_initializations;
static void (*axs_cachekeeper_original_set_capacity)(id, SEL, NSUInteger);
static id (*axs_cachekeeper_original_init_path)(id __attribute__((ns_consumed)), SEL, NSUInteger, NSUInteger, NSString *) __attribute__((ns_returns_retained));
static id (*axs_cachekeeper_original_init_url)(id __attribute__((ns_consumed)), SEL, NSUInteger, NSUInteger, NSURL *) __attribute__((ns_returns_retained));
static void (*axs_cachekeeper_original_set_shared)(id, SEL, NSURLCache *);

static AxsCacheKeeperNetworkInitialization *axs_cachekeeper_initializing_cache(NSURLCache *cache) {
    uintptr_t address=(uintptr_t)(__bridge void *)cache;
    for (AxsCacheKeeperNetworkInitialization *frame=axs_cachekeeper_initializations;frame;frame=frame->next)
        if (frame->receiver==address || frame->result==address) return frame->root;
    return NULL;
}
static AxsCacheKeeperNetworkCapacity *axs_cachekeeper_capacity_state(NSURLCache *cache) {
    AxsCacheKeeperNetworkCapacity *state=[axs_cachekeeper_capacities objectForKey:cache];
    if (!state) {
        state=[AxsCacheKeeperNetworkCapacity new];
        [axs_cachekeeper_capacities setObject:state forKey:cache];
    }
    return state;
}
static void axs_cachekeeper_track_cache(NSURLCache *cache) {
    if (!cache) return;
    @synchronized (axs_cachekeeper_cache_lock) {
        // 尚未返回的初始化器由其最外层完成恢复，不能在半初始化对象上读容量。
        if (axs_cachekeeper_initializing_cache(cache)) return;
        AxsCacheKeeperNetworkCapacity *state=axs_cachekeeper_capacity_state(cache);
        if (!axs_cachekeeper_prevent_network) return;
        if (!state.pending) state.desired=cache.diskCapacity;
        state.pending=YES;
        axs_cachekeeper_original_set_capacity(cache,@selector(setDiskCapacity:),0);
    }
}
static void axs_cachekeeper_set_capacity(NSURLCache *cache, SEL selector, NSUInteger capacity) {
    @synchronized (axs_cachekeeper_cache_lock) {
        AxsCacheKeeperNetworkInitialization *frame=axs_cachekeeper_initializing_cache(cache);
        // 显式 setter（包括零）都比初始化参数新；不能按数值猜测调用者意图。
        if (frame) {
            frame->desired=capacity;
            frame->request=++axs_cachekeeper_capacity_request;
            frame->suppressed |= axs_cachekeeper_prevent_network;
        } else {
            AxsCacheKeeperNetworkCapacity *state=axs_cachekeeper_capacity_state(cache);
            state.desired=capacity;
            state.request=++axs_cachekeeper_capacity_request;
            state.pending=axs_cachekeeper_prevent_network;
        }
        axs_cachekeeper_original_set_capacity(cache, selector, axs_cachekeeper_prevent_network ? 0 : capacity);
    }
}
static void axs_cachekeeper_begin_initialization(AxsCacheKeeperNetworkInitialization *frame, id object, NSUInteger disk) {
    @synchronized (axs_cachekeeper_cache_lock) {
        frame->receiver=(uintptr_t)(__bridge void *)object;
        frame->parent=axs_cachekeeper_thread_initialization;
        frame->root=frame;
        for (AxsCacheKeeperNetworkInitialization *parent=frame->parent;parent;parent=parent->parent)
            if (parent->receiver==frame->receiver || parent->result==frame->receiver) { frame->root=parent->root; break; }
        frame->desired=disk;
        frame->beganAtRequest=axs_cachekeeper_capacity_request;
        frame->forwarded=axs_cachekeeper_prevent_network ? 0 : disk;
        frame->root->suppressed |= axs_cachekeeper_prevent_network;
        frame->next=axs_cachekeeper_initializations;
        axs_cachekeeper_initializations=frame;
        axs_cachekeeper_thread_initialization=frame;
    }
}
static void axs_cachekeeper_end_initialization(AxsCacheKeeperNetworkInitialization *frame);
static void axs_cachekeeper_finish_initialization(AxsCacheKeeperNetworkInitialization *frame, NSURLCache *cache) {
    if (!cache) return;
    @synchronized (axs_cachekeeper_cache_lock) {
        frame->root->result=(uintptr_t)(__bridge void *)cache;
        if (frame->root!=frame) { axs_cachekeeper_end_initialization(frame); return; }
        AxsCacheKeeperNetworkCapacity *state=axs_cachekeeper_capacity_state(cache);
        // 类簇可返回另一对象；该对象在本次初始化后收到的新请求也必须胜过外层旧参数。
        if (state.request>frame->beganAtRequest && state.request>frame->request) {
            frame->desired=state.desired;
            frame->request=state.request;
        }
        BOOL restore=frame->suppressed || state.pending;
        state.desired=frame->desired;
        state.request=frame->request;
        state.pending=axs_cachekeeper_prevent_network;
        if (axs_cachekeeper_prevent_network || restore)
            axs_cachekeeper_original_set_capacity(cache,@selector(setDiskCapacity:),axs_cachekeeper_prevent_network ? 0 : state.desired);
        // 发布最终状态与移除活动帧必须原子完成，否则关闭/新请求会落在两者之间。
        axs_cachekeeper_end_initialization(frame);
    }
}
static void axs_cachekeeper_end_initialization(AxsCacheKeeperNetworkInitialization *frame) {
    @synchronized (axs_cachekeeper_cache_lock) {
        AxsCacheKeeperNetworkInitialization **entry=&axs_cachekeeper_initializations;
        while (*entry && *entry!=frame) entry=&(*entry)->next;
        if (*entry) {
            *entry=frame->next;
            axs_cachekeeper_thread_initialization=frame->parent;
        }
    }
}
static id axs_cachekeeper_init_path(id object __attribute__((ns_consumed)), SEL selector, NSUInteger memory, NSUInteger disk, NSString *path) __attribute__((ns_returns_retained));
static id axs_cachekeeper_init_path(id object __attribute__((ns_consumed)), SEL selector, NSUInteger memory, NSUInteger disk, NSString *path) {
    AxsCacheKeeperNetworkInitialization frame={0};
    axs_cachekeeper_begin_initialization(&frame,object,disk);
    @try {
        // 原初始化器在锁外执行；只压缩磁盘参数，内存、路径、Cookie 与请求策略不变。
        id result=axs_cachekeeper_original_init_path(object,selector,memory,frame.forwarded,path);
        axs_cachekeeper_finish_initialization(&frame,result);
        return result;
    } @finally { axs_cachekeeper_end_initialization(&frame); }
}
static id axs_cachekeeper_init_url(id object __attribute__((ns_consumed)), SEL selector, NSUInteger memory, NSUInteger disk, NSURL *url) __attribute__((ns_returns_retained));
static id axs_cachekeeper_init_url(id object __attribute__((ns_consumed)), SEL selector, NSUInteger memory, NSUInteger disk, NSURL *url) {
    AxsCacheKeeperNetworkInitialization frame={0};
    axs_cachekeeper_begin_initialization(&frame,object,disk);
    @try {
        id result=axs_cachekeeper_original_init_url(object,selector,memory,frame.forwarded,url);
        axs_cachekeeper_finish_initialization(&frame,result);
        return result;
    } @finally { axs_cachekeeper_end_initialization(&frame); }
}
static void axs_cachekeeper_set_shared(id object, SEL selector, NSURLCache *cache) {
    axs_cachekeeper_track_cache(cache);
    axs_cachekeeper_original_set_shared(object, selector, cache);
}
BOOL axs_cachekeeper_configure_network_cache(BOOL prevent) {
    // 未启用时连 Hook 和共享缓存都不初始化；关闭后的重复刷新也不重写容量。
    if (!prevent && !atomic_load(&axs_cachekeeper_network_hooks_requested)) return YES;
    atomic_store(&axs_cachekeeper_network_hooks_requested,true);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        axs_cachekeeper_capacities = [NSMapTable weakToStrongObjectsMapTable];
        axs_cachekeeper_cache_lock = [NSObject new];
        MSHookMessageEx(NSURLCache.class, @selector(setDiskCapacity:), (IMP)axs_cachekeeper_set_capacity, (IMP *)&axs_cachekeeper_original_set_capacity);
        MSHookMessageEx(NSURLCache.class, @selector(initWithMemoryCapacity:diskCapacity:diskPath:), (IMP)axs_cachekeeper_init_path, (IMP *)&axs_cachekeeper_original_init_path);
        SEL urlInitializer = @selector(initWithMemoryCapacity:diskCapacity:directoryURL:);
        if ([NSURLCache instancesRespondToSelector:urlInitializer])
            MSHookMessageEx(NSURLCache.class, urlInitializer, (IMP)axs_cachekeeper_init_url, (IMP *)&axs_cachekeeper_original_init_url);
        MSHookMessageEx(object_getClass(NSURLCache.class), @selector(setSharedURLCache:), (IMP)axs_cachekeeper_set_shared, (IMP *)&axs_cachekeeper_original_set_shared);
    });
    if (!axs_cachekeeper_original_set_capacity) return NO;
    BOOL applied=YES;
    @synchronized (axs_cachekeeper_cache_lock) {
        axs_cachekeeper_prevent_network = prevent;
        NSArray *instances=axs_cachekeeper_capacities.keyEnumerator.allObjects;
        for (NSURLCache *cache in instances) {
            if (axs_cachekeeper_initializing_cache(cache)) continue;
            AxsCacheKeeperNetworkCapacity *state=[axs_cachekeeper_capacities objectForKey:cache];
            if (!prevent && !state.pending) continue;
            if (prevent && !state.pending) state.desired=cache.diskCapacity;
            if (prevent) state.pending=YES;
            NSUInteger desired=prevent ? 0 : state.desired;
            axs_cachekeeper_original_set_capacity(cache, @selector(setDiskCapacity:), desired);
            BOOL matches=cache.diskCapacity == desired;
            applied &= matches;
            if (!prevent && matches) state.pending=NO;
        }
    }
    // 先发布禁止状态，新建 sharedURLCache 也从零磁盘容量开始；原初始化器不持全局锁。
    NSURLCache *shared=prevent ? NSURLCache.sharedURLCache : nil;
    if (shared) axs_cachekeeper_track_cache(shared);
    @synchronized (axs_cachekeeper_cache_lock) {
        return applied && axs_cachekeeper_prevent_network==prevent && (!prevent || shared.diskCapacity==0);
    }
}
