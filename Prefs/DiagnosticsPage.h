#import <UIKit/UIKit.h>
@interface AxsCacheKeeperDiagnosticsPage : UIViewController
- (void)presentResumableCollection;
@property(nonatomic,copy) NSDictionary<NSString *,NSString *> *applicationNames;
- (instancetype)init;
- (instancetype)initWithSearchSnapshot:(NSDictionary *)snapshot;
- (instancetype)initWithPDFBundle:(NSString *)bundle relativeDirectory:(NSString *)relative;
- (instancetype)initWithCollectionSession:(BOOL)guided;
@end
