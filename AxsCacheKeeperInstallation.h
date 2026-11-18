#pragma once
#import <Foundation/Foundation.h>
#import "AxsCacheKeeperInstallationDetail.h"

#ifdef __cplusplus
extern "C" {
#endif

// Call on a background queue, using only the system application's bundleURL.
// Snapshots (including fingerprint and private identity fields) stay in memory; never export them.
// Path and FD each bind all eleven fields; only seven non-time fields must agree across views.
// Legacy single-view snapshots fail closed and must be recollected.
// Missing version/build remain absent with installationState=versionUnknown; invalid files fail closed.
// Failures retain codes 1..7 and add userInfo.detail through the fixed, non-sensitive detail contract.
typedef NS_ENUM(NSUInteger, AxsCacheKeeperInstallationContext) {
    AxsCacheKeeperInstallationContextUnspecified,
    AxsCacheKeeperInstallationContextHostMainBundle,
    AxsCacheKeeperInstallationContextRegistryBundle,
    AxsCacheKeeperInstallationContextTestInjected,
};
NSDictionary *axs_cachekeeper_installation_snapshot(NSURL *bundleURL, NSString *bundleIdentifier,
                                                   NSString *systemShortVersion, NSError **error);
NSDictionary *axs_cachekeeper_installation_snapshot_with_context(NSURL *bundleURL, NSString *bundleIdentifier,
    NSString *systemShortVersion, AxsCacheKeeperInstallationContext context, NSError **error);
// Bounded metadata-only verification; does not parse Info.plist or read executable contents.
BOOL axs_cachekeeper_validate_installation_snapshot(NSDictionary *snapshot, NSURL *currentBundleURL,
                                                     NSString *currentSystemShortVersion, NSError **error);
BOOL axs_cachekeeper_validate_installation_snapshot_with_context(NSDictionary *snapshot, NSURL *currentBundleURL,
    NSString *currentSystemShortVersion, AxsCacheKeeperInstallationContext context, NSError **error);
// Shared background provider. Caller owns a private serial-queue cache of installation snapshots
// and display entries; never pass this cache to UI/export. Unchanged packages need metadata only.
// The returned array contains display entries only, without paths, fingerprints or private snapshots.
NSArray *axs_cachekeeper_installed_applications(NSMutableDictionary *cache, NSError **error);
// Same registry read, before display filtering. Counts describe registered URLs, not access or deletion.
NSArray *axs_cachekeeper_installed_applications_with_container_coverage(NSMutableDictionary *cache,
                                                                       NSDictionary **coverage, NSError **error);
// Same bounded role sampling, including non-display registrations. No additional filesystem reads.
// Resource tokens express exact URL-string equality within this inventory, never physical identity.
NSArray *axs_cachekeeper_installed_applications_with_registry_inventory(NSMutableDictionary *cache,
    NSDictionary **coverage, NSDictionary **registryInventory, NSError **error);
// Closed public projection; unknown keys are dropped. Invalid/nil sources remain explicit.
NSDictionary *axs_cachekeeper_registry_inventory_projection(id registryInventory);
// Fixed, count-only schema; invalid values return an explicit invalid state. Never exports raw identities.
NSDictionary *axs_cachekeeper_container_coverage_projection(id coverage);

#ifdef __cplusplus
}
#endif
