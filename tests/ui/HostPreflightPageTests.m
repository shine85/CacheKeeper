#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>
#import "../../Prefs/HostPreflightPage.h"
#import "../../AxsCacheKeeperHostPreflight.h"
#import "../../AxsCacheKeeperHostEvidence.h"
#import "../../AxsCacheKeeperProbe.h"
#include <notify.h>

// 新文件无旧版可备份。仅在测试宿主内创建服务端，不启动真实 APP。
@interface AxsCacheKeeperHostPreflightPage (AxsCacheKeeperTestActions)
- (void)axs_cachekeeper_action;
- (void)axs_cachekeeper_poll;
- (void)axs_cachekeeper_retry_saving;
@end

@interface AxsCacheKeeperHostPreflightPageFixture : AxsCacheKeeperHostPreflightPage
@property(nonatomic,strong) XCTestExpectation *axs_cachekeeper_appeared;
@end
@implementation AxsCacheKeeperHostPreflightPageFixture
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.axs_cachekeeper_appeared fulfill];self.axs_cachekeeper_appeared=nil;
}
@end

// 只缩短真实客户端 deadline，保留生产批次、Darwin notify 和文件保存路径。
@interface AxsCacheKeeperShortHostPreflight : AxsCacheKeeperHostPreflight
@end
@implementation AxsCacheKeeperShortHostPreflight
- (BOOL)startWithTimeout:(NSTimeInterval)timeout {
    (void)timeout;return [super startWithTimeout:0.15];
}
@end

@interface AxsCacheKeeperHostPreflightCancelledPush : NSObject <UIViewControllerAnimatedTransitioning,UINavigationControllerDelegate>
@property(nonatomic,strong) XCTestExpectation *axs_cachekeeper_started,*axs_cachekeeper_returned;
@property(nonatomic,weak) UIViewController *axs_cachekeeper_target;
@end
@implementation AxsCacheKeeperHostPreflightCancelledPush
- (NSTimeInterval)transitionDuration:(id<UIViewControllerContextTransitioning>)context {
    (void)context;return 0.1;
}
- (void)animateTransition:(id<UIViewControllerContextTransitioning>)context {
    UIViewController *from=[context viewControllerForKey:UITransitionContextFromViewControllerKey];
    UIViewController *to=[context viewControllerForKey:UITransitionContextToViewControllerKey];
    UIView *incoming=[context viewForKey:UITransitionContextToViewKey];
    incoming.frame=[context finalFrameForViewController:to];[context.containerView addSubview:incoming];
    if (from.view) [context.containerView bringSubviewToFront:from.view];
    [self.axs_cachekeeper_started fulfill];self.axs_cachekeeper_started=nil;
    dispatch_async(dispatch_get_main_queue(),^{[context completeTransition:NO];});
}
- (id<UIViewControllerAnimatedTransitioning>)navigationController:(UINavigationController *)navigation
    animationControllerForOperation:(UINavigationControllerOperation)operation fromViewController:(UIViewController *)from toViewController:(UIViewController *)to {
    (void)navigation;(void)from;(void)to;return operation==UINavigationControllerOperationPush ? self : nil;
}
- (void)navigationController:(UINavigationController *)navigation didShowViewController:(UIViewController *)controller animated:(BOOL)animated {
    (void)navigation;(void)animated;
    if (controller==self.axs_cachekeeper_target) {
        [self.axs_cachekeeper_returned fulfill];self.axs_cachekeeper_returned=nil;
    }
}
@end

@interface AxsCacheKeeperHostPreflightPageTests : XCTestCase
@property(nonatomic,strong) UIWindow *window,*previousWindow;
@property(nonatomic,strong) UINavigationController *navigation;
@property(nonatomic,strong) AxsCacheKeeperHostPreflightPageFixture *page;
@property(nonatomic,strong) NSMutableArray<AxsCacheKeeperHostEvidenceServer *> *servers;
@property(nonatomic,strong) NSMutableArray<NSNumber *> *networkTokens,*networkStates;
@property(nonatomic,copy) NSString *folder,*statusDirectory,*hostFolder;
@property(nonatomic,copy) NSData *configurationBefore,*resourceBefore;
- (AxsCacheKeeperHostPreflight *)axs_cachekeeper_batch;
- (NSArray<NSDictionary *> *)axs_cachekeeper_rows;
- (NSString *)axs_cachekeeper_text;
@end

