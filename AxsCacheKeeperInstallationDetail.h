#pragma once
#import <Foundation/Foundation.h>
#include <limits.h>
#include <math.h>

enum {
    AxsCacheKeeperInstallationIdentityFieldCount=11,
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
static inline NSDictionary *axs_cachekeeper_installation_identity_projection(id value, NSString *operation) {
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    NSUInteger schema,mask;
    if (!axs_cachekeeper_installation_detail_number(value[@"schemaVersion"],1,&schema) || schema!=1 ||
        !axs_cachekeeper_installation_detail_number(value[@"differenceMask"],AxsCacheKeeperInstallationIdentityAllFields,&mask) || !mask ||
        ![value[@"comparison"] isKindOfClass:NSString.class]) return nil;
    NSString *comparison=value[@"comparison"];
    BOOL allowed=([operation isEqual:@"openIdentity"] && [comparison isEqual:@"pathToFD"]) ||
        ([operation isEqual:@"recheckIdentity"] && [@[@"referenceToFD",@"fdToPath"] containsObject:comparison]) ||
        ([operation isEqual:@"snapshotIdentity"] && [comparison isEqual:@"snapshotToFD"]);
    if (!allowed) return nil;
    NSMutableDictionary *result=[@{@"schemaVersion":@1,@"comparison":[comparison copy],@"differenceMask":@(mask)} mutableCopy];
    if (value[@"resample"]) {
        NSDictionary *resample=axs_cachekeeper_installation_resample_projection(value[@"resample"]);
        if (![operation isEqual:@"openIdentity"] || !resample) return nil;
        result[@"resample"]=resample;
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
        result[@"identity"]=identity;
    }
    return [result copy];
}
