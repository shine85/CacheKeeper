#import <UIKit/UIKit.h>
@class AxsCacheKeeperImageCollectionSession;
@interface AxsCacheKeeperImageCollectionPage : UIViewController
- (instancetype)initWithFolder:(NSString *)folder sessionID:(NSString *)sessionID;
- (instancetype)initWithSession:(AxsCacheKeeperImageCollectionSession *)session;
@end
