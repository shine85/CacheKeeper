#import <XCTest/XCTest.h>
#import "../../Prefs/DiagnosticsPage.h"
#import "../../AxsCacheKeeperCapacityStatus.h"
#include <sys/stat.h>

@interface AxsCacheKeeperDiagnosticsPage (AxsCacheKeeperCapacityTests)
- (NSString *)axs_cachekeeper_capacity_file:(NSString *)name;
- (void)axs_cachekeeper_capacity_action;
- (void)axs_cachekeeper_capacity_stop;
- (void)axs_cachekeeper_capacity_poll;
- (void)axs_cachekeeper_capacity_background:(NSNotification *)notification;
- (void)axs_cachekeeper_collect;
- (BOOL)axs_cachekeeper_capacity_write_stop:(NSString *)epoch error:(NSError **)error;
@end
@interface AxsCacheKeeperCapacityPageFixture : AxsCacheKeeperDiagnosticsPage
@property(nonatomic,copy) NSString *fixtureFolder;
@property(nonatomic,strong) XCTestExpectation *appeared;
@property(nonatomic) BOOL rejectStopWithoutError;
@property(nonatomic) BOOL successfulStopWithError;
@end
@implementation AxsCacheKeeperCapacityPageFixture
- (NSString *)axs_cachekeeper_capacity_file:(NSString *)name {return [self.fixtureFolder stringByAppendingPathComponent:name];}
- (BOOL)axs_cachekeeper_capacity_write_stop:(NSString *)epoch error:(NSError **)error {
    if (self.rejectStopWithoutError) {if (error) *error=nil;return NO;}
    BOOL saved=[super axs_cachekeeper_capacity_write_stop:epoch error:error];
    if (saved && self.successfulStopWithError && error) *error=[NSError errorWithDomain:@"SyntheticStaleError" code:1 userInfo:nil];
    return saved;
}
- (void)viewDidAppear:(BOOL)animated {[super viewDidAppear:animated];[self.appeared fulfill];self.appeared=nil;}
@end
@interface AxsCacheKeeperCapacityCancelledPush : NSObject <UIViewControllerAnimatedTransitioning,UINavigationControllerDelegate>
@property(nonatomic,strong) XCTestExpectation *returned;
@property(nonatomic,weak) UIViewController *target;
@end
@implementation AxsCacheKeeperCapacityCancelledPush
- (NSTimeInterval)transitionDuration:(id<UIViewControllerContextTransitioning>)context {(void)context;return 0.1;}
- (void)animateTransition:(id<UIViewControllerContextTransitioning>)context {
    UIView *to=[context viewForKey:UITransitionContextToViewKey];[context.containerView addSubview:to];
    dispatch_async(dispatch_get_main_queue(),^{[context completeTransition:NO];});
}
- (id<UIViewControllerAnimatedTransitioning>)navigationController:(UINavigationController *)navigation animationControllerForOperation:(UINavigationControllerOperation)operation fromViewController:(UIViewController *)from toViewController:(UIViewController *)to {
    (void)navigation;(void)from;(void)to;return operation==UINavigationControllerOperationPush ? self : nil;
}
- (void)navigationController:(UINavigationController *)navigation didShowViewController:(UIViewController *)page animated:(BOOL)animated {
    (void)navigation;(void)animated;if (page==self.target) {[self.returned fulfill];self.returned=nil;}
}
@end
@interface AxsCacheKeeperCapacityPageTests : XCTestCase <UINavigationControllerDelegate>
@property(nonatomic,strong) AxsCacheKeeperCapacityPageFixture *page;
@property(nonatomic,copy) NSString *folder;
@property(nonatomic,strong) UIWindow *window,*previousWindow;
@property(nonatomic,strong) XCTestExpectation *navigationFinished;
@property(nonatomic,weak) UIViewController *expectedPage;
@end
@implementation AxsCacheKeeperCapacityPageTests
- (void)setUp {
    [super setUp];self.folder=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtPath:self.folder withIntermediateDirectories:YES attributes:nil error:NULL]);
    self.page=[AxsCacheKeeperCapacityPageFixture new];self.page.fixtureFolder=self.folder;[self.page loadViewIfNeeded];
}
- (void)tearDown {
    [self.page axs_cachekeeper_capacity_stop];self.page=nil;
    self.window.hidden=YES;self.window.rootViewController=nil;[self.previousWindow makeKeyWindow];self.window=nil;
    [NSFileManager.defaultManager removeItemAtPath:self.folder error:NULL];[super tearDown];
}
- (UINavigationController *)showPage {
    self.previousWindow=UIApplication.sharedApplication.delegate.window;
    XCTestExpectation *appeared=[self expectationWithDescription:@"measuring page actually appeared"];
    self.page.appeared=appeared;
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UINavigationController *navigation=[[UINavigationController alloc] initWithRootViewController:self.page];
    self.window.rootViewController=navigation;[self.window makeKeyAndVisible];[self waitForExpectations:@[appeared] timeout:5];return navigation;
}
- (void)drainCollectionQueue {
    XCTestExpectation *drained=[self expectationWithDescription:@"production collection queue and main reply completed"];
    dispatch_queue_t queue=[self.page valueForKey:@"collectionQueue"];
    dispatch_async(queue,^{dispatch_async(dispatch_get_main_queue(),^{[drained fulfill];});});
    [self waitForExpectations:@[drained] timeout:10];
}
- (void)navigationController:(UINavigationController *)navigation didShowViewController:(UIViewController *)page animated:(BOOL)animated {
    (void)navigation;(void)animated;if (page==self.expectedPage) {[self.navigationFinished fulfill];self.navigationFinished=nil;}
}
- (NSDictionary *)request {return [NSDictionary dictionaryWithContentsOfFile:[self.folder stringByAppendingPathComponent:@"capacityRequest.plist"]];}
- (void)assertReturnedControls {
    UIButton *collect=[self.page valueForKey:@"collectButton"],*measure=[self.page valueForKey:@"axs_cachekeeper_capacityButton"];
    XCTAssertTrue(collect.enabled);XCTAssertTrue(measure.enabled);
    XCTAssertEqualObjects(measure.currentTitle,@"重新测量全容器占用 · 只读");
    XCTAssertTrue([[self.page valueForKey:@"status"] containsString:@"服务终态"]);
}
- (NSDictionary *)savedMeasurement:(NSString *)epoch {
    // UI consumes an already saved observation. Its nonzero fixture numbers come
    // from OS metadata of isolated synthetic files, not a mocked traversal.
    NSString *root=[self.folder stringByAppendingPathComponent:@"container"];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL]);
    NSString *file=[root stringByAppendingPathComponent:@"synthetic"];
    XCTAssertTrue([[NSMutableData dataWithLength:8192] writeToFile:file atomically:YES]);
    struct stat rootInfo,fileInfo;XCTAssertEqual(lstat(root.fileSystemRepresentation,&rootInfo),0);XCTAssertEqual(lstat(file.fileSystemRepresentation,&fileInfo),0);
    NSNumber *logical=@((uint64_t)fileInfo.st_size),*allocated=@(((uint64_t)rootInfo.st_blocks+(uint64_t)fileInfo.st_blocks)*512);
    NSMutableDictionary *registry=[@{@"schemaVersion":@1,@"state":@"available",@"sourceState":@"available",@"sourceSampledAt":@100,
        @"observedRegistrations":@1,@"invalidRegistrationCount":@0,@"truncatedRegistrationCount":@0,
        @"allRolesUniqueRegisteredURLCount":@1,@"countsAreLowerBounds":@NO,
        @"entries":@[@{@"bundle":@"test.capacity",@"displayEligible":@YES,@"sourceClassification":@"user",
            @"relationships":@{@"home":@{@"state":@"notProvided",@"tokens":@[]},@"group":@{@"state":@"available",@"tokens":@[@"resource-1"]},
                @"extension":@{@"state":@"available",@"tokens":@[]}}}]} mutableCopy];
    for (NSString *role in @[@"home",@"group",@"extension"]) registry[role]=@{@"state":@"available",@"observedSourceCount":@1,
        @"missingSelectorCount":@0,@"notProvidedCount":[role isEqual:@"home"] ? @1 : @0,@"invalidSourceCount":@0,@"invalidAssociationCount":@0,
        @"ownerMismatchCount":@0,@"unavailableOwnerCount":@0,@"truncatedCount":@0,
        @"registeredURLCount":[role isEqual:@"group"] ? @1 : @0,@"associationCount":[role isEqual:@"group"] ? @1 : @0};
    NSDictionary *closed=axs_cachekeeper_registry_inventory_projection(registry);XCTAssertEqualObjects(closed[@"state"],@"available");
    NSDictionary *measurement=@{@"schemaVersion":@1,@"state":@"complete",@"logicalBytes":logical,@"allocatedBytes":allocated,@"entries":@2,
        @"uniqueInodes":@2,@"duplicateInodes":@0,@"entryLimit":@2000000,@"depthLimit":@64,@"inodeLimit":@262144,@"nodeLimit":@4096,
        @"nodes":@[@{@"id":@1,@"parent":@0,@"category":@"unknown",@"logicalBytes":logical,@"allocatedBytes":allocated,@"entries":@2}],
        @"deletionAuthorization":@"notGranted",@"physicalUniqueBytes":@"notMeasured",@"reclaimableBytes":@"notMeasured"};
    return @{@"schemaVersion":@1,@"epoch":epoch,@"state":@"complete",@"sourceSampledAt":@100,
        @"startedAt":@101,@"updatedAt":@102,@"finishedAt":@102,@"totalRoots":@1,@"completedRoots":@1,@"failedRoots":@0,
        @"excludedBundles":@[@"com.tencent.qy.xin"],@"registry":closed,
        @"roots":@[@{@"id":@1,@"token":@"resource-1",@"owners":@[@"test.capacity"],@"roles":@[@"group"],@"measurement":measurement}],
        @"entries":@[@{@"bundle":@"test.capacity",@"state":@"registered",@"rootIds":@[@1]}],
        @"deletionAuthorization":@"notGranted",@"physicalUniqueBytes":@"notMeasured",@"reclaimableBytes":@"notMeasured",@"freshness":@"savedObservationUnverified",
        @"measurementWindow":@"nonAtomicTraversal",@"installationMatch":@"notRevalidatedAtExport"};
}
- (void)testStartAndCancelUseOnlyEpochAndOperation {
    [self.page axs_cachekeeper_capacity_action];NSDictionary *started=[self request];
    XCTAssertEqualObjects(started[@"operation"],@"start");XCTAssertNotNil([[NSUUID alloc] initWithUUIDString:started[@"epoch"]]);
    XCTAssertEqual(started.count,3u);XCTAssertNil(started[@"path"]);XCTAssertNil(started[@"bundle"]);
    [self.page axs_cachekeeper_capacity_action];NSDictionary *cancelled=[self request];
    XCTAssertEqualObjects(cancelled[@"operation"],@"cancel");XCTAssertEqualObjects(cancelled[@"epoch"],started[@"epoch"]);
    XCTAssertEqual(cancelled.count,3u);
}
- (void)testNewMeasurementDoesNotReuseCancelledEpoch {
    [self.page axs_cachekeeper_capacity_action];NSString *epoch=[self request][@"epoch"];
    [self.page axs_cachekeeper_capacity_stop];[self.page axs_cachekeeper_capacity_action];
    XCTAssertEqualObjects([self request][@"operation"],@"start");XCTAssertNotEqualObjects([self request][@"epoch"],epoch);
}
- (void)testSourceAndConfigurationRemainUntouched {
    NSString *path=[self.folder stringByAppendingPathComponent:@"appEnabled.plist"];
    NSData *before=[@"private-config-canary" dataUsingEncoding:NSUTF8StringEncoding];XCTAssertTrue([before writeToFile:path atomically:YES]);
    [self.page axs_cachekeeper_capacity_action];[self.page axs_cachekeeper_capacity_stop];
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:path],before);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[self.folder stringByAppendingPathComponent:@"request.plist"]]);
}
- (void)testRequestFailureDoesNotPretendMeasurementStarted {
    self.page.fixtureFolder=[self.folder stringByAppendingPathComponent:@"missing"];
    [self.page axs_cachekeeper_capacity_action];XCTAssertNil([self request]);
    XCTAssertNil([self.page valueForKey:@"axs_cachekeeper_capacityEpoch"]);
    XCTAssertNil([self.page valueForKey:@"axs_cachekeeper_capacityTimer"]);
}
- (void)testBackgroundRequestsCancellationWithoutClaimingCompletion {
    [self.page axs_cachekeeper_capacity_action];NSString *epoch=[self request][@"epoch"];
    [self.page axs_cachekeeper_capacity_background:nil];
    XCTAssertEqualObjects([self request][@"operation"],@"cancel");XCTAssertEqualObjects([self request][@"epoch"],epoch);
    XCTAssertNil([self.page valueForKey:@"axs_cachekeeper_capacityEpoch"]);
    XCTAssertNil([self.page valueForKey:@"reportData"]);
}
- (void)testUnconfirmedStopAllowsAbandoningWaitWithoutClaimingServiceStopped {
    [self.page axs_cachekeeper_capacity_action];[self.page axs_cachekeeper_capacity_action];
    XCTAssertEqualObjects([self request][@"operation"],@"cancel");
    [self.page setValue:@(NSProcessInfo.processInfo.systemUptime-11) forKey:@"axs_cachekeeper_capacityStopStarted"];
    [self.page axs_cachekeeper_capacity_poll];[self drainCollectionQueue];
    UIButton *button=[self.page valueForKey:@"axs_cachekeeper_capacityButton"];
    XCTAssertTrue(button.enabled);XCTAssertEqualObjects(button.currentTitle,@"放弃等待 · 停止尚未确认");
    [button sendActionsForControlEvents:UIControlEventTouchUpInside];
    XCTAssertNil([self.page valueForKey:@"axs_cachekeeper_capacityEpoch"]);
    XCTAssertNil([self.page valueForKey:@"axs_cachekeeper_capacityTimer"]);
    XCTAssertEqualObjects([self.page valueForKey:@"axs_cachekeeper_capacityError"],@"cancelNotConfirmed");
    XCTAssertNil([self.page valueForKey:@"reportData"]);
}
- (void)testInvalidOrOtherEpochResultCannotCompleteCurrentMeasurement {
    [self.page axs_cachekeeper_capacity_action];NSString *epoch=[self request][@"epoch"];
    // An untrusted old result claims success but lacks a valid closed report.
    [@{@"schemaVersion":@1,@"state":@"complete",@"epoch":NSUUID.UUID.UUIDString,@"path":@"private-path-canary"} writeToFile:[self.folder stringByAppendingPathComponent:@"capacityResult.plist"] atomically:YES];
    [self.page axs_cachekeeper_capacity_poll];
    [self drainCollectionQueue];
    XCTAssertEqualObjects([self.page valueForKey:@"axs_cachekeeper_capacityEpoch"],epoch);
    XCTAssertNil([self.page valueForKey:@"axs_cachekeeper_capacitySnapshot"]);XCTAssertNil([self.page valueForKey:@"reportData"]);
}
- (void)testDisplayedMeasurementRemainsFrozenWhenGlobalResultIsReplaced {
    [self.page axs_cachekeeper_capacity_action];NSString *epoch=[self request][@"epoch"];
    NSMutableDictionary *receipt=[[self savedMeasurement:epoch] mutableCopy];
    XCTAssertEqualObjects(axs_cachekeeper_capacity_projection(receipt)[@"state"],@"complete");
    NSDictionary *original=receipt[@"roots"][0][@"measurement"];
    NSString *path=[self.folder stringByAppendingPathComponent:@"capacityResult.plist"];
    XCTAssertTrue([receipt writeToFile:path atomically:YES]);[self.page axs_cachekeeper_capacity_poll];[self drainCollectionQueue];
    // Initial read may have raced before this fixture save; poll after draining it.
    [self.page axs_cachekeeper_capacity_poll];[self drainCollectionQueue];
    XCTAssertNil([self.page valueForKey:@"axs_cachekeeper_capacityEpoch"]);
    receipt[@"epoch"]=NSUUID.UUID.UUIDString;receipt[@"updatedAt"]=@200;receipt[@"finishedAt"]=@200;
    XCTAssertTrue([receipt writeToFile:path atomically:YES]);[self.page axs_cachekeeper_collect];[self drainCollectionQueue];
    NSDictionary *report=[NSJSONSerialization JSONObjectWithData:[self.page valueForKey:@"reportData"] options:0 error:NULL];
    XCTAssertEqualObjects(report[@"capacityMeasurement"][@"epoch"],epoch);XCTAssertEqualObjects(report[@"capacityMeasurement"][@"updatedAt"],@102);
    XCTAssertEqualObjects(report[@"capacityMeasurement"][@"sourceSampledAt"],@100);XCTAssertEqualObjects(report[@"capacityMeasurement"][@"finishedAt"],@102);
    XCTAssertEqualObjects(report[@"capacityMeasurement"][@"roots"][0][@"measurement"],original);
    XCTAssertEqualObjects(original[@"logicalBytes"],@8192);XCTAssertGreaterThan([original[@"allocatedBytes"] unsignedLongLongValue],0u);
}
- (NSString *)cacheRunningMeasurement {
    [self.page axs_cachekeeper_capacity_action];NSString *epoch=[self request][@"epoch"];
    NSMutableDictionary *running=[[self savedMeasurement:epoch] mutableCopy];running[@"state"]=@"running";[running removeObjectForKey:@"finishedAt"];
    XCTAssertTrue([running writeToFile:[self.folder stringByAppendingPathComponent:@"capacityResult.plist"] atomically:YES]);
    [self drainCollectionQueue];[self.page axs_cachekeeper_capacity_poll];[self drainCollectionQueue];
    XCTAssertEqualObjects([self.page valueForKey:@"axs_cachekeeper_capacitySnapshot"][@"state"],@"running");return epoch;
}
- (NSDictionary *)collectedCapacity {
    [self.page axs_cachekeeper_collect];[self drainCollectionQueue];
    NSDictionary *report=[NSJSONSerialization JSONObjectWithData:[self.page valueForKey:@"reportData"] options:0 error:NULL];
    return report[@"capacityMeasurement"];
}
- (void)testBackgroundReplacesCachedRunningWithSameEpochSavedTerminal {
    NSString *epoch=[self cacheRunningMeasurement];[self.page axs_cachekeeper_capacity_background:nil];
    NSMutableDictionary *terminal=[[self savedMeasurement:epoch] mutableCopy];terminal[@"state"]=@"cancelled";terminal[@"updatedAt"]=@200;terminal[@"finishedAt"]=@200;
    XCTAssertTrue([terminal writeToFile:[self.folder stringByAppendingPathComponent:@"capacityResult.plist"] atomically:YES]);
    NSDictionary *capacity=[self collectedCapacity];
    XCTAssertEqualObjects(capacity[@"state"],@"cancelled",@"D1 stopped page exports saved terminal instead of cached running");
    if (![capacity[@"state"] isEqual:@"cancelled"]) return;
    XCTAssertEqualObjects(capacity[@"epoch"],epoch);XCTAssertEqualObjects(capacity[@"updatedAt"],@200);XCTAssertEqualObjects(capacity[@"finishedAt"],@200);
    XCTAssertEqualObjects(capacity[@"clientStop"][@"confirmation"],@"terminalObserved");
}
- (void)testAbandonWaitReplacesRunningWithSavedTerminal {
    NSString *epoch=[self cacheRunningMeasurement];[self.page axs_cachekeeper_capacity_action];
    [self.page setValue:@(NSProcessInfo.processInfo.systemUptime-11) forKey:@"axs_cachekeeper_capacityStopStarted"];[self.page axs_cachekeeper_capacity_action];
    NSMutableDictionary *terminal=[[self savedMeasurement:epoch] mutableCopy];terminal[@"state"]=@"cancelled";
    XCTAssertTrue([terminal writeToFile:[self.folder stringByAppendingPathComponent:@"capacityResult.plist"] atomically:YES]);
    XCTAssertEqualObjects([self collectedCapacity][@"state"],@"cancelled");
}
- (void)testStoppedARejectsOtherEpochBAndMarksUnconfirmed {
    NSString *a=[self cacheRunningMeasurement];[self.page axs_cachekeeper_capacity_background:nil];
    NSString *b=NSUUID.UUID.UUIDString;XCTAssertTrue([[self savedMeasurement:b] writeToFile:[self.folder stringByAppendingPathComponent:@"capacityResult.plist"] atomically:YES]);
    NSDictionary *capacity=[self collectedCapacity];XCTAssertEqualObjects(capacity[@"epoch"],a);
    XCTAssertEqualObjects(capacity[@"clientStop"][@"confirmation"],@"unconfirmed");
    XCTAssertEqualObjects(capacity[@"clientStop"][@"requestWrite"],@"saved");XCTAssertNil(capacity[@"finishedAt"]);
}
- (void)testFailedBackgroundStopIsExplicitAndDoesNotFreezeRunning {
    NSString *epoch=[self cacheRunningMeasurement],*path=[self.folder stringByAppendingPathComponent:@"capacityRequest.plist"];
    XCTAssertTrue([NSFileManager.defaultManager removeItemAtPath:path error:NULL]);
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:NO attributes:nil error:NULL]);
    [self.page axs_cachekeeper_capacity_background:nil];NSDictionary *capacity=[self collectedCapacity];
    XCTAssertEqualObjects(capacity[@"epoch"],epoch);XCTAssertEqualObjects(capacity[@"clientStop"][@"requestWrite"],@"failed");
    XCTAssertEqualObjects(capacity[@"clientStop"][@"confirmation"],@"unconfirmed");
}
- (void)testFalseStopReturnWithoutNSErrorCannotClaimSaved {
    NSString *epoch=[self cacheRunningMeasurement];self.page.rejectStopWithoutError=YES;
    [self.page axs_cachekeeper_capacity_background:nil];NSDictionary *capacity=[self collectedCapacity];
    XCTAssertEqualObjects(capacity[@"epoch"],epoch);
    XCTAssertEqualObjects(capacity[@"clientStop"][@"requestWrite"],@"failed",@"D1 BOOL false cannot become saved when NSError is nil");
    XCTAssertEqualObjects(capacity[@"clientStop"][@"confirmation"],@"unconfirmed");
    XCTAssertEqualObjects([self request][@"operation"],@"start");
}
- (void)testTrueStopReturnWithStaleNSErrorIsSaved {
    [self cacheRunningMeasurement];self.page.successfulStopWithError=YES;[self.page axs_cachekeeper_capacity_background:nil];
    NSDictionary *capacity=[self collectedCapacity];XCTAssertEqualObjects(capacity[@"clientStop"][@"requestWrite"],@"saved");
    XCTAssertNil([self.page valueForKey:@"axs_cachekeeper_capacityError"]);XCTAssertEqualObjects([self request][@"operation"],@"cancel");
}
- (void)testStopBeforeFirstSnapshotDoesNotExportOtherEpoch {
    [self.page axs_cachekeeper_capacity_action];NSString *a=[self request][@"epoch"];
    [self.page axs_cachekeeper_capacity_background:nil];
    XCTAssertTrue([[self savedMeasurement:NSUUID.UUID.UUIDString] writeToFile:[self.folder stringByAppendingPathComponent:@"capacityResult.plist"] atomically:YES]);
    NSDictionary *capacity=[self collectedCapacity];XCTAssertEqualObjects(capacity[@"state"],@"notMeasured");
    XCTAssertEqualObjects(capacity[@"clientStop"][@"epoch"],a);XCTAssertEqualObjects(capacity[@"clientStop"][@"confirmation"],@"unconfirmed");
}
- (void)testOtherEpochHistoryIsSummaryOnlyForStoppedPage {
    NSString *a=[self cacheRunningMeasurement];[self.page axs_cachekeeper_capacity_background:nil];
    NSMutableDictionary *b=[[self savedMeasurement:NSUUID.UUID.UUIDString] mutableCopy];
    b[@"terminalHistory"]=@{@"limit":@16,@"omittedCount":@0,@"records":@[@{@"epoch":a,@"state":@"cancelled",@"startedAt":@101,@"finishedAt":@150,
        @"resultPublication":@"notSaved"}]};
    XCTAssertTrue([b writeToFile:[self.folder stringByAppendingPathComponent:@"capacityResult.plist"] atomically:YES]);
    NSDictionary *capacity=[self collectedCapacity];XCTAssertEqualObjects(capacity[@"epoch"],a);XCTAssertEqualObjects(capacity[@"state"],@"running");
    XCTAssertNil(capacity[@"finishedAt"]);XCTAssertEqualObjects(capacity[@"clientStop"][@"confirmation"],@"terminalHistoryObserved");
    XCTAssertEqualObjects(capacity[@"clientStop"][@"terminal"][@"resultPublication"],@"notSaved");
}
- (void)testFrozenCompleteCanCarryNewerStopReceiptWithoutChangingItsEpoch {
    NSString *a=[self cacheRunningMeasurement];[self.page axs_cachekeeper_capacity_background:nil];
    [self.page axs_cachekeeper_capacity_action];NSString *b=[self request][@"epoch"];
    XCTAssertTrue([[self savedMeasurement:b] writeToFile:[self.folder stringByAppendingPathComponent:@"capacityResult.plist"] atomically:YES]);
    [self drainCollectionQueue];[self.page axs_cachekeeper_capacity_poll];[self drainCollectionQueue];
    NSDictionary *capacity=[self collectedCapacity];XCTAssertEqualObjects(capacity[@"epoch"],b);XCTAssertEqualObjects(capacity[@"state"],@"complete");
    XCTAssertEqualObjects(capacity[@"clientStop"][@"epoch"],a);XCTAssertEqualObjects(capacity[@"clientStop"][@"confirmation"],@"unconfirmed");
}
- (void)testCursorErrorsSurviveSavedCapacityAndActualJSONExport {
    NSString *epoch=[self cacheRunningMeasurement];[self.page axs_cachekeeper_capacity_background:nil];
    NSMutableDictionary *saved=[[self savedMeasurement:epoch] mutableCopy],*root=[saved[@"roots"][0] mutableCopy],*measurement=[root[@"measurement"] mutableCopy];
    saved[@"state"]=@"partial";saved[@"completedRoots"]=@0;saved[@"failedRoots"]=@1;measurement[@"state"]=@"readError";
    measurement[@"cursorErrors"]=@{@"enumerationErrors":@1,@"statErrors":@0,@"errorsTruncated":@NO,@"omittedErrorCount":@0,
        @"errors":@[@{@"stage":@"enumerate",@"reason":@"readFailure",@"errorDomain":@"posix",@"errorCode":@5,@"count":@1,@"scope":@"home",@"path":@"private-canary"}]};
    root[@"measurement"]=measurement;saved[@"roots"]=@[root];
    XCTAssertTrue([saved writeToFile:[self.folder stringByAppendingPathComponent:@"capacityResult.plist"] atomically:YES]);
    NSDictionary *capacity=[self collectedCapacity],*error=[capacity[@"roots"][0][@"measurement"][@"cursorErrors"][@"errors"] firstObject];
    XCTAssertEqualObjects(error[@"errorCode"],@5);XCTAssertEqualObjects(error[@"stage"],@"enumerate");XCTAssertNil(error[@"scope"]);XCTAssertNil(error[@"path"]);
}
- (void)testLatePollReplyCannotRestoreStoppedRunningSnapshot {
    NSString *epoch=[self cacheRunningMeasurement];[self.page axs_cachekeeper_capacity_poll];
    [self.page axs_cachekeeper_capacity_background:nil];[self drainCollectionQueue];
    NSMutableDictionary *terminal=[[self savedMeasurement:epoch] mutableCopy];terminal[@"state"]=@"cancelled";
    XCTAssertTrue([terminal writeToFile:[self.folder stringByAppendingPathComponent:@"capacityResult.plist"] atomically:YES]);
    XCTAssertEqualObjects([self collectedCapacity][@"state"],@"cancelled");
}
- (void)testCompletedPushCancelsMeasurement {
    UINavigationController *navigation=[self showPage];[self.page axs_cachekeeper_capacity_action];
    UIViewController *detail=[UIViewController new];self.expectedPage=detail;XCTestExpectation *shown=[self expectationWithDescription:@"actual push completed"];
    self.navigationFinished=shown;navigation.delegate=self;
    [navigation pushViewController:detail animated:NO];[self waitForExpectations:@[shown] timeout:5];
    XCTAssertEqualObjects([self request][@"operation"],@"cancel");XCTAssertNil([self.page valueForKey:@"axs_cachekeeper_capacityTimer"]);
    XCTestExpectation *returned=[self expectationWithDescription:@"actual pop returned to measuring page"];
    self.page.appeared=returned;[navigation popViewControllerAnimated:NO];[self waitForExpectations:@[returned] timeout:5];[self assertReturnedControls];
}
- (void)testCompletedFullscreenCoverCancelsMeasurement {
    [self showPage];[self.page axs_cachekeeper_capacity_action];UIViewController *modal=[UIViewController new];modal.modalPresentationStyle=UIModalPresentationFullScreen;
    XCTestExpectation *shown=[self expectationWithDescription:@"actual fullscreen cover completed"];
    [self.page presentViewController:modal animated:NO completion:^{[shown fulfill];}];[self waitForExpectations:@[shown] timeout:5];
    XCTAssertEqualObjects([self request][@"operation"],@"cancel");XCTAssertNil([self.page valueForKey:@"axs_cachekeeper_capacityEpoch"]);
    XCTestExpectation *returned=[self expectationWithDescription:@"actual fullscreen dismiss returned to page"];
    self.page.appeared=returned;[self.page dismissViewControllerAnimated:NO completion:nil];[self waitForExpectations:@[returned] timeout:5];[self assertReturnedControls];
}
- (void)testStoppingPushAndPopRestoresActionableControls {
    UINavigationController *navigation=[self showPage];[self.page axs_cachekeeper_capacity_action];[self.page axs_cachekeeper_capacity_action];
    XCTAssertFalse([[self.page valueForKey:@"axs_cachekeeper_capacityButton"] isEnabled]);
    UIViewController *detail=[UIViewController new];self.expectedPage=detail;
    XCTestExpectation *shown=[self expectationWithDescription:@"stopping page push actually completed"];
    self.navigationFinished=shown;navigation.delegate=self;
    [navigation pushViewController:detail animated:NO];[self waitForExpectations:@[shown] timeout:5];
    XCTestExpectation *returned=[self expectationWithDescription:@"stopping page returned after push"];
    self.page.appeared=returned;[navigation popViewControllerAnimated:NO];[self waitForExpectations:@[returned] timeout:5];[self assertReturnedControls];
}
- (void)testFailedStopSaveLeavesRetryAvailable {
    [self.page axs_cachekeeper_capacity_action];NSString *epoch=[self request][@"epoch"];
    NSString *path=[self.folder stringByAppendingPathComponent:@"capacityRequest.plist"];
    XCTAssertTrue([NSFileManager.defaultManager removeItemAtPath:path error:NULL]);
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:NO attributes:nil error:NULL]);
    UIButton *button=[self.page valueForKey:@"axs_cachekeeper_capacityButton"];[button sendActionsForControlEvents:UIControlEventTouchUpInside];
    XCTAssertEqualObjects([self.page valueForKey:@"axs_cachekeeper_capacityEpoch"],epoch);XCTAssertTrue(button.enabled);
    XCTAssertTrue([[self.page valueForKey:@"status"] containsString:@"停止请求未保存"]);
}
- (void)testCancelledPushKeepsCurrentMeasurement {
    UINavigationController *navigation=[self showPage];[self.page axs_cachekeeper_capacity_action];NSString *epoch=[self request][@"epoch"];
    AxsCacheKeeperCapacityCancelledPush *transition=[AxsCacheKeeperCapacityCancelledPush new];transition.target=self.page;
    transition.returned=[self expectationWithDescription:@"actual cancelled push returned to measuring page"];navigation.delegate=transition;
    XCTestExpectation *returned=transition.returned;[navigation pushViewController:[UIViewController new] animated:YES];[self waitForExpectations:@[returned] timeout:5];
    XCTAssertEqualObjects([self request][@"operation"],@"start");XCTAssertEqualObjects([self.page valueForKey:@"axs_cachekeeper_capacityEpoch"],epoch);
}
@end
