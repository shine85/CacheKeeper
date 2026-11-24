#import <XCTest/XCTest.h>
#import "ScanHostEvidenceBoundary.h"
#import "../../AxsCacheKeeperDiagnostics.h"
#import "../../Prefs/DiagnosticsPage.h"
// The visual harness already owns a CKScanPage navigation substitute. Compile the
// actual product implementation under an isolated class name, unchanged behavior.
#define CKScanPage AxsCacheKeeperActualScanPage
#define AxsCacheKeeperHostEvidenceClient AxsCacheKeeperScanHostClient
#import "../../Prefs/ScanPage.m"
#undef CKScanPage
#undef AxsCacheKeeperHostEvidenceClient

@interface AxsCacheKeeperScanFixture : AxsCacheKeeperActualScanPage
@property(nonatomic,copy) NSString *axs_cachekeeper_folder,*axs_cachekeeper_lastMessage;
@property(nonatomic) NSUInteger axs_cachekeeper_oldProbeCalls;
@property(nonatomic,strong) XCTestExpectation *axs_cachekeeper_appeared;
@end
@implementation AxsCacheKeeperScanFixture
- (NSString *)file:(NSString *)name {return [self.axs_cachekeeper_folder stringByAppendingPathComponent:name];}
- (void)message:(NSString *)text {self.axs_cachekeeper_lastMessage=text;}
- (void)axs_cachekeeper_begin_probe {self.axs_cachekeeper_oldProbeCalls++;[super axs_cachekeeper_begin_probe];}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];[self.axs_cachekeeper_appeared fulfill];self.axs_cachekeeper_appeared=nil;
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    NSLog(@"ScanPage lifecycle willDisappear moving=%d dismissed=%d topIsSelf=%d tokens=%lu",self.isMovingFromParentViewController,self.isBeingDismissed,self.navigationController.topViewController==self,(unsigned long)self.axs_cachekeeper_hostClient.axs_cachekeeper_activeTokenCount);
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    NSLog(@"ScanPage lifecycle didDisappear moving=%d dismissed=%d topIsSelf=%d tokens=%lu",self.isMovingFromParentViewController,self.isBeingDismissed,self.navigationController.topViewController==self,(unsigned long)self.axs_cachekeeper_hostClient.axs_cachekeeper_activeTokenCount);
}
@end
@interface AxsCacheKeeperCancelledPush : NSObject <UIViewControllerAnimatedTransitioning, UINavigationControllerDelegate>
@property(nonatomic,strong) XCTestExpectation *axs_cachekeeper_started,*axs_cachekeeper_finished;
@property(nonatomic,weak) UIViewController *axs_cachekeeper_target;
@end
@implementation AxsCacheKeeperCancelledPush
- (NSTimeInterval)transitionDuration:(id<UIViewControllerContextTransitioning>)context { (void)context;return 0.1; }
- (void)animateTransition:(id<UIViewControllerContextTransitioning>)context {
    UIViewController *from=[context viewControllerForKey:UITransitionContextFromViewControllerKey];
    UIViewController *to=[context viewControllerForKey:UITransitionContextToViewControllerKey];
    UIView *toView=[context viewForKey:UITransitionContextToViewKey];
    toView.frame=[context finalFrameForViewController:to];[context.containerView addSubview:toView];
    if (from.view) [context.containerView bringSubviewToFront:from.view];
    [self.axs_cachekeeper_started fulfill];self.axs_cachekeeper_started=nil;
    dispatch_async(dispatch_get_main_queue(), ^{ [context completeTransition:NO]; });
}
- (id<UIViewControllerAnimatedTransitioning>)navigationController:(UINavigationController *)navigation
    animationControllerForOperation:(UINavigationControllerOperation)operation fromViewController:(UIViewController *)from toViewController:(UIViewController *)to {
    (void)navigation;(void)from;(void)to;return operation==UINavigationControllerOperationPush ? self : nil;
}
- (void)navigationController:(UINavigationController *)navigation didShowViewController:(UIViewController *)controller animated:(BOOL)animated {
    (void)navigation;(void)animated;
    if (controller==self.axs_cachekeeper_target) { [self.axs_cachekeeper_finished fulfill];self.axs_cachekeeper_finished=nil; }
}
@end

