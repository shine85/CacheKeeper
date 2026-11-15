#import "AxsCacheKeeperWebKitCache.h"
#import <WebKit/WebKit.h>
#import <dispatch/dispatch.h>

@interface AxsCacheKeeperWebKitStoreReference : NSObject
@property(nonatomic,weak) id<AxsCacheKeeperWebKitStore> store;
@property(nonatomic) BOOL persistent;
@end
@implementation AxsCacheKeeperWebKitStoreReference
@end

@interface AxsCacheKeeperWebKitCache () {
    AxsCacheKeeperWebKitPreparation _prepare;
    AxsCacheKeeperWebKitDeadlineScheduler _schedule;
    NSTimeInterval (^_clock)(void);
    void (^_observer)(NSDictionary *);
    NSDictionary *_context;
    NSMapTable *_stores;
    NSMutableArray<AxsCacheKeeperWebKitStoreReference *> *_queue;
    id<AxsCacheKeeperWebKitStore> _flight;
    NSUInteger _contextGeneration,_foregroundGeneration,_lastBackgroundGeneration,_preparationID,_flightID;
    NSUInteger _flightContextGeneration,_submitted,_completed;
    BOOL _activeSeen,_background,_hasTime,_preparing,_timedOut,_configurationPending;
    NSTimeInterval _flightStarted;
    NSString *_state,*_reason;
    NSDate *_updated;
}
@end

