#import "AxsCacheKeeperWebKitCache.h"
#import <WebKit/WebKit.h>
#import <dispatch/dispatch.h>

@interface AxsCacheKeeperWebKitStoreReference : NSObject
@property(nonatomic,weak) id<AxsCacheKeeperWebKitStore> store;
@property(nonatomic) BOOL persistent;
@property(nonatomic) NSUInteger ownerID,actionID;
@property(nonatomic) NSUInteger eventID;
@end
@implementation AxsCacheKeeperWebKitStoreReference
@end

@interface AxsCacheKeeperWebKitCache () {
    AxsCacheKeeperWebKitPreparation _prepare;
    AxsCacheKeeperWebKitDeadlineScheduler _schedule;
    NSTimeInterval (^_clock)(void);
    void (^_observer)(NSDictionary *);
    BOOL (^_backgroundTimeValidation)(void);
    NSDictionary *_context;
    NSMapTable *_stores;
    NSMutableArray<AxsCacheKeeperWebKitStoreReference *> *_queue;
    AxsCacheKeeperWebKitStoreReference *_preparingReference;
    id<AxsCacheKeeperWebKitStore> _flight;
    NSUInteger _contextGeneration,_foregroundGeneration,_lastBackgroundGeneration,_preparationID,_flightID;
    NSUInteger _flightContextGeneration,_submitted,_completed;
    BOOL _activeSeen,_background,_hasTime,_preparing,_timedOut,_configurationPending,_configurationRevoked,_contextRefreshInProgress;
    NSTimeInterval _flightStarted;
    NSTimeInterval _preparationStarted;
    NSUInteger _preparationAttempt;
    NSTimeInterval _initialPreparationStarted;
    NSUInteger _initialPreparationID;
    BOOL _initialPreparationWaiting,_initialPreparationExpired,_inheritInitialPreparation;
    NSString *_state,*_reason;
    NSDate *_updated;
    NSMutableDictionary *_operationHistory;
    NSUInteger _operationEvent,_batchEvent,_flightEvent,_flightAction,_preparingAction,_nextOwner,_installationGeneration;
    NSUInteger _flightForegroundGeneration;
    NSString *_operationTrigger;
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
    _operationHistory=axs_cachekeeper_operation_history_create(@"webkit",nil);
    _state=@"disabled";_reason=@"notAuthorized";_updated=NSDate.date;
    return self;
}
- (void)restoreOperationHistory:(id)history {
    NSAssert(NSThread.isMainThread,@"WebKit history requires main thread");
    axs_cachekeeper_operation_restore(_operationHistory,history);
    [self axs_cachekeeper_publish];
}
- (NSUInteger)axs_cachekeeper_begin_event:(NSString *)trigger refreshing:(BOOL)refreshing {
    if (_operationEvent) {
        axs_cachekeeper_operation_refresh(_operationHistory,_operationEvent,@"obsolete");
        axs_cachekeeper_operation_finish(_operationHistory,_operationEvent);
        _contextRefreshInProgress=NO;
    }
    _operationTrigger=trigger;
    _operationEvent=axs_cachekeeper_operation_begin(_operationHistory,trigger,_contextGeneration,_installationGeneration,refreshing);
    return _operationEvent;
}
- (NSUInteger)beginOperationRefreshWithTrigger:(NSString *)trigger {
    if (!_operationEvent || ![_operationTrigger isEqual:trigger] || _contextRefreshInProgress) [self axs_cachekeeper_begin_event:trigger refreshing:YES];
    else axs_cachekeeper_operation_request(_operationHistory,_operationEvent);
    _contextRefreshInProgress=YES;[self axs_cachekeeper_publish];return _operationEvent;
}
- (void)completeOperationRefresh:(NSUInteger)event applied:(BOOL)applied {
    if (event==_operationEvent) _contextRefreshInProgress=NO;
    axs_cachekeeper_operation_refresh(_operationHistory,event,applied ? @"applied" : @"obsolete");
    if (!applied || event!=_operationEvent || ![_operationTrigger isEqual:@"background"])
        axs_cachekeeper_operation_finish(_operationHistory,event);
    [self axs_cachekeeper_publish];
}
- (NSString *)axs_cachekeeper_block_reason {
    if (_configurationRevoked) return @"notAuthorized";
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
    [self axs_cachekeeper_cancel_queue_reason:[self axs_cachekeeper_block_reason] ?: @"authorizationChanged"];
}
- (void)axs_cachekeeper_cancel_queue_reason:(NSString *)reason {
    for (AxsCacheKeeperWebKitStoreReference *reference in _queue)
        axs_cachekeeper_operation_transition_reason(_operationHistory,reference.actionID,@"skipped",reason,NO);
    if (_preparingAction) axs_cachekeeper_operation_transition_reason(_operationHistory,_preparingAction,@"skipped",reason,NO);
    _preparingAction=0;
    _queue=nil;_preparing=NO;_preparingReference=nil;++_preparationID;++_preparationAttempt;
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
    for (NSString *key in @[@"excludedPaths",@"installation",@"process",@"installationCheck"])
        if ([copy[key] conformsToProtocol:@protocol(NSCopying)]) copy[key]=[copy[key] copy];
    BOOL wasPending=_configurationPending;
    _configurationPending=NO;
    BOOL changed=!_context;
    for (NSString *key in @[@"readable",@"valid",@"enabled",@"requested",@"excludedPaths",@"installation",@"process",@"reportWritable"])
        if (![_context[key] isEqual:copy[key]]) changed=YES;
    if (!changed) {
        _context=[copy copy];
        if (wasPending && !_contextRefreshInProgress) {axs_cachekeeper_operation_refresh(_operationHistory,_operationEvent,@"applied");axs_cachekeeper_operation_finish(_operationHistory,_operationEvent);}
        if (_preparing && wasPending) [self axs_cachekeeper_read_preparation];
        else if (!_flight && _queue.count && wasPending) [self axs_cachekeeper_prepare_next];
        else if (!_flight && !_preparing && !_queue.count && [@[@"blocked",@"disabled"] containsObject:_state] &&
            [@[@"authorizationChanged",@"configurationInvalid",@"configurationUnreadable",@"notAuthorized"] containsObject:_reason]) [self axs_cachekeeper_refresh_idle_state];
        [self axs_cachekeeper_publish];return;
    }
    BOOL identityChanged=_context && (![_context[@"installation"] isEqual:copy[@"installation"]] || ![_context[@"process"] isEqual:copy[@"process"]]);
    if (!_context || ![_context[@"installation"] isEqual:copy[@"installation"]]) ++_installationGeneration;
    _context=[copy copy];++_contextGeneration;
    if (!wasPending && !_contextRefreshInProgress) {
        NSUInteger event=[self axs_cachekeeper_begin_event:@"configuration" refreshing:YES];
        axs_cachekeeper_operation_refresh(_operationHistory,event,@"applied");axs_cachekeeper_operation_finish(_operationHistory,event);
    }
    [self axs_cachekeeper_cancel_queue];
    if (identityChanged) [_stores removeAllObjects];
    if (_flight) _reason=@"authorizationChanged";
    else {
        [self axs_cachekeeper_refresh_idle_state];
        if (identityChanged && ![self axs_cachekeeper_block_reason]) {_state=@"stale";_reason=@"installationChanged";}
    }
    if (wasPending && !_contextRefreshInProgress) {axs_cachekeeper_operation_refresh(_operationHistory,_operationEvent,@"applied");axs_cachekeeper_operation_finish(_operationHistory,_operationEvent);}
    [self axs_cachekeeper_publish];
}
- (void)suspendForConfiguration {
    [self suspendForConfigurationWithAuthorization:YES];
}
- (void)suspendForConfigurationWithAuthorization:(BOOL)authorized {
    NSAssert(NSThread.isMainThread,@"WebKit configuration requires main thread");
    _configurationPending=YES;++_preparationID;
    _configurationRevoked=!authorized;
    if (!authorized) {
        ++_contextGeneration;_initialPreparationWaiting=NO;_inheritInitialPreparation=NO;++_initialPreparationID;
        [self axs_cachekeeper_cancel_queue_reason:@"notAuthorized"];
    }
    [self axs_cachekeeper_begin_event:@"configuration" refreshing:YES];
    if (!authorized || ![_reason isEqual:@"foregroundAgain"])
        _reason=authorized ? @"authorizationChanged" : @"notAuthorized";
    if (!_flight) _state=_preparing ? @"queued" : (authorized ? @"blocked" : @"disabled");
    [self axs_cachekeeper_publish];
}
- (BOOL)hasPendingWork { return _flight!=nil || _preparing || _queue.count>0 || _initialPreparationWaiting; }
- (void)rejectRevokedConfiguration {
    NSAssert(NSThread.isMainThread,@"WebKit rejection requires main thread");
    if (!_configurationRevoked) return;
    _configurationPending=NO;[self axs_cachekeeper_cancel_queue_reason:@"notAuthorized"];
    if (!_flight) _state=@"disabled";_reason=@"notAuthorized";[self axs_cachekeeper_publish];
}
- (void)setBackgroundTimeValidation:(BOOL (^)(void))validation {
    NSAssert(NSThread.isMainThread,@"WebKit time validation requires main thread");_backgroundTimeValidation=[validation copy];
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
    AxsCacheKeeperWebKitStoreReference *reference=[AxsCacheKeeperWebKitStoreReference new];reference.store=store;reference.persistent=store.isPersistent;reference.ownerID=++_nextOwner;
    [_stores setObject:reference forKey:store];
    if (!_flight && !_preparing) [self axs_cachekeeper_refresh_idle_state];
    [self axs_cachekeeper_publish];
}
- (void)didBecomeActive {
    NSAssert(NSThread.isMainThread,@"WebKit lifecycle requires main thread");
    NSUInteger event=[self axs_cachekeeper_begin_event:@"foreground" refreshing:NO];axs_cachekeeper_operation_finish(_operationHistory,event);
    _activeSeen=YES;_background=NO;_hasTime=NO;++_foregroundGeneration;
    _initialPreparationWaiting=NO;_initialPreparationExpired=NO;_inheritInitialPreparation=NO;++_initialPreparationID;
    [self axs_cachekeeper_cancel_queue_reason:@"foregroundAgain"];
    _reason=@"foregroundAgain";
    if (!_flight) _state=@"blocked";
    [self checkTimeout];[self axs_cachekeeper_publish];
}
- (void)axs_cachekeeper_expire_initial_preparation {
    if (_initialPreparationWaiting) {
        _initialPreparationWaiting=NO;_initialPreparationExpired=YES;++_initialPreparationID;
        NSUInteger event=[self axs_cachekeeper_begin_event:@"background" refreshing:NO];
        axs_cachekeeper_operation_event_reason(_operationHistory,event,@"deadlineExceeded");
        axs_cachekeeper_operation_finish(_operationHistory,event);
    }
    if (_initialPreparationExpired && !_configurationRevoked) {
        [self axs_cachekeeper_cancel_queue_reason:@"deadlineExceeded"];
        if (!_flight) _state=@"blocked";_reason=@"deadlineExceeded";[self axs_cachekeeper_publish];
    }
}
- (void)axs_cachekeeper_schedule_initial_preparation:(NSUInteger)request after:(NSTimeInterval)delay {
    __weak typeof(self) weakSelf=self;
    _schedule(delay,^{
        void (^check)(void)=^{
            AxsCacheKeeperWebKitCache *self=weakSelf;
            if (!self || !self->_initialPreparationWaiting || self->_initialPreparationID!=request) return;
            NSTimeInterval now=self->_clock ? self->_clock() : NSProcessInfo.processInfo.systemUptime;
            NSTimeInterval remaining=10-(now-self->_initialPreparationStarted);
            if (remaining>0) [self axs_cachekeeper_schedule_initial_preparation:request after:remaining];
            else [self axs_cachekeeper_expire_initial_preparation];
        };
        if (NSThread.isMainThread) check();else dispatch_async(dispatch_get_main_queue(),check);
    });
}
- (void)beginBackgroundPreparation {
    NSAssert(NSThread.isMainThread,@"WebKit initial preparation requires main thread");
    if (_initialPreparationWaiting || _initialPreparationExpired || !_activeSeen || _configurationRevoked) return;
    _background=YES;_initialPreparationWaiting=YES;
    _initialPreparationStarted=_clock ? _clock() : NSProcessInfo.processInfo.systemUptime;
    [self axs_cachekeeper_schedule_initial_preparation:++_initialPreparationID after:10];
}
- (BOOL)backgroundPreparationAllowed {
    NSAssert(NSThread.isMainThread,@"WebKit initial preparation requires main thread");
    NSTimeInterval now=_clock ? _clock() : NSProcessInfo.processInfo.systemUptime;
    if (_initialPreparationWaiting && now-_initialPreparationStarted>=10) [self axs_cachekeeper_expire_initial_preparation];
    if (_initialPreparationExpired) {[self axs_cachekeeper_expire_initial_preparation];return NO;}
    return YES;
}
- (void)didEnterBackgroundWithTime:(BOOL)hasTime {
    NSAssert(NSThread.isMainThread,@"WebKit lifecycle requires main thread");
    if (![self backgroundPreparationAllowed]) return;
    _inheritInitialPreparation=_initialPreparationWaiting;_initialPreparationWaiting=NO;++_initialPreparationID;
    NSDictionary *lastEvent=[[[axs_cachekeeper_operation_snapshot(_operationHistory)[@"processes"] lastObject] objectForKey:@"events"] lastObject];
    if ([_operationTrigger isEqual:@"background"] && [lastEvent[@"state"] isEqual:@"active"] && ![lastEvent[@"refresh"] isEqual:@"requested"])
        _batchEvent=_operationEvent;
    else _batchEvent=[self axs_cachekeeper_begin_event:@"background" refreshing:NO];
    _background=YES;_hasTime=hasTime;
    // A timed-out, non-cancellable call still owns the process-wide slot.
    if (_flight) { _reason=@"inFlight";axs_cachekeeper_operation_finish(_operationHistory,_batchEvent);[self checkTimeout];[self axs_cachekeeper_publish];return; }
    if (!_activeSeen || _lastBackgroundGeneration==_foregroundGeneration) {axs_cachekeeper_operation_finish(_operationHistory,_batchEvent);[self axs_cachekeeper_publish];return;}
    _lastBackgroundGeneration=_foregroundGeneration;
    NSString *blocked=[self axs_cachekeeper_block_reason];
    if (blocked) { axs_cachekeeper_operation_event_reason(_operationHistory,_batchEvent,blocked);axs_cachekeeper_operation_finish(_operationHistory,_batchEvent);[self axs_cachekeeper_refresh_idle_state];[self axs_cachekeeper_publish];return; }
    _submitted=0;_completed=0;_timedOut=NO;
    _queue=[NSMutableArray new];
    for (AxsCacheKeeperWebKitStoreReference *reference in _stores.objectEnumerator.allObjects)
        if (reference.persistent && reference.store) {reference.eventID=_batchEvent;reference.actionID=axs_cachekeeper_operation_action(_operationHistory,_batchEvent,reference.ownerID);[_queue addObject:reference];}
    axs_cachekeeper_operation_finish(_operationHistory,_batchEvent);
    if (!_queue.count) {[self axs_cachekeeper_refresh_idle_state];[self axs_cachekeeper_publish];return;}
    if (!hasTime) {[self axs_cachekeeper_cancel_queue_reason:@"noBackgroundTime"];_state=@"blocked";_reason=@"noBackgroundTime";[self axs_cachekeeper_publish];return;}
    [self axs_cachekeeper_prepare_next];
}
- (void)axs_cachekeeper_prepare_next {
    if (_flight || _preparing || !_queue.count || !_background || !_hasTime) return;
    NSString *blocked=[self axs_cachekeeper_block_reason];
    if (blocked && !(_configurationPending && !_configurationRevoked)) {[self axs_cachekeeper_cancel_queue];[self axs_cachekeeper_refresh_idle_state];[self axs_cachekeeper_publish];return;}
    AxsCacheKeeperWebKitStoreReference *reference=_queue.firstObject;[_queue removeObjectAtIndex:0];
    if (!reference.store) {
        axs_cachekeeper_operation_transition_reason(_operationHistory,reference.actionID,@"skipped",@"storeUnavailable",NO);
        _state=@"blocked";_reason=@"storeUnavailable";[self axs_cachekeeper_publish];[self axs_cachekeeper_prepare_next];return;
    }
    _preparingAction=reference.actionID;_preparingReference=reference;
    _preparing=YES;_preparationStarted=_inheritInitialPreparation ? _initialPreparationStarted : (_clock ? _clock() : NSProcessInfo.processInfo.systemUptime);
    _inheritInitialPreparation=NO;
    NSUInteger attempt=++_preparationAttempt;
    NSTimeInterval now=_clock ? _clock() : NSProcessInfo.processInfo.systemUptime;
    [self axs_cachekeeper_schedule_preparation:attempt after:MAX(0,10-(now-_preparationStarted))];
    _state=@"queued";_reason=_configurationPending ? @"authorizationChanged" : @"none";[self axs_cachekeeper_publish];
    [self axs_cachekeeper_read_preparation];
}
- (void)axs_cachekeeper_schedule_preparation:(NSUInteger)attempt after:(NSTimeInterval)delay {
    __weak typeof(self) weakSelf=self;
    _schedule(delay,^{
        void (^check)(void)=^{
            AxsCacheKeeperWebKitCache *self=weakSelf;
            if (!self || !self->_preparing || self->_preparationAttempt!=attempt) return;
            NSTimeInterval now=self->_clock ? self->_clock() : NSProcessInfo.processInfo.systemUptime;
            NSTimeInterval remaining=10-(now-self->_preparationStarted);
            if (remaining>0) [self axs_cachekeeper_schedule_preparation:attempt after:remaining];
            else {
                [self axs_cachekeeper_cancel_queue_reason:@"deadlineExceeded"];
                self->_state=@"blocked";self->_reason=@"deadlineExceeded";[self axs_cachekeeper_publish];
            }
        };
        if (NSThread.isMainThread) check();else dispatch_async(dispatch_get_main_queue(),check);
    });
}
- (void)axs_cachekeeper_read_preparation {
    if (!_preparing || !_preparingReference || _configurationPending) return;
    AxsCacheKeeperWebKitStoreReference *reference=_preparingReference;
    NSUInteger preparation=++_preparationID,generation=_contextGeneration,foreground=_foregroundGeneration,event=reference.eventID,action=reference.actionID;
    __weak typeof(self) weakSelf=self;
    void (^reply)(NSDictionary *,BOOL)=^(NSDictionary *context,BOOL hasTime) {
        void (^accept)(void)=^{
            AxsCacheKeeperWebKitCache *self=weakSelf;
            if (!self || !self->_preparing || self->_preparationID!=preparation) return;
            NSTimeInterval now=self->_clock ? self->_clock() : NSProcessInfo.processInfo.systemUptime;
            if (now-self->_preparationStarted>=10) {
                [self axs_cachekeeper_cancel_queue_reason:@"deadlineExceeded"];
                self->_state=@"blocked";self->_reason=@"deadlineExceeded";[self axs_cachekeeper_publish];return;
            }
            if (self->_configurationPending) return;
            [self updateContext:context];
            if (!self->_preparing || self->_preparationID!=preparation) return;
            if (self->_contextGeneration!=generation || self->_foregroundGeneration!=foreground || !self->_background || !self->_hasTime || !hasTime) {
                NSString *skipReason=[self axs_cachekeeper_block_reason] ?: ((!self->_hasTime || !hasTime) ? @"noBackgroundTime" : (!self->_background ? @"foregroundAgain" : @"authorizationChanged"));
                axs_cachekeeper_operation_transition_reason(self->_operationHistory,action,@"skipped",skipReason,NO);
                [self axs_cachekeeper_cancel_queue_reason:skipReason];
                if (!self->_flight) {
                    NSString *reason=[self axs_cachekeeper_block_reason];
                    self->_state=@"blocked";self->_reason=reason ?: ((!self->_hasTime || !hasTime) ? @"noBackgroundTime" : (!self->_background ? @"foregroundAgain" : @"authorizationChanged"));
                    [self axs_cachekeeper_publish];
                }
                return;
            }
            id<AxsCacheKeeperWebKitStore> store=reference.store;
            BOOL persistent=store && store.isPersistent;
            if (!self->_preparing || self->_preparationID!=preparation) return;
            if (!persistent) {
                self->_preparingAction=0;self->_preparing=NO;self->_preparingReference=nil;++self->_preparationAttempt;
                axs_cachekeeper_operation_transition_reason(self->_operationHistory,action,@"skipped",@"storeUnavailable",NO);
                self->_state=@"blocked";self->_reason=@"storeUnavailable";[self axs_cachekeeper_publish];[self axs_cachekeeper_prepare_next];return;
            }
            NSString *reason=[self axs_cachekeeper_block_reason];
            if (reason || self->_flight) return;
            if (!self->_preparing || self->_preparationID!=preparation) return;
            BOOL liveTime=self->_backgroundTimeValidation ? self->_backgroundTimeValidation() : hasTime;
            NSTimeInterval submissionNow=self->_clock ? self->_clock() : NSProcessInfo.processInfo.systemUptime;
            if (submissionNow-self->_preparationStarted>=10) {
                [self axs_cachekeeper_cancel_queue_reason:@"deadlineExceeded"];
                self->_state=@"blocked";self->_reason=@"deadlineExceeded";[self axs_cachekeeper_publish];return;
            }
            if (!self->_background || !self->_hasTime || !liveTime || self->_foregroundGeneration!=foreground) {
                NSString *skip=!self->_background ? @"foregroundAgain" : @"noBackgroundTime";
                [self axs_cachekeeper_cancel_queue_reason:skip];self->_state=@"blocked";self->_reason=skip;[self axs_cachekeeper_publish];return;
            }
            if (!self->_preparing || self->_preparationID!=preparation || [self axs_cachekeeper_block_reason]) return;
            self->_preparingAction=0;self->_preparing=NO;self->_preparingReference=nil;++self->_preparationAttempt;
            self->_flight=store;self->_flightContextGeneration=generation;self->_flightForegroundGeneration=foreground;
            self->_flightEvent=event;self->_flightAction=action;
            axs_cachekeeper_operation_transition(self->_operationHistory,action,@"submitted",NO);
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
    BOOL currentAttempt=_flightContextGeneration==_contextGeneration && _flightForegroundGeneration==_foregroundGeneration &&
        _flightEvent==_batchEvent && _background && _hasTime && !_configurationRevoked;
    BOOL sameGeneration=currentAttempt && !_configurationPending && ![self axs_cachekeeper_block_reason];
    axs_cachekeeper_operation_transition(_operationHistory,_flightAction,@"apiCompleted",NO);
    _flight=nil;_completed++;
    if (currentAttempt && _configurationPending) {
        _state=_queue.count ? @"queued" : @"blocked";_reason=@"authorizationChanged";
        [self axs_cachekeeper_prepare_next];
    } else if (sameGeneration) {_state=@"completed";_reason=@"none";}
    else {
        [self axs_cachekeeper_cancel_queue];
        NSString *blocked=[self axs_cachekeeper_block_reason];
        if (blocked) {[self axs_cachekeeper_refresh_idle_state];}
        else if (![_reason isEqual:@"none"]) _state=@"blocked";
        else [self axs_cachekeeper_refresh_idle_state];
    }
    [self axs_cachekeeper_publish];
    if (sameGeneration && _background && _hasTime) [self axs_cachekeeper_prepare_next];
}
- (void)expireBackgroundTime {
    NSAssert(NSThread.isMainThread,@"WebKit expiration requires main thread");
    _hasTime=NO;[self axs_cachekeeper_cancel_queue_reason:@"noBackgroundTime"];
    if (!_flight) _state=@"blocked";
    _reason=@"noBackgroundTime";[self checkTimeout];[self axs_cachekeeper_publish];
}
- (void)checkTimeout {
    NSAssert(NSThread.isMainThread,@"WebKit timeout requires main thread");
    NSTimeInterval now=_clock ? _clock() : NSProcessInfo.processInfo.systemUptime;
    if (_flight && now-_flightStarted>=15 && !_timedOut) {
        _timedOut=YES;_state=@"waitingTimedOut";
        axs_cachekeeper_operation_transition(_operationHistory,_flightAction,@"submitted",YES);
        [self axs_cachekeeper_cancel_queue_reason:@"inFlight"];[self axs_cachekeeper_publish];
    }
}
- (NSDictionary *)receipt {
    NSUInteger persistent=0,nonPersistent=0;
    for (AxsCacheKeeperWebKitStoreReference *reference in _stores.objectEnumerator.allObjects) {
        if (!reference.store) continue;
        if (reference.persistent) persistent++;else nonPersistent++;
    }
    BOOL requested=!_configurationRevoked && axs_cachekeeper_webkit_boolean(_context[@"requested"]) && [_context[@"requested"] boolValue];
    NSMutableDictionary *receipt=[@{@"schemaVersion":@1,@"requested":@(requested),@"timedOut":@(_timedOut),@"state":_state ?: @"disabled",@"reason":_reason ?: @"notAuthorized",
        @"persistentStores":@(persistent),@"nonPersistentStores":@(nonPersistent),@"submitted":@(_submitted),@"completed":@(_completed),@"pending":@(_flight ? 1 : 0),
        @"updated":_updated ?: NSDate.date,@"bytesState":@"notMeasured"} mutableCopy];
    if (_context[@"installationCheck"]) receipt[@"installationCheck"]=axs_cachekeeper_webkit_installation_check(_context[@"installationCheck"]) ?: @{@"state":@"invalid",@"errorCode":@0};
    receipt[@"operationHistory"]=axs_cachekeeper_operation_snapshot(_operationHistory);
    return [receipt copy];
}
@end
