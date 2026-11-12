#pragma once
#import "AxsCacheKeeperPolicy.h"

static inline BOOL axs_cachekeeper_row_manageable(NSDictionary *row) {
    return ![row[@"readOnly"] boolValue] && ![row[@"manageable"] isEqual:@NO] && axs_cachekeeper_cache_path(row[@"path"]);
}
static inline NSArray<NSDictionary *> *axs_cachekeeper_manageable_rows(NSArray *rows) {
    NSMutableArray *result=[NSMutableArray new];
    for (NSDictionary *row in axs_cachekeeper_parent_rows(rows)) {
        if (axs_cachekeeper_row_manageable(row)) [result addObject:row];
    }
    return axs_cachekeeper_size_ordered_rows(result);
}
static inline NSArray<NSDictionary *> *axs_cachekeeper_readonly_rows(NSArray *rows) {
    NSMutableArray *result=[NSMutableArray new];
    for (NSDictionary *row in axs_cachekeeper_parent_rows(rows))
        if (!axs_cachekeeper_hidden_directory(row[@"path"]) && !axs_cachekeeper_row_manageable(row)) [result addObject:row];
    return axs_cachekeeper_size_ordered_rows(result);
}
static inline NSArray<NSDictionary *> *axs_cachekeeper_unknown_rows(NSArray *rows) {
    NSMutableArray *result=[NSMutableArray new];
    for (NSDictionary *row in axs_cachekeeper_readonly_rows(rows))
        if ([axs_cachekeeper_directory_kind(row[@"path"]) isEqual:@"unknown"]) [result addObject:row];
    return result;
}
static inline NSArray<NSDictionary *> *axs_cachekeeper_known_readonly_rows(NSArray *rows) {
    NSMutableArray *result=[NSMutableArray new];
    for (NSDictionary *row in axs_cachekeeper_readonly_rows(rows))
        if (![axs_cachekeeper_directory_kind(row[@"path"]) isEqual:@"unknown"]) [result addObject:row];
    return result;
}
static inline NSArray<NSString *> *axs_cachekeeper_enableable_paths(NSArray *rows) {
    NSMutableArray *paths=[NSMutableArray new];
    for (NSDictionary *row in axs_cachekeeper_manageable_rows(rows)) [paths addObject:row[@"path"]];
    return axs_cachekeeper_cache_paths(paths);
}
static inline BOOL axs_cachekeeper_row_selected(NSString *path, NSArray *effectivePaths) {
    for (NSString *selected in effectivePaths)
        if (axs_cachekeeper_paths_overlap(path,selected)) return YES;
    return NO;
}
static inline NSArray<NSDictionary *> *axs_cachekeeper_prioritized_rows(NSArray *rows, NSArray *selected, id state) {
    NSArray *manageable=axs_cachekeeper_manageable_rows(rows);
    // 保留配置，但显示和排序只反映实际启用状态。
    NSArray *effective=axs_cachekeeper_effective_paths(selected,state,axs_cachekeeper_enableable_paths(manageable));
    return [manageable sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        BOOL left=axs_cachekeeper_row_selected(a[@"path"],effective),right=axs_cachekeeper_row_selected(b[@"path"],effective);
        if (left!=right) return left ? NSOrderedAscending : NSOrderedDescending;
        unsigned long long l=[a[@"bytes"] unsignedLongLongValue],r=[b[@"bytes"] unsignedLongLongValue];
        if (l!=r) return l>r ? NSOrderedAscending : NSOrderedDescending;
        return [a[@"path"] compare:b[@"path"]];
    }];
}
static inline NSArray<NSDictionary *> *axs_cachekeeper_display_rows(NSArray *rows, NSArray *discovered) {
    NSMutableArray *result=[axs_cachekeeper_parent_rows(rows) mutableCopy];
    NSMutableSet *known=[NSMutableSet new];
    for (NSDictionary *row in result) [known addObject:row[@"path"]];
    for (NSString *path in axs_cachekeeper_cache_paths(discovered)) {
        if (![known containsObject:path]) [result addObject:@{@"path":path,@"manageable":@YES,@"automatic":@YES}];
    }
    return axs_cachekeeper_parent_rows(result);
}

