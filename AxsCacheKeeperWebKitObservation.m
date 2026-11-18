#import "AxsCacheKeeperWebKitObservation.h"
#import "AxsCacheKeeperWebKitCache.h"
#import <WebKit/WebKit.h>

static const NSUInteger AxsCacheKeeperWebKitPendingViewLimit=32;

@interface AxsCacheKeeperWebKitObservation () {
    AxsCacheKeeperWebKitCache *_cache;
    NSHashTable<WKWebView *> *_candidates;
    NSUInteger _generation;
    BOOL _authorized,_validated;
}
@end

@implementation AxsCacheKeeperWebKitObservation
- (instancetype)initWithCache:(AxsCacheKeeperWebKitCache *)cache {
    self=[super init];if (!self) return nil;
    _cache=cache;
    _candidates=[NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory|NSPointerFunctionsObjectPointerPersonality];
    return self;
}
- (NSUInteger)generation { return _generation; }
- (NSUInteger)pendingViewCount { return _candidates.allObjects.count; }
- (BOOL)observing { return _authorized && _validated && _cache.observationAllowed; }
- (NSUInteger)beginConfigurationWithAuthorization:(BOOL)authorized {
    NSAssert(NSThread.isMainThread,@"WebKit bootstrap requires main thread");
    ++_generation;_authorized=authorized;_validated=NO;
    if (!authorized) [_candidates removeAllObjects];
    [_cache suspendForConfigurationWithAuthorization:authorized];
    return _generation;
}
- (BOOL)applyContext:(NSDictionary *)context forGeneration:(NSUInteger)generation {
    NSAssert(NSThread.isMainThread,@"WebKit validation requires main thread");
    if (generation!=_generation) return NO;
    // A newer closed synchronous snapshot wins even if another disk read races a later toggle.
    if (!_authorized && [context[@"enabled"] boolValue] && [context[@"requested"] boolValue]) return NO;
    [_cache updateContext:context];
    _validated=_authorized && _cache.observationAllowed;
    if (_validated) {
        NSArray<WKWebView *> *views=_candidates.allObjects;
        [_candidates removeAllObjects];
        for (WKWebView *view in views) {
            if (generation!=_generation || !self.observing) break;
            [self captureCreatedWebView:view];
        }
    } else [_candidates removeAllObjects];
    return YES;
}
- (void)captureCreatedWebView:(WKWebView *)view {
    NSAssert(NSThread.isMainThread,@"WebKit capture requires main thread");
    if (!_authorized || !view) return;
    if (!_validated) {
        if (self.pendingViewCount<AxsCacheKeeperWebKitPendingViewLimit) [_candidates addObject:view];
        return;
    }
    if (!self.observing) return;
    NSUInteger generation=_generation;
    WKWebViewConfiguration *configuration=view.configuration;
    // A getter may re-enter application code; recheck authorization before touching its store.
    if (generation!=_generation || !self.observing) return;
    [_cache observeStore:(id<AxsCacheKeeperWebKitStore>)configuration.websiteDataStore];
}
@end
