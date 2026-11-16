#import "AxsCacheKeeperOperationInfo.h"
#include <stdio.h>

// Logos uses Objective-C++; the shared implementation remains Objective-C.
int main(void) { @autoreleasepool {
    NSDictionary *process=axs_cachekeeper_operation_process();
    if (![process[@"processID"] isKindOfClass:NSString.class] ||
        ![process[@"firstObserved"] isKindOfClass:NSNumber.class] ||
        axs_cachekeeper_operation_history_validate(@{@"schemaVersion":@1},@"webkit") ||
        axs_cachekeeper_operation_history_projection(@{@"schemaVersion":@1},[NSMutableDictionary new])) {
        fprintf(stderr,"FAIL: operation linkage must preserve shared process and invalid-history rejection\n");
        return 1;
    }
    puts("PASS: Objective-C++ operation caller links Objective-C exports and rejects malformed history");
    return 0;
}}
