#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdatomic.h>
#import "../AxsCacheKeeperNetworkCache.h"
#ifndef AXS_CACHEKEEPER_NETWORK_LOCK_SOURCE
#define AXS_CACHEKEEPER_NETWORK_LOCK_SOURCE "../AxsCacheKeeperNetworkCache.m"
#endif
#include AXS_CACHEKEEPER_NETWORK_LOCK_SOURCE

extern void axs_cachekeeper_prepare_network_cache_tests(void);
extern void axs_cachekeeper_run_network_cache_tests(NSString *fixture);
static void (*AxsNetworkRealSetter)(id,SEL,NSUInteger);
static NSUInteger (*AxsNetworkRealGetter)(id,SEL);
static NSURLCache *AxsNetworkTarget;
static void (^AxsNetworkAction)(void);
static atomic_bool AxsNetworkSetterArmed,AxsNetworkGetterArmed;
static atomic_bool AxsNetworkForbidTargetAccess;
static atomic_bool AxsNetworkReplayFailure;
static atomic_uint AxsNetworkTargetWrites;
static dispatch_semaphore_t AxsNetworkReplayFailed;
static atomic_bool AxsNetworkAfterGetterArmed;
static void (^AxsNetworkAfterGetter)(NSUInteger);
static void AxsNetworkRequire(BOOL value,const char *message) {
    if (!value) {fprintf(stderr,"FAIL: network locking: %s\n",message);exit(1);}
}
// The scheduling fence is the only controlled boundary. Every successful call
// continues to the real Foundation getter/setter captured before production hooks.
static void AxsNetworkSetter(id object,SEL selector,NSUInteger value) {
    AxsNetworkRequire(object!=AxsNetworkTarget || !atomic_load(&AxsNetworkForbidTargetAccess),"configuration must not reenter a cache with an unfinished native call");
    if (object==AxsNetworkTarget) {
        atomic_fetch_add(&AxsNetworkTargetWrites,1);
        if (atomic_exchange(&AxsNetworkReplayFailure,false)) {
            dispatch_semaphore_signal(AxsNetworkReplayFailed);
            @throw [NSException exceptionWithName:@"AxsNetworkReplayFailure" reason:@"controlled asynchronous native failure" userInfo:nil];
        }
    }
    if (object==AxsNetworkTarget && atomic_exchange(&AxsNetworkSetterArmed,false)) {void (^action)(void)=AxsNetworkAction;action();}
    AxsNetworkRealSetter(object,selector,value);
}
static NSUInteger AxsNetworkGetter(id object,SEL selector) {
    AxsNetworkRequire(object!=AxsNetworkTarget || !atomic_load(&AxsNetworkForbidTargetAccess),"configuration must not reenter a cache with an unfinished native call");
    if (object==AxsNetworkTarget && atomic_exchange(&AxsNetworkGetterArmed,false)) AxsNetworkAction();
    NSUInteger value=AxsNetworkRealGetter(object,selector);
    if (object==AxsNetworkTarget && atomic_exchange(&AxsNetworkAfterGetterArmed,false)) AxsNetworkAfterGetter(value);
    return value;
}
static NSURLCache *AxsNetworkCreate(NSString *folder,NSString *name) {
    return [[NSURLCache alloc] initWithMemoryCapacity:1048576 diskCapacity:8388608 diskPath:[folder stringByAppendingPathComponent:name]];
}
static void AxsNetworkWait(dispatch_semaphore_t signal,const char *message) {
    AxsNetworkRequire(dispatch_semaphore_wait(signal,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC))==0,message);
}
static void AxsNetworkAwaitCapacity(NSURLCache *cache,NSUInteger expected) {
    NSTimeInterval end=NSProcessInfo.processInfo.systemUptime+3;
    while (cache.diskCapacity!=expected && NSProcessInfo.processInfo.systemUptime<end) [NSThread sleepForTimeInterval:.005];
    AxsNetworkRequire(cache.diskCapacity==expected,"completed older native write must converge to newest request/policy");
}
static void AxsNetworkAwaitPolicy(BOOL prevent) {
    NSTimeInterval end=NSProcessInfo.processInfo.systemUptime+3;
    BOOL applied=axs_cachekeeper_configure_network_cache(prevent);
    while (!applied && NSProcessInfo.processInfo.systemUptime<end) {
        [NSThread sleepForTimeInterval:.005];applied=axs_cachekeeper_configure_network_cache(prevent);
    }
    AxsNetworkRequire(applied,"pending concurrency repair reaches an explicitly verified policy");
}
int main(int argc,const char *argv[]) {@autoreleasepool {
    AxsNetworkRequire(argc==3,"scenario and fixture arguments are required");
    NSString *scenario=@(argv[1]),*folder=@(argv[2]);
    Method setter=class_getInstanceMethod(NSURLCache.class,@selector(setDiskCapacity:));
    Method getter=class_getInstanceMethod(NSURLCache.class,@selector(diskCapacity));
    AxsNetworkRealSetter=(void *)method_setImplementation(setter,(IMP)AxsNetworkSetter);
    AxsNetworkRealGetter=(void *)method_setImplementation(getter,(IMP)AxsNetworkGetter);
    axs_cachekeeper_prepare_network_cache_tests();
    if ([scenario isEqual:@"existing"]) {axs_cachekeeper_run_network_cache_tests(folder);return 0;}
    if ([scenario isEqual:@"initial-getter-new-request"]) {
        NSURLCache *preexisting=AxsNetworkCreate(folder,@"before-hooks");
        NSURLCache.sharedURLCache=preexisting;AxsNetworkTarget=preexisting;
        AxsNetworkAction=^{
            dispatch_semaphore_t done=dispatch_semaphore_create(0);
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{preexisting.diskCapacity=33554432;dispatch_semaphore_signal(done);});
            AxsNetworkWait(done,"first baseline getter permits a newer same-cache request");
        };
        atomic_store(&AxsNetworkGetterArmed,true);
        (void)axs_cachekeeper_configure_network_cache(YES);
        AxsNetworkRequire(!atomic_load(&AxsNetworkGetterArmed),"first baseline getter fence was entered");
        AxsNetworkAwaitPolicy(YES);AxsNetworkAwaitPolicy(NO);
        AxsNetworkRequire(preexisting.diskCapacity==33554432,"first baseline getter cannot overwrite a newer request with temporary zero");
        printf("PASS: network-lock %s\n",argv[1]);return 0;
    }
    AxsNetworkRequire(axs_cachekeeper_configure_network_cache(YES),"initial enable succeeds");
    AxsNetworkRequire(axs_cachekeeper_configure_network_cache(NO),"initial disable succeeds");
    NSURLCache *first=AxsNetworkCreate(folder,@"first"),*second=AxsNetworkCreate(folder,@"second");
    AxsNetworkTarget=first;
    if ([@[@"setter-reentry",@"getter-reentry",@"setter-same-instance-reentry"] containsObject:scenario]) {
        BOOL same=[scenario isEqual:@"setter-same-instance-reentry"];
        AxsNetworkAction=^{
            dispatch_semaphore_t done=dispatch_semaphore_create(0);
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{(same ? first : second).diskCapacity=25165824;dispatch_semaphore_signal(done);});
            AxsNetworkWait(done,"native capacity access must allow another thread to enter a different cache setter");
        };
        if (![scenario isEqual:@"getter-reentry"]) {atomic_store(&AxsNetworkSetterArmed,true);first.diskCapacity=16777216;}
        else {atomic_store(&AxsNetworkGetterArmed,true);AxsNetworkRequire(axs_cachekeeper_configure_network_cache(YES),"getter reentry enable is verified");}
        AxsNetworkRequire(!atomic_load(&AxsNetworkSetterArmed) && !atomic_load(&AxsNetworkGetterArmed),"real native capacity fence was entered");
        AxsNetworkAwaitPolicy(NO);
        AxsNetworkRequire((same ? first : second).diskCapacity==25165824,"cross-thread request survives restriction and restoration");
    } else if ([scenario isEqual:@"late-write-after-read"]) {
        dispatch_semaphore_t oldEntered=dispatch_semaphore_create(0),oldRelease=dispatch_semaphore_create(0),oldDone=dispatch_semaphore_create(0);
        dispatch_semaphore_t newRead=dispatch_semaphore_create(0),newRelease=dispatch_semaphore_create(0),newDone=dispatch_semaphore_create(0);
        AxsNetworkAction=^{dispatch_semaphore_signal(oldEntered);AxsNetworkWait(oldRelease,"old writer released after newer getter sampled");};
        atomic_store(&AxsNetworkSetterArmed,true);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{first.diskCapacity=16777216;dispatch_semaphore_signal(oldDone);});
        AxsNetworkWait(oldEntered,"old writer entered before latest request");
        AxsNetworkAfterGetter=^(NSUInteger value) {
            AxsNetworkRequire(value==33554432,"newer getter really sampled the latest native capacity");
            dispatch_semaphore_signal(newRead);AxsNetworkWait(newRelease,"newer getter returned after old writer completed");
        };
        atomic_store(&AxsNetworkAfterGetterArmed,true);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{first.diskCapacity=33554432;dispatch_semaphore_signal(newDone);});
        AxsNetworkWait(newRead,"newer getter sampled before the old native write");
        dispatch_semaphore_signal(oldRelease);AxsNetworkWait(oldDone,"old native write completed before latest read committed");
        dispatch_semaphore_signal(newRelease);AxsNetworkWait(newDone,"latest request returned");
        AxsNetworkAwaitCapacity(first,33554432);AxsNetworkAwaitPolicy(NO);
        AxsNetworkRequire(first.diskCapacity==33554432,"a getter overtaken by an older native write cannot verify stale state");
    }
