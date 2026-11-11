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
    // 目录开关记住用户选择；总开关关闭不丢掉排列中的已选状态。
    NSArray *effective=axs_cachekeeper_effective_paths(selected,axs_cachekeeper_app_state(state,YES),axs_cachekeeper_enableable_paths(manageable));
    return [manageable sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        BOOL left=axs_cachekeeper_row_selected(a[@"path"],effective),right=axs_cachekeeper_row_selected(b[@"path"],effective);
        if (left!=right) return left ? NSOrderedAscending : NSOrderedDescending;
        unsigned long long l=[a[@"bytes"] unsignedLongLongValue],r=[b[@"bytes"] unsignedLongLongValue];
        if (l!=r) return l>r ? NSOrderedAscending : NSOrderedDescending;
        return [a[@"path"] compare:b[@"path"]];
    }];
}
static inline BOOL axs_cachekeeper_row_manageable_tiered(NSDictionary *row, NSSet *extra) {
    if (axs_cachekeeper_row_manageable(row)) return YES;
    return ![row[@"readOnly"] boolValue] && [extra containsObject:row[@"path"]] && axs_cachekeeper_probe_eligible(row[@"path"]);
}
static inline NSArray<NSDictionary *> *axs_cachekeeper_manageable_rows_tiered(NSArray *rows, NSSet *extra) {
    NSMutableArray *result=[NSMutableArray new];
    for (NSDictionary *row in axs_cachekeeper_parent_rows(rows)) {
        if (axs_cachekeeper_row_manageable_tiered(row,extra)) [result addObject:row];
    }
    return axs_cachekeeper_size_ordered_rows(result);
}
static inline NSArray<NSDictionary *> *axs_cachekeeper_readonly_rows_tiered(NSArray *rows, NSSet *extra) {
    NSMutableArray *result=[NSMutableArray new];
    for (NSDictionary *row in axs_cachekeeper_parent_rows(rows))
        if (!axs_cachekeeper_hidden_directory(row[@"path"]) && !axs_cachekeeper_row_manageable_tiered(row,extra)) [result addObject:row];
    return axs_cachekeeper_size_ordered_rows(result);
}
static inline NSArray<NSDictionary *> *axs_cachekeeper_unknown_rows_tiered(NSArray *rows, NSSet *extra) {
    NSMutableArray *result=[NSMutableArray new];
    for (NSDictionary *row in axs_cachekeeper_readonly_rows_tiered(rows,extra))
        if ([axs_cachekeeper_directory_kind(row[@"path"]) isEqual:@"unknown"]) [result addObject:row];
    return result;
}
static inline NSArray<NSDictionary *> *axs_cachekeeper_known_readonly_rows_tiered(NSArray *rows, NSSet *extra) {
    NSMutableArray *result=[NSMutableArray new];
    for (NSDictionary *row in axs_cachekeeper_readonly_rows_tiered(rows,extra))
        if (![axs_cachekeeper_directory_kind(row[@"path"]) isEqual:@"unknown"]) [result addObject:row];
    return result;
}
static inline NSArray<NSDictionary *> *axs_cachekeeper_prioritized_rows_tiered(NSArray *rows, NSArray *selected, id state, NSSet *extra) {
    NSArray *manageable=axs_cachekeeper_manageable_rows_tiered(rows,extra);
    // 自动发现只认白名单根：enableable_paths 内部按白名单口径再过滤，证据通道目录不会被当成自动发现结果。
    NSArray *effective=axs_cachekeeper_effective_paths_tiered(selected,axs_cachekeeper_app_state(state,YES),axs_cachekeeper_enableable_paths(rows),extra);
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
static inline NSString *axs_cachekeeper_save_selection_extra(NSString *folder, NSString *bundle, NSArray *changes, BOOL enable, BOOL oneClick, NSSet *extra) {
    if (!axs_cachekeeper_bundle_id(bundle) || ![changes isKindOfClass:NSArray.class] || !changes.count) return @"没有可开启的缓存目录。";
    // 开启时才需要资格校验（白名单或证据通道）；关闭任何已选项永远允许，避免目录被重新定级后关不掉。
    if (enable) for (id path in changes) if (!axs_cachekeeper_cache_path(path) && ![extra containsObject:path]) return @"选择包含只读或受保护目录，未应用。";
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
    state[@"excludedPaths"]=axs_cachekeeper_cache_paths(exclusions);
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
static inline NSSet *axs_cachekeeper_save_extra(NSString *folder, NSString *bundle) {
    NSDictionary *snapshots=[NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:@"snapshots.plist"]];
    NSDictionary *states=[NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:@"appEnabled.plist"]];
    NSArray *rows=[snapshots[bundle][@"rows"] isKindOfClass:NSArray.class] ? snapshots[bundle][@"rows"] : @[];
    return axs_cachekeeper_extra_selectable(rows, states[bundle]);
}
static inline NSString *axs_cachekeeper_save_selection(NSString *folder, NSString *bundle, NSArray *changes, BOOL enable, BOOL oneClick) {
    return axs_cachekeeper_save_selection_extra(folder,bundle,changes,enable,oneClick,axs_cachekeeper_save_extra(folder,bundle));
}
// 用户判定：先落判定记录，再走普通保存通道选中目录；保存失败时回滚判定，避免半成品状态。
static inline NSString *axs_cachekeeper_save_judged(NSString *folder, NSString *bundle, NSString *path, BOOL judged) {
    if (!axs_cachekeeper_bundle_id(bundle) || !axs_cachekeeper_probe_eligible(path)) return @"该目录不在可判定范围内。";
    if (judged) {
        // 红线不只靠界面：已检出数据文件的目录，保存层同样拒绝判定开启。
        NSDictionary *snapshots=[NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:@"snapshots.plist"]];
        if ([snapshots[bundle][@"rows"] isKindOfClass:NSArray.class]) for (NSDictionary *row in snapshots[bundle][@"rows"])
            if ([row[@"path"] isEqual:path] && [axs_cachekeeper_evidence_grade(row[@"evidence"]) isEqual:@"data"])
                return @"该目录已检出数据文件，不能判定开启。";
    }
    NSString *stateFile=[folder stringByAppendingPathComponent:@"appEnabled.plist"];
    NSMutableDictionary *states=axs_cachekeeper_edit_configuration(stateFile);
    if (!states) return @"原配置不可读或损坏，已停止保存。";
    NSMutableDictionary *state=axs_cachekeeper_app_state(states[bundle], axs_cachekeeper_app_enabled(states[bundle]));
    NSMutableArray *list=[axs_cachekeeper_judged_paths(states[bundle]) mutableCopy];
    if (judged) { if (![list containsObject:path]) [list addObject:path]; }
    else [list removeObject:path];
    state[@"judgedPaths"]=list;
    states[bundle]=state;
    if (![states writeToFile:stateFile atomically:YES]) return @"用户判定保存失败。";
    NSString *error=axs_cachekeeper_save_selection_extra(folder,bundle,@[path],judged,NO,axs_cachekeeper_extra_selectable(@[],state));
    if (error && judged) {
        NSMutableDictionary *rollback=axs_cachekeeper_app_state(state, axs_cachekeeper_app_enabled(state));
        NSMutableArray *back=[axs_cachekeeper_judged_paths(state) mutableCopy];
        [back removeObject:path];
        rollback[@"judgedPaths"]=back;
        NSMutableDictionary *all=axs_cachekeeper_edit_configuration(stateFile);
        if (all) { all[bundle]=rollback; [all writeToFile:stateFile atomically:YES]; }
    }
    return error;
}

static inline NSString *axs_cachekeeper_update_selection(NSString *folder, NSString *bundle, NSArray *changes, BOOL enable) {
    return axs_cachekeeper_save_selection(folder,bundle,changes,enable,NO);
}
static inline NSString *axs_cachekeeper_one_click(NSString *folder, NSString *bundle, NSArray *rows) {
    return axs_cachekeeper_save_selection(folder,bundle,axs_cachekeeper_enableable_paths(rows),YES,YES);
}

