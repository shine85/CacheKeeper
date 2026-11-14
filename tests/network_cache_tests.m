#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <execinfo.h>
#include <string.h>
#import "../AxsCacheKeeperNetworkCache.h"

// 在生产 Hook 捕获原 IMP 前加透明观察层；每次仍调用 Foundation 的真实初始化器。
static id (*axs_cachekeeper_test_real_path)(id __attribute__((ns_consumed)), SEL, NSUInteger, NSUInteger, NSString *) __attribute__((ns_returns_retained));
static id (*axs_cachekeeper_test_real_url)(id __attribute__((ns_consumed)), SEL, NSUInteger, NSUInteger, NSURL *) __attribute__((ns_returns_retained));
static NSMutableArray<NSDictionary *> *axs_cachekeeper_test_network_calls;
static NSURLCache *(^axs_cachekeeper_test_after_init)(NSURLCache *);
static BOOL axs_cachekeeper_test_observe_network;
static BOOL axs_cachekeeper_test_network_prepared;
static IMP axs_cachekeeper_test_real_setter;
static void (*axs_cachekeeper_test_next_setter)(id, SEL, NSUInteger);
static BOOL axs_cachekeeper_test_trace_limited;
static NSUInteger axs_cachekeeper_test_traced_setters;
static __thread NSUInteger axs_cachekeeper_test_real_init_depth;

// 只诊断当前合成 limited 夹具；不输出缓存路径或应用内容，不改变真实调用。
static void axs_cachekeeper_test_trace_address(const char *label, NSUInteger index, void *address) {
    Dl_info info={0};
    dladdr(address,&info);
    const char *image=info.dli_fname ? strrchr(info.dli_fname,'/') : NULL;
    if (image) image++; else image=info.dli_fname ? info.dli_fname : "unresolved";
    fprintf(stderr,"NETWORK_TRACE %s[%lu] image=%s symbol=%s offset=%llu\n",label,(unsigned long)index,
        image,info.dli_sname ? info.dli_sname : "unresolved",
        info.dli_saddr ? (unsigned long long)((uintptr_t)address-(uintptr_t)info.dli_saddr) : 0);
}
static void axs_cachekeeper_test_trace_setter(id object, SEL selector, NSUInteger capacity) {
    if (axs_cachekeeper_test_trace_limited && axs_cachekeeper_test_traced_setters++<12) {
        fprintf(stderr,"NETWORK_TRACE setter capacity=%lu realInitDepth=%lu class=%s\n",
            (unsigned long)capacity,(unsigned long)axs_cachekeeper_test_real_init_depth,object_getClassName(object));
        axs_cachekeeper_test_trace_address("caller",0,__builtin_extract_return_addr(__builtin_return_address(0)));
        void *frames[8];
        int count=backtrace(frames,8);
        for (int index=1;index<count;index++) axs_cachekeeper_test_trace_address("stack",(NSUInteger)index,frames[index]);
    }
    axs_cachekeeper_test_next_setter(object,selector,capacity);
}
static void axs_cachekeeper_test_install_setter_trace(void) {
    if (axs_cachekeeper_test_next_setter) return;
    Method setter=class_getInstanceMethod(NSURLCache.class,@selector(setDiskCapacity:));
    axs_cachekeeper_test_next_setter=(void *)method_setImplementation(setter,(IMP)axs_cachekeeper_test_trace_setter);
}

