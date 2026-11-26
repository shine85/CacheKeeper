#import <XCTest/XCTest.h>
#import <SDWebImage/SDWebImage.h>
#import "../../AxsCacheKeeperImageCache.h"
#import "../../AxsCacheKeeperCleanupRules.h"
#import <objc/runtime.h>

// This target links unmodified SDWebImage 5.10.4 at its fixed upstream revision.
// Its private queue getter/setter are present in that source; no newer config API is added.
@interface SDImageCache (AxsCacheKeeperImageLegacyQueue)
@property(nonatomic,strong) dispatch_queue_t ioQueue;
@end
@interface AxsCacheKeeperImageLegacyCustomDisk : SDDiskCache
@end
@implementation AxsCacheKeeperImageLegacyCustomDisk
@end
@interface AxsCacheKeeperImageLegacyCustomConfig : SDImageCacheConfig
@end
@implementation AxsCacheKeeperImageLegacyCustomConfig
@end
@interface AxsCacheKeeperImageLegacySubstitutingMemory : SDMemoryCache
@end
@implementation AxsCacheKeeperImageLegacySubstitutingMemory
- (instancetype)initWithConfig:(SDImageCacheConfig *)config {
    if (!(self=[super initWithConfig:config])) return nil;
    config.memoryCacheClass=SDMemoryCache.class;
    return (id)[[SDMemoryCache alloc] initWithConfig:config];
}
@end

@interface AxsCacheKeeperImageLegacyTestCase : XCTestCase
@property(nonatomic,strong) AxsCacheKeeperImageCache *engine;
@property(nonatomic,strong) NSMutableDictionary *context;
@property(nonatomic,copy) NSString *home;
@property(nonatomic,strong) NSMutableArray<SDImageCache *> *owners;
@end
@implementation AxsCacheKeeperImageLegacyTestCase
- (void)setUp {
    [super setUp];
    self.home=[[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] stringByStandardizingPath];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtPath:[self.home stringByAppendingPathComponent:@"Library/Caches"] withIntermediateDirectories:YES attributes:nil error:nil]);
    self.context=[@{@"valid":@YES,@"appState":@{@"enabled":@YES,@"mode":@"clean",@"autoDiscover":@YES,@"excludedPaths":@[]},
        @"selected":@[],@"home":self.home,@"bundle":@"cachekeeper.owned.legacy.integration",@"version":@"1.0",
        @"installation":@"owned-legacy-fixture",@"reportWritable":@YES} mutableCopy];
    self.owners=[NSMutableArray new];__weak typeof(self) weakSelf=self;
    self.engine=[[AxsCacheKeeperImageCache alloc] initWithContextProvider:^NSDictionary *{
        AxsCacheKeeperImageLegacyTestCase *test=weakSelf;@synchronized(test) {return [test.context copy] ?: @{};}
    } observer:nil];
#if AXS_CACHEKEEPER_IMAGE_LEGACY_RED
    // The old adapter's explicit modern pin still runs its complete production ABI gate.
    [self.engine usePinnedSDKForIntegrationTests];
#else
    // Each fresh test process probes the modern ABI before any legacy hook is installed.
    static dispatch_once_t axs_cachekeeper_legacy_modern_probe;
    dispatch_once(&axs_cachekeeper_legacy_modern_probe,^{
        [self.engine usePinnedSDKForIntegrationTests];[self.engine startObserving];
        [self axs_cachekeeper_legacy_refresh];
        NSDictionary *receipt=self.engine.receipt;
        XCTAssertEqualObjects(receipt[@"state"],@"unsupported");
        XCTAssertEqualObjects(receipt[@"discoveryCheck"][@"failure"],@"missingMethod");
        XCTAssertEqualObjects(receipt[@"discoveryCheck"][@"methodIndex"],@11);
    });
    [self.engine usePinnedLegacySDKForIntegrationTests];
#endif
    [self.engine startObserving];[self axs_cachekeeper_legacy_refresh];
#if !AXS_CACHEKEEPER_IMAGE_LEGACY_RED
    self.continueAfterFailure=NO;
    XCTAssertEqualObjects(self.engine.receipt[@"state"],@"notObserved",@"legacy fixed-serial SDK admission");
    self.continueAfterFailure=YES;
