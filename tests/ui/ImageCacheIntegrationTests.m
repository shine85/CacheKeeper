#import <XCTest/XCTest.h>
#import <SDWebImage/SDWebImage.h>
#import "../../AxsCacheKeeperImageCache.h"
#import "../../AxsCacheKeeperCleanupRules.h"
#include <sys/stat.h>
#import <objc/runtime.h>

// The private queue getter is verified against the fixed SDK source and the saved device ABI.
@interface SDImageCache (AxsCacheKeeperImageTestQueue)
@property(nonatomic,strong) dispatch_queue_t ioQueue;
@end
// Test fixture uses the existing observer/context boundaries; no product test-only scheduler.
@interface AxsCacheKeeperImageCache (AxsCacheKeeperImageTestObserver)
- (void)setObserver:(void (^)(NSDictionary *))observer;
@end
@interface AxsCacheKeeperImageTestCustomDisk : SDDiskCache
@end
@implementation AxsCacheKeeperImageTestCustomDisk
@end
@interface AxsCacheKeeperImageTestCustomConfig : SDImageCacheConfig
@end
@implementation AxsCacheKeeperImageTestCustomConfig
@end
@interface AxsCacheKeeperImageTestMutatingMemory : SDMemoryCache
@end
@implementation AxsCacheKeeperImageTestMutatingMemory
- (instancetype)initWithConfig:(SDImageCacheConfig *)config {
    if ((self=[super initWithConfig:config])) config.ioQueueAttributes=nil;
    return self;
}
@end
@interface AxsCacheKeeperImageTestSubstitutingMemory : SDMemoryCache
@end
@implementation AxsCacheKeeperImageTestSubstitutingMemory
- (instancetype)initWithConfig:(SDImageCacheConfig *)config {
    if (!(self=[super initWithConfig:config])) return nil;
    config.ioQueueAttributes=nil;config.memoryCacheClass=SDMemoryCache.class;
    return (id)[[SDMemoryCache alloc] initWithConfig:config];
}
@end

@interface AxsCacheKeeperImageTestWrongReturn : NSObject
- (NSUInteger)fileManager;
@end
@implementation AxsCacheKeeperImageTestWrongReturn
- (NSUInteger)fileManager { return 0; }
@end
@interface AxsCacheKeeperImageTestWrongCount : NSObject
@end
@implementation AxsCacheKeeperImageTestWrongCount
@end
@interface AxsCacheKeeperImageTestWrongArgument : NSObject
@end
@implementation AxsCacheKeeperImageTestWrongArgument
@end
@interface AxsCacheKeeperImageTestForeignMethod : NSObject
- (id)fileManager;
@end
@implementation AxsCacheKeeperImageTestForeignMethod
- (id)fileManager { return nil; }
@end
static id AxsCacheKeeperImageTestMetadataOnlyMethod(id object, SEL selector, id value) {
    (void)object;(void)selector;(void)value;return nil;
}
static id AxsCacheKeeperImageTestChangedGetter(id object, SEL selector) {
    (void)object;(void)selector;return nil;
}

