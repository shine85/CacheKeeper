#import <Foundation/Foundation.h>
#import "AxsCacheKeeperImageCacheStatus.h"
#import "AxsCacheKeeperWebKitStatus.h"

static void ckcheck(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr,"FAIL: %s\n",message.UTF8String); exit(1); }
}
int main(void) { @autoreleasepool {
    NSDictionary *runtime=@{@"schemaVersion":@1,@"packageVersion":@"0.7.2-154.1",@"firstObserved":@1794800000.25};
    NSMutableDictionary *image=[@{@"schemaVersion":@1,@"sdk":@"SDWebImage",@"state":@"unsupported",@"reason":@"unsupportedSDK",
        @"observed":@0,@"eligible":@0,@"restricted":@0,@"writesBlocked":@0,@"queued":@0,@"submitted":@0,
        @"apiCompleted":@0,@"skipped":@0,@"pending":@0,@"updated":NSDate.date,@"bytesState":@"notMeasured",
        @"runtimeInfo":runtime} mutableCopy];
    ckcheck([axs_cachekeeper_image_cache_projection(image)[@"runtimeInfo"] isEqual:runtime],@"current runtime build survives image receipt");
    NSMutableDictionary *web=[@{@"schemaVersion":@1,@"requested":@YES,@"timedOut":@NO,@"state":@"notObserved",@"reason":@"none",
        @"persistentStores":@0,@"nonPersistentStores":@0,@"submitted":@0,@"completed":@0,@"pending":@0,
        @"updated":NSDate.date,@"bytesState":@"notMeasured",@"runtimeInfo":runtime} mutableCopy];
    ckcheck([axs_cachekeeper_webkit_projection(web)[@"runtimeInfo"] isEqual:runtime],@"current runtime build survives web receipt");
    NSArray *invalid=@[
        @{@"schemaVersion":@YES,@"packageVersion":@"0.7.2-154.1",@"firstObserved":@1794800000},
        @{@"schemaVersion":@1,@"packageVersion":@"/private/account",@"firstObserved":@1794800000},
        @{@"schemaVersion":@1,@"packageVersion":@"0.7.2-154.1\n",@"firstObserved":@1794800000},
        @{@"schemaVersion":@1,@"packageVersion":@"0.7.2-154.1",@"firstObserved":@YES},
        @{@"schemaVersion":@1,@"packageVersion":@"0.7.2-154.1",@"firstObserved":@(-1)},
        @{@"schemaVersion":@1,@"packageVersion":@"0.7.2-154.1",@"firstObserved":@(NAN)},
        @{@"schemaVersion":@1,@"packageVersion":@"0.7.2-154.1",@"firstObserved":@1794800000,@"privatePath":@"secret"}];
    for (NSDictionary *bad in invalid) {
        image[@"runtimeInfo"]=bad;web[@"runtimeInfo"]=bad;
        ckcheck(!axs_cachekeeper_image_cache_projection(image) && !axs_cachekeeper_webkit_projection(web),@"invalid runtime metadata is rejected by both receipts");
    }
    [image removeObjectForKey:@"runtimeInfo"];[web removeObjectForKey:@"runtimeInfo"];
    ckcheck(axs_cachekeeper_image_cache_projection(image) && axs_cachekeeper_webkit_projection(web),@"historical receipts stay readable without inventing current runtime metadata");
    NSDictionary *check=@{@"state":@"failed",@"errorCode":@2,@"detail":@{@"target":@"root",@"operation":@"openIdentity",@"errno":@0}};
    image[@"installationCheck"]=check;
    ckcheck([axs_cachekeeper_image_cache_projection(image)[@"installationCheck"] isEqual:check],@"image installation failure is retained independently from SDK discovery");
    image[@"installationCheck"]=@{@"state":@"verified",@"errorCode":@2};
    ckcheck(!axs_cachekeeper_image_cache_projection(image),@"invalid installation evidence is rejected");
    [image removeObjectForKey:@"installationCheck"];
    NSDictionary *discovery=@{@"schemaVersion":@1,@"stage":@"method",@"classMask":@15,@"imageKind":@"main",
        @"source":@"imageUUID",@"methodIndex":@25,@"failure":@"argumentType"};
    image[@"discoveryCheck"]=discovery;
    ckcheck([axs_cachekeeper_image_cache_projection(image)[@"discoveryCheck"] isEqual:discovery],@"exact SDK rejection survives independently of old aggregate state");
    for (NSDictionary *change in @[@{@"classMask":@YES},@{@"methodIndex":@26},@{@"methodIndex":@0},
        @{@"source":@"rejected"},@{@"stage":@"complete"},@{@"object":@"private-value"},@{@"failure":NSNull.null}]) {
        NSMutableDictionary *bad=[discovery mutableCopy];[bad addEntriesFromDictionary:change];image[@"discoveryCheck"]=bad;
        ckcheck(!axs_cachekeeper_image_cache_projection(image),@"invalid SDK diagnosis is rejected");
    }
#if !defined(AXS_CACHEKEEPER_RECEIPT_BASELINE)
    NSDictionary *sourceCheck=@{@"schemaVersion":@1,@"accepted":@NO,@"stage":@"slots",@"reason":@"missing",@"methodIndex":@25,@"helperIndex":@0};
    NSDictionary *relation=@{@"schemaVersion":@1,@"classPresentMask":@15,@"classNameKnownMask":@15,@"classNameEqualsMainMask":@0,
        @"classResolvedMask":@0,@"classLoadedMainMask":@0,@"classUUIDMatchesMainMask":@0,@"initializerUsesSavedOriginal":@NO,
        @"initializerResolved":@YES,@"initializerBaseIsMain":@YES,@"initializerUUIDMatchesMain":@YES,
        @"originalResolvedMask":@0,@"originalBaseIsMainMask":@0,@"originalUUIDMatchesMainMask":@0,
        @"helperResolvedMask":@0,@"helperBaseIsMainMask":@0,@"helperUUIDMatchesMainMask":@0,
        @"mainUUIDResolved":@YES,@"mainUUIDMatchesContract":@YES,@"mainLayoutChecked":@NO};
    NSMutableDictionary *current=[@{@"schemaVersion":@2,@"stage":@"source",@"classMask":@15,@"imageKind":@"other",@"source":@"rejected",
        @"methodIndex":@0,@"failure":@"unknownSource",@"sourceCheck":sourceCheck,@"loadedRelation":relation} mutableCopy];
    image[@"discoveryCheck"]=current;
    ckcheck([axs_cachekeeper_image_cache_projection(image)[@"discoveryCheck"] isEqual:current],@"first failure and unresolved class identity remain distinct in new receipt");
    for (NSDictionary *change in @[@{@"accepted":@YES},@{@"accepted":@0},@{@"stage":@"complete"},@{@"reason":@"private"},
        @{@"methodIndex":@11},@{@"methodIndex":@26},@{@"helperIndex":@1},@{@"private":@1}]) {
        NSMutableDictionary *bad=[sourceCheck mutableCopy];[bad addEntriesFromDictionary:change];current[@"sourceCheck"]=bad;
        ckcheck(!axs_cachekeeper_image_cache_projection(image),@"new source schema refuses contradictory acceptance, stage, reason and indexes");
    }
    current[@"sourceCheck"]=sourceCheck;
    for (NSDictionary *change in @[@{@"classLoadedMainMask":@1},@{@"classUUIDMatchesMainMask":@1},@{@"classNameEqualsMainMask":@16},
        @{@"originalBaseIsMainMask":@1},@{@"helperUUIDMatchesMainMask":@1},@{@"initializerUsesSavedOriginal":@YES},
        @{@"mainUUIDResolved":@NO},@{@"initializerResolved":@NO},@{@"mainLayoutChecked":@1},@{@"privateAddress":@1}]) {
        NSMutableDictionary *bad=[relation mutableCopy];[bad addEntriesFromDictionary:change];current[@"loadedRelation"]=bad;
        ckcheck(!axs_cachekeeper_image_cache_projection(image),@"loaded relationships require actual resolution and forbid private extra keys");
    }
    current[@"loadedRelation"]=relation;
    // Equal bits are all zero here: incomplete main UUID alone must invalidate each resolved relation.
    NSMutableDictionary *unresolvedMain=[relation mutableCopy];unresolvedMain[@"mainUUIDResolved"]=@NO;
    unresolvedMain[@"mainUUIDMatchesContract"]=@NO;unresolvedMain[@"initializerResolved"]=@NO;
    unresolvedMain[@"initializerBaseIsMain"]=@NO;unresolvedMain[@"initializerUUIDMatchesMain"]=@NO;
    ckcheck(axs_cachekeeper_image_loaded_relation_projection(unresolvedMain)!=nil,@"fully unresolved main relation remains representable without guessed equality");
    for (NSDictionary *change in @[@{@"initializerResolved":@YES},@{@"originalResolvedMask":@1},@{@"helperResolvedMask":@1},@{@"classResolvedMask":@1}]) {
        NSMutableDictionary *bad=[unresolvedMain mutableCopy];[bad addEntriesFromDictionary:change];
        ckcheck(!axs_cachekeeper_image_loaded_relation_projection(bad),@"main UUID unresolved forbids complete dependent resolutions even when every equality bit is zero");
    }
    NSDictionary *acceptedSource=@{@"schemaVersion":@1,@"accepted":@YES,@"stage":@"complete",@"reason":@"none",@"methodIndex":@0,@"helperIndex":@0};
    NSArray *early=@[
        @{@"stage":@"notChecked",@"classMask":@0,@"imageKind":@"unknown",@"source":@"unknown",@"failure":@"none",@"methodIndex":@0},
        @{@"stage":@"classes",@"classMask":@1,@"imageKind":@"other",@"source":@"unknown",@"failure":@"missingClass",@"methodIndex":@0},
        @{@"stage":@"image",@"classMask":@15,@"imageKind":@"other",@"source":@"unknown",@"failure":@"missingImage",@"methodIndex":@0}];
    for (NSDictionary *outer in early) for (NSDictionary *checkValue in @[sourceCheck,acceptedSource]) {
        NSMutableDictionary *bad=[outer mutableCopy],*observed=[relation mutableCopy];
        observed[@"classPresentMask"]=outer[@"classMask"];observed[@"classNameKnownMask"]=outer[@"classMask"];
        observed[@"mainLayoutChecked"]=checkValue[@"accepted"];
        bad[@"schemaVersion"]=@2;bad[@"sourceCheck"]=checkValue;bad[@"loadedRelation"]=observed;
        ckcheck(!axs_cachekeeper_image_discovery_projection(bad),@"early outer stages cannot attach a legacy check they never executed");
    }
    for (NSString *modern in @[@"frameworkVersion",@"imageUUID"]) for (NSDictionary *checkValue in @[sourceCheck,acceptedSource]) {
        NSMutableDictionary *bad=[current mutableCopy],*observed=[relation mutableCopy];
        bad[@"stage"]=@"complete";bad[@"source"]=modern;bad[@"failure"]=@"none";
        observed[@"mainLayoutChecked"]=checkValue[@"accepted"];bad[@"sourceCheck"]=checkValue;bad[@"loadedRelation"]=observed;
        ckcheck(!axs_cachekeeper_image_discovery_projection(bad),@"modern source branches cannot claim any legacy source check");
        [bad removeObjectForKey:@"sourceCheck"];observed[@"mainLayoutChecked"]=@NO;
        ckcheck(axs_cachekeeper_image_discovery_projection(bad)!=nil,@"modern successful discovery without legacy source check remains readable");
    }
    NSMutableDictionary *pinned=[current mutableCopy];pinned[@"stage"]=@"complete";pinned[@"source"]=@"testPinned";pinned[@"failure"]=@"none";
    ckcheck(axs_cachekeeper_image_discovery_projection(pinned)!=nil,@"explicit pinned fixture can override a measured legacy refusal");
    NSMutableDictionary *pinnedRelation=[relation mutableCopy];pinnedRelation[@"mainLayoutChecked"]=@YES;
    pinned[@"sourceCheck"]=acceptedSource;pinned[@"loadedRelation"]=pinnedRelation;
    ckcheck(!axs_cachekeeper_image_discovery_projection(pinned),@"accepted legacy check cannot be relabeled as pinned refusal override");
    [pinned removeObjectForKey:@"sourceCheck"];pinnedRelation[@"mainLayoutChecked"]=@NO;
    ckcheck(!axs_cachekeeper_image_discovery_projection(pinned),@"current pinned result cannot omit its measured source refusal");
    NSMutableDictionary *changed=[current mutableCopy];changed[@"stage"]=@"method";changed[@"source"]=@"imageFingerprint";changed[@"failure"]=@"methodsChanged";
    ckcheck(axs_cachekeeper_image_discovery_projection(changed)!=nil,@"prior fixed source invalidation retains its current legacy refusal");
    [changed removeObjectForKey:@"sourceCheck"];
    ckcheck(!axs_cachekeeper_image_discovery_projection(changed),@"fixed source invalidation still requires the actual attempted legacy result");
    NSMutableDictionary *mutableCheck=[sourceCheck mutableCopy],*mutableRelation=[relation mutableCopy];
    current[@"sourceCheck"]=mutableCheck;current[@"loadedRelation"]=mutableRelation;
    NSDictionary *projected=axs_cachekeeper_image_cache_projection(image);
    mutableCheck[@"methodIndex"]=@1;mutableRelation[@"classResolvedMask"]=@15;
    ckcheck([projected[@"discoveryCheck"][@"sourceCheck"] isEqual:sourceCheck] && [projected[@"discoveryCheck"][@"loadedRelation"] isEqual:relation],@"new nested observations remain immutable after caller mutation");
    [current removeObjectForKey:@"sourceCheck"];
    ckcheck(!axs_cachekeeper_image_cache_projection(image),@"current unknownSource never omits its actual source failure");
#endif
    puts("PASS: runtime provenance and installation receipt boundaries");
    return 0;
} }
