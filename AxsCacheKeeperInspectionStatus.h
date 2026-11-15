#pragma once
#import <Foundation/Foundation.h>
#include <limits.h>
#include <math.h>

// Only the primary root-open failure is currently instrumented. Never infer other stages from text.
static inline NSDictionary *axs_cachekeeper_inspection_read_failure_projection(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    if ([value count]==1 && [value[@"state"] isKindOfClass:NSString.class] && [value[@"state"] isEqual:@"notRecorded"])
        return @{@"state":@"notRecorded"};
    if ([value count]!=3 || ![value[@"stage"] isKindOfClass:NSString.class] || ![value[@"stage"] isEqual:@"openRoot"] ||
        ![value[@"errorDomain"] isKindOfClass:NSString.class] || ![value[@"errorDomain"] isEqual:@"posix"] ||
        ![value[@"errorCode"] isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value[@"errorCode"])==CFBooleanGetTypeID()) return nil;
    double number=[value[@"errorCode"] doubleValue];
    if (!isfinite(number) || number<=0 || number>INT_MAX || floor(number)!=number) return nil;
    return @{@"stage":@"openRoot",@"errorDomain":@"posix",@"errorCode":@((int)number)};
}
