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
static inline NSDictionary *axs_cachekeeper_image_discovery_projection(id value) {
    if (![value isKindOfClass:NSDictionary.class] || [value count]!=7 ||
        !axs_cachekeeper_image_discovery_integer(value[@"schemaVersion"],1) || [value[@"schemaVersion"] unsignedIntegerValue]!=1 ||
        !axs_cachekeeper_image_discovery_integer(value[@"classMask"],15) ||
        !axs_cachekeeper_image_discovery_integer(value[@"methodIndex"],AxsCacheKeeperImageMethodCount)) return nil;
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
    return [value copy];
}
