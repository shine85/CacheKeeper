#pragma once
#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <string.h>

static NSString *const AxsCacheKeeperPreferencesChanged = @"dev.local.cachekeeper.preferences-changed";
static const NSTimeInterval AxsCacheKeeperMinimumFileAge = 60;
static inline void axs_cachekeeper_notify_preferences(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge CFStringRef)AxsCacheKeeperPreferencesChanged, NULL, NULL, YES);
}
static inline NSMutableDictionary *axs_cachekeeper_edit_configuration(NSString *path) {
    NSDictionary *value=[NSDictionary dictionaryWithContentsOfFile:path];
    if (!value && [NSFileManager.defaultManager fileExistsAtPath:path]) return nil;
    return [value mutableCopy] ?: [NSMutableDictionary new];
}

static inline BOOL axs_cachekeeper_relative_path(NSString *path) {
    if (![path isKindOfClass:NSString.class] || !path.length || [path hasPrefix:@"/"]) return NO;
    for (NSString *part in [path componentsSeparatedByString:@"/"]) {
        if (!part.length || [part isEqual:@"."] || [part isEqual:@".."] || [part containsString:@"\\"]) return NO;
    }
    return YES;
}
static inline BOOL axs_cachekeeper_protected_path(NSString *path) {
    if (!axs_cachekeeper_relative_path(path)) return YES;
    for (NSString *part in [path.lowercaseString componentsSeparatedByString:@"/"]) {
        for (NSString *word in @[@"documents", @"preferences", @"webkit", @"cookie", @"database", @"sqlite",
            @"realm", @"keychain", @"credential", @"login", @"account", @"auth", @"session", @"token",
            @"downloads", @"offline", @"inbox"]) {
            if ([part containsString:word]) return YES;
        }
        if ([part isEqual:@"db"] || [part hasSuffix:@".db"] || [part containsString:@".db-"] ||
            [part hasSuffix:@".plist"] || [part hasSuffix:@".json"] || [part hasSuffix:@".key"] ||
            [part hasSuffix:@".pem"] || [part hasSuffix:@".p12"]) return YES;
    }
    return NO;
}
static inline BOOL axs_cachekeeper_data_marker(NSString *name) {
    NSString *n=name.lowercaseString;
    if ([n hasSuffix:@".db"] || [n containsString:@".db-"] || [n containsString:@"sqlite"] ||
        [n hasSuffix:@".realm"] || [n hasSuffix:@".ldb"] || [n hasSuffix:@".sst"] ||
        [n isEqual:@"current"] || [n hasPrefix:@"manifest-"]) return YES;
    for (NSString *word in @[@"cookie",@"keychain",@"credential",@"login",@"account",@"auth",@"session",@"token"])
        if ([n containsString:word]) return YES;
    NSString *stem=n.stringByDeletingPathExtension;
    return [n.pathExtension isEqual:@"log"] && stem.length &&
        [stem rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location==NSNotFound;
}
static inline NSArray<NSString *> *axs_cachekeeper_cache_roots(void) {
    return @[@"Library/Caches", @"tmp", @"Library/Logs", @"Caches", @"Cache", @"cache", @".cache"];
}
// 扫描可展示所有一级数据目录；允许删除的根只来自这里，不能由目录名字含 cache 推断。
static inline BOOL axs_cachekeeper_cache_path(NSString *path) {
    if (axs_cachekeeper_protected_path(path)) return NO;
    for (NSString *root in axs_cachekeeper_cache_roots()) {
        if ([path isEqual:root] || [path hasPrefix:[root stringByAppendingString:@"/"]]) return YES;
    }
    return NO;
}
static inline NSString *axs_cachekeeper_inner_path(NSString *path) {
    if (!axs_cachekeeper_relative_path(path)) return nil;
    if (![path hasPrefix:@"Group/"]) return path;
    NSArray *parts=[path componentsSeparatedByString:@"/"];
    return parts.count>=3 ? [[parts subarrayWithRange:NSMakeRange(2,parts.count-2)] componentsJoinedByString:@"/"] : nil;
}
static inline BOOL axs_cachekeeper_hidden_directory(NSString *path) {
    NSString *inner=axs_cachekeeper_inner_path(path);
    if (!inner) return YES;
    // 按明确持久化/敏感用途隐藏，不能将“白名单外”都推断为必需数据。
    for (NSString *root in @[@"Documents",@"Inbox",@"Downloads",@"Library/Preferences",@"Library/Cookies",@"Library/WebKit",@"Library/Keychains"]) {
        if ([inner caseInsensitiveCompare:root]==NSOrderedSame || [inner.lowercaseString hasPrefix:[root.lowercaseString stringByAppendingString:@"/"]]) return YES;
    }
    return NO;
}
static inline NSString *axs_cachekeeper_directory_kind(NSString *path) {
    if (axs_cachekeeper_hidden_directory(path)) return @"protected";
    if ([path hasPrefix:@"Group/"]) return @"shared";
    if (axs_cachekeeper_cache_path(path)) return @"cache";
    NSString *inner=axs_cachekeeper_inner_path(path);
    for (NSString *root in @[@"Library/Application Support",@"Library/HTTPStorages",@"Library/SplashBoard",@"Library/Saved Application State"]) {
        if ([inner isEqual:root] || [inner hasPrefix:[root stringByAppendingString:@"/"]]) return @"mixed";
    }
    return @"unknown";
}
static inline NSString *axs_cachekeeper_directory_description(NSString *path) {
    if ([path hasPrefix:@"Group/"]) return @"App Group 共享数据：可能被其他 APP 或扩展使用；仅统计，不锁不删";
    NSDictionary *descriptions=@{
        @"tmp":@"临时工作文件、导入导出与下载中转；仅识别出的媒体缓存可清理",
        @"Library/Caches":@"可重建缓存；普通媒体可清理，数据库与未知内容保留",
        @"Library/Logs":@"日志与诊断；日志、数据库 WAL 和未知内容保留",
        @"Library/Application Support":@"混合用途：业务数据、数据库、离线资源或缓存；未逐项验证可删性",
        @"Library/HTTPStorages":@"混合用途：网络持久化数据与会话状态；未验证可删性",
        @"Library/WebKit":@"网页缓存、网站数据库与登录态；仅查看",
        @"Library/Cookies":@"Cookie 与登录会话；仅查看",
        @"Library/Preferences":@"APP 设置与偏好；仅查看",
        @"Library/SplashBoard":@"启动与切换画面快照；仅查看",
        @"Library/Saved Application State":@"界面恢复与运行状态；仅查看",
        @"Documents":@"用户文稿、聊天附件和离线文件；仅查看",
        @"Downloads":@"用户下载与离线文件；仅查看",
        @"Inbox":@"导入或共享接收的用户文件；仅查看"
    };
    if (descriptions[path]) return descriptions[path];
    return axs_cachekeeper_cache_path(path) ? @"缓存目录；仅清理可识别的普通媒体，其他内容保留" : @"用途未确认：尚无证据证明是缓存或必需数据；不自动处理";
}
static inline BOOL axs_cachekeeper_ordinary_cache_file(NSString *relative) {
    return !axs_cachekeeper_protected_path(relative);
}
static inline BOOL axs_cachekeeper_media_signature(const unsigned char *data, size_t length) {
    // 扩展名不能排除 LevelDB WAL 或私有状态文件，只放行可识别的媒体缓存。
    if (length >= 8 && !memcmp(data, "\x89PNG\r\n\x1a\n", 8)) return YES;
    if (length >= 3 && data[0]==0xff && data[1]==0xd8 && data[2]==0xff) return YES;
    if (length >= 6 && (!memcmp(data,"GIF87a",6) || !memcmp(data,"GIF89a",6))) return YES;
    if (length >= 12 && !memcmp(data,"RIFF",4) && (!memcmp(data+8,"WEBP",4) || !memcmp(data+8,"WAVE",4))) return YES;
    if (length >= 12 && !memcmp(data+4,"ftyp",4)) return YES;
    if (length >= 4 && (!memcmp(data,"OggS",4) || !memcmp(data,"fLaC",4))) return YES;
    if (length >= 3 && !memcmp(data,"ID3",3)) return YES;
    return NO;
}
static inline BOOL axs_cachekeeper_old_enough(struct stat info, NSTimeInterval now) {
    NSTimeInterval born = info.st_birthtimespec.tv_sec + info.st_birthtimespec.tv_nsec / 1e9;
    NSTimeInterval modified = info.st_mtimespec.tv_sec + info.st_mtimespec.tv_nsec / 1e9;
    NSTimeInterval changed = info.st_ctimespec.tv_sec + info.st_ctimespec.tv_nsec / 1e9;
    return born > 0 && modified > 0 && changed > 0 && MAX(born, MAX(modified, changed)) <= now - AxsCacheKeeperMinimumFileAge;
}
static inline BOOL axs_cachekeeper_bundle_id(NSString *bundle) {
    if (![bundle isKindOfClass:NSString.class] || !bundle.length) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"];
    return [bundle rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound && ![bundle isEqual:@"."] && ![bundle isEqual:@".."];
}
static inline NSArray<NSString *> *axs_cachekeeper_parent_paths(NSArray *paths) {
    NSMutableSet *unique = [NSMutableSet new];
    if ([paths isKindOfClass:NSArray.class]) for (id path in paths) if (axs_cachekeeper_relative_path(path)) [unique addObject:path];
    NSMutableArray *result = [NSMutableArray new];
    for (NSString *path in [unique.allObjects sortedArrayUsingSelector:@selector(compare:)]) {
        BOOL covered = NO;
        for (NSString *parent in result) if ([path hasPrefix:[parent stringByAppendingString:@"/"]]) { covered = YES; break; }
        if (!covered) [result addObject:path];
    }
    return result;
}
static inline NSArray<NSString *> *axs_cachekeeper_cache_paths(NSArray *paths) {
    NSMutableArray *safe = [NSMutableArray new];
    if ([paths isKindOfClass:NSArray.class]) for (id path in paths) if (axs_cachekeeper_cache_path(path)) [safe addObject:path];
    return axs_cachekeeper_parent_paths(safe);
}
static inline NSArray<NSDictionary *> *axs_cachekeeper_parent_rows(NSArray *rows) {
    NSMutableDictionary *byPath = [NSMutableDictionary new];
    if ([rows isKindOfClass:NSArray.class]) for (id row in rows) {
        if ([row isKindOfClass:NSDictionary.class] && axs_cachekeeper_relative_path(row[@"path"])) byPath[row[@"path"]] = row;
    }
    NSMutableArray *result = [NSMutableArray new];
    for (NSString *path in axs_cachekeeper_parent_paths(byPath.allKeys)) [result addObject:byPath[path]];
    return result;
}
static inline NSArray<NSDictionary *> *axs_cachekeeper_size_ordered_rows(NSArray *rows) {
    return [axs_cachekeeper_parent_rows(rows) sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        unsigned long long left=[a[@"bytes"] unsignedLongLongValue], right=[b[@"bytes"] unsignedLongLongValue];
        if (left!=right) return left>right ? NSOrderedAscending : NSOrderedDescending;
        return [a[@"path"] compare:b[@"path"]];
    }];
}
static inline NSDictionary *axs_cachekeeper_application_entry(NSString *bundle, NSString *name, NSString *type, NSURL *url) {
    if (!axs_cachekeeper_bundle_id(bundle)) return nil;
    BOOL appURL=[url isKindOfClass:NSURL.class] && [url.pathExtension.lowercaseString isEqual:@"app"];
    if (!appURL && ![type isEqual:@"User"] && ![type isEqual:@"System"]) return nil;
    return @{@"id":bundle,@"name":[name isKindOfClass:NSString.class] && name.length ? name : bundle};
}
static inline BOOL axs_cachekeeper_app_enabled(id state) {
    if (!state) return NO;
    if ([state isKindOfClass:NSNumber.class]) return [state boolValue];
    return [state isKindOfClass:NSDictionary.class] && [state[@"enabled"] isKindOfClass:NSNumber.class] && [state[@"enabled"] boolValue];
}
static inline NSString *axs_cachekeeper_mode(id state) {
    if ([state isKindOfClass:NSDictionary.class]) {
        if ([@[@"auto", @"prevent", @"clean"] containsObject:state[@"mode"]]) return state[@"mode"];
        // 迁移本轮之前的布尔限写选项，不另写第二个配置文件。
        if ([state[@"restrict"] isKindOfClass:NSNumber.class] && ![state[@"restrict"] boolValue]) return @"clean";
    }
    return @"auto";
}
static inline BOOL axs_cachekeeper_wants_restriction(id state) { return ![axs_cachekeeper_mode(state) isEqual:@"clean"]; }
static inline BOOL axs_cachekeeper_wants_cleanup(id state) { return ![axs_cachekeeper_mode(state) isEqual:@"prevent"]; }
static inline BOOL axs_cachekeeper_url_cache_enabled(id state) {
    if ([state isKindOfClass:NSDictionary.class] && state[@"urlCache"] != nil)
        return [state[@"urlCache"] isKindOfClass:NSNumber.class] && [state[@"urlCache"] boolValue];
    // 兼容既有显式开启的记录；全新 APP 仍默认关闭网络选项。
    return axs_cachekeeper_app_enabled(state) && axs_cachekeeper_wants_restriction(state);
}
static inline BOOL axs_cachekeeper_should_prevent(id state) {
    return axs_cachekeeper_app_enabled(state) && axs_cachekeeper_wants_restriction(state) && axs_cachekeeper_url_cache_enabled(state);
}
static inline BOOL axs_cachekeeper_auto_discover(id state) {
    return [state isKindOfClass:NSDictionary.class] && [state[@"autoDiscover"] isKindOfClass:NSNumber.class] && [state[@"autoDiscover"] boolValue];
}
// 只有主容器内的未知/混合目录走证据通道；共享、受保护与白名单目录不抽检、不隔离、不接受用户判定。
static inline BOOL axs_cachekeeper_probe_eligible(NSString *path) {
    if (!axs_cachekeeper_relative_path(path) || [path hasPrefix:@"Group/"]) return NO;
    if (axs_cachekeeper_protected_path(path) || axs_cachekeeper_cache_path(path)) return NO;
    NSString *kind = axs_cachekeeper_directory_kind(path);
    return [kind isEqual:@"unknown"] || [kind isEqual:@"mixed"];
}
static inline NSArray<NSString *> *axs_cachekeeper_valid_exclusions(NSArray *paths) {
    // 排除名单除白名单外还须保留证据通道目录，否则对定级/判定目录的关闭会在状态回写时丢失。
    NSMutableArray *result = [NSMutableArray new];
    if ([paths isKindOfClass:NSArray.class]) for (id path in paths)
        if ([path isKindOfClass:NSString.class] && (axs_cachekeeper_cache_path(path) || axs_cachekeeper_probe_eligible(path))) [result addObject:path];
    return axs_cachekeeper_parent_paths(result);
}
static inline NSArray<NSString *> *axs_cachekeeper_exclusions(id state) {
    return [state isKindOfClass:NSDictionary.class] ? axs_cachekeeper_valid_exclusions(state[@"excludedPaths"]) : @[];
}
static inline BOOL axs_cachekeeper_paths_overlap(NSString *left, NSString *right) {
    return [left isEqual:right] || [left hasPrefix:[right stringByAppendingString:@"/"]] ||
        [right hasPrefix:[left stringByAppendingString:@"/"]];
}
static inline NSArray<NSString *> *axs_cachekeeper_effective_paths(NSArray *selected, id state, NSArray *discovered) {
    if (!axs_cachekeeper_app_enabled(state)) return @[];
    NSMutableArray *paths=[axs_cachekeeper_cache_paths(selected) mutableCopy];
    if (axs_cachekeeper_auto_discover(state) && [discovered isKindOfClass:NSArray.class]) {
        for (id path in discovered) if ([axs_cachekeeper_cache_roots() containsObject:path]) [paths addObject:path];
    }
    // 不能通过加入父目录绕过子目录的手动排除。
    for (NSString *path in [paths copy]) for (NSString *excluded in axs_cachekeeper_exclusions(state)) {
        if (axs_cachekeeper_paths_overlap(path,excluded)) { [paths removeObject:path];break; }
    }
    return axs_cachekeeper_cache_paths(paths);
}
static inline NSArray<NSString *> *axs_cachekeeper_judged_paths(id state) {
    NSMutableArray *result = [NSMutableArray new];
    if ([state isKindOfClass:NSDictionary.class] && [state[@"judgedPaths"] isKindOfClass:NSArray.class])
        for (id path in state[@"judgedPaths"]) if (axs_cachekeeper_probe_eligible(path)) [result addObject:path];
    return result;
}
static inline NSMutableDictionary *axs_cachekeeper_app_state(id previous, BOOL enabled) {
    return [@{@"enabled":@(enabled), @"mode":axs_cachekeeper_mode(previous), @"urlCache":@(axs_cachekeeper_url_cache_enabled(previous)),
        @"autoDiscover":@(axs_cachekeeper_auto_discover(previous)), @"excludedPaths":axs_cachekeeper_exclusions(previous),
        @"judgedPaths":axs_cachekeeper_judged_paths(previous)} mutableCopy];
}
static inline NSArray *axs_cachekeeper_activation_paths(id previous) {
    return axs_cachekeeper_cache_paths(previous);
}
static inline NSArray<NSString *> *axs_cachekeeper_selected_paths(NSDictionary *directories, NSDictionary *states, NSString *bundle) {
    if (!axs_cachekeeper_bundle_id(bundle) || ![directories isKindOfClass:NSDictionary.class]) return @[];
    if (states && ![states isKindOfClass:NSDictionary.class]) return @[];
    if (!axs_cachekeeper_app_enabled(states[bundle])) return @[];
    return axs_cachekeeper_effective_paths(directories[bundle],states[bundle],@[]);
}
static inline BOOL axs_cachekeeper_can_clean(NSDictionary *directories, NSDictionary *states, NSString *bundle) {
    return axs_cachekeeper_bundle_id(bundle) && [states isKindOfClass:NSDictionary.class] &&
        axs_cachekeeper_app_enabled(states[bundle]) && axs_cachekeeper_wants_cleanup(states[bundle]) &&
        (axs_cachekeeper_selected_paths(directories,states,bundle).count > 0 || axs_cachekeeper_auto_discover(states[bundle]));
}
static inline NSString *axs_cachekeeper_summary(NSDictionary *scan, NSDictionary *report) {
    NSMutableArray *parts = [NSMutableArray new];
    if ([scan[@"rows"] isKindOfClass:NSArray.class]) [parts addObject:[NSString stringWithFormat:@"检测到 %lu 个目录（大小为检测快照）", (unsigned long)[scan[@"rows"] count]]];
    if ([report isKindOfClass:NSDictionary.class]) {
        NSString *message = report[@"message"];
        if ([message isKindOfClass:NSString.class] && message.length) [parts addObject:message];
        [parts addObject:[NSString stringWithFormat:@"累计清理 %lu 个 · %.2f MB", (unsigned long)[report[@"removed"] unsignedIntegerValue], [report[@"bytes"] doubleValue] / 1048576.0]];
        if ([report[@"failed"] unsignedIntegerValue]) [parts addObject:[NSString stringWithFormat:@"本轮失败 %@ 项", report[@"failed"]]];
        if (report[@"updated"]) [parts addObject:[NSString stringWithFormat:@"最近检查 %@", report[@"updated"]]];
    }
    return parts.count ? [parts componentsJoinedByString:@"\n"] : @"尚未检测；检测后开启 APP 缓存控制";
}

// 证据分级：抽检结论只来自文件计数，不凭目录名推断。data=检出数据标记或数据库头；
// cachelike=全量核查且全部文件均为可识别媒体、无数据标记；其余情况不下结论。
static inline NSString *axs_cachekeeper_evidence_grade(NSDictionary *evidence) {
    if (![evidence isKindOfClass:NSDictionary.class]) return @"";
    if ([evidence[@"data"] unsignedIntegerValue] > 0) return @"data";
    NSUInteger files = [evidence[@"files"] unsignedIntegerValue];
    NSUInteger media = [evidence[@"media"] unsignedIntegerValue];
    NSUInteger other = [evidence[@"other"] unsignedIntegerValue];
    NSUInteger unchecked = [evidence[@"unchecked"] unsignedIntegerValue];
    if ([evidence[@"complete"] boolValue] && files > 0 && media == files && other == 0 && unchecked == 0) return @"cachelike";
    return @"";
}
static inline NSSet<NSString *> *axs_cachekeeper_cachelike_paths(NSArray *rows) {
    NSMutableSet *result = [NSMutableSet new];
    if ([rows isKindOfClass:NSArray.class]) for (id row in rows) {
        if (![row isKindOfClass:NSDictionary.class]) continue;
        NSString *path = row[@"path"];
        if (axs_cachekeeper_probe_eligible(path) && [axs_cachekeeper_evidence_grade(row[@"evidence"]) isEqual:@"cachelike"])
            [result addObject:path];
    }
    return result;
}
// 证据通道可开启集合：抽检定级为缓存特征的目录 + 用户看过深度档案后明确判定的目录。
static inline NSSet<NSString *> *axs_cachekeeper_extra_selectable(NSArray *rows, id state) {
    NSMutableSet *result = [axs_cachekeeper_cachelike_paths(rows) mutableCopy];
    [result addObjectsFromArray:axs_cachekeeper_judged_paths(state)];
    return result;
}
static inline NSArray<NSString *> *axs_cachekeeper_effective_paths_tiered(NSArray *selected, id state, NSArray *discovered, NSSet *extra) {
    NSMutableArray *paths = [axs_cachekeeper_effective_paths(selected, state, discovered) mutableCopy];
    if (!axs_cachekeeper_app_enabled(state) || ![selected isKindOfClass:NSArray.class]) return axs_cachekeeper_parent_paths(paths);
    NSArray *excluded = axs_cachekeeper_exclusions(state);
    for (id path in selected) {
        if (![path isKindOfClass:NSString.class] || ![extra containsObject:path]) continue;
        BOOL blocked = NO;
        for (NSString *ex in excluded) if (axs_cachekeeper_paths_overlap(path, ex)) { blocked = YES; break; }
        if (!blocked) [paths addObject:path];
    }
    return axs_cachekeeper_parent_paths(paths);
}
static inline NSArray<NSString *> *axs_cachekeeper_selected_paths_tiered(NSDictionary *directories, NSDictionary *states, NSString *bundle, NSArray *rows) {
    if (!axs_cachekeeper_bundle_id(bundle) || ![directories isKindOfClass:NSDictionary.class]) return @[];
    if (states && ![states isKindOfClass:NSDictionary.class]) return @[];
    if (!axs_cachekeeper_app_enabled(states[bundle])) return @[];
    return axs_cachekeeper_effective_paths_tiered(directories[bundle], states[bundle], @[], axs_cachekeeper_extra_selectable(rows, states[bundle]));
}
static inline BOOL axs_cachekeeper_can_clean_tiered(NSDictionary *directories, NSDictionary *states, NSString *bundle, NSArray *rows) {
    return axs_cachekeeper_bundle_id(bundle) && [states isKindOfClass:NSDictionary.class] &&
        axs_cachekeeper_app_enabled(states[bundle]) && axs_cachekeeper_wants_cleanup(states[bundle]) &&
        (axs_cachekeeper_selected_paths_tiered(directories, states, bundle, rows).count > 0 || axs_cachekeeper_auto_discover(states[bundle]));
}
static inline NSString *axs_cachekeeper_evidence_summary(NSDictionary *evidence) {
    if (![evidence isKindOfClass:NSDictionary.class]) return @"尚未抽检内容；点按目录可查看处置选项";
    NSUInteger files = [evidence[@"files"] unsignedIntegerValue];
    NSUInteger media = [evidence[@"media"] unsignedIntegerValue];
    NSUInteger data = [evidence[@"data"] unsignedIntegerValue];
    NSUInteger other = [evidence[@"other"] unsignedIntegerValue];
    NSUInteger unchecked = [evidence[@"unchecked"] unsignedIntegerValue];
    NSString *scope = [evidence[@"complete"] boolValue] ? @"全量" : @"部分";
    NSString *grade = axs_cachekeeper_evidence_grade(evidence);
    if ([grade isEqual:@"data"]) return [NSString stringWithFormat:@"抽检（%@ %lu 个文件）：检出 %lu 个数据文件，仅查看", scope, (unsigned long)files, (unsigned long)data];
    if ([grade isEqual:@"cachelike"]) return [NSString stringWithFormat:@"抽检（全量 %lu 个文件）：均为可识别媒体，无数据标记", (unsigned long)files];
    if (!files) return @"抽检：目录为空或没有可读文件";
    return [NSString stringWithFormat:@"抽检（%@ %lu 个文件）：媒体 %lu · 数据 %lu · 未识别 %lu · 未查 %lu", scope, (unsigned long)files, (unsigned long)media, (unsigned long)data, (unsigned long)other, (unsigned long)unchecked];
}
// 纵向旁证：generations 为最新在前的 {rows, updated} 列表；只描述大小序列，不参与定性。
static inline NSString *axs_cachekeeper_trend_label(NSArray *generations, NSString *path) {
    if (![generations isKindOfClass:NSArray.class] || generations.count < 3) return nil;
    NSMutableArray *sizes = [NSMutableArray new];
    NSDate *newest = nil, *oldest = nil;
    for (id generation in generations) {
        if (![generation isKindOfClass:NSDictionary.class]) continue;
        BOOL found = NO; unsigned long long bytes = 0;
        if ([generation[@"rows"] isKindOfClass:NSArray.class]) for (id row in generation[@"rows"])
            if ([row isKindOfClass:NSDictionary.class] && [row[@"path"] isEqual:path]) { bytes = [row[@"bytes"] unsignedLongLongValue]; found = YES; break; }
        if (!found) return nil;
        [sizes addObject:@(bytes)];
        NSDate *date = generation[@"updated"];
        if ([date isKindOfClass:NSDate.class]) { if (!newest) newest = date; oldest = date; }
    }
    if (sizes.count < 3 || !newest || !oldest) return nil;
    BOOL same = YES, growing = [sizes.firstObject unsignedLongLongValue] > [sizes.lastObject unsignedLongLongValue];
    for (NSUInteger i = 1; i < sizes.count; i++) {
        if (![sizes[i] isEqual:sizes[0]]) same = NO;
        if ([sizes[i] unsignedLongLongValue] > [sizes[i - 1] unsignedLongLongValue]) growing = NO;
    }
    if (same && [newest timeIntervalSinceDate:oldest] >= 7 * 86400) return @"多次检测大小无变化";
    if (growing && !same) return @"近几次检测持续增长";
    return nil;
}
static inline NSDictionary *axs_cachekeeper_quarantine_entry(NSDictionary *quarantine, NSString *bundle, NSString *path) {
    if (![quarantine[bundle] isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *entry = quarantine[bundle][path];
    return [entry isKindOfClass:NSDictionary.class] ? entry : nil;
}
static inline BOOL axs_cachekeeper_quarantine_active(NSDictionary *quarantine, NSString *bundle, NSString *path) {
    NSDictionary *entry = axs_cachekeeper_quarantine_entry(quarantine, bundle, path);
    return [entry[@"status"] isEqual:@"active"] && [entry[@"holding"] isKindOfClass:NSString.class] && [entry[@"holding"] length];
}

#ifdef __cplusplus
extern "C" {
#endif
NSDictionary *axs_cachekeeper_restore_paths(NSArray *paths, NSString *journal);
void axs_cachekeeper_request_cleanup(NSString *bundle);
void CKScanRequests(void);
void CKDeepRequests(void);
void CKQuarantineRequests(void);
void CKApplyDirectorySwitches(void);
#ifdef __cplusplus
}
#endif
