#pragma once
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSUInteger,AxsCacheKeeperScanHostFailure) {
    AxsCacheKeeperScanHostFailureNone,
    AxsCacheKeeperScanHostFailureFirstRegister,
    AxsCacheKeeperScanHostFailureSecondRegister,
    AxsCacheKeeperScanHostFailureSet,
    AxsCacheKeeperScanHostFailurePost
};
void axs_cachekeeper_scan_host_fail(AxsCacheKeeperScanHostFailure failure);
NSUInteger axs_cachekeeper_scan_host_active_tokens(void);
NSUInteger axs_cachekeeper_scan_host_register_calls(void);
NSUInteger axs_cachekeeper_scan_host_cancel_calls(void);
