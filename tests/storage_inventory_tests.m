#import <Foundation/Foundation.h>
#import "../AxsCacheKeeperDiagnostics.h"
#import "../AxsCacheKeeperInstallation.h"
#import "../AxsCacheKeeperScanDiagnostics.h"
#import "../AxsCacheKeeperPolicy.h"
#import "../AxsCacheKeeperStorageInventory.h"

#if !AXS_CACHEKEEPER_STORAGE_INVENTORY_RED
// Instrument only call boundaries; the real inline policy and production aggregation still run.
static NSUInteger sieffectiveCalls,siexclusionCalls,siselectedCalls;
static NSArray *sieffective(NSArray *selected,id state,NSArray *discovered) {
    sieffectiveCalls++;return axs_cachekeeper_effective_paths(selected,state,discovered);
}
static NSArray *siexclusions(id state) {siexclusionCalls++;return axs_cachekeeper_exclusions(state);}
static NSArray *siselected(NSArray *selected) {siselectedCalls++;return axs_cachekeeper_cache_paths(selected);}
#define axs_cachekeeper_effective_paths sieffective
#define axs_cachekeeper_exclusions siexclusions
#define axs_cachekeeper_cache_paths siselected
#import "../AxsCacheKeeperStorageInventory.m"
#undef axs_cachekeeper_effective_paths
#undef axs_cachekeeper_exclusions
#undef axs_cachekeeper_cache_paths

// NSArray's primitives expose whether production discovery touches omitted rows; no simulated
// collector replaces the real aggregation. count itself does not enumerate or read any row.
@interface AxsCacheKeeperStorageBudgetRows : NSArray
@property(nonatomic,strong) NSArray *values;
@property(nonatomic) NSUInteger highestRead,reads;
@end
@implementation AxsCacheKeeperStorageBudgetRows
- (NSUInteger)count {return self.values.count;}
- (id)objectAtIndex:(NSUInteger)index {self.highestRead=MAX(self.highestRead,index);self.reads++;return self.values[index];}
@end
#endif

