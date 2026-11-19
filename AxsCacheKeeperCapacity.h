#pragma once
#import <Foundation/Foundation.h>
#include <sys/stat.h>

// One process-local, serial-queue-confined read-only measurement. Owns no queue,
// persistence or cleanup authorization. The caller supplies a system container URL.
// result is a closed JSON/plist snapshot:
// schemaVersion=1; state=running/complete/cancelled/readError/identityChanged/
// entryLimit/depthLimit/timeLimit/inodeLimit/invalidMetadata/nodeLimit;
// logicalBytes counts regular-file paths, allocatedBytes counts first-observed
// dev/ino st_blocks*512 for ALL types, entries includes the root;
// uniqueInodes, duplicateInodes; budgets entryLimit=2000000, depthLimit=64,
// inodeLimit=262144, nodeLimit=4096; deletionAuthorization=notGranted,
// physicalUniqueBytes=notMeasured, reclaimableBytes=notMeasured.
// nodes contain only id,parent,category,logicalBytes,allocatedBytes,entries;
// id=1,parent=0 is the root, category=unknown; directory nodes to depth 3.
// Fixed categories Documents/Library/tmp at depth 1, Caches/Application Support
// only under Library at depth 2. All other names remain unknown and private.
// Allocation contributions belong to the first path; summing ancestor nodes
// would double-count, and allocation is neither extent uniqueness nor reclaimable.
@interface AxsCacheKeeperCapacityRoot : NSObject
- (instancetype)initWithRoot:(NSURL *)root;
// Bind the provider's observed identity to the root's actual opened FD, not a
// second pathname check. A mismatch returns identityChanged with no observations
// and closes the cursor before initialization returns. The old initializer is unbound.
- (instancetype)initWithRoot:(NSURL *)root expectedDevice:(dev_t)device expectedInode:(ino_t)inode;
- (void)advanceEntries:(NSUInteger)entries seconds:(NSTimeInterval)seconds;
- (void)stopWithState:(NSString *)state;
@property(nonatomic,readonly) NSDictionary *result;
@property(nonatomic,readonly) NSString *state;
#if defined(AXS_CACHEKEEPER_CAPACITY_TESTING)
// Reduced budgets exercise production failure branches on small real fixtures.
- (instancetype)initWithRoot:(NSURL *)root entryLimit:(NSUInteger)entries depthLimit:(NSUInteger)depth
                 inodeLimit:(NSUInteger)inodes nodeLimit:(NSUInteger)nodes;
#endif
@end
