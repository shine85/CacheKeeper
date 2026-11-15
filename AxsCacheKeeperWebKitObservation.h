#pragma once
#import <Foundation/Foundation.h>
@class WKWebView;
@class AxsCacheKeeperWebKitCache;

// Main-thread adapter shared by the runtime hooks and real WKWebView regressions.
// It never creates a view/configuration/store or enumerates a default store.
@interface AxsCacheKeeperWebKitObservation : NSObject
- (instancetype)initWithCache:(AxsCacheKeeperWebKitCache *)cache;
- (NSUInteger)beginConfigurationWithAuthorization:(BOOL)authorized;
- (BOOL)applyContext:(NSDictionary *)context forGeneration:(NSUInteger)generation;
- (void)captureCreatedWebView:(WKWebView *)view;
@property(nonatomic,readonly) NSUInteger generation;
@property(nonatomic,readonly) NSUInteger pendingViewCount;
@property(nonatomic,readonly) BOOL observing;
@end
