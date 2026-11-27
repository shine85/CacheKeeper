#import <UIKit/UIKit.h>
@interface AxsCacheKeeperDiagnosticsPage : UIViewController
- (instancetype)init;
- (instancetype)initWithSearchSnapshot:(NSDictionary *)snapshot;
- (instancetype)initWithPDFBundle:(NSString *)bundle relativeDirectory:(NSString *)relative;
- (instancetype)initWithCollectionSession:(BOOL)guided;
@end
