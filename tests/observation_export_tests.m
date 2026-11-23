#import <Foundation/Foundation.h>
#import "AxsCacheKeeperImageWriteObservation.h"
#import "../AxsCacheKeeperDiagnostics.h"

static void oecheck(BOOL condition, NSString *message) {
    if (!condition) {fprintf(stderr,"FAIL: observation export: %s\n",message.UTF8String);exit(1);}
}
static NSDictionary *oejson(NSString *text) {
    return [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
}
int main(int argc,char **argv) { @autoreleasepool {
    if (argc!=2) return 2;
    NSString *folder=[NSString stringWithUTF8String:argv[1]],*status=[folder stringByAppendingPathComponent:@"Status"];
    oecheck([NSFileManager.defaultManager createDirectoryAtPath:status withIntermediateDirectories:YES attributes:nil error:nil],@"create fixture folder");
    NSString *imagePath=[status stringByAppendingPathComponent:@"test.observation.imagecache.plist"],*webPath=[status stringByAppendingPathComponent:@"test.observation.webkit.plist"];
    // Inventory membership comes from registration or saved configuration;
    // the displayed app list and SDK receipts do not establish that membership.
    NSString *statesPath=[folder stringByAppendingPathComponent:@"appEnabled.plist"],
        *directoriesPath=[folder stringByAppendingPathComponent:@"directories.plist"];
    oecheck([@{@"test.observation":@NO} writeToFile:statesPath atomically:YES] &&
        [@{} writeToFile:directoriesPath atomically:YES],@"save disabled app configuration as inventory membership source");
    NSData *savedStates=[NSData dataWithContentsOfFile:statesPath],*savedDirectories=[NSData dataWithContentsOfFile:directoriesPath];
    NSDictionary *source=@{@"schemaVersion":@1,@"accepted":@NO,@"stage":@"mainIdentity",@"reason":@"notMainBase",@"methodIndex":@0,@"helperIndex":@0};
    NSDictionary *relation=oejson(@"{\"schemaVersion\":1,\"classPresentMask\":31,\"classNameKnownMask\":31,\"classNameEqualsMainMask\":0,\"classResolvedMask\":0,\"classLoadedMainMask\":0,\"classUUIDMatchesMainMask\":0,\"initializerUsesSavedOriginal\":false,\"initializerResolved\":true,\"initializerBaseIsMain\":false,\"initializerUUIDMatchesMain\":false,\"originalResolvedMask\":0,\"originalBaseIsMainMask\":0,\"originalUUIDMatchesMainMask\":0,\"helperResolvedMask\":3,\"helperBaseIsMainMask\":0,\"helperUUIDMatchesMainMask\":0,\"mainUUIDResolved\":true,\"mainUUIDMatchesContract\":true,\"mainLayoutChecked\":false}");
    NSMutableDictionary *discovery=[@{@"schemaVersion":@2,@"stage":@"source",@"classMask":@15,@"imageKind":@"other",@"source":@"rejected",@"failure":@"unknownSource",@"methodIndex":@0,@"sourceCheck":source,@"loadedRelation":relation} mutableCopy];
    NSDictionary *view=oejson(@"{\"schemaVersion\":1,\"context\":\"hostMainBundle\",\"pathAPI\":\"lstat\",\"openAPI\":\"openSearchNoFollow\",\"fdAPI\":\"fstat\",\"pathCallOwner\":\"libSystem\",\"openCallOwner\":\"libSystem\",\"fdCallOwner\":\"libSystem\",\"pathCallResolved\":true,\"openCallResolved\":true,\"fdCallResolved\":true,\"callOwnersStable\":true,\"fdPathState\":\"success\",\"fdPathErrno\":0,\"inputResolveState\":\"success\",\"inputResolveErrno\":0,\"fdResolveState\":\"success\",\"fdResolveErrno\":0,\"inputEqualsFDPath\":true,\"resolvedInputEqualsResolvedFDPath\":true,\"sameObjectNonTimeFields\":true}");
    NSDictionary *identity=@{@"schemaVersion":@2,@"comparison":@"pathToFD",@"differenceMask":@1920,@"resample":@{@"fdErrno":@0,@"pathErrno":@0,@"fdDifferenceMask":@0,@"pathDifferenceMask":@0,@"pathFDDifferenceMask":@1920},@"viewObservation":view};
    NSDictionary *(^installation)(NSDictionary *)=^NSDictionary *(NSDictionary *item){return @{@"state":@"failed",@"errorCode":@2,@"detail":@{@"target":@"root",@"operation":@"openIdentity",@"errno":@0,@"identity":item}};};
    // XML property lists preserve dates at whole-second precision; keep the
    // fixture aligned with the persisted representation under test.
    NSDate *time=[NSDate dateWithTimeIntervalSince1970:1794800000];
    NSMutableDictionary *image=[@{@"schemaVersion":@1,@"sdk":@"SDWebImage",@"state":@"unsupported",@"reason":@"unsupportedSDK",@"observed":@0,@"eligible":@0,@"restricted":@0,@"writesBlocked":@0,@"queued":@0,@"submitted":@0,@"apiCompleted":@0,@"skipped":@0,@"pending":@0,@"updated":time,@"bytesState":@"notMeasured",@"discoveryCheck":discovery,@"installationCheck":installation(identity)} mutableCopy];
    NSMutableDictionary *web=[@{@"schemaVersion":@1,@"requested":@YES,@"timedOut":@NO,@"state":@"blocked",@"reason":@"installationUnverified",@"persistentStores":@0,@"nonPersistentStores":@0,@"submitted":@0,@"completed":@0,@"pending":@0,@"updated":time,@"bytesState":@"notMeasured",@"installationCheck":installation(identity)} mutableCopy];
    AxsCacheKeeperDiagnostics *session=[[AxsCacheKeeperDiagnostics alloc] initWithFolder:folder];
    __block BOOL binaryFixture=NO;__block NSDictionary *inventoryImage=nil;
    NSDictionary *(^read)(void)=^NSDictionary *{
        if (binaryFixture) {
            for (NSString *path in @[imagePath,webPath]) {
                NSDictionary *record=[path isEqual:imagePath] ? image : web;
                NSData *serialized=[NSPropertyListSerialization dataWithPropertyList:record format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
                oecheck(serialized && [serialized writeToFile:path options:NSDataWritingAtomic error:nil],@"write current binary saved receipt");
            }
        } else oecheck([image writeToFile:imagePath atomically:YES] && [web writeToFile:webPath atomically:YES],@"write legacy XML saved receipts");
        NSData *beforeImage=[NSData dataWithContentsOfFile:imagePath],*beforeWeb=[NSData dataWithContentsOfFile:webPath];
        NSDictionary *report=[session reportWithApps:@[@{@"id":@"test.observation"}] environment:@{}];
        NSData *json=[NSJSONSerialization dataWithJSONObject:report options:0 error:nil];
        oecheck(json && [[NSData dataWithContentsOfFile:imagePath] isEqual:beforeImage] && [[NSData dataWithContentsOfFile:webPath] isEqual:beforeWeb],@"JSON roundtrip preserves both source files");
        oecheck([[NSData dataWithContentsOfFile:statesPath] isEqual:savedStates] &&
            [[NSData dataWithContentsOfFile:directoriesPath] isEqual:savedDirectories],@"export preserves the saved inventory membership and disabled configuration");
        oecheck(![[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] containsString:@"observation-private-canary"],@"private data never escapes invalid observations");
        NSDictionary *decoded=[NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
        inventoryImage=nil;
        for (NSDictionary *entry in decoded[@"storageInventory"][@"entries"])
            if ([entry[@"bundle"] isEqual:@"test.observation"]) {
                oecheck([entry[@"appEnabled"] isEqual:@NO] && [entry[@"configurationPresent"] isEqual:@YES],
                    @"saved configuration admits an inventory row without enabling cleanup");
                inventoryImage=entry[@"sdkReceipts"][@"imageDiskCache"];
            }
        oecheck(inventoryImage!=nil,@"saved SDK app is present in the actual all-app inventory export");
        return decoded[@"apps"][0];
    };
    NSDictionary *app=read(),*out=app[@"imageDiskCache"][@"data"];
    oecheck([out[@"discoveryCheck"] isEqual:discovery],@"first source failure and unresolved loaded relationship survive actual export");
    for (NSString *key in @[@"imageDiskCache",@"webKitDiskCache"]) {
        oecheck([app[key][@"data"][@"installationCheck"] isEqual:installation(identity)],@"same closed installation view evidence survives both component exports");
        oecheck([app[key][@"data"][@"updated"] isEqual:@1794800000],@"saved observation timestamp is not refreshed by export");
    }
    // Complete producer-shaped epoch evidence travels through saved plist,
    // production Diagnostics/Inventory and JSON without becoming persistence proof.
    AxsCacheKeeperWriteObservation writes={0};
    uint64_t writeEpoch=axs_cachekeeper_write_epoch_begin(&writes,1,1,true,2);
    axs_cachekeeper_write_observe(&writes,writeEpoch,0,true);axs_cachekeeper_write_observe(&writes,writeEpoch,1,true);
    writeEpoch=axs_cachekeeper_write_epoch_begin(&writes,2,1,false,2);
    axs_cachekeeper_write_observe(&writes,writeEpoch,0,false);
    NSDictionary *writeRecord=axs_cachekeeper_write_observation_record(writes);
    image[@"writeObservation"]=writeRecord;
    app=read();
    oecheck([app[@"imageDiskCache"][@"data"][@"writeObservation"] isEqual:writeRecord] &&
        [app[@"capabilities"][@"image"][@"writeObservation"] isEqual:writeRecord] &&
        [inventoryImage[@"writeObservation"] isEqual:writeRecord],@"same writer decisions survive saved plist through canonical capability and inventory JSON paths");
    oecheck([app[@"capabilities"][@"image"][@"effectVerification"] isEqual:@"notVerified"] &&
        [app[@"capabilities"][@"image"][@"resourceContract"] isEqual:@"notEstablishedByReceipt"] &&
        [inventoryImage[@"resourceContract"] isEqual:@"notEstablishedByReceipt"],@"forwarded writer decisions do not grant an effect or resource contract");
    for (NSString *field in @[@"scope",@"allowedMeaning",@"diskPersistence",@"privatePath"]) {
        NSMutableDictionary *bad=[writeRecord mutableCopy];bad[field]=@"observation-private-canary";image[@"writeObservation"]=bad;
        app=read();
        oecheck([app[@"imageDiskCache"][@"state"] isEqual:@"invalid"] &&
            [app[@"capabilities"][@"image"][@"sourceState"] isEqual:@"invalid"] &&
            [inventoryImage[@"state"] isEqual:@"invalid"] && !inventoryImage[@"writeObservation"] &&
            !app[@"capabilities"][@"image"][@"writeObservation"],@"unknown writer semantics reject all three saved receipt consumers");
    }
    for (NSString *change in @[@"sum",@"disabled",@"duplicate",@"boolean",@"overflow",@"installation",@"unknown"]) {
        NSData *encoded=[NSPropertyListSerialization dataWithPropertyList:writeRecord format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        NSMutableDictionary *bad=[NSPropertyListSerialization propertyListWithData:encoded options:NSPropertyListMutableContainersAndLeaves format:NULL error:nil];
        NSMutableDictionary *first=bad[@"epochs"][0],*second=bad[@"epochs"][1];
        if ([change isEqual:@"sum"]) first[@"data"][@"attempts"]=@2;
        else if ([change isEqual:@"disabled"]) first[@"enabled"]=@NO;
        else if ([change isEqual:@"duplicate"]) second[@"epoch"]=@1;
        else if ([change isEqual:@"boolean"]) first[@"data"][@"allowed"]=@NO;
        else if ([change isEqual:@"overflow"]) first[@"data"][@"overflow"]=@YES;
        else if ([change isEqual:@"installation"]) second[@"installation"]=@0;
        else first[@"rawKey"]=@"observation-private-canary";
        image[@"writeObservation"]=bad;
        oecheck([read()[@"imageDiskCache"][@"state"] isEqual:@"invalid"],@"impossible counts or cross-epoch splice cannot pass saved receipt validation");
    }
    [image removeObjectForKey:@"writeObservation"];
    app=read();
    oecheck(!app[@"imageDiskCache"][@"data"][@"writeObservation"] &&
        !app[@"capabilities"][@"image"][@"writeObservation"] && !inventoryImage[@"writeObservation"],
        @"old receipts are not backfilled with zero writer evidence in any consumer");
    image[@"writeObservation"]=writeRecord;
    binaryFixture=YES;
    image[@"updated"]=[NSDate dateWithTimeIntervalSince1970:1794800000.25];web[@"updated"]=image[@"updated"];
    app=read();
    oecheck([app[@"capabilities"][@"image"][@"writeObservation"] isEqual:writeRecord] &&
        [inventoryImage[@"writeObservation"] isEqual:writeRecord],@"binary saved writer decisions retain the same all-app summaries");
    for (NSString *key in @[@"imageDiskCache",@"webKitDiskCache"])
        oecheck([app[key][@"data"][@"updated"] isEqual:@1794800000.25],@"current binary receipt preserves fractional time through export");
    for (NSString *key in @[@"sourceCheck",@"loadedRelation"]) {
        NSMutableDictionary *bad=[discovery[key] mutableCopy];bad[@"rawPath"]=@"observation-private-canary";
        NSMutableDictionary *changed=[discovery mutableCopy];changed[key]=bad;image[@"discoveryCheck"]=changed;
        oecheck([read()[@"imageDiskCache"][@"state"] isEqual:@"invalid"],@"private source or relation fields reject the saved receipt");
    }
    image[@"discoveryCheck"]=discovery;
    NSMutableDictionary *badView=[view mutableCopy];badView[@"rawPath"]=@"observation-private-canary";
    NSMutableDictionary *badIdentity=[identity mutableCopy];badIdentity[@"viewObservation"]=badView;
    image[@"installationCheck"]=installation(badIdentity);web[@"installationCheck"]=installation(badIdentity);app=read();
    oecheck([app[@"imageDiskCache"][@"state"] isEqual:@"invalid"] && [app[@"webKitDiskCache"][@"state"] isEqual:@"invalid"],@"both components reject private view fields");
    NSMutableDictionary *legacyIdentity=[identity mutableCopy];legacyIdentity[@"schemaVersion"]=@1;[legacyIdentity removeObjectForKey:@"viewObservation"];
    NSMutableDictionary *legacyDiscovery=[discovery mutableCopy];legacyDiscovery[@"schemaVersion"]=@1;[legacyDiscovery removeObjectForKey:@"sourceCheck"];[legacyDiscovery removeObjectForKey:@"loadedRelation"];
    image[@"discoveryCheck"]=legacyDiscovery;image[@"installationCheck"]=installation(legacyIdentity);web[@"installationCheck"]=installation(legacyIdentity);app=read();
    oecheck([app[@"imageDiskCache"][@"data"][@"discoveryCheck"] isEqual:legacyDiscovery] &&
        [app[@"imageDiskCache"][@"data"][@"installationCheck"] isEqual:installation(legacyIdentity)] &&
        [app[@"webKitDiskCache"][@"data"][@"installationCheck"] isEqual:installation(legacyIdentity)],@"historical observations stay readable without invented evidence");
    puts("PASS: saved source and installation observation export, privacy and historical compatibility");
    return 0;
}}
