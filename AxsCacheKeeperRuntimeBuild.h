#pragma once
#import "AxsCacheKeeperRuntimeInfo.h"
#import "AxsCacheKeeperOperationInfo.h"

#if AXS_CACHEKEEPER_IMAGE_TESTING && !defined(AXS_CACHEKEEPER_PACKAGE_VERSION)
// The actual integration target is never included in the packaged tweak.
#define AXS_CACHEKEEPER_PACKAGE_VERSION "0.0.0-0.0"
#endif
#ifndef AXS_CACHEKEEPER_PACKAGE_VERSION
#error Compile the runtime with the package version read from control.
#endif

static inline NSDictionary *axs_cachekeeper_runtime_info(void) {
    static NSDictionary *info;
    static dispatch_once_t once;
    dispatch_once(&once,^{
        info=@{@"schemaVersion":@1,@"packageVersion":@AXS_CACHEKEEPER_PACKAGE_VERSION,
            @"firstObserved":axs_cachekeeper_operation_process()[@"firstObserved"]};
    });
    return info;
}