#if AXS_CACHEKEEPER_NETWORK_LOCK_CURRENT
    else if ([scenario isEqual:@"queued-replay-exception"]) {
        // Fence the real production repair queue, without adding a test API to
        // the component. The queued old repair must recheck a later failure.
        dispatch_semaphore_t queueEntered=dispatch_semaphore_create(0),queueRelease=dispatch_semaphore_create(0),queueDrained=dispatch_semaphore_create(0);
        dispatch_async(axs_cachekeeper_reconcile_queue,^{dispatch_semaphore_signal(queueEntered);AxsNetworkWait(queueRelease,"repair queue fixture released");});
        AxsNetworkWait(queueEntered,"production repair queue held before older repair");
        dispatch_semaphore_t entered=dispatch_semaphore_create(0),release=dispatch_semaphore_create(0),done=dispatch_semaphore_create(0);
        AxsNetworkAction=^{dispatch_semaphore_signal(entered);AxsNetworkWait(release,"queued old setter released");};
        atomic_store(&AxsNetworkSetterArmed,true);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{first.diskCapacity=16777216;dispatch_semaphore_signal(done);});
        AxsNetworkWait(entered,"old setter entered before queued repair");
        first.diskCapacity=33554432;dispatch_semaphore_signal(release);AxsNetworkWait(done,"old setter enqueued its repair");
        AxsNetworkAction=^{@throw [NSException exceptionWithName:@"AxsNetworkQueuedFailure" reason:@"new explicit request fails before old repair executes" userInfo:nil];};
        atomic_store(&AxsNetworkSetterArmed,true);BOOL caught=NO;
        @try {first.diskCapacity=41943040;} @catch (NSException *error) {caught=[error.name isEqual:@"AxsNetworkQueuedFailure"];}
        AxsNetworkRequire(caught,"newer explicit failure propagated before old repair runs");
        unsigned writes=atomic_load(&AxsNetworkTargetWrites);
        dispatch_async(axs_cachekeeper_reconcile_queue,^{dispatch_semaphore_signal(queueDrained);});
        dispatch_semaphore_signal(queueRelease);AxsNetworkWait(queueDrained,"old queued repair retired after failure");
        AxsNetworkRequire(atomic_load(&AxsNetworkTargetWrites)==writes && first.diskCapacity==16777216,"old queued repair cannot retry the newer failed version");
        AxsNetworkRequire(axs_cachekeeper_configure_network_cache(NO) && first.diskCapacity==41943040,"explicit recovery alone retries the failed latest request");
    }