@implementation AxsCacheKeeperHostPreflightPageTests
- (void)setUp {
    [super setUp];
    self.folder=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"host-preflight-ui-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    self.statusDirectory=[self.folder stringByAppendingPathComponent:@"Status"];
    self.hostFolder=[self.folder stringByAppendingPathComponent:@"Hosts"];
    NSFileManager *files=NSFileManager.defaultManager;
    XCTAssertTrue([files createDirectoryAtPath:self.statusDirectory withIntermediateDirectories:YES attributes:nil error:NULL]);
    XCTAssertTrue([files createDirectoryAtPath:[self.hostFolder stringByAppendingPathComponent:@"Status"] withIntermediateDirectories:YES attributes:nil error:NULL]);
    NSMutableDictionary *configuration=[NSMutableDictionary new];
    for (NSDictionary *target in axs_cachekeeper_host_preflight_targets()) configuration[target[@"bundle"]]=@{@"enabled":@NO};
    XCTAssertTrue([configuration writeToFile:[self.folder stringByAppendingPathComponent:@"appEnabled.plist"] atomically:YES]);
    XCTAssertTrue([configuration writeToFile:[self.hostFolder stringByAppendingPathComponent:@"appEnabled.plist"] atomically:YES]);
    XCTAssertTrue([@"retained application bytes" writeToFile:[self.folder stringByAppendingPathComponent:@"resource.bin"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    self.configurationBefore=[NSData dataWithContentsOfFile:[self.folder stringByAppendingPathComponent:@"appEnabled.plist"]];
    self.resourceBefore=[NSData dataWithContentsOfFile:[self.folder stringByAppendingPathComponent:@"resource.bin"]];
    self.servers=[NSMutableArray new];self.networkTokens=[NSMutableArray new];self.networkStates=[NSMutableArray new];
    for (NSDictionary *target in axs_cachekeeper_host_preflight_targets()) {
        int token=-1;uint64_t state=0;
        XCTAssertEqual(notify_register_check(axs_cachekeeper_probe_name(target[@"bundle"],NO).UTF8String,&token),NOTIFY_STATUS_OK);
        if (token>=0) {
            XCTAssertEqual(notify_get_state(token,&state),NOTIFY_STATUS_OK);
            [self.networkTokens addObject:@(token)];[self.networkStates addObject:@(state)];
        }
    }
    self.previousWindow=UIApplication.sharedApplication.delegate.window;
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.navigation=[[UINavigationController alloc] initWithRootViewController:[UIViewController new]];
    self.window.rootViewController=self.navigation;[self.window makeKeyAndVisible];
    self.page=[[AxsCacheKeeperHostPreflightPageFixture alloc] initWithStatusDirectory:self.statusDirectory panelVersion:@"0.7.2-215.1"];
    XCTestExpectation *appeared=[self expectationWithDescription:@"预检页面完成真实 push"];
    self.page.axs_cachekeeper_appeared=appeared;
    [self.navigation pushViewController:self.page animated:NO];
    [self waitForExpectations:@[appeared] timeout:5];
}
- (void)tearDown {
    [self.axs_cachekeeper_batch cancel];
    [[self.page valueForKey:@"axs_cachekeeper_timer"] invalidate];
    for (AxsCacheKeeperHostEvidenceServer *server in self.servers) [server axs_cachekeeper_invalidate];
    for (NSUInteger i=0;i<self.networkTokens.count;i++) {
        uint64_t state=0;XCTAssertEqual(notify_get_state(self.networkTokens[i].intValue,&state),NOTIFY_STATUS_OK);
        XCTAssertEqual(state,self.networkStates[i].unsignedLongLongValue,@"宿主预检不能写网络 probe 请求");
        notify_cancel(self.networkTokens[i].intValue);
    }
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:[self.folder stringByAppendingPathComponent:@"appEnabled.plist"]],self.configurationBefore);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:[self.folder stringByAppendingPathComponent:@"resource.bin"]],self.resourceBefore);
    self.window.hidden=YES;self.window.rootViewController=nil;[self.previousWindow makeKeyWindow];
    self.page=nil;self.servers=nil;self.navigation=nil;self.window=nil;
    XCTAssertTrue([NSFileManager.defaultManager removeItemAtPath:self.folder error:NULL]);
    [super tearDown];
}
- (AxsCacheKeeperHostPreflight *)axs_cachekeeper_batch {return [self.page valueForKey:@"axs_cachekeeper_batch"];}
- (NSArray<NSDictionary *> *)axs_cachekeeper_rows {return [self.axs_cachekeeper_batch snapshot][@"rows"];}
- (NSString *)axs_cachekeeper_text {return [[self.page valueForKey:@"text"] text] ?: @"";}
- (void)axs_cachekeeper_wait:(BOOL (^)(void))condition description:(NSString *)description {
    XCTNSPredicateExpectation *expectation=[[XCTNSPredicateExpectation alloc] initWithPredicate:[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *bindings) {
        (void)object;(void)bindings;return condition();
    }] object:nil];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[expectation] timeout:5],XCTWaiterResultCompleted,@"%@",description);
}
- (void)axs_cachekeeper_waitForTerminal {
    [self axs_cachekeeper_wait:^BOOL { [self.page axs_cachekeeper_poll];return !self.axs_cachekeeper_batch.running; } description:@"真实客户端收齐终态"];
}
- (void)axs_cachekeeper_startServers {
    NSArray *targets=axs_cachekeeper_host_preflight_targets();
    for (NSUInteger index=0;index<targets.count;index++) {
        NSDictionary *runtime=@{@"schemaVersion":@1,@"packageVersion":index==0 ? @"0.7.2-211.1" : @"0.7.2-215.1",@"firstObserved":@1700000000};
        AxsCacheKeeperHostEvidenceServer *server=[[AxsCacheKeeperHostEvidenceServer alloc] initWithBundle:targets[index][@"bundle"] folder:self.hostFolder runtimeInfo:runtime];
        XCTAssertNotNil(server);[self.servers addObject:server];
        [server axs_cachekeeper_observeContainer:YES authorizationAttempted:YES authorizationCode:0 sharedAccess:YES];
        XCTAssertEqualObjects([server axs_cachekeeper_snapshot][@"configurationReadState"],@"readable");
    }
}
- (void)axs_cachekeeper_assertRows:(NSString *)state saved:(NSString *)saved {
    NSArray *rows=self.axs_cachekeeper_rows;XCTAssertEqual(rows.count,5u);
    for (NSDictionary *row in rows) {
        XCTAssertEqualObjects(row[@"state"],state,@"%@",row[@"bundle"]);
        if (saved) XCTAssertEqualObjects(row[@"saveState"],saved,@"%@",row[@"bundle"]);
    }
    if (![@[@"idle",@"pending"] containsObject:state]) {
        for (AxsCacheKeeperHostEvidenceClient *client in [self.axs_cachekeeper_batch valueForKey:@"axs_cachekeeper_clients"])
            XCTAssertEqual(client.axs_cachekeeper_activeTokenCount,0u,@"终态必须释放本批客户端 notify tokens");
    }
}

