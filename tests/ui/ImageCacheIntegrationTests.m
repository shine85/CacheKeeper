#import <XCTest/XCTest.h>
#import <SDWebImage/SDWebImage.h>
#import "../../AxsCacheKeeperImageCache.h"
#import "../../AxsCacheKeeperCleanupRules.h"
#include <sys/stat.h>

// The private queue getter is verified against the fixed SDK source and the saved device ABI.
@interface SDImageCache (AxsCacheKeeperImageTestQueue)
@property(nonatomic,strong) dispatch_queue_t ioQueue;
@end
@interface AxsCacheKeeperImageTestCustomDisk : SDDiskCache
@end
@implementation AxsCacheKeeperImageTestCustomDisk
@end

@interface ImageCacheIntegrationTests : XCTestCase
@property(nonatomic,strong) AxsCacheKeeperImageCache *engine;
@property(nonatomic,strong) NSMutableDictionary *context;
@property(nonatomic,copy) NSString *home;
@property(nonatomic,strong) NSMutableArray<SDImageCache *> *owners;
@end
@implementation ImageCacheIntegrationTests
- (void)setUp {
    [super setUp];
    self.home=[[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] stringByStandardizingPath];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtPath:[self.home stringByAppendingPathComponent:@"Library/Caches"] withIntermediateDirectories:YES attributes:nil error:nil]);
    self.context=[@{@"valid":@YES,@"appState":@{@"enabled":@YES,@"mode":@"clean",@"autoDiscover":@YES,@"excludedPaths":@[]},
        @"selected":@[],@"home":self.home,@"bundle":@"cachekeeper.owned.integration",@"version":@"1.0",
        @"installation":@"owned-fixture-install",@"reportWritable":@YES} mutableCopy];
    self.owners=[NSMutableArray new];__weak typeof(self) weakSelf=self;
    self.engine=[[AxsCacheKeeperImageCache alloc] initWithContextProvider:^NSDictionary *{
        ImageCacheIntegrationTests *test=weakSelf;@synchronized(test) {return [test.context copy] ?: @{};}
    } observer:nil];
    [self.engine usePinnedSDKForIntegrationTests];[self.engine startObserving];[self axs_cachekeeper_refresh];
}
- (void)tearDown {
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
    XCTestExpectation *done=[self expectationWithDescription:@"image configuration refresh"];
    [self.engine refreshWithCompletion:^{[done fulfill];}];
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
    XCTAssertNotNil(owner);[self.owners addObject:owner];[self axs_cachekeeper_refresh];return owner;
}
- (void)axs_cachekeeper_wait:(BOOL (^)(NSDictionary *))test description:(NSString *)description {
    NSPredicate *predicate=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *unused) {(void)object;(void)unused;return test(self.engine.receipt);}];
    XCTNSPredicateExpectation *done=[[XCTNSPredicateExpectation alloc] initWithPredicate:predicate object:self.engine];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[done] timeout:5],XCTWaiterResultCompleted,@"%@; %@",description,self.engine.receipt);
    XCTAssertNotNil(axs_cachekeeper_image_cache_projection(self.engine.receipt));
}
- (NSData *)axs_cachekeeper_payload {return [@"owned image-cache fixture" dataUsingEncoding:NSUTF8StringEncoding];}
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
    XCTAssertNil([first diskImageDataForKey:@"one"]);XCTAssertNil([second diskImageDataForKey:@"two"]);
    XCTAssertEqual([first imageFromMemoryCacheForKey:@"memory"],image);
    XCTAssertEqualObjects(self.engine.receipt[@"bytesState"],@"notMeasured");
    // SDK clear recreates its root. A second round must use the new verified root identity.
    [first storeImageDataToDisk:payload forKey:@"again"];
    [self.engine didEnterBackgroundWithTime:YES];
    [self axs_cachekeeper_wait:^BOOL(NSDictionary *r) {return [r[@"apiCompleted"] unsignedIntegerValue]==4 && ![r[@"pending"] unsignedIntegerValue];} description:@"repeat clear after SDK root recreation"];
    XCTAssertNil([first diskImageDataForKey:@"again"]);
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
    SDImageCache *overflow=[self axs_cachekeeper_owner:@"capacity-0" config:nil];
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
