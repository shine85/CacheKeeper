#pragma once
#import <Foundation/Foundation.h>
#include <math.h>
#include <stdint.h>

static const NSUInteger AxsCacheKeeperScanErrorLimit=16;

static inline BOOL axs_cachekeeper_scan_integer(id value, uint64_t maximum) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()) return NO;
    double number=[value doubleValue];
    return isfinite(number) && number>=0 && number==trunc(number) && number<=maximum;
}

// One schema serves persisted-record validation and the privacy boundary of exported reports.
static inline NSDictionary *axs_cachekeeper_scan_diagnostics_projection(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *allowed=@{
        @"containerState":@[@"available",@"noHome",@"invalidHome",@"rootMissing",@"unreadable",@"notObserved"],
        @"scope":@[@"home",@"group"],
        @"stage":@[@"containerResolve",@"rootStat",@"rootOpen",@"rootRecheck",@"listChildren",@"entryStat",@"enumerate"],
        @"reason":@[@"noHome",@"invalidHome",@"rootMissing",@"permissionDenied",@"readFailure",@"enumeratorUnavailable",@"identityChanged"],
        @"errorDomain":@[@"none",@"posix",@"cocoa",@"other"]};
    if (![allowed[@"containerState"] containsObject:value[@"containerState"] ?: NSNull.null]) return nil;
    NSMutableDictionary *out=[@{@"containerState":value[@"containerState"]} mutableCopy];
    for (NSString *key in @[@"discoveryComplete",@"measurementComplete",@"timeBudgetExceeded",@"entryLimitExceeded",@"errorsTruncated"]) {
        id flag=value[key];
        if (![flag isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)flag)!=CFBooleanGetTypeID()) return nil;
        out[key]=flag;
    }
    for (NSString *key in @[@"entriesVisited",@"enumerationErrors",@"statErrors",@"omittedErrorCount"]) {
        if (!axs_cachekeeper_scan_integer(value[key],UINT32_MAX)) return nil;
        out[key]=value[key];
    }
    id errors=value[@"errors"];
    if (![errors isKindOfClass:NSArray.class] || [errors count]>AxsCacheKeeperScanErrorLimit) return nil;
    NSMutableArray *projected=[NSMutableArray new];
    for (id error in errors) {
        if (![error isKindOfClass:NSDictionary.class]) return nil;
        NSMutableDictionary *item=[NSMutableDictionary new];
        for (NSString *key in @[@"scope",@"stage",@"reason",@"errorDomain"]) {
            if (![allowed[key] containsObject:error[key] ?: NSNull.null]) return nil;
            item[key]=error[key];
        }
        NSString *domain=item[@"errorDomain"];
        uint64_t maximum=[domain isEqual:@"posix"] ? 255 : [domain isEqual:@"cocoa"] ? INT32_MAX : 0;
        if (!axs_cachekeeper_scan_integer(error[@"errorCode"],maximum) ||
            !axs_cachekeeper_scan_integer(error[@"count"],UINT32_MAX) || ![error[@"count"] unsignedLongLongValue]) return nil;
        item[@"errorCode"]=error[@"errorCode"];item[@"count"]=error[@"count"];
        [projected addObject:item];
    }
    out[@"errors"]=projected;
    BOOL measurement=[out[@"measurementComplete"] boolValue];
    if ((measurement && (![out[@"discoveryComplete"] boolValue] || [out[@"timeBudgetExceeded"] boolValue] ||
            [out[@"entryLimitExceeded"] boolValue] || [out[@"enumerationErrors"] unsignedIntValue] ||
            [out[@"statErrors"] unsignedIntValue] || projected.count)) ||
        (![out[@"errorsTruncated"] boolValue] && [out[@"omittedErrorCount"] unsignedIntValue])) return nil;
    return out;
}

static inline NSMutableDictionary *axs_cachekeeper_scan_diagnostics_new(void) {
    return [@{@"containerState":@"available",@"discoveryComplete":@YES,@"measurementComplete":@YES,
        @"timeBudgetExceeded":@NO,@"entryLimitExceeded":@NO,@"entriesVisited":@0,@"enumerationErrors":@0,
        @"statErrors":@0,@"errorsTruncated":@NO,@"omittedErrorCount":@0,@"errors":[NSMutableArray new]} mutableCopy];
}

static inline void axs_cachekeeper_scan_count(NSMutableDictionary *diagnostics, NSString *key, uint64_t count) {
    uint64_t total=[diagnostics[key] unsignedLongLongValue]+count;
    diagnostics[key]=@(MIN(total,(uint64_t)UINT32_MAX));
    if (total>UINT32_MAX) {diagnostics[@"errorsTruncated"]=@YES;diagnostics[@"measurementComplete"]=@NO;}
}

static inline void axs_cachekeeper_scan_error(NSMutableDictionary *diagnostics, NSString *scope, NSString *stage,
                                              NSString *reason, NSString *domain, NSInteger code, uint64_t count) {
    NSMutableArray *errors=[diagnostics[@"errors"] mutableCopy];
    for (NSUInteger index=0;index<errors.count;index++) {
        NSDictionary *known=errors[index];
        if ([known[@"scope"] isEqual:scope] && [known[@"stage"] isEqual:stage] && [known[@"reason"] isEqual:reason] &&
            [known[@"errorDomain"] isEqual:domain] && [known[@"errorCode"] integerValue]==code) {
            NSMutableDictionary *next=[known mutableCopy];
            next[@"count"]=@(MIN([known[@"count"] unsignedLongLongValue]+count,(uint64_t)UINT32_MAX));
            errors[index]=next;diagnostics[@"errors"]=errors;return;
        }
    }
    if (errors.count<AxsCacheKeeperScanErrorLimit)
        [errors addObject:@{@"scope":scope,@"stage":stage,@"reason":reason,@"errorDomain":domain,@"errorCode":@(code),@"count":@(count)}];
    else {diagnostics[@"errorsTruncated"]=@YES;axs_cachekeeper_scan_count(diagnostics,@"omittedErrorCount",count);}
    diagnostics[@"errors"]=errors;
}

static inline NSDictionary *axs_cachekeeper_scan_scope(NSDictionary *diagnostics, NSString *scope) {
    NSMutableDictionary *out=[diagnostics mutableCopy];NSMutableArray *errors=[NSMutableArray new];
    for (NSDictionary *error in diagnostics[@"errors"]) {
        NSMutableDictionary *item=[error mutableCopy];item[@"scope"]=scope;[errors addObject:item];
    }
    out[@"errors"]=errors;return out;
}

static inline void axs_cachekeeper_scan_merge(NSMutableDictionary *target, NSDictionary *source) {
    for (NSString *key in @[@"discoveryComplete",@"measurementComplete"])
        target[key]=[target[key] boolValue] && [source[key] boolValue] ? @YES : @NO;
    for (NSString *key in @[@"timeBudgetExceeded",@"entryLimitExceeded",@"errorsTruncated"])
        target[key]=[target[key] boolValue] || [source[key] boolValue] ? @YES : @NO;
    for (NSString *key in @[@"entriesVisited",@"enumerationErrors",@"statErrors",@"omittedErrorCount"])
        axs_cachekeeper_scan_count(target,key,[source[key] unsignedLongLongValue]);
    for (NSDictionary *error in source[@"errors"])
        axs_cachekeeper_scan_error(target,error[@"scope"],error[@"stage"],error[@"reason"],error[@"errorDomain"],
            [error[@"errorCode"] integerValue],[error[@"count"] unsignedLongLongValue]);
}
