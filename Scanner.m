#import <Foundation/Foundation.h>
#import <objc/message.h>
#include <roothide.h>
#include <sys/stat.h>
#include <signal.h>
#include <errno.h>
extern void CKSetPaths(NSArray *,BOOL);
extern NSArray *CKBaselineDirectories(NSString *,NSTimeInterval,BOOL,NSUInteger *,unsigned long long *,BOOL *);
static id SRead(id target,NSString *name) { SEL s=NSSelectorFromString(name);return [target respondsToSelector:s]?((id(*)(id,SEL))objc_msgSend)(target,s):nil; }
static NSURL *Container(NSString *bundle) {
    Class proxy=NSClassFromString(@"LSApplicationProxy"); SEL s=NSSelectorFromString(@"applicationProxyForIdentifier:");
    id app=[proxy respondsToSelector:s]?((id(*)(id,SEL,id))objc_msgSend)(proxy,s,bundle):nil;
    NSURL *home=SRead(app,@"dataContainerURL");
    if (![home isKindOfClass:NSURL.class]) return nil;
    home=home.URLByResolvingSymlinksInPath;
    return [home.path containsString:@"/Containers/Data/Application/"]?home:nil;
}
// 0.4.1 禁区硬拦截：以下路径永不列、永不锁、永不删。不只靠“不生成”保证，
// 在候选产出与配置应用两处再各拦一道，旧配置或手工改过的配置也进不来。
static BOOL CKForbiddenPath(NSString *relative) {
    for (NSString *zone in @[@"Documents", @"Library/Preferences", @"Library/Cookies", @"Library/WebKit"])
        if ([relative isEqual:zone] || [relative hasPrefix:[zone stringByAppendingString:@"/"]]) return YES;
    return NO;
}

// 候选目录（0.4.0 定版根集 + 0.4.7 补全）：只列“根级”条目——任何条目都不能是
// 另一条的子路径（父目录优先、子条目忽略）。三类：
//  ① 固定根：Caches、tmp、HTTPStorages、SplashBoard（启动快照）、
//     Saved Application State（界面恢复状态）；
//  ② Application Support 的一级子目录（混真实数据，只能逐个选，永不列 AS 根）；
//  ③ 容器根与 Library 下的其他一级子目录逐个成行（各 SDK/App 自建目录常在此
//     堆缓存）——红线名与已单列的根跳过。用户据此逐个 App、逐个目录定位判断。
// 0.4.10 补定义：0.4.7 重写 Candidates 时调用了这个存在性检查，但函数本体
// 一直缺失（旧版用的是内联写法）——Actions 第 10 号运行报未声明函数错误。
static BOOL Directory(NSURL *home, NSString *relative) {
    struct stat info;
    NSString *path = [home.path stringByAppendingPathComponent:relative];
    return !lstat(path.fileSystemRepresentation, &info) && S_ISDIR(info.st_mode);
}

static NSArray *Candidates(NSURL *home) {
    NSMutableArray *result = [NSMutableArray new];
    for (NSString *relative in @[@"Library/Caches",@"tmp",@"Library/HTTPStorages",
                                 @"Library/SplashBoard",@"Library/Saved Application State"])
        if (Directory(home, relative)) [result addObject:relative];
    NSURL *support = [home URLByAppendingPathComponent:@"Library/Application Support"];
    for (NSURL *entry in [NSFileManager.defaultManager contentsOfDirectoryAtURL:support
        includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:0 error:nil]) {
        NSNumber *directory = nil;
        [entry getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil];
        if (directory.boolValue)
            [result addObject:[@"Library/Application Support/" stringByAppendingString:entry.lastPathComponent]];
    }
    NSSet *rootSkip = [NSSet setWithObjects:@"Documents",@"Library",@"tmp",
        @"Preferences",@"Cookies",@"WebKit",nil];
    for (NSURL *entry in [NSFileManager.defaultManager contentsOfDirectoryAtURL:home
        includingPropertiesForKeys:nil options:0 error:nil]) {
        struct stat info;
        if (lstat(entry.fileSystemRepresentation,&info) || !S_ISDIR(info.st_mode)) continue;
        NSString *name = entry.lastPathComponent;
        if ([rootSkip containsObject:name] || [name hasPrefix:@"."]) continue;
        [result addObject:name];
    }
    NSSet *librarySkip = [NSSet setWithObjects:@"Caches",@"HTTPStorages",@"Application Support",
        @"Preferences",@"Cookies",@"WebKit",@"SplashBoard",@"Saved Application State",nil];
    NSURL *library = [home URLByAppendingPathComponent:@"Library"];
    for (NSURL *entry in [NSFileManager.defaultManager contentsOfDirectoryAtURL:library
        includingPropertiesForKeys:nil options:0 error:nil]) {
        struct stat info;
        if (lstat(entry.fileSystemRepresentation,&info) || !S_ISDIR(info.st_mode)) continue;
        NSString *name = entry.lastPathComponent;
        if ([librarySkip containsObject:name] || [name hasPrefix:@"."]) continue;
        [result addObject:[@"Library/" stringByAppendingString:name]];
    }
    return result;
}

