#import <XCTest/XCTest.h>
#import "../../AxsCacheKeeperCollectionSession.h"
#import "../../AxsCacheKeeperImageCollection.h"
#import "../../Prefs/DiagnosticsPage.h"
#import "../../Prefs/ImageCollectionPage.h"

@interface AxsCacheKeeperDiagnosticsPage (AxsCollectionTests)
- (instancetype)initWithCollectionSessionObject:(AxsCacheKeeperCollectionSession *)session;
- (void)axs_cachekeeper_capacity_action;
- (void)axs_cachekeeper_capacity_background:(NSNotification *)notification;
- (void)axs_cachekeeper_capacity_poll;
- (NSString *)axs_cachekeeper_capacity_file:(NSString *)name;
- (void)axs_cachekeeper_collect;
@end
@interface AxsCacheKeeperImageCollectionPage (AxsCollectionTests)
- (void)axs_start_bundle:(NSString *)bundle;
@end
@interface AxsCollectionLiveDiagnosticsFixture : AxsCacheKeeperDiagnosticsPage
@property(nonatomic,copy) NSString *axs_collection_folder;
@end
@implementation AxsCollectionLiveDiagnosticsFixture
- (NSString *)axs_cachekeeper_capacity_file:(NSString *)name {return [self.axs_collection_folder stringByAppendingPathComponent:name];}
@end
@interface AxsCollectionDiagnosticsFixture : AxsCacheKeeperDiagnosticsPage
@property(nonatomic,copy) NSString *axs_collection_folder;
@end
@implementation AxsCollectionDiagnosticsFixture
- (NSString *)axs_cachekeeper_capacity_file:(NSString *)name {return [self.axs_collection_folder stringByAppendingPathComponent:name];}
- (void)axs_cachekeeper_capacity_poll {} // No privileged service in this UI state-transition fixture.
@end
@interface AxsCacheKeeperCollectionSessionTests : XCTestCase
@property(nonatomic,copy) NSString *axs_cachekeeper_folder,*axs_cachekeeper_path;
@end
@implementation AxsCacheKeeperCollectionSessionTests
- (void)setUp {
    [super setUp];
    self.axs_cachekeeper_folder=[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"collection-%@",NSUUID.UUID.UUIDString]];
    self.axs_cachekeeper_path=[self.axs_cachekeeper_folder stringByAppendingPathComponent:@"session.plist"];
}
- (void)tearDown {
    [NSFileManager.defaultManager removeItemAtPath:self.axs_cachekeeper_folder error:NULL];[super tearDown];
}
- (AxsCacheKeeperCollectionSession *)axs_collection_session {
    NSError *error=nil;
    AxsCacheKeeperCollectionSession *session=[[AxsCacheKeeperCollectionSession alloc] initWithPath:self.axs_cachekeeper_path error:&error];
    XCTAssertNotNil(session);XCTAssertNil(error);
    XCTAssertTrue([session blockCapability:@"com.tencent.mqq" capability:@"privateResourceContract" error:&error]);
    XCTAssertTrue([session beginPhase:@"hostPreflight" error:&error]);
    XCTAssertTrue([session finishPhase:@"hostPreflight" result:@{@"state":@"partial"} error:&error]);
    return session;
}
- (void)testBlockedReadOnlySessionResumesWithoutReplayingTerminalPhase {
    AxsCacheKeeperCollectionSession *session=[self axs_collection_session];NSError *error=nil;
    NSArray *rows=[AxsCacheKeeperCollectionSession resumableSessionsInDirectory:self.axs_cachekeeper_folder error:&error];
    XCTAssertEqual(rows.count,1u);XCTAssertEqualObjects(rows.firstObject[@"nextPhase"],@"capacity");
    AxsCacheKeeperCollectionSession *resumed=[AxsCacheKeeperCollectionSession openSessionAtPath:rows.firstObject[@"path"] error:&error];
    XCTAssertEqualObjects(session.sessionID,resumed.sessionID);
    XCTAssertFalse([resumed beginPhase:@"hostPreflight" error:&error]);
    XCTAssertTrue([resumed beginPhase:@"capacity" error:&error]);
    XCTAssertFalse([resumed beginPhase:@"capacity" error:&error]);
    XCTAssertEqualObjects(resumed.reportProjection[@"state"],@"blocked");
}
- (void)testCapacityRetryPersistsRunningBeforeRequestAndBackgroundPersistsInterruption {
    AxsCacheKeeperCollectionSession *session=[self axs_collection_session];NSError *error=nil;
    XCTAssertTrue([session beginPhase:@"capacity" error:&error]);
    XCTAssertTrue(([session finishPhase:@"capacity" result:@{@"state":@"interrupted",@"epoch":@"previous",
        @"terminalSource":@"clientLifecycle",@"observedAt":@1} error:&error]));
    AxsCollectionDiagnosticsFixture *page=[[AxsCollectionDiagnosticsFixture alloc] initWithCollectionSessionObject:session];page.axs_collection_folder=self.axs_cachekeeper_folder;
    [page loadViewIfNeeded];
    UIButton *button=[page valueForKey:@"axs_cachekeeper_capacityButton"];
    XCTAssertNotNil(button.superview);XCTAssertFalse(button.hidden);XCTAssertTrue(button.enabled);
    [page axs_cachekeeper_capacity_action];
    XCTAssertEqualObjects(session.reportProjection[@"phases"][@"capacity"][@"state"],@"running");
    NSDictionary *request=[NSDictionary dictionaryWithContentsOfFile:[self.axs_cachekeeper_folder stringByAppendingPathComponent:@"capacityRequest.plist"]];
    XCTAssertEqualObjects(request[@"operation"],@"start");XCTAssertNotNil(request[@"epoch"]);
    [page axs_cachekeeper_capacity_background:nil];
    NSDictionary *phase=session.reportProjection[@"phases"][@"capacity"];
    XCTAssertEqualObjects(phase[@"state"],@"interrupted");
    XCTAssertEqualObjects(phase[@"result"][@"epoch"],request[@"epoch"]);
    XCTAssertEqualObjects(phase[@"result"][@"terminalSource"],@"clientLifecycle");
    XCTAssertNil(phase[@"result"][@"finishedAt"]);
    request=[NSDictionary dictionaryWithContentsOfFile:[self.axs_cachekeeper_folder stringByAppendingPathComponent:@"capacityRequest.plist"]];
    XCTAssertEqualObjects(request[@"operation"],@"cancel");
    [page viewDidAppear:NO];
    XCTAssertNotNil(button.superview);XCTAssertFalse(button.hidden);XCTAssertTrue(button.enabled);
    [button sendActionsForControlEvents:UIControlEventTouchUpInside];
    XCTAssertEqualObjects(session.reportProjection[@"phases"][@"capacity"][@"state"],@"running");
    [button sendActionsForControlEvents:UIControlEventTouchUpInside];
    [page setValue:@(NSProcessInfo.processInfo.systemUptime-11) forKey:@"axs_cachekeeper_capacityStopStarted"];
    [button sendActionsForControlEvents:UIControlEventTouchUpInside];
    XCTAssertEqualObjects(session.reportProjection[@"phases"][@"capacity"][@"state"],@"interrupted");
    XCTAssertEqualObjects(session.reportProjection[@"phases"][@"capacity"][@"result"][@"reason"],@"cancelNotConfirmed");
    XCTAssertFalse(button.hidden);XCTAssertTrue(button.enabled);
}
- (void)testCompletedReportReopensByteIdenticallyAndCollectDoesNotReplay {
    AxsCacheKeeperCollectionSession *session=[self axs_collection_session];NSError *error=nil;
    XCTAssertTrue([session beginPhase:@"capacity" error:&error]);
    XCTAssertTrue(([session finishPhase:@"capacity" result:@{@"state":@"partial",@"epoch":@"e1",@"finishedAt":@1,
        @"completedRoots":@0,@"totalRoots":@1,@"failedRoots":@1} error:&error]));
    XCTAssertTrue([session beginPhase:@"diagnostics" error:&error]);
    XCTAssertTrue([[session imageCollectionSession:&error] skip:&error]);
    NSData *data=[session saveReport:@{@"apps":@[],@"capacityMeasurement":@{@"state":@"notMeasured"}}
        diagnosticsResult:@{@"state":@"partial",@"appCount":@0,@"missingSources":@[@"fixture"]} error:&error];
    XCTAssertNotNil(data);XCTAssertNil(error);
    AxsCacheKeeperCollectionSession *resumed=[AxsCacheKeeperCollectionSession openSessionAtPath:self.axs_cachekeeper_path error:&error];
    XCTAssertEqualObjects([resumed savedReportData:&error],data);
    AxsCacheKeeperDiagnosticsPage *page=[[AxsCacheKeeperDiagnosticsPage alloc] initWithCollectionSessionObject:resumed];
    [page loadViewIfNeeded];NSDictionary *before=resumed.reportProjection;
    [page axs_cachekeeper_collect];
    XCTAssertEqualObjects([page valueForKey:@"reportData"],data);
    XCTAssertEqualObjects(resumed.reportProjection,before);
    XCTAssertFalse([[page valueForKey:@"collecting"] boolValue]);
    XCTAssertEqualObjects(resumed.reportProjection[@"state"],@"blocked");
}
- (void)testDurableHistoricalReportWithStaleClockBindingCanStillBeShared {
    AxsCacheKeeperCollectionSession *session=[self axs_collection_session];
    AxsCacheKeeperDiagnosticsPage *page=[[AxsCacheKeeperDiagnosticsPage alloc] initWithCollectionSessionObject:session];
    // Keep the fixture on the diagnostics state without contacting a capacity service.
    [page setValue:@NO forKey:@"axs_cachekeeper_guidedCollection"];
    [page loadViewIfNeeded];
    NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"capacityMeasurement":@{@"state":@"partial",@"summaryBinding":@{@"state":@"stale"}}} options:0 error:NULL];
    [page setValue:data forKey:@"reportData"];
    [page performSelector:NSSelectorFromString(@"axs_cachekeeper_refresh")];
    XCTAssertTrue([[page valueForKey:@"exportButton"] isEnabled]);
    [page setValue:nil forKey:@"axs_cachekeeper_collectionSession"];
    [page performSelector:NSSelectorFromString(@"axs_cachekeeper_refresh")];
    XCTAssertFalse([[page valueForKey:@"exportButton"] isEnabled],@"ordinary reports keep the current-result requirement");
}
- (void)testActualCapacityReplyRequiresImageDecisionAndPersistsUnavailableEntry {
    AxsCacheKeeperCollectionSession *session=[self axs_collection_session];NSError *error=nil;
    AxsCollectionLiveDiagnosticsFixture *page=[[AxsCollectionLiveDiagnosticsFixture alloc] initWithCollectionSessionObject:session];page.axs_collection_folder=self.axs_cachekeeper_folder;
    UINavigationController *navigation=[[UINavigationController alloc] initWithRootViewController:page];[page loadViewIfNeeded];
    NSDictionary *request=[NSDictionary dictionaryWithContentsOfFile:[self.axs_cachekeeper_folder stringByAppendingPathComponent:@"capacityRequest.plist"]];
    NSDictionary *terminal=@{@"schemaVersion":@1,@"epoch":request[@"epoch"],@"state":@"partial",@"sourceSampledAt":@0,
        @"startedAt":@1,@"updatedAt":@2,@"finishedAt":@2,@"totalRoots":@0,@"completedRoots":@0,@"failedRoots":@0,
        @"excludedBundles":@[@"com.tencent.qy.xin"],@"registry":axs_cachekeeper_registry_inventory_projection(nil),@"roots":@[],@"entries":@[],
        @"deletionAuthorization":@"notGranted",@"physicalUniqueBytes":@"notMeasured",@"reclaimableBytes":@"notMeasured",
        @"freshness":@"savedObservationUnverified",@"measurementWindow":@"nonAtomicTraversal",@"installationMatch":@"notRevalidatedAtExport"};
    XCTAssertEqualObjects(axs_cachekeeper_capacity_projection(terminal)[@"state"],@"partial");
    XCTAssertTrue([terminal writeToFile:[self.axs_cachekeeper_folder stringByAppendingPathComponent:@"capacityResult.plist"] atomically:YES]);
    [page axs_cachekeeper_capacity_poll];
    NSPredicate *terminalSaved=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *unused){(void)object;(void)unused;return [session.reportProjection[@"phases"][@"capacity"][@"state"] isEqual:@"partial"];}];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[[[XCTNSPredicateExpectation alloc] initWithPredicate:terminalSaved object:session]] timeout:5],XCTWaiterResultCompleted);
    XCTAssertNil([page valueForKey:@"reportData"]);XCTAssertNil(session.reportProjection[@"phases"][@"diagnostics"]);
    UIButton *collect=[page valueForKey:@"collectButton"],*image=[page valueForKey:@"axs_cachekeeper_imageCollectionButton"];
    XCTAssertFalse(collect.enabled);XCTAssertTrue(image.enabled);
    [page axs_cachekeeper_collect];XCTAssertNil(session.reportProjection[@"phases"][@"diagnostics"]);
    XCTAssertTrue([@{AxsCacheKeeperImageCollectionBundle:@NO} writeToFile:[self.axs_cachekeeper_folder stringByAppendingPathComponent:@"appEnabled.plist"] atomically:YES]);
    [image sendActionsForControlEvents:UIControlEventTouchUpInside];
    AxsCacheKeeperImageCollectionPage *imagePage=(id)navigation.topViewController;XCTAssertTrue([imagePage isKindOfClass:AxsCacheKeeperImageCollectionPage.class]);[imagePage loadViewIfNeeded];
    [(UIButton *)[imagePage valueForKey:@"startButton"] sendActionsForControlEvents:UIControlEventTouchUpInside];
    NSDictionary *imageReport=[session imageCollectionSession:&error].reportProjection;
    XCTAssertEqualObjects(imageReport[@"entry"][@"state"],@"entered");XCTAssertEqualObjects(imageReport[@"preflight"][@"state"],@"noCandidate");
    XCTAssertEqualObjects(imageReport[@"preflight"][@"modules"][0][@"reason"],@"appDisabled");
    [(UIButton *)[imagePage valueForKey:@"skipButton"] sendActionsForControlEvents:UIControlEventTouchUpInside];
    [navigation popViewControllerAnimated:NO];[page viewDidAppear:NO];XCTAssertTrue(collect.enabled);
    [collect sendActionsForControlEvents:UIControlEventTouchUpInside];
    NSPredicate *reportSaved=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *unused){(void)object;(void)unused;return [page valueForKey:@"reportData"]!=nil;}];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[[[XCTNSPredicateExpectation alloc] initWithPredicate:reportSaved object:page]] timeout:10],XCTWaiterResultCompleted);
    AxsCacheKeeperCollectionSession *reopened=[AxsCacheKeeperCollectionSession openSessionAtPath:self.axs_cachekeeper_path error:&error];
    NSDictionary *report=[NSJSONSerialization JSONObjectWithData:[reopened savedReportData:&error] options:0 error:&error];
    XCTAssertEqualObjects(report[@"supportedImageCollection"][@"state"],@"skipped");
    XCTAssertEqualObjects(report[@"supportedImageCollection"][@"preflight"][@"modules"][0][@"reason"],@"appDisabled");
    XCTAssertEqualObjects(report[@"supportedImageCollection"][@"verificationState"],@"notPerformed");
    XCTAssertNil([NSDictionary dictionaryWithContentsOfFile:[self.axs_cachekeeper_folder stringByAppendingPathComponent:@"imageCollectionRequest.plist"]]);
}
- (void)testImageSelectionFailurePersistsBeforeRequestAndSkipRemainsExplicit {
    NSError *error=nil;AxsCacheKeeperCollectionSession *session=[self axs_collection_session];
    AxsCacheKeeperImageCollectionSession *image=[session imageCollectionSession:&error];
    AxsCacheKeeperImageCollectionPage *page=[[AxsCacheKeeperImageCollectionPage alloc] initWithSession:image];[page loadViewIfNeeded];
    XCTAssertTrue([@{AxsCacheKeeperImageCollectionBundle:@YES} writeToFile:[self.axs_cachekeeper_folder stringByAppendingPathComponent:@"appEnabled.plist"] atomically:YES]);
    XCTAssertTrue([@{} writeToFile:[self.axs_cachekeeper_folder stringByAppendingPathComponent:@"directories.plist"] atomically:YES]);
    [page axs_start_bundle:AxsCacheKeeperImageCollectionBundle];
    image=[session imageCollectionSession:&error];
    XCTAssertEqualObjects(image.reportProjection[@"selectedCheck"][@"reason"],@"receiptMissing");
    XCTAssertEqualObjects(image.reportProjection[@"lastFailure"][@"stage"],@"candidate");XCTAssertFalse([image readyForReport]);
    XCTAssertFalse([[page valueForKey:@"nextButton"] isEnabled]);XCTAssertTrue([[page valueForKey:@"skipButton"] isEnabled]);
    [(UIButton *)[page valueForKey:@"skipButton"] sendActionsForControlEvents:UIControlEventTouchUpInside];
    image=[session imageCollectionSession:&error];XCTAssertTrue([image readyForReport]);
    XCTAssertEqualObjects(image.reportProjection[@"state"],@"skipped");XCTAssertNotNil(image.reportProjection[@"lastFailure"]);
}
- (void)testFailedCapacityRequestStillOffersExplicitImageSkipAndFailureExport {
    AxsCacheKeeperCollectionSession *session=[self axs_collection_session];NSError *error=nil;
    NSString *requestPath=[self.axs_cachekeeper_folder stringByAppendingPathComponent:@"capacityRequest.plist"];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtPath:requestPath withIntermediateDirectories:NO attributes:nil error:&error]);
    AxsCollectionLiveDiagnosticsFixture *page=[[AxsCollectionLiveDiagnosticsFixture alloc] initWithCollectionSessionObject:session];page.axs_collection_folder=self.axs_cachekeeper_folder;
    [page loadViewIfNeeded];
    XCTAssertEqualObjects(session.reportProjection[@"phases"][@"capacity"][@"state"],@"failed");
    XCTAssertFalse([[page valueForKey:@"axs_cachekeeper_imageCollectionButton"] isEnabled]);
    UIButton *skip=[page valueForKey:@"axs_cachekeeper_skipImageButton"],*collect=[page valueForKey:@"collectButton"];
    XCTAssertFalse(skip.hidden);XCTAssertTrue(skip.enabled);XCTAssertFalse(collect.enabled);
    [skip sendActionsForControlEvents:UIControlEventTouchUpInside];XCTAssertTrue(collect.enabled);
    [collect sendActionsForControlEvents:UIControlEventTouchUpInside];
    NSPredicate *saved=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *unused){(void)object;(void)unused;return [page valueForKey:@"reportData"]!=nil;}];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[[[XCTNSPredicateExpectation alloc] initWithPredicate:saved object:page]] timeout:10],XCTWaiterResultCompleted);
    NSDictionary *report=[NSJSONSerialization JSONObjectWithData:[session savedReportData:&error] options:0 error:&error];
    XCTAssertEqualObjects(report[@"guidedCollection"][@"phases"][@"capacity"][@"state"],@"failed");
    XCTAssertEqualObjects(report[@"supportedImageCollection"][@"state"],@"skipped");
    XCTAssertEqualObjects(report[@"capacityMeasurement"][@"state"],@"notMeasured");
}
@end
