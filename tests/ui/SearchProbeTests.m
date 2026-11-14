#import <XCTest/XCTest.h>
#import "../../Prefs/SearchInput.h"
#import "../../Prefs/SearchDiagnostics.h"
#import "../../Prefs/DiagnosticsPage.h"
#import "../../AxsCacheKeeperDiagnostics.h"
#import "Preferences/PSViewController.h"

@interface CKSettings : PSViewController
- (void)axs_cachekeeper_diagnostics;
@end
// Only the event marker is synthetic; all hierarchy, bounds and hit testing below use UIKit.
@interface AxsCacheKeeperProbeTouchEvent : UIEvent
@end
@implementation AxsCacheKeeperProbeTouchEvent
- (UIEventType)type { return UIEventTypeTouches; }
- (NSTimeInterval)timestamp { return 1; }
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
@property(nonatomic,strong) AxsCacheKeeperSearchDiagnostics *probe;
@property(nonatomic,weak) AxsCacheKeeperSearchInput *activeInput;
@property(nonatomic,strong) XCTestExpectation *navigationFinished;
@property(nonatomic) Class expectedControllerClass;
@end
@implementation AxsCacheKeeperSearchProbeTests
- (void)setUp {
    [super setUp];
    self.previousKeyWindow=UIApplication.sharedApplication.delegate.window;
    self.window=[[UIWindow alloc] initWithFrame:CGRectMake(0,0,390,844)];
    AxsCacheKeeperProbeHostController *owner=[AxsCacheKeeperProbeHostController new];self.owner=owner;
    XCTestExpectation *visible=[self expectationWithDescription:@"UIKit delivered host viewDidAppear"];
    owner.axs_cachekeeper_appeared=visible;
    self.root=[[AxsCacheKeeperSearchRootView alloc] initWithFrame:self.window.bounds];owner.view=self.root;
    self.window.rootViewController=owner;
    self.input=[[AxsCacheKeeperSearchInput alloc] initWithFrame:CGRectMake(0,80,390,56)];[self.root addSubview:self.input];
    UITableView *table=[[UITableView alloc] initWithFrame:CGRectMake(0,160,390,500)];[self.root addSubview:table];
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
    self.probe=nil;self.input=nil;self.root=nil;self.owner=nil;self.window=nil;self.previousKeyWindow=nil;[super tearDown];
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
    if (self.navigationFinished && [viewController isKindOfClass:self.expectedControllerClass]) {
        [self.navigationFinished fulfill];self.navigationFinished=nil;
    }
}
- (NSDictionary *)axs_cachekeeper_last {
    return [[self.probe axs_cachekeeper_snapshot][@"events"] lastObject];
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
    NSDictionary *snapshot=[self.probe axs_cachekeeper_freeze:AxsCacheKeeperSearchEventDiagnostics];
    XCTAssertEqualObjects(snapshot[@"state"],@"frozen");XCTAssertEqual([snapshot[@"events"] count],2u);
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
    [wrapper addSubview:self.input];self.input.frame=CGRectMake(0,0,390,56);
    [self.probe axs_cachekeeper_record:AxsCacheKeeperSearchEventDidAppear];
    NSDictionary *last=[self axs_cachekeeper_last];
    XCTAssertNotEqualObjects(last[@"centerHit"],@"field");
    BOOL foundBoundsMiss=NO;
    for (NSDictionary *ancestor in last[@"ancestors"])
        if (![ancestor[@"view"][@"centerInsideBounds"] boolValue] && ![ancestor[@"view"][@"clips"] boolValue]) foundBoundsMiss=YES;
    XCTAssertTrue(foundBoundsMiss);
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
    __weak AxsCacheKeeperSearchDiagnostics *weakProbe=self.probe;
    self.probe=nil;XCTAssertNil(weakProbe);
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
