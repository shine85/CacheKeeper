#pragma once
#import <Foundation/Foundation.h>

// Display-only contracts. Directory coverage never inherits app discovery coverage;
// cleanup byte counters never substitute for a directory size snapshot.
static inline NSString *axs_cachekeeper_presentation_round_state(NSDictionary *receipt) { return @""; }
static inline NSString *axs_cachekeeper_presentation_snapshot(NSDictionary *row, id updated) { return @""; }
static inline NSString *axs_cachekeeper_presentation_receipt(NSDictionary *receipt, NSDictionary *appReport) { return @""; }
static inline NSString *axs_cachekeeper_presentation_inspection(NSDictionary *report) { return @""; }
