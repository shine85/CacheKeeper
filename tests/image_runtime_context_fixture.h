// Include after production ImageCache.m: real Runtime provider and real plist I/O;
// only the platform bundle, shared folder, UIKit symbols and identity service differ.
#import "AxsCacheKeeperInstallation.h"
#import <UIKit/UIKit.h>
static NSString *axs_cachekeeper_image_runtime_fixture_root;
NSString *axs_cachekeeper_image_runtime_fixture_folder(void) {return axs_cachekeeper_image_runtime_fixture_root;}
@interface AxsCacheKeeperImageRuntimeFixtureBundle : NSObject
+ (instancetype)mainBundle;
@property(nonatomic,readonly) NSString *bundleIdentifier;
@property(nonatomic,readonly) NSURL *bundleURL;
- (id)objectForInfoDictionaryKey:(NSString *)key;
@end
@implementation AxsCacheKeeperImageRuntimeFixtureBundle
+ (instancetype)mainBundle {static id bundle;static dispatch_once_t once;dispatch_once(&once,^{bundle=[self new];});return bundle;}
- (NSString *)bundleIdentifier {return @"cachekeeper.owned.runtime.fixture";}
- (NSURL *)bundleURL {return [NSURL fileURLWithPath:axs_cachekeeper_image_runtime_fixture_root];}
- (id)objectForInfoDictionaryKey:(NSString *)key {(void)key;return @"1";}
@end
const UIBackgroundTaskIdentifier UIBackgroundTaskInvalid=NSUIntegerMax;
NSString * const UIApplicationDidBecomeActiveNotification=@"fixture.active";
NSString * const UIApplicationDidEnterBackgroundNotification=@"fixture.background";
@implementation UIApplication
+ (instancetype)sharedApplication {return nil;}
- (NSTimeInterval)backgroundTimeRemaining {return 0;}
- (UIApplicationState)applicationState {return UIApplicationStateActive;}
- (UIBackgroundTaskIdentifier)beginBackgroundTaskWithName:(NSString *)name expirationHandler:(void (^)(void))expiration {(void)name;(void)expiration;return UIBackgroundTaskInvalid;}
- (void)endBackgroundTask:(UIBackgroundTaskIdentifier)task {(void)task;}
@end
NSDictionary *axs_cachekeeper_installation_snapshot_with_context(NSURL *url,NSString *bundle,NSString *version,AxsCacheKeeperInstallationContext kind,NSError **error) {
    (void)url;(void)bundle;(void)version;(void)kind;(void)error;axs_cachekeeper_runtime_require(NO,"disabled Runtime never rebuilds identity");return nil;
}
BOOL axs_cachekeeper_validate_installation_snapshot_with_context(NSDictionary *snapshot,NSURL *url,NSString *version,AxsCacheKeeperInstallationContext kind,NSError **error) {
    (void)snapshot;(void)url;(void)version;(void)kind;(void)error;axs_cachekeeper_runtime_require(NO,"disabled Runtime never revalidates identity");return NO;
}
NSDictionary *axs_cachekeeper_installation_image_observation(NSDictionary *snapshot,NSURL *url,NSString *version) {
    (void)snapshot;(void)url;(void)version;axs_cachekeeper_runtime_require(NO,"disabled Runtime never observes executable metadata");return nil;
}
#define NSBundle AxsCacheKeeperImageRuntimeFixtureBundle
#import "AxsCacheKeeperImageCacheRuntime.m"
#undef NSBundle
static NSDictionary *axs_cachekeeper_runtime_disabled_context(NSString *home) {
    axs_cachekeeper_image_runtime_fixture_root=[home stringByAppendingPathComponent:@"runtime-configuration"];
    axs_cachekeeper_runtime_require([NSFileManager.defaultManager createDirectoryAtPath:axs_cachekeeper_image_runtime_fixture_root withIntermediateDirectories:YES attributes:nil error:nil],"real Runtime configuration directory created");
    NSDictionary *states=@{@"cachekeeper.owned.runtime.fixture":@{@"enabled":@NO,@"mode":@"prevent"}};
    axs_cachekeeper_runtime_require([states writeToFile:[axs_cachekeeper_image_runtime_fixture_root stringByAppendingPathComponent:@"appEnabled.plist"] atomically:YES] &&
        [@{} writeToFile:[axs_cachekeeper_image_runtime_fixture_root stringByAppendingPathComponent:@"directories.plist"] atomically:YES],"real disabled Runtime inputs written");
    axs_cachekeeper_image_context_lock=[NSObject new];axs_cachekeeper_image_access=YES;
    axs_cachekeeper_image_installation=@{@"installationState":@"verified",@"fingerprint":@"stale-enabled-install"};
    NSDictionary *context=AxsCacheKeeperImageContext();
    axs_cachekeeper_runtime_require([context[@"valid"] isEqual:@YES] && [context[@"installation"] isEqual:@""] &&
        [context[@"installationCheck"][@"state"] isEqual:@"notRequested"] && !context[@"installationImage"],
        "actual Runtime returns disabled empty identity without republishing its stale cached fingerprint");
    return context;
}
