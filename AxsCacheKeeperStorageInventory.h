#pragma once
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif
// Read envelopes are the current Diagnostics saved-record reads, never independent sources.
// savedSDKApps contains raw SDK read envelopes with NSDate timestamps, before export aliasing.
// This aggregation reads no files and grants no cleanup. The caller's existing redactor owns
// every displayed path; saved logical bytes never prove current identity or reclaimable bytes.
NSDictionary *axs_cachekeeper_storage_inventory(id registryInventory, NSDictionary *statesRead,
    NSDictionary *directoriesRead, NSDictionary *snapshotsRead, NSArray *savedSDKApps,
    NSString *(^pathRedactor)(NSString *path));
#ifdef __cplusplus
}
#endif