// 缺目标或加载页面即发请求会破坏初始可见状态与用户主动开始的边界。
- (void)testFiveTargetsAreVisibleBeforeUserStarts {
    XCTAssertFalse(self.axs_cachekeeper_batch.running);
    [self axs_cachekeeper_assertRows:@"idle" saved:@"notAttempted"];
    NSArray *expected=@[@"com.ss.iphone.ugc.Aweme",@"com.tencent.mqq",@"com.baidu.netdisk",@"com.360buy.jdmobile",@"app.swiftgram.ios"];
    XCTAssertEqualObjects([self.axs_cachekeeper_rows valueForKey:@"bundle"],expected);
    for (NSString *name in @[@"抖音",@"QQ",@"百度网盘",@"京东",@"Swiftgram"]) XCTAssertTrue([self.axs_cachekeeper_text containsString:name]);
    XCTAssertEqual([NSFileManager.defaultManager contentsOfDirectoryAtPath:self.statusDirectory error:NULL].count,0u);
}

// 忽略一项响应、写错文件或把旧 producer 冒充面板版本均会被真实回执断言发现。
- (void)testRealFiveHostRepliesAreShownAndSavedWithTheirProducerVersions {
    [self axs_cachekeeper_startServers];[self.page axs_cachekeeper_action];
    [self axs_cachekeeper_waitForTerminal];[self axs_cachekeeper_assertRows:@"observed" saved:@"succeeded"];
    XCTAssertTrue([self.axs_cachekeeper_text containsString:@"0.7.2-211.1"]);
    XCTAssertTrue([self.axs_cachekeeper_text containsString:@"0.7.2-215.1"]);
    XCTAssertTrue([self.axs_cachekeeper_text containsString:@"未经"]);
    for (NSDictionary *row in self.axs_cachekeeper_rows) {
        NSString *path=[self.statusDirectory stringByAppendingPathComponent:[row[@"bundle"] stringByAppendingString:@".hostObserved.plist"]];
        NSDictionary *saved=[NSDictionary dictionaryWithContentsOfFile:path];
        XCTAssertNotNil(axs_cachekeeper_host_observed_projection(saved));
        XCTAssertEqualObjects(saved,row[@"result"]);
        XCTAssertEqualObjects(saved[@"data"][@"transportTrust"],@"unauthenticated");
    }
    XCTAssertFalse([[self.page valueForKey:@"axs_cachekeeper_timer"] isValid]);
}

