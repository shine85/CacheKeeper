#pragma once
#import <Foundation/Foundation.h>

// 仅在内存汇总插件已有记录，不发起检测、不访问 APP 容器、不写报告文件。
@interface AxsCacheKeeperDiagnostics : NSObject
// 初始化时的有效配置 ID 快照；每次报告独立读取当前配置并合入传入的安装快照。
@property(nonatomic,readonly) NSArray<NSString *> *bundles;
- (instancetype)initWithFolder:(NSString *)folder;
// installedMetadataState: available / notInSnapshot（只表示传入快照缺条目）/ unavailable。
// nil、非数组或含无效身份条目的安装来源不能用于缺席判断；有效条目仍可提供元数据。
- (NSDictionary *)reportWithApps:(NSArray<NSDictionary *> *)apps environment:(NSDictionary *)environment;
// 回调在调用线程运行，依次报告 0/总数到总数/总数；调用方负责主线程显示。
- (NSDictionary *)reportWithApps:(NSArray<NSDictionary *> *)apps environment:(NSDictionary *)environment progress:(void (^)(NSUInteger completed,NSUInteger total))progress;
@end
