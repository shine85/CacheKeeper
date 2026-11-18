#pragma once
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif
// Internal snapshot only: data contains third-party preferences and must never be exported.
// Call once per report using the caller's canonical Roothide-resolved path.
NSDictionary *axs_cachekeeper_injection_conditions_read(NSString *path);
// Fixed, privacy-preserving projection for CacheKeeper.dylib only. No runtime inference.
NSDictionary *axs_cachekeeper_injection_conditions_projection(NSDictionary *snapshot, NSString *bundle);
NSString *axs_cachekeeper_injection_conditions_summary(NSDictionary *projection);
#ifdef __cplusplus
}
#endif
