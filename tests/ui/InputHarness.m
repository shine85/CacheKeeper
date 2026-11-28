#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "Preferences/PSViewController.h"
#import "../../Prefs/SearchInput.h"
#import "../../Prefs/SearchHitRouting.h"
#import "../../Prefs/DiagnosticsPage.h"
#import "../../Prefs/ImageCollectionPage.h"
#import "../../Prefs/CollectionHistoryPage.h"
#import "../../AxsCacheKeeperCollectionReturn.h"
#import "../../AxsCacheKeeperCollectionSession.h"
#import "../../AxsCacheKeeperAppList.h"
@implementation PSViewController
@end
@interface AxsCacheKeeperTestHostBarContainer : UIView
@end
@implementation AxsCacheKeeperTestHostBarContainer
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit=[super hitTest:point withEvent:event];return hit==self ? nil : hit;
}
@end
@interface CKSettings : PSViewController
- (void)axs_cachekeeper_application_active:(NSNotification *)notification;
- (void)axs_cachekeeper_render;
- (void)axs_cachekeeper_apply_pending_snapshot;
- (void)updateBatch;
@end
@interface AxsCollectionReturnHarnessRoot : CKSettings
@property(nonatomic,copy) NSString *directory;
@end
@implementation AxsCollectionReturnHarnessRoot
- (NSString *)axs_cachekeeper_collection_directory {return self.directory;}
@end
// The visual fixture drives the production controller with synthetic metadata, without device reads/writes.
@interface AxsCacheKeeperVisualSettings : CKSettings
@property(nonatomic,strong) NSDictionary *axs_cachekeeper_fixtureSnapshot;
@property(nonatomic) NSUInteger axs_cachekeeper_fixtureDeliveries;
@end
@implementation AxsCacheKeeperVisualSettings
- (void)viewDidLoad {
    [super viewDidLoad];
    NSArray *names=@[@"阿尔法笔记",@"播客",@"地图",@"读书",@"旅行",@"视频",@"网盘",@"音乐"];
    NSArray *pinyin=@[@"Alpha",@"Bo ke",@"Di tu",@"Du shu",@"Lv xing",@"Shi pin",@"Wang pan",@"Yin yue"];
    NSArray *ids=@[@"notes",@"podcasts",@"maps",@"reader",@"travel",@"video",@"drive",@"music"];
    NSMutableArray *apps=[NSMutableArray new];
    for (NSUInteger i=0;i<names.count;i++) [apps addObject:@{@"name":names[i],@"pinyin":[@"App " stringByAppendingString:pinyin[i]],
        @"id":[@"example." stringByAppendingString:ids[i]],@"source":@"user",@"version":@"1.0"}];
    self.axs_cachekeeper_fixtureSnapshot=@{@"revision":@1,@"apps":[apps copy],
        @"states":@{@"example.drive":@{@"enabled":@YES},@"example.video":@{@"enabled":@YES}},
        @"statuses":@{@"example.drive":@{@"phase":@"complete",@"coverageComplete":@YES,@"removed":@1539,@"bytes":@544232448,@"message":@"Synthetic long rule text must stay in details."},
            @"example.video":@{@"phase":@"error",@"failed":@1}},
        @"directories":@{},@"errors":@{},@"batch":@{},@"favorites":@[],@"history":@{}};
    NSDictionary *snapshot=self.axs_cachekeeper_fixtureSnapshot;
    __weak typeof(self) weak=self;
    AxsCacheKeeperAppList *source=[[AxsCacheKeeperAppList alloc] initWithProvider:^NSDictionary *(BOOL refreshApplications) {
        (void)refreshApplications;return snapshot;
    } completion:^(NSDictionary *result) {
        typeof(self) strong=weak;
        if (!strong || ![[strong valueForKey:@"axs_cachekeeper_visible"] boolValue] || UIApplication.sharedApplication.applicationState!=UIApplicationStateActive) return;
        strong.axs_cachekeeper_fixtureDeliveries++;
        [strong setValue:result forKey:@"axs_cachekeeper_pendingSnapshot"];
        [strong axs_cachekeeper_apply_pending_snapshot];
    }];
    [(AxsCacheKeeperAppList *)[self valueForKey:@"axs_cachekeeper_appList"] invalidate];
    [self setValue:source forKey:@"axs_cachekeeper_appList"];
    [self setValue:@1 forKey:@"selectedTab"];
    ((UISegmentedControl *)[self valueForKey:@"tabs"]).selectedSegmentIndex=1;
}
- (void)axs_cachekeeper_application_active:(NSNotification *)notification {
    [self setValue:self.axs_cachekeeper_fixtureSnapshot forKey:@"axs_cachekeeper_pendingSnapshot"];
    [self axs_cachekeeper_apply_pending_snapshot];
    [super axs_cachekeeper_application_active:notification];
}
@end
@interface AxsCacheKeeperTestNestedHost : UIViewController
@property(nonatomic,strong) UINavigationController *axs_cachekeeper_inner;
- (instancetype)initWithSettings:(CKSettings *)settings;
- (instancetype)initWithContent:(UIViewController *)content;
@end
@implementation AxsCacheKeeperTestNestedHost
- (instancetype)initWithSettings:(CKSettings *)settings {
    return [self initWithContent:settings];
}
- (instancetype)initWithContent:(UIViewController *)content {
    if (!(self=[super init])) return nil;
    self.title=@"缓存管家";
    self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeAlways;
    self.axs_cachekeeper_inner=[[UINavigationController alloc] initWithRootViewController:content];
    self.axs_cachekeeper_inner.navigationBarHidden=YES;
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    [self addChildViewController:self.axs_cachekeeper_inner];
    UIView *content=self.axs_cachekeeper_inner.view;content.frame=self.view.bounds;
    content.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:content];[self.axs_cachekeeper_inner didMoveToParentViewController:self];
}
@end
// A real container may forward its item after UIKit has already installed its own item.
// Keep UINavigationController and UINavigationBar untouched so the probe must verify that
// UIKit really retains the installed item before it exercises the production controller.
@interface AxsCacheKeeperTestForwardingHost : AxsCacheKeeperTestNestedHost
@property(nonatomic) BOOL axs_cachekeeper_forwardsItem;
@end
@implementation AxsCacheKeeperTestForwardingHost
- (UINavigationItem *)navigationItem {
    return self.axs_cachekeeper_forwardsItem ? self.axs_cachekeeper_inner.topViewController.navigationItem : [super navigationItem];
}
@end
@interface AxsCacheKeeperAliasedSettings : AxsCacheKeeperVisualSettings
@property(nonatomic,strong) UINavigationItem *axs_cachekeeper_aliasedItem;
@end
@implementation AxsCacheKeeperAliasedSettings
- (UINavigationItem *)navigationItem {
    return self.axs_cachekeeper_aliasedItem ?: [super navigationItem];
}
@end
static NSDictionary *axs_cachekeeper_test_region_evidence(CKSettings *settings,UINavigationBar *bar) {
    AxsCacheKeeperSearchInput *input=[settings valueForKey:@"axs_cachekeeper_searchInput"];
    UIView *root=settings.view;CGRect safe=root.safeAreaLayoutGuide.layoutFrame;
    CGRect whole=CGRectMake(safe.origin.x,safe.origin.y,safe.size.width,input.bounds.size.height);
    NSMutableArray *controls=[NSMutableArray new];
    for (NSValue *value in [input axs_cachekeeper_visible_control_rects]) {
        CGRect rect=CGRectOffset(value.CGRectValue,safe.origin.x-input.bounds.origin.x,safe.origin.y-input.bounds.origin.y);
        [controls addObject:[AxsCacheKeeperSearchHitRouting axs_cachekeeper_bar:bar owner:(id)settings inspect_rect:[root convertRect:rect toView:bar]]];
    }
    return @{@"fullInput":[AxsCacheKeeperSearchHitRouting axs_cachekeeper_bar:bar owner:(id)settings inspect_rect:[root convertRect:whole toView:bar]],@"controls":controls};
}
// Inject the observed late regrowth at touch dispatch; AX snapshots may arrive after UIKit has relaid out.
@interface AxsCacheKeeperRegrowingWindow : UIWindow
@property(nonatomic,weak) CKSettings *axs_cachekeeper_settings;
@property(nonatomic,weak) UINavigationBar *axs_cachekeeper_bar;
@property(nonatomic) NSUInteger axs_cachekeeper_armed;
@property(nonatomic) BOOL axs_cachekeeper_probing;
@property(nonatomic,strong) NSMutableDictionary *axs_cachekeeper_samples;
@property(nonatomic,strong) CADisplayLink *axs_cachekeeper_displayLink;
@property(nonatomic,strong) NSTimer *axs_cachekeeper_layoutTimer;
@property(nonatomic) CGFloat axs_cachekeeper_baselineTop;
- (void)axs_cachekeeper_start_stability;
@end
@implementation AxsCacheKeeperRegrowingWindow
- (void)axs_cachekeeper_capture_frame:(CADisplayLink *)link {
    (void)link;
    CKSettings *settings=self.axs_cachekeeper_settings;
    if (!self.axs_cachekeeper_armed || ![[settings valueForKey:@"axs_cachekeeper_appeared"] boolValue]) return;
    AxsCacheKeeperSearchInput *input=[settings valueForKey:@"axs_cachekeeper_searchInput"];
    CGFloat top=[input.axs_cachekeeper_field convertRect:input.axs_cachekeeper_field.bounds toView:self].origin.y;
    CALayer *fieldLayer=input.axs_cachekeeper_field.layer.presentationLayer;
    CALayer *windowLayer=self.layer.presentationLayer;
    BOOL presented=fieldLayer && windowLayer;
    CGFloat visualTop=presented ? [fieldLayer convertRect:fieldLayer.bounds toLayer:windowLayer].origin.y : top;
    NSString *key=[NSString stringWithFormat:@"%lu",(unsigned long)self.axs_cachekeeper_armed];
    NSMutableDictionary *sample=[self.axs_cachekeeper_samples[key] mutableCopy] ?: [NSMutableDictionary new];
    sample[@"renderSamples"]=@([sample[@"renderSamples"] unsignedIntegerValue]+1);
    CGFloat minimum=sample[@"minimumTop"] ? [sample[@"minimumTop"] doubleValue] : top;
    CGFloat maximum=sample[@"maximumTop"] ? [sample[@"maximumTop"] doubleValue] : top;
    sample[@"minimumTop"]=@(MIN(minimum,top));
    sample[@"maximumTop"]=@(MAX(maximum,top));
    CGFloat visualMinimum=sample[@"minimumVisualTop"] ? [sample[@"minimumVisualTop"] doubleValue] : visualTop;
    CGFloat visualMaximum=sample[@"maximumVisualTop"] ? [sample[@"maximumVisualTop"] doubleValue] : visualTop;
    sample[@"minimumVisualTop"]=@(MIN(visualMinimum,visualTop));
    sample[@"maximumVisualTop"]=@(MAX(visualMaximum,visualTop));
    sample[@"presentationSamples"]=@([sample[@"presentationSamples"] unsignedIntegerValue]+(presented ? 1 : 0));
    sample[@"baselineTop"]=@(self.axs_cachekeeper_baselineTop);
    self.axs_cachekeeper_samples[key]=sample;
}
- (void)axs_cachekeeper_layout_tick {
    CKSettings *settings=self.axs_cachekeeper_settings;UINavigationBar *bar=self.axs_cachekeeper_bar;
    if (!self.axs_cachekeeper_armed || ![[settings valueForKey:@"axs_cachekeeper_appeared"] boolValue]) return;
    NSString *key=[NSString stringWithFormat:@"%lu",(unsigned long)self.axs_cachekeeper_armed];
    NSMutableDictionary *sample=[self.axs_cachekeeper_samples[key] mutableCopy] ?: [NSMutableDictionary new];
    NSUInteger ticks=[sample[@"layoutTicks"] unsignedIntegerValue];
    CGFloat height=ticks%2 ? 44 : 91;
    CGRect frame=bar.frame;frame.size.height=height;bar.frame=frame;
    if (height==91 && !sample[@"firstRegionChecks"]) sample[@"firstRegionChecks"]=axs_cachekeeper_test_region_evidence(settings,bar);
    [settings.view setNeedsLayout];[settings.view layoutIfNeeded];[settings updateBatch];
    sample[@"layoutTicks"]=@(ticks+1);
    sample[@"hostGeometryPreserved"]=@(fabs(bar.bounds.size.height-height)<0.5 &&
        (!sample[@"hostGeometryPreserved"] || [sample[@"hostGeometryPreserved"] boolValue]));
    self.axs_cachekeeper_samples[key]=sample;
    [self axs_cachekeeper_capture_frame:nil];
}
- (void)axs_cachekeeper_start_stability {
    if (!self.axs_cachekeeper_samples) self.axs_cachekeeper_samples=[NSMutableDictionary new];
    AxsCacheKeeperSearchInput *input=[self.axs_cachekeeper_settings valueForKey:@"axs_cachekeeper_searchInput"];
    self.axs_cachekeeper_baselineTop=[input.axs_cachekeeper_field convertRect:input.axs_cachekeeper_field.bounds toView:self].origin.y;
    if (self.axs_cachekeeper_displayLink) return;
    self.axs_cachekeeper_displayLink=[CADisplayLink displayLinkWithTarget:self selector:@selector(axs_cachekeeper_capture_frame:)];
    [self.axs_cachekeeper_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    __weak typeof(self) weak=self;
    self.axs_cachekeeper_layoutTimer=[NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *tick) {
        (void)tick;[weak axs_cachekeeper_layout_tick];
    }];
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    CKSettings *settings=self.axs_cachekeeper_settings;UINavigationBar *bar=self.axs_cachekeeper_bar;
    if (!event || event.type!=UIEventTypeTouches || !self.axs_cachekeeper_armed || self.axs_cachekeeper_probing ||
        !settings || bar.window!=self) return [super hitTest:point withEvent:event];
    AxsCacheKeeperSearchInput *input=[settings valueForKey:@"axs_cachekeeper_searchInput"];
    UIView *target=[settings.view hitTest:[settings.view convertPoint:point fromView:self] withEvent:nil];
    if (![input axs_cachekeeper_owns_enabled_hit:target]) return [super hitTest:point withEvent:event];
    self.axs_cachekeeper_probing=YES;
    @try {
        CGFloat topBefore=[input.axs_cachekeeper_field convertRect:input.axs_cachekeeper_field.bounds toView:self].origin.y;
        CGRect frame=bar.frame;frame.size.height=91;bar.frame=frame;
        CGRect barRect=[bar convertRect:bar.bounds toView:self];
        // Test the untouched production binding first: the fixture must never repair it before the real touch.
        UIView *actual=[super hitTest:point withEvent:event];
        UIView *original=nil;
        [AxsCacheKeeperSearchHitRouting axs_cachekeeper_release_bar:bar owner:(id)settings];
        @try { original=[super hitTest:point withEvent:nil]; }
        @finally { [AxsCacheKeeperSearchHitRouting axs_cachekeeper_claim_bar:bar owner:(id)settings]; }
        CGFloat topAfter=[input.axs_cachekeeper_field convertRect:input.axs_cachekeeper_field.bounds toView:self].origin.y;
        NSString *key=[NSString stringWithFormat:@"%lu",(unsigned long)self.axs_cachekeeper_armed];
        if (!self.axs_cachekeeper_samples) self.axs_cachekeeper_samples=[NSMutableDictionary new];
        NSDictionary *previous=self.axs_cachekeeper_samples[key];
        BOOL passed=CGRectContainsPoint(barRect,point) && original==bar && actual==target && fabs(topAfter-topBefore)<0.5;
        NSMutableDictionary *sample=[previous mutableCopy] ?: [NSMutableDictionary new];
        [sample addEntriesFromDictionary:@{@"passed":@(passed && (!previous[@"passed"] || [previous[@"passed"] boolValue])),
            @"queries":@([previous[@"queries"] unsignedIntegerValue]+1),@"barHeight":@(barRect.size.height),
            @"overlap":@(CGRectContainsPoint(barRect,point)),@"originalBareBar":@(original==bar),
            @"productionHitMatchesTarget":@(actual==target),@"fieldTopBefore":@(topBefore),@"fieldTopAfter":@(topAfter),
            @"originalClass":original ? NSStringFromClass(original.class) : @"nil",
            @"actualClass":actual ? NSStringFromClass(actual.class) : @"nil",
            @"touchRegionChecks":axs_cachekeeper_test_region_evidence(settings,bar)}];
        self.axs_cachekeeper_samples[key]=sample;
        if (!previous[@"passed"]) NSLog(@"REGROWTH_TOUCH %@ %@",key,self.axs_cachekeeper_samples[key]);
        return actual;
    } @finally { self.axs_cachekeeper_probing=NO; }
}
@end
@interface AxsCacheKeeperRegrowthEvidenceLabel : UILabel
@property(nonatomic,weak) AxsCacheKeeperRegrowingWindow *axs_cachekeeper_source;
@end
@implementation AxsCacheKeeperRegrowthEvidenceLabel
- (NSString *)accessibilityLabel {
    AxsCacheKeeperRegrowingWindow *source=self.axs_cachekeeper_source;
    CKSettings *settings=source.axs_cachekeeper_settings;
    NSMutableDictionary *evidence=[source.axs_cachekeeper_samples mutableCopy] ?: [NSMutableDictionary new];
    NSNumber *entry=[settings valueForKey:@"axs_cachekeeper_searchEntry"],*settled=[settings valueForKey:@"axs_cachekeeper_searchSettledEntry"];
    evidence[@"entry"]=@{@"ready":@(entry.unsignedIntegerValue>0 && [entry isEqual:settled]),
        @"fixtureAppCount":@([[settings valueForKey:@"apps"] count]),
        @"fixtureDeliveries":[settings valueForKey:@"axs_cachekeeper_fixtureDeliveries"] ?: @0};
    NSData *json=[NSJSONSerialization dataWithJSONObject:evidence options:0 error:nil];
    return [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
}
@end
@interface AxsCacheKeeperRegrowingNavigationController : UINavigationController
@property(nonatomic) NSUInteger axs_cachekeeper_regrow_count;
- (void)axs_cachekeeper_regrow;
@end
@implementation AxsCacheKeeperRegrowingNavigationController
- (void)axs_cachekeeper_regrow {
    AxsCacheKeeperTestNestedHost *host=(id)self.topViewController;
    CKSettings *settings=(id)host.axs_cachekeeper_inner.topViewController;
    host.navigationItem.leftBarButtonItem.title=[NSString stringWithFormat:@"重现遮挡 %lu",(unsigned long)++self.axs_cachekeeper_regrow_count];
    AxsCacheKeeperRegrowingWindow *window=(id)self.view.window;
    window.axs_cachekeeper_settings=settings;window.axs_cachekeeper_bar=self.navigationBar;
    window.axs_cachekeeper_armed=self.axs_cachekeeper_regrow_count;
    [window axs_cachekeeper_start_stability];
}
@end
@interface CKScanPage : UITableViewController
@property(nonatomic,copy) NSString *bundle;
@property(nonatomic,copy) NSString *appName;
@end
@implementation CKScanPage
@end
@interface AxsCacheKeeperInputTestDelegate : UIResponder <UIApplicationDelegate,UINavigationControllerDelegate>
@property(nonatomic,strong) UIWindow *window;
@property(nonatomic,strong) UIView *axs_cachekeeper_testOverlay;
@property(nonatomic,strong) UINavigationBar *axs_cachekeeper_testHostBar;
@property(nonatomic,copy) NSString *axs_collectionDirectory;
@property(nonatomic) NSUInteger axs_collectionRebuilds;
@end
@implementation AxsCacheKeeperInputTestDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application;(void)options;
    BOOL regrown=[NSProcessInfo.processInfo.arguments containsObject:@"--search-regrown-bar"] &&
        [NSProcessInfo.processInfo.arguments containsObject:@"--compact-visual"];
    Class windowClass=regrown ? AxsCacheKeeperRegrowingWindow.class : UIWindow.class;
    self.window=[[windowClass alloc] initWithFrame:UIScreen.mainScreen.bounds];
    if([NSProcessInfo.processInfo.arguments containsObject:@"--collection-history"]){
        NSString *directory=[[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] stringByAppendingPathComponent:@"collectionSessions"];
        for(NSUInteger i=0;i<3;i++)[AxsCacheKeeperCollectionSession createNewSessionInDirectory:directory error:NULL];
        AxsCacheKeeperCollectionHistoryPage *page=[[AxsCacheKeeperCollectionHistoryPage alloc] initWithDirectory:directory selection:^(AxsCacheKeeperCollectionSession *session){(void)session;} create:^{}];
        self.window.rootViewController=[[UINavigationController alloc] initWithRootViewController:page];[self.window makeKeyAndVisible];return YES;
    }
    if([NSProcessInfo.processInfo.arguments containsObject:@"--collection-auto-return"]){
        NSString *folder=[NSTemporaryDirectory() stringByAppendingPathComponent:@"collection-return-xcui"];
        self.axs_collectionDirectory=[folder stringByAppendingPathComponent:@"collectionSessions"];
        if(![NSProcessInfo.processInfo.arguments containsObject:@"--collection-resume"]){
            NSError *error=nil;AxsCacheKeeperCollectionSession *session=[AxsCacheKeeperCollectionSession createNewSessionInDirectory:self.axs_collectionDirectory error:&error];
            [session beginPhase:@"hostPreflight" error:&error];[session finishPhase:@"hostPreflight" result:@{@"state":@"partial"} error:&error];
            [session beginPhase:@"capacity" error:&error];[session finishPhase:@"capacity" result:@{@"state":@"partial",@"epoch":@"fixture",@"finishedAt":@2,@"completedRoots":@0,@"totalRoots":@0,@"failedRoots":@0} error:&error];
            [session imageCollectionSession:&error];
            AxsCacheKeeperCollectionReturn *store=[[AxsCacheKeeperCollectionReturn alloc] initWithDirectory:self.axs_collectionDirectory];[store selectSession:session page:@"image" error:&error];
            NSAssert(!error,@"Collection fixture must persist successfully");
        }
        [self axs_collection_show_root];return YES;
    }
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--compact-visual"]) {
        AxsCacheKeeperVisualSettings *settings=[AxsCacheKeeperVisualSettings new];
        AxsCacheKeeperTestNestedHost *host=[[AxsCacheKeeperTestNestedHost alloc] initWithSettings:settings];
        UINavigationController *navigation=regrown ? [[AxsCacheKeeperRegrowingNavigationController alloc] initWithRootViewController:host] : [[UINavigationController alloc] initWithRootViewController:host];
        navigation.navigationBar.prefersLargeTitles=YES;
        [settings loadViewIfNeeded];host.navigationItem.rightBarButtonItems=settings.navigationItem.rightBarButtonItems;
        if (regrown) {
            host.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"重现遮挡" style:UIBarButtonItemStylePlain target:navigation action:@selector(axs_cachekeeper_regrow)];
            host.navigationItem.leftBarButtonItem.accessibilityIdentifier=@"CacheKeeperRegrowHost";
            navigation.navigationBar.accessibilityIdentifier=@"CacheKeeperTestRegrownBar";
            ((AxsCacheKeeperRegrowingWindow *)self.window).axs_cachekeeper_settings=settings;
            ((AxsCacheKeeperRegrowingWindow *)self.window).axs_cachekeeper_bar=navigation.navigationBar;
        }
        if ([NSProcessInfo.processInfo.arguments containsObject:@"--dark"]) self.window.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
        else self.window.overrideUserInterfaceStyle=UIUserInterfaceStyleLight;
        self.window.rootViewController=navigation;[self.window makeKeyAndVisible];
        if (regrown) {
            AxsCacheKeeperRegrowthEvidenceLabel *label=[[AxsCacheKeeperRegrowthEvidenceLabel alloc] initWithFrame:CGRectMake(8,self.window.bounds.size.height-34,self.window.bounds.size.width-16,22)];
            label.text=@"Touch dispatch evidence";label.accessibilityIdentifier=@"CacheKeeperRegrowthEvidence";
            label.axs_cachekeeper_source=(id)self.window;label.userInteractionEnabled=NO;[self.window addSubview:label];
        }
        return YES;
    }
    CKSettings *settings=[CKSettings new];
    UINavigationController *navigation=[[UINavigationController alloc] initWithRootViewController:settings];
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--search-host-navigation-bar"]) {
        navigation.navigationBarHidden=YES;
        settings.additionalSafeAreaInsets=UIEdgeInsetsMake(44,0,0,0);
    }
    navigation.delegate=self;self.window.rootViewController=navigation;
    [self.window makeKeyAndVisible];return YES;
}
- (void)navigationController:(UINavigationController *)navigation didShowViewController:(UIViewController *)controller animated:(BOOL)animated {
    (void)animated;
    if(self.axs_collectionDirectory && [controller isKindOfClass:AxsCacheKeeperImageCollectionPage.class]){
        NSDictionary *report=[[controller valueForKey:@"session"] reportProjection];
        for(UIView *view in controller.view.subviews)if([view.accessibilityIdentifier isEqual:@"CollectionReturnEvidence"])[view removeFromSuperview];
        UILabel *label=[[UILabel alloc] initWithFrame:CGRectMake(8,controller.view.bounds.size.height-36,controller.view.bounds.size.width-16,30)];
        label.accessibilityIdentifier=@"CollectionReturnEvidence";label.text=[NSString stringWithFormat:@"%@:%@:%lu",report[@"sessionID"],report[@"state"],(unsigned long)self.axs_collectionRebuilds];
        [controller.view addSubview:label];return;
    }
    if ([controller isKindOfClass:CKSettings.class] &&
        [NSProcessInfo.processInfo.arguments containsObject:@"--search-host-navigation-bar"]) {
        [navigation.view layoutIfNeeded];
        CGFloat compactBottom=[controller.view convertPoint:CGPointMake(0,controller.view.safeAreaInsets.top) toView:self.window].y;
        // Device 119.1: the reported inner bar is hidden, while another host bar occupies 91 points.
        UINavigationBar *bar=[[UINavigationBar alloc] initWithFrame:CGRectMake(0,compactBottom-44,self.window.bounds.size.width,91)];
        bar.accessibilityIdentifier=@"CacheKeeperTestHostNavigationBar";
        UINavigationItem *item=[[UINavigationItem alloc] initWithTitle:@"Host navigation"];
        item.leftBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"收起测试栏" style:UIBarButtonItemStylePlain target:self action:@selector(axs_cachekeeper_collapseHostBar)];
        item.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"诊断" style:UIBarButtonItemStylePlain target:controller action:NSSelectorFromString(@"axs_cachekeeper_diagnostics")];
        [bar setItems:@[item] animated:NO];
        UIView *wrapper=[[AxsCacheKeeperTestHostBarContainer alloc] initWithFrame:self.window.bounds];
        [wrapper addSubview:bar];[self.window addSubview:wrapper];self.axs_cachekeeper_testHostBar=bar;
        [controller.view setNeedsLayout];
    }
    if ([controller isKindOfClass:CKSettings.class] &&
        [NSProcessInfo.processInfo.arguments containsObject:@"--search-external-overlay"]) {
        AxsCacheKeeperSearchInput *input=[controller valueForKey:@"axs_cachekeeper_searchInput"];
        [navigation.view layoutIfNeeded];
        // A sibling above the content bypasses its root hitTest, as opposed to the existing inner-overlay fixture.
        UIView *overlay=[[UIView alloc] initWithFrame:[input.axs_cachekeeper_field convertRect:input.axs_cachekeeper_field.bounds toView:navigation.view]];
        overlay.backgroundColor=UIColor.clearColor;overlay.isAccessibilityElement=YES;
        overlay.accessibilityIdentifier=@"CacheKeeperTestExternalOverlay";
        overlay.accessibilityLabel=@"Search overlay ready";
        [navigation.view addSubview:overlay];self.axs_cachekeeper_testOverlay=overlay;
    }
    if (![controller isKindOfClass:AxsCacheKeeperDiagnosticsPage.class]) return;
    if (self.axs_cachekeeper_testHostBar) {
        [self.axs_cachekeeper_testHostBar.superview removeFromSuperview];self.axs_cachekeeper_testHostBar=nil;
        [navigation setNavigationBarHidden:NO animated:NO];
    }
    NSDictionary *snapshot=[controller valueForKey:@"axs_cachekeeper_searchSnapshot"];
    NSDictionary *route=[snapshot[@"events"] lastObject][@"hitRoute"];
    BOOL observed=NO;
    for (NSDictionary *event in snapshot[@"events"])
        if ([event[@"event"] isEqual:@"rootHit"] && [event[@"observedHit"] isEqual:@"field"]) observed=YES;
    // Test-only accessibility output: never shipped in the PreferenceBundle.
    NSDictionary *result=@{@"state":snapshot[@"state"] ?: NSNull.null,
        @"probeRevision":snapshot[@"probeRevision"] ?: NSNull.null,
        @"events":[snapshot[@"events"] valueForKey:@"event"] ?: @[],@"observedFieldTouch":@(observed),
        @"rootCenterHit":route[@"rootCenterHit"] ?: NSNull.null,
        @"windowHitRole":route[@"windowHit"][@"role"] ?: NSNull.null,
        @"windowHitKind":route[@"windowHit"][@"kind"] ?: NSNull.null,
        @"windowHitInsideRoot":route[@"windowHitInsideRoot"] ?: NSNull.null,
        @"windowHitInsideNavigationBar":route[@"windowHitInsideNavigationBar"] ?: NSNull.null,
        @"sameHit":route[@"sameHit"] ?: NSNull.null};
    NSData *json=[NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    UILabel *label=[[UILabel alloc] initWithFrame:CGRectMake(8,controller.view.bounds.size.height-45,controller.view.bounds.size.width-16,28)];
    label.autoresizingMask=UIViewAutoresizingFlexibleTopMargin|UIViewAutoresizingFlexibleWidth;
    label.text=@"Search routing test result";label.accessibilityIdentifier=@"CacheKeeperTestSearchRoute";
    label.accessibilityLabel=[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    [controller.view addSubview:label];
    [self.axs_cachekeeper_testOverlay removeFromSuperview];self.axs_cachekeeper_testOverlay=nil;
}
- (void)axs_cachekeeper_collapseHostBar {
    CGRect frame=self.axs_cachekeeper_testHostBar.frame;frame.size.height=44;self.axs_cachekeeper_testHostBar.frame=frame;
}
- (void)axs_collection_show_root {
    AxsCollectionReturnHarnessRoot *root=[AxsCollectionReturnHarnessRoot new];root.directory=self.axs_collectionDirectory;
    UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:root];nav.delegate=self;self.window.rootViewController=nav;[self.window makeKeyAndVisible];
}
- (void)applicationDidEnterBackground:(UIApplication *)application {
    (void)application;if(!self.axs_collectionDirectory)return;
    // Controlled reproduction of a host discarding its plugin navigation, not an OS diagnosis.
    self.window.rootViewController=nil;self.axs_collectionRebuilds++;
}
- (void)applicationWillEnterForeground:(UIApplication *)application {
    (void)application;if(self.axs_collectionDirectory)[self axs_collection_show_root];
}
@end
int main(int argc,char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(AxsCacheKeeperInputTestDelegate.class)); }
}
