#import <UIKit/UIKit.h>
@class AxsCacheKeeperCollectionSession;
@interface AxsCacheKeeperCollectionHistoryPage : UITableViewController
- (instancetype)initWithDirectory:(NSString *)directory selection:(void (^)(AxsCacheKeeperCollectionSession *))selection create:(dispatch_block_t)create;
@end