#endif
}
- (void)tearDown {
    @synchronized(self) {self.context[@"appState"]=@{@"enabled":@NO};}
    [self.engine refreshWithCompletion:nil];
    for (SDImageCache *owner in self.owners) dispatch_sync(owner.ioQueue,^{});
    [self axs_cachekeeper_legacy_refresh];self.owners=nil;self.engine=nil;
    XCTAssertTrue([NSFileManager.defaultManager removeItemAtPath:self.home error:nil]);
    [AxsCacheKeeperCleanupRules removeAllRulesForTesting];[super tearDown];
}
- (NSData *)axs_cachekeeper_legacy_payload {return [@"owned legacy image fixture" dataUsingEncoding:NSUTF8StringEncoding];}
- (void)axs_cachekeeper_legacy_refresh {
    XCTestExpectation *done=[self expectationWithDescription:@"legacy policy refresh"];
    [self.engine refreshWithCompletion:^{[done fulfill];}];[self waitForExpectations:@[done] timeout:5];
    XCTAssertNotNil(axs_cachekeeper_image_cache_projection(self.engine.receipt));
}
- (void)axs_cachekeeper_legacy_state:(NSDictionary *)state {
    @synchronized(self) {self.context[@"appState"]=state;}[self axs_cachekeeper_legacy_refresh];
}
- (void)axs_cachekeeper_legacy_wait:(BOOL (^)(NSDictionary *))condition description:(NSString *)description {
    NSPredicate *predicate=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *unused) {
        (void)object;(void)unused;return condition(self.engine.receipt);
    }];
    XCTNSPredicateExpectation *done=[[XCTNSPredicateExpectation alloc] initWithPredicate:predicate object:self.engine];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[done] timeout:5],XCTWaiterResultCompleted,@"%@; %@",description,self.engine.receipt);
}
- (SDImageCache *)axs_cachekeeper_legacy_owner:(NSString *)space config:(SDImageCacheConfig *)config seed:(BOOL)seed {
    SDImageCacheConfig *actual=config ?: [SDImageCacheConfig new];
    actual.shouldRemoveExpiredDataWhenEnterBackground=NO;
    SDImageCache *owner=[[SDImageCache alloc] initWithNamespace:space diskCacheDirectory:[self.home stringByAppendingPathComponent:@"Library/Caches"] config:actual];
    XCTAssertNotNil(owner);[self.owners addObject:owner];
    if (seed && ![NSFileManager.defaultManager fileExistsAtPath:owner.diskCachePath]) {
        [owner storeImageDataToDisk:[self axs_cachekeeper_legacy_payload] forKey:@"fixture-root-seed"];
        XCTAssertNotNil([owner diskImageDataForKey:@"fixture-root-seed"]);
        dispatch_sync(owner.ioQueue,^{[owner.diskCache removeDataForKey:@"fixture-root-seed"];});
    }
    [self axs_cachekeeper_legacy_refresh];return owner;
}
@end

