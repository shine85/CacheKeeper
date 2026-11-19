#pragma once
#import <Foundation/Foundation.h>

// Serial-queue confined. Private provider URLs are never written to disk.
// Only a new start may supersede an epoch. Cancellation applies to the active
// epoch; without any saved observation it may acknowledge cancel-before-start.
// An unknown cancel never overwrites an existing saved observation (also after
// restart): UUIDs have no ordering proof. A new measurement needs a new start.
@interface AxsCacheKeeperCapacityService : NSObject
- (instancetype)initWithFolder:(NSString *)folder
                      provider:(NSDictionary *(^)(NSError **error))provider
                        writer:(BOOL (^)(NSDictionary *record,NSString *path))writer;
- (BOOL)tick;
@end
