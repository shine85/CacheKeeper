#import <XCTest/XCTest.h>
#import "../../Prefs/SearchInput.h"
#import "../../Prefs/SearchDiagnostics.h"
#import "../../Prefs/DiagnosticsPage.h"
#import "../../AxsCacheKeeperDiagnostics.h"
#import "Preferences/PSViewController.h"

@interface CKSettings : PSViewController
- (void)axs_cachekeeper_diagnostics;
- (void)updateBatch;
@end
@interface AxsCacheKeeperTestHostBarContainer : UIView
@end
@interface AxsCacheKeeperVisualSettings : CKSettings
@end
@interface AxsCacheKeeperTestNestedHost : UIViewController
@property(nonatomic,strong) UINavigationController *axs_cachekeeper_inner;
- (instancetype)initWithSettings:(CKSettings *)settings;
@end
// Only the event marker is synthetic; all hierarchy, bounds and hit testing below use UIKit.
@interface AxsCacheKeeperProbeTouchEvent : UIEvent
@end
@implementation AxsCacheKeeperProbeTouchEvent
- (UIEventType)type { return UIEventTypeTouches; }
- (NSTimeInterval)timestamp { return 1; }
@end
@interface AxsCacheKeeperProbeRootView : AxsCacheKeeperSearchRootView
@property(nonatomic) NSUInteger axs_cachekeeper_nilEventQueries;
@end
@implementation AxsCacheKeeperProbeRootView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!event) self.axs_cachekeeper_nilEventQueries++;
    return [super hitTest:point withEvent:event];
}
@end
@interface AxsCacheKeeperProbeHostController : UIViewController
@property(nonatomic,strong) XCTestExpectation *axs_cachekeeper_appeared;
@end
@implementation AxsCacheKeeperProbeHostController
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];[self.axs_cachekeeper_appeared fulfill];self.axs_cachekeeper_appeared=nil;
}
@end
@interface AxsCacheKeeperSearchProbeTests : XCTestCase <UINavigationControllerDelegate>
@property(nonatomic,strong) UIWindow *window;
@property(nonatomic,strong) UIWindow *previousKeyWindow;
@property(nonatomic,strong) AxsCacheKeeperProbeHostController *owner;
@property(nonatomic,strong) AxsCacheKeeperSearchRootView *root;
@property(nonatomic,strong) AxsCacheKeeperSearchInput *input;
@property(nonatomic,strong) UITableView *table;
@property(nonatomic,strong) AxsCacheKeeperSearchDiagnostics *probe;
@property(nonatomic,weak) AxsCacheKeeperSearchInput *activeInput;
@property(nonatomic,strong) XCTestExpectation *navigationFinished;
@property(nonatomic) Class expectedControllerClass;
@property(nonatomic,weak) UINavigationController *expectedNavigation;
@property(nonatomic,weak) UIViewController *expectedController;
@end
@implementation AxsCacheKeeperSearchProbeTests
- (void)setUp {
    [super setUp];
    self.previousKeyWindow=UIApplication.sharedApplication.delegate.window;
    self.window=[[UIWindow alloc] initWithFrame:CGRectMake(0,0,390,844)];
    AxsCacheKeeperProbeHostController *owner=[AxsCacheKeeperProbeHostController new];self.owner=owner;
    XCTestExpectation *visible=[self expectationWithDescription:@"UIKit delivered host viewDidAppear"];
    owner.axs_cachekeeper_appeared=visible;
    self.root=[[AxsCacheKeeperProbeRootView alloc] initWithFrame:self.window.bounds];owner.view=self.root;
    self.window.rootViewController=owner;
    self.input=[[AxsCacheKeeperSearchInput alloc] initWithFrame:CGRectMake(0,80,390,44)];[self.root addSubview:self.input];
    UITableView *table=[[UITableView alloc] initWithFrame:CGRectMake(0,160,390,500)];self.table=table;[self.root addSubview:table];
    self.probe=[[AxsCacheKeeperSearchDiagnostics alloc] initWithField:self.input.axs_cachekeeper_field input:self.input root:self.root table:table owner:owner];
    self.input.axs_cachekeeper_diagnostics=self.probe;self.root.axs_cachekeeper_diagnostics=self.probe;
    [self.window makeKeyAndVisible];[self waitForExpectations:@[visible] timeout:10];
    XCTAssertTrue(self.window.isKeyWindow);XCTAssertEqual(self.root.window,self.window);
    [self.root layoutIfNeeded];[self.input layoutIfNeeded];
}
- (void)tearDown {
    [self.probe axs_cachekeeper_freeze:AxsCacheKeeperSearchEventWillDisappear];
    if (self.activeInput.axs_cachekeeper_field.isFirstResponder) [self axs_cachekeeper_dismiss:self.activeInput];
    if (self.owner.presentedViewController) {
        XCTestExpectation *dismissed=[self expectationWithDescription:@"Presented test controller dismissed"];
        [self.owner dismissViewControllerAnimated:NO completion:^{ [dismissed fulfill]; }];
        [self waitForExpectations:@[dismissed] timeout:10];
    }
    XCTestExpectation *hidden=[self expectationForNotification:UIWindowDidBecomeHiddenNotification object:self.window handler:nil];
    self.window.hidden=YES;
    [self waitForExpectations:@[hidden] timeout:10];
    XCTAssertTrue(self.window.hidden);
    self.window.rootViewController=nil;[self.previousKeyWindow makeKeyWindow];
    self.probe=nil;self.input=nil;self.table=nil;self.root=nil;self.owner=nil;self.window=nil;self.previousKeyWindow=nil;[super tearDown];
}
- (void)axs_cachekeeper_focus:(AxsCacheKeeperSearchInput *)input {
    XCTAssertEqual(input.window,self.window);XCTAssertTrue(self.window.isKeyWindow);
    XCTestExpectation *editing=[self expectationForNotification:UITextFieldTextDidBeginEditingNotification object:input.axs_cachekeeper_field handler:nil];
    XCTestExpectation *keyboard=[self expectationForNotification:UIKeyboardDidShowNotification object:nil handler:nil];
    self.activeInput=input;XCTAssertTrue([input axs_cachekeeper_focus]);
    [self waitForExpectations:@[editing,keyboard] timeout:10];XCTAssertTrue(input.axs_cachekeeper_field.isFirstResponder);
}
- (void)axs_cachekeeper_dismiss:(AxsCacheKeeperSearchInput *)input {
    XCTestExpectation *editing=[self expectationForNotification:UITextFieldTextDidEndEditingNotification object:input.axs_cachekeeper_field handler:nil];
    XCTestExpectation *keyboard=[self expectationForNotification:UIKeyboardDidHideNotification object:nil handler:nil];
    [input axs_cachekeeper_dismiss_keyboard];
    [self waitForExpectations:@[editing,keyboard] timeout:10];XCTAssertFalse(input.axs_cachekeeper_field.isFirstResponder);
    self.activeInput=nil;
}
- (void)navigationController:(UINavigationController *)navigationController didShowViewController:(UIViewController *)viewController animated:(BOOL)animated {
    (void)navigationController;(void)animated;
    BOOL matches=self.expectedController ? (navigationController==self.expectedNavigation && viewController==self.expectedController) :
        [viewController isKindOfClass:self.expectedControllerClass];
    if (self.navigationFinished && matches) {
        [self.navigationFinished fulfill];self.navigationFinished=nil;
        self.expectedNavigation=nil;self.expectedController=nil;
    }
}
- (NSDictionary *)axs_cachekeeper_last {
    return [[self.probe axs_cachekeeper_snapshot][@"events"] lastObject];
}
- (void)testCompactTitleUsesAncestorItemAndRestoresOnInnerNavigation {
    for (NSNumber *mode in @[@(UINavigationItemLargeTitleDisplayModeAutomatic),@(UINavigationItemLargeTitleDisplayModeAlways)]) {
        AxsCacheKeeperVisualSettings *settings=[AxsCacheKeeperVisualSettings new];
        AxsCacheKeeperTestNestedHost *host=[[AxsCacheKeeperTestNestedHost alloc] initWithSettings:settings];
        host.navigationItem.largeTitleDisplayMode=mode.integerValue;
        UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:host];
        nav.navigationBar.prefersLargeTitles=YES;nav.modalPresentationStyle=UIModalPresentationFullScreen;
        XCTestExpectation *shown=[self expectationWithDescription:@"Nested navigation appeared"];
        [self.owner presentViewController:nav animated:NO completion:^{ [shown fulfill]; }];
        [self waitForExpectations:@[shown] timeout:10];
        [nav.view layoutIfNeeded];
        AxsCacheKeeperSearchInput *input=[settings valueForKey:@"axs_cachekeeper_searchInput"];
        for (NSUInteger i=0;i<3;i++) {
            [settings updateBatch];
            XCTAssertEqual(host.navigationItem.largeTitleDisplayMode,UINavigationItemLargeTitleDisplayModeNever);
            // 126.1 device: the mode alone does not shrink the bar (its frame stayed 91pt with
            // the mode at Never), so the claim also switches the host bar off large titles.
            XCTAssertFalse(nav.navigationBar.prefersLargeTitles);
            XCTAssertTrue(host.axs_cachekeeper_inner.navigationBarHidden);
            CGRect rect=[input.axs_cachekeeper_field convertRect:input.axs_cachekeeper_field.bounds toView:self.window];
            CGRect bar=[nav.navigationBar convertRect:nav.navigationBar.bounds toView:self.window];
            XCTAssertGreaterThanOrEqual(rect.origin.y,CGRectGetMaxY(bar));
            XCTAssertLessThanOrEqual(nav.navigationBar.bounds.size.height,44.5);
        }
        UIViewController *detail=[UIViewController new];
        host.axs_cachekeeper_inner.delegate=self;
        self.expectedNavigation=host.axs_cachekeeper_inner;self.expectedController=detail;
        XCTestExpectation *pushed=[self expectationWithDescription:@"Inner navigation delivered detail didShow"];
        self.navigationFinished=pushed;
        [host.axs_cachekeeper_inner pushViewController:detail animated:NO];
        [self waitForExpectations:@[pushed] timeout:10];
        XCTAssertEqual(host.navigationItem.largeTitleDisplayMode,mode.integerValue);
        XCTAssertTrue(nav.navigationBar.prefersLargeTitles);
        self.expectedNavigation=host.axs_cachekeeper_inner;self.expectedController=settings;
        XCTestExpectation *popped=[self expectationWithDescription:@"Inner navigation delivered settings didShow"];
        self.navigationFinished=popped;
        [host.axs_cachekeeper_inner popViewControllerAnimated:NO];
        [self waitForExpectations:@[popped] timeout:10];
        [nav.view layoutIfNeeded];[settings updateBatch];
        XCTAssertEqual(host.navigationItem.largeTitleDisplayMode,UINavigationItemLargeTitleDisplayModeNever);
        XCTAssertFalse(nav.navigationBar.prefersLargeTitles);
        // A subsequent host change belongs to the host and must not be overwritten on release.
        host.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeAlways;
        self.expectedNavigation=host.axs_cachekeeper_inner;self.expectedController=detail;
        XCTestExpectation *repushed=[self expectationWithDescription:@"Host override preserved after detail didShow"];
        self.navigationFinished=repushed;
        [host.axs_cachekeeper_inner pushViewController:detail animated:NO];
        [self waitForExpectations:@[repushed] timeout:10];
        XCTAssertEqual(host.navigationItem.largeTitleDisplayMode,UINavigationItemLargeTitleDisplayModeAlways);
        XCTAssertTrue(nav.navigationBar.prefersLargeTitles);
        XCTestExpectation *dismissed=[self expectationWithDescription:@"Nested navigation dismissed"];
        [self.owner dismissViewControllerAnimated:NO completion:^{ [dismissed fulfill]; }];
        [self waitForExpectations:@[dismissed] timeout:10];
    }
}
- (void)testUpdateBatchShrinksStaleExpandedHostBar {
    // 124.1 device: the host bar re-expanded after appearance (mode still Never, frame stale
    // at ~91pt), so the geometry clearance held ~47pt. A viewDidAppear-only force cannot catch
    // it; the per-second batch must shrink the bar back.
    AxsCacheKeeperVisualSettings *settings=[AxsCacheKeeperVisualSettings new];
    AxsCacheKeeperTestNestedHost *host=[[AxsCacheKeeperTestNestedHost alloc] initWithSettings:settings];
    host.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeAutomatic;
    UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:host];
    nav.navigationBar.prefersLargeTitles=YES;nav.modalPresentationStyle=UIModalPresentationFullScreen;
    XCTestExpectation *shown=[self expectationWithDescription:@"Nested navigation appeared"];
    [self.owner presentViewController:nav animated:NO completion:^{ [shown fulfill]; }];
    [self waitForExpectations:@[shown] timeout:10];
    [nav.view layoutIfNeeded];
    AxsCacheKeeperSearchInput *input=[settings valueForKey:@"axs_cachekeeper_searchInput"];
    [settings updateBatch];
    XCTAssertEqual(host.navigationItem.largeTitleDisplayMode,UINavigationItemLargeTitleDisplayModeNever);
    XCTAssertLessThanOrEqual(nav.navigationBar.bounds.size.height,44.5);
    CGFloat originalTop=[input.axs_cachekeeper_field convertRect:input.axs_cachekeeper_field.bounds toView:self.window].origin.y;
    // Force the stale expanded frame while the mode stays Never, exactly as on device.
    CGRect frame=nav.navigationBar.frame;frame.size.height=91;nav.navigationBar.frame=frame;
    XCTAssertEqualWithAccuracy(nav.navigationBar.bounds.size.height,91,0.5);
    XCTAssertEqual(host.navigationItem.largeTitleDisplayMode,UINavigationItemLargeTitleDisplayModeNever);
    [settings updateBatch];
    XCTAssertLessThanOrEqual(nav.navigationBar.bounds.size.height,44.5);
    CGRect rect=[input.axs_cachekeeper_field convertRect:input.axs_cachekeeper_field.bounds toView:self.window];
    XCTAssertGreaterThanOrEqual(rect.origin.y,CGRectGetMaxY([nav.navigationBar convertRect:nav.navigationBar.bounds toView:self.window]));
    XCTAssertEqualWithAccuracy(rect.origin.y,originalTop,0.5);
    XCTestExpectation *dismissed=[self expectationWithDescription:@"Nested navigation dismissed"];
    [self.owner dismissViewControllerAnimated:NO completion:^{ [dismissed fulfill]; }];
    [self waitForExpectations:@[dismissed] timeout:10];
}
- (void)testSearchClearsExternalNavigationBarAndReturnsAfterCollapse {
    CKSettings *settings=[CKSettings new];
    settings.additionalSafeAreaInsets=UIEdgeInsetsMake(44,0,0,0);
    UINavigationController *navigation=[[UINavigationController alloc] initWithRootViewController:settings];
    navigation.navigationBarHidden=YES;navigation.delegate=self;
    self.expectedControllerClass=CKSettings.class;
    self.navigationFinished=[self expectationWithDescription:@"Settings appeared in hidden inner navigation"];
    XCTestExpectation *shown=self.navigationFinished;
    self.window.rootViewController=navigation;
    [self waitForExpectations:@[shown] timeout:10];
    [self.window layoutIfNeeded];
    AxsCacheKeeperSearchInput *input=[settings valueForKey:@"axs_cachekeeper_searchInput"];
    UITextField *field=input.axs_cachekeeper_field;
    CGFloat originalTop=[field convertRect:field.bounds toView:self.window].origin.y;
    CGFloat safeTop=[settings.view convertPoint:CGPointMake(0,settings.view.safeAreaInsets.top) toView:self.window].y;
    XCTAssertTrue(settings.navigationController.navigationBar.hidden);
    UINavigationBar *bar=[[UINavigationBar alloc] initWithFrame:CGRectMake(0,safeTop-44,self.window.bounds.size.width,91)];
    UIView *wrapper=[[AxsCacheKeeperTestHostBarContainer alloc] initWithFrame:self.window.bounds];
    [wrapper addSubview:bar];[self.window addSubview:wrapper];
    for (NSNumber *height in @[@91,@120,@44,@110]) {
        CGRect frame=bar.frame;frame.size.height=height.doubleValue;bar.frame=frame;
        // The last change happens entirely outside the content hierarchy. Only the existing refresh runs.
        if (height.doubleValue!=110) { [settings.view setNeedsLayout];[settings.view layoutIfNeeded]; }
        [settings updateBatch];
        XCTAssertEqualWithAccuracy(bar.frame.origin.y,safeTop-44,0.5);
        XCTAssertEqualWithAccuracy(bar.frame.size.height,height.doubleValue,0.5);
        XCTAssertFalse(bar.hidden);XCTAssertTrue(bar.userInteractionEnabled);
        XCTAssertEqual(bar.superview,wrapper);
        CGRect fieldRect=[field convertRect:field.bounds toView:self.window];
        XCTAssertGreaterThanOrEqual(CGRectGetMinY(fieldRect),CGRectGetMaxY(bar.frame));
        if (height.doubleValue==44) XCTAssertEqualWithAccuracy(fieldRect.origin.y,originalTop,0.5);
        CGPoint center=CGPointMake(CGRectGetMidX(fieldRect),CGRectGetMidY(fieldRect));
        UIView *hit=[self.window hitTest:center withEvent:nil];
        XCTAssertTrue(hit==field || [hit isDescendantOfView:field]);
        for (NSUInteger repeat=0;repeat<3;repeat++) {
            [settings updateBatch];
            XCTAssertEqualWithAccuracy([field convertRect:field.bounds toView:self.window].origin.y,fieldRect.origin.y,0.5);
        }
    }
    CGFloat expandedTop=[field convertRect:field.bounds toView:self.window].origin.y;
    UIView *temporaryCover=[[UIView alloc] initWithFrame:self.window.bounds];
    [self.window addSubview:temporaryCover];
    [settings updateBatch];
    XCTAssertEqualWithAccuracy([field convertRect:field.bounds toView:self.window].origin.y,expandedTop,0.5);
    [temporaryCover removeFromSuperview];[settings updateBatch];
    XCTAssertEqualWithAccuracy([field convertRect:field.bounds toView:self.window].origin.y,expandedTop,0.5);
    bar.hidden=YES;
    [settings updateBatch];
    XCTAssertEqualWithAccuracy([field convertRect:field.bounds toView:self.window].origin.y,originalTop,0.5);
    bar.hidden=NO;
    wrapper.hidden=YES;[settings updateBatch];
    XCTAssertEqualWithAccuracy([field convertRect:field.bounds toView:self.window].origin.y,originalTop,0.5);
    wrapper.hidden=NO;[settings updateBatch];
    XCTAssertEqualWithAccuracy([field convertRect:field.bounds toView:self.window].origin.y,expandedTop,0.5);
    CGRect offscreen=bar.frame;offscreen.origin.x=self.window.bounds.size.width+10;bar.frame=offscreen;
    [settings updateBatch];
    XCTAssertEqualWithAccuracy([field convertRect:field.bounds toView:self.window].origin.y,originalTop,0.5);
    XCTAssertEqualWithAccuracy(bar.frame.origin.x,offscreen.origin.x,0.5);
    [wrapper removeFromSuperview];
}
- (void)testProducerBooleansSurviveStrictProjectionAndReport {
    [self.probe axs_cachekeeper_record:AxsCacheKeeperSearchEventDidAppear];
    NSDictionary *raw=[[self.probe valueForKey:@"events"] lastObject];
    // #116: these C comparison/logical expressions boxed as int and invalidated every real snapshot.
    for (NSString *key in @[@"presented",@"windowAttached",@"ancestorsTruncated"]) {
        id value=raw[key];XCTAssertNotNil(value);
        if (value) XCTAssertEqual(CFGetTypeID((__bridge CFTypeRef)value),CFBooleanGetTypeID(),@"%@ must originate as a boolean",key);
    }
    for (NSString *key in @[@"field",@"input",@"root",@"table"]) {
        id value=raw[key][@"centerInsideBounds"];XCTAssertNotNil(value);
        if (value) XCTAssertEqual(CFGetTypeID((__bridge CFTypeRef)value),CFBooleanGetTypeID(),@"%@ bounds result must originate as a boolean",key);
    }
    NSDictionary *route=raw[@"hitRoute"];
    XCTAssertNotNil(route);
    for (NSString *key in @[@"hitAncestorsTruncated",@"windowHitInsideRoot",@"windowHitInsideNavigationBar",@"sameHit"]) {
        id value=route[key];XCTAssertNotNil(value);
        if (value) XCTAssertEqual(CFGetTypeID((__bridge CFTypeRef)value),CFBooleanGetTypeID(),@"%@ must originate as CFBoolean",key);
    }
    NSDictionary *snapshot=[self.probe axs_cachekeeper_freeze:AxsCacheKeeperSearchEventDiagnostics];
    XCTAssertEqualObjects(snapshot[@"state"],@"frozen");XCTAssertEqual([snapshot[@"events"] count],2u);
    XCTAssertEqualObjects(snapshot[@"probeRevision"],@2);
    NSString *folder=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    AxsCacheKeeperDiagnostics *session=[[AxsCacheKeeperDiagnostics alloc] initWithFolder:folder];
    NSDictionary *report=[session reportWithApps:@[] environment:@{@"searchUI":snapshot}];
    XCTAssertEqualObjects(report[@"searchUI"],snapshot);
    XCTAssertNotNil([NSJSONSerialization dataWithJSONObject:report options:0 error:nil]);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:folder]);
}
- (void)testRealHierarchyDistinguishesFieldOverlayAndBoundsMiss {
    [self.probe axs_cachekeeper_record:AxsCacheKeeperSearchEventDidAppear];
    XCTAssertEqualObjects([self axs_cachekeeper_last][@"centerHit"],@"field");
    UIView *overlay=[[UIView alloc] initWithFrame:self.input.frame];[self.root addSubview:overlay];
    [self.probe axs_cachekeeper_record:AxsCacheKeeperSearchEventDidAppear];
    XCTAssertEqualObjects([self axs_cachekeeper_last][@"centerHit"],@"other");
    [overlay removeFromSuperview];
    // An actual unclipped wrapper draws the input outside its bounds but cannot hit that portion.
    UIView *wrapper=[[UIView alloc] initWithFrame:CGRectMake(0,80,390,10)];[self.root addSubview:wrapper];
    [wrapper addSubview:self.input];self.input.frame=CGRectMake(0,0,390,44);
    [self.probe axs_cachekeeper_record:AxsCacheKeeperSearchEventDidAppear];
    NSDictionary *last=[self axs_cachekeeper_last];
    XCTAssertNotEqualObjects(last[@"centerHit"],@"field");
    BOOL foundBoundsMiss=NO;
    for (NSDictionary *ancestor in last[@"ancestors"])
        if (![ancestor[@"view"][@"centerInsideBounds"] boolValue] && ![ancestor[@"view"][@"clips"] boolValue]) foundBoundsMiss=YES;
    XCTAssertTrue(foundBoundsMiss);
}
- (void)testRouteSeparatesWindowOverlayFromRootLocalHit {
    UIViewController *owner=[UIViewController new];
    AxsCacheKeeperSearchRootView *root=[[AxsCacheKeeperSearchRootView alloc] initWithFrame:self.window.bounds];owner.view=root;
    AxsCacheKeeperSearchInput *input=[[AxsCacheKeeperSearchInput alloc] initWithFrame:CGRectMake(0,120,390,44)];[root addSubview:input];
    UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:owner];nav.modalPresentationStyle=UIModalPresentationFullScreen;
    XCTestExpectation *visible=[self expectationWithDescription:@"Navigation host visible for route capture"];
    [self.owner presentViewController:nav animated:NO completion:^{ [visible fulfill]; }];
    [self waitForExpectations:@[visible] timeout:10];[root layoutIfNeeded];[input layoutIfNeeded];
    AxsCacheKeeperSearchDiagnostics *probe=[[AxsCacheKeeperSearchDiagnostics alloc] initWithField:input.axs_cachekeeper_field input:input root:root table:nil owner:owner];
    root.axs_cachekeeper_diagnostics=probe;
    [probe axs_cachekeeper_record:AxsCacheKeeperSearchEventDidAppear];
    NSDictionary *normal=[[probe axs_cachekeeper_snapshot][@"events"] lastObject][@"hitRoute"];
    XCTAssertEqualObjects(normal[@"rootCenterHit"],@"field");XCTAssertEqualObjects(normal[@"windowHit"][@"role"],@"field");
    XCTAssertTrue([normal[@"windowHitInsideRoot"] boolValue]);XCTAssertTrue([normal[@"sameHit"] boolValue]);
    UIView *overlay=[[UIView alloc] initWithFrame:[input convertRect:input.bounds toView:nav.view]];[nav.view addSubview:overlay];
    [probe axs_cachekeeper_record:AxsCacheKeeperSearchEventDidAppear];
    NSDictionary *route=[[probe axs_cachekeeper_snapshot][@"events"] lastObject][@"hitRoute"];
    XCTAssertEqualObjects(route[@"rootCenterHit"],@"field");
    XCTAssertEqualObjects(route[@"windowHit"][@"role"],@"navigationContainer");XCTAssertEqualObjects(route[@"windowHit"][@"kind"],@"view");
    XCTAssertFalse([route[@"windowHitInsideRoot"] boolValue]);XCTAssertFalse([route[@"windowHitInsideNavigationBar"] boolValue]);
    XCTAssertFalse([route[@"sameHit"] boolValue]);XCTAssertTrue([route[@"navigationBar"][@"windowRect"][@"valid"] boolValue]);
    XCTAssertTrue([[route[@"hitAncestors"] valueForKey:@"role"] containsObject:@"navigationContainer"]);
    XCTAssertEqual([(NSArray *)[probe axs_cachekeeper_snapshot][@"events"] count],2u);
}
- (void)testSamplingDeduplicatesSearchStateAndIgnoresTableScrolling {
    for (NSUInteger i=0;i<24;i++) [self.probe axs_cachekeeper_sample];
    NSDictionary *snapshot=[self.probe axs_cachekeeper_snapshot];
    XCTAssertEqual([(NSArray *)snapshot[@"events"] count],1u);XCTAssertEqualObjects(snapshot[@"events"][0][@"event"],@"sampled");
    XCTAssertFalse([snapshot[@"truncated"] boolValue]);
    self.table.contentOffset=CGPointMake(0,40);[self.probe axs_cachekeeper_sample];
    XCTAssertEqual([(NSArray *)[self.probe axs_cachekeeper_snapshot][@"events"] count],1u);
    UITextField *field=self.input.axs_cachekeeper_field;
    CGPoint point=[field convertPoint:CGPointMake(CGRectGetMidX(field.bounds),CGRectGetMidY(field.bounds)) toView:self.root];
    [self.root hitTest:point withEvent:[AxsCacheKeeperProbeTouchEvent new]];
    [self.probe axs_cachekeeper_sample];
    NSArray *events=[self.probe axs_cachekeeper_snapshot][@"events"];
    XCTAssertEqual(events.count,2u);XCTAssertEqualObjects([events lastObject][@"event"],@"rootHit");
    UIView *overlay=[[UIView alloc] initWithFrame:self.input.frame];[self.root addSubview:overlay];
    [self.probe axs_cachekeeper_sample];[self.probe axs_cachekeeper_sample];
    XCTAssertEqual([(NSArray *)[self.probe axs_cachekeeper_snapshot][@"events"] count],3u);
    XCTAssertEqualObjects([self axs_cachekeeper_last][@"hitRoute"][@"windowHit"][@"role"],@"root");
    [overlay removeFromSuperview];self.input.alpha=0.8;
    [self.probe axs_cachekeeper_sample];
    XCTAssertEqual([(NSArray *)[self.probe axs_cachekeeper_snapshot][@"events"] count],4u);
    snapshot=[self.probe axs_cachekeeper_freeze:AxsCacheKeeperSearchEventDiagnostics];
    NSUInteger queries=((AxsCacheKeeperProbeRootView *)self.root).axs_cachekeeper_nilEventQueries;
    self.input.hidden=YES;[self.probe axs_cachekeeper_sample];
    XCTAssertEqualObjects(snapshot,[self.probe axs_cachekeeper_snapshot]);
    XCTAssertEqual(((AxsCacheKeeperProbeRootView *)self.root).axs_cachekeeper_nilEventQueries,queries);
    [self.probe axs_cachekeeper_clear];[self.probe axs_cachekeeper_sample];
    XCTAssertEqual([(NSArray *)[self.probe axs_cachekeeper_snapshot][@"events"] count],0u);
    self.input.hidden=NO;[self.probe axs_cachekeeper_begin];[self.probe axs_cachekeeper_sample];
    XCTAssertEqual([(NSArray *)[self.probe axs_cachekeeper_snapshot][@"events"] count],1u);
    [self.input removeFromSuperview];[self.probe axs_cachekeeper_sample];
    XCTAssertEqual([(NSArray *)[self.probe axs_cachekeeper_snapshot][@"events"] count],1u);
}
- (void)testRootObservationReturnsOriginalHitAndDoesNotSelfRecurse {
    UITextField *field=self.input.axs_cachekeeper_field;
    CGPoint point=[field convertPoint:CGPointMake(CGRectGetMidX(field.bounds),CGRectGetMidY(field.bounds)) toView:self.root];
    UIView *expected=[self.root hitTest:point withEvent:nil];
    XCTAssertEqual([(NSArray *)[self.probe axs_cachekeeper_snapshot][@"events"] count],0u);
    UIView *observed=[self.root hitTest:point withEvent:[AxsCacheKeeperProbeTouchEvent new]];
    XCTAssertEqual(observed,expected);
    NSArray *events=[self.probe axs_cachekeeper_snapshot][@"events"];
    XCTAssertEqual(events.count,1u);XCTAssertEqualObjects(events[0][@"observedHit"],@"field");
    [self.root hitTest:CGPointMake(20,400) withEvent:[AxsCacheKeeperProbeTouchEvent new]];
    XCTAssertEqual([(NSArray *)[self.probe axs_cachekeeper_snapshot][@"events"] count],1u);
}
- (void)testDisabledFieldAndEarlyFocusReturnAreObserved {
    self.input.axs_cachekeeper_field.enabled=NO;
    self.input.axs_cachekeeper_field.userInteractionEnabled=YES;
    [self.probe axs_cachekeeper_record:AxsCacheKeeperSearchEventDidAppear];
    XCTAssertFalse([[self axs_cachekeeper_last][@"fieldEnabled"] boolValue]);
    XCTAssertTrue([[self axs_cachekeeper_last][@"field"][@"interaction"] boolValue]);
    self.input.userInteractionEnabled=NO;
    XCTAssertFalse([self.input axs_cachekeeper_focus]);
    XCTAssertEqualObjects([self axs_cachekeeper_last][@"event"],@"focusDisabled");
    self.input.userInteractionEnabled=YES;self.input.hidden=YES;
    XCTAssertFalse([self.input axs_cachekeeper_focus]);
    XCTAssertEqualObjects([self axs_cachekeeper_last][@"event"],@"focusHidden");
    [self.input removeFromSuperview];
    XCTAssertFalse([self.input axs_cachekeeper_focus]);
    XCTAssertEqualObjects([self axs_cachekeeper_last][@"event"],@"focusNoWindow");
}
- (void)testBoundsAndFreezeStopNavigationDismissEvents {
    for (NSUInteger i=0;i<24;i++) [self.probe axs_cachekeeper_record:AxsCacheKeeperSearchEventDidAppear];
    NSDictionary *snapshot=[self.probe axs_cachekeeper_freeze:AxsCacheKeeperSearchEventDiagnostics];
    XCTAssertEqual([(NSArray *)snapshot[@"events"] count],16u);XCTAssertTrue([snapshot[@"truncated"] boolValue]);
    [self axs_cachekeeper_focus:self.input];[self axs_cachekeeper_dismiss:self.input];
    XCTAssertEqualObjects(snapshot,[self.probe axs_cachekeeper_snapshot]);
    [self.probe axs_cachekeeper_begin];[self axs_cachekeeper_focus:self.input];
    NSArray *names=[[self.probe axs_cachekeeper_snapshot][@"events"] valueForKey:@"event"];
    XCTAssertTrue([names containsObject:@"shouldBegin"]);XCTAssertTrue([names containsObject:@"didBegin"]);
    XCTAssertFalse([[self.probe axs_cachekeeper_snapshot][@"truncated"] boolValue]);
    [self.probe axs_cachekeeper_clear];
    XCTAssertEqual([(NSArray *)[self.probe axs_cachekeeper_snapshot][@"events"] count],0u);
}
- (void)testAncestorDepthAndWeakOwnership {
    UIView *parent=self.input.superview;
    for (NSUInteger i=0;i<9;i++) {
        UIView *wrapper=[[UIView alloc] initWithFrame:parent.bounds];[parent addSubview:wrapper];[wrapper addSubview:self.input];parent=wrapper;
    }
    [self.probe axs_cachekeeper_record:AxsCacheKeeperSearchEventDidAppear];
    NSDictionary *last=[self axs_cachekeeper_last];
    XCTAssertEqual([(NSArray *)last[@"ancestors"] count],6u);XCTAssertTrue([last[@"ancestorsTruncated"] boolValue]);
    XCTAssertEqual([(NSArray *)last[@"hitRoute"][@"hitAncestors"] count],6u);
    XCTAssertTrue([last[@"hitRoute"][@"hitAncestorsTruncated"] boolValue]);
    __weak AxsCacheKeeperSearchDiagnostics *weakProbe=self.probe;
    self.probe=nil;XCTAssertNil(weakProbe);
}
- (void)testSnapshotDoesNotRetainUIKitOwners {
    __weak UIViewController *weakOwner;__weak UINavigationController *weakNavigation;
    __weak UIView *weakRoot;__weak UITextField *weakField;
    AxsCacheKeeperSearchDiagnostics *probe;NSDictionary *snapshot;
    @autoreleasepool {
        UIViewController *owner=[UIViewController new];UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:owner];
        UIView *root=owner.view;UITextField *field=[[UITextField alloc] initWithFrame:CGRectMake(0,0,100,44)];[root addSubview:field];
        [nav loadViewIfNeeded];
        weakOwner=owner;weakNavigation=nav;weakRoot=root;weakField=field;
        probe=[[AxsCacheKeeperSearchDiagnostics alloc] initWithField:field input:root root:root table:nil owner:owner];
        [probe axs_cachekeeper_record:AxsCacheKeeperSearchEventLoaded];snapshot=[probe axs_cachekeeper_snapshot];
    }
    XCTAssertNil(weakOwner);XCTAssertNil(weakNavigation);XCTAssertNil(weakRoot);XCTAssertNil(weakField);
    XCTAssertEqualObjects(snapshot[@"state"],@"recording");XCTAssertEqual([(NSArray *)snapshot[@"events"] count],1u);
    [probe axs_cachekeeper_sample];XCTAssertEqualObjects(snapshot,[probe axs_cachekeeper_snapshot]);
}
- (void)testSettingsTransfersFrozenSnapshotBeforeResigning {
    CKSettings *settings=[CKSettings new];UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:settings];
    nav.delegate=self;nav.modalPresentationStyle=UIModalPresentationFullScreen;
    XCTestExpectation *visible=[self expectationWithDescription:@"UIKit completed Settings presentation"];
    [self.owner presentViewController:nav animated:NO completion:^{ [visible fulfill]; }];
    [self waitForExpectations:@[visible] timeout:10];
    AxsCacheKeeperSearchInput *input=[settings valueForKey:@"axs_cachekeeper_searchInput"];
    AxsCacheKeeperSearchDiagnostics *probe=[settings valueForKey:@"axs_cachekeeper_searchDiagnostics"];
    XCTAssertEqualObjects([[probe axs_cachekeeper_snapshot][@"events"] lastObject][@"event"],@"didAppear");
    [self axs_cachekeeper_focus:input];
    XCTestExpectation *editing=[self expectationForNotification:UITextFieldTextDidEndEditingNotification object:input.axs_cachekeeper_field handler:nil];
    XCTestExpectation *keyboard=[self expectationForNotification:UIKeyboardDidHideNotification object:nil handler:nil];
    XCTestExpectation *pushed=[self expectationWithDescription:@"UIKit completed diagnostics push"];
    self.navigationFinished=pushed;self.expectedControllerClass=AxsCacheKeeperDiagnosticsPage.class;
    [settings axs_cachekeeper_diagnostics];
    AxsCacheKeeperDiagnosticsPage *page=(id)nav.topViewController;
    NSDictionary *snapshot=[page valueForKey:@"axs_cachekeeper_searchSnapshot"];
    XCTAssertEqualObjects(snapshot[@"state"],@"frozen");
    NSDictionary *last=[snapshot[@"events"] lastObject];
    XCTAssertEqualObjects(last[@"event"],@"diagnostics");XCTAssertTrue([last[@"firstResponder"] boolValue]);
    XCTAssertFalse(input.axs_cachekeeper_field.isFirstResponder);
    [self waitForExpectations:@[pushed,editing,keyboard] timeout:10];self.activeInput=nil;
    XCTAssertEqual([(NSArray *)[probe axs_cachekeeper_snapshot][@"events"] count],0u);
    XCTAssertEqualObjects(snapshot,[page valueForKey:@"axs_cachekeeper_searchSnapshot"]);
    XCTestExpectation *popped=[self expectationWithDescription:@"UIKit completed Settings return"];
    self.navigationFinished=popped;self.expectedControllerClass=CKSettings.class;
    [nav popViewControllerAnimated:YES];[self waitForExpectations:@[popped] timeout:10];
    XCTAssertEqualObjects([[probe axs_cachekeeper_snapshot][@"events"] firstObject][@"event"],@"willAppear");
    XCTAssertEqualObjects([[probe axs_cachekeeper_snapshot][@"events"] lastObject][@"event"],@"didAppear");
}
@end
