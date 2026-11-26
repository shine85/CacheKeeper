#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#define AXS_CACHEKEEPER_WRITE_EPOCH_CAP 16
#define AXS_CACHEKEEPER_WRITE_MAX UINT64_C(9007199254740991)
#define AXS_CACHEKEEPER_WRITE_PAYLOAD_OBSERVATION 1
typedef struct {
    uint64_t attempts,allowed,blocked;
    bool overflow;
    uint64_t nonemptyAttempts,nonemptyAllowed,nonemptyBlocked;
    uint64_t emptyAttempts,emptyAllowed,emptyBlocked;
} AxsCacheKeeperWriteCounts;
typedef struct {
    uint64_t identifier,configuration,installation;
    unsigned mode;
    bool enabled;
    AxsCacheKeeperWriteCounts writers[2];
} AxsCacheKeeperWriteEpoch;
typedef struct {
    AxsCacheKeeperWriteEpoch epochs[AXS_CACHEKEEPER_WRITE_EPOCH_CAP];
    unsigned count;
    uint64_t lastEpoch,droppedEpochs;
    bool overflow;
    AxsCacheKeeperWriteCounts unattributed[2];
} AxsCacheKeeperWriteObservation;
// Caller serializes access. Counting represents the hook decision, not disk persistence.
static inline void axs_cachekeeper_write_count(AxsCacheKeeperWriteCounts *counts,bool blocked,unsigned payload) {
    if (counts->attempts==AXS_CACHEKEEPER_WRITE_MAX) {counts->overflow=true;return;}
    counts->attempts++;
    if (blocked) counts->blocked++;else counts->allowed++;
    if (payload==1) {counts->emptyAttempts++;if(blocked) counts->emptyBlocked++;else counts->emptyAllowed++;}
    if (payload==2) {counts->nonemptyAttempts++;if(blocked) counts->nonemptyBlocked++;else counts->nonemptyAllowed++;}
}
static inline uint64_t axs_cachekeeper_write_epoch_begin(AxsCacheKeeperWriteObservation *observation,
    uint64_t configuration,uint64_t installation,bool enabled,unsigned mode) {
    if (configuration>AXS_CACHEKEEPER_WRITE_MAX || installation>AXS_CACHEKEEPER_WRITE_MAX || mode>2) return 0;
    AxsCacheKeeperWriteEpoch *last=observation->count ? &observation->epochs[observation->count-1] : NULL;
    if (last && last->configuration==configuration && last->installation==installation && last->enabled==enabled && last->mode==mode) return last->identifier;
    if (observation->lastEpoch==AXS_CACHEKEEPER_WRITE_MAX) {observation->overflow=true;return 0;}
    if (observation->count==AXS_CACHEKEEPER_WRITE_EPOCH_CAP) {
        memmove(observation->epochs,observation->epochs+1,(AXS_CACHEKEEPER_WRITE_EPOCH_CAP-1)*sizeof(*observation->epochs));
        observation->count--;observation->droppedEpochs++;
    }
    AxsCacheKeeperWriteEpoch epoch={0};epoch.identifier=++observation->lastEpoch;
    epoch.configuration=configuration;epoch.installation=installation;epoch.enabled=enabled;epoch.mode=mode;
    observation->epochs[observation->count++]=epoch;return epoch.identifier;
}
static inline void axs_cachekeeper_write_observe_classified(AxsCacheKeeperWriteObservation *observation,uint64_t identifier,unsigned writer,bool blocked,unsigned payload) {
    if (writer>1) return;
    for (unsigned index=0;index<observation->count;index++) if (observation->epochs[index].identifier==identifier) {
        axs_cachekeeper_write_count(&observation->epochs[index].writers[writer],blocked,payload);return;
    }
    axs_cachekeeper_write_count(&observation->unattributed[writer],blocked,payload);
}
// Old source fixtures did not observe length. Their decisions stay unclassified.
static inline void axs_cachekeeper_write_observe(AxsCacheKeeperWriteObservation *observation,uint64_t identifier,unsigned writer,bool blocked) {
    axs_cachekeeper_write_observe_classified(observation,identifier,writer,blocked,0);
}
static inline void axs_cachekeeper_write_observe_payload(AxsCacheKeeperWriteObservation *observation,uint64_t identifier,unsigned writer,bool blocked,bool nonempty) {
    axs_cachekeeper_write_observe_classified(observation,identifier,writer,blocked,nonempty ? 2 : 1);
}
#ifdef __OBJC__
#import <Foundation/Foundation.h>
#include <math.h>
static inline BOOL axs_cachekeeper_write_keys(id value,NSArray *keys) {
    return [value isKindOfClass:NSDictionary.class] && [value count]==keys.count &&
        [[NSSet setWithArray:[value allKeys]] isEqual:[NSSet setWithArray:keys]];
}
static inline BOOL axs_cachekeeper_write_number(id value) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()) return NO;
    double n=[value doubleValue];return isfinite(n) && n>=0 && n<=AXS_CACHEKEEPER_WRITE_MAX && floor(n)==n;
}
static inline BOOL axs_cachekeeper_write_boolean(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID();
}
static inline NSDictionary *axs_cachekeeper_write_counts_record(AxsCacheKeeperWriteCounts counts) {
    return @{@"attempts":@(counts.attempts),@"allowed":@(counts.allowed),@"blocked":@(counts.blocked),@"overflow":@(counts.overflow),
        @"nonemptyAttempts":@(counts.nonemptyAttempts),@"nonemptyAllowed":@(counts.nonemptyAllowed),@"nonemptyBlocked":@(counts.nonemptyBlocked),
        @"emptyAttempts":@(counts.emptyAttempts),@"emptyAllowed":@(counts.emptyAllowed),@"emptyBlocked":@(counts.emptyBlocked)};
}
static inline NSDictionary *axs_cachekeeper_write_counts_projection(id value,BOOL payloadRecorded) {
    NSArray *numbers=@[@"attempts",@"allowed",@"blocked"];
    if(payloadRecorded) numbers=[numbers arrayByAddingObjectsFromArray:@[@"nonemptyAttempts",@"nonemptyAllowed",@"nonemptyBlocked",@"emptyAttempts",@"emptyAllowed",@"emptyBlocked"]];
    if (!axs_cachekeeper_write_keys(value,[numbers arrayByAddingObject:@"overflow"]) || !axs_cachekeeper_write_boolean(value[@"overflow"])) return nil;
    for (NSString *key in numbers) if (!axs_cachekeeper_write_number(value[key])) return nil;
    uint64_t attempts=[value[@"attempts"] unsignedLongLongValue],allowed=[value[@"allowed"] unsignedLongLongValue],blocked=[value[@"blocked"] unsignedLongLongValue];
    if (allowed>attempts || blocked!=attempts-allowed || ([value[@"overflow"] boolValue] && attempts!=AXS_CACHEKEEPER_WRITE_MAX)) return nil;
    if(payloadRecorded) {
        uint64_t na=[value[@"nonemptyAttempts"] unsignedLongLongValue],nl=[value[@"nonemptyAllowed"] unsignedLongLongValue],nb=[value[@"nonemptyBlocked"] unsignedLongLongValue],
            ea=[value[@"emptyAttempts"] unsignedLongLongValue],el=[value[@"emptyAllowed"] unsignedLongLongValue],eb=[value[@"emptyBlocked"] unsignedLongLongValue];
        if(nl>na || nb!=na-nl || el>ea || eb!=ea-el || na>attempts || ea>attempts-na ||
            nl>allowed || el>allowed-nl || nb>blocked || eb>blocked-nb) return nil;
    }
    return [value copy];
}
static inline NSDictionary *axs_cachekeeper_write_observation_record(AxsCacheKeeperWriteObservation observation) {
    NSMutableArray *epochs=[NSMutableArray new];NSArray *modes=@[@"auto",@"clean",@"prevent"];
    for (unsigned i=0;i<observation.count && i<AXS_CACHEKEEPER_WRITE_EPOCH_CAP;i++) {
        AxsCacheKeeperWriteEpoch row=observation.epochs[i];if (row.mode>2) return nil;
        [epochs addObject:@{@"epoch":@(row.identifier),@"configuration":@(row.configuration),@"installation":@(row.installation),
            @"identityState":row.enabled ? @"verified" : @"notRevalidated",
            @"enabled":@(row.enabled),@"mode":modes[row.mode],@"data":axs_cachekeeper_write_counts_record(row.writers[0]),
            @"extended":axs_cachekeeper_write_counts_record(row.writers[1])}];
    }
    return @{@"schemaVersion":@3,@"scope":@"boundWriterDecisions",@"attemptBasis":@"dataAndKeyNonNil",@"allowedMeaning":@"originalCallForwarded",
        @"payloadBasis":@"lengthAtHookEntry",@"unclassifiedMeaning":@"totalMinusEmptyAndNonempty",
        @"diskPersistence":@"notMeasured",@"lastEpoch":@(observation.lastEpoch),@"droppedEpochs":@(observation.droppedEpochs),
        @"truncated":@((BOOL)(observation.droppedEpochs>0)),@"overflow":@(observation.overflow),@"epochs":[epochs copy],
        @"unattributed":@{@"data":axs_cachekeeper_write_counts_record(observation.unattributed[0]),@"extended":axs_cachekeeper_write_counts_record(observation.unattributed[1])}};
}
static inline NSDictionary *axs_cachekeeper_write_observation_projection(id value) {
    NSArray *keys=@[@"schemaVersion",@"scope",@"attemptBasis",@"allowedMeaning",@"diskPersistence",@"lastEpoch",@"droppedEpochs",@"truncated",@"overflow",@"epochs",@"unattributed"];
    if(![value isKindOfClass:NSDictionary.class]) return nil;
    BOOL payloadRecorded=[value[@"schemaVersion"] isEqual:@3];
    if(payloadRecorded) keys=[keys arrayByAddingObjectsFromArray:@[@"payloadBasis",@"unclassifiedMeaning"]];
    if (!axs_cachekeeper_write_keys(value,keys) || !axs_cachekeeper_write_number(value[@"schemaVersion"]) || ![@[@1,@2,@3] containsObject:value[@"schemaVersion"]] ||
        (payloadRecorded && (![value[@"payloadBasis"] isEqual:@"lengthAtHookEntry"] || ![value[@"unclassifiedMeaning"] isEqual:@"totalMinusEmptyAndNonempty"])) ||
        ![value[@"scope"] isEqual:@"boundWriterDecisions"] || ![value[@"attemptBasis"] isEqual:@"dataAndKeyNonNil"] ||
        ![value[@"allowedMeaning"] isEqual:@"originalCallForwarded"] || ![value[@"diskPersistence"] isEqual:@"notMeasured"] ||
        !axs_cachekeeper_write_number(value[@"lastEpoch"]) || !axs_cachekeeper_write_number(value[@"droppedEpochs"]) ||
        !axs_cachekeeper_write_boolean(value[@"truncated"]) || !axs_cachekeeper_write_boolean(value[@"overflow"]) ||
        ![value[@"epochs"] isKindOfClass:NSArray.class] || [value[@"epochs"] count]>AXS_CACHEKEEPER_WRITE_EPOCH_CAP ||
        !axs_cachekeeper_write_keys(value[@"unattributed"],@[@"data",@"extended"])) return nil;
    uint64_t last=[value[@"lastEpoch"] unsignedLongLongValue],dropped=[value[@"droppedEpochs"] unsignedLongLongValue];
    NSArray *rows=value[@"epochs"];
    if (dropped>last || last-dropped!=rows.count || (last && rows.count!=MIN(last,AXS_CACHEKEEPER_WRITE_EPOCH_CAP)) ||
        [value[@"truncated"] boolValue]!=(dropped>0) || ([value[@"overflow"] boolValue] && last!=AXS_CACHEKEEPER_WRITE_MAX)) return nil;
    NSMutableArray *epochs=[NSMutableArray new];uint64_t configuration=0,installation=0;NSDictionary *previous=nil;
    BOOL identityRecorded=![value[@"schemaVersion"] isEqual:@1];
    for (NSUInteger i=0;i<rows.count;i++) {
        id row=rows[i];NSArray *rowKeys=@[@"epoch",@"configuration",@"installation",@"enabled",@"mode",@"data",@"extended"];
        if (identityRecorded) rowKeys=[rowKeys arrayByAddingObject:@"identityState"];
        if (!axs_cachekeeper_write_keys(row,rowKeys) || !axs_cachekeeper_write_boolean(row[@"enabled"]) ||
            ![@[@"auto",@"clean",@"prevent"] containsObject:row[@"mode"]]) return nil;
        if (identityRecorded && ![row[@"identityState"] isEqual:([row[@"enabled"] boolValue] ? @"verified" : @"notRevalidated")]) return nil;
        for (NSString *key in @[@"epoch",@"configuration",@"installation"]) if (!axs_cachekeeper_write_number(row[key])) return nil;
        uint64_t currentConfiguration=[row[@"configuration"] unsignedLongLongValue],currentInstallation=[row[@"installation"] unsignedLongLongValue];
        if ([row[@"epoch"] unsignedLongLongValue]!=dropped+i+1 || currentConfiguration<configuration || currentInstallation<installation) return nil;
        NSDictionary *data=axs_cachekeeper_write_counts_projection(row[@"data"],payloadRecorded),*extended=axs_cachekeeper_write_counts_projection(row[@"extended"],payloadRecorded);
        if (!data || !extended || ((! [row[@"enabled"] boolValue] || [row[@"mode"] isEqual:@"clean"]) &&
            ([data[@"blocked"] unsignedLongLongValue] || [extended[@"blocked"] unsignedLongLongValue]))) return nil;
        if (i && currentConfiguration==configuration && currentInstallation==installation &&
            [row[@"enabled"] isEqual:previous[@"enabled"]] && [row[@"mode"] isEqual:previous[@"mode"]]) return nil;
        configuration=currentConfiguration;installation=currentInstallation;
        previous=row;
        NSMutableDictionary *projected=[@{@"epoch":row[@"epoch"],@"configuration":row[@"configuration"],@"installation":row[@"installation"],
            @"enabled":row[@"enabled"],@"mode":[row[@"mode"] copy],@"data":data,@"extended":extended} mutableCopy];
        if (identityRecorded) projected[@"identityState"]=[row[@"identityState"] copy];
        [epochs addObject:[projected copy]];
    }
    NSDictionary *data=axs_cachekeeper_write_counts_projection(value[@"unattributed"][@"data"],payloadRecorded),*extended=axs_cachekeeper_write_counts_projection(value[@"unattributed"][@"extended"],payloadRecorded);
    if (!data || !extended) return nil;
    NSMutableDictionary *result=[value mutableCopy];result[@"epochs"]=[epochs copy];result[@"unattributed"]=@{@"data":data,@"extended":extended};return [result copy];
}
#endif