static void sicheck(BOOL condition, NSString *message) {
    if (!condition) {fprintf(stderr,"FAIL: storage inventory: %s\n",message.UTF8String);exit(1);}
}
// Replace only the unavailable system registration boundary. Provider validation, association
// revocation, saved plist reads, policy decisions and final serialization remain production code.
@interface AxsCacheKeeperStorageTestOwner : NSObject
@property(nonatomic,copy) NSString *bundleIdentifier;
@end
@implementation AxsCacheKeeperStorageTestOwner
@end
@interface AxsCacheKeeperStorageTestPlugin : NSObject
@property(nonatomic,strong) id pluginIdentifier,containingBundle,dataContainerURL;
@end
@implementation AxsCacheKeeperStorageTestPlugin
@end
@interface AxsCacheKeeperStorageTestProxy : NSObject
@property(nonatomic,strong) id applicationType,applicationIdentifier,bundleURL,localizedName,shortVersionString;
@property(nonatomic,strong) id dataContainerURL,groupContainerURLs,plugInKitPlugins;
@end
@implementation AxsCacheKeeperStorageTestProxy
@end
static id siregistrations;
static NSUInteger siRegistryReads;
@interface AxsCacheKeeperStorageTestWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (id)allInstalledApplications;
@end
@implementation AxsCacheKeeperStorageTestWorkspace
+ (instancetype)defaultWorkspace {return [self new];}
- (id)allInstalledApplications {siRegistryReads++;return siregistrations;}
@end
Class axs_cachekeeper_storage_test_class_lookup(NSString *name) {
    return [name isEqual:@"LSApplicationWorkspace"] ? AxsCacheKeeperStorageTestWorkspace.class : NSClassFromString(name);
}
static AxsCacheKeeperStorageTestProxy *siproxy(NSString *bundle, NSString *type, id home) {
    AxsCacheKeeperStorageTestProxy *proxy=[AxsCacheKeeperStorageTestProxy new];
    proxy.applicationIdentifier=bundle;proxy.applicationType=type;
    proxy.bundleURL=[NSURL fileURLWithPath:@"/Applications/StorageFixture.app"];
    proxy.dataContainerURL=home;proxy.groupContainerURLs=@{};proxy.plugInKitPlugins=@[];return proxy;
}
static id siplugin(NSString *identifier,NSString *owner,id url) {
    AxsCacheKeeperStorageTestOwner *parent=[AxsCacheKeeperStorageTestOwner new];parent.bundleIdentifier=owner;
    AxsCacheKeeperStorageTestPlugin *plugin=[AxsCacheKeeperStorageTestPlugin new];
    plugin.pluginIdentifier=identifier;plugin.containingBundle=parent;plugin.dataContainerURL=url;return plugin;
}
static NSArray *siprovider(NSMutableDictionary *cache, NSDictionary **registry) {
    NSDictionary *coverage=nil;
#if AXS_CACHEKEEPER_STORAGE_INVENTORY_RED
    *registry=nil;return axs_cachekeeper_installed_applications_with_container_coverage(cache,&coverage,nil);
#else
    return axs_cachekeeper_installed_applications_with_registry_inventory(cache,&coverage,registry,nil);
#endif
}
#if !AXS_CACHEKEEPER_STORAGE_INVENTORY_RED
static NSArray *siPlanProvider(NSMutableDictionary *cache,NSDictionary **registry,NSDictionary **plan) {
    NSUInteger before=siRegistryReads;
    NSArray *apps=axs_cachekeeper_installed_applications_with_capacity_plan(cache,NULL,registry,plan,nil);
    sicheck(siRegistryReads==before+1,@"boundary plan and registry still use one system enumeration");
    if (*plan) sicheck([(*plan)[@"registry"] isEqual:*registry],@"boundary plan is bound to this registry projection");
    return apps;
}
static void siPrivatePlan(NSMutableDictionary *cache,NSURL *shared) {
    NSDictionary *coverage=nil,*registry=nil,*plan=nil;NSUInteger before=siRegistryReads;
    axs_cachekeeper_installed_applications_with_capacity_plan(cache,&coverage,&registry,&plan,nil);
    sicheck(siRegistryReads==before+1,@"capacity plan and registry share exactly one system enumeration");
    sicheck([plan[@"roots"] count]==1 && [plan[@"roots"][0][@"url"] isEqual:shared],@"capacity plan preserves one private URL across home group and extension aliases");
    NSDictionary *root=plan[@"roots"][0];
    sicheck([root[@"owners"] isEqual:@[@"com.apple.inventory.system",@"test.inventory.alpha",@"test.inventory.beta"]],@"capacity plan includes non-display owner and every validated role");
    sicheck([root[@"roles"] isEqual:@[@"extension",@"group",@"home"]],@"capacity plan retains all registered role associations");
    NSString *json=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:registry options:0 error:nil] encoding:NSUTF8StringEncoding];
    sicheck(![json containsString:shared.absoluteString] && ![json containsString:@"private-plugin-id-canary"],@"private capacity URLs and association identities never enter public registry");
}
#endif
static NSDictionary *siapp(NSDictionary *inventory,NSString *bundle) {
    for (NSDictionary *entry in inventory[@"entries"]) if ([entry[@"bundle"] isEqual:bundle]) return entry;
    return nil;
}
static NSDictionary *sirow(NSDictionary *entry,NSString *path) {
    for (NSDictionary *row in entry[@"resources"]) if ([row[@"path"] isEqual:path]) return row;
    return nil;
}
#if !AXS_CACHEKEEPER_STORAGE_INVENTORY_RED
static void sitiming(const char *phase, NSTimeInterval started) {
    fprintf(stdout,"TIMING: storage inventory %s %.3f seconds\n",phase,NSProcessInfo.processInfo.systemUptime-started);
    fflush(stdout);
}
#endif
static NSDictionary *sifiles(NSString *folder) {
    NSMutableDictionary *files=[NSMutableDictionary new];
    for (NSString *path in [NSFileManager.defaultManager subpathsAtPath:folder]) {
        NSString *full=[folder stringByAppendingPathComponent:path];
        NSDictionary *attributes=[NSFileManager.defaultManager attributesOfItemAtPath:full error:nil];
        if ([attributes[NSFileType] isEqual:NSFileTypeRegular]) files[path]=@[[NSData dataWithContentsOfFile:full],attributes[NSFileModificationDate]];
    }return files;
}
static NSDictionary *siscan(NSArray *rows, NSDate *date,BOOL complete) {
    return @{@"rows":rows,@"updated":date,@"complete":@(complete),@"home":@"private-home-canary",@"token":@"private-token-canary",@"groups":@{@"private-group-canary":@"private-group-path-canary"}};
}
static void siput(NSString *folder,NSString *name,id value) {
    NSString *path=[folder stringByAppendingPathComponent:name];NSError *error=nil;
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    BOOL saved=data && [data writeToFile:path options:NSDataWritingAtomic error:&error];
    sicheck(saved,
        [NSString stringWithFormat:@"write saved plist fixture %@ (%@/%ld)",name,error.domain,(long)error.code]);
}
#if !AXS_CACHEKEEPER_STORAGE_INVENTORY_RED
static NSMutableDictionary *simutable(id value) {
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    return [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainers format:NULL error:nil];
}
static void sirole_contract(NSDictionary *registry) {
    registry=simutable(registry);[(NSMutableDictionary *)registry removeObjectForKey:@"scopeObservation"];
    // Same full token union survives through home/extension: only per-role consistency can reject.
    NSMutableDictionary *missing=simutable(registry);
    for (NSMutableDictionary *entry in missing[@"entries"]) entry[@"relationships"][@"group"][@"tokens"]=[NSMutableArray new];
    sicheck([axs_cachekeeper_registry_inventory_projection(missing)[@"state"] isEqual:@"invalid"],@"role tokens cannot disappear while all-role union is unchanged");
    NSMutableDictionary *home=simutable(registry);
    for (NSMutableDictionary *entry in home[@"entries"]) if ([entry[@"bundle"] isEqual:@"test.inventory.alpha"])
        entry[@"relationships"][@"home"][@"tokens"]=[NSMutableArray new];
    sicheck([axs_cachekeeper_registry_inventory_projection(home)[@"state"] isEqual:@"invalid"],@"available home cannot claim an empty relationship");
    NSMutableDictionary *notProvided=simutable(registry);
    for (NSMutableDictionary *entry in notProvided[@"entries"]) if ([entry[@"bundle"] isEqual:@"test.inventory.alpha"])
        entry[@"relationships"][@"home"][@"state"]=@"notProvided";
    sicheck([axs_cachekeeper_registry_inventory_projection(notProvided)[@"state"] isEqual:@"invalid"],@"notProvided home cannot claim a token");
    NSMutableDictionary *wrongOwnerCount=simutable(registry);
    for (NSMutableDictionary *entry in wrongOwnerCount[@"entries"]) if ([entry[@"bundle"] isEqual:@"test.inventory.beta"])
        entry[@"relationships"][@"home"]=simutable(@{@"state":@"available",@"tokens":@[@"resource-1"]});
    sicheck([axs_cachekeeper_registry_inventory_projection(wrongOwnerCount)[@"state"] isEqual:@"invalid"],@"home owner relationships cannot exceed registered association count");
    // A second exact URL exists only in extension. Substituting it into group preserves the global
    // union but changes this role's union from one to two URLs, inconsistent with source coverage.
    NSMutableDictionary *second=simutable(registry);
    for (NSMutableDictionary *entry in second[@"entries"]) if ([entry[@"bundle"] isEqual:@"test.inventory.alpha"])
        entry[@"relationships"][@"extension"][@"tokens"]=[NSMutableArray arrayWithObject:@"resource-2"];
    second[@"allRolesUniqueRegisteredURLCount"]=@2;
    sicheck([axs_cachekeeper_registry_inventory_projection(second)[@"state"] isEqual:@"available"],@"valid distinct extension token keeps separate source counts");
    for (NSMutableDictionary *entry in second[@"entries"]) if ([entry[@"bundle"] isEqual:@"test.inventory.beta"])
        entry[@"relationships"][@"group"][@"tokens"]=[NSMutableArray arrayWithObject:@"resource-2"];
    sicheck([axs_cachekeeper_registry_inventory_projection(second)[@"state"] isEqual:@"invalid"],@"moving an existing global token into another role cannot falsify role URL count");
}
static void siresource_budget(NSString *folder,NSDictionary *registry,NSDate *date) {
    NSTimeInterval started=NSProcessInfo.processInfo.systemUptime;
    NSMutableArray *values=[NSMutableArray new];
    // Included tmp descendant cannot auto-discover tmp; the sole exact tmp root is omitted.
    [values addObject:@{@"path":@"tmp/ordinary",@"bytes":@20,@"complete":@YES}];
    for (NSUInteger i=1;i<16384;i++) [values addObject:@{@"path":@"Library/Caches",@"bytes":@1,@"complete":@YES}];
    [values addObject:@{@"path":@"tmp",@"bytes":@9000,@"complete":@YES}];
    [values addObject:@{@"path":@"Cache",@"bytes":@9000,@"complete":@YES}];
    NSDictionary *states=@{@"test.inventory.alpha":@{@"enabled":@YES,@"autoDiscover":@YES,@"excludedPaths":@[@"Library/Caches/retained"]}};
    NSDictionary *snapshots=@{@"test.inventory.alpha":siscan(values,date,YES)};
    siput(folder,@"appEnabled.plist",states);siput(folder,@"directories.plist",@{});siput(folder,@"snapshots.plist",snapshots);
    NSDictionary *before=sifiles(folder);
    AxsCacheKeeperDiagnostics *session=[[AxsCacheKeeperDiagnostics alloc] initWithFolder:folder];
    NSDictionary *report=[session reportWithApps:@[] environment:@{@"registryInventory":registry}],*entry=siapp(report[@"storageInventory"],@"test.inventory.alpha");
    sicheck([entry[@"resources"] count]==16384 && [entry[@"resourceRowsTruncated"] isEqual:@YES] && [entry[@"omittedResourceRows"] isEqual:@2],@"saved duplicate resources retain bounded output and exact omission count");
    sicheck([entry[@"discoveryRowsTruncated"] isEqual:@YES] && [entry[@"discoveryRowsExamined"] isEqual:@16384] && [entry[@"discoveredRootCount"] isEqual:@1],@"bounded discovery deduplicates roots and visibly retains incomplete coverage");
    sicheck([entry[@"resources"][0][@"authorizationState"] isEqual:@"notAuthorized"] && [entry[@"resources"][1][@"authorizationState"] isEqual:@"configuredPendingExecutionPreflight"] && [entry[@"resources"][1][@"actuallyReclaimable"] isEqual:@"notMeasured"],@"omitted root cannot promote authorization and observed root still requires execution preflight");
    sicheck([before isEqual:sifiles(folder)],@"resource budget regression does not rewrite saved sources");
    NSData *json=[NSJSONSerialization dataWithJSONObject:report options:0 error:nil];
    sicheck(json && [NSJSONSerialization JSONObjectWithData:json options:0 error:nil]!=nil,@"large saved budget report survives real JSON serialization");
    sitiming("saved budget and JSON",started);started=NSProcessInfo.processInfo.systemUptime;
    AxsCacheKeeperStorageBudgetRows *tracked=[AxsCacheKeeperStorageBudgetRows new];tracked.values=values;
    sieffectiveCalls=0;siexclusionCalls=0;siselectedCalls=0;
    NSDictionary *direct=axs_cachekeeper_storage_inventory(nil,@{@"state":@"available",@"data":states},@{@"state":@"available",@"data":@{}},@{@"state":@"available",@"data":@{@"test.inventory.alpha":siscan(tracked,date,YES)}},@[],^NSString *(NSString *path){return path;});
    sicheck(tracked.highestRead==16383 && tracked.reads<=32768 && sieffectiveCalls==1 && siexclusionCalls==1 && siselectedCalls==1,@"resource budget bounds actual row access and policy computation once per app");
    sicheck([siapp(direct,@"test.inventory.alpha")[@"discoveredRootCount"] isEqual:@1] && [siapp(direct,@"test.inventory.alpha")[@"resources"][0][@"authorizationState"] isEqual:@"notAuthorized"],@"only examined roots can contribute effective paths");
    sitiming("direct budget",started);
}
#endif
int main(int argc,const char *argv[]) { @autoreleasepool {
    if (argc!=2) return 2;NSString *folder=@(argv[1]);
    sicheck([NSFileManager.defaultManager createDirectoryAtPath:[folder stringByAppendingPathComponent:@"Status"] withIntermediateDirectories:YES attributes:nil error:nil],@"create fixture");
    NSURL *shared=[NSURL URLWithString:@"file:///private/var/private-url-canary"];
    AxsCacheKeeperStorageTestProxy *system=siproxy(@"com.apple.inventory.system",@"System",nil);
    AxsCacheKeeperStorageTestProxy *alpha=siproxy(@"test.inventory.alpha",@"User",shared);
    AxsCacheKeeperStorageTestProxy *beta=siproxy(@"test.inventory.beta",@"User",nil);
    system.groupContainerURLs=@{@"private-group-id-canary":shared};beta.groupContainerURLs=system.groupContainerURLs;
    alpha.plugInKitPlugins=@[siplugin(@"private-plugin-id-canary",alpha.applicationIdentifier,shared),siplugin(@"private-plugin-id-canary",alpha.applicationIdentifier,shared)];
    siregistrations=@[beta,system,alpha];NSMutableDictionary *cache=[NSMutableDictionary new];NSDictionary *registry=nil;
    NSArray *apps=siprovider(cache,&registry);
#if !AXS_CACHEKEEPER_STORAGE_INVENTORY_RED
    siPrivatePlan(cache,shared);
#endif
    NSDate *date=[NSDate dateWithTimeIntervalSince1970:120];
    NSDictionary *states=@{@"test.inventory.alpha":@{@"enabled":@YES,@"autoDiscover":@YES,@"excludedPaths":@[@"Library/Caches/retained"]},@"test.inventory.beta":@NO,@"test.inventory.configured":@YES};
    siput(folder,@"appEnabled.plist",states);siput(folder,@"directories.plist",@{@"test.inventory.alpha":@[@"Library/Caches"],@"test.inventory.beta":@[@"tmp"]});
    NSDictionary *scans=@{
        @"test.inventory.alpha":siscan(@[@{@"path":@"Library/Caches",@"bytes":@100,@"complete":@YES},@{@"path":@"Library/Caches/retained",@"bytes":@80,@"complete":@YES},@{@"path":@"Library/Application Support",@"bytes":@900,@"complete":@YES},@{@"path":@"Library/Logs",@"bytes":@0,@"complete":@YES},@{@"path":@"Cache",@"complete":@NO}],date,YES),
        @"test.inventory.beta":siscan(@[@{@"path":@"tmp",@"bytes":@200,@"complete":@NO},@{@"path":@"Library/Application Support",@"bytes":@900,@"complete":@YES},@{@"path":@"Group/private-account-canary/storage",@"bytes":@400,@"complete":@YES}],date,NO),
        @"com.apple.inventory.system":siscan(@[@{@"path":@"Library/Logs",@"bytes":@300,@"complete":@YES}],date,YES)};
    siput(folder,@"snapshots.plist",scans);
    NSDictionary *image=@{@"schemaVersion":@1,@"sdk":@"SDWebImage",@"state":@"apiCompleted",@"reason":@"none",
        @"observed":@1,@"eligible":@1,@"restricted":@0,@"writesBlocked":@0,@"queued":@1,@"submitted":@1,
        @"apiCompleted":@1,@"skipped":@0,@"pending":@0,@"updated":date,@"bytesState":@"notMeasured"};
    NSDictionary *web=@{@"schemaVersion":@1,@"requested":@YES,@"timedOut":@NO,@"state":@"completed",@"reason":@"none",
        @"persistentStores":@1,@"nonPersistentStores":@0,@"submitted":@1,@"completed":@1,@"pending":@0,@"updated":date,@"bytesState":@"notMeasured"};
    siput(folder,@"Status/test.inventory.alpha.imagecache.plist",image);siput(folder,@"Status/test.inventory.alpha.webkit.plist",web);
    NSDictionary *before=sifiles(folder);
    AxsCacheKeeperDiagnostics *session=[[AxsCacheKeeperDiagnostics alloc] initWithFolder:folder];
    NSDictionary *report=[session reportWithApps:apps environment:registry ? @{@"registryInventory":registry} : @{}];
    NSDictionary *inventory=report[@"storageInventory"];
    // Removing same-pass registry/storage aggregation fails here on the exact old producer.
    sicheck([inventory[@"entries"] count]==4,@"all registrations and configured-only entries survive saved report export");
#if !AXS_CACHEKEEPER_STORAGE_INVENTORY_RED
    sicheck([axs_cachekeeper_platform_cache_scope(@"Library/Caches") isEqual:@"Library/Caches"] &&
        [axs_cachekeeper_platform_cache_scope(@"Library/Caches/ordinary") isEqual:@"Library/Caches"] &&
        [axs_cachekeeper_platform_cache_scope(@"tmp/item") isEqual:@"tmp"] &&
        !axs_cachekeeper_platform_cache_scope(@"Library/CachesExtra") && !axs_cachekeeper_platform_cache_scope(@"Cache") &&
        !axs_cachekeeper_platform_cache_scope(@"../tmp") && axs_cachekeeper_retention_path(@"Library/Caches/account/state"),
        @"single platform scope preserves roots, boundaries and separate necessary-data retention");
    // Names describe an unverified purpose hint, not a proven data contract.
    {
        NSArray *rows=@[@{@"path":@"Library/Caches/authors",@"bytes":@10}];
        NSDictionary *direct=axs_cachekeeper_storage_inventory(nil,@{@"state":@"available",@"data":@{@"test.inventory.names":@{@"enabled":@YES}}},
            @{@"state":@"available",@"data":@{@"test.inventory.names":@[]}},
            @{@"state":@"available",@"data":@{@"test.inventory.names":siscan(rows,date,YES)}},@[],^NSString *(NSString *path){return path;});
        NSDictionary *row=sirow(siapp(direct,@"test.inventory.names"),@"Library/Caches/authors");
        sicheck([row[@"retentionReason"] isEqual:@"nameHintPurposeUnverified"] &&
            [row[@"authorizationState"] isEqual:@"retainedPendingContract"],@"name hint does not establish necessary data or expand deletion");
    }
    sicheck([apps count]==2 && [registry[@"entries"] count]==3,@"system metadata does not widen display filtering");
    sicheck([[inventory[@"entries"] valueForKey:@"bundle"] isEqual:@[@"com.apple.inventory.system",@"test.inventory.alpha",@"test.inventory.beta",@"test.inventory.configured"]],@"bundle union sorted and deduplicated");
    NSDictionary *a=siapp(inventory,@"test.inventory.alpha"),*b=siapp(inventory,@"test.inventory.beta"),*s=siapp(inventory,@"com.apple.inventory.system");
    sicheck([a[@"sdkReceipts"][@"imageDiskCache"][@"receiptState"] isEqual:@"apiCompleted"] &&
        [a[@"sdkReceipts"][@"webKitDiskCache"][@"receiptState"] isEqual:@"completed"] &&
        [a[@"sdkReceipts"][@"webKitDiskCache"][@"resourceContract"] isEqual:@"notEstablishedByReceipt"] &&
        [a[@"contractState"] isEqual:@"noResourceContract"],@"existing closed SDK states survive without class/API-to-contract inference");
    // Inventory consumes saved raw receipts, before report-wide operation aliases are assigned.
    NSDictionary *(^rawSummary)(NSDictionary *)=^NSDictionary *(NSDictionary *receipt) {
        NSArray *raw=@[@{@"bundle":@"test.inventory.alpha",@"imageDiskCache":@{@"state":@"available",@"data":receipt}}];
        NSDictionary *result=axs_cachekeeper_storage_inventory(nil,@{@"state":@"available",@"data":states},
            @{@"state":@"available",@"data":@{}},@{@"state":@"available",@"data":@{}},raw,^NSString *(NSString *path){return path;});
        return siapp(result,@"test.inventory.alpha")[@"sdkReceipts"][@"imageDiskCache"];
    };
    sicheck([rawSummary(image)[@"receiptState"] isEqual:@"apiCompleted"] && [rawSummary(image)[@"sourceUpdated"] isEqual:@120],
        @"inventory summarizes original saved SDK receipt before export transformation");
    NSMutableDictionary *withRejection=[image mutableCopy];
    withRejection[@"instanceAdmission"]=@{@"schemaVersion":@1,@"initializerReturns":@2,@"registered":@1,@"unregistered":@1,@"released":@0,@"overflow":@NO,@"unregisteredReasons":@{@"sdkMethodsChanged":@1},@"liveReasons":@{@"none":@1}};
    NSDictionary *sdkRejection=@{@"schemaVersion":@1,@"state":@"recorded",@"initializerOrdinal":@2,@"check":@{@"schemaVersion":@1,@"accepted":@NO,@"cause":@"methodCount",@"methodIndex":@0,@"methodsCount":@24}};
    withRejection[@"sdkMethodsRejectionObservation"]=sdkRejection;
    sicheck([rawSummary(withRejection)[@"sdkMethodsRejectionObservation"] isEqual:sdkRejection],@"inventory preserves closed frozen rejection diagnostic");
    sicheck([rawSummary(image)[@"sdkMethodsRejectionObservation"] isEqual:@{@"schemaVersion":@1,@"state":@"notRecorded"}],@"legacy inventory keeps rejection detail explicitly not recorded");
    NSDictionary *(^imageCapability)(NSDictionary *)=^NSDictionary *(NSDictionary *receipt) {
        return axs_cachekeeper_capabilities(@{@"image":@{@"state":@"available",@"data":receipt}},@"0.7.2")[@"image"];
    };
    AxsCacheKeeperWriteObservation writeCounts={0};
    uint64_t writerEpoch=axs_cachekeeper_write_epoch_begin(&writeCounts,3,1,true,2);
    axs_cachekeeper_write_observe(&writeCounts,writerEpoch,0,true);
    writerEpoch=axs_cachekeeper_write_epoch_begin(&writeCounts,4,1,false,2);
    axs_cachekeeper_write_observe(&writeCounts,writerEpoch,1,false);
    NSDictionary *writeObservation=axs_cachekeeper_write_observation_record(writeCounts);
    NSMutableDictionary *withWrites=[image mutableCopy];withWrites[@"writeObservation"]=writeObservation;
    sicheck([rawSummary(withWrites)[@"writeObservation"] isEqual:writeObservation] &&
        [imageCapability(withWrites)[@"writeObservation"] isEqual:writeObservation],
        @"inventory and capability preserve the same validated writer epochs without a second counter source");
    sicheck(!rawSummary(image)[@"writeObservation"] && !imageCapability(image)[@"writeObservation"],
        @"legacy summaries never fabricate zero writer epochs");
    NSMutableDictionary *badWrites=[writeObservation mutableCopy];badWrites[@"privateKey"]=@"private-writer-canary";
    withWrites[@"writeObservation"]=badWrites;
    sicheck([rawSummary(withWrites)[@"state"] isEqual:@"invalid"] &&
        [imageCapability(withWrites)[@"sourceState"] isEqual:@"invalid"] &&
        !rawSummary(withWrites)[@"writeObservation"] && !imageCapability(withWrites)[@"writeObservation"],
        @"both summary paths reject invalid writer evidence before copying fields");
    sicheck([imageCapability(image)[@"sdkMethodsRejectionObservation"] isEqual:@{@"schemaVersion":@1,@"state":@"notRecorded"}] &&
        [imageCapability(image)[@"resourceContract"] isEqual:@"notEstablishedByReceipt"] &&
        [imageCapability(image)[@"effectVerification"] isEqual:@"notVerified"],@"legacy capability diagnostic remains not recorded without granting effects or contracts");
    sicheck([imageCapability(withRejection)[@"sdkMethodsRejectionObservation"] isEqual:sdkRejection],@"capability preserves the same frozen rejection as inventory");
    NSMutableDictionary *serializedImage=[image mutableCopy];serializedImage[@"updated"]=@120;
    sicheck([rawSummary(serializedImage)[@"state"] isEqual:@"invalid"],@"exported timestamp cannot masquerade as raw saved SDK receipt");
    sicheck([imageCapability(serializedImage)[@"sourceState"] isEqual:@"invalid"] && !imageCapability(serializedImage)[@"sdkMethodsRejectionObservation"],@"invalid raw capability cannot receive a valid-looking default diagnostic");
    NSMutableDictionary *privateImage=[image mutableCopy];privateImage[@"rawOwner"]=@"private-owner-canary";
    sicheck([rawSummary(privateImage)[@"state"] isEqual:@"invalid"],@"inventory raw boundary rejects private unknown fields");
    sicheck([s[@"registry"][@"displayEligible"] isEqual:@NO] && [s[@"registry"][@"relationships"][@"home"][@"state"] isEqual:@"notProvided"],@"excluded system no independent home remains explicit");
    sicheck([b[@"registry"][@"relationships"][@"group"][@"tokens"] isEqual:s[@"registry"][@"relationships"][@"group"][@"tokens"]] && [a[@"registry"][@"relationships"][@"home"][@"tokens"] isEqual:b[@"registry"][@"relationships"][@"group"][@"tokens"]],@"shared URL equality survives all roles without identifiers");
    sicheck([a[@"registry"][@"relationships"][@"extension"][@"tokens"] count]==1,@"duplicate extension exact URL projects once");
    sirole_contract(registry);
    NSMutableDictionary *injected=[registry mutableCopy];injected[@"rawCanary"]=@"private-registry-canary";
    NSMutableArray *injectedEntries=[registry[@"entries"] mutableCopy];NSMutableDictionary *injectedEntry=[injectedEntries[0] mutableCopy];
    injectedEntry[@"rawHome"]=@"private-registry-canary";NSMutableDictionary *injectedRelations=[injectedEntry[@"relationships"] mutableCopy],*injectedGroup=[injectedRelations[@"group"] mutableCopy];
    injectedGroup[@"rawGroup"]=@"private-registry-canary";injectedRelations[@"group"]=injectedGroup;injectedEntry[@"relationships"]=injectedRelations;injectedEntries[0]=injectedEntry;injected[@"entries"]=injectedEntries;
    sicheck([axs_cachekeeper_registry_inventory_projection(injected) isEqual:registry],@"unknown keys at every registry level are dropped");
    injectedGroup[@"tokens"]=@[@"private-registry-canary"];
    sicheck([axs_cachekeeper_registry_inventory_projection(injected)[@"state"] isEqual:@"invalid"],@"raw token strings reject complete registry projection");
    sicheck([siapp(inventory,@"test.inventory.configured")[@"registryState"] isEqual:@"notInRegistrySnapshot"] && [siapp(inventory,@"test.inventory.configured")[@"scanState"] isEqual:@"notScanned"],@"configured absence is not uninstall or zero scan");
    sicheck([sirow(a,@"Library/Logs")[@"observedLogicalBytes"] isEqual:@0] && [sirow(a,@"Cache")[@"measurementState"] isEqual:@"notMeasured"] && !sirow(a,@"Cache")[@"observedLogicalBytes"],@"zero and unmeasured remain distinct");
    sicheck([sirow(a,@"Library/Caches")[@"sourceUpdated"] isEqual:@120] && [a[@"scanUpdated"] isEqual:@120] && [sirow(a,@"Library/Caches")[@"freshness"] isEqual:@"savedObservationUnverified"],@"collection does not refresh scan time or promote old evidence");
    NSArray *standard=inventory[@"queues"][@"standardPolicyCandidates"],*unknown=inventory[@"queues"][@"unknownResourceEvidence"];
    sicheck(standard.count==3 && [standard[0][@"bundle"] isEqual:@"test.inventory.beta"] && [standard[0][@"observedLogicalBytes"] isEqual:@200] && [standard[0][@"appEnabled"] isEqual:@NO],@"all-app candidates sorted per row and disabled constraint preserved");
    sicheck([standard[1][@"exclusionState"] isEqual:@"childExclusionsRequirePreflight"] && [standard[2][@"exclusionState"] isEqual:@"excluded"] && [standard[2][@"authorizationState"] isEqual:@"notAuthorized"],@"child and whole exclusions remain separate authorization constraints");
    sicheck(unknown.count==5 && [unknown[0][@"bundle"] isEqual:@"test.inventory.alpha"] && [unknown[1][@"bundle"] isEqual:@"test.inventory.beta"] && [unknown.lastObject[@"observedLogicalBytes"] isEqual:@0],@"unknown queue has no allowlist or threshold and deterministic ties");
    for (NSDictionary *row in unknown) sicheck([row[@"authorizationState"] isEqual:@"retainedPendingContract"],@"unknown/shared size does not authorize deletion");
    sicheck([inventory[@"bytesBasis"] isEqual:@"logicalPerPath"] && [inventory[@"physicalBytes"] isEqual:@"notMeasured"] && [inventory[@"reclaimableBytes"] isEqual:@"notMeasured"] && !inventory[@"totalBytes"] && !inventory[@"totalReclaimableBytes"],@"no logical sum masquerades as physical or reclaimable");
    NSData *json=[NSJSONSerialization dataWithJSONObject:report options:0 error:nil];
    NSDictionary *roundtrip=json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
    sicheck([roundtrip[@"storageInventory"] isEqual:inventory],@"real saved plist to report to JSON roundtrip");
    NSString *text=[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    for (NSString *canary in @[@"private-url-canary",@"private-home-canary",@"private-token-canary",@"private-group-canary",@"private-group-path-canary",@"private-group-id-canary",@"private-plugin-id-canary",@"private-account-canary"])
        sicheck(![text containsString:canary],@"no raw URL/group/plugin/account/scan token leak");
    sicheck([before isEqual:sifiles(folder)],@"inventory/queue collection performs zero source writes");
    NSMutableDictionary *badScans=[scans mutableCopy];badScans[@"test.inventory.alpha"]=siscan(@[@{@"path":@"/private/absolute-canary",@"bytes":@900},@{@"path":@"Cache",@"bytes":@(-1)},@{@"path":@"Library/Logs",@"bytes":@"private-invalid-count-canary"}],date,NO);
    siput(folder,@"snapshots.plist",badScans);
    NSDictionary *badReport=[session reportWithApps:apps environment:@{@"registryInventory":registry}],*badInventory=badReport[@"storageInventory"];
    NSArray *badRows=siapp(badInventory,@"test.inventory.alpha")[@"resources"];
    sicheck([badRows[0][@"rowState"] isEqual:@"invalid"] && [badRows[1][@"measurementState"] isEqual:@"invalid"] && !badRows[1][@"observedLogicalBytes"] && !badRows[2][@"observedLogicalBytes"],@"invalid paths/counts cannot become actionable or zero measurements");
    NSData *badJSON=[NSJSONSerialization dataWithJSONObject:badReport options:0 error:nil];NSString *badText=[[NSString alloc] initWithData:badJSON encoding:NSUTF8StringEncoding];
    sicheck(badText && ![badText containsString:@"absolute-canary"] && ![badText containsString:@"private-invalid-count-canary"],@"invalid saved rows do not leak raw paths or count strings");
    siput(folder,@"snapshots.plist",scans);
    siresource_budget(folder,registry,date);
    siput(folder,@"appEnabled.plist",states);siput(folder,@"directories.plist",@{@"test.inventory.alpha":@[@"Library/Caches"],@"test.inventory.beta":@[@"tmp"]});siput(folder,@"snapshots.plist",scans);
    // Matching SDK/type/name is not a resource contract; membership changes require fresh sampling.
    beta.groupContainerURLs=@{};alpha.dataContainerURL=nil;alpha.plugInKitPlugins=@[];
    NSDictionary *boundaryPlan=nil;
    AxsCacheKeeperStorageTestProxy *fresh=siproxy(@"test.inventory.fresh",@"User",nil);siregistrations=@[beta,fresh];apps=siPlanProvider(cache,&registry,&boundaryPlan);
    sicheck([boundaryPlan[@"roots"] count]==0,@"removed owner and changed relationships leave no stale private roots");
    NSDictionary *updated=[session reportWithApps:apps environment:@{@"registryInventory":registry}][@"storageInventory"];
    sicheck(!siapp(updated,@"com.apple.inventory.system") && [siapp(updated,@"test.inventory.alpha")[@"registryState"] isEqual:@"notInRegistrySnapshot"] && [siapp(updated,@"test.inventory.fresh")[@"scanState"] isEqual:@"notScanned"] && [siapp(updated,@"test.inventory.beta")[@"registry"][@"relationships"][@"group"][@"tokens"] count]==0,@"remove/change/new membership uses current registry without stale association reuse");
    alpha.plugInKitPlugins=@[siplugin(@"test.conflict",alpha.applicationIdentifier,shared)];beta.plugInKitPlugins=@[siplugin(@"test.conflict",beta.applicationIdentifier,shared)];
    for (NSArray *order in @[@[alpha,beta],@[beta,alpha],@[alpha,beta,alpha]]) {
        siregistrations=order;siPlanProvider(cache,&registry,&boundaryPlan);
        sicheck([boundaryPlan[@"roots"] count]==0 && [boundaryPlan[@"state"] isEqual:@"partial"],@"conflicting extension ownership revokes private roots in every sample order");
        for (NSDictionary *entry in registry[@"entries"]) sicheck([entry[@"relationships"][@"extension"][@"tokens"] count]==0 && ![entry[@"relationships"][@"extension"][@"state"] isEqual:@"available"],@"conflicting extension ownership revokes all earlier associations");
    }
    beta.plugInKitPlugins=nil;beta.groupContainerURLs=@42;siregistrations=@[beta];siPlanProvider(cache,&registry,&boundaryPlan);
    sicheck([boundaryPlan[@"roots"] count]==0 && [boundaryPlan[@"state"] isEqual:@"partial"],@"missing and malformed metadata do not invent private roots");
    sicheck([registry[@"entries"][0][@"relationships"][@"group"][@"state"] isEqual:@"invalid"] && [registry[@"entries"][0][@"relationships"][@"extension"][@"state"] isEqual:@"unavailable"] && !registry[@"entries"][0][@"relationships"][@"extension"][@"tokens"],@"invalid and nil metadata are not false empty relationships");
    AxsCacheKeeperStorageTestProxy *duplicate=siproxy(beta.applicationIdentifier,@"User",nil);duplicate.groupContainerURLs=nil;duplicate.plugInKitPlugins=nil;
    siregistrations=@[duplicate,beta];siprovider(cache,&registry);
    sicheck([registry[@"entries"][0][@"relationships"][@"group"][@"state"] isEqual:@"invalid"] && !registry[@"entries"][0][@"relationships"][@"group"][@"tokens"],@"duplicate nil/invalid sources cannot become a sampled empty relation");
    AxsCacheKeeperStorageTestProxy *pairA=siproxy(@"test.inventory.pair",@"User",nil),*pairB=siproxy(@"test.inventory.pair.part",@"User",nil);
    NSURL *otherURL=[NSURL URLWithString:@"file:///private/var/private-other-url-canary"];
    pairA.groupContainerURLs=@{@"part.asset":shared};pairB.groupContainerURLs=@{@"asset":otherURL};
    siregistrations=@[pairA,pairB];siPlanProvider(cache,&registry,&boundaryPlan);
    sicheck([boundaryPlan[@"roots"] count]==2,@"distinct owner-group tuples preserve both private URLs");
    sicheck([registry[@"group"][@"associationCount"] isEqual:@2] && [registry[@"group"][@"registeredURLCount"] isEqual:@2],
        @"owner and group components cannot collide when their dot-concatenated names match");
    AxsCacheKeeperStorageTestProxy *conflict=siproxy(pairA.applicationIdentifier,@"User",nil);
    conflict.groupContainerURLs=@{@"part.asset":otherURL};siregistrations=@[pairA,conflict,pairA];siPlanProvider(cache,&registry,&boundaryPlan);
    sicheck([boundaryPlan[@"roots"] count]==0,@"same-owner group URL conflict never leaks revoked private URLs");
    sicheck([registry[@"group"][@"associationCount"] isEqual:@0] && [registry[@"group"][@"invalidAssociationCount"] isEqual:@1],
        @"conflicting same-owner group is revoked and cannot be restored by a repeated earlier sample");
    pairA.groupContainerURLs=@{@"part.asset":otherURL};siregistrations=@[pairA];siPlanProvider(cache,&registry,&boundaryPlan);
    sicheck([boundaryPlan[@"roots"] count]==1 && [boundaryPlan[@"roots"][0][@"url"] isEqual:otherURL],@"same-version relationship change uses only the new private URL");
    NSTimeInterval registrationStarted=NSProcessInfo.processInfo.systemUptime;
    NSMutableArray *many=[NSMutableArray new];for (NSUInteger i=0;i<4097;i++) [many addObject:beta];siregistrations=many;siprovider(cache,&registry);
    sicheck([registry[@"observedRegistrations"] isEqual:@4096] && [registry[@"truncatedRegistrationCount"] isEqual:@1] && [registry[@"state"] isEqual:@"partial"],@"registration budget exposes lower-bound coverage");
    sitiming("4097 registrations",registrationStarted);registrationStarted=NSProcessInfo.processInfo.systemUptime;
    NSMutableDictionary *groups=[NSMutableDictionary new];for (NSUInteger i=0;i<16385;i++) groups[[NSString stringWithFormat:@"test.group.%lu",(unsigned long)i]]=shared;
    beta.groupContainerURLs=groups;beta.plugInKitPlugins=@[];siregistrations=@[beta];siprovider(cache,&registry);
    sicheck([registry[@"entries"][0][@"relationships"][@"group"][@"state"] isEqual:@"partial"] && [registry[@"group"][@"truncatedCount"] unsignedIntegerValue]>0,@"role budget remains explicit even when URL tokens deduplicate");
    sitiming("16385 group associations",registrationStarted);
    beta.applicationIdentifier=@"../private-invalid-id-canary";siregistrations=@[beta];siprovider(cache,&registry);
    sicheck([registry[@"invalidRegistrationCount"] isEqual:@1] && [registry[@"entries"] count]==0,@"invalid registry identities excluded explicitly");
    siregistrations=nil;boundaryPlan=@{@"privateCanary":shared};siPlanProvider(cache,&registry,&boundaryPlan);
    sicheck(boundaryPlan==nil,@"unavailable provider clears previously supplied private plan");
    sicheck([registry[@"state"] isEqual:@"unavailable"] && !registry[@"entries"],@"nil registry source is not observed empty");
    siregistrations=@[];siPlanProvider(cache,&registry,&boundaryPlan);
    sicheck([boundaryPlan[@"state"] isEqual:@"available"] && [boundaryPlan[@"roots"] count]==0,@"observed empty provider returns an explicit empty current plan");
    sicheck([registry[@"state"] isEqual:@"available"] && [registry[@"entries"] count]==0,@"observed empty registry remains distinct from unavailable");
    puts("PASS: all-app registry, saved logical inventory, queues, boundaries and JSON roundtrip");
#endif
    // Allocation is an independent observation: old records, invalid metadata and malformed
    // schemas cannot become reliable disk allocation, physical bytes or deletion permission.
#if !AXS_CACHEKEEPER_STORAGE_INVENTORY_RED
    sicheck([siapp(inventory,@"test.inventory.alpha")[@"allocationState"] isEqual:@"notMeasured"] &&
        !siapp(inventory,@"test.inventory.alpha")[@"allocationObservation"],@"old saved records remain explicitly unmeasured for allocation");
    NSDictionary *allocation=@{@"schemaVersion":@1,@"scope":@"taskUniqueRegularFileInodeFirstObservation",@"state":@"complete",@"allocatedBytes":@4096,
        @"uniqueFiles":@1,@"duplicateFiles":@0,@"untrackedFiles":@0,@"inodeBudget":@65536};
    NSMutableDictionary *allocationScan=[siscan(@[@{@"path":@"Library/Caches",@"bytes":@17,@"allocationObservation":allocation}],date,YES) mutableCopy];
    allocationScan[@"allocationObservation"]=allocation;
    NSDictionary *(^allocationInventory)(id)=^NSDictionary *(id observation) {
        NSMutableDictionary *scan=[allocationScan mutableCopy];scan[@"allocationObservation"]=observation;
        scan[@"rows"]=@[@{@"path":@"Library/Caches",@"bytes":@17,@"allocationObservation":observation}];
        return axs_cachekeeper_storage_inventory(registry,@{@"state":@"available",@"data":states},@{@"state":@"available",@"data":@{}},
            @{@"state":@"available",@"data":@{@"test.inventory.alpha":scan}},@[],^NSString *(NSString *p){return p;});
    };
    NSDictionary *allocated=siapp(allocationInventory(allocation),@"test.inventory.alpha");
    sicheck([allocated[@"allocationObservation"][@"allocatedBytes"] isEqual:@4096] &&
        [sirow(allocated,@"Library/Caches")[@"observedLogicalBytes"] isEqual:@17] &&
        [sirow(allocated,@"Library/Caches")[@"physicalBytes"] isEqual:@"notMeasured"],@"logical and allocated remain distinct; physical unmeasured");
    NSMutableDictionary *invalidAllocation=[allocation mutableCopy];invalidAllocation[@"state"]=@"invalidMetadata";
    NSDictionary *invalidAllocated=siapp(allocationInventory(invalidAllocation),@"test.inventory.alpha");
    sicheck([invalidAllocated[@"allocationState"] isEqual:@"invalidMetadata"] && !invalidAllocated[@"allocationObservation"] &&
        !sirow(invalidAllocated,@"Library/Caches")[@"allocationObservation"],@"invalid metadata hides untrusted allocation numbers");
    invalidAllocation[@"scope"]=@"private-allocation-canary";
    sicheck([siapp(allocationInventory(invalidAllocation),@"test.inventory.alpha")[@"allocationState"] isEqual:@"invalid"],@"malformed allocation scope fails closed");
    sicheck([allocationInventory(allocation)[@"allocationAggregation"] isEqual:@"notSummedAcrossApps"] &&
        [allocationInventory(allocation)[@"cleanupEligibility"] isEqual:@"notGrantedByInventory"],@"allocation never sums apps or grants deletion");
    for (NSArray *fixture in @[@[allocation,@"complete"],@[@{@"schemaVersion":@1,@"scope":@"taskUniqueRegularFileInodeFirstObservation",@"state":@"invalidMetadata",
        @"allocatedBytes":@4096,@"uniqueFiles":@1,@"duplicateFiles":@0,@"untrackedFiles":@0,@"inodeBudget":@65536},@"invalidMetadata"],
        @[invalidAllocation,@"invalid"]]) {
        NSMutableDictionary *scan=[allocationScan mutableCopy];scan[@"allocationObservation"]=fixture[0];
        scan[@"rows"]=@[@{@"path":@"Library/Caches",@"bytes":@17,@"allocationObservation":fixture[0]}];
        siput(folder,@"snapshots.plist",@{@"test.inventory.alpha":scan});
        NSDictionary *exportedScan=nil;
        for (NSDictionary *app in [session reportWithApps:apps environment:@{}][@"apps"])
            if ([app[@"bundle"] isEqual:@"test.inventory.alpha"]) exportedScan=app[@"scan"][@"data"];
        NSDictionary *projection=exportedScan[@"allocationObservation"];
        sicheck([projection[@"state"] isEqual:fixture[1]],@"saved plist report keeps strict task allocation state");
        if (![fixture[1] isEqual:@"complete"]) sicheck(projection.count==1 && [exportedScan[@"rows"][0][@"allocationObservation"] count]==1,
            @"saved task and row exports suppress invalid allocation numbers");
        NSString *json=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:exportedScan options:0 error:nil] encoding:NSUTF8StringEncoding];
        sicheck(json && ![json containsString:@"private-allocation-canary"],@"malformed allocation scope never leaks in report JSON");
    }
    siput(folder,@"snapshots.plist",scans);
#endif
    return 0;
}}
