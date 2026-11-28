#pragma once
#import <Foundation/Foundation.h>
@class AxsCacheKeeperCollectionSession;
// UI return location only; execution state remains in the referenced collection session.
@interface AxsCacheKeeperCollectionReturn : NSObject
- (instancetype)initWithDirectory:(NSString *)directory;
- (NSDictionary *)read:(NSError **)error;
- (NSDictionary *)selectSession:(AxsCacheKeeperCollectionSession *)session page:(NSString *)page error:(NSError **)error;
- (NSDictionary *)update:(NSDictionary *)expected page:(NSString *)page error:(NSError **)error;
- (BOOL)clear:(NSDictionary *)expected error:(NSError **)error;
- (BOOL)isReleasedIntent:(NSDictionary *)intent;
- (AxsCacheKeeperCollectionSession *)openSession:(NSDictionary *)intent error:(NSError **)error;
@end
