#pragma once
#import "AxsCacheKeeperImageDiscovery.h"
#include <stdint.h>

static inline BOOL axs_cachekeeper_image_observation_keys(NSDictionary *value,NSArray *keys) {
    return [value isKindOfClass:NSDictionary.class] && [value count]==keys.count &&
        [[NSSet setWithArray:value.allKeys] isEqual:[NSSet setWithArray:keys]];
}
static inline BOOL axs_cachekeeper_image_observation_signed(id value) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()) return NO;
    double number=[value doubleValue];return isfinite(number) && floor(number)==number && number>=INT32_MIN && number<=INT32_MAX;
}
static inline NSDictionary *axs_cachekeeper_image_macho_observation_projection(id value) {
    if (![value isKindOfClass:NSDictionary.class] || ![@[@"complete",@"missingUUID",@"invalid",@"unreadable",@"changed"] containsObject:value[@"state"]]) return nil;
    BOOL header=[@[@"complete",@"missingUUID"] containsObject:value[@"state"]];
    NSMutableArray *keys=[NSMutableArray arrayWithObject:@"state"];
    if (header) {
        [keys addObjectsFromArray:@[@"cpuType",@"cpuSubtype",@"fileType"]];
        if (!axs_cachekeeper_image_observation_signed(value[@"cpuType"]) || !axs_cachekeeper_image_observation_signed(value[@"cpuSubtype"]) ||
            !axs_cachekeeper_image_discovery_integer(value[@"fileType"],UINT32_MAX)) return nil;
    }
    if ([value[@"state"] isEqual:@"complete"]) {
        [keys addObject:@"uuid"];NSString *uuid=value[@"uuid"];
        if (![uuid isKindOfClass:NSString.class] || uuid.length!=32 ||
            [uuid rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet].location!=NSNotFound) return nil;
    }
    return axs_cachekeeper_image_observation_keys(value,keys) ? [value copy] : nil;
}
static inline NSDictionary *axs_cachekeeper_image_runtime_observation_projection(id value) {
    NSArray *keys=@[@"schemaVersion",@"state",@"dyldState",@"observedDyldImages",@"observedMethods",@"modules",@"classes",@"methods",@"originals",@"mainModule",@"candidateModule",@"initializerUsesSavedOriginal",@"mappingBackingIdentity"];
    if (!axs_cachekeeper_image_observation_keys(value,keys) ||
        !axs_cachekeeper_image_discovery_integer(value[@"schemaVersion"],2) || [value[@"schemaVersion"] unsignedIntegerValue]<1 ||
        ![@[@"complete",@"partial"] containsObject:value[@"state"]] || ![@[@"complete",@"partial",@"changed"] containsObject:value[@"dyldState"]] ||
        ![value[@"mappingBackingIdentity"] isEqual:@"notVerified"] || !axs_cachekeeper_image_discovery_bool(value[@"initializerUsesSavedOriginal"]) ||
        !axs_cachekeeper_image_discovery_integer(value[@"observedDyldImages"],4096) || !axs_cachekeeper_image_discovery_integer(value[@"observedMethods"],32768)) return nil;
    for (NSString *key in @[@"modules",@"classes",@"methods",@"originals"]) if (![value[key] isKindOfClass:NSArray.class]) return nil;
    NSArray *modules=value[@"modules"];
    BOOL complete=[value[@"state"] isEqual:@"complete"];
    if (complete && (![value[@"dyldState"] isEqual:@"complete"] || ![value[@"observedDyldImages"] unsignedIntegerValue])) return nil;
    if (modules.count>40 || [value[@"classes"] count]!=5 || [value[@"methods"] count]!=27 || [value[@"originals"] count]!=4) return nil;
    for (NSUInteger i=0;i<modules.count;i++) {
        NSDictionary *module=modules[i];NSMutableArray *moduleKeys=[NSMutableArray arrayWithArray:@[@"index",@"metadata",@"dyldMatches",@"contractUUIDRelation"]];
        if (![module isKindOfClass:NSDictionary.class] || !axs_cachekeeper_image_discovery_integer(module[@"index"],40) || [module[@"index"] unsignedIntegerValue]!=i+1 ||
            !axs_cachekeeper_image_macho_observation_projection(module[@"metadata"]) ||
            !axs_cachekeeper_image_discovery_integer(module[@"dyldMatches"],[value[@"observedDyldImages"] unsignedIntegerValue]) ||
            ![@[@"notResolved",@"matches",@"different"] containsObject:module[@"contractUUIDRelation"]]) return nil;
        if ([module[@"dyldMatches"] unsignedIntegerValue]==1) {
            [moduleKeys addObject:@"dyldIndex"];
            if (!axs_cachekeeper_image_discovery_integer(module[@"dyldIndex"],4095) || [module[@"dyldIndex"] unsignedIntegerValue]>=[value[@"observedDyldImages"] unsignedIntegerValue]) return nil;
        }
        NSString *uuid=module[@"metadata"][@"uuid"];
        NSString *relation=uuid ? ([uuid isEqual:@"b2b9d30a1caf31b482cac776e7eb2ba1"] ? @"matches" : @"different") : @"notResolved";
        if (![module[@"contractUUIDRelation"] isEqual:relation] || !axs_cachekeeper_image_observation_keys(module,moduleKeys)) return nil;
        if (complete && ![@[@"complete",@"missingUUID"] containsObject:module[@"metadata"][@"state"]]) return nil;
    }
    for (NSString *key in @[@"mainModule",@"candidateModule"]) if (!axs_cachekeeper_image_discovery_integer(value[key],modules.count)) return nil;
    if (complete && ![value[@"mainModule"] unsignedIntegerValue]) return nil;
    if ([value[@"mainModule"] unsignedIntegerValue]) {
        NSDictionary *main=modules[[value[@"mainModule"] unsignedIntegerValue]-1];
        if ([main[@"dyldMatches"] unsignedIntegerValue]!=1) return nil;
        // Preserve saved v1 observations; v2 identifies the executable independently of loader order.
        if ([value[@"schemaVersion"] unsignedIntegerValue]==1) {
            if ([main[@"dyldIndex"] unsignedIntegerValue]!=0) return nil;
        } else if ([main[@"metadata"][@"fileType"] unsignedIntegerValue]!=2) return nil;
    }
    for (NSUInteger i=0;i<5;i++) {
        NSDictionary *row=value[@"classes"][i];
        if (!axs_cachekeeper_image_observation_keys(row,@[@"index",@"present",@"nameState",@"module"]) ||
            !axs_cachekeeper_image_discovery_integer(row[@"index"],5) || [row[@"index"] unsignedIntegerValue]!=i+1 ||
            !axs_cachekeeper_image_discovery_bool(row[@"present"]) || !axs_cachekeeper_image_discovery_integer(row[@"module"],modules.count) ||
            ![@[@"matched",@"ambiguous",@"notRegistered",@"unavailable",@"partial"] containsObject:row[@"nameState"]] ||
            ([row[@"nameState"] isEqual:@"matched"]!=([row[@"module"] unsignedIntegerValue]>0)) ||
            (![row[@"present"] boolValue] && ![row[@"nameState"] isEqual:@"unavailable"])) return nil;
        if (complete && [row[@"present"] boolValue] && ![row[@"nameState"] isEqual:@"matched"]) return nil;
        if ([row[@"nameState"] isEqual:@"matched"] && [modules[[row[@"module"] unsignedIntegerValue]-1][@"dyldMatches"] unsignedIntegerValue]!=1) return nil;
    }
    for (NSUInteger i=0;i<27;i++) {
        NSDictionary *row=value[@"methods"][i];
        if (!axs_cachekeeper_image_observation_keys(row,@[@"index",@"state",@"module",@"wrapper"]) ||
            !axs_cachekeeper_image_discovery_integer(row[@"index"],27) || [row[@"index"] unsignedIntegerValue]!=i+1 ||
            !axs_cachekeeper_image_discovery_integer(row[@"module"],modules.count) || ![@[@"own",@"inherited",@"missing",@"partial"] containsObject:row[@"state"]] ||
            ![@[@"matches",@"different",@"notCompared"] containsObject:row[@"wrapper"]] ||
            ([@[@"missing",@"partial"] containsObject:row[@"state"]] && ([row[@"module"] unsignedIntegerValue] || ![row[@"wrapper"] isEqual:@"notCompared"]))) return nil;
        if (complete && ([row[@"state"] isEqual:@"partial"] || ([@[@"own",@"inherited"] containsObject:row[@"state"]] && ![row[@"module"] unsignedIntegerValue]))) return nil;
        if (i!=0 && i!=20 && i!=23 && i!=24 && ![row[@"wrapper"] isEqual:@"notCompared"]) return nil;
    }
    static const NSUInteger originalSlots[4]={0,20,23,24};
    for (NSUInteger i=0;i<4;i++) {
        NSDictionary *row=value[@"originals"][i];
        if (!axs_cachekeeper_image_observation_keys(row,@[@"index",@"present",@"module",@"currentRelation"]) ||
            !axs_cachekeeper_image_discovery_integer(row[@"index"],4) || [row[@"index"] unsignedIntegerValue]!=i+1 ||
            !axs_cachekeeper_image_discovery_bool(row[@"present"]) || !axs_cachekeeper_image_discovery_integer(row[@"module"],modules.count) ||
            ![@[@"same",@"different",@"notCompared"] containsObject:row[@"currentRelation"]] ||
            (![row[@"present"] boolValue] && ([row[@"module"] unsignedIntegerValue] || ![row[@"currentRelation"] isEqual:@"notCompared"]))) return nil;
        if (complete && [row[@"present"] boolValue] && ![row[@"module"] unsignedIntegerValue]) return nil;
        NSDictionary *current=value[@"methods"][originalSlots[i]];
        if (![@[@"own",@"inherited"] containsObject:current[@"state"]] && ![row[@"currentRelation"] isEqual:@"notCompared"]) return nil;
        if ([row[@"currentRelation"] isEqual:@"same"] && [row[@"module"] unsignedIntegerValue] && [current[@"module"] unsignedIntegerValue] &&
            ![row[@"module"] isEqual:current[@"module"]]) return nil;
    }
    if ([value[@"initializerUsesSavedOriginal"] boolValue] && ![value[@"originals"][0][@"present"] boolValue]) return nil;
    NSNumber *candidateValue=[value[@"initializerUsesSavedOriginal"] boolValue] ? value[@"originals"][0][@"module"] : value[@"methods"][0][@"module"];
    NSUInteger candidate=[candidateValue unsignedIntegerValue];
    if ([value[@"candidateModule"] unsignedIntegerValue]!=candidate) return nil;
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    return data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:nil] : nil;
}