@interface ImageCacheIntegrationTests : XCTestCase
@property(nonatomic,strong) AxsCacheKeeperImageCache *engine;
@property(nonatomic,strong) NSMutableDictionary *context;
@property(nonatomic,copy) NSString *home;
@property(nonatomic,strong) NSMutableArray<SDImageCache *> *owners;
@property(atomic) NSUInteger contextReads;
@property(atomic,copy) void (^contextBarrier)(void);
@property(nonatomic) NSUInteger refreshSequence;
@end
@implementation ImageCacheIntegrationTests
- (void)setUp {
    [super setUp];
    self.home=[[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] stringByStandardizingPath];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtPath:[self.home stringByAppendingPathComponent:@"Library/Caches"] withIntermediateDirectories:YES attributes:nil error:nil]);
    self.context=[@{@"valid":@YES,@"appState":@{@"enabled":@YES,@"mode":@"clean",@"autoDiscover":@YES,@"excludedPaths":@[]},
        @"selected":@[],@"home":self.home,@"bundle":@"cachekeeper.owned.integration",@"version":@"1.0",
        @"installation":@"owned-fixture-install",@"reportWritable":@YES} mutableCopy];
    self.owners=[NSMutableArray new];self.contextReads=0;__weak typeof(self) weakSelf=self;
    self.engine=[[AxsCacheKeeperImageCache alloc] initWithContextProvider:^NSDictionary *{
        ImageCacheIntegrationTests *test=weakSelf;
        void (^barrier)(void)=test.contextBarrier;if (barrier) barrier();
        @synchronized(test) {test.contextReads++;return [test.context copy] ?: @{};}
    } observer:nil];
    [self.engine usePinnedSDKForIntegrationTests];[self.engine startObserving];[self axs_cachekeeper_refresh];
}
- (void)tearDown {
    self.contextBarrier=nil;[self.engine setObserver:nil];
    @synchronized(self) {self.context[@"appState"]=@{@"enabled":@NO};}
    [self.engine refreshWithCompletion:nil];
    for (SDImageCache *owner in self.owners) dispatch_sync(owner.ioQueue,^{});
    [self axs_cachekeeper_refresh];
    self.owners=nil;self.engine=nil;
    // Only this test's explicitly created UUID directory is removed.
    XCTAssertTrue([NSFileManager.defaultManager removeItemAtPath:self.home error:nil]);
    [AxsCacheKeeperCleanupRules removeAllRulesForTesting];[super tearDown];
}
- (void)axs_cachekeeper_refresh {
    NSUInteger sequence=++self.refreshSequence,owners=self.owners.count;
    NSTimeInterval began=NSProcessInfo.processInfo.systemUptime;
    XCTestExpectation *done=[self expectationWithDescription:[NSString stringWithFormat:@"image configuration refresh #%lu owners=%lu",(unsigned long)sequence,(unsigned long)owners]];
    [self.engine refreshWithCompletion:^{
        NSLog(@"CK_IMAGE_REFRESH_DONE sequence=%lu owners=%lu elapsed=%.3f",(unsigned long)sequence,(unsigned long)owners,NSProcessInfo.processInfo.systemUptime-began);
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:5];
    XCTAssertNotNil(axs_cachekeeper_image_cache_projection(self.engine.receipt));
}
- (void)axs_cachekeeper_state:(NSDictionary *)state {
    @synchronized(self) {self.context[@"appState"]=state;}
    [self axs_cachekeeper_refresh];
}
- (SDImageCache *)axs_cachekeeper_owner:(NSString *)space config:(SDImageCacheConfig *)config {
    SDImageCacheConfig *actual=config ?: [SDImageCacheConfig new];
    actual.shouldRemoveExpiredDataWhenEnterBackground=NO;actual.shouldRemoveExpiredDataWhenTerminate=NO;
    SDImageCache *owner=[[SDImageCache alloc] initWithNamespace:space diskCacheDirectory:[self.home stringByAppendingPathComponent:@"Library/Caches"] config:actual];
    XCTAssertNotNil(owner);[self.owners addObject:owner];
    if (!config) {
        // Stop at the contract failure, before queue/cleanup assertions create cascades.
        NSDictionary *detail=[self.engine instanceDiagnosticsForIntegrationTests:owner];
        BOOL continuing=self.continueAfterFailure;self.continueAfterFailure=NO;
        XCTAssertEqualObjects(detail[@"initialReason"],@"none",@"standard SDK admission: %@",detail);
        XCTAssertEqualObjects(detail[@"currentReason"],@"none",@"standard SDK admission: %@",detail);
        self.continueAfterFailure=continuing;
    }
    // 5.15.5 creates the cache root lazily on its first actual write; 5.21.7 creates it in init.
    // Let the SDK establish its own root, even when this test later rejects the owner.
    if (![NSFileManager.defaultManager fileExistsAtPath:owner.diskCachePath]) {
        [owner storeImageDataToDisk:[self axs_cachekeeper_payload] forKey:@"fixture-root-seed"];
        XCTAssertNotNil([owner diskImageDataForKey:@"fixture-root-seed"]);
        dispatch_sync(owner.ioQueue,^{[owner.diskCache removeDataForKey:@"fixture-root-seed"];});
    }
    [self axs_cachekeeper_refresh];return owner;
}
- (void)axs_cachekeeper_wait:(BOOL (^)(NSDictionary *))test description:(NSString *)description {
    NSPredicate *predicate=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *unused) {(void)object;(void)unused;return test(self.engine.receipt);}];
    XCTNSPredicateExpectation *done=[[XCTNSPredicateExpectation alloc] initWithPredicate:predicate object:self.engine];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[done] timeout:5],XCTWaiterResultCompleted,@"%@; %@",description,self.engine.receipt);
    XCTAssertNotNil(axs_cachekeeper_image_cache_projection(self.engine.receipt));
}
- (NSData *)axs_cachekeeper_payload {return [@"owned image-cache fixture" dataUsingEncoding:NSUTF8StringEncoding];}
- (void)testDiscoveryReceiptContainsCompleteContractWithoutOwnerClaims {
    NSDictionary *check=self.engine.receipt[@"discoveryCheck"];
    XCTAssertNotNil(axs_cachekeeper_image_discovery_projection(check));
    XCTAssertEqualObjects(check[@"stage"],@"complete");
    XCTAssertEqualObjects(check[@"classMask"],@15);
    XCTAssertEqualObjects(check[@"methodIndex"],@0);
    XCTAssertEqualObjects(check[@"failure"],@"none");
    XCTAssertEqualObjects(self.engine.receipt[@"state"],@"notObserved");
    XCTAssertEqualObjects(self.engine.receipt[@"observed"],@0);
    XCTAssertEqual(AxsCacheKeeperImageMethodCount,25);
}
- (void)testUnpinnedStaticSDKIsRejectedByProductionSourceProbe {
    AxsCacheKeeperImageCache *probe=[[AxsCacheKeeperImageCache alloc] initWithContextProvider:nil observer:nil];
    SEL selector=@selector(initWithNamespace:diskCacheDirectory:config:);
    IMP before=class_getMethodImplementation(SDImageCache.class,selector);
    NSDictionary *check=[probe discoveryDiagnosticsForIntegrationTests];
    XCTAssertNotNil(axs_cachekeeper_image_discovery_projection(check));
    XCTAssertEqualObjects(check[@"classMask"],@15);
    XCTAssertEqualObjects(check[@"stage"],@"source");
    XCTAssertEqualObjects(check[@"source"],@"rejected");
    XCTAssertEqualObjects(check[@"failure"],@"unknownSource");
    XCTAssertEqualObjects(check[@"methodIndex"],@0);
    XCTAssertEqual(class_getMethodImplementation(SDImageCache.class,selector),before);
}
- (void)testMethodProbeDistinguishesMissingInheritedAndReturnTypes {
    XCTAssertEqualObjects([self.engine methodDiagnosticsForIntegrationTests:9 ownerClass:SDDiskCache.class][@"failure"],@"none");
    XCTAssertEqualObjects([self.engine methodDiagnosticsForIntegrationTests:9 ownerClass:NSObject.class][@"failure"],@"missingMethod");
    XCTAssertEqualObjects([self.engine methodDiagnosticsForIntegrationTests:9 ownerClass:AxsCacheKeeperImageTestCustomDisk.class][@"failure"],@"inheritedMethod");
    XCTAssertEqualObjects([self.engine methodDiagnosticsForIntegrationTests:9 ownerClass:AxsCacheKeeperImageTestWrongReturn.class][@"failure"],@"returnType");
}
- (void)testMethodProbeDistinguishesArgumentCountTypeAndForeignImplementation {
    SEL copySelector=@selector(copyWithZone:);
    XCTAssertTrue(class_addMethod(AxsCacheKeeperImageTestWrongCount.class,copySelector,(IMP)AxsCacheKeeperImageTestMetadataOnlyMethod,"@16@0:8"));
    XCTAssertTrue(class_addMethod(AxsCacheKeeperImageTestWrongArgument.class,copySelector,(IMP)AxsCacheKeeperImageTestMetadataOnlyMethod,"@24@0:8@16"));
    XCTAssertEqualObjects([self.engine methodDiagnosticsForIntegrationTests:14 ownerClass:AxsCacheKeeperImageTestWrongCount.class][@"failure"],@"argumentCount");
    XCTAssertEqualObjects([self.engine methodDiagnosticsForIntegrationTests:14 ownerClass:AxsCacheKeeperImageTestWrongArgument.class][@"failure"],@"argumentType");
    Method method=class_getInstanceMethod(AxsCacheKeeperImageTestForeignMethod.class,@selector(fileManager));
    IMP original=method_setImplementation(method,class_getMethodImplementation(NSObject.class,@selector(description)));
    @try {
        XCTAssertEqualObjects([self.engine methodDiagnosticsForIntegrationTests:9 ownerClass:AxsCacheKeeperImageTestForeignMethod.class][@"failure"],@"methodImage");
    } @finally { method_setImplementation(method,original); }
}
- (void)testDiscoveryChangesPublishWithoutLifecycleAndRecoverWhenMethodRestored {
    Method method=class_getInstanceMethod(SDDiskCache.class,@selector(fileManager));
    IMP original=method_setImplementation(method,(IMP)AxsCacheKeeperImageTestChangedGetter);
    @try {
        [self.engine requestDiscoveryRefresh];
        [self axs_cachekeeper_wait:^BOOL(NSDictionary *receipt) {
            return [receipt[@"discoveryCheck"][@"failure"] isEqual:@"methodsChanged"];
        } description:@"runtime method change published without lifecycle"];
        NSDictionary *check=self.engine.receipt[@"discoveryCheck"];
        XCTAssertNotNil(axs_cachekeeper_image_discovery_projection(check));
        XCTAssertEqualObjects(check[@"stage"],@"method");
        XCTAssertEqualObjects(check[@"methodIndex"],@9);
        XCTAssertEqualObjects(self.engine.receipt[@"state"],@"unsupported");
    } @finally {
        method_setImplementation(method,original);
        [self.engine requestDiscoveryRefresh];
        [self axs_cachekeeper_wait:^BOOL(NSDictionary *receipt) {
            return [receipt[@"discoveryCheck"][@"stage"] isEqual:@"complete"];
        } description:@"restored method is rediscovered"];
    }
    XCTAssertEqualObjects(self.engine.receipt[@"state"],@"notObserved");
}
- (void)testRepeatedUnchangedDiscoveryDoesNotReadInstallationAgain {
    NSUInteger before=self.contextReads;
    for (NSUInteger i=0;i<64;i++) [self.engine requestDiscoveryRefresh];
    // This final explicit refresh is the queue barrier and accounts for one provider read.
    [self axs_cachekeeper_refresh];
    XCTAssertEqual(self.contextReads,before+1);
    XCTAssertEqualObjects(self.engine.receipt[@"discoveryCheck"][@"stage"],@"complete");
}
- (void)testDiscoveryMethodChangeRevokesRestrictionUntilOriginalReturns {
    SDImageCache *owner=[self axs_cachekeeper_owner:@"discovery-restoration" config:nil];
    [self axs_cachekeeper_state:@{@"enabled":@YES,@"mode":@"auto"}];
    XCTAssertEqual([self.engine.receipt[@"restricted"] unsignedIntegerValue],1u);
    Method method=class_getInstanceMethod(SDDiskCache.class,@selector(fileManager));
    IMP original=method_getImplementation(method);
    // The foreign IMP preserves the SDK getter's behavior. Any write suppression here is
    // therefore the adapter's gate, not a broken test implementation of the SDK backend.
    IMP replacement=imp_implementationWithBlock(^id(id receiver) {
        return ((id (*)(id,SEL))original)(receiver,@selector(fileManager));
    });
    XCTAssertNotEqual(replacement,(IMP)NULL);if (!replacement) return;
    method_setImplementation(method,replacement);
    @try {
        [self.engine requestDiscoveryRefresh];
        [self axs_cachekeeper_wait:^BOOL(NSDictionary *receipt) {
            return [receipt[@"discoveryCheck"][@"failure"] isEqual:@"methodsChanged"];
        } description:@"changed SDK contract revokes the observed owner's gate"];
        XCTAssertEqual([self.engine.receipt[@"restricted"] unsignedIntegerValue],0u);
        XCTAssertEqual([self.engine.receipt[@"eligible"] unsignedIntegerValue],0u);
        [owner storeImageDataToDisk:[self axs_cachekeeper_payload] forKey:@"allowed-while-changed"];
        XCTAssertNotNil([owner diskImageDataForKey:@"allowed-while-changed"]);
    } @finally {
        method_setImplementation(method,original);XCTAssertTrue(imp_removeBlock(replacement));
        [self.engine requestDiscoveryRefresh];
        [self axs_cachekeeper_wait:^BOOL(NSDictionary *receipt) {
            return [receipt[@"discoveryCheck"][@"stage"] isEqual:@"complete"] && [receipt[@"restricted"] unsignedIntegerValue]==1;
        } description:@"restored SDK contract rechecks the owner and resumes restriction"];
    }
    [owner storeImageDataToDisk:[self axs_cachekeeper_payload] forKey:@"blocked-after-restoration"];
    XCTAssertNil([owner diskImageDataForKey:@"blocked-after-restoration"]);
    XCTAssertNotNil([owner diskImageDataForKey:@"allowed-while-changed"]);
}

