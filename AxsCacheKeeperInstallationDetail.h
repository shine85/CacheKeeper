#pragma once
#import <Foundation/Foundation.h>
#include <limits.h>
#include <math.h>

enum {
    AxsCacheKeeperInstallationIdentityFieldCount=11,
    AxsCacheKeeperInstallationIdentityObjectFields=(1U<<7)-1,
    AxsCacheKeeperInstallationIdentityAllFields=(1U<<AxsCacheKeeperInstallationIdentityFieldCount)-1
};
static inline BOOL axs_cachekeeper_installation_detail_number(id value, NSUInteger maximum, NSUInteger *result) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()) return NO;
    double number=[value doubleValue];
    if (!isfinite(number) || number<0 || number>maximum || floor(number)!=number) return NO;
    *result=(NSUInteger)number;return YES;
}
static inline NSDictionary *axs_cachekeeper_installation_resample_projection(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    NSUInteger fdError,pathError;
    if (!axs_cachekeeper_installation_detail_number(value[@"fdErrno"],INT_MAX,&fdError) ||
        !axs_cachekeeper_installation_detail_number(value[@"pathErrno"],INT_MAX,&pathError)) return nil;
    NSMutableDictionary *result=[@{@"fdErrno":@(fdError),@"pathErrno":@(pathError)} mutableCopy];
    for (NSArray *pair in @[@[@"fdErrno",@"fdDifferenceMask"],@[@"pathErrno",@"pathDifferenceMask"]]) {
        if (![result[pair[0]] unsignedIntegerValue]) {
            NSUInteger mask;
            if (!axs_cachekeeper_installation_detail_number(value[pair[1]],AxsCacheKeeperInstallationIdentityAllFields,&mask)) return nil;
            result[pair[1]]=@(mask);
        }
    }
    if (!fdError && !pathError) {
        NSUInteger mask;
        if (!axs_cachekeeper_installation_detail_number(value[@"pathFDDifferenceMask"],AxsCacheKeeperInstallationIdentityAllFields,&mask)) return nil;
        result[@"pathFDDifferenceMask"]=@(mask);
    }
    if (![[NSSet setWithArray:[value allKeys]] isEqual:[NSSet setWithArray:result.allKeys]]) return nil;
    return [result copy];
}
static inline BOOL axs_cachekeeper_installation_detail_bool(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID();
}
static inline NSDictionary *axs_cachekeeper_installation_view_projection(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    NSUInteger schema;
    if (!axs_cachekeeper_installation_detail_number(value[@"schemaVersion"],1,&schema) || schema!=1) return nil;
    NSMutableDictionary *result=[@{@"schemaVersion":@1} mutableCopy];
    NSDictionary *enums=@{@"context":@[@"unspecified",@"hostMainBundle",@"registryBundle",@"testInjected"],
        @"pathAPI":@[@"lstat",@"fstatatNoFollow"],@"openAPI":@[@"openSearchNoFollow",@"openatReadNoFollow"],@"fdAPI":@[@"fstat"],
        @"pathCallOwner":@[@"libSystem",@"libRootHide",@"other",@"unresolved"],
        @"openCallOwner":@[@"libSystem",@"libRootHide",@"other",@"unresolved"],
        @"fdCallOwner":@[@"libSystem",@"libRootHide",@"other",@"unresolved"],
        @"fdPathState":@[@"success",@"failed",@"unavailable",@"invalidResult"],@"inputResolveState":@[@"success",@"failed"],
        @"fdResolveState":@[@"success",@"failed",@"notAttempted"]};
    for (NSString *key in enums) {
        if (![value[key] isKindOfClass:NSString.class] || ![enums[key] containsObject:value[key]]) return nil;
        result[key]=[value[key] copy];
    }
    for (NSString *key in @[@"pathCallResolved",@"openCallResolved",@"fdCallResolved",@"callOwnersStable",@"sameObjectNonTimeFields"])
        if (!axs_cachekeeper_installation_detail_bool(value[key])) return nil;else result[key]=value[key];
    for (NSArray *pair in @[@[@"pathCallOwner",@"pathCallResolved"],@[@"openCallOwner",@"openCallResolved"],@[@"fdCallOwner",@"fdCallResolved"]])
        if ([result[pair[1]] boolValue]==[result[pair[0]] isEqual:@"unresolved"]) return nil;
    if ([result[@"callOwnersStable"] boolValue] && (![result[@"pathCallResolved"] boolValue] || ![result[@"openCallResolved"] boolValue] || ![result[@"fdCallResolved"] boolValue])) return nil;
    BOOL root=[result[@"pathAPI"] isEqual:@"lstat"];
    if (root!=[result[@"openAPI"] isEqual:@"openSearchNoFollow"]) return nil;
    for (NSArray *pair in @[@[@"fdPathState",@"fdPathErrno"],@[@"inputResolveState",@"inputResolveErrno"],@[@"fdResolveState",@"fdResolveErrno"]]) {
        NSUInteger number;
        if (!axs_cachekeeper_installation_detail_number(value[pair[1]],INT_MAX,&number) ||
            ([result[pair[0]] isEqual:@"failed"] ? number==0 : number!=0)) return nil;
        result[pair[1]]=@(number);
    }
    BOOL fdPath=[result[@"fdPathState"] isEqual:@"success"],input=[result[@"inputResolveState"] isEqual:@"success"],fd=[result[@"fdResolveState"] isEqual:@"success"];
    if (fdPath==[result[@"fdResolveState"] isEqual:@"notAttempted"]) return nil;
    if (fdPath) {
        if (!axs_cachekeeper_installation_detail_bool(value[@"inputEqualsFDPath"])) return nil;result[@"inputEqualsFDPath"]=value[@"inputEqualsFDPath"];
    }
    if (input && fd) {
        if (!axs_cachekeeper_installation_detail_bool(value[@"resolvedInputEqualsResolvedFDPath"])) return nil;
        result[@"resolvedInputEqualsResolvedFDPath"]=value[@"resolvedInputEqualsResolvedFDPath"];
    }
    if (![[NSSet setWithArray:[value allKeys]] isEqual:[NSSet setWithArray:result.allKeys]]) return nil;
    return [result copy];
}
static inline NSDictionary *axs_cachekeeper_installation_identity_projection(id value, NSString *operation) {
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    NSUInteger schema,mask;
    if (!axs_cachekeeper_installation_detail_number(value[@"schemaVersion"],2,&schema) || !schema ||
        !axs_cachekeeper_installation_detail_number(value[@"differenceMask"],AxsCacheKeeperInstallationIdentityAllFields,&mask) || !mask ||
        ![value[@"comparison"] isKindOfClass:NSString.class]) return nil;
    NSString *comparison=value[@"comparison"];
    BOOL allowed=([operation isEqual:@"openIdentity"] && [comparison isEqual:@"pathToFD"]) ||
        ([operation isEqual:@"recheckIdentity"] && [@[@"referenceToFD",@"fdToPath",@"referenceToPath"] containsObject:comparison]) ||
        ([operation isEqual:@"snapshotIdentity"] && [@[@"snapshotToFD",@"snapshotToPath"] containsObject:comparison]);
    if (!allowed) return nil;
    NSMutableDictionary *result=[@{@"schemaVersion":@(schema),@"comparison":[comparison copy],@"differenceMask":@(mask)} mutableCopy];
    if (value[@"resample"]) {
        NSDictionary *resample=axs_cachekeeper_installation_resample_projection(value[@"resample"]);
        if (![operation isEqual:@"openIdentity"] || !resample) return nil;
        result[@"resample"]=resample;
    }
    if (schema==2) {
        NSDictionary *view=axs_cachekeeper_installation_view_projection(value[@"viewObservation"]);
        if (![operation isEqual:@"openIdentity"] || !view || !result[@"resample"] ||
            [view[@"sameObjectNonTimeFields"] boolValue]!=((mask&127)==0)) return nil;
        result[@"viewObservation"]=view;
    }
    if (![[NSSet setWithArray:[value allKeys]] isEqual:[NSSet setWithArray:result.allKeys]]) return nil;
    return [result copy];
}

