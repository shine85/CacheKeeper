#import <Foundation/Foundation.h>
#import "../AxsCacheKeeperImageCollection.h"
#import "../AxsCacheKeeperImageCacheStatus.h"
static void check(BOOL value,const char *message) {if (!value) {fprintf(stderr,"FAIL: image-collection: %s\n",message);exit(1);}}
static BOOL writeReceipt(NSDictionary *value,NSString *path) {
    NSMutableDictionary *pending=nil;BOOL writable=NO;
    if (!axs_cachekeeper_operation_save(value,path,YES,&pending,&writable)) return NO;
    check(!pending && writable && [[NSDictionary dictionaryWithContentsOfFile:path] isEqual:value],"production receipt writer preserves exact fields and fractional date");
    return YES;
}
@interface AxsCacheKeeperImageCollectionSession (TestSaveBoundary)
- (BOOL)axs_save:(NSDictionary *)next expected:(NSDictionary *)expected error:(NSError **)error;
@end
@interface AxsImagePreparationRace : AxsCacheKeeperImageCollectionSession
@property(nonatomic) BOOL holdSave;
@property(nonatomic,strong) dispatch_semaphore_t entered,releaseGate;
@end
@implementation AxsImagePreparationRace
- (BOOL)axs_save:(NSDictionary *)next expected:(NSDictionary *)expected error:(NSError **)error {
    if (self.holdSave) {self.holdSave=NO;dispatch_semaphore_signal(self.entered);check(dispatch_semaphore_wait(self.releaseGate,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0,"release held preparation save");}
    return [super axs_save:next expected:expected error:error];
}
@end
static NSDictionary *receipt(NSDictionary *metadata) {
    NSMutableDictionary *value=[@{@"schemaVersion":@1,@"sdk":@"SDWebImage",@"state":@"ready",@"reason":@"none",@"observed":@1,
        @"eligible":@1,@"restricted":@0,@"writesBlocked":@0,@"queued":@0,@"submitted":@0,@"apiCompleted":@0,@"skipped":@0,@"pending":@0,
        @"updated":NSDate.date,@"bytesState":@"notMeasured",@"runtimeInfo":@{@"schemaVersion":@1,@"packageVersion":@"0.7.2-217.1",@"firstObserved":@1}} mutableCopy];
    if (metadata) value[@"imageCollection"]=metadata;return value;
}
int main(int argc,const char **argv) {@autoreleasepool {
    check(argc==2 || argc==3,"isolated folder supplied");NSString *folder=[NSString stringWithUTF8String:argv[1]];
    NSString *status=[folder stringByAppendingPathComponent:@"Status"];
    check([NSFileManager.defaultManager createDirectoryAtPath:status withIntermediateDirectories:YES attributes:nil error:NULL],"create status directory");
    NSString *precisionPath=[status stringByAppendingPathComponent:@"precision.plist"];
    NSDictionary *precision=@{@"updated":[NSDate dateWithTimeIntervalSince1970:1234567890.75]};
    check([precision writeToFile:precisionPath atomically:YES] &&
        [[NSDictionary dictionaryWithContentsOfFile:precisionPath][@"updated"] timeIntervalSince1970]==1234567890.0,"XML fixture deterministically loses fractional receipt date");
    check(writeReceipt(precision,precisionPath),"actual producer transport retains fractional receipt date");
    printf("PASS: real receipt writer preserves fractional timestamp lost by XML fixture\n");
    NSDictionary *state=@{@"enabled":@YES,@"mode":@"clean",@"autoDiscover":@NO,@"excludedPaths":@[@"Library/Caches/retained"]};
    NSString *statePath=[folder stringByAppendingPathComponent:@"appEnabled.plist"],*selectionPath=[folder stringByAppendingPathComponent:@"directories.plist"];
    check([@{AxsCacheKeeperImageCollectionBundle:state,@"other.app":@NO} writeToFile:statePath atomically:YES],"save actual base config");
    check([@{AxsCacheKeeperImageCollectionBundle:@[@"Library/Caches"]} writeToFile:selectionPath atomically:YES],"save actual selection");
    NSString *receiptPath=[status stringByAppendingPathComponent:[AxsCacheKeeperImageCollectionBundle stringByAppendingString:@".imagecache.plist"]];
    check(writeReceipt(receipt(nil),receiptPath),"save valid actual-format receipt");
    NSData *originalState=[NSData dataWithContentsOfFile:statePath],*originalSelection=[NSData dataWithContentsOfFile:selectionPath];NSError *error=nil;
    AxsCacheKeeperImageCollectionSession *session=[[AxsCacheKeeperImageCollectionSession alloc] initWithFolder:folder sessionID:@"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" error:&error];
    if (argc==3) {
        NSMutableDictionary *old=[receipt(nil) mutableCopy];old[@"updated"]=[NSDate dateWithTimeIntervalSinceNow:-301];
        check(writeReceipt(old,receiptPath),"save expired previously eligible receipt");
        NSArray *found=[session availableModules:&error];
        check(found.count==1 && [found[0][@"state"] isEqual:@"requiresRefresh"],"stale known SDK remains selectable for refresh without execution authority");
        check(![session start:&error] && error && !axs_cachekeeper_image_collection_read(folder,NULL),"stale candidate never publishes executable lease");
        printf("PASS: stale image candidate discovery without execution\n");return 0;
    }
    NSArray *modules=[session availableModules:&error];
    check(modules.count==1 && [modules[0][@"bundle"] isEqual:AxsCacheKeeperImageCollectionBundle],"module selection requires existing eligible enabled receipt");
    AxsCacheKeeperImageCollectionSession *entryReopen=[[AxsCacheKeeperImageCollectionSession alloc] initWithFolder:folder sessionID:@"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" error:&error];
    check([entryReopen.reportProjection[@"preflight"][@"state"] isEqual:@"available"] &&
        [entryReopen.reportProjection[@"preflight"][@"modules"] count]==2,"candidate check and rejection reasons survive reopening before start");
    check([entryReopen.reportProjection[@"preflight"][@"modules"][1][@"reason"] isEqual:@"appDisabled"],"disabled candidate keeps explicit reason");
    NSMutableDictionary *nonJSON=[state mutableCopy];nonJSON[@"unknownDate"]=NSDate.date;
    check([@{AxsCacheKeeperImageCollectionBundle:nonJSON} writeToFile:statePath atomically:YES],"valid plist may contain unknown non-JSON value");
    check(![session start:&error] && error.code==EINVAL,"non-JSON baseline fails explicitly without constructing nil intent");
    entryReopen=[[AxsCacheKeeperImageCollectionSession alloc] initWithFolder:folder sessionID:@"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" error:&error];
    check([entryReopen.reportProjection[@"lastFailure"][@"stage"] isEqual:@"baseline"] &&
        [entryReopen.reportProjection[@"lastFailure"][@"errorCode"] isEqual:@(EINVAL)],"start failure persists independently of page message");
    check([@{AxsCacheKeeperImageCollectionBundle:state,@"other.app":@NO} writeToFile:statePath atomically:YES],"restore supported baseline");
    check([session start:&error] && !error,"real fixed-path receipt and request round trip starts");
    check([session.reportProjection[@"selectedCheck"][@"state"] isEqual:@"available"] &&
        session.reportProjection[@"selectedCheck"][@"checkedAt"] && !session.reportProjection[@"lastFailure"] &&
        [session.reportProjection[@"failureHistory"] count]==1,"successful retry updates current check and preserves timestamped failure history");
    NSDictionary *request=axs_cachekeeper_image_collection_read(folder,&error);check(request!=nil && !error,"runtime reader accepts published dedicated request");
    check(!axs_cachekeeper_read_input([folder stringByAppendingPathComponent:@"imageCollectionRequest.plist"],NULL),"general configuration schema remains closed to dedicated request");
    NSMutableDictionary *base=[@{@"bundle":AxsCacheKeeperImageCollectionBundle,@"valid":@YES,@"appState":state,
        @"selected":@[@"Library/Caches"],@"installation":@"private-in-memory",@"processFirstObserved":@1} mutableCopy];
    NSDictionary *effective=axs_cachekeeper_image_collection_context(base,request,NSDate.date.timeIntervalSince1970);
    check([effective[@"appState"][@"mode"] isEqual:@"prevent"],"image-only lease changes effective mode");
    check([base[@"appState"] isEqual:state] && [effective[@"selected"] isEqual:base[@"selected"]],"base settings and scope are not mutated");
    check([[session poll:&error][@"state"] isEqual:@"awaitingHost"],"request without adopted host acknowledgement is not success");
    NSMutableDictionary *bad=[request mutableCopy];bad[@"step"]=@2;check(!axs_cachekeeper_image_collection_request(bad),"wrong step/phase pair is rejected");
    effective=axs_cachekeeper_image_collection_context(base,request,[request[@"expiresAt"] doubleValue]);
    check([effective[@"imageCollection"][@"disposition"] isEqual:@"expired"] && [effective[@"appState"] isEqual:state],"expiry returns base without keeping prevent overlay");
    base[@"processFirstObserved"]=@2;
    check([axs_cachekeeper_image_collection_context(base,request,NSDate.date.timeIntervalSince1970)[@"imageCollection"][@"disposition"] isEqual:@"unavailable"],"old request cannot activate in a new process");
    base[@"processFirstObserved"]=@1;base[@"appState"]=@{@"enabled":@NO};
    check([axs_cachekeeper_image_collection_context(base,request,NSDate.date.timeIntervalSince1970)[@"imageCollection"][@"disposition"] isEqual:@"configurationChanged"],"base user change revokes lease");
    check([session cancel:&error],"explicit cancellation publishes restore intent");request=axs_cachekeeper_image_collection_read(folder,&error);
    effective=axs_cachekeeper_image_collection_context(base,request,NSDate.date.timeIntervalSince1970);
    check([effective[@"appState"] isEqual:base[@"appState"]] && [effective[@"imageCollection"][@"disposition"] isEqual:@"restored"],"restore adopts latest user state rather than saved enabled value");
    check(writeReceipt(receipt(effective[@"imageCollection"]),receiptPath),"write host-confirmed restoration receipt");
    check([[session poll:&error][@"state"] isEqual:@"complete"],"only host restoration acknowledgement completes transaction");
    NSDictionary *completed=session.reportProjection;
    check(writeReceipt(receipt(nil),receiptPath),"later unrelated global receipt replaces prior host response");
    AxsCacheKeeperImageCollectionSession *completedReopen=[[AxsCacheKeeperImageCollectionSession alloc] initWithFolder:folder sessionID:@"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" error:&error];
    check([[completedReopen poll:&error] isEqual:completed],"completed evidence is immutable after global receipt changes");
    check([[NSData dataWithContentsOfFile:statePath] isEqual:originalState] && [[NSData dataWithContentsOfFile:selectionPath] isEqual:originalSelection],"transaction never writes user config or directories");
    NSDictionary *multiStates=@{AxsCacheKeeperImageCollectionBundle:state,@"com.xiaomi.mihome":state,@"unknown.app":state};
    check([multiStates writeToFile:statePath atomically:YES],"second already-supported module fixture enabled");
    check(writeReceipt(receipt(nil),[status stringByAppendingPathComponent:@"com.xiaomi.mihome.imagecache.plist"]),"second module has valid supported-engine receipt");
    modules=[session availableModules:&error];check(modules.count==2,"same interface offers known image receipts and excludes unknown module");
    check([@{AxsCacheKeeperImageCollectionBundle:state,@"other.app":@NO} writeToFile:statePath atomically:YES],"restore isolated fixture config");
    NSString *sessionPath=[[folder stringByAppendingPathComponent:@"collectionSessions"] stringByAppendingPathComponent:@"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.image.plist"];
    for (NSString *reason in @[@"pendingAction",@"unavailable"]) {
        NSMutableDictionary *document=[[NSDictionary dictionaryWithContentsOfFile:sessionPath] mutableCopy];
        NSMutableDictionary *expired=[document[@"request"] mutableCopy];expired[@"issuedAt"]=@(NSDate.date.timeIntervalSince1970-2);expired[@"expiresAt"]=@(NSDate.date.timeIntervalSince1970-1);
        document[@"request"]=expired;document[@"state"]=@"awaitingHost";
        check([document writeToFile:sessionPath atomically:YES],"write deterministic expired restore fixture");
        NSMutableDictionary *ack=[effective[@"imageCollection"] mutableCopy];ack[@"expiresAt"]=expired[@"expiresAt"];
        if ([reason isEqual:@"unavailable"]) ack[@"disposition"]=@"unavailable";
        NSMutableDictionary *record=[receipt(ack) mutableCopy];
        if ([reason isEqual:@"pendingAction"]) {record[@"queued"]=@1;record[@"submitted"]=@1;record[@"pending"]=@1;record[@"state"]=@"timedOut";}
        check(writeReceipt(record,receiptPath),"save matched expired host acknowledgement");
        AxsCacheKeeperImageCollectionSession *resumed=[[AxsCacheKeeperImageCollectionSession alloc] initWithFolder:folder sessionID:@"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" error:&error];
        check([[resumed poll:&error][@"state"] isEqual:@"restorationUnconfirmed"],"expired restore with pending or unavailable ack is reportable without false restoration");
    }
    NSDictionary *cleanAction=@{@"eventID":@1,@"state":@"apiCompleted",@"cacheEffect":@{@"before":@{@"state":@"complete",@"files":@1},@"after":@{@"state":@"complete",@"files":@0}}};
    NSMutableDictionary *process=[@{@"events":@[@{@"eventID":@1,@"started":@2}],@"actions":@[cleanAction]} mutableCopy];
    NSMutableDictionary *history=[@{@"processes":@[process],@"historyTruncated":@NO} mutableCopy];
    NSDictionary *cleanupReceipt=@{@"imageCollection":@{@"events":@[@1]},@"operationHistory":history};
    check([axs_cachekeeper_image_collection_cleanup(cleanupReceipt,@{@"issuedAt":@1})[@"cleanupState"] isEqual:@"passed"],"all complete cleanup actions retain positive evidence");
    process[@"actions"]=@[cleanAction,@{@"eventID":@1,@"state":@"skipped",@"reason":@"scopeUnverified"}];
    check([axs_cachekeeper_image_collection_cleanup(cleanupReceipt,@{@"issuedAt":@1})[@"cleanupState"] isEqual:@"insufficientEvidence"],"one successful owner cannot hide another skipped owner");
    process[@"actions"]=@[cleanAction];history[@"historyTruncated"]=@YES;
    check([axs_cachekeeper_image_collection_cleanup(cleanupReceipt,@{@"issuedAt":@1})[@"cleanupState"] isEqual:@"insufficientEvidence"],"truncated cleanup history is never complete coverage");
    AxsCacheKeeperImageCollectionSession *entry=[[AxsCacheKeeperImageCollectionSession alloc] initWithFolder:folder sessionID:@"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" error:&error];
    check([entry recordEntry:&error],"entering page persists before user starts a request");
    for (NSString *reason in @[@"receiptMissing",@"receiptInvalid",@"receiptStale",@"noEligibleOwner",@"pendingAction"]) {
        NSMutableDictionary *raw=[receipt(nil) mutableCopy];
        if ([reason isEqual:@"receiptStale"]) raw[@"updated"]=[NSDate dateWithTimeIntervalSinceNow:-301];
        if ([reason isEqual:@"noEligibleOwner"]) {raw[@"eligible"]=@0;raw[@"observed"]=@0;raw[@"state"]=@"notObserved";}
        if ([reason isEqual:@"pendingAction"]) {raw[@"queued"]=@1;raw[@"pending"]=@1;raw[@"state"]=@"queued";}
        if ([reason isEqual:@"receiptMissing"]) check([NSFileManager.defaultManager removeItemAtPath:receiptPath error:&error],"remove only fixture receipt");
        else check(writeReceipt([reason isEqual:@"receiptInvalid"] ? @{@"invalid":@YES} : raw,receiptPath),"write candidate rejection fixture");
        NSUInteger candidates=[entry availableModules:&error].count;
        check(candidates==([@[@"receiptStale",@"pendingAction"] containsObject:reason] ? 1u : 0u) && !error,"only known stale or pending SDK is offered for refresh without execution");
        AxsCacheKeeperImageCollectionSession *opened=[[AxsCacheKeeperImageCollectionSession alloc] initWithFolder:folder sessionID:@"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" error:&error];
        check([opened.reportProjection[@"preflight"][@"modules"][0][@"reason"] isEqual:reason],"specific candidate reason survives process restart");
    }
    NSString *entryPath=[[folder stringByAppendingPathComponent:@"collectionSessions"] stringByAppendingPathComponent:@"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.image.plist"];
    NSString *entryPrior=[entryPath stringByAppendingString:@".prior"];
    NSDictionary *entryBefore=entry.reportProjection;
    check([NSFileManager.defaultManager moveItemAtPath:entryPath toPath:entryPrior error:&error] &&
        [NSFileManager.defaultManager createDirectoryAtPath:entryPath withIntermediateDirectories:NO attributes:nil error:&error],"inject actual entry-decision save failure");
    check(![entry skip:&error] && error && [entry.reportProjection isEqual:entryBefore],"failed skip persistence never changes in-memory decision");
    check([NSFileManager.defaultManager removeItemAtPath:entryPath error:&error] &&
        [NSFileManager.defaultManager moveItemAtPath:entryPrior toPath:entryPath error:&error],"restore entry fixture target");
    check([entry skip:&error],"explicit skip retries after storage repair");
    entry=[[AxsCacheKeeperImageCollectionSession alloc] initWithFolder:folder sessionID:@"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" error:&error];
    check([entry readyForReport] && [entry.reportProjection[@"state"] isEqual:@"skipped"] &&
        [entry.reportProjection[@"verificationState"] isEqual:@"notPerformed"] && entry.reportProjection[@"preflight"],"skip retains candidate evidence without claiming execution");
    AxsCacheKeeperImageCollectionSession *prepared=[[AxsCacheKeeperImageCollectionSession alloc] initWithFolder:folder sessionID:@"cccccccccccccccccccccccccccccccc" error:&error];
    NSMutableDictionary *old=[receipt(nil) mutableCopy];old[@"updated"]=[NSDate dateWithTimeIntervalSinceNow:-601];
    old[@"runtimeInfo"]=@{@"schemaVersion":@1,@"packageVersion":@"0.7.2-221.1",@"firstObserved":@10};
    check(writeReceipt(old,receiptPath),"model full capacity delay with real stale receipt file");
    NSData *priorRequest=[NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:@"imageCollectionRequest.plist"]];
    check([prepared prepareBundle:AxsCacheKeeperImageCollectionBundle error:&error],"known stale SDK can be selected for preparation");
    prepared=[[AxsCacheKeeperImageCollectionSession alloc] initWithFolder:folder sessionID:@"cccccccccccccccccccccccccccccccc" error:&error];
    check([[prepared refreshPreparation:&error][@"state"] isEqual:@"awaitingRefresh"] && ![prepared start:&error],"reopened preparation never starts from expired evidence");
    check([[NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:@"imageCollectionRequest.plist"]] isEqual:priorRequest],"preparation never publishes or replaces a lease");
    NSMutableDictionary *unsupported=[old mutableCopy];unsupported[@"eligible"]=@0;unsupported[@"observed"]=@0;unsupported[@"state"]=@"unsupported";unsupported[@"reason"]=@"unsupportedSDK";
    check(writeReceipt(unsupported,receiptPath),"expired unsupported receipt fixture");
    check([prepared availableModules:&error].count==0 && [[prepared refreshPreparation:&error][@"reason"] isEqual:@"noEligibleOwner"],"staleness cannot disguise unsupported SDK as refreshable");
    NSMutableDictionary *fresh=[receipt(nil) mutableCopy];fresh[@"runtimeInfo"]=@{@"schemaVersion":@1,@"packageVersion":@"0.7.2-221.1",@"firstObserved":@20};
    check(writeReceipt(fresh,receiptPath),"new process publishes current eligible receipt");
    NSDictionary *ready=[prepared refreshPreparation:&error];
    if (![ready[@"state"] isEqual:@"readyToStart"]) fprintf(stderr,"PREPARATION: %s error=%ld document=%s\n",ready.description.UTF8String,(long)error.code,prepared.reportProjection.description.UTF8String);
    check([ready[@"state"] isEqual:@"readyToStart"],"new current producer evidence readies the same selected session");
    check([@{AxsCacheKeeperImageCollectionBundle:@NO} writeToFile:statePath atomically:YES],"user disable after preparation");
    check(![prepared start:&error] && [[prepared refreshPreparation:&error][@"reason"] isEqual:@"appDisabled"],"confirm rechecks current user enable without enabling it");
    check([@{AxsCacheKeeperImageCollectionBundle:state,@"other.app":@NO} writeToFile:statePath atomically:YES],"restore explicitly controlled fixture configuration");
    check([prepared start:&error],"explicit confirmation publishes only after current checks");
    NSDictionary *preparedRequest=axs_cachekeeper_image_collection_read(folder,&error);
    check([preparedRequest[@"processFirstObserved"] isEqual:@20] && [preparedRequest[@"sessionID"] isEqual:@"cccccccccccccccccccccccccccccccc"],"request binds newly checked process rather than historical process");
    AxsCacheKeeperImageCollectionSession *newer=[[AxsCacheKeeperImageCollectionSession alloc] initWithFolder:folder sessionID:@"cccccccccccccccccccccccccccccccc" error:&error];
    check([newer cancel:&error],"newer page publishes restore request");
    NSData *restoreBytes=[NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:@"imageCollectionRequest.plist"]];
    check(![prepared retryPublishing:&error] && error.code==ESTALE &&
        [[NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:@"imageCollectionRequest.plist"]] isEqual:restoreBytes],"stale retry rejects before overwriting newer restore request");
    check([[NSData dataWithContentsOfFile:statePath] isEqual:originalState] && [[NSData dataWithContentsOfFile:selectionPath] isEqual:originalSelection],"preparation and start never write original settings");
    printf("PASS: image preparation stale selection, refreshed process binding and explicit execution\n");
    for (NSString *decision in @[@"skip",@"replace"]) {
        NSString *identifier=[decision isEqual:@"skip"] ? @"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" : @"ffffffffffffffffffffffffffffffff";
        AxsImagePreparationRace *race=[[AxsImagePreparationRace alloc] initWithFolder:folder sessionID:identifier error:&error];
        check(writeReceipt(old,receiptPath) && [race prepareBundle:AxsCacheKeeperImageCollectionBundle error:&error],"race starts with persisted stale preparation");
        fresh[@"updated"]=NSDate.date;check(writeReceipt(fresh,receiptPath),"race has refreshed selected evidence");
        race.entered=dispatch_semaphore_create(0);race.releaseGate=dispatch_semaphore_create(0);race.holdSave=YES;
        dispatch_semaphore_t finished=dispatch_semaphore_create(0);__block NSDictionary *late=nil;__block NSError *lateError=nil;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{late=[race refreshPreparation:&lateError];dispatch_semaphore_signal(finished);});
        check(dispatch_semaphore_wait(race.entered,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0,"old refresh reached actual persistence boundary");
        AxsCacheKeeperImageCollectionSession *other=[[AxsCacheKeeperImageCollectionSession alloc] initWithFolder:folder sessionID:identifier error:&error];
        if ([decision isEqual:@"skip"]) check([other skip:&error],"other page persists skip while old refresh waits");
        else {check([multiStates writeToFile:statePath atomically:YES],"other candidate enabled fixture");check([other prepareBundle:@"com.xiaomi.mihome" error:&error],"other page replaces selected preparation");}
        dispatch_semaphore_signal(race.releaseGate);check(dispatch_semaphore_wait(finished,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0,"old refresh completes without deadlock");
        check(!late && lateError.code==ESTALE,"stale preparation snapshot cannot overwrite current decision");
        other=[[AxsCacheKeeperImageCollectionSession alloc] initWithFolder:folder sessionID:identifier error:&error];
        check([decision isEqual:@"skip"] ? [other.reportProjection[@"state"] isEqual:@"skipped"] : [other.reportProjection[@"preparation"][@"bundle"] isEqual:@"com.xiaomi.mihome"],"new decision remains durable after old refresh resumes");
        check([@{AxsCacheKeeperImageCollectionBundle:state,@"other.app":@NO} writeToFile:statePath atomically:YES],"restore race fixture configuration");
    }
    printf("PASS: preparation concurrent skip and replacement preserve latest durable decision\n");
    printf("PASS: image collection real file transport, overlay isolation, expiry, process binding and restoration\n");
}return 0;}
