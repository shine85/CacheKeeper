#import "AxsCacheKeeperCapacityService.h"
#import "AxsCacheKeeperCapacityStatus.h"
#import "AxsCacheKeeperCapacity.h"
#include <errno.h>

static NSNumber *AxsCacheKeeperCapacityNow(void) {return @((uint64_t)NSDate.date.timeIntervalSince1970);}
static NSDictionary *AxsCacheKeeperCapacityRequest(NSString *folder) {
    id value=axs_cachekeeper_capacity_read_plist(folder,@"capacityRequest.plist",4096,nil);
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    NSSet *keys=[NSSet setWithArray:[value allKeys]],*required=[NSSet setWithArray:@[@"schemaVersion",@"epoch",@"operation"]];
    if (![keys isEqual:required]) return nil;
    if (!axs_cachekeeper_capacity_number(value[@"schemaVersion"]) || ![value[@"schemaVersion"] isEqual:@1] ||
        !axs_cachekeeper_capacity_epoch(value[@"epoch"]) || ![@[@"start",@"cancel"] containsObject:value[@"operation"]]) return nil;
    return value;
}
@implementation AxsCacheKeeperCapacityService {
    NSString *_folder,*_seenEpoch;
    NSDictionary *(^_provider)(NSError **);
    BOOL (^_writer)(NSDictionary *,NSString *);
    BOOL _loaded,_pending,_partial;
    NSMutableDictionary *_record;
    NSArray<NSDictionary *> *_plans;
    NSMutableArray<NSDictionary *> *_rows;
    AxsCacheKeeperCapacityRoot *_root;
    NSUInteger _index,_nodeCount;
    NSTimeInterval _started,_rootStarted,_published,_retryAt;
    BOOL _aliasChanged;
    NSDictionary *_aliasFailure;
    NSMutableArray<NSDictionary *> *_history;
    uint64_t _historyOmitted;
    NSString *_previousEpoch;
    BOOL _cursorObserved,_allCursorsClosed;
}
- (BOOL)axs_cachekeeper_epoch_matches:(NSDictionary *)request {
    // Only a new start can supersede this observation. A delayed cancellation
    // from another page is not authority over the current epoch.
    return !request || [request[@"operation"] isEqual:@"cancel"] || [request[@"epoch"] isEqual:_record[@"epoch"]];
}
- (instancetype)initWithFolder:(NSString *)folder provider:(NSDictionary *(^)(NSError **))provider writer:(BOOL (^)(NSDictionary *,NSString *))writer {
    if ((self=[super init])) {_folder=[folder copy];_provider=[provider copy];_writer=[writer copy];_history=[NSMutableArray new];}
    return self;
}
- (void)dealloc {[_root stopWithState:@"interrupted"];}
- (void)axs_cachekeeper_abandon {
    [_root stopWithState:@"interrupted"];_root=nil;_record=nil;_plans=nil;_rows=nil;_pending=NO;_nodeCount=0;_retryAt=0;
}
- (void)axs_cachekeeper_remember:(NSDictionary *)record saved:(BOOL)saved supersededBy:(NSString *)replacement {
    if (!record[@"epoch"] || [record[@"state"] isEqual:@"running"]) return;
    NSMutableDictionary *item=[@{@"epoch":record[@"epoch"],@"state":record[@"state"],@"startedAt":record[@"startedAt"],
        @"finishedAt":record[@"finishedAt"],@"resultPublication":saved ? @"saved" : @"notSaved"} mutableCopy];
    if (saved) item[@"publicationObservedAt"]=AxsCacheKeeperCapacityNow();
    if (replacement) item[@"supersededBy"]=replacement;
    if (record[@"lifecycle"]) item[@"lifecycle"]=record[@"lifecycle"];
    if (record[@"failure"]) item[@"failure"]=record[@"failure"];
    NSDictionary *closed=axs_cachekeeper_capacity_terminal(item);if (!closed) return;
    for (NSUInteger i=0;i<_history.count;i++) if ([_history[i][@"epoch"] isEqual:item[@"epoch"]]) {
        // A saved full terminal cannot be downgraded by a later observation.
        if (![_history[i][@"resultPublication"] isEqual:@"saved"]) _history[i]=closed;
        return;
    }
    [_history addObject:closed];
    if (_history.count>16) {[_history removeObjectAtIndex:0];_historyOmitted=MIN(_historyOmitted+1,9007199254740991ULL);}
}
- (void)axs_cachekeeper_supersede:(NSDictionary *)request {
    if ([_record[@"state"] isEqual:@"running"]) [self axs_cachekeeper_finish:@"interrupted"];
    [self axs_cachekeeper_remember:_record saved:NO supersededBy:request[@"epoch"]];
    _previousEpoch=_record[@"epoch"];[self axs_cachekeeper_abandon];
}
- (void)axs_cachekeeper_note_cancel:(NSDictionary *)request {
    if (![request[@"operation"] isEqual:@"cancel"] || ![request[@"epoch"] isEqual:_record[@"epoch"]]) return;
    NSMutableDictionary *lifecycle=[_record[@"lifecycle"] mutableCopy];
    if (lifecycle && !lifecycle[@"cancelObservedAt"]) {lifecycle[@"cancelObservedAt"]=AxsCacheKeeperCapacityNow();_record[@"lifecycle"]=lifecycle;}
}
- (void)axs_cachekeeper_observe_closed_root {
    if (_root) _allCursorsClosed &= _root.openDirectoryCount==0;
}
- (NSMutableDictionary *)axs_cachekeeper_base:(NSString *)epoch {
    return [@{@"schemaVersion":@1,@"epoch":epoch,@"state":@"running",@"sourceSampledAt":@0,
        @"startedAt":AxsCacheKeeperCapacityNow(),@"updatedAt":AxsCacheKeeperCapacityNow(),@"totalRoots":@0,@"completedRoots":@0,@"failedRoots":@0,
        @"excludedBundles":@[@"com.tencent.qy.xin"],@"registry":axs_cachekeeper_registry_inventory_projection(nil),@"roots":@[],@"entries":@[],
        @"deletionAuthorization":@"notGranted",@"physicalUniqueBytes":@"notMeasured",@"reclaimableBytes":@"notMeasured",@"freshness":@"savedObservationUnverified",
        @"measurementWindow":@"nonAtomicTraversal",@"installationMatch":@"notRevalidatedAtExport"} mutableCopy];
}
- (BOOL)axs_cachekeeper_aliases_match:(NSDictionary *)plan failure:(NSDictionary **)failure {
    NSData *expected=plan[@"identity"];
    if (!expected) return NO;
    for (NSURL *url in plan[@"aliases"]) {
        struct stat info;
        if (lstat(url.fileSystemRepresentation,&info)) {
            int code=errno;if (failure) *failure=@{@"stage":@"aliasRecheck",@"reason":@"statFailed",@"errorDomain":@"posix",@"errorCode":@(code)};return NO;
        }
        if (!S_ISDIR(info.st_mode)) {if (failure) *failure=@{@"stage":@"aliasRecheck",@"reason":@"notDirectory",@"errorDomain":@"none"};return NO;}
        uint64_t pair[2]={(uint64_t)info.st_dev,(uint64_t)info.st_ino};
        if (![expected isEqual:[NSData dataWithBytes:pair length:sizeof(pair)]]) {
            if (failure) *failure=@{@"stage":@"aliasRecheck",@"reason":@"identityChanged",@"errorDomain":@"none"};return NO;
        }
    }
    return YES;
}
- (void)axs_cachekeeper_open_root {
    NSDictionary *plan=_plans[_index];BOOL observed=plan[@"identity"]!=nil;
    NSDictionary *aliasFailure=nil;
    _aliasChanged=observed && ![self axs_cachekeeper_aliases_match:plan failure:&aliasFailure];_aliasFailure=aliasFailure;
    // A source without an observed directory identity must not open a later
    // replacement. Preserve the source check instead of creating a nil cursor.
    uint64_t expected[2]={0,0};if (observed) [plan[@"identity"] getBytes:expected length:sizeof(expected)];
    BOOL swiftGroup=[plan[@"owners"] isEqual:@[@"app.swiftgram.ios"]] && [plan[@"roles"] isEqual:@[@"group"]];
    AxsCacheKeeperResourceLayout layout=swiftGroup ? AxsCacheKeeperResourceLayoutSwiftgramGroup : AxsCacheKeeperResourceLayoutPlatform;
    _root=observed && !_aliasChanged ? [[AxsCacheKeeperCapacityRoot alloc] initWithRoot:plan[@"url"] expectedDevice:(dev_t)expected[0] expectedInode:(ino_t)expected[1] layout:layout] :
        [[AxsCacheKeeperCapacityRoot alloc] initWithSourceFailure:observed ? _aliasFailure : plan[@"sourceFailure"]];_rootStarted=NSProcessInfo.processInfo.systemUptime;
    _cursorObserved |= _root.cursorCreated;
    if (observed && !_aliasChanged && ![self axs_cachekeeper_aliases_match:plan failure:&aliasFailure]) {_aliasChanged=YES;_aliasFailure=aliasFailure;}
    if (_aliasChanged) {[_root stopWithState:@"identityChanged"];_partial=YES;_record[@"failure"]=@{@"stage":@"root",@"code":@"identityChanged"};}
}
- (void)axs_cachekeeper_snapshot {
    if (_root) {
        NSDictionary *plan=_plans[_index],*measurement=axs_cachekeeper_capacity_measurement(_root.result);
        if (measurement && _aliasChanged) {
            NSMutableDictionary *changed=[measurement mutableCopy];changed[@"state"]=@"identityChanged";changed[@"sourceFailure"]=_aliasFailure;
            measurement=axs_cachekeeper_capacity_measurement(changed);
        }
        if (measurement) {
            NSDictionary *row=@{@"id":plan[@"id"],@"token":plan[@"token"],@"owners":plan[@"owners"],@"roles":plan[@"roles"],@"measurement":measurement};
            if (_rows.count>_index) _rows[_index]=row;else [_rows addObject:row];
        } else {_partial=YES;[_root stopWithState:@"invalidMetadata"];}
    }
    NSUInteger complete=0,failed=0;
    for (NSDictionary *row in _rows) {
        if ([row[@"measurement"][@"state"] isEqual:@"complete"]) complete++;
        else if (![row[@"measurement"][@"state"] isEqual:@"running"]) failed++;
    }
    _record[@"roots"]=[_rows copy] ?: @[];_record[@"completedRoots"]=@(complete);_record[@"failedRoots"]=@(failed);_record[@"updatedAt"]=AxsCacheKeeperCapacityNow();
}
- (void)axs_cachekeeper_finish:(NSString *)state {
    if (_root && [_root.state isEqual:@"running"]) [_root stopWithState:[@[@"cancelled",@"interrupted"] containsObject:state] ? state : @"timeLimit"];
    [self axs_cachekeeper_snapshot];[self axs_cachekeeper_observe_closed_root];_root=nil;_plans=nil;
    _record[@"state"]=state;_record[@"finishedAt"]=AxsCacheKeeperCapacityNow();_pending=YES;
    NSMutableDictionary *lifecycle=[_record[@"lifecycle"] mutableCopy];
    if (lifecycle && _cursorObserved && _allCursorsClosed) {
        lifecycle[@"cursorClosure"]=@"observedZero";if (!lifecycle[@"cursorClosedAt"]) lifecycle[@"cursorClosedAt"]=AxsCacheKeeperCapacityNow();_record[@"lifecycle"]=lifecycle;
    }
}
- (BOOL)axs_cachekeeper_publish {
    // Re-read at the publication boundary; a provider/scan may have yielded while
    // the client replaced its epoch. No private plan is ever passed to the writer.
    NSDictionary *current=AxsCacheKeeperCapacityRequest(_folder);
    if (current && ![self axs_cachekeeper_epoch_matches:current]) {
        [self axs_cachekeeper_supersede:current];return NO;
    }
    if (![@[@"cancelled",@"interrupted"] containsObject:_record[@"state"]] && [self axs_cachekeeper_cancel_requested:current]) {
        [self axs_cachekeeper_note_cancel:current];
        [self axs_cachekeeper_finish:@"cancelled"];
    }
    _record[@"terminalHistory"]=@{@"limit":@16,@"omittedCount":@(_historyOmitted),@"records":[_history copy]};
    NSDictionary *closed=axs_cachekeeper_capacity_projection(_record);
    if ([closed[@"state"] isEqual:@"invalid"]) {
        NSString *epoch=_record[@"epoch"];NSDictionary *lifecycle=_record[@"lifecycle"];[_root stopWithState:@"invalidMetadata"];[self axs_cachekeeper_observe_closed_root];_root=nil;_plans=nil;_rows=[NSMutableArray new];
        _record=[self axs_cachekeeper_base:epoch];if (lifecycle) _record[@"lifecycle"]=lifecycle;_record[@"terminalHistory"]=@{@"limit":@16,@"omittedCount":@(_historyOmitted),@"records":[_history copy]};
        _record[@"failure"]=@{@"stage":@"publication",@"code":@"resultSchema"};[self axs_cachekeeper_finish:@"unavailable"];
        closed=axs_cachekeeper_capacity_projection(_record);
        if ([closed[@"state"] isEqual:@"invalid"]) {_seenEpoch=epoch;[self axs_cachekeeper_abandon];return NO;}
    }
    NSData *bytes=[NSPropertyListSerialization dataWithPropertyList:closed format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if (!bytes || bytes.length>32*1024*1024) {
        NSString *epoch=_record[@"epoch"];NSDictionary *lifecycle=_record[@"lifecycle"];[_root stopWithState:@"timeLimit"];[self axs_cachekeeper_observe_closed_root];_root=nil;_plans=nil;_rows=[NSMutableArray new];
        _record=[self axs_cachekeeper_base:epoch];if (lifecycle) _record[@"lifecycle"]=lifecycle;_record[@"terminalHistory"]=@{@"limit":@16,@"omittedCount":@(_historyOmitted),@"records":[_history copy]};
        _record[@"failure"]=@{@"stage":@"publication",@"code":@"resultBudget"};[self axs_cachekeeper_finish:@"unavailable"];closed=axs_cachekeeper_capacity_projection(_record);
    }
    NSString *path=[_folder stringByAppendingPathComponent:@"capacityResult.plist"];
    // Serialization can yield long enough for a replacement request; recheck
    // again immediately before the only persistence side effect.
    NSDictionary *latest=AxsCacheKeeperCapacityRequest(_folder);
    if (![self axs_cachekeeper_epoch_matches:latest]) {[self axs_cachekeeper_supersede:latest];return NO;}
    if ([self axs_cachekeeper_cancel_requested:latest] && ![@[@"cancelled",@"interrupted"] containsObject:_record[@"state"]]) {
        [self axs_cachekeeper_note_cancel:latest];
        [self axs_cachekeeper_finish:@"cancelled"];return NO;
    }
    BOOL saved=_writer ? _writer(closed,path) : axs_cachekeeper_capacity_atomic_write(closed,_folder,@"capacityResult.plist",32*1024*1024,nil);
    if (!saved) {
        // Stop advancing after a failed save, close the current cursor, then retry
        // the very same pending snapshot at most once per second.
        _record[@"failure"]=@{@"stage":@"publication",@"code":@"writeFailed"};
        if (_root) {[_root stopWithState:@"readError"];[self axs_cachekeeper_snapshot];[self axs_cachekeeper_observe_closed_root];_root=nil;}
        if ([@[@"running",@"complete"] containsObject:_record[@"state"]]) [self axs_cachekeeper_finish:@"partial"];
        _retryAt=NSProcessInfo.processInfo.systemUptime+1;return NO;
    }
    _pending=NO;_retryAt=0;_published=NSProcessInfo.processInfo.systemUptime;
    if (![_record[@"state"] isEqual:@"running"]) {
        [self axs_cachekeeper_remember:_record saved:YES supersededBy:nil];_previousEpoch=_record[@"epoch"];_seenEpoch=_record[@"epoch"];[self axs_cachekeeper_abandon];
    }
    return YES;
}
- (BOOL)axs_cachekeeper_cancel_requested:(NSDictionary *)request {
    return !request || ([request[@"operation"] isEqual:@"cancel"] && [request[@"epoch"] isEqual:_record[@"epoch"]]);
}
- (NSArray *)axs_cachekeeper_validate_plan:(NSDictionary *)plan registry:(NSDictionary *)registry {
    if (![plan isKindOfClass:NSDictionary.class] || !axs_cachekeeper_capacity_number(plan[@"sourceSampledAt"]) ||
        ![plan[@"sourceSampledAt"] isEqual:registry[@"sourceSampledAt"]] || ![plan[@"state"] isEqual:registry[@"state"]] || ![@[@"available",@"partial"] containsObject:registry[@"state"]] ||
        ![plan[@"roots"] isKindOfClass:NSArray.class] || [plan[@"roots"] count]>36864) return nil;
    NSMutableDictionary *expectedOwners=[NSMutableDictionary new],*expectedRoles=[NSMutableDictionary new];
    for (NSDictionary *entry in registry[@"entries"]) for (NSString *role in @[@"home",@"group",@"extension"]) {
        for (NSString *token in entry[@"relationships"][role][@"tokens"]) {
            if (!expectedOwners[token]) {expectedOwners[token]=[NSMutableSet new];expectedRoles[token]=[NSMutableSet new];}
            [expectedOwners[token] addObject:entry[@"bundle"]];[expectedRoles[token] addObject:role];
        }
    }
    NSMutableSet *tokens=[NSMutableSet new];
    for (id root in plan[@"roots"]) {
        if (![root isKindOfClass:NSDictionary.class] || !axs_cachekeeper_capacity_token(root[@"token"]) || [tokens containsObject:root[@"token"]] ||
            ![root[@"url"] isKindOfClass:NSURL.class] || ![root[@"url"] isFileURL] || ![[root[@"url"] path] hasPrefix:@"/"] ||
            !axs_cachekeeper_capacity_strings(root[@"owners"],YES) || !axs_cachekeeper_capacity_strings(root[@"roles"],NO) ||
            ![[NSSet setWithArray:root[@"owners"]] isEqual:expectedOwners[root[@"token"]]] || ![[NSSet setWithArray:root[@"roles"]] isEqual:expectedRoles[root[@"token"]]]) return nil;
        [tokens addObject:root[@"token"]];
    }
    if (![tokens isEqual:[NSSet setWithArray:expectedOwners.allKeys]]) return nil;
    // Validate every owner/token before any root metadata access. Large plans are
    // explicit partial coverage with no root traversal, not a truncated success.
    if ([plan[@"roots"] count]>4096) {_partial=YES;_record[@"failure"]=@{@"stage":@"source",@"code":@"rootBudget"};return @[];}
    NSMutableDictionary *identities=[NSMutableDictionary new];NSMutableArray *merged=[NSMutableArray new];
    for (NSDictionary *root in plan[@"roots"]) {
        struct stat info;NSString *path=[root[@"url"] path];
        NSData *expected=nil;NSDictionary *sourceFailure=nil;
        if (lstat(path.fileSystemRepresentation,&info)) {
            int code=errno;sourceFailure=@{@"stage":@"sourceStat",@"reason":@"statFailed",@"errorDomain":@"posix",@"errorCode":@(code)};
        } else if (!S_ISDIR(info.st_mode)) sourceFailure=@{@"stage":@"sourceStat",@"reason":@"notDirectory",@"errorDomain":@"none"};
        else {uint64_t pair[2]={(uint64_t)info.st_dev,(uint64_t)info.st_ino};expected=[NSData dataWithBytes:pair length:sizeof(pair)];}
        id identity=expected ?: root[@"token"];
        NSMutableDictionary *existing=identities[identity];
        if (!existing) {existing=[@{@"token":root[@"token"],@"url":root[@"url"],@"owners":[NSMutableSet new],@"roles":[NSMutableSet new],@"aliases":[NSMutableArray new]} mutableCopy];if (expected) existing[@"identity"]=expected;identities[identity]=existing;[merged addObject:existing];}
        if (sourceFailure) existing[@"sourceFailure"]=sourceFailure;
        [existing[@"aliases"] addObject:root[@"url"]];
        [existing[@"owners"] addObjectsFromArray:root[@"owners"]];[existing[@"roles"] addObjectsFromArray:root[@"roles"]];
    }
    NSMutableArray *allowed=[NSMutableArray new];
    for (NSDictionary *root in merged) {
        if ([root[@"owners"] containsObject:@"com.tencent.qy.xin"]) {_partial=YES;continue;}
        NSMutableDictionary *plan=[@{@"id":@(allowed.count+1),@"token":root[@"token"],@"url":root[@"url"],@"aliases":[root[@"aliases"] copy],
            @"owners":[[root[@"owners"] allObjects] sortedArrayUsingSelector:@selector(compare:)],@"roles":[[root[@"roles"] allObjects] sortedArrayUsingSelector:@selector(compare:)]} mutableCopy];
        if (root[@"identity"]) plan[@"identity"]=root[@"identity"];
        if (root[@"sourceFailure"]) plan[@"sourceFailure"]=root[@"sourceFailure"];[allowed addObject:plan];
    }
    return allowed;
}
- (void)axs_cachekeeper_start:(NSDictionary *)request {
    _record=[self axs_cachekeeper_base:request[@"epoch"]];_rows=[NSMutableArray new];_index=0;_nodeCount=0;_partial=NO;_started=NSProcessInfo.processInfo.systemUptime;
    _cursorObserved=NO;_allCursorsClosed=YES;
    NSMutableDictionary *lifecycle=[@{@"acceptedOperation":@"start",@"acceptedAt":AxsCacheKeeperCapacityNow(),@"cursorClosure":@"notObserved"} mutableCopy];
    if (_previousEpoch && ![_previousEpoch isEqual:request[@"epoch"]]) lifecycle[@"previousObservedEpoch"]=_previousEpoch;_record[@"lifecycle"]=lifecycle;
    NSError *error=nil;NSDictionary *plan=_provider ? _provider(&error) : nil;
    if (![plan isKindOfClass:NSDictionary.class]) plan=nil;
    if (plan && (![plan[@"registry"] isKindOfClass:NSDictionary.class] || ![plan[@"roots"] isKindOfClass:NSArray.class])) plan=nil;
    NSDictionary *registry=axs_cachekeeper_registry_inventory_projection(plan[@"registry"]);
    NSData *registryBytes=[NSPropertyListSerialization dataWithPropertyList:registry format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    NSArray *validated=!error && registryBytes.length<=16*1024*1024 ? [self axs_cachekeeper_validate_plan:plan registry:registry] : nil;
    if (!validated) {_record[@"failure"]=@{@"stage":error || !plan ? @"provider" : @"source",@"code":error || !plan ? @"unavailable" : registryBytes.length>16*1024*1024 ? @"sourceBudget" : @"invalidPlan"};[self axs_cachekeeper_finish:@"unavailable"];return;}
    _plans=validated;_partial |= [registry[@"state"] isEqual:@"partial"];
    _record[@"registry"]=registry;_record[@"sourceSampledAt"]=plan[@"sourceSampledAt"];_record[@"totalRoots"]=@(_plans.count);
    NSMutableArray *entries=[NSMutableArray new];
    for (NSDictionary *entry in registry[@"entries"]) {
        NSMutableArray *ids=[NSMutableArray new];BOOL sourcePartial=[registry[@"state"] isEqual:@"partial"],hasRegistration=NO;
        for (NSDictionary *root in _plans) if ([root[@"owners"] containsObject:entry[@"bundle"]]) [ids addObject:root[@"id"]];
        for (NSString *role in @[@"home",@"group",@"extension"]) {
            NSDictionary *relationship=entry[@"relationships"][role];hasRegistration |= [relationship[@"tokens"] count]>0;
            if (![@[@"available",@"notProvided"] containsObject:relationship[@"state"]]) sourcePartial=YES;
        }
        sourcePartial |= hasRegistration && !ids.count;
        NSString *state=[entry[@"bundle"] isEqual:@"com.tencent.qy.xin"] ? @"excluded" : sourcePartial ? @"sourcePartial" : ids.count ? @"registered" : @"noRegisteredRoots";
        if (sourcePartial && ![state isEqual:@"excluded"]) _partial=YES;
        [entries addObject:@{@"bundle":entry[@"bundle"],@"rootIds":ids,@"state":state}];
    }
    _record[@"entries"]=entries;
    if (!_plans.count) {[self axs_cachekeeper_finish:_partial ? @"partial" : @"complete"];return;}
    [self axs_cachekeeper_open_root];
    [self axs_cachekeeper_snapshot];_pending=YES;
}
- (BOOL)tick {
    NSDictionary *request=AxsCacheKeeperCapacityRequest(_folder);
    if (!_loaded) {
        _loaded=YES;NSDictionary *saved=axs_cachekeeper_capacity_read_result([_folder stringByAppendingPathComponent:@"capacityResult.plist"],nil);
        if (saved[@"epoch"]) _seenEpoch=saved[@"epoch"];
        if (saved[@"terminalHistory"]) {[_history addObjectsFromArray:saved[@"terminalHistory"][@"records"]];_historyOmitted=[saved[@"terminalHistory"][@"omittedCount"] unsignedLongLongValue];}
        _previousEpoch=saved[@"epoch"];
        if (saved[@"epoch"] && ![saved[@"state"] isEqual:@"running"]) [self axs_cachekeeper_remember:saved saved:YES supersededBy:nil];
        if ([saved[@"state"] isEqual:@"running"]) {
            _record=[saved mutableCopy];_rows=[NSMutableArray new];
            // A new process did not observe the previous process closing FDs.
            _cursorObserved=NO;_allCursorsClosed=NO;
            _record[@"lifecycle"]=@{@"acceptedOperation":@"recovered",@"acceptedAt":AxsCacheKeeperCapacityNow(),@"cursorClosure":@"notObserved"};
            for (NSDictionary *row in saved[@"roots"]) {
                NSMutableDictionary *copy=[row mutableCopy],*measurement=[row[@"measurement"] mutableCopy];
                if ([measurement[@"state"] isEqual:@"running"]) measurement[@"state"]=@"interrupted";
                copy[@"measurement"]=measurement;[_rows addObject:copy];
            }
            [self axs_cachekeeper_finish:@"interrupted"];
        }
    }
    if (_record && ![self axs_cachekeeper_epoch_matches:request]) [self axs_cachekeeper_supersede:request];
    if (_record && [_record[@"state"] isEqual:@"running"] && [self axs_cachekeeper_cancel_requested:request]) {[self axs_cachekeeper_note_cancel:request];[self axs_cachekeeper_finish:@"cancelled"];}
    if (_pending) {if (NSProcessInfo.processInfo.systemUptime>=_retryAt) [self axs_cachekeeper_publish];return _record!=nil || (request && [request[@"operation"] isEqual:@"start"] && ![request[@"epoch"] isEqual:_seenEpoch]);}
    if (!_record) {
        // Three-key UUID requests carry no ordering proof. Once an observation
        // is saved, an unknown cancel cannot replace it, including cold startup.
        // Before any saved epoch, cancel-before-start may receive an empty ack.
        if (!request || [request[@"epoch"] isEqual:_seenEpoch] || (_seenEpoch && [request[@"operation"] isEqual:@"cancel"])) return NO;
        if ([request[@"operation"] isEqual:@"cancel"]) {
            _record=[self axs_cachekeeper_base:request[@"epoch"]];_rows=[NSMutableArray new];[self axs_cachekeeper_finish:@"cancelled"];
            _record[@"lifecycle"]=@{@"acceptedOperation":@"cancel",@"acceptedAt":AxsCacheKeeperCapacityNow(),@"cancelObservedAt":AxsCacheKeeperCapacityNow(),@"cursorClosure":@"notObserved"};
        } else [self axs_cachekeeper_start:request];
        [self axs_cachekeeper_publish];return _record!=nil || (request && [request[@"operation"] isEqual:@"start"] && ![request[@"epoch"] isEqual:_seenEpoch]);
    }
    NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
    if (now-_started>=1800) {[self axs_cachekeeper_finish:@"partial"];[self axs_cachekeeper_publish];return _record!=nil;}
    if (!_root) {
        if (_index>=_plans.count) {[self axs_cachekeeper_finish:_partial ? @"partial" : @"complete"];[self axs_cachekeeper_publish];return _record!=nil;}
        // Reserve a whole root's enforced maximum so even its in-flight snapshot
        // cannot exceed the service-wide anonymous-node memory budget.
        if (_nodeCount+4096>65536) {_record[@"failure"]=@{@"stage":@"source",@"code":@"nodeBudget"};[self axs_cachekeeper_finish:@"partial"];[self axs_cachekeeper_publish];return _record!=nil;}
        [self axs_cachekeeper_open_root];
    }
    NSDictionary *aliasFailure=nil;
    if (!_aliasChanged && _plans[_index][@"identity"] && ![self axs_cachekeeper_aliases_match:_plans[_index] failure:&aliasFailure]) {_aliasChanged=YES;_aliasFailure=aliasFailure;[_root stopWithState:@"identityChanged"];
        _record[@"failure"]=@{@"stage":@"root",@"code":@"identityChanged"};}
    if (now-_rootStarted>=300) [_root stopWithState:@"timeLimit"];
    else [_root advanceEntries:512 seconds:0.05];
    if (!_aliasChanged && _plans[_index][@"identity"] && ![self axs_cachekeeper_aliases_match:_plans[_index] failure:&aliasFailure]) {_aliasChanged=YES;_aliasFailure=aliasFailure;[_root stopWithState:@"identityChanged"];
        _record[@"failure"]=@{@"stage":@"root",@"code":@"identityChanged"};}
    [self axs_cachekeeper_snapshot];
    BOOL finished=![_root.state isEqual:@"running"];
    if (finished) {_partial |= _aliasChanged || ![_root.state isEqual:@"complete"];_nodeCount+=[_root.result[@"nodes"] count];[self axs_cachekeeper_observe_closed_root];_root=nil;_index++;}
    if (finished && _index>=_plans.count) [self axs_cachekeeper_finish:_partial ? @"partial" : @"complete"];
    else if (now-_published>=1) _pending=YES;
    if (_pending) [self axs_cachekeeper_publish];
    return _record!=nil;
}
@end
