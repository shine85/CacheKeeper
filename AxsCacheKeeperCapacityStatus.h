#pragma once
#import <Foundation/Foundation.h>
#import "AxsCacheKeeperInstallation.h"
#import "AxsCacheKeeperFileAccess.h"
#include <math.h>
#include "AxsCacheKeeperResourceLayout.h"

static inline AxsCacheKeeperResourceCategory axs_cachekeeper_capacity_category(id value) {
    if (![value isKindOfClass:NSString.class]) return AxsCacheKeeperResourceCategoryCount;
    const char *text=[value UTF8String];if (!text) return AxsCacheKeeperResourceCategoryCount;
    size_t length=[value lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    for (int i=0;i<AxsCacheKeeperResourceCategoryCount;i++) {
        const char *name=axs_cachekeeper_resource_category_name((AxsCacheKeeperResourceCategory)i);
        if (length==strlen(name) && !memcmp(text,name,length)) return (AxsCacheKeeperResourceCategory)i;
    }
    return AxsCacheKeeperResourceCategoryCount;
}

// Closed, path-free saved observations; one spelling at both schema levels.
static inline BOOL axs_cachekeeper_capacity_number(id value) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()) return NO;
    double number=[value doubleValue];
    return isfinite(number) && number>=0 && number<=9007199254740991.0 && floor(number)==number;
}
static inline BOOL axs_cachekeeper_capacity_epoch(id value) {
    return [value isKindOfClass:NSString.class] && [value length]==36 &&
        [[[NSUUID alloc] initWithUUIDString:value].UUIDString isEqual:value];
}
// Cursor scope is deliberately absent: the enclosing root carries the actual
// home/group/extension roles. Never export the cursor default home as evidence.
static inline NSDictionary *axs_cachekeeper_capacity_cursor_errors(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    NSMutableDictionary *out=[NSMutableDictionary new];
    for (NSString *key in @[@"enumerationErrors",@"statErrors",@"omittedErrorCount"]) {
        if (!axs_cachekeeper_capacity_number(value[key]) || [value[key] unsignedLongLongValue]>UINT32_MAX) return nil;out[key]=value[key];
    }
    id truncated=value[@"errorsTruncated"];
    if (![truncated isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)truncated)!=CFBooleanGetTypeID() ||
        (![truncated boolValue] && [out[@"omittedErrorCount"] unsignedLongLongValue]) ||
        ![value[@"errors"] isKindOfClass:NSArray.class] || [value[@"errors"] count]>16) return nil;
    NSMutableArray *errors=[NSMutableArray new];uint64_t enumerated=0,statted=0;
    for (id item in value[@"errors"]) {
        if (![item isKindOfClass:NSDictionary.class] || ![@[@"entryStat",@"enumerate"] containsObject:item[@"stage"]] ||
            ![@[@"identityChanged",@"permissionDenied",@"readFailure"] containsObject:item[@"reason"]] || ![item[@"errorDomain"] isEqual:@"posix"] ||
            !axs_cachekeeper_capacity_number(item[@"errorCode"]) || [item[@"errorCode"] unsignedLongLongValue]>255 ||
            !axs_cachekeeper_capacity_number(item[@"count"]) || ![item[@"count"] unsignedLongLongValue] || [item[@"count"] unsignedLongLongValue]>UINT32_MAX) return nil;
        [errors addObject:@{@"stage":item[@"stage"],@"reason":item[@"reason"],@"errorDomain":@"posix",@"errorCode":item[@"errorCode"],@"count":item[@"count"]}];
        if ([item[@"stage"] isEqual:@"enumerate"]) enumerated+=[item[@"count"] unsignedLongLongValue];
        else statted+=[item[@"count"] unsignedLongLongValue];
    }
    uint64_t enumeration=[out[@"enumerationErrors"] unsignedLongLongValue],stat=[out[@"statErrors"] unsignedLongLongValue],omitted=[out[@"omittedErrorCount"] unsignedLongLongValue];
    if (![truncated boolValue]) {
        if (enumerated!=enumeration || statted!=stat) return nil;
    } else {
        // Saturated stage totals are lower bounds. Detail sums can exceed them;
        // omissions have no stage, and their own counter may also saturate.
        BOOL saturated=enumeration==UINT32_MAX || stat==UINT32_MAX;
        if ((enumeration<UINT32_MAX && enumerated>enumeration) || (stat<UINT32_MAX && statted>stat)) return nil;
        uint64_t missing=(enumeration>enumerated ? enumeration-enumerated : 0)+(stat>statted ? stat-statted : 0);
        if ((!omitted && !saturated) || (omitted<UINT32_MAX ? omitted<missing || (!saturated && omitted!=missing) : !saturated && missing<UINT32_MAX)) return nil;
    }
    out[@"errorsTruncated"]=truncated;out[@"errors"]=errors;return [out copy];
}
static inline NSDictionary *axs_cachekeeper_capacity_source_failure(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    NSString *stage=value[@"stage"],*reason=value[@"reason"];
    BOOL input=[stage isEqual:@"inputValidation"] && [reason isEqual:@"invalidRoot"];
    BOOL source=[stage isEqual:@"sourceStat"] && [@[@"statFailed",@"notDirectory"] containsObject:reason];
    BOOL alias=[stage isEqual:@"aliasRecheck"] && [@[@"statFailed",@"notDirectory",@"identityChanged"] containsObject:reason];
    if (!input && !source && !alias) return nil;
    NSMutableDictionary *out=[@{@"stage":stage,@"reason":reason} mutableCopy];
    if ([reason isEqual:@"statFailed"]) {
        if (![value[@"errorDomain"] isEqual:@"posix"] || !axs_cachekeeper_capacity_number(value[@"errorCode"]) ||
            ![value[@"errorCode"] unsignedLongLongValue] || [value[@"errorCode"] unsignedLongLongValue]>INT32_MAX) return nil;
        out[@"errorDomain"]=@"posix";out[@"errorCode"]=value[@"errorCode"];
    } else {
        if (![value[@"errorDomain"] isEqual:@"none"] || value[@"errorCode"]) return nil;out[@"errorDomain"]=@"none";
    }
    return [out copy];
}
static inline NSDictionary *axs_cachekeeper_capacity_failure(id value) {
    if (![value isKindOfClass:NSDictionary.class] ||
        ![@[@"provider",@"source",@"root",@"publication"] containsObject:value[@"stage"]] ||
        ![@[@"unavailable",@"invalidPlan",@"sourceBudget",@"rootBudget",@"nodeBudget",@"resultBudget",@"resultSchema",@"identityChanged",@"writeFailed"] containsObject:value[@"code"]]) return nil;
    return @{@"stage":value[@"stage"],@"code":value[@"code"]};
}
static inline NSDictionary *axs_cachekeeper_capacity_lifecycle(id value) {
    if (![value isKindOfClass:NSDictionary.class] || ![@[@"start",@"cancel",@"recovered"] containsObject:value[@"acceptedOperation"]] ||
        !axs_cachekeeper_capacity_number(value[@"acceptedAt"]) || ![@[@"notObserved",@"observedZero"] containsObject:value[@"cursorClosure"]]) return nil;
    NSMutableDictionary *out=[@{@"acceptedOperation":value[@"acceptedOperation"],@"acceptedAt":value[@"acceptedAt"],@"cursorClosure":value[@"cursorClosure"]} mutableCopy];
    for (NSString *key in @[@"cancelObservedAt",@"cursorClosedAt"]) if (value[key]) {
        if (!axs_cachekeeper_capacity_number(value[key])) return nil;out[key]=value[key];
    }
    if ([value[@"cursorClosure"] isEqual:@"observedZero"] != (value[@"cursorClosedAt"]!=nil)) return nil;
    if (value[@"previousObservedEpoch"]) {if (!axs_cachekeeper_capacity_epoch(value[@"previousObservedEpoch"])) return nil;out[@"previousObservedEpoch"]=value[@"previousObservedEpoch"];}
    return [out copy];
}
static inline NSDictionary *axs_cachekeeper_capacity_terminal(id value) {
    if (![value isKindOfClass:NSDictionary.class] || !axs_cachekeeper_capacity_epoch(value[@"epoch"]) ||
        ![@[@"complete",@"partial",@"cancelled",@"interrupted",@"unavailable"] containsObject:value[@"state"]] ||
        ![@[@"saved",@"notSaved"] containsObject:value[@"resultPublication"]]) return nil;
    NSMutableDictionary *out=[@{@"epoch":value[@"epoch"],@"state":value[@"state"],@"resultPublication":value[@"resultPublication"]} mutableCopy];
    for (NSString *key in @[@"startedAt",@"finishedAt"]) {if (!axs_cachekeeper_capacity_number(value[key])) return nil;out[key]=value[key];}
    BOOL saved=[value[@"resultPublication"] isEqual:@"saved"];
    if (saved != (value[@"publicationObservedAt"]!=nil)) return nil;
    if (saved) {if (!axs_cachekeeper_capacity_number(value[@"publicationObservedAt"])) return nil;out[@"publicationObservedAt"]=value[@"publicationObservedAt"];}
    if (value[@"supersededBy"]) {if (!axs_cachekeeper_capacity_epoch(value[@"supersededBy"]) || [value[@"supersededBy"] isEqual:value[@"epoch"]]) return nil;out[@"supersededBy"]=value[@"supersededBy"];}
    if (value[@"lifecycle"]) {NSDictionary *closed=axs_cachekeeper_capacity_lifecycle(value[@"lifecycle"]);if (!closed) return nil;out[@"lifecycle"]=closed;}
    if (value[@"failure"]) {NSDictionary *closed=axs_cachekeeper_capacity_failure(value[@"failure"]);if (!closed) return nil;out[@"failure"]=closed;}
    return [out copy];
}
static inline NSDictionary *axs_cachekeeper_capacity_history(id value) {
    if (![value isKindOfClass:NSDictionary.class] || ![value[@"limit"] isEqual:@16] || !axs_cachekeeper_capacity_number(value[@"limit"]) ||
        !axs_cachekeeper_capacity_number(value[@"omittedCount"]) || ![value[@"records"] isKindOfClass:NSArray.class] || [value[@"records"] count]>16) return nil;
    NSMutableSet *epochs=[NSMutableSet new];NSMutableArray *rows=[NSMutableArray new];
    for (id item in value[@"records"]) {NSDictionary *closed=axs_cachekeeper_capacity_terminal(item);
        if (!closed || [epochs containsObject:closed[@"epoch"]]) return nil;[epochs addObject:closed[@"epoch"]];[rows addObject:closed];}
    return @{@"limit":@16,@"omittedCount":value[@"omittedCount"],@"records":rows};
}
static inline NSDictionary *axs_cachekeeper_capacity_client_stop(id value) {
    if (![value isKindOfClass:NSDictionary.class] || !axs_cachekeeper_capacity_epoch(value[@"epoch"]) ||
        !axs_cachekeeper_capacity_number(value[@"attemptedAt"]) || ![@[@"saved",@"failed"] containsObject:value[@"requestWrite"]] ||
        ![@[@"unconfirmed",@"terminalObserved",@"terminalHistoryObserved"] containsObject:value[@"confirmation"]]) return nil;
    NSMutableDictionary *out=[@{@"epoch":value[@"epoch"],@"attemptedAt":value[@"attemptedAt"],@"requestWrite":value[@"requestWrite"],@"confirmation":value[@"confirmation"]} mutableCopy];
    if (value[@"terminal"]) {NSDictionary *terminal=axs_cachekeeper_capacity_terminal(value[@"terminal"]);
        if (!terminal || ![terminal[@"epoch"] isEqual:value[@"epoch"]] || ![value[@"confirmation"] isEqual:@"terminalHistoryObserved"]) return nil;out[@"terminal"]=terminal;
    } else if ([value[@"confirmation"] isEqual:@"terminalHistoryObserved"]) return nil;
    return [out copy];
}
static inline NSDictionary *axs_cachekeeper_capacity_summary_binding(id value,id terminal) {
    if (!value) return @{ @"state":@"unknown" };
    if (![value isKindOfClass:NSDictionary.class] || !([value count]==4 || [value count]==5) ||
        (value[@"state"] && ![value[@"state"] isEqual:@"current"]) || !axs_cachekeeper_capacity_epoch(value[@"epoch"]) ||
        ![@[@"complete",@"partial",@"cancelled",@"interrupted",@"unavailable"] containsObject:value[@"terminalState"]] ||
        !axs_cachekeeper_capacity_number(value[@"terminalFinishedAt"]) || !axs_cachekeeper_capacity_number(value[@"summarizedAt"]))
        return @{ @"state":@"stale" };
    if (![terminal isKindOfClass:NSDictionary.class] || !axs_cachekeeper_capacity_epoch(terminal[@"epoch"]) ||
        ![@[@"complete",@"partial",@"cancelled",@"interrupted",@"unavailable"] containsObject:terminal[@"state"]] ||
        !axs_cachekeeper_capacity_number(terminal[@"finishedAt"])) return @{ @"state":@"stale" };
    BOOL current=[value[@"epoch"] isEqual:terminal[@"epoch"]] && [value[@"terminalState"] isEqual:terminal[@"state"]] &&
        [value[@"terminalFinishedAt"] isEqual:terminal[@"finishedAt"]] && [value[@"summarizedAt"] doubleValue]>=[terminal[@"finishedAt"] doubleValue];
    if (!current) return @{ @"state":@"stale" };
    return @{ @"state":@"current",@"epoch":value[@"epoch"],@"terminalState":value[@"terminalState"],
        @"terminalFinishedAt":value[@"terminalFinishedAt"],@"summarizedAt":value[@"summarizedAt"] };
}
static inline BOOL axs_cachekeeper_capacity_summary_is_current(id report) {
    if (![report isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *capacity=report[@"capacityMeasurement"],*binding=capacity[@"summaryBinding"];
    if (![capacity isKindOfClass:NSDictionary.class] || ![binding isKindOfClass:NSDictionary.class] || ![binding[@"state"] isEqual:@"current"]) return NO;
    NSDictionary *terminal=@{ @"epoch":capacity[@"epoch"] ?: NSNull.null,@"state":capacity[@"state"] ?: NSNull.null,
        @"finishedAt":capacity[@"finishedAt"] ?: NSNull.null };
    return [[axs_cachekeeper_capacity_summary_binding(binding,terminal) objectForKey:@"state"] isEqual:@"current"];
}
static inline BOOL axs_cachekeeper_capacity_report_exportable(id report) {
    if (![report isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *capacity=report[@"capacityMeasurement"];
    if (![capacity isKindOfClass:NSDictionary.class]) return YES;
    if ([@[@"notMeasured",@"invalid"] containsObject:capacity[@"state"]]) return YES;
    return axs_cachekeeper_capacity_summary_is_current(report);
}
static inline BOOL axs_cachekeeper_capacity_token(id value) {
    if (![value isKindOfClass:NSString.class] || ![value hasPrefix:@"resource-"]) return NO;
    NSString *suffix=[value substringFromIndex:9];
    return suffix.length && suffix.length<=6 && ![suffix hasPrefix:@"0"] &&
        [suffix rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet].location==NSNotFound && suffix.integerValue<=36864;
}
static inline BOOL axs_cachekeeper_capacity_strings(id value,BOOL bundles) {
    if (![value isKindOfClass:NSArray.class] || [value count]>4096) return NO;
    NSMutableSet *seen=[NSMutableSet new];
    for (id item in value) {
        if (bundles ? !axs_cachekeeper_bundle_id(item) : ![@[@"home",@"group",@"extension"] containsObject:item]) return NO;
        if ([seen containsObject:item]) return NO;[seen addObject:item];
    }
    return YES;
}
static inline NSDictionary *axs_cachekeeper_capacity_measurement(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    AxsCacheKeeperResourceLayout layout=AxsCacheKeeperResourceLayoutPlatform;
    if (value[@"layoutProfile"]) {
        if (![value[@"layoutProfile"] isEqual:@"swiftgramGroupStructureV1"]) return nil;
        layout=AxsCacheKeeperResourceLayoutSwiftgramGroup;
    }
    NSArray *numbers=@[@"schemaVersion",@"logicalBytes",@"allocatedBytes",@"entries",@"uniqueInodes",@"duplicateInodes",@"entryLimit",@"depthLimit",@"inodeLimit",@"nodeLimit"];
    NSMutableDictionary *out=[NSMutableDictionary new];
    for (NSString *key in numbers) {if (!axs_cachekeeper_capacity_number(value[key])) return nil;out[key]=value[key];}
    for (NSString *key in @[@"entryLimit",@"depthLimit",@"inodeLimit",@"nodeLimit"]) if (![value[key] unsignedLongLongValue]) return nil;
    if ([value[@"entryLimit"] unsignedLongLongValue]>2000000 || [value[@"depthLimit"] unsignedLongLongValue]>64 ||
        [value[@"inodeLimit"] unsignedLongLongValue]>262144 || [value[@"nodeLimit"] unsignedLongLongValue]>4096 ||
        [value[@"entries"] unsignedLongLongValue]!=[value[@"uniqueInodes"] unsignedLongLongValue]+[value[@"duplicateInodes"] unsignedLongLongValue] ||
        [value[@"entries"] unsignedLongLongValue]>[value[@"entryLimit"] unsignedLongLongValue] || [value[@"uniqueInodes"] unsignedLongLongValue]>[value[@"inodeLimit"] unsignedLongLongValue]) return nil;
    if (![value[@"schemaVersion"] isEqual:@1] || ![@[@"running",@"complete",@"cancelled",@"interrupted",@"timeLimit",@"entryLimit",@"depthLimit",@"inodeLimit",@"nodeLimit",@"readError",@"identityChanged",@"invalidMetadata",@"partial"] containsObject:value[@"state"]] ||
        ![value[@"deletionAuthorization"] isEqual:@"notGranted"] || ![value[@"physicalUniqueBytes"] isEqual:@"notMeasured"] || ![value[@"reclaimableBytes"] isEqual:@"notMeasured"] ||
        ![value[@"nodes"] isKindOfClass:NSArray.class] || [value[@"nodes"] count]>[value[@"nodeLimit"] unsignedIntegerValue]) return nil;
    NSMutableArray *nodes=[NSMutableArray new];NSMutableSet *ids=[NSMutableSet new];
    NSMutableDictionary *byId=[NSMutableDictionary new],*depths=[NSMutableDictionary new],*childTotals=[NSMutableDictionary new];
    for (id node in value[@"nodes"]) {
        if (![node isKindOfClass:NSDictionary.class]) return nil;
        NSMutableDictionary *closed=[NSMutableDictionary new];
        for (NSString *key in @[@"id",@"parent",@"logicalBytes",@"allocatedBytes",@"entries"]) {
            if (!axs_cachekeeper_capacity_number(node[key])) return nil;closed[key]=node[key];
        }
        if ([node[@"id"] unsignedLongLongValue]==0 || [ids containsObject:node[@"id"]] ||
            (nodes.count==0 ? ![node[@"id"] isEqual:@1] || ![node[@"parent"] isEqual:@0] : ![node[@"parent"] unsignedLongLongValue]) ||
            ([node[@"parent"] unsignedLongLongValue] && ![ids containsObject:node[@"parent"]]) ||
            axs_cachekeeper_capacity_category(node[@"category"])==AxsCacheKeeperResourceCategoryCount ||
            (nodes.count==0 && ![node[@"category"] isEqual:@"unknown"])) return nil;
        NSDictionary *parent=byId[node[@"parent"]];NSUInteger depth=parent ? [depths[node[@"parent"]] unsignedIntegerValue]+1 : 0;
        if (depth>axs_cachekeeper_resource_node_depth(layout) || ![node[@"entries"] unsignedLongLongValue]) return nil;
        NSString *category=node[@"category"];
        BOOL positioned=axs_cachekeeper_resource_node_valid(layout,axs_cachekeeper_capacity_category(category),axs_cachekeeper_capacity_category(parent[@"category"]),depth);
        if (!positioned) return nil;
        if (depth>3) {
            NSDictionary *postbox=depth==4 ? parent : byId[parent[@"parent"]];
            if (![postbox[@"category"] isEqual:@"postbox"]) return nil;
        }
        if (parent) {
            NSMutableDictionary *totals=childTotals[node[@"parent"]];if (!totals) childTotals[node[@"parent"]]=totals=[NSMutableDictionary new];
            for (NSString *key in @[@"logicalBytes",@"allocatedBytes",@"entries"]) {
                uint64_t maximum=[parent[key] unsignedLongLongValue],amount=[node[key] unsignedLongLongValue],sum=[totals[key] unsignedLongLongValue];
                // Parents include their own directory entry; unnamed direct files
                // and directory blocks may leave a remainder, never equality.
                if ([key isEqual:@"entries"]) maximum--;
                if (amount>maximum || sum>maximum-amount) return nil;
                totals[key]=@(sum+amount);
            }
        }
        closed[@"category"]=category;[ids addObject:node[@"id"]];[nodes addObject:closed];
        byId[node[@"id"]]=closed;depths[node[@"id"]]=@(depth);
    }
    if (nodes.count) {
        for (NSString *key in @[@"logicalBytes",@"allocatedBytes",@"entries"]) if (![nodes[0][key] isEqual:value[key]]) return nil;
    } else if ([value[@"entries"] unsignedLongLongValue] || [value[@"logicalBytes"] unsignedLongLongValue] || [value[@"allocatedBytes"] unsignedLongLongValue] || [value[@"state"] isEqual:@"complete"]) return nil;
    for (NSString *key in @[@"state",@"deletionAuthorization",@"physicalUniqueBytes",@"reclaimableBytes"]) out[key]=value[key];
    if (value[@"cursorErrors"]) {
        NSDictionary *errors=axs_cachekeeper_capacity_cursor_errors(value[@"cursorErrors"]);if (!errors) return nil;
        if ([value[@"state"] isEqual:@"complete"] && ([errors[@"enumerationErrors"] unsignedLongLongValue] ||
            [errors[@"statErrors"] unsignedLongLongValue] || [errors[@"errors"] count] || [errors[@"errorsTruncated"] boolValue])) return nil;
        out[@"cursorErrors"]=errors;
    }
    if (value[@"sourceFailure"]) {
        NSDictionary *failure=axs_cachekeeper_capacity_source_failure(value[@"sourceFailure"]);
        if (!failure || [@[@"running",@"complete"] containsObject:value[@"state"]]) return nil;
        out[@"sourceFailure"]=failure;
    }
    if (value[@"layoutProfile"]) out[@"layoutProfile"]=value[@"layoutProfile"];
    out[@"nodes"]=nodes;return [out copy];
}
static inline NSDictionary *axs_cachekeeper_capacity_projection(id value) {
    NSDictionary *invalid=@{@"schemaVersion":@1,@"state":value ? @"invalid" : @"notMeasured"};
    if (![value isKindOfClass:NSDictionary.class] || !axs_cachekeeper_capacity_number(value[@"schemaVersion"]) || ![value[@"schemaVersion"] isEqual:@1]) return invalid;
    NSString *state=value[@"state"];
    NSDictionary *clientStop=value[@"clientStop"] ? axs_cachekeeper_capacity_client_stop(value[@"clientStop"]) : nil;
    if (value[@"clientStop"] && !clientStop) return invalid;
    if ([@[@"invalid",@"notMeasured"] containsObject:state]) {
        if ([clientStop[@"confirmation"] isEqual:@"terminalObserved"]) return invalid;
        return clientStop ? @{@"schemaVersion":@1,@"state":state,@"clientStop":clientStop} : @{@"schemaVersion":@1,@"state":state};
    }
    if (![@[@"running",@"complete",@"partial",@"cancelled",@"interrupted",@"unavailable"] containsObject:state] || !axs_cachekeeper_capacity_epoch(value[@"epoch"])) return invalid;
    NSMutableDictionary *out=[NSMutableDictionary new];
    if (clientStop) {
        if ([clientStop[@"confirmation"] isEqual:@"terminalObserved"] &&
            (![clientStop[@"epoch"] isEqual:value[@"epoch"]] || [state isEqual:@"running"])) return invalid;
        out[@"clientStop"]=clientStop;
    }
    if (value[@"lifecycle"]) {NSDictionary *closed=axs_cachekeeper_capacity_lifecycle(value[@"lifecycle"]);if (!closed) return invalid;out[@"lifecycle"]=closed;}
    if (value[@"terminalHistory"]) {NSDictionary *closed=axs_cachekeeper_capacity_history(value[@"terminalHistory"]);if (!closed) return invalid;out[@"terminalHistory"]=closed;}
    for (NSString *key in @[@"schemaVersion",@"sourceSampledAt",@"startedAt",@"updatedAt",@"totalRoots",@"completedRoots",@"failedRoots"]) {
        if (!axs_cachekeeper_capacity_number(value[key])) return invalid;out[key]=value[key];
    }
    BOOL running=[state isEqual:@"running"];
    if ((running && [out[@"lifecycle"][@"cursorClosure"] isEqual:@"observedZero"]) ||
        [out[@"lifecycle"][@"previousObservedEpoch"] isEqual:value[@"epoch"]]) return invalid;
    if (running ? value[@"finishedAt"]!=nil : !axs_cachekeeper_capacity_number(value[@"finishedAt"])) return invalid;
    if (!running) out[@"finishedAt"]=value[@"finishedAt"];
    NSDictionary *terminal=running ? nil : @{ @"epoch":value[@"epoch"],@"state":state,@"finishedAt":value[@"finishedAt"] };
    out[@"summaryBinding"]=running ? @{ @"state":@"unknown" } : axs_cachekeeper_capacity_summary_binding(value[@"summaryBinding"],terminal);
    // Wall-clock jumps do not change the monotonic traversal budget or validity.
    if ([value[@"totalRoots"] unsignedLongLongValue]>4096 ||
        ![value[@"excludedBundles"] isEqual:@[@"com.tencent.qy.xin"]] ||
        ![value[@"deletionAuthorization"] isEqual:@"notGranted"] || ![value[@"physicalUniqueBytes"] isEqual:@"notMeasured"] ||
        ![value[@"reclaimableBytes"] isEqual:@"notMeasured"] || ![value[@"freshness"] isEqual:@"savedObservationUnverified"] ||
        ![value[@"roots"] isKindOfClass:NSArray.class] || [value[@"roots"] count]>4096 ||
        ![value[@"entries"] isKindOfClass:NSArray.class] || [value[@"entries"] count]>4096 ||
        ![value[@"measurementWindow"] isEqual:@"nonAtomicTraversal"] || ![value[@"installationMatch"] isEqual:@"notRevalidatedAtExport"]) return invalid;
    if (value[@"failure"]) {
        id failure=value[@"failure"];
        NSDictionary *closed=axs_cachekeeper_capacity_failure(failure);if (!closed) return invalid;out[@"failure"]=closed;
    }
    NSDictionary *registry=[value[@"registry"] isEqual:axs_cachekeeper_registry_inventory_projection(nil)] ? axs_cachekeeper_registry_inventory_projection(nil) : axs_cachekeeper_registry_inventory_projection(value[@"registry"]);
    BOOL unobserved=[registry isEqual:axs_cachekeeper_registry_inventory_projection(nil)];
    if (!value[@"registry"] || [registry[@"state"] isEqual:@"invalid"] ||
        (unobserved ? ![value[@"sourceSampledAt"] isEqual:@0] : ![value[@"sourceSampledAt"] isEqual:registry[@"sourceSampledAt"]])) return invalid;
    if ([value[@"completedRoots"] unsignedLongLongValue]+[value[@"failedRoots"] unsignedLongLongValue]>[value[@"totalRoots"] unsignedLongLongValue]) return invalid;
    NSMutableArray *roots=[NSMutableArray new],*entries=[NSMutableArray new];NSMutableDictionary *byId=[NSMutableDictionary new],*registrations=[NSMutableDictionary new];NSMutableSet *tokens=[NSMutableSet new],*registeredTokens=[NSMutableSet new];
    for (NSDictionary *entry in registry[@"entries"]) {
        registrations[entry[@"bundle"]]=entry;
        for (NSString *role in @[@"home",@"group",@"extension"]) [registeredTokens addObjectsFromArray:entry[@"relationships"][role][@"tokens"] ?: @[]];
    }
    NSUInteger nodes=0,completed=0,failed=0;
    for (id root in value[@"roots"]) {
        if (![root isKindOfClass:NSDictionary.class] || !axs_cachekeeper_capacity_number(root[@"id"]) || ![root[@"id"] unsignedLongLongValue] || [root[@"id"] unsignedLongLongValue]>[value[@"totalRoots"] unsignedLongLongValue] ||
            byId[root[@"id"]] || !axs_cachekeeper_capacity_token(root[@"token"]) || ![registeredTokens containsObject:root[@"token"]] || [tokens containsObject:root[@"token"]] ||
            !axs_cachekeeper_capacity_strings(root[@"owners"],YES) || ![root[@"owners"] count] || [root[@"owners"] containsObject:@"com.tencent.qy.xin"] ||
            !axs_cachekeeper_capacity_strings(root[@"roles"],NO) || ![root[@"roles"] count]) return invalid;
        NSDictionary *measurement=axs_cachekeeper_capacity_measurement(root[@"measurement"]);if (!measurement) return invalid;
        if (measurement[@"layoutProfile"] && (![root[@"owners"] isEqual:@[@"app.swiftgram.ios"]] || ![root[@"roles"] isEqual:@[@"group"]])) return invalid;
        if (!running && [measurement[@"state"] isEqual:@"running"]) return invalid;
        nodes+=[measurement[@"nodes"] count];if (nodes>65536) return invalid;
        if ([measurement[@"state"] isEqual:@"complete"]) completed++;
        else if (![measurement[@"state"] isEqual:@"running"]) failed++;
        NSDictionary *closed=@{@"id":root[@"id"],@"token":root[@"token"],@"owners":root[@"owners"],@"roles":root[@"roles"],@"measurement":measurement};
        byId[root[@"id"]]=closed;[tokens addObject:root[@"token"]];[roots addObject:closed];
    }
    if (roots.count>[value[@"totalRoots"] unsignedIntegerValue] || completed!=[value[@"completedRoots"] unsignedIntegerValue] || failed!=[value[@"failedRoots"] unsignedIntegerValue] ||
        ([state isEqual:@"complete"] && (roots.count!=[value[@"totalRoots"] unsignedIntegerValue] || completed!=roots.count || ![registry[@"state"] isEqual:@"available"]))) return invalid;
    NSMutableSet *bundles=[NSMutableSet new],*registeredBundles=[NSMutableSet new];NSMutableDictionary *entryIds=[NSMutableDictionary new];
    for (NSDictionary *entry in registry[@"entries"]) [registeredBundles addObject:entry[@"bundle"]];
    for (id entry in value[@"entries"]) {
        if (![entry isKindOfClass:NSDictionary.class] || !axs_cachekeeper_bundle_id(entry[@"bundle"]) || [bundles containsObject:entry[@"bundle"]] ||
            ![@[@"registered",@"noRegisteredRoots",@"excluded",@"sourcePartial"] containsObject:entry[@"state"]] ||
            ![entry[@"rootIds"] isKindOfClass:NSArray.class] || [entry[@"rootIds"] count]>4096) return invalid;
        NSMutableSet *ids=[NSMutableSet new];
        for (id rootId in entry[@"rootIds"]) {
            if (!axs_cachekeeper_capacity_number(rootId) || ![rootId unsignedLongLongValue] || [ids containsObject:rootId] || [rootId unsignedLongLongValue]>[value[@"totalRoots"] unsignedLongLongValue]) return invalid;
            if (byId[rootId] && ![byId[rootId][@"owners"] containsObject:entry[@"bundle"]]) return invalid;
            [ids addObject:rootId];
        }
        if (([@[@"noRegisteredRoots",@"excluded"] containsObject:entry[@"state"]] && ids.count) ||
            ([entry[@"bundle"] isEqual:@"com.tencent.qy.xin"] != [entry[@"state"] isEqual:@"excluded"])) return invalid;
        if ([state isEqual:@"complete"] && [entry[@"state"] isEqual:@"sourcePartial"]) return invalid;
        if ([entry[@"state"] isEqual:@"registered"] && !ids.count) return invalid;
        BOOL hasRegistration=NO,partialRegistration=NO;
        for (NSString *role in @[@"home",@"group",@"extension"]) {
            NSDictionary *relation=registrations[entry[@"bundle"]][@"relationships"][role];
            hasRegistration |= [relation[@"tokens"] count]>0;
            partialRegistration |= ![@[@"available",@"notProvided"] containsObject:relation[@"state"]];
        }
        if (([entry[@"state"] isEqual:@"noRegisteredRoots"] && (hasRegistration || partialRegistration)) ||
            ([entry[@"state"] isEqual:@"registered"] && (!hasRegistration || partialRegistration))) return invalid;
        [bundles addObject:entry[@"bundle"]];entryIds[entry[@"bundle"]]=ids;[entries addObject:@{@"bundle":entry[@"bundle"],@"rootIds":entry[@"rootIds"],@"state":entry[@"state"]}];
    }
    if (![bundles isEqual:registeredBundles]) return invalid;
    for (NSDictionary *root in roots) for (NSString *owner in root[@"owners"]) if (![entryIds[owner] containsObject:root[@"id"]]) return invalid;
    for (NSString *key in @[@"epoch",@"state",@"excludedBundles",@"deletionAuthorization",@"physicalUniqueBytes",@"reclaimableBytes",@"freshness",@"measurementWindow",@"installationMatch"]) out[key]=value[key];
    out[@"registry"]=registry;out[@"roots"]=roots;out[@"entries"]=entries;return [out copy];
}
static inline NSDictionary *axs_cachekeeper_capacity_report_measurement(id value,uint64_t summarizedAt) {
    (void)summarizedAt;
    return axs_cachekeeper_capacity_projection(value);
}
static inline void axs_cachekeeper_capacity_io_error(NSError **error,NSInteger code) {
    if (error) *error=[NSError errorWithDomain:@"AxsCacheKeeperCapacityIO" code:code userInfo:nil];
}
static inline BOOL axs_cachekeeper_capacity_same_file(const struct stat *a,const struct stat *b) {
    return S_ISREG(b->st_mode) && a->st_dev==b->st_dev && a->st_ino==b->st_ino && a->st_size==b->st_size &&
        a->st_mtimespec.tv_sec==b->st_mtimespec.tv_sec && a->st_mtimespec.tv_nsec==b->st_mtimespec.tv_nsec &&
        a->st_ctimespec.tv_sec==b->st_ctimespec.tv_sec && a->st_ctimespec.tv_nsec==b->st_ctimespec.tv_nsec;
}
static inline id axs_cachekeeper_capacity_read_plist(NSString *folder,NSString *name,NSUInteger limit,NSError **error) {
    if (error) *error=nil;
    int directory=axs_cachekeeper_open_directory(folder);if (directory<0) {axs_cachekeeper_capacity_io_error(error,errno);return nil;}
    int fd=openat(directory,name.fileSystemRepresentation,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK);
    if (fd<0) {int code=errno;close(directory);axs_cachekeeper_capacity_io_error(error,code);return nil;}
    struct stat before,after,path,parent,parentPath;id result=nil;
    if (fstat(directory,&parent)) {close(fd);close(directory);axs_cachekeeper_capacity_io_error(error,EIO);return nil;}
    if (fstat(fd,&before) || !S_ISREG(before.st_mode) || before.st_size<=0 || (uint64_t)before.st_size>limit) axs_cachekeeper_capacity_io_error(error,EINVAL);
    else {
        NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)before.st_size];NSUInteger readBytes=0;BOOL ok=YES;
        while (readBytes<data.length) {ssize_t count=read(fd,(char *)data.mutableBytes+readBytes,data.length-readBytes);if (count<0 && errno==EINTR) continue;if (count<=0) {ok=NO;break;}readBytes+=(NSUInteger)count;}
        char extra;ssize_t count;do {count=read(fd,&extra,1);} while (count<0 && errno==EINTR);
        ok=ok && count==0 && !fstat(fd,&after) && !fstatat(directory,name.fileSystemRepresentation,&path,AT_SYMLINK_NOFOLLOW) &&
            !lstat(folder.fileSystemRepresentation,&parentPath) && S_ISDIR(parentPath.st_mode) && parent.st_dev==parentPath.st_dev && parent.st_ino==parentPath.st_ino &&
            axs_cachekeeper_capacity_same_file(&before,&after) && axs_cachekeeper_capacity_same_file(&before,&path);
        if (ok) result=[NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:error];
        else axs_cachekeeper_capacity_io_error(error,ESTALE);
    }
    close(fd);close(directory);return result;
}
static inline BOOL axs_cachekeeper_capacity_atomic_write(NSDictionary *record,NSString *folder,NSString *name,NSUInteger limit,NSError **error) {
    if (error) *error=nil;NSData *data=[NSPropertyListSerialization dataWithPropertyList:record format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!data || data.length>limit) {axs_cachekeeper_capacity_io_error(error,EFBIG);return NO;}
    int directory=axs_cachekeeper_open_directory(folder);if (directory<0) {axs_cachekeeper_capacity_io_error(error,errno);return NO;}
    struct stat previous,directoryBefore;
    int statResult=fstatat(directory,name.fileSystemRepresentation,&previous,AT_SYMLINK_NOFOLLOW);
    if ((statResult && errno!=ENOENT) || (!statResult && !S_ISREG(previous.st_mode)) || fstat(directory,&directoryBefore)) {
        int code=errno;close(directory);axs_cachekeeper_capacity_io_error(error,code ?: EINVAL);return NO;
    }
    NSString *temporary=[@".capacity-" stringByAppendingString:NSUUID.UUID.UUIDString];
    int fd=openat(directory,temporary.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC|O_NOFOLLOW,0600);BOOL ok=fd>=0;NSUInteger written=0;
    struct stat temporaryIdentity;BOOL owned=fd>=0 && !fstat(fd,&temporaryIdentity);ok=ok && owned;
    while (ok && written<data.length) {ssize_t count=write(fd,(const char *)data.bytes+written,data.length-written);if (count<0 && errno==EINTR) continue;if (count<=0) {ok=NO;break;}written+=(NSUInteger)count;}
    if (ok) ok=!fsync(fd);if (fd>=0 && close(fd)) ok=NO;
    struct stat directoryNow,targetNow,temporaryNow;
    if (ok) ok=!lstat(folder.fileSystemRepresentation,&directoryNow) && S_ISDIR(directoryNow.st_mode) && directoryNow.st_dev==directoryBefore.st_dev && directoryNow.st_ino==directoryBefore.st_ino;
    if (ok) {int present=fstatat(directory,name.fileSystemRepresentation,&targetNow,AT_SYMLINK_NOFOLLOW);ok=present ? errno==ENOENT : S_ISREG(targetNow.st_mode);}
    if (ok) ok=!fstatat(directory,temporary.fileSystemRepresentation,&temporaryNow,AT_SYMLINK_NOFOLLOW) && S_ISREG(temporaryNow.st_mode) && temporaryIdentity.st_dev==temporaryNow.st_dev && temporaryIdentity.st_ino==temporaryNow.st_ino;
    if (ok) ok=!renameat(directory,temporary.fileSystemRepresentation,directory,name.fileSystemRepresentation);
    if (!ok) {int code=errno;if (owned && !fstatat(directory,temporary.fileSystemRepresentation,&temporaryNow,AT_SYMLINK_NOFOLLOW) &&
        S_ISREG(temporaryNow.st_mode) && temporaryIdentity.st_dev==temporaryNow.st_dev && temporaryIdentity.st_ino==temporaryNow.st_ino) unlinkat(directory,temporary.fileSystemRepresentation,0);
        axs_cachekeeper_capacity_io_error(error,code ?: EIO);}
    close(directory);return ok;
}
static inline NSDictionary *axs_cachekeeper_capacity_read_result(NSString *path,NSError **error) {
    if (![path isKindOfClass:NSString.class] || ![path hasPrefix:@"/"] || ![path.lastPathComponent isEqual:@"capacityResult.plist"]) {
        axs_cachekeeper_capacity_io_error(error,EINVAL);return @{@"schemaVersion":@1,@"state":@"invalid"};
    }
    NSError *readError=nil;
    id value=axs_cachekeeper_capacity_read_plist(path.stringByDeletingLastPathComponent,@"capacityResult.plist",32*1024*1024,&readError);
    if (error) *error=readError.code==ENOENT ? nil : readError;
    if (readError && readError.code!=ENOENT) return @{@"schemaVersion":@1,@"state":@"invalid"};
    NSDictionary *result=axs_cachekeeper_capacity_projection(value);
    if (value && [result[@"state"] isEqual:@"invalid"]) axs_cachekeeper_capacity_io_error(error,EINVAL);
    return result;
}
static inline BOOL axs_cachekeeper_capacity_write_request(NSString *path,NSString *epoch,BOOL cancel,NSError **error) {
    if (![path isKindOfClass:NSString.class] || ![path hasPrefix:@"/"] || ![path.lastPathComponent isEqual:@"capacityRequest.plist"] || !axs_cachekeeper_capacity_epoch(epoch)) {
        axs_cachekeeper_capacity_io_error(error,EINVAL);return NO;
    }
    return axs_cachekeeper_capacity_atomic_write(@{@"schemaVersion":@1,@"epoch":epoch,@"operation":cancel ? @"cancel" : @"start"},path.stringByDeletingLastPathComponent,@"capacityRequest.plist",4096,error);
}