// 0.4.2 App Group 共享容器：不少 App 会把主 App 与小组件/扩展共用
// 的缓存放在 /var/mobile/Containers/Shared/AppGroup/<UUID>/ 下，那里同样有
// Library/Caches、tmp 等目录，只扫主容器会漏掉这一池。groupContainerURLs 给出
// 组 ID -> 容器 URL；候选以 "Group/<组ID>/<相对路径>" 的形式并入同一套管理。
static NSDictionary *GroupHomes(NSString *bundle) {
    Class proxy = NSClassFromString(@"LSApplicationProxy");
    SEL s = NSSelectorFromString(@"applicationProxyForIdentifier:");
    id app = [proxy respondsToSelector:s] ? ((id(*)(id,SEL,id))objc_msgSend)(proxy, s, bundle) : nil;
    NSDictionary *groups = SRead(app, @"groupContainerURLs");
    if (![groups isKindOfClass:NSDictionary.class]) return @{};
    NSMutableDictionary *result = [NSMutableDictionary new];
    for (NSString *gid in groups) {
        NSURL *url = groups[gid];
        if (![url isKindOfClass:NSURL.class]) continue;
        url = url.URLByResolvingSymlinksInPath;
        if ([url.path containsString:@"/Containers/Shared/AppGroup/"]) result[gid] = url;
    }
    return result;
}
static NSArray *PrefixedCandidates(NSURL *home, NSDictionary *groups) {
    NSMutableArray *all = [NSMutableArray arrayWithArray:Candidates(home)];
    for (NSString *gid in [groups.allKeys sortedArrayUsingSelector:@selector(compare:)])
        for (NSString *inner in Candidates(groups[gid]))
            [all addObject:[NSString stringWithFormat:@"Group/%@/%@", gid, inner]];
    return all;
}
static NSURL *CKHomeForRelative(NSString *relative, NSURL *home, NSDictionary *groups, NSString **inner) {
    if ([relative hasPrefix:@"Group/"]) {
        NSString *rest = [relative substringFromIndex:6];
        NSRange slash = [rest rangeOfString:@"/"];
        if (slash.location != NSNotFound) {
            NSURL *groupHome = groups[[rest substringToIndex:slash.location]];
            if (groupHome) { *inner = [rest substringFromIndex:slash.location + 1]; return groupHome; }
        }
        return nil;
    }
    *inner = relative;
    return home;
}