@implementation AxsCacheKeeperWebKitCache
- (instancetype)initWithPreparation:(AxsCacheKeeperWebKitPreparation)prepare clock:(NSTimeInterval (^)(void))clock observer:(void (^)(NSDictionary *))observer {
    return [self initWithPreparation:prepare clock:clock scheduler:nil observer:observer];
}
- (instancetype)initWithPreparation:(AxsCacheKeeperWebKitPreparation)prepare clock:(NSTimeInterval (^)(void))clock scheduler:(AxsCacheKeeperWebKitDeadlineScheduler)scheduler observer:(void (^)(NSDictionary *))observer {
    self=[super init];if (!self) return nil;
    _prepare=[prepare copy];_clock=[clock copy];_observer=[observer copy];
    if (scheduler) _schedule=[scheduler copy];
    else _schedule=^(NSTimeInterval delay,void (^deadline)(void)) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),dispatch_get_main_queue(),deadline);
    };
    _stores=[NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory|NSPointerFunctionsObjectPointerPersonality valueOptions:NSPointerFunctionsStrongMemory];
    _state=@"disabled";_reason=@"notAuthorized";_updated=NSDate.date;
    return self;
}
- (NSString *)axs_cachekeeper_block_reason {
    if (_configurationPending) return @"authorizationChanged";
    NSDictionary *context=_context;
    for (NSString *key in @[@"readable",@"valid",@"enabled",@"requested",@"reportWritable"])
        if (!axs_cachekeeper_webkit_boolean(context[key])) return @"configurationInvalid";
    if (![context[@"readable"] boolValue]) return @"configurationUnreadable";
    if (![context[@"valid"] boolValue]) return @"configurationInvalid";
    if (![context[@"enabled"] boolValue]) return @"appDisabled";
    if (![context[@"requested"] boolValue]) return @"notAuthorized";
    if (![context[@"excludedPaths"] isKindOfClass:NSArray.class]) return @"configurationInvalid";
    if ([context[@"excludedPaths"] count]) return @"exclusionUnrepresentable";
    if (![context[@"installation"] isKindOfClass:NSString.class] || ![context[@"installation"] length]) return @"installationUnverified";
    if (![context[@"process"] isKindOfClass:NSString.class] || ![context[@"process"] length]) return @"processUnverified";
    if (![context[@"reportWritable"] boolValue]) return @"reportWriteFailed";
    return nil;
}
- (void)axs_cachekeeper_publish {
    _updated=NSDate.date;
    if (_observer) _observer(self.receipt);
}
- (void)axs_cachekeeper_cancel_queue {
    _queue=nil;_preparing=NO;++_preparationID;
}
- (void)axs_cachekeeper_refresh_idle_state {
    NSString *blocked=[self axs_cachekeeper_block_reason];
    if (blocked) {
        _reason=blocked;
        _state=[@[@"appDisabled",@"notAuthorized"] containsObject:blocked] ? @"disabled" : @"blocked";
        return;
    }
    NSUInteger persistent=0,nonPersistent=0;
    for (AxsCacheKeeperWebKitStoreReference *reference in _stores.objectEnumerator.allObjects) {
        if (!reference.store) continue;
        if (reference.persistent) persistent++;else nonPersistent++;
    }
    _reason=@"none";_state=persistent ? @"ready" : (nonPersistent ? @"nonPersistentOnly" : @"notObserved");
}
- (void)updateContext:(NSDictionary *)context {
    NSAssert(NSThread.isMainThread,@"WebKit coordinator requires main thread");
    if (![context isKindOfClass:NSDictionary.class]) context=@{};
    NSMutableDictionary *copy=[context mutableCopy];
    for (NSString *key in @[@"excludedPaths",@"installation",@"process"])
        if ([copy[key] conformsToProtocol:@protocol(NSCopying)]) copy[key]=[copy[key] copy];
    BOOL wasPending=_configurationPending;
    _configurationPending=NO;
    if ([_context isEqual:copy] && !wasPending) return;
    BOOL identityChanged=_context && (![_context[@"installation"] isEqual:copy[@"installation"]] || ![_context[@"process"] isEqual:copy[@"process"]]);
    _context=[copy copy];++_contextGeneration;
    [self axs_cachekeeper_cancel_queue];
    if (identityChanged) [_stores removeAllObjects];
    if (_flight) _reason=@"authorizationChanged";
    else {
        [self axs_cachekeeper_refresh_idle_state];
        if (identityChanged && ![self axs_cachekeeper_block_reason]) {_state=@"stale";_reason=@"installationChanged";}
    }
    [self axs_cachekeeper_publish];
}
- (void)suspendForConfiguration {
    NSAssert(NSThread.isMainThread,@"WebKit configuration requires main thread");
    _configurationPending=YES;++_contextGeneration;[self axs_cachekeeper_cancel_queue];
    _reason=@"authorizationChanged";
    if (!_flight) _state=@"blocked";
    [self axs_cachekeeper_publish];
}
- (BOOL)observationAllowed {
    NSAssert(NSThread.isMainThread,@"WebKit observation requires main thread");
    return [self axs_cachekeeper_block_reason]==nil;
}
- (void)observeStore:(id<AxsCacheKeeperWebKitStore>)store {
    NSAssert(NSThread.isMainThread,@"WebKit observation requires main thread");
    if ([self axs_cachekeeper_block_reason] || !store || [_stores objectForKey:store]) return;
    if (![store respondsToSelector:@selector(isPersistent)] || ![store respondsToSelector:@selector(removeDataOfTypes:modifiedSince:completionHandler:)]) {
        if (!_flight) {_state=@"unsupported";_reason=@"unsupported";[self axs_cachekeeper_publish];}
        return;
    }
    AxsCacheKeeperWebKitStoreReference *reference=[AxsCacheKeeperWebKitStoreReference new];reference.store=store;reference.persistent=store.isPersistent;
    [_stores setObject:reference forKey:store];
    if (!_flight && !_preparing) [self axs_cachekeeper_refresh_idle_state];
    [self axs_cachekeeper_publish];
}
- (void)didBecomeActive {
    NSAssert(NSThread.isMainThread,@"WebKit lifecycle requires main thread");
    _activeSeen=YES;_background=NO;_hasTime=NO;++_foregroundGeneration;
    [self axs_cachekeeper_cancel_queue];
    if (_flight) _reason=@"foregroundAgain";
    [self checkTimeout];
}
- (void)didEnterBackgroundWithTime:(BOOL)hasTime {
    NSAssert(NSThread.isMainThread,@"WebKit lifecycle requires main thread");
    _background=YES;_hasTime=hasTime;
    // A timed-out, non-cancellable call still owns the process-wide slot.
    if (_flight) { _reason=@"inFlight";[self checkTimeout];[self axs_cachekeeper_publish];return; }
    if (!_activeSeen || _lastBackgroundGeneration==_foregroundGeneration) return;
    _lastBackgroundGeneration=_foregroundGeneration;
    NSString *blocked=[self axs_cachekeeper_block_reason];
    if (blocked) { [self axs_cachekeeper_refresh_idle_state];[self axs_cachekeeper_publish];return; }
    _submitted=0;_completed=0;_timedOut=NO;
    _queue=[NSMutableArray new];
    for (AxsCacheKeeperWebKitStoreReference *reference in _stores.objectEnumerator.allObjects)
        if (reference.persistent && reference.store) [_queue addObject:reference];
    if (!_queue.count) {[self axs_cachekeeper_refresh_idle_state];[self axs_cachekeeper_publish];return;}
    if (!hasTime) {_queue=nil;_state=@"blocked";_reason=@"noBackgroundTime";[self axs_cachekeeper_publish];return;}
    [self axs_cachekeeper_prepare_next];
}
- (void)axs_cachekeeper_prepare_next {
    if (_flight || _preparing || !_queue.count || !_background || !_hasTime) return;
    NSString *blocked=[self axs_cachekeeper_block_reason];
    if (blocked) {[self axs_cachekeeper_cancel_queue];[self axs_cachekeeper_refresh_idle_state];[self axs_cachekeeper_publish];return;}
    AxsCacheKeeperWebKitStoreReference *reference=_queue.firstObject;[_queue removeObjectAtIndex:0];
    if (!reference.store) {
        _state=@"blocked";_reason=@"storeUnavailable";[self axs_cachekeeper_publish];[self axs_cachekeeper_prepare_next];return;
    }
    _preparing=YES;NSUInteger preparation=++_preparationID,generation=_contextGeneration,foreground=_foregroundGeneration;
    _state=@"queued";_reason=@"none";[self axs_cachekeeper_publish];
    __weak typeof(self) weakSelf=self;
    void (^reply)(NSDictionary *,BOOL)=^(NSDictionary *context,BOOL hasTime) {
        void (^accept)(void)=^{
            AxsCacheKeeperWebKitCache *self=weakSelf;
            if (!self || !self->_preparing || self->_preparationID!=preparation) return;
            self->_preparing=NO;
            [self updateContext:context];
            if (self->_contextGeneration!=generation || self->_foregroundGeneration!=foreground || !self->_background || !self->_hasTime || !hasTime) {
                [self axs_cachekeeper_cancel_queue];
                if (!self->_flight) {
                    NSString *reason=[self axs_cachekeeper_block_reason];
                    self->_state=@"blocked";self->_reason=reason ?: ((!self->_hasTime || !hasTime) ? @"noBackgroundTime" : (!self->_background ? @"foregroundAgain" : @"authorizationChanged"));
                    [self axs_cachekeeper_publish];
                }
                return;
            }
            id<AxsCacheKeeperWebKitStore> store=reference.store;
            if (!store || !store.isPersistent) {
                self->_state=@"blocked";self->_reason=@"storeUnavailable";[self axs_cachekeeper_publish];[self axs_cachekeeper_prepare_next];return;
            }
            NSString *reason=[self axs_cachekeeper_block_reason];
            if (reason || self->_flight) return;
            self->_flight=store;self->_flightContextGeneration=generation;
            self->_flightStarted=self->_clock ? self->_clock() : NSProcessInfo.processInfo.systemUptime;
            NSUInteger flight=++self->_flightID;self->_submitted++;
            self->_timedOut=NO;
            self->_state=@"submitted";self->_reason=@"none";
            [self axs_cachekeeper_schedule_deadline:flight after:15];
            [store removeDataOfTypes:[NSSet setWithObject:WKWebsiteDataTypeDiskCache] modifiedSince:NSDate.distantPast completionHandler:^{
                void (^finish)(void)=^{[weakSelf axs_cachekeeper_completed:flight];};
                if (NSThread.isMainThread) finish();else dispatch_async(dispatch_get_main_queue(),finish);
            }];
            [self axs_cachekeeper_publish];
        };
        if (NSThread.isMainThread) accept();else dispatch_async(dispatch_get_main_queue(),accept);
    };
    if (_prepare) _prepare(reply);else reply(_context,_hasTime);
}
- (void)axs_cachekeeper_schedule_deadline:(NSUInteger)flight after:(NSTimeInterval)delay {
    __weak typeof(self) weakSelf=self;
    _schedule(delay,^{
        void (^check)(void)=^{
            AxsCacheKeeperWebKitCache *self=weakSelf;
            if (!self || !self->_flight || self->_flightID!=flight || self->_timedOut) return;
            NSTimeInterval now=self->_clock ? self->_clock() : NSProcessInfo.processInfo.systemUptime;
            NSTimeInterval remaining=15-(now-self->_flightStarted);
            if (remaining>0) [self axs_cachekeeper_schedule_deadline:flight after:remaining];
            else [self checkTimeout];
        };
        if (NSThread.isMainThread) check();else dispatch_async(dispatch_get_main_queue(),check);
    });
}
- (void)axs_cachekeeper_completed:(NSUInteger)flight {
    if (!_flight || flight!=_flightID) return;
    BOOL sameGeneration=_flightContextGeneration==_contextGeneration;
    _flight=nil;_completed++;_state=@"completed";_reason=sameGeneration ? @"none" : @"authorizationChanged";
    [self axs_cachekeeper_publish];
    if (sameGeneration && _background && _hasTime) [self axs_cachekeeper_prepare_next];
}
- (void)expireBackgroundTime {
    NSAssert(NSThread.isMainThread,@"WebKit expiration requires main thread");
    _hasTime=NO;[self axs_cachekeeper_cancel_queue];
    if (!_flight) _state=@"blocked";
    _reason=@"noBackgroundTime";[self checkTimeout];[self axs_cachekeeper_publish];
}
- (void)checkTimeout {
    NSAssert(NSThread.isMainThread,@"WebKit timeout requires main thread");
    NSTimeInterval now=_clock ? _clock() : NSProcessInfo.processInfo.systemUptime;
    if (_flight && now-_flightStarted>=15 && !_timedOut) {
        _timedOut=YES;_state=@"waitingTimedOut";
        [self axs_cachekeeper_cancel_queue];[self axs_cachekeeper_publish];
    }
}
- (NSDictionary *)receipt {
    NSUInteger persistent=0,nonPersistent=0;
    for (AxsCacheKeeperWebKitStoreReference *reference in _stores.objectEnumerator.allObjects) {
        if (!reference.store) continue;
        if (reference.persistent) persistent++;else nonPersistent++;
    }
    BOOL requested=axs_cachekeeper_webkit_boolean(_context[@"requested"]) && [_context[@"requested"] boolValue];
    return @{@"schemaVersion":@1,@"requested":@(requested),@"timedOut":@(_timedOut),@"state":_state ?: @"disabled",@"reason":_reason ?: @"notAuthorized",
        @"persistentStores":@(persistent),@"nonPersistentStores":@(nonPersistent),@"submitted":@(_submitted),@"completed":@(_completed),@"pending":@(_flight ? 1 : 0),
        @"updated":_updated ?: NSDate.date,@"bytesState":@"notMeasured"};
}
@end
