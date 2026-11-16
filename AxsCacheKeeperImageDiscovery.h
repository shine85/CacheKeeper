#pragma once
#import <Foundation/Foundation.h>
#include <math.h>

enum { AxsCacheKeeperImageMethodCount = 25 };
typedef NS_ENUM(NSUInteger, AxsCacheKeeperImageContract) {
    AxsCacheKeeperImageContractUnknown,
    AxsCacheKeeperImageContractModern,
    AxsCacheKeeperImageContractFixedSerialLegacy,
};
// classMask: SDImageCache=1, SDDiskCache=2, SDImageCacheConfig=4, SDMemoryCache=8.
// methodIndex is the first failing one-based MethodSpec; zero means no method failed.
static inline BOOL axs_cachekeeper_image_discovery_integer(id value, NSUInteger maximum) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()) return NO;
    double number=[value doubleValue];
    return isfinite(number) && number>=0 && number<=maximum && floor(number)==number;
}
static inline BOOL axs_cachekeeper_image_discovery_bool(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID();
}
static inline NSDictionary *axs_cachekeeper_image_source_check_projection(id value) {
    if (![value isKindOfClass:NSDictionary.class] || [value count]!=6 ||
        !axs_cachekeeper_image_discovery_integer(value[@"schemaVersion"],1) || [value[@"schemaVersion"] unsignedIntegerValue]!=1 ||
        !axs_cachekeeper_image_discovery_bool(value[@"accepted"]) ||
        !axs_cachekeeper_image_discovery_integer(value[@"methodIndex"],25) ||
        !axs_cachekeeper_image_discovery_integer(value[@"helperIndex"],2) ||
        ![value[@"stage"] isKindOfClass:NSString.class] || ![value[@"reason"] isKindOfClass:NSString.class]) return nil;
    NSString *stage=value[@"stage"],*reason=value[@"reason"];NSUInteger method=[value[@"methodIndex"] unsignedIntegerValue],helper=[value[@"helperIndex"] unsignedIntegerValue];
    NSArray *reasons=nil;BOOL indexedMain=NO,indexedHelper=NO;
    if ([stage isEqual:@"slots"]) {reasons=@[@"missing",@"unexpected"];indexedMain=YES;}
    else if ([stage isEqual:@"mainIdentity"]) reasons=@[@"missingBase",@"notMainBase",@"bundle",@"version",@"build"];
    else if ([stage isEqual:@"layout"]) reasons=@[@"read",@"header",@"commands",@"uuid",@"segments",@"section",@"slide"];
    else if ([stage isEqual:@"mainWindow"]) {reasons=@[@"pointer",@"offset",@"section",@"protectionOrRead",@"digest"];indexedMain=YES;}
    else if ([stage isEqual:@"helperOwner"]) {reasons=@[@"missing",@"metaclass",@"image",@"methodMissing",@"inherited"];indexedHelper=YES;}
    else if ([stage isEqual:@"helperABI"]) {reasons=@[@"encodingRead",@"encoding"];indexedHelper=YES;}
    else if ([stage isEqual:@"helperWindow"]) {reasons=@[@"pointer",@"offset",@"section",@"protectionOrRead",@"digest",@"changed"];indexedHelper=YES;}
    else if ([stage isEqual:@"complete"]) reasons=@[@"none"];
    if (![reasons containsObject:reason] || [value[@"accepted"] boolValue]!=[stage isEqual:@"complete"] ||
        (indexedMain ? !method || helper : method!=0) || (indexedHelper ? !helper || method : helper!=0) ||
        (indexedMain && method==11 && !([stage isEqual:@"slots"] && [reason isEqual:@"unexpected"])) ||
        ([reason isEqual:@"unexpected"] && method!=11)) return nil;
    return @{@"schemaVersion":@1,@"accepted":value[@"accepted"],@"stage":[stage copy],@"reason":[reason copy],@"methodIndex":@(method),@"helperIndex":@(helper)};
}
static inline NSDictionary *axs_cachekeeper_image_loaded_relation_projection(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    NSMutableDictionary *result=[NSMutableDictionary new];
    NSDictionary *masks=@{@"classPresentMask":@31,@"classNameKnownMask":@31,@"classNameEqualsMainMask":@31,
        @"classResolvedMask":@31,@"classLoadedMainMask":@31,@"classUUIDMatchesMainMask":@31,
        @"originalResolvedMask":@15,@"originalBaseIsMainMask":@15,@"originalUUIDMatchesMainMask":@15,
        @"helperResolvedMask":@3,@"helperBaseIsMainMask":@3,@"helperUUIDMatchesMainMask":@3};
    if (!axs_cachekeeper_image_discovery_integer(value[@"schemaVersion"],1) || [value[@"schemaVersion"] unsignedIntegerValue]!=1) return nil;
    result[@"schemaVersion"]=@1;
    for (NSString *key in masks) {
        if (!axs_cachekeeper_image_discovery_integer(value[key],[masks[key] unsignedIntegerValue])) return nil;
        result[key]=@([value[key] unsignedIntegerValue]);
    }
    for (NSString *key in @[@"initializerUsesSavedOriginal",@"initializerResolved",@"initializerBaseIsMain",@"initializerUUIDMatchesMain",@"mainUUIDResolved",@"mainUUIDMatchesContract",@"mainLayoutChecked"])
        if (!axs_cachekeeper_image_discovery_bool(value[key])) return nil;else result[key]=value[key];
    for (NSArray *pair in @[@[@"classNameKnownMask",@"classPresentMask"],@[@"classNameEqualsMainMask",@"classNameKnownMask"],
        @[@"classResolvedMask",@"classPresentMask"],@[@"classLoadedMainMask",@"classResolvedMask"],@[@"classUUIDMatchesMainMask",@"classResolvedMask"],
        @[@"originalBaseIsMainMask",@"originalResolvedMask"],@[@"originalUUIDMatchesMainMask",@"originalResolvedMask"],
        @[@"helperBaseIsMainMask",@"helperResolvedMask"],@[@"helperUUIDMatchesMainMask",@"helperResolvedMask"]])
        if ([result[pair[0]] unsignedIntegerValue]&~[result[pair[1]] unsignedIntegerValue]) return nil;
    if (![result[@"initializerResolved"] boolValue] && ([result[@"initializerBaseIsMain"] boolValue] || [result[@"initializerUUIDMatchesMain"] boolValue])) return nil;
    if (![result[@"mainUUIDResolved"] boolValue] && ([result[@"mainUUIDMatchesContract"] boolValue] || [result[@"initializerUUIDMatchesMain"] boolValue] ||
        [result[@"classUUIDMatchesMainMask"] unsignedIntegerValue] || [result[@"originalUUIDMatchesMainMask"] unsignedIntegerValue] || [result[@"helperUUIDMatchesMainMask"] unsignedIntegerValue] ||
        [result[@"initializerResolved"] boolValue] || [result[@"classResolvedMask"] unsignedIntegerValue] ||
        [result[@"originalResolvedMask"] unsignedIntegerValue] || [result[@"helperResolvedMask"] unsignedIntegerValue])) return nil;
    if ([result[@"initializerUsesSavedOriginal"] boolValue] &&
        ([result[@"initializerResolved"] boolValue]!=(([result[@"originalResolvedMask"] unsignedIntegerValue]&1)!=0) ||
         [result[@"initializerBaseIsMain"] boolValue]!=(([result[@"originalBaseIsMainMask"] unsignedIntegerValue]&1)!=0) ||
         [result[@"initializerUUIDMatchesMain"] boolValue]!=(([result[@"originalUUIDMatchesMainMask"] unsignedIntegerValue]&1)!=0))) return nil;
    if (![[NSSet setWithArray:[value allKeys]] isEqual:[NSSet setWithArray:result.allKeys]]) return nil;
    return [result copy];
}
static inline NSDictionary *axs_cachekeeper_image_discovery_projection(id value) {
    if (![value isKindOfClass:NSDictionary.class] ||
        !axs_cachekeeper_image_discovery_integer(value[@"schemaVersion"],2) || ![value[@"schemaVersion"] unsignedIntegerValue] ||
        !axs_cachekeeper_image_discovery_integer(value[@"classMask"],15) ||
        !axs_cachekeeper_image_discovery_integer(value[@"methodIndex"],AxsCacheKeeperImageMethodCount)) return nil;
    NSUInteger schema=[value[@"schemaVersion"] unsignedIntegerValue];
    NSDictionary *sourceCheck=nil,*relation=nil;
    if (schema==1) {if ([value count]!=7) return nil;}
    else {
        relation=axs_cachekeeper_image_loaded_relation_projection(value[@"loadedRelation"]);
        if (!relation) return nil;
        if (value[@"sourceCheck"] && !(sourceCheck=axs_cachekeeper_image_source_check_projection(value[@"sourceCheck"]))) return nil;
        if ([value count]!=(sourceCheck ? 9 : 8)) return nil;
    }
    NSString *stage=value[@"stage"],*kind=value[@"imageKind"],*source=value[@"source"],*failure=value[@"failure"];
    if (![stage isKindOfClass:NSString.class] || ![kind isKindOfClass:NSString.class] ||
        ![source isKindOfClass:NSString.class] || ![failure isKindOfClass:NSString.class] ||
        ![@[@"notChecked",@"classes",@"image",@"source",@"method",@"complete"] containsObject:stage] ||
        ![@[@"unknown",@"main",@"framework",@"other"] containsObject:kind] ||
        ![@[@"unknown",@"frameworkVersion",@"imageUUID",@"imageFingerprint",@"testPinned",@"rejected"] containsObject:source] ||
        ![@[@"none",@"missingClass",@"missingImage",@"mixedImages",@"missingInitializer",@"imageLookup",@"unknownSource",
            @"missingMethod",@"unexpectedMethod",@"inheritedMethod",@"signature",@"returnType",@"argumentCount",@"argumentType",@"methodImage",@"methodsChanged"] containsObject:failure]) return nil;
    NSUInteger mask=[value[@"classMask"] unsignedIntegerValue],index=[value[@"methodIndex"] unsignedIntegerValue];
    BOOL trusted=[@[@"frameworkVersion",@"imageUUID",@"imageFingerprint",@"testPinned"] containsObject:source];
    if ([stage isEqual:@"notChecked"]) {
        if (mask || index || ![kind isEqual:@"unknown"] || ![source isEqual:@"unknown"] || ![failure isEqual:@"none"]) return nil;
    } else if ([stage isEqual:@"complete"]) {
        if (mask!=15 || index || !trusted || [kind isEqual:@"unknown"] || ![failure isEqual:@"none"]) return nil;
    } else if ([stage isEqual:@"classes"]) {
        if (mask==15 || index || ![source isEqual:@"unknown"] || ![failure isEqual:@"missingClass"]) return nil;
    } else if ([stage isEqual:@"image"]) {
        if (mask!=15 || index || ![source isEqual:@"unknown"] ||
            ![@[@"missingImage",@"mixedImages",@"missingInitializer",@"imageLookup"] containsObject:failure]) return nil;
    } else if ([stage isEqual:@"source"]) {
        if (mask!=15 || index || ![source isEqual:@"rejected"] || ![failure isEqual:@"unknownSource"]) return nil;
    } else if (mask!=15 || !trusted || [kind isEqual:@"unknown"] ||
        ![@[@"missingMethod",@"unexpectedMethod",@"inheritedMethod",@"signature",@"returnType",@"argumentCount",@"argumentType",@"methodImage",@"methodsChanged"] containsObject:failure] ||
        (!index && ![failure isEqual:@"methodsChanged"])) return nil;
    if (schema==2) {
        if (([relation[@"classPresentMask"] unsignedIntegerValue]&15)!=mask) return nil;
        BOOL layoutAttempted=sourceCheck && [@[@"layout",@"mainWindow",@"helperOwner",@"helperABI",@"helperWindow",@"complete"] containsObject:sourceCheck[@"stage"]];
        if ([relation[@"mainLayoutChecked"] boolValue]!=layoutAttempted) return nil;
        BOOL legacyStage=[@[@"source",@"method",@"complete"] containsObject:stage];
        if (sourceCheck && !legacyStage) return nil;
        if ([@[@"frameworkVersion",@"imageUUID"] containsObject:source] && sourceCheck) return nil;
        if ([source isEqual:@"testPinned"] && (!sourceCheck || [sourceCheck[@"accepted"] boolValue])) return nil;
        if ([failure isEqual:@"unknownSource"] && (!sourceCheck || [sourceCheck[@"accepted"] boolValue])) return nil;
        if ([source isEqual:@"imageFingerprint"] && (!sourceCheck || (![failure isEqual:@"methodsChanged"] && ![sourceCheck[@"accepted"] boolValue]))) return nil;
    }
    NSMutableDictionary *result=[@{@"schemaVersion":@(schema),@"classMask":@(mask),@"methodIndex":@(index),
        @"stage":[stage copy],@"imageKind":[kind copy],@"source":[source copy],@"failure":[failure copy]} mutableCopy];
    if (relation) result[@"loadedRelation"]=relation;if (sourceCheck) result[@"sourceCheck"]=sourceCheck;
    return [result copy];
}
