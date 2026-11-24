#import <Foundation/Foundation.h>
#import "AxsCacheKeeperImageCacheStatus.h"
#include <stdio.h>
#include <stdlib.h>

static void ck_write_status_require(BOOL condition,const char *message) {
    if (!condition) {fprintf(stderr,"FAIL: image-write-status: %s\n",message);exit(1);}
}
static void ck_write_status_roundtrip(AxsCacheKeeperWriteObservation observation) {
    NSDictionary *record=axs_cachekeeper_write_observation_record(observation);
    ck_write_status_require(axs_cachekeeper_write_boolean(record[@"truncated"]),"producer truncation is a Foundation boolean at zero and after eviction");
    ck_write_status_require([axs_cachekeeper_write_observation_projection(record) isEqual:record],"actual producer record passes the strict observation projection");
    if ([record[@"schemaVersion"] isEqual:@2]) {
        NSMutableDictionary *legacy=[record mutableCopy];NSMutableArray *oldRows=[NSMutableArray new];
        for (NSDictionary *row in record[@"epochs"]) {
            ck_write_status_require([row[@"identityState"] isEqual:([row[@"enabled"] boolValue] ? @"verified" : @"notRevalidated")],"current epochs state whether identity was revalidated");
            NSMutableDictionary *old=[row mutableCopy];[old removeObjectForKey:@"identityState"];[oldRows addObject:old];
        }
        legacy[@"schemaVersion"]=@1;legacy[@"epochs"]=oldRows;
        ck_write_status_require([axs_cachekeeper_write_observation_projection(legacy) isEqual:legacy],"schema one stays readable without inventing identity verification");
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
}
void axs_cachekeeper_run_write_status_tests(void) {
    AxsCacheKeeperWriteObservation observation={0};
    ck_write_status_roundtrip(observation);
    uint64_t epoch=axs_cachekeeper_write_epoch_begin(&observation,1,1,true,2);
    axs_cachekeeper_write_observe(&observation,epoch,0,true);axs_cachekeeper_write_observe(&observation,epoch,1,true);
    ck_write_status_roundtrip(observation);
    for (uint64_t i=2;i<=18;i++) axs_cachekeeper_write_epoch_begin(&observation,i,1,false,2);
    ck_write_status_require(observation.droppedEpochs==2,"fixture genuinely evicts two epochs");
    AxsCacheKeeperWriteCounts *counts=&observation.epochs[observation.count-1].writers[0];
    *counts=(AxsCacheKeeperWriteCounts){AXS_CACHEKEEPER_WRITE_MAX,AXS_CACHEKEEPER_WRITE_MAX,0,false};
    axs_cachekeeper_write_observe(&observation,observation.lastEpoch,0,false);
    ck_write_status_roundtrip(observation);
}
#if AXS_CACHEKEEPER_WRITE_STATUS_STANDALONE
int main(void) {@autoreleasepool {axs_cachekeeper_run_write_status_tests();puts("PASS: image-write-status producer and strict Foundation roundtrip");return 0;}}
#endif
