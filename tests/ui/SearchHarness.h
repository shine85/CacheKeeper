#import <UIKit/UIKit.h>
// Test-only presentation keeps search navigation regressions independent of product features.
@interface AxsCacheKeeperSearchTestPage : UIViewController
@property(nonatomic,strong) NSDictionary *axs_cachekeeper_searchSnapshot;
@end
