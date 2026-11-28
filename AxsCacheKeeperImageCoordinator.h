#pragma once
#import <Foundation/Foundation.h>

@protocol AxsCacheKeeperImageLifecycle <NSObject>
- (void)didBecomeActive;
- (void)didEnterBackgroundWithTime:(BOOL)hasTime completion:(void (^)(void))completion;
- (void)expireBackgroundTime;
- (NSDictionary *)receipt;
@end

// Main-thread lifecycle ownership. Zero is an unavailable platform task token.
@interface AxsCacheKeeperImageCoordinator : NSObject
- (instancetype)initWithCache:(id<AxsCacheKeeperImageLifecycle>)cache
              beginBackground:(NSUInteger (^)(void (^expiration)(void)))begin
                endBackground:(void (^)(NSUInteger task))end
               backgroundTime:(BOOL (^)(NSUInteger task))time;
- (void)didBecomeActive;
- (void)didEnterBackground;
- (void)configurationDidChange;
// Call only after the observer's synchronous persistence attempt has returned.
- (void)receiptDidChange:(NSDictionary *)receipt;
@end