static void axs_cachekeeper_network_require(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "FAIL: network initialization: %s\n", message.UTF8String); exit(1); }
}
static void axs_cachekeeper_test_record_init(NSString *kind, NSUInteger memory, NSUInteger disk) {
    if (axs_cachekeeper_test_observe_network)
        [axs_cachekeeper_test_network_calls addObject:@{@"kind":kind, @"memory":@(memory), @"disk":@(disk)}];
}
static NSURLCache *axs_cachekeeper_test_finish_init(NSURLCache *result) {
    NSURLCache *(^action)(NSURLCache *)=axs_cachekeeper_test_after_init;
    if (action) {
        axs_cachekeeper_test_after_init=nil;
        return action(result);
    }
    return result;
}
static id axs_cachekeeper_test_init_path(id object __attribute__((ns_consumed)), SEL selector, NSUInteger memory, NSUInteger disk, NSString *path) __attribute__((ns_returns_retained));
static id axs_cachekeeper_test_init_path(id object __attribute__((ns_consumed)), SEL selector, NSUInteger memory, NSUInteger disk, NSString *path) {
    axs_cachekeeper_test_record_init(@"path",memory,disk);
    if (axs_cachekeeper_test_trace_limited) fprintf(stderr,"NETWORK_TRACE path enter memory=%lu disk=%lu\n",(unsigned long)memory,(unsigned long)disk);
    id result=nil;
    axs_cachekeeper_test_real_init_depth++;
    @try { result=axs_cachekeeper_test_real_path(object,selector,memory,disk,path); }
    @finally { axs_cachekeeper_test_real_init_depth--; }
    if (axs_cachekeeper_test_trace_limited) fprintf(stderr,"NETWORK_TRACE path return memory=%lu disk=%lu\n",(unsigned long)[result memoryCapacity],(unsigned long)[result diskCapacity]);
    return axs_cachekeeper_test_finish_init(result);
}
static id axs_cachekeeper_test_init_url(id object __attribute__((ns_consumed)), SEL selector, NSUInteger memory, NSUInteger disk, NSURL *url) __attribute__((ns_returns_retained));
static id axs_cachekeeper_test_init_url(id object __attribute__((ns_consumed)), SEL selector, NSUInteger memory, NSUInteger disk, NSURL *url) {
    axs_cachekeeper_test_record_init(@"url",memory,disk);
    if (axs_cachekeeper_test_trace_limited) fprintf(stderr,"NETWORK_TRACE url enter memory=%lu disk=%lu\n",(unsigned long)memory,(unsigned long)disk);
    id result=nil;
    axs_cachekeeper_test_real_init_depth++;
    @try { result=axs_cachekeeper_test_real_url(object,selector,memory,disk,url); }
    @finally { axs_cachekeeper_test_real_init_depth--; }
    if (axs_cachekeeper_test_trace_limited) fprintf(stderr,"NETWORK_TRACE url return memory=%lu disk=%lu\n",(unsigned long)[result memoryCapacity],(unsigned long)[result diskCapacity]);
    return axs_cachekeeper_test_finish_init(result);
}

void axs_cachekeeper_prepare_network_cache_tests(void) {
    if (axs_cachekeeper_test_network_prepared) return;
    axs_cachekeeper_test_network_prepared=YES;
    axs_cachekeeper_test_network_calls=[NSMutableArray array];
    Method path=class_getInstanceMethod(NSURLCache.class,@selector(initWithMemoryCapacity:diskCapacity:diskPath:));
    axs_cachekeeper_network_require(path!=NULL,@"Foundation path 初始化器可用");
    axs_cachekeeper_test_real_path=(void *)method_setImplementation(path,(IMP)axs_cachekeeper_test_init_path);
    Method url=class_getInstanceMethod(NSURLCache.class,@selector(initWithMemoryCapacity:diskCapacity:directoryURL:));
    if (url) axs_cachekeeper_test_real_url=(void *)method_setImplementation(url,(IMP)axs_cachekeeper_test_init_url);
    IMP setter=method_getImplementation(class_getInstanceMethod(NSURLCache.class,@selector(setDiskCapacity:)));
    axs_cachekeeper_test_real_setter=setter;
    axs_cachekeeper_network_require(axs_cachekeeper_configure_network_cache(NO),@"初始关闭返回成功");
    axs_cachekeeper_network_require(method_getImplementation(path)==(IMP)axs_cachekeeper_test_init_path &&
        setter==method_getImplementation(class_getInstanceMethod(NSURLCache.class,@selector(setDiskCapacity:))),
        @"从未开启时不安装 Hook");
}

