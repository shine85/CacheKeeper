#import <UIKit/UIKit.h>

@protocol AxsCacheKeeperSearchHitOwner <NSObject>
- (BOOL)axs_cachekeeper_search_passes_point:(CGPoint)point fromBar:(UINavigationBar *)bar;
@end

// The original UIKit route is changed only for a currently claimed instance's empty overlap.
@interface AxsCacheKeeperSearchHitRouting : NSObject
+ (void)axs_cachekeeper_claim_bar:(UINavigationBar *)bar owner:(id<AxsCacheKeeperSearchHitOwner>)owner;
+ (void)axs_cachekeeper_release_bar:(UINavigationBar *)bar owner:(id<AxsCacheKeeperSearchHitOwner>)owner;
// Layout may ignore empty overlap only while this exact instance still has our live route.
+ (BOOL)axs_cachekeeper_bar:(UINavigationBar *)bar owner:(id<AxsCacheKeeperSearchHitOwner>)owner has_empty_rect:(CGRect)rect;
// Explicit diagnostics only: fixed reasons, class names and geometry, never titles or view descriptions.
+ (NSDictionary *)axs_cachekeeper_bar:(UINavigationBar *)bar owner:(id<AxsCacheKeeperSearchHitOwner>)owner inspect_rect:(CGRect)rect;
@end
