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
            @"downloads", @"offline", @"inbox", @"draft"]) {
            if ([part containsString:word]) return YES;
        }
        if ([part isEqual:@"db"] || [part hasSuffix:@".db"] || [part containsString:@".db-"] ||
            [part hasSuffix:@".plist"] || [part hasSuffix:@".json"] || [part hasSuffix:@".key"] ||
            [part hasSuffix:@".pem"] || [part hasSuffix:@".p12"]) return YES;
    }
    return NO;
}
// 保留子树判定（修订方案任务 1）：相对路径的任一目录成分命中必要状态词，即为已确认
// 保留范围——其下文件不删，其余独立范围继续。与 protected_path 的区别：只含状态词
//（偏好/登录/凭据/下载/收件等必要状态），不含格式词（database/sqlite/realm）与文件
// 后缀规则——数据库格式不能单独证明必须保留，平台缓存内的 SQLite 按平台规则可清。
// 调用方只对目录成分使用本函数，不对文件名使用（文件名命中状态词不等于整目录保留）。
static inline BOOL axs_cachekeeper_retention_path(NSString *path) {
    if (!axs_cachekeeper_relative_path(path)) return YES;
    for (NSString *part in [path.lowercaseString componentsSeparatedByString:@"/"]) {
        for (NSString *word in @[@"documents", @"preferences", @"webkit", @"cookie",
            @"keychain", @"credential", @"login", @"account", @"auth", @"session", @"token",
            @"downloads", @"offline", @"inbox", @"draft"]) {
            if ([part containsString:word]) return YES;
        }
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
    return @[@"Library/Caches", @"tmp", @"Caches", @"Cache", @"cache", @".cache"];
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
    for (NSString *root in @[@"Library/Application Support",@"Library/HTTPStorages",@"Library/SplashBoard",@"Library/Saved Application State",@"Library/Logs"]) {
        if ([inner isEqual:root] || [inner hasPrefix:[root stringByAppendingString:@"/"]]) return @"mixed";
    }
    return @"unknown";
}
static inline NSString *axs_cachekeeper_directory_description(NSString *path) {
    if ([path hasPrefix:@"Group/"]) return @"App Group 共享数据：可能被其他 APP 或扩展使用；仅统计，不锁不删";
    NSDictionary *descriptions=@{
        @"tmp":@"按平台临时文件用途清理；保留已确认数据与手动排除，近期文件延期",
        @"Library/Caches":@"按平台缓存用途清理，包含缓存数据库；保留已确认数据与手动排除，近期文件延期",
        @"Library/Logs":@"平台约定：日志与诊断，也可能含数据库 WAL；当前不提供清理开关，可深度检测",
        @"Library/Application Support":@"混合用途：业务数据、数据库、离线资源或缓存；未逐项验证可删性",
        @"Library/HTTPStorages":@"混合用途：网络持久化数据与会话状态；未验证可删性",
        @"Library/WebKit":@"网页缓存、网站数据库与登录态；仅查看",
        @"Library/Cookies":@"Cookie 与登录会话；仅查看",
        @"Library/Preferences":@"APP 设置与偏好；仅查看",
        @"Library/SplashBoard":@"平台约定：可再生的启动与切换画面快照；未实测可删性",
        @"Library/Saved Application State":@"平台约定：界面恢复状态；未实测可删性",
        @"Documents":@"用户文稿、聊天附件和离线文件；仅查看",
        @"Downloads":@"用户下载与离线文件；仅查看",
        @"Inbox":@"导入或共享接收的用户文件；仅查看"
    };
    if (descriptions[path]) return descriptions[path];
    if ([path hasPrefix:@"Library/Caches/"] || [path hasPrefix:@"tmp/"]) return @"标准缓存范围：按平台用途清理；已确认数据与手动排除优先";
    return @"用途待识别；仅按已验证 APP 规则或日志定级处理，零证据不构成删除依据";
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
static inline BOOL axs_cachekeeper_container_bundle_path(NSString *path) {
    // 真实应用容器：…/Bundle/Application/<UUID>/<App>.app（Application/ 后恰好两级）。
    // Roothide 的 jbroot 藏在容器目录下（…/Application/.jbroot-<hex>/Applications/<App>.app，Application/ 后三级），
    // 仅含子串会把越狱应用误判为容器应用（#66 真机：Sileo 包体 /private/var/containers/Bundle/Application/.jbroot-A9F73A89EAC821EE/Applications/Sileo.app）。
    if (![path isKindOfClass:NSString.class] || !path.length) return NO;
    NSRange marker=[path rangeOfString:@"/containers/Bundle/Application/"];
    if (marker.location==NSNotFound) return NO;
    NSArray *parts=[[path substringFromIndex:NSMaxRange(marker)] pathComponents];
    if (parts.count!=2) return NO;
    NSString *leaf=parts[1];
    return [leaf isKindOfClass:NSString.class] && [[leaf lowercaseString] hasSuffix:@".app"];
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
// 三种模式共用同一删除引擎（方案任务 9）：模式只决定是否限制网络缓存，不再决定是否清理。
// 旧 wants_cleanup（prevent 不清理）已删除：prevent 同样清理存量与新增缓存。
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
    // 全新 APP 默认自动发现开启：只开总开关即全自动（标准缓存根自动纳入，未知目录内容审查自动清理）；
    // 已明确关闭的（键为 @NO）保持关闭；手动排除始终有效。2026-11-12 用户要求：分目录不用逐个管。
    if ([state isKindOfClass:NSDictionary.class] && [state[@"autoDiscover"] isKindOfClass:NSNumber.class])
        return [state[@"autoDiscover"] boolValue];
    return YES;
}
// 标准缓存按用途清理已成为已启用 APP 的统一行为（方案任务 8/9）：平台缓存契约目录
// Library/Caches 与 tmp 按 CleanupRules 平台规则处理，不再需要逐 APP 的全量开关。
// 旧 fullClear 键只作面板迁移识别：状态归一化时丢弃，产品判定永不读取。
// 顶层 Caches/Cache/cache/.cache 虽属 kind=cache 白名单根，但非苹果缓存契约目录，
// 不按平台规则全量清理（审计第 4 项）；Library/Logs 自 0.7.0 起归混合类，不在此列。
static inline BOOL axs_cachekeeper_log_file_name(NSString *name) {
    // 日志特征文件名（定级日志目录内的删除门）：常见日志扩展名及其复合后缀形态
    //（如 BDALog_20261111.alog.iOS.1128、微信 *.xlog）。仅名字特征，不读内容另行判断。
    NSString *n=name.lowercaseString;
    if (!n.length) return NO;
    for (NSString *ext in @[@".log", @".alog", @".xlog"]) {
        if ([n hasSuffix:ext] || [n containsString:[ext stringByAppendingString:@"."]]) return YES;
    }
    return NO;
}
static inline BOOL axs_cachekeeper_log_path_valid(NSString *path) {
    // 可定级为日志目录的路径：用途未知类目录，且不是任何受保护/标准缓存根的祖先
    //（如 Library 本身），避免一次定级吞掉整片区域。Group/混合/缓存/受保护类均不可定级。
    if (!axs_cachekeeper_relative_path(path) || axs_cachekeeper_protected_path(path)) return NO;
    if (![axs_cachekeeper_directory_kind(path) isEqual:@"unknown"]) return NO;
    for (NSString *root in @[@"Documents",@"Inbox",@"Downloads",@"Library/Preferences",@"Library/Cookies",
        @"Library/WebKit",@"Library/Keychains",@"Library/Caches",@"tmp",@"Caches",@"Cache",@"cache",@".cache"]) {
        if ([root hasPrefix:[path stringByAppendingString:@"/"]]) return NO;
    }
    return YES;
}
static inline NSArray<NSString *> *axs_cachekeeper_log_paths(id state) {
    if (![state isKindOfClass:NSDictionary.class]) return @[];
    NSMutableArray *valid=[NSMutableArray new];
    if ([state[@"logPaths"] isKindOfClass:NSArray.class]) for (id path in state[@"logPaths"])
        if (axs_cachekeeper_log_path_valid(path)) [valid addObject:path];
    return axs_cachekeeper_parent_paths(valid);
}
// B 案内容审查的证据口径（无数据证据即清的判定依据）：数据库与登录态类证据命中其一，
// 目录自动降级为日志门（仅删日志文件）；目录名命中仍整目录保留。
// 配置类 .plist/.json 不算证据：它们是可再生的运行时配置（tma 含此类文件，仍可清）；
// 凭证类 .key/.pem/.p12 算证据。目录名数据标记与数据库头另由 Sweep 预检复核。
static inline BOOL axs_cachekeeper_purge_evidence_path(NSString *relative) {
    if (!axs_cachekeeper_relative_path(relative)) return YES;
    for (NSString *part in [relative.lowercaseString componentsSeparatedByString:@"/"]) {
        for (NSString *word in @[@"documents", @"preferences", @"webkit", @"cookie", @"database", @"sqlite",
            @"realm", @"keychain", @"credential", @"login", @"account", @"auth", @"session", @"token",
            @"downloads", @"offline", @"inbox"]) {
            if ([part containsString:word]) return YES;
        }
        if ([part isEqual:@"db"] || [part hasSuffix:@".db"] || [part containsString:@".db-"] ||
            [part hasSuffix:@".key"] || [part hasSuffix:@".pem"] || [part hasSuffix:@".p12"]) return YES;
    }
    return NO;
}
static inline NSArray<NSString *> *axs_cachekeeper_exclusions(id state) {
    // 用户手动排除的目录：缓存根（行开关）与用途未知目录（保留开关）共用同一清单。
    // 保留意图只校验路径语法；用途/格式过滤会丢掉用户排除，不能用于缩小保留清单。
    if (![state isKindOfClass:NSDictionary.class]) return @[];
    NSMutableArray *safe=[NSMutableArray new];
    if ([state[@"excludedPaths"] isKindOfClass:NSArray.class]) for (id path in state[@"excludedPaths"])
        if ([path isKindOfClass:NSString.class] && axs_cachekeeper_relative_path(path)) [safe addObject:path];
    return axs_cachekeeper_parent_paths(safe);
}
static inline BOOL axs_cachekeeper_paths_overlap(NSString *left, NSString *right) {
    return [left isEqual:right] || [left hasPrefix:[right stringByAppendingString:@"/"]] ||
        [right hasPrefix:[left stringByAppendingString:@"/"]];
}
// 单向包含判定（方案任务 6）：path 在 ancestor 子树内（相等也算）。排除剪枝只用单向判定——
// 候选在排除子树内才移除；排除是候选的子树时保留候选，Sweep 按文件级排除决定裁剪子树，
// 不丢弃排除外的合法同级范围（旧双向 overlap 会把整个父根删掉）。
static inline BOOL axs_cachekeeper_path_inside(NSString *path, NSString *ancestor) {
    return [path isEqual:ancestor] || [path hasPrefix:[ancestor stringByAppendingString:@"/"]];
}
// 须置于 exclusions/paths_overlap 定义之后：C 不允许先用后定义（#34 即因此编译失败）。
static inline NSArray<NSString *> *axs_cachekeeper_purge_paths(NSArray *candidates, id state) {
    // 未知目录自动清理候选集：用途未知类、未定级为日志、未被手动排除；父目录优先去重。
    NSMutableArray *paths=[NSMutableArray new];
    NSArray *logs=axs_cachekeeper_log_paths(state);
    NSArray *excluded=axs_cachekeeper_exclusions(state);
    for (NSString *path in candidates) {
        if (!axs_cachekeeper_log_path_valid(path)) continue;
        if ([logs containsObject:path]) continue;
        BOOL hit=NO;
        for (NSString *ex in excluded) if (axs_cachekeeper_path_inside(path,ex)) { hit=YES; break; }
        if (!hit) [paths addObject:path];
    }
    return axs_cachekeeper_parent_paths(paths);
}
static inline NSArray<NSString *> *axs_cachekeeper_effective_paths(NSArray *selected, id state, NSArray *discovered) {
    if (!axs_cachekeeper_app_enabled(state)) return @[];
    NSMutableArray *paths=[axs_cachekeeper_cache_paths(selected) mutableCopy];
    if (axs_cachekeeper_auto_discover(state) && [discovered isKindOfClass:NSArray.class]) {
        for (id path in discovered) if ([axs_cachekeeper_cache_roots() containsObject:path]) [paths addObject:path];
    }
    // 用户逐项定级的日志目录与缓存根并列为有效根（定级只存于状态，永不由一键开启/自动发现写入）。
    [paths addObjectsFromArray:axs_cachekeeper_log_paths(state)];
    // 手动排除的剪枝只按单向包含（任务 6）：候选在排除子树内才移除；排除是候选的子树时
    // 保留候选——Sweep 按文件级排除决定裁剪子树，排除外的合法同级范围继续处理。
    // 父范围不能绕过子排除（文件级决定保证），也不因一个子排除丢掉整个父根。
    for (NSString *path in [paths copy]) for (NSString *excluded in axs_cachekeeper_exclusions(state)) {
        if (axs_cachekeeper_path_inside(path,excluded)) { [paths removeObject:path];break; }
    }
    NSMutableArray *result=[axs_cachekeeper_cache_paths(paths) mutableCopy];
    for (NSString *path in paths) if (axs_cachekeeper_log_path_valid(path) && ![result containsObject:path]) [result addObject:path];
    return axs_cachekeeper_parent_paths(result);
}
static inline NSMutableDictionary *axs_cachekeeper_app_state(id previous, BOOL enabled) {
    // 唯一状态归一化入口（方案任务 8）：旧 fullClear 键在此丢弃（不再写入新状态），
    // 其余选择（模式、网络选项、自动发现、日志定级、手动排除）原样保留；Tweak 不写用户配置。
    return [@{@"enabled":@(enabled), @"mode":axs_cachekeeper_mode(previous), @"urlCache":@(axs_cachekeeper_url_cache_enabled(previous)),
        @"autoDiscover":@(axs_cachekeeper_auto_discover(previous)),
        @"logPaths":axs_cachekeeper_log_paths(previous),
        @"excludedPaths":axs_cachekeeper_exclusions(previous)} mutableCopy];
}
static inline NSMutableDictionary *axs_cachekeeper_state_with_mode(id previous, NSString *mode) {
    NSMutableDictionary *state=axs_cachekeeper_app_state(previous,axs_cachekeeper_app_enabled(previous));
    state[@"mode"]=axs_cachekeeper_mode(@{@"mode":mode ?: @""});
    return state;
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
        axs_cachekeeper_app_enabled(states[bundle]) &&
        (axs_cachekeeper_selected_paths(directories,states,bundle).count > 0 || axs_cachekeeper_auto_discover(states[bundle]));
}
// 界面时间统一按设备本地时区显示；NSDate 的 %@ 描述恒为 UTC（+0000），会与机器时间差出时区小时数。
static inline NSString *axs_cachekeeper_format_time(id value, NSTimeZone *zone) {
    if (![value isKindOfClass:NSDate.class]) return @"时间未知";
    NSDateFormatter *formatter=[NSDateFormatter new];
    formatter.locale=[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.calendar=[[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    formatter.dateFormat=@"yyyy-MM-dd HH:mm:ss";
    formatter.timeZone=zone;
    return [formatter stringFromDate:value];
}
static inline NSString *axs_cachekeeper_time_string(id value) {
    return axs_cachekeeper_format_time(value,NSTimeZone.localTimeZone);
}
static inline NSString *axs_cachekeeper_summary(NSDictionary *scan, NSDictionary *report) {
    NSMutableArray *parts = [NSMutableArray new];
    if ([scan[@"rows"] isKindOfClass:NSArray.class]) [parts addObject:[NSString stringWithFormat:@"检测到 %lu 个目录（大小为检测快照）", (unsigned long)[scan[@"rows"] count]]];
    if ([report isKindOfClass:NSDictionary.class]) {
        NSString *message = report[@"message"];
        if ([message isKindOfClass:NSString.class] && message.length) [parts addObject:message];
        [parts addObject:[NSString stringWithFormat:@"累计清理 %lu 个 · %.2f MB", (unsigned long)[report[@"removed"] unsignedIntegerValue], [report[@"bytes"] doubleValue] / 1048576.0]];
        if (report[@"lastBytes"]) [parts addObject:[NSString stringWithFormat:@"上次清理：%.2f MB", [report[@"lastBytes"] doubleValue] / 1048576.0]];
        if ([report[@"failed"] unsignedIntegerValue]) [parts addObject:[NSString stringWithFormat:@"本轮失败 %@ 项", report[@"failed"]]];
        if (report[@"updated"]) [parts addObject:[NSString stringWithFormat:@"最近检查 %@", axs_cachekeeper_time_string(report[@"updated"])]];
    }
    return parts.count ? [parts componentsJoinedByString:@"\n"] : @"尚未检测；检测后开启 APP 缓存控制";
}
#ifdef __cplusplus
extern "C" {
#endif
NSDictionary *axs_cachekeeper_restore_paths(NSArray *paths, NSString *journal);
NSDictionary *axs_cachekeeper_lock_paths(NSArray *roots, NSString *journal);
void axs_cachekeeper_request_cleanup(NSString *bundle);
void CKScanRequests(void);
void CKInspectRequests(void);
void CKApplyDirectorySwitches(void);
#ifdef __cplusplus
}
#endif