// 只更新当前 APP；自动发现的实时结果由引擎计算，不回写用户选择。
static inline NSString *axs_cachekeeper_save_selection(NSString *folder, NSString *bundle, NSArray *changes, BOOL enable, BOOL oneClick) {
    if (!axs_cachekeeper_bundle_id(bundle) || ![changes isKindOfClass:NSArray.class] || !changes.count) return @"没有可开启的缓存目录。";
    for (id path in changes) if (!axs_cachekeeper_cache_path(path)) return @"选择包含只读或受保护目录，未应用。";
    NSString *directoryFile=[folder stringByAppendingPathComponent:@"directories.plist"];
    NSString *stateFile=[folder stringByAppendingPathComponent:@"appEnabled.plist"];
    NSMutableDictionary *directories=axs_cachekeeper_edit_configuration(directoryFile);
    NSMutableDictionary *states=axs_cachekeeper_edit_configuration(stateFile);
    if (!directories || !states || (directories[bundle] && ![directories[bundle] isKindOfClass:NSArray.class])) return @"原配置不可读或目录记录损坏，已停止保存。";
    NSDictionary *previousDirectories=[directories copy];
    NSMutableArray *paths=[axs_cachekeeper_cache_paths(directories[bundle]) mutableCopy];
    NSMutableDictionary *state=axs_cachekeeper_app_state(states[bundle],enable ? YES : axs_cachekeeper_app_enabled(states[bundle]));
    NSMutableArray *exclusions=[axs_cachekeeper_exclusions(states[bundle]) mutableCopy];
    if (enable) [paths addObjectsFromArray:changes];
    else for (NSString *path in [paths copy]) {
        for (NSString *removed in changes) if ([path isEqual:removed] || [path hasPrefix:[removed stringByAppendingString:@"/"]]) {
            [paths removeObject:path];break;
        }
    }
    if (enable) {
        for (NSString *excluded in [exclusions copy]) for (NSString *added in changes) {
            if (axs_cachekeeper_paths_overlap(excluded,added)) { [exclusions removeObject:excluded];break; }
        }
    } else [exclusions addObjectsFromArray:changes];
    state[@"excludedPaths"]=axs_cachekeeper_parent_paths(exclusions);
    if (oneClick) { state[@"mode"]=@"auto";state[@"urlCache"]=@YES;state[@"autoDiscover"]=@YES; }
    directories[bundle]=axs_cachekeeper_cache_paths(paths);
    if (![directories writeToFile:directoryFile atomically:YES]) return @"目录选择保存失败。";
    states[bundle]=state;
    if (![states writeToFile:stateFile atomically:YES]) {
        if (![previousDirectories writeToFile:directoryFile atomically:YES]) return @"保存失败且目录选择未能恢复，请检查配置目录权限。";
        return @"APP 设置保存失败，已恢复原目录选择。";
    }
    NSDictionary *readDirectories=[NSDictionary dictionaryWithContentsOfFile:directoryFile];
    NSDictionary *readStates=[NSDictionary dictionaryWithContentsOfFile:stateFile];
    if (![readDirectories[bundle] isEqual:directories[bundle]] || ![readStates[bundle] isEqual:state])
        return @"保存后回读不一致，请检查配置访问；未确认设置已应用。";
    return nil;
}
static inline NSString *axs_cachekeeper_update_selection(NSString *folder, NSString *bundle, NSArray *changes, BOOL enable) {
    return axs_cachekeeper_save_selection(folder,bundle,changes,enable,NO);
}
static inline NSString *axs_cachekeeper_one_click(NSString *folder, NSString *bundle, NSArray *rows) {
    return axs_cachekeeper_save_selection(folder,bundle,axs_cachekeeper_enableable_paths(rows),YES,YES);
}
// 日志目录定级（逐 APP、逐目录的用户判定，只写状态文件）：定级要求路径通过
// axs_cachekeeper_log_path_valid；取消定级对已存路径无条件放行。永不由一键开启/自动发现调用。
static inline NSString *axs_cachekeeper_set_log_path(NSString *folder, NSString *bundle, NSString *path, BOOL mark) {
    if (!axs_cachekeeper_bundle_id(bundle) || !axs_cachekeeper_relative_path(path)) return @"目录路径无效，未应用。";
    if (mark && !axs_cachekeeper_log_path_valid(path)) return @"该目录不属于可定级的用途未知目录，未应用。";
    NSString *stateFile=[folder stringByAppendingPathComponent:@"appEnabled.plist"];
    NSMutableDictionary *states=axs_cachekeeper_edit_configuration(stateFile);
    if (!states) return @"原配置不可读或损坏，已停止保存。";
    NSMutableDictionary *state=axs_cachekeeper_app_state(states[bundle],axs_cachekeeper_app_enabled(states[bundle]));
    NSMutableArray *list=[NSMutableArray new];
    if ([states[bundle] isKindOfClass:NSDictionary.class] && [states[bundle][@"logPaths"] isKindOfClass:NSArray.class])
        for (id item in states[bundle][@"logPaths"]) if ([item isKindOfClass:NSString.class]) [list addObject:item];
    [list removeObject:path];
    if (mark) [list addObject:path];
    state[@"logPaths"]=axs_cachekeeper_log_paths(@{@"logPaths":list});
    states[bundle]=state;
    if (![states writeToFile:stateFile atomically:YES]) return @"定级保存失败。";
    NSDictionary *readStates=[NSDictionary dictionaryWithContentsOfFile:stateFile];
    if (![readStates[bundle] isEqual:state]) return @"保存后回读不一致，请检查配置访问；未确认设置已应用。";
    return nil;
}
// 未知目录逐项保留（只写状态文件）：关 = 加入排除清单，退出时不做内容审查；开 = 移出清单，恢复自动审查。
// 保留不走 save_selection（其只接受标准缓存路径），与定级开关同一写入规矩：回读验证。
static inline NSString *axs_cachekeeper_set_excluded_path(NSString *folder, NSString *bundle, NSString *path, BOOL exclude) {
    if (!axs_cachekeeper_bundle_id(bundle) || !axs_cachekeeper_relative_path(path)) return @"目录路径无效，未应用。";
    if (exclude && !axs_cachekeeper_log_path_valid(path)) return @"该目录不属于可保留的用途未知目录，未应用。";
    NSString *stateFile=[folder stringByAppendingPathComponent:@"appEnabled.plist"];
    NSMutableDictionary *states=axs_cachekeeper_edit_configuration(stateFile);
    if (!states) return @"原配置不可读或损坏，已停止保存。";
    NSMutableDictionary *state=axs_cachekeeper_app_state(states[bundle],axs_cachekeeper_app_enabled(states[bundle]));
    NSMutableArray *list=[[axs_cachekeeper_exclusions(states[bundle]) mutableCopy] ?: [NSMutableArray new]];
    [list removeObject:path];
    if (exclude) [list addObject:path];
    state[@"excludedPaths"]=axs_cachekeeper_parent_paths(list);
    states[bundle]=state;
    if (![states writeToFile:stateFile atomically:YES]) return @"保留设置保存失败。";
    NSDictionary *readStates=[NSDictionary dictionaryWithContentsOfFile:stateFile];
    if (![readStates[bundle] isEqual:state]) return @"保存后回读不一致，请检查配置访问；未确认设置已应用。";
    return nil;
}
