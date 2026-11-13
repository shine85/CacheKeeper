#pragma once
#import <Foundation/Foundation.h>

// 仅聚合插件记录；补采复用现有只读检测接口，不直接访问 APP 容器。
@interface AxsCacheKeeperDiagnostics : NSObject
@property(nonatomic,readonly) NSArray<NSString *> *bundles;
@property(nonatomic,readonly) BOOL running;
@property(nonatomic,readonly) NSString *status;
- (instancetype)initWithFolder:(NSString *)folder;
- (NSString *)startAt:(NSTimeInterval)now;
- (void)advanceAt:(NSTimeInterval)now;
- (void)stop;
- (NSDictionary *)reportWithApps:(NSArray<NSDictionary *> *)apps environment:(NSDictionary *)environment;
@end