// The only export contract for installation failures. No paths, metadata values or error messages.
// A missing detail is allowed by older callers; a present invalid detail must not be exported.
static inline NSDictionary *axs_cachekeeper_installation_detail_projection(id value) {
    if (![value isKindOfClass:NSDictionary.class] || [value count]!=(value[@"identity"] ? 4 : 3) ||
        ![value[@"target"] isKindOfClass:NSString.class] || ![value[@"operation"] isKindOfClass:NSString.class] ||
        ![value[@"errno"] isKindOfClass:NSNumber.class]) return nil;
    NSString *target=value[@"target"],*operation=value[@"operation"];
    NSUInteger number;
    if (!axs_cachekeeper_installation_detail_number(value[@"errno"],INT_MAX,&number)) return nil;
    NSArray *operations=nil;
    if ([target isEqual:@"input"]) operations=@[@"identifier",@"version",@"url",@"path"];
    else if ([target isEqual:@"snapshot"]) operations=@[@"shape",@"executable",@"path",@"version",@"fingerprint"];
    else if ([target isEqual:@"registry"]) operations=@[@"enumerate"];
    else if ([@[@"root",@"info",@"main"] containsObject:target]) {
        operations=@[@"stat",@"open",@"fstat",@"type",@"openIdentity",@"recheckFD",@"recheckPath",@"recheckIdentity",@"snapshotIdentity"];
        if ([target isEqual:@"root"]) operations=[operations arrayByAddingObject:@"snapshotStat"];
        if ([target isEqual:@"info"]) operations=[operations arrayByAddingObjectsFromArray:
            @[@"size",@"read",@"parse",@"metadataType",@"identifier",@"identifierMismatch",@"executable",@"build",@"version",@"versionMismatch"]];
    }
    if (![operations containsObject:operation]) return nil;
    BOOL syscall=[@[@"stat",@"open",@"fstat",@"snapshotStat",@"recheckFD",@"recheckPath"] containsObject:operation];
    // read==0 diagnoses premature EOF; only failed syscalls carry a positive errno.
    if (syscall ? number==0 : ![operation isEqual:@"read"] && number!=0) return nil;
    NSMutableDictionary *result=[@{@"target":[target copy],@"operation":[operation copy],@"errno":@(number)} mutableCopy];
    if (value[@"identity"]) {
        NSDictionary *identity=axs_cachekeeper_installation_identity_projection(value[@"identity"],operation);
        if (!identity || ![@[@"root",@"info",@"main"] containsObject:target]) return nil;
        if (identity[@"viewObservation"] && [target isEqual:@"root"]!=[identity[@"viewObservation"][@"pathAPI"] isEqual:@"lstat"]) return nil;
        result[@"identity"]=identity;
    }
    return [result copy];
}
