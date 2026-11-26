// Included by the runtime fixture after the production implementation and fixture helpers.
// Missing production accounting, counting nil, losing prior epochs, or relabeling a
// cancelled write must each fail a literal assertion below.
static NSDictionary *axs_cachekeeper_write_epoch(NSDictionary *observation,NSNumber *identifier) {
    for (NSDictionary *row in observation[@"epochs"]) if ([row[@"epoch"] isEqual:identifier]) return row;
    return nil;
}
#if AXS_CACHEKEEPER_WRITE_PAYLOAD_TESTING
static void axs_cachekeeper_runtime_payload_observation(AxsCacheKeeperImageCache *engine,NSString *home,NSMutableDictionary *context) {
    __attribute__((objc_precise_lifetime)) SDImageCache *owner=[[SDImageCache alloc] initWithNamespace:@"payload-observation"
        diskCacheDirectory:[home stringByAppendingPathComponent:@"Library/Caches"] config:[SDImageCacheConfig new]];
    axs_cachekeeper_runtime_refresh(engine);
    NSData *payload=[@"nonempty" dataUsingEncoding:NSUTF8StringEncoding],*empty=[NSData data];
    [owner.diskCache setData:empty forKey:@"empty"];[owner.diskCache setExtendedData:empty forKey:@"empty"];
    [owner.diskCache setData:payload forKey:@"payload"];[owner.diskCache setExtendedData:payload forKey:@"payload"];
    dispatch_sync(engine.work,^{[engine axs_cachekeeper_publish];});
    NSDictionary *row=[engine.receipt[@"writeObservation"][@"epochs"] lastObject];
    for(NSString *writer in @[@"data",@"extended"]) {
        NSDictionary *counts=row[writer];
        axs_cachekeeper_runtime_require([counts[@"attempts"] isEqual:@2] && [counts[@"blocked"] isEqual:@2] &&
            [counts[@"emptyAttempts"] isEqual:@1] && [counts[@"emptyBlocked"] isEqual:@1] &&
            [counts[@"nonemptyAttempts"] isEqual:@1] && [counts[@"nonemptyBlocked"] isEqual:@1],
            "actual hooks distinguish empty and nonempty payload decisions");
    }
    NSDictionary *frozen=row;NSNumber *identifier=row[@"epoch"];
    context[@"appState"]=@{@"enabled":@NO,@"mode":@"prevent"};axs_cachekeeper_runtime_refresh(engine);
    [owner.diskCache setData:empty forKey:@"empty"];[owner.diskCache setExtendedData:empty forKey:@"empty"];
    [owner.diskCache setData:payload forKey:@"payload"];[owner.diskCache setExtendedData:payload forKey:@"payload"];
    [owner.diskCache setData:nil forKey:@"nil"];[owner.diskCache setExtendedData:nil forKey:@"nil"];
    [owner.diskCache setData:payload forKey:nil];[owner.diskCache setExtendedData:payload forKey:nil];
    dispatch_sync(engine.work,^{[engine axs_cachekeeper_publish];});
    NSDictionary *observation=engine.receipt[@"writeObservation"];row=[observation[@"epochs"] lastObject];
    for(NSString *writer in @[@"data",@"extended"]) {
        NSDictionary *counts=row[writer];
        axs_cachekeeper_runtime_require([counts[@"attempts"] isEqual:@2] && [counts[@"allowed"] isEqual:@2] &&
            [counts[@"emptyAllowed"] isEqual:@1] && [counts[@"nonemptyAllowed"] isEqual:@1] &&
            [counts[@"nonemptyBlocked"] isEqual:@0],"disabled hooks forward exact empty and nonempty attempts while nil is uncounted");
    }
    axs_cachekeeper_runtime_require([axs_cachekeeper_write_epoch(observation,identifier) isEqual:frozen] &&
        axs_cachekeeper_image_cache_raw_projection(engine.receipt)!=nil,"payload attribution preserves prior epochs and the strict receipt");
}
#endif
#if !AXS_CACHEKEEPER_WRITE_OBSERVATION_OLD
void axs_cachekeeper_run_write_status_tests(void);
static void axs_cachekeeper_runtime_pruned_writer(AxsCacheKeeperImageCache *engine,NSString *home,NSMutableDictionary *context) {
    for (NSString *mode in @[@"disabled",@"clean"]) {
        context[@"appState"]=@{@"enabled":@YES,@"mode":@"auto",@"autoDiscover":@YES};
        context[@"installation"]=[@"before-prune-" stringByAppendingString:mode];
        axs_cachekeeper_runtime_refresh(engine);
        __weak SDImageCache *releasedOwner;SDDiskCache *retainedDisk;NSNumber *oldEpoch;
        @autoreleasepool {
            __attribute__((objc_precise_lifetime)) SDImageCache *owner=[[SDImageCache alloc]
                initWithNamespace:[@"pruned-" stringByAppendingString:mode]
                diskCacheDirectory:[home stringByAppendingPathComponent:@"Library/Caches"] config:[SDImageCacheConfig new]];
            axs_cachekeeper_runtime_refresh(engine);retainedDisk=owner.diskCache;releasedOwner=owner;
            [retainedDisk setData:[NSData data] forKey:@"blocked-before-release"];
            [retainedDisk setExtendedData:[NSData data] forKey:@"blocked-before-release"];
            dispatch_sync(engine.work,^{[engine axs_cachekeeper_publish];});
            NSDictionary *row=[engine.receipt[@"writeObservation"][@"epochs"] lastObject];oldEpoch=row[@"epoch"];
            axs_cachekeeper_runtime_require([row[@"data"][@"blocked"] isEqual:@1] && [row[@"extended"][@"blocked"] isEqual:@1],
                "prune fixture starts with a real restricted owner epoch");
            owner=nil;
        }
        axs_cachekeeper_runtime_require(!releasedOwner && retainedDisk,"only the disk remains externally retained before registry pruning");
        AxsCacheKeeperImageBinding *detached=objc_getAssociatedObject(retainedDisk,AxsCacheKeeperImageBindingKey);
        __attribute__((objc_precise_lifetime)) SDImageCache *replacement=[[SDImageCache alloc]
            initWithNamespace:[@"replacement-" stringByAppendingString:mode]
            diskCacheDirectory:[home stringByAppendingPathComponent:@"Library/Caches"] config:[SDImageCacheConfig new]];
        axs_cachekeeper_runtime_require(replacement && ![[engine axs_cachekeeper_bindings] containsObject:detached],
            "registering the replacement actually prunes the released nonpending binding");
        context[@"installation"]=[@"after-prune-" stringByAppendingString:mode];
        context[@"appState"]=@{@"enabled":@([mode isEqual:@"clean"]),@"mode":@"clean",@"autoDiscover":@YES};
        axs_cachekeeper_runtime_refresh(engine);
        NSDictionary *before=engine.receipt[@"writeObservation"],*old=axs_cachekeeper_write_epoch(before,oldEpoch);
        axs_cachekeeper_runtime_require(old!=nil,"old attributed history survives registry pruning");
        unsigned writes=atomic_load(&axs_cachekeeper_runtime_writes),metadata=atomic_load(&axs_cachekeeper_runtime_metadata);
        [retainedDisk setData:[NSData data] forKey:@"detached-forward"];
        [retainedDisk setExtendedData:[NSData data] forKey:@"detached-forward"];
        dispatch_sync(engine.work,^{[engine axs_cachekeeper_publish];});
        NSDictionary *after=engine.receipt[@"writeObservation"];
        axs_cachekeeper_runtime_require([after[@"epochs"] isEqual:before[@"epochs"]] &&
            [after[@"unattributed"][@"data"][@"allowed"] unsignedLongLongValue]==[before[@"unattributed"][@"data"][@"allowed"] unsignedLongLongValue]+1 &&
            [after[@"unattributed"][@"extended"][@"allowed"] unsignedLongLongValue]==[before[@"unattributed"][@"extended"][@"allowed"] unsignedLongLongValue]+1 &&
            [after[@"unattributed"][@"data"][@"blocked"] isEqual:before[@"unattributed"][@"data"][@"blocked"]] &&
            [after[@"unattributed"][@"extended"][@"blocked"] isEqual:before[@"unattributed"][@"extended"][@"blocked"]],
            "pruned disk forwards both writers as unattributed without changing old or new configuration epochs");
        axs_cachekeeper_runtime_require(atomic_load(&axs_cachekeeper_runtime_writes)==writes+1 &&
            atomic_load(&axs_cachekeeper_runtime_metadata)==metadata+1 && axs_cachekeeper_image_cache_raw_projection(engine.receipt),
            "pruned disk preserves both original calls and a valid receipt after mode and installation change");
    }
}
#endif
static void axs_cachekeeper_runtime_write_observation(AxsCacheKeeperImageCache *engine,NSString *home,NSMutableDictionary *context) {
#if AXS_CACHEKEEPER_WRITE_PAYLOAD_TESTING
    axs_cachekeeper_runtime_payload_observation(engine,home,context);return;
#endif
#if AXS_CACHEKEEPER_DISABLED_IDENTITY_TESTING
    __attribute__((objc_precise_lifetime)) SDImageCache *disabledOwner=[[SDImageCache alloc] initWithNamespace:@"disabled-identity"
        diskCacheDirectory:[home stringByAppendingPathComponent:@"Library/Caches"] config:[SDImageCacheConfig new]];
    axs_cachekeeper_runtime_refresh(engine);
    [context setDictionary:axs_cachekeeper_runtime_disabled_context(home)];
    axs_cachekeeper_runtime_refresh(engine);
    [disabledOwner.diskCache setData:[NSData data] forKey:@"disabled"];
    [disabledOwner.diskCache setExtendedData:[NSData data] forKey:@"disabled"];
    dispatch_sync(engine.work,^{[engine axs_cachekeeper_publish];});
    NSDictionary *disabledRow=[engine.receipt[@"writeObservation"][@"epochs"] lastObject];
    axs_cachekeeper_runtime_require([disabledRow[@"enabled"] isEqual:@NO] &&
        [disabledRow[@"data"][@"allowed"] isEqual:@1] && [disabledRow[@"extended"][@"allowed"] isEqual:@1],
        "disabled real-context empty identity retains its own original-call evidence");
    axs_cachekeeper_runtime_require([disabledRow[@"identityState"] isEqual:@"notRevalidated"] &&
        [engine.receipt[@"eligible"] isEqual:@0] && [engine.receipt[@"restricted"] isEqual:@0] &&
        atomic_load(&axs_cachekeeper_runtime_writes)==1 && atomic_load(&axs_cachekeeper_runtime_metadata)==1,
        "disabled identity is explicitly unverified and grants no cleanup or writer restriction");
    axs_cachekeeper_runtime_require(axs_cachekeeper_image_cache_raw_projection(engine.receipt)!=nil,"disabled identity receipt passes full strict projection");
    NSNumber *disabledEpoch=disabledRow[@"epoch"];
    context[@"valid"]=@NO;axs_cachekeeper_runtime_refresh(engine);
    [disabledOwner.diskCache setData:[NSData data] forKey:@"invalid"];
    context[@"valid"]=@YES;context[@"appState"]=@{@"enabled":@YES,@"mode":@"prevent"};
    axs_cachekeeper_runtime_refresh(engine);
    [disabledOwner.diskCache setData:[NSData data] forKey:@"enabled-without-identity"];
    dispatch_sync(engine.work,^{[engine axs_cachekeeper_publish];});
    NSDictionary *after=engine.receipt[@"writeObservation"];
    axs_cachekeeper_runtime_require([after[@"lastEpoch"] isEqual:disabledEpoch] &&
        [axs_cachekeeper_write_epoch(after,disabledEpoch) isEqual:disabledRow] &&
        [after[@"unattributed"][@"data"][@"allowed"] isEqual:@2] &&
        [engine.receipt[@"eligible"] isEqual:@0] && [engine.receipt[@"restricted"] isEqual:@0] &&
        atomic_load(&axs_cachekeeper_runtime_writes)==3,
        "invalid configuration or reenabled empty identity cannot inherit disabled attribution or authorization");
    return;
#endif
    SDDiskCache *disk;NSData *data=[NSData data];
#if !AXS_CACHEKEEPER_WRITE_OBSERVATION_OLD
    axs_cachekeeper_run_write_status_tests();
    __weak id weakOwner;NSDictionary *beforeRelease;
    @autoreleasepool {
#endif
    __attribute__((objc_precise_lifetime)) SDImageCache *owner=[[SDImageCache alloc] initWithNamespace:@"write-observation"
        diskCacheDirectory:[home stringByAppendingPathComponent:@"Library/Caches"] config:[SDImageCacheConfig new]];
    axs_cachekeeper_runtime_refresh(engine);
    disk=owner.diskCache;
    [disk setData:data forKey:@"blocked"];[disk setExtendedData:data forKey:@"blocked"];
    dispatch_sync(engine.work,^{[engine axs_cachekeeper_publish];});
    NSDictionary *observation=engine.receipt[@"writeObservation"],*row=[observation[@"epochs"] lastObject];
    axs_cachekeeper_runtime_require([row[@"data"][@"attempts"] isEqual:@1] && [row[@"data"][@"blocked"] isEqual:@1] &&
        [row[@"extended"][@"attempts"] isEqual:@1] && [row[@"extended"][@"blocked"] isEqual:@1],
        "actual nonnil writers publish separate attempted and blocked evidence");
#if !AXS_CACHEKEEPER_WRITE_OBSERVATION_OLD
    NSNumber *oldEpoch=row[@"epoch"];NSDictionary *frozen=row;
    [disk setData:nil forKey:@"nil"];[disk setData:data forKey:nil];[disk setExtendedData:nil forKey:@"nil"];
    dispatch_sync(engine.work,^{[engine axs_cachekeeper_publish];});
    axs_cachekeeper_runtime_require([axs_cachekeeper_write_epoch(engine.receipt[@"writeObservation"],oldEpoch) isEqual:frozen],"nil arguments preserve SDK semantics without invented attempts");
    axs_cachekeeper_runtime_require(atomic_load(&axs_cachekeeper_runtime_writes)==2 && atomic_load(&axs_cachekeeper_runtime_metadata)==1,"nil calls reach the original writers");
    SDDiskCache *unbound=[SDDiskCache new];[unbound setData:data forKey:@"unbound"];
    dispatch_sync(engine.work,^{[engine axs_cachekeeper_publish];});
    axs_cachekeeper_runtime_require([engine.receipt[@"writeObservation"] isEqual:observation],"unbound disk does not invent observed SDK writes");
    // Suspend the existing identity getter after the hook captured its old epoch.
    // Closing the switch while this check is held must win at the commit boundary.
    dispatch_semaphore_t gateEntered=dispatch_semaphore_create(0),gateRelease=dispatch_semaphore_create(0),gateDone=dispatch_semaphore_create(0);
    axs_cachekeeper_runtime_writer_getter_barrier=^{dispatch_semaphore_signal(gateEntered);dispatch_semaphore_wait(gateRelease,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC));};
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{
        axs_cachekeeper_runtime_hold_writer_getter=YES;[disk setData:data forKey:@"gate-race"];dispatch_semaphore_signal(gateDone);
    });
    axs_cachekeeper_runtime_require(!dispatch_semaphore_wait(gateEntered,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)),"writer identity check is held after old epoch capture");
    context[@"appState"]=@{@"enabled":@NO,@"mode":@"prevent"};axs_cachekeeper_runtime_refresh(engine);
    dispatch_semaphore_signal(gateRelease);axs_cachekeeper_runtime_require(!dispatch_semaphore_wait(gateDone,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)),"revoked writer returns without a lock cycle");
    axs_cachekeeper_runtime_writer_getter_barrier=nil;dispatch_sync(engine.work,^{[engine axs_cachekeeper_publish];});
    axs_cachekeeper_runtime_require([axs_cachekeeper_write_epoch(engine.receipt[@"writeObservation"],oldEpoch) isEqual:frozen] &&
        [engine.receipt[@"writeObservation"][@"unattributed"][@"data"][@"allowed"] isEqual:@1] &&
        [[[engine.receipt[@"writeObservation"] objectForKey:@"epochs"] lastObject][@"data"][@"attempts"] isEqual:@0],
        "refresh during identity validation cannot block or attribute an old attempt to the new epoch");
    context[@"appState"]=@{@"enabled":@YES,@"mode":@"clean",@"autoDiscover":@YES};axs_cachekeeper_runtime_refresh(engine);
    [disk setData:data forKey:@"allowed"];[disk setExtendedData:data forKey:@"allowed"];
    dispatch_sync(engine.work,^{[engine axs_cachekeeper_publish];});
    observation=engine.receipt[@"writeObservation"];row=[observation[@"epochs"] lastObject];
    axs_cachekeeper_runtime_require([row[@"mode"] isEqual:@"clean"] && [row[@"data"][@"allowed"] isEqual:@1] &&
        [row[@"extended"][@"allowed"] isEqual:@1] && [axs_cachekeeper_write_epoch(observation,oldEpoch) isEqual:frozen],"clean forwarding belongs to its own epoch and never rewrites the blocked epoch");
    NSNumber *cleanEpoch=row[@"epoch"];
    // Hold the original, after the production hook chose forwarding. A refresh
    // must complete while the SDK is held, and cannot relabel that old decision.
    dispatch_semaphore_t originalEntered=dispatch_semaphore_create(0),originalRelease=dispatch_semaphore_create(0),originalDone=dispatch_semaphore_create(0);
    axs_cachekeeper_runtime_writer_barrier=^{dispatch_semaphore_signal(originalEntered);dispatch_semaphore_wait(originalRelease,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC));};
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{[disk setData:data forKey:@"old-inflight"];dispatch_semaphore_signal(originalDone);});
    axs_cachekeeper_runtime_require(!dispatch_semaphore_wait(originalEntered,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)),"original writer is held after its forwarding decision");
    axs_cachekeeper_runtime_refresh(engine);
    axs_cachekeeper_runtime_require([axs_cachekeeper_write_epoch(engine.receipt[@"writeObservation"],cleanEpoch)[@"data"][@"allowed"] isEqual:@2],"refresh completes while original SDK is held and keeps the decision in its old epoch");
    dispatch_semaphore_signal(originalRelease);axs_cachekeeper_runtime_require(!dispatch_semaphore_wait(originalDone,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)),"original writer returns outside diagnostic locks");
    axs_cachekeeper_runtime_writer_barrier=nil;
    dispatch_semaphore_t entered=dispatch_semaphore_create(0),release=dispatch_semaphore_create(0),done=dispatch_semaphore_create(0);
    dispatch_async(engine.work,^{dispatch_semaphore_signal(entered);dispatch_semaphore_wait(release,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC));});
    axs_cachekeeper_runtime_require(!dispatch_semaphore_wait(entered,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)),"configuration worker is held");
    context[@"appState"]=@{@"enabled":@NO,@"mode":@"prevent"};
    [engine refreshWithCompletion:^{dispatch_semaphore_signal(done);}];[disk setData:data forKey:@"transition"];
    dispatch_semaphore_signal(release);
    axs_cachekeeper_runtime_require(!dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)),"disabled epoch commits");
    [disk setData:data forKey:@"restored"];[disk setExtendedData:data forKey:@"restored"];
    dispatch_sync(engine.work,^{[engine axs_cachekeeper_publish];});
    observation=engine.receipt[@"writeObservation"];row=[observation[@"epochs"] lastObject];
    axs_cachekeeper_runtime_require(![row[@"enabled"] boolValue] && [row[@"data"][@"allowed"] isEqual:@1] &&
        [row[@"extended"][@"allowed"] isEqual:@1] && [observation[@"unattributed"][@"data"][@"allowed"] isEqual:@2] &&
        [axs_cachekeeper_write_epoch(observation,cleanEpoch)[@"data"][@"allowed"] isEqual:@2],"cancel gap is unassigned and disabled original forwarding has its own evidence");
    axs_cachekeeper_runtime_require(axs_cachekeeper_image_cache_raw_projection(engine.receipt)!=nil,"new evidence obeys complete production receipt projection");
    NSMutableDictionary *legacy=[engine.receipt mutableCopy];[legacy removeObjectForKey:@"writeObservation"];
    axs_cachekeeper_runtime_require(axs_cachekeeper_image_cache_raw_projection(legacy)!=nil,"schema one legacy receipts remain valid without invented evidence");
    dispatch_apply(32,dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^(size_t index){(void)index;
        [disk setData:data forKey:@"concurrent"];[disk setExtendedData:data forKey:@"concurrent"];
    });
    dispatch_sync(engine.work,^{[engine axs_cachekeeper_publish];});
    observation=engine.receipt[@"writeObservation"];row=[observation[@"epochs"] lastObject];
    axs_cachekeeper_runtime_require([row[@"data"][@"attempts"] isEqual:@33] && [row[@"data"][@"allowed"] isEqual:@33] &&
        [row[@"extended"][@"allowed"] isEqual:@33] && [row[@"data"][@"blocked"] isEqual:@0],"concurrent actual writers retain exact decision totals");
    beforeRelease=observation;weakOwner=owner;owner=nil;
    }
    dispatch_sync(engine.work,^{[engine axs_cachekeeper_publish];});
    axs_cachekeeper_runtime_require(!weakOwner && [engine.receipt[@"writeObservation"] isEqual:beforeRelease],"owner release never discards recorded epochs");
    // A stale disk association must not turn a released owner into a successful
    // persistence claim; the SDK forwarding itself remains observable.
    [disk setData:data forKey:@"released-owner"];
    dispatch_sync(engine.work,^{[engine axs_cachekeeper_publish];});
    axs_cachekeeper_runtime_require([[[engine.receipt[@"writeObservation"] objectForKey:@"epochs"] lastObject][@"data"][@"allowed"] isEqual:@34],"retained disk forwarding is counted without retaining the released owner");
    for (NSUInteger index=0;index<20;index++) axs_cachekeeper_runtime_refresh(engine);
    NSDictionary *observation=engine.receipt[@"writeObservation"];
    axs_cachekeeper_runtime_require([observation[@"epochs"] count]==16 && [observation[@"droppedEpochs"] unsignedIntegerValue]>0 &&
        [observation[@"truncated"] boolValue] && axs_cachekeeper_image_cache_raw_projection(engine.receipt)!=nil,"bounded epoch history explicitly reports truncation");
    AxsCacheKeeperImageBinding *binding=objc_getAssociatedObject(disk,AxsCacheKeeperImageBindingKey);
    @synchronized(binding.writeLedger) {
        AxsCacheKeeperWriteObservation *ledger=&binding.writeLedger->observation;
        AxsCacheKeeperWriteCounts *counts=&ledger->epochs[ledger->count-1].writers[0];
        *counts=(AxsCacheKeeperWriteCounts){.attempts=AXS_CACHEKEEPER_WRITE_MAX-1,.allowed=AXS_CACHEKEEPER_WRITE_MAX-1};
    }
    [disk setData:data forKey:@"last-exact"];[disk setData:data forKey:@"overflow"];
    dispatch_sync(engine.work,^{[engine axs_cachekeeper_publish];});
    NSDictionary *row=[engine.receipt[@"writeObservation"][@"epochs"] lastObject];
    axs_cachekeeper_runtime_require([row[@"data"][@"attempts"] unsignedLongLongValue]==AXS_CACHEKEEPER_WRITE_MAX &&
        [row[@"data"][@"allowed"] unsignedLongLongValue]==AXS_CACHEKEEPER_WRITE_MAX && [row[@"data"][@"overflow"] boolValue] &&
        axs_cachekeeper_image_cache_raw_projection(engine.receipt)!=nil,"actual hook freezes exact overflow without impossible totals or wraparound");
    axs_cachekeeper_runtime_pruned_writer(engine,home,context);
#endif
}
