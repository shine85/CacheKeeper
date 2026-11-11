#pragma once
#import <Foundation/Foundation.h>

@interface AxsCacheKeeperSweep : NSObject
@property(nonatomic, readonly, copy) NSString *root;
@property(nonatomic, readonly) BOOL fullClear;
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
- (instancetype)initWithRoot:(NSString *)root;
- (instancetype)initWithRoot:(NSString *)root clock:(NSTimeInterval (^)(void))clock;
- (instancetype)initWithRoot:(NSString *)root fullClear:(BOOL)fullClear;
- (instancetype)initWithRoot:(NSString *)root clock:(NSTimeInterval (^)(void))clock fullClear:(BOOL)fullClear;
- (void)advance:(NSUInteger)limit shouldContinue:(BOOL (^)(void))shouldContinue;
@end
