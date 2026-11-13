#import <Foundation/Foundation.h>
#import <objc/message.h>
#include <roothide.h>
#include <sys/stat.h>
#include <signal.h>
#include <errno.h>
#include <time.h>
#import "AxsCacheKeeperPolicy.h"
#import "AxsCacheKeeperSweep.h"
#import "AxsCacheKeeperCleanupJob.h"
#import "AxsCacheKeeperCleanupRules.h"
#import "AxsCacheKeeperDirectories.h"
#import "AxsCacheKeeperProcess.h"
#import "AxsCacheKeeperProcessObservation.h"
#import "AxsCacheKeeperReceipts.h"
#import "AxsCacheKeeperCleanupSchedule.h"
#import "AxsCacheKeeperInspection.h"
static id SRead(id target,NSString *name) { SEL s=NSSelectorFromString(name);return [target respondsToSelector:s]?((id(*)(id,SEL))objc_msgSend)(target,s):nil; }
static id AxsCacheKeeperAppProxy(NSString *bundle) {
    Class proxy=NSClassFromString(@"LSApplicationProxy"); SEL selector=NSSelectorFromString(@"applicationProxyForIdentifier:");
    return [proxy respondsToSelector:selector] ? ((id(*)(id,SEL,id))objc_msgSend)(proxy,selector,bundle) : nil;
}
static NSURL *Container(NSString *bundle) {
    id app=AxsCacheKeeperAppProxy(bundle);
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
    // 检测仍只读；让下一次满足进程条件的清理轮重新预检，不沿用旧静默/未知登记。
    if (!([request[@"diagnostic"] isKindOfClass:NSNumber.class] && [request[@"diagnostic"] boolValue]))
        [AxsCacheKeeperProcessObservation requestRecheckForBundle:bundle];
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
        NSMutableArray *searchRoots=[NSMutableArray new];
        if (home.path.length) [searchRoots addObject:@{@"path":home.path,@"label":@"容器"}];
        for (NSString *groupID in groups) {
            NSURL *groupHome=groups[groupID];
            if ([groupHome isKindOfClass:NSURL.class] && groupHome.path.length)
                [searchRoots addObject:@{@"path":groupHome.path,@"label":[NSString stringWithFormat:@"Group:%@",groupID]}];
        }
        NSURL *bundleURL=SRead(app,@"bundleURL");
        if ([bundleURL isKindOfClass:NSURL.class] && bundleURL.path.length)
            [searchRoots addObject:@{@"path":bundleURL.path,@"label":@"安装包"}];
        AxsCacheKeeperInspection *inspection=root ? [[AxsCacheKeeperInspection alloc] initWithRoot:root.path searchRoots:searchRoots] : nil;
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
static AxsCacheKeeperExecState axs_cachekeeper_exec(NSString *bundle, NSString **identity, NSInteger *taskState, NSString **reason) {
    id manager = SRead(NSClassFromString(@"FBProcessManager"), @"sharedInstance");
    return axs_cachekeeper_process_exec_state(manager,bundle,identity,taskState,reason);
}
// 单调时钟（秒）：系统时间被用户/网络调整时墙钟会跳变，挂起稳定计时与删除阶段
// 上限必须用不受调钟影响的时钟（审计第 6、8 项）。仅用于安全相关的计时；30 秒
// 节流与回执去重仍用墙钟（调钟只影响轮次节奏，不影响安全判定）。
static double axs_cachekeeper_monotonic_seconds(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now)) return 0;
    return (double)now.tv_sec + (double)now.tv_nsec / 1000000000.0;
}
// 清理放行判定（主线程调用）：进程消失可清理；进程被挂起时须为任务所绑定的同一实例且已持续挂起满 60 秒。
static BOOL axs_cachekeeper_gate_open(NSString *bundle, NSString *jobInstance) {
    NSString *identity=nil;
    AxsCacheKeeperExecState exec=axs_cachekeeper_exec(bundle,&identity,NULL,NULL);
    [AxsCacheKeeperProcessObservation observeBundle:bundle state:exec identity:identity atMonotonicTime:axs_cachekeeper_monotonic_seconds()];
    if (exec==AxsCacheKeeperExecAbsent || exec==AxsCacheKeeperExecTerminated) return YES;
    if (exec!=AxsCacheKeeperExecSuspended || !identity.length) return NO;
    if (jobInstance.length && ![identity isEqual:jobInstance]) return NO;
    return [AxsCacheKeeperProcessObservation allowsSuspendedCleanupForBundle:bundle identity:identity atMonotonicTime:axs_cachekeeper_monotonic_seconds()];
}
static NSString *axs_cachekeeper_folder(void) { return jbroot(@"/var/mobile/Library/CacheKeeper"); }
// 回执模块配置（幂等）：Status 目录只由调用方给定，模块本身不依赖 jbroot。
static void axs_cachekeeper_configure_receipts(void) {
    [AxsCacheKeeperReceipts configureWithStatusFolder:[axs_cachekeeper_folder() stringByAppendingPathComponent:@"Status"]];
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
    axs_cachekeeper_configure_receipts();
    NSDictionary *selection = [NSDictionary dictionaryWithContentsOfFile:[axs_cachekeeper_folder() stringByAppendingPathComponent:@"directories.plist"]];
    NSDictionary *states = [NSDictionary dictionaryWithContentsOfFile:[axs_cachekeeper_folder() stringByAppendingPathComponent:@"appEnabled.plist"]];
    if (!axs_cachekeeper_app_enabled(states[bundle])) return;
    // 任务 9：三种模式共用清理引擎，prevent 不再短路——手动检测目录同样走门控与清理流程。
    if (!axs_cachekeeper_can_clean(selection,states,bundle)) return;
    if (!axs_cachekeeper_manual) axs_cachekeeper_manual = [NSMutableSet new];
    NSString *reason=nil;
    if (!axs_cachekeeper_gate_open(bundle, @"")) {
        NSString *execReason=nil;
        if (axs_cachekeeper_exec(bundle,nil,NULL,&execReason)==AxsCacheKeeperExecSuspended)
            execReason=@"APP 进程已被系统挂起（未在执行），稳定确认中；持续挂起满 60 秒后自动清理";
        [AxsCacheKeeperReceipts updateStatusForBundle:bundle phase:@"waiting" message:execReason ?: reason failed:0 effectivePaths:@[] discoveredPaths:nil directories:nil]; return;
    }
    [axs_cachekeeper_manual addObject:bundle];
}
void CKApplyDirectorySwitches(void) {
    static BOOL busy;
    static dispatch_queue_t queue;
    static NSMutableDictionary *jobs, *finished, *discovery, *purgeDiscovery, *unresolvedRanges, *jobReports;
    // 实例观测独立于清理忙碌状态：每轮入口先记录各已启用 APP 当前运行实例，
    // 使长任务存续期间发生的新实例启停也能被门控采样的绑定比对发现；
    // 同时维护挂起稳定跟踪（同一实例被系统挂起的起始时刻），供放行判定使用。
    NSDictionary *observedStates = [NSDictionary dictionaryWithContentsOfFile:
        [axs_cachekeeper_folder() stringByAppendingPathComponent:@"appEnabled.plist"]];
    // 周期起点差集清理：以当前启用集合为准，配置键直接移除的 bundle 其挂起起点与
    // 执行实例记录一并作废；配置读不到时全部作废（方案任务 2 补齐）。
    NSMutableSet *enabledBundles = [NSMutableSet new];
    for (NSString *bundle in observedStates) if (axs_cachekeeper_bundle_id(bundle) && axs_cachekeeper_app_enabled(observedStates[bundle])) [enabledBundles addObject:bundle];
    [AxsCacheKeeperProcessObservation beginCycleWithEnabledBundles:enabledBundles configurationReadable:(observedStates != nil)];
    for (NSString *bundle in observedStates) {
        if (!axs_cachekeeper_bundle_id(bundle) || !axs_cachekeeper_app_enabled(observedStates[bundle])) {
            // 未启用/无效 bundle 不观测，但须清除旧挂起记录：停用期间进程恢复运行再挂起，
            // 重开时不能继承停用前的旧起点（方案任务 2 第 3 步；与周期差集清理互为纵深）。
            [AxsCacheKeeperProcessObservation observeBundle:bundle state:AxsCacheKeeperExecUnknown identity:nil atMonotonicTime:axs_cachekeeper_monotonic_seconds()];
            continue;
        }
        NSString *identity=nil;
        AxsCacheKeeperExecState exec=axs_cachekeeper_exec(bundle,&identity,NULL,NULL);
        [AxsCacheKeeperProcessObservation observeBundle:bundle state:exec identity:identity atMonotonicTime:axs_cachekeeper_monotonic_seconds()];
    }
    if (busy) return;
    if (!queue) {
        queue = dispatch_queue_create("dev.local.cachekeeper.cleanup", DISPATCH_QUEUE_SERIAL);
        jobs = [NSMutableDictionary new]; finished = [NSMutableDictionary new]; discovery = [NSMutableDictionary new]; purgeDiscovery = [NSMutableDictionary new];
        // 未确认范围登记（方案任务 3 扩展）：bundle → 相对路径 → 登记记录
        // {rulesVersion, appVersion, exclusions, mtime, ctime, unresolved, unresolvedBytes, evidence}。
        // 未确认内容不阻塞其他根；登记的范围在规则/版本/排除/内容均未变且非手动重查时，
        // 跳过深度复查（不建 sweep），沿用登记的残留计数；任一触发条件变化即重新分析。
        unresolvedRanges = [NSMutableDictionary new]; jobReports = [NSMutableDictionary new];
        axs_cachekeeper_configure_receipts();
    }
    NSString *folder = axs_cachekeeper_folder();
    NSString *selectionFile = [folder stringByAppendingPathComponent:@"directories.plist"];
    NSString *stateFile = [folder stringByAppendingPathComponent:@"appEnabled.plist"];
    NSDictionary *selection = [NSDictionary dictionaryWithContentsOfFile:selectionFile];
    NSDictionary *states = [NSDictionary dictionaryWithContentsOfFile:stateFile];
    if ((!selection && [NSFileManager.defaultManager fileExistsAtPath:selectionFile]) ||
        (!states && [NSFileManager.defaultManager fileExistsAtPath:stateFile])) {
        // 配置不可读：无法枚举应观测的 bundle，全部挂起起点作废，不继承未持续维护的窗口。
        [AxsCacheKeeperProcessObservation invalidateAllBundles];
        NSLog(@"[CacheKeeper] 用户配置不可读，取消旧作业并重试待保存回执");
        selection=@{}; states=@{};
    }
    NSMutableSet *bundles = [NSMutableSet setWithArray:selection.allKeys ?: @[]];
    [bundles addObjectsFromArray:states.allKeys ?: @[]];
    [bundles addObjectsFromArray:axs_cachekeeper_manual.allObjects ?: @[]];
    NSMutableDictionary *targets = [NSMutableDictionary new];
    if (!states) [AxsCacheKeeperProcessObservation invalidateAllBundles];
    for (NSString *bundle in bundles) {
        if (!axs_cachekeeper_bundle_id(bundle)) continue;
        if (!axs_cachekeeper_app_enabled(states[bundle])) {
            // 未启用：清除旧挂起记录（见定时入口同款处理）；同时取消其手动请求。
            [AxsCacheKeeperProcessObservation observeBundle:bundle state:AxsCacheKeeperExecUnknown identity:nil atMonotonicTime:axs_cachekeeper_monotonic_seconds()];
            [axs_cachekeeper_manual removeObject:bundle]; continue;
        }
        NSArray *selected = axs_cachekeeper_selected_paths(selection, states, bundle);
        BOOL manual = [axs_cachekeeper_manual containsObject:bundle];
        NSString *mode = axs_cachekeeper_mode(states[bundle]);
        NSArray *paths = selected;
        NSURL *home = Container(bundle);
        NSMutableArray *roots = [NSMutableArray new];
        if (home) for (NSString *relative in paths) [roots addObject:[home.path stringByAppendingPathComponent:relative]];
        NSString *reason=nil, *execIdentity=nil;
        AxsCacheKeeperExecState exec=axs_cachekeeper_exec(bundle,&execIdentity,NULL,&reason);
        [AxsCacheKeeperProcessObservation observeBundle:bundle state:exec identity:execIdentity atMonotonicTime:axs_cachekeeper_monotonic_seconds()];
        AxsCacheKeeperProcessState process=AxsCacheKeeperProcessUnknown;
        AxsCacheKeeperSignalConfidence confidence=AxsCacheKeeperSignalNone;
        NSString *instance=[AxsCacheKeeperProcessObservation lastExecutingIdentityForBundle:bundle] ?: @"";
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
            if ([AxsCacheKeeperProcessObservation allowsSuspendedCleanupForBundle:bundle identity:execIdentity atMonotonicTime:axs_cachekeeper_monotonic_seconds()]) {
                process=AxsCacheKeeperProcessStopped;
                reason=@"APP 进程已被系统挂起且持续满 60 秒（未在执行），按已退出处理";
            } else {
                process=AxsCacheKeeperProcessRunning;
                reason=@"APP 进程已被系统挂起（未在执行），稳定确认中；持续挂起满 60 秒后自动清理";
            }
        }
        id rawVersion=SRead(AxsCacheKeeperAppProxy(bundle),@"shortVersionString");
        NSString *version=[rawVersion isKindOfClass:NSString.class] ? rawVersion : @"";
        targets[bundle] = @{@"version":version, @"roots":roots, @"paths":paths, @"home":home.path ?: @"", @"mode":mode,
            @"manual":@(manual), @"process":@(process), @"processReason":reason ?: @"",
            @"instance":instance, @"revision":@([AxsCacheKeeperProcessObservation revisionForBundle:bundle]), @"confidence":@(confidence)};
    }
    busy = YES;
    dispatch_async(queue, ^{
        // 回执重试与清理资格无关，停用/运行中/配置移除仍能补记。
        [AxsCacheKeeperReceipts flushAllPending];
        NSString *journal = [folder stringByAppendingPathComponent:@"permissions.plist"];
        NSDictionary *restored = axs_cachekeeper_restore_paths(nil, journal);
        NSUInteger unlocatedRestoreFailures = [restored[@"unlocatedFailures"] unsignedIntegerValue];
        for (NSString *bundle in jobs.allKeys) if (!targets[bundle]) {
            [AxsCacheKeeperCleanupSchedule retireJob:jobs[bundle] bundle:bundle message:@"APP 已停用或配置不可用，已停止本轮清理"];
            [jobs removeObjectForKey:bundle]; [jobReports removeObjectForKey:bundle];
        }
        for (NSString *bundle in finished.allKeys) if (!targets[bundle]) [finished removeObjectForKey:bundle];
        for (NSString *bundle in discovery.allKeys) if (!targets[bundle]) [discovery removeObjectForKey:bundle];
        for (NSString *bundle in purgeDiscovery.allKeys) if (!targets[bundle]) [purgeDiscovery removeObjectForKey:bundle];
        for (NSString *bundle in unresolvedRanges.allKeys) if (!targets[bundle]) [unresolvedRanges removeObjectForKey:bundle];
        for (NSString *bundle in targets) {
            NSDictionary *target = targets[bundle];
            NSArray *roots = target[@"roots"], *paths = target[@"paths"];
            BOOL manual = [target[@"manual"] boolValue];
            NSString *mode = target[@"mode"];
            NSArray *restoreExclusions=[AxsCacheKeeperCleanupSchedule restoreExclusions:restored home:target[@"home"]];
            if (![target[@"home"] length]) {
                [AxsCacheKeeperCleanupSchedule retireJob:jobs[bundle] bundle:bundle message:@"APP 数据容器不可用，已停止本轮清理"];
                [jobs removeObjectForKey:bundle]; [jobReports removeObjectForKey:bundle];
                [AxsCacheKeeperReceipts updateStatusForBundle:bundle phase:@"error" message:@"无法解析 APP 数据容器" failed:1 effectivePaths:paths discoveredPaths:nil directories:nil]; continue;
            }
            if ([target[@"process"] integerValue] != AxsCacheKeeperProcessStopped ||
                [target[@"confidence"] integerValue] != AxsCacheKeeperSignalStrong) {
                [AxsCacheKeeperCleanupSchedule retireJob:jobs[bundle] bundle:bundle message:@"APP 重新运行或状态未确认，已停止本轮清理"];
                [jobs removeObjectForKey:bundle]; [jobReports removeObjectForKey:bundle]; [finished removeObjectForKey:bundle];
                NSString *message = target[@"processReason"];
                if (axs_cachekeeper_should_prevent(states[bundle])) message = [message stringByAppendingFormat:@"\n%@", axs_cachekeeper_network_status(bundle)];
                [AxsCacheKeeperReceipts updateStatusForBundle:bundle phase:@"waiting" message:message failed:0 effectivePaths:paths discoveredPaths:nil directories:nil]; continue;
            }
            NSArray *discovered=@[];
            NSString *discoveryError=@"";
            if (axs_cachekeeper_auto_discover(states[bundle])) {
                NSDictionary *known=discovery[bundle];
                NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
                if (![known[@"home"] isEqual:target[@"home"]] || now-[known[@"time"] doubleValue]>=30) {
                    NSError *error=nil;
                    NSArray *found=axs_cachekeeper_discover_cache_roots([NSURL fileURLWithPath:target[@"home"]],&error);
                    // 读取失败永不缓存为"无内容"（任务 6）：本次返回空且旧缓存有根时沿用旧根，
                    // 错误照常记录并上报；30 秒后重试，恢复后新结果替换。
                    if (error && [known[@"home"] isEqual:target[@"home"]]) found=axs_cachekeeper_parent_paths([(found ?: @[]) arrayByAddingObjectsFromArray:known[@"paths"] ?: @[]]);
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
                // 读取失败永不缓存为"无内容"（任务 6）：同标准根发现，空结果时沿用旧候选。
                if (purgeError && [knownPurge[@"home"] isEqual:target[@"home"]]) found=axs_cachekeeper_parent_paths([(found ?: @[]) arrayByAddingObjectsFromArray:knownPurge[@"paths"] ?: @[]]);
                knownPurge=@{@"home":target[@"home"],@"time":@(nowPurge),@"paths":found ?: @[],@"error":purgeError.localizedDescription ?: @""};
                purgeDiscovery[bundle]=knownPurge;
            }
            purgeCandidates=knownPurge[@"paths"];
            NSArray *purgePaths=axs_cachekeeper_purge_paths(purgeCandidates, states[bundle]);
            // 发现错误合并（任务 6）：标准根与未知候选的发现错误同进消息与失败计数，
            // 不只报其一；覆盖完整性已在提交时合并两路错误。
            NSString *purgeErrorMessage = knownPurge[@"error"] ?: @"";
            NSString *discoveryErrors = discoveryError.length && purgeErrorMessage.length ?
                [NSString stringWithFormat:@"%@\n%@", discoveryError, purgeErrorMessage] :
                (discoveryError.length ? discoveryError : purgeErrorMessage);
            // 未确认登记剪枝：不再是候选的范围移除登记（下次重入候选时重新分析）。
            NSMutableDictionary *bundleRanges = unresolvedRanges[bundle];
            if (bundleRanges.count) {
                NSMutableSet *candidates = [NSMutableSet setWithArray:paths];
                [candidates addObjectsFromArray:purgePaths];
                for (NSString *registered in bundleRanges.allKeys) if (![candidates containsObject:registered]) [bundleRanges removeObjectForKey:registered];
            }
            if (!paths.count && !purgePaths.count) {
                [AxsCacheKeeperCleanupSchedule retireJob:jobs[bundle] bundle:bundle message:@"可清范围已移除，已停止本轮清理"];
                [jobs removeObjectForKey:bundle]; [jobReports removeObjectForKey:bundle]; [finished removeObjectForKey:bundle];
                NSString *message=discoveryErrors.length ? discoveryErrors : @"没有可处理的缓存目录；已尊重手动排除，网络限制按独立选项执行";
                if (unlocatedRestoreFailures) message=[message stringByAppendingFormat:@"\n权限恢复记录异常：%@",restored[@"error"]];
                NSUInteger failures=(discoveryErrors.length ? 1 : 0)+unlocatedRestoreFailures;
                [AxsCacheKeeperReceipts updateStatusForBundle:bundle phase:failures ? @"error" : @"waiting" message:message failed:failures effectivePaths:@[] discoveredPaths:axs_cachekeeper_auto_discover(states[bundle]) ? discovered : nil directories:nil];continue;
            }
            BOOL hasLogRoot = NO;
            BOOL hasPlatformRoot = NO;
            for (NSString *path in paths) {
                if ([axs_cachekeeper_log_paths(states[bundle]) containsObject:path]) hasLogRoot = YES;
                if ([path isEqual:@"Library/Caches"] || [path isEqual:@"tmp"] ||
                    [path hasPrefix:@"Library/Caches/"] || [path hasPrefix:@"tmp/"]) hasPlatformRoot = YES;
            }
            BOOL hasPurgeRoot = purgePaths.count > 0;
            // 排除边界与规则版本参与 job 签名：排除变化或规则升级使旧 job 失效，下轮重建决定。
            // 容器路径已在签名内（roots 为绝对路径，含 home 前缀）：重装换容器即签名变化，静默期失效。
            // 任务 8 起签名不再含 fullClear（该键已废止，标准缓存统一按平台规则处理）。
            NSString *exclusionsString = [axs_cachekeeper_exclusions(states[bundle]) componentsJoinedByString:@"\n"] ?: @"";
            NSString *signature = [NSString stringWithFormat:@"%@\n%@\n%@\n%@\n%@\n%@\n%@\n%@\n%@\n%@", [roots componentsJoinedByString:@"\n"], mode, target[@"instance"], [purgePaths componentsJoinedByString:@"\n"], exclusionsString, [AxsCacheKeeperCleanupRules rulesVersion], target[@"version"], [axs_cachekeeper_log_paths(states[bundle]) componentsJoinedByString:@"\n"], [restoreExclusions componentsJoinedByString:@"\n"], target[@"revision"]];
            NSDictionary *done = finished[bundle];
            // 静默期（方案任务 3，P1-3＋扩展）：1800 秒只给真正干净的完成轮——结束原因 Completed
            //（触顶/未确认轮不算，哪怕 0 删除）、无删除、无失败、无变化、无近期待处理文件、
            // 无未确认残留、发现覆盖完整。任一条件不满足都按 30 秒重试；APP 再次运行
            //（新实例→签名变化）、规则升级、排除改变或容器改变时不受限；手动清理不受限。
            if (!manual && !discoveryErrors.length && !restoreExclusions.count && !unlocatedRestoreFailures &&
                [AxsCacheKeeperCleanupSchedule shouldSkipSummary:done signature:signature now:axs_cachekeeper_monotonic_seconds()]) continue;
            AxsCacheKeeperCleanupJob *job = jobs[bundle];
            // 手动重查（用户点检测目录）强制重建作业并清空未确认登记：完整重查，
            // 不受静默期与登记跳过约束。重建即消耗手动请求（异步清标志，避免下周期
            // 重复重建）；重建不丢失已上报增量（每周期末已写回执，新作业从 0 起计）。
            if (manual) {
                [unresolvedRanges removeObjectForKey:bundle];
                dispatch_async(dispatch_get_main_queue(), ^{ [axs_cachekeeper_manual removeObject:bundle]; });
            }
            if (manual || ![job.signature isEqual:signature]) {
                [AxsCacheKeeperCleanupSchedule retireJob:job bundle:bundle message:@"配置、版本或范围改变，已结算旧轮清理"];
                [jobs removeObjectForKey:bundle]; [jobReports removeObjectForKey:bundle];
                if ([AxsCacheKeeperReceipts hasPendingForBundle:bundle]) continue;
                NSMutableArray *sweeps=[NSMutableArray new];
                NSMutableDictionary *diagnostics=[NSMutableDictionary new];
                NSMutableDictionary *sweepState=[states[bundle] isKindOfClass:NSDictionary.class] ? [states[bundle] mutableCopy] : [NSMutableDictionary new];
                sweepState[@"unavailablePaths"]=restoreExclusions;
                NSArray *ranges=axs_cachekeeper_parent_paths([paths arrayByAddingObjectsFromArray:purgePaths]);
                for (NSString *relative in ranges) {
                    NSString *root=[target[@"home"] stringByAppendingPathComponent:relative];
                    BOOL blocked=NO;
                    for (NSString *failedPath in restoreExclusions) if (!failedPath.length || [relative isEqual:failedPath] || [relative hasPrefix:[failedPath stringByAppendingString:@"/"]]) { blocked=YES; break; }
                    if (blocked) {
                        [unresolvedRanges[bundle] removeObjectForKey:relative];
                        diagnostics[relative]=@{@"updated":NSDate.date,@"measurementComplete":@NO,@"coverageComplete":@NO,@"failed":@1,@"error":restored[@"error"] ?: @"旧权限恢复失败"};
                        continue;
                    }
                    NSString *rangeError=nil;
                    AxsCacheKeeperRangeState rangeState=[AxsCacheKeeperCleanupSchedule checkRoot:root registration:unresolvedRanges[bundle][relative] signature:signature now:axs_cachekeeper_monotonic_seconds() stat:nil error:&rangeError];
                    if (rangeState==AxsCacheKeeperRangeUnchanged) continue;
                    [unresolvedRanges[bundle] removeObjectForKey:relative];
                    if (rangeState==AxsCacheKeeperRangeMissing) continue;
                    if (rangeState==AxsCacheKeeperRangeFailed) {
                        diagnostics[relative]=@{@"updated":NSDate.date,@"measurementComplete":@NO,@"coverageComplete":@NO,@"failed":@1,@"error":rangeError};
                        continue;
                    }
                    [sweeps addObject:[[AxsCacheKeeperSweep alloc] initWithRoot:root bundle:bundle version:target[@"version"] containerPath:target[@"home"] state:sweepState]];
                }
                // 失败子树单列诊断；父范围通过本轮排除仍可处理独立 sibling。
                for (NSString *failedPath in restoreExclusions) if (failedPath.length) {
                    for (NSString *relative in ranges) if ([failedPath hasPrefix:[relative stringByAppendingString:@"/"]])
                        diagnostics[failedPath]=@{@"updated":NSDate.date,@"measurementComplete":@NO,@"coverageComplete":@NO,@"failed":@1,@"error":restored[@"error"] ?: @"旧权限恢复失败"};
                }
                jobReports[bundle]=diagnostics;
                job = [[AxsCacheKeeperCleanupJob alloc] initWithSweeps:sweeps signature:signature instance:target[@"instance"] ?: @"" clock:^NSTimeInterval { return axs_cachekeeper_monotonic_seconds(); }];
                jobs[bundle] = job;
            }
            if ([AxsCacheKeeperReceipts hasPendingForBundle:bundle]) continue;
            NSString *jobInstance = job.instance;
            // 放行判定逐 sweep 采样：每周期采样一次时，周期内重开 APP 或关闭总开关要到
            // 下一周期才停手，至多 36 根 × 256 项的超删；逐 sweep 采样把超删界定在一根
            // （256 项，远不足 2 秒），采样量 ≤36 次/周期，远低于逐文件采样的 9216 次
            // （#42 实证：逐文件采样把单周期拖到约 10 秒；审计 #42 后续，用户 12:19 定）。
            // 作业每周期每根调用一次本块（预检与删除都一样）；根内不再重采。
            BOOL (^sampleGate)(void) = ^BOOL {
                __block BOOL allowed = NO;
                dispatch_sync(dispatch_get_main_queue(), ^{
                    NSDictionary *currentSelection = [NSDictionary dictionaryWithContentsOfFile:selectionFile];
                    NSDictionary *currentStates = [NSDictionary dictionaryWithContentsOfFile:stateFile];
                    BOOL readable = (currentSelection || ![NSFileManager.defaultManager fileExistsAtPath:selectionFile]) &&
                        (currentStates || ![NSFileManager.defaultManager fileExistsAtPath:stateFile]);
                    NSArray *currentPaths = axs_cachekeeper_effective_paths(currentSelection[bundle],currentStates[bundle],discovered);
                    BOOL selected = [currentPaths isEqual:paths] && [axs_cachekeeper_mode(currentStates[bundle]) isEqual:mode] &&
                        [axs_cachekeeper_log_paths(currentStates[bundle]) isEqual:axs_cachekeeper_log_paths(states[bundle])] &&
                        [axs_cachekeeper_exclusions(currentStates[bundle]) isEqual:axs_cachekeeper_exclusions(states[bundle])];
                    // 未知目录候选集须同步复核：中途被定级为日志或手动排除的目录，本轮立即停手，下一轮改走日志模式。
                    NSArray *currentPurgePaths = axs_cachekeeper_purge_paths(purgeCandidates, currentStates[bundle]);
                    BOOL purgeOK = [currentPurgePaths isEqual:purgePaths];
                    // 实例绑定：任务存续期间观测到不同实例运行过，说明目标缓存可能已被新实例接管，旧任务过期。
                    NSString *seen = [AxsCacheKeeperProcessObservation lastExecutingIdentityForBundle:bundle];
                    BOOL instanceOK = ![jobInstance length] || ![seen length] || [seen isEqual:jobInstance];
                    // 仅清理未知目录的任务没有缓存根，currentPaths 为空是正常态：任一根存在即放行。
                    // 任务 9：三种模式共用引擎，门控不再按模式拦截清理（模式只决定网络限制）。
                    allowed = readable && selected && (currentPaths.count || currentPurgePaths.count) && [Container(bundle).path isEqual:target[@"home"]] &&
                        axs_cachekeeper_gate_open(bundle, jobInstance) && instanceOK && purgeOK &&
                        [AxsCacheKeeperProcessObservation revisionForBundle:bundle]==[target[@"revision"] unsignedIntegerValue];
                });
                return allowed;
            };
            // 单周期推进由作业驱动：Checking 阶段只预检全部根；全部预检完成才转入删除，
            // 120 秒期限从首次真实删除推进起算；2000 项全作业共享硬上限（方案任务 3）。
            [job advanceCycleWithPerRootLimit:256 gate:sampleGate];
            NSUInteger removed=job.removed, protectedCount=job.protectedCount, inspected=job.inspected;
            unsigned long long bytes=job.bytes;
            BOOL checking=job.phase==AxsCacheKeeperCleanupPhaseChecking;
            NSString *error=@"";
            NSMutableDictionary *directoryReports=[jobReports[bundle] mutableCopy] ?: [NSMutableDictionary new];
            for (AxsCacheKeeperSweep *sweep in job.sweeps) directoryReports[sweep.relativePath]=[sweep directoryReport];
            for (NSString *relative in unresolvedRanges[bundle]) {
                if (!directoryReports[relative] && ([paths containsObject:relative] || [purgePaths containsObject:relative]))
                    directoryReports[relative]=[AxsCacheKeeperCleanupSchedule carriedReport:unresolvedRanges[bundle][relative]];
            }
            for (NSDictionary *report in directoryReports.allValues) if ([report[@"error"] length]) error=report[@"error"];
            if (discoveryErrors.length) error=discoveryErrors;
            if (unlocatedRestoreFailures) error=restored[@"error"] ?: @"旧权限恢复记录失败，无法定位具体路径";
            NSUInteger externalFailures=unlocatedRestoreFailures+(discoveryError.length ? 1 : 0)+(purgeErrorMessage.length ? 1 : 0);
            NSDictionary *summary=[AxsCacheKeeperCleanupSchedule summaryForJob:job directories:directoryReports externalFailures:externalFailures discoveryComplete:!discoveryErrors.length];
            NSUInteger failures=[summary[@"failed"] unsignedIntegerValue], recentCount=[summary[@"recent"] unsignedIntegerValue],
                changedCount=[summary[@"changed"] unsignedIntegerValue], unresolvedCount=[summary[@"unresolved"] unsignedIntegerValue];
            unsigned long long unresolvedBytes=[summary[@"unresolvedBytes"] unsignedLongLongValue];
            AxsCacheKeeperCleanupEndReason endReason=[summary[@"endReason"] integerValue];
            BOOL complete=endReason==AxsCacheKeeperCleanupEndReasonCompleted;
            BOOL cancelled=endReason==AxsCacheKeeperCleanupEndReasonCancelled;
            BOOL capHit=endReason==AxsCacheKeeperCleanupEndReasonLimitReached;
            BOOL unresolvedEnd=endReason==AxsCacheKeeperCleanupEndReasonUnresolved;
            BOOL hasUnresolved=unresolvedCount>0;
            // 回执按 roundID 幂等提交本轮累计（任务 4）：模块内部按轮次核算增量，重复提交不重复计入；
            // 写失败时快照滞留模块待处理队列，作业替换/取消不清除，下周期重试落盘。
            NSString *phase = @"cleaning", *message = @"正在分批清理；无需重新检测目录";
            if (checking) message=[NSString stringWithFormat:@"正在检查数据目录，已检查 %lu 项；预检完成后才删除",(unsigned long)inspected];
            if (cancelled) {
                phase = @"waiting"; message = @"APP 重新运行或配置改变，已停止清理";
                if (removed) message = [message stringByAppendingFormat:@"；已清理 %lu 项 · %.2f MB", (unsigned long)removed, bytes / 1048576.0];
            } else if (complete || capHit || unresolvedEnd) {
                phase = failures ? @"error" : @"complete";
                // 部分完成：未确认残留的轮次只报部分完成（任务 3 扩展），不冒充“已经干净”。
                NSString *lead = unresolvedEnd ? @"本轮部分完成" : @"本轮检查完成";
                message = failures ? [@"本轮未全部完成：" stringByAppendingString:error] :
                    (capHit ? [NSString stringWithFormat:@"本轮已达单轮上限（2000 项或 120 秒），已清理 %lu 项 · %.2f MB；剩余内容顺延下轮继续", (unsigned long)removed, bytes / 1048576.0] :
                    [NSString stringWithFormat:@"%@；已清理 %lu 项 · %.2f MB；保留 %lu 项受保护内容、%lu 项未知内容待识别、%lu 项近期文件", lead, (unsigned long)removed, bytes / 1048576.0, (unsigned long)protectedCount, (unsigned long)unresolvedCount, (unsigned long)recentCount]);
                if (changedCount) message=[message stringByAppendingFormat:@"；%lu 项在预检后变化，已跳过等待下轮",(unsigned long)changedCount];
                if (hasPlatformRoot) message=[message stringByAppendingString:@"\n标准缓存目录（Library/Caches、tmp）内的文件按平台缓存用途约定处理，不按类型保留（60 秒内新文件除外）"];
                if (hasLogRoot) message=[message stringByAppendingString:@"\n含用户定级的日志目录：仅清理日志特征文件（.log/.alog/.xlog)，数据与未知内容保留"];
                if (hasPurgeRoot) message=[message stringByAppendingString:@"\n未知目录暂不自动清理（用途未确认），待专属识别规则按占用适配"];
                if (hasUnresolved) message=[message stringByAppendingFormat:@"\n未知内容残留 %lu 项 · %.2f MB（用途未确认，暂不自动清理）", (unsigned long)unresolvedCount, unresolvedBytes / 1048576.0];
                if (axs_cachekeeper_should_prevent(states[bundle])) message = [message stringByAppendingFormat:@"\n%@", axs_cachekeeper_network_status(bundle)];
            }
            if (axs_cachekeeper_auto_discover(states[bundle])) message=[message stringByAppendingFormat:@"\n自动识别已纳入 %lu 个缓存根（手动排除保持关闭）",(unsigned long)paths.count];
            if (discoveryErrors.length) message=[message stringByAppendingFormat:@"\n%@",discoveryErrors];
            if (unlocatedRestoreFailures) message=[message stringByAppendingFormat:@"\n权限恢复记录异常：%@",restored[@"error"]];
            // 回执写成功后才退役作业；写失败时保留已完成作业，下周期先重试落盘再推进
            //（暂停检查在作业构建前，见上）。一轮退役时把本轮总量记为上次清理；中途周期传 nil，沿用上一轮的值。
            NSDictionary *round = (complete || capHit || cancelled || unresolvedEnd) ? @{@"removed":@(removed), @"bytes":@(bytes)} : nil;
            BOOL reported = [AxsCacheKeeperReceipts submitRoundForBundle:bundle roundID:job.roundID removed:removed bytes:bytes endReason:(NSInteger)endReason phase:phase message:message failed:failures effectivePaths:paths discoveredPaths:axs_cachekeeper_auto_discover(states[bundle]) ? discovered : nil directories:directoryReports round:round coverageComplete:[summary[@"coverageComplete"] boolValue]];
            if (reported) {
                if (cancelled || complete || capHit || unresolvedEnd) {
                    // 结束记录供静默期判定：结束原因＋近期文件数＋未确认残留＋发现覆盖完整性（方案任务 3）。
                    // 取消的轮次不记录（下周期立即重开，不受静默期约束）。
                    if (complete || capHit || unresolvedEnd) {
                        NSMutableDictionary *finishedSummary=[summary mutableCopy];
                        finishedSummary[@"signature"]=signature; finishedSummary[@"finishedAt"]=@(axs_cachekeeper_monotonic_seconds());
                        finished[bundle]=finishedSummary;
                    }
                    for (AxsCacheKeeperSweep *sweep in job.sweeps) {
                        NSDictionary *registration=[AxsCacheKeeperCleanupSchedule registrationForSweep:sweep signature:signature now:axs_cachekeeper_monotonic_seconds()];
                        if (registration) {
                            if (!unresolvedRanges[bundle]) unresolvedRanges[bundle]=[NSMutableDictionary new];
                            unresolvedRanges[bundle][sweep.relativePath]=registration;
                        } else [unresolvedRanges[bundle] removeObjectForKey:sweep.relativePath];
                    }
                    [jobReports removeObjectForKey:bundle];
                    [jobs removeObjectForKey:bundle];
                    if (manual && (complete || cancelled || unresolvedEnd)) dispatch_async(dispatch_get_main_queue(), ^{ [axs_cachekeeper_manual removeObject:bundle]; });
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ busy = NO; });
    });
}
