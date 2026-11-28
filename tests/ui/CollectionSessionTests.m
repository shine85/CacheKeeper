#import <XCTest/XCTest.h>
#import "../../AxsCacheKeeperCollectionSession.h"
#import "../../AxsCacheKeeperImageCollection.h"
#import "../../AxsCacheKeeperOperationInfo.h"
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
- (void)axs_write_receipt:(NSDictionary *)receipt path:(NSString *)path {
    NSMutableDictionary *pending=nil;BOOL writable=NO;
    XCTAssertTrue(axs_cachekeeper_operation_save(receipt,path,YES,&pending,&writable));
    XCTAssertNil(pending);XCTAssertTrue(writable);
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:path],receipt,@"producer transport preserves fractional receipt date");
}
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
- (void)testCapacityRetryPersistsRunningAndBackgroundKeepsOriginalEpoch {
    AxsCacheKeeperCollectionSession *session=[self axs_collection_session];NSError *error=nil;
    XCTAssertTrue([session beginPhase:@"capacity" error:&error]);
    XCTAssertTrue(([session finishPhase:@"capacity" result:@{@"state":@"interrupted",@"epoch":@"previous",
        @"terminalSource":@"clientLifecycle",@"observedAt":@1} error:&error]));
    AxsCollectionDiagnosticsFixture *page=[[AxsCollectionDiagnosticsFixture alloc] initWithCollectionSessionObject:session];page.axs_collection_folder=self.axs_cachekeeper_folder;
    UINavigationController *navigation=[[UINavigationController alloc] initWithRootViewController:page];
    [page loadViewIfNeeded];
    UIButton *button=[page valueForKey:@"axs_cachekeeper_capacityButton"];
    XCTAssertNotNil(button.superview);XCTAssertFalse(button.hidden);XCTAssertTrue(button.enabled);
    [page axs_cachekeeper_capacity_action];
    XCTAssertEqualObjects(session.reportProjection[@"phases"][@"capacity"][@"state"],@"running");
    NSDictionary *request=[NSDictionary dictionaryWithContentsOfFile:[self.axs_cachekeeper_folder stringByAppendingPathComponent:@"capacityRequest.plist"]];
    XCTAssertEqualObjects(request[@"operation"],@"start");XCTAssertNotNil(request[@"epoch"]);
    [page axs_cachekeeper_capacity_background:nil];
    NSDictionary *phase=session.reportProjection[@"phases"][@"capacity"];
    XCTAssertEqualObjects(phase[@"state"],@"running");
    XCTAssertEqualObjects(phase[@"request"][@"epoch"],request[@"epoch"]);
    [page viewDidDisappear:NO];XCTAssertEqual(navigation.topViewController,page);
    request=[NSDictionary dictionaryWithContentsOfFile:[self.axs_cachekeeper_folder stringByAppendingPathComponent:@"capacityRequest.plist"]];
    XCTAssertEqualObjects(request[@"operation"],@"start");
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];
    [page viewDidAppear:NO];
    XCTAssertNotNil(button.superview);XCTAssertFalse(button.hidden);XCTAssertTrue(button.enabled);
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
- (void)testCapacityDelayKeepsStaleSDKSelectableThenForegroundRefreshRequiresConfirmation {
    AxsCacheKeeperCollectionSession *session=[self axs_collection_session];NSError *error=nil;
    AxsCollectionLiveDiagnosticsFixture *page=[[AxsCollectionLiveDiagnosticsFixture alloc] initWithCollectionSessionObject:session];page.axs_collection_folder=self.axs_cachekeeper_folder;
    page.applicationNames=@{AxsCacheKeeperImageCollectionBundle:@"图片测试 APP"};
    UINavigationController *navigation=[[UINavigationController alloc] initWithRootViewController:page];[page loadViewIfNeeded];
    [page viewDidAppear:NO];
    NSString *epoch=[NSDictionary dictionaryWithContentsOfFile:[self.axs_cachekeeper_folder stringByAppendingPathComponent:@"capacityRequest.plist"]][@"epoch"];
    NSDictionary *terminal=@{@"schemaVersion":@1,@"epoch":epoch,@"state":@"partial",@"sourceSampledAt":@0,@"startedAt":@1,@"updatedAt":@602,@"finishedAt":@602,
        @"totalRoots":@0,@"completedRoots":@0,@"failedRoots":@0,@"excludedBundles":@[@"com.tencent.qy.xin"],@"registry":axs_cachekeeper_registry_inventory_projection(nil),
        @"roots":@[],@"entries":@[],@"deletionAuthorization":@"notGranted",@"physicalUniqueBytes":@"notMeasured",@"reclaimableBytes":@"notMeasured",@"freshness":@"savedObservationUnverified",@"measurementWindow":@"nonAtomicTraversal",@"installationMatch":@"notRevalidatedAtExport"};
    XCTAssertTrue([terminal writeToFile:[self.axs_cachekeeper_folder stringByAppendingPathComponent:@"capacityResult.plist"] atomically:YES]);[page axs_cachekeeper_capacity_poll];
    NSPredicate *capacitySaved=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *unused){(void)object;(void)unused;return [session.reportProjection[@"phases"][@"capacity"][@"state"] isEqual:@"partial"];}];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[[[XCTNSPredicateExpectation alloc] initWithPredicate:capacitySaved object:session]] timeout:5],XCTWaiterResultCompleted);
    NSString *bundle=AxsCacheKeeperImageCollectionBundle,*statesPath=[self.axs_cachekeeper_folder stringByAppendingPathComponent:@"appEnabled.plist"];
    NSMutableDictionary *states=[NSMutableDictionary new];states[bundle]=@{@"enabled":@YES,@"mode":@"clean",@"autoDiscover":@YES};
    for (NSUInteger i=0;i<139;i++) states[[NSString stringWithFormat:@"disabled.app%lu",(unsigned long)i]]=@NO;
    XCTAssertTrue([states writeToFile:statesPath atomically:YES]);NSData *settings=[NSData dataWithContentsOfFile:statesPath];
    XCTAssertTrue([@{} writeToFile:[self.axs_cachekeeper_folder stringByAppendingPathComponent:@"directories.plist"] atomically:YES]);
    NSString *status=[self.axs_cachekeeper_folder stringByAppendingPathComponent:@"Status"];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtPath:status withIntermediateDirectories:YES attributes:nil error:&error]);
    NSString *receiptPath=[status stringByAppendingPathComponent:[bundle stringByAppendingString:@".imagecache.plist"]];
    NSMutableDictionary *receipt=[@{@"schemaVersion":@1,@"sdk":@"SDWebImage",@"state":@"ready",@"reason":@"none",@"observed":@1,@"eligible":@1,@"restricted":@0,
        @"writesBlocked":@0,@"queued":@0,@"submitted":@0,@"apiCompleted":@0,@"skipped":@0,@"pending":@0,@"updated":[NSDate dateWithTimeIntervalSinceNow:-601],
        @"bytesState":@"notMeasured",@"runtimeInfo":@{@"schemaVersion":@1,@"packageVersion":@"0.7.2-221.1",@"firstObserved":@1}} mutableCopy];
    [self axs_write_receipt:receipt path:receiptPath];
    [(UIButton *)[page valueForKey:@"axs_cachekeeper_imageCollectionButton"] sendActionsForControlEvents:UIControlEventTouchUpInside];
    AxsCacheKeeperImageCollectionPage *image=(id)navigation.topViewController;[image loadViewIfNeeded];
    AxsCacheKeeperImageCollectionSession *imageSession=[image valueForKey:@"session"];
    NSArray *modules=[imageSession availableModules:&error];XCTAssertEqual(modules.count,1u);XCTAssertEqualObjects(modules[0][@"state"],@"requiresRefresh");
    // Invoke the same selection callback used by the APP action sheet; no request is created here.
    [image axs_start_bundle:bundle];
    NSPredicate *readFinished=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *unused){(void)object;(void)unused;return ![[image valueForKey:@"preparationReading"] boolValue];}];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[[[XCTNSPredicateExpectation alloc] initWithPredicate:readFinished object:image]] timeout:5],XCTWaiterResultCompleted);
    XCTAssertEqualObjects([image valueForKey:@"preparationStatus"][@"state"],@"awaitingRefresh");
    NSString *text=((UITextView *)[image valueForKey:@"text"]).text;
    XCTAssertTrue([text containsString:@"图片测试 APP"]);XCTAssertFalse([text containsString:@"disabled.app138"]);XCTAssertLessThan(text.length,1500u);
    NSString *requestPath=[self.axs_cachekeeper_folder stringByAppendingPathComponent:@"imageCollectionRequest.plist"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:requestPath]);XCTAssertFalse([[image valueForKey:@"nextButton"] isEnabled]);
    receipt[@"updated"]=NSDate.date;receipt[@"runtimeInfo"]=@{@"schemaVersion":@1,@"packageVersion":@"0.7.2-221.1",@"firstObserved":@2};
    [self axs_write_receipt:receipt path:receiptPath];
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];
    NSPredicate *ready=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *unused){(void)object;(void)unused;return [[image valueForKey:@"preparationStatus"][@"state"] isEqual:@"readyToStart"];}];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[[[XCTNSPredicateExpectation alloc] initWithPredicate:ready object:image]] timeout:5],XCTWaiterResultCompleted);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:requestPath]);
    UIButton *start=[image valueForKey:@"startButton"];XCTAssertEqualObjects([start titleForState:UIControlStateNormal],@"确认开始图片阶段");[start sendActionsForControlEvents:UIControlEventTouchUpInside];
    NSDictionary *request=axs_cachekeeper_image_collection_read(self.axs_cachekeeper_folder,&error);
    XCTAssertEqualObjects(request[@"sessionID"],session.sessionID);XCTAssertEqualObjects(request[@"processFirstObserved"],@2);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:statesPath],settings);
    NSData *leaseBefore=[NSData dataWithContentsOfFile:requestPath];
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidEnterBackgroundNotification object:nil];
    [image viewWillDisappear:NO];[image viewDidDisappear:NO];
    XCTAssertNil(image.view.window);XCTAssertTrue([navigation.viewControllers containsObject:image]);
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:requestPath],leaseBefore,@"normal app switch preserves exact request and original expiry");
    [navigation popViewControllerAnimated:NO];[image viewDidDisappear:NO];[page viewDidAppear:NO];
    XCTAssertEqual(navigation.topViewController,page,@"ordinary back remains on parent instead of reopening image page");
    XCTAssertEqualObjects(axs_cachekeeper_image_collection_read(self.axs_cachekeeper_folder,&error)[@"phase"],@"restore");
    leaseBefore=[NSData dataWithContentsOfFile:requestPath];
    AxsCacheKeeperCollectionSession *reopened=[AxsCacheKeeperCollectionSession openSessionAtPath:self.axs_cachekeeper_path error:&error];
    NSArray *resumable=[AxsCacheKeeperCollectionSession resumableSessionsInDirectory:self.axs_cachekeeper_folder error:&error];
    XCTAssertTrue(([@[@"imagePreparation",@"imageCollection"] containsObject:resumable.firstObject[@"nextPhase"]]));
    AxsCollectionLiveDiagnosticsFixture *resumed=[[AxsCollectionLiveDiagnosticsFixture alloc] initWithCollectionSessionObject:reopened];resumed.axs_collection_folder=self.axs_cachekeeper_folder;
    UINavigationController *resumedNavigation=[[UINavigationController alloc] initWithRootViewController:resumed];[resumed loadViewIfNeeded];[resumed viewDidAppear:NO];
    XCTAssertTrue([resumedNavigation.topViewController isKindOfClass:AxsCacheKeeperImageCollectionPage.class]);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:requestPath],leaseBefore,@"restoring current stage never renews or replays lease");
    navigation=resumedNavigation;page=resumed;session=reopened;image=(id)resumedNavigation.topViewController;[image loadViewIfNeeded];
    [(UIButton *)[image valueForKey:@"cancelButton"] sendActionsForControlEvents:UIControlEventTouchUpInside];
    request=axs_cachekeeper_image_collection_read(self.axs_cachekeeper_folder,&error);XCTAssertEqualObjects(request[@"phase"],@"restore");
    NSDictionary *base=@{@"valid":@YES,@"bundle":bundle,@"appState":states[bundle],@"selected":@[],@"installation":@"fixture-installation",@"processFirstObserved":@2};
    receipt[@"imageCollection"]=axs_cachekeeper_image_collection_context(base,request,NSDate.date.timeIntervalSince1970)[@"imageCollection"];receipt[@"updated"]=NSDate.date;
    [self axs_write_receipt:receipt path:receiptPath];[NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];
    [navigation popViewControllerAnimated:NO];[page viewDidAppear:NO];
    [(UIButton *)[page valueForKey:@"collectButton"] sendActionsForControlEvents:UIControlEventTouchUpInside];
    NSPredicate *saved=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *unused){(void)object;(void)unused;return [page valueForKey:@"reportData"]!=nil;}];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[[[XCTNSPredicateExpectation alloc] initWithPredicate:saved object:page]] timeout:10],XCTWaiterResultCompleted);
    NSDictionary *report=[NSJSONSerialization JSONObjectWithData:[session savedReportData:&error] options:0 error:&error];
    XCTAssertEqualObjects(report[@"supportedImageCollection"][@"preparation"][@"previousProcess"],@1);
    XCTAssertEqualObjects(report[@"supportedImageCollection"][@"restoration"][@"state"],@"hostConfirmed");
}
- (void)testMainContinueEntryPassesExistingApplicationNamesWithoutStartingAnotherSession {
    UIViewController *root=[NSClassFromString(@"CKSettings") new];UINavigationController *navigation=[[UINavigationController alloc] initWithRootViewController:root];
    [root loadViewIfNeeded];[root setValue:@[@{@"id":@"com.baidu.netdisk",@"name":@"图片测试 APP"}] forKey:@"apps"];
    UIBarButtonItem *continuation=nil;
    for (UIBarButtonItem *item in root.navigationItem.rightBarButtonItems) if ([item.title isEqual:@"继续采集"]) continuation=item;
    XCTAssertNotNil(continuation);XCTAssertTrue([UIApplication.sharedApplication sendAction:continuation.action to:continuation.target from:continuation forEvent:nil]);
    AxsCacheKeeperDiagnosticsPage *page=(id)navigation.topViewController;XCTAssertTrue([page isKindOfClass:AxsCacheKeeperDiagnosticsPage.class]);
    XCTAssertEqualObjects(page.applicationNames[@"com.baidu.netdisk"],@"图片测试 APP");
    XCTAssertTrue([[page valueForKey:@"axs_cachekeeper_presentResumePending"] boolValue]);
    XCTAssertNil([page valueForKey:@"axs_cachekeeper_collectionSession"]);
}
@end
