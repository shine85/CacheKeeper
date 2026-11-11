#import <Foundation/Foundation.h>
#import <objc/message.h>
#include <roothide.h>
#include <sys/stat.h>
#include <signal.h>
#include <errno.h>
#import "AxsCacheKeeperPolicy.h"
#import "AxsCacheKeeperSweep.h"
#import "AxsCacheKeeperDirectories.h"
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
static id SRead(id target,NSString *name) { SEL s=NSSelectorFromString(name);return [target respondsToSelector:s]?((id(*)(id,SEL))objc_msgSend)(target,s):nil; }
static NSURL *Container(NSString *bundle) {
    Class proxy=NSClassFromString(@"LSApplicationProxy"); SEL s=NSSelectorFromString(@"applicationProxyForIdentifier:");
    id app=[proxy respondsToSelector:s]?((id(*)(id,SEL,id))objc_msgSend)(proxy,s,bundle):nil;
    NSURL *home=SRead(app,@"dataContainerURL");
    if (![home isKindOfClass:NSURL.class]) return nil;
    home=home.URLByResolvingSymlinksInPath;
    return [home.path containsString:@"/Containers/Data/Application/"]?home:nil;
}

static BOOL axs_cachekeeper_structured_header(const unsigned char *data, size_t length) {
    if (length >= 16 && !memcmp(data, "SQLite format 3", 15) && data[15] == 0) return YES;
    if (length >= 8 && !memcmp(data, "bplist00", 8)) return YES;
    return NO;
}
// 单目录内容抽检：与清理引擎同一套判据（数据标记名、数据库头、媒体特征）。
// headerCap 限制文件头读取次数；超限或读失败的文件记为未查，定级时如实反映。
static NSDictionary *axs_cachekeeper_probe_directory(NSURL *root, NSTimeInterval deadline, NSUInteger headerCap, BOOL deep) {
    NSUInteger files = 0, data = 0, media = 0, other = 0, unchecked = 0, headers = 0, walked = 0;
    unsigned long long bytes = 0, largestBytes = 0;
    NSString *largest = @"";
    NSDate *newest = nil, *oldest = nil;
    __block BOOL complete = YES;
    NSDirectoryEnumerator *entries = [NSFileManager.defaultManager enumeratorAtURL:root includingPropertiesForKeys:nil options:0 errorHandler:^BOOL(NSURL *url, NSError *error){ complete = NO; return YES; }];
    for (NSURL *entry in entries) {
        if (NSProcessInfo.processInfo.systemUptime > deadline || ++walked > 100000) { complete = NO; break; }
        struct stat info;
        if (lstat(entry.path.fileSystemRepresentation, &info)) { complete = NO; continue; }
        if (S_ISLNK(info.st_mode)) continue;
        if (S_ISDIR(info.st_mode)) { if (axs_cachekeeper_data_marker(entry.lastPathComponent)) data++; continue; }
        if (!S_ISREG(info.st_mode)) continue;
        files++;
        bytes += (unsigned long long)info.st_size;
        if ((unsigned long long)info.st_size > largestBytes) { largestBytes = (unsigned long long)info.st_size; largest = entry.lastPathComponent; }
        NSDate *modified = [NSDate dateWithTimeIntervalSince1970:info.st_mtime];
        if (!newest || [modified compare:newest] == NSOrderedDescending) newest = modified;
        if (!oldest || [modified compare:oldest] == NSOrderedAscending) oldest = modified;
        if (axs_cachekeeper_data_marker(entry.lastPathComponent)) { data++; continue; }
        if (info.st_size <= 2) { other++; continue; }
        if (headers >= headerCap) { unchecked++; continue; }
        headers++;
        int fd = open(entry.path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
        if (fd < 0) { unchecked++; continue; }
        unsigned char buffer[16];
        ssize_t count = read(fd, buffer, sizeof(buffer));
        close(fd);
        if (count < 3) { unchecked++; continue; }
        if (axs_cachekeeper_structured_header(buffer, (size_t)count)) data++;
        else if (axs_cachekeeper_media_signature(buffer, (size_t)count)) media++;
        else other++;
    }
    if (!entries) complete = NO;
    NSDictionary *evidence = @{@"files":@(files), @"data":@(data), @"media":@(media), @"other":@(other),
        @"unchecked":@(unchecked), @"complete":@(complete && unchecked == 0), @"deep":@(deep),
        @"largest":largest, @"largestBytes":@(largestBytes),
        @"newest":newest ?: NSDate.distantPast, @"oldest":oldest ?: NSDate.distantPast};
    return @{@"evidence":evidence, @"bytes":@(bytes), @"complete":@(complete)};
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
    Class proxy=NSClassFromString(@"LSApplicationProxy");
    SEL lookup=NSSelectorFromString(@"applicationProxyForIdentifier:");
    id app=[proxy respondsToSelector:lookup] ? ((id(*)(id,SEL,id))objc_msgSend)(proxy,lookup,bundle) : nil;
    NSDictionary *groups=axs_cachekeeper_valid_group_homes(SRead(app,@"groupContainerURLs"));
    if (!batchItem) [NSFileManager.defaultManager removeItemAtPath:requestPath error:nil];
    busy=YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        NSError *directoryError=nil;
        NSArray *candidates=axs_cachekeeper_scan_targets(home,groups,&directoryError);
        NSMutableArray *rows=[NSMutableArray array];
        NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+15;
        NSUInteger remainingDirectories=candidates.count;
        for (NSDictionary *candidate in candidates) {
            NSString *relative=candidate[@"path"];
            // 把剩余时间分给其余目录，避免前面的巨大目录耗尽整次检测时间。
            NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
            NSTimeInterval directoryDeadline=now+MAX(0,deadline-now)/MAX((NSUInteger)1,remainingDirectories);
            remainingDirectories--;
            NSURL *root=candidate[@"root"];
            if (axs_cachekeeper_probe_eligible(relative)) {
                NSDictionary *probe=axs_cachekeeper_probe_directory(root,directoryDeadline,512,NO);
                [rows addObject:@{@"path":relative,@"bytes":probe[@"bytes"],@"complete":probe[@"complete"],@"manageable":@(![candidate[@"readOnly"] boolValue]),@"evidence":probe[@"evidence"]}];
                continue;
            }
            unsigned long long size=0; NSUInteger files=0; __block BOOL complete=YES;
            NSDirectoryEnumerator *entries=[NSFileManager.defaultManager enumeratorAtURL:root includingPropertiesForKeys:nil options:0 errorHandler:^BOOL(NSURL *url,NSError *error){complete=NO;return YES;}];
            for (NSURL *entry in entries) {
                if (NSProcessInfo.processInfo.systemUptime>directoryDeadline || ++files>100000) {complete=NO;break;}
                struct stat info;
                if (lstat(entry.path.fileSystemRepresentation,&info)) {complete=NO;continue;}
                if (S_ISLNK(info.st_mode)) continue;
                if (S_ISREG(info.st_mode)) size+=info.st_size;
            }
            if (!entries || NSProcessInfo.processInfo.systemUptime>directoryDeadline) complete=NO;
            [rows addObject:@{@"path":relative,@"bytes":@(size),@"complete":@(complete),@"manageable":@(![candidate[@"readOnly"] boolValue])}];
        }
        NSMutableDictionary *history=[[NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:@"snapshots.plist"]] mutableCopy]?:[NSMutableDictionary new];
        NSDictionary *old=history[bundle];
        NSMutableDictionary *groupPaths=[NSMutableDictionary new];
        for (NSString *identifier in groups) groupPaths[identifier]=[groups[identifier] path];
        // 保留最近四代检测结果，详情页据此给出纵向旁证（持续增长/长期无变化）。
        NSMutableArray *generations=[NSMutableArray new];
        [generations addObject:@{@"rows":rows,@"updated":NSDate.date}];
        if ([old[@"history"] isKindOfClass:NSArray.class]) for (id generation in old[@"history"]) {
            if (generations.count>=4) break;
            if ([generation isKindOfClass:NSDictionary.class]) [generations addObject:generation];
        }
        if (generations.count<2 && [old[@"rows"] isKindOfClass:NSArray.class])
            [generations addObject:@{@"rows":old[@"rows"],@"updated":[old[@"updated"] isKindOfClass:NSDate.class] ? old[@"updated"] : NSDate.date}];
        NSDictionary *result=@{@"token":token,@"bundle":bundle,@"home":home.path?:@"",@"groups":groupPaths,@"rows":rows,@"updated":NSDate.date,@"history":generations,@"previousRows":generations.count>1 ? generations[1][@"rows"] : @[],
            @"error":home ? (directoryError.localizedDescription ?: @"") : @"此 APP 没有可读取的标准数据容器"};
        history[bundle]=result;
        [history writeToFile:[folder stringByAppendingPathComponent:@"snapshots.plist"] atomically:YES];
        if (!batchItem) [result writeToFile:[folder stringByAppendingPathComponent:@"scan.plist"] atomically:YES];
        dispatch_async(dispatch_get_main_queue(),^{
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
typedef NS_ENUM(NSInteger, AxsCacheKeeperProcessState) {
    AxsCacheKeeperProcessUnknown, AxsCacheKeeperProcessRunning, AxsCacheKeeperProcessStopped
};
static NSMutableSet<NSString *> *axs_cachekeeper_manual;
static AxsCacheKeeperProcessState axs_cachekeeper_process(NSString *bundle) {
    id manager = SRead(NSClassFromString(@"SBApplicationController"), @"sharedInstance");
    SEL lookup = NSSelectorFromString(@"applicationWithBundleIdentifier:");
    id app = [manager respondsToSelector:lookup] ? ((id(*)(id,SEL,id))objc_msgSend)(manager,lookup,bundle) : nil;
    id state = SRead(app,@"processState") ?: SRead(app,@"_internalProcessState");
    SEL running = NSSelectorFromString(@"isRunning");
    if (![state respondsToSelector:running]) return AxsCacheKeeperProcessUnknown;
    return ((BOOL(*)(id,SEL))objc_msgSend)(state,running) ? AxsCacheKeeperProcessRunning : AxsCacheKeeperProcessStopped;
}
static NSString *axs_cachekeeper_folder(void) { return jbroot(@"/var/mobile/Library/CacheKeeper"); }
static void axs_cachekeeper_report(NSString *bundle, NSString *phase, NSString *message,
                                  NSUInteger removed, unsigned long long bytes, NSUInteger failed, NSArray *effectivePaths, NSArray *discoveredPaths) {
    // 主线程快捷操作与清理队列共享同一个原子读改写区，避免累计量丢失。
    @synchronized (AxsCacheKeeperSweep.class) {
        NSString *path = [[axs_cachekeeper_folder() stringByAppendingPathComponent:@"Status"]
            stringByAppendingPathComponent:[bundle stringByAppendingString:@".auto.plist"]];
        NSDictionary *previous = [NSDictionary dictionaryWithContentsOfFile:path];
        NSArray *known=discoveredPaths ?: (previous[@"discoveredPaths"] ?: @[]);
        if (!removed && !bytes && [previous[@"phase"] isEqual:phase] && [previous[@"message"] isEqual:message] &&
            [previous[@"failed"] unsignedIntegerValue] == failed && [previous[@"effectivePaths"] isEqual:effectivePaths] &&
            [previous[@"discoveredPaths"] isEqual:known]) return;
        NSDictionary *report = @{@"updated":NSDate.date, @"phase":phase, @"message":message,
            @"removed":@([previous[@"removed"] unsignedIntegerValue]+removed),
            @"bytes":@([previous[@"bytes"] unsignedLongLongValue]+bytes), @"failed":@(failed),
            @"effectivePaths":effectivePaths ?: @[], @"discoveredPaths":known};
        if (![report writeToFile:path atomically:YES]) NSLog(@"[CacheKeeper] 无法保存 %@ 清理状态", bundle);
    }
}
static NSString *axs_cachekeeper_network_status(NSString *bundle) {
    NSString *path = [[axs_cachekeeper_folder() stringByAppendingPathComponent:@"Status"]
        stringByAppendingPathComponent:[bundle stringByAppendingString:@".network.plist"]];
    NSDictionary *report = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![report isKindOfClass:NSDictionary.class]) return @"尚无进程内网络缓存回执；请重新打开 APP 检查注入";
    NSString *message = [report[@"message"] isKindOfClass:NSString.class] ? report[@"message"] : @"回执格式不完整";
    return [NSString stringWithFormat:@"网络缓存回执：%@（%@）", message, report[@"updated"] ?: @"时间未知"];
}
void axs_cachekeeper_request_cleanup(NSString *bundle) {
    if (!axs_cachekeeper_bundle_id(bundle)) return;
    NSDictionary *selection = [NSDictionary dictionaryWithContentsOfFile:[axs_cachekeeper_folder() stringByAppendingPathComponent:@"directories.plist"]];
    NSDictionary *states = [NSDictionary dictionaryWithContentsOfFile:[axs_cachekeeper_folder() stringByAppendingPathComponent:@"appEnabled.plist"]];
    if (!axs_cachekeeper_app_enabled(states[bundle])) return;
    if ([axs_cachekeeper_mode(states[bundle]) isEqual:@"prevent"]) {
        axs_cachekeeper_report(bundle, @"prevent", @"当前为只禁止模式，不删除缓存文件", 0, 0, 0, @[], nil); return;
    }
    NSDictionary *snapshots = [NSDictionary dictionaryWithContentsOfFile:[axs_cachekeeper_folder() stringByAppendingPathComponent:@"snapshots.plist"]];
    if (!axs_cachekeeper_can_clean_tiered(selection,states,bundle,snapshots[bundle][@"rows"])) return;
    if (!axs_cachekeeper_manual) axs_cachekeeper_manual = [NSMutableSet new];
    if (axs_cachekeeper_process(bundle) != AxsCacheKeeperProcessStopped) {
        axs_cachekeeper_report(bundle, @"waiting", @"请先完全退出 APP 后再试；若刚退出请稍等片刻。状态未知时不清理", 0, 0, 0, @[], nil); return;
    }
    [axs_cachekeeper_manual addObject:bundle];
}
void CKApplyDirectorySwitches(void) {
    static BOOL busy;
    static dispatch_queue_t queue;
    static NSMutableDictionary *jobs, *finished, *discovery;
    if (busy) return;
    if (!queue) {
        queue = dispatch_queue_create("dev.local.cachekeeper.cleanup", DISPATCH_QUEUE_SERIAL);
        jobs = [NSMutableDictionary new]; finished = [NSMutableDictionary new]; discovery = [NSMutableDictionary new];
    }
    NSString *folder = axs_cachekeeper_folder();
    NSString *selectionFile = [folder stringByAppendingPathComponent:@"directories.plist"];
    NSString *stateFile = [folder stringByAppendingPathComponent:@"appEnabled.plist"];
    NSDictionary *selection = [NSDictionary dictionaryWithContentsOfFile:selectionFile];
    NSDictionary *states = [NSDictionary dictionaryWithContentsOfFile:stateFile];
    if ((!selection && [NSFileManager.defaultManager fileExistsAtPath:selectionFile]) ||
        (!states && [NSFileManager.defaultManager fileExistsAtPath:stateFile])) {
        NSLog(@"[CacheKeeper] 用户配置不可读，停止本轮处理"); return;
    }
    NSDictionary *snapshots = [NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:@"snapshots.plist"]];
    NSDictionary *quarantine = [NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:@"quarantine.plist"]];
    NSMutableSet *bundles = [NSMutableSet setWithArray:selection.allKeys ?: @[]];
    [bundles addObjectsFromArray:states.allKeys ?: @[]];
    [bundles addObjectsFromArray:axs_cachekeeper_manual.allObjects ?: @[]];
    NSMutableDictionary *targets = [NSMutableDictionary new];
    for (NSString *bundle in bundles) {
        if (!axs_cachekeeper_bundle_id(bundle)) continue;
        if (!axs_cachekeeper_app_enabled(states[bundle])) { [axs_cachekeeper_manual removeObject:bundle];continue; }
        NSArray *selected = axs_cachekeeper_selected_paths_tiered(selection, states, bundle, snapshots[bundle][@"rows"]);
        NSMutableArray *activeSelected = [NSMutableArray new];
        for (NSString *path in selected) if (!axs_cachekeeper_quarantine_active(quarantine, bundle, path)) [activeSelected addObject:path];
        selected = activeSelected;
        BOOL manual = [axs_cachekeeper_manual containsObject:bundle];
        NSString *mode = axs_cachekeeper_mode(states[bundle]);
        NSArray *paths = selected;
        NSURL *home = Container(bundle);
        NSMutableArray *roots = [NSMutableArray new];
        if (home) for (NSString *relative in paths) [roots addObject:[home.path stringByAppendingPathComponent:relative]];
        targets[bundle] = @{@"roots":roots, @"paths":paths, @"home":home.path ?: @"", @"mode":mode,
            @"manual":@(manual), @"process":@(axs_cachekeeper_process(bundle))};
    }
    busy = YES;
    dispatch_async(queue, ^{
        NSDictionary *restored = axs_cachekeeper_restore_paths(nil, [folder stringByAppendingPathComponent:@"permissions.plist"]);
        for (NSString *bundle in jobs.allKeys) if (!targets[bundle]) [jobs removeObjectForKey:bundle];
        for (NSString *bundle in finished.allKeys) if (!targets[bundle]) [finished removeObjectForKey:bundle];
        for (NSString *bundle in discovery.allKeys) if (!targets[bundle]) [discovery removeObjectForKey:bundle];
        for (NSString *bundle in targets) {
            NSDictionary *target = targets[bundle];
            NSArray *roots = target[@"roots"], *paths = target[@"paths"];
            BOOL manual = [target[@"manual"] boolValue];
            NSString *mode = target[@"mode"];
            if ([restored[@"failed"] unsignedIntegerValue]) {
                axs_cachekeeper_report(bundle, @"error", restored[@"error"], 0, 0, [restored[@"failed"] unsignedIntegerValue], paths, nil);
                continue;
            }
            if ([mode isEqual:@"prevent"]) {
                [jobs removeObjectForKey:bundle]; [finished removeObjectForKey:bundle];
                NSString *network=axs_cachekeeper_url_cache_enabled(states[bundle]) ? axs_cachekeeper_network_status(bundle) : @"网络缓存开关已关闭，当前不执行缓存干预";
                axs_cachekeeper_report(bundle, @"prevent", [@"只禁止模式，不清理文件。\n" stringByAppendingString:network], 0, 0, 0, paths, nil);
                if (manual) dispatch_async(dispatch_get_main_queue(), ^{ [axs_cachekeeper_manual removeObject:bundle]; });
                continue;
            }
            if (![target[@"home"] length]) { axs_cachekeeper_report(bundle, @"error", @"无法解析 APP 数据容器", 0, 0, 1, paths, nil); continue; }
            if ([target[@"process"] integerValue] != AxsCacheKeeperProcessStopped) {
                [jobs removeObjectForKey:bundle]; [finished removeObjectForKey:bundle];
                NSString *message = [target[@"process"] integerValue] == AxsCacheKeeperProcessUnknown ? @"无法确认进程状态，暂不删除文件；请打开一次该 APP 再完全退出，然后等待下轮检查" : @"APP 运行中；完全退出后清理超过 60 秒的普通缓存";
                if ([mode isEqual:@"auto"] && axs_cachekeeper_url_cache_enabled(states[bundle])) message = [message stringByAppendingFormat:@"\n%@", axs_cachekeeper_network_status(bundle)];
                axs_cachekeeper_report(bundle, @"waiting", message, 0, 0, 0, paths, nil); continue;
            }
            NSArray *discovered=@[];
            NSString *discoveryError=@"";
            if (axs_cachekeeper_auto_discover(states[bundle])) {
                NSDictionary *known=discovery[bundle];
                NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
                if (![known[@"home"] isEqual:target[@"home"]] || now-[known[@"time"] doubleValue]>=30) {
                    NSError *error=nil;
                    NSArray *found=axs_cachekeeper_discover_cache_roots([NSURL fileURLWithPath:target[@"home"]],&error);
                    known=@{@"home":target[@"home"],@"time":@(now),@"paths":found,@"error":error.localizedDescription ?: @""};
                    discovery[bundle]=known;
                }
                discovered=known[@"paths"];discoveryError=known[@"error"];
            } else [discovery removeObjectForKey:bundle];
            paths=axs_cachekeeper_effective_paths(selection[bundle],states[bundle],discovered);
            NSMutableArray *effectiveRoots=[NSMutableArray new];
            for (NSString *relative in paths) [effectiveRoots addObject:[target[@"home"] stringByAppendingPathComponent:relative]];
            roots=effectiveRoots;
            if (!paths.count) {
                [jobs removeObjectForKey:bundle];[finished removeObjectForKey:bundle];
                NSString *message=discoveryError.length ? discoveryError : @"没有可处理的缓存目录；已尊重手动排除，网络限制按独立选项执行";
                axs_cachekeeper_report(bundle,@"waiting",message,0,0,discoveryError.length ? 1 : 0,@[],axs_cachekeeper_auto_discover(states[bundle]) ? discovered : nil);continue;
            }
            NSString *signature = [NSString stringWithFormat:@"%@\n%@", [roots componentsJoinedByString:@"\n"], mode];
            NSDictionary *done = finished[bundle];
            if (!manual && [done[@"signature"] isEqual:signature] && -[done[@"time"] timeIntervalSinceNow] < 30) continue;
            NSMutableDictionary *job = jobs[bundle];
            if (![job[@"signature"] isEqual:signature]) {
                NSMutableArray *sweeps = [NSMutableArray new];
                for (NSString *root in roots) {
                    struct stat info;
                    if (lstat(root.fileSystemRepresentation, &info) && errno == ENOENT) continue;
                    [sweeps addObject:[[AxsCacheKeeperSweep alloc] initWithRoot:root]];
                }
                job = [@{@"signature":signature, @"sweeps":sweeps, @"removed":@0, @"bytes":@0} mutableCopy];
                jobs[bundle] = job;
            }
            BOOL (^shouldContinue)(void) = ^BOOL {
                __block BOOL allowed = NO;
                dispatch_sync(dispatch_get_main_queue(), ^{
                    NSDictionary *currentSelection = [NSDictionary dictionaryWithContentsOfFile:selectionFile];
                    NSDictionary *currentStates = [NSDictionary dictionaryWithContentsOfFile:stateFile];
                    BOOL readable = (currentSelection || ![NSFileManager.defaultManager fileExistsAtPath:selectionFile]) &&
                        (currentStates || ![NSFileManager.defaultManager fileExistsAtPath:stateFile]);
                    NSMutableSet *extraNow = [axs_cachekeeper_cachelike_paths(snapshots[bundle][@"rows"]) mutableCopy];
                    [extraNow addObjectsFromArray:axs_cachekeeper_judged_paths(currentStates[bundle])];
                    NSDictionary *quarantineNow = [NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:@"quarantine.plist"]];
                    NSMutableArray *filteredNow = [NSMutableArray new];
                    for (NSString *path in axs_cachekeeper_effective_paths_tiered(currentSelection[bundle],currentStates[bundle],discovered,extraNow))
                        if (!axs_cachekeeper_quarantine_active(quarantineNow,bundle,path)) [filteredNow addObject:path];
                    NSArray *currentPaths = filteredNow;
                    BOOL selected = [currentPaths isEqual:paths] && [axs_cachekeeper_mode(currentStates[bundle]) isEqual:mode];
                    allowed = readable && selected && currentPaths.count && axs_cachekeeper_wants_cleanup(currentStates[bundle]) && [Container(bundle).path isEqual:target[@"home"]] &&
                        axs_cachekeeper_process(bundle) == AxsCacheKeeperProcessStopped;
                });
                return allowed;
            };
            NSUInteger removed = 0, failures = 0, protectedCount = 0, recentCount = 0, inspected = 0, changedCount = 0;
            unsigned long long bytes = 0;
            BOOL complete = YES, cancelled = NO, checking = NO;
            NSString *error = @"";
            for (AxsCacheKeeperSweep *sweep in job[@"sweeps"]) {
                if (!cancelled) [sweep advance:256 shouldContinue:shouldContinue];
                removed += sweep.removed; bytes += sweep.bytes; failures += sweep.failed;
                protectedCount += sweep.protectedCount; recentCount += sweep.recentCount;
                inspected += sweep.inspected; checking |= sweep.checking && !sweep.complete;
                changedCount += sweep.changedCount;
                complete &= sweep.complete; cancelled |= sweep.cancelled;
                if (sweep.error.length) error = sweep.error;
            }
            NSUInteger deltaRemoved = removed-[job[@"removed"] unsignedIntegerValue];
            unsigned long long deltaBytes = bytes-[job[@"bytes"] unsignedLongLongValue];
            job[@"removed"] = @(removed); job[@"bytes"] = @(bytes);
            NSString *phase = @"cleaning", *message = @"正在分批清理；无需重新检测目录";
            if (checking) message=[NSString stringWithFormat:@"正在检查数据目录，已检查 %lu 项；预检完成后才删除",(unsigned long)inspected];
            if (cancelled) {
                phase = @"waiting"; message = @"APP 重新运行或配置改变，已停止清理"; [jobs removeObjectForKey:bundle];
            } else if (complete) {
                phase = failures ? @"error" : @"complete";
                message = failures ? [@"本轮未全部完成：" stringByAppendingString:error] :
                    [NSString stringWithFormat:@"本轮检查完成；保留 %lu 项受保护/未知内容、%lu 项近期文件", (unsigned long)protectedCount, (unsigned long)recentCount];
                if (changedCount) message=[message stringByAppendingFormat:@"；%lu 个目录在预检后变化，已跳过等待下轮",(unsigned long)changedCount];
                if ([mode isEqual:@"auto"] && axs_cachekeeper_url_cache_enabled(states[bundle])) message = [message stringByAppendingFormat:@"\n%@", axs_cachekeeper_network_status(bundle)];
                finished[bundle] = @{@"signature":signature, @"time":NSDate.date};
                [jobs removeObjectForKey:bundle];
            }
            if (axs_cachekeeper_auto_discover(states[bundle])) message=[message stringByAppendingFormat:@"\n自动识别已纳入 %lu 个缓存根（手动排除保持关闭）",(unsigned long)paths.count];
            if (discoveryError.length) message=[message stringByAppendingFormat:@"\n%@",discoveryError];
            axs_cachekeeper_report(bundle, phase, message, deltaRemoved, deltaBytes, failures, paths, axs_cachekeeper_auto_discover(states[bundle]) ? discovered : nil);
            if (manual && (complete || cancelled)) dispatch_async(dispatch_get_main_queue(), ^{ [axs_cachekeeper_manual removeObject:bundle]; });
        }
        dispatch_async(dispatch_get_main_queue(), ^{ busy = NO; });
    });
}

