#pragma once
#import "AxsCacheKeeperPolicy.h"

static inline NSArray<NSString *> *axs_cachekeeper_enableable_paths(NSArray *rows) {
    NSMutableArray *paths=[NSMutableArray new];
    for (NSDictionary *row in axs_cachekeeper_parent_rows(rows)) {
        if ([row[@"readOnly"] boolValue] || [row[@"manageable"] isEqual:@NO]) continue;
        if (axs_cachekeeper_cache_path(row[@"path"])) [paths addObject:row[@"path"]];
    }
    return axs_cachekeeper_cache_paths(paths);
}

// 单项与一键开启共用保存入口。只更新当前 APP，模式与网络选项保持用户原选择。
static inline NSString *axs_cachekeeper_update_selection(NSString *folder, NSString *bundle, NSArray *changes, BOOL enable) {
    if (!axs_cachekeeper_bundle_id(bundle) || ![changes isKindOfClass:NSArray.class] || !changes.count) return @"没有可开启的缓存目录。";
    for (id path in changes) if (!axs_cachekeeper_cache_path(path)) return @"选择包含只读或受保护目录，未应用。";
    NSString *directoryFile=[folder stringByAppendingPathComponent:@"directories.plist"];
    NSString *stateFile=[folder stringByAppendingPathComponent:@"appEnabled.plist"];
    NSMutableDictionary *directories=axs_cachekeeper_edit_configuration(directoryFile);
    NSMutableDictionary *states=axs_cachekeeper_edit_configuration(stateFile);
    if (!directories || !states || (directories[bundle] && ![directories[bundle] isKindOfClass:NSArray.class])) return @"原配置不可读或目录记录损坏，已停止保存。";
    NSDictionary *previousDirectories=[directories copy];
    NSMutableArray *paths=[axs_cachekeeper_cache_paths(directories[bundle]) mutableCopy];
    if (enable) [paths addObjectsFromArray:changes];
    else for (NSString *path in [paths copy]) {
        for (NSString *removed in changes) if ([path isEqual:removed] || [path hasPrefix:[removed stringByAppendingString:@"/"]]) {
            [paths removeObject:path];break;
        }
    }
    directories[bundle]=axs_cachekeeper_cache_paths(paths);
    if (![directories writeToFile:directoryFile atomically:YES]) return @"目录选择保存失败。";
    if (enable) {
        states[bundle]=axs_cachekeeper_app_state(states[bundle],YES);
        if (![states writeToFile:stateFile atomically:YES]) {
            if (![previousDirectories writeToFile:directoryFile atomically:YES]) return @"开启失败且目录选择未能恢复，请检查配置目录权限。";
            return @"总开关保存失败，已恢复原目录选择。";
        }
    }
    return nil;
}
