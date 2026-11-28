#import "AxsCacheKeeperImageCoordinator.h"
#import <dispatch/dispatch.h>

@interface AxsCacheKeeperImageCoordinator () {
    id<AxsCacheKeeperImageLifecycle> _cache;
    NSUInteger (^_begin)(void (^)(void));
    void (^_end)(NSUInteger);
    BOOL (^_time)(NSUInteger);
    NSUInteger _request,_task;
    BOOL _background,_scheduling,_expired;
    NSDictionary *_publishedReceipt;
}
@end
@implementation AxsCacheKeeperImageCoordinator
- (instancetype)initWithCache:(id<AxsCacheKeeperImageLifecycle>)cache
              beginBackground:(NSUInteger (^)(void (^)(void)))begin
                endBackground:(void (^)(NSUInteger))end backgroundTime:(BOOL (^)(NSUInteger))time {
    self=[super init];if (!self) return nil;
    _cache=cache;_begin=[begin copy];_end=[end copy];_time=[time copy];return self;
}
- (void)axs_cachekeeper_end_task {
    NSUInteger task=_task;_task=0;if (task && _end) _end(task);
}
- (void)axs_cachekeeper_finish_published_work {
    // refresh_event publishes zero pending before it schedules owners. Only the
    // explicit completion can end preparation; a future in-memory snapshot cannot
    // end the task while its synchronous publication is still in progress.
    if (!_scheduling && _publishedReceipt && ![_publishedReceipt[@"pending"] unsignedIntegerValue]) [self axs_cachekeeper_end_task];
}
- (void)receiptDidChange:(NSDictionary *)receipt {
    NSAssert(NSThread.isMainThread,@"Image lifecycle requires main thread");
    _publishedReceipt=[receipt copy];
    [self axs_cachekeeper_finish_published_work];
}
- (void)configurationDidChange {
    NSAssert(NSThread.isMainThread,@"Image lifecycle requires main thread");
    ++_request;_scheduling=NO;_expired=YES;
    if (_background) [_cache expireBackgroundTime];
    [self axs_cachekeeper_end_task];
}
- (void)didBecomeActive {
    NSAssert(NSThread.isMainThread,@"Image lifecycle requires main thread");
    ++_request;_background=NO;_scheduling=NO;_expired=YES;
    [_cache didBecomeActive];[self axs_cachekeeper_end_task];
}
- (void)didEnterBackground {
    NSAssert(NSThread.isMainThread,@"Image lifecycle requires main thread");
    if (_background) return;
    _background=YES;_scheduling=YES;_expired=NO;_publishedReceipt=nil;NSUInteger request=++_request;
    __weak typeof(self) weakSelf=self;
    // Time covers asynchronous preparation, whose eligible count is not known yet.
    NSUInteger task=_begin ? _begin(^{
        void (^expire)(void)=^{
            AxsCacheKeeperImageCoordinator *self=weakSelf;
            if (!self || request!=self->_request || !self->_background || self->_expired || (!self->_scheduling && !self->_task)) return;
            self->_expired=YES;[self->_cache expireBackgroundTime];[self axs_cachekeeper_end_task];
        };
        if (NSThread.isMainThread) expire();else dispatch_async(dispatch_get_main_queue(),expire);
    }) : 0;
    // UIKit can expire synchronously or a provider can reenter lifecycle before
    // returning its token. Never let that returned token replace a newer task.
    if (request!=_request) {if (task && _end) _end(task);return;}
    _task=task;if (_expired) [self axs_cachekeeper_end_task];
    BOOL hasTime=!_expired && _task && _time && _time(_task);
    [_cache didEnterBackgroundWithTime:hasTime completion:^{
        void (^complete)(void)=^{
            AxsCacheKeeperImageCoordinator *self=weakSelf;
            if (!self || request!=self->_request || !self->_background) return;
            self->_scheduling=NO;[self axs_cachekeeper_finish_published_work];
        };
        if (NSThread.isMainThread) complete();else dispatch_async(dispatch_get_main_queue(),complete);
    }];
}
@end
