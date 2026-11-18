#import <XCTest/XCTest.h>
#import <WebKit/WebKit.h>
#import "../../AxsCacheKeeperWebKitCache.h"
#import "../../AxsCacheKeeperWebKitObservation.h"
#import "../../AxsCacheKeeperWebKitCoordinator.h"
@interface AxsCacheKeeperObservedWebView : WKWebView
@property(nonatomic) NSUInteger configurationReads;
@end
@implementation AxsCacheKeeperObservedWebView
- (WKWebViewConfiguration *)configuration {
    self.configurationReads++;
    return [super configuration];
}
@end

static NSDictionary *axs_cachekeeper_webkit_test_context(void) {
    return @{@"readable":@YES,@"valid":@YES,@"enabled":@YES,@"requested":@YES,@"excludedPaths":@[],
        @"installation":@"owned-test-install",@"process":@"owned-test-process",@"reportWritable":@YES};
}

@interface AxsCacheKeeperWebKitBridgeFixture : NSObject
@property(nonatomic,strong) AxsCacheKeeperWebKitCoordinator *coordinator;
@property(nonatomic,strong) NSMutableArray *reads,*expirations,*deadlines;
@property(nonatomic,strong) NSMutableSet *tasks;
@property(nonatomic) NSTimeInterval now,remaining;
@property(nonatomic) NSUInteger nextTask;
@property(nonatomic) BOOL grant,background,expireSynchronously;
@property(nonatomic,copy) void (^duringBegin)(void);
- (void)reply:(NSUInteger)index context:(NSDictionary *)context;
- (AxsCacheKeeperObservedWebView *)readyView;
@end
@implementation AxsCacheKeeperWebKitBridgeFixture
- (instancetype)init {
    self=[super init];if (!self) return nil;
    _reads=[NSMutableArray new];_expirations=[NSMutableArray new];_deadlines=[NSMutableArray new];_tasks=[NSMutableSet new];
    _now=100;_remaining=30;_grant=YES;_background=YES;
    __weak typeof(self) weakSelf=self;
    _coordinator=[[AxsCacheKeeperWebKitCoordinator alloc] initWithReader:^(void (^reply)(NSDictionary *)) {
        [weakSelf.reads addObject:[reply copy]];
    } beginBackground:^NSUInteger(void (^expiration)(void)) {
        AxsCacheKeeperWebKitBridgeFixture *self=weakSelf;
        [self.expirations addObject:[expiration copy]];
        if (!self.grant) return 0;
        NSUInteger token=++self.nextTask;[self.tasks addObject:@(token)];
        void (^duringBegin)(void)=self.duringBegin;self.duringBegin=nil;if (duringBegin) duringBegin();
        if (self.expireSynchronously) expiration();return token;
    } endBackground:^(NSUInteger task) {[weakSelf.tasks removeObject:@(task)];}
    backgroundTime:^BOOL(NSUInteger task) {return weakSelf.background && weakSelf.remaining>1 && [weakSelf.tasks containsObject:@(task)];}
    clock:^{return weakSelf.now;} scheduler:^(NSTimeInterval delay,void (^deadline)(void)) {
        (void)delay;[weakSelf.deadlines addObject:[deadline copy]];
    } observer:^(NSDictionary *receipt) {NSAssert(axs_cachekeeper_webkit_projection(receipt)!=nil,@"Bridge receipt must obey the production schema");}];
    return self;
}
- (void)reply:(NSUInteger)index context:(NSDictionary *)context {
    NSAssert(index<self.reads.count,@"Missing production read completion");
    ((void (^)(NSDictionary *))self.reads[index])(context);
}
- (AxsCacheKeeperObservedWebView *)readyView {
    [self.coordinator configureWithAuthorization:YES];[self reply:0 context:axs_cachekeeper_webkit_test_context()];
    [self.coordinator didBecomeActive];[self reply:1 context:axs_cachekeeper_webkit_test_context()];
    AxsCacheKeeperObservedWebView *view=[[AxsCacheKeeperObservedWebView alloc] initWithFrame:CGRectZero configuration:[WKWebViewConfiguration new]];
    [self.coordinator captureCreatedWebView:view];return view;
}
@end