#endif
    else if ([scenario isEqual:@"replay-exception"]) {
        dispatch_semaphore_t entered=dispatch_semaphore_create(0),release=dispatch_semaphore_create(0),done=dispatch_semaphore_create(0);
        AxsNetworkReplayFailed=dispatch_semaphore_create(0);
        AxsNetworkAction=^{dispatch_semaphore_signal(entered);AxsNetworkWait(release,"replay exception old setter released");};
        atomic_store(&AxsNetworkSetterArmed,true);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{first.diskCapacity=16777216;dispatch_semaphore_signal(done);});
        AxsNetworkWait(entered,"replay exception old setter entered");
        first.diskCapacity=33554432;
        atomic_store(&AxsNetworkReplayFailure,true);
        dispatch_semaphore_signal(release);AxsNetworkWait(done,"replay exception old setter returned");
        AxsNetworkWait(AxsNetworkReplayFailed,"asynchronous latest-intent repair reached the real native boundary");
        [NSThread sleepForTimeInterval:.15];unsigned writes=atomic_load(&AxsNetworkTargetWrites);
        [NSThread sleepForTimeInterval:.15];
        AxsNetworkRequire(atomic_load(&AxsNetworkTargetWrites)==writes,"failed replay version must not retry automatically");
        AxsNetworkRequire(first.diskCapacity==16777216,"failed repair does not pretend the newest capacity was applied");
        AxsNetworkRequire(axs_cachekeeper_configure_network_cache(NO),"explicit refresh can recover after reported asynchronous failure");
        AxsNetworkRequire(first.diskCapacity==33554432,"explicit recovery applies the preserved latest request");
    } else if ([@[@"newer-setter",@"disable-during-setter",@"enable-during-setter",@"off-on-during-setter"] containsObject:scenario]) {
        BOOL disable=[scenario isEqual:@"disable-during-setter"];
        BOOL enable=[scenario isEqual:@"enable-during-setter"],offOn=[scenario isEqual:@"off-on-during-setter"];
        BOOL policyChange=disable || enable || offOn;
        if (disable || offOn) AxsNetworkRequire(axs_cachekeeper_configure_network_cache(YES),"late writer starts restricted");
        dispatch_semaphore_t entered=dispatch_semaphore_create(0),release=dispatch_semaphore_create(0),done=dispatch_semaphore_create(0);
        AxsNetworkAction=^{if (policyChange) atomic_store(&AxsNetworkForbidTargetAccess,true);dispatch_semaphore_signal(entered);AxsNetworkWait(release,"held native setter released");};
        atomic_store(&AxsNetworkSetterArmed,true);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{first.diskCapacity=16777216;dispatch_semaphore_signal(done);});
        AxsNetworkWait(entered,"old native setter entered");
        if (disable || offOn) AxsNetworkRequire(!axs_cachekeeper_configure_network_cache(NO),"disable cannot report verified while older native write is unfinished");
        if (enable || offOn) for (NSUInteger i=0;i<4;i++) AxsNetworkRequire(!axs_cachekeeper_configure_network_cache(YES),"enable and repeated policy cannot report verified or reenter unfinished native write");
        if (!policyChange) first.diskCapacity=33554432;
        atomic_store(&AxsNetworkForbidTargetAccess,false);
        dispatch_semaphore_signal(release);AxsNetworkWait(done,"old setter returned after newer intent");
        AxsNetworkAwaitCapacity(first,(enable || offOn) ? 0 : disable ? 16777216 : 33554432);
        if (enable || offOn) AxsNetworkAwaitPolicy(YES);
        AxsNetworkAwaitPolicy(NO);
        if (policyChange) AxsNetworkRequire(first.diskCapacity==16777216,"all policy interleavings restore the latest original request");
    } else if ([scenario isEqual:@"setter-exception"] || [scenario isEqual:@"getter-exception"]) {
        BOOL setterFailure=[scenario isEqual:@"setter-exception"];
        AxsNetworkAction=^{@throw [NSException exceptionWithName:@"AxsNetworkNativeFailure" reason:@"one controlled native boundary failure" userInfo:nil];};
        if (setterFailure) atomic_store(&AxsNetworkSetterArmed,true);else atomic_store(&AxsNetworkGetterArmed,true);
        BOOL caught=NO;
        @try {if (setterFailure) first.diskCapacity=16777216;else (void)axs_cachekeeper_configure_network_cache(YES);}
        @catch (NSException *error) {caught=[error.name isEqual:@"AxsNetworkNativeFailure"];}
        AxsNetworkRequire(caught,"native exception propagates to its caller");
        AxsNetworkRequire(axs_cachekeeper_configure_network_cache(NO),"native exception retires active write and permits explicit recovery");
        AxsNetworkRequire(first.diskCapacity==(setterFailure ? 16777216 : 8388608),"explicit recovery retains latest requested capacity");
    } else if ([scenario isEqual:@"parallel-setters"]) {
        dispatch_group_t group=dispatch_group_create();
        for (NSUInteger thread=0;thread<4;thread++) dispatch_group_async(group,dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{
            for (NSUInteger i=0;i<24;i++) first.diskCapacity=(thread+1)*1048576+i*4096;
        });
        AxsNetworkRequire(dispatch_group_wait(group,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0,"continuous concurrent setters all return without global serialization");
        first.diskCapacity=41943040;AxsNetworkAwaitCapacity(first,41943040);
        AxsNetworkAwaitPolicy(NO);
    } else AxsNetworkRequire(NO,"unknown scenario");
    AxsNetworkRequire(first.memoryCapacity==1048576 && second.memoryCapacity==1048576,"disk coordination preserves real memory capacity");
    printf("PASS: network-lock %s\n",argv[1]);return 0;
}}
