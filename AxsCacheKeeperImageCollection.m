#import "AxsCacheKeeperImageCollection.h"
#import "AxsCacheKeeperImageCacheStatus.h"
#include <errno.h>
#include <notify.h>

static NSString *AxsImageCollectionID(void) {return [NSUUID.UUID.UUIDString.lowercaseString stringByReplacingOccurrencesOfString:@"-" withString:@""];}
static BOOL AxsImageCollectionError(NSError **error,NSInteger code) {if (error) *error=[NSError errorWithDomain:@"CacheKeeper.ImageCollection" code:code userInfo:nil];return NO;}
static id AxsImageCollectionJSON(id value) {
    if ([value isKindOfClass:NSDate.class]) return @([value timeIntervalSince1970]);
    if ([value isKindOfClass:NSArray.class]) {NSMutableArray *out=[NSMutableArray new];for (id item in value) [out addObject:AxsImageCollectionJSON(item)];return out;}
    if ([value isKindOfClass:NSDictionary.class]) {NSMutableDictionary *out=[NSMutableDictionary new];for (NSString *key in value) out[key]=AxsImageCollectionJSON(value[key]);return out;}
    return value;
}
static NSDictionary *AxsImageCollectionExportReceipt(NSDictionary *raw) {
    NSDictionary *projected=axs_cachekeeper_image_cache_projection(raw);
    return projected ? AxsImageCollectionJSON(projected) : nil;
}
static BOOL AxsImageCollectionNumber(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value)!=CFBooleanGetTypeID() && isfinite([value doubleValue]);
}
static BOOL AxsImageCollectionFailure(id value) {
    if (![value isKindOfClass:NSDictionary.class] || ![[NSSet setWithArray:[value allKeys]] isSubsetOfSet:
        [NSSet setWithArray:@[@"stage",@"errorCode",@"at",@"bundle",@"reason"]]]) return NO;
    return
        [@[@"configurationRead",@"candidate",@"baseline",@"publication"] containsObject:value[@"stage"]] &&
        AxsImageCollectionNumber(value[@"errorCode"]) && AxsImageCollectionNumber(value[@"at"]) &&
        (!value[@"bundle"] || axs_cachekeeper_bundle_id(value[@"bundle"])) &&
        (!value[@"reason"] || [value[@"reason"] isKindOfClass:NSString.class]);
}
static BOOL AxsImageCollectionCandidate(id value) {
    if (![value isKindOfClass:NSDictionary.class] || !axs_cachekeeper_bundle_id(value[@"bundle"]) ||
        ![@[@"available",@"unavailable"] containsObject:value[@"state"]] ||
        ![@[@"none",@"configurationInvalid",@"appDisabled",@"receiptMissing",@"receiptReadFailed",@"receiptInvalid",@"receiptFromFuture",@"receiptStale",@"noEligibleOwner",@"pendingAction"] containsObject:value[@"reason"]]) return NO;
    NSSet *allowed=[NSSet setWithArray:@[@"bundle",@"state",@"reason",@"errorCode",@"checkedAt",@"sourceUpdated",@"eligible",@"pending",@"hostVersion",@"hostReason"]];
    if (![[NSSet setWithArray:[value allKeys]] isSubsetOfSet:allowed] ||
        ([value[@"state"] isEqual:@"available"] != [value[@"reason"] isEqual:@"none"])) return NO;
    for (NSString *key in @[@"errorCode",@"checkedAt",@"sourceUpdated",@"eligible",@"pending"]) if (value[key] && !AxsImageCollectionNumber(value[key])) return NO;
    for (NSString *key in @[@"hostVersion",@"hostReason"]) if (value[key] && ![value[key] isKindOfClass:NSString.class]) return NO;
    return YES;
}
static BOOL AxsImageCollectionEntryEvidence(NSDictionary *document) {
    NSDictionary *entry=document[@"entry"],*decision=document[@"decision"],*preflight=document[@"preflight"];
    if (entry && (![entry isKindOfClass:NSDictionary.class] || entry.count!=2 || ![entry[@"state"] isEqual:@"entered"] || !AxsImageCollectionNumber(entry[@"at"]))) return NO;
    if (decision && (![decision isKindOfClass:NSDictionary.class] || !AxsImageCollectionNumber(decision[@"at"]) ||
        !(([decision[@"state"] isEqual:@"execute"] && decision.count==2) ||
          ([decision[@"state"] isEqual:@"explicitSkip"] && decision.count==3 && [decision[@"reason"] isEqual:@"userSkipped"])))) return NO;
    if (preflight) {
        if (![preflight isKindOfClass:NSDictionary.class] || preflight.count!=3 ||
            ![@[@"available",@"noCandidate"] containsObject:preflight[@"state"]] || !AxsImageCollectionNumber(preflight[@"at"]) ||
            ![preflight[@"modules"] isKindOfClass:NSArray.class] || [preflight[@"modules"] count]>4096) return NO;
        for (id row in preflight[@"modules"]) if (!AxsImageCollectionCandidate(row)) return NO;
    }
    if (document[@"selectedCheck"] && !AxsImageCollectionCandidate(document[@"selectedCheck"])) return NO;
    if (document[@"lastFailure"] && !AxsImageCollectionFailure(document[@"lastFailure"])) return NO;
    if (document[@"failureHistory"]) {
        if (![document[@"failureHistory"] isKindOfClass:NSArray.class] || [document[@"failureHistory"] count]>16) return NO;
        for (id row in document[@"failureHistory"]) if (!AxsImageCollectionFailure(row)) return NO;
    }
    return !document[@"failuresOmitted"] || axs_cachekeeper_capacity_number(document[@"failuresOmitted"]);
}
NSDictionary *axs_cachekeeper_image_collection_cleanup(NSDictionary *receipt,NSDictionary *request) {
    NSMutableDictionary *result=[NSMutableDictionary new];
            BOOL cleaned=NO,complete=YES;NSUInteger actions=0,positive=0;
            NSDictionary *history=receipt[@"operationHistory"];
            if (![history isKindOfClass:NSDictionary.class] || [history[@"historyTruncated"] boolValue] || [history[@"historyRejected"] boolValue]) complete=NO;
            for (NSDictionary *process in receipt[@"operationHistory"][@"processes"]) {
                if (process!=[receipt[@"operationHistory"][@"processes"] lastObject]) continue;
                NSMutableSet *ids=[NSMutableSet new];
                for (NSDictionary *item in process[@"events"]) if ([receipt[@"imageCollection"][@"events"] containsObject:item[@"eventID"]] &&
                    [item[@"started"] doubleValue]>=[request[@"issuedAt"] doubleValue]) [ids addObject:item[@"eventID"]];
                if (![[NSSet setWithArray:receipt[@"imageCollection"][@"events"]] isSubsetOfSet:ids]) complete=NO;
                for (NSDictionary *action in process[@"actions"]) if ([ids containsObject:action[@"eventID"]]) {
                    actions++;
                    BOOL full=[action[@"state"] isEqual:@"apiCompleted"] &&
                        [action[@"cacheEffect"][@"before"][@"state"] isEqual:@"complete"] && [action[@"cacheEffect"][@"after"][@"state"] isEqual:@"complete"] &&
                        [action[@"cacheEffect"][@"after"][@"files"] unsignedIntegerValue]==0;
                    if (!full) complete=NO;
                    if (full && [action[@"cacheEffect"][@"before"][@"files"] unsignedIntegerValue]>0) positive++;
                }
            }
            cleaned=complete && actions>0 && positive>0;
            result[@"cleanupState"]=cleaned ? @"passed" : @"insufficientEvidence";
            result[@"cleanupActions"]=@(actions);result[@"cleanupPositiveActions"]=@(positive);result[@"cleanupCoverageComplete"]=@(complete && actions>0);
    return result;
}
@interface AxsCacheKeeperImageCollectionSession ()
@property(nonatomic,copy) NSString *folder,*path,*sessionID;
@property(nonatomic,strong) NSMutableDictionary *document;
@end
@implementation AxsCacheKeeperImageCollectionSession
- (instancetype)initWithFolder:(NSString *)folder sessionID:(NSString *)identifier error:(NSError **)error {
    if (error) *error=nil;
    if (![folder isKindOfClass:NSString.class] || !folder.isAbsolutePath || !axs_cachekeeper_image_collection_id(identifier)) {AxsImageCollectionError(error,EINVAL);return nil;}
    if (!(self=[super init])) return nil;
    _folder=[folder copy];_sessionID=[identifier copy];
    NSString *directory=[folder stringByAppendingPathComponent:@"collectionSessions"];
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:error]) return nil;
    _path=[directory stringByAppendingPathComponent:[identifier stringByAppendingString:@".image.plist"]];
    if ([NSFileManager.defaultManager fileExistsAtPath:_path]) {
        NSData *data=[NSData dataWithContentsOfFile:_path options:0 error:error];
        id value=data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainers format:NULL error:error] : nil;
        if (![value isKindOfClass:NSDictionary.class] || ![value[@"sessionID"] isEqual:identifier] ||
            ![value[@"events"] isKindOfClass:NSArray.class] || ![value[@"state"] isKindOfClass:NSString.class] ||
            (value[@"request"] && !axs_cachekeeper_image_collection_request(value[@"request"])) ||
            !AxsImageCollectionEntryEvidence(value)) {AxsImageCollectionError(error,EINVAL);return nil;}
        _document=[value mutableCopy];
    } else {
        _document=[@{@"schemaVersion":@1,@"sessionID":identifier,@"state":@"idle",@"events":[NSMutableArray new]} mutableCopy];
        if (![self axs_save:_document error:error]) return nil;
    }
    return self;
}
- (BOOL)axs_save:(NSDictionary *)next error:(NSError **)error {
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:next format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!data || ![data writeToFile:self.path options:NSDataWritingAtomic error:error]) return NO;
    self.document=[next mutableCopy];return YES;
}
- (BOOL)recordEntry:(NSError **)error {
    if (error) *error=nil;
    if (self.document[@"entry"]) return YES;
    NSMutableDictionary *next=[self.document mutableCopy];
    next[@"entry"]=@{@"state":@"entered",@"at":@(NSDate.date.timeIntervalSince1970)};
    return [self axs_save:next error:error];
}
- (BOOL)readyForReport {
    return [@[@"complete",@"skipped",@"restorationUnconfirmed"] containsObject:self.document[@"state"]];
}
- (BOOL)skip:(NSError **)error {
    if (error) *error=nil;
    if ([self.document[@"state"] isEqual:@"skipped"]) return YES;
    if (![self.document[@"state"] isEqual:@"idle"] || self.document[@"request"]) return AxsImageCollectionError(error,EBUSY);
    NSMutableDictionary *next=[self.document mutableCopy];
    next[@"state"]=@"skipped";next[@"decision"]=@{@"state":@"explicitSkip",@"reason":@"userSkipped",@"at":@(NSDate.date.timeIntervalSince1970)};
    return [self axs_save:next error:error];
}
- (BOOL)axs_failure:(NSError *)failure stage:(NSString *)stage error:(NSError **)error {
    NSError *actual=failure ?: [NSError errorWithDomain:@"CacheKeeper.ImageCollection" code:EIO userInfo:nil];
    NSMutableDictionary *next=[self.document mutableCopy];
    NSMutableDictionary *record=[@{@"stage":stage,@"errorCode":@(actual.code),@"at":@(NSDate.date.timeIntervalSince1970)} mutableCopy];
    if (self.document[@"bundle"]) record[@"bundle"]=self.document[@"bundle"];
    if ([stage isEqual:@"candidate"] && self.document[@"selectedCheck"][@"reason"]) record[@"reason"]=self.document[@"selectedCheck"][@"reason"];
    next[@"lastFailure"]=record;
    NSMutableArray *history=[self.document[@"failureHistory"] mutableCopy] ?: [NSMutableArray new];[history addObject:record];
    if (history.count>16) {[history removeObjectAtIndex:0];next[@"failuresOmitted"]=@([next[@"failuresOmitted"] unsignedIntegerValue]+1);}
    next[@"failureHistory"]=history;
    if (![self axs_save:next error:error]) return NO;
    if (error) *error=[NSError errorWithDomain:actual.domain code:actual.code userInfo:@{@"entryEvidenceSaved":@YES}];return NO;
}
- (NSDictionary *)axs_check:(NSString *)bundle state:(id)state now:(NSTimeInterval)now receipt:(NSDictionary **)output {
    NSString *reason=nil;NSError *failure=nil;NSDictionary *receipt=nil;
    if (!axs_cachekeeper_state_valid(state)) reason=@"configurationInvalid";
    else if (!axs_cachekeeper_app_enabled(state)) reason=@"appDisabled";
    else {
        NSString *directory=[self.folder stringByAppendingPathComponent:@"Status"];
        NSDictionary *raw=axs_cachekeeper_capacity_read_plist(directory,[bundle stringByAppendingString:@".imagecache.plist"],32*1024*1024,&failure);
        receipt=axs_cachekeeper_image_cache_raw_projection(raw);
        if (failure) reason=failure.code==ENOENT ? @"receiptMissing" : @"receiptReadFailed";
        else if (!receipt || !receipt[@"runtimeInfo"]) reason=@"receiptInvalid";
        else {
            NSTimeInterval age=now-[receipt[@"updated"] timeIntervalSince1970];
            if (age<0) reason=@"receiptFromFuture";
            else if (age>AxsCacheKeeperImageCollectionLease) reason=@"receiptStale";
            else if (![receipt[@"eligible"] unsignedIntegerValue]) reason=@"noEligibleOwner";
            else if ([receipt[@"pending"] unsignedIntegerValue]) reason=@"pendingAction";
        }
    }
    NSMutableDictionary *row=[@{@"bundle":bundle,@"checkedAt":@(now),@"state":reason ? @"unavailable" : @"available",@"reason":reason ?: @"none"} mutableCopy];
    if (failure) row[@"errorCode"]=@(failure.code);
    if (receipt) {
        row[@"sourceUpdated"]=@([receipt[@"updated"] timeIntervalSince1970]);
        row[@"eligible"]=receipt[@"eligible"];row[@"pending"]=receipt[@"pending"];
        if (receipt[@"runtimeInfo"][@"packageVersion"]) row[@"hostVersion"]=receipt[@"runtimeInfo"][@"packageVersion"];
        row[@"hostReason"]=receipt[@"reason"];
    }
    if (output) *output=receipt;return row;
}
- (NSDictionary *)axs_base:(NSError **)error {
    NSError *stateError=nil,*selectionError=nil;
    NSDictionary *states=axs_cachekeeper_read_input([self.folder stringByAppendingPathComponent:@"appEnabled.plist"],&stateError);
    NSDictionary *selected=axs_cachekeeper_read_input([self.folder stringByAppendingPathComponent:@"directories.plist"],&selectionError);
    NSString *bundle=self.document[@"bundle"];
    if (stateError || selectionError || !axs_cachekeeper_bundle_id(bundle) || !axs_cachekeeper_state_valid(states[bundle])) {AxsImageCollectionError(error,EINVAL);return nil;}
    return @{@"bundle":bundle,@"appState":states[bundle] ?: @NO,@"selected":selected[bundle] ?: @[]};
}
- (NSDictionary *)axs_receipt:(NSError **)error {
    NSString *directory=[self.folder stringByAppendingPathComponent:@"Status"];
    NSString *bundle=self.document[@"bundle"] ?: self.document[@"request"][@"bundle"];
    if (!axs_cachekeeper_bundle_id(bundle)) {AxsImageCollectionError(error,EINVAL);return nil;}
    NSDictionary *raw=axs_cachekeeper_capacity_read_plist(directory,[bundle stringByAppendingString:@".imagecache.plist"],32*1024*1024,error);
    NSDictionary *receipt=axs_cachekeeper_image_cache_raw_projection(raw);
    if (!receipt && error && !*error) AxsImageCollectionError(error,EAGAIN);
    return receipt;
}
- (BOOL)axs_publish:(NSDictionary *)request error:(NSError **)error {
    NSDictionary *current=axs_cachekeeper_image_collection_read(self.folder,error);
    if (error && *error) return NO;
    if (axs_cachekeeper_image_collection_request(current) && ![current[@"sessionID"] isEqual:self.sessionID] &&
        ![current[@"phase"] isEqual:@"restore"] && [current[@"expiresAt"] doubleValue]>NSDate.date.timeIntervalSince1970)
        return AxsImageCollectionError(error,EBUSY);
    if (!axs_cachekeeper_capacity_atomic_write(request,self.folder,@"imageCollectionRequest.plist",4096,error)) return NO;
    uint32_t status=notify_post(AxsCacheKeeperImageCollectionChanged.UTF8String);
    if (status!=NOTIFY_STATUS_OK) return AxsImageCollectionError(error,EIO);
    NSMutableDictionary *next=[self.document mutableCopy];next[@"publication"]=@"published";
    [next removeObjectForKey:@"lastFailure"];
    return [self axs_save:next error:error];
}
- (BOOL)axs_request_phase:(NSString *)phase step:(NSUInteger)step events:(NSArray *)events error:(NSError **)error {
    NSTimeInterval now=NSDate.date.timeIntervalSince1970;
    NSDictionary *request=@{@"schemaVersion":@1,@"sessionID":self.sessionID,@"requestID":AxsImageCollectionID(),
        @"bundle":self.document[@"bundle"],@"phase":phase,@"step":@(step),@"issuedAt":@(now),
        @"expiresAt":@(now+AxsCacheKeeperImageCollectionLease),@"baselineSHA256":self.document[@"baselineSHA256"],
        @"processFirstObserved":self.document[@"processFirstObserved"]};
    NSMutableDictionary *next=[self.document mutableCopy];next[@"request"]=request;next[@"state"]=@"awaitingHost";next[@"events"]=events;next[@"publication"]=@"pending";
    next[@"decision"]=@{@"state":@"execute",@"at":@(now)};
    [next removeObjectForKey:@"lastFailure"];
    // Persist intent before publishing. A crash can only leave an unacknowledged finite lease.
    if (![self axs_save:next error:error]) return NO;
    NSError *failure=nil;
    if (![self axs_publish:request error:&failure]) return [self axs_failure:failure stage:@"publication" error:error];
    return YES;
}
- (BOOL)start:(NSError **)error {
    return [self startWithBundle:AxsCacheKeeperImageCollectionBundle error:error];
}
- (NSArray<NSDictionary *> *)availableModules:(NSError **)error {
    if (error) *error=nil;
    NSError *failure=nil;
    NSDictionary *states=axs_cachekeeper_read_input([self.folder stringByAppendingPathComponent:@"appEnabled.plist"],&failure);
    if (!states || failure) {[self axs_failure:failure stage:@"configurationRead" error:error];return nil;}
    if (states.count>4096) {[self axs_failure:[NSError errorWithDomain:@"CacheKeeper.ImageCollection" code:EOVERFLOW userInfo:nil] stage:@"configurationRead" error:error];return nil;}
    NSTimeInterval now=NSDate.date.timeIntervalSince1970;
    NSMutableArray *modules=[NSMutableArray new],*checks=[NSMutableArray new];
    for (NSString *bundle in [states.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSDictionary *receipt=nil,*check=[self axs_check:bundle state:states[bundle] now:now receipt:&receipt];[checks addObject:check];
        if (![check[@"state"] isEqual:@"available"]) continue;
        [modules addObject:@{@"bundle":bundle,@"sdk":@"SDWebImage",@"hostVersion":receipt[@"runtimeInfo"][@"packageVersion"],@"state":@"requiresHostAcknowledgement"}];
    }
    if (![self readyForReport]) {
        NSMutableDictionary *next=[self.document mutableCopy];
        next[@"preflight"]=@{@"state":modules.count ? @"available" : @"noCandidate",@"at":@(now),@"modules":checks};
        if (!next[@"entry"]) next[@"entry"]=@{@"state":@"entered",@"at":@(now)};
        if (![self axs_save:next error:error]) return nil;
    }
    return modules;
}
- (BOOL)startWithBundle:(NSString *)bundle error:(NSError **)error {
    @synchronized(AxsCacheKeeperImageCollectionSession.class) {
        if (error) *error=nil;
        if (![self.document[@"state"] isEqual:@"idle"]) return AxsImageCollectionError(error,EALREADY);
        if (!axs_cachekeeper_bundle_id(bundle)) return AxsImageCollectionError(error,EINVAL);
        NSMutableDictionary *selected=[self.document mutableCopy];selected[@"bundle"]=bundle;
        if (![self axs_save:selected error:error]) return NO;
        NSError *failure=nil;
        NSDictionary *base=[self axs_base:&failure];
        if (!base) return [self axs_failure:failure stage:@"configurationRead" error:error];
        NSDictionary *receipt=nil,*check=[self axs_check:bundle state:base[@"appState"] now:NSDate.date.timeIntervalSince1970 receipt:&receipt];
        NSMutableDictionary *checked=[self.document mutableCopy];checked[@"selectedCheck"]=check;
        if (![self axs_save:checked error:error]) return NO;
        if (![check[@"state"] isEqual:@"available"]) {
            return [self axs_failure:[NSError errorWithDomain:@"CacheKeeper.ImageCollection" code:ENOTSUP userInfo:nil] stage:@"candidate" error:error];
        }
        NSString *baseline=axs_cachekeeper_image_collection_baseline(base);
        if (!baseline) return [self axs_failure:[NSError errorWithDomain:@"CacheKeeper.ImageCollection" code:EINVAL userInfo:nil] stage:@"baseline" error:error];
        self.document[@"baselineSHA256"]=baseline;
        self.document[@"processFirstObserved"]=receipt[@"runtimeInfo"][@"firstObserved"];
        return [self axs_request_phase:@"prevent" step:1 events:@[] error:error];
    }
}
- (NSDictionary *)poll:(NSError **)error {
    if (error) *error=nil;
    if ([self.document[@"state"] isEqual:@"complete"]) return self.reportProjection;
    NSDictionary *request=self.document[@"request"];
    if (!request) return self.reportProjection;
    BOOL expired=NSDate.date.timeIntervalSince1970>=[request[@"expiresAt"] doubleValue];
    NSDictionary *receipt=[self axs_receipt:error];
    if (!receipt) {
        if (!expired) return nil;
        if (error) *error=nil;NSMutableDictionary *next=[self.document mutableCopy];
        next[@"state"]=[request[@"phase"] isEqual:@"restore"] ? @"restorationUnconfirmed" : @"interrupted";
        if (![self axs_save:next error:error]) return nil;return self.reportProjection;
    }
    NSDictionary *metadata=receipt[@"imageCollection"];
    if (![metadata[@"sessionID"] isEqual:self.sessionID] || ![metadata[@"requestID"] isEqual:request[@"requestID"]] ||
        ![metadata[@"step"] isEqual:request[@"step"]]) {
        if (expired) {
            NSMutableDictionary *next=[self.document mutableCopy];next[@"state"]=[request[@"phase"] isEqual:@"restore"] ? @"restorationUnconfirmed" : @"interrupted";
            if (![self axs_save:next error:error]) return nil;return self.reportProjection;
        }
        return @{ @"state":@"awaitingHost",@"phase":request[@"phase"] };
    }
    if ([request[@"phase"] isEqual:@"restore"] && expired &&
        (![metadata[@"disposition"] isEqual:@"restored"] || [receipt[@"pending"] unsignedIntegerValue])) {
        NSMutableDictionary *next=[self.document mutableCopy];next[@"state"]=@"restorationUnconfirmed";
        next[@"restoration"]=@{@"state":@"notConfirmed",@"reason":[receipt[@"pending"] unsignedIntegerValue] ? @"pendingAction" : metadata[@"disposition"],
            @"receipt":AxsImageCollectionExportReceipt(receipt)};
        if (![self axs_save:next error:error]) return nil;return self.reportProjection;
    }
    if (![receipt[@"runtimeInfo"][@"firstObserved"] isEqual:self.document[@"processFirstObserved"]] && ![request[@"phase"] isEqual:@"restore"])
        return @{ @"state":@"interrupted",@"reason":@"processChanged",@"phase":request[@"phase"] };
    if ([receipt[@"pending"] unsignedIntegerValue]) return @{ @"state":@"awaitingCompletion",@"phase":request[@"phase"] };
    if ([request[@"phase"] isEqual:@"restore"] && [metadata[@"disposition"] isEqual:@"restored"]) {
        if (![self.document[@"state"] isEqual:@"complete"]) {
            NSMutableDictionary *next=[self.document mutableCopy];next[@"state"]=@"complete";
            next[@"restoration"]=@{@"state":@"hostConfirmed",@"configurationSource":@"currentUserConfiguration",@"restoredAt":@([receipt[@"updated"] timeIntervalSince1970]),
                @"receipt":AxsImageCollectionExportReceipt(receipt)};
            if (![self axs_save:next error:error]) return nil;
        }
        return self.reportProjection;
    }
    if (![metadata[@"disposition"] isEqual:@"applied"] || NSDate.date.timeIntervalSince1970>=[request[@"expiresAt"] doubleValue])
        return @{ @"state":@"interrupted",@"reason":metadata[@"disposition"] ?: @"unavailable",@"phase":request[@"phase"] };
    NSMutableArray *epochs=[NSMutableArray new];
    for (NSDictionary *candidate in receipt[@"writeObservation"][@"epochs"])
        if ([metadata[@"epochs"] containsObject:candidate[@"epoch"]] && [candidate[@"installation"] isEqual:metadata[@"installation"]]) [epochs addObject:candidate];
    if (!epochs.count) return @{ @"state":@"awaitingHost",@"phase":request[@"phase"] };
    if (epochs.count!=[metadata[@"epochs"] count] || [receipt[@"writeObservation"][@"truncated"] boolValue])
        return @{ @"state":@"interrupted",@"reason":@"writerHistoryIncomplete",@"phase":request[@"phase"] };
    if (![request[@"phase"] isEqual:@"disabled"] && ![receipt[@"eligible"] unsignedIntegerValue])
        return @{ @"state":@"interrupted",@"reason":@"noEligibleOwner",@"phase":request[@"phase"] };
    return @{ @"state":@"observing",@"phase":request[@"phase"],@"epochs":epochs,
        @"receipt":receipt,@"request":request };
}
- (BOOL)captureAndAdvance:(NSError **)error {
    @synchronized(AxsCacheKeeperImageCollectionSession.class) {
        if (error) *error=nil;
        NSDictionary *observed=[self poll:error];
        if (![observed[@"state"] isEqual:@"observing"]) return AxsImageCollectionError(error,EAGAIN);
        NSDictionary *request=observed[@"request"],*receipt=observed[@"receipt"];NSArray *epochs=observed[@"epochs"];
        NSMutableDictionary *writers=[NSMutableDictionary new];BOOL passed=YES,triggered=NO,failed=NO;
        for (NSString *writer in @[@"data",@"extended"]) {
            NSUInteger attempts=0,blocked=0,allowed=0;BOOL overflow=NO;
            for (NSDictionary *epoch in epochs) {
                NSDictionary *counts=epoch[writer],*baseline=receipt[@"imageCollection"][@"baselines"][[epoch[@"epoch"] stringValue]][writer];
                for (NSString *key in @[@"nonemptyAttempts",@"nonemptyBlocked",@"nonemptyAllowed"])
                    if ([counts[key] unsignedLongLongValue]<[baseline[key] unsignedLongLongValue]) return AxsImageCollectionError(error,EINVAL);
                attempts+=[counts[@"nonemptyAttempts"] unsignedIntegerValue]-[baseline[@"nonemptyAttempts"] unsignedIntegerValue];
                blocked+=[counts[@"nonemptyBlocked"] unsignedIntegerValue]-[baseline[@"nonemptyBlocked"] unsignedIntegerValue];
                allowed+=[counts[@"nonemptyAllowed"] unsignedIntegerValue]-[baseline[@"nonemptyAllowed"] unsignedIntegerValue];
                overflow|=[counts[@"overflow"] boolValue] || [baseline[@"overflow"] boolValue];
            }
            BOOL prevent=[request[@"phase"] isEqual:@"prevent"];
            BOOL ok=attempts>0 && !overflow && (prevent ? blocked : allowed)==attempts;
            writers[writer]=@{@"state":!attempts ? @"notTriggered" : ok ? @"passed" : @"failed",@"nonemptyAttempts":@(attempts),
                @"nonemptyBlocked":@(blocked),@"nonemptyAllowed":@(allowed)};
            passed &= ok;triggered |= attempts>0;failed |= attempts>0 && !ok;
        }
        NSMutableDictionary *event=[@{@"phase":request[@"phase"],@"requestID":request[@"requestID"],@"step":request[@"step"],
            @"state":failed ? @"failed" : passed ? @"passed" : triggered ? @"insufficientEvidence" : @"notTriggered",
            @"writers":writers,@"writerEvidence":@"hookDecisionSinceAdoption",@"diskPersistence":@"notMeasured",
            @"receipt":AxsImageCollectionExportReceipt(receipt)} mutableCopy];
        if ([request[@"phase"] isEqual:@"clean"]) {
            NSDictionary *cleanup=axs_cachekeeper_image_collection_cleanup(receipt,request);
            [event addEntriesFromDictionary:cleanup];
            BOOL cleaned=[cleanup[@"cleanupState"] isEqual:@"passed"];
            if (!cleaned && [event[@"state"] isEqual:@"passed"]) event[@"state"]=@"insufficientEvidence";
        }
        NSMutableArray *events=[self.document[@"events"] mutableCopy];[events addObject:event];
        NSUInteger step=[request[@"step"] unsignedIntegerValue]+1;
        NSString *phase=step==2 ? @"clean" : step==3 ? @"disabled" : @"restore";
        return [self axs_request_phase:phase step:step events:events error:error];
    }
}
- (BOOL)cancel:(NSError **)error {
    @synchronized(AxsCacheKeeperImageCollectionSession.class) {
        if (error) *error=nil;
        if (!self.document[@"baselineSHA256"]) return AxsImageCollectionError(error,EINVAL);
        if ([self.document[@"request"][@"phase"] isEqual:@"restore"]) return [self retryPublishing:error];
        return [self axs_request_phase:@"restore" step:4 events:self.document[@"events"] error:error];
    }
}
- (BOOL)retryPublishing:(NSError **)error {
    @synchronized(AxsCacheKeeperImageCollectionSession.class) {
        if (error) *error=nil;
        NSDictionary *request=self.document[@"request"];
        if (!request || NSDate.date.timeIntervalSince1970>=[request[@"expiresAt"] doubleValue]) return AxsImageCollectionError(error,ETIMEDOUT);
        return [self axs_publish:request error:error];
    }
}
- (NSDictionary *)reportProjection {
    NSMutableDictionary *report=[@{@"schemaVersion":@1,@"sessionID":self.sessionID,@"module":@"existingSupportedImageSDK",@"moduleVersion":@1,@"bundle":self.document[@"bundle"] ?: @"notSelected",
        @"state":self.document[@"state"],@"phase":self.document[@"request"][@"phase"] ?: @"notStarted",
        @"coverage":@"existingEligibleImageOwnersOnly",@"userConfigurationWritten":@NO,
        @"events":[self.document[@"events"] copy],@"publication":self.document[@"publication"] ?: @"notRequested",
        @"entry":self.document[@"entry"] ?: @{@"state":@"notEntered"},
        @"decision":self.document[@"decision"] ?: @{@"state":@"notChosen"},
        @"verificationState":@"notPerformed",
        @"restoration":self.document[@"restoration"] ?: @{@"state":@"notConfirmed"}} mutableCopy];
    NSArray *events=self.document[@"events"];
    if (events.count) {
        BOOL passed=events.count==3 && [self.document[@"state"] isEqual:@"complete"],failed=NO;
        for (NSDictionary *event in events) {passed &= [event[@"state"] isEqual:@"passed"];failed |= [event[@"state"] isEqual:@"failed"];}
        report[@"verificationState"]=failed ? @"failed" : passed ? @"passed" : @"insufficientEvidence";
    }
    for (NSString *key in @[@"preflight",@"selectedCheck",@"lastFailure",@"failureHistory",@"failuresOmitted"]) if (self.document[key]) report[key]=self.document[key];
    return report;
}
@end
