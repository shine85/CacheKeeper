#pragma once
#import <Foundation/Foundation.h>
@class AxsCacheKeeperImageCollectionSession;

@interface AxsCacheKeeperCollectionSession : NSObject
- (instancetype)initWithPath:(NSString *)path error:(NSError **)error;
+ (instancetype)createNewSessionInDirectory:(NSString *)directory error:(NSError **)error;
+ (NSArray<NSDictionary *> *)resumableSessionsInDirectory:(NSString *)directory error:(NSError **)error;
+ (instancetype)openSessionAtPath:(NSString *)path error:(NSError **)error;
@property(nonatomic,readonly,copy) NSString *sessionID;
- (AxsCacheKeeperImageCollectionSession *)imageCollectionSession:(NSError **)error;
- (BOOL)beginPhase:(NSString *)phase error:(NSError **)error;
- (BOOL)beginCapacityWithEpoch:(NSString *)epoch error:(NSError **)error;
- (BOOL)finishCapacityWithSnapshot:(NSDictionary *)snapshot error:(NSError **)error;
- (NSDictionary *)savedCapacitySnapshot:(NSError **)error;
- (BOOL)prepareRetryForPhase:(NSString *)phase error:(NSError **)error;
- (BOOL)finishPhase:(NSString *)phase result:(NSDictionary *)result error:(NSError **)error;
- (BOOL)blockCapability:(NSString *)bundle capability:(NSString *)capability error:(NSError **)error;
- (NSData *)saveReport:(NSDictionary *)report diagnosticsResult:(NSDictionary *)result error:(NSError **)error;
- (NSData *)savedReportData:(NSError **)error;
- (NSDictionary *)reportProjection;
@end