- (void)testFirstSDKMethodRejectionFreezesAndSurvivesRestore {
    SDImageCacheConfig *config=[SDImageCacheConfig new];config.shouldRemoveExpiredDataWhenEnterBackground=NO;config.shouldRemoveExpiredDataWhenTerminate=NO;
    Method getter=class_getInstanceMethod(SDImageCache.class,@selector(diskCache));IMP original=method_getImplementation(getter);
    IMP foreign=imp_implementationWithBlock(^id(id receiver) {return ((id (*)(id,SEL))original)(receiver,@selector(diskCache));});
    method_setImplementation(getter,foreign);NSDictionary *frozen=nil;
    @try {
        SDImageCache *first=[[SDImageCache alloc] initWithNamespace:@"gate-first" diskCacheDirectory:[self.home stringByAppendingPathComponent:@"Library/Caches"] config:config];
        XCTAssertNotNil(first);[self.owners addObject:first];
        [self axs_cachekeeper_wait:^BOOL(NSDictionary *r) {return [r[@"instanceAdmission"][@"unregisteredReasons"][@"sdkMethodsChanged"] isEqual:@1];} description:@"first hook rejection published"];
        frozen=self.engine.receipt[@"sdkMethodsRejectionObservation"];
        XCTAssertEqualObjects(frozen[@"state"],@"recorded");XCTAssertEqualObjects(frozen[@"initializerOrdinal"],@1);
        XCTAssertEqualObjects(frozen[@"check"][@"cause"],@"implementation");XCTAssertEqualObjects(frozen[@"check"][@"methodIndex"],@2);
        XCTAssertEqualObjects(frozen[@"check"][@"classRawMatchesStored"],@NO);
        XCTAssertEqualObjects(self.engine.receipt[@"instanceAdmission"][@"registered"],@0);
    } @finally {method_setImplementation(getter,original);XCTAssertTrue(imp_removeBlock(foreign));}
    [self axs_cachekeeper_owner:@"gate-restored" config:nil];
    XCTAssertEqualObjects(self.engine.receipt[@"sdkMethodsRejectionObservation"],frozen,@"recovery must not replace historical first failure");
    XCTAssertEqualObjects(self.engine.receipt[@"instanceAdmission"][@"registered"],@1);
}

