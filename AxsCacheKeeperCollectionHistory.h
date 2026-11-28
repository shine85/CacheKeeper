#pragma once
#import <Foundation/Foundation.h>

// Only local session records are managed; exported copies and shared requests are never removed.
@interface AxsCacheKeeperCollectionHistory : NSObject
- (instancetype)initWithDirectory:(NSString *)directory;
// Rows contain file, sessionID, createdAt, state, deletable, reason and an opaque revision.
- (NSArray<NSDictionary *> *)records:(NSError **)error;
// Use the exact row shown before confirmation. Failure may return state=partial with NSError.
- (NSDictionary *)deleteRecord:(NSDictionary *)expected confirmed:(BOOL)confirmed error:(NSError **)error;
@end
