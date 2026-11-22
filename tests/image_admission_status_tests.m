#import "AxsCacheKeeperImageCacheStatus.h"
#include <stdio.h>
static void check(BOOL condition,const char *message) {
    if (!condition) {fprintf(stderr,"FAIL: image-admission-status: %s\n",message);exit(1);}
}
int main(void) {@autoreleasepool {
    NSMutableDictionary *old=[@{@"schemaVersion":@1,@"sdk":@"SDWebImage",@"state":@"notObserved",@"reason":@"none",
        @"observed":@0,@"eligible":@0,@"restricted":@0,@"writesBlocked":@0,@"queued":@0,@"submitted":@0,
        @"apiCompleted":@0,@"skipped":@0,@"pending":@0,@"updated":NSDate.date,@"bytesState":@"notMeasured"} mutableCopy];
    check(axs_cachekeeper_image_cache_projection(old)!=nil,"legacy receipt remains readable without invented admission");
    check(!axs_cachekeeper_image_cache_projection(old)[@"instanceAdmission"],"legacy field stays absent");
    NSDictionary *valid=@{@"schemaVersion":@1,@"initializerReturns":@3,@"registered":@1,@"unregistered":@2,@"released":@1,
        @"overflow":@NO,@"unregisteredReasons":@{@"diskMissing":@1,@"configurationMissing":@1},@"liveReasons":@{}};
    old[@"instanceAdmission"]=valid;
    check(axs_cachekeeper_image_cache_projection(old)!=nil,"valid early and released outcomes project");
    NSMutableDictionary *booleanCounter=[valid mutableCopy];booleanCounter[@"registered"]=@YES;old[@"instanceAdmission"]=booleanCounter;
    check(!axs_cachekeeper_image_cache_projection(old),"boolean fractional negative unsafe and nonnumeric counts rejected");
    for (id bad in @[@YES,@(-1),@1.5,@(9007199254740992ULL),@"secret",NSNull.null]) {
        NSMutableDictionary *candidate=[valid mutableCopy];candidate[@"initializerReturns"]=bad;old[@"instanceAdmission"]=candidate;
        check(!axs_cachekeeper_image_cache_projection(old),"boolean fractional negative unsafe and nonnumeric counts rejected");
    }
    for (NSString *key in @[@"initializerReturns",@"registered",@"unregistered",@"released"]) {
        NSMutableDictionary *candidate=[valid mutableCopy];candidate[key]=@9;old[@"instanceAdmission"]=candidate;
        check(!axs_cachekeeper_image_cache_projection(old),"contradictory lifecycle counts rejected");
    }
    for (id reasons in @[@{@"private-path":@1},@{@"diskMissing":@YES},@{@"diskMissing":@0},@{@"queueIdentity":@2},@[]]) {
        NSMutableDictionary *candidate=[valid mutableCopy];candidate[@"unregisteredReasons"]=reasons;old[@"instanceAdmission"]=candidate;
        check(!axs_cachekeeper_image_cache_projection(old),"unknown or misclassified reason data rejected");
    }
    NSMutableDictionary *candidate=[valid mutableCopy];candidate[@"overflow"]=@0;old[@"instanceAdmission"]=candidate;
    check(!axs_cachekeeper_image_cache_projection(old),"overflow requires CFBoolean");
    candidate=[valid mutableCopy];candidate[@"path"]=@"private-value";old[@"instanceAdmission"]=candidate;
    check(!axs_cachekeeper_image_cache_projection(old),"unknown private fields rejected");
    candidate=[valid mutableCopy];candidate[@"liveReasons"]=@{@"none":@1};old[@"instanceAdmission"]=candidate;
    check(!axs_cachekeeper_image_cache_projection(old),"live reason counts must match observed owner count");
    candidate=[valid mutableCopy];candidate[@"overflow"]=@YES;old[@"instanceAdmission"]=candidate;
    check(!axs_cachekeeper_image_cache_projection(old),"unsaturated diagnostics cannot claim overflow");
    old[@"instanceAdmission"]=valid;
    NSDictionary *projected=axs_cachekeeper_image_cache_projection(old);
    NSData *json=[NSJSONSerialization dataWithJSONObject:projected[@"instanceAdmission"] options:0 error:nil];
    check(json && [[NSJSONSerialization JSONObjectWithData:json options:0 error:nil] isEqual:valid],"closed diagnostic survives JSON export");
    NSData *plist=[NSPropertyListSerialization dataWithPropertyList:old format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    check(plist && axs_cachekeeper_image_cache_projection([NSPropertyListSerialization propertyListWithData:plist options:0 format:NULL error:nil]),"saved receipt roundtrip keeps optional diagnostic types");
    NSString *message=axs_cachekeeper_image_cache_message(old);
    check([message containsString:@"释放"] && ![message containsString:@"尚未观察到"],"released owners are not described as never triggered");
    candidate=[valid mutableCopy];candidate[@"registered"]=@0;candidate[@"released"]=@0;candidate[@"initializerReturns"]=@2;
    old[@"instanceAdmission"]=candidate;
    check([axs_cachekeeper_image_cache_message(old) containsString:@"磁盘缓存成员缺失"],"early member failure has specific safe wording");
    old[@"instanceAdmission"]=@{@"schemaVersion":@1,@"initializerReturns":@1,@"registered":@1,@"unregistered":@0,@"released":@0,
        @"overflow":@NO,@"unregisteredReasons":@{},@"liveReasons":@{@"queueIdentity":@1}};
    old[@"observed"]=@1;old[@"state"]=@"blocked";old[@"reason"]=@"unsupportedInstance";
    check([axs_cachekeeper_image_cache_message(old) containsString:@"队列身份已变化"],"queue change is distinguished from custom backend");
    [old removeObjectForKey:@"instanceAdmission"];
    check(![axs_cachekeeper_image_cache_message(old) containsString:@"自定义后端"],"legacy generic rejection does not invent a cause");

    NSDictionary *notRecorded=@{@"schemaVersion":@1,@"state":@"notRecorded"};
    check([axs_cachekeeper_image_cache_projection(old)[@"sdkMethodsRejectionObservation"] isEqual:notRecorded],"legacy rejection detail explicitly remains not recorded");
    NSDictionary *gate=@{@"schemaVersion":@1,@"accepted":@NO,@"cause":@"methodCount",@"methodIndex":@0,@"methodsCount":@24};
    NSDictionary *failure=@{@"schemaVersion":@1,@"state":@"recorded",@"initializerOrdinal":@2,@"check":gate};
    old[@"instanceAdmission"]=@{@"schemaVersion":@1,@"initializerReturns":@2,@"registered":@0,@"unregistered":@2,@"released":@0,@"overflow":@NO,@"unregisteredReasons":@{@"diskMissing":@1,@"sdkMethodsChanged":@1},@"liveReasons":@{}};
    old[@"observed"]=@0;old[@"sdkMethodsRejectionObservation"]=failure;
    check(axs_cachekeeper_image_cache_projection(old)!=nil,"saved rejection and lifecycle counters agree");
    NSDictionary *rejectedAdmission=old[@"instanceAdmission"];
    for (id malformed in @[@[],NSNull.null,@{@"sdkMethodsChanged":@[]},@{@"sdkMethodsChanged":NSNull.null}]) {
        NSMutableDictionary *invalidAdmission=[rejectedAdmission mutableCopy];invalidAdmission[@"unregisteredReasons"]=malformed;
        old[@"instanceAdmission"]=invalidAdmission;
        @try {check(!axs_cachekeeper_image_cache_projection(old),"recorded rejection rejects malformed cumulative reason data");}
        @catch (NSException *exception) {(void)exception;check(NO,"recorded rejection validates admission before reading cumulative reason data");}
    }
    for (id malformed in @[@[],NSNull.null]) {
        NSMutableDictionary *invalidAdmission=[rejectedAdmission mutableCopy];invalidAdmission[@"initializerReturns"]=malformed;
        old[@"instanceAdmission"]=invalidAdmission;
        @try {check(!axs_cachekeeper_image_cache_projection(old),"recorded rejection rejects malformed initializer counts");}
        @catch (NSException *exception) {(void)exception;check(NO,"recorded rejection validates admission before reading initializer counts");}
    }
    old[@"instanceAdmission"]=rejectedAdmission;
    NSMutableDictionary *wrong=[failure mutableCopy];wrong[@"state"]=@"notRecorded";old[@"sdkMethodsRejectionObservation"]=wrong;
    check(!axs_cachekeeper_image_cache_projection(old),"not recorded state cannot conceal a populated rejection");
    for (id ordinal in @[@0,@YES,@1.5,@(-1)]) {
        wrong=[failure mutableCopy];wrong[@"initializerOrdinal"]=ordinal;old[@"sdkMethodsRejectionObservation"]=wrong;
        check(!axs_cachekeeper_image_cache_projection(old),"first rejection ordinal must be a positive exact counter");
    }
    old[@"sdkMethodsRejectionObservation"]=failure;
    NSMutableDictionary *badFailure=[failure mutableCopy];badFailure[@"initializerOrdinal"]=@3;old[@"sdkMethodsRejectionObservation"]=badFailure;
    check(!axs_cachekeeper_image_cache_projection(old),"rejection ordinal cannot exceed real initializer returns");
    badFailure=[failure mutableCopy];badFailure[@"address"]=@"0x1234";old[@"sdkMethodsRejectionObservation"]=badFailure;
    check(!axs_cachekeeper_image_cache_projection(old),"saved rejection rejects unknown pointer fields");
    old[@"sdkMethodsRejectionObservation"]=failure;old[@"instanceAdmission"]=valid;
    check(!axs_cachekeeper_image_cache_projection(old),"recorded SDK rejection requires matching cumulative reason count");
    [old removeObjectForKey:@"sdkMethodsRejectionObservation"];old[@"instanceAdmission"]=valid;
    puts("PASS: image-admission-status closed projection, privacy, legacy and wording");
    return 0;
}}
