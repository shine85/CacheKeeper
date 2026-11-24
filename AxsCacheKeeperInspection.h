#pragma once
#import <Foundation/Foundation.h>
#import "AxsCacheKeeperScanDiagnostics.h"
#include <sys/stat.h>

// 只读档案；识别文件格式不等于证明可以删除。
// searchRoots：孪生扫描的搜索根，每项 @{@"path": 绝对路径, @"label": 显示名}；
// 深度检测发现硬链接文件后，按设备+inode 在这些根中找孪生并记入报告。
@interface AxsCacheKeeperInspection : NSObject
@property(nonatomic,readonly) BOOL complete;
- (instancetype)initWithRoot:(NSString *)root;
- (instancetype)initWithRoot:(NSString *)root searchRoots:(NSArray<NSDictionary *> *)searchRoots;
// 默认孪生预算 100000 项。兼容原 stat 注入；真实身份仍以父 FD 的 fstatat 为准。
- (instancetype)initWithRoot:(NSString *)root searchRoots:(NSArray<NSDictionary *> *)searchRoots
                 searchLimit:(NSUInteger)searchLimit stat:(int (^)(const char *, struct stat *))statBlock;
- (void)advance:(NSUInteger)limit;
// 与 advance 在同一任务线程调用；立即释放主遍历和孪生搜索持有的全部 FD。
- (void)cancel;
- (NSDictionary *)report;
@end

static inline NSDictionary *axs_cachekeeper_recent_scan_entry(id value) {
    if (![value isKindOfClass:NSDictionary.class] || ![value[@"updated"] isKindOfClass:NSDate.class] ||
        ![value[@"rows"] isKindOfClass:NSArray.class]) return nil;
    NSMutableDictionary *entry=[@{@"updated":value[@"updated"],@"rows":value[@"rows"]} mutableCopy];
    if ([value[@"home"] isKindOfClass:NSString.class]) entry[@"home"]=value[@"home"];
    id diagnostics=value[@"scanDiagnostics"],state=value[@"scanDiagnosticsState"];
    if (!diagnostics && !state) entry[@"scanDiagnosticsState"]=@"unknown";
    else if ([state isEqual:@"unknown"] && !diagnostics) entry[@"scanDiagnosticsState"]=@"unknown";
    else if ([state isEqual:@"invalid"]) entry[@"scanDiagnosticsState"]=@"invalid";
    else {
        NSDictionary *projected=axs_cachekeeper_scan_diagnostics_projection(diagnostics);
        if ([state isEqual:@"available"] && projected) {
            entry[@"scanDiagnosticsState"]=@"available";entry[@"scanDiagnostics"]=projected;
        } else entry[@"scanDiagnosticsState"]=@"invalid";
    }
    return entry;
}
static inline NSArray *axs_cachekeeper_recent_scans(NSDictionary *previous) {
    NSMutableArray *recent=[NSMutableArray new];
    if ([previous[@"recentScans"] isKindOfClass:NSArray.class])
        for (id value in previous[@"recentScans"]) {NSDictionary *entry=axs_cachekeeper_recent_scan_entry(value);if(entry) [recent addObject:entry];}
    if ([previous[@"updated"] isKindOfClass:NSDate.class] && [previous[@"rows"] isKindOfClass:NSArray.class]) {
        NSMutableDictionary *current=[@{@"updated":previous[@"updated"],@"rows":previous[@"rows"]} mutableCopy];
        if ([previous[@"home"] isKindOfClass:NSString.class]) current[@"home"]=previous[@"home"];
        if (previous[@"scanDiagnostics"]) {current[@"scanDiagnosticsState"]=@"available";current[@"scanDiagnostics"]=previous[@"scanDiagnostics"];}
        else if ([previous[@"scanDiagnosticsState"] isEqual:@"invalid"]) current[@"scanDiagnosticsState"]=@"invalid";
        NSDictionary *entry=axs_cachekeeper_recent_scan_entry(current);
        // Compare the closed projection so legacy normalization cannot duplicate its current round.
        if (entry && ![recent.lastObject isEqual:entry]) [recent addObject:entry];
    }
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
