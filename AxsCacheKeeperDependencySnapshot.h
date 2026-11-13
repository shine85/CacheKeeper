#pragma once
#import <Foundation/Foundation.h>

// 文件或目录集合的分批元数据快照；不跟随依赖内的链接，不读取文件内容。
@interface AxsCacheKeeperDependencySnapshot : NSObject
@property(nonatomic,readonly) BOOL complete;
@property(nonatomic,readonly) BOOL valid;
@property(nonatomic,readonly,copy) NSString *error;
- (instancetype)initWithPath:(NSString *)path;
- (NSUInteger)advance:(NSUInteger)limit;
- (void)beginVerification;
- (BOOL)validateRoot;
- (void)didRemovePath:(NSString *)path;
@end
