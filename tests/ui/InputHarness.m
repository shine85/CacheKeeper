#import <UIKit/UIKit.h>
#import "Preferences/PSViewController.h"
#import "../../Prefs/SearchInput.h"
#import "../../Prefs/DiagnosticsPage.h"
@implementation PSViewController
@end
@interface CKSettings : PSViewController
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
        [bar setItems:@[[[UINavigationItem alloc] initWithTitle:@"Host navigation"]] animated:NO];
        [self.window addSubview:bar];self.axs_cachekeeper_testHostBar=bar;
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
@end
int main(int argc,char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(AxsCacheKeeperInputTestDelegate.class)); }
}
