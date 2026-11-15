#pragma once
#import <Foundation/Foundation.h>
#include <limits.h>
#include <math.h>

// The only export contract for installation failures. No paths, metadata values or error messages.
// A missing detail is allowed by older callers; a present invalid detail must not be exported.
static inline NSDictionary *axs_cachekeeper_installation_detail_projection(id value) {
    if (![value isKindOfClass:NSDictionary.class] || [value count]!=3 ||
        ![value[@"target"] isKindOfClass:NSString.class] || ![value[@"operation"] isKindOfClass:NSString.class] ||
        ![value[@"errno"] isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value[@"errno"])==CFBooleanGetTypeID()) return nil;
    NSString *target=value[@"target"],*operation=value[@"operation"];
    double number=[value[@"errno"] doubleValue];
    if (!isfinite(number) || number<0 || number>INT_MAX || floor(number)!=number) return nil;
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
    return @{@"target":[target copy],@"operation":[operation copy],@"errno":@((int)number)};
}
