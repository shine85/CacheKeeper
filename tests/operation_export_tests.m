#import <Foundation/Foundation.h>
#import "../AxsCacheKeeperDiagnostics.h"
#import "../AxsCacheKeeperImageEffectStatus.h"
#import "../AxsCacheKeeperStorageInventory.h"
#include <string.h>

static void oxcheck(BOOL value, NSString *message) {
    if (!value) { fprintf(stderr,"FAIL: operation export: %s\n",message.UTF8String); exit(1); }
}
static NSDictionary *oxhistory(NSString *component, NSString *process) {
    return @{@"schemaVersion":@1,@"component":component,@"historyTruncated":@NO,@"historyRejected":@NO,
        @"processes":@[@{@"processID":process,@"firstObserved":@1794800000,
            @"events":@[@{@"eventID":@1,@"configurationGeneration":@1,@"installationGeneration":@1,
                @"trigger":@"background",@"refresh":@"applied",@"state":@"finished",@"reason":@"none",@"started":@1794800001,@"updated":@1794800002}],
            @"actions":@[@{@"actionID":@1,@"eventID":@1,@"ownerID":@1,@"state":@"apiCompleted",@"timedOut":@NO,
                @"reason":@"none",@"started":@1794800001,@"updated":@1794800002,@"bytesState":@"notMeasured"}]}]};
}
int main(int argc, char **argv) { @autoreleasepool {
    if (argc!=2 && argc!=3) return 2;
    BOOL pendingScenario=argc==3 && strcmp(argv[2],"pending")==0;
    NSString *folder=[NSString stringWithUTF8String:argv[1]],*status=[folder stringByAppendingPathComponent:@"Status"];
    oxcheck([NSFileManager.defaultManager createDirectoryAtPath:status withIntermediateDirectories:YES attributes:nil error:nil],@"create saved receipt directory");
    NSString *processA=@"550E8400-E29B-41D4-A716-446655440000",*processB=@"550E8400-E29B-41D4-A716-446655440001";
    NSDate *updated=[NSDate dateWithTimeIntervalSince1970:1794800002];
    NSDictionary *image=@{@"schemaVersion":@1,@"sdk":@"SDWebImage",@"state":@"apiCompleted",@"reason":@"none",
        @"observed":@1,@"eligible":@1,@"restricted":@0,@"writesBlocked":@0,@"queued":@1,@"submitted":@1,
        @"apiCompleted":@1,@"skipped":@0,@"pending":@0,@"updated":updated,@"bytesState":@"notMeasured"};
    NSDictionary *web=@{@"schemaVersion":@1,@"requested":@YES,@"timedOut":@NO,@"state":@"completed",@"reason":@"none",
        @"persistentStores":@1,@"nonPersistentStores":@0,@"submitted":@1,@"completed":@1,@"pending":@0,
        @"updated":updated,@"bytesState":@"notMeasured"};
    NSArray *bundles=@[@"test.operation.a",@"test.operation.b"];
    oxcheck([@{bundles[0]:@NO,bundles[1]:@NO} writeToFile:[folder stringByAppendingPathComponent:@"appEnabled.plist"] atomically:YES],
        @"persist disabled configuration for inventory aggregation");
    NSMutableDictionary *records=[NSMutableDictionary new];
    for (NSUInteger index=0;index<2;index++) {
        for (NSString *component in @[@"image",@"webkit"]) {
            BOOL isImage=[component isEqual:@"image"];
            NSMutableDictionary *record=[(isImage ? image : web) mutableCopy];
            NSDictionary *history=oxhistory(component,(isImage==(index==0)) ? processA : processB);
            if (isImage && index==0) {
                record[@"instanceAdmission"]=@{@"schemaVersion":@1,@"initializerReturns":@3,@"registered":@2,@"unregistered":@1,
                    @"released":@1,@"overflow":@NO,@"unregisteredReasons":@{@"diskMissing":@1},@"liveReasons":@{@"none":@1}};
                NSData *data=[NSPropertyListSerialization dataWithPropertyList:history format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
                NSMutableDictionary *measured=[NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainersAndLeaves format:NULL error:nil];
                AxsCacheKeeperImageSample before={.files=2,.logicalBytes=12,.allocatedBytes=1024},after={0};
                measured[@"processes"][0][@"actions"][0][@"cacheEffect"]=axs_cachekeeper_image_effect_record(before,after);history=measured;
            }
            record[@"operationHistory"]=history;
            NSString *file=[NSString stringWithFormat:@"%@.%@.plist",bundles[index],isImage ? @"imagecache" : @"webkit"];
            records[file]=record;
        }
    }
    if (pendingScenario) for (NSString *file in records) if ([file hasSuffix:@".webkit.plist"]) {
        NSMutableDictionary *record=records[file];record[@"state"]=@"submitted";record[@"completed"]=@0;record[@"pending"]=@1;
        NSData *data=[NSPropertyListSerialization dataWithPropertyList:record[@"operationHistory"] format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        NSMutableDictionary *history=[NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainersAndLeaves format:NULL error:nil];
        history[@"processes"][0][@"events"][0][@"state"]=@"active";history[@"processes"][0][@"actions"][0][@"state"]=@"submitted";record[@"operationHistory"]=history;
    }
    AxsCacheKeeperDiagnostics *session=[[AxsCacheKeeperDiagnostics alloc] initWithFolder:folder];
    NSDictionary *(^read)(void)=^NSDictionary *{
        NSMutableDictionary *before=[NSMutableDictionary new];
        for (NSString *file in records) {
            NSString *path=[status stringByAppendingPathComponent:file];
            oxcheck([records[file] writeToFile:path atomically:YES],@"persist actual raw component record");
            before[file]=[NSData dataWithContentsOfFile:path];
        }
        NSDictionary *report=[session reportWithApps:@[@{@"id":bundles[0]},@{@"id":bundles[1]}] environment:@{}];
        NSData *data=[NSJSONSerialization dataWithJSONObject:report options:0 error:nil];
        oxcheck(data!=nil,@"serialize complete production report");
        NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        for (NSString *privateValue in @[processA,processB,@"operation-private-canary",@"processID"])
            oxcheck(![text containsString:privateValue],@"raw process identifiers and private history fields never leave report");
        for (NSString *file in before)
            oxcheck([[NSData dataWithContentsOfFile:[status stringByAppendingPathComponent:file]] isEqual:before[file]],@"export never rewrites saved records");
        return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    };
    NSDictionary *report=read();NSArray *apps=report[@"apps"];
    NSDictionary *aImage=apps[0][@"imageDiskCache"][@"data"],*aWeb=apps[0][@"webKitDiskCache"][@"data"];
    NSDictionary *bImage=apps[1][@"imageDiskCache"][@"data"],*bWeb=apps[1][@"webKitDiskCache"][@"data"];
    oxcheck([aImage[@"apiCompleted"] isEqual:@1] && !aImage[@"writeObservation"] && !bImage[@"writeObservation"],
        @"SDWebImage API completion never fabricates writer attempts or blocked evidence");
    if (pendingScenario) {
        oxcheck([aWeb[@"state"] isEqual:@"submitted"] && [aWeb[@"pending"] isEqual:@1] && [aWeb[@"completed"] isEqual:@0] &&
            [aWeb[@"operationHistory"][@"processes"][0][@"actions"][0][@"state"] isEqual:@"submitted"],@"saved pending export never invents API completion or interruption");
        for (NSDictionary *entry in report[@"storageInventory"][@"entries"]) {
            NSDictionary *sdk=entry[@"sdkReceipts"][@"webKitDiskCache"];
            oxcheck([sdk[@"liveProcessState"] isEqual:@"unknown"],
                @"saved pending receipt is not evidence of a live process");
            oxcheck([sdk[@"pending"] isEqual:@1] && [sdk[@"completed"] isEqual:@0] && [sdk[@"sourceUpdated"] isEqual:@1794800002],
                @"saved pending count and observation time remain original");
        }
        oxcheck([apps[0][@"capabilities"][@"webKit"][@"liveProcessState"] isEqual:@"unknown"],@"capability cannot imply a current live process");
        oxcheck([read()[@"apps"] isEqual:apps],@"reading pending twice cannot refresh or terminalize saved request");
        puts("PASS: saved pending receipt preserves unknown live state and original request");return 0;
    }
    NSNumber *aliasA=aImage[@"operationHistory"][@"processes"][0][@"processAlias"];
    NSNumber *aliasB=aWeb[@"operationHistory"][@"processes"][0][@"processAlias"];
    NSDictionary *effect=aImage[@"operationHistory"][@"processes"][0][@"actions"][0][@"cacheEffect"];
    oxcheck([effect[@"result"] isEqual:@"empty"] && [effect[@"before"][@"logicalBytes"] isEqual:@12] &&
        [effect[@"physicalRelease"] isEqual:@"notMeasured"],@"saved image effect survives the real diagnostics JSON boundary");
    oxcheck(!bImage[@"operationHistory"][@"processes"][0][@"actions"][0][@"cacheEffect"],@"legacy image completion is not populated from another app effect");
    oxcheck([aImage[@"instanceAdmission"][@"initializerReturns"] isEqual:@3] &&
        [aImage[@"instanceAdmission"][@"released"] isEqual:@1] &&
        [aImage[@"instanceAdmission"][@"unregisteredReasons"][@"diskMissing"] isEqual:@1],
        @"saved admission counters survive production diagnostics JSON");
    oxcheck(!bImage[@"instanceAdmission"],@"legacy app does not inherit another app admission");
    oxcheck(aliasA && aliasB && ![aliasA isEqual:aliasB],@"distinct process instances remain distinct across the report");
    oxcheck([aliasA isEqual:bWeb[@"operationHistory"][@"processes"][0][@"processAlias"]] &&
        [aliasB isEqual:bImage[@"operationHistory"][@"processes"][0][@"processAlias"]],@"shared process relation survives cross-component and cross-app export");
    for (NSDictionary *record in @[aImage,aWeb,bImage,bWeb]) {
        NSDictionary *process=record[@"operationHistory"][@"processes"][0];
        oxcheck([record[@"updated"] isEqual:@1794800002] && [process[@"firstObserved"] isEqual:@1794800000],@"export preserves original observation times");
        oxcheck([process[@"actions"][0][@"eventID"] isEqual:process[@"events"][0][@"eventID"]] &&
            [process[@"actions"][0][@"state"] isEqual:@"apiCompleted"] &&
            [process[@"actions"][0][@"bytesState"] isEqual:@"notMeasured"],@"operation association and unmeasured completion survive actual JSON");
    }
    NSArray *inventory=report[@"storageInventory"][@"entries"];
    oxcheck(inventory.count==2,@"inventory retains both configured entries");
    for (NSDictionary *entry in inventory)
        for (NSString *key in @[@"imageDiskCache",@"webKitDiskCache"])
            oxcheck([entry[@"sdkReceipts"][key][@"state"] isEqual:@"available"] &&
                [entry[@"sdkReceipts"][key][@"sourceUpdated"] isEqual:@1794800002],
                @"inventory validates original history before aliases replace raw process identities");
    NSDictionary *again=read();
    oxcheck([again[@"apps"] isEqual:apps],@"repeated saved export does not invent a new event or refresh existing records");
    NSString *firstFile=@"test.operation.a.imagecache.plist";
    NSMutableDictionary *first=records[firstFile];
    NSDictionary *validAdmission=first[@"instanceAdmission"];
    NSMutableDictionary *badAdmission=[validAdmission mutableCopy];badAdmission[@"path"]=@"operation-private-canary";
    first[@"instanceAdmission"]=badAdmission;
    oxcheck([read()[@"apps"][0][@"imageDiskCache"][@"state"] isEqual:@"invalid"],@"private admission field rejects entire saved receipt");
    first[@"instanceAdmission"]=validAdmission;
    NSMutableDictionary *bad=[first[@"operationHistory"] mutableCopy];bad[@"rawPath"]=@"operation-private-canary";
    first[@"operationHistory"]=bad;
    oxcheck([read()[@"apps"][0][@"imageDiskCache"][@"state"] isEqual:@"invalid"],@"unknown private historical fields reject saved receipt");
    first[@"operationHistory"]=aImage[@"operationHistory"];
    oxcheck([read()[@"apps"][0][@"imageDiskCache"][@"state"] isEqual:@"invalid"],@"export aliases cannot be reused as raw process identities");
    for (NSMutableDictionary *record in records.allValues) [record removeObjectForKey:@"operationHistory"];
    for (NSDictionary *app in read()[@"apps"])
        for (NSString *key in @[@"imageDiskCache",@"webKitDiskCache"])
            oxcheck([app[key][@"state"] isEqual:@"available"] && !app[key][@"data"][@"operationHistory"],@"legacy receipts remain readable without fabricated history");
    puts("PASS: operation history saved plist to production export, shared aliases and privacy");
    return 0;
}}
