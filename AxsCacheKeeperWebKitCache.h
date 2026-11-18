#pragma once
#import <Foundation/Foundation.h>
#import "AxsCacheKeeperWebKitStatus.h"

@protocol AxsCacheKeeperWebKitStore <NSObject>
- (BOOL)isPersistent;
- (void)removeDataOfTypes:(NSSet<NSString *> *)types modifiedSince:(NSDate *)date completionHandler:(void (^)(void))completion;
@end

// All methods and preparation replies run on the main thread. The context contains only validated
// authorization and private generation tokens; receipt never includes those tokens.
typedef void (^AxsCacheKeeperWebKitPreparation)(void (^reply)(NSDictionary *context, BOOL hasBackgroundTime));
typedef void (^AxsCacheKeeperWebKitDeadlineScheduler)(NSTimeInterval delay, void (^deadline)(void));
@interface AxsCacheKeeperWebKitCache : NSObject
- (instancetype)initWithPreparation:(AxsCacheKeeperWebKitPreparation)prepare
                              clock:(NSTimeInterval (^)(void))clock
                           observer:(void (^)(NSDictionary *receipt))observer;
- (instancetype)initWithPreparation:(AxsCacheKeeperWebKitPreparation)prepare
                              clock:(NSTimeInterval (^)(void))clock
                          scheduler:(AxsCacheKeeperWebKitDeadlineScheduler)scheduler
                           observer:(void (^)(NSDictionary *receipt))observer;
// A fresh synchronous authorization read suspends new work until its own validation arrives.
- (void)suspendForConfiguration;
- (void)suspendForConfigurationWithAuthorization:(BOOL)authorized;
- (BOOL)hasPendingWork;
// Runtime validates the live UIKit task again at the actual API boundary.
- (void)setBackgroundTimeValidation:(BOOL (^)(void))validation;
- (void)rejectRevokedConfiguration;
- (BOOL)observationAllowed;
- (void)updateContext:(NSDictionary *)context;
- (void)observeStore:(id<AxsCacheKeeperWebKitStore>)store;
- (void)didBecomeActive;
// Initial configuration wait shares the first store's preparation deadline; it grants no task/time.
- (void)beginBackgroundPreparation;
- (BOOL)backgroundPreparationAllowed;
- (void)didEnterBackgroundWithTime:(BOOL)hasTime;
- (void)expireBackgroundTime;
- (void)checkTimeout;
// Restore once before observation; malformed input is explicitly recorded as rejected.
- (void)restoreOperationHistory:(id)history;
- (NSUInteger)beginOperationRefreshWithTrigger:(NSString *)trigger;
- (void)completeOperationRefresh:(NSUInteger)event applied:(BOOL)applied;
- (NSDictionary *)receipt;
@end

#ifdef __cplusplus
extern "C" {
#endif
// Installs observation synchronously when already on main; no store is read before verification.
void axs_cachekeeper_configure_webkit(BOOL containerEligible, BOOL configurationAccess, BOOL diskCacheAuthorized);
#ifdef __cplusplus
}
#endif
