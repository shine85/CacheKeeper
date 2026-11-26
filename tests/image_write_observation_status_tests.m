#import <Foundation/Foundation.h>
#import "AxsCacheKeeperImageCacheStatus.h"
#include <stdio.h>
#include <stdlib.h>

static void ck_write_status_require(BOOL condition,const char *message) {
    if (!condition) {fprintf(stderr,"FAIL: image-write-status: %s\n",message);exit(1);}
}
static void ck_write_status_payload(AxsCacheKeeperWriteObservation *observation,uint64_t epoch,unsigned writer,BOOL blocked,BOOL nonempty) {
#if AXS_CACHEKEEPER_WRITE_PAYLOAD_OBSERVATION
    axs_cachekeeper_write_observe_payload(observation,epoch,writer,blocked,nonempty);
#else
    (void)nonempty;axs_cachekeeper_write_observe(observation,epoch,writer,blocked);
#endif
}
static NSDictionary *ck_write_status_legacy(NSDictionary *record,NSUInteger schema) {
    NSData *bytes=[NSPropertyListSerialization dataWithPropertyList:record format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    NSMutableDictionary *legacy=[NSPropertyListSerialization propertyListWithData:bytes options:NSPropertyListMutableContainersAndLeaves format:NULL error:nil];
    legacy[@"schemaVersion"]=@(schema);[legacy removeObjectForKey:@"payloadBasis"];[legacy removeObjectForKey:@"unclassifiedMeaning"];
    NSMutableArray *containers=[legacy[@"epochs"] mutableCopy];[containers addObject:legacy[@"unattributed"]];
    for(NSMutableDictionary *row in containers) {
        if(schema==1) [row removeObjectForKey:@"identityState"];
        for(NSString *writer in @[@"data",@"extended"]) for(NSString *key in @[@"nonemptyAttempts",@"nonemptyAllowed",@"nonemptyBlocked",@"emptyAttempts",@"emptyAllowed",@"emptyBlocked"])
            [row[writer] removeObjectForKey:key];
    }
    return legacy;
}
static void ck_write_status_roundtrip(AxsCacheKeeperWriteObservation observation) {
    NSDictionary *record=axs_cachekeeper_write_observation_record(observation);
    ck_write_status_require(axs_cachekeeper_write_boolean(record[@"truncated"]),"producer truncation is a Foundation boolean at zero and after eviction");
    ck_write_status_require([axs_cachekeeper_write_observation_projection(record) isEqual:record],"actual producer record passes the strict observation projection");
    if ([record[@"schemaVersion"] unsignedIntegerValue]>=2) {
        NSMutableDictionary *legacy;
        for (NSDictionary *row in record[@"epochs"]) {
            ck_write_status_require([row[@"identityState"] isEqual:([row[@"enabled"] boolValue] ? @"verified" : @"notRevalidated")],"current epochs state whether identity was revalidated");
        }
        legacy=[ck_write_status_legacy(record,1) mutableCopy];
        ck_write_status_require([axs_cachekeeper_write_observation_projection(legacy) isEqual:legacy],"schema one stays readable without inventing identity verification");
        legacy=[ck_write_status_legacy(record,2) mutableCopy];
        ck_write_status_require([axs_cachekeeper_write_observation_projection(legacy) isEqual:legacy],"schema two preserves missing payload evidence instead of inventing zeros");
        if ([record[@"epochs"] count]) {
            NSMutableDictionary *badIdentity=[record mutableCopy];NSMutableArray *badRows=[record[@"epochs"] mutableCopy];
            NSMutableDictionary *badRow=[badRows[0] mutableCopy];badRow[@"identityState"]=[badRow[@"enabled"] boolValue] ? @"notRevalidated" : @"verified";
            badRows[0]=badRow;badIdentity[@"epochs"]=badRows;
            ck_write_status_require(!axs_cachekeeper_write_observation_projection(badIdentity),"contradictory identity claim is rejected");
            [badRow removeObjectForKey:@"identityState"];
            ck_write_status_require(!axs_cachekeeper_write_observation_projection(badIdentity),"schema two requires every identity state");
        }
    }
    for (NSNumber *format in @[@(NSPropertyListXMLFormat_v1_0),@(NSPropertyListBinaryFormat_v1_0)]) {
        NSError *error=nil;
        NSData *data=[NSPropertyListSerialization dataWithPropertyList:record format:format.unsignedIntegerValue options:0 error:&error];
        NSDictionary *decoded=data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:&error] : nil;
        ck_write_status_require(data && !error && [decoded isEqual:record] &&
            [axs_cachekeeper_write_observation_projection(decoded) isEqual:record],"XML and binary property lists retain boolean types and exact writer counts");
    }
    NSError *error=nil;NSData *json=[NSJSONSerialization dataWithJSONObject:record options:0 error:&error];
    NSDictionary *decoded=json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:&error] : nil;
    ck_write_status_require(json && !error && [axs_cachekeeper_write_observation_projection(decoded) isEqual:record],"JSON roundtrip retains strict boolean identity");
    NSMutableDictionary *bad=[record mutableCopy];
    // The shipped bug boxes a C relational expression as int, even though it is
    // numerically 0/1. The validator must keep rejecting that old representation.
    bad[@"truncated"]=@(observation.droppedEpochs>0);
    ck_write_status_require(!axs_cachekeeper_write_observation_projection(bad),"integer comparison boxing cannot impersonate a boolean");
    for (NSNumber *integer in @[@0,@1]) {
        bad=[record mutableCopy];bad[@"overflow"]=integer;
        ck_write_status_require(!axs_cachekeeper_write_observation_projection(bad),"overflow rejects numeric zero and one");
    }
    NSDictionary *receipt=@{@"schemaVersion":@1,@"sdk":@"SDWebImage",@"state":@"ready",@"reason":@"none",
        @"observed":@0,@"eligible":@0,@"restricted":@0,@"writesBlocked":@0,@"queued":@0,@"submitted":@0,
        @"apiCompleted":@0,@"skipped":@0,@"pending":@0,@"updated":[NSDate dateWithTimeIntervalSince1970:120],
        @"bytesState":@"notMeasured",@"writeObservation":record};
    ck_write_status_require(axs_cachekeeper_image_cache_raw_projection(receipt)!=nil,"producer write observation remains valid inside the full public receipt");
    ck_write_status_require([axs_cachekeeper_image_cache_message(receipt) containsString:@"SDWebImage 写入观测"],
        "summary explicitly identifies the writer observation");
    NSMutableDictionary *legacy=[receipt mutableCopy];[legacy removeObjectForKey:@"writeObservation"];
    legacy[@"writesBlocked"]=@7;legacy[@"apiCompleted"]=@1;legacy[@"queued"]=@1;legacy[@"submitted"]=@1;legacy[@"pending"]=@0;
    NSString *legacyMessage=axs_cachekeeper_image_cache_message(legacy);
    ck_write_status_require([legacyMessage containsString:@"写入观测未记录"] && ![legacyMessage containsString:@"限制写盘 7 次"],
        "legacy API completion and aggregate write counters cannot impersonate writer observation");
    NSMutableDictionary *completionOnly=[legacy mutableCopy];[completionOnly removeObjectForKey:@"writeObservation"];
    NSDictionary *completionExport=axs_cachekeeper_image_cache_projection(completionOnly);
    ck_write_status_require(!completionExport[@"writeObservation"] && ![axs_cachekeeper_image_cache_message(completionOnly) containsString:@"data 1/1/0"],
        "API completion never creates blocked writer evidence");
    legacy[@"reason"]=@"appDisabled";
    ck_write_status_require([axs_cachekeeper_image_cache_message(legacy) containsString:@"未开启"],
        "specific disabled state remains visible without historical writer observations");
}
void axs_cachekeeper_run_write_status_tests(void) {
    AxsCacheKeeperWriteObservation observation={0};
    ck_write_status_roundtrip(observation);
    NSDictionary *zeroReceipt=@{@"schemaVersion":@1,@"sdk":@"SDWebImage",@"state":@"ready",@"reason":@"none",
        @"observed":@0,@"eligible":@0,@"restricted":@0,@"writesBlocked":@0,@"queued":@0,@"submitted":@0,
        @"apiCompleted":@0,@"skipped":@0,@"pending":@0,@"updated":[NSDate dateWithTimeIntervalSince1970:120],
        @"bytesState":@"notMeasured",@"writeObservation":axs_cachekeeper_write_observation_record(observation)};
    ck_write_status_require([axs_cachekeeper_image_cache_message(zeroReceipt) containsString:@"本记录没有 SDWebImage 写入尝试观测"],
        "zero-attempt observation does not claim a writer decision");
    uint64_t epoch=axs_cachekeeper_write_epoch_begin(&observation,1,1,true,2);
    ck_write_status_payload(&observation,epoch,0,true,YES);ck_write_status_payload(&observation,epoch,1,true,YES);
    ck_write_status_roundtrip(observation);
    NSDictionary *blockedReceipt=@{@"schemaVersion":@1,@"sdk":@"SDWebImage",@"state":@"ready",@"reason":@"none",
        @"observed":@0,@"eligible":@0,@"restricted":@0,@"writesBlocked":@2,@"queued":@0,@"submitted":@0,
        @"apiCompleted":@0,@"skipped":@0,@"pending":@0,@"updated":[NSDate dateWithTimeIntervalSince1970:120],
        @"bytesState":@"notMeasured",@"writeObservation":axs_cachekeeper_write_observation_record(observation)};
    ck_write_status_require([axs_cachekeeper_image_cache_message(blockedReceipt) containsString:@"prevent data 1/1/0, extended 1/1/0"],
        "nonzero writer fixture reports the exact data and extended decisions");
    NSDictionary *payloadRecord=blockedReceipt[@"writeObservation"];
    ck_write_status_require([payloadRecord[@"schemaVersion"] isEqual:@3] &&
        [payloadRecord[@"epochs"][0][@"data"][@"nonemptyBlocked"] isEqual:@1],"current producer records actual nonempty decisions");
    ck_write_status_require([axs_cachekeeper_image_cache_message(blockedReceipt) containsString:@"非空 data 1/1/0"],"summary distinguishes nonempty decisions");
    for(NSString *mutation in @[@"missing",@"sum",@"subset",@"overlap",@"boolean",@"private",@"basis"]) {
        NSData *bytes=[NSPropertyListSerialization dataWithPropertyList:payloadRecord format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        NSMutableDictionary *bad=[NSPropertyListSerialization propertyListWithData:bytes options:NSPropertyListMutableContainersAndLeaves format:NULL error:nil];
        NSMutableDictionary *counts=bad[@"epochs"][0][@"data"];
        if([mutation isEqual:@"missing"]) [counts removeObjectForKey:@"nonemptyAttempts"];
        else if([mutation isEqual:@"sum"]) counts[@"nonemptyAllowed"]=@1;
        else if([mutation isEqual:@"subset"]) {counts[@"nonemptyAttempts"]=@2;counts[@"nonemptyBlocked"]=@2;}
        else if([mutation isEqual:@"overlap"]) {counts[@"emptyAttempts"]=@1;counts[@"emptyBlocked"]=@1;}
        else if([mutation isEqual:@"boolean"]) counts[@"emptyAttempts"]=@NO;
        else if([mutation isEqual:@"private"]) counts[@"payload"]=@"private-canary";
        else bad[@"payloadBasis"]=@"diskWriteVerified";
        ck_write_status_require(!axs_cachekeeper_write_observation_projection(bad),"payload counts reject malformed sums, subsets, overlap, types and semantics");
    }
    for (uint64_t i=2;i<=18;i++) axs_cachekeeper_write_epoch_begin(&observation,i,1,false,2);
    ck_write_status_require(observation.droppedEpochs==2,"fixture genuinely evicts two epochs");
    AxsCacheKeeperWriteCounts *counts=&observation.epochs[observation.count-1].writers[0];
    *counts=(AxsCacheKeeperWriteCounts){.attempts=AXS_CACHEKEEPER_WRITE_MAX,.allowed=AXS_CACHEKEEPER_WRITE_MAX};
    axs_cachekeeper_write_observe(&observation,observation.lastEpoch,0,false);
    ck_write_status_roundtrip(observation);
}
#if AXS_CACHEKEEPER_WRITE_STATUS_STANDALONE
int main(void) {@autoreleasepool {axs_cachekeeper_run_write_status_tests();puts("PASS: image-write-status producer and strict Foundation roundtrip");return 0;}}
#endif
