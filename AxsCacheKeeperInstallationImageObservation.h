#pragma once
#import "AxsCacheKeeperImageSourceObservation.h"

static inline NSDictionary *axs_cachekeeper_installation_image_observation_projection(id value) {
    if (![value isKindOfClass:NSDictionary.class] || !axs_cachekeeper_image_discovery_integer(value[@"schemaVersion"],1) ||
        [value[@"schemaVersion"] unsignedIntegerValue]!=1 || ![@[@"observed",@"notVerified"] containsObject:value[@"state"]] ||
        ![value[@"mappingBackingIdentity"] isEqual:@"notVerified"] || ![@[@"none",@"mainThread",@"snapshot",@"read",@"invalid",@"architecture",@"ambiguous",@"changed"] containsObject:value[@"reason"]]) return nil;
    NSMutableArray *keys=[NSMutableArray arrayWithArray:@[@"schemaVersion",@"state",@"reason",@"mappingBackingIdentity"]];
    if ([value[@"state"] isEqual:@"observed"]) {
        [keys addObjectsFromArray:@[@"container",@"metadata"]];
        if (![value[@"reason"] isEqual:@"none"] || ![@[@"thin",@"fat32",@"fat64"] containsObject:value[@"container"]] ||
            !axs_cachekeeper_image_macho_observation_projection(value[@"metadata"]) ||
            ![@[@"complete",@"missingUUID"] containsObject:value[@"metadata"][@"state"]]) return nil;
    } else if ([value[@"reason"] isEqual:@"none"]) return nil;
    return axs_cachekeeper_image_observation_keys(value,keys) ? [value copy] : nil;
}
static inline NSDictionary *axs_cachekeeper_installed_runtime_relation_projection(id value) {
    if (!axs_cachekeeper_image_observation_keys(value,@[@"schemaVersion",@"installationImage",@"mainUUIDRelation",@"candidateUUIDRelation",@"mappingBackingIdentity"]) ||
        !axs_cachekeeper_image_discovery_integer(value[@"schemaVersion"],1) || [value[@"schemaVersion"] unsignedIntegerValue]!=1 ||
        !axs_cachekeeper_installation_image_observation_projection(value[@"installationImage"]) || ![value[@"mappingBackingIdentity"] isEqual:@"notVerified"]) return nil;
    for (NSString *key in @[@"mainUUIDRelation",@"candidateUUIDRelation"]) if (![@[@"notCompared",@"same",@"different"] containsObject:value[key]]) return nil;
    if (!value[@"installationImage"][@"metadata"][@"uuid"] &&
        (![value[@"mainUUIDRelation"] isEqual:@"notCompared"] || ![value[@"candidateUUIDRelation"] isEqual:@"notCompared"])) return nil;
    return [value copy];
}
static inline BOOL axs_cachekeeper_installed_runtime_relation_matches(NSDictionary *relation,NSDictionary *runtime) {
    if (!axs_cachekeeper_installed_runtime_relation_projection(relation) || (runtime && !axs_cachekeeper_image_runtime_observation_projection(runtime))) return NO;
    NSString *uuid=relation[@"installationImage"][@"metadata"][@"uuid"];
    for (NSArray *pair in @[@[@"mainModule",@"mainUUIDRelation"],@[@"candidateModule",@"candidateUUIDRelation"]]) {
        NSUInteger module=[runtime[pair[0]] unsignedIntegerValue];NSString *loaded=nil;
        if ([runtime[@"state"] isEqual:@"complete"] && module && module<=[runtime[@"modules"] count]) loaded=runtime[@"modules"][module-1][@"metadata"][@"uuid"];
        NSString *expected=uuid && loaded ? ([uuid isEqual:loaded] ? @"same" : @"different") : @"notCompared";
        if (![relation[pair[1]] isEqual:expected]) return NO;
    }
    return YES;
}
