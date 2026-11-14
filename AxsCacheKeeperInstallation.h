#pragma once
#import <Foundation/Foundation.h>

// Call on a background queue, using only the system application's bundleURL.
// Snapshots (including fingerprint and private identity fields) stay in memory; never export them.
// Missing version/build remain absent with installationState=versionUnknown; invalid files fail closed.
NSDictionary *axs_cachekeeper_installation_snapshot(NSURL *bundleURL, NSString *bundleIdentifier,
                                                   NSString *systemShortVersion, NSError **error);
// Bounded metadata-only verification; does not parse Info.plist or read executable contents.
BOOL axs_cachekeeper_validate_installation_snapshot(NSDictionary *snapshot, NSURL *currentBundleURL,
                                                     NSString *currentSystemShortVersion, NSError **error);
// Shared background provider. Caller owns a private serial-queue cache of installation snapshots
// and display entries; never pass this cache to UI/export. Unchanged packages need metadata only.
// The returned array contains display entries only, without paths, fingerprints or private snapshots.
NSArray *axs_cachekeeper_installed_applications(NSMutableDictionary *cache, NSError **error);
