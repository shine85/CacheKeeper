#pragma once
#import <Foundation/Foundation.h>

// 仅在内存汇总插件已有记录，不发起检测、不访问 APP 容器、不写报告文件。
@interface AxsCacheKeeperDiagnostics : NSObject
@property(nonatomic,readonly) NSArray<NSString *> *bundles;
- (instancetype)initWithFolder:(NSString *)folder;
- (NSDictionary *)reportWithApps:(NSArray<NSDictionary *> *)apps environment:(NSDictionary *)environment;
// 回调在调用线程运行，依次报告 0/总数到总数/总数；调用方负责主线程显示。
- (NSDictionary *)reportWithApps:(NSArray<NSDictionary *> *)apps environment:(NSDictionary *)environment progress:(void (^)(NSUInteger completed,NSUInteger total))progress;
@end
