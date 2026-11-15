#import <XCTest/XCTest.h>
#import <WebKit/WebKit.h>
#import "../../AxsCacheKeeperWebKitCache.h"
#import "../../AxsCacheKeeperWebKitObservation.h"
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

@interface AxsCacheKeeperWebKitProbeTests : XCTestCase
@end
@implementation AxsCacheKeeperWebKitProbeTests
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
