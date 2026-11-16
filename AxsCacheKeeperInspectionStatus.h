#pragma once
#import <Foundation/Foundation.h>
#include <limits.h>
#include <math.h>

static inline BOOL axs_cachekeeper_inspection_count(id value) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()) return NO;
    double number=[value doubleValue];
    return isfinite(number) && number>=0 && number<=9007199254740991.0 && floor(number)==number;
}

// Finite operation/domain pairs only. Identity changes, limits and short reads
// have no errno; legacy notRecorded is retained without guessing from text.
static inline NSDictionary *axs_cachekeeper_inspection_read_failure_projection(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    if ([value count]==1 && [value[@"state"] isKindOfClass:NSString.class] && [value[@"state"] isEqual:@"notRecorded"])
        return @{@"state":@"notRecorded"};
    if ([value count]!=3 || ![value[@"stage"] isKindOfClass:NSString.class] ||
        ![value[@"errorDomain"] isKindOfClass:NSString.class] ||
        ![value[@"errorCode"] isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value[@"errorCode"])==CFBooleanGetTypeID()) return nil;
    double number=[value[@"errorCode"] doubleValue];
    if (!isfinite(number) || number<0 || number>INT_MAX || floor(number)!=number) return nil;
    NSString *stage=value[@"stage"],*domain=value[@"errorDomain"];
    BOOL valid=NO;
    if ([domain isEqual:@"posix"] && number>0)
        valid=[@[@"openRoot",@"rootStat",@"rootRecheck",@"enumerate",@"entryName",@"entryStat",@"openDirectory",
            @"ancestorRecheck",@"openFile",@"fileStat",@"fileRecheck",@"readHeader"] containsObject:stage];
    else if (number==0) {
        if ([domain isEqual:@"identity"]) valid=[@[@"rootRecheck",@"ancestorRecheck",@"fileRecheck"] containsObject:stage];
        else if ([domain isEqual:@"read"]) valid=[stage isEqual:@"shortRead"];
        else if ([domain isEqual:@"limit"]) valid=[stage isEqual:@"depthLimit"];
    }
    return valid ? @{@"stage":stage,@"errorDomain":domain,@"errorCode":@((int)number)} : nil;
}