// 将后台通知当作离页取消，或返回页面不恢复轮询，会丢失后台到达的响应。
- (void)testBackgroundStopsTimerButKeepsRequestsUntilForegroundPoll {
    [self.page axs_cachekeeper_action];[self axs_cachekeeper_assertRows:@"pending" saved:@"notAttempted"];
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidEnterBackgroundNotification object:nil];
    XCTAssertTrue(self.axs_cachekeeper_batch.running);
    XCTAssertFalse([[self.page valueForKey:@"axs_cachekeeper_timer"] isValid]);
    [self axs_cachekeeper_startServers];
    [self axs_cachekeeper_assertRows:@"pending" saved:@"notAttempted"];
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];
    [self axs_cachekeeper_waitForTerminal];[self axs_cachekeeper_assertRows:@"observed" saved:@"succeeded"];
}

// 超时来自真实 notify 客户端 deadline；不能伪造成未注入或成功。
- (void)testRealTimeoutIsSavedWithoutClaimingNoInjection {
    AxsCacheKeeperShortHostPreflight *batch=[[AxsCacheKeeperShortHostPreflight alloc] initWithStatusDirectory:self.statusDirectory panelVersion:@"0.7.2-215.1"];
    [self.page setValue:batch forKey:@"axs_cachekeeper_batch"];
    [self.page axs_cachekeeper_action];[self axs_cachekeeper_waitForTerminal];
    [self axs_cachekeeper_assertRows:@"timedOut" saved:@"succeeded"];
    NSString *text=self.axs_cachekeeper_text;
    XCTAssertTrue([text containsString:@"超时"] || [text containsString:@"timedOut"]);
    XCTAssertTrue([text containsString:@"不能"] || [text containsString:@"不代表"]);
    for (NSDictionary *row in self.axs_cachekeeper_rows) XCTAssertNil(row[@"result"][@"data"]);
}

// 第二次点击必须取消等待，而不能开始新请求或清除已收到的证据。
- (void)testActionButtonCancelsPendingBatch {
    [self.page axs_cachekeeper_action];XCTAssertTrue(self.axs_cachekeeper_batch.running);
    [self.page axs_cachekeeper_action];XCTAssertFalse(self.axs_cachekeeper_batch.running);
    [self axs_cachekeeper_assertRows:@"cancelled" saved:@"succeeded"];
    XCTAssertFalse([[self.page valueForKey:@"axs_cachekeeper_timer"] isValid]);
}

// UIKit 实际 pop 进入离页路径；只测 viewWillDisappear 会漏掉层级判断错误。
- (void)testActualNavigationPopCancelsPendingRequests {
    [self.page axs_cachekeeper_action];
    XCTAssertEqualObjects([self.navigation popViewControllerAnimated:NO],self.page);
    [self axs_cachekeeper_wait:^BOOL {return !self.axs_cachekeeper_batch.running;} description:@"实际 pop 取消请求"];
    [self axs_cachekeeper_assertRows:@"cancelled" saved:@"succeeded"];
}

