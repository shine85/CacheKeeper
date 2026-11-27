#import <Foundation/Foundation.h>
#import "../AxsCacheKeeperImageCollection.h"
#import "../AxsCacheKeeperImageCacheStatus.h"
static void check(BOOL value,const char *message) {if (!value) {fprintf(stderr,"FAIL: image-collection: %s\n",message);exit(1);}}
static NSDictionary *receipt(NSDictionary *metadata) {
    NSMutableDictionary *value=[@{@"schemaVersion":@1,@"sdk":@"SDWebImage",@"state":@"ready",@"reason":@"none",@"observed":@1,
        @"eligible":@1,@"restricted":@0,@"writesBlocked":@0,@"queued":@0,@"submitted":@0,@"apiCompleted":@0,@"skipped":@0,@"pending":@0,
        @"updated":NSDate.date,@"bytesState":@"notMeasured",@"runtimeInfo":@{@"schemaVersion":@1,@"packageVersion":@"0.7.2-217.1",@"firstObserved":@1}} mutableCopy];
    if (metadata) value[@"imageCollection"]=metadata;return value;
}
int main(int argc,const char **argv) {@autoreleasepool {
    check(argc==2,"isolated folder supplied");NSString *folder=[NSString stringWithUTF8String:argv[1]];
    NSString *status=[folder stringByAppendingPathComponent:@"Status"];
    check([NSFileManager.defaultManager createDirectoryAtPath:status withIntermediateDirectories:YES attributes:nil error:NULL],"create status directory");
    NSDictionary *state=@{@"enabled":@YES,@"mode":@"clean",@"autoDiscover":@NO,@"excludedPaths":@[@"Library/Caches/retained"]};
    NSString *statePath=[folder stringByAppendingPathComponent:@"appEnabled.plist"],*selectionPath=[folder stringByAppendingPathComponent:@"directories.plist"];
    check([@{AxsCacheKeeperImageCollectionBundle:state,@"other.app":@NO} writeToFile:statePath atomically:YES],"save actual base config");
    check([@{AxsCacheKeeperImageCollectionBundle:@[@"Library/Caches"]} writeToFile:selectionPath atomically:YES],"save actual selection");
    NSString *receiptPath=[status stringByAppendingPathComponent:[AxsCacheKeeperImageCollectionBundle stringByAppendingString:@".imagecache.plist"]];
    check([receipt(nil) writeToFile:receiptPath atomically:YES],"save valid actual-format receipt");
    NSData *originalState=[NSData dataWithContentsOfFile:statePath],*originalSelection=[NSData dataWithContentsOfFile:selectionPath];NSError *error=nil;
    AxsCacheKeeperImageCollectionSession *session=[[AxsCacheKeeperImageCollectionSession alloc] initWithFolder:folder sessionID:@"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" error:&error];
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
    check([receipt(effective[@"imageCollection"]) writeToFile:receiptPath atomically:YES],"write host-confirmed restoration receipt");
    check([[session poll:&error][@"state"] isEqual:@"complete"],"only host restoration acknowledgement completes transaction");
    NSDictionary *completed=session.reportProjection;
    check([receipt(nil) writeToFile:receiptPath atomically:YES],"later unrelated global receipt replaces prior host response");
    AxsCacheKeeperImageCollectionSession *completedReopen=[[AxsCacheKeeperImageCollectionSession alloc] initWithFolder:folder sessionID:@"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" error:&error];
    check([[completedReopen poll:&error] isEqual:completed],"completed evidence is immutable after global receipt changes");
    check([[NSData dataWithContentsOfFile:statePath] isEqual:originalState] && [[NSData dataWithContentsOfFile:selectionPath] isEqual:originalSelection],"transaction never writes user config or directories");
    NSDictionary *multiStates=@{AxsCacheKeeperImageCollectionBundle:state,@"com.xiaomi.mihome":state,@"unknown.app":state};
    check([multiStates writeToFile:statePath atomically:YES],"second already-supported module fixture enabled");
    check([receipt(nil) writeToFile:[status stringByAppendingPathComponent:@"com.xiaomi.mihome.imagecache.plist"] atomically:YES],"second module has valid supported-engine receipt");
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
        check([record writeToFile:receiptPath atomically:YES],"save matched expired host acknowledgement");
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
        else check([([reason isEqual:@"receiptInvalid"] ? @{@"invalid":@YES} : raw) writeToFile:receiptPath atomically:YES],"write candidate rejection fixture");
        check([entry availableModules:&error].count==0 && !error,"candidate rejection is a reported result rather than silent error");
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
    printf("PASS: image collection real file transport, overlay isolation, expiry, process binding and restoration\n");
}return 0;}