@interface ImageCacheLegacyIntegrationTests : AxsCacheKeeperImageLegacyTestCase
@end
@implementation ImageCacheLegacyIntegrationTests
- (void)testActualWritesKeepSeparateConfigurationEvidenceAndRestoreFiles {
#if !AXS_CACHEKEEPER_IMAGE_LEGACY_RED
    SDImageCache *owner=[self axs_cachekeeper_legacy_owner:@"write-epochs" config:nil seed:YES];NSData *payload=[self axs_cachekeeper_legacy_payload];
    NSNumber *(^epoch)(void)=^NSNumber *{return [self.engine.receipt[@"writeObservation"][@"epochs"] lastObject][@"epoch"];};
    NSDictionary *(^row)(NSNumber *)=^NSDictionary *(NSNumber *identifier){
        for (NSDictionary *item in self.engine.receipt[@"writeObservation"][@"epochs"]) if ([item[@"epoch"] isEqual:identifier]) return item;
        return nil;
    };
    NSNumber *clean=epoch();XCTAssertNotNil(clean);
    [owner storeImageDataToDisk:payload forKey:@"seed"];XCTAssertEqualObjects([owner diskImageDataForKey:@"seed"],payload);
    dispatch_sync(owner.ioQueue,^{[owner.diskCache setExtendedData:payload forKey:@"seed"];});
    [self axs_cachekeeper_legacy_state:@{@"enabled":@YES,@"mode":@"prevent"}];
    XCTAssertEqualObjects(row(clean)[@"data"][@"allowed"],@1);XCTAssertEqualObjects(row(clean)[@"extended"][@"allowed"],@1);
    NSNumber *blocked=epoch();
    [owner storeImageDataToDisk:payload forKey:@"blocked"];XCTAssertNil([owner diskImageDataForKey:@"blocked"]);
    dispatch_sync(owner.ioQueue,^{[owner.diskCache setData:[NSData data] forKey:@"empty-blocked"];[owner.diskCache setExtendedData:[NSData data] forKey:@"seed"];});
    XCTAssertNil([owner diskImageDataForKey:@"empty-blocked"]);
    __block NSData *metadata=nil;
    dispatch_sync(owner.ioQueue,^{[owner.diskCache setExtendedData:nil forKey:@"seed"];[owner.diskCache setExtendedData:payload forKey:@"seed"];metadata=[owner.diskCache extendedDataForKey:@"seed"];});
    XCTAssertNil(metadata);
    @synchronized(self) {self.context[@"installation"]=@"";}
    [self axs_cachekeeper_legacy_state:@{@"enabled":@NO,@"mode":@"prevent"}];
    for(NSString *writer in @[@"data",@"extended"]) {
        XCTAssertEqualObjects(row(blocked)[writer][@"attempts"],@2);XCTAssertEqualObjects(row(blocked)[writer][@"blocked"],@2);
        XCTAssertEqualObjects(row(blocked)[writer][@"nonemptyAttempts"],@1);XCTAssertEqualObjects(row(blocked)[writer][@"nonemptyBlocked"],@1);
        XCTAssertEqualObjects(row(blocked)[writer][@"emptyAttempts"],@1);XCTAssertEqualObjects(row(blocked)[writer][@"emptyBlocked"],@1);
    }
    NSNumber *disabled=epoch();
    XCTAssertEqualObjects(row(disabled)[@"identityState"],@"notRevalidated");
    [owner storeImageDataToDisk:payload forKey:@"restored"];XCTAssertEqualObjects([owner diskImageDataForKey:@"restored"],payload);
    dispatch_sync(owner.ioQueue,^{[owner.diskCache setExtendedData:payload forKey:@"seed"];metadata=[owner.diskCache extendedDataForKey:@"seed"];});
    XCTAssertEqualObjects(metadata,payload);[self axs_cachekeeper_legacy_refresh];
    XCTAssertEqualObjects(row(disabled)[@"enabled"],@NO);XCTAssertEqualObjects(row(disabled)[@"data"][@"allowed"],@1);
    XCTAssertEqualObjects(row(disabled)[@"extended"][@"allowed"],@1);XCTAssertEqualObjects(row(disabled)[@"data"][@"blocked"],@0);
    for(NSString *writer in @[@"data",@"extended"]) {
        XCTAssertEqualObjects(row(clean)[writer][@"nonemptyAllowed"],@1);
        XCTAssertEqualObjects(row(disabled)[writer][@"nonemptyAllowed"],@1);
        XCTAssertEqualObjects(row(disabled)[writer][@"nonemptyBlocked"],@0);
        XCTAssertEqualObjects(row(disabled)[writer][@"emptyAttempts"],@0);
    }
    XCTAssertEqualObjects(self.engine.receipt[@"writeObservation"][@"allowedMeaning"],@"originalCallForwarded");
    XCTAssertEqualObjects(self.engine.receipt[@"writeObservation"][@"diskPersistence"],@"notMeasured");
#endif
}
- (void)testFixedSerialContractAdmitsRealOwnerWithoutQueueAttributesAPI {
#if AXS_CACHEKEEPER_IMAGE_LEGACY_RED
    XCTAssertEqualObjects(self.engine.receipt[@"state"],@"notObserved",@"legacy fixed-serial SDK admission");
    return;
#endif
    XCTAssertEqual(class_getInstanceMethod(SDImageCacheConfig.class,sel_registerName("ioQueueAttributes")),(Method)NULL);
    SDImageCache *owner=[self axs_cachekeeper_legacy_owner:@"fixed-serial" config:nil seed:YES];
    XCTAssertFalse([owner.config respondsToSelector:sel_registerName("ioQueueAttributes")]);
    XCTAssertEqual([self.engine.receipt[@"eligible"] unsignedIntegerValue],1u);
    XCTAssertEqualObjects([self.engine instanceDiagnosticsForIntegrationTests:owner][@"currentReason"],@"none");
    dispatch_semaphore_t entered=dispatch_semaphore_create(0),release=dispatch_semaphore_create(0),second=dispatch_semaphore_create(0);
    dispatch_async(owner.ioQueue,^{dispatch_semaphore_signal(entered);dispatch_semaphore_wait(release,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC));});
    XCTAssertEqual(dispatch_semaphore_wait(entered,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)),0L);
    dispatch_async(owner.ioQueue,^{dispatch_semaphore_signal(second);});
    XCTAssertNotEqual(dispatch_semaphore_wait(second,dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC)),0L);
    dispatch_semaphore_signal(release);
    XCTAssertEqual(dispatch_semaphore_wait(second,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)),0L);
}
- (void)testModernContractCannotReuseLegacyHooks {
    AxsCacheKeeperImageCache *modern=[[AxsCacheKeeperImageCache alloc] initWithContextProvider:^NSDictionary *{
        return @{@"valid":@YES,@"appState":@{@"enabled":@YES}};
    } observer:nil];
    [modern usePinnedSDKForIntegrationTests];[modern startObserving];
    XCTestExpectation *done=[self expectationWithDescription:@"modern contract cannot reuse legacy hooks"];
    [modern refreshWithCompletion:^{[done fulfill];}];[self waitForExpectations:@[done] timeout:5];
    XCTAssertEqualObjects(modern.receipt[@"state"],@"unsupported");
}
- (void)testLazyRootFirstWriteIsPreservedBeforeRestrictionStarts {
    [self axs_cachekeeper_legacy_state:@{@"enabled":@YES,@"mode":@"auto"}];
    SDImageCache *owner=[self axs_cachekeeper_legacy_owner:@"lazy" config:nil seed:NO];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:owner.diskCachePath]);
    XCTAssertEqual([self.engine.receipt[@"eligible"] unsignedIntegerValue],0u);
    NSData *payload=[self axs_cachekeeper_legacy_payload];[owner storeImageDataToDisk:payload forKey:@"first"];
    [self axs_cachekeeper_legacy_wait:^BOOL(NSDictionary *r) {return [r[@"restricted"] unsignedIntegerValue]==1;} description:@"SDK first write establishes the real root"];
    XCTAssertEqualObjects([owner diskImageDataForKey:@"first"],payload);
    [owner storeImageDataToDisk:payload forKey:@"later"];XCTAssertNil([owner diskImageDataForKey:@"later"]);
}
- (void)testKVOConfigIsSupportedAndCustomConfigPreservesOriginalWrites {
    SDImageCache *standard=[self axs_cachekeeper_legacy_owner:@"kvo" config:nil seed:YES];
    XCTAssertEqualObjects([self.engine instanceDiagnosticsForIntegrationTests:standard][@"configKind"],@"standardKVO");
    standard.config.maxMemoryCost=2048;standard.config.maxMemoryCount=7;
    XCTAssertEqual(((SDMemoryCache *)standard.memoryCache).totalCostLimit,2048u);
    XCTAssertEqual(((SDMemoryCache *)standard.memoryCache).countLimit,7u);
    SDImageCache *custom=[self axs_cachekeeper_legacy_owner:@"custom-config" config:[AxsCacheKeeperImageLegacyCustomConfig new] seed:YES];
    XCTAssertEqualObjects([self.engine instanceDiagnosticsForIntegrationTests:custom][@"initialReason"],@"configurationClass");
    [self axs_cachekeeper_legacy_state:@{@"enabled":@YES,@"mode":@"prevent"}];
    [custom storeImageDataToDisk:[self axs_cachekeeper_legacy_payload] forKey:@"kept"];
    XCTAssertNotNil([custom diskImageDataForKey:@"kept"]);XCTAssertEqual([self.engine.receipt[@"restricted"] unsignedIntegerValue],1u);
}
- (void)testRestrictionPreservesMemoryMetadataRemovalAndDisableRestoresWrites {
    SDImageCache *owner=[self axs_cachekeeper_legacy_owner:@"restriction" config:nil seed:YES];NSData *payload=[self axs_cachekeeper_legacy_payload];
    [owner storeImageDataToDisk:payload forKey:@"seed.png"];
    dispatch_sync(owner.ioQueue,^{[owner.diskCache setExtendedData:payload forKey:@"seed.png"];});
    [self axs_cachekeeper_legacy_state:@{@"enabled":@YES,@"mode":@"auto"}];
    __block NSData *metadata=nil;
    dispatch_sync(owner.ioQueue,^{[owner.diskCache setExtendedData:nil forKey:@"seed.png"];metadata=[owner.diskCache extendedDataForKey:@"seed.png"];});
    XCTAssertNil(metadata);
    UIImage *image=[[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(2,2)] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [UIColor.blueColor setFill];[context fillRect:CGRectMake(0,0,2,2)];
    }];
    XCTestExpectation *done=[self expectationWithDescription:@"legacy SDK keeps original completion"];
    __block NSUInteger callbacks=0;
    [owner storeImage:image imageData:payload forKey:@"blocked.png" toDisk:YES completion:^{callbacks++;XCTAssertTrue(NSThread.isMainThread);[done fulfill];}];
    [self waitForExpectations:@[done] timeout:5];XCTAssertEqual(callbacks,1u);
    XCTAssertNotNil([owner imageFromMemoryCacheForKey:@"blocked.png"]);XCTAssertNil([owner diskImageDataForKey:@"blocked.png"]);
    dispatch_sync(owner.ioQueue,^{[owner.diskCache setExtendedData:payload forKey:@"seed.png"];metadata=[owner.diskCache extendedDataForKey:@"seed.png"];});
    XCTAssertNil(metadata);
    [self axs_cachekeeper_legacy_state:@{@"enabled":@YES,@"mode":@"prevent"}];
    [owner storeImageDataToDisk:payload forKey:@"prevented"];XCTAssertNil([owner diskImageDataForKey:@"prevented"]);
    [self axs_cachekeeper_legacy_state:@{@"enabled":@NO,@"mode":@"prevent"}];
    [owner storeImageDataToDisk:payload forKey:@"restored"];XCTAssertEqualObjects([owner diskImageDataForKey:@"restored"],payload);
    dispatch_sync(owner.ioQueue,^{[owner.diskCache setExtendedData:payload forKey:@"seed.png"];metadata=[owner.diskCache extendedDataForKey:@"seed.png"];});
    XCTAssertEqualObjects(metadata,payload);XCTAssertEqualObjects([owner diskImageDataForKey:@"seed.png"],payload);
}
- (void)testCleanupWaitsForOwnerQueuePreservesMemoryAndRepeatsAfterRootRecreation {
    SDImageCache *owner=[self axs_cachekeeper_legacy_owner:@"cleanup" config:nil seed:YES];NSData *payload=[self axs_cachekeeper_legacy_payload];
    [owner storeImageDataToDisk:payload forKey:@"clear"];UIImage *image=[UIImage new];[owner storeImageToMemory:image forKey:@"memory"];
    dispatch_semaphore_t entered=dispatch_semaphore_create(0),release=dispatch_semaphore_create(0);
    dispatch_async(owner.ioQueue,^{dispatch_semaphore_signal(entered);dispatch_semaphore_wait(release,dispatch_time(DISPATCH_TIME_NOW,8*NSEC_PER_SEC));});
    XCTAssertEqual(dispatch_semaphore_wait(entered,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)),0L);
    [self.engine didEnterBackgroundWithTime:YES];
    [self axs_cachekeeper_legacy_wait:^BOOL(NSDictionary *r) {return [r[@"pending"] unsignedIntegerValue]==1;} description:@"cleanup queued on actual owner queue"];
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:[owner cachePathForKey:@"clear"]]);
    dispatch_semaphore_signal(release);
    [self axs_cachekeeper_legacy_wait:^BOOL(NSDictionary *r) {return [r[@"apiCompleted"] unsignedIntegerValue]==1 && ![r[@"pending"] unsignedIntegerValue];} description:@"actual legacy disk clear"];
    NSDictionary *effect=[[self.engine.receipt[@"operationHistory"][@"processes"] lastObject][@"actions"] lastObject][@"cacheEffect"];
    XCTAssertEqualObjects(effect[@"result"],@"empty");XCTAssertEqualObjects(effect[@"before"][@"files"],@1);
    XCTAssertEqualObjects(effect[@"before"][@"logicalBytes"],@(payload.length));
    XCTAssertEqualObjects(effect[@"after"][@"files"],@0);XCTAssertEqualObjects(effect[@"physicalRelease"],@"notMeasured");
    XCTAssertNil([owner diskImageDataForKey:@"clear"]);XCTAssertEqual([owner imageFromMemoryCacheForKey:@"memory"],image);
    [owner storeImageDataToDisk:payload forKey:@"again"];[self.engine didEnterBackgroundWithTime:YES];
    [self axs_cachekeeper_legacy_wait:^BOOL(NSDictionary *r) {return [r[@"apiCompleted"] unsignedIntegerValue]==2;} description:@"verified recreated root can clear again"];
    XCTAssertNil([owner diskImageDataForKey:@"again"]);XCTAssertEqualObjects(self.engine.receipt[@"bytesState"],@"notMeasured");
}
- (void)testCustomBackendsAndFileManagerCannotGainEligibility {
    SDImageCacheConfig *diskConfig=[SDImageCacheConfig new];diskConfig.diskCacheClass=AxsCacheKeeperImageLegacyCustomDisk.class;
    SDImageCacheConfig *memoryConfig=[SDImageCacheConfig new];memoryConfig.memoryCacheClass=AxsCacheKeeperImageLegacySubstitutingMemory.class;
    SDImageCacheConfig *managerConfig=[SDImageCacheConfig new];managerConfig.fileManager=[NSFileManager new];
    NSArray *configs=@[diskConfig,memoryConfig,managerConfig];NSArray *reasons=@[@"diskBackend",@"memoryBackend",@"customFileManager"];
    for (NSUInteger i=0;i<configs.count;i++) {
        SDImageCache *owner=[self axs_cachekeeper_legacy_owner:[NSString stringWithFormat:@"custom-%lu",(unsigned long)i] config:configs[i] seed:YES];
        XCTAssertEqualObjects([self.engine instanceDiagnosticsForIntegrationTests:owner][@"initialReason"],reasons[i]);
    }
    [self axs_cachekeeper_legacy_state:@{@"enabled":@YES,@"mode":@"auto"}];
    for (SDImageCache *owner in self.owners) [owner storeImageDataToDisk:[self axs_cachekeeper_legacy_payload] forKey:@"kept"];
    [self.engine didEnterBackgroundWithTime:YES];[self axs_cachekeeper_legacy_refresh];
    XCTAssertEqual([self.engine.receipt[@"eligible"] unsignedIntegerValue],0u);XCTAssertEqual([self.engine.receipt[@"submitted"] unsignedIntegerValue],0u);
    for (SDImageCache *owner in self.owners) XCTAssertNotNil([owner diskImageDataForKey:@"kept"]);
}
- (void)testInstallationAndQueueIdentityDriftRestoreOriginalWrites {
    SDImageCache *owner=[self axs_cachekeeper_legacy_owner:@"identity" config:nil seed:YES];
    [self axs_cachekeeper_legacy_state:@{@"enabled":@YES,@"mode":@"auto"}];
    @synchronized(self) {self.context[@"installation"]=@"replacement";}[self axs_cachekeeper_legacy_refresh];
    XCTAssertEqual([self.engine.receipt[@"restricted"] unsignedIntegerValue],0u);
    [owner storeImageDataToDisk:[self axs_cachekeeper_legacy_payload] forKey:@"installation-kept"];XCTAssertNotNil([owner diskImageDataForKey:@"installation-kept"]);
    owner.ioQueue=dispatch_queue_create("cachekeeper.legacy.changed-queue",DISPATCH_QUEUE_CONCURRENT);
    [self axs_cachekeeper_legacy_refresh];XCTAssertEqual([self.engine.receipt[@"eligible"] unsignedIntegerValue],0u);
    XCTAssertEqualObjects([self.engine instanceDiagnosticsForIntegrationTests:owner][@"currentReason"],@"queueIdentity");
}
- (void)testPathReplacementAndSymbolicRootAreRejected {
    SDImageCache *owner=[self axs_cachekeeper_legacy_owner:@"path" config:nil seed:YES];NSString *path=owner.diskCachePath;
    XCTAssertTrue([NSFileManager.defaultManager moveItemAtPath:path toPath:[path stringByAppendingString:@"-old"] error:nil]);
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil]);
    [owner storeImageDataToDisk:[self axs_cachekeeper_legacy_payload] forKey:@"replacement-kept"];
    [self.engine didEnterBackgroundWithTime:YES];[self axs_cachekeeper_legacy_refresh];
    XCTAssertEqual([self.engine.receipt[@"eligible"] unsignedIntegerValue],0u);XCTAssertEqual([self.engine.receipt[@"submitted"] unsignedIntegerValue],0u);
    XCTAssertNotNil([owner diskImageDataForKey:@"replacement-kept"]);
    NSString *link=[self.home stringByAppendingPathComponent:@"Library/Caches/link"];
    XCTAssertTrue([NSFileManager.defaultManager createSymbolicLinkAtPath:link withDestinationPath:path error:nil]);
    [self axs_cachekeeper_legacy_owner:@"link" config:nil seed:NO];XCTAssertEqual([self.engine.receipt[@"eligible"] unsignedIntegerValue],0u);
}
- (void)testSelectionExclusionsRetentionAndUnknownChildrenPreserveData {
    SDImageCache *owner=[self axs_cachekeeper_legacy_owner:@"scope" config:nil seed:YES];NSData *payload=[self axs_cachekeeper_legacy_payload];
    [self axs_cachekeeper_legacy_state:@{@"enabled":@YES,@"mode":@"prevent",@"autoDiscover":@NO}];
    [owner storeImageDataToDisk:payload forKey:@"unselected-kept"];XCTAssertNotNil([owner diskImageDataForKey:@"unselected-kept"]);
    @synchronized(self) {self.context[@"selected"]=@[@"Library/Caches/scope"];}[self axs_cachekeeper_legacy_refresh];
    [owner storeImageDataToDisk:payload forKey:@"selected-blocked"];XCTAssertNil([owner diskImageDataForKey:@"selected-blocked"]);
    [self axs_cachekeeper_legacy_state:@{@"enabled":@YES,@"mode":@"clean",@"excludedPaths":@[@"Library/Caches/scope/kept-child"]}];
    XCTAssertEqual([self.engine.receipt[@"eligible"] unsignedIntegerValue],0u);
    AxsCacheKeeperAppRule *rule=[[AxsCacheKeeperAppRule alloc] initWithRuleID:@"legacy-retention" revision:@"1" appVersion:@"old" cleanablePaths:@[] retentionPaths:@[@"Library/Caches/scope/retained"] dependencyPaths:@[]];
    [AxsCacheKeeperCleanupRules registerRule:rule forBundle:@"cachekeeper.owned.legacy.integration"];
    [self axs_cachekeeper_legacy_state:@{@"enabled":@YES,@"mode":@"clean"}];XCTAssertEqual([self.engine.receipt[@"eligible"] unsignedIntegerValue],0u);
    [AxsCacheKeeperCleanupRules removeAllRulesForTesting];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtPath:[owner.diskCachePath stringByAppendingPathComponent:@"account-state"] withIntermediateDirectories:YES attributes:nil error:nil]);
    [self.engine didEnterBackgroundWithTime:YES];
    [self axs_cachekeeper_legacy_wait:^BOOL(NSDictionary *r) {return [r[@"skipped"] unsignedIntegerValue]==1;} description:@"unknown child rejects whole-owner clear"];
    XCTAssertEqual([self.engine.receipt[@"submitted"] unsignedIntegerValue],0u);XCTAssertNotNil([owner diskImageDataForKey:@"unselected-kept"]);
}
- (void)testQueuedDisablePreventsActualClear {
    SDImageCache *owner=[self axs_cachekeeper_legacy_owner:@"queued-disable" config:nil seed:YES];NSData *payload=[self axs_cachekeeper_legacy_payload];[owner storeImageDataToDisk:payload forKey:@"kept"];
    dispatch_semaphore_t release=dispatch_semaphore_create(0);
    dispatch_async(owner.ioQueue,^{dispatch_semaphore_wait(release,dispatch_time(DISPATCH_TIME_NOW,8*NSEC_PER_SEC));});
    [self.engine didEnterBackgroundWithTime:YES];[self axs_cachekeeper_legacy_wait:^BOOL(NSDictionary *r) {return [r[@"pending"] unsignedIntegerValue]==1;} description:@"queued before disable"];
    [self axs_cachekeeper_legacy_state:@{@"enabled":@NO}];dispatch_semaphore_signal(release);
    [self axs_cachekeeper_legacy_wait:^BOOL(NSDictionary *r) {return [r[@"skipped"] unsignedIntegerValue]==1 && ![r[@"pending"] unsignedIntegerValue];} description:@"disabled clear never enters SDK"];
    XCTAssertEqual([self.engine.receipt[@"submitted"] unsignedIntegerValue],0u);XCTAssertEqualObjects([owner diskImageDataForKey:@"kept"],payload);
}
- (void)testForegroundCancelsPluginClearButAllowsTheAppsOwnClear {
    SDImageCache *owner=[self axs_cachekeeper_legacy_owner:@"foreground" config:nil seed:YES];[owner storeImageDataToDisk:[self axs_cachekeeper_legacy_payload] forKey:@"kept"];
    dispatch_semaphore_t release=dispatch_semaphore_create(0);dispatch_async(owner.ioQueue,^{dispatch_semaphore_wait(release,dispatch_time(DISPATCH_TIME_NOW,8*NSEC_PER_SEC));});
    [self.engine didEnterBackgroundWithTime:YES];[self axs_cachekeeper_legacy_wait:^BOOL(NSDictionary *r) {return [r[@"pending"] unsignedIntegerValue]==1;} description:@"queued before foreground"];
    [self.engine didBecomeActive];dispatch_semaphore_signal(release);
    [self axs_cachekeeper_legacy_wait:^BOOL(NSDictionary *r) {return [r[@"skipped"] unsignedIntegerValue]==1;} description:@"foreground cancels queued plugin clear"];
    XCTAssertNotNil([owner diskImageDataForKey:@"kept"]);
    XCTestExpectation *done=[self expectationWithDescription:@"original legacy clear completion"];
    [owner clearDiskOnCompletion:^{[done fulfill];}];[self waitForExpectations:@[done] timeout:5];
    XCTAssertNil([owner diskImageDataForKey:@"kept"]);XCTAssertEqual([self.engine.receipt[@"submitted"] unsignedIntegerValue],0u);
    [self axs_cachekeeper_legacy_state:@{@"enabled":@YES,@"mode":@"auto"}];
    [owner storeImageDataToDisk:[self axs_cachekeeper_legacy_payload] forKey:@"blocked-after-own-clear"];XCTAssertNil([owner diskImageDataForKey:@"blocked-after-own-clear"]);
}
- (void)testBackgroundExpirationSkipsQueuedFlightWithoutSubmittingAgain {
    SDImageCache *owner=[self axs_cachekeeper_legacy_owner:@"expiration" config:nil seed:YES];[owner storeImageDataToDisk:[self axs_cachekeeper_legacy_payload] forKey:@"kept"];
    dispatch_semaphore_t release=dispatch_semaphore_create(0);dispatch_async(owner.ioQueue,^{dispatch_semaphore_wait(release,dispatch_time(DISPATCH_TIME_NOW,8*NSEC_PER_SEC));});
    [self.engine didEnterBackgroundWithTime:YES];[self axs_cachekeeper_legacy_wait:^BOOL(NSDictionary *r) {return [r[@"pending"] unsignedIntegerValue]==1;} description:@"queued before expiration"];
    [self.engine expireBackgroundTime];[self.engine didEnterBackgroundWithTime:YES];[self axs_cachekeeper_legacy_refresh];
    XCTAssertEqual([self.engine.receipt[@"queued"] unsignedIntegerValue],1u);dispatch_semaphore_signal(release);
    [self axs_cachekeeper_legacy_wait:^BOOL(NSDictionary *r) {return [r[@"skipped"] unsignedIntegerValue]==1;} description:@"expired flight cannot enter SDK"];
    XCTAssertEqual([self.engine.receipt[@"submitted"] unsignedIntegerValue],0u);XCTAssertNotNil([owner diskImageDataForKey:@"kept"]);
}
- (void)testChangedMethodRestoresOriginalWritesUntilVerifiedImplementationReturns {
    SDImageCache *owner=[self axs_cachekeeper_legacy_owner:@"method-change" config:nil seed:YES];[self axs_cachekeeper_legacy_state:@{@"enabled":@YES,@"mode":@"auto"}];
    Method method=class_getInstanceMethod(SDDiskCache.class,@selector(fileManager));IMP original=method_getImplementation(method);
    IMP replacement=imp_implementationWithBlock(^id(id receiver) {return ((id (*)(id,SEL))original)(receiver,@selector(fileManager));});
    XCTAssertNotEqual(replacement,(IMP)NULL);if (!replacement) return;
    method_setImplementation(method,replacement);
    @try {
        [self axs_cachekeeper_legacy_refresh];XCTAssertEqualObjects(self.engine.receipt[@"state"],@"unsupported");
        [owner storeImageDataToDisk:[self axs_cachekeeper_legacy_payload] forKey:@"allowed-while-changed"];XCTAssertNotNil([owner diskImageDataForKey:@"allowed-while-changed"]);
    } @finally {
        method_setImplementation(method,original);XCTAssertTrue(imp_removeBlock(replacement));[self axs_cachekeeper_legacy_refresh];
    }
    XCTAssertEqual([self.engine.receipt[@"restricted"] unsignedIntegerValue],1u);
    [owner storeImageDataToDisk:[self axs_cachekeeper_legacy_payload] forKey:@"blocked-after-restore"];XCTAssertNil([owner diskImageDataForKey:@"blocked-after-restore"]);
}
- (void)testOverlappingOwnersRevokeRestrictionAndPreserveAllWrites {
    SDImageCache *first=[self axs_cachekeeper_legacy_owner:@"overlap" config:nil seed:YES];[self axs_cachekeeper_legacy_state:@{@"enabled":@YES,@"mode":@"auto"}];
    XCTAssertEqual([self.engine.receipt[@"restricted"] unsignedIntegerValue],1u);
    SDImageCache *second=[self axs_cachekeeper_legacy_owner:@"overlap" config:nil seed:YES];
    XCTAssertEqual([self.engine.receipt[@"eligible"] unsignedIntegerValue],0u);
    [first storeImageDataToDisk:[self axs_cachekeeper_legacy_payload] forKey:@"first"];[second storeImageDataToDisk:[self axs_cachekeeper_legacy_payload] forKey:@"second"];
    [self.engine didEnterBackgroundWithTime:YES];[self axs_cachekeeper_legacy_refresh];
    XCTAssertEqual([self.engine.receipt[@"submitted"] unsignedIntegerValue],0u);XCTAssertNotNil([first diskImageDataForKey:@"first"]);XCTAssertNotNil([second diskImageDataForKey:@"second"]);
}
@end

