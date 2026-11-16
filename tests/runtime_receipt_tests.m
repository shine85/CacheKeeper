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
    puts("PASS: runtime provenance and installation receipt boundaries");
    return 0;
} }
