#pragma once
#import "AxsCacheKeeperPolicy.h"

// Validate fields consumed by history and report readers before subscripting or messaging them.
// Unknown fields are preserved for forward compatibility; malformed known fields reject the file.
static inline BOOL axs_cachekeeper_record_valid(id value, NSUInteger depth) {
    if (depth>8 || ![value isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *record=value;
    for (NSString *key in @[@"token",@"bundle",@"path",@"source",@"twin",@"home",@"error",@"message",@"evidence",
        @"type",@"reason",@"stage",@"detail",@"mode",@"phase",@"purgeClassification",@"purgeEvidence",@"appRuleSummary"])
        if (record[key] && ![record[key] isKindOfClass:NSString.class]) return NO;
    for (NSString *key in @[@"updated",@"started"])
        if (record[key] && ![record[key] isKindOfClass:NSDate.class]) return NO;
    for (NSString *key in @[@"bytes",@"files",@"count",@"nlink",@"removed",@"failed",@"failures",@"changed",@"recent",
        @"remaining",@"remainingBytes",@"deferred",@"deferredBytes",@"unresolved",@"unresolvedBytes",@"protected",@"protectedBytes",
        @"retainedSubtreeCount",@"lastRemoved",@"lastBytes",@"confirmedRemoved",@"confirmedBytes",@"links",@"hardLinks",@"symlinks",
        @"hidden",@"twinBytes",@"twinFailures",@"twinScanned",@"code"])
        if (record[key] && !axs_cachekeeper_input_counter(record[key])) return NO;
    for (NSString *key in @[@"complete",@"coverageComplete",@"measurementComplete",@"cancelled",@"checking",@"skipped",@"manageable",@"readOnly",
        @"twinCoverageComplete",@"twinScanTruncated",@"twinDisplayTruncated",@"linkFilesTruncated",@"appRuleWaitingForExit"])
        if (record[key] && !axs_cachekeeper_input_boolean(record[key])) return NO;
    for (NSString *key in @[@"effectivePaths",@"discoveredPaths",@"excludedPaths",@"logPaths"])
        if (record[key] && !axs_cachekeeper_input_strings(record[key],axs_cachekeeper_relative_path)) return NO;
    for (NSString *key in @[@"rows",@"previousRows",@"recentScans",@"largest",@"largestHardLinks",@"linkTwins",@"retainedSubtrees",@"failureDetails"]) {
        if (!record[key]) continue;
        if (![record[key] isKindOfClass:NSArray.class]) return NO;
        for (id item in record[key]) if (!axs_cachekeeper_record_valid(item,depth+1)) return NO;
    }
    for (NSString *key in @[@"reports",@"directories",@"types"]) {
        if (!record[key]) continue;
        if (![record[key] isKindOfClass:NSDictionary.class]) return NO;
        for (id item in [record[key] allValues]) if (!axs_cachekeeper_record_valid(item,depth+1)) return NO;
    }
    if (record[@"ages"]) {
        if (![record[@"ages"] isKindOfClass:NSDictionary.class]) return NO;
        for (id item in [record[@"ages"] allValues]) if (!axs_cachekeeper_input_counter(item)) return NO;
    }
    if (record[@"groups"]) {
        if (![record[@"groups"] isKindOfClass:NSDictionary.class]) return NO;
        for (id item in [record[@"groups"] allValues]) if (![item isKindOfClass:NSString.class]) return NO;
    }
    return YES;
}
static inline BOOL axs_cachekeeper_records_valid(id value, NSString *name) {
    if (![value isKindOfClass:NSDictionary.class]) return NO;
    if ([name isEqual:@"snapshots.plist"]) {
        for (id bundle in value) if (!axs_cachekeeper_bundle_id(bundle) || !axs_cachekeeper_record_valid(value[bundle],0)) return NO;
        return YES;
    }
    return axs_cachekeeper_record_valid(value,0);
}
static inline NSDictionary *axs_cachekeeper_read_records(NSString *path, NSError **error) {
    id value=axs_cachekeeper_read_plist(path,error);
    if (value && !axs_cachekeeper_records_valid(value,path.lastPathComponent)) {
        if (error) *error=[NSError errorWithDomain:@"dev.local.cachekeeper.records" code:1 userInfo:@{NSLocalizedDescriptionKey:@"历史记录字段损坏，已停止使用并保留原文件"}];
        return nil;
    }
    return value;
}