void CKScanRequests(void) {
    static BOOL busy;
    if (busy) return;
    NSString *folder=jbroot(@"/var/mobile/Library/CacheKeeper");
    NSString *requestPath=[folder stringByAppendingPathComponent:@"request.plist"];
    NSDictionary *request=[NSDictionary dictionaryWithContentsOfFile:requestPath];
    NSString *batchPath=[folder stringByAppendingPathComponent:@"batch.plist"];
    NSMutableDictionary *batch=[[NSDictionary dictionaryWithContentsOfFile:batchPath] mutableCopy];
    BOOL batchItem=NO;
    if (!request && [batch[@"remaining"] count]) {
        NSMutableArray *remaining=[batch[@"remaining"] mutableCopy];
        NSString *next=remaining.firstObject;
        batch[@"remaining"]=remaining;
        [batch writeToFile:batchPath atomically:YES];
        request=@{@"bundle":next,@"token":batch[@"token"]};
        batchItem=YES;
    }
    NSString *bundle=request[@"bundle"],*token=request[@"token"];
    if (![bundle isKindOfClass:NSString.class] || ![token isKindOfClass:NSString.class] || !token.length) return;
    NSURL *home=Container(bundle);
    NSDictionary *groups=home?GroupHomes(bundle):@{};
    NSArray *candidates=home?PrefixedCandidates(home,groups):@[];
    if (!batchItem) [NSFileManager.defaultManager removeItemAtPath:requestPath error:nil];
    busy=YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        NSMutableArray *rows=[NSMutableArray array];
        NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+15;
        for (NSString *relative in candidates) {
            NSString *inner=nil;
            NSURL *base=CKHomeForRelative(relative,home,groups,&inner);
            if (!base) continue;
            NSURL *root=[base URLByAppendingPathComponent:inner];
            unsigned long long size=0; NSUInteger files=0; __block BOOL complete=YES;
            NSDirectoryEnumerator *entries=[NSFileManager.defaultManager enumeratorAtURL:root includingPropertiesForKeys:nil options:0 errorHandler:^BOOL(NSURL *url,NSError *error){complete=NO;return YES;}];
            for (NSURL *entry in entries) {
                if (NSProcessInfo.processInfo.systemUptime>deadline || ++files>100000) {complete=NO;break;}
                struct stat info;
                if (lstat(entry.path.fileSystemRepresentation,&info)) continue;
                if (S_ISLNK(info.st_mode)) {[entries skipDescendants];continue;}
                if (S_ISREG(info.st_mode)) size+=info.st_size;
            }
            [rows addObject:@{@"path":relative,@"bytes":@(size),@"complete":@(complete)}];
        }
        NSMutableDictionary *history=[[NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:@"snapshots.plist"]] mutableCopy]?:[NSMutableDictionary new];
        NSDictionary *old=history[bundle];
        NSMutableDictionary *groupPaths=[NSMutableDictionary new];
        for (NSString *gid in groups) groupPaths[gid]=[groups[gid] path];
        NSDictionary *result=@{@"token":token,@"bundle":bundle,@"home":home.path?:@"",@"groups":groupPaths,@"rows":rows,@"updated":NSDate.date,@"previousRows":old[@"rows"]?:@[]};
        history[bundle]=result;
        [history writeToFile:[folder stringByAppendingPathComponent:@"snapshots.plist"] atomically:YES];
        if (!batchItem) [result writeToFile:[folder stringByAppendingPathComponent:@"scan.plist"] atomically:YES];
        dispatch_async(dispatch_get_main_queue(),^{
            NSString *selectionPath=[folder stringByAppendingPathComponent:@"directories.plist"];
            NSMutableDictionary *selection=[[NSDictionary dictionaryWithContentsOfFile:selectionPath] mutableCopy]?:[NSMutableDictionary new];
            // Only seed an application once. Preserve later manual choices, including an empty list.
            if (!selection[bundle] && [candidates containsObject:@"Library/Caches"]) {
                NSString *statePath=[folder stringByAppendingPathComponent:@"appEnabled.plist"];
                NSMutableDictionary *states=[[NSDictionary dictionaryWithContentsOfFile:statePath] mutableCopy]?:[NSMutableDictionary new];
                states[bundle]=@NO;
                // Persist the disabled master before storing recommended paths.
                if ([states writeToFile:statePath atomically:YES]) {
                    selection[bundle]=@[@"Library/Caches"];
                    [selection writeToFile:selectionPath atomically:YES];
                }
            }
            if (batchItem) {
                NSMutableDictionary *current=[[NSDictionary dictionaryWithContentsOfFile:batchPath] mutableCopy];
                if ([current[@"token"] isEqual:token]) {
                    NSMutableArray *left=[current[@"remaining"] mutableCopy];
                    if ([left.firstObject isEqual:bundle]) [left removeObjectAtIndex:0];
                    current[@"remaining"]=left;
                    current[@"completed"]=@([current[@"completed"] unsignedIntegerValue]+1);
                    [current writeToFile:batchPath atomically:YES];
                }
            }
            busy=NO;
        });
    });
}
// 0.5.0 “安全类”目录：内容按系统约定可再生（缓存/临时/启动快照/界面状态），
// 一键开启、自动纳入、存量清理都只对这类目录生效。HTTPStorages 可能混
// cookies 文件，不算安全类；Application Support 与各自建目录一律手动。
static BOOL CKSafeRelative(NSString *relative) {
    NSString *inner = relative;
    if ([relative hasPrefix:@"Group/"]) {
        NSString *rest = [relative substringFromIndex:6];
        NSRange slash = [rest rangeOfString:@"/"];
        if (slash.location == NSNotFound) return NO;
        inner = [rest substringFromIndex:slash.location + 1];
    }
    return [@[@"Library/Caches", @"tmp", @"Library/SplashBoard", @"Library/Saved Application State"] containsObject:inner];
}
static BOOL CKAppRunning(NSString *bundle) {
    id manager = SRead(NSClassFromString(@"SBApplicationController"), @"sharedInstance");
    SEL lookup = NSSelectorFromString(@"applicationWithBundleIdentifier:");
    id app = [manager respondsToSelector:lookup] ? ((id(*)(id,SEL,id))objc_msgSend)(manager, lookup, bundle) : nil;
    id state = SRead(app, @"processState") ?: SRead(app, @"_internalProcessState");
    SEL rs = NSSelectorFromString(@"isRunning");
    // 状态拿不到时按“在运行”处理：宁可等下一轮，也不在使用中动文件。
    if (![state respondsToSelector:rs]) return YES;
    return ((BOOL(*)(id,SEL))objc_msgSend)(state, rs);
}
static unsigned long long CKBoundedSize(NSURL *root) {
    unsigned long long size = 0; NSUInteger files = 0;
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 10;
    NSDirectoryEnumerator *entries = [NSFileManager.defaultManager enumeratorAtURL:root includingPropertiesForKeys:nil options:0 errorHandler:^BOOL(NSURL *url, NSError *error){ return YES; }];
    for (NSURL *entry in entries) {
        if (NSProcessInfo.processInfo.systemUptime > deadline || ++files > 100000) break;
        struct stat info;
        if (lstat(entry.path.fileSystemRepresentation, &info)) continue;
        if (S_ISLNK(info.st_mode)) { [entries skipDescendants]; continue; }
        if (S_ISREG(info.st_mode)) size += info.st_size;
    }
    return size;
}
// 0.5.0 附加通道（用户 2026-11-11 第 2、3 点）：
//  (a) 存量清理：设置页对已开启的 App 写下 stock.plist 请求后，在该 App 未
//      运行时，把它已选中“安全类”目录里的【已有】文件一次清掉（开启插件
//      之前那次运行产生的缓存）。只走安全类；数据库/登录文件与数据目录由
//      基线函数内部的保护规则照常跳过；目录本身保留。
//  (b) 自动纳入：policy.autoNew 打开的 App，每小时至多一次重扫候选，把新
//      出现的“安全类”目录自动加入选择并补进快照行；谨慎类永不自动加。
static void CKProcessExtras(void) {
    NSString *folder = jbroot(@"/var/mobile/Library/CacheKeeper");
    NSDictionary *appEnabled = [NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:@"appEnabled.plist"]] ?: @{};
    NSString *stockPath = [folder stringByAppendingPathComponent:@"stock.plist"];
    NSMutableDictionary *stock = [[NSDictionary dictionaryWithContentsOfFile:stockPath] mutableCopy];
    if (stock.count) {
        NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:@"directories.plist"]] ?: @{};
        BOOL stockDirty = NO;
        for (NSString *bundle in stock.allKeys) {
            if (![appEnabled[bundle] boolValue]) { [stock removeObjectForKey:bundle]; stockDirty = YES; continue; }
            NSURL *home = Container(bundle);
            if (!home) { [stock removeObjectForKey:bundle]; stockDirty = YES; continue; }
            if (CKAppRunning(bundle)) continue; // 还在运行：留到下一轮
            NSDictionary *groups = GroupHomes(bundle);
            NSUInteger removed = 0; unsigned long long bytes = 0;
            for (NSString *relative in config[bundle]) {
                if (!CKSafeRelative(relative)) continue;
                NSString *inner = nil;
                NSURL *base = CKHomeForRelative(relative, home, groups, &inner);
                if (!base) continue;
                NSString *path = [base.path stringByAppendingPathComponent:inner];
                struct stat info;
                if (lstat(path.fileSystemRepresentation, &info) || !S_ISDIR(info.st_mode)) continue;
                BOOL protectedRoot = NO;
                CKBaselineDirectories(path, 0, YES, &removed, &bytes, &protectedRoot);
            }
            NSString *report = [[folder stringByAppendingPathComponent:@"Status"] stringByAppendingPathComponent:[bundle stringByAppendingString:@".auto.plist"]];
            NSDictionary *prior = [NSDictionary dictionaryWithContentsOfFile:report];
            [@{@"updated": NSDate.date, @"removed": @([prior[@"removed"] unsignedIntegerValue] + removed),
               @"bytes": @([prior[@"bytes"] unsignedLongLongValue] + bytes)} writeToFile:report atomically:YES];
            [stock removeObjectForKey:bundle]; stockDirty = YES;
        }
        if (stockDirty) [stock writeToFile:stockPath atomically:YES];
    }
    static NSMutableDictionary *lastRefresh;
    if (!lastRefresh) lastRefresh = [NSMutableDictionary new];
    NSDictionary *policies = [NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:@"policy.plist"]] ?: @{};
    NSString *selectionPath = [folder stringByAppendingPathComponent:@"directories.plist"];
    NSMutableDictionary *config = [[NSDictionary dictionaryWithContentsOfFile:selectionPath] mutableCopy] ?: [NSMutableDictionary new];
    BOOL configDirty = NO;
    for (NSString *bundle in policies) {
        if (![policies[bundle][@"autoNew"] boolValue] || ![appEnabled[bundle] boolValue]) continue;
        NSDate *last = lastRefresh[bundle];
        if (last && [NSDate.date timeIntervalSinceDate:last] < 3600) continue;
        NSURL *home = Container(bundle); if (!home) continue;
        lastRefresh[bundle] = NSDate.date;
        NSDictionary *groups = GroupHomes(bundle);
        NSArray *candidates = PrefixedCandidates(home, groups);
        NSMutableArray *selected = [config[bundle] mutableCopy] ?: [NSMutableArray new];
        NSMutableArray *added = [NSMutableArray new];
        for (NSString *relative in candidates)
            if (CKSafeRelative(relative) && ![selected containsObject:relative]) { [selected addObject:relative]; [added addObject:relative]; }
        if (!added.count) continue;
        config[bundle] = selected; configDirty = YES;
        NSString *snapPath = [folder stringByAppendingPathComponent:@"snapshots.plist"];
        NSMutableDictionary *history = [[NSDictionary dictionaryWithContentsOfFile:snapPath] mutableCopy] ?: [NSMutableDictionary new];
        NSMutableDictionary *snap = [history[bundle] mutableCopy] ?: [NSMutableDictionary new];
        NSMutableArray *rows = [snap[@"rows"] mutableCopy] ?: [NSMutableArray new];
        NSMutableSet *known = [NSMutableSet new];
        for (NSDictionary *row in rows) if (row[@"path"]) [known addObject:row[@"path"]];
        for (NSString *relative in added) {
            if ([known containsObject:relative]) continue;
            NSString *inner = nil;
            NSURL *base = CKHomeForRelative(relative, home, groups, &inner);
            if (!base) continue;
            [rows addObject:@{@"path": relative, @"bytes": @(CKBoundedSize([base URLByAppendingPathComponent:inner])), @"complete": @YES}];
        }
        snap[@"rows"] = rows;
        if (!snap[@"home"]) {
            snap[@"home"] = home.path;
            NSMutableDictionary *groupPaths = [NSMutableDictionary new];
            for (NSString *gid in groups) groupPaths[gid] = [groups[gid] path];
            snap[@"groups"] = groupPaths;
        }
        history[bundle] = snap;
        [history writeToFile:snapPath atomically:YES];
    }
    if (configDirty) [config writeToFile:selectionPath atomically:YES];
}

