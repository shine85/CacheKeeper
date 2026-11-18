#import "AxsCacheKeeperStorageInventory.h"
#import "AxsCacheKeeperInstallation.h"
#import "AxsCacheKeeperPolicy.h"
#import "AxsCacheKeeperScanDiagnostics.h"
#import "AxsCacheKeeperImageCacheStatus.h"
#import "AxsCacheKeeperWebKitStatus.h"
#import "AxsCacheKeeperHostEvidence.h"
#import "AxsCacheKeeperRecords.h"
#import "AxsCacheKeeperAllocation.h"

static BOOL axs_cachekeeper_inventory_count(id value) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()) return NO;
    double number=[value doubleValue];return isfinite(number) && number>=0 && trunc(number)==number && number<=9007199254740991.0;
}
static NSNumber *axs_cachekeeper_inventory_time(id value) {
    if (![value isKindOfClass:NSDate.class]) return nil;
    NSTimeInterval time=[value timeIntervalSince1970];return isfinite(time) && time>=0 ? @(time) : nil;
}
static NSString *axs_cachekeeper_inventory_source(id envelope) {
    if (![envelope isKindOfClass:NSDictionary.class] || ![@[@"available",@"missing",@"unreadable",@"invalid"] containsObject:envelope[@"state"]]) return @"invalid";
    if ([envelope[@"state"] isEqual:@"available"] && ![envelope[@"data"] isKindOfClass:NSDictionary.class]) return @"invalid";
    return envelope[@"state"];
}
static NSString *axs_cachekeeper_inventory_display_path(id path,NSString *(^redactor)(NSString *)) {
    NSString *display=redactor ? redactor(path) : nil;
    return [display isKindOfClass:NSString.class] && display.length ? display : @"<路径未提供>";
}
static NSDictionary *axs_cachekeeper_inventory_sdk(id wrapper,BOOL image) {
    if (![wrapper isKindOfClass:NSDictionary.class]) return @{@"state":@"notObserved"};
    if (![@[@"available",@"missing",@"unreadable",@"invalid"] containsObject:wrapper[@"state"]]) return @{@"state":@"invalid"};
    NSMutableDictionary *out=[@{@"state":wrapper[@"state"],@"source":@"savedRecords",@"resourceContract":@"notEstablishedByReceipt"} mutableCopy];
    if (![wrapper[@"state"] isEqual:@"available"]) return out;
    NSDictionary *data=wrapper[@"data"];if (![data isKindOfClass:NSDictionary.class]) return @{@"state":@"invalid"};
    // Validate the saved record before export replaces internal operation identities with aliases.
    // Presence, method discovery or API completion never becomes container cleanup support.
    NSDictionary *projected=image ? axs_cachekeeper_image_cache_raw_projection(data) : axs_cachekeeper_webkit_raw_projection(data);
    if (!projected) return @{@"state":@"invalid"};
    NSNumber *time=axs_cachekeeper_inventory_time(projected[@"updated"]);
    if (!time) return @{@"state":@"invalid"};
    out[@"receiptState"]=projected[@"state"];out[@"sourceUpdated"]=time;
    for (NSString *key in image ? @[@"observed",@"eligible",@"restricted",@"writesBlocked",@"queued",@"submitted",@"apiCompleted",@"skipped",@"pending"] : @[@"persistentStores",@"nonPersistentStores",@"submitted",@"completed",@"pending"])
        if (axs_cachekeeper_inventory_count(projected[key])) out[key]=projected[key];
    for (NSString *key in @[@"runtimeInfo",@"discoveryCheck",@"runtimeSourceObservation",@"installedRuntimeRelation",@"installationCheck",@"reason"]) if (projected[key]) out[key]=projected[key];
    out[@"bytesState"]=@"notMeasured";return [out copy];
}
// A pure view over this report's raw reads. Version and observation axes stay independent.
NSDictionary *axs_cachekeeper_capabilities(NSDictionary *raw,NSString *panelVersion) {
    NSMutableDictionary *out=[NSMutableDictionary new];
    for (NSString *key in @[@"standardDirectories",@"network",@"image",@"webKit",@"hostAutomatic",@"hostObserved"]) {
        NSDictionary *envelope=raw[key];NSString *source=axs_cachekeeper_inventory_source(envelope);
        NSMutableDictionary *entry=[@{@"sourceState":source,@"observationScope":@"savedRecords",@"runtimeVersionState":@"notRecorded",@"resourceContract":@"notEstablishedByReceipt",@"effectVerification":@"notVerified"} mutableCopy];
        NSDictionary *data=nil;
        if ([source isEqual:@"available"]) {
            if ([key isEqual:@"network"]) data=axs_cachekeeper_network_projection(envelope[@"data"]);
            else if ([key isEqual:@"image"]) data=axs_cachekeeper_image_cache_raw_projection(envelope[@"data"]);
            else if ([key isEqual:@"webKit"]) data=axs_cachekeeper_webkit_raw_projection(envelope[@"data"]);
            else if ([key isEqual:@"hostAutomatic"]) data=axs_cachekeeper_host_projection(envelope[@"data"]);
            else if ([key isEqual:@"hostObserved"]) data=axs_cachekeeper_host_observed_projection(envelope[@"data"]);
            else data=axs_cachekeeper_record_valid(envelope[@"data"],0) ? envelope[@"data"] : nil;
            if (!data) entry[@"sourceState"]=@"invalid";
        }
        if (data) {
            id updated=data[@"updated"];NSNumber *time=[updated isKindOfClass:NSDate.class] ? axs_cachekeeper_inventory_time(updated) : ([updated isKindOfClass:NSNumber.class] ? updated : nil);
            if (time) entry[@"sourceUpdated"]=time;
            NSDictionary *runtime=data[@"runtimeInfo"];
            if ([key isEqual:@"hostObserved"]) {
                entry[@"observationState"]=data[@"state"];
                if ([data[@"state"] isEqual:@"observed"]) runtime=data[@"data"][@"runtimeInfo"];
            }
            entry[@"runtimeVersionState"]=axs_cachekeeper_host_version_state(runtime,panelVersion);
            NSDictionary *runtimeProjection=axs_cachekeeper_runtime_info_projection(runtime);
            if (runtimeProjection) entry[@"runtimeInfo"]=runtimeProjection;
            if ([key isEqual:@"standardDirectories"]) {
                for (NSString *field in @[@"complete",@"coverageComplete",@"measurementComplete"]) if (axs_cachekeeper_input_boolean(data[field])) entry[field]=@([data[field] boolValue]);
                NSDictionary *progress=axs_cachekeeper_scan_progress_projection(data[@"scanProgress"]),*diagnostics=axs_cachekeeper_scan_diagnostics_projection(data[@"scanDiagnostics"]);
                if (progress) entry[@"scanProgress"]=progress;if (diagnostics) entry[@"scanDiagnostics"]=diagnostics;
            } else for (NSString *field in @[@"state",@"reason",@"discoveryCheck",@"runtimeSourceObservation",@"installedRuntimeRelation",@"installationCheck",@"prevent",@"applied",@"submitted",@"completed",@"apiCompleted",@"pending",@"observed",@"eligible",@"restricted",@"writesBlocked"])
                if (data[field]) entry[field]=data[field];
            if ([key isEqual:@"network"]) entry[@"actionState"]=data[@"policyObservation"] ?: ([data[@"prevent"] boolValue] ? ([data[@"applied"] boolValue] ? @"restrictionReported" : @"restrictionNotApplied") : ([data[@"applied"] boolValue] ? @"unrestrictedOrRestoreReported" : @"restorePending"));
            if ([key isEqual:@"image"] || [key isEqual:@"webKit"]) entry[@"actionState"]=data[@"state"];
            if ([key isEqual:@"standardDirectories"]) entry[@"resourceContract"]=@"standardDirectoryRulesOnly";
        }
        out[key]=entry;
    }
    return out;
}
static NSArray *axs_cachekeeper_inventory_sorted_queue(NSArray *rows) {
    NSArray *sorted=[rows sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b) {
        unsigned long long left=[a[@"observedLogicalBytes"] unsignedLongLongValue],right=[b[@"observedLogicalBytes"] unsignedLongLongValue];
        if (left!=right) return left>right ? NSOrderedAscending : NSOrderedDescending;
        NSComparisonResult order=[a[@"bundle"] compare:b[@"bundle"]];if (order) return order;
        order=[a[@"path"] compare:b[@"path"]];if (order) return order;
        return [a[@"observationIndex"] compare:b[@"observationIndex"]];
    }];return sorted;
}
NSDictionary *axs_cachekeeper_storage_inventory(id registryInventory,NSDictionary *statesRead,
    NSDictionary *directoriesRead,NSDictionary *snapshotsRead,NSArray *savedSDKApps,NSString *(^pathRedactor)(NSString *)) {
    NSDictionary *registry=axs_cachekeeper_registry_inventory_projection(registryInventory);
    BOOL registryObserved=[@[@"available",@"partial"] containsObject:registry[@"state"]];
    NSMutableDictionary *registered=[NSMutableDictionary new],*sdkRecords=[NSMutableDictionary new];
    NSMutableSet *bundles=[NSMutableSet new];
    for (NSDictionary *entry in registry[@"entries"]) {registered[entry[@"bundle"]]=entry;[bundles addObject:entry[@"bundle"]];}
    NSString *configurationSource=axs_cachekeeper_inventory_source(statesRead),*selectionSource=axs_cachekeeper_inventory_source(directoriesRead),
        *scanSource=axs_cachekeeper_inventory_source(snapshotsRead);
    NSDictionary *states=[configurationSource isEqual:@"available"] ? statesRead[@"data"] : @{},
        *directories=[selectionSource isEqual:@"available"] ? directoriesRead[@"data"] : @{},
        *scans=[scanSource isEqual:@"available"] ? snapshotsRead[@"data"] : @{};
    for (NSDictionary *source in @[states,directories]) for (id bundle in source) if (axs_cachekeeper_bundle_id(bundle)) [bundles addObject:bundle];
    if ([savedSDKApps isKindOfClass:NSArray.class]) for (id app in savedSDKApps)
        if ([app isKindOfClass:NSDictionary.class] && axs_cachekeeper_bundle_id(app[@"bundle"])) sdkRecords[app[@"bundle"]]=app;
    NSMutableArray *entries=[NSMutableArray new],*standard=[NSMutableArray new],*unknown=[NSMutableArray new];
    for (NSString *bundle in [bundles.allObjects sortedArrayUsingSelector:@selector(compare:)]) { @autoreleasepool {
        id state=states[bundle],selection=directories[bundle],scan=scans[bundle];
        BOOL stateValid=!state || axs_cachekeeper_state_valid(state),selectionValid=!selection || axs_cachekeeper_input_strings(selection,axs_cachekeeper_relative_path);
        BOOL configAvailable=stateValid && [@[@"available",@"missing"] containsObject:configurationSource],
            selectionAvailable=selectionValid && [@[@"available",@"missing"] containsObject:selectionSource];
        BOOL enabled=configAvailable && axs_cachekeeper_app_enabled(state);
        NSMutableDictionary *entry=[@{@"bundle":bundle,@"registryState":registered[bundle] ? @"registered" : registryObserved ? @"notInRegistrySnapshot" : @"registryUnavailable",
            @"configurationState":!stateValid ? @"invalid" : state ? configurationSource : [configurationSource isEqual:@"available"] ? @"missing" : configurationSource,
            @"selectionState":!selectionValid ? @"invalid" : selection ? selectionSource : [selectionSource isEqual:@"available"] ? @"missing" : selectionSource,
            @"configurationPresent":@(state!=nil),@"selectionPresent":@(selection!=nil),@"appEnabled":@(enabled),
            @"contractState":@"noResourceContract",@"observationMode":@"savedRecords",@"currentInstallationMatch":@"notChecked",
            @"sdkReceipts":@{@"imageDiskCache":axs_cachekeeper_inventory_sdk(sdkRecords[bundle][@"imageDiskCache"],YES),@"webKitDiskCache":axs_cachekeeper_inventory_sdk(sdkRecords[bundle][@"webKitDiskCache"],NO)}} mutableCopy];
        if (registered[bundle]) entry[@"registry"]=registered[bundle];
        BOOL scanValid=[scan isKindOfClass:NSDictionary.class] && [scan[@"rows"] isKindOfClass:NSArray.class];
        entry[@"scanState"]=scan ? (scanValid ? @"savedObservation" : @"invalid") : [scanSource isEqual:@"available"] || [scanSource isEqual:@"missing"] ? @"notScanned" : scanSource;
        NSNumber *updated=scanValid ? axs_cachekeeper_inventory_time(scan[@"updated"]) : nil;
        if (updated) entry[@"scanUpdated"]=updated;entry[@"scanTimeState"]=updated ? @"available" : @"notRecorded";
        if (scanValid && axs_cachekeeper_input_boolean(scan[@"complete"])) entry[@"scanComplete"]=scan[@"complete"];
        NSDictionary *allocation=scanValid ? axs_cachekeeper_allocation_projection(scan[@"allocationObservation"]) : nil;
        entry[@"allocationState"]=allocation ? allocation[@"state"] : scanValid && scan[@"allocationObservation"] ? @"invalid" : @"notMeasured";
        if (allocation && ![allocation[@"state"] isEqual:@"invalidMetadata"]) entry[@"allocationObservation"]=allocation;
        NSDictionary *scanDiagnostics=scanValid ? axs_cachekeeper_scan_diagnostics_projection(scan[@"scanDiagnostics"]) : nil;
        if (scanDiagnostics) entry[@"scanDiagnostics"]=scanDiagnostics;
        else if (scanValid && scan[@"scanDiagnostics"]) entry[@"scanDiagnosticsState"]=@"invalid";
        NSMutableArray *resources=[NSMutableArray new];NSUInteger count=0;
        NSArray *rows=scanValid ? scan[@"rows"] : @[];
        NSUInteger limit=MIN(rows.count,(NSUInteger)16384);
        NSMutableSet *discovered=[NSMutableSet new];NSArray *cacheRoots=axs_cachekeeper_cache_roots();
        for (NSUInteger index=0;index<limit;index++) {
            id candidate=rows[index];
            if ([candidate isKindOfClass:NSDictionary.class] && [cacheRoots containsObject:candidate[@"path"] ?: NSNull.null]) [discovered addObject:candidate[@"path"]];
        }
        NSArray *exclusions=axs_cachekeeper_exclusions(state),*selectedPaths=selectionValid ? axs_cachekeeper_cache_paths(selection) : @[];
        NSArray *effectivePaths=configAvailable && selectionAvailable ? axs_cachekeeper_effective_paths(selection,state,[discovered.allObjects sortedArrayUsingSelector:@selector(compare:)]) : @[];
        entry[@"discoveryRowsExamined"]=@(limit);entry[@"discoveryRowsTruncated"]=@(rows.count>limit);entry[@"discoveredRootCount"]=@(discovered.count);
        for (NSUInteger index=0;index<limit;index++) {
            id sourceRow=rows[index];
            BOOL valid=[sourceRow isKindOfClass:NSDictionary.class];id rawPath=valid ? sourceRow[@"path"] : nil;
            BOOL pathValid=axs_cachekeeper_relative_path(rawPath);
            BOOL measured=valid && axs_cachekeeper_inventory_count(sourceRow[@"bytes"]);
            NSString *path=axs_cachekeeper_inventory_display_path(rawPath,pathRedactor);
            BOOL shared=pathValid && [rawPath hasPrefix:@"Group/"],retained=pathValid && axs_cachekeeper_retention_path(rawPath);
            NSString *scope=pathValid && !shared && !retained ? axs_cachekeeper_platform_cache_scope(rawPath) : nil;
            NSString *kind=pathValid ? axs_cachekeeper_directory_kind(rawPath) : @"invalid";
            NSMutableDictionary *row=[@{@"bundle":bundle,@"path":path,@"observationIndex":@(count++),@"bytesBasis":@"logicalPerPath",
                @"measurementState":measured ? @"observed" : valid && sourceRow[@"bytes"] ? @"invalid" : @"notMeasured",
                @"freshness":@"savedObservationUnverified",@"currentInstallationMatch":@"notChecked",@"physicalBytes":@"notMeasured",@"reclaimableBytes":@"notMeasured",
                @"hardLinkDeduplication":@"notMeasured",@"coverageState":@"notRecorded",@"resourceKind":kind,@"appEnabled":@(enabled),
                @"contractState":scope ? @"standardDirectoryPolicy" : @"noResourceContract",@"authorizationState":@"retainedPendingContract"} mutableCopy];
            NSDictionary *rowAllocation=valid ? axs_cachekeeper_allocation_projection(sourceRow[@"allocationObservation"]) : nil;
            row[@"allocationState"]=rowAllocation ? rowAllocation[@"state"] : valid && sourceRow[@"allocationObservation"] ? @"invalid" : @"notMeasured";
            if (rowAllocation && ![rowAllocation[@"state"] isEqual:@"invalidMetadata"]) row[@"allocationObservation"]=rowAllocation;
            row[@"scanCoverageState"]=scanDiagnostics ? ([scanDiagnostics[@"measurementComplete"] boolValue] ? @"completeAtObservation" : @"partialAtObservation") :
                axs_cachekeeper_input_boolean(scan[@"complete"]) ? ([scan[@"complete"] boolValue] ? @"completeAtObservation" : @"partialAtObservation") : @"notRecorded";
            if (!pathValid || !valid) row[@"rowState"]=@"invalid";else row[@"rowState"]=@"savedObservation";
            if (measured) row[@"observedLogicalBytes"]=sourceRow[@"bytes"];
            if (updated) row[@"sourceUpdated"]=updated;
            row[@"sourceTimeState"]=updated ? @"available" : @"notRecorded";
            if (valid && axs_cachekeeper_input_boolean(sourceRow[@"complete"])) row[@"coverageState"]=[sourceRow[@"complete"] boolValue] ? @"completeAtObservation" : @"partialAtObservation";
            NSDictionary *diagnostics=valid ? axs_cachekeeper_scan_diagnostics_projection(sourceRow[@"scanDiagnostics"]) : nil;
            if (diagnostics) {row[@"scanDiagnostics"]=diagnostics;row[@"coverageState"]=[diagnostics[@"measurementComplete"] boolValue] ? @"completeAtObservation" : @"partialAtObservation";}
            else if (valid && sourceRow[@"scanDiagnostics"]) row[@"coverageState"]=@"invalid";
            if (shared) row[@"retentionReason"]=@"sharedContainerReadOnly";
            else if (retained) row[@"retentionReason"]=@"necessaryData";
            else row[@"retentionReason"]=@"purposeOwnerRecoveryContractMissing";
            if (scope) {
                row[@"policyReference"]=@{@"ruleID":axs_cachekeeper_platform_cache_rule_id(),@"ruleRevision":axs_cachekeeper_platform_cache_rule_revision(),@"scope":scope};
                BOOL excluded=NO,childExcluded=NO,selected=NO;
                for (NSString *ex in exclusions) {if (axs_cachekeeper_path_inside(rawPath,ex)) excluded=YES;else if (axs_cachekeeper_path_inside(ex,rawPath)) childExcluded=YES;}
                for (NSString *candidate in selectedPaths) if (axs_cachekeeper_path_inside(rawPath,candidate)) selected=YES;
                BOOL effective=NO;
                for (NSString *candidate in effectivePaths)
                    if (axs_cachekeeper_path_inside(rawPath,candidate)) effective=YES;
                row[@"selected"]=@(selected);row[@"autoDiscoveryEnabled"]=@(configAvailable && axs_cachekeeper_auto_discover(state));
                row[@"exclusionState"]=!configAvailable ? @"configurationUnavailable" : excluded ? @"excluded" : childExcluded ? @"childExclusionsRequirePreflight" : @"none";
                row[@"authorizationState"]=configAvailable && selectionAvailable && enabled && effective && !excluded ? @"configuredPendingExecutionPreflight" : @"notAuthorized";
                row[@"executionPreflight"]=@[@"currentInstallationAndContainerIdentity",@"freshRulesSelectionAndExclusions",@"actualFilePurposeAndRetention",@"ageProcessAndInFlight",@"postActionAndRecoveryVerification"];
                row[@"actuallyReclaimable"]=@"notMeasured";row[@"retentionReason"]=@"executionPreflightRequired";
                if (measured) [standard addObject:[row copy]];
            } else if (measured && pathValid) [unknown addObject:[row copy]];
            [resources addObject:[row copy]];
        }
        entry[@"resources"]=resources;entry[@"resourceRowsTruncated"]=@(rows.count>resources.count);
        entry[@"omittedResourceRows"]=@(rows.count-resources.count);[entries addObject:entry];
    }}
    return @{@"schemaVersion":@1,@"scope":@"allSystemRegistrationsAndConfiguredEntries",@"mode":@"savedRecordsWithCurrentSystemMetadata",
        @"registry":registry,@"sourceStates":@{@"configuration":configurationSource,@"selection":selectionSource,@"snapshots":scanSource},
        @"entries":entries,@"queues":@{@"standardPolicyCandidates":axs_cachekeeper_inventory_sorted_queue(standard),@"unknownResourceEvidence":axs_cachekeeper_inventory_sorted_queue(unknown)},
        @"queueOrder":@"observedLogicalBytesDescendingThenBundlePathIndex",@"bytesBasis":@"logicalPerPath",@"hardLinkDeduplication":@"notMeasured",
        @"physicalBytes":@"notMeasured",@"reclaimableBytes":@"notMeasured",@"rescanned":@NO,@"cleanupEligibility":@"notGrantedByInventory",
        @"allocationAggregation":@"notSummedAcrossApps",@"allocationLimitations":@[@"regularFilesOnly",@"firstInodeObservationWithinTask",@"crossAppReferencesNotDeduplicated",@"APFSCloneSnapshotAndOpenHandleOwnershipUnknown"],
        @"capabilityGaps":@[@"containerSubtreeAccessAndBusinessReferencesNotVerified",@"freshMeasurementAndInstallationBinding",@"crossAppResourcePurposeOwnerRecoveryContracts",@"persistentContractInvalidationAndRevalidation",@"sharedContainerOwnershipAndAuthorization",@"crossAppInodeAndAPFSCloneSnapshotDeduplication",@"physicalEffectAttributionAndDeviceRecoveryVerification"]};
}
