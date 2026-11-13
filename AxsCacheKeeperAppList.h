#pragma once
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

typedef NSDictionary *(^AxsCacheKeeperAppListProvider)(BOOL refreshApplications);
typedef NSArray<NSDictionary *> *(^AxsCacheKeeperApplicationsProvider)(NSError **error);
typedef void (^AxsCacheKeeperAppListCompletion)(NSDictionary *snapshot);

// Main-thread coordinator. Providers run serially off the main thread; completion runs on main.
// Repeated refreshes merge into one pending request without invalidating the current result.
@interface AxsCacheKeeperAppList : NSObject
- (instancetype)initWithProvider:(AxsCacheKeeperAppListProvider)provider completion:(AxsCacheKeeperAppListCompletion)completion;
// Snapshot keys: apps, states, directories, favorites, history, batch, statuses, errors.
// A failed source retains its last readable value and reports an entry in errors.
- (instancetype)initWithFolder:(NSString *)folder applicationsProvider:(AxsCacheKeeperApplicationsProvider)provider completion:(AxsCacheKeeperAppListCompletion)completion;
- (void)requestRefreshApplications:(BOOL)refreshApplications;
// Invalidates in-flight delivery and pending work; the next request can start a new generation.
- (void)invalidate;
// Read and validate the actual file before a write. Missing file: nil/no error; invalid or unreadable: nil/error.
+ (id)axs_cachekeeper_read_source_at_path:(NSString *)path name:(NSString *)name error:(NSError **)error;
+ (NSArray<NSDictionary *> *)sectionsForApps:(NSArray<NSDictionary *> *)apps states:(NSDictionary *)states favorites:(NSSet<NSString *> *)favorites tab:(NSInteger)tab query:(NSString *)query;
@end
