#pragma once
#import <Foundation/Foundation.h>
#import "AxsCacheKeeperWebKitCache.h"
#import "AxsCacheKeeperWebKitObservation.h"

typedef void (^AxsCacheKeeperWebKitContextReader)(void (^reply)(NSDictionary *context));
// Token zero means no task. Providers own the platform handle; epochs remain private here.
typedef NSUInteger (^AxsCacheKeeperWebKitBackgroundBegin)(void (^expiration)(void));
typedef void (^AxsCacheKeeperWebKitBackgroundEnd)(NSUInteger task);
typedef BOOL (^AxsCacheKeeperWebKitBackgroundTime)(NSUInteger task);

// Main-thread production bridge shared by Logos and real WebKit regressions.
@interface AxsCacheKeeperWebKitCoordinator : NSObject
- (instancetype)initWithReader:(AxsCacheKeeperWebKitContextReader)reader
               beginBackground:(AxsCacheKeeperWebKitBackgroundBegin)begin
                 endBackground:(AxsCacheKeeperWebKitBackgroundEnd)end
                backgroundTime:(AxsCacheKeeperWebKitBackgroundTime)time
                         clock:(NSTimeInterval (^)(void))clock
                     scheduler:(AxsCacheKeeperWebKitDeadlineScheduler)scheduler
                      observer:(void (^)(NSDictionary *receipt))observer;
- (void)configureWithAuthorization:(BOOL)authorized;
- (void)didBecomeActive;
- (void)didEnterBackground;
- (void)captureCreatedWebView:(WKWebView *)view;
@property(nonatomic,strong,readonly) AxsCacheKeeperWebKitCache *cache;
@property(nonatomic,strong,readonly) AxsCacheKeeperWebKitObservation *observation;
@end
