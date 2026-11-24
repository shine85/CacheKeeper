#pragma once
#import <Foundation/Foundation.h>
#import "AxsCacheKeeperImageCacheStatus.h"
#import "AxsCacheKeeperImageCoordinator.h"

// Provider runs on private background queues and must be thread-safe. It returns the latest
// validated configuration and in-memory installation identity, never image data or keys.
typedef NSDictionary * (^AxsCacheKeeperImageContextProvider)(void);
@interface AxsCacheKeeperImageCache : NSObject <AxsCacheKeeperImageLifecycle>
- (instancetype)initWithContextProvider:(AxsCacheKeeperImageContextProvider)provider
                              observer:(void (^)(NSDictionary *receipt))observer;
- (void)startObserving;
// Coalesces loader notifications on the engine queue and publishes changed discovery state.
- (void)requestDiscoveryRefresh;
// FIFO fence only; completion runs off main after previously queued preparation.
// Returns the last adopted context and generation without creating a refresh/event.
- (void)performAfterPendingWork:(void (^)(NSDictionary *context, NSUInteger generation))completion;
// Short synchronized read; never waits for provider or filesystem IO.
- (BOOL)isCurrentWorkGeneration:(NSUInteger)generation;
// Immediately suspends write gates and cancels work which has not entered the SDK API.
- (void)refreshWithCompletion:(void (^)(void))completion;
- (void)didBecomeActive;
- (void)didEnterBackgroundWithTime:(BOOL)hasTime;
// Completion means owner scheduling finished, not that SDK deletion completed.
- (void)didEnterBackgroundWithTime:(BOOL)hasTime completion:(void (^)(void))completion;
- (void)expireBackgroundTime;
// Restore once before observation; malformed input is explicitly recorded as rejected.
- (void)restoreOperationHistory:(id)history;
- (void)loadOperationHistoryFromPath:(NSString *)path;
- (NSDictionary *)receipt;
#if AXS_CACHEKEEPER_IMAGE_TESTING
// The integration target links the actual SDK at the fixed source revision. No fake SDK class.
- (void)usePinnedSDKForIntegrationTests;
// Separate target links unmodified 5.10.4; this explicitly selects its fixed-serial contract.
- (void)usePinnedLegacySDKForIntegrationTests;
// Closed reason codes only; no paths, keys, object descriptions or identities.
- (NSDictionary *)instanceDiagnosticsForIntegrationTests:(id)owner;
// Read-only runtime metadata probes. They neither install hooks nor create cache owners.
- (NSDictionary *)discoveryDiagnosticsForIntegrationTests;
- (NSDictionary *)methodDiagnosticsForIntegrationTests:(NSUInteger)index ownerClass:(Class)ownerClass;
#endif
@end
