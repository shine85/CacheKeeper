#pragma once
#import <Foundation/Foundation.h>
#import "AxsCacheKeeperGurdSource.h"
#import "AxsCacheKeeperGurdStatus.h"
typedef NSDictionary * (^AxsCacheKeeperGurdContextProvider)(void);
// Lifecycle methods are main-thread entry points. The context provider is thread-safe
// and returns a validated immutable snapshot with the Image runtime context keys.
@interface AxsCacheKeeperGurdCache : NSObject
- (instancetype)initWithContextProvider:(AxsCacheKeeperGurdContextProvider)provider
                                 source:(id<AxsCacheKeeperGurdHostSource>)source
                              beginTask:(NSUInteger (^)(void (^expiration)(void)))begin
                                endTask:(void (^)(NSUInteger task))end
                               observer:(void (^)(NSDictionary *receipt))observer;
- (void)didBecomeActive;
- (void)didEnterBackground;
- (void)refresh;
- (void)refreshForConfiguration:(NSUInteger)configuration;
- (void)expireBackgroundTime;
// Legacy records are bounded, retained as unknown; never infer submission or completion.
- (void)restoreReceipt:(id)receipt;
#if defined(AXS_CACHEKEEPER_GURD_TESTING)
- (void)axs_cachekeeper_setSampleEntryLimit:(NSUInteger)entries seconds:(NSTimeInterval)seconds;
#endif
- (NSDictionary *)receipt;
@end
