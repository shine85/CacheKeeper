#import <Foundation/Foundation.h>
#import "../AxsCacheKeeperCollectionSession.h"
#import "../AxsCacheKeeperImageCollection.h"
#import "../AxsCacheKeeperCapacityService.h"
#import "../AxsCacheKeeperCapacityStatus.h"

static void CKCheck(BOOL condition,const char *message) {
    if (!condition) {fprintf(stderr,"FAIL: collection-session: %s\n",message);exit(1);}
}
static NSDictionary *CKCapacity(NSString *state) {
    return @{@"state":state,@"epoch":@"capacity-1",@"finishedAt":@2,@"completedRoots":@1,@"totalRoots":@1,@"failedRoots":@0};
}
static NSDictionary *CKHost(void) {
    NSMutableArray *apps=[NSMutableArray new];
    NSDictionary *receipt=@{@"source":@"panelObserved",@"state":@"observed",@"updated":@2,@"transportTrust":@"unauthenticated",
        @"data":@{@"schemaVersion":@1,@"source":@"hostAutomatic",@"transportTrust":@"unauthenticated",@"updated":@2,
        @"runtimeInfo":@{@"schemaVersion":@1,@"packageVersion":@"0.7.2-217.1",@"firstObserved":@1},
        @"existingContainerGatePassed":@YES,@"authorizationAttempted":@NO,@"sharedAccessGranted":@NO,@"authorizationCode":@0,
        @"configurationReadScope":@"appEnabled",@"configurationReadState":@"notPermitted",@"previousPublishState":@"notAttempted",@"previousPublishErrorCode":@0}};
    for (NSString *bundle in @[@"com.ss.iphone.ugc.Aweme",@"com.tencent.mqq",@"com.baidu.netdisk",@"com.360buy.jdmobile",@"app.swiftgram.ios"])
        [apps addObject:@{@"bundle":bundle,@"state":@"observed",@"saveState":@"succeeded",@"transportTrust":@"unauthenticated",
            @"observationFreshness":@"currentRound",@"sourceUpdated":@2,@"multipleResponders":@NO,@"receipt":receipt}];
    return @{@"state":@"complete",@"roundStartedAt":@1,@"transportTrust":@"unauthenticated",
        @"apps":apps};
}
static NSDictionary *CKMeasuredCapacity(NSString *folder,NSString *container,NSUInteger bytes) {
    NSError *error=nil;
    CKCheck([NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:&error],"create capacity service folder");
    CKCheck([NSFileManager.defaultManager createDirectoryAtPath:container withIntermediateDirectories:YES attributes:nil error:&error],"create real capacity container");
    CKCheck([[NSMutableData dataWithLength:bytes] writeToFile:[container stringByAppendingPathComponent:@"private-fixture-name"] atomically:YES],"write real capacity file");
    NSMutableDictionary *roles=[NSMutableDictionary new],*relationships=[NSMutableDictionary new];
    for (NSString *role in @[@"home",@"group",@"extension"]) {
        BOOL group=[role isEqual:@"group"],home=[role isEqual:@"home"];
        roles[role]=@{@"state":@"available",@"observedSourceCount":@1,@"missingSelectorCount":@0,@"notProvidedCount":home ? @1 : @0,
            @"invalidSourceCount":@0,@"invalidAssociationCount":@0,@"ownerMismatchCount":@0,@"unavailableOwnerCount":@0,
            @"truncatedCount":@0,@"registeredURLCount":group ? @1 : @0,@"associationCount":group ? @1 : @0};
        relationships[role]=@{@"state":home ? @"notProvided" : @"available",@"tokens":group ? @[@"resource-1"] : @[]};
    }
    NSMutableDictionary *registry=[@{@"schemaVersion":@1,@"state":@"available",@"sourceState":@"available",@"observedRegistrations":@1,
        @"invalidRegistrationCount":@0,@"truncatedRegistrationCount":@0,@"allRolesUniqueRegisteredURLCount":@1,@"countsAreLowerBounds":@NO,
        @"sourceSampledAt":@100,@"entries":@[@{@"bundle":@"test.collection",@"displayEligible":@YES,@"sourceClassification":@"user",@"relationships":relationships}]} mutableCopy];
    [registry addEntriesFromDictionary:roles];
    NSDictionary *closed=axs_cachekeeper_registry_inventory_projection(registry);
    CKCheck([closed[@"state"] isEqual:@"available"],"real measurement provider registry is valid");
    NSDictionary *plan=@{@"state":@"available",@"sourceSampledAt":@100,@"registry":closed,
        @"roots":@[@{@"token":@"resource-1",@"url":[NSURL fileURLWithPath:container],@"owners":@[@"test.collection"],@"roles":@[@"group"]}]};
    AxsCacheKeeperCapacityService *service=[[AxsCacheKeeperCapacityService alloc] initWithFolder:folder provider:^NSDictionary *(NSError **e) {(void)e;return plan;} writer:nil];
    CKCheck(axs_cachekeeper_capacity_write_request([folder stringByAppendingPathComponent:@"capacityRequest.plist"],NSUUID.UUID.UUIDString,NO,&error),"write capacity request");
    NSUInteger ticks=0;while ([service tick] && ++ticks<1000) {}
    CKCheck(ticks<1000,"real capacity service completes bounded fixture");
    NSDictionary *snapshot=axs_cachekeeper_capacity_read_result([folder stringByAppendingPathComponent:@"capacityResult.plist"],&error);
    CKCheck([snapshot[@"state"] isEqual:@"complete"] && [snapshot[@"roots"][0][@"measurement"][@"logicalBytes"] unsignedIntegerValue]==bytes,"capacity snapshot contains actual file bytes");
    return snapshot;
}
static void CKCapacityRoundTrip(NSString *root) {
    NSString *folder=[root stringByAppendingPathComponent:@"shared-capacity"],*container=[root stringByAppendingPathComponent:@"private-capacity"];
    NSString *path=[root stringByAppendingPathComponent:@"durable-capacity.plist"];
    NSDictionary *a=CKMeasuredCapacity(folder,container,64);NSError *error=nil;
    AxsCacheKeeperCollectionSession *session=[[AxsCacheKeeperCollectionSession alloc] initWithPath:path error:&error];
    CKCheck([session beginPhase:@"hostPreflight" error:&error] && [session finishPhase:@"hostPreflight" result:CKHost() error:&error],"capacity round trip starts host");
    CKCheck([session beginCapacityWithEpoch:a[@"epoch"] error:&error],"capacity request identity is durable before execution");
    NSMutableDictionary *wrong=[a mutableCopy];wrong[@"epoch"]=NSUUID.UUID.UUIDString;
    CKCheck(![session finishCapacityWithSnapshot:wrong error:&error],"wrong epoch is refused at first artifact write");
    NSString *prior=[path stringByAppendingString:@".prior"];
    CKCheck([NSFileManager.defaultManager moveItemAtPath:path toPath:prior error:&error] && [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:NO attributes:nil error:&error],"inject actual capacity artifact save failure");
    NSDictionary *before=session.reportProjection;
    CKCheck(![session finishCapacityWithSnapshot:a error:&error] && [session.reportProjection isEqual:before] && ![session savedCapacitySnapshot:NULL],"capacity bytes and terminal roll back together");
    CKCheck([NSFileManager.defaultManager removeItemAtPath:path error:&error] && [NSFileManager.defaultManager moveItemAtPath:prior toPath:path error:&error],"restore capacity artifact target");
    NSMutableDictionary *withPrivate=[a mutableCopy];withPrivate[@"privatePath"]=container;
    CKCheck([session finishCapacityWithSnapshot:withPrivate error:&error],"complete capacity tree and terminal commit together");
    NSDictionary *saved=[session savedCapacitySnapshot:&error];
    CKCheck([saved[@"roots"] isEqual:a[@"roots"]] && !saved[@"privatePath"],"saved capacity preserves full anonymous tree and drops private extras");
    NSDictionary *b=CKMeasuredCapacity(folder,container,256);
    CKCheck(![a[@"epoch"] isEqual:b[@"epoch"]],"later global result belongs to another epoch");
    AxsCacheKeeperCollectionSession *reopened=[AxsCacheKeeperCollectionSession openSessionAtPath:path error:&error];
    CKCheck([[reopened savedCapacitySnapshot:&error] isEqual:saved],"A snapshot survives B global overwrite and process restart");
    CKCheck([reopened beginPhase:@"diagnostics" error:&error],"resume diagnostics after stored capacity");
    CKCheck([[reopened imageCollectionSession:&error] skip:&error],"explicit skip precedes full retained-source report");
    NSData *data=[reopened saveReport:@{@"apps":@[@{@"bundle":@"com.baidu.netdisk",@"hostObserved":@{@"state":@"available",@"data":@{@"updated":@999}}}],@"capacityMeasurement":b} diagnosticsResult:@{@"state":@"complete",@"missingSources":@[]} error:&error];
    NSDictionary *report=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
    CKCheck([report[@"capacityMeasurement"] isEqual:saved],"export uses full retained A evidence rather than global B or missing placeholder");
    CKCheck([report[@"apps"][0][@"hostObserved"][@"data"][@"updated"] isEqual:@999],"current diagnostic snapshot retains its own source time");
    CKCheck([report[@"guidedCollection"][@"phases"][@"hostPreflight"][@"result"][@"apps"][0][@"receipt"][@"updated"] isEqual:@2],"original host phase survives later global diagnostics separately");
    CKCheck([report[@"sourceManifest"][@"files"] count]==2 && [report[@"sourceObjects"] count]==2,"single report includes both exact redacted stage objects and manifest");
    CKCheck([report[@"guidedCollection"][@"phases"][@"capacity"][@"result"][@"sourceSHA256"] length]==64,"phase records hash of its retained capacity source");
    CKCheck(![[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] containsString:@"private-fixture-name"],"durable capacity export contains no private filename");
    CKCheck([data writeToFile:[root stringByAppendingPathComponent:@"native-capacity-report.json"] atomically:YES],"write actual product report for independent manifest verification");
    NSMutableDictionary *document=[[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy];
    NSMutableDictionary *artifact=[document[@"capacityArtifact"] mutableCopy];artifact[@"sha256"]=@"invalid";document[@"capacityArtifact"]=artifact;
    CKCheck([document writeToFile:path atomically:YES],"write corrupted capacity hash fixture");
    CKCheck([AxsCacheKeeperCollectionSession openSessionAtPath:path error:&error]==nil,"corrupt retained source fails reopening even when final report bytes are intact");
    NSString *partialPath=[root stringByAppendingPathComponent:@"partial-capacity.plist"];
    AxsCacheKeeperCollectionSession *partial=[[AxsCacheKeeperCollectionSession alloc] initWithPath:partialPath error:&error];
    CKCheck([partial beginPhase:@"hostPreflight" error:&error] && [partial finishPhase:@"hostPreflight" result:CKHost() error:&error],"partial artifact fixture begins");
    NSMutableDictionary *partialSnapshot=[a mutableCopy];partialSnapshot[@"state"]=@"partial";
    CKCheck([partial beginCapacityWithEpoch:partialSnapshot[@"epoch"] error:&error] && [partial finishCapacityWithSnapshot:partialSnapshot error:&error],"partial source can be durably captured");
    partial=[AxsCacheKeeperCollectionSession openSessionAtPath:partialPath error:&error];
    CKCheck([[partial savedCapacitySnapshot:&error][@"state"] isEqual:@"partial"] && [partial.reportProjection[@"phases"][@"capacity"][@"state"] isEqual:@"partial"],"reopening never promotes partial source to complete");
    CKCheck([[partial savedCapacitySnapshot:&error][@"roots"] isEqual:a[@"roots"]],"partial source keeps its full measured anonymous tree");
    NSString *stalePath=[root stringByAppendingPathComponent:@"clock-stale.plist"];
    AxsCacheKeeperCollectionSession *stale=[[AxsCacheKeeperCollectionSession alloc] initWithPath:stalePath error:&error];
    CKCheck([stale beginPhase:@"hostPreflight" error:&error] && [stale finishPhase:@"hostPreflight" result:CKHost() error:&error],"stale fixture begins");
    NSMutableDictionary *future=[a mutableCopy];future[@"finishedAt"]=@((uint64_t)NSDate.date.timeIntervalSince1970+3600);
    CKCheck([stale beginCapacityWithEpoch:future[@"epoch"] error:&error] && [stale finishCapacityWithSnapshot:future error:&error],"backward clock does not discard source");
    CKCheck([[stale savedCapacitySnapshot:&error][@"summaryBinding"][@"state"] isEqual:@"stale"],"clock reversal is retained rather than inventing current time");
    CKCheck([stale beginPhase:@"diagnostics" error:&error],"stale capacity can produce a historical report");
    CKCheck([[stale imageCollectionSession:&error] skip:&error],"historical report explicitly records image skip");
    CKCheck([stale saveReport:@{@"apps":@[]} diagnosticsResult:@{@"state":@"partial",@"missingSources":@[]} error:&error]!=nil,"historical report is durable");
    CKCheck([[AxsCacheKeeperCollectionSession openSessionAtPath:stalePath error:&error] savedReportData:&error]!=nil,"clock-stale historical report remains recoverable");
}
int main(int argc,const char **argv) {@autoreleasepool {
    CKCheck(argc==2,"runner provides isolated output directory");
    NSString *root=[NSString stringWithUTF8String:argv[1]],*path=[root stringByAppendingPathComponent:@"session.plist"];
    NSError *error=nil;
    AxsCacheKeeperCollectionSession *session=[[AxsCacheKeeperCollectionSession alloc] initWithPath:path error:&error];
    CKCheck(session && !error,"new session is usable immediately");
    NSString *identifier=session.sessionID;
    CKCheck(identifier.length==32,"session has immutable hexadecimal identity");
    CKCheck([session blockCapability:@"com.tencent.mqq" capability:@"privateResourceContract" error:&error],"first capability append uses mutable nested containers");
    CKCheck([session beginPhase:@"hostPreflight" error:&error],"fresh session begins first phase");
    CKCheck(![session beginPhase:@"hostPreflight" error:&error],"running phase cannot append duplicate start");
    CKCheck(![session beginPhase:@"capacity" error:&error],"later phase cannot overtake active prerequisite");
    NSMutableDictionary *host=[CKHost() mutableCopy];
    CKCheck([session finishPhase:@"hostPreflight" result:host error:&error],"host phase persists");
    host[@"state"]=@"failed";
    CKCheck([session.reportProjection[@"phases"][@"hostPreflight"][@"result"][@"state"] isEqual:@"complete"],"caller mutation cannot rewrite saved evidence");
    NSDictionary *oldProjection=session.reportProjection;
    CKCheck([session blockCapability:@"com.baidu.netdisk" capability:@"privateResourceContract" error:&error],"same instance appends a later capability");
    CKCheck([oldProjection[@"blockedCapabilities"] count]==1 && [session.reportProjection[@"blockedCapabilities"] count]==2,"same-instance future append cannot alter an old projection");
    NSArray *rows=[AxsCacheKeeperCollectionSession resumableSessionsInDirectory:root error:&error];
    CKCheck(rows.count==1 && [rows[0][@"nextPhase"] isEqual:@"capacity"],"private capability blockage still permits unfinished read-only work");
    AxsCacheKeeperCollectionSession *resumed=[AxsCacheKeeperCollectionSession openSessionAtPath:path error:&error];
    CKCheck([resumed.sessionID isEqual:identifier],"reopen preserves identity");
    CKCheck([resumed beginPhase:@"capacity" error:&error],"resume starts next phase");
    CKCheck(oldProjection[@"phases"][@"capacity"]==nil,"returned projection is detached from future changes");
    CKCheck(![resumed finishPhase:@"capacity" result:@{@"state":@"partial"} error:&error],"service terminal requires complete evidence fields");
    CKCheck([resumed finishPhase:@"capacity" result:@{@"state":@"interrupted",@"epoch":@"capacity-1",@"terminalSource":@"clientLifecycle",@"observedAt":@3,@"reason":@"background"} error:&error],"client interruption records no invented service terminal");
    CKCheck(![resumed beginPhase:@"capacity" error:&error],"interrupted phase requires explicit retry");
    CKCheck([resumed prepareRetryForPhase:@"capacity" error:&error],"explicit retry persists pending transition");
    CKCheck([resumed beginPhase:@"capacity" error:&error],"retry enters running");
    CKCheck([resumed finishPhase:@"capacity" result:CKCapacity(@"partial") error:&error],"partial is a retained terminal result");
    CKCheck(![resumed beginPhase:@"capacity" error:&error],"partial phase cannot be replayed");
    CKCheck([resumed beginPhase:@"diagnostics" error:&error],"diagnostics follows terminal partial capacity");
    CKCheck(![resumed.reportProjection[@"state"] isEqual:@"complete"],"running report cannot complete session");
    CKCheck([resumed saveReport:@{@"apps":@[]} diagnosticsResult:@{@"state":@"complete",@"missingSources":@[]} error:&error]==nil &&
        error.code==EBUSY && !resumed.reportProjection[@"phases"][@"export"],"unselected image stage cannot silently seal guided report");
    CKCheck([[resumed imageCollectionSession:&error] skip:&error],"explicit skip is durable before report generation");

    // Real filesystem failure: the document path is temporarily a directory.
    NSString *prior=[path stringByAppendingString:@".prior"];
    CKCheck([NSFileManager.defaultManager moveItemAtPath:path toPath:prior error:&error],"keep original document before filesystem failure");
    CKCheck([NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:NO attributes:nil error:&error],"inject non-file output target");
    NSDictionary *before=resumed.reportProjection;
    NSDictionary *payload=@{@"apps":@[],@"capacityMeasurement":@{@"state":@"complete",@"epoch":@"another-session",
        @"finishedAt":@2,@"completedRoots":@1,@"totalRoots":@1,@"failedRoots":@0},@"fixture":@"retained-redacted-result"};
    NSDictionary *coverage=@{@"state":@"complete",@"appCount":@0,@"missingSources":@[]};
    CKCheck([resumed saveReport:payload diagnosticsResult:coverage error:&error]==nil && error,"failed write returns error");
    CKCheck([resumed.reportProjection isEqual:before],"failed report atomically rolls back diagnostics and export state");
    CKCheck([NSFileManager.defaultManager removeItemAtPath:path error:&error] && [NSFileManager.defaultManager moveItemAtPath:prior toPath:path error:&error],"restore isolated output target");
    NSData *data=[resumed saveReport:payload diagnosticsResult:coverage error:&error];
    CKCheck(data && !error,"same object remains mutable and saves after rollback");
    NSDictionary *exported=[NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    CKCheck([exported[@"supportedImageCollection"][@"state"] isEqual:@"skipped"] &&
        [exported[@"supportedImageCollection"][@"verificationState"] isEqual:@"notPerformed"],"skipped image stage is present and never reported as verified");
    CKCheck([exported[@"capacityMeasurement"][@"state"] isEqual:@"notMeasured"] && !exported[@"capacityMeasurement"][@"epoch"],"another session capacity cannot be attached to this session");
    CKCheck([exported[@"guidedCollection"][@"phases"][@"diagnostics"][@"result"][@"missingSources"] containsObject:@"capacitySessionEvidence"],"missing original capacity evidence remains explicit");
    CKCheck([resumed.reportProjection[@"phases"][@"export"][@"state"] isEqual:@"complete"],"export completes only with persisted bytes");
    CKCheck([resumed.reportProjection[@"state"] isEqual:@"blocked"] && ![resumed.reportProjection[@"executionAvailable"] boolValue],"saved read-only report does not make missing private capability ready");
    CKCheck([resumed saveReport:payload diagnosticsResult:coverage error:&error]==nil,"terminal report cannot be overwritten");
    CKCheck(![resumed blockCapability:@"another.app" capability:@"lateMutation" error:&error],"published session projection cannot be mutated after export");
    AxsCacheKeeperCollectionSession *reopened=[AxsCacheKeeperCollectionSession openSessionAtPath:path error:&error];
    CKCheck(reopened && [[reopened savedReportData:&error] isEqual:data],"reopen retrieves byte-identical report with validated session and SHA");
    CKCheck([AxsCacheKeeperCollectionSession resumableSessionsInDirectory:root error:&error].count==1,"completed report remains available for re-export");
    CKCheck(![reopened beginPhase:@"diagnostics" error:&error],"report recovery does not recollect completed diagnostics");

    NSString *failedPath=[root stringByAppendingPathComponent:@"failed-phase.plist"];
    AxsCacheKeeperCollectionSession *failed=[[AxsCacheKeeperCollectionSession alloc] initWithPath:failedPath error:&error];
    CKCheck([failed beginPhase:@"hostPreflight" error:&error] && [failed finishPhase:@"hostPreflight" result:CKHost() error:&error],"failed capacity fixture completes host");
    CKCheck([failed beginPhase:@"capacity" error:&error] && [failed finishPhase:@"capacity" result:CKCapacity(@"failed") error:&error],"failed capacity is recorded honestly");
    CKCheck([failed beginPhase:@"diagnostics" error:&error],"failure report can still collect diagnostics");
    CKCheck([[failed imageCollectionSession:&error] skip:&error],"failure report explicitly records skipped image stage");
    NSData *failedData=[failed saveReport:payload diagnosticsResult:coverage error:&error];
    CKCheck(failedData!=nil,"failure report is saved");
    BOOL foundFailure=NO;
    for (NSDictionary *row in [AxsCacheKeeperCollectionSession resumableSessionsInDirectory:root error:&error])
        if ([row[@"sessionID"] isEqual:failed.sessionID] && [row[@"nextPhase"] isEqual:@"export"]) foundFailure=YES;
    CKCheck(foundFailure,"failed phase does not hide its completed report from re-export");
    CKCheck([[[AxsCacheKeeperCollectionSession openSessionAtPath:failedPath error:&error] savedReportData:&error] isEqual:failedData],"failure report is byte-identical after reopen");

    NSMutableDictionary *document=[[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy];
    NSMutableDictionary *artifact=[document[@"reportArtifact"] mutableCopy];artifact[@"sha256"]=@"wrong";document[@"reportArtifact"]=artifact;
    CKCheck([document writeToFile:path atomically:YES],"persist corrupt hash fixture");
    CKCheck([AxsCacheKeeperCollectionSession openSessionAtPath:path error:&error]==nil && error,"corrupt report fails closed");
    NSString *absent=[root stringByAppendingPathComponent:@"absent.plist"];
    CKCheck([AxsCacheKeeperCollectionSession openSessionAtPath:absent error:&error]==nil && ![NSFileManager.defaultManager fileExistsAtPath:absent],"open existing never creates a replacement identity");
    NSString *interrupted=[root stringByAppendingPathComponent:@"interrupted.plist"];
    AxsCacheKeeperCollectionSession *active=[[AxsCacheKeeperCollectionSession alloc] initWithPath:interrupted error:&error];
    CKCheck([active beginPhase:@"hostPreflight" error:&error],"interruption fixture begins");
    AxsCacheKeeperCollectionSession *recovered=[AxsCacheKeeperCollectionSession openSessionAtPath:interrupted error:&error];
    CKCheck([recovered.reportProjection[@"phases"][@"hostPreflight"][@"state"] isEqual:@"interrupted"],"process loss becomes explicit interruption");
    CKCheck(![recovered beginPhase:@"hostPreflight" error:&error],"recovered work cannot restart without retry transition");
    CKCheck([recovered prepareRetryForPhase:@"hostPreflight" error:&error] && [recovered beginPhase:@"hostPreflight" error:&error],"explicit interrupted work can restart");
    CKCheck([recovered finishPhase:@"hostPreflight" result:CKHost() error:&error],"background capacity fixture host completes");
    NSString *durableEpoch=NSUUID.UUID.UUIDString;
    CKCheck([recovered beginCapacityWithEpoch:durableEpoch error:&error],"durable capacity starts once");
    recovered=[AxsCacheKeeperCollectionSession openSessionAtPath:interrupted error:&error];
    CKCheck([recovered.reportProjection[@"phases"][@"capacity"][@"state"] isEqual:@"running"] &&
        [recovered.reportProjection[@"phases"][@"capacity"][@"request"][@"epoch"] isEqual:durableEpoch],"recreated settings preserves service epoch instead of inventing interruption");
    CKCheck(![recovered beginCapacityWithEpoch:NSUUID.UUID.UUIDString error:&error],"recreated settings cannot silently issue a new capacity run");
    CKCapacityRoundTrip(root);
    printf("PASS: durable collection state, atomic report rollback, capability-aware resume and integrity\n");
}return 0;}