// Run this class in a separate xcodebuild test process. Objective-C cannot remove an
// added method, so it must never share a process with the unchanged SDK behavior suite.
static id axs_cachekeeper_legacy_unexpected_attributes(id object,SEL selector) {(void)object;(void)selector;return nil;}
@interface ImageCacheLegacyAbsentAPITests : AxsCacheKeeperImageLegacyTestCase
@end
@implementation ImageCacheLegacyAbsentAPITests
- (void)testAddedQueueAttributesAPIRevokesExistingAndFutureAdmission {
    SDImageCache *owner=[self axs_cachekeeper_legacy_owner:@"absent-api" config:nil seed:YES];[self axs_cachekeeper_legacy_state:@{@"enabled":@YES,@"mode":@"auto"}];
    XCTAssertEqual([self.engine.receipt[@"restricted"] unsignedIntegerValue],1u);
    XCTAssertTrue(class_addMethod(SDImageCacheConfig.class,sel_registerName("ioQueueAttributes"),(IMP)axs_cachekeeper_legacy_unexpected_attributes,"@16@0:8"));
    [owner storeImageDataToDisk:[self axs_cachekeeper_legacy_payload] forKey:@"original-write-restored"];
    XCTAssertNotNil([owner diskImageDataForKey:@"original-write-restored"]);
    [self axs_cachekeeper_legacy_refresh];
    XCTAssertEqualObjects(self.engine.receipt[@"state"],@"unsupported");
    XCTAssertEqualObjects(self.engine.receipt[@"discoveryCheck"][@"methodIndex"],@11);
    XCTAssertEqual([self.engine.receipt[@"restricted"] unsignedIntegerValue],0u);
    [self.engine didEnterBackgroundWithTime:YES];[self axs_cachekeeper_legacy_refresh];
    XCTAssertEqual([self.engine.receipt[@"submitted"] unsignedIntegerValue],0u);
    XCTAssertNotNil([owner diskImageDataForKey:@"original-write-restored"]);
    AxsCacheKeeperImageCache *next=[[AxsCacheKeeperImageCache alloc] initWithContextProvider:^NSDictionary *{
        return @{@"valid":@YES,@"appState":@{@"enabled":@YES}};
    } observer:nil];
#if AXS_CACHEKEEPER_IMAGE_LEGACY_RED
    [next usePinnedSDKForIntegrationTests];
#else
    [next usePinnedLegacySDKForIntegrationTests];
#endif
    [next startObserving];
    XCTestExpectation *done=[self expectationWithDescription:@"new observer must preserve absent-API refusal"];
    [next refreshWithCompletion:^{[done fulfill];}];[self waitForExpectations:@[done] timeout:5];
    XCTAssertEqualObjects(next.receipt[@"state"],@"unsupported");
}
@end
