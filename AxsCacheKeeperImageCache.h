#pragma once
#import <Foundation/Foundation.h>
#import "AxsCacheKeeperImageCacheStatus.h"

// Provider runs on private background queues and must be thread-safe. It returns the latest
// validated configuration and in-memory installation identity, never image data or keys.
typedef NSDictionary * (^AxsCacheKeeperImageContextProvider)(void);
@interface AxsCacheKeeperImageCache : NSObject
- (instancetype)initWithContextProvider:(AxsCacheKeeperImageContextProvider)provider
                              observer:(void (^)(NSDictionary *receipt))observer;
- (void)startObserving;
// Immediately suspends write gates and cancels work which has not entered the SDK API.
- (void)refreshWithCompletion:(void (^)(void))completion;
- (void)didBecomeActive;
- (void)didEnterBackgroundWithTime:(BOOL)hasTime;
- (void)expireBackgroundTime;
- (NSDictionary *)receipt;
#if AXS_CACHEKEEPER_IMAGE_TESTING
// The integration target links the actual SDK at the fixed source revision. No fake SDK class.
- (void)usePinnedSDKForIntegrationTests;
#endif
@end
