#pragma once
#import <Foundation/Foundation.h>

// Preferences-only batch over the existing unauthenticated host self-report client.
// No policy, access request, resource operation or host protocol is added here.
NSArray<NSDictionary *> *axs_cachekeeper_host_preflight_targets(void);

@interface AxsCacheKeeperHostPreflight : NSObject
- (instancetype)initWithStatusDirectory:(NSString *)directory panelVersion:(NSString *)version;
// Rejects replacement while running. A new round resets prior page results.
- (BOOL)startWithTimeout:(NSTimeInterval)timeout;
- (void)poll;
- (void)cancel;
// Retries only terminal rows whose file save failed; never sends another request.
- (void)retrySaving;
- (NSDictionary *)snapshot;
@property(nonatomic,readonly) BOOL running;
@end