static NSString *axs_cachekeeper_quarantine_suffix(NSString *token) {
    NSMutableString *suffix = [NSMutableString new];
    for (NSUInteger i = 0; i < token.length && suffix.length < 8; i++) {
        unichar c = [token characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) [suffix appendFormat:@"%C", c];
    }
    return suffix.length ? suffix : @"x";
}
static void axs_cachekeeper_quarantine_store(NSString *folder, NSString *bundle, NSString *path, NSDictionary *entry) {
    NSString *file = [folder stringByAppendingPathComponent:@"quarantine.plist"];
    NSMutableDictionary *all = [[NSDictionary dictionaryWithContentsOfFile:file] mutableCopy] ?: [NSMutableDictionary new];
    NSMutableDictionary *perApp = [all[bundle] mutableCopy] ?: [NSMutableDictionary new];
    if (entry) perApp[path] = entry; else [perApp removeObjectForKey:path];
    if (perApp.count) all[bundle] = perApp; else [all removeObjectForKey:bundle];
    [all writeToFile:file atomically:YES];
}
// 深度检测：对单个未知/混合目录做全量核查（不设文件头上限），结果回写快照行。
void CKDeepRequests(void) {
    static BOOL busy;
    if (busy) return;
    NSString *folder = axs_cachekeeper_folder();
    NSString *requestPath = [folder stringByAppendingPathComponent:@"deep-request.plist"];
    NSDictionary *request = [NSDictionary dictionaryWithContentsOfFile:requestPath];
    if (!request) return;
    NSString *bundle = request[@"bundle"], *path = request[@"path"], *token = request[@"token"];
    [NSFileManager.defaultManager removeItemAtPath:requestPath error:nil];
    if (!axs_cachekeeper_bundle_id(bundle) || !axs_cachekeeper_probe_eligible(path) ||
        ![token isKindOfClass:NSString.class] || !token.length) return;
    busy = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *error = @"";
        NSURL *home = Container(bundle);
        if (!home) error = @"无法解析 APP 数据容器";
        else {
            NSDictionary *probe = axs_cachekeeper_probe_directory([home URLByAppendingPathComponent:path],
                NSProcessInfo.processInfo.systemUptime + 60, NSUIntegerMax, YES);
            NSString *snapPath = [folder stringByAppendingPathComponent:@"snapshots.plist"];
            NSMutableDictionary *snapshots = [[NSDictionary dictionaryWithContentsOfFile:snapPath] mutableCopy] ?: [NSMutableDictionary new];
            NSMutableDictionary *entry = [snapshots[bundle] mutableCopy];
            BOOL updated = NO;
            if (entry) {
                NSMutableArray *rows = [NSMutableArray new];
                for (NSDictionary *row in entry[@"rows"]) {
                    if ([row[@"path"] isEqual:path]) {
                        NSMutableDictionary *copy = [row mutableCopy];
                        copy[@"bytes"] = probe[@"bytes"]; copy[@"complete"] = probe[@"complete"]; copy[@"evidence"] = probe[@"evidence"];
                        [rows addObject:copy]; updated = YES;
                    } else [rows addObject:row];
                }
                if (updated) { entry[@"rows"] = rows; snapshots[bundle] = entry; [snapshots writeToFile:snapPath atomically:YES]; }
            }
            if (!updated) error = @"尚无该目录的检测记录，请先点“检测目录”";
        }
        [@{@"token":token, @"bundle":bundle, @"path":path, @"error":error} writeToFile:[folder stringByAppendingPathComponent:@"deep-result.plist"] atomically:YES];
        dispatch_async(dispatch_get_main_queue(), ^{ busy = NO; });
    });
}
// 隔离测试：APP 完全退出时把目录改名留置、同名空目录占位；恢复时原样换回，再生内容另存待用户处置。
void CKQuarantineRequests(void) {
    static BOOL busy;
    if (busy) return;
    NSString *folder = axs_cachekeeper_folder();
    NSString *requestPath = [folder stringByAppendingPathComponent:@"quarantine-request.plist"];
    NSDictionary *request = [NSDictionary dictionaryWithContentsOfFile:requestPath];
    if (!request) return;
    NSString *bundle = request[@"bundle"], *path = request[@"path"], *action = request[@"action"], *token = request[@"token"];
    [NSFileManager.defaultManager removeItemAtPath:requestPath error:nil];
    if (!axs_cachekeeper_bundle_id(bundle) || !axs_cachekeeper_probe_eligible(path) ||
        ![token isKindOfClass:NSString.class] || !token.length ||
        ![@[@"quarantine", @"restore", @"purge", @"purgeRegenerated"] containsObject:action]) return;
    busy = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *error = @"";
        NSDictionary *quarantine = [NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:@"quarantine.plist"]];
        NSDictionary *entry = axs_cachekeeper_quarantine_entry(quarantine, bundle, path);
        NSURL *home = Container(bundle);
        NSFileManager *fm = NSFileManager.defaultManager;
        if (!home) error = @"无法解析 APP 数据容器";
        else if (![action isEqual:@"quarantine"] && !entry) error = @"没有该目录的隔离记录";
        else if (axs_cachekeeper_process(bundle) != AxsCacheKeeperProcessStopped) error = @"APP 未完全退出；请完全退出后重试";
        else if ([action isEqual:@"quarantine"]) {
            if ([entry[@"status"] isEqual:@"active"]) error = @"该目录已在隔离中";
            else {
                NSURL *original = [home URLByAppendingPathComponent:path];
                struct stat info;
                if (lstat(original.path.fileSystemRepresentation, &info) || !S_ISDIR(info.st_mode) || S_ISLNK(info.st_mode)) error = @"原目录不存在或不是普通目录";
                else {
                    NSString *holdingRel = [path stringByAppendingFormat:@".ckq-%@", axs_cachekeeper_quarantine_suffix(token)];
                    NSURL *holding = [home URLByAppendingPathComponent:holdingRel];
                    NSError *moveError = nil;
                    if (![fm moveItemAtURL:original toURL:holding error:&moveError]) error = [NSString stringWithFormat:@"隔离改名失败：%@", moveError.localizedDescription ?: @"未知错误"];
                    else {
                        mode_t mode = info.st_mode & 07777;
                        NSError *createError = nil;
                        if (![fm createDirectoryAtURL:original withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@(mode)} error:&createError]) {
                            [fm moveItemAtURL:holding toURL:original error:nil];
                            error = [NSString stringWithFormat:@"重建空目录失败，已回滚隔离：%@", createError.localizedDescription ?: @"未知错误"];
                        } else axs_cachekeeper_quarantine_store(folder, bundle, path, @{@"status":@"active", @"holding":holdingRel, @"since":NSDate.date, @"mode":@(mode)});
                    }
                }
            }
        } else if ([action isEqual:@"restore"]) {
            if (![entry[@"status"] isEqual:@"active"]) error = @"该目录不在隔离中";
            else {
                NSURL *original = [home URLByAppendingPathComponent:path];
                NSURL *holding = [home URLByAppendingPathComponent:entry[@"holding"]];
                NSString *regenRel = [path stringByAppendingFormat:@".ckr-%@", axs_cachekeeper_quarantine_suffix(token)];
                NSURL *regen = [home URLByAppendingPathComponent:regenRel];
                NSError *moveError = nil;
                BOOL currentExists = [fm fileExistsAtPath:original.path];
                if (currentExists && ![fm moveItemAtURL:original toURL:regen error:&moveError]) error = [NSString stringWithFormat:@"挪开当前目录失败：%@", moveError.localizedDescription ?: @"未知错误"];
                else if (![fm moveItemAtURL:holding toURL:original error:&moveError]) {
                    if (currentExists) [fm moveItemAtURL:regen toURL:original error:nil];
                    error = [NSString stringWithFormat:@"恢复隔离内容失败：%@", moveError.localizedDescription ?: @"未知错误"];
                } else {
                    NSMutableDictionary *updated = [entry mutableCopy];
                    updated[@"status"] = @"restored"; updated[@"holding"] = @"";
                    if (currentExists) updated[@"regenerated"] = regenRel; else [updated removeObjectForKey:@"regenerated"];
                    updated[@"restoredAt"] = NSDate.date;
                    axs_cachekeeper_quarantine_store(folder, bundle, path, updated);
                }
            }
        } else if ([action isEqual:@"purge"]) {
            if (![entry[@"status"] isEqual:@"active"]) error = @"该目录不在隔离中";
            else {
                NSURL *holding = [home URLByAppendingPathComponent:entry[@"holding"]];
                NSError *removeError = nil;
                if ([fm fileExistsAtPath:holding.path] && ![fm removeItemAtURL:holding error:&removeError]) error = [NSString stringWithFormat:@"删除隔离内容失败：%@", removeError.localizedDescription ?: @"未知错误"];
                else axs_cachekeeper_quarantine_store(folder, bundle, path, nil);
            }
        } else if ([action isEqual:@"purgeRegenerated"]) {
            NSString *regenRel = entry[@"regenerated"];
            if (![regenRel isKindOfClass:NSString.class] || ![regenRel length]) error = @"没有待处理的再生副本";
            else {
                NSURL *regen = [home URLByAppendingPathComponent:regenRel];
                NSError *removeError = nil;
                if ([fm fileExistsAtPath:regen.path] && ![fm removeItemAtURL:regen error:&removeError]) error = [NSString stringWithFormat:@"删除再生副本失败：%@", removeError.localizedDescription ?: @"未知错误"];
                else axs_cachekeeper_quarantine_store(folder, bundle, path, nil);
            }
        }
        [@{@"token":token, @"bundle":bundle, @"path":path, @"action":action, @"error":error} writeToFile:[folder stringByAppendingPathComponent:@"quarantine-result.plist"] atomically:YES];
        dispatch_async(dispatch_get_main_queue(), ^{ busy = NO; });
    });
}
