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
@property(nonatomic) BOOL hasDesired,dirty,reconcileScheduled;
@property(nonatomic) NSUInteger active;
@property(nonatomic) uint64_t revision;
@property(nonatomic) uint64_t nativeCompletions;
@property(nonatomic) BOOL failed;
@property(nonatomic) uint64_t failedRevision,failedPolicy;
@end
@implementation AxsCacheKeeperNetworkCapacity
@end

static NSMapTable<NSURLCache *, AxsCacheKeeperNetworkCapacity *> *axs_cachekeeper_capacities;
static NSObject *axs_cachekeeper_cache_lock;
static BOOL axs_cachekeeper_prevent_network;
static atomic_bool axs_cachekeeper_network_hooks_requested;
static uint64_t axs_cachekeeper_capacity_request,axs_cachekeeper_policy_revision;
static dispatch_queue_t axs_cachekeeper_reconcile_queue;
static const char *axs_cachekeeper_network_class_image;

// 栈帧只保存地址，不持有可能被类簇初始化释放的 receiver；全局链表只在锁内访问。
typedef struct AxsCacheKeeperNetworkInitialization {
    uintptr_t receiver, result;
    NSUInteger forwarded, desired;
    uint64_t beganAtRequest, request;
    BOOL suppressed;
    BOOL restorationUnverified;
    // The initializer's precise-lifetime local owns this stable state, never
    // the receiver. Same-receiver nested frames borrow the outer state.
    __unsafe_unretained AxsCacheKeeperNetworkCapacity *provisional;
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
typedef struct {NSUInteger capacity;uint64_t revision,policy;} AxsCacheKeeperNetworkWrite;
static BOOL axs_cachekeeper_apply_capacity(NSURLCache *cache,AxsCacheKeeperNetworkCapacity *state,BOOL allowConcurrent,BOOL automatic,const AxsCacheKeeperNetworkWrite *request);
static BOOL axs_cachekeeper_failed_current(AxsCacheKeeperNetworkCapacity *state) {
    return state.failed && state.failedRevision==state.revision && state.failedPolicy==axs_cachekeeper_policy_revision;
}
// Only a completed, overtaken call schedules repair. Normal setters stay synchronous;
// plugin coordination adds no wait for another native call or contention loop.
static void axs_cachekeeper_reconcile_locked(NSURLCache *cache,AxsCacheKeeperNetworkCapacity *state) {
    if ([axs_cachekeeper_capacities objectForKey:cache]!=state || axs_cachekeeper_initializing_cache(cache)) return;
    if (state.active || state.reconcileScheduled || !state.hasDesired || axs_cachekeeper_failed_current(state)) return;
    state.reconcileScheduled=YES;
    dispatch_async(axs_cachekeeper_reconcile_queue,^{
        @synchronized(axs_cachekeeper_cache_lock) {
            state.reconcileScheduled=NO;
            if (state.active || !state.dirty || axs_cachekeeper_failed_current(state) ||
                [axs_cachekeeper_capacities objectForKey:cache]!=state || axs_cachekeeper_initializing_cache(cache)) return;
        }
        @try {(void)axs_cachekeeper_apply_capacity(cache,state,NO,YES,NULL);}
        @catch (NSException *error) {
            // The apply boundary retained dirty/pending and blocked this version
            // from automatic retries. A later explicit configuration may retry.
            NSLog(@"[CacheKeeper] 网络容量并发修复失败（%@）；保留待恢复状态，等待明确刷新",error.name);
        }
    });
}
static BOOL axs_cachekeeper_apply_capacity(NSURLCache *cache,AxsCacheKeeperNetworkCapacity *state,BOOL allowConcurrent,BOOL automatic,const AxsCacheKeeperNetworkWrite *request) {
    NSUInteger desired;uint64_t revision,policy;
    @synchronized(axs_cachekeeper_cache_lock) {
        if (!state.hasDesired && !request) return NO;
        if (automatic && ([axs_cachekeeper_capacities objectForKey:cache]!=state || axs_cachekeeper_initializing_cache(cache))) return NO;
        if (automatic && axs_cachekeeper_failed_current(state)) return NO;
        if (!allowConcurrent && state.active) {state.dirty=YES;state.pending=YES;return NO;}
        desired=request ? request->capacity : (axs_cachekeeper_prevent_network ? 0 : state.desired);
        revision=request ? request->revision : state.revision;policy=request ? request->policy : axs_cachekeeper_policy_revision;
        // Setter requests reserve their flight in the same transaction that
        // publishes the frozen original argument. No later policy can overlook
        // a registered write merely because its thread has not called us yet.
        if (!request) state.active++;
        state.dirty=YES;
    }
    BOOL finished=NO,setterCompleted=NO,readable=NO,matches=NO,applied=NO;
    uint64_t checkedCompletions=0;
    @try {
        axs_cachekeeper_original_set_capacity(cache,@selector(setDiskCapacity:),desired);
        setterCompleted=YES;
        @synchronized(axs_cachekeeper_cache_lock) {
            state.nativeCompletions++;
            readable=axs_cachekeeper_initializing_cache(cache)==NULL;
            checkedCompletions=state.nativeCompletions;
        }
        // Never ask a partially initialized cache for its capacity.
        if (readable) matches=cache.diskCapacity==desired;
        finished=YES;
    } @finally {
        @synchronized(axs_cachekeeper_cache_lock) {
            state.active--;
            if (!setterCompleted) state.nativeCompletions++;
            BOOL readUnchanged=checkedCompletions==state.nativeCompletions;
            BOOL current=revision==state.revision && policy==axs_cachekeeper_policy_revision;
            if (finished && current && readable && readUnchanged && matches && !state.active) {
                state.dirty=NO;state.failed=NO;
                if (!axs_cachekeeper_prevent_network && !state.restorationUnverified) state.pending=NO;
                applied=axs_cachekeeper_prevent_network || !state.restorationUnverified;
            } else {
                state.dirty=YES;
                if (!finished) {state.failed=YES;state.failedRevision=revision;state.failedPolicy=policy;}
                if (!axs_cachekeeper_prevent_network && (!finished || !current || readable || state.active)) state.pending=YES;
                // A native exception is propagated, never retried invisibly. An
                // explicit later configuration can retry the recorded intent.
                if (finished && (!current || !readUnchanged)) axs_cachekeeper_reconcile_locked(cache,state);
            }
        }
    }
    return applied;
}
static BOOL axs_cachekeeper_track_cache(NSURLCache *cache) {
    if (!cache) return YES;
    AxsCacheKeeperNetworkCapacity *state;uint64_t revision,policy;BOOL read;
    @synchronized(axs_cachekeeper_cache_lock) {
        if (axs_cachekeeper_initializing_cache(cache)) return YES;
        state=axs_cachekeeper_capacity_state(cache);
        if (!axs_cachekeeper_prevent_network && state.hasDesired) return YES;
        if (state.active) {state.dirty=YES;state.pending=YES;return NO;}
        read=!state.hasDesired || !state.pending;revision=state.revision;policy=axs_cachekeeper_policy_revision;
        if (read) {state.active++;state.dirty=YES;}
    }
    if (read) {
        NSUInteger observed=0;BOOL finished=NO;
        @try {observed=cache.diskCapacity;finished=YES;}
        @finally {
            @synchronized(axs_cachekeeper_cache_lock) {
                state.active--;
                BOOL current=revision==state.revision && policy==axs_cachekeeper_policy_revision;
                if (!finished) {state.failed=YES;state.failedRevision=revision;state.failedPolicy=policy;}
                // A setter or policy transition during the getter owns the newer
                // intent. Never learn the temporary zero as requested capacity.
                if (finished && current) {
                    state.desired=observed;state.hasDesired=YES;state.revision++;
                    if (!axs_cachekeeper_prevent_network && !state.active) {state.dirty=NO;state.pending=NO;state.failed=NO;}
                }
                if (finished && !current) axs_cachekeeper_reconcile_locked(cache,state);
            }
        }
    }
    @synchronized(axs_cachekeeper_cache_lock) {
        if (!state.hasDesired) return NO;
        if (!axs_cachekeeper_prevent_network) return YES;
        state.pending=YES;
    }
    return axs_cachekeeper_apply_capacity(cache,state,NO,NO,NULL);
}
static void axs_cachekeeper_set_capacity(NSURLCache *cache, SEL selector, NSUInteger capacity) {
    Dl_info source={0};
    // 取直接调用方；初始化结束后的明确请求也必须能解除该对象的来源未确认状态。
    void *caller=__builtin_extract_return_addr(__builtin_return_address(0));
#if __has_feature(ptrauth_calls)
    caller=ptrauth_strip(caller,ptrauth_key_return_address);
#endif
    dladdr(caller,&source);
    BOOL reportUnverified=NO;AxsCacheKeeperNetworkCapacity *state;AxsCacheKeeperNetworkWrite write;
    @synchronized (axs_cachekeeper_cache_lock) {
        AxsCacheKeeperNetworkInitialization *frame=axs_cachekeeper_initializing_cache(cache);
        AxsCacheKeeperCapacitySource origin=axs_cachekeeper_capacity_source(frame,&source);
        AxsCacheKeeperNetworkCapacity *published=[axs_cachekeeper_capacities objectForKey:cache];
        state=frame ? (published ?: frame->provisional) : axs_cachekeeper_capacity_state(cache);
        if (frame) {
            if (origin!=AxsCacheKeeperCapacitySourceInternal) {
                frame->desired=capacity;
                frame->request=++axs_cachekeeper_capacity_request;
                frame->restorationUnverified=origin==AxsCacheKeeperCapacitySourceUnverified &&
                    (frame->suppressed || axs_cachekeeper_prevent_network);
            }
            frame->suppressed |= axs_cachekeeper_prevent_network;
            if (!published || origin==AxsCacheKeeperCapacitySourceExplicit) {
                state.desired=frame->desired;state.request=frame->request;
                state.restorationUnverified=frame->restorationUnverified;
                state.hasDesired=YES;
            }
            // Only an actual external request survives an initializer that may
            // throw or return nil. Internal/unknown observations stay provisional
            // until success and cannot poison an already published object's intent.
            if (origin==AxsCacheKeeperCapacitySourceExplicit && !published)
                [axs_cachekeeper_capacities setObject:state forKey:cache];
        } else {
            state.desired=capacity;
            state.request=++axs_cachekeeper_capacity_request;
            state.restorationUnverified=origin==AxsCacheKeeperCapacitySourceUnverified &&
                (state.pending || axs_cachekeeper_prevent_network);
            state.hasDesired=YES;
        }
        state.revision++;
        state.pending=(frame && published && origin!=AxsCacheKeeperCapacitySourceExplicit) ||
            axs_cachekeeper_prevent_network || state.restorationUnverified;
        reportUnverified=state.restorationUnverified;
        write=(AxsCacheKeeperNetworkWrite){axs_cachekeeper_prevent_network ? 0 : capacity,state.revision,axs_cachekeeper_policy_revision};
        state.active++;state.dirty=YES;
    }
    (void)selector;
    (void)axs_cachekeeper_apply_capacity(cache,state,YES,NO,&write);
    if (reportUnverified) axs_cachekeeper_unknown_initialization_source();
}
static void axs_cachekeeper_begin_initialization(AxsCacheKeeperNetworkInitialization *frame, id object, NSUInteger disk,AxsCacheKeeperNetworkCapacity *provisional) {
    @synchronized (axs_cachekeeper_cache_lock) {
        frame->receiver=(uintptr_t)(__bridge void *)object;
        frame->parent=axs_cachekeeper_thread_initialization;
        frame->root=frame;
        frame->provisional=provisional;
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
    AxsCacheKeeperNetworkCapacity *state;BOOL apply;
    @synchronized (axs_cachekeeper_cache_lock) {
        frame->root->result=(uintptr_t)(__bridge void *)cache;
        if (frame->root!=frame) { axs_cachekeeper_end_initialization(frame); return; }
        state=[axs_cachekeeper_capacities objectForKey:cache];
        if (!state) {
            state=(uintptr_t)(__bridge void *)cache==frame->receiver ? frame->provisional : [AxsCacheKeeperNetworkCapacity new];
            [axs_cachekeeper_capacities setObject:state forKey:cache];
        }
        if (state.request>frame->beganAtRequest && state.request>frame->request) {
            frame->desired=state.desired;frame->request=state.request;
            frame->restorationUnverified=state.restorationUnverified;
        }
        BOOL restore=frame->suppressed || state.pending;
        state.desired=frame->desired;state.request=frame->request;
        state.restorationUnverified=frame->restorationUnverified;
        state.hasDesired=YES;state.revision++;
        state.pending=axs_cachekeeper_prevent_network || state.restorationUnverified || restore;
        apply=axs_cachekeeper_prevent_network || restore;
        if (!apply) state.dirty=state.active!=0;
        // Publish the final intent and retire the stack frame atomically. Later
        // setters update this stable state while Foundation runs outside the lock.
        axs_cachekeeper_end_initialization(frame);
    }
    if (apply) (void)axs_cachekeeper_apply_capacity(cache,state,NO,NO,NULL);
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
    __attribute__((objc_precise_lifetime)) AxsCacheKeeperNetworkCapacity *provisional=[AxsCacheKeeperNetworkCapacity new];
    axs_cachekeeper_begin_initialization(&frame,object,disk,provisional);
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
    __attribute__((objc_precise_lifetime)) AxsCacheKeeperNetworkCapacity *provisional=[AxsCacheKeeperNetworkCapacity new];
    axs_cachekeeper_begin_initialization(&frame,object,disk,provisional);
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
        axs_cachekeeper_capacities = [[NSMapTable alloc] initWithKeyOptions:NSPointerFunctionsWeakMemory|NSPointerFunctionsObjectPointerPersonality valueOptions:NSPointerFunctionsStrongMemory capacity:0];
        axs_cachekeeper_reconcile_queue=dispatch_queue_create("dev.local.cachekeeper.network.reconcile",DISPATCH_QUEUE_SERIAL);
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
    BOOL applied=YES;NSArray *instances;uint64_t policy;
    @synchronized (axs_cachekeeper_cache_lock) {
        if (axs_cachekeeper_prevent_network!=prevent) {
            axs_cachekeeper_prevent_network=prevent;axs_cachekeeper_policy_revision++;
        }
        policy=axs_cachekeeper_policy_revision;
        instances=axs_cachekeeper_capacities.keyEnumerator.allObjects;
    }
    for (NSURLCache *cache in instances) {
        AxsCacheKeeperNetworkCapacity *state;BOOL capture;
        @synchronized(axs_cachekeeper_cache_lock) {
            if (axs_cachekeeper_initializing_cache(cache)) continue;
            state=[axs_cachekeeper_capacities objectForKey:cache];
            // A policy refresh must not enter Foundation again while a previous
            // write may own its internal object lock. Its completion will repair
            // the changed policy; this call reports that work as unfinished.
            if (state.active) {state.dirty=YES;state.pending=YES;applied=NO;continue;}
            if (!prevent && !state.pending && !state.dirty && !state.active) continue;
            capture=!state.hasDesired || (prevent && !state.pending);
            if (prevent && !capture) state.pending=YES;
        }
        applied &= capture ? axs_cachekeeper_track_cache(cache) : axs_cachekeeper_apply_capacity(cache,state,NO,NO,NULL);
    }
    // Constructing sharedURLCache and all capacity access stay outside our lock.
    NSURLCache *shared=prevent ? NSURLCache.sharedURLCache : nil;
    if (shared && [instances indexOfObjectIdenticalTo:shared]==NSNotFound)
        applied &= axs_cachekeeper_track_cache(shared);
    @synchronized (axs_cachekeeper_cache_lock) {
        if (axs_cachekeeper_policy_revision!=policy || axs_cachekeeper_prevent_network!=prevent) return NO;
        for (NSURLCache *cache in axs_cachekeeper_capacities.keyEnumerator.allObjects) {
            AxsCacheKeeperNetworkCapacity *state=[axs_cachekeeper_capacities objectForKey:cache];
            if (state.active) return NO;
            if (axs_cachekeeper_initializing_cache(cache)) continue;
            if (state.dirty || state.reconcileScheduled || (!prevent && (state.pending || state.restorationUnverified))) return NO;
        }
        for (AxsCacheKeeperNetworkInitialization *frame=axs_cachekeeper_initializations;frame;frame=frame->next)
            if (frame->root->provisional.active || (!prevent && frame->root->restorationUnverified)) return NO;
        return applied && (!prevent || shared!=nil);
    }
}
