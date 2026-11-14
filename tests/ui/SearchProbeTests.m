#import <XCTest/XCTest.h>
#import "../../Prefs/SearchInput.h"
#import "../../Prefs/SearchDiagnostics.h"
#import "../../Prefs/DiagnosticsPage.h"
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
@interface AxsCacheKeeperSearchProbeTests : XCTestCase
@property(nonatomic,strong) UIWindow *window;
@property(nonatomic,strong) AxsCacheKeeperSearchRootView *root;
@property(nonatomic,strong) AxsCacheKeeperSearchInput *input;
@property(nonatomic,strong) AxsCacheKeeperSearchDiagnostics *probe;
@end
@implementation AxsCacheKeeperSearchProbeTests
- (void)setUp {
    [super setUp];
    self.window=[[UIWindow alloc] initWithFrame:CGRectMake(0,0,390,844)];
    UIViewController *owner=[UIViewController new];
    self.root=[[AxsCacheKeeperSearchRootView alloc] initWithFrame:self.window.bounds];owner.view=self.root;
    self.window.rootViewController=owner;[self.window makeKeyAndVisible];
    self.input=[[AxsCacheKeeperSearchInput alloc] initWithFrame:CGRectMake(0,80,390,56)];[self.root addSubview:self.input];
    UITableView *table=[[UITableView alloc] initWithFrame:CGRectMake(0,160,390,500)];[self.root addSubview:table];
    self.probe=[[AxsCacheKeeperSearchDiagnostics alloc] initWithField:self.input.axs_cachekeeper_field input:self.input root:self.root table:table owner:owner];
    self.input.axs_cachekeeper_diagnostics=self.probe;self.root.axs_cachekeeper_diagnostics=self.probe;
    [self.root layoutIfNeeded];[self.input layoutIfNeeded];
}
- (void)tearDown {
    [self.probe axs_cachekeeper_freeze:AxsCacheKeeperSearchEventWillDisappear];
    [self.input axs_cachekeeper_dismiss_keyboard];self.window.hidden=YES;
    self.probe=nil;self.input=nil;self.root=nil;self.window=nil;[super tearDown];
}
- (NSDictionary *)axs_cachekeeper_last {
    return [[self.probe axs_cachekeeper_snapshot][@"events"] lastObject];
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
    [self.input axs_cachekeeper_focus];[self.input axs_cachekeeper_dismiss_keyboard];
    XCTAssertEqualObjects(snapshot,[self.probe axs_cachekeeper_snapshot]);
    [self.probe axs_cachekeeper_begin];[self.input axs_cachekeeper_focus];
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
    self.window.rootViewController=nav;[settings loadViewIfNeeded];[settings.view layoutIfNeeded];
    [settings viewWillAppear:NO];[settings viewDidAppear:NO];
    AxsCacheKeeperSearchInput *input=[settings valueForKey:@"axs_cachekeeper_searchInput"];
    XCTAssertTrue([input axs_cachekeeper_focus]);
    [settings axs_cachekeeper_diagnostics];
    AxsCacheKeeperDiagnosticsPage *page=(id)nav.topViewController;
    NSDictionary *snapshot=[page valueForKey:@"axs_cachekeeper_searchSnapshot"];
    XCTAssertEqualObjects(snapshot[@"state"],@"frozen");
    NSDictionary *last=[snapshot[@"events"] lastObject];
    XCTAssertEqualObjects(last[@"event"],@"diagnostics");XCTAssertTrue([last[@"firstResponder"] boolValue]);
    XCTAssertFalse(input.axs_cachekeeper_field.isFirstResponder);
    [settings viewDidDisappear:NO];
    AxsCacheKeeperSearchDiagnostics *probe=[settings valueForKey:@"axs_cachekeeper_searchDiagnostics"];
    XCTAssertEqual([(NSArray *)[probe axs_cachekeeper_snapshot][@"events"] count],0u);
    XCTAssertEqualObjects(snapshot,[page valueForKey:@"axs_cachekeeper_searchSnapshot"]);
    [settings viewWillAppear:NO];
    XCTAssertEqualObjects([[probe axs_cachekeeper_snapshot][@"events"] firstObject][@"event"],@"willAppear");
    [settings viewWillDisappear:NO];
}
@end
