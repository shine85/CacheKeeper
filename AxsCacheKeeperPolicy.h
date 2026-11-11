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
// 扫描可展示所有一级数据目录；允许删除的根只来自这里，不能由目录名字含 cache 推断。
static inline BOOL axs_cachekeeper_cache_path(NSString *path) {
    if (axs_cachekeeper_protected_path(path)) return NO;
    for (NSString *root in @[@"Library/Caches", @"tmp", @"Library/Logs", @"Caches", @"Cache", @"cache", @".cache"]) {
        if ([path isEqual:root] || [path hasPrefix:[root stringByAppendingString:@"/"]]) return YES;
    }
    return NO;
}
static inline NSString *axs_cachekeeper_directory_description(NSString *path) {
    if ([path hasPrefix:@"Group/"]) return @"App Group 共享数据：可能被其他 APP 或扩展使用；仅统计，不锁不删";
    NSDictionary *descriptions=@{
        @"tmp":@"临时工作文件、导入导出与下载中转；仅识别出的媒体缓存可清理",
        @"Library/Caches":@"可重建缓存；普通媒体可清理，数据库与未知内容保留",
        @"Library/Logs":@"日志与诊断；日志、数据库 WAL 和未知内容保留",
        @"Library/Application Support":@"业务数据、数据库、离线资源和运行组件；仅查看",
        @"Library/HTTPStorages":@"HTTP 持久化数据与可能的会话状态；仅查看",
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
    return axs_cachekeeper_cache_path(path) ? @"缓存目录；仅清理可识别的普通媒体，其他内容保留" : @"APP 自定义数据，用途未确认；仅查看";
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
static inline NSMutableDictionary *axs_cachekeeper_app_state(id previous, BOOL enabled) {
    return [@{@"enabled":@(enabled), @"mode":axs_cachekeeper_mode(previous), @"urlCache":@(axs_cachekeeper_url_cache_enabled(previous))} mutableCopy];
}
static inline NSArray *axs_cachekeeper_activation_paths(id previous) {
    return previous==nil ? @[@"Library/Caches",@"tmp"] : axs_cachekeeper_cache_paths(previous);
}
static inline NSArray<NSString *> *axs_cachekeeper_selected_paths(NSDictionary *directories, NSDictionary *states, NSString *bundle) {
    if (!axs_cachekeeper_bundle_id(bundle) || ![directories isKindOfClass:NSDictionary.class]) return @[];
    if (states && ![states isKindOfClass:NSDictionary.class]) return @[];
    if (!axs_cachekeeper_app_enabled(states[bundle])) return @[];
    return axs_cachekeeper_cache_paths(directories[bundle]);
}
static inline BOOL axs_cachekeeper_can_clean(NSDictionary *directories, NSDictionary *states, NSString *bundle) {
    return axs_cachekeeper_selected_paths(directories,states,bundle).count > 0 && axs_cachekeeper_wants_cleanup(states[bundle]);
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
#ifdef __cplusplus
extern "C" {
#endif
NSDictionary *axs_cachekeeper_restore_paths(NSArray *paths, NSString *journal);
void axs_cachekeeper_request_cleanup(NSString *bundle);
void CKScanRequests(void);
void CKApplyDirectorySwitches(void);
#ifdef __cplusplus
}
#endif
