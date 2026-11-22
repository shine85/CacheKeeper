#pragma once
#import "AxsCacheKeeperReleaseEvidenceStatus.h"
#import "AxsCacheKeeperRelativePath.h"
#import <CommonCrypto/CommonDigest.h>

// One closed public schema shared by persistence, diagnostics and presentation. No I/O or paths.
static const NSUInteger AxsCacheKeeperCleanupHistoryCapacity = 16;
static inline BOOL axs_cachekeeper_cleanup_token(id value) {
    if (![value isKindOfClass:NSString.class] || ![value length] || [value length]>128) return NO;
    NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._+-"];
    return [value rangeOfCharacterFromSet:allowed.invertedSet].location==NSNotFound;
}
static inline BOOL axs_cachekeeper_cleanup_boolean(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID();
}
static inline BOOL axs_cachekeeper_cleanup_rules_version(id value) {
    if (![value isKindOfClass:NSString.class] || ![value length] || [value length]>4096) return NO;
    NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._+-:;"];
    return [value rangeOfCharacterFromSet:allowed.invertedSet].location==NSNotFound;
}
static inline NSArray *axs_cachekeeper_cleanup_configuration_paths(id value) {
    if (![value isKindOfClass:NSArray.class]) return nil;
    NSMutableSet *paths=[NSMutableSet new];
    for (id path in value) {
        if (!axs_cachekeeper_relative_path(path)) return nil;
        [paths addObject:[path copy]];
    }
    return [paths.allObjects sortedArrayUsingSelector:@selector(compare:)];
}
static inline NSString *axs_cachekeeper_cleanup_configuration_id(NSDictionary *context, NSArray *selectedPaths,
    NSArray *excludedPaths, NSArray *logPaths) {
    NSArray *selected=axs_cachekeeper_cleanup_configuration_paths(selectedPaths),*excluded=axs_cachekeeper_cleanup_configuration_paths(excludedPaths),
        *logs=axs_cachekeeper_cleanup_configuration_paths(logPaths);
    if (!selected || !excluded || !logs) return nil;
    // Ordered fields and sorted unique relative paths produce one canonical configuration.
    // Installation fingerprints, process identities and absolute container paths never enter this hash.
    NSArray *fields=@[@"cleanup-configuration-v1",context[@"mode"],context[@"enabled"],context[@"urlCache"],
        context[@"webKitDiskCache"],context[@"autoDiscover"],context[@"rulesVersion"],selected,excluded,logs];
    NSData *data=[NSJSONSerialization dataWithJSONObject:fields options:0 error:nil];
    if (!data || data.length>UINT32_MAX) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
    NSMutableString *identifier=[NSMutableString stringWithString:@"sha256:"];
    for (NSUInteger i=0;i<sizeof(digest);i++) [identifier appendFormat:@"%02x",digest[i]];
    return [identifier copy];
}
static inline NSDictionary *axs_cachekeeper_cleanup_context_projection(id value) {
    if (axs_cachekeeper_release_keys(value,@[@"state"]) && [value[@"state"] isEqual:@"notRecorded"]) return @{@"state":@"notRecorded"};
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    NSMutableArray *keys=[@[@"state",@"mode",@"enabled",@"urlCache",@"webKitDiskCache",@"autoDiscover",
        @"packageVersion",@"rulesVersion",@"configurationID"] mutableCopy];
    for (NSString *key in @[@"appVersion",@"appBuild"]) if (value[key]) [keys addObject:key];
    if (!axs_cachekeeper_release_keys(value,keys) || ![value[@"state"] isEqual:@"recorded"] ||
        ![@[@"auto",@"clean",@"prevent"] containsObject:value[@"mode"]]) return nil;
    for (NSString *key in @[@"enabled",@"urlCache",@"webKitDiskCache",@"autoDiscover"])
        if (!axs_cachekeeper_cleanup_boolean(value[key])) return nil;
    for (NSString *key in @[@"packageVersion",@"appVersion",@"appBuild"])
        if ((value[key] || [key isEqual:@"packageVersion"]) && !axs_cachekeeper_cleanup_token(value[key])) return nil;
    if (!axs_cachekeeper_cleanup_rules_version(value[@"rulesVersion"])) return nil;
    NSString *identifier=value[@"configurationID"];
    if (![identifier isKindOfClass:NSString.class] || identifier.length!=71 || ![identifier hasPrefix:@"sha256:"] ||
        [[identifier substringFromIndex:7] rangeOfCharacterFromSet:
            [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet].location!=NSNotFound) return nil;
    NSMutableDictionary *out=[NSMutableDictionary new];
    for (NSString *key in keys) out[key]=[value[key] copy];
    return [out copy];
}
static inline NSDictionary *axs_cachekeeper_cleanup_context(NSString *mode, BOOL enabled, BOOL urlCache,
    BOOL webKitDiskCache, BOOL autoDiscover, NSString *packageVersion, NSString *appVersion, NSString *appBuild, NSString *rulesVersion,
    NSArray *selectedPaths, NSArray *excludedPaths, NSArray *logPaths) {
    if (!mode || !packageVersion || !rulesVersion) return nil;
    NSMutableDictionary *out=[@{@"state":@"recorded",@"mode":mode,@"enabled":@(enabled),@"urlCache":@(urlCache),
        @"webKitDiskCache":@(webKitDiskCache),@"autoDiscover":@(autoDiscover),@"packageVersion":packageVersion,@"rulesVersion":rulesVersion} mutableCopy];
    if (appVersion.length) out[@"appVersion"]=appVersion;
    if (appBuild.length) out[@"appBuild"]=appBuild;
    NSString *identifier=axs_cachekeeper_cleanup_configuration_id(out,selectedPaths,excludedPaths,logPaths);
    if (!identifier) return nil;
    out[@"configurationID"]=identifier;
    return axs_cachekeeper_cleanup_context_projection(out);
}
static inline NSDictionary *axs_cachekeeper_cleanup_round_projection(id value, BOOL exportDates) {
    NSArray *keys=@[@"roundID",@"finishedAt",@"removed",@"bytes",@"failed",@"endReason",@"coverageComplete",@"context",@"releaseEvidence"];
    if (!axs_cachekeeper_release_keys(value,keys) || !axs_cachekeeper_cleanup_token(value[@"roundID"]) ||
        ![value[@"finishedAt"] isKindOfClass:NSDate.class] || !isfinite([value[@"finishedAt"] timeIntervalSince1970]) ||
        !axs_cachekeeper_cleanup_boolean(value[@"coverageComplete"])) return nil;
    for (NSString *key in @[@"removed",@"bytes",@"failed",@"endReason"])
        if (!axs_cachekeeper_release_uint(value[key],NULL)) return nil;
    if ([value[@"endReason"] unsignedLongLongValue]<1 || [value[@"endReason"] unsignedLongLongValue]>6) return nil;
    NSDictionary *context=axs_cachekeeper_cleanup_context_projection(value[@"context"]);
    id rawEvidence=value[@"releaseEvidence"];
    NSDictionary *evidence=axs_cachekeeper_release_keys(rawEvidence,@[@"state"]) && [rawEvidence[@"state"] isEqual:@"notRecorded"] ?
        @{@"state":@"notRecorded"} : axs_cachekeeper_release_evidence_projection(rawEvidence,value[@"roundID"]);
    if (!context || !evidence || [evidence[@"state"] isEqual:@"recording"] ||
        (evidence[@"schemaVersion"] && [evidence[@"succeeded"] unsignedLongLongValue]!=[value[@"removed"] unsignedLongLongValue])) return nil;
    NSMutableDictionary *out=[NSMutableDictionary new];
    for (NSString *key in keys) out[key]=[value[key] copy];
    out[@"context"]=context;out[@"releaseEvidence"]=evidence;
    if (exportDates) out[@"finishedAt"]=@([value[@"finishedAt"] timeIntervalSince1970]);
    return [out copy];
}
// Missing legacy history is explicit, never reconstructed from cumulative totals.
// A partial or malformed new envelope is rejected as a whole, including during status-only writes.
static inline NSDictionary *axs_cachekeeper_cleanup_history_projection(id record, BOOL exportDates) {
    if (![record isKindOfClass:NSDictionary.class]) return nil;
    id history=record[@"cleanupHistory"],effective=record[@"lastEffectiveCleanup"],rawContext=record[@"cleanupContext"];
    if (!history && !effective && !rawContext) return @{@"cleanupHistory":@{@"state":@"notRecorded"},
        @"lastEffectiveCleanup":@{@"state":@"notRecorded"},@"cleanupContext":@{@"state":@"notRecorded"}};
    NSDictionary *context=axs_cachekeeper_cleanup_context_projection(rawContext);
    if (!context || !axs_cachekeeper_release_keys(history,@[@"schemaVersion",@"state",@"capacity",@"truncatedCount",@"rounds"]) ||
        ![history[@"state"] isEqual:@"recorded"] || !axs_cachekeeper_release_uint(history[@"schemaVersion"],NULL) ||
        [history[@"schemaVersion"] unsignedLongLongValue]!=1 || !axs_cachekeeper_release_uint(history[@"capacity"],NULL) ||
        [history[@"capacity"] unsignedLongLongValue]!=AxsCacheKeeperCleanupHistoryCapacity ||
        !axs_cachekeeper_release_uint(history[@"truncatedCount"],NULL) || ![history[@"rounds"] isKindOfClass:NSArray.class] ||
        [history[@"rounds"] count]>AxsCacheKeeperCleanupHistoryCapacity ||
        ([history[@"truncatedCount"] unsignedLongLongValue] && [history[@"rounds"] count]!=AxsCacheKeeperCleanupHistoryCapacity)) return nil;
    NSMutableArray *rounds=[NSMutableArray new];NSMutableSet *identifiers=[NSMutableSet new];
    NSDictionary *lastEffectiveInHistory=nil;
    for (id row in history[@"rounds"]) {
        NSDictionary *projected=axs_cachekeeper_cleanup_round_projection(row,exportDates);
        if (!projected || [identifiers containsObject:projected[@"roundID"]]) return nil;
        if ([record[@"confirmedRoundID"] isEqual:projected[@"roundID"]] && ![projected[@"context"] isEqual:context]) return nil;
        [identifiers addObject:projected[@"roundID"]];[rounds addObject:projected];
        if ([projected[@"removed"] unsignedLongLongValue]) lastEffectiveInHistory=projected;
    }
    NSDictionary *projectedEffective=nil;
    if (axs_cachekeeper_release_keys(effective,@[@"state"]) && [effective[@"state"] isEqual:@"notRecorded"])
        projectedEffective=@{@"state":@"notRecorded"};
    else projectedEffective=axs_cachekeeper_cleanup_round_projection(effective,exportDates);
    if (!projectedEffective || (projectedEffective[@"roundID"] && ![projectedEffective[@"removed"] unsignedLongLongValue]) ||
        (lastEffectiveInHistory && ![lastEffectiveInHistory isEqual:projectedEffective]) ||
        (!lastEffectiveInHistory && projectedEffective[@"roundID"] && ![history[@"truncatedCount"] unsignedLongLongValue])) return nil;
    return @{@"cleanupContext":context,@"lastEffectiveCleanup":projectedEffective,
        @"cleanupHistory":@{@"schemaVersion":@1,@"state":@"recorded",@"capacity":@(AxsCacheKeeperCleanupHistoryCapacity),
            @"truncatedCount":history[@"truncatedCount"],@"rounds":[rounds copy]}};
}
// Pure bounded update. Caller validates the prior envelope and owns serial atomic persistence.
static inline NSDictionary *axs_cachekeeper_cleanup_history_update(NSDictionary *previous, NSDictionary *snapshot) {
    NSDictionary *projected=axs_cachekeeper_cleanup_history_projection(previous,NO);
    if (!projected) return nil;
    NSDictionary *context=axs_cachekeeper_cleanup_context_projection(snapshot[@"cleanupContext"]);
    if (!context) return nil;
    NSMutableArray *rounds=[projected[@"cleanupHistory"][@"rounds"] mutableCopy] ?: [NSMutableArray new];
    uint64_t truncated=[projected[@"cleanupHistory"][@"truncatedCount"] unsignedLongLongValue];
    NSDictionary *effective=projected[@"lastEffectiveCleanup"];
    if (snapshot[@"round"]) {
        NSDictionary *row=axs_cachekeeper_cleanup_round_projection(@{@"roundID":snapshot[@"roundID"],@"finishedAt":snapshot[@"finishedAt"],
            @"removed":snapshot[@"removed"],@"bytes":snapshot[@"bytes"],@"failed":snapshot[@"failed"],@"endReason":snapshot[@"endReason"],
            @"coverageComplete":snapshot[@"coverageComplete"],@"context":context,
            @"releaseEvidence":snapshot[@"releaseEvidence"] ?: @{@"state":@"notRecorded"}},NO);
        if (!row) return nil;
        NSUInteger existing=[rounds indexOfObjectPassingTest:^BOOL(NSDictionary *old,NSUInteger index,BOOL *stop) {
            (void)index;(void)stop;return [old[@"roundID"] isEqual:row[@"roundID"]];
        }];
        if (existing!=NSNotFound) {
            row=rounds[existing]; // First terminal is immutable, including its failure and coverage facts.
        } else [rounds addObject:row];
        if ([row[@"removed"] unsignedLongLongValue]) effective=row;
        if (rounds.count>AxsCacheKeeperCleanupHistoryCapacity) {
            if (truncated==UINT64_MAX) return nil;
            [rounds removeObjectAtIndex:0];truncated++;
        }
    }
    NSDictionary *result=@{@"cleanupContext":context,@"lastEffectiveCleanup":effective,
        @"cleanupHistory":@{@"schemaVersion":@1,@"state":@"recorded",@"capacity":@(AxsCacheKeeperCleanupHistoryCapacity),
            @"truncatedCount":@(truncated),@"rounds":[rounds copy]}};
    return axs_cachekeeper_cleanup_history_projection(result,NO);
}
