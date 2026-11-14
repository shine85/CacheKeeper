#import "AxsCacheKeeperNetworkCache.h"
#import <substrate.h>
#import <objc/runtime.h>
#include <stdatomic.h>
#include <dlfcn.h>
#include <string.h>
#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif

@interface AxsCacheKeeperNetworkCapacity : NSObject
@property(nonatomic) NSUInteger desired;
@property(nonatomic) uint64_t request;
@property(nonatomic) BOOL pending;
@property(nonatomic) BOOL restorationUnverified;
@end
@implementation AxsCacheKeeperNetworkCapacity
@end

static NSMapTable<NSURLCache *, AxsCacheKeeperNetworkCapacity *> *axs_cachekeeper_capacities;
static NSObject *axs_cachekeeper_cache_lock;
static BOOL axs_cachekeeper_prevent_network;
static atomic_bool axs_cachekeeper_network_hooks_requested;
static uint64_t axs_cachekeeper_capacity_request;
static const char *axs_cachekeeper_network_class_image;

// 栈帧只保存地址，不持有可能被类簇初始化释放的 receiver；全局链表只在锁内访问。
typedef struct AxsCacheKeeperNetworkInitialization {
    uintptr_t receiver, result;
    NSUInteger forwarded, desired;
    uint64_t beganAtRequest, request;
    BOOL suppressed;
    BOOL restorationUnverified;
    struct AxsCacheKeeperNetworkInitialization *parent, *next, *root;
} AxsCacheKeeperNetworkInitialization;
static __thread AxsCacheKeeperNetworkInitialization *axs_cachekeeper_thread_initialization;
static AxsCacheKeeperNetworkInitialization *axs_cachekeeper_initializations;
static void (*axs_cachekeeper_original_set_capacity)(id, SEL, NSUInteger);
static id (*axs_cachekeeper_original_init_path)(id __attribute__((ns_consumed)), SEL, NSUInteger, NSUInteger, NSString *) __attribute__((ns_returns_retained));
static id (*axs_cachekeeper_original_init_url)(id __attribute__((ns_consumed)), SEL, NSUInteger, NSUInteger, NSURL *) __attribute__((ns_returns_retained));
static void (*axs_cachekeeper_original_set_shared)(id, SEL, NSURLCache *);

static void axs_cachekeeper_unknown_initialization_source(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSLog(@"[CacheKeeper] NSURLCache 初始化调用来源不可确认；保留 setter 请求，初始磁盘容量恢复未验证");
    });
}
typedef NS_ENUM(NSUInteger, AxsCacheKeeperCapacitySource) {
    AxsCacheKeeperCapacitySourceInternal,
    AxsCacheKeeperCapacitySourceExplicit,
    AxsCacheKeeperCapacitySourceUnverified
};
static AxsCacheKeeperCapacitySource axs_cachekeeper_capacity_source(AxsCacheKeeperNetworkInitialization *frame, const Dl_info *source) {
    if (!axs_cachekeeper_network_class_image || !source->dli_fname) return AxsCacheKeeperCapacitySourceUnverified;
    // 已确认其他 image 的 APP / SDK / 框架转发属于显式请求，即使该 image 没有符号。
    if (strcmp(source->dli_fname,axs_cachekeeper_network_class_image)) return AxsCacheKeeperCapacitySourceExplicit;
    BOOL sameThread=NO;
    for (AxsCacheKeeperNetworkInitialization *active=axs_cachekeeper_thread_initialization;active;active=active->parent)
        if (active->root==frame) { sameThread=YES; break; }
    if (sameThread && source->dli_saddr && source->dli_sname &&
        (!strcmp(source->dli_sname,"-[NSURLCache initWithMemoryCapacity:diskCapacity:diskPath:]") ||
         !strcmp(source->dli_sname,"-[NSURLCache initWithMemoryCapacity:diskCapacity:directoryURL:]"))) return AxsCacheKeeperCapacitySourceInternal;
    return AxsCacheKeeperCapacitySourceUnverified;
}
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
    Dl_info source={0};
    // 取直接调用方；初始化结束后的明确请求也必须能解除该对象的来源未确认状态。
    void *caller=__builtin_extract_return_addr(__builtin_return_address(0));