@interface AxsCacheKeeperWebKitProbeTests : XCTestCase
@end
@implementation AxsCacheKeeperWebKitProbeTests
- (void)testProductionBridgeInitialConfigurationWaitExpiresWithoutTask {
    AxsCacheKeeperWebKitBridgeFixture *fixture=[AxsCacheKeeperWebKitBridgeFixture new];
    AxsCacheKeeperObservedWebView *view=[fixture readyView];
    [fixture.coordinator configureWithAuthorization:YES];[fixture.coordinator didEnterBackground];
    XCTAssertEqual(fixture.deadlines.count,1u);XCTAssertEqual(fixture.expirations.count,0u);
    XCTAssertTrue(fixture.coordinator.cache.hasPendingWork);
    fixture.now+=10;((void (^)(void))fixture.deadlines[0])();
    XCTAssertEqualObjects(fixture.coordinator.cache.receipt[@"reason"],@"deadlineExceeded");
    XCTAssertFalse(fixture.coordinator.cache.hasPendingWork);
    [fixture reply:2 context:axs_cachekeeper_webkit_test_context()];
    XCTAssertEqual(fixture.expirations.count,0u);XCTAssertEqual(fixture.tasks.count,0u);
    XCTAssertEqualObjects(fixture.coordinator.cache.receipt[@"submitted"],@0);
    XCTAssertEqualObjects(fixture.coordinator.cache.receipt[@"reason"],@"deadlineExceeded");
    (void)view;
}
- (void)testProductionBridgeFirstStoreInheritsInitialWaitDeadline {
    AxsCacheKeeperWebKitBridgeFixture *fixture=[AxsCacheKeeperWebKitBridgeFixture new];
    AxsCacheKeeperObservedWebView *view=[fixture readyView];
    [fixture.coordinator configureWithAuthorization:YES];[fixture.coordinator didEnterBackground];
    fixture.now+=9;[fixture reply:2 context:axs_cachekeeper_webkit_test_context()];
    XCTAssertEqual(fixture.expirations.count,1u);XCTAssertEqual(fixture.reads.count,4u);
    XCTAssertEqual(fixture.deadlines.count,2u);
    ((void (^)(void))fixture.deadlines[0])();
    XCTAssertEqualObjects(fixture.coordinator.cache.receipt[@"state"],@"queued");
    fixture.now+=1;[fixture reply:3 context:axs_cachekeeper_webkit_test_context()];
    XCTAssertEqualObjects(fixture.coordinator.cache.receipt[@"reason"],@"deadlineExceeded");
    XCTAssertEqualObjects(fixture.coordinator.cache.receipt[@"submitted"],@0);
    ((void (^)(void))fixture.expirations[0])();(void)view;
}
- (void)testProductionBridgeOldInitialWaitTimerCannotExpireNewBackground {
    AxsCacheKeeperWebKitBridgeFixture *fixture=[AxsCacheKeeperWebKitBridgeFixture new];
    AxsCacheKeeperObservedWebView *view=[fixture readyView];
    [fixture.coordinator configureWithAuthorization:YES];[fixture.coordinator didEnterBackground];
    void (^oldDeadline)(void)=fixture.deadlines[0];
    [fixture.coordinator configureWithAuthorization:NO];
    NSMutableDictionary *closed=[axs_cachekeeper_webkit_test_context() mutableCopy];closed[@"requested"]=@NO;
    [fixture reply:3 context:closed];fixture.now+=10;oldDeadline();
    XCTAssertEqualObjects(fixture.coordinator.cache.receipt[@"reason"],@"notAuthorized");
    XCTAssertFalse(fixture.coordinator.cache.hasPendingWork);XCTAssertEqual(fixture.tasks.count,0u);
    [fixture.coordinator configureWithAuthorization:YES];[fixture reply:4 context:axs_cachekeeper_webkit_test_context()];
    [fixture.coordinator didBecomeActive];[fixture reply:5 context:axs_cachekeeper_webkit_test_context()];
    [fixture.coordinator captureCreatedWebView:view];[fixture.coordinator didEnterBackground];
    oldDeadline();[fixture reply:2 context:axs_cachekeeper_webkit_test_context()];
    XCTAssertEqualObjects(fixture.coordinator.cache.receipt[@"state"],@"queued");XCTAssertEqual(fixture.tasks.count,1u);
    ((void (^)(void))fixture.expirations.lastObject)();
}
- (void)testProductionBridgeEqualReadRevocationAndRecovery {
    AxsCacheKeeperWebKitBridgeFixture *fixture=[AxsCacheKeeperWebKitBridgeFixture new];
    AxsCacheKeeperObservedWebView *view=[fixture readyView];
    [fixture.coordinator didEnterBackground];
    XCTAssertEqual(fixture.reads.count,3u);XCTAssertEqualObjects(fixture.coordinator.cache.receipt[@"state"],@"queued");
    [fixture.coordinator configureWithAuthorization:YES];
    [fixture reply:2 context:axs_cachekeeper_webkit_test_context()];
    XCTAssertEqualObjects(fixture.coordinator.cache.receipt[@"submitted"],@0);
    [fixture reply:3 context:axs_cachekeeper_webkit_test_context()];
    XCTAssertEqual(fixture.reads.count,5u);XCTAssertEqual(fixture.deadlines.count,1u);
    view.configurationReads=0;[fixture.coordinator configureWithAuthorization:NO];
    [fixture.coordinator captureCreatedWebView:view];
    [fixture reply:4 context:axs_cachekeeper_webkit_test_context()];
    XCTAssertEqual(view.configurationReads,0u);XCTAssertEqualObjects(fixture.coordinator.cache.receipt[@"submitted"],@0);
    NSMutableDictionary *closed=[axs_cachekeeper_webkit_test_context() mutableCopy];closed[@"requested"]=@NO;
    [fixture reply:5 context:closed];
    XCTAssertFalse(fixture.coordinator.observation.observing);XCTAssertFalse(fixture.coordinator.cache.hasPendingWork);
    XCTAssertEqual(fixture.tasks.count,0u);
    [fixture.coordinator configureWithAuthorization:YES];[fixture reply:6 context:axs_cachekeeper_webkit_test_context()];
    [fixture.coordinator didBecomeActive];[fixture reply:7 context:axs_cachekeeper_webkit_test_context()];
    XCTAssertEqualObjects(fixture.coordinator.cache.receipt[@"reason"],@"foregroundAgain");
    [fixture.coordinator captureCreatedWebView:view];[fixture.coordinator didEnterBackground];
    XCTAssertEqualObjects(fixture.coordinator.cache.receipt[@"state"],@"queued");
    XCTAssertEqual(fixture.reads.count,9u);XCTAssertEqual(fixture.tasks.count,1u);
    ((void (^)(void))fixture.expirations.lastObject)();
}
- (void)testProductionBridgePreparationExpiryAndOldTaskEpoch {
    AxsCacheKeeperWebKitBridgeFixture *fixture=[AxsCacheKeeperWebKitBridgeFixture new];
    AxsCacheKeeperObservedWebView *view=[fixture readyView];
    [fixture.coordinator didEnterBackground];
    void (^oldExpiration)(void)=fixture.expirations[0];
    fixture.now+=10;((void (^)(void))fixture.deadlines[0])();
    XCTAssertEqualObjects(fixture.coordinator.cache.receipt[@"reason"],@"deadlineExceeded");
    [fixture reply:2 context:axs_cachekeeper_webkit_test_context()];
    XCTAssertEqualObjects(fixture.coordinator.cache.receipt[@"submitted"],@0);
    [fixture.coordinator didBecomeActive];[fixture reply:3 context:axs_cachekeeper_webkit_test_context()];
    XCTAssertEqualObjects(fixture.coordinator.cache.receipt[@"reason"],@"foregroundAgain");
    [fixture.coordinator captureCreatedWebView:view];[fixture.coordinator didEnterBackground];
    oldExpiration();((void (^)(void))fixture.deadlines[0])();
    XCTAssertEqualObjects(fixture.coordinator.cache.receipt[@"state"],@"queued");
    XCTAssertEqual(fixture.tasks.count,1u);XCTAssertTrue([fixture.tasks containsObject:@2]);
    ((void (^)(void))fixture.expirations[1])();
    XCTAssertEqualObjects(fixture.coordinator.cache.receipt[@"reason"],@"noBackgroundTime");XCTAssertEqual(fixture.tasks.count,0u);
}
- (void)testProductionBridgeChecksLatestTaskAndTimeBeforeSubmission {
    // These are injected platform boundaries; real UIKit background execution is a separate device test.
    for (NSNumber *gate in @[@0,@1,@2,@3]) {
        AxsCacheKeeperWebKitBridgeFixture *fixture=[AxsCacheKeeperWebKitBridgeFixture new];
        AxsCacheKeeperObservedWebView *view=[fixture readyView];
        if (gate.integerValue==0) fixture.grant=NO;
        [fixture.coordinator didEnterBackground];
        if (gate.integerValue>0) {
            if (gate.integerValue==1) fixture.remaining=1;
            if (gate.integerValue==2) fixture.background=NO;
            if (gate.integerValue==3) ((void (^)(void))fixture.expirations[0])();
            [fixture reply:2 context:axs_cachekeeper_webkit_test_context()];
        }
        XCTAssertEqualObjects(fixture.coordinator.cache.receipt[@"submitted"],@0);
        XCTAssertEqualObjects(fixture.coordinator.cache.receipt[@"reason"],@"noBackgroundTime");
        fixture.grant=YES;fixture.remaining=30;fixture.background=YES;
        NSUInteger next=fixture.reads.count;
        [fixture.coordinator didBecomeActive];[fixture reply:next context:axs_cachekeeper_webkit_test_context()];
        [fixture.coordinator captureCreatedWebView:view];[fixture.coordinator didEnterBackground];
        XCTAssertEqualObjects(fixture.coordinator.cache.receipt[@"state"],@"queued");
        XCTAssertEqual(fixture.tasks.count,1u);((void (^)(void))fixture.expirations.lastObject)();
    }
}
- (void)testProductionBridgeDoesNotAcquireTaskForUnobservedOrClosedApp {
    AxsCacheKeeperWebKitBridgeFixture *fixture=[AxsCacheKeeperWebKitBridgeFixture new];
    [fixture.coordinator configureWithAuthorization:YES];[fixture reply:0 context:axs_cachekeeper_webkit_test_context()];
    [fixture.coordinator didBecomeActive];[fixture reply:1 context:axs_cachekeeper_webkit_test_context()];
    [fixture.coordinator didEnterBackground];
    XCTAssertEqual(fixture.expirations.count,0u);XCTAssertEqualObjects(fixture.coordinator.cache.receipt[@"state"],@"notObserved");
    [fixture.coordinator configureWithAuthorization:NO];
    NSMutableDictionary *closed=[axs_cachekeeper_webkit_test_context() mutableCopy];closed[@"requested"]=@NO;
    [fixture reply:2 context:closed];[fixture.coordinator didBecomeActive];[fixture reply:3 context:closed];
    [fixture.coordinator didEnterBackground];
    XCTAssertEqual(fixture.expirations.count,0u);XCTAssertEqualObjects(fixture.coordinator.cache.receipt[@"reason"],@"notAuthorized");
}
- (void)testProductionBridgeObsoleteConfigurationReadCannotReopenObservation {
    AxsCacheKeeperWebKitBridgeFixture *fixture=[AxsCacheKeeperWebKitBridgeFixture new];
    AxsCacheKeeperObservedWebView *view=[fixture readyView];
    [fixture.coordinator configureWithAuthorization:YES];[fixture.coordinator configureWithAuthorization:NO];
    view.configurationReads=0;[fixture.coordinator captureCreatedWebView:view];
    [fixture reply:2 context:axs_cachekeeper_webkit_test_context()];
    XCTAssertEqual(view.configurationReads,0u);XCTAssertFalse(fixture.coordinator.observation.observing);
    NSMutableDictionary *closed=[axs_cachekeeper_webkit_test_context() mutableCopy];closed[@"requested"]=@NO;
    [fixture reply:3 context:closed];
    NSArray *events=[fixture.coordinator.cache.receipt[@"operationHistory"][@"processes"] lastObject][@"events"];
    XCTAssertGreaterThanOrEqual(events.count,2u);
    NSDictionary *obsolete=events[events.count-2],*current=events.lastObject;
    XCTAssertEqualObjects(obsolete[@"refresh"],@"obsolete");XCTAssertEqualObjects(current[@"refresh"],@"applied");
    XCTAssertEqualObjects(fixture.coordinator.cache.receipt[@"requested"],@NO);
    XCTAssertEqual(view.configurationReads,0u);
}
- (void)testProductionBridgeClosedEnabledReadSettlesWithoutApplyingOldAuthorization {
    AxsCacheKeeperWebKitBridgeFixture *fixture=[AxsCacheKeeperWebKitBridgeFixture new];
    AxsCacheKeeperObservedWebView *view=[fixture readyView];
    [fixture.coordinator didEnterBackground];[fixture.coordinator configureWithAuthorization:NO];
    view.configurationReads=0;[fixture.coordinator captureCreatedWebView:view];
    [fixture reply:2 context:axs_cachekeeper_webkit_test_context()];
    [fixture reply:3 context:axs_cachekeeper_webkit_test_context()];
    XCTAssertEqualObjects(fixture.coordinator.cache.receipt[@"state"],@"disabled");
    XCTAssertEqualObjects(fixture.coordinator.cache.receipt[@"requested"],@NO);
    XCTAssertFalse(fixture.coordinator.cache.observationAllowed);XCTAssertFalse(fixture.coordinator.cache.hasPendingWork);
    XCTAssertEqual(fixture.tasks.count,0u);XCTAssertEqual(view.configurationReads,0u);
    [fixture.coordinator configureWithAuthorization:YES];[fixture reply:4 context:axs_cachekeeper_webkit_test_context()];
    [fixture.coordinator didBecomeActive];[fixture reply:5 context:axs_cachekeeper_webkit_test_context()];
    [fixture.coordinator captureCreatedWebView:view];[fixture.coordinator didEnterBackground];
    XCTAssertEqualObjects(fixture.coordinator.cache.receipt[@"state"],@"queued");
    ((void (^)(void))fixture.expirations.lastObject)();
}
- (void)testProductionBridgeSynchronousExpirationEndsOnlyReturnedTask {
    AxsCacheKeeperWebKitBridgeFixture *fixture=[AxsCacheKeeperWebKitBridgeFixture new];
    AxsCacheKeeperObservedWebView *view=[fixture readyView];fixture.expireSynchronously=YES;
    [fixture.coordinator didEnterBackground];
    XCTAssertEqualObjects(fixture.coordinator.cache.receipt[@"submitted"],@0);
    XCTAssertEqualObjects(fixture.coordinator.cache.receipt[@"reason"],@"noBackgroundTime");XCTAssertEqual(fixture.tasks.count,0u);
    fixture.expireSynchronously=NO;
    [fixture.coordinator didBecomeActive];[fixture reply:2 context:axs_cachekeeper_webkit_test_context()];
    [fixture.coordinator captureCreatedWebView:view];[fixture.coordinator didEnterBackground];
    ((void (^)(void))fixture.expirations[0])();
    XCTAssertEqualObjects(fixture.coordinator.cache.receipt[@"state"],@"queued");XCTAssertEqual(fixture.tasks.count,1u);
    ((void (^)(void))fixture.expirations[1])();
}
- (void)testProductionBridgeOldBeginReturnCannotOverwriteReentrantNewTask {
    AxsCacheKeeperWebKitBridgeFixture *fixture=[AxsCacheKeeperWebKitBridgeFixture new];
    AxsCacheKeeperObservedWebView *view=[fixture readyView];
    __weak AxsCacheKeeperWebKitBridgeFixture *weakFixture=fixture;
    fixture.duringBegin=^{
        AxsCacheKeeperWebKitBridgeFixture *current=weakFixture;
        [current.coordinator didBecomeActive];[current reply:2 context:axs_cachekeeper_webkit_test_context()];
        [current.coordinator didEnterBackground];
    };
    [fixture.coordinator didEnterBackground];
    XCTAssertEqualObjects(fixture.coordinator.cache.receipt[@"state"],@"queued");
    XCTAssertEqual(fixture.tasks.count,1u);XCTAssertTrue([fixture.tasks containsObject:@2]);
    ((void (^)(void))fixture.expirations[0])();
    XCTAssertEqual(fixture.tasks.count,1u);XCTAssertEqualObjects(fixture.coordinator.cache.receipt[@"submitted"],@0);
    ((void (^)(void))fixture.expirations[1])();
    XCTAssertEqual(fixture.tasks.count,0u);(void)view;
}
- (void)testColdStartViewWaitsForCurrentIdentityValidation {
    XCTAssertTrue(NSThread.isMainThread);
    AxsCacheKeeperWebKitCache *engine=[[AxsCacheKeeperWebKitCache alloc] initWithPreparation:nil clock:nil observer:nil];
    AxsCacheKeeperWebKitObservation *observation=[[AxsCacheKeeperWebKitObservation alloc] initWithCache:engine];
    NSUInteger generation=[observation beginConfigurationWithAuthorization:YES];
    AxsCacheKeeperObservedWebView *view=[[AxsCacheKeeperObservedWebView alloc] initWithFrame:CGRectZero configuration:[WKWebViewConfiguration new]];
    view.configurationReads=0;
    [observation captureCreatedWebView:view];[observation captureCreatedWebView:view];
    XCTAssertEqual(view.configurationReads,0u);XCTAssertEqual(observation.pendingViewCount,1u);
    XCTAssertEqualObjects(engine.receipt[@"persistentStores"],@0);
    XCTestExpectation *validated=[self expectationWithDescription:@"Delayed installation validation observes the startup view"];
    dispatch_async(dispatch_get_main_queue(),^{
        XCTAssertTrue([observation applyContext:axs_cachekeeper_webkit_test_context() forGeneration:generation]);
        XCTAssertEqual(view.configurationReads,1u);XCTAssertEqual(observation.pendingViewCount,0u);
        XCTAssertEqualObjects(engine.receipt[@"persistentStores"],@1);
        [validated fulfill];
    });
    [self waitForExpectations:@[validated] timeout:5];
}
- (void)testRevocationDropsWeakCandidatesBeforeAnyConfigurationGetter {
    AxsCacheKeeperWebKitCache *engine=[[AxsCacheKeeperWebKitCache alloc] initWithPreparation:nil clock:nil observer:nil];
    AxsCacheKeeperWebKitObservation *observation=[[AxsCacheKeeperWebKitObservation alloc] initWithCache:engine];
    NSUInteger oldGeneration=[observation beginConfigurationWithAuthorization:YES];
    AxsCacheKeeperObservedWebView *view=[[AxsCacheKeeperObservedWebView alloc] initWithFrame:CGRectZero configuration:[WKWebViewConfiguration new]];
    view.configurationReads=0;[observation captureCreatedWebView:view];
    NSUInteger closedGeneration=[observation beginConfigurationWithAuthorization:NO];
    XCTAssertEqual(observation.pendingViewCount,0u);
    XCTAssertFalse([observation applyContext:axs_cachekeeper_webkit_test_context() forGeneration:oldGeneration]);
    // Even a racing enabled disk read cannot override the newer synchronous closed snapshot.
    XCTAssertFalse([observation applyContext:axs_cachekeeper_webkit_test_context() forGeneration:closedGeneration]);
    [observation captureCreatedWebView:view];
    XCTAssertEqual(view.configurationReads,0u);XCTAssertFalse(observation.observing);
    XCTAssertEqualObjects(engine.receipt[@"persistentStores"],@0);
    NSMutableDictionary *closed=[axs_cachekeeper_webkit_test_context() mutableCopy];closed[@"requested"]=@NO;
    XCTAssertTrue([observation applyContext:closed forGeneration:closedGeneration]);
    XCTAssertEqualObjects(engine.receipt[@"requested"],@NO);
}
- (void)testCandidatesAreWeakAndBounded {
    AxsCacheKeeperWebKitCache *engine=[[AxsCacheKeeperWebKitCache alloc] initWithPreparation:nil clock:nil observer:nil];
    AxsCacheKeeperWebKitObservation *observation=[[AxsCacheKeeperWebKitObservation alloc] initWithCache:engine];
    NSUInteger generation=[observation beginConfigurationWithAuthorization:YES];
    __weak WKWebView *released;
    @autoreleasepool {
        WKWebView *view=[[WKWebView alloc] initWithFrame:CGRectZero configuration:[WKWebViewConfiguration new]];
        released=view;[observation captureCreatedWebView:view];
    }
    // WebKit itself retains new views until asynchronous initialization drains.
    XCTNSPredicateExpectation *releasedView=[[XCTNSPredicateExpectation alloc] initWithPredicate:[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *bindings) {
        (void)object;(void)bindings;return released==nil;
    }] object:nil];
    [self waitForExpectations:@[releasedView] timeout:5];
    XCTAssertNil(released);XCTAssertEqual(observation.pendingViewCount,0u);
    @autoreleasepool {
        // These views test object identity, not process isolation. Reuse one pool instead of
        // starting a separate WebKit process pool for each of the forty capacity candidates.
        WKWebViewConfiguration *configuration=[WKWebViewConfiguration new];
        configuration.processPool=[WKProcessPool new];
        NSMutableArray<AxsCacheKeeperObservedWebView *> *views=[NSMutableArray new];
        for (NSUInteger index=0;index<40;index++) {
            AxsCacheKeeperObservedWebView *view=[[AxsCacheKeeperObservedWebView alloc] initWithFrame:CGRectZero configuration:configuration];
            view.configurationReads=0;[views addObject:view];[observation captureCreatedWebView:view];
        }
        XCTAssertEqual(observation.pendingViewCount,32u);
        for (AxsCacheKeeperObservedWebView *view in views) XCTAssertEqual(view.configurationReads,0u);
        XCTAssertTrue([observation applyContext:axs_cachekeeper_webkit_test_context() forGeneration:generation]);
        NSUInteger reads=0;for (AxsCacheKeeperObservedWebView *view in views) reads+=view.configurationReads;
        XCTAssertEqual(reads,32u);
    }
}
@end
