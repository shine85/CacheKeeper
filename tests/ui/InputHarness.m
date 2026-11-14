#import <UIKit/UIKit.h>
#import "Preferences/PSViewController.h"
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
@interface AxsCacheKeeperInputTestDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation AxsCacheKeeperInputTestDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application;(void)options;
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController=[[UINavigationController alloc] initWithRootViewController:[CKSettings new]];
    [self.window makeKeyAndVisible];return YES;
}
@end
int main(int argc,char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(AxsCacheKeeperInputTestDelegate.class)); }
}