#if __has_feature(ptrauth_calls)
    caller=ptrauth_strip(caller,ptrauth_key_return_address);
#endif
    dladdr(caller,&source);
    BOOL reportUnverified=NO;
    @synchronized (axs_cachekeeper_cache_lock) {
        AxsCacheKeeperNetworkInitialization *frame=axs_cachekeeper_initializing_cache(cache);
        AxsCacheKeeperCapacitySource origin=axs_cachekeeper_capacity_source(frame,&source);
        // 只有已确认的系统原初始化器直接调用属于参数实施；其他 setter（包括零）是新请求。
        if (frame) {
            if (origin!=AxsCacheKeeperCapacitySourceInternal) {
                frame->desired=capacity;
                frame->request=++axs_cachekeeper_capacity_request;
                frame->restorationUnverified=origin==AxsCacheKeeperCapacitySourceUnverified &&
                    (frame->suppressed || axs_cachekeeper_prevent_network);
                reportUnverified=frame->restorationUnverified;
            }
            frame->suppressed |= axs_cachekeeper_prevent_network;
        } else {
            AxsCacheKeeperNetworkCapacity *state=axs_cachekeeper_capacity_state(cache);
            state.desired=capacity;
            state.request=++axs_cachekeeper_capacity_request;
            state.restorationUnverified=origin==AxsCacheKeeperCapacitySourceUnverified &&
                (state.pending || axs_cachekeeper_prevent_network);
            state.pending=axs_cachekeeper_prevent_network || state.restorationUnverified;
            reportUnverified=state.restorationUnverified;
        }
        axs_cachekeeper_original_set_capacity(cache, selector, axs_cachekeeper_prevent_network ? 0 : capacity);
    }
    if (reportUnverified) axs_cachekeeper_unknown_initialization_source();
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
            frame->restorationUnverified=state.restorationUnverified;
        }
        BOOL restore=frame->suppressed || state.pending;
        state.desired=frame->desired;
        state.request=frame->request;
        state.restorationUnverified=frame->restorationUnverified;
        state.pending=axs_cachekeeper_prevent_network || state.restorationUnverified;
        if (axs_cachekeeper_prevent_network || restore) {
            axs_cachekeeper_original_set_capacity(cache,@selector(setDiskCapacity:),axs_cachekeeper_prevent_network ? 0 : state.desired);
            if (!axs_cachekeeper_prevent_network && cache.diskCapacity!=state.desired) state.pending=YES;
        }
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
        axs_cachekeeper_network_class_image=class_getImageName(NSURLCache.class);
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
            BOOL verified=matches && !state.restorationUnverified;
            applied &= prevent ? matches : verified;
            if (!prevent && verified) state.pending=NO;
        }
    }
    // 先发布禁止状态，新建 sharedURLCache 也从零磁盘容量开始；原初始化器不持全局锁。
    NSURLCache *shared=prevent ? NSURLCache.sharedURLCache : nil;
    if (shared) axs_cachekeeper_track_cache(shared);
    @synchronized (axs_cachekeeper_cache_lock) {
        // 在返回结果的同一临界区检查，包含尚未发布的帧及两次加锁之间出现的新未知请求。
        if (!prevent) {
            for (AxsCacheKeeperNetworkCapacity *state in axs_cachekeeper_capacities.objectEnumerator.allObjects)
                if (state.restorationUnverified) return NO;
            for (AxsCacheKeeperNetworkInitialization *frame=axs_cachekeeper_initializations;frame;frame=frame->next)
                if (frame->root->restorationUnverified) return NO;
        }
        return applied && axs_cachekeeper_prevent_network==prevent && (!prevent || shared.diskCapacity==0);
    }
}
