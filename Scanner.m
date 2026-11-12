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
// 最近一次观测到的运行实例标识（仅主线程读写：CKApply 入口观测、目标构建与 shouldContinue 均在主线程）。
static NSMutableDictionary<NSString *, NSString *> *axs_cachekeeper_seen_instances;
// 挂起稳定跟踪（仅主线程读写）：bundle → {identity, since}；同一实例持续挂起满 60 秒才放行清理。
static NSMutableDictionary<NSString *, NSDictionary *> *axs_cachekeeper_suspended_since;
static AxsCacheKeeperExecState axs_cachekeeper_exec(NSString *bundle, NSString **identity, NSInteger *taskState, NSString **reason) {
    id manager = SRead(NSClassFromString(@"FBProcessManager"), @"sharedInstance");
    return axs_cachekeeper_process_exec_state(manager,bundle,identity,taskState,reason);
}
// 清理放行判定（主线程调用）：进程消失可清理；进程被挂起时须为任务所绑定的同一实例且已持续挂起满 60 秒。
static BOOL axs_cachekeeper_gate_open(NSString *bundle, NSString *jobInstance) {
    NSString *identity=nil;
    AxsCacheKeeperExecState exec=axs_cachekeeper_exec(bundle,&identity,NULL,NULL);
    if (exec==AxsCacheKeeperExecAbsent || exec==AxsCacheKeeperExecTerminated) return YES;
    if (exec!=AxsCacheKeeperExecSuspended || !identity.length) return NO;
    if (jobInstance.length && ![identity isEqual:jobInstance]) return NO;
    NSDictionary *record=axs_cachekeeper_suspended_since[bundle];
    return [record[@"identity"] isEqual:identity] && -[record[@"since"] timeIntervalSinceNow]>=60;
}
static NSString *axs_cachekeeper_folder(void) { return jbroot(@"/var/mobile/Library/CacheKeeper"); }
static BOOL axs_cachekeeper_report(NSString *bundle, NSString *phase, NSString *message,
                                  NSUInteger removed, unsigned long long bytes, NSUInteger failed, NSArray *effectivePaths, NSArray *discoveredPaths, NSDictionary *directories) {
    // 主线程快捷操作与清理队列共享同一个原子读改写区，避免累计量丢失。
    // 返回是否落盘成功：调用方据此决定是否推进累计与退役作业（审计第 9 项）。
    @synchronized (AxsCacheKeeperSweep.class) {
        NSString *path = [[axs_cachekeeper_folder() stringByAppendingPathComponent:@"Status"]
            stringByAppendingPathComponent:[bundle stringByAppendingString:@".auto.plist"]];
        NSDictionary *previous = [NSDictionary dictionaryWithContentsOfFile:path];
        NSArray *known=discoveredPaths ?: (previous[@"discoveredPaths"] ?: @[]);
        if (!removed && !bytes && [previous[@"phase"] isEqual:phase] && [previous[@"message"] isEqual:message] &&
            [previous[@"failed"] unsignedIntegerValue] == failed && [previous[@"effectivePaths"] isEqual:effectivePaths] &&
            [previous[@"discoveredPaths"] isEqual:known] && !directories && -[previous[@"updated"] timeIntervalSinceNow]<30) return YES;
        NSDictionary *report = @{@"updated":NSDate.date, @"phase":phase, @"message":message,
            @"removed":@([previous[@"removed"] unsignedIntegerValue]+removed),
            @"bytes":@([previous[@"bytes"] unsignedLongLongValue]+bytes), @"failed":@(failed),
            @"effectivePaths":effectivePaths ?: @[], @"discoveredPaths":known, @"directories":directories ?: previous[@"directories"] ?: @{}};
        if (![report writeToFile:path atomically:YES]) { NSLog(@"[CacheKeeper] 无法保存 %@ 清理状态", bundle); return NO; }
        return YES;
    }
}
static NSString *axs_cachekeeper_network_status(NSString *bundle) {
    NSString *path = [[axs_cachekeeper_folder() stringByAppendingPathComponent:@"Status"]
        stringByAppendingPathComponent:[bundle stringByAppendingString:@".network.plist"]];
    NSDictionary *report = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![report isKindOfClass:NSDictionary.class]) {
        NSDictionary *probe=[NSDictionary dictionaryWithContentsOfFile:[[axs_cachekeeper_folder() stringByAppendingPathComponent:@"Status"] stringByAppendingPathComponent:[bundle stringByAppendingString:@".probe.plist"]]];
        if ([probe[@"message"] isKindOfClass:NSString.class]) return [NSString stringWithFormat:@"尚无网络文件回执；上次主动诊断（%@）：%@",axs_cachekeeper_time_string(probe[@"updated"]),probe[@"message"]];
        return @"尚无网络文件回执；请点“检查网络限制”后打开此 APP，再返回查看原因";
    }
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
    if (!axs_cachekeeper_gate_open(bundle, @"")) {
        NSString *execReason=nil;
        if (axs_cachekeeper_exec(bundle,nil,NULL,&execReason)==AxsCacheKeeperExecSuspended)
            execReason=@"APP 进程已被系统挂起（未在执行），稳定确认中；持续挂起满 60 秒后自动清理";
        axs_cachekeeper_report(bundle, @"waiting", execReason ?: reason, 0, 0, 0, @[], nil, nil); return;
    }
    [axs_cachekeeper_manual addObject:bundle];
}
void CKApplyDirectorySwitches(void) {
    static BOOL busy;
    static dispatch_queue_t queue;
    static NSMutableDictionary *jobs, *finished, *discovery, *lockChecks, *purgeDiscovery;
    // 实例观测独立于清理忙碌状态：每轮入口先记录各已启用 APP 当前运行实例，
    // 使长任务存续期间发生的新实例启停也能被 shouldContinue 的绑定比对发现；
    // 同时维护挂起稳定跟踪（同一实例被系统挂起的起始时刻），供放行判定使用。
    if (!axs_cachekeeper_seen_instances) axs_cachekeeper_seen_instances = [NSMutableDictionary new];
    if (!axs_cachekeeper_suspended_since) axs_cachekeeper_suspended_since = [NSMutableDictionary new];
    NSDictionary *observedStates = [NSDictionary dictionaryWithContentsOfFile:
        [axs_cachekeeper_folder() stringByAppendingPathComponent:@"appEnabled.plist"]];
    for (NSString *bundle in observedStates) {
        if (!axs_cachekeeper_bundle_id(bundle) || !axs_cachekeeper_app_enabled(observedStates[bundle])) continue;
        NSString *identity=nil;
        AxsCacheKeeperExecState exec=axs_cachekeeper_exec(bundle,&identity,NULL,NULL);
        if (exec==AxsCacheKeeperExecExecuting && identity) axs_cachekeeper_seen_instances[bundle]=identity;
        if (exec==AxsCacheKeeperExecSuspended && identity) {
            NSDictionary *record=axs_cachekeeper_suspended_since[bundle];
            if (![record[@"identity"] isEqual:identity])
                axs_cachekeeper_suspended_since[bundle]=@{@"identity":identity,@"since":NSDate.date};
        } else [axs_cachekeeper_suspended_since removeObjectForKey:bundle];
    }
    if (busy) return;
    if (!queue) {
        queue = dispatch_queue_create("dev.local.cachekeeper.cleanup", DISPATCH_QUEUE_SERIAL);
        jobs = [NSMutableDictionary new]; finished = [NSMutableDictionary new]; discovery = [NSMutableDictionary new]; lockChecks = [NSMutableDictionary new]; purgeDiscovery = [NSMutableDictionary new];
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
        NSString *reason=nil, *execIdentity=nil;
        AxsCacheKeeperExecState exec=axs_cachekeeper_exec(bundle,&execIdentity,NULL,&reason);
        AxsCacheKeeperProcessState process=AxsCacheKeeperProcessUnknown;
        AxsCacheKeeperSignalConfidence confidence=AxsCacheKeeperSignalNone;
        NSString *instance=axs_cachekeeper_seen_instances[bundle] ?: @"";
        if (exec==AxsCacheKeeperExecAbsent) {
            process=AxsCacheKeeperProcessStopped; confidence=AxsCacheKeeperSignalStrong;
        } else if (exec==AxsCacheKeeperExecTerminated) {
            process=AxsCacheKeeperProcessStopped; confidence=AxsCacheKeeperSignalStrong;
        } else if (exec==AxsCacheKeeperExecExecuting) {
            process=AxsCacheKeeperProcessRunning; confidence=AxsCacheKeeperSignalStrong;
            if (execIdentity) instance=execIdentity;
        } else if (exec==AxsCacheKeeperExecSuspended) {
            confidence=AxsCacheKeeperSignalStrong;
            if (execIdentity) instance=execIdentity;
            NSDictionary *suspendRecord=axs_cachekeeper_suspended_since[bundle];
            if (execIdentity && [suspendRecord[@"identity"] isEqual:execIdentity] &&
                -[suspendRecord[@"since"] timeIntervalSinceNow]>=60) {
                process=AxsCacheKeeperProcessStopped;
                reason=@"APP 进程已被系统挂起且持续满 60 秒（未在执行），按已退出处理";
            } else {
                process=AxsCacheKeeperProcessRunning;
                reason=@"APP 进程已被系统挂起（未在执行），稳定确认中；持续挂起满 60 秒后自动清理";
            }
        }
        targets[bundle] = @{@"roots":roots, @"paths":paths, @"home":home.path ?: @"", @"mode":mode,
            @"manual":@(manual), @"process":@(process), @"processReason":reason ?: @"",
            @"instance":instance, @"confidence":@(confidence)};
    }
    busy = YES;
    dispatch_async(queue, ^{
        // 权限记录只恢复「不再被期望锁定」的部分：期望集合 = 已启用且只禁止模式的 APP 的已选缓存根；
        // 其余记录（含旧版残留、已切换模式或关闭总开关的 APP）每轮在此恢复，期望内条目保持锁定。
        NSString *journal = [folder stringByAppendingPathComponent:@"permissions.plist"];
        NSDictionary *journalRecords = [NSDictionary dictionaryWithContentsOfFile:journal];
        NSMutableArray *desiredRoots = [NSMutableArray new];
        for (NSString *bundle in targets) if ([targets[bundle][@"mode"] isEqual:@"prevent"]) {
            // 只禁止的写锁只作用于标准缓存根；定级日志目录不因只禁止模式被上锁（其语义是退出后清理）。
            NSArray *targetPaths = targets[bundle][@"paths"], *targetRoots = targets[bundle][@"roots"];
            for (NSUInteger index = 0; index < targetPaths.count && index < targetRoots.count; index++)
                if ([axs_cachekeeper_directory_kind(targetPaths[index]) isEqual:@"cache"]) [desiredRoots addObject:targetRoots[index]];
        }
        NSMutableArray *undesired = [NSMutableArray new];
        for (NSString *path in journalRecords) {
            BOOL wanted = NO;
            for (NSString *root in desiredRoots)
                if ([path isEqual:root] || [path hasPrefix:[root stringByAppendingString:@"/"]]) { wanted = YES; break; }
            if (!wanted) [undesired addObject:path];
        }
        NSDictionary *restored = undesired.count ? axs_cachekeeper_restore_paths(undesired, journal) :
            @{@"failed":@0, @"applied":@0, @"error":@""};
        for (NSString *bundle in lockChecks.allKeys) if (!targets[bundle]) [lockChecks removeObjectForKey:bundle];
        for (NSString *bundle in jobs.allKeys) if (!targets[bundle]) [jobs removeObjectForKey:bundle];
        for (NSString *bundle in finished.allKeys) if (!targets[bundle]) [finished removeObjectForKey:bundle];
        for (NSString *bundle in discovery.allKeys) if (!targets[bundle]) [discovery removeObjectForKey:bundle];
        for (NSString *bundle in purgeDiscovery.allKeys) if (!targets[bundle]) [purgeDiscovery removeObjectForKey:bundle];
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
                NSString *lockMessage;
                if ([target[@"process"] integerValue] != AxsCacheKeeperProcessStopped) {
                    lockMessage = @"只禁止模式：限制网络缓存并锁定已选缓存目录写入；APP 未完全退出，上锁将在退出后自动执行。";
                } else if (!roots.count) {
                    lockMessage = @"只禁止模式：限制网络缓存，不删除文件；尚未选择缓存目录，没有可锁定的目录。";
                } else {
                    NSString *signature = [roots componentsJoinedByString:@"\n"];
                    NSDictionary *last = lockChecks[bundle];
                    NSDictionary *result = ([last[@"signature"] isEqual:signature] && -[last[@"time"] timeIntervalSinceNow] < 30) ? last[@"result"] : nil;
                    if (!result) {
                        result = axs_cachekeeper_lock_paths(roots, journal);
                        lockChecks[bundle] = @{@"signature":signature, @"time":NSDate.date, @"result":result};
                    }
                    lockMessage = [result[@"failed"] unsignedIntegerValue] ?
                        [NSString stringWithFormat:@"只禁止模式：目录写入锁定失败：%@；网络缓存限制照常执行。", result[@"error"]] :
                        [NSString stringWithFormat:@"只禁止模式：已锁定 %lu 个缓存目录的写入（可读取、不可新建或修改），不删除已有文件。", (unsigned long)roots.count];
                }
                axs_cachekeeper_report(bundle, @"prevent", [lockMessage stringByAppendingFormat:@"\n%@", network], 0, 0, 0, paths, nil, nil);
                if (manual) dispatch_async(dispatch_get_main_queue(), ^{ [axs_cachekeeper_manual removeObject:bundle]; });
                continue;
            }
            if (![target[@"home"] length]) { axs_cachekeeper_report(bundle, @"error", @"无法解析 APP 数据容器", 0, 0, 1, paths, nil, nil); continue; }
            if ([target[@"process"] integerValue] != AxsCacheKeeperProcessStopped ||
                [target[@"confidence"] integerValue] != AxsCacheKeeperSignalStrong) {
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
            // 未知目录自动清理（B 案）：候选集来自家目录枚举（30 秒缓存，与缓存根发现同节奏；Group 容器不在内）；
            // 内容审查在 Sweep 预检内完成，此处只决定候选集（用途未知类、未定级为日志、未被手动排除）。
            // 只开总开关即全自动：候选发现不依赖自动发现开关。
            NSArray *purgeCandidates=@[];
            NSError *purgeError=nil;
            NSDictionary *knownPurge=purgeDiscovery[bundle];
            NSTimeInterval nowPurge=NSProcessInfo.processInfo.systemUptime;
            if (![knownPurge[@"home"] isEqual:target[@"home"]] || nowPurge-[knownPurge[@"time"] doubleValue]>=30) {
                // 注意：不能用 scan_targets 的 readOnly 过滤——它标记的是“非标准缓存路径”，
                // 未知目录全是 readOnly=YES，过滤后 B 案候选集恒为空（#37 真机静默失效）。
                NSArray *found=axs_cachekeeper_purge_candidates([NSURL fileURLWithPath:target[@"home"]], &purgeError);
                knownPurge=@{@"home":target[@"home"],@"time":@(nowPurge),@"paths":found ?: @[],@"error":purgeError.localizedDescription ?: @""};
                purgeDiscovery[bundle]=knownPurge;
            }
            purgeCandidates=knownPurge[@"paths"];
            NSArray *purgePaths=axs_cachekeeper_purge_paths(purgeCandidates, states[bundle]);
            if (!paths.count && !purgePaths.count) {
                [jobs removeObjectForKey:bundle];[finished removeObjectForKey:bundle];
                NSString *message=discoveryError.length ? discoveryError : @"没有可处理的缓存目录；已尊重手动排除，网络限制按独立选项执行";
                axs_cachekeeper_report(bundle,@"waiting",message,0,0,discoveryError.length ? 1 : 0,@[],axs_cachekeeper_auto_discover(states[bundle]) ? discovered : nil,nil);continue;
            }
            BOOL fullClear = axs_cachekeeper_full_clear(states[bundle]);
            BOOL hasLogRoot = NO;
            for (NSString *path in paths) if ([axs_cachekeeper_log_paths(states[bundle]) containsObject:path]) { hasLogRoot = YES; break; }
            BOOL hasPurgeRoot = purgePaths.count > 0;
            NSString *signature = [NSString stringWithFormat:@"%@\n%@\n%@\n%@\n%@", [roots componentsJoinedByString:@"\n"], mode, fullClear ? @"full" : @"media", target[@"instance"], [purgePaths componentsJoinedByString:@"\n"]];
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
                    BOOL rootLog = index < paths.count && [axs_cachekeeper_log_paths(states[bundle]) containsObject:paths[index]];
                    [sweeps addObject:[[AxsCacheKeeperSweep alloc] initWithRoot:root fullClear:rootFullClear logMode:rootLog]];
                }
                for (NSString *relative in purgePaths) {
                    NSString *purgeRoot=[target[@"home"] stringByAppendingPathComponent:relative];
                    struct stat info;
                    if (lstat(purgeRoot.fileSystemRepresentation, &info) && errno == ENOENT) continue;
                    [sweeps addObject:[[AxsCacheKeeperSweep alloc] initWithRoot:purgeRoot fullClear:NO logMode:NO purgeMode:YES]];
                }
                job = [@{@"signature":signature, @"sweeps":sweeps, @"removed":@0, @"bytes":@0,
                    @"instance":target[@"instance"] ?: @"", @"started":NSDate.date} mutableCopy];
                jobs[bundle] = job;
            }
            NSString *jobInstance = job[@"instance"];
            // 放行判定每周期采样一次：原先逐文件调用时每次都读两份配置并查询进程，
            // 36 根 × 256 项的调用量把单周期拖到约 10 秒，抖音的预检因此撞上 120 秒上限无限重开（2026-11-12 实证）。
            // 采样间隔即轮次周期（约 2 秒），重开 APP 至多下一周期停手；逐文件身份/年龄核对仍在 remove 内逐项执行。
            __block BOOL cycleAllowed = NO;
            dispatch_sync(dispatch_get_main_queue(), ^{
                NSDictionary *currentSelection = [NSDictionary dictionaryWithContentsOfFile:selectionFile];
                NSDictionary *currentStates = [NSDictionary dictionaryWithContentsOfFile:stateFile];
                BOOL readable = (currentSelection || ![NSFileManager.defaultManager fileExistsAtPath:selectionFile]) &&
                    (currentStates || ![NSFileManager.defaultManager fileExistsAtPath:stateFile]);
                NSArray *currentPaths = axs_cachekeeper_effective_paths(currentSelection[bundle],currentStates[bundle],discovered);
                BOOL selected = [currentPaths isEqual:paths] && [axs_cachekeeper_mode(currentStates[bundle]) isEqual:mode] &&
                    axs_cachekeeper_full_clear(currentStates[bundle]) == fullClear;
                // 未知目录候选集须同步复核：中途被定级为日志或手动排除的目录，本轮立即停手，下一轮改走日志模式。
                NSArray *currentPurgePaths = axs_cachekeeper_purge_paths(purgeCandidates, currentStates[bundle]);
                BOOL purgeOK = [currentPurgePaths isEqual:purgePaths];
                // 实例绑定：任务存续期间观测到不同实例运行过，说明目标缓存可能已被新实例接管，旧任务过期。
                NSString *seen = axs_cachekeeper_seen_instances[bundle];
                BOOL instanceOK = ![jobInstance length] || ![seen length] || [seen isEqual:jobInstance];
                // 仅清理未知目录的任务没有缓存根，currentPaths 为空是正常态：任一根存在即放行。
                cycleAllowed = readable && selected && (currentPaths.count || currentPurgePaths.count) && axs_cachekeeper_wants_cleanup(currentStates[bundle]) && [Container(bundle).path isEqual:target[@"home"]] &&
                    axs_cachekeeper_gate_open(bundle, jobInstance) && instanceOK && purgeOK;
            });
            BOOL (^shouldContinue)(void) = ^BOOL { return cycleAllowed; };
            NSUInteger removed = 0, failures = 0, protectedCount = 0, recentCount = 0, inspected = 0, changedCount = 0, mixedPurgeRemoved = 0;
            unsigned long long bytes = 0;
            BOOL complete = YES, cancelled = NO, checking = NO, hasMixedPurge = NO;
            NSString *error = @"";
            NSMutableDictionary *directoryReports=[NSMutableDictionary new];
            for (AxsCacheKeeperSweep *sweep in job[@"sweeps"]) {
                if (!cancelled) [sweep advance:256 shouldContinue:shouldContinue];
                removed += sweep.removed; bytes += sweep.bytes; failures += sweep.failed;
                hasMixedPurge |= sweep.purgeMixed;
                if (sweep.purgeMixed) mixedPurgeRemoved += sweep.removed;
                protectedCount += sweep.protectedCount; recentCount += sweep.recentCount;
                inspected += sweep.inspected; checking |= sweep.checking && !sweep.complete;
                changedCount += sweep.changedCount;
                complete &= sweep.complete; cancelled |= sweep.cancelled;
                if (sweep.error.length) error = sweep.error;
                NSString *relative=[sweep.root substringFromIndex:[target[@"home"] length]+1];
                // 分类与首条证据独立落盘（审计第 10 项）：error 会被后续失败覆盖，不能作为证据载体；
                // 完整性由已有的 complete/checking/cancelled 三键表达（分类在预检完成时定型，删除阶段可重标混合）。
                NSString *purgeClassification = @"";
                if (sweep.purgeBlocked) purgeClassification = @"blocked";
                else if (sweep.purgeMixed) purgeClassification = @"mixed";
                else if (sweep.purgeMode) purgeClassification = @"clean";
                directoryReports[relative]=@{@"updated":NSDate.date,@"complete":@(sweep.complete),@"checking":@(sweep.checking),@"cancelled":@(sweep.cancelled),
                    @"removed":@(sweep.removed),@"bytes":@(sweep.bytes),@"protected":@(sweep.protectedCount),@"recent":@(sweep.recentCount),@"changed":@(sweep.changedCount),@"failed":@(sweep.failed),@"error":sweep.error ?: @"",@"failureDetails":sweep.failureDetails ?: @[],@"purgeClassification":purgeClassification,@"purgeEvidence":sweep.purgeEvidence ?: @""};
            }
            NSUInteger deltaRemoved = removed-[job[@"removed"] unsignedIntegerValue];
            unsigned long long deltaBytes = bytes-[job[@"bytes"] unsignedLongLongValue];
            // 累计不在此推进：须等回执写成功后再推进，写失败时保留增量与作业以便下周期重试（审计第 9 项）。
            // 单轮硬上限（对照方案吸收并按本引擎分批模型适配）：单轮累计删除 2000 项或累计运行 120 秒即收尾，
            // 剩余内容顺延下轮重新预检后继续，限制单轮异常时的损害半径。
            // 120 秒计时仅在预检完成后生效：预检不删任何文件，计入上限只会让大目录的轮次无限重开（抖音 2026-11-12 实证）；
            // 2000 项删除上限不受影响（删除只发生在预检之后）。
            BOOL capHit = !complete && !cancelled &&
                (removed >= 2000 || (!checking && -[job[@"started"] timeIntervalSinceNow] >= 120));
            NSString *phase = @"cleaning", *message = @"正在分批清理；无需重新检测目录";
            if (checking) message=[NSString stringWithFormat:@"正在检查数据目录，已检查 %lu 项；预检完成后才删除",(unsigned long)inspected];
            if (cancelled) {
                phase = @"waiting"; message = @"APP 重新运行或配置改变，已停止清理";
            } else if (complete || capHit) {
                phase = failures ? @"error" : @"complete";
                message = failures ? [@"本轮未全部完成：" stringByAppendingString:error] :
                    (capHit ? [NSString stringWithFormat:@"本轮已达单轮上限（2000 项或 120 秒），已清理 %lu 项；剩余内容顺延下轮继续", (unsigned long)removed] :
                    [NSString stringWithFormat:@"本轮检查完成；保留 %lu 项受保护/未知内容、%lu 项近期文件", (unsigned long)protectedCount, (unsigned long)recentCount]);
                if (changedCount) message=[message stringByAppendingFormat:@"；%lu 个目录在预检后变化，已跳过等待下轮",(unsigned long)changedCount];
                if (fullClear) message=[message stringByAppendingString:@"\n全量清理开启：标准缓存目录内的文件按平台缓存契约处理，不按类型保留（60 秒内新文件除外）"];
                if (hasLogRoot) message=[message stringByAppendingString:@"\n含用户定级的日志目录：仅清理日志特征文件（.log/.alog/.xlog)，数据与未知内容保留"];
                if (hasPurgeRoot) message=[message stringByAppendingString:@"\n未知目录已按内容审查清理：无数据证据的目录退出后清理，检出数据证据的目录自动仅清理其中的日志文件"];
                if (hasMixedPurge) {
                    // 混合行按实际删除数表述，不只按策略启用（审计第 10 项）：0 删除时明确说未删。
                    if (mixedPurgeRemoved) message=[message stringByAppendingFormat:@"\n本轮有未知目录检出数据证据，已自动仅清理其中的日志文件 %lu 个（数据与未知内容保留）",(unsigned long)mixedPurgeRemoved];
                    else message=[message stringByAppendingString:@"\n本轮有未知目录检出数据证据，未删除其中任何文件（数据与未知内容保留）"];
                }
                if ([mode isEqual:@"auto"] && axs_cachekeeper_url_cache_enabled(states[bundle])) message = [message stringByAppendingFormat:@"\n%@", axs_cachekeeper_network_status(bundle)];
            }
            if (axs_cachekeeper_auto_discover(states[bundle])) message=[message stringByAppendingFormat:@"\n自动识别已纳入 %lu 个缓存根（手动排除保持关闭）",(unsigned long)paths.count];
            if (discoveryError.length) message=[message stringByAppendingFormat:@"\n%@",discoveryError];
            // 回执写成功后才推进累计并退役作业；写失败时保留增量与已完成作业，
            // 下周期重试同一增量与同一分目录回执（审计第 9 项，用户 12:19 定）。
            BOOL reported = axs_cachekeeper_report(bundle, phase, message, deltaRemoved, deltaBytes, failures, paths, axs_cachekeeper_auto_discover(states[bundle]) ? discovered : nil, directoryReports);
            if (reported) {
                job[@"removed"] = @(removed); job[@"bytes"] = @(bytes);
                if (cancelled || complete || capHit) {
                    if (complete || capHit) finished[bundle] = @{@"signature":signature, @"time":NSDate.date};
                    [jobs removeObjectForKey:bundle];
                    if (manual && (complete || cancelled)) dispatch_async(dispatch_get_main_queue(), ^{ [axs_cachekeeper_manual removeObject:bundle]; });
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ busy = NO; });
    });
}