static NSURLCache *axs_cachekeeper_test_create_cache(NSString *fixture, NSString *name, BOOL url) {
    NSString *path=[fixture stringByAppendingPathComponent:name];
    if (url) return [[NSURLCache alloc] initWithMemoryCapacity:1048576 diskCapacity:8388608 directoryURL:[NSURL fileURLWithPath:path isDirectory:YES]];
    return [[NSURLCache alloc] initWithMemoryCapacity:1048576 diskCapacity:8388608 diskPath:path];
}
static void axs_cachekeeper_test_assert_boundary(NSString *kind, NSUInteger disk) {
    NSDictionary *entry=axs_cachekeeper_test_network_calls.firstObject;
    axs_cachekeeper_network_require([entry[@"kind"] isEqual:kind] && [entry[@"memory"] unsignedIntegerValue]==1048576,
        @"真实原方法收到原内存参数与对应构造器调用");
    axs_cachekeeper_network_require([entry[@"disk"] unsignedIntegerValue]==disk,
        [NSString stringWithFormat:@"%@ 原初始化器 disk 期望 %lu，实际 %@",kind,(unsigned long)disk,entry[@"disk"]]);
    if (!disk) for (NSDictionary *call in axs_cachekeeper_test_network_calls)
        axs_cachekeeper_network_require([call[@"disk"] unsignedIntegerValue]==0,@"构造器内部委托同样不能收到非零磁盘容量");
}

