#import "AxsCacheKeeperWebKitCoordinator.h"
#import <dispatch/dispatch.h>

@interface AxsCacheKeeperWebKitCoordinator () {
    AxsCacheKeeperWebKitContextReader _reader;
    AxsCacheKeeperWebKitBackgroundBegin _begin;
    AxsCacheKeeperWebKitBackgroundEnd _end;
    AxsCacheKeeperWebKitBackgroundTime _time;
    NSUInteger _readGeneration,_taskEpoch,_task;
    BOOL _authorized,_readingConfiguration,_foregroundSeen,_background,_attemptStarted,_startingTask,_expired;
}
@property(nonatomic,strong,readwrite) AxsCacheKeeperWebKitCache *cache;
@property(nonatomic,strong,readwrite) AxsCacheKeeperWebKitObservation *observation;
@end

@implementation AxsCacheKeeperWebKitCoordinator
- (instancetype)initWithReader:(AxsCacheKeeperWebKitContextReader)reader beginBackground:(AxsCacheKeeperWebKitBackgroundBegin)begin
                 endBackground:(AxsCacheKeeperWebKitBackgroundEnd)end backgroundTime:(AxsCacheKeeperWebKitBackgroundTime)time
                         clock:(NSTimeInterval (^)(void))clock scheduler:(AxsCacheKeeperWebKitDeadlineScheduler)scheduler
                      observer:(void (^)(NSDictionary *))observer {
    self=[super init];if (!self) return nil;
    _reader=[reader copy];_begin=[begin copy];_end=[end copy];_time=[time copy];
    __weak typeof(self) weakSelf=self;
    _cache=[[AxsCacheKeeperWebKitCache alloc] initWithPreparation:^(void (^reply)(NSDictionary *,BOOL)) {
        [weakSelf axs_cachekeeper_prepare:reply];
    } clock:clock scheduler:scheduler observer:^(NSDictionary *receipt) {
        if (observer) observer(receipt);
        // A synchronous public API callback can queue the next store before ending the task.
        dispatch_async(dispatch_get_main_queue(),^{[weakSelf axs_cachekeeper_end_if_idle];});
    }];
    _observation=[[AxsCacheKeeperWebKitObservation alloc] initWithCache:_cache];
    [_cache setBackgroundTimeValidation:^BOOL {return [weakSelf axs_cachekeeper_has_time];}];
    return self;
}
- (void)axs_cachekeeper_read:(void (^)(NSDictionary *))reply {
    if (!_reader) {reply(@{});return;}
    __block BOOL delivered=NO;
    _reader(^(NSDictionary *context) {
        void (^deliver)(void)=^{
            if (delivered) return;delivered=YES;reply(context);
        };
        if (NSThread.isMainThread) deliver();else dispatch_async(dispatch_get_main_queue(),deliver);
    });
}
- (BOOL)axs_cachekeeper_has_time {
    return _background && !_expired && _task && _time && _time(_task);
}
- (void)axs_cachekeeper_end_task:(NSUInteger)epoch {
    if (epoch!=_taskEpoch || !_task) return;
    NSUInteger task=_task;_task=0;++_taskEpoch;
    if (_end) _end(task);
}
- (void)axs_cachekeeper_end_if_idle {
    if (!_startingTask && !_cache.hasPendingWork) [self axs_cachekeeper_end_task:_taskEpoch];
}
- (void)axs_cachekeeper_prepare:(void (^)(NSDictionary *,BOOL))reply {
    NSAssert(NSThread.isMainThread,@"WebKit preparation requires main thread");
    NSUInteger generation=_readGeneration,epoch=_taskEpoch;
    __weak typeof(self) weakSelf=self;
    [self axs_cachekeeper_read:^(NSDictionary *context) {
        AxsCacheKeeperWebKitCoordinator *self=weakSelf;
        // Even an obsolete read explicitly replies. The engine's request ID rejects it.
        if (!self || generation!=self->_readGeneration || epoch!=self->_taskEpoch || !self->_authorized) {reply(nil,NO);return;}
        reply(context,[self axs_cachekeeper_has_time]);
    }];
}
- (void)configureWithAuthorization:(BOOL)authorized {
    NSAssert(NSThread.isMainThread,@"WebKit configuration requires main thread");
    _authorized=authorized;_readingConfiguration=YES;
    NSUInteger request=++_readGeneration,generation=[_observation beginConfigurationWithAuthorization:authorized];
    NSUInteger event=[_cache beginOperationRefreshWithTrigger:@"configuration"];
    __weak typeof(self) weakSelf=self;
    [self axs_cachekeeper_read:^(NSDictionary *context) {
        AxsCacheKeeperWebKitCoordinator *self=weakSelf;if (!self) return;
        if (request!=self->_readGeneration) {[self.cache completeOperationRefresh:event applied:NO];return;}
        self->_readingConfiguration=NO;
        BOOL applied=[self.observation applyContext:context forGeneration:generation];
        if (!applied && !self->_authorized) [self.cache rejectRevokedConfiguration];
        [self.cache completeOperationRefresh:event applied:applied];
        if (applied) [self axs_cachekeeper_start_background];
        [self axs_cachekeeper_end_if_idle];
    }];
}
- (void)didBecomeActive {
    NSAssert(NSThread.isMainThread,@"WebKit lifecycle requires main thread");
    _foregroundSeen=YES;_background=NO;_attemptStarted=NO;++_readGeneration;
    [_cache didBecomeActive];
    NSUInteger epoch=_taskEpoch;[self axs_cachekeeper_end_task:epoch];
    if (_taskEpoch==epoch) ++_taskEpoch;
    _startingTask=NO;
    [self configureWithAuthorization:_authorized];
}
- (void)didEnterBackground {
    NSAssert(NSThread.isMainThread,@"WebKit lifecycle requires main thread");
    if (_background) return;_background=YES;_attemptStarted=NO;
    if (_readingConfiguration && _foregroundSeen) [_cache beginBackgroundPreparation];
    [self axs_cachekeeper_start_background];
}
- (void)axs_cachekeeper_start_background {
    if (!_background) return;
    if (_foregroundSeen && ![_cache backgroundPreparationAllowed]) return;
    if (_attemptStarted || _readingConfiguration) return;
    _attemptStarted=YES;
    if (!_foregroundSeen || !_observation.observing || ![_cache.receipt[@"persistentStores"] unsignedIntegerValue]) {
        [_cache didEnterBackgroundWithTime:NO];return;
    }
    NSUInteger epoch=++_taskEpoch;_expired=NO;_startingTask=YES;
    __weak typeof(self) weakSelf=self;
    NSUInteger task=_begin ? _begin(^{
        void (^expire)(void)=^{
            AxsCacheKeeperWebKitCoordinator *self=weakSelf;if (!self || epoch!=self->_taskEpoch) return;
            self->_expired=YES;[self.cache expireBackgroundTime];[self axs_cachekeeper_end_task:epoch];
        };
        if (NSThread.isMainThread) expire();else dispatch_async(dispatch_get_main_queue(),expire);
    }) : 0;
    if (epoch!=_taskEpoch) {_startingTask=NO;if (task && _end) _end(task);return;}
    _task=task;_startingTask=NO;
    [_cache didEnterBackgroundWithTime:[self axs_cachekeeper_has_time]];
    [self axs_cachekeeper_end_if_idle];
}
- (void)captureCreatedWebView:(WKWebView *)view {[_observation captureCreatedWebView:view];}
@end
