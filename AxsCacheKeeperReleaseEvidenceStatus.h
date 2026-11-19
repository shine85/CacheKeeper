#pragma once
#import <Foundation/Foundation.h>
#include <stdint.h>
#include <math.h>
#include <string.h>

// Closed, round-local observation schema. No paths or raw filesystem identities leave the collector.
static inline BOOL axs_cachekeeper_release_keys(id value, NSArray *keys) {
    return [value isKindOfClass:NSDictionary.class] &&
        [[NSSet setWithArray:[value allKeys]] isEqual:[NSSet setWithArray:keys]];
}
static inline BOOL axs_cachekeeper_release_uint(id value, uint64_t *result) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()) return NO;
    const char *type=[value objCType];
    if (strlen(type)!=1) return NO;
    if (strchr("CSILQ",type[0])) { if (result) *result=[value unsignedLongLongValue]; return YES; }
    if (strchr("csilq",type[0])) {
        if ([value longLongValue]<0) return NO;
        if (result) *result=(uint64_t)[value longLongValue]; return YES;
    }
    double n=[value doubleValue];
    if (!strchr("fd",type[0]) || !isfinite(n) || n<0 || trunc(n)!=n || n>9007199254740991.0) return NO;
    if (result) *result=(uint64_t)n; return YES;
}
static inline BOOL axs_cachekeeper_release_int(id value, int64_t *result) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()) return NO;
    const char *type=[value objCType];
    if (strlen(type)!=1) return NO;
    if (strchr("csilq",type[0])) { if (result) *result=[value longLongValue];return YES; }
    uint64_t n=0;
    if (!axs_cachekeeper_release_uint(value,&n) || n>INT64_MAX) {
        double d=[value doubleValue];
        if (!strchr("fd",type[0]) || !isfinite(d) || trunc(d)!=d || fabs(d)>9007199254740991.0) return NO;
        if (result) *result=(int64_t)d;return YES;
    }
    if (result) *result=(int64_t)n;return YES;
}
static inline BOOL axs_cachekeeper_release_errno(id value) {
    uint64_t n; return axs_cachekeeper_release_uint(value,&n) && n<=INT32_MAX;
}
static inline BOOL axs_cachekeeper_release_time(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value)!=CFBooleanGetTypeID() &&
        isfinite([value doubleValue]) && [value doubleValue]>=0;
}
static inline NSDictionary *axs_cachekeeper_release_stat(id value) {
    if (![value isKindOfClass:NSDictionary.class] || !axs_cachekeeper_release_errno(value[@"errno"])) return nil;
    if ([value[@"state"] isEqual:@"invalidMetadata"])
        return ![value[@"errno"] unsignedIntegerValue] && axs_cachekeeper_release_keys(value,@[@"state",@"errno"]) ? [value copy] : nil;
    if ([value[@"state"] isEqual:@"unavailable"])
        return axs_cachekeeper_release_keys(value,@[@"state",@"errno"]) ? [value copy] : nil;
    if (![value[@"state"] isEqual:@"observed"] || [value[@"errno"] unsignedIntegerValue] ||
        !axs_cachekeeper_release_keys(value,@[@"state",@"errno",@"size",@"blocks",@"nlink"])) return nil;
    for (NSString *key in @[@"size",@"blocks",@"nlink"]) if (!axs_cachekeeper_release_uint(value[key],NULL)) return nil;
    return [value copy];
}
static inline NSDictionary *axs_cachekeeper_release_volume_sample(id value) {
    if (![value isKindOfClass:NSDictionary.class] || !axs_cachekeeper_release_errno(value[@"errno"])) return nil;
    if ([@[@"notRecorded",@"unavailable",@"invalidMetadata"] containsObject:value[@"state"]]) {
        if (![value[@"state"] isEqual:@"unavailable"] && [value[@"errno"] unsignedIntegerValue]) return nil;
        return axs_cachekeeper_release_keys(value,@[@"state",@"errno"]) ? [value copy] : nil;
    }
    if (![value[@"state"] isEqual:@"observed"] || [value[@"errno"] unsignedIntegerValue] ||
        !axs_cachekeeper_release_keys(value,@[@"state",@"errno",@"blockSize",@"freeBlocks",@"availableBlocks",@"uptime"])) return nil;
    for (NSString *key in @[@"blockSize",@"freeBlocks",@"availableBlocks"]) if (!axs_cachekeeper_release_uint(value[key],NULL)) return nil;
    if (![value[@"blockSize"] unsignedLongLongValue] || !axs_cachekeeper_release_time(value[@"uptime"])) return nil;
    return [value copy];
}
static inline BOOL axs_cachekeeper_release_delta(NSDictionary *before, NSDictionary *after, NSString *key, int64_t *delta) {
    uint64_t b=[before[key] unsignedLongLongValue],a=[after[key] unsignedLongLongValue];
    uint64_t bs=[before[@"blockSize"] unsignedLongLongValue],as=[after[@"blockSize"] unsignedLongLongValue];
    if (!bs || bs!=as || b>UINT64_MAX/bs || a>UINT64_MAX/as) return NO;
    b*=bs;a*=as;
    uint64_t difference=a>=b ? a-b : b-a;
    if (a>=b) { if (difference>INT64_MAX) return NO;*delta=(int64_t)difference; }
    else { if (difference>(UINT64_C(1)<<63)) return NO;*delta=difference==(UINT64_C(1)<<63) ? INT64_MIN : -(int64_t)difference; }
    return YES;
}
static inline NSDictionary *axs_cachekeeper_release_evidence_projection(id value, NSString *roundID) {
    NSArray *keys=@[@"schemaVersion",@"roundID",@"revision",@"state",@"attempts",@"succeeded",@"failed",@"postMissing",
        @"detailsOmitted",@"identitiesOmitted",@"volumesOmitted",@"overflow",@"details",@"volumes",@"uniqueExtents",@"reclaimedPhysicalBytes"];
    if (!axs_cachekeeper_release_keys(value,keys) || !axs_cachekeeper_release_uint(value[@"schemaVersion"],NULL) ||
        [value[@"schemaVersion"] unsignedLongLongValue]!=1 || ![value[@"roundID"] isKindOfClass:NSString.class] ||
        ![[NSUUID alloc] initWithUUIDString:value[@"roundID"]] || (roundID && ![value[@"roundID"] isEqual:roundID]) ||
        ![@[@"notRecorded",@"recording",@"finished",@"cancelled"] containsObject:value[@"state"]] ||
        ![value[@"uniqueExtents"] isEqual:@"notMeasured"] || ![value[@"reclaimedPhysicalBytes"] isEqual:@"notMeasured"] ||
        ![value[@"overflow"] isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value[@"overflow"])!=CFBooleanGetTypeID() ||
        ![value[@"details"] isKindOfClass:NSArray.class] || [value[@"details"] count]>256 ||
        ![value[@"volumes"] isKindOfClass:NSArray.class] || [value[@"volumes"] count]>4) return nil;
    for (NSString *key in @[@"revision",@"attempts",@"succeeded",@"failed",@"postMissing",@"detailsOmitted",@"identitiesOmitted",@"volumesOmitted"])
        if (!axs_cachekeeper_release_uint(value[key],NULL)) return nil;
    uint64_t attempts=[value[@"attempts"] unsignedLongLongValue],succeeded=[value[@"succeeded"] unsignedLongLongValue],failed=[value[@"failed"] unsignedLongLongValue];
    uint64_t omitted=[value[@"detailsOmitted"] unsignedLongLongValue];
    BOOL overflow=[value[@"overflow"] boolValue];
    if ((!attempts)!=[value[@"state"] isEqual:@"notRecorded"] || [value[@"details"] count]>attempts || omitted>attempts || succeeded>attempts || failed>attempts ||
        [value[@"postMissing"] unsignedLongLongValue]>attempts || [value[@"identitiesOmitted"] unsignedLongLongValue]>attempts ||
        (!overflow && (succeeded>UINT64_MAX-failed || succeeded+failed!=attempts || omitted>UINT64_MAX-[value[@"details"] count] ||
            omitted+[value[@"details"] count]!=attempts))) return nil;
    NSMutableArray *details=[NSMutableArray new],*volumes=[NSMutableArray new];
    uint64_t detailSuccess=0,detailFailed=0,detailMissing=0,detailIdentityMissing=0;
    for (id row in value[@"details"]) {
        if (!axs_cachekeeper_release_keys(row,@[@"attemptID",@"rootID",@"objectID",@"kind",@"result",@"errno",@"pre",@"post",@"identityMatch",@"linkTransition"])) return nil;
        for (NSString *key in @[@"attemptID",@"rootID",@"objectID"]) if (!axs_cachekeeper_release_uint(row[key],NULL)) return nil;
        int64_t result;
        if ([row[@"attemptID"] unsignedLongLongValue]!=details.count+1 || ![row[@"rootID"] unsignedLongLongValue] ||
            [row[@"objectID"] unsignedLongLongValue]>2048 || ![@[@"ordinary",@"closedHardlink"] containsObject:row[@"kind"]] ||
            !axs_cachekeeper_release_int(row[@"result"],&result) || result < -1 || result>0 || !axs_cachekeeper_release_errno(row[@"errno"]) ||
            (result==0 && [row[@"errno"] unsignedIntegerValue]) ||
            ![@[@"same",@"different",@"notObserved"] containsObject:row[@"identityMatch"]] ||
            ![@[@"decremented",@"unchanged",@"other",@"notObserved"] containsObject:row[@"linkTransition"]]) return nil;
        NSDictionary *pre=axs_cachekeeper_release_stat(row[@"pre"]),*post=axs_cachekeeper_release_stat(row[@"post"]);
        if (!pre || !post) return nil;
        BOOL observed=[pre[@"state"] isEqual:@"observed"] && [post[@"state"] isEqual:@"observed"];
        if (!observed && (![row[@"identityMatch"] isEqual:@"notObserved"] || ![row[@"linkTransition"] isEqual:@"notObserved"])) return nil;
        if (observed && [row[@"identityMatch"] isEqual:@"notObserved"]) return nil;
        if ([row[@"identityMatch"] isEqual:@"different"] && ![row[@"linkTransition"] isEqual:@"notObserved"]) return nil;
        if ([row[@"identityMatch"] isEqual:@"same"]) {
            uint64_t before=[pre[@"nlink"] unsignedLongLongValue],after=[post[@"nlink"] unsignedLongLongValue];
            NSString *transition=before && after==before-1 ? @"decremented" : before==after ? @"unchanged" : @"other";
            if (![row[@"linkTransition"] isEqual:transition]) return nil;
        }
        if (result==0) detailSuccess++;else detailFailed++;
        if (![post[@"state"] isEqual:@"observed"]) detailMissing++;
        if (![row[@"objectID"] unsignedLongLongValue]) detailIdentityMissing++;
        NSMutableDictionary *copy=[row mutableCopy];copy[@"pre"]=pre;copy[@"post"]=post;[details addObject:[copy copy]];
    }
    if (detailSuccess>succeeded || detailFailed>failed || detailMissing>[value[@"postMissing"] unsignedLongLongValue] ||
        detailIdentityMissing>[value[@"identitiesOmitted"] unsignedLongLongValue]) return nil;
    if (!overflow && (succeeded-detailSuccess>omitted || failed-detailFailed>omitted ||
        [value[@"postMissing"] unsignedLongLongValue]-detailMissing>omitted ||
        [value[@"identitiesOmitted"] unsignedLongLongValue]-detailIdentityMissing>omitted)) return nil;
    for (id row in value[@"volumes"]) {
        BOOL observed=[row isKindOfClass:NSDictionary.class] && [row[@"state"] isEqual:@"observed"];
        NSArray *volumeKeys=observed ? @[@"volumeID",@"state",@"before",@"after",@"closeErrno",@"freeBytesDelta",@"availableBytesDelta",@"elapsedSeconds"] :
            @[@"volumeID",@"state",@"before",@"after",@"closeErrno"];
        if (!axs_cachekeeper_release_keys(row,volumeKeys) || !axs_cachekeeper_release_uint(row[@"volumeID"],NULL) ||
            [row[@"volumeID"] unsignedLongLongValue]!=volumes.count+1 || !axs_cachekeeper_release_errno(row[@"closeErrno"]) ||
            ![@[@"recording",@"observed",@"unavailable",@"overflow"] containsObject:row[@"state"]]) return nil;
        NSDictionary *before=axs_cachekeeper_release_volume_sample(row[@"before"]),*after=axs_cachekeeper_release_volume_sample(row[@"after"]);
        if (!before || !after) return nil;
        if (observed) {
            int64_t freeDelta,availableDelta,submittedFree,submittedAvailable;
            if (![before[@"state"] isEqual:@"observed"] || ![after[@"state"] isEqual:@"observed"] ||
                !axs_cachekeeper_release_delta(before,after,@"freeBlocks",&freeDelta) ||
                !axs_cachekeeper_release_delta(before,after,@"availableBlocks",&availableDelta) ||
                !axs_cachekeeper_release_int(row[@"freeBytesDelta"],&submittedFree) || submittedFree!=freeDelta ||
                !axs_cachekeeper_release_int(row[@"availableBytesDelta"],&submittedAvailable) || submittedAvailable!=availableDelta ||
                !axs_cachekeeper_release_time(row[@"elapsedSeconds"]) ||
                [after[@"uptime"] doubleValue]<[before[@"uptime"] doubleValue] ||
                fabs([row[@"elapsedSeconds"] doubleValue]-([after[@"uptime"] doubleValue]-[before[@"uptime"] doubleValue]))>0.000001) return nil;
        }
        if ([row[@"state"] isEqual:@"recording"] && (![after[@"state"] isEqual:@"notRecorded"] ||
            [@[@"finished",@"cancelled"] containsObject:value[@"state"]])) return nil;
        if ([row[@"state"] isEqual:@"overflow"] && !overflow) return nil;
        NSMutableDictionary *copy=[row mutableCopy];copy[@"before"]=before;copy[@"after"]=after;[volumes addObject:[copy copy]];
    }
    NSMutableDictionary *copy=[value mutableCopy];copy[@"details"]=[details copy];copy[@"volumes"]=[volumes copy];return [copy copy];
}
