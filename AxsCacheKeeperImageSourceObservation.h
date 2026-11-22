#pragma once
#import "AxsCacheKeeperImageDiscovery.h"
#include <stdint.h>
#include <stdlib.h>

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

#import <objc/runtime.h>
// Diagnostic metadata reads enumerate own methods: they never ask the resolver for a Method.
static inline NSDictionary *axs_cachekeeper_image_observation_own_methods(Class owner,NSArray *records) {
    unsigned count=0;Method *methods=class_copyMethodList(owner,&count);NSMutableDictionary *snapshot=[NSMutableDictionary new];
    NSMutableSet *selected=[NSMutableSet new];for (NSDictionary *record in records) if (record[@"class"]==owner && ![record[@"absent"] boolValue]) [selected addObject:record[@"selector"]];
    for (unsigned index=0;index<count;index++) {
        NSString *selector=NSStringFromSelector(method_getName(methods[index]));if (![selected containsObject:selector]) continue;
        if (snapshot[selector]) continue;
        snapshot[selector]=@{@"method":[NSValue valueWithPointer:methods[index]],@"implementation":[NSValue valueWithPointer:(const void *)method_getImplementation(methods[index])]};
    }
    free(methods);return [snapshot copy];
}
typedef const void *(*AxsCacheKeeperImageObservationCodeAddress)(const void *);
static inline NSDictionary *AxsCacheKeeperImageMethodsCheck(NSArray *methods,NSUInteger installationFailure,NSDictionary *(^helperCheck)(void),AxsCacheKeeperImageObservationCodeAddress codeAddress,BOOL captureRelations) {
    NSMutableDictionary *result=[@{@"schemaVersion":@1,@"accepted":@NO,@"cause":@"complete",@"methodIndex":@0,@"methodsCount":@(methods.count)} mutableCopy];
    if (installationFailure) {result[@"cause"]=@"installationOriginal";result[@"methodIndex"]=@(installationFailure);return [result copy];}
    if (helperCheck) {
        NSDictionary *helper=axs_cachekeeper_image_source_check_projection(helperCheck());
        if (!helper) {result[@"cause"]=@"helperCheckInvalid";return [result copy];}
        if (![helper[@"accepted"] boolValue]) {
            result[@"cause"]=@"legacyHelper";result[@"helperStage"]=helper[@"stage"];result[@"helperReason"]=helper[@"reason"];result[@"helperIndex"]=helper[@"helperIndex"];
            return [result copy];
        }
    }
    NSMutableDictionary *ownerSnapshots=captureRelations ? [NSMutableDictionary new] : nil;
    for (NSUInteger index=0;index<methods.count;index++) {
        NSDictionary *entry=methods[index];Class owner=entry[@"class"];SEL selector=NSSelectorFromString(entry[@"selector"]);
        if ([entry[@"absent"] boolValue]) {
            if (class_getInstanceMethod(owner,selector)) {result[@"cause"]=@"unexpectedMethod";result[@"methodIndex"]=@(index+1);return [result copy];}
            continue;
        }
        const void *stored=[entry[@"implementation"] pointerValue];
        NSDictionary *beforeRow=nil;
        if (captureRelations) {
            NSValue *key=[NSValue valueWithPointer:(__bridge const void *)owner];NSDictionary *snapshot=ownerSnapshots[key];
            // Freeze each class before its first gate lookup; later selectors reuse that same view.
            if (!snapshot) {snapshot=axs_cachekeeper_image_observation_own_methods(owner,methods);ownerSnapshots[key]=snapshot;}
            beforeRow=snapshot[entry[@"selector"]];
        }
        Method before=[beforeRow[@"method"] pointerValue];const void *beforeIMP=[beforeRow[@"implementation"] pointerValue];
        // This is the gate's original, single lookup. Canonical relations below never grant admission.
        IMP actual=class_getMethodImplementation(owner,selector);
        if ((const void *)actual!=stored) {
            result[@"cause"]=@"implementation";result[@"methodIndex"]=@(index+1);result[@"relationState"]=captureRelations ? @"collected" : @"notCollected";
            if (!captureRelations) return [result copy];
            NSDictionary *afterRow=axs_cachekeeper_image_observation_own_methods(owner,methods)[entry[@"selector"]];
            Method after=[afterRow[@"method"] pointerValue];const void *afterIMP=[afterRow[@"implementation"] pointerValue];
            result[@"methodPresentBefore"]=before ? @YES : @NO;result[@"methodPresentAfter"]=after ? @YES : @NO;
            result[@"methodIdentityStable"]=(before && after && before==after) ? @YES : @NO;
            result[@"methodIMPStable"]=(before && after && beforeIMP==afterIMP) ? @YES : @NO;
            result[@"methodRawMatchesStoredBefore"]=(before && (const void *)beforeIMP==stored) ? @YES : @NO;
            result[@"methodRawMatchesStoredAfter"]=(after && (const void *)afterIMP==stored) ? @YES : @NO;
            result[@"classRawMatchesStored"]=@NO;
            result[@"methodCanonicalMatchesStoredBefore"]=(before && codeAddress((const void *)beforeIMP)==codeAddress(stored)) ? @YES : @NO;
            result[@"methodCanonicalMatchesStoredAfter"]=(after && codeAddress((const void *)afterIMP)==codeAddress(stored)) ? @YES : @NO;
            result[@"classCanonicalMatchesStored"]=(codeAddress((const void *)actual)==codeAddress(stored)) ? @YES : @NO;
            return [result copy];
        }
    }
    if (methods.count!=AxsCacheKeeperImageMethodCount) result[@"cause"]=@"methodCount";
    else result[@"accepted"]=@YES;
    return [result copy];
}
static inline NSDictionary *axs_cachekeeper_image_methods_check_projection(id value) {
    NSArray *keys=@[@"schemaVersion",@"accepted",@"cause",@"methodIndex",@"methodsCount"];
    if (![value isKindOfClass:NSDictionary.class] || !axs_cachekeeper_image_discovery_integer(value[@"schemaVersion"],1) || [value[@"schemaVersion"] unsignedIntegerValue]!=1 ||
        !axs_cachekeeper_image_discovery_bool(value[@"accepted"]) || !axs_cachekeeper_image_discovery_integer(value[@"methodIndex"],4096) ||
        !axs_cachekeeper_image_discovery_integer(value[@"methodsCount"],4096) || ![value[@"cause"] isKindOfClass:NSString.class]) return nil;
    NSString *cause=value[@"cause"];NSUInteger index=[value[@"methodIndex"] unsignedIntegerValue],count=[value[@"methodsCount"] unsignedIntegerValue];
    BOOL accepted=[value[@"accepted"] boolValue];
    if ([cause isEqual:@"complete"]) {if (!accepted || index || count!=25) return nil;}
    else if (accepted) return nil;
    else if ([cause isEqual:@"installationOriginal"]) {if (!index || index>25) return nil;}
    else if ([cause isEqual:@"legacyHelper"]) {
        if (index) return nil;keys=[keys arrayByAddingObjectsFromArray:@[@"helperStage",@"helperReason",@"helperIndex"]];
        NSDictionary *helper=@{@"schemaVersion":@1,@"accepted":@NO,@"stage":value[@"helperStage"] ?: NSNull.null,@"reason":value[@"helperReason"] ?: NSNull.null,@"methodIndex":@0,@"helperIndex":value[@"helperIndex"] ?: NSNull.null};
        NSDictionary *valid=axs_cachekeeper_image_source_check_projection(helper);
        if (!valid || ![@[@"mainIdentity",@"layout",@"helperOwner",@"helperABI",@"helperWindow"] containsObject:valid[@"stage"]]) return nil;
    } else if ([cause isEqual:@"implementation"]) {
        if (!index || index>count) return nil;
        keys=[keys arrayByAddingObject:@"relationState"];
        if (![value[@"relationState"] isEqual:@"collected"]) {
            if (![value[@"relationState"] isEqual:@"notCollected"]) return nil;
            return axs_cachekeeper_image_observation_keys(value,keys) ? [value copy] : nil;
        }
        NSArray *relations=@[@"methodPresentBefore",@"methodPresentAfter",@"methodIdentityStable",@"methodIMPStable",@"methodRawMatchesStoredBefore",@"methodRawMatchesStoredAfter",@"classRawMatchesStored",@"methodCanonicalMatchesStoredBefore",@"methodCanonicalMatchesStoredAfter",@"classCanonicalMatchesStored"];
        keys=[keys arrayByAddingObjectsFromArray:relations];for (NSString *key in relations) if (!axs_cachekeeper_image_discovery_bool(value[key])) return nil;
        if ([value[@"classRawMatchesStored"] boolValue] ||
            (![value[@"methodPresentBefore"] boolValue] && ([value[@"methodRawMatchesStoredBefore"] boolValue] || [value[@"methodCanonicalMatchesStoredBefore"] boolValue])) ||
            (![value[@"methodPresentAfter"] boolValue] && ([value[@"methodRawMatchesStoredAfter"] boolValue] || [value[@"methodCanonicalMatchesStoredAfter"] boolValue])) ||
            (([value[@"methodIdentityStable"] boolValue] || [value[@"methodIMPStable"] boolValue]) && (![value[@"methodPresentBefore"] boolValue] || ![value[@"methodPresentAfter"] boolValue])) ||
            ([value[@"methodRawMatchesStoredBefore"] boolValue] && ![value[@"methodCanonicalMatchesStoredBefore"] boolValue]) ||
            ([value[@"methodRawMatchesStoredAfter"] boolValue] && ![value[@"methodCanonicalMatchesStoredAfter"] boolValue])) return nil;
    } else if ([cause isEqual:@"unexpectedMethod"]) {if (!index || index>count) return nil;}
    else if ([cause isEqual:@"methodCount"]) {if (index || count==25) return nil;}
    else if ([cause isEqual:@"helperCheckInvalid"]) {if (index) return nil;}
    else return nil;
    if ([cause isEqual:@"implementation"] && [value[@"relationState"] isEqual:@"collected"] && [value[@"methodIMPStable"] boolValue] &&
        ([value[@"methodRawMatchesStoredBefore"] boolValue]!=[value[@"methodRawMatchesStoredAfter"] boolValue] ||
         [value[@"methodCanonicalMatchesStoredBefore"] boolValue]!=[value[@"methodCanonicalMatchesStoredAfter"] boolValue])) return nil;
    return axs_cachekeeper_image_observation_keys(value,keys) ? [value copy] : nil;
}
static inline NSDictionary *axs_cachekeeper_image_sdk_rejection_projection(id value) {
    if (![value isKindOfClass:NSDictionary.class] || !axs_cachekeeper_image_discovery_integer(value[@"schemaVersion"],1) || [value[@"schemaVersion"] unsignedIntegerValue]!=1) return nil;
    if ([value[@"state"] isEqual:@"notRecorded"]) return axs_cachekeeper_image_observation_keys(value,@[@"schemaVersion",@"state"]) ? [value copy] : nil;
    NSDictionary *check=axs_cachekeeper_image_methods_check_projection(value[@"check"]);
    if ([check[@"cause"] isEqual:@"implementation"] && ![check[@"relationState"] isEqual:@"collected"]) return nil;
    if (![value[@"state"] isEqual:@"recorded"] || !axs_cachekeeper_image_observation_keys(value,@[@"schemaVersion",@"state",@"initializerOrdinal",@"check"]) ||
        !axs_cachekeeper_image_discovery_integer(value[@"initializerOrdinal"],9007199254740991ULL) || ![value[@"initializerOrdinal"] unsignedLongLongValue] || !check || [check[@"accepted"] boolValue]) return nil;
    return @{@"schemaVersion":@1,@"state":@"recorded",@"initializerOrdinal":value[@"initializerOrdinal"],@"check":check};
}
