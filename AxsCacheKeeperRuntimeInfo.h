#pragma once
#import <Foundation/Foundation.h>
#include <math.h>

// Identifies the code that emitted this receipt, independently of the installed preference bundle.
static inline NSDictionary *axs_cachekeeper_runtime_info_projection(id value) {
    if (![value isKindOfClass:NSDictionary.class] || [value count]!=3 ||
        ![value[@"schemaVersion"] isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value[@"schemaVersion"])==CFBooleanGetTypeID() ||
        [value[@"schemaVersion"] doubleValue]!=1 ||
        ![value[@"packageVersion"] isKindOfClass:NSString.class] ||
        [value[@"packageVersion"] length]>48 ||
        ![value[@"firstObserved"] isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value[@"firstObserved"])==CFBooleanGetTypeID()) return nil;
    NSString *version=value[@"packageVersion"];
    NSRange match=[version rangeOfString:@"\\A[0-9]+\\.[0-9]+\\.[0-9]+(?:-[0-9]+\\.[0-9]+)?\\z" options:NSRegularExpressionSearch];
    double observed=[value[@"firstObserved"] doubleValue];
    if (match.location==NSNotFound || match.length!=version.length || !isfinite(observed) || observed<=0 || observed>9007199254740991.0) return nil;
    return [value copy];
}
