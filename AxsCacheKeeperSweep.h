#pragma once
#import <Foundation/Foundation.h>

@interface AxsCacheKeeperSweep : NSObject
@property(nonatomic, readonly, copy) NSString *root;
@property(nonatomic, readonly) BOOL fullClear;
@property(nonatomic, readonly) BOOL logMode;
@property(nonatomic, readonly) BOOL purgeMode;
@property(nonatomic, readonly) BOOL purgeBlocked;
@property(nonatomic, readonly) BOOL purgeMixed;
@property(nonatomic, readonly, copy) NSString *purgeEvidence;
@property(nonatomic, readonly) BOOL complete;
@property(nonatomic, readonly) BOOL cancelled;
@property(nonatomic, readonly) NSUInteger removed;
@property(nonatomic, readonly) NSUInteger failed;
@property(nonatomic, readonly) NSUInteger protectedCount;
@property(nonatomic, readonly) NSUInteger recentCount;
@property(nonatomic, readonly) BOOL checking;
@property(nonatomic, readonly) NSUInteger inspected;
@property(nonatomic, readonly) NSUInteger changedCount;
@property(nonatomic, readonly) unsigned long long bytes;
@property(nonatomic, readonly, copy) NSString *error;
@property(nonatomic, readonly, copy) NSArray<NSDictionary *> *failureDetails;
- (instancetype)initWithRoot:(NSString *)root;
- (instancetype)initWithRoot:(NSString *)root clock:(NSTimeInterval (^)(void))clock;
- (instancetype)initWithRoot:(NSString *)root clock:(NSTimeInterval (^)(void))clock unlinkFile:(int (^)(int, const char *))unlinkFile;
- (instancetype)initWithRoot:(NSString *)root fullClear:(BOOL)fullClear;
- (instancetype)initWithRoot:(NSString *)root clock:(NSTimeInterval (^)(void))clock fullClear:(BOOL)fullClear;
- (instancetype)initWithRoot:(NSString *)root fullClear:(BOOL)fullClear logMode:(BOOL)logMode;
- (instancetype)initWithRoot:(NSString *)root clock:(NSTimeInterval (^)(void))clock fullClear:(BOOL)fullClear logMode:(BOOL)logMode;
- (instancetype)initWithRoot:(NSString *)root fullClear:(BOOL)fullClear logMode:(BOOL)logMode purgeMode:(BOOL)purgeMode;
- (instancetype)initWithRoot:(NSString *)root clock:(NSTimeInterval (^)(void))clock fullClear:(BOOL)fullClear logMode:(BOOL)logMode purgeMode:(BOOL)purgeMode;
- (void)advance:(NSUInteger)limit shouldContinue:(BOOL (^)(void))shouldContinue;
@end