- (void)testStandardMemoryKVOConfigurationIsAdmittedButCustomConfigurationIsNot {
    SDImageCache *standard=[self axs_cachekeeper_owner:@"standard-kvo" config:nil];
    XCTAssertNotEqual(object_getClass(standard.config),SDImageCacheConfig.class);
    XCTAssertEqual(class_getSuperclass(object_getClass(standard.config)),SDImageCacheConfig.class);
    XCTAssertEqual([standard.config class],SDImageCacheConfig.class);
    XCTAssertEqualObjects([self.engine instanceDiagnosticsForIntegrationTests:standard][@"configKind"],@"standardKVO");
    standard.config.maxMemoryCost=4096;standard.config.maxMemoryCount=17;
    XCTAssertEqual(((SDMemoryCache *)standard.memoryCache).totalCostLimit,4096u);
    XCTAssertEqual(((SDMemoryCache *)standard.memoryCache).countLimit,17u);
    [self axs_cachekeeper_refresh];XCTAssertEqual([self.engine.receipt[@"eligible"] unsignedIntegerValue],1u);
    SDImageCache *custom=[self axs_cachekeeper_owner:@"custom-config" config:[AxsCacheKeeperImageTestCustomConfig new]];
    XCTAssertEqualObjects([self.engine instanceDiagnosticsForIntegrationTests:custom][@"initialReason"],@"configurationClass");
    XCTAssertEqualObjects(self.engine.receipt[@"instanceAdmission"][@"liveReasons"][@"configurationClass"],@1);
    XCTAssertEqual([self.engine.receipt[@"eligible"] unsignedIntegerValue],1u);
    [self axs_cachekeeper_state:@{@"enabled":@YES,@"mode":@"auto"}];
    [custom storeImageDataToDisk:[self axs_cachekeeper_payload] forKey:@"custom-kept"];
    XCTAssertNotNil([custom diskImageDataForKey:@"custom-kept"]);
    [self.engine didEnterBackgroundWithTime:YES];
    [self axs_cachekeeper_wait:^BOOL(NSDictionary *r) {return [r[@"apiCompleted"] unsignedIntegerValue]==1 && ![r[@"pending"] unsignedIntegerValue];} description:@"only standard KVO owner cleared"];
    XCTAssertNotNil([custom diskImageDataForKey:@"custom-kept"]);
}
- (void)testCustomMemoryBackendCannotDisguiseAConcurrentQueue {
    SDImageCacheConfig *config=[SDImageCacheConfig new];
    config.ioQueueAttributes=DISPATCH_QUEUE_CONCURRENT;config.memoryCacheClass=AxsCacheKeeperImageTestMutatingMemory.class;
    SDImageCache *owner=[self axs_cachekeeper_owner:@"mutating-memory" config:config];
    XCTAssertNil(owner.config.ioQueueAttributes,@"custom memory initializer altered only the config after queue creation");
    dispatch_semaphore_t entered=dispatch_semaphore_create(0),release=dispatch_semaphore_create(0),second=dispatch_semaphore_create(0);
    dispatch_async(owner.ioQueue,^{dispatch_semaphore_signal(entered);dispatch_semaphore_wait(release,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC));});
    XCTAssertEqual(dispatch_semaphore_wait(entered,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)),0L);
    dispatch_async(owner.ioQueue,^{dispatch_semaphore_signal(second);});
    long concurrent=dispatch_semaphore_wait(second,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC));
    dispatch_semaphore_signal(release);XCTAssertEqual(concurrent,0L,@"the actual SDK queue stayed concurrent");
    XCTAssertEqualObjects([self.engine instanceDiagnosticsForIntegrationTests:owner][@"initialReason"],@"memoryBackend");
    SDImageCacheConfig *substituting=[SDImageCacheConfig new];
    substituting.ioQueueAttributes=DISPATCH_QUEUE_CONCURRENT;substituting.memoryCacheClass=AxsCacheKeeperImageTestSubstitutingMemory.class;
    SDImageCache *substitute=[self axs_cachekeeper_owner:@"substituting-memory" config:substituting];
    XCTAssertEqual(object_getClass(substitute.memoryCache),SDMemoryCache.class);
    XCTAssertEqual(substitute.config.memoryCacheClass,SDMemoryCache.class);XCTAssertNil(substitute.config.ioQueueAttributes);
    XCTAssertEqualObjects([self.engine instanceDiagnosticsForIntegrationTests:substitute][@"initialReason"],@"memoryBackend");
    XCTAssertEqualObjects(self.engine.receipt[@"instanceAdmission"][@"liveReasons"][@"memoryBackend"],@2);
    [self axs_cachekeeper_state:@{@"enabled":@YES,@"mode":@"auto"}];
    XCTAssertEqual([self.engine.receipt[@"eligible"] unsignedIntegerValue],0u);
    XCTAssertEqual([self.engine.receipt[@"restricted"] unsignedIntegerValue],0u);
    [owner storeImageDataToDisk:[self axs_cachekeeper_payload] forKey:@"ordinary"];
    [substitute storeImageDataToDisk:[self axs_cachekeeper_payload] forKey:@"substitute-ordinary"];
    [self.engine didEnterBackgroundWithTime:YES];[self axs_cachekeeper_refresh];
    XCTAssertNotNil([owner diskImageDataForKey:@"ordinary"]);
    XCTAssertNotNil([substitute diskImageDataForKey:@"substitute-ordinary"]);
    XCTAssertEqual([self.engine.receipt[@"submitted"] unsignedIntegerValue],0u);
}
- (void)testFirstSDKWriteAdmitsALazyRootAndKeepsTheFirstPayload {
    SDImageCacheConfig *config=[SDImageCacheConfig new];
    config.shouldRemoveExpiredDataWhenEnterBackground=NO;config.shouldRemoveExpiredDataWhenTerminate=NO;
    SDImageCache *owner=[[SDImageCache alloc] initWithNamespace:@"lazy-root" diskCacheDirectory:[self.home stringByAppendingPathComponent:@"Library/Caches"] config:config];
    [self.owners addObject:owner];[self axs_cachekeeper_refresh];
    XCTAssertEqualObjects([self.engine instanceDiagnosticsForIntegrationTests:owner][@"currentReason"],@"none");
    BOOL rootExists=[NSFileManager.defaultManager fileExistsAtPath:owner.diskCachePath];
    XCTAssertEqual([self.engine.receipt[@"eligible"] unsignedIntegerValue],rootExists ? 1u : 0u);
    if (!rootExists) XCTAssertEqualObjects(self.engine.receipt[@"reason"],@"pathChanged");
    [owner storeImageDataToDisk:[self axs_cachekeeper_payload] forKey:@"first-write"];
    // No explicit refresh: the real write must schedule discovery of a 5.15.5 lazy root.
    [self axs_cachekeeper_wait:^BOOL(NSDictionary *r) {return [r[@"eligible"] unsignedIntegerValue]==1;} description:@"actual SDK root creation observed"];
    [self axs_cachekeeper_state:@{@"enabled":@YES,@"mode":@"auto"}];
    XCTAssertNotNil([owner diskImageDataForKey:@"first-write"]);
    XCTAssertEqual([self.engine.receipt[@"writesBlocked"] unsignedIntegerValue],0u);
    [owner storeImageDataToDisk:[self axs_cachekeeper_payload] forKey:@"later-write"];
    XCTAssertNil([owner diskImageDataForKey:@"later-write"]);
    [self axs_cachekeeper_refresh];XCTAssertEqual([self.engine.receipt[@"writesBlocked"] unsignedIntegerValue],1u);
}
- (void)testUnboundOwnersRequestAtMostOneWriteDrivenRefresh {
    [self axs_cachekeeper_state:@{@"enabled":@YES,@"mode":@"clean",@"excludedPaths":@[@"Library/Caches"]}];
    SDImageCache *first=[self axs_cachekeeper_owner:@"excluded-overlap" config:nil];
    XCTAssertEqualObjects(self.engine.receipt[@"reason"],@"scopeNotAuthorized");
    NSUInteger before=self.contextReads;
    for (NSUInteger i=0;i<5;i++) [first storeImageDataToDisk:[self axs_cachekeeper_payload] forKey:@"kept-excluded"];
    [self axs_cachekeeper_refresh];
    XCTAssertGreaterThanOrEqual(self.contextReads,before+1);
    XCTAssertLessThanOrEqual(self.contextReads,before+2,@"one initial SDK write may schedule one probe; never one per write");
    before=self.contextReads;
    for (NSUInteger i=0;i<5;i++) [first storeImageDataToDisk:[self axs_cachekeeper_payload] forKey:@"kept-excluded"];
    [self axs_cachekeeper_refresh];
    XCTAssertEqual(self.contextReads,before+1,@"later writes to an unbound scope must not poll configuration");
    XCTAssertNotNil([first diskImageDataForKey:@"kept-excluded"]);
    SDImageCache *second=[self axs_cachekeeper_owner:@"excluded-overlap" config:nil];
    [self axs_cachekeeper_state:@{@"enabled":@YES,@"mode":@"clean"}];
    XCTAssertEqualObjects(self.engine.receipt[@"reason"],@"overlappingOwners");
    before=self.contextReads;
    for (NSUInteger i=0;i<5;i++) [second storeImageDataToDisk:[self axs_cachekeeper_payload] forKey:@"kept-overlap"];
    [self axs_cachekeeper_refresh];
    XCTAssertLessThanOrEqual(self.contextReads,before+2);
    before=self.contextReads;
    for (NSUInteger i=0;i<5;i++) [second storeImageDataToDisk:[self axs_cachekeeper_payload] forKey:@"kept-overlap"];
    [self axs_cachekeeper_refresh];
    XCTAssertEqual(self.contextReads,before+1,@"unbound overlapping owners must not poll configuration on writes");
    XCTAssertNotNil([second diskImageDataForKey:@"kept-overlap"]);
    XCTAssertEqual([self.engine.receipt[@"eligible"] unsignedIntegerValue],0u);
    XCTAssertEqual([self.engine.receipt[@"submitted"] unsignedIntegerValue],0u);
}
- (void)testActualSDWebImageDiskRestrictionPreservesMemoryAndRestoresOnDisable {
    SDImageCache *owner=[self axs_cachekeeper_owner:@"normal" config:nil];
    XCTAssertEqual([self.engine.receipt[@"eligible"] unsignedIntegerValue],1u);
    NSData *payload=[self axs_cachekeeper_payload];
    [owner storeImageDataToDisk:payload forKey:@"seed.png"];
    XCTAssertEqualObjects([owner diskImageDataForKey:@"seed.png"],payload);
    dispatch_sync(owner.ioQueue,^{[owner.diskCache setExtendedData:payload forKey:@"seed.png"];});
    [self axs_cachekeeper_state:@{@"enabled":@YES,@"mode":@"auto"}];
    __block NSData *removedMetadata=nil;
    dispatch_sync(owner.ioQueue,^{[owner.diskCache setExtendedData:nil forKey:@"seed.png"];removedMetadata=[owner.diskCache extendedDataForKey:@"seed.png"];});
    XCTAssertNil(removedMetadata,@"restriction must preserve APP metadata removal");
    UIImage *image=[[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(2,2)] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [UIColor.redColor setFill];[context fillRect:CGRectMake(0,0,2,2)];
    }];
    XCTestExpectation *stored=[self expectationWithDescription:@"original SDK completion"];
    __block NSUInteger callbacks=0;
    [owner storeImage:image imageData:payload forKey:@"blocked.png" toDisk:YES completion:^{
        callbacks++;XCTAssertTrue(NSThread.isMainThread);[stored fulfill];
    }];
    [self waitForExpectations:@[stored] timeout:5];
    XCTAssertEqual(callbacks,1u);XCTAssertNotNil([owner imageFromMemoryCacheForKey:@"blocked.png"]);
    XCTAssertNil([owner diskImageDataForKey:@"blocked.png"]);
    dispatch_sync(owner.ioQueue,^{[owner.diskCache setExtendedData:payload forKey:@"seed.png"];});
    __block NSData *extended=nil;dispatch_sync(owner.ioQueue,^{extended=[owner.diskCache extendedDataForKey:@"seed.png"];});
    XCTAssertNil(extended);
    [self axs_cachekeeper_refresh];XCTAssertGreaterThanOrEqual([self.engine.receipt[@"writesBlocked"] unsignedIntegerValue],2u);
    [self axs_cachekeeper_state:@{@"enabled":@NO,@"mode":@"auto"}];
    [owner storeImageDataToDisk:payload forKey:@"restored.png"];
    XCTAssertEqualObjects([owner diskImageDataForKey:@"restored.png"],payload);
    dispatch_sync(owner.ioQueue,^{[owner.diskCache setExtendedData:payload forKey:@"seed.png"];extended=[owner.diskCache extendedDataForKey:@"seed.png"];});
    XCTAssertEqualObjects(extended,payload);
}
- (void)testActualCleanupUsesOwnerQueueAndLeavesMemoryReadable {
    SDImageCache *first=[self axs_cachekeeper_owner:@"first" config:nil],*second=[self axs_cachekeeper_owner:@"second" config:nil];
    NSData *payload=[self axs_cachekeeper_payload];
    [first storeImageDataToDisk:payload forKey:@"one"];[second storeImageDataToDisk:payload forKey:@"two"];
    UIImage *image=[UIImage new];[first storeImageToMemory:image forKey:@"memory"];
    [self.engine didEnterBackgroundWithTime:YES];
    [self axs_cachekeeper_wait:^BOOL(NSDictionary *r) {return [r[@"apiCompleted"] unsignedIntegerValue]==2 && ![r[@"pending"] unsignedIntegerValue];} description:@"two real SDK clears"];
    NSDictionary *history=self.engine.receipt[@"operationHistory"];
    XCTAssertNotNil(axs_cachekeeper_operation_history_validate(history,@"image"));
    NSArray *actions=[history[@"processes"] lastObject][@"actions"];
    XCTAssertEqual(actions.count,2u);
    XCTAssertNotEqualObjects(actions[0][@"ownerID"],actions[1][@"ownerID"]);
    XCTAssertEqualObjects(actions[0][@"eventID"],actions[1][@"eventID"]);
    for (NSDictionary *action in actions) {
        XCTAssertEqualObjects(action[@"state"],@"apiCompleted");
        NSDictionary *effect=action[@"cacheEffect"];
        XCTAssertEqualObjects(effect[@"result"],@"empty");
        XCTAssertEqualObjects(effect[@"before"][@"files"],@1);
        XCTAssertEqualObjects(effect[@"before"][@"logicalBytes"],@(payload.length));
        XCTAssertEqualObjects(effect[@"after"][@"files"],@0);
        XCTAssertEqualObjects(effect[@"after"][@"allocatedBytes"],@0);
        XCTAssertEqualObjects(effect[@"physicalRelease"],@"notMeasured");
    }
    XCTAssertNil([first diskImageDataForKey:@"one"]);XCTAssertNil([second diskImageDataForKey:@"two"]);
    XCTAssertEqual([first imageFromMemoryCacheForKey:@"memory"],image);
    XCTAssertEqualObjects(self.engine.receipt[@"bytesState"],@"notMeasured");
    // SDK clear recreates its root. A second round must use the new verified root identity.
    [first storeImageDataToDisk:payload forKey:@"again"];
    [self.engine didEnterBackgroundWithTime:YES];
    [self axs_cachekeeper_wait:^BOOL(NSDictionary *r) {return [r[@"apiCompleted"] unsignedIntegerValue]==4 && ![r[@"pending"] unsignedIntegerValue];} description:@"repeat clear after SDK root recreation"];
    NSArray *repeated=[self.engine.receipt[@"operationHistory"][@"processes"] lastObject][@"actions"];
    XCTAssertEqual(repeated.count,4u);
    XCTAssertNotEqualObjects(repeated[0][@"eventID"],repeated[2][@"eventID"]);
    for (NSDictionary *action in [repeated subarrayWithRange:NSMakeRange(2,2)]) XCTAssertEqualObjects(action[@"cacheEffect"][@"result"],@"empty");
    XCTAssertNil([first diskImageDataForKey:@"again"]);
}
- (void)testUnchangedImageLoadDuringBackgroundContextReadDoesNotCancelCleanup {
    SDImageCache *owner=[self axs_cachekeeper_owner:@"discovery-background-barrier" config:nil];
    NSData *payload=[self axs_cachekeeper_payload];[owner storeImageDataToDisk:payload forKey:@"remove"];
    dispatch_semaphore_t entered=dispatch_semaphore_create(0),release=dispatch_semaphore_create(0);
    __block BOOL first=YES;
    self.contextBarrier=^{if (first) {first=NO;dispatch_semaphore_signal(entered);dispatch_semaphore_wait(release,dispatch_time(DISPATCH_TIME_NOW,8*NSEC_PER_SEC));}};
    [self.engine didEnterBackgroundWithTime:YES];
    XCTAssertEqual(dispatch_semaphore_wait(entered,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)),0L);
    [self.engine requestDiscoveryRefresh];dispatch_semaphore_signal(release);
    [self axs_cachekeeper_wait:^BOOL(NSDictionary *r){return [r[@"apiCompleted"] unsignedIntegerValue]==1 && ![r[@"pending"] unsignedIntegerValue];} description:@"unchanged discovery preserves background action"];
    XCTAssertNil([owner diskImageDataForKey:@"remove"]);
    NSDictionary *process=[self.engine.receipt[@"operationHistory"][@"processes"] lastObject];
    NSArray *actions=process[@"actions"];XCTAssertEqual(actions.count,1u);
    XCTAssertGreaterThan([actions[0][@"actionID"] unsignedIntegerValue],0u);
    for (NSDictionary *event in process[@"events"]) if ([event[@"eventID"] isEqual:actions[0][@"eventID"]]) XCTAssertEqualObjects(event[@"trigger"],@"background");
    XCTAssertNotEqualObjects(self.engine.receipt[@"state"],@"queued");
}
- (void)testImageLoadAtRefreshPublicationRetainsOriginalChildIdentity {
    SDImageCache *owner=[self axs_cachekeeper_owner:@"discovery-action-boundary" config:nil];
    [owner storeImageDataToDisk:[self axs_cachekeeper_payload] forKey:@"remove"];
    __weak typeof(self) weakSelf=self;__block BOOL injected=NO;
    [self.engine setObserver:^(NSDictionary *receipt){
        NSDictionary *event=[[[receipt[@"operationHistory"] objectForKey:@"processes"] lastObject][@"events"] lastObject];
        if (!injected && [event[@"trigger"] isEqual:@"background"] && [event[@"refresh"] isEqual:@"applied"] && ![receipt[@"queued"] unsignedIntegerValue]) {
            injected=YES;[weakSelf.engine requestDiscoveryRefresh];
        }
    }];
    [self.engine didEnterBackgroundWithTime:YES];
    [self axs_cachekeeper_wait:^BOOL(NSDictionary *r){return [r[@"apiCompleted"] unsignedIntegerValue]==1 && ![r[@"pending"] unsignedIntegerValue];} description:@"refresh-publication image load keeps child identity"];
    XCTAssertTrue(injected);
    NSArray *actions=[self.engine.receipt[@"operationHistory"][@"processes"] lastObject][@"actions"];
    XCTAssertEqual(actions.count,1u);XCTAssertGreaterThan([actions[0][@"actionID"] unsignedIntegerValue],0u);
    XCTAssertEqualObjects(actions[0][@"state"],@"apiCompleted");XCTAssertNotEqualObjects(self.engine.receipt[@"state"],@"queued");
}
- (void)testConfigurationAtFirstQueuedPublicationKeepsSkippedOriginalAction {
    SDImageCache *owner=[self axs_cachekeeper_owner:@"configuration-action-boundary" config:nil];
    NSData *payload=[self axs_cachekeeper_payload];[owner storeImageDataToDisk:payload forKey:@"keep"];
    __weak typeof(self) weakSelf=self;__block BOOL injected=NO;
    [self.engine setObserver:^(NSDictionary *receipt){
        if (!injected && [receipt[@"queued"] unsignedIntegerValue]==1) {
            injected=YES;ImageCacheIntegrationTests *test=weakSelf;
            @synchronized(test) {test.context[@"appState"]=@{@"enabled":@NO};}
            [test.engine refreshWithCompletion:nil];
        }
    }];
    [self.engine didEnterBackgroundWithTime:YES];
    [self axs_cachekeeper_wait:^BOOL(NSDictionary *r){return [r[@"skipped"] unsignedIntegerValue]==1 && ![r[@"pending"] unsignedIntegerValue];} description:@"configuration preserves bound skipped action"];
    NSArray *actions=[self.engine.receipt[@"operationHistory"][@"processes"] lastObject][@"actions"];
    XCTAssertTrue(injected);XCTAssertEqual(actions.count,1u);XCTAssertGreaterThan([actions[0][@"actionID"] unsignedIntegerValue],0u);
    XCTAssertEqualObjects(actions[0][@"state"],@"skipped");XCTAssertEqualObjects(actions[0][@"reason"],@"appDisabled");
    XCTAssertEqualObjects([owner diskImageDataForKey:@"keep"],payload);XCTAssertEqual([self.engine.receipt[@"submitted"] unsignedIntegerValue],0u);
}
- (void)testQueuedCleanupRechecksDisableAndDoesNotClear {
    SDImageCache *owner=[self axs_cachekeeper_owner:@"queued-disable" config:nil];NSData *payload=[self axs_cachekeeper_payload];
    [owner storeImageDataToDisk:payload forKey:@"keep"];
    dispatch_semaphore_t entered=dispatch_semaphore_create(0),release=dispatch_semaphore_create(0);
    dispatch_async(owner.ioQueue,^{dispatch_semaphore_signal(entered);dispatch_semaphore_wait(release,dispatch_time(DISPATCH_TIME_NOW,8*NSEC_PER_SEC));});
    XCTAssertEqual(dispatch_semaphore_wait(entered,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)),0L);
    [self.engine didEnterBackgroundWithTime:YES];
    [self axs_cachekeeper_wait:^BOOL(NSDictionary *r) {return [r[@"pending"] unsignedIntegerValue]==1;} description:@"SDK queue actually blocked"];
    [self axs_cachekeeper_state:@{@"enabled":@NO}];dispatch_semaphore_signal(release);
    [self axs_cachekeeper_wait:^BOOL(NSDictionary *r) {return [r[@"skipped"] unsignedIntegerValue]==1 && ![r[@"pending"] unsignedIntegerValue];} description:@"disabled queued action cancelled"];
    NSDictionary *cancelled=[[self.engine.receipt[@"operationHistory"][@"processes"] lastObject][@"actions"] lastObject];
    XCTAssertEqualObjects(cancelled[@"state"],@"skipped");
    XCTAssertEqualObjects(cancelled[@"reason"],@"appDisabled");
    XCTAssertEqualObjects(self.engine.receipt[@"state"],@"disabled");
    XCTAssertEqual([self.engine.receipt[@"submitted"] unsignedIntegerValue],0u);
    XCTAssertEqualObjects([owner diskImageDataForKey:@"keep"],payload);
}
- (void)testQueuedCleanupRechecksNewChildExclusion {
    SDImageCache *owner=[self axs_cachekeeper_owner:@"queued-exclusion" config:nil];NSData *payload=[self axs_cachekeeper_payload];
    [owner storeImageDataToDisk:payload forKey:@"keep"];
    dispatch_semaphore_t release=dispatch_semaphore_create(0);
    dispatch_async(owner.ioQueue,^{dispatch_semaphore_wait(release,dispatch_time(DISPATCH_TIME_NOW,8*NSEC_PER_SEC));});
    [self.engine didEnterBackgroundWithTime:YES];
    [self axs_cachekeeper_wait:^BOOL(NSDictionary *r) {return [r[@"pending"] unsignedIntegerValue]==1;} description:@"queued before exclusion"];
    // No explicit engine refresh: the SDK-queue execution gate must read the changed file snapshot.
    @synchronized(self) {self.context[@"appState"]=@{@"enabled":@YES,@"mode":@"clean",@"excludedPaths":@[@"Library/Caches/queued-exclusion/retained"]};}
    dispatch_semaphore_signal(release);
    [self axs_cachekeeper_wait:^BOOL(NSDictionary *r) {return [r[@"skipped"] unsignedIntegerValue]==1;} description:@"latest child exclusion prevents whole-owner clear"];
    NSDictionary *excluded=[[self.engine.receipt[@"operationHistory"][@"processes"] lastObject][@"actions"] lastObject];
    XCTAssertEqualObjects(excluded[@"state"],@"skipped");
    XCTAssertEqualObjects(excluded[@"reason"],@"scopeNotAuthorized");
    XCTAssertEqualObjects([owner diskImageDataForKey:@"keep"],payload);XCTAssertEqual([self.engine.receipt[@"submitted"] unsignedIntegerValue],0u);
}
- (void)testOnlyCleanModeAllowsWritesAndManualSelectionIsRequiredWhenDiscoveryIsOff {
    SDImageCache *owner=[self axs_cachekeeper_owner:@"selected" config:nil];NSData *payload=[self axs_cachekeeper_payload];
    [self axs_cachekeeper_state:@{@"enabled":@YES,@"mode":@"prevent",@"autoDiscover":@NO}];
    XCTAssertEqual([self.engine.receipt[@"eligible"] unsignedIntegerValue],0u);
    [owner storeImageDataToDisk:payload forKey:@"unselected"];XCTAssertNotNil([owner diskImageDataForKey:@"unselected"]);
    @synchronized(self) {self.context[@"selected"]=@[@"Library/Caches/selected"];}
    [self axs_cachekeeper_refresh];XCTAssertEqual([self.engine.receipt[@"restricted"] unsignedIntegerValue],1u);
    [owner storeImageDataToDisk:payload forKey:@"prevented"];XCTAssertNil([owner diskImageDataForKey:@"prevented"]);
    [self axs_cachekeeper_state:@{@"enabled":@YES,@"mode":@"clean",@"autoDiscover":@NO}];
    [owner storeImageDataToDisk:payload forKey:@"clean-only"];XCTAssertNotNil([owner diskImageDataForKey:@"clean-only"]);
}
- (void)testConcurrentQueueCannotBecomeEligibleByLaterChangingConfiguration {
    SDImageCacheConfig *config=[SDImageCacheConfig new];config.ioQueueAttributes=DISPATCH_QUEUE_CONCURRENT;
    SDImageCache *owner=[self axs_cachekeeper_owner:@"concurrent" config:config];
    owner.config.ioQueueAttributes=nil;[self axs_cachekeeper_refresh];
    XCTAssertEqualObjects(self.engine.receipt[@"instanceAdmission"][@"liveReasons"][@"initialQueueAttributes"],@1);
    XCTAssertEqual([self.engine.receipt[@"eligible"] unsignedIntegerValue],0u);
    [self axs_cachekeeper_state:@{@"enabled":@YES,@"mode":@"auto"}];
    [owner storeImageDataToDisk:[self axs_cachekeeper_payload] forKey:@"ordinary"];XCTAssertNotNil([owner diskImageDataForKey:@"ordinary"]);
}
- (void)testDefaultSerialAndNullSerialWorkButCustomBackendAndFileManagerDoNot {
    SDImageCacheConfig *serial=[SDImageCacheConfig new];serial.ioQueueAttributes=nil;
    [self axs_cachekeeper_owner:@"null-serial" config:serial];
    [self axs_cachekeeper_owner:@"default-serial" config:nil];
    SDImageCacheConfig *custom=[SDImageCacheConfig new];custom.diskCacheClass=AxsCacheKeeperImageTestCustomDisk.class;
    [self axs_cachekeeper_owner:@"custom" config:custom];
    SDImageCacheConfig *fileManager=[SDImageCacheConfig new];fileManager.fileManager=[NSFileManager new];
    [self axs_cachekeeper_owner:@"manager" config:fileManager];
    XCTAssertEqual([self.engine.receipt[@"observed"] unsignedIntegerValue],4u);
    XCTAssertEqual([self.engine.receipt[@"eligible"] unsignedIntegerValue],2u);
    XCTAssertEqualObjects(self.engine.receipt[@"instanceAdmission"][@"registered"],@4);
    XCTAssertEqualObjects(self.engine.receipt[@"instanceAdmission"][@"liveReasons"][@"diskBackend"],@1);
    XCTAssertEqualObjects(self.engine.receipt[@"instanceAdmission"][@"liveReasons"][@"customFileManager"],@1);
}
- (void)testReleasedSDKOwnerRemainsDiagnosableAfterReplacement {
    __weak SDImageCache *weakOwner;
    @autoreleasepool {
        SDImageCache *owner=[self axs_cachekeeper_owner:@"released-owner" config:nil];
        weakOwner=owner;dispatch_sync(owner.ioQueue,^{});
        [self.owners removeObject:owner];owner=nil;
    }
    [self axs_cachekeeper_refresh];
    XCTAssertNil(weakOwner);
    XCTAssertEqualObjects(self.engine.receipt[@"observed"],@0);
    XCTAssertEqualObjects(self.engine.receipt[@"instanceAdmission"][@"released"],@1);
    [self axs_cachekeeper_refresh];
    XCTAssertEqualObjects(self.engine.receipt[@"instanceAdmission"][@"released"],@1);
    [self axs_cachekeeper_owner:@"replacement-owner" config:nil];
    XCTAssertEqualObjects(self.engine.receipt[@"instanceAdmission"][@"registered"],@2);
    XCTAssertEqualObjects(self.engine.receipt[@"instanceAdmission"][@"released"],@1);
    XCTAssertEqualObjects(self.engine.receipt[@"eligible"],@1);
}
- (void)testOverlappingOwnersAreRejectedAndParentAndChildExclusionsWin {
    SDImageCache *first=[self axs_cachekeeper_owner:@"overlap" config:nil];
    [self axs_cachekeeper_state:@{@"enabled":@YES,@"mode":@"auto"}];XCTAssertEqual([self.engine.receipt[@"restricted"] unsignedIntegerValue],1u);
    [self axs_cachekeeper_owner:@"overlap" config:nil];XCTAssertEqual([self.engine.receipt[@"eligible"] unsignedIntegerValue],0u);
    [first storeImageDataToDisk:[self axs_cachekeeper_payload] forKey:@"allowed-original"];XCTAssertNotNil([first diskImageDataForKey:@"allowed-original"]);
    SDImageCache *other=[self axs_cachekeeper_owner:@"separate" config:nil];(void)other;
    for (NSString *excluded in @[@"Library/Caches",@"Library/Caches/separate/child",@"Library/Caches/separate"])
        [self axs_cachekeeper_state:@{@"enabled":@YES,@"mode":@"auto",@"excludedPaths":@[excluded]}];
    XCTAssertEqual([self.engine.receipt[@"eligible"] unsignedIntegerValue],0u);
}
- (void)testUnknownSubdirectoryAndSymlinkPreventWholeOwnerCleanup {
    SDImageCache *owner=[self axs_cachekeeper_owner:@"mixed" config:nil];NSData *payload=[self axs_cachekeeper_payload];
    [owner storeImageDataToDisk:payload forKey:@"keep"];
    NSString *nested=[owner.diskCachePath stringByAppendingPathComponent:@"account-state"];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtPath:nested withIntermediateDirectories:YES attributes:nil error:nil]);
    [self.engine didEnterBackgroundWithTime:YES];
    [self axs_cachekeeper_wait:^BOOL(NSDictionary *r) {return [r[@"skipped"] unsignedIntegerValue]==1;} description:@"nested state prevents SDK whole-tree clear"];
    XCTAssertEqualObjects([owner diskImageDataForKey:@"keep"],payload);XCTAssertEqualObjects(self.engine.receipt[@"reason"],@"scopeUnverified");
    XCTAssertTrue([NSFileManager.defaultManager removeItemAtPath:nested error:nil]);
    XCTAssertTrue([NSFileManager.defaultManager createSymbolicLinkAtPath:[owner.diskCachePath stringByAppendingPathComponent:@"outside-link"] withDestinationPath:self.home error:nil]);
    [self.engine didEnterBackgroundWithTime:YES];
    [self axs_cachekeeper_wait:^BOOL(NSDictionary *r) {return [r[@"skipped"] unsignedIntegerValue]==2;} description:@"symlink prevents SDK whole-tree clear"];
    XCTAssertEqualObjects([owner diskImageDataForKey:@"keep"],payload);
}
- (void)testInstallationAndQueueDriftRestoreOriginalWrites {
    SDImageCache *owner=[self axs_cachekeeper_owner:@"drift" config:nil];
    [self axs_cachekeeper_state:@{@"enabled":@YES,@"mode":@"auto"}];
    @synchronized(self) {self.context[@"installation"]=@"replacement-install";}[self axs_cachekeeper_refresh];
    XCTAssertEqual([self.engine.receipt[@"restricted"] unsignedIntegerValue],0u);
    [owner storeImageDataToDisk:[self axs_cachekeeper_payload] forKey:@"after-install-change"];XCTAssertNotNil([owner diskImageDataForKey:@"after-install-change"]);
    owner.ioQueue=dispatch_queue_create("cachekeeper.tests.replacement-sdk-queue",DISPATCH_QUEUE_SERIAL);
    [self axs_cachekeeper_refresh];XCTAssertEqual([self.engine.receipt[@"eligible"] unsignedIntegerValue],0u);
}
- (void)testKnownRetentionAndUnavailableReportPreventCleanup {
    SDImageCache *owner=[self axs_cachekeeper_owner:@"retained" config:nil];NSData *payload=[self axs_cachekeeper_payload];[owner storeImageDataToDisk:payload forKey:@"keep"];
    AxsCacheKeeperAppRule *rule=[[AxsCacheKeeperAppRule alloc] initWithRuleID:@"test-retention" revision:@"1" appVersion:@"older-version" cleanablePaths:@[] retentionPaths:@[@"Library/Caches/retained/child"] dependencyPaths:@[]];
    [AxsCacheKeeperCleanupRules registerRule:rule forBundle:@"cachekeeper.owned.integration"];
    [self axs_cachekeeper_refresh];XCTAssertEqual([self.engine.receipt[@"eligible"] unsignedIntegerValue],0u);
    [AxsCacheKeeperCleanupRules removeAllRulesForTesting];
    @synchronized(self) {self.context[@"reportWritable"]=@NO;}[self.engine didEnterBackgroundWithTime:YES];
    [self axs_cachekeeper_wait:^BOOL(NSDictionary *r) {return [r[@"skipped"] unsignedIntegerValue]==1;} description:@"failed receipt storage blocks API"];
    XCTAssertEqualObjects([owner diskImageDataForKey:@"keep"],payload);XCTAssertEqualObjects(self.engine.receipt[@"reason"],@"reportWriteFailed");
}
- (void)testForegroundReturnCancelsQueuedCleanupWithoutCancellingTheAppsOwnClear {
    SDImageCache *owner=[self axs_cachekeeper_owner:@"foreground" config:nil];NSData *payload=[self axs_cachekeeper_payload];
    [owner storeImageDataToDisk:payload forKey:@"keep"];
    dispatch_semaphore_t release=dispatch_semaphore_create(0);
    dispatch_async(owner.ioQueue,^{dispatch_semaphore_wait(release,dispatch_time(DISPATCH_TIME_NOW,8*NSEC_PER_SEC));});
    [self.engine didEnterBackgroundWithTime:YES];
    [self axs_cachekeeper_wait:^BOOL(NSDictionary *r) {return [r[@"pending"] unsignedIntegerValue]==1;} description:@"queued before foreground"];
    [self.engine didBecomeActive];dispatch_semaphore_signal(release);
    [self axs_cachekeeper_wait:^BOOL(NSDictionary *r) {return [r[@"skipped"] unsignedIntegerValue]==1;} description:@"foreground cancels plugin queued clear"];
    XCTAssertEqualObjects([owner diskImageDataForKey:@"keep"],payload);
    XCTestExpectation *appClear=[self expectationWithDescription:@"APP original clear is never intercepted"];
    [owner clearDiskOnCompletion:^{[appClear fulfill];}];[self waitForExpectations:@[appClear] timeout:5];
    XCTAssertNil([owner diskImageDataForKey:@"keep"]);XCTAssertEqual([self.engine.receipt[@"submitted"] unsignedIntegerValue],0u);
}
- (void)testPathReplacementAndSymbolicDirectoryAreNotAdmitted {
    SDImageCache *owner=[self axs_cachekeeper_owner:@"replace" config:nil];NSData *payload=[self axs_cachekeeper_payload];
    NSString *original=owner.diskCachePath;
    NSString *old=[original stringByAppendingString:@"-old"];
    XCTAssertTrue([NSFileManager.defaultManager moveItemAtPath:original toPath:old error:nil]);
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtPath:original withIntermediateDirectories:YES attributes:nil error:nil]);
    [owner storeImageDataToDisk:payload forKey:@"replacement"];
    [self.engine didEnterBackgroundWithTime:YES];[self axs_cachekeeper_refresh];
    XCTAssertEqual([self.engine.receipt[@"eligible"] unsignedIntegerValue],0u);
    XCTAssertEqual([self.engine.receipt[@"submitted"] unsignedIntegerValue],0u);
    XCTAssertEqualObjects([owner diskImageDataForKey:@"replacement"],payload);
    NSString *link=[self.home stringByAppendingPathComponent:@"Library/Caches/link"];
    XCTAssertTrue([NSFileManager.defaultManager createSymbolicLinkAtPath:link withDestinationPath:old error:nil]);
    [self axs_cachekeeper_owner:@"link" config:nil];XCTAssertEqual([self.engine.receipt[@"eligible"] unsignedIntegerValue],0u);
}
- (void)testBackgroundExpirationDoesNotSubmitAgainWhileTheOldFlightIsQueued {
    SDImageCache *owner=[self axs_cachekeeper_owner:@"expire" config:nil];NSData *payload=[self axs_cachekeeper_payload];
    [owner storeImageDataToDisk:payload forKey:@"keep"];
    dispatch_semaphore_t release=dispatch_semaphore_create(0);
    dispatch_async(owner.ioQueue,^{dispatch_semaphore_wait(release,dispatch_time(DISPATCH_TIME_NOW,8*NSEC_PER_SEC));});
    [self.engine didEnterBackgroundWithTime:YES];
    [self axs_cachekeeper_wait:^BOOL(NSDictionary *r) {return [r[@"pending"] unsignedIntegerValue]==1;} description:@"pending before background expiry"];
    [self.engine expireBackgroundTime];[self.engine didEnterBackgroundWithTime:YES];[self axs_cachekeeper_refresh];
    XCTAssertEqual([self.engine.receipt[@"queued"] unsignedIntegerValue],1u);
    dispatch_semaphore_signal(release);
    [self axs_cachekeeper_wait:^BOOL(NSDictionary *r) {return [r[@"skipped"] unsignedIntegerValue]==1;} description:@"old flight cannot execute after expiration"];
    XCTAssertEqualObjects([owner diskImageDataForKey:@"keep"],payload);XCTAssertEqual([self.engine.receipt[@"submitted"] unsignedIntegerValue],0u);
}
- (void)testActualFifteenSecondDeadlineCancelsOnlyTheBlockedOwner {
    SDImageCache *blocked=[self axs_cachekeeper_owner:@"deadline-blocked" config:nil];
    SDImageCache *free=[self axs_cachekeeper_owner:@"deadline-free" config:nil];NSData *payload=[self axs_cachekeeper_payload];
    [blocked storeImageDataToDisk:payload forKey:@"keep"];[free storeImageDataToDisk:payload forKey:@"clear"];
    dispatch_semaphore_t release=dispatch_semaphore_create(0);
    dispatch_async(blocked.ioQueue,^{dispatch_semaphore_wait(release,dispatch_time(DISPATCH_TIME_NOW,22*NSEC_PER_SEC));});
    [self.engine didEnterBackgroundWithTime:YES];
    [self axs_cachekeeper_wait:^BOOL(NSDictionary *r) {return [r[@"apiCompleted"] unsignedIntegerValue]==1 && [r[@"pending"] unsignedIntegerValue]==1;} description:@"independent owner completed before timeout"];
    XCTestExpectation *deadline=[self expectationWithDescription:@"real production 15-second deadline"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,16*NSEC_PER_SEC),dispatch_get_main_queue(),^{[deadline fulfill];});
    [self waitForExpectations:@[deadline] timeout:20];
    XCTAssertEqualObjects(self.engine.receipt[@"state"],@"timedOut");
    XCTAssertEqual([self.engine.receipt[@"submitted"] unsignedIntegerValue],1u);
    dispatch_semaphore_signal(release);
    [self axs_cachekeeper_wait:^BOOL(NSDictionary *r) {return [r[@"skipped"] unsignedIntegerValue]==1 && ![r[@"pending"] unsignedIntegerValue];} description:@"late SDK queue must skip expired flight"];
    XCTAssertEqualObjects([blocked diskImageDataForKey:@"keep"],payload);XCTAssertNil([free diskImageDataForKey:@"clear"]);
    XCTAssertEqual([self.engine.receipt[@"submitted"] unsignedIntegerValue],1u);
}
- (void)testNewOverlappingOwnerInvalidatesAnAlreadyQueuedFlight {
    SDImageCache *owner=[self axs_cachekeeper_owner:@"new-overlap" config:nil];NSData *payload=[self axs_cachekeeper_payload];
    [owner storeImageDataToDisk:payload forKey:@"keep"];
    dispatch_semaphore_t release=dispatch_semaphore_create(0);
    dispatch_async(owner.ioQueue,^{dispatch_semaphore_wait(release,dispatch_time(DISPATCH_TIME_NOW,8*NSEC_PER_SEC));});
    [self.engine didEnterBackgroundWithTime:YES];
    [self axs_cachekeeper_wait:^BOOL(NSDictionary *r) {return [r[@"pending"] unsignedIntegerValue]==1;} description:@"queued before second owner exists"];
    [self axs_cachekeeper_owner:@"new-overlap" config:nil];
    XCTAssertEqual([self.engine.receipt[@"eligible"] unsignedIntegerValue],0u);
    dispatch_semaphore_signal(release);
    [self axs_cachekeeper_wait:^BOOL(NSDictionary *r) {return [r[@"skipped"] unsignedIntegerValue]==1;} description:@"registry change cancels old flight"];
    XCTAssertEqualObjects([owner diskImageDataForKey:@"keep"],payload);
    XCTAssertEqual([self.engine.receipt[@"submitted"] unsignedIntegerValue],0u);
}
- (void)testSystemHomeAliasAndResolvedHomeShareOneOwnerScope {
    // A system-provided home alias may differ from the URL returned to the SDK. Resolve only
    // that trusted home alias; a link within Library/Caches remains rejected by openat.
    NSString *alias=[self.home stringByAppendingPathComponent:@"system-home-alias"];
    XCTAssertTrue([NSFileManager.defaultManager createSymbolicLinkAtPath:alias withDestinationPath:self.home error:nil]);
    @synchronized(self) {self.context[@"home"]=alias;}
    [self axs_cachekeeper_refresh];
    SDImageCache *owner=[self axs_cachekeeper_owner:@"aliased" config:nil];
    XCTAssertEqual([self.engine.receipt[@"eligible"] unsignedIntegerValue],1u);
    [owner storeImageDataToDisk:[self axs_cachekeeper_payload] forKey:@"original"];
    SDImageCacheConfig *config=[SDImageCacheConfig new];config.shouldRemoveExpiredDataWhenEnterBackground=NO;config.shouldRemoveExpiredDataWhenTerminate=NO;
    SDImageCache *other=[[SDImageCache alloc] initWithNamespace:@"aliased" diskCacheDirectory:[alias stringByAppendingPathComponent:@"Library/Caches"] config:config];
    [self.owners addObject:other];[self axs_cachekeeper_refresh];
    XCTAssertEqual([self.engine.receipt[@"eligible"] unsignedIntegerValue],0u);
    XCTAssertEqualObjects([owner diskImageDataForKey:@"original"],[self axs_cachekeeper_payload]);
}
- (void)testAppsOwnClearRecreatesRootWithoutDisablingLaterRestrictionOrCleanup {
    SDImageCache *owner=[self axs_cachekeeper_owner:@"app-clear" config:nil];NSData *payload=[self axs_cachekeeper_payload];
    [owner storeImageDataToDisk:payload forKey:@"old"];
    XCTestExpectation *done=[self expectationWithDescription:@"APP actual clearDiskOnCompletion"];
    [owner clearDiskOnCompletion:^{[done fulfill];}];[self waitForExpectations:@[done] timeout:5];
    [self axs_cachekeeper_refresh];XCTAssertEqual([self.engine.receipt[@"eligible"] unsignedIntegerValue],1u);
    [owner storeImageDataToDisk:payload forKey:@"after-app-clear"];
    XCTAssertEqualObjects([owner diskImageDataForKey:@"after-app-clear"],payload);
    [self axs_cachekeeper_state:@{@"enabled":@YES,@"mode":@"auto"}];
    [owner storeImageDataToDisk:payload forKey:@"restricted-after-clear"];
    XCTAssertNil([owner diskImageDataForKey:@"restricted-after-clear"]);
    [self.engine didEnterBackgroundWithTime:YES];
    [self axs_cachekeeper_wait:^BOOL(NSDictionary *r) {return [r[@"apiCompleted"] unsignedIntegerValue]==1;} description:@"plugin clear after APP own root recreation"];
    XCTAssertNil([owner diskImageDataForKey:@"after-app-clear"]);
}
- (void)testSixtyFifthRealOwnerRevokesExistingGatesAndDoesNotPermitUnknownOverlap {
    for (NSUInteger i=0;i<64;i++) [self axs_cachekeeper_owner:[NSString stringWithFormat:@"capacity-%lu",(unsigned long)i] config:nil];
    [self axs_cachekeeper_state:@{@"enabled":@YES,@"mode":@"auto"}];
    XCTAssertEqual([self.engine.receipt[@"restricted"] unsignedIntegerValue],64u);
    SDImageCache *first=self.owners.firstObject;
    // This owner is intentionally unregistered, so it does not use the standard admission preflight.
    SDImageCache *overflow=[self axs_cachekeeper_owner:@"capacity-0" config:[SDImageCacheConfig new]];
    XCTAssertEqual([self.engine.receipt[@"eligible"] unsignedIntegerValue],0u);
    XCTAssertEqual([self.engine.receipt[@"restricted"] unsignedIntegerValue],0u);
    XCTAssertEqualObjects(self.engine.receipt[@"reason"],@"observationLimit");
    NSData *payload=[self axs_cachekeeper_payload];
    [first storeImageDataToDisk:payload forKey:@"original-owner"];
    [overflow storeImageDataToDisk:payload forKey:@"overflow-owner"];
    XCTAssertEqualObjects([first diskImageDataForKey:@"original-owner"],payload);
    XCTAssertEqualObjects([overflow diskImageDataForKey:@"overflow-owner"],payload);
    [self.engine didEnterBackgroundWithTime:YES];[self axs_cachekeeper_refresh];
    XCTAssertEqual([self.engine.receipt[@"submitted"] unsignedIntegerValue],0u);
}
@end
