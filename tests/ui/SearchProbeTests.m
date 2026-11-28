#import <XCTest/XCTest.h>
#import "../../Prefs/SearchInput.h"
#import "../../Prefs/SearchDiagnostics.h"
#import "../../Prefs/SearchNavigation.h"
#import "../../Prefs/SearchHitRouting.h"
#import "SearchHarness.h"
#import "../../AxsCacheKeeperDiagnostics.h"
#import "Preferences/PSViewController.h"

@interface CKSettings : PSViewController
- (void)axs_cachekeeper_test_snapshot;
- (void)updateBatch;
- (void)axs_cachekeeper_restore_title_claim:(NSDictionary *)claim keepingClaims:(NSArray<NSDictionary *> *)claims;
@end
@interface AxsCacheKeeperTestHostBarContainer : UIView
@end
@interface AxsCacheKeeperVisualSettings : CKSettings
@property(nonatomic) NSUInteger axs_cachekeeper_fixtureDeliveries;
@end
@interface AxsCacheKeeperTestNestedHost : UIViewController
@property(nonatomic,strong) UINavigationController *axs_cachekeeper_inner;
- (instancetype)initWithSettings:(CKSettings *)settings;
- (instancetype)initWithContent:(UIViewController *)content;
@end
@interface AxsCacheKeeperTestForwardingHost : AxsCacheKeeperTestNestedHost
@property(nonatomic) BOOL axs_cachekeeper_forwardsItem;
@end
@interface AxsCacheKeeperAliasedSettings : AxsCacheKeeperVisualSettings
@property(nonatomic,strong) UINavigationItem *axs_cachekeeper_aliasedItem;
@end
// A replacement item must be unattached: UIKit forbids installing an inner bar's item on an outer bar.
@interface AxsCacheKeeperReplacementHost : AxsCacheKeeperTestNestedHost
@property(nonatomic,strong) UINavigationItem *axs_cachekeeper_replacement;
@end
@implementation AxsCacheKeeperReplacementHost
- (UINavigationItem *)navigationItem { return self.axs_cachekeeper_replacement ?: [super navigationItem]; }
@end
@interface AxsCacheKeeperDirectHost : UIViewController
@property(nonatomic,strong) UIViewController *axs_cachekeeper_content;
@end
@implementation AxsCacheKeeperDirectHost
- (void)viewDidLoad {
    [super viewDidLoad];
    UIViewController *content=self.axs_cachekeeper_content;
    [self addChildViewController:content];content.view.frame=self.view.bounds;
    content.view.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:content.view];[content didMoveToParentViewController:self];
}
@end
@interface AxsCacheKeeperAppearanceCountedSettings : AxsCacheKeeperVisualSettings
@property(nonatomic) NSUInteger axs_cachekeeper_disappearances;
@end
@implementation AxsCacheKeeperAppearanceCountedSettings
- (void)viewWillDisappear:(BOOL)animated {
    self.axs_cachekeeper_disappearances++;
    [super viewWillDisappear:animated];
}
@end
@interface AxsCacheKeeperLayoutCountedSettings : AxsCacheKeeperVisualSettings
@property(nonatomic) NSUInteger axs_cachekeeper_layoutCallbacks;
@property(nonatomic) NSUInteger axs_cachekeeper_safeCallbacks;
@property(nonatomic) NSUInteger axs_cachekeeper_batchCalls;
@end
@implementation AxsCacheKeeperLayoutCountedSettings
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews];self.axs_cachekeeper_layoutCallbacks++; }
- (void)viewSafeAreaInsetsDidChange { [super viewSafeAreaInsetsDidChange];self.axs_cachekeeper_safeCallbacks++; }
- (void)updateBatch { [super updateBatch];self.axs_cachekeeper_batchCalls++; }
@end
// Hold an actual UIKit navigation transition; no top-controller or bar-item properties are replaced.
@interface AxsCacheKeeperHeldTransition : NSObject <UIViewControllerAnimatedTransitioning,UINavigationControllerDelegate>
@property(nonatomic,strong) id<UIViewControllerContextTransitioning> axs_cachekeeper_context;
@property(nonatomic,strong) XCTestExpectation *axs_cachekeeper_started;
@property(nonatomic,strong) XCTestExpectation *axs_cachekeeper_finished;
@property(nonatomic,weak) UIViewController *axs_cachekeeper_target;
- (void)axs_cachekeeper_finish;
@end
@implementation AxsCacheKeeperHeldTransition
- (NSTimeInterval)transitionDuration:(id<UIViewControllerContextTransitioning>)context { (void)context;return 0.25; }
- (void)animateTransition:(id<UIViewControllerContextTransitioning>)context {
    self.axs_cachekeeper_context=context;
    UIViewController *target=[context viewControllerForKey:UITransitionContextToViewControllerKey];
    UIView *view=[context viewForKey:UITransitionContextToViewKey];
    view.frame=[context finalFrameForViewController:target];[context.containerView addSubview:view];
    [self.axs_cachekeeper_started fulfill];self.axs_cachekeeper_started=nil;
}
- (id<UIViewControllerAnimatedTransitioning>)navigationController:(UINavigationController *)navigation
    animationControllerForOperation:(UINavigationControllerOperation)operation fromViewController:(UIViewController *)from toViewController:(UIViewController *)to {
    (void)navigation;(void)from;(void)to;return operation==UINavigationControllerOperationPush ? self : nil;
}
- (void)navigationController:(UINavigationController *)navigation didShowViewController:(UIViewController *)controller animated:(BOOL)animated {
    (void)navigation;(void)animated;
    if (controller==self.axs_cachekeeper_target) { [self.axs_cachekeeper_finished fulfill];self.axs_cachekeeper_finished=nil; }
}
- (void)axs_cachekeeper_finish {
    id<UIViewControllerContextTransitioning> context=self.axs_cachekeeper_context;
    [context completeTransition:YES];self.axs_cachekeeper_context=nil;
}
@end
// Contract fault injection around a real UIKit coordinator: report NO while retaining the
// real completion, and let the test observe the early queued attempt before releasing it.
@interface AxsCacheKeeperCompletionGate : NSProxy
@property(nonatomic,strong) id<UIViewControllerTransitionCoordinator> axs_cachekeeper_source;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *axs_cachekeeper_deliveries;
@property(nonatomic) NSUInteger axs_cachekeeper_requests;
@property(nonatomic) BOOL axs_cachekeeper_released;
- (instancetype)initWithCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator;
- (void)axs_cachekeeper_release_completions;
@end
@implementation AxsCacheKeeperCompletionGate
- (instancetype)initWithCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    _axs_cachekeeper_source=coordinator;_axs_cachekeeper_deliveries=[NSMutableArray new];return self;
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector { return [(NSObject *)self.axs_cachekeeper_source methodSignatureForSelector:selector]; }
- (void)forwardInvocation:(NSInvocation *)invocation { [invocation invokeWithTarget:self.axs_cachekeeper_source]; }
- (BOOL)animateAlongsideTransition:(void (^)(id<UIViewControllerTransitionCoordinatorContext>))animation completion:(void (^)(id<UIViewControllerTransitionCoordinatorContext>))completion {
    self.axs_cachekeeper_requests++;
    [self.axs_cachekeeper_source animateAlongsideTransition:animation completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        if (!completion) return;
        if (self.axs_cachekeeper_released) completion(context);
        else [self.axs_cachekeeper_deliveries addObject:@{@"completion":[completion copy],@"context":context}];
    }];
    return NO;
}
- (void)axs_cachekeeper_release_completions {
    self.axs_cachekeeper_released=YES;
    NSArray<NSDictionary *> *deliveries=[self.axs_cachekeeper_deliveries copy];
    [self.axs_cachekeeper_deliveries removeAllObjects];
    for (NSDictionary *delivery in deliveries) {
        void (^completion)(id<UIViewControllerTransitionCoordinatorContext>)=delivery[@"completion"];
        completion(delivery[@"context"]);
    }
}
@end
@interface AxsCacheKeeperCompletionGatedNavigation : UINavigationController
@property(nonatomic,strong) AxsCacheKeeperCompletionGate *axs_cachekeeper_gate;
- (id<UIViewControllerTransitionCoordinator>)axs_cachekeeper_actual_coordinator;
@end
@implementation AxsCacheKeeperCompletionGatedNavigation
- (id<UIViewControllerTransitionCoordinator>)transitionCoordinator { return (id)self.axs_cachekeeper_gate ?: [super transitionCoordinator]; }
- (id<UIViewControllerTransitionCoordinator>)axs_cachekeeper_actual_coordinator { return [super transitionCoordinator]; }
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
- (BOOL)axs_cachekeeper_wait_for_compact_entry:(CKSettings *)settings navigation:(UINavigationController *)navigation {
    NSPredicate *settled=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *bindings) {
        (void)object;(void)bindings;
        if (![[settings valueForKey:@"axs_cachekeeper_appeared"] boolValue]) return NO;
        if (![[settings valueForKey:@"axs_cachekeeper_searchEntry"] isEqual:[settings valueForKey:@"axs_cachekeeper_searchSettledEntry"]]) return NO;
        for (UIViewController *ancestor=settings;ancestor;ancestor=ancestor.parentViewController)
            if (ancestor.transitionCoordinator) return NO;
        UINavigationBar *bar=navigation.navigationBar;
        AxsCacheKeeperSearchInput *input=[settings valueForKey:@"axs_cachekeeper_searchInput"];
        CGRect safe=[settings.view convertRect:settings.view.safeAreaLayoutGuide.layoutFrame toView:self.window];
        CGRect barRect=[bar convertRect:bar.bounds toView:self.window];
        CGRect field=[input.axs_cachekeeper_field convertRect:input.axs_cachekeeper_field.bounds toView:self.window];
        CGFloat fieldInset=[input.axs_cachekeeper_field convertRect:input.axs_cachekeeper_field.bounds toView:input].origin.y;
        return bar.window==self.window && !bar.prefersLargeTitles && bar.bounds.size.height<=44.5 &&
            bar.topItem.largeTitleDisplayMode==UINavigationItemLargeTitleDisplayModeNever &&
            fabs(safe.origin.y-CGRectGetMaxY(barRect))<0.5 && fabs(field.origin.y-safe.origin.y-fieldInset)<0.5;
    }];
    XCTestExpectation *ready=[[XCTNSPredicateExpectation alloc] initWithPredicate:settled object:nil];
    XCTWaiterResult result=[XCTWaiter waitForExpectations:@[ready] timeout:5];
    XCTAssertEqual(result,XCTWaiterResultCompleted,@"The real ancestor transition and compact safe area must settle before recording a baseline; safe=%@ bar=%@",NSStringFromCGRect(settings.view.safeAreaLayoutGuide.layoutFrame),NSStringFromCGRect(navigation.navigationBar.frame));
    return result==XCTWaiterResultCompleted;
}
- (UINavigationController *)axs_cachekeeper_present_host:(AxsCacheKeeperTestNestedHost *)host {
    UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:host];
    nav.navigationBar.prefersLargeTitles=YES;nav.modalPresentationStyle=UIModalPresentationFullScreen;
    XCTestExpectation *shown=[self expectationWithDescription:@"Real nested host appeared"];
    [self.owner presentViewController:nav animated:NO completion:^{ [shown fulfill]; }];
    [self waitForExpectations:@[shown] timeout:10];
    [self axs_cachekeeper_wait_for_compact_entry:(CKSettings *)host.axs_cachekeeper_inner.topViewController navigation:nav];
    return nav;
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
        nav.navigationBar.prefersLargeTitles=YES;
        [settings updateBatch];
        XCTAssertEqual(host.navigationItem.largeTitleDisplayMode,UINavigationItemLargeTitleDisplayModeAlways);
        XCTAssertTrue(nav.navigationBar.prefersLargeTitles,@"An explicit host mode change must survive refresh");
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
- (void)testEditingVisibilityPublishesSettledControlGeometryBeforeParentLayout {
    AxsCacheKeeperVisualSettings *settings=[AxsCacheKeeperVisualSettings new];
    AxsCacheKeeperTestNestedHost *host=[[AxsCacheKeeperTestNestedHost alloc] initWithSettings:settings];
    UINavigationController *nav=[self axs_cachekeeper_present_host:host];
    AxsCacheKeeperSearchInput *input=[settings valueForKey:@"axs_cachekeeper_searchInput"];
    UINavigationBar *bar=nav.navigationBar;
    CGRect frame=bar.frame;frame.size.height=91;bar.frame=frame;
    [settings updateBatch];
    CGFloat top=[input convertRect:input.bounds toView:self.window].origin.y;
    CGFloat idleWidth=input.axs_cachekeeper_field.bounds.size.width;
    // Exercise the synchronous delegate boundary before any run-loop/keyboard wait can
    // conceal the hidden arranged view's stale zero-width frame.
    id<UITextFieldDelegate> delegate=input.axs_cachekeeper_field.delegate;
    for (NSUInteger cycle=0;cycle<3;cycle++) {
        [delegate textFieldDidBeginEditing:input.axs_cachekeeper_field];
        XCTAssertEqual([input axs_cachekeeper_visible_control_rects].count,2u,@"SEARCH_EDITING_GEOMETRY: visible controls must already have valid frames");
        XCTAssertLessThan(input.axs_cachekeeper_field.bounds.size.width,idleWidth,@"SEARCH_EDITING_GEOMETRY: field must already leave room for cancel");
        [settings updateBatch];
        XCTAssertEqualWithAccuracy([input convertRect:input.bounds toView:self.window].origin.y,top,0.5,@"SEARCH_EDITING_GEOMETRY: focus changes must not move search vertically");
        [delegate textFieldDidEndEditing:input.axs_cachekeeper_field];
        XCTAssertEqual([input axs_cachekeeper_visible_control_rects].count,1u,@"SEARCH_EDITING_GEOMETRY: hidden cancel must leave the control set");
        XCTAssertEqualWithAccuracy(input.axs_cachekeeper_field.bounds.size.width,idleWidth,0.5,@"SEARCH_EDITING_GEOMETRY: ending editing must restore field width synchronously");
        [settings updateBatch];
        XCTAssertEqualWithAccuracy([input convertRect:input.bounds toView:self.window].origin.y,top,0.5,@"SEARCH_EDITING_GEOMETRY: focus changes must not move search vertically");
    }
}
- (void)testClaimedCompactBarRegrowthDoesNotCoverEditableSearchControls {
    AxsCacheKeeperVisualSettings *settings=[AxsCacheKeeperVisualSettings new];
    AxsCacheKeeperTestNestedHost *host=[[AxsCacheKeeperTestNestedHost alloc] initWithSettings:settings];
    UINavigationController *nav=[self axs_cachekeeper_present_host:host];
    AxsCacheKeeperSearchInput *input=[settings valueForKey:@"axs_cachekeeper_searchInput"];
    UINavigationBar *bar=nav.navigationBar;
    XCTAssertFalse(bar.prefersLargeTitles);
    XCTAssertEqual(bar.topItem.largeTitleDisplayMode,UINavigationItemLargeTitleDisplayModeNever);
    CGFloat originalTop=[input convertRect:input.bounds toView:self.window].origin.y;
    // Reproduce 144.1: the host restores a 91pt frame between our layout pass and the tap,
    // while its compact flags and the field's safe area remain unchanged.
    CGRect frame=bar.frame;frame.size.height=91;bar.frame=frame;
    CGPoint center=[input.axs_cachekeeper_field convertPoint:CGPointMake(CGRectGetMidX(input.axs_cachekeeper_field.bounds),18) toView:self.window];
    XCTAssertTrue(CGRectContainsPoint([bar convertRect:bar.bounds toView:self.window],center));
    // In the same valid fixture, removing only the new claim binding must restore the old failure.
    [AxsCacheKeeperSearchHitRouting axs_cachekeeper_release_bar:bar owner:(id)settings];
    XCTAssertEqual([self.window hitTest:center withEvent:nil],bar,@"Negative control must reproduce the original blank-bar interception");
    CGRect searchRect=[input convertRect:input.bounds toView:bar];
    XCTAssertFalse([AxsCacheKeeperSearchHitRouting axs_cachekeeper_bar:bar owner:(id)settings has_empty_rect:searchRect],@"Ownership alone must not authorize layout without the installed route binding");
    [AxsCacheKeeperSearchHitRouting axs_cachekeeper_claim_bar:bar owner:(id)settings];
    NSDictionary *whole=[AxsCacheKeeperSearchHitRouting axs_cachekeeper_bar:bar owner:(id)settings inspect_rect:searchRect];
    NSLog(@"SEARCH_REGROWTH_FULL_INPUT %@",whole);
    NSArray<NSValue *> *controls=[input axs_cachekeeper_visible_control_rects];
    XCTAssertGreaterThan(controls.count,0u);
    for (NSValue *value in controls) {
        CGRect control=[input convertRect:value.CGRectValue toView:bar];
        NSDictionary *check=[AxsCacheKeeperSearchHitRouting axs_cachekeeper_bar:bar owner:(id)settings inspect_rect:control];
        XCTAssertTrue([AxsCacheKeeperSearchHitRouting axs_cachekeeper_bar:bar owner:(id)settings has_empty_rect:control],@"Native control region=%@, whole input=%@",check,whole);
    }
    XCTAssertFalse([AxsCacheKeeperSearchHitRouting axs_cachekeeper_bar:bar owner:(id)host has_empty_rect:searchRect]);
    UIView *hit=[self.window hitTest:center withEvent:nil];
    XCTAssertTrue(hit==input.axs_cachekeeper_field || [hit isDescendantOfView:input.axs_cachekeeper_field],@"Regrown compact host must not swallow the real field's touches");
    XCTAssertEqualWithAccuracy([input convertRect:input.bounds toView:self.window].origin.y,originalTop,0.5);
    input.axs_cachekeeper_field.enabled=NO;
    hit=[self.window hitTest:center withEvent:nil];
    XCTAssertTrue(hit==bar || [hit isDescendantOfView:bar],@"A disabled field must not take the host's route");
    input.axs_cachekeeper_field.enabled=YES;
    UIControl *hostControl=[[UIControl alloc] initWithFrame:[input.axs_cachekeeper_field convertRect:input.axs_cachekeeper_field.bounds toView:bar]];
    [bar addSubview:hostControl];
    XCTAssertEqual([self.window hitTest:center withEvent:nil],hostControl,@"Host controls always retain their original route, even inside the overlap");
    [hostControl removeFromSuperview];
    UINavigationBar *unclaimed=[[UINavigationBar alloc] initWithFrame:[bar convertRect:bar.bounds toView:self.window]];
    [self.window addSubview:unclaimed];
    hit=[self.window hitTest:center withEvent:nil];
    XCTAssertTrue(hit==unclaimed || [hit isDescendantOfView:unclaimed],@"Installing a route for one bar must not change unrelated bars");
    [unclaimed removeFromSuperview];
    [self axs_cachekeeper_focus:input];[input layoutIfNeeded];
    UIButton *cancel=[input valueForKey:@"axs_cachekeeper_cancel_button"];
    frame=bar.frame;frame.size.height=91;bar.frame=frame;
    CGPoint cancelCenter=[cancel convertPoint:CGPointMake(CGRectGetMidX(cancel.bounds),CGRectGetMidY(cancel.bounds)) toView:self.window];
    XCTAssertTrue(CGRectContainsPoint([bar convertRect:bar.bounds toView:self.window],cancelCenter));
    hit=[self.window hitTest:cancelCenter withEvent:nil];
    XCTAssertTrue(hit==cancel || [hit isDescendantOfView:cancel],@"Cancel must receive its native touch too");
    // Explicit host expansion has no compact claim and must keep its own hit route.
    [self axs_cachekeeper_dismiss:input];
    host.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeAlways;
    bar.prefersLargeTitles=YES;
    frame=bar.frame;frame.size.height=91;bar.frame=frame;
    hit=[self.window hitTest:center withEvent:nil];
    XCTAssertTrue(hit==bar || [hit isDescendantOfView:bar]);
}
- (void)testHostLargeTitleResetReconcilesExistingClaim {
    // The same-item early return used to ignore a host reset after a successful claim.
    // Exercise the production refresh and UIKit layout, including an originally compact host.
    for (NSNumber *previousPrefers in @[@YES,@NO]) {
        AxsCacheKeeperVisualSettings *settings=[AxsCacheKeeperVisualSettings new];
        AxsCacheKeeperTestNestedHost *host=[[AxsCacheKeeperTestNestedHost alloc] initWithSettings:settings];
        host.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeAutomatic;
        UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:host];
        nav.navigationBar.prefersLargeTitles=previousPrefers.boolValue;
        nav.modalPresentationStyle=UIModalPresentationFullScreen;
        XCTestExpectation *shown=[self expectationWithDescription:@"Host reset fixture appeared"];
        [self.owner presentViewController:nav animated:NO completion:^{ [shown fulfill]; }];
        [self waitForExpectations:@[shown] timeout:10];
        if (![self axs_cachekeeper_wait_for_compact_entry:settings navigation:nav]) return;
        AxsCacheKeeperSearchInput *input=[settings valueForKey:@"axs_cachekeeper_searchInput"];
        UITextField *field=input.axs_cachekeeper_field;
        XCTAssertEqual(host.navigationItem.largeTitleDisplayMode,UINavigationItemLargeTitleDisplayModeNever);
        XCTAssertFalse(nav.navigationBar.prefersLargeTitles);
        CGFloat compactHeight=nav.navigationBar.bounds.size.height;
        CGFloat compactTop=[field convertRect:field.bounds toView:self.window].origin.y;
        CGFloat pixel=1.0/self.window.screen.scale;
        for (NSUInteger reset=0;reset<3;reset++) {
            nav.navigationBar.prefersLargeTitles=YES;
            [settings updateBatch];
            for (NSUInteger layout=0;layout<3;layout++) {
                [nav.view setNeedsLayout];[nav.view layoutIfNeeded];
                [settings.view setNeedsLayout];[settings.view layoutIfNeeded];
                [settings updateBatch];
                XCTAssertFalse(nav.navigationBar.prefersLargeTitles,@"A current claim must reconcile the host reset");
                XCTAssertEqual(host.navigationItem.largeTitleDisplayMode,UINavigationItemLargeTitleDisplayModeNever);
                XCTAssertEqualWithAccuracy(nav.navigationBar.bounds.size.height,compactHeight,pixel);
                CGRect rect=[field convertRect:field.bounds toView:self.window];
                CGRect bar=[nav.navigationBar convertRect:nav.navigationBar.bounds toView:self.window];
                XCTAssertGreaterThanOrEqual(CGRectGetMinY(rect),CGRectGetMaxY(bar));
                XCTAssertEqualWithAccuracy(rect.origin.y,compactTop,pixel);
                UIView *hit=[self.window hitTest:CGPointMake(CGRectGetMidX(rect),CGRectGetMidY(rect)) withEvent:nil];
                XCTAssertTrue(hit==field || [hit isDescendantOfView:field]);
            }
        }
        UIViewController *detail=[UIViewController new];
        host.axs_cachekeeper_inner.delegate=self;
        self.expectedNavigation=host.axs_cachekeeper_inner;self.expectedController=detail;
        XCTestExpectation *pushed=[self expectationWithDescription:@"Host reset fixture left the list"];
        self.navigationFinished=pushed;
        [host.axs_cachekeeper_inner pushViewController:detail animated:NO];
        [self waitForExpectations:@[pushed] timeout:10];
        [settings updateBatch];
        XCTAssertEqual(host.navigationItem.largeTitleDisplayMode,UINavigationItemLargeTitleDisplayModeAutomatic);
        XCTAssertEqual(nav.navigationBar.prefersLargeTitles,previousPrefers.boolValue,@"Repeated resets must not replace the saved original value");
        XCTestExpectation *dismissed=[self expectationWithDescription:@"Host reset fixture dismissed"];
        [self.owner dismissViewControllerAnimated:NO completion:^{ [dismissed fulfill]; }];
        [self waitForExpectations:@[dismissed] timeout:10];
    }
}
- (void)testForwardedWrapperItemKeepsInstalledBarCompactAndRestoresItsOriginalState {
    // Rejecting the installed bar item merely because the wrapper now forwards another item
    // releases the existing claim and moves the search. All navigation state here is UIKit's.
    AxsCacheKeeperVisualSettings *settings=[AxsCacheKeeperVisualSettings new];
    AxsCacheKeeperTestForwardingHost *host=[[AxsCacheKeeperTestForwardingHost alloc] initWithSettings:settings];
    UINavigationItem *installedItem=host.navigationItem;
    installedItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeAlways;
    UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:host];
    nav.navigationBar.prefersLargeTitles=YES;nav.modalPresentationStyle=UIModalPresentationFullScreen;
    XCTestExpectation *shown=[self expectationWithDescription:@"Forwarding wrapper appeared with its original item installed"];
    [self.owner presentViewController:nav animated:NO completion:^{ [shown fulfill]; }];
    [self waitForExpectations:@[shown] timeout:10];
    if (![self axs_cachekeeper_wait_for_compact_entry:settings navigation:nav]) return;
    XCTAssertEqual(nav.topViewController,host);
    XCTAssertEqual(nav.navigationBar.topItem,installedItem);
    XCTAssertEqual(host.navigationItem,installedItem);
    AxsCacheKeeperSearchInput *input=[settings valueForKey:@"axs_cachekeeper_searchInput"];
    UITextField *field=input.axs_cachekeeper_field;
    CGRect initialFieldRect=[field convertRect:field.bounds toView:self.window];
    BOOL initialClaimValid=installedItem.largeTitleDisplayMode==UINavigationItemLargeTitleDisplayModeNever &&
        !nav.navigationBar.prefersLargeTitles && nav.navigationBar.bounds.size.height<=44.5 &&
        field.window==self.window && !CGRectIsEmpty(initialFieldRect) && !CGRectIsNull(initialFieldRect) &&
        isfinite(initialFieldRect.origin.x) && isfinite(initialFieldRect.origin.y) &&
        isfinite(initialFieldRect.size.width) && isfinite(initialFieldRect.size.height);
    XCTAssertTrue(initialClaimValid,@"FIXTURE INVALID: initial compact claim and attached search geometry were not established");
    if (!initialClaimValid) return;
    CGFloat compactTop=initialFieldRect.origin.y;
    CGFloat pixel=1.0/self.window.screen.scale;
    UINavigationItem *contentItem=settings.navigationItem;
    UINavigationItemLargeTitleDisplayMode contentMode=contentItem.largeTitleDisplayMode;
    host.axs_cachekeeper_forwardsItem=YES;
    BOOL fixtureValid=nav.topViewController==host && nav.navigationBar.topItem==installedItem &&
        host.navigationItem==contentItem && installedItem!=contentItem;
    XCTAssertTrue(fixtureValid,@"FIXTURE INVALID: UIKit synchronized the forwarded item; no installed-item mismatch was established");
    if (!fixtureValid) return;
    for (NSUInteger refresh=0;refresh<3;refresh++) {
        [settings updateBatch];[nav.view layoutIfNeeded];[settings.view layoutIfNeeded];
        if (nav.navigationBar.topItem!=installedItem) {
            XCTFail(@"FIXTURE INVALID: UIKit replaced the installed item during refresh; do not treat this as the requested RED");
            return;
        }
        XCTAssertEqual(installedItem.largeTitleDisplayMode,UINavigationItemLargeTitleDisplayModeNever,
            @"The actual visible bar item must retain the compact claim after wrapper forwarding");
        XCTAssertFalse(nav.navigationBar.prefersLargeTitles,@"The visible bar must stay compact when the wrapper getter changes");
        XCTAssertLessThanOrEqual(nav.navigationBar.bounds.size.height,44.5);
        CGRect rect=[field convertRect:field.bounds toView:self.window];
        CGRect bar=[nav.navigationBar convertRect:nav.navigationBar.bounds toView:self.window];
        XCTAssertGreaterThanOrEqual(CGRectGetMinY(rect),CGRectGetMaxY(bar));
        XCTAssertEqualWithAccuracy(CGRectGetMinY(rect),compactTop,pixel,@"Forwarding must not move the search down after appearance");
        UIView *hit=[self.window hitTest:CGPointMake(CGRectGetMidX(rect),CGRectGetMidY(rect)) withEvent:nil];
        XCTAssertTrue(hit==field || [hit isDescendantOfView:field]);
        XCTAssertEqual(contentItem.largeTitleDisplayMode,contentMode);
    }
    AxsCacheKeeperSearchDiagnostics *probe=input.axs_cachekeeper_diagnostics;
    [probe axs_cachekeeper_record:AxsCacheKeeperSearchEventDidAppear];
    NSDictionary *snapshot=[probe axs_cachekeeper_snapshot];
    NSDictionary *last=[snapshot[@"events"] lastObject];NSDictionary *ownership=nil;
    for (NSDictionary *bar in last[@"bars"]) if ([bar[@"role"] isEqual:@"ancestor"]) ownership=bar[@"ownership"];
    XCTAssertNotNil(ownership);
    XCTAssertEqualObjects(ownership[@"topIsDirectChild"],@YES);
    XCTAssertEqualObjects(ownership[@"topItemIsChildItem"],@NO);
    XCTAssertEqualObjects(ownership[@"candidateEligible"],@YES);
    XCTAssertEqualObjects(ownership[@"claimActive"],@YES);
    XCTAssertEqualObjects(ownership[@"reason"],@"eligible");
    XCTAssertEqualObjects(last[@"layout"][@"appeared"],@YES);
    AxsCacheKeeperDiagnostics *session=[[AxsCacheKeeperDiagnostics alloc] initWithFolder:NSTemporaryDirectory()];
    XCTAssertEqualObjects([session reportWithApps:@[] environment:@{@"searchUI":snapshot}][@"searchUI"],snapshot);
    [self axs_cachekeeper_focus:input];[self axs_cachekeeper_dismiss:input];
    UIViewController *detail=[UIViewController new];
    host.axs_cachekeeper_inner.delegate=self;
    self.expectedNavigation=host.axs_cachekeeper_inner;self.expectedController=detail;
    XCTestExpectation *pushed=[self expectationWithDescription:@"Forwarding wrapper left the settings page"];
    self.navigationFinished=pushed;
    [host.axs_cachekeeper_inner pushViewController:detail animated:NO];
    [self waitForExpectations:@[pushed] timeout:10];
    XCTAssertEqual(installedItem.largeTitleDisplayMode,UINavigationItemLargeTitleDisplayModeAlways,
        @"Release must restore the exact installed item, even when the getter now returns the detail item");
    XCTAssertTrue(nav.navigationBar.prefersLargeTitles);
    XCTAssertEqual(contentItem.largeTitleDisplayMode,contentMode);
}
- (void)testAliasedNavigationItemIsNotChangedBeforeAppearanceAndRestoresOriginalMode {
    // A load-time write through a forwarded getter loses the host's original mode before claiming it.
    AxsCacheKeeperDirectHost *host=[AxsCacheKeeperDirectHost new];
    UINavigationItem *item=host.navigationItem;item.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeAlways;
    AxsCacheKeeperAliasedSettings *settings=[AxsCacheKeeperAliasedSettings new];settings.axs_cachekeeper_aliasedItem=item;
    [settings loadViewIfNeeded];
    XCTAssertEqual(item.largeTitleDisplayMode,UINavigationItemLargeTitleDisplayModeAlways,@"Loading an aliased page must not modify an unclaimed host item");
    host.axs_cachekeeper_content=settings;
    UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:host];
    nav.navigationBar.prefersLargeTitles=YES;nav.modalPresentationStyle=UIModalPresentationFullScreen;
    XCTestExpectation *shown=[self expectationWithDescription:@"Aliased direct child appeared"];
    [self.owner presentViewController:nav animated:NO completion:^{[shown fulfill];}];
    [self waitForExpectations:@[shown] timeout:10];[settings updateBatch];
    XCTAssertEqual(nav.navigationBar.topItem,item);XCTAssertEqual(settings.navigationItem,item);
    XCTAssertEqual(item.largeTitleDisplayMode,UINavigationItemLargeTitleDisplayModeNever);XCTAssertFalse(nav.navigationBar.prefersLargeTitles);
    UIViewController *detail=[UIViewController new];nav.delegate=self;
    self.expectedNavigation=nav;self.expectedController=detail;
    XCTestExpectation *pushed=[self expectationWithDescription:@"Aliased settings left the visible stack"];
    self.navigationFinished=pushed;[nav pushViewController:detail animated:NO];
    [self waitForExpectations:@[pushed] timeout:10];
    XCTAssertEqual(item.largeTitleDisplayMode,UINavigationItemLargeTitleDisplayModeAlways);XCTAssertTrue(nav.navigationBar.prefersLargeTitles);
}
- (void)testActualTopItemReplacementRetainsTheSameBarsOriginalPreference {
    // A new item on an already-claimed bar must not save the temporarily forced NO as its origin.
    AxsCacheKeeperAppearanceCountedSettings *settings=[AxsCacheKeeperAppearanceCountedSettings new];
    AxsCacheKeeperReplacementHost *host=[[AxsCacheKeeperReplacementHost alloc] initWithSettings:settings];
    UINavigationItem *itemA=host.navigationItem;UINavigationItem *itemB=[[UINavigationItem alloc] initWithTitle:@"Replacement"];
    itemB.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeAutomatic;
    UINavigationController *nav=[self axs_cachekeeper_present_host:host];[settings updateBatch];
    UINavigationBar *bar=nav.navigationBar;
    BOOL initialClaim=bar.topItem==itemA && itemA!=itemB && itemA.largeTitleDisplayMode==UINavigationItemLargeTitleDisplayModeNever && !bar.prefersLargeTitles;
    XCTAssertTrue(initialClaim,@"FIXTURE INVALID: item A must first hold the visible bar's compact claim");
    if (!initialClaim) return;
    host.axs_cachekeeper_replacement=itemB;
    // UIKit rebuilds the real stack while keeping the same top controller on screen.
    // No navigation-bar item array or read-only navigation property is replaced by the fixture.
    [nav setViewControllers:@[[UIViewController new],host] animated:NO];
    BOOL replaced=nav.topViewController==host && nav.navigationBar==bar && bar.topItem==itemB &&
        settings.axs_cachekeeper_disappearances==0 && settings.view.window==self.window;
    XCTAssertTrue(replaced,@"FIXTURE INVALID: UIKit must replace A with B on the same bar without releasing the visible page");
    if (!replaced) return;
    [settings updateBatch];
    XCTAssertEqual(itemA.largeTitleDisplayMode,UINavigationItemLargeTitleDisplayModeAlways);
    XCTAssertEqual(itemB.largeTitleDisplayMode,UINavigationItemLargeTitleDisplayModeNever);XCTAssertFalse(bar.prefersLargeTitles);
    UIViewController *detail=[UIViewController new];host.axs_cachekeeper_inner.delegate=self;
    self.expectedNavigation=host.axs_cachekeeper_inner;self.expectedController=detail;
    XCTestExpectation *pushed=[self expectationWithDescription:@"Replacement item released after leaving the settings page"];
    self.navigationFinished=pushed;[host.axs_cachekeeper_inner pushViewController:detail animated:NO];
    [self waitForExpectations:@[pushed] timeout:10];
    XCTAssertEqual(itemA.largeTitleDisplayMode,UINavigationItemLargeTitleDisplayModeAlways);
    XCTAssertEqual(itemB.largeTitleDisplayMode,UINavigationItemLargeTitleDisplayModeAutomatic);
    XCTAssertTrue(bar.prefersLargeTitles,@"Replacing an item must retain the bar's original YES until the last claim releases it");
}
- (void)testItemTransferReleasesOnlyResourcesAbsentFromTheNewClaim {
    // Exercise the production release boundary without violating UIKit's one-bar-per-item rule.
    CKSettings *settings=[CKSettings new];
    UINavigationItem *item=[UINavigationItem new];item.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;
    UINavigationBar *outer=[UINavigationBar new],*inner=[UINavigationBar new];
    outer.prefersLargeTitles=NO;inner.prefersLargeTitles=NO;
    NSDictionary *old=@{@"item":item,@"bar":outer,@"previousMode":@(UINavigationItemLargeTitleDisplayModeAlways),@"previousPrefersLargeTitles":@YES};
    NSDictionary *current=@{@"item":item,@"bar":inner,@"previousMode":@(UINavigationItemLargeTitleDisplayModeAlways),@"previousPrefersLargeTitles":@NO};
    [settings axs_cachekeeper_restore_title_claim:old keepingClaims:@[current]];
    XCTAssertEqual(item.largeTitleDisplayMode,UINavigationItemLargeTitleDisplayModeNever);
    XCTAssertTrue(outer.prefersLargeTitles);XCTAssertFalse(inner.prefersLargeTitles);
    [settings axs_cachekeeper_restore_title_claim:current keepingClaims:@[]];
    XCTAssertEqual(item.largeTitleDisplayMode,UINavigationItemLargeTitleDisplayModeAlways);
    XCTAssertFalse(inner.prefersLargeTitles);
}
- (void)testHostExplicitLargeTitlePreferenceSurvivesAnOriginallyCompactBar {
    AxsCacheKeeperVisualSettings *settings=[AxsCacheKeeperVisualSettings new];
    AxsCacheKeeperTestNestedHost *host=[[AxsCacheKeeperTestNestedHost alloc] initWithSettings:settings];
    UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:host];
    nav.navigationBar.prefersLargeTitles=NO;nav.modalPresentationStyle=UIModalPresentationFullScreen;
    XCTestExpectation *shown=[self expectationWithDescription:@"Originally compact host appeared"];
    [self.owner presentViewController:nav animated:NO completion:^{[shown fulfill];}];
    [self waitForExpectations:@[shown] timeout:10];[settings updateBatch];
    BOOL claimed=host.navigationItem.largeTitleDisplayMode==UINavigationItemLargeTitleDisplayModeNever && !nav.navigationBar.prefersLargeTitles;
    XCTAssertTrue(claimed,@"FIXTURE INVALID: original NO preference must be captured before the host override");
    if (!claimed) return;
    host.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeAlways;
    nav.navigationBar.prefersLargeTitles=YES;
    for (NSUInteger refresh=0;refresh<3;refresh++) {
        [settings updateBatch];
        XCTAssertEqual(host.navigationItem.largeTitleDisplayMode,UINavigationItemLargeTitleDisplayModeAlways);
        XCTAssertTrue(nav.navigationBar.prefersLargeTitles,@"An explicit host YES must not be overwritten with the original NO");
    }
    UIViewController *detail=[UIViewController new];host.axs_cachekeeper_inner.delegate=self;
    self.expectedNavigation=host.axs_cachekeeper_inner;self.expectedController=detail;
    XCTestExpectation *pushed=[self expectationWithDescription:@"Host override survived leaving the settings page"];
    self.navigationFinished=pushed;[host.axs_cachekeeper_inner pushViewController:detail animated:NO];
    [self waitForExpectations:@[pushed] timeout:10];
    XCTAssertEqual(host.navigationItem.largeTitleDisplayMode,UINavigationItemLargeTitleDisplayModeAlways);
    XCTAssertTrue(nav.navigationBar.prefersLargeTitles);
}
- (void)testHostModeOnlyAlwaysOverrideReleasesTheForcedBarPreference {
    AxsCacheKeeperVisualSettings *settings=[AxsCacheKeeperVisualSettings new];
    AxsCacheKeeperTestNestedHost *host=[[AxsCacheKeeperTestNestedHost alloc] initWithSettings:settings];
    UINavigationController *nav=[self axs_cachekeeper_present_host:host];[settings updateBatch];
    BOOL claimed=host.navigationItem.largeTitleDisplayMode==UINavigationItemLargeTitleDisplayModeNever && !nav.navigationBar.prefersLargeTitles;
    XCTAssertTrue(claimed,@"FIXTURE INVALID: the host override must start from a compact claim");
    if (!claimed) return;
    host.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeAlways;
    XCTAssertFalse(nav.navigationBar.prefersLargeTitles,@"This control changes only the host item mode");
    for (NSUInteger refresh=0;refresh<3;refresh++) {
        [settings updateBatch];
        XCTAssertEqual(host.navigationItem.largeTitleDisplayMode,UINavigationItemLargeTitleDisplayModeAlways);
        XCTAssertTrue(nav.navigationBar.prefersLargeTitles,@"Our stale NO must not keep suppressing the host's explicit Always mode");
    }
}
- (void)testInnerTopMismatchStopsBeforeAnOtherwiseMatchingOuterHost {
    // Continuing past an off-top inner page would authorize the still-matching outer wrapper.
    AxsCacheKeeperVisualSettings *settings=[AxsCacheKeeperVisualSettings new];
    AxsCacheKeeperTestNestedHost *host=[[AxsCacheKeeperTestNestedHost alloc] initWithSettings:settings];
    UINavigationController *nav=[self axs_cachekeeper_present_host:host];
    UIViewController *detail=[UIViewController new];host.axs_cachekeeper_inner.delegate=self;
    self.expectedNavigation=host.axs_cachekeeper_inner;self.expectedController=detail;
    XCTestExpectation *pushed=[self expectationWithDescription:@"Inner detail became the real top controller"];
    self.navigationFinished=pushed;[host.axs_cachekeeper_inner pushViewController:detail animated:NO];
    [self waitForExpectations:@[pushed] timeout:10];
    XCTAssertEqual(nav.topViewController,host);XCTAssertEqual(host.axs_cachekeeper_inner.topViewController,detail);
    NSArray *states=[(id<AxsCacheKeeperSearchNavigationOwner>)settings axs_cachekeeper_search_navigation_states];
    XCTAssertEqualObjects(states.firstObject[@"ownership"][@"reason"],@"branchMismatch");
    XCTAssertEqualObjects(states.firstObject[@"ownership"][@"candidateEligible"],@NO);
    XCTAssertFalse([[states valueForKey:@"bar"] containsObject:nav.navigationBar],@"The shared ownership boundary must stop at the first stack mismatch");
    [settings updateBatch];
    XCTAssertEqual(host.navigationItem.largeTitleDisplayMode,UINavigationItemLargeTitleDisplayModeAlways);XCTAssertTrue(nav.navigationBar.prefersLargeTitles);
}
- (void)testHostAlwaysBarKeepsItsGeometryWhileSearchClearsItBeforeInteractionReturns {
    // Forcing every candidate shrinks an explicit Always bar; using hit testing alone ignores
    // that same visible bar while UIKit disables interaction, then moves the search on enable.
    AxsCacheKeeperVisualSettings *settings=[AxsCacheKeeperVisualSettings new];
    AxsCacheKeeperTestNestedHost *host=[[AxsCacheKeeperTestNestedHost alloc] initWithSettings:settings];
    UINavigationController *nav=[self axs_cachekeeper_present_host:host];[settings updateBatch];
    UINavigationBar *bar=nav.navigationBar;
    host.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeAlways;bar.prefersLargeTitles=YES;
    // As with the existing stale-frame regression, change geometry without a content layout.
    CGRect frame=bar.frame;frame.size.height=91;bar.frame=frame;bar.userInteractionEnabled=NO;
    AxsCacheKeeperSearchInput *input=[settings valueForKey:@"axs_cachekeeper_searchInput"];UITextField *field=input.axs_cachekeeper_field;
    CGRect barRect=[bar convertRect:bar.bounds toView:self.window];
    CGFloat safeTop=[settings.view convertPoint:CGPointMake(0,CGRectGetMinY(settings.view.safeAreaLayoutGuide.layoutFrame)) toView:self.window].y;
    BOOL overlaps=CGRectGetMaxY(barRect)>safeTop+1;
    XCTAssertTrue(overlaps,@"FIXTURE INVALID: visible host bar must extend beyond the content safe edge");
    if (!overlaps) return;
    [settings updateBatch];
    CGFloat disabledTop=[field convertRect:field.bounds toView:self.window].origin.y;
    XCTAssertEqual(host.navigationItem.largeTitleDisplayMode,UINavigationItemLargeTitleDisplayModeAlways);XCTAssertTrue(bar.prefersLargeTitles);
    XCTAssertEqualWithAccuracy(bar.bounds.size.height,91,0.5,@"An explicit host mode must not be forced to a compact fitting size");
    XCTAssertGreaterThanOrEqual(disabledTop,CGRectGetMaxY(barRect));
    bar.userInteractionEnabled=YES;[settings updateBatch];
    CGRect rect=[field convertRect:field.bounds toView:self.window];
    XCTAssertEqualWithAccuracy(rect.origin.y,disabledTop,1.0/self.window.screen.scale);
    UIView *hit=[self.window hitTest:CGPointMake(CGRectGetMidX(rect),CGRectGetMidY(rect)) withEvent:nil];
    XCTAssertTrue(hit==field || [hit isDescendantOfView:field]);
}
- (void)testUnfinishedNavigationDoesNotAcquireAForwardedInstalledItem {
    UIViewController *initial=[UIViewController new];
    UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:initial];
    nav.navigationBar.prefersLargeTitles=YES;nav.modalPresentationStyle=UIModalPresentationFullScreen;
    XCTestExpectation *shown=[self expectationWithDescription:@"Transition fixture navigation appeared"];
    [self.owner presentViewController:nav animated:NO completion:^{ [shown fulfill]; }];[self waitForExpectations:@[shown] timeout:10];
    AxsCacheKeeperVisualSettings *settings=[AxsCacheKeeperVisualSettings new];
    AxsCacheKeeperReplacementHost *host=[[AxsCacheKeeperReplacementHost alloc] initWithSettings:settings];
    [host loadViewIfNeeded];
    UINavigationItem *installedItem=host.navigationItem;
    AxsCacheKeeperHeldTransition *transition=[AxsCacheKeeperHeldTransition new];
    XCTestExpectation *started=[self expectationWithDescription:@"UIKit navigation transition is held before completion"];
    XCTestExpectation *finished=[self expectationWithDescription:@"UIKit completed the held navigation transition"];
    transition.axs_cachekeeper_started=started;transition.axs_cachekeeper_finished=finished;transition.axs_cachekeeper_target=host;nav.delegate=transition;
    [nav pushViewController:host animated:YES];[self waitForExpectations:@[started] timeout:10];
    host.axs_cachekeeper_replacement=[[UINavigationItem alloc] initWithTitle:@"Forwarded after installation"];
    BOOL fixtureValid=nav.topViewController==host && nav.navigationBar.topItem==installedItem &&
        host.navigationItem!=installedItem && installedItem!=settings.navigationItem && nav.transitionCoordinator!=nil &&
        settings.parentViewController==host.axs_cachekeeper_inner && host.axs_cachekeeper_inner.parentViewController==host && settings.view.window==self.window;
    XCTAssertTrue(fixtureValid,@"FIXTURE INVALID: UIKit must retain the installed item during a real unfinished transition");
    if (fixtureValid) {
        [settings updateBatch];
        XCTAssertEqual(installedItem.largeTitleDisplayMode,UINavigationItemLargeTitleDisplayModeAlways);
        XCTAssertTrue(nav.navigationBar.prefersLargeTitles);
        NSArray *states=[(id<AxsCacheKeeperSearchNavigationOwner>)settings axs_cachekeeper_search_navigation_states];
        NSDictionary *ownership=[states lastObject][@"ownership"];
        XCTAssertEqualObjects(ownership[@"transitioning"],@YES);XCTAssertEqualObjects(ownership[@"candidateEligible"],@NO);
    }
    [transition axs_cachekeeper_finish];[self waitForExpectations:@[finished] timeout:10];
    if (!fixtureValid) return;
    XCTNSPredicateExpectation *settled=[[XCTNSPredicateExpectation alloc] initWithPredicate:[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *bindings) {
        (void)object;(void)bindings;return nav.transitionCoordinator==nil && settings.transitionCoordinator==nil;
    }] object:nil];
    [self waitForExpectations:@[settled] timeout:5];
    [settings updateBatch];
    XCTAssertEqual(nav.navigationBar.topItem.largeTitleDisplayMode,UINavigationItemLargeTitleDisplayModeNever);XCTAssertFalse(nav.navigationBar.prefersLargeTitles);
}
- (void)testEntryCompletionSurvivesNoAnimationQueuedAndAnEarlierAttempt {
    UIViewController *initial=[UIViewController new];
    AxsCacheKeeperCompletionGatedNavigation *nav=[[AxsCacheKeeperCompletionGatedNavigation alloc] initWithRootViewController:initial];
    nav.navigationBar.prefersLargeTitles=YES;nav.modalPresentationStyle=UIModalPresentationFullScreen;
    XCTestExpectation *shown=[self expectationWithDescription:@"Entry completion fixture navigation appeared"];
    [self.owner presentViewController:nav animated:NO completion:^{ [shown fulfill]; }];
    [self waitForExpectations:@[shown] timeout:10];
    AxsCacheKeeperVisualSettings *settings=[AxsCacheKeeperVisualSettings new];
    AxsCacheKeeperTestNestedHost *host=[[AxsCacheKeeperTestNestedHost alloc] initWithSettings:settings];
    AxsCacheKeeperHeldTransition *transition=[AxsCacheKeeperHeldTransition new];
    XCTestExpectation *started=[self expectationWithDescription:@"A real UIKit navigation transition is held"];
    XCTestExpectation *finished=[self expectationWithDescription:@"UIKit delivered the real transition's didShow"];
    transition.axs_cachekeeper_started=started;transition.axs_cachekeeper_finished=finished;transition.axs_cachekeeper_target=host;nav.delegate=transition;
    [nav pushViewController:host animated:YES];[self waitForExpectations:@[started] timeout:10];
    id<UIViewControllerTransitionCoordinator> coordinator=[nav axs_cachekeeper_actual_coordinator];
    XCTAssertNotNil(coordinator);
    AxsCacheKeeperCompletionGate *gate=[[AxsCacheKeeperCompletionGate alloc] initWithCoordinator:coordinator];nav.axs_cachekeeper_gate=gate;
    [transition axs_cachekeeper_finish];[self waitForExpectations:@[finished] timeout:10];
    XCTestExpectation *delivered=[self expectationForPredicate:[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *bindings) {
        (void)object;(void)bindings;return gate.axs_cachekeeper_deliveries.count>0 && [nav axs_cachekeeper_actual_coordinator]==nil;
    }] evaluatedWithObject:nav handler:nil];
    [self waitForExpectations:@[delivered] timeout:5];
    // The controlled gate retains only the exposed pending-completion boundary. It does not
    // replace UIKit's views, stack, frame, transition context, or actual completion delivery.
    XCTestExpectation *early=[self expectationWithDescription:@"The first production queued attempt has run"];
    dispatch_async(dispatch_get_main_queue(),^{ [early fulfill]; });
    [self waitForExpectations:@[early] timeout:5];
    XCTAssertGreaterThan(gate.axs_cachekeeper_requests,0u);
    XCTAssertTrue([[settings valueForKey:@"axs_cachekeeper_appeared"] boolValue]);
    XCTAssertNotEqualObjects([settings valueForKey:@"axs_cachekeeper_searchEntry"],[settings valueForKey:@"axs_cachekeeper_searchSettledEntry"],@"An early attempt must not mark an exposed pending transition complete");
    nav.axs_cachekeeper_gate=nil;
    [gate axs_cachekeeper_release_completions];
    XCTAssertTrue([self axs_cachekeeper_wait_for_compact_entry:settings navigation:nav],@"The genuine completion must be able to schedule the final entry layout after an earlier blocked attempt");
}
- (void)testLayoutAndBatchKeepClaimedBlankRegrowthStableWithoutForcingHostGeometry {
    // Reintroducing either forced sizeToFit or blank-bar geometry avoidance breaks this test.
    AxsCacheKeeperLayoutCountedSettings *settings=[AxsCacheKeeperLayoutCountedSettings new];
    AxsCacheKeeperTestNestedHost *host=[[AxsCacheKeeperTestNestedHost alloc] initWithSettings:settings];
    host.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeAutomatic;
    UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:host];
    nav.navigationBar.prefersLargeTitles=YES;nav.modalPresentationStyle=UIModalPresentationFullScreen;
    XCTestExpectation *shown=[self expectationWithDescription:@"Nested navigation appeared"];
    [self.owner presentViewController:nav animated:NO completion:^{ [shown fulfill]; }];
    [self waitForExpectations:@[shown] timeout:10];
    if (![self axs_cachekeeper_wait_for_compact_entry:settings navigation:nav]) return;
    AxsCacheKeeperSearchInput *input=[settings valueForKey:@"axs_cachekeeper_searchInput"];
    [settings updateBatch];
    XCTAssertEqual(host.navigationItem.largeTitleDisplayMode,UINavigationItemLargeTitleDisplayModeNever);
    XCTAssertLessThanOrEqual(nav.navigationBar.bounds.size.height,44.5);
    CGFloat originalTop=[input.axs_cachekeeper_field convertRect:input.axs_cachekeeper_field.bounds toView:self.window].origin.y;
    NSUInteger layouts=settings.axs_cachekeeper_layoutCallbacks,safes=settings.axs_cachekeeper_safeCallbacks;
    NSUInteger batches=settings.axs_cachekeeper_batchCalls;
    NSTimer *timer=[NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *tick) {
        (void)tick;[settings updateBatch];
    }];
    @try {
        for (NSUInteger cycle=0;cycle<3;cycle++) {
            CGFloat extra=cycle==1 ? 3 : 0;
            settings.additionalSafeAreaInsets=UIEdgeInsetsMake(extra,0,0,0);
            [settings.view setNeedsLayout];[settings.view layoutIfNeeded];
            CGRect frame=nav.navigationBar.frame;frame.size.height=91;nav.navigationBar.frame=frame;
            CGFloat top=[input.axs_cachekeeper_field convertRect:input.axs_cachekeeper_field.bounds toView:self.window].origin.y;
            XCTAssertEqualWithAccuracy(top,originalTop+extra,0.5);
            for (NSNumber *interactive in @[@YES,@NO,@YES]) {
                nav.navigationBar.userInteractionEnabled=interactive.boolValue;
                [settings.view setNeedsLayout];[settings.view layoutIfNeeded];
                [settings updateBatch];
                XCTAssertEqualWithAccuracy(nav.navigationBar.bounds.size.height,91,0.5,@"Refresh must not force the host's frame");
                XCTAssertEqualWithAccuracy([input.axs_cachekeeper_field convertRect:input.axs_cachekeeper_field.bounds toView:self.window].origin.y,top,0.5,@"Blank regrowth and temporary interaction suppression must not move search");
            }
            XCTestExpectation *elapsed=[self expectationWithDescription:@"A real one-second refresh elapsed"];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.05*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[elapsed fulfill];});
            [self waitForExpectations:@[elapsed] timeout:3];
            CGRect rect=[input.axs_cachekeeper_field convertRect:input.axs_cachekeeper_field.bounds toView:self.window];
            XCTAssertEqualWithAccuracy(rect.origin.y,top,0.5);
            UIView *hit=[self.window hitTest:CGPointMake(CGRectGetMidX(rect),CGRectGetMidY(rect)) withEvent:nil];
            XCTAssertTrue([input axs_cachekeeper_owns_enabled_hit:hit]);
            frame=nav.navigationBar.frame;frame.size.height=44;nav.navigationBar.frame=frame;
            [settings.view setNeedsLayout];[settings.view layoutIfNeeded];[settings updateBatch];
            XCTAssertEqualWithAccuracy([input.axs_cachekeeper_field convertRect:input.axs_cachekeeper_field.bounds toView:self.window].origin.y,top,0.5);
        }
    } @finally { [timer invalidate]; }
    XCTAssertGreaterThan(settings.axs_cachekeeper_layoutCallbacks,layouts);
    XCTAssertGreaterThan(settings.axs_cachekeeper_safeCallbacks,safes);
    XCTAssertGreaterThanOrEqual(settings.axs_cachekeeper_batchCalls-batches,15u);
    XCTestExpectation *dismissed=[self expectationWithDescription:@"Nested navigation dismissed"];
    [self.owner dismissViewControllerAnimated:NO completion:^{ [dismissed fulfill]; }];
    [self waitForExpectations:@[dismissed] timeout:10];
}
- (void)testClaimedBarStillAvoidsRealControlsAndReturnsWhenTheyLeave {
    AxsCacheKeeperVisualSettings *settings=[AxsCacheKeeperVisualSettings new];
    AxsCacheKeeperTestNestedHost *host=[[AxsCacheKeeperTestNestedHost alloc] initWithSettings:settings];
    UINavigationController *nav=[self axs_cachekeeper_present_host:host];[settings updateBatch];
    AxsCacheKeeperSearchInput *input=[settings valueForKey:@"axs_cachekeeper_searchInput"];
    CGFloat top=[input.axs_cachekeeper_field convertRect:input.axs_cachekeeper_field.bounds toView:self.window].origin.y;
    UINavigationBar *bar=nav.navigationBar;
    CGRect frame=bar.frame;frame.size.height=91;bar.frame=frame;
    CGRect fieldRect=[input.axs_cachekeeper_field convertRect:input.axs_cachekeeper_field.bounds toView:bar];
    // An off-centre control must be found; checking only the field midpoint would miss it.
    UILabel *title=[UILabel new];title.text=@"Visible title";title.userInteractionEnabled=NO;
    UIImageView *icon=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"star"]];icon.userInteractionEnabled=NO;
    for (UIView *content in @[[UIControl new],title,icon]) {
        content.frame=CGRectMake(fieldRect.origin.x+7,fieldRect.origin.y+3,6,6);[bar addSubview:content];
        for (NSNumber *interactive in @[@YES,@NO,@YES]) {
            bar.userInteractionEnabled=interactive.boolValue;
            [settings.view setNeedsLayout];[settings.view layoutIfNeeded];[settings updateBatch];
            CGFloat moved=[input.axs_cachekeeper_field convertRect:input.axs_cachekeeper_field.bounds toView:self.window].origin.y;
            XCTAssertGreaterThan(moved,top+40);
            XCTAssertGreaterThanOrEqual(moved,CGRectGetMaxY([bar convertRect:bar.bounds toView:self.window]));
        }
        [content removeFromSuperview];
        for (NSUInteger pass=0;pass<3;pass++) {
            [settings.view setNeedsLayout];[settings.view layoutIfNeeded];[settings updateBatch];
            XCTAssertEqualWithAccuracy([input.axs_cachekeeper_field convertRect:input.axs_cachekeeper_field.bounds toView:self.window].origin.y,top,0.5,@"Avoidance must return to the same safe baseline without oscillating");
        }
    }
}
- (void)testPaddingContentDoesNotMoveNativeControlsButControlContentStillDoes {
    AxsCacheKeeperVisualSettings *settings=[AxsCacheKeeperVisualSettings new];
    AxsCacheKeeperTestNestedHost *host=[[AxsCacheKeeperTestNestedHost alloc] initWithSettings:settings];
    UINavigationController *nav=[self axs_cachekeeper_present_host:host];
    AxsCacheKeeperSearchInput *input=[settings valueForKey:@"axs_cachekeeper_searchInput"];
    [self axs_cachekeeper_focus:input];[input layoutIfNeeded];
    CGFloat top=[input.axs_cachekeeper_field convertRect:input.axs_cachekeeper_field.bounds toView:self.window].origin.y;
    NSArray<NSValue *> *controls=[input axs_cachekeeper_visible_control_rects];
    XCTAssertEqual(controls.count,2u,@"Both the native field (including clear) and cancel must reserve space");
    UINavigationBar *bar=nav.navigationBar;
    CGRect frame=bar.frame;frame.size.height=91;bar.frame=frame;
    CGRect whole=[input convertRect:input.bounds toView:bar];
    UILabel *label=[UILabel new];label.text=@"Host content";label.userInteractionEnabled=NO;
    UIImageView *image=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"star"]];image.userInteractionEnabled=NO;
    for (UIView *content in @[[UIControl new],label,image]) {
        // The side margin has no native editable target. Its host content must keep its route.
        content.frame=CGRectMake(whole.origin.x+2,whole.origin.y+6,6,6);[bar addSubview:content];
        XCTAssertFalse([AxsCacheKeeperSearchHitRouting axs_cachekeeper_bar:bar owner:(id)settings has_empty_rect:whole],@"The former whole-input check rejects this padding content: %@",[AxsCacheKeeperSearchHitRouting axs_cachekeeper_bar:bar owner:(id)settings inspect_rect:whole]);
        for (NSValue *value in controls) {
            CGRect control=[input convertRect:value.CGRectValue toView:bar];
            XCTAssertTrue([AxsCacheKeeperSearchHitRouting axs_cachekeeper_bar:bar owner:(id)settings has_empty_rect:control],@"Actual native control must remain clear: %@",[AxsCacheKeeperSearchHitRouting axs_cachekeeper_bar:bar owner:(id)settings inspect_rect:control]);
        }
        if ([content isKindOfClass:UIControl.class]) {
            CGPoint point=[content convertPoint:CGPointMake(3,3) toView:self.window];
            XCTAssertEqual([self.window hitTest:point withEvent:nil],content);
        }
        [settings updateBatch];
        XCTAssertEqualWithAccuracy([input.axs_cachekeeper_field convertRect:input.axs_cachekeeper_field.bounds toView:self.window].origin.y,top,0.5);
        for (NSValue *value in controls) {
            CGRect control=[input convertRect:value.CGRectValue toView:bar];
            content.frame=CGRectMake(control.origin.x+7,control.origin.y+3,6,6);
            for (NSNumber *interactive in @[@YES,@NO,@YES]) {
                bar.userInteractionEnabled=interactive.boolValue;
                [settings.view setNeedsLayout];[settings.view layoutIfNeeded];[settings updateBatch];
                CGFloat moved=[input.axs_cachekeeper_field convertRect:input.axs_cachekeeper_field.bounds toView:self.window].origin.y;
                XCTAssertGreaterThan(moved,top+40);
                XCTAssertGreaterThanOrEqual(moved,CGRectGetMaxY([bar convertRect:bar.bounds toView:self.window]));
            }
            content.frame=CGRectMake(whole.origin.x+2,whole.origin.y+6,6,6);
            [settings updateBatch];
            XCTAssertEqualWithAccuracy([input.axs_cachekeeper_field convertRect:input.axs_cachekeeper_field.bounds toView:self.window].origin.y,top,0.5);
        }
        [content removeFromSuperview];
    }
    [self axs_cachekeeper_dismiss:input];
}
- (void)testVisualFixtureKeepsItsApplicationsAcrossRealBatchRefreshes {
    AxsCacheKeeperVisualSettings *settings=[AxsCacheKeeperVisualSettings new];
    AxsCacheKeeperTestNestedHost *host=[[AxsCacheKeeperTestNestedHost alloc] initWithSettings:settings];
    [self axs_cachekeeper_present_host:host];
    NSArray *expected=@[@"example.notes",@"example.podcasts",@"example.maps",@"example.reader",@"example.travel",@"example.video",@"example.drive",@"example.music"];
    for (NSUInteger pass=0;pass<3;pass++) {
        NSUInteger before=settings.axs_cachekeeper_fixtureDeliveries;
        [settings setValue:@0 forKey:@"axs_cachekeeper_lastApplicationsRefresh"];
        [settings updateBatch];
        XCTestExpectation *delivered=[self expectationForPredicate:[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *bindings) {
            (void)object;(void)bindings;return settings.axs_cachekeeper_fixtureDeliveries>before;
        }] evaluatedWithObject:settings handler:nil];
        [self waitForExpectations:@[delivered] timeout:5];
        XCTAssertEqualObjects([[settings valueForKey:@"apps"] valueForKey:@"id"],expected);
        XCTAssertEqualObjects([settings valueForKey:@"sourceErrors"],@{});
    }
    AxsCacheKeeperSearchInput *input=[settings valueForKey:@"axs_cachekeeper_searchInput"];
    input.axs_cachekeeper_field.text=@"drive";[input.axs_cachekeeper_field sendActionsForControlEvents:UIControlEventEditingChanged];
    NSArray *filtered=[settings valueForKeyPath:@"sections.@unionOfArrays.apps"];
    XCTAssertEqualObjects([filtered valueForKey:@"id"],(@[@"example.drive"]));
    input.axs_cachekeeper_field.text=@"";[input.axs_cachekeeper_field sendActionsForControlEvents:UIControlEventEditingChanged];
    XCTAssertEqual([[settings valueForKeyPath:@"sections.@unionOfArrays.apps"] count],8u);
}
- (void)testRealHostNavigationLayoutFollowsItsSafeAreaWithoutTickCompetition {
    AxsCacheKeeperLayoutCountedSettings *settings=[AxsCacheKeeperLayoutCountedSettings new];
    AxsCacheKeeperTestNestedHost *host=[[AxsCacheKeeperTestNestedHost alloc] initWithSettings:settings];
    UINavigationController *nav=[self axs_cachekeeper_present_host:host];[settings updateBatch];
    [nav.view layoutIfNeeded];[settings.view layoutIfNeeded];
    AxsCacheKeeperSearchInput *input=[settings valueForKey:@"axs_cachekeeper_searchInput"];
    CGFloat (^safeTop)(void)=^CGFloat {
        return [settings.view convertPoint:CGPointMake(0,CGRectGetMinY(settings.view.safeAreaLayoutGuide.layoutFrame)) toView:self.window].y;
    };
    CGFloat compactSafe=safeTop();
    CGFloat compactTop=[input.axs_cachekeeper_field convertRect:input.axs_cachekeeper_field.bounds toView:self.window].origin.y;
    NSUInteger safes=settings.axs_cachekeeper_safeCallbacks;
    // Let UIKit derive the real bar and safe-area geometry; this fixture never writes a frame.
    host.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeAlways;
    nav.navigationBar.prefersLargeTitles=YES;
    [nav.view setNeedsLayout];[nav.view layoutIfNeeded];[settings.view layoutIfNeeded];[settings updateBatch];
    CGFloat expandedSafe=safeTop();
    XCTAssertGreaterThan(expandedSafe,compactSafe+40,@"FIXTURE INVALID: UIKit must actually grow the host safe area");
    XCTAssertGreaterThan(settings.axs_cachekeeper_safeCallbacks,safes);
    CGFloat expandedTop=[input.axs_cachekeeper_field convertRect:input.axs_cachekeeper_field.bounds toView:self.window].origin.y;
    XCTAssertGreaterThan(expandedTop,compactTop+40);
    for (NSUInteger pass=0;pass<3;pass++) {
        [settings updateBatch];
        XCTAssertEqualWithAccuracy([input.axs_cachekeeper_field convertRect:input.axs_cachekeeper_field.bounds toView:self.window].origin.y,expandedTop,0.5);
        XCTAssertGreaterThanOrEqual(expandedTop,CGRectGetMaxY([nav.navigationBar convertRect:nav.navigationBar.bounds toView:self.window]));
    }
    host.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;
    nav.navigationBar.prefersLargeTitles=NO;
    [nav.view setNeedsLayout];[nav.view layoutIfNeeded];[settings.view layoutIfNeeded];[settings updateBatch];
    XCTAssertEqualWithAccuracy(safeTop(),compactSafe,0.5);
    XCTAssertEqualWithAccuracy([input.axs_cachekeeper_field convertRect:input.axs_cachekeeper_field.bounds toView:self.window].origin.y,compactTop,0.5);
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
- (void)testCompletedLayoutRecordsInputMovementBeforeTheNextBatchTick {
    AxsCacheKeeperLayoutCountedSettings *settings=[AxsCacheKeeperLayoutCountedSettings new];
    AxsCacheKeeperTestNestedHost *host=[[AxsCacheKeeperTestNestedHost alloc] initWithSettings:settings];
    UINavigationController *nav=[self axs_cachekeeper_present_host:host];[settings updateBatch];
    [nav.view layoutIfNeeded];[settings.view layoutIfNeeded];
    AxsCacheKeeperSearchDiagnostics *probe=[settings valueForKey:@"axs_cachekeeper_searchDiagnostics"];
    [probe axs_cachekeeper_clear];[probe axs_cachekeeper_begin];
    NSUInteger batches=settings.axs_cachekeeper_batchCalls;
    settings.additionalSafeAreaInsets=UIEdgeInsetsMake(7,0,0,0);
    [settings.view setNeedsLayout];[settings.view layoutIfNeeded];
    NSArray *events=[probe axs_cachekeeper_snapshot][@"events"];
    XCTAssertEqual(settings.axs_cachekeeper_batchCalls,batches);
    XCTAssertEqualObjects([events lastObject][@"event"],@"sampled",@"A completed layout must be observed without waiting for updateBatch");
    AxsCacheKeeperSearchInput *input=[settings valueForKey:@"axs_cachekeeper_searchInput"];
    CGFloat top=[input convertRect:input.bounds toView:self.window].origin.y;
    XCTAssertEqualWithAccuracy([[events lastObject][@"input"][@"windowRect"][@"y"] doubleValue],top,0.5);
    NSUInteger count=events.count;
    for (NSUInteger pass=0;pass<4;pass++) { [settings.view setNeedsLayout];[settings.view layoutIfNeeded]; }
    XCTAssertEqual([(NSArray *)[probe axs_cachekeeper_snapshot][@"events"] count],count);
}
- (void)testChangingLayoutSamplesDoNotEvictInteractionEvidence {
    [self.probe axs_cachekeeper_record:AxsCacheKeeperSearchEventRootHit];
    [self.probe axs_cachekeeper_record:AxsCacheKeeperSearchEventShouldBegin];
    [self.probe axs_cachekeeper_record:AxsCacheKeeperSearchEventDidBegin];
    for (NSUInteger pass=0;pass<24;pass++) {
        CGRect frame=self.input.frame;frame.origin.y+=1;self.input.frame=frame;
        [self.probe axs_cachekeeper_sample];
    }
    NSArray *events=[self.probe axs_cachekeeper_snapshot][@"events"];
    XCTAssertEqual(events.count,16u);
    XCTAssertTrue([[events valueForKey:@"event"] containsObject:@"rootHit"]);
    XCTAssertTrue([[events valueForKey:@"event"] containsObject:@"shouldBegin"]);
    XCTAssertTrue([[events valueForKey:@"event"] containsObject:@"didBegin"]);
    [self.probe axs_cachekeeper_clear];[self.probe axs_cachekeeper_begin];
    for (NSUInteger pass=0;pass<16;pass++) [self.probe axs_cachekeeper_record:AxsCacheKeeperSearchEventDidBegin];
    [self.probe axs_cachekeeper_sample];
    XCTAssertFalse([[[self.probe axs_cachekeeper_snapshot][@"events"] valueForKey:@"event"] containsObject:@"sampled"]);
    XCTAssertTrue([[self.probe axs_cachekeeper_snapshot][@"truncated"] boolValue]);
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
    XCTAssertTrue([[self.probe axs_cachekeeper_snapshot][@"truncated"] boolValue]);
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
    self.navigationFinished=pushed;self.expectedControllerClass=AxsCacheKeeperSearchTestPage.class;
    [settings axs_cachekeeper_test_snapshot];
    AxsCacheKeeperSearchTestPage *page=(id)nav.topViewController;
    NSDictionary *snapshot=[page valueForKey:@"axs_cachekeeper_searchSnapshot"];
    XCTAssertEqualObjects(snapshot[@"state"],@"frozen");
    NSDictionary *last=[snapshot[@"events"] lastObject];
    XCTAssertEqualObjects(last[@"event"],@"diagnostics");XCTAssertTrue([last[@"firstResponder"] boolValue]);
    XCTAssertFalse(input.axs_cachekeeper_field.isFirstResponder);
    [self waitForExpectations:@[pushed,editing,keyboard] timeout:10];self.activeInput=nil;
    XCTAssertEqualObjects(snapshot,[probe axs_cachekeeper_snapshot]);
    XCTAssertEqualObjects(snapshot,[page valueForKey:@"axs_cachekeeper_searchSnapshot"]);
    XCTestExpectation *popped=[self expectationWithDescription:@"UIKit completed Settings return"];
    self.navigationFinished=popped;self.expectedControllerClass=CKSettings.class;
    [nav popViewControllerAnimated:YES];[self waitForExpectations:@[popped] timeout:10];
    XCTAssertTrue([[[probe axs_cachekeeper_snapshot][@"events"] valueForKey:@"event"] containsObject:@"didBegin"],@"Returning from a page must preserve the preceding search attempt for export");
    XCTAssertEqualObjects([[probe axs_cachekeeper_snapshot][@"events"] lastObject][@"event"],@"didAppear");
}
- (void)testProductNavigationKeepsAppDetailsAndReturnsToRootWithoutCollection {
    CKSettings *settings=[CKSettings new];
    UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:settings];
    nav.delegate=self;nav.modalPresentationStyle=UIModalPresentationFullScreen;
    XCTestExpectation *visible=[self expectationWithDescription:@"production root displayed"];
    [self.owner presentViewController:nav animated:NO completion:^{[visible fulfill];}];
    [self waitForExpectations:@[visible] timeout:10];
    XCTAssertEqual(settings.navigationItem.rightBarButtonItems.count,1u);
    XCTAssertEqualObjects(settings.navigationItem.rightBarButtonItems.firstObject.title,@"检测全部");
    NSDictionary *app=@{@"id":@"test.simplified.navigation",@"name":@"测试 APP"};
    [settings setValue:@[@{@"apps":@[app]}] forKey:@"sections"];
    UITableView *table=[settings valueForKey:@"table"];
    XCTestExpectation *pushed=[self expectationWithDescription:@"real app row opens details"];
    self.navigationFinished=pushed;self.expectedControllerClass=NSClassFromString(@"CKScanPage");
    [(id<UITableViewDelegate>)settings tableView:table didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
    [self waitForExpectations:@[pushed] timeout:10];
    XCTAssertEqualObjects([nav.topViewController valueForKey:@"bundle"],app[@"id"]);
    XCTAssertEqualObjects([nav.topViewController valueForKey:@"appName"],app[@"name"]);
    XCTestExpectation *popped=[self expectationWithDescription:@"details return to ordinary root"];
    self.navigationFinished=popped;self.expectedControllerClass=CKSettings.class;
    [nav popViewControllerAnimated:YES];[self waitForExpectations:@[popped] timeout:10];
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];
    XCTestExpectation *settled=[self expectationWithDescription:@"foreground callbacks settled"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{[settled fulfill];});
    [self waitForExpectations:@[settled] timeout:5];
    XCTAssertEqual(nav.topViewController,settings);
    XCTAssertEqual(nav.viewControllers.count,1u);
    XCTAssertEqual(settings.navigationItem.rightBarButtonItems.count,1u);
}
@end