@interface AxsCacheKeeperScanPageTests : XCTestCase <UINavigationControllerDelegate>
@property(nonatomic,strong) UIWindow *window,*previousWindow;
@property(nonatomic,strong) AxsCacheKeeperScanFixture *page;
@property(nonatomic,strong) AxsCacheKeeperHostEvidenceServer *server;
@property(nonatomic,weak) UINavigationController *expectedNavigation;
@property(nonatomic,weak) UIViewController *expectedController;
@property(nonatomic,strong) XCTestExpectation *navigationFinished;
@property(nonatomic,copy) NSString *folder;
@end
@implementation AxsCacheKeeperScanPageTests
- (void)setUp {
    [super setUp];axs_cachekeeper_scan_host_fail(AxsCacheKeeperScanHostFailureNone);self.folder=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:[self.folder stringByAppendingPathComponent:@"Status"] withIntermediateDirectories:YES attributes:nil error:NULL];
    self.page=[AxsCacheKeeperScanFixture new];self.page.axs_cachekeeper_folder=self.folder;self.page.bundle=[@"dev.local.scanpage." stringByAppendingString:[NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""]];self.page.appName=@"扫描测试";
    [@{self.page.bundle:@{@"enabled":@NO}} writeToFile:[self.page file:@"appEnabled.plist"] atomically:YES];
    XCTestExpectation *appeared=[self expectationWithDescription:@"UIKit completed ScanPage's initial appearance"];
    self.page.axs_cachekeeper_appeared=appeared;
    self.previousWindow=UIApplication.sharedApplication.delegate.window;self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];self.window.rootViewController=[[UINavigationController alloc] initWithRootViewController:self.page];[self.window makeKeyAndVisible];[self.page loadViewIfNeeded];
    [self waitForExpectations:@[appeared] timeout:5];
    XCTAssertEqual([self.page tableView:self.page.tableView numberOfRowsInSection:0],9);
}
- (void)navigationController:(UINavigationController *)navigationController didShowViewController:(UIViewController *)viewController animated:(BOOL)animated {
    (void)animated;
    if (self.navigationFinished && navigationController==self.expectedNavigation && viewController==self.expectedController) {
        [self.navigationFinished fulfill];self.navigationFinished=nil;self.expectedNavigation=nil;self.expectedController=nil;
    }
}
- (void)tearDown {
    [self.server axs_cachekeeper_invalidate];self.server=nil;[self.page.timer invalidate];[self.page.statusTimer invalidate];[self.page.axs_cachekeeper_hostClient axs_cachekeeper_cancel];
    XCTAssertEqual(axs_cachekeeper_scan_host_active_tokens(),0u);axs_cachekeeper_scan_host_fail(AxsCacheKeeperScanHostFailureNone);
    self.window.hidden=YES;self.window.rootViewController=nil;[self.previousWindow makeKeyWindow];self.page=nil;self.window=nil;
    [NSFileManager.defaultManager removeItemAtPath:self.folder error:NULL];[super tearDown];
}
- (NSDictionary *)axs_cachekeeper_progress:(NSString *)state {
    return @{@"state":state,@"slices":@2,@"entriesVisited":@10,@"rootsCompleted":@0,@"rootsTotal":@1,@"entryLimit":@100,@"sliceEntryLimit":@10,@"maxOpenDirectories":@2,@"wallTimeLimitSeconds":@300};
}
- (void)axs_cachekeeper_receipt:(NSString *)state error:(NSString *)error {
    NSMutableDictionary *diagnostics=axs_cachekeeper_scan_diagnostics_new();diagnostics[@"measurementComplete"]=@NO;
    NSMutableDictionary *record=[@{@"bundle":self.page.bundle,@"token":self.page.token,@"rows":@[],@"previousRows":@[],@"updated":NSDate.date,@"complete":@NO,@"scanDiagnostics":diagnostics,@"scanProgress":[self axs_cachekeeper_progress:state]} mutableCopy];
    if (error) record[@"error"]=error;
    XCTAssertTrue([record writeToURL:[NSURL fileURLWithPath:[self.page file:@"scan.plist"]] error:NULL]);
}
- (void)axs_cachekeeper_saveCleanupHistory {
    NSDictionary *context=axs_cachekeeper_cleanup_context(@"clean",YES,YES,NO,YES,@"0.7.2-188.1",@"1.0",@"110",@"platform-cache:2",@[],@[],@[]);
    NSDictionary *round=@{@"roundID":@"saved-round",@"finishedAt":[NSDate dateWithTimeIntervalSince1970:1700000000],
        @"removed":@3,@"bytes":@36,@"failed":@1,@"endReason":@4,@"coverageComplete":@NO,@"context":context,@"releaseEvidence":@{@"state":@"notRecorded"}};
    NSDictionary *report=@{@"removed":@3,@"bytes":@36,@"failed":@0,@"updated":[NSDate dateWithTimeIntervalSince1970:1700001000],
        @"confirmedRoundID":@"saved-round",@"cleanupContext":context,@"lastEffectiveCleanup":round,
        @"cleanupHistory":@{@"schemaVersion":@1,@"state":@"recorded",@"capacity":@16,@"truncatedCount":@0,@"rounds":@[round]}};
    XCTAssertTrue(([report writeToFile:[self.page file:[NSString stringWithFormat:@"Status/%@.auto.plist",self.page.bundle]] atomically:YES]));
}
- (void)axs_cachekeeper_assertHistoryWithHint:(NSString *)hint {
    self.page.displayCache=nil;
    UITableViewCell *cell=[self.page tableView:self.page.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
    NSString *text=cell.detailTextLabel.text;
    NSDateFormatter *formatter=[NSDateFormatter new];formatter.locale=[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.calendar=[[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    formatter.timeZone=NSTimeZone.localTimeZone;formatter.dateFormat=@"yyyy-MM-dd HH:mm:ss";
    NSString *savedTime=[formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:1700000000]];
    NSDictionary *facts=@{self.page.actionStatus:@1,hint:@1,@"累计清理 3 个":@1,@"最近一轮：":@1,@"最近实际清理：":@1,
        savedTime:@2,@"3 项 /":@2,@"只清理":@2,@"插件 0.7.2-188.1":@2,@"APP 1.0（构建 110）":@2,
        @"该轮失败 1 项":@2,@"该轮已中止":@2,@"该轮覆盖未完整":@2};
    for (NSString *fact in facts) {
        NSUInteger count=[text componentsSeparatedByString:fact].count-1;
        XCTAssertEqual(count,[facts[fact] unsignedIntegerValue],@"HISTORY_CONFIGURATION: expected saved fact %@ exactly %@ times in %@",fact,facts[fact],text);
    }
    XCTAssertTrue([text hasPrefix:[self.page.actionStatus stringByAppendingString:@"\n"]],@"HISTORY_CONFIGURATION: action status must remain the first line");
    XCTAssertTrue([text hasSuffix:hint],@"HISTORY_CONFIGURATION: current configuration hint must follow the retained history");
    NSRange total=[cell.detailTextLabel.text rangeOfString:@"累计清理 "];
    XCTAssertNotEqual(total.location,NSNotFound,@"HISTORY_CONFIGURATION: current hint must not erase cumulative cleanup");
    if (total.location!=NSNotFound) {
        XCTAssertEqualObjects([cell.detailTextLabel.attributedText attribute:NSForegroundColorAttributeName atIndex:total.location effectiveRange:NULL],UIColor.systemRedColor,@"The retained cumulative cleanup line must keep its red emphasis");
        XCTAssertNotEqualObjects([cell.detailTextLabel.attributedText attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL],UIColor.systemRedColor,@"Action status must not inherit the historical red range");
    }
}
- (void)testDisabledAppKeepsHistoricalSummaryAndActionStatus {
    [self axs_cachekeeper_saveCleanupHistory];self.page.actionStatus=@"操作状态：配置已保存";
    NSData *before=[NSData dataWithContentsOfFile:[self.page file:@"appEnabled.plist"]];
    [self axs_cachekeeper_assertHistoryWithHint:@"未开启；打开总开关、单项开启或一键开启后才生效"];
    XCTAssertEqualObjects(before,[NSData dataWithContentsOfFile:[self.page file:@"appEnabled.plist"]]);
}
- (void)testEnabledAppWithoutDirectoriesKeepsHistoricalSummaryAndActionStatus {
    [self axs_cachekeeper_saveCleanupHistory];self.page.actionStatus=@"操作状态：配置已保存";
    XCTAssertTrue(([@{self.page.bundle:@{@"enabled":@YES,@"autoDiscover":@NO}} writeToFile:[self.page file:@"appEnabled.plist"] atomically:YES]));
    XCTAssertTrue([@{} writeToFile:[self.page file:@"directories.plist"] atomically:YES]);
    NSData *before=[NSData dataWithContentsOfFile:[self.page file:@"appEnabled.plist"]];
    [self axs_cachekeeper_assertHistoryWithHint:@"总开关已开启；未选择文件清理目录，网络缓存按独立选项执行"];
    XCTAssertEqualObjects(before,[NSData dataWithContentsOfFile:[self.page file:@"appEnabled.plist"]]);
}
- (void)testRestrictionCopyNamesOnlyAdaptedDiskWriterScope {
    UITableViewCell *mode=[self.page tableView:self.page.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:1 inSection:0]];
    UITableViewCell *image=[self.page tableView:self.page.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:6 inSection:0]];
    NSString *modeCopy=[mode.contentView.subviews description];
    NSString *imageCopy=image.detailTextLabel.text;
    XCTAssertTrue([modeCopy containsString:@"SDWebImage"] || [imageCopy containsString:@"SDWebImage"]);
    XCTAssertTrue([imageCopy containsString:@"磁盘写入"]);
    XCTAssertTrue([imageCopy containsString:@"未知"]);
    XCTAssertFalse([imageCopy containsString:@"禁止所有"]);
    XCTAssertFalse([imageCopy containsString:@"任何磁盘写入"]);
    XCTAssertFalse([imageCopy containsString:@"所有网络缓存"]);
}
- (void)testRunningReceiptKeepsWaitingAndStopRetainsToken {
    [self.page scan];NSString *token=self.page.token;XCTAssertNotNil(self.page.timer);
    self.page.started=NSProcessInfo.processInfo.systemUptime-40;
    [self axs_cachekeeper_receipt:@"running" error:nil];[self.page check];
    XCTAssertNotNil(self.page.timer);XCTAssertTrue([self.page.title containsString:@"已计量"]);
    [self.page scan];NSDictionary *request=[NSDictionary dictionaryWithContentsOfFile:[self.page file:@"request.plist"]];
    XCTAssertEqualObjects(request[@"token"],token);XCTAssertEqualObjects(self.page.token,token);XCTAssertTrue([request[@"cancel"] boolValue]);XCTAssertNotNil(self.page.timer);XCTAssertEqualObjects(self.page.scanButton.title,@"正在停止");
    [self axs_cachekeeper_receipt:@"cancelled" error:nil];[self.page check];XCTAssertNil(self.page.timer);XCTAssertEqualObjects(self.page.title,self.page.appName);XCTAssertTrue(self.page.scanButton.enabled);
}
- (void)testSaveFailureStopsWaitingAndShowsRealFailure {
    [self.page scan];[self axs_cachekeeper_receipt:@"saveFailed" error:@"检测结果保存失败；本次未完成"];
    [self.page check];XCTAssertNil(self.page.timer);XCTAssertTrue([self.page.axs_cachekeeper_lastMessage containsString:@"保存失败"]);XCTAssertTrue(self.page.scanButton.enabled);
}
- (void)testRequestWriteFailureDoesNotStartTimer {
    [NSFileManager.defaultManager createDirectoryAtPath:[self.page file:@"request.plist"] withIntermediateDirectories:NO attributes:nil error:NULL];
    [self.page scan];XCTAssertNil(self.page.timer);XCTAssertTrue([self.page.axs_cachekeeper_lastMessage containsString:@"无法写入检测请求"]);
}
- (void)axs_cachekeeper_startServer {
    self.server=[[AxsCacheKeeperHostEvidenceServer alloc] initWithBundle:self.page.bundle folder:self.folder runtimeInfo:@{@"schemaVersion":@1,@"packageVersion":@"0.7.2-167.1",@"firstObserved":@1700000000}];
    [self.server axs_cachekeeper_observeContainer:YES authorizationAttempted:NO authorizationCode:0 sharedAccess:NO];(void)[self.server axs_cachekeeper_snapshot];
}
- (void)axs_cachekeeper_tapHost {
    NSIndexPath *path=[NSIndexPath indexPathForRow:7 inSection:0];
    UITableViewCell *cell=[self.page tableView:self.page.tableView cellForRowAtIndexPath:path];XCTAssertEqualObjects(cell.accessibilityIdentifier,@"CacheKeeperReadonlyHost");
    [self.page.tableView selectRowAtIndexPath:path animated:NO scrollPosition:UITableViewScrollPositionNone];[self.page tableView:self.page.tableView didSelectRowAtIndexPath:path];
}
- (void)axs_cachekeeper_waitHost {
    XCTestExpectation *done=[self expectationForPredicate:[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *bindings) {(void)object;(void)bindings;[self.page axs_cachekeeper_reload];return !self.page.axs_cachekeeper_hostPending;}] evaluatedWithObject:self.page handler:nil];
    [self waitForExpectations:@[done] timeout:5];
}
- (void)testDisabledAppReadonlyInteractionPreservesConfigAndUsesFullPackageVersion {
    [self axs_cachekeeper_startServer];NSData *before=[NSData dataWithContentsOfFile:[self.page file:@"appEnabled.plist"]];
    [self axs_cachekeeper_tapHost];[self axs_cachekeeper_waitHost];
    XCTAssertEqual(self.page.axs_cachekeeper_oldProbeCalls,0u);XCTAssertTrue([self.page.axs_cachekeeper_hostStatus containsString:@"currentVersion"]);XCTAssertEqual(self.page.axs_cachekeeper_hostClient.axs_cachekeeper_activeTokenCount,0u);
    XCTAssertEqualObjects(before,[NSData dataWithContentsOfFile:[self.page file:@"appEnabled.plist"]]);
    NSDictionary *record=[NSDictionary dictionaryWithContentsOfFile:[self.page file:[NSString stringWithFormat:@"Status/%@.hostObserved.plist",self.page.bundle]]];XCTAssertEqualObjects(record[@"state"],@"observed");XCTAssertFalse([record[@"data"][@"authorizationAttempted"] boolValue]);
    UITableViewCell *old=[self.page tableView:self.page.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:4 inSection:0]];XCTAssertEqualObjects(old.textLabel.text,@"检查网络限制");
    [self.page tableView:self.page.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:4 inSection:0]];XCTAssertEqual(self.page.axs_cachekeeper_oldProbeCalls,1u);XCTAssertFalse(self.page.probePending);XCTAssertTrue([self.page.probeStatus containsString:@"未开启"]);
}
- (void)testSavedInjectionConditionsRowIsReadonlyAndDoesNotStartOtherChecks {
    NSData *before=[NSData dataWithContentsOfFile:[self.page file:@"appEnabled.plist"]];
    UITableViewCell *cell=[self.page tableView:self.page.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:8 inSection:0]];
    XCTAssertEqualObjects(cell.accessibilityIdentifier,@"CacheKeeperSavedInjectionConditions");
    XCTAssertTrue([cell.detailTextLabel.text containsString:@"Choicy 保存条件"]);
    XCTAssertNil(self.page.axs_cachekeeper_hostClient);
    XCTAssertEqual(self.page.axs_cachekeeper_oldProbeCalls,0u);
    [self.page tableView:self.page.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:8 inSection:0]];
    XCTAssertNil(self.page.axs_cachekeeper_hostClient);
    XCTAssertEqual(self.page.axs_cachekeeper_oldProbeCalls,0u);
    XCTAssertEqualObjects(before,[NSData dataWithContentsOfFile:[self.page file:@"appEnabled.plist"]]);
}
- (void)testReadonlySaveFailureIsVisibleAndSeparateFromHost {
    [self axs_cachekeeper_startServer];NSString *path=[self.page file:[NSString stringWithFormat:@"Status/%@.hostObserved.plist",self.page.bundle]];
    [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:NO attributes:nil error:NULL];
    [self axs_cachekeeper_tapHost];[self axs_cachekeeper_waitHost];XCTAssertTrue([self.page.axs_cachekeeper_hostStatus containsString:@"面板观察保存失败"]);
    NSString *hostPath=[self.page file:[NSString stringWithFormat:@"Status/%@.host.plist",self.page.bundle]];
    BOOL hostExists=[NSFileManager.defaultManager fileExistsAtPath:hostPath];
    XCTAssertFalse(hostExists);
}
- (void)axs_cachekeeper_assertImmediateFailure:(AxsCacheKeeperScanHostFailure)failure {
    NSTimeInterval oldTime=NSDate.date.timeIntervalSince1970-60;
    NSDictionary *host=@{@"schemaVersion":@1,@"source":@"hostAutomatic",@"transportTrust":@"unauthenticated",@"updated":@(oldTime),@"runtimeInfo":@{@"schemaVersion":@1,@"packageVersion":@"0.7.2-154.1",@"firstObserved":@1700000000},@"existingContainerGatePassed":@YES,@"authorizationAttempted":@NO,@"sharedAccessGranted":@NO,@"authorizationCode":@0,@"configurationReadScope":@"appEnabled",@"configurationReadState":@"notPermitted",@"previousPublishState":@"notAttempted",@"previousPublishErrorCode":@0};
    NSString *observed=[self.page file:[NSString stringWithFormat:@"Status/%@.hostObserved.plist",self.page.bundle]];
    NSString *automatic=[self.page file:[NSString stringWithFormat:@"Status/%@.host.plist",self.page.bundle]];
    NSDictionary *previousObservation=@{@"source":@"panelObserved",@"state":@"observed",@"updated":@(oldTime),@"data":host};
    BOOL previousObservationSaved=[previousObservation writeToURL:[NSURL fileURLWithPath:observed] error:NULL];
    XCTAssertTrue(previousObservationSaved);XCTAssertTrue([host writeToURL:[NSURL fileURLWithPath:automatic] error:NULL]);
    NSData *automaticBefore=[NSData dataWithContentsOfFile:automatic],*configBefore=[NSData dataWithContentsOfFile:[self.page file:@"appEnabled.plist"]];
    NSString *resource=[self.page file:@"user-resource.bin"];NSData *resourceBefore=[@"retained app data" dataUsingEncoding:NSUTF8StringEncoding];XCTAssertTrue([resourceBefore writeToFile:resource atomically:YES]);
    axs_cachekeeper_scan_host_fail(failure);[self axs_cachekeeper_tapHost];
    XCTAssertFalse(self.page.axs_cachekeeper_hostPending);XCTAssertTrue(self.page.axs_cachekeeper_hostResultConsumed);XCTAssertTrue([self.page.axs_cachekeeper_hostStatus containsString:@"transportError"]);XCTAssertFalse([self.page.axs_cachekeeper_hostStatus containsString:@"154.1"]);
    NSDictionary *saved=[NSDictionary dictionaryWithContentsOfFile:observed];XCTAssertEqualObjects(saved[@"source"],@"panelObserved");XCTAssertEqualObjects(saved[@"state"],@"transportError");XCTAssertGreaterThan([saved[@"updated"] doubleValue],oldTime);XCTAssertNil(saved[@"data"]);
    NSData *terminalBefore=[NSData dataWithContentsOfFile:observed];[self.page axs_cachekeeper_reload];XCTAssertEqualObjects([NSData dataWithContentsOfFile:observed],terminalBefore);
    XCTAssertEqual(self.page.axs_cachekeeper_hostClient.axs_cachekeeper_activeTokenCount,0u);XCTAssertEqual(axs_cachekeeper_scan_host_active_tokens(),0u);
    NSUInteger expectedTokens=failure==AxsCacheKeeperScanHostFailureFirstRegister ? 0 : (failure==AxsCacheKeeperScanHostFailureSecondRegister ? 1 : 2);
    XCTAssertEqual(axs_cachekeeper_scan_host_cancel_calls(),expectedTokens);XCTAssertEqual(axs_cachekeeper_scan_host_register_calls(),failure==AxsCacheKeeperScanHostFailureFirstRegister ? 1u : 2u);
    NSDictionary *report=[[[AxsCacheKeeperDiagnostics alloc] initWithFolder:self.folder] reportWithApps:@[@{@"id":self.page.bundle}] environment:@{@"pluginVersion":@"0.7.2-167.1"}];
    NSDictionary *app=[report[@"apps"] firstObject],*record=app[@"hostObserved"][@"data"];
    XCTAssertEqualObjects(record[@"state"],@"transportError");XCTAssertEqualObjects(record[@"updated"],saved[@"updated"]);XCTAssertNil(record[@"data"]);
    XCTAssertEqualObjects(app[@"capabilities"][@"hostObserved"][@"observationState"],@"transportError");XCTAssertEqualObjects(app[@"capabilities"][@"hostObserved"][@"runtimeVersionState"],@"notRecorded");
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:automatic],automaticBefore);XCTAssertEqualObjects([NSData dataWithContentsOfFile:[self.page file:@"appEnabled.plist"]],configBefore);XCTAssertEqualObjects([NSData dataWithContentsOfFile:resource],resourceBefore);XCTAssertEqual(self.page.axs_cachekeeper_oldProbeCalls,0u);
    NSData *json=[NSJSONSerialization dataWithJSONObject:report options:0 error:NULL];XCTAssertNotNil(json);
}
- (void)testReadonlyFirstRegistrationFailureReplacesOldObserved { [self axs_cachekeeper_assertImmediateFailure:AxsCacheKeeperScanHostFailureFirstRegister]; }
- (void)testReadonlySecondRegistrationFailureReplacesOldObserved { [self axs_cachekeeper_assertImmediateFailure:AxsCacheKeeperScanHostFailureSecondRegister]; }
- (void)testReadonlySetFailureReplacesOldObserved { [self axs_cachekeeper_assertImmediateFailure:AxsCacheKeeperScanHostFailureSet]; }
- (void)testReadonlyPostFailureReplacesOldObserved { [self axs_cachekeeper_assertImmediateFailure:AxsCacheKeeperScanHostFailurePost]; }
- (void)testReplacingHostRequestCancelsPreviousClient {
    [self axs_cachekeeper_tapHost];AxsCacheKeeperScanHostClient *previous=self.page.axs_cachekeeper_hostClient;[self axs_cachekeeper_tapHost];XCTAssertEqual(previous.axs_cachekeeper_activeTokenCount,0u);XCTAssertEqualObjects([previous axs_cachekeeper_poll][@"state"],@"cancelled");
}
- (void)testOverdueHostRequestReleasesTokens {
    [self axs_cachekeeper_tapHost];
    // Exercise the real client's existing deadline branch as if UIKit returned after suspension.
    [self.page.axs_cachekeeper_hostClient setValue:@(NSProcessInfo.processInfo.systemUptime-1) forKey:@"axs_cachekeeper_deadline"];
    [self.page axs_cachekeeper_reload];XCTAssertTrue([self.page.axs_cachekeeper_hostStatus containsString:@"timedOut"]);XCTAssertEqual(self.page.axs_cachekeeper_hostClient.axs_cachekeeper_activeTokenCount,0u);
}
- (void)testViewWillDisappearKeepsRequestUntilDepartureCompletes {
    [self axs_cachekeeper_tapHost];[self.page beginAppearanceTransition:NO animated:NO];
    XCTAssertGreaterThan(self.page.axs_cachekeeper_hostClient.axs_cachekeeper_activeTokenCount,0u);
    [self.page endAppearanceTransition];
    XCTAssertGreaterThan(self.page.axs_cachekeeper_hostClient.axs_cachekeeper_activeTokenCount,0u);
}
- (void)testCompletedPushReleasesHostRequest {
    [self axs_cachekeeper_tapHost];
    XCTAssertGreaterThan(self.page.axs_cachekeeper_hostClient.axs_cachekeeper_activeTokenCount,0u);
    UINavigationController *navigation=self.page.navigationController;UIViewController *detail=[UIViewController new];
    XCTestExpectation *shown=[self expectationWithDescription:@"UIKit completed the navigation away from ScanPage"];
    self.expectedNavigation=navigation;self.expectedController=detail;self.navigationFinished=shown;navigation.delegate=self;
    [navigation pushViewController:detail animated:NO];[self waitForExpectations:@[shown] timeout:5];
    XCTAssertEqual(navigation.viewControllers.firstObject,self.page);
    XCTAssertEqual(self.page.axs_cachekeeper_hostClient.axs_cachekeeper_activeTokenCount,0u);
}
- (void)testWholeContainerEntryOpensSeparateReadOnlyPage {
    UIBarButtonItem *entry=self.page.navigationItem.leftBarButtonItem;
    XCTAssertNotNil(entry);XCTAssertNotEqual(entry.target,nil);
    [UIApplication.sharedApplication sendAction:entry.action to:entry.target from:entry forEvent:nil];
    XCTAssertTrue([self.page.navigationController.topViewController isKindOfClass:AxsCacheKeeperDiagnosticsPage.class]);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[self.page file:@"request.plist"]]);
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[self.page file:@"appEnabled.plist"]][self.page.bundle][@"enabled"],@NO);
}
- (void)testCompletedPopReleasesHostRequest {
    UINavigationController *navigation=self.page.navigationController;UIViewController *root=[UIViewController new];
    [navigation setViewControllers:@[root,self.page] animated:NO];[self axs_cachekeeper_tapHost];
    XCTestExpectation *shown=[self expectationWithDescription:@"UIKit completed the navigation pop from ScanPage"];
    self.expectedNavigation=navigation;self.expectedController=root;self.navigationFinished=shown;navigation.delegate=self;
    [navigation popViewControllerAnimated:NO];[self waitForExpectations:@[shown] timeout:5];
    XCTAssertEqual(navigation.topViewController,root);XCTAssertEqual(self.page.axs_cachekeeper_hostClient.axs_cachekeeper_activeTokenCount,0u);
}
- (void)testCompletedModalPresentationReleasesHostRequest {
    [self axs_cachekeeper_tapHost];UIViewController *modal=[UIViewController new];
    modal.modalPresentationStyle=UIModalPresentationFullScreen;
    XCTestExpectation *shown=[self expectationWithDescription:@"UIKit completed the modal presentation"];
    [self.page presentViewController:modal animated:NO completion:^{ [shown fulfill]; }];[self waitForExpectations:@[shown] timeout:5];
    XCTAssertEqual(self.page.axs_cachekeeper_hostClient.axs_cachekeeper_activeTokenCount,0u);
    [self.page dismissViewControllerAnimated:NO completion:nil];
}
- (void)testCancelledPushKeepsHostRequest {
    [self axs_cachekeeper_tapHost];UINavigationController *navigation=self.page.navigationController;UIViewController *detail=[UIViewController new];
    AxsCacheKeeperCancelledPush *transition=[AxsCacheKeeperCancelledPush new];
    XCTestExpectation *started=[self expectationWithDescription:@"UIKit started the push transition"];
    XCTestExpectation *returned=[self expectationWithDescription:@"UIKit restored ScanPage after cancelled push"];
    transition.axs_cachekeeper_started=started;transition.axs_cachekeeper_finished=returned;transition.axs_cachekeeper_target=self.page;navigation.delegate=transition;
    [navigation pushViewController:detail animated:YES];[self waitForExpectations:@[started,returned] timeout:10];
    XCTAssertEqual(navigation.topViewController,self.page);XCTAssertGreaterThan(self.page.axs_cachekeeper_hostClient.axs_cachekeeper_activeTokenCount,0u);
}
@end
