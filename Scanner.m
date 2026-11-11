#import <Foundation/Foundation.h>
#import <objc/message.h>
#include <roothide.h>
#include <sys/stat.h>
#include <signal.h>
#include <errno.h>
extern void CKSetPaths(NSArray *,BOOL);
extern NSArray *CKBaselineDirectories(NSString *,NSTimeInterval,BOOL,NSUInteger *,unsigned long long *);
static id SRead(id target,NSString *name) { SEL s=NSSelectorFromString(name);return [target respondsToSelector:s]?((id(*)(id,SEL))objc_msgSend)(target,s):nil; }
static NSURL *Container(NSString *bundle) {
    Class proxy=NSClassFromString(@"LSApplicationProxy"); SEL s=NSSelectorFromString(@"applicationProxyForIdentifier:");
    id app=[proxy respondsToSelector:s]?((id(*)(id,SEL,id))objc_msgSend)(proxy,s,bundle):nil;
    NSURL *home=SRead(app,@"dataContainerURL");
    if (![home isKindOfClass:NSURL.class]) return nil;
    home=home.URLByResolvingSymlinksInPath;
    return [home.path containsString:@"/Containers/Data/Application/"]?home:nil;
}
static NSArray *Candidates(NSURL *home) {
    NSMutableArray *paths=[NSMutableArray array];
    for (NSString *base in @[@"Library/Caches",@"Library/Application Support"]) {
        NSURL *root=[home URLByAppendingPathComponent:base];
        if (![root.path isEqual:root.URLByResolvingSymlinksInPath.path]) continue;
        NSArray *entries=[NSFileManager.defaultManager contentsOfDirectoryAtURL:root includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
        if ([base isEqual:@"Library/Caches"] && entries) [paths addObject:base];
        for (NSURL *entry in entries) {
            struct stat info;
            if (!lstat(entry.path.fileSystemRepresentation,&info) && S_ISDIR(info.st_mode) && !S_ISLNK(info.st_mode))
                [paths addObject:[base stringByAppendingPathComponent:entry.lastPathComponent]];
            if (paths.count>=150) return paths;
        }
    }
    return paths;
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
    NSArray *candidates=home?Candidates(home):@[];
    if (!batchItem) [NSFileManager.defaultManager removeItemAtPath:requestPath error:nil];
    busy=YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        NSMutableArray *rows=[NSMutableArray array];
        NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+15;
        for (NSString *relative in candidates) {
            NSURL *root=[home URLByAppendingPathComponent:relative];
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
        NSDictionary *result=@{@"token":token,@"bundle":bundle,@"home":home.path?:@"",@"rows":rows,@"updated":NSDate.date,@"previousRows":old[@"rows"]?:@[]};
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
    for (NSString *bundle in config) {
        BOOL masterOff = appEnabled[bundle] && ![appEnabled[bundle] boolValue];
        if (masterOff) continue;
        NSURL *home=Container(bundle); if (!home) continue;
        NSArray *candidates= Candidates(home);
        NSArray *selected = config[bundle];
        if (![selected isKindOfClass:NSArray.class]) continue;
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
        NSUInteger removed = 0;
        unsigned long long bytes = 0;
        BOOL attempted = NO;
        for (NSString *relative in selected) {
            if (![candidates containsObject:relative]) continue;
            NSString *path = [home.path stringByAppendingPathComponent:relative];
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
                NSArray *locked = record[@"locked"];
                // 0.3.8 优化：无清理事件的轮询原来也每 2 秒全量重扫目录树只为重建锁定清单。
                // 清单上一轮已存进 baselines.plist，目录被限写后集合基本冻结，直接复用；
                // 有清理时必重扫，每 30 轮（约 1 分钟）兜底刷新一次，防清单漂移。
                BOOL refreshLocked = (applyPolls % 30 == 0);
                if (!locked || cleanup || refreshLocked) {
                    locked = CKBaselineDirectories(path,cutoff.timeIntervalSince1970,cleanup,&removed,&bytes);
                    attempted |= cleanup;
                }
                next[@"locked"] = locked;
                [enabled addObjectsFromArray:locked];
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
}
