#import <XCTest/XCTest.h>
#import <WebKit/WebKit.h>
#import "../../AxsCacheKeeperWebKitCache.h"
#import "../../AxsCacheKeeperWebKitObservation.h"
#include <sys/socket.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

// The fixture serves only its own static page on an ephemeral loopback port.
@interface AxsCacheKeeperWebKitHTTPFixture : NSObject
@property(nonatomic,strong) NSURL *url;
@property(nonatomic,strong) dispatch_source_t source;
@property(atomic) NSUInteger responseCount;
@property(atomic) NSInteger lastError;
@end
@implementation AxsCacheKeeperWebKitHTTPFixture
- (instancetype)init {
    self=[super init];if (!self) return nil;
    int server=socket(AF_INET,SOCK_STREAM,0);if (server<0) return nil;
    struct sockaddr_in address={0};address.sin_len=sizeof(address);address.sin_family=AF_INET;
    address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    if (bind(server,(struct sockaddr *)&address,sizeof(address)) || listen(server,8)) {close(server);return nil;}
    socklen_t size=sizeof(address);
    if (getsockname(server,(struct sockaddr *)&address,&size)) {close(server);return nil;}
    self.url=[NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%u/fixture.html",ntohs(address.sin_port)]];
    fcntl(server,F_SETFL,O_NONBLOCK);
    self.source=dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,server,0,dispatch_queue_create("cachekeeper.tests.http",DISPATCH_QUEUE_SERIAL));
    __weak typeof(self) weakSelf=self;
    dispatch_source_set_event_handler(self.source,^{
        int client;
        while ((client=accept(server,NULL,NULL))>=0) {
            fcntl(client,F_SETFL,0);struct timeval limit={2,0};int yes=1;
            setsockopt(client,SOL_SOCKET,SO_RCVTIMEO,&limit,sizeof(limit));
            setsockopt(client,SOL_SOCKET,SO_SNDTIMEO,&limit,sizeof(limit));
            setsockopt(client,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof(yes));
            char request[4096];
            if (recv(client,request,sizeof(request),0)>0) {
                NSString *body=@"<!doctype html><meta charset='utf-8'><title>Owned fixture</title><p>CacheKeeper test</p>";
                NSData *html=[body dataUsingEncoding:NSUTF8StringEncoding];
                NSString *header=[NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: %lu\r\nCache-Control: max-age=3600\r\nConnection: close\r\n\r\n",(unsigned long)html.length];
                NSMutableData *response=[[header dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];[response appendData:html];
                const uint8_t *bytes=response.bytes;NSUInteger sent=0;
                while (sent<response.length) {ssize_t count=send(client,bytes+sent,response.length-sent,0);if (count<=0) break;sent+=(NSUInteger)count;}
                if (sent==response.length) {
                    weakSelf.responseCount++;NSLog(@"CacheKeeper fixture HTTP response delivered");
                } else weakSelf.lastError=errno;
            } else weakSelf.lastError=errno;
            close(client);
        }
    });
    dispatch_source_set_cancel_handler(self.source,^{close(server);});dispatch_resume(self.source);
    return self;
}
- (void)dealloc { if (_source) dispatch_source_cancel(_source); }
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
- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
    (void)webView;(void)navigation;NSLog(@"CacheKeeper fixture navigation started");
}
- (void)webView:(WKWebView *)webView didCommitNavigation:(WKNavigation *)navigation {
    (void)webView;(void)navigation;NSLog(@"CacheKeeper fixture navigation committed");
}
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    [self webView:webView didFailNavigation:nil withError:[NSError errorWithDomain:@"CacheKeeperTestWebContent" code:1 userInfo:nil]];
}
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    (void)webView;(void)navigation;NSLog(@"CacheKeeper fixture navigation finished");[self.finished fulfill];self.finished=nil;
}
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    (void)webView;(void)navigation;self.error=error;[self.finished fulfill];self.finished=nil;
}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self webView:webView didFailNavigation:navigation withError:error];
}
@end