void axs_cachekeeper_run_network_cache_tests(NSString *fixture) {
    axs_cachekeeper_prepare_network_cache_tests();
    axs_cachekeeper_network_require(axs_cachekeeper_configure_network_cache(NO),@"关闭前一组测试策略");
    for (NSNumber *useURL in (axs_cachekeeper_test_real_url ? @[@NO,@YES] : @[@NO])) {
        BOOL url=useURL.boolValue;
        NSString *kind=url ? @"url" : @"path";
        axs_cachekeeper_test_observe_network=YES;
        [axs_cachekeeper_test_network_calls removeAllObjects];
        NSURLCache *control=axs_cachekeeper_test_create_cache(fixture,[kind stringByAppendingString:@"-disabled"],url);
        axs_cachekeeper_test_assert_boundary(kind,8388608);
        axs_cachekeeper_network_require(control.diskCapacity==8388608 && control.memoryCapacity==1048576,@"未启用对照保留应用请求");

        axs_cachekeeper_test_observe_network=NO;
        axs_cachekeeper_network_require(axs_cachekeeper_configure_network_cache(YES),@"开启限制");
        // 在生产 Hook 外观察入口，生产直接调用原 setter 时不会伪装成一次 APP 请求。
        axs_cachekeeper_test_install_setter_trace();
        axs_cachekeeper_test_observe_network=YES;
        [axs_cachekeeper_test_network_calls removeAllObjects];
        axs_cachekeeper_test_traced_setters=0;
        axs_cachekeeper_test_trace_limited=YES;
        axs_cachekeeper_test_trace_address("path-original",0,(void *)axs_cachekeeper_test_real_path);
        if (axs_cachekeeper_test_real_url) axs_cachekeeper_test_trace_address("url-original",0,(void *)axs_cachekeeper_test_real_url);
        axs_cachekeeper_test_trace_address("setter-original",0,(void *)axs_cachekeeper_test_real_setter);
        NSURLCache *limited=axs_cachekeeper_test_create_cache(fixture,[kind stringByAppendingString:@"-limited"],url);
        axs_cachekeeper_test_assert_boundary(kind,0);
        axs_cachekeeper_network_require(limited.diskCapacity==0 && limited.memoryCapacity==1048576,@"实际返回对象限制磁盘且保留内存");
        BOOL restored=axs_cachekeeper_configure_network_cache(NO);
        NSUInteger restoredDisk=limited.diskCapacity;
        fprintf(stderr,"NETWORK_TRACE restore kind=%s applied=%d disk=%lu memory=%lu\n",kind.UTF8String,
            restored,(unsigned long)restoredDisk,(unsigned long)limited.memoryCapacity);
        axs_cachekeeper_test_trace_limited=NO;
        axs_cachekeeper_network_require(restored && restoredDisk==8388608,@"关闭恢复原始初始化请求，不恢复被压成的零");
        limited.diskCapacity=33554432;
        axs_cachekeeper_network_require(axs_cachekeeper_configure_network_cache(NO) && limited.diskCapacity==33554432,@"重复关闭不覆盖后续应用容量");

        axs_cachekeeper_network_require(axs_cachekeeper_configure_network_cache(YES),@"再次开启限制");
        NSURLCache *latest=axs_cachekeeper_test_create_cache(fixture,[kind stringByAppendingString:@"-latest"],url);
        latest.diskCapacity=16777216;
        axs_cachekeeper_network_require(latest.diskCapacity==0,@"启用期间显式请求仍被限制");
        axs_cachekeeper_network_require(axs_cachekeeper_configure_network_cache(NO) && latest.diskCapacity==16777216,@"较新的显式请求优先于原始初始化容量");

        axs_cachekeeper_network_require(axs_cachekeeper_configure_network_cache(YES),@"初始化中请求测试开启限制");
        axs_cachekeeper_test_after_init=^NSURLCache *(NSURLCache *cache) { cache.diskCapacity=25165824; return cache; };
        NSURLCache *requested=axs_cachekeeper_test_create_cache(fixture,[kind stringByAppendingString:@"-in-init-request"],url);
        axs_cachekeeper_network_require(requested.diskCapacity==0 && axs_cachekeeper_configure_network_cache(NO) && requested.diskCapacity==25165824,
            @"真实初始化期间较新的 setter 请求不被外层旧参数覆盖");

        axs_cachekeeper_network_require(axs_cachekeeper_configure_network_cache(YES),@"初始化中显式零请求测试开启限制");
        axs_cachekeeper_test_after_init=^NSURLCache *(NSURLCache *cache) { cache.diskCapacity=0; return cache; };
        NSURLCache *zeroRequested=axs_cachekeeper_test_create_cache(fixture,[kind stringByAppendingString:@"-in-init-zero"],url);
        axs_cachekeeper_network_require(axs_cachekeeper_configure_network_cache(NO) && zeroRequested.diskCapacity==0,
            @"真实初始化期间显式请求零不能被误当成内部转发而丢失");

        axs_cachekeeper_network_require(axs_cachekeeper_configure_network_cache(YES),@"初始化中多次请求测试开启限制");
        axs_cachekeeper_test_after_init=^NSURLCache *(NSURLCache *cache) { cache.diskCapacity=25165824; cache.diskCapacity=0; return cache; };
        NSURLCache *lastZero=axs_cachekeeper_test_create_cache(fixture,[kind stringByAppendingString:@"-in-init-last-zero"],url);
        axs_cachekeeper_network_require(axs_cachekeeper_configure_network_cache(NO) && lastZero.diskCapacity==0,
            @"真实初始化期间非零后再请求零，以最后一次请求为准");

        axs_cachekeeper_network_require(axs_cachekeeper_configure_network_cache(YES),@"类簇返回测试开启限制");
        axs_cachekeeper_test_after_init=^NSURLCache *(NSURLCache *cache) {
            (void)cache;
            // 真实原方法仍已运行；用另一个真实 Foundation 对象复现类簇替换返回值。
            return [[NSURLCache alloc] initWithMemoryCapacity:1048576 diskCapacity:0 diskPath:[fixture stringByAppendingPathComponent:[kind stringByAppendingString:@"-replacement"]]];
        };
        NSURLCache *replaced=axs_cachekeeper_test_create_cache(fixture,[kind stringByAppendingString:@"-cluster"],url);
        axs_cachekeeper_network_require(replaced.diskCapacity==0 && replaced.memoryCapacity==1048576 &&
            axs_cachekeeper_configure_network_cache(NO) && replaced.diskCapacity==8388608,@"类簇替换对象恢复外层应用请求，而非内层转发的零");

        axs_cachekeeper_network_require(axs_cachekeeper_configure_network_cache(YES),@"类簇新请求测试开启限制");
        axs_cachekeeper_test_after_init=^NSURLCache *(NSURLCache *cache) {
            (void)cache;
            NSURLCache *replacement=[[NSURLCache alloc] initWithMemoryCapacity:1048576 diskCapacity:0 diskPath:[fixture stringByAppendingPathComponent:[kind stringByAppendingString:@"-replacement-latest"]]];
            replacement.diskCapacity=41943040;
            return replacement;
        };
        NSURLCache *replacedLatest=axs_cachekeeper_test_create_cache(fixture,[kind stringByAppendingString:@"-cluster-latest"],url);
        axs_cachekeeper_network_require(replacedLatest.diskCapacity==0 && axs_cachekeeper_configure_network_cache(NO) && replacedLatest.diskCapacity==41943040,
            @"类簇替换对象的新 setter 请求优先于外层原始请求");

        axs_cachekeeper_network_require(axs_cachekeeper_configure_network_cache(YES),@"类簇零请求测试开启限制");
        axs_cachekeeper_test_after_init=^NSURLCache *(NSURLCache *cache) {
            (void)cache;
            NSURLCache *replacement=[[NSURLCache alloc] initWithMemoryCapacity:1048576 diskCapacity:0 diskPath:[fixture stringByAppendingPathComponent:[kind stringByAppendingString:@"-replacement-zero"]]];
            replacement.diskCapacity=0;
            return replacement;
        };
        NSURLCache *replacedZero=axs_cachekeeper_test_create_cache(fixture,[kind stringByAppendingString:@"-cluster-zero"],url);
        axs_cachekeeper_network_require(axs_cachekeeper_configure_network_cache(NO) && replacedZero.diskCapacity==0,
            @"类簇替换对象的新零请求也优先于外层原始请求");

        axs_cachekeeper_network_require(axs_cachekeeper_configure_network_cache(YES),@"并发关闭测试开启限制");
        axs_cachekeeper_test_after_init=^NSURLCache *(NSURLCache *cache) {
            dispatch_semaphore_t completed=dispatch_semaphore_create(0);
            __block BOOL applied=NO;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{
                applied=axs_cachekeeper_configure_network_cache(NO);
                dispatch_semaphore_signal(completed);
            });
            axs_cachekeeper_network_require(dispatch_semaphore_wait(completed,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0 && applied,
                @"真实初始化期间另一线程能关闭，不能跨原初始化器持全局锁");
            return cache;
        };
        NSURLCache *switched=axs_cachekeeper_test_create_cache(fixture,[kind stringByAppendingString:@"-switch-off"],url);
        axs_cachekeeper_network_require(switched.diskCapacity==8388608,@"初始化中关闭后恢复未被零覆盖的应用容量");

        axs_cachekeeper_test_after_init=^NSURLCache *(NSURLCache *cache) {
            axs_cachekeeper_network_require(axs_cachekeeper_configure_network_cache(YES),@"初始化中开启限制");
            return cache;
        };
        NSURLCache *switchedOn=axs_cachekeeper_test_create_cache(fixture,[kind stringByAppendingString:@"-switch-on"],url);
        axs_cachekeeper_network_require(switchedOn.diskCapacity==0 && axs_cachekeeper_configure_network_cache(NO) && switchedOn.diskCapacity==8388608,
            @"关闭状态进入而初始化中开启时，返回对象受限且可恢复");

        axs_cachekeeper_test_after_init=^NSURLCache *(NSURLCache *cache) {
            axs_cachekeeper_network_require(axs_cachekeeper_configure_network_cache(YES),@"关闭状态进入初始化后临时开启限制");
            cache.diskCapacity=25165824;
            axs_cachekeeper_network_require(cache.diskCapacity==0,@"初始化中临时开启确实压制新的非零请求");
            axs_cachekeeper_network_require(axs_cachekeeper_configure_network_cache(NO),@"初始化返回前再次关闭限制");
            return cache;
        };
        NSURLCache *switchedTwice=axs_cachekeeper_test_create_cache(fixture,[kind stringByAppendingString:@"-off-on-request-off"],url);
        axs_cachekeeper_network_require(switchedTwice.diskCapacity==25165824 && switchedTwice.memoryCapacity==1048576,
            @"关闭进入初始化、开启后新请求、返回前关闭，必须恢复最新非零容量");
        switchedTwice.diskCapacity=33554432;
        axs_cachekeeper_network_require(axs_cachekeeper_configure_network_cache(NO) && switchedTwice.diskCapacity==33554432,
            @"短暂开启的初始化恢复完成后，重复关闭不覆盖后续请求");
        axs_cachekeeper_test_observe_network=NO;
    }
    axs_cachekeeper_test_after_init=nil;
    [axs_cachekeeper_test_network_calls removeAllObjects];
    axs_cachekeeper_network_require(axs_cachekeeper_configure_network_cache(NO),@"测试退出关闭限制");
    puts("PASS: NSURLCache real initializer boundary, restoration, latest requests and concurrent toggle");
}
