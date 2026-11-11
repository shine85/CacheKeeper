#import <Foundation/Foundation.h>
#import <objc/message.h>
#include <roothide.h>
#include <sys/stat.h>
#include <signal.h>
#include <errno.h>
#import "AxsCacheKeeperPolicy.h"
#import "AxsCacheKeeperSweep.h"
#import "AxsCacheKeeperDirectories.h"
#import "AxsCacheKeeperProcess.h"
#import "AxsCacheKeeperInspection.h"
static id SRead(id target,NSString *name) { SEL s=NSSelectorFromString(name);return [target respondsToSelector:s]?((id(*)(id,SEL))objc_msgSend)(target,s):nil; }
static NSURL *Container(NSString *bundle) {
    Class proxy=NSClassFromString(@"LSApplicationProxy"); SEL s=NSSelectorFromString(@"applicationProxyForIdentifier:");
    id app=[proxy respondsToSelector:s]?((id(*)(id,SEL,id))objc_msgSend)(proxy,s,bundle):nil;
    NSURL *home=SRead(app,@"dataContainerURL");
    if (![home isKindOfClass:NSURL.class]) return nil;
    home=home.URLByResolvingSymlinksInPath;
    return [home.path containsString:@"/Containers/Data/Application/"]?home:nil;
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
    if (!axs_cachekeeper_bundle_id(bundle) || ![token isKindOfClass:NSString.class] || !token.length) return;
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
        NSMutableDictionary *result=[@{@"token":token,@"bundle":bundle,@"home":home.path?:@"",@"groups":groupPaths,@"rows":rows,@"updated":NSDate.date,@"previousRows":old[@"rows"]?:@[],@"recentScans":axs_cachekeeper_recent_scans(old),
            @"error":home ? (directoryError.localizedDescription ?: @"") : @"此 APP 没有可读取的标准数据容器"} mutableCopy];
        history[bundle]=result;
        NSError *saveError=nil;
        if (![history writeToURL:[NSURL fileURLWithPath:[folder stringByAppendingPathComponent:@"snapshots.plist"]] error:&saveError]) {
            result[@"error"]=[NSString stringWithFormat:@"%@\n检测结果未能持久保存：%@（%@/%ld）。检查配置目录可写性后重试。",result[@"error"],saveError.localizedDescription,saveError.domain,(long)saveError.code];
            NSLog(@"[CacheKeeper] %@",result[@"error"]);
        }
        if (!batchItem && ![result writeToURL:[NSURL fileURLWithPath:[folder stringByAppendingPathComponent:@"scan.plist"]] error:&saveError]) NSLog(@"[CacheKeeper] 检测回执写入失败：%@",saveError);
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
void CKInspectRequests(void) {
    static BOOL busy;static NSString *lastToken;
    if (busy) return;
    NSString *folder=jbroot(@"/var/mobile/Library/CacheKeeper");
    NSString *file=[folder stringByAppendingPathComponent:@"inspectionRequest.plist"];
    NSDictionary *request=[NSDictionary dictionaryWithContentsOfFile:file];
    NSString *bundle=request[@"bundle"],*relative=request[@"path"],*token=request[@"token"];
    if (!axs_cachekeeper_bundle_id(bundle) || !axs_cachekeeper_relative_path(relative) ||
        ![token isKindOfClass:NSString.class] || !token.length || [token isEqual:lastToken]) return;
    // 每次由系统重新解析容器，不信任面板传入绝对路径或旧快照路径。
    NSURL *home=Container(bundle);
    id proxyClass=NSClassFromString(@"LSApplicationProxy");SEL lookup=NSSelectorFromString(@"applicationProxyForIdentifier:");
    id app=[proxyClass respondsToSelector:lookup] ? ((id(*)(id,SEL,id))objc_msgSend)(proxyClass,lookup,bundle) : nil;
    NSDictionary *groups=axs_cachekeeper_valid_group_homes(SRead(app,@"groupContainerURLs"));
    busy=YES;lastToken=[token copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        NSString *output=[folder stringByAppendingPathComponent:[NSString stringWithFormat:@"Status/%@.inspection.plist",bundle]];
        NSMutableDictionary *saved=[[[NSDictionary dictionaryWithContentsOfFile:output] objectForKey:@"reports"] mutableCopy] ?: [NSMutableDictionary new];
        NSError *error=nil;NSURL *root=nil;
        for (NSDictionary *target in ([request[@"cancel"] boolValue] ? @[] : axs_cachekeeper_scan_targets(home,groups,&error)))
            if ([target[@"path"] isEqual:relative]) { root=target[@"root"];break; }
        AxsCacheKeeperInspection *inspection=root ? [[AxsCacheKeeperInspection alloc] initWithRoot:root.path] : nil;
        NSTimeInterval written=0;
        while (YES) {
            @autoreleasepool {
                NSDictionary *current=[NSDictionary dictionaryWithContentsOfFile:file];
                BOOL cancelled=![current[@"token"] isEqual:token] || [current[@"cancel"] boolValue];
                if (!cancelled) [inspection advance:256];
                BOOL done=!inspection || inspection.complete || cancelled;
                NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
                if (done || now-written>=1) {
                    NSMutableDictionary *report=inspection ? [[inspection report] mutableCopy] : [@{@"complete":@(!cancelled),@"coverageComplete":@NO,@"error":cancelled ? @"" : (error.localizedDescription ?: @"目录已消失、被保护或不属于此 APP 的可见父目录")} mutableCopy];
                    report[@"token"]=token;report[@"bundle"]=bundle;report[@"path"]=relative;report[@"cancelled"]=@(cancelled);report[@"updated"]=NSDate.date;
                    saved[relative]=report;
                    if (![@{@"reports":saved} writeToURL:[NSURL fileURLWithPath:output] error:&error]) { NSLog(@"[CacheKeeper] 深度档案写入失败：%@",error);break; }
                    written=now;
                }
                if (done) break;
            }
        }
        dispatch_async(dispatch_get_main_queue(),^{busy=NO;});
    });
}
static NSMutableSet<NSString *> *axs_cachekeeper_manual;
static AxsCacheKeeperProcessState axs_cachekeeper_process(NSString *bundle, NSString **reason) {
    id manager = SRead(NSClassFromString(@"FBProcessManager"), @"sharedInstance");
    return axs_cachekeeper_process_state(manager,bundle,reason);
}
static NSString *axs_cachekeeper_folder(void) { return jbroot(@"/var/mobile/Library/CacheKeeper"); }
static void axs_cachekeeper_report(NSString *bundle, NSString *phase, NSString *message,
                                  NSUInteger removed, unsigned long long bytes, NSUInteger failed, NSArray *effectivePaths, NSArray *discoveredPaths, NSDictionary *directories) {
    // 主线程快捷操作与清理队列共享同一个原子读改写区，避免累计量丢失。
    @synchronized (AxsCacheKeeperSweep.class) {
        NSString *path = [[axs_cachekeeper_folder() stringByAppendingPathComponent:@"Status"]
            stringByAppendingPathComponent:[bundle stringByAppendingString:@".auto.plist"]];
        NSDictionary *previous = [NSDictionary dictionaryWithContentsOfFile:path];
        NSArray *known=discoveredPaths ?: (previous[@"discoveredPaths"] ?: @[]);
        if (!removed && !bytes && [previous[@"phase"] isEqual:phase] && [previous[@"message"] isEqual:message] &&
            [previous[@"failed"] unsignedIntegerValue] == failed && [previous[@"effectivePaths"] isEqual:effectivePaths] &&
            [previous[@"discoveredPaths"] isEqual:known] && !directories && -[previous[@"updated"] timeIntervalSinceNow]<30) return;
        NSDictionary *report = @{@"updated":NSDate.date, @"phase":phase, @"message":message,
            @"removed":@([previous[@"removed"] unsignedIntegerValue]+removed),
            @"bytes":@([previous[@"bytes"] unsignedLongLongValue]+bytes), @"failed":@(failed),
            @"effectivePaths":effectivePaths ?: @[], @"discoveredPaths":known, @"directories":directories ?: previous[@"directories"] ?: @{}};
        if (![report writeToFile:path atomically:YES]) NSLog(@"[CacheKeeper] 无法保存 %@ 清理状态", bundle);
    }
}
static NSString *axs_cachekeeper_network_status(NSString *bundle) {
    NSString *path = [[axs_cachekeeper_folder() stringByAppendingPathComponent:@"Status"]
        stringByAppendingPathComponent:[bundle stringByAppendingString:@".network.plist"]];
    NSDictionary *report = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![report isKindOfClass:NSDictionary.class]) return @"尚无进程内网络缓存回执；请重新打开 APP 检查注入";
    NSString *message = [report[@"message"] isKindOfClass:NSString.class] ? report[@"message"] : @"回执格式不完整";
    return [NSString stringWithFormat:@"网络缓存回执：%@（%@）", message, axs_cachekeeper_time_string(report[@"updated"])];
}
void axs_cachekeeper_request_cleanup(NSString *bundle) {
    if (!axs_cachekeeper_bundle_id(bundle)) return;
    NSDictionary *selection = [NSDictionary dictionaryWithContentsOfFile:[axs_cachekeeper_folder() stringByAppendingPathComponent:@"directories.plist"]];
    NSDictionary *states = [NSDictionary dictionaryWithContentsOfFile:[axs_cachekeeper_folder() stringByAppendingPathComponent:@"appEnabled.plist"]];
    if (!axs_cachekeeper_app_enabled(states[bundle])) return;
    if ([axs_cachekeeper_mode(states[bundle]) isEqual:@"prevent"]) {
        axs_cachekeeper_report(bundle, @"prevent", @"当前为只禁止模式，不删除缓存文件", 0, 0, 0, @[], nil, nil); return;
    }
    if (!axs_cachekeeper_can_clean(selection,states,bundle)) return;
    if (!axs_cachekeeper_manual) axs_cachekeeper_manual = [NSMutableSet new];
    NSString *reason=nil;
    if (axs_cachekeeper_process(bundle,&reason) != AxsCacheKeeperProcessStopped) {
        axs_cachekeeper_report(bundle, @"waiting", reason, 0, 0, 0, @[], nil, nil); return;
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
    NSMutableSet *bundles = [NSMutableSet setWithArray:selection.allKeys ?: @[]];
    [bundles addObjectsFromArray:states.allKeys ?: @[]];
    [bundles addObjectsFromArray:axs_cachekeeper_manual.allObjects ?: @[]];
    NSMutableDictionary *targets = [NSMutableDictionary new];
    for (NSString *bundle in bundles) {
        if (!axs_cachekeeper_bundle_id(bundle)) continue;
        if (!axs_cachekeeper_app_enabled(states[bundle])) { [axs_cachekeeper_manual removeObject:bundle];continue; }
        NSArray *selected = axs_cachekeeper_selected_paths(selection, states, bundle);
        BOOL manual = [axs_cachekeeper_manual containsObject:bundle];
        NSString *mode = axs_cachekeeper_mode(states[bundle]);
        NSArray *paths = selected;
        NSURL *home = Container(bundle);
        NSMutableArray *roots = [NSMutableArray new];
        if (home) for (NSString *relative in paths) [roots addObject:[home.path stringByAppendingPathComponent:relative]];
        NSString *reason=nil;
        AxsCacheKeeperProcessState process=axs_cachekeeper_process(bundle,&reason);
        targets[bundle] = @{@"roots":roots, @"paths":paths, @"home":home.path ?: @"", @"mode":mode,
            @"manual":@(manual), @"process":@(process), @"processReason":reason ?: @""};
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
                axs_cachekeeper_report(bundle, @"error", restored[@"error"], 0, 0, [restored[@"failed"] unsignedIntegerValue], paths, nil, nil);
                continue;
            }
            if ([mode isEqual:@"prevent"]) {
                [jobs removeObjectForKey:bundle]; [finished removeObjectForKey:bundle];
                NSString *network=axs_cachekeeper_url_cache_enabled(states[bundle]) ? axs_cachekeeper_network_status(bundle) : @"网络缓存开关已关闭，当前不执行缓存干预";
                axs_cachekeeper_report(bundle, @"prevent", [@"只禁止模式：仅限制标准网络缓存，不删除文件；APP 自行写入缓存目录的文件仍会产生。\n" stringByAppendingString:network], 0, 0, 0, paths, nil, nil);
                if (manual) dispatch_async(dispatch_get_main_queue(), ^{ [axs_cachekeeper_manual removeObject:bundle]; });
                continue;
            }
            if (![target[@"home"] length]) { axs_cachekeeper_report(bundle, @"error", @"无法解析 APP 数据容器", 0, 0, 1, paths, nil, nil); continue; }
            if ([target[@"process"] integerValue] != AxsCacheKeeperProcessStopped) {
                [jobs removeObjectForKey:bundle]; [finished removeObjectForKey:bundle];
                NSString *message = target[@"processReason"];
                if ([mode isEqual:@"auto"] && axs_cachekeeper_url_cache_enabled(states[bundle])) message = [message stringByAppendingFormat:@"\n%@", axs_cachekeeper_network_status(bundle)];
                axs_cachekeeper_report(bundle, @"waiting", message, 0, 0, 0, paths, nil, nil); continue;
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
                axs_cachekeeper_report(bundle,@"waiting",message,0,0,discoveryError.length ? 1 : 0,@[],axs_cachekeeper_auto_discover(states[bundle]) ? discovered : nil,nil);continue;
            }
            BOOL fullClear = axs_cachekeeper_full_clear(states[bundle]);
            NSString *signature = [NSString stringWithFormat:@"%@\n%@\n%@", [roots componentsJoinedByString:@"\n"], mode, fullClear ? @"full" : @"media"];
            NSDictionary *done = finished[bundle];
            if (!manual && [done[@"signature"] isEqual:signature] && -[done[@"time"] timeIntervalSinceNow] < 30) continue;
            NSMutableDictionary *job = jobs[bundle];
            if (![job[@"signature"] isEqual:signature]) {
                NSMutableArray *sweeps = [NSMutableArray new];
                for (NSUInteger index = 0; index < roots.count; index++) {
                    NSString *root = roots[index];
                    struct stat info;
                    if (lstat(root.fileSystemRepresentation, &info) && errno == ENOENT) continue;
                    BOOL rootFullClear = index < paths.count && axs_cachekeeper_full_clear_path(states[bundle], paths[index]);
                    [sweeps addObject:[[AxsCacheKeeperSweep alloc] initWithRoot:root fullClear:rootFullClear]];
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
                    NSArray *currentPaths = axs_cachekeeper_effective_paths(currentSelection[bundle],currentStates[bundle],discovered);
                    BOOL selected = [currentPaths isEqual:paths] && [axs_cachekeeper_mode(currentStates[bundle]) isEqual:mode] &&
                        axs_cachekeeper_full_clear(currentStates[bundle]) == fullClear;
                    allowed = readable && selected && currentPaths.count && axs_cachekeeper_wants_cleanup(currentStates[bundle]) && [Container(bundle).path isEqual:target[@"home"]] &&
                        axs_cachekeeper_process(bundle,NULL) == AxsCacheKeeperProcessStopped;
                });
                return allowed;
            };
            NSUInteger removed = 0, failures = 0, protectedCount = 0, recentCount = 0, inspected = 0, changedCount = 0;
            unsigned long long bytes = 0;
            BOOL complete = YES, cancelled = NO, checking = NO;
            NSString *error = @"";
            NSMutableDictionary *directoryReports=[NSMutableDictionary new];
            for (AxsCacheKeeperSweep *sweep in job[@"sweeps"]) {
                if (!cancelled) [sweep advance:256 shouldContinue:shouldContinue];
                removed += sweep.removed; bytes += sweep.bytes; failures += sweep.failed;
                protectedCount += sweep.protectedCount; recentCount += sweep.recentCount;
                inspected += sweep.inspected; checking |= sweep.checking && !sweep.complete;
                changedCount += sweep.changedCount;
                complete &= sweep.complete; cancelled |= sweep.cancelled;
                if (sweep.error.length) error = sweep.error;
                NSString *relative=[sweep.root substringFromIndex:[target[@"home"] length]+1];
                directoryReports[relative]=@{@"updated":NSDate.date,@"complete":@(sweep.complete),@"checking":@(sweep.checking),@"cancelled":@(sweep.cancelled),
                    @"removed":@(sweep.removed),@"bytes":@(sweep.bytes),@"protected":@(sweep.protectedCount),@"recent":@(sweep.recentCount),@"changed":@(sweep.changedCount),@"failed":@(sweep.failed),@"error":sweep.error ?: @""};
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
                if (fullClear) message=[message stringByAppendingString:@"\n全量清理开启：标准缓存目录内的文件按平台缓存契约处理，不按类型保留（60 秒内新文件除外）"];
                if ([mode isEqual:@"auto"] && axs_cachekeeper_url_cache_enabled(states[bundle])) message = [message stringByAppendingFormat:@"\n%@", axs_cachekeeper_network_status(bundle)];
                finished[bundle] = @{@"signature":signature, @"time":NSDate.date};
                [jobs removeObjectForKey:bundle];
            }
            if (axs_cachekeeper_auto_discover(states[bundle])) message=[message stringByAppendingFormat:@"\n自动识别已纳入 %lu 个缓存根（手动排除保持关闭）",(unsigned long)paths.count];
            if (discoveryError.length) message=[message stringByAppendingFormat:@"\n%@",discoveryError];
            axs_cachekeeper_report(bundle, phase, message, deltaRemoved, deltaBytes, failures, paths, axs_cachekeeper_auto_discover(states[bundle]) ? discovered : nil, directoryReports);
            if (manual && (complete || cancelled)) dispatch_async(dispatch_get_main_queue(), ^{ [axs_cachekeeper_manual removeObject:bundle]; });
        }
        dispatch_async(dispatch_get_main_queue(), ^{ busy = NO; });
    });
}