@interface AxsCacheKeeperWebKitIntegrationTests : XCTestCase
@property(nonatomic,strong) AxsCacheKeeperWebKitHTTPFixture *fixture;
@property(nonatomic,strong) UIWindow *axs_cachekeeper_window;
@property(nonatomic,strong) UIWindow *axs_cachekeeper_previousWindow;
@property(nonatomic,strong) NSMutableArray<WKWebView *> *axs_cachekeeper_attachedViews;
@end
@implementation AxsCacheKeeperWebKitIntegrationTests
- (void)setUp {
    [super setUp];
    self.axs_cachekeeper_previousWindow=UIApplication.sharedApplication.delegate.window;
    self.axs_cachekeeper_window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.axs_cachekeeper_window.rootViewController=[UIViewController new];
    [self.axs_cachekeeper_window makeKeyAndVisible];
    [self.axs_cachekeeper_window layoutIfNeeded];
    XCTAssertTrue(self.axs_cachekeeper_window.isKeyWindow);
    XCTAssertEqual(UIApplication.sharedApplication.applicationState,UIApplicationStateActive);
}
- (void)tearDown {
    for (WKWebView *view in self.axs_cachekeeper_attachedViews) { [view stopLoading];[view removeFromSuperview]; }
    self.axs_cachekeeper_attachedViews=nil;self.fixture=nil;
    self.axs_cachekeeper_window.hidden=YES;self.axs_cachekeeper_window.rootViewController=nil;
    self.axs_cachekeeper_window=nil;[self.axs_cachekeeper_previousWindow makeKeyWindow];
    self.axs_cachekeeper_previousWindow=nil;[super tearDown];
}
- (BOOL)axs_cachekeeper_load_fixture:(WKWebView *)view preparation:(BOOL)preparation {
    UIWindow *window=self.axs_cachekeeper_window;
    XCTAssertNotNil(window);XCTAssertFalse(window.hidden);
    if (!window || window.hidden) return NO;
    // An unattached view may be suspended while simulator WebKit services cold-start.
    if (!self.axs_cachekeeper_attachedViews) self.axs_cachekeeper_attachedViews=[NSMutableArray new];
    [self.axs_cachekeeper_attachedViews addObject:view];[window.rootViewController.view addSubview:view];
    NSTimeInterval started=NSProcessInfo.processInfo.systemUptime;
    AxsCacheKeeperWebKitFixtureNavigation *delegate=[AxsCacheKeeperWebKitFixtureNavigation new];
    delegate.finished=[self expectationWithDescription:@"Synthetic WebKit fixture loaded"];
    XCTestExpectation *finished=delegate.finished;view.navigationDelegate=delegate;
    [view loadRequest:[NSURLRequest requestWithURL:self.fixture.url]];
    // The first real page establishes the cold WebKit fixture; subsequent navigation retains 15s.
    [self waitForExpectations:@[finished] timeout:preparation ? 60 : 15];XCTAssertNil(delegate.error);
    NSLog(@"CacheKeeper fixture page: prepared=%d elapsed=%.3fs responses=%lu serverError=%ld",preparation,
        NSProcessInfo.processInfo.systemUptime-started,(unsigned long)self.fixture.responseCount,(long)self.fixture.lastError);
    BOOL loaded=delegate.finished==nil && delegate.error==nil;
    view.navigationDelegate=nil;return loaded;
}
- (id)axs_cachekeeper_evaluate:(NSString *)script view:(WKWebView *)view {
    XCTestExpectation *finished=[self expectationWithDescription:@"Fixture storage operation"];
    __block id result=nil;__block NSError *failure=nil;
    [view evaluateJavaScript:script completionHandler:^(id value,NSError *error) {result=value;failure=error;[finished fulfill];}];
    [self waitForExpectations:@[finished] timeout:10];XCTAssertNil(failure);return result;
}
- (void)testProductionDiskCacheActionCompletesAndPreservesCookieAndLocalStorage {
    XCTAssertTrue(NSThread.isMainThread);
    self.fixture=[AxsCacheKeeperWebKitHTTPFixture new];XCTAssertNotNil(self.fixture);
    if (!self.fixture) return;
    // This is the isolated test application's own persistent store. The production adapter obtains
    // the store from a real WebView; it never discovers or creates a user's default store.
    WKWebView *view=[[WKWebView alloc] initWithFrame:CGRectMake(0,0,320,480) configuration:[WKWebViewConfiguration new]];
    WKWebsiteDataStore *store=view.configuration.websiteDataStore;XCTAssertTrue(store.isPersistent);
    if (![self axs_cachekeeper_load_fixture:view preparation:YES]) return;
    XCTAssertEqualObjects([self axs_cachekeeper_evaluate:@"localStorage.setItem('ck-preserved', 'fixture-value');localStorage.getItem('ck-preserved')" view:view],@"fixture-value");
    NSHTTPCookie *cookie=[NSHTTPCookie cookieWithProperties:@{NSHTTPCookieName:@"ck-preserved",NSHTTPCookieValue:@"fixture-value",
        NSHTTPCookieDomain:@"127.0.0.1",NSHTTPCookiePath:@"/",NSHTTPCookieExpires:[NSDate dateWithTimeIntervalSinceNow:3600]}];
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
    if (![self axs_cachekeeper_load_fixture:reopened preparation:NO]) return;
    XCTAssertEqualObjects([self axs_cachekeeper_evaluate:@"localStorage.getItem('ck-preserved')" view:reopened],@"fixture-value");
    XCTestExpectation *cookieRead=[self expectationWithDescription:@"Fixture cookie preserved"];
    __block BOOL cookiePreserved=NO;
    [store.httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
        for (NSHTTPCookie *candidate in cookies)
            if ([candidate.name isEqual:@"ck-preserved"] && [candidate.domain isEqual:@"127.0.0.1"] && [candidate.value isEqual:@"fixture-value"]) cookiePreserved=YES;
        [cookieRead fulfill];
    }];
    [self waitForExpectations:@[cookieRead] timeout:10];XCTAssertTrue(cookiePreserved);
    // This test proves a real API call and retained storage sentinels, not reclaimed physical bytes
    // or cross-process disk-cache misses. Those require the controlled network/relaunch fixture.
}
@end
