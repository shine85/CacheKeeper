#pragma once
#import <Foundation/Foundation.h>
// Bind only a getter-provided root below the system main container. Values are private,
// process-local; no path or dev/ino from a binding may enter a receipt.
NSDictionary *axs_cachekeeper_gurd_bind_root(NSString *root,NSString *home,NSString *installation,NSString **reason);
// The caller owns a returned descriptor; -1 means current ancestry or root failed.
int axs_cachekeeper_gurd_open_root(NSDictionary *binding);
NSString *axs_cachekeeper_gurd_binding_reason(NSDictionary *binding,NSString *home,NSString *installation);
@protocol AxsCacheKeeperGurdHostSource <NSObject>
- (NSDictionary *)prepareWithContext:(NSDictionary *)context reason:(NSString **)reason;
- (NSString *)validateBinding:(NSDictionary *)binding context:(NSDictionary *)context;
// YES means the verified void selector returned. There is no completion callback.
// Authorization must run immediately before entering the host implementation.
- (BOOL)submitBinding:(NSDictionary *)binding context:(NSDictionary *)context
       authorization:(BOOL (^)(void))authorization reason:(NSString **)reason;
@end
@interface AxsCacheKeeperGurdSource : NSObject <AxsCacheKeeperGurdHostSource>
@end
