#pragma once
#import <Foundation/Foundation.h>

// Technical self-report only. This API has no authorization, policy or resource-operation hook.
#ifdef __cplusplus
extern "C" {
#endif
uint64_t axs_cachekeeper_host_request(uint32_t nonce, NSTimeInterval epoch);
BOOL axs_cachekeeper_host_request_fresh(uint64_t request, NSTimeInterval now);
NSArray<NSNumber *> *axs_cachekeeper_host_encode(NSDictionary *snapshot, uint64_t request);
NSDictionary *axs_cachekeeper_host_decode(NSArray *frames, uint64_t request, NSTimeInterval now);
NSDictionary *axs_cachekeeper_host_projection(id value);
NSDictionary *axs_cachekeeper_host_observed_projection(id value);
NSDictionary *axs_cachekeeper_network_projection(id value);
NSString *axs_cachekeeper_host_version_state(id runtimeInfo, NSString *panelVersion);
NSString *axs_cachekeeper_host_name(NSString *bundle, uint64_t request, uint64_t tag, NSInteger frame);
NSString *axs_cachekeeper_host_summary(NSDictionary *envelope, NSString *panelVersion);
#ifdef __cplusplus
}
#endif

@interface AxsCacheKeeperHostEvidenceServer : NSObject
- (instancetype)initWithBundle:(NSString *)bundle folder:(NSString *)folder runtimeInfo:(NSDictionary *)runtimeInfo;
// Values are the existing Cleaner results. This never tries to obtain access.
- (void)axs_cachekeeper_observeContainer:(BOOL)eligible authorizationAttempted:(BOOL)attempted authorizationCode:(int32_t)code sharedAccess:(BOOL)access;
- (NSDictionary *)axs_cachekeeper_snapshot;
- (void)axs_cachekeeper_invalidate;
@end

@interface AxsCacheKeeperHostEvidenceClient : NSObject
- (instancetype)initWithBundle:(NSString *)bundle;
- (BOOL)axs_cachekeeper_beginWithTimeout:(NSTimeInterval)timeout;
- (NSDictionary *)axs_cachekeeper_poll;
- (void)axs_cachekeeper_cancel;
@property(nonatomic,readonly) NSUInteger axs_cachekeeper_activeTokenCount;
@end