// 取消 push 必须恢复原页面的轮询，不能把转场开始当成真正离页。
- (void)testCancelledPushKeepsPendingRequestsAndRestoresTimer {
    [self.page axs_cachekeeper_action];
    [self axs_cachekeeper_assertRows:@"pending" saved:@"notAttempted"];
    AxsCacheKeeperHostPreflightCancelledPush *transition=[AxsCacheKeeperHostPreflightCancelledPush new];
    XCTestExpectation *started=[self expectationWithDescription:@"UIKit 开始预检页 push 转场"];
    XCTestExpectation *returned=[self expectationWithDescription:@"UIKit 取消 push 并恢复预检页"];
    transition.axs_cachekeeper_started=started;transition.axs_cachekeeper_returned=returned;
    transition.axs_cachekeeper_target=self.page;self.navigation.delegate=transition;
    [self.navigation pushViewController:[UIViewController new] animated:YES];
    [self waitForExpectations:@[started,returned] timeout:10];
    self.navigation.delegate=nil;
    XCTAssertEqual(self.navigation.topViewController,self.page);
    XCTAssertTrue(self.axs_cachekeeper_batch.running);
    [self axs_cachekeeper_assertRows:@"pending" saved:@"notAttempted"];
    XCTAssertTrue([[self.page valueForKey:@"axs_cachekeeper_timer"] isValid]);
    for (AxsCacheKeeperHostEvidenceClient *client in [self.axs_cachekeeper_batch valueForKey:@"axs_cachekeeper_clients"])
        XCTAssertGreaterThan(client.axs_cachekeeper_activeTokenCount,0u);
    [self axs_cachekeeper_startServers];
    // 不手动 poll，只有页面恢复的真实 timer 能将后到响应推进为终态。
    [self axs_cachekeeper_wait:^BOOL {return !self.axs_cachekeeper_batch.running;} description:@"恢复的 timer 收齐五项响应"];
    [self axs_cachekeeper_assertRows:@"observed" saved:@"succeeded"];
}

// dismiss 导航容器时页面自身 isBeingDismissed 可能为 NO，仍必须释放等待。
- (void)testActualModalNavigationDismissCancelsPendingRequests {
    [self.navigation popViewControllerAnimated:NO];
    self.page=[[AxsCacheKeeperHostPreflightPageFixture alloc] initWithStatusDirectory:self.statusDirectory panelVersion:@"0.7.2-215.1"];
    XCTestExpectation *appeared=[self expectationWithDescription:@"模态导航页面真实显示"];
    self.page.axs_cachekeeper_appeared=appeared;
    UINavigationController *modal=[[UINavigationController alloc] initWithRootViewController:self.page];
    [self.navigation presentViewController:modal animated:NO completion:nil];
    [self waitForExpectations:@[appeared] timeout:5];
    [self.page axs_cachekeeper_action];
    XCTestExpectation *dismissed=[self expectationWithDescription:@"模态导航真实 dismiss"];
    [self.navigation dismissViewControllerAnimated:NO completion:^{[dismissed fulfill];}];
    [self waitForExpectations:@[dismissed] timeout:5];
    [self axs_cachekeeper_wait:^BOOL {return !self.axs_cachekeeper_batch.running;} description:@"dismiss 取消请求"];
    [self axs_cachekeeper_assertRows:@"cancelled" saved:@"succeeded"];
}

// 原子写入被目录阻挡时保留已观察结果；重试只落盘，不能重发新请求。
- (void)testFailedSaveRemainsVisibleAndRetryPreservesObservedResult {
    NSDictionary *target=axs_cachekeeper_host_preflight_targets()[0];
    NSString *blocked=[self.statusDirectory stringByAppendingPathComponent:[target[@"bundle"] stringByAppendingString:@".hostObserved.plist"]];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtPath:blocked withIntermediateDirectories:NO attributes:nil error:NULL]);
    [self axs_cachekeeper_startServers];[self.page axs_cachekeeper_action];[self axs_cachekeeper_waitForTerminal];
    NSArray *rows=self.axs_cachekeeper_rows;XCTAssertEqualObjects(rows[0][@"state"],@"observed");
    XCTAssertEqualObjects(rows[0][@"saveState"],@"failed");XCTAssertNotEqual([rows[0][@"saveErrorCode"] integerValue],0);
    XCTAssertTrue([self.axs_cachekeeper_text containsString:@"保存"]);XCTAssertTrue([self.axs_cachekeeper_text containsString:@"失败"]);
    NSDictionary *result=[rows[0][@"result"] copy];
    XCTAssertFalse([[self.page valueForKey:@"axs_cachekeeper_retryButton"] isHidden]);
    for (AxsCacheKeeperHostEvidenceServer *server in self.servers) [server axs_cachekeeper_invalidate];
    [self.servers removeAllObjects];
    XCTAssertTrue([NSFileManager.defaultManager removeItemAtPath:blocked error:NULL]);
    [self.page axs_cachekeeper_retry_saving];
    [self axs_cachekeeper_assertRows:@"observed" saved:@"succeeded"];
    XCTAssertFalse(self.axs_cachekeeper_batch.running);
    XCTAssertEqualObjects(self.axs_cachekeeper_rows[0][@"result"],result);
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:blocked],result);
}
@end
