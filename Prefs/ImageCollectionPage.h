#import <UIKit/UIKit.h>
@class AxsCacheKeeperImageCollectionSession;
@class AxsCacheKeeperCollectionNavigation;
@interface AxsCacheKeeperImageCollectionPage : UIViewController
- (instancetype)initWithFolder:(NSString *)folder sessionID:(NSString *)sessionID;
- (instancetype)initWithSession:(AxsCacheKeeperImageCollectionSession *)session;
@property(nonatomic,copy) NSDictionary<NSString *,NSString *> *applicationNames;
@property(nonatomic,strong) AxsCacheKeeperCollectionNavigation *collectionNavigation;
@end
