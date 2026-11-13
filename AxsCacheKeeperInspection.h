#pragma once
#import <Foundation/Foundation.h>
#include <sys/stat.h>

// 只读档案；识别文件格式不等于证明可以删除。
// searchRoots：孪生扫描的搜索根，每项 @{@"path": 绝对路径, @"label": 显示名}；
// 深度检测发现硬链接文件后，按设备+inode 在这些根中找孪生并记入报告。
@interface AxsCacheKeeperInspection : NSObject
@property(nonatomic,readonly) BOOL complete;
- (instancetype)initWithRoot:(NSString *)root;
- (instancetype)initWithRoot:(NSString *)root searchRoots:(NSArray<NSDictionary *> *)searchRoots;
// 默认 100000 项、真实 lstat；可注入预算/读取以确定性验证搜索边界和读取失败。
- (instancetype)initWithRoot:(NSString *)root searchRoots:(NSArray<NSDictionary *> *)searchRoots
                 searchLimit:(NSUInteger)searchLimit stat:(int (^)(const char *, struct stat *))statBlock;
- (void)advance:(NSUInteger)limit;
- (NSDictionary *)report;
@end

static inline NSArray *axs_cachekeeper_recent_scans(NSDictionary *previous) {
    NSMutableArray *recent=[NSMutableArray new];
    if ([previous[@"recentScans"] isKindOfClass:NSArray.class]) [recent addObjectsFromArray:previous[@"recentScans"]];
    if ([previous[@"updated"] isKindOfClass:NSDate.class] && [previous[@"rows"] isKindOfClass:NSArray.class])
        [recent addObject:@{@"updated":previous[@"updated"],@"home":previous[@"home"] ?: @"",@"rows":previous[@"rows"]}];
    while (recent.count>4) [recent removeObjectAtIndex:0];
    return recent;
}
static inline NSString *axs_cachekeeper_growth_evidence(NSString *path, NSArray *history, NSDictionary *current) {
    NSMutableArray *sizes=[NSMutableArray new];
    for (NSDictionary *scan in [history arrayByAddingObject:current ?: @{}]) {
        if (![scan[@"home"] isEqual:current[@"home"]]) { [sizes removeAllObjects];continue; }
        NSDictionary *found=nil;
        for (NSDictionary *row in scan[@"rows"]) if ([row[@"path"] isEqual:path]) { found=row;break; }
        if (![found[@"complete"] boolValue]) { [sizes removeAllObjects];continue; }
        [sizes addObject:found[@"bytes"] ?: @0];
    }
    if (sizes.count<3) return @"趋势：需至少 3 次完整检测；体积变化不等于插件清理量";
    BOOL growing=YES,same=YES;
    for (NSUInteger i=1;i<sizes.count;i++) { growing &= [sizes[i] unsignedLongLongValue]>[sizes[i-1] unsignedLongLongValue];same &= [sizes[i] isEqual:sizes[i-1]]; }
    return [NSString stringWithFormat:@"最近 %lu 次完整检测%@；仅为占用证据，不能判定可删或证明文件未变化",(unsigned long)sizes.count,growing ? @"占用持续增长" : same ? @"总字节数相同" : @"占用有波动"];
}
