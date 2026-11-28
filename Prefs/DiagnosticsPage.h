#import <UIKit/UIKit.h>
@class AxsCacheKeeperCollectionSession;
@interface AxsCacheKeeperDiagnosticsPage : UIViewController
- (void)presentResumableCollection;
- (instancetype)initWithCollectionSessionObject:(AxsCacheKeeperCollectionSession *)session;
- (instancetype)initWithAutomaticSession:(AxsCacheKeeperCollectionSession *)session intent:(NSDictionary *)intent;
@property(nonatomic,copy) NSDictionary<NSString *,NSString *> *applicationNames;
- (instancetype)init;
- (instancetype)initWithSearchSnapshot:(NSDictionary *)snapshot;
- (instancetype)initWithPDFBundle:(NSString *)bundle relativeDirectory:(NSString *)relative;
- (instancetype)initWithCollectionSession:(BOOL)guided;
@end
