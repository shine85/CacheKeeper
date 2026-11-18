#pragma once
#import <Foundation/Foundation.h>

// Confined to one serial queue. Cursors are intentionally process-local.
@interface AxsCacheKeeperScanCursor : NSObject
- (instancetype)initWithRoot:(NSURL *)root entryLimit:(NSUInteger)limit depthLimit:(NSUInteger)depth;
#if defined(AXS_CACHEKEEPER_SCAN_TESTING)
- (instancetype)initWithRoot:(NSURL *)root entryLimit:(NSUInteger)limit depthLimit:(NSUInteger)depth allocationLimit:(NSUInteger)allocationLimit;
#endif
- (void)advanceEntries:(NSUInteger)entries seconds:(NSTimeInterval)seconds;
- (void)stopWithState:(NSString *)state;
@property(nonatomic,readonly) NSDictionary *result;
@property(nonatomic,readonly) NSString *state;
@property(nonatomic,readonly) NSUInteger openDirectoryCount;
@end

// Resolver returns current home (NSURL), groups (identifier -> NSURL), and optional homeWasRejected.
// writer is injectable solely to test real persistence failures; nil uses atomic plist writes.
@interface AxsCacheKeeperScanService : NSObject
@property(nonatomic,copy) void (^acceptedRequest)(NSString *bundle, BOOL diagnostic);
#if defined(AXS_CACHEKEEPER_SCAN_TESTING)
@property(nonatomic,copy) NSTimeInterval (^axs_cachekeeper_clock)(void);
@property(nonatomic,readonly) NSUInteger axs_cachekeeper_historyDecodeCount;
// Called after actual history IO to inject request changes at the publication boundary.
@property(nonatomic,copy) void (^axs_cachekeeper_didReadHistory)(void);
#endif
- (instancetype)initWithFolder:(NSString *)folder
                      resolver:(NSDictionary *(^)(NSString *bundle))resolver
                        writer:(BOOL (^)(NSDictionary *record, NSString *path))writer;
- (BOOL)tick;
@end

#if defined(AXS_CACHEKEEPER_SCAN_TESTING)
#include <sys/stat.h>
// Feed numeric boundary samples into the same production metadata accumulator.
NSDictionary *axs_cachekeeper_scan_allocation_test_stats(const struct stat *samples,NSUInteger count,NSUInteger limit);
#endif
