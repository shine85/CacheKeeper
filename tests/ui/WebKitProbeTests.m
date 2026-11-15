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

@interface AxsCacheKeeperWebKitFixtureNavigation : NSObject <WKNavigationDelegate>
@property(nonatomic,strong) XCTestExpectation *finished;
@property(nonatomic,strong) NSError *error;
@end
@implementation AxsCacheKeeperWebKitFixtureNavigation
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    (void)webView;(void)navigation;[self.finished fulfill];self.finished=nil;
}
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    (void)webView;(void)navigation;self.error=error;[self.finished fulfill];self.finished=nil;
}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self webView:webView didFailNavigation:navigation withError:error];
}
@end

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
    XCTAssertNil(released);XCTAssertEqual(observation.pendingViewCount,0u);
    NSMutableArray<AxsCacheKeeperObservedWebView *> *views=[NSMutableArray new];
    for (NSUInteger index=0;index<40;index++) {
        AxsCacheKeeperObservedWebView *view=[[AxsCacheKeeperObservedWebView alloc] initWithFrame:CGRectZero configuration:[WKWebViewConfiguration new]];
        view.configurationReads=0;[views addObject:view];[observation captureCreatedWebView:view];
    }
    XCTAssertEqual(observation.pendingViewCount,32u);
    for (AxsCacheKeeperObservedWebView *view in views) XCTAssertEqual(view.configurationReads,0u);
    XCTAssertTrue([observation applyContext:axs_cachekeeper_webkit_test_context() forGeneration:generation]);
    NSUInteger reads=0;for (AxsCacheKeeperObservedWebView *view in views) reads+=view.configurationReads;
    XCTAssertEqual(reads,32u);
}
- (void)axs_cachekeeper_load_fixture:(WKWebView *)view {
    AxsCacheKeeperWebKitFixtureNavigation *delegate=[AxsCacheKeeperWebKitFixtureNavigation new];
    delegate.finished=[self expectationWithDescription:@"Synthetic WebKit fixture loaded"];
    XCTestExpectation *finished=delegate.finished;view.navigationDelegate=delegate;
    [view loadHTMLString:@"<!doctype html><meta charset='utf-8'><title>CacheKeeper owned fixture</title><p>Fixture</p>"
                baseURL:[NSURL URLWithString:@"https://cachekeeper-fixture.invalid/"]];
    [self waitForExpectations:@[finished] timeout:15];XCTAssertNil(delegate.error);
    view.navigationDelegate=nil;
}
- (id)axs_cachekeeper_evaluate:(NSString *)script view:(WKWebView *)view {
    XCTestExpectation *finished=[self expectationWithDescription:@"Fixture storage operation"];
    __block id result=nil;__block NSError *failure=nil;
    [view evaluateJavaScript:script completionHandler:^(id value,NSError *error) {result=value;failure=error;[finished fulfill];}];
    [self waitForExpectations:@[finished] timeout:10];XCTAssertNil(failure);return result;
}
- (void)testProductionDiskCacheActionCompletesAndPreservesCookieAndLocalStorage {
    XCTAssertTrue(NSThread.isMainThread);
    // This is the isolated test application's own persistent store. The production adapter obtains
    // the store from a real WebView; it never discovers or creates a user's default store.
    WKWebView *view=[[WKWebView alloc] initWithFrame:CGRectMake(0,0,320,480) configuration:[WKWebViewConfiguration new]];
    WKWebsiteDataStore *store=view.configuration.websiteDataStore;XCTAssertTrue(store.isPersistent);
    [self axs_cachekeeper_load_fixture:view];
    XCTAssertEqualObjects([self axs_cachekeeper_evaluate:@"localStorage.setItem('ck-preserved', 'fixture-value');localStorage.getItem('ck-preserved')" view:view],@"fixture-value");
    NSHTTPCookie *cookie=[NSHTTPCookie cookieWithProperties:@{NSHTTPCookieName:@"ck-preserved",NSHTTPCookieValue:@"fixture-value",
        NSHTTPCookieDomain:@"cachekeeper-fixture.invalid",NSHTTPCookiePath:@"/",NSHTTPCookieSecure:@"TRUE",NSHTTPCookieExpires:[NSDate dateWithTimeIntervalSinceNow:3600]}];
    XCTAssertNotNil(cookie);
    XCTestExpectation *cookieWritten=[self expectationWithDescription:@"Fixture cookie written"];
    [store.httpCookieStore setCookie:cookie completionHandler:^{[cookieWritten fulfill];}];
    [self waitForExpectations:@[cookieWritten] timeout:10];

    NSDictionary *context=axs_cachekeeper_webkit_test_context();
    XCTestExpectation *completed=[self expectationWithDescription:@"Actual public WebKit removal callback"];
    __block BOOL received=NO;
    AxsCacheKeeperWebKitCache *engine=[[AxsCacheKeeperWebKitCache alloc] initWithPreparation:^(void (^reply)(NSDictionary *,BOOL)) {reply(context,YES);}
        clock:^{return NSProcessInfo.processInfo.systemUptime;} observer:^(NSDictionary *receipt) {
            if (!received && [receipt[@"completed"] unsignedIntegerValue]==1) {received=YES;[completed fulfill];}
        }];
    AxsCacheKeeperWebKitObservation *observation=[[AxsCacheKeeperWebKitObservation alloc] initWithCache:engine];
    NSUInteger generation=[observation beginConfigurationWithAuthorization:YES];
    [observation captureCreatedWebView:view];
    XCTAssertTrue([observation applyContext:context forGeneration:generation]);
    [engine didBecomeActive];[engine didEnterBackgroundWithTime:YES];
    [self waitForExpectations:@[completed] timeout:20];
    XCTAssertEqualObjects(engine.receipt[@"submitted"],@1);XCTAssertEqualObjects(engine.receipt[@"completed"],@1);
    XCTAssertEqualObjects(engine.receipt[@"pending"],@0);XCTAssertEqualObjects(engine.receipt[@"bytesState"],@"notMeasured");

    WKWebViewConfiguration *configuration=[WKWebViewConfiguration new];configuration.websiteDataStore=store;
    WKWebView *reopened=[[WKWebView alloc] initWithFrame:CGRectMake(0,0,320,480) configuration:configuration];
    [self axs_cachekeeper_load_fixture:reopened];
    XCTAssertEqualObjects([self axs_cachekeeper_evaluate:@"localStorage.getItem('ck-preserved')" view:reopened],@"fixture-value");
    XCTestExpectation *cookieRead=[self expectationWithDescription:@"Fixture cookie preserved"];
    __block BOOL cookiePreserved=NO;
    [store.httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
        for (NSHTTPCookie *candidate in cookies)
            if ([candidate.name isEqual:@"ck-preserved"] && [candidate.domain isEqual:@"cachekeeper-fixture.invalid"] && [candidate.value isEqual:@"fixture-value"]) cookiePreserved=YES;
        [cookieRead fulfill];
    }];
    [self waitForExpectations:@[cookieRead] timeout:10];XCTAssertTrue(cookiePreserved);
    // This test proves a real API call and retained storage sentinels, not reclaimed physical bytes
    // or cross-process disk-cache misses. Those require the controlled network/relaunch fixture.
}
@end