void CKApplyDirectorySwitches(void) {
    NSString *folder=jbroot(@"/var/mobile/Library/CacheKeeper");
    NSMutableDictionary *config=[[NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:@"directories.plist"]] mutableCopy] ?: [NSMutableDictionary new];
    NSMutableArray *enabled=[NSMutableArray array];
    NSDictionary *appEnabled=[NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:@"appEnabled.plist"]];
    NSString *baselinePath = [folder stringByAppendingPathComponent:@"baselines.plist"];
    NSDictionary *previous = [NSDictionary dictionaryWithContentsOfFile:baselinePath] ?: @{};
    NSMutableDictionary *baselines = [NSMutableDictionary new];
    static NSMutableDictionary *lastBackground, *lastRunning, *lastCleanup;
    static NSUInteger applyPolls;
    applyPolls++;
    if (!lastBackground) lastBackground = [NSMutableDictionary new];
    if (!lastRunning) lastRunning = [NSMutableDictionary new];
    if (!lastCleanup) lastCleanup = [NSMutableDictionary new];
    // 0.4.0：每 App 策略与自动降级状态。policy.plist 由设置页写：
    // bundle -> { mode: auto|lock|clean, urlCache: BOOL }，缺省 auto / 关。
    // fallback.plist 以受管目录绝对路径为键：{ strikes: N } 是警告计数，
    // 出现 reason 表示该目录已降级为只清理（权限由下方恢复环节自动还原）。
    NSDictionary *policies = [NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:@"policy.plist"]] ?: @{};
    NSMutableDictionary *fallback = [[NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:@"fallback.plist"]] mutableCopy] ?: [NSMutableDictionary new];
    BOOL fallbackDirty = NO;
    NSMutableDictionary *lockRoots = [NSMutableDictionary new];
    static NSMutableDictionary *shortRuns;
    if (!shortRuns) shortRuns = [NSMutableDictionary new];
    // 0.4.6 严格按人选（用户拍板，推翻 0.4.5 的默认全开）：全部 App 只在设置
    // 列表里列出，由用户逐个开启；未开启的 App 引擎完全不管（微信类 App 绝
    // 不能碰）。未开启但曾被管理过的 App 走到下面时 selected 为空，只做一件
    // 事：把此前锁过的权限全部恢复（见本轮末尾的恢复段）。
    for (NSString *bundle in config) {
        NSURL *home=Container(bundle); if (!home) continue;
        NSDictionary *groups=GroupHomes(bundle);
        NSArray *candidates= PrefixedCandidates(home,groups);
        NSString *mode = policies[bundle][@"mode"] ?: @"auto";
        BOOL cleanMode = [mode isEqual:@"clean"];
        NSArray *rawSelected = config[bundle];
        if (![rawSelected isKindOfClass:NSArray.class]) rawSelected = @[];
        BOOL optedIn = [appEnabled[bundle] boolValue];
        // 0.4.0 父目录优先、子条目忽略：已存选择里父子并存时，只保留父目录。
        NSMutableArray *effective = [NSMutableArray new];
        for (NSString *relative in rawSelected) {
            NSString *innerCheck = relative;
            if ([relative hasPrefix:@"Group/"]) {
                NSString *rest = [relative substringFromIndex:6];
                NSRange slash = [rest rangeOfString:@"/"];
                if (slash.location != NSNotFound) innerCheck = [rest substringFromIndex:slash.location + 1];
            }
            if (CKForbiddenPath(innerCheck)) continue;
            BOOL child = NO;
            for (NSString *other in rawSelected)
                if ([other isKindOfClass:NSString.class] && other.length < relative.length &&
                    [relative hasPrefix:[other stringByAppendingString:@"/"]]) { child = YES; break; }
            if (!child) [effective addObject:relative];
        }
        // 未开启的 App 选择集强制为空：不建基线、不锁、不删，只走恢复。
        NSArray *selected = optedIn ? effective : @[];
        NSString *signal = [[folder stringByAppendingPathComponent:@"Status"] stringByAppendingPathComponent:[bundle stringByAppendingString:@".background.plist"]];
        NSDictionary *lifecycle = [NSDictionary dictionaryWithContentsOfFile:signal];
        NSDate *background = lifecycle[@"time"];
        NSDate *launched = lifecycle[@"launched"];
        pid_t pid = [lifecycle[@"pid"] intValue];
        BOOL reportedProcessExited = pid > 1 && kill(pid, 0) == -1 && errno == ESRCH;
        id manager = SRead(NSClassFromString(@"SBApplicationController"), @"sharedInstance");
        SEL lookup = NSSelectorFromString(@"applicationWithBundleIdentifier:");
        id app = [manager respondsToSelector:lookup] ? ((id(*)(id,SEL,id))objc_msgSend)(manager,lookup,bundle) : nil;
        id state = SRead(app,@"processState") ?: SRead(app,@"_internalProcessState");
        SEL runningSelector = NSSelectorFromString(@"isRunning");
        BOOL stopped = [state respondsToSelector:runningSelector] && !((BOOL(*)(id,SEL))objc_msgSend)(state,runningSelector);
        BOOL justStopped = (stopped || reportedProcessExited) && [lastRunning[bundle] boolValue];
        if ([state respondsToSelector:runningSelector]) lastRunning[bundle] = @(!stopped);
        BOOL newBackground = background && ![background isEqual:lastBackground[bundle]];
        // A bounded retry catches files written after the initial background callback.
        BOOL retry = (background || stopped || reportedProcessExited) &&
            (!lastCleanup[bundle] || -[lastCleanup[bundle] timeIntervalSinceNow] >= 10);
        BOOL cleanup = newBackground || justStopped || retry;
        // 0.4.0 自动降级（三）：自动模式下，App 被限权后若反复“秒退”（启动不足
        // 10 秒、未退后台就直接结束，多为闪退），15 分钟内累计 3 次，把该 App 全部
        // 目录降级为只清理；已限权的目录会在本轮末尾的恢复环节自动还原原权限。
        if ([mode isEqual:@"auto"] && justStopped && launched &&
            (!background || [background compare:launched] == NSOrderedAscending) &&
            [NSDate.date timeIntervalSinceDate:launched] < 10) {
            NSMutableArray *events = [shortRuns[bundle] mutableCopy] ?: [NSMutableArray new];
            [events addObject:NSDate.date];
            NSDate *window = [NSDate dateWithTimeIntervalSinceNow:-900];
            [events filterUsingPredicate:[NSPredicate predicateWithFormat:@"SELF > %@", window]];
            shortRuns[bundle] = events;
            if (events.count >= 3) {
                for (NSString *relative in selected) {
                    NSString *innerPath = nil;
                    NSURL *dirHome = CKHomeForRelative(relative, home, groups, &innerPath);
                    if (!dirHome) continue;
                    NSString *path = [dirHome.path stringByAppendingPathComponent:innerPath];
                    if (!fallback[path][@"reason"]) {
                        fallback[path] = @{@"reason": @"应用反复秒退，已自动降级为只清理", @"time": NSDate.date};
                        fallbackDirty = YES;
                    }
                }
                [shortRuns removeObjectForKey:bundle];
            }
        }
        // 只禁止（lock）模式语义纯粹化：只限权、从不删文件；其余模式照常清扫。
        BOOL sweep = cleanup && ![mode isEqual:@"lock"];
        NSUInteger removed = 0;
        unsigned long long bytes = 0;
        BOOL attempted = NO;
        for (NSString *relative in selected) {
            if (![candidates containsObject:relative]) continue;
            NSString *inner = nil;
            NSURL *dirHome = CKHomeForRelative(relative, home, groups, &inner);
            if (!dirHome) continue;
            NSString *path = [dirHome.path stringByAppendingPathComponent:inner];
            struct stat info;
            if (lstat(path.fileSystemRepresentation, &info) || !S_ISDIR(info.st_mode)) continue;
            NSDictionary *record = previous[path];
            if ([record[@"inode"] unsignedLongLongValue] != info.st_ino ||
                [record[@"device"] unsignedLongLongValue] != info.st_dev) record = nil;
            NSDate *armed = record[@"armed"] ?: NSDate.date;
            NSDate *cutoff = record[@"cutoff"];
            if (!cutoff && [background compare:armed] == NSOrderedDescending) cutoff = background;
            if (!cutoff && record && (justStopped ||
                (reportedProcessExited && [launched compare:armed] == NSOrderedDescending))) cutoff = NSDate.date;
            NSMutableDictionary *next = [@{@"inode":@(info.st_ino),@"device":@(info.st_dev),@"armed":armed} mutableCopy];
            if (cutoff) {
                next[@"cutoff"] = cutoff;
                if (record[@"protectedRoot"]) next[@"protectedRoot"] = record[@"protectedRoot"];
                NSArray *locked = record[@"locked"];
                // 0.3.8 优化：无清理事件的轮询原来也每 2 秒全量重扫目录树只为重建锁定清单。
                // 清单上一轮已存进 baselines.plist，目录被限写后集合基本冻结，直接复用；
                // 有清理时必重扫，每 30 轮（约 1 分钟）兜底刷新一次，防清单漂移。
                BOOL refreshLocked = (applyPolls % 30 == 0);
                NSDictionary *fb = fallback[path];
                BOOL cleanDir = cleanMode || fb[@"reason"] != nil;
                if (!locked || cleanup || refreshLocked) {
                    NSUInteger removedBefore = removed;
                    BOOL protectedRoot = NO;
                    locked = CKBaselineDirectories(path,cutoff.timeIntervalSince1970,sweep,&removed,&bytes,&protectedRoot);
                    next[@"protectedRoot"] = @(protectedRoot);
                    attempted |= sweep;
                    // 0.4.0 自动降级（二）：目录明明处于限权状态，一轮清理却仍删到了
                    // 基线后新建的文件，说明 App 把权限改了回去（沙盒内属主可改自己
                    // 文件的权限，限权本质是软限制）。连续两轮如此，该目录降级为只清理。
                    if (!cleanDir && [mode isEqual:@"auto"] && sweep && removed > removedBefore) {
                        NSUInteger strikes = [fb[@"strikes"] unsignedIntegerValue] + 1;
                        if (strikes >= 2) {
                            fallback[path] = @{@"reason": @"限权后仍有新文件生成，已自动降级为只清理", @"time": NSDate.date};
                            fallbackDirty = YES; cleanDir = YES;
                        } else {
                            NSMutableDictionary *entry = [fb mutableCopy] ?: [NSMutableDictionary new];
                            entry[@"strikes"] = @(strikes); fallback[path] = entry; fallbackDirty = YES;
                        }
                    } else if (!cleanDir && [mode isEqual:@"auto"] && sweep && fb[@"strikes"]) {
                        NSMutableDictionary *entry = [fb mutableCopy];
                        [entry removeObjectForKey:@"strikes"]; fallback[path] = entry; fallbackDirty = YES;
                    }
                }
                next[@"locked"] = locked;
                if (!cleanDir) {
                    [enabled addObjectsFromArray:locked];
                    NSMutableArray *roots = lockRoots[bundle] ?: [NSMutableArray new];
                    if (![roots containsObject:path]) [roots addObject:path];
                    lockRoots[bundle] = roots;
                }
            }
            baselines[path] = next;
        }
        if (attempted) {
            lastCleanup[bundle] = NSDate.date;
            NSString *report = [[folder stringByAppendingPathComponent:@"Status"] stringByAppendingPathComponent:[bundle stringByAppendingString:@".auto.plist"]];
            NSDictionary *prior = [NSDictionary dictionaryWithContentsOfFile:report];
            [@{@"updated":NSDate.date,@"removed":@([prior[@"removed"] unsignedIntegerValue]+removed),
                @"bytes":@([prior[@"bytes"] unsignedLongLongValue]+bytes)} writeToFile:report atomically:YES];
        }
        if (background) lastBackground[bundle] = background;

    }
    NSDictionary *saved=[NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:@"permissions.plist"]];
    NSMutableArray *restore=[NSMutableArray array];
    for (NSString *path in saved) if (![enabled containsObject:path]) [restore addObject:path];
    if (![previous isEqual:baselines] && ![baselines writeToFile:baselinePath atomically:YES]) return;
    CKSetPaths(restore,NO); CKSetPaths(enabled,YES);
    // 0.4.0 自动降级（一）：限权后立刻复查根目录的属主写位；仍可写说明本轮限权
    // 没生效（改权限被拒或记录落盘失败），方法 2 对该目录不可行，登记降级，
    // 下一轮起自动只做事后清理。
    for (NSString *bundle in lockRoots) {
        if (![(policies[bundle][@"mode"] ?: @"auto") isEqual:@"auto"]) continue;
        for (NSString *path in lockRoots[bundle]) {
            if (fallback[path][@"reason"]) continue;
            // 0.4.4：根目录本身装有数据库/登录文件、按红线被排除出锁定清单的，
            // 不是限权失败——自动模式下直接转只清理并写明原因。
            if ([baselines[path][@"protectedRoot"] boolValue]) {
                fallback[path] = @{@"reason": @"目录含数据库/登录文件，按红线不锁定，已转只清理", @"time": NSDate.date};
                fallbackDirty = YES;
                continue;
            }
            struct stat info;
            if (!lstat(path.fileSystemRepresentation, &info) && S_ISDIR(info.st_mode) && (info.st_mode & S_IWUSR)) {
                fallback[path] = @{@"reason": @"写入限制未生效，已自动降级为只清理", @"time": NSDate.date};
                fallbackDirty = YES;
            }
        }
    }
    if (fallbackDirty) [fallback writeToFile:[folder stringByAppendingPathComponent:@"fallback.plist"] atomically:YES];
    CKProcessExtras();
}
