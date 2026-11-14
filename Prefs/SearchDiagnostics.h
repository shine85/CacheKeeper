#import <UIKit/UIKit.h>
#import "../AxsCacheKeeperSearchDiagnostics.h"

// Main-thread-only, owned by one CKSettings instance; all UIKit references are weak.
@interface AxsCacheKeeperSearchDiagnostics : NSObject
- (instancetype)initWithField:(UITextField *)field input:(UIView *)input root:(UIView *)root table:(UIView *)table owner:(UIViewController *)owner;
- (void)axs_cachekeeper_begin;
- (void)axs_cachekeeper_record:(AxsCacheKeeperSearchEvent)event;
- (NSDictionary *)axs_cachekeeper_freeze:(AxsCacheKeeperSearchEvent)event;
- (NSDictionary *)axs_cachekeeper_snapshot;
- (void)axs_cachekeeper_clear;
- (void)axs_cachekeeper_observe_hit:(UIView *)hit point:(CGPoint)point event:(UIEvent *)event;
@end

@interface AxsCacheKeeperSearchRootView : UIView
@property(nonatomic,weak) AxsCacheKeeperSearchDiagnostics *axs_cachekeeper_diagnostics;
@end
