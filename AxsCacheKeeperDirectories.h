#pragma once
#import <Foundation/Foundation.h>

NSArray<NSString *> *axs_cachekeeper_scan_directories(NSURL *home, NSError **error);
NSDictionary<NSString *,NSURL *> *axs_cachekeeper_valid_group_homes(NSDictionary *groups);
NSArray<NSDictionary *> *axs_cachekeeper_scan_targets(NSURL *home, NSDictionary *groups, NSError **error);
NSArray<NSString *> *axs_cachekeeper_discover_cache_roots(NSURL *home, NSError **error);
