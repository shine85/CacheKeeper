#pragma once
#import "AxsCacheKeeperPolicy.h"

// Metadata observation only; neither APFS extent ownership nor reclaimable bytes.
// uniqueFiles counts identities; duplicateFiles/untrackedFiles count encountered entries.
static inline BOOL axs_cachekeeper_allocation_count(id value) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()) return NO;
    double number=[value doubleValue];
    return isfinite(number) && number>=0 && trunc(number)==number && number<=9007199254740991.0;
}
static inline NSDictionary *axs_cachekeeper_allocation_projection(id value) {
    if (![value isKindOfClass:NSDictionary.class] || [value count]!=8 ||
        !axs_cachekeeper_allocation_count(value[@"schemaVersion"]) || [value[@"schemaVersion"] unsignedIntegerValue]!=1 ||
        ![value[@"scope"] isKindOfClass:NSString.class] || ![value[@"state"] isKindOfClass:NSString.class] ||
        ![value[@"scope"] isEqual:@"taskUniqueRegularFileInodeFirstObservation"] ||
        ![@[@"complete",@"partial",@"inodeLimit",@"invalidMetadata"] containsObject:value[@"state"]]) return nil;
    for (NSString *key in @[@"allocatedBytes",@"uniqueFiles",@"duplicateFiles",@"untrackedFiles",@"inodeBudget"])
        if (!axs_cachekeeper_allocation_count(value[key])) return nil;
    NSUInteger budget=[value[@"inodeBudget"] unsignedIntegerValue];
    if (!budget || budget>65536 || [value[@"uniqueFiles"] unsignedIntegerValue]>budget ||
        ([value[@"state"] isEqual:@"complete"] && [value[@"untrackedFiles"] unsignedIntegerValue])) return nil;
    return [value copy];
}
