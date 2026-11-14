#import <UIKit/UIKit.h>
#import "Preferences/PSViewController.h"
#import "../../Prefs/SearchInput.h"
#import "../../Prefs/DiagnosticsPage.h"
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
@end
// The visual fixture drives the production controller with synthetic metadata, without device reads/writes.
@interface AxsCacheKeeperVisualSettings : CKSettings
@end
@implementation AxsCacheKeeperVisualSettings
- (void)axs_cachekeeper_application_active:(NSNotification *)notification {
    (void)notification;
    if (![[self valueForKey:@"apps"] count]) {
        NSArray *names=@[@"阿尔法笔记",@"播客",@"地图",@"读书",@"旅行",@"视频",@"网盘",@"音乐"];
        NSArray *pinyin=@[@"Alpha",@"Bo ke",@"Di tu",@"Du shu",@"Lv xing",@"Shi pin",@"Wang pan",@"Yin yue"];
        NSArray *ids=@[@"notes",@"podcasts",@"maps",@"reader",@"travel",@"video",@"drive",@"music"];
        NSMutableArray *apps=[NSMutableArray new];
        for (NSUInteger i=0;i<names.count;i++) [apps addObject:@{@"name":names[i],@"pinyin":[@"App " stringByAppendingString:pinyin[i]],
            @"id":[@"example." stringByAppendingString:ids[i]],@"source":@"user",@"version":@"1.0"}];
        [self setValue:apps forKey:@"apps"];
        [self setValue:@{@"example.drive":@{@"enabled":@YES},@"example.video":@{@"enabled":@YES}} forKey:@"statesSnapshot"];
        [self setValue:@{@"example.drive":@{@"phase":@"complete",@"coverageComplete":@YES,@"removed":@1539,@"bytes":@544232448,@"message":@"Synthetic long rule text must stay in details."},
            @"example.video":@{@"phase":@"error",@"failed":@1}} forKey:@"statusSnapshot"];
        [self setValue:@{} forKey:@"directoriesSnapshot"];[self setValue:@{} forKey:@"sourceErrors"];
        [self setValue:@{} forKey:@"batchSnapshot"];[self setValue:nil forKey:@"appsError"];
        [self setValue:@1 forKey:@"selectedTab"];
        ((UISegmentedControl *)[self valueForKey:@"tabs"]).selectedSegmentIndex=1;
    }
    [self axs_cachekeeper_render];
}
@end
@interface AxsCacheKeeperTestNestedHost : UIViewController
@property(nonatomic,strong) UINavigationController *axs_cachekeeper_inner;
- (instancetype)initWithSettings:(CKSettings *)settings;
@end
@implementation AxsCacheKeeperTestNestedHost
- (instancetype)initWithSettings:(CKSettings *)settings {
    if (!(self=[super init])) return nil;
    self.title=@"缓存管家";
    self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeAlways;
    self.axs_cachekeeper_inner=[[UINavigationController alloc] initWithRootViewController:settings];
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
@end
@implementation AxsCacheKeeperInputTestDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application;(void)options;
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--compact-visual"]) {
        AxsCacheKeeperVisualSettings *settings=[AxsCacheKeeperVisualSettings new];
        AxsCacheKeeperTestNestedHost *host=[[AxsCacheKeeperTestNestedHost alloc] initWithSettings:settings];
        UINavigationController *navigation=[[UINavigationController alloc] initWithRootViewController:host];
        navigation.navigationBar.prefersLargeTitles=YES;
        [settings loadViewIfNeeded];host.navigationItem.rightBarButtonItems=settings.navigationItem.rightBarButtonItems;
        if ([NSProcessInfo.processInfo.arguments containsObject:@"--dark"]) self.window.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
        else self.window.overrideUserInterfaceStyle=UIUserInterfaceStyleLight;
        self.window.rootViewController=navigation;[self.window makeKeyAndVisible];return YES;
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
@end
int main(int argc,char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(AxsCacheKeeperInputTestDelegate.class)); }
}
