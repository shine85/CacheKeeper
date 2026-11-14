#import <UIKit/UIKit.h>

// Own the editable responder directly, without UISearchBar's internal hit-test/delegate chain.
@interface AxsCacheKeeperSearchInput : UIView
@property(nonatomic,copy) void (^axs_cachekeeper_changed_handler)(void);
@property(nonatomic,copy) void (^axs_cachekeeper_focus_failed)(void);
@property(nonatomic,readonly,copy) NSString *axs_cachekeeper_text;
- (BOOL)axs_cachekeeper_focus;
- (void)axs_cachekeeper_dismiss_keyboard;
@end
