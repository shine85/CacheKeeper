#import <UIKit/UIKit.h>
#import <objc/message.h>
#include <roothide.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString *const DouyinID = @"com.ss.iphone.ugc.Aweme";
static NSString *const ShortcutType = @"dev.local.cachekeeper.clean";
static BOOL busy;
extern "C" void CKScanRequests(void);
extern "C" void CKApplyDirectorySwitches(void);
extern "C" void CKPermissions(NSURL *,BOOL);
static id Read(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] ? ((id(*)(id,SEL))objc_msgSend)(object,selector) : nil;
}
static id Proxy(void) {
    Class cls = NSClassFromString(@"LSApplicationProxy");
    SEL selector = NSSelectorFromString(@"applicationProxyForIdentifier:");
    return [cls respondsToSelector:selector] ? ((id(*)(id,SEL,id))objc_msgSend)(cls,selector,DouyinID) : nil;
}
static BOOL Running(BOOL *known) {
    id manager = Read(NSClassFromString(@"SBApplicationController"),@"sharedInstance");
    SEL lookup = NSSelectorFromString(@"applicationWithBundleIdentifier:");
    if (![manager respondsToSelector:lookup]) { *known = NO; return YES; }
    id app = ((id(*)(id,SEL,id))objc_msgSend)(manager,lookup,DouyinID);
    id state = Read(app,@"processState") ?: Read(app,@"_internalProcessState");
    SEL selector = NSSelectorFromString(@"isRunning");
    *known = [state respondsToSelector:selector];
    return *known ? ((BOOL(*)(id,SEL))objc_msgSend)(state,selector) : YES;
}
static void Report(NSString *message, NSUInteger count, unsigned long long bytes) {
    NSString *path = [jbroot(@"/var/mobile/Library/CacheKeeper/Status") stringByAppendingPathComponent:[DouyinID stringByAppendingString:@".plist"]];
    [@{@"mode":message,@"removed":@(count),@"bytes":@(bytes),@"updated":NSDate.date} writeToFile:path atomically:YES];
}
static void CleanDouyin(void) {
    if (busy) return;
    BOOL known;
    if (Running(&known) || !known) { Report(@"请先从多任务上划关闭抖音",0,0); return; }
    id proxy = Proxy();
    NSString *version = Read(proxy,@"shortVersionString");
    if (![version isEqualToString:@"40.9.0"]) { Report(@"版本不匹配，仅适配 40.9.0",0,0); return; }
    NSURL *home = Read(proxy,@"dataContainerURL");
    if (![home isKindOfClass:NSURL.class]) { Report(@"无法读取抖音数据目录",0,0); return; }
    home = home.URLByResolvingSymlinksInPath;
    if (![home.path containsString:@"/Containers/Data/Application/"]) { Report(@"数据目录校验失败",0,0); return; }
    NSURL *root = [home URLByAppendingPathComponent:@"Library/Caches" isDirectory:YES];
    if (![root.path isEqualToString:root.URLByResolvingSymlinksInPath.path]) { Report(@"缓存目录为链接，已跳过",0,0); return; }
    busy = YES;
    Report(@"正在清理",0,0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        NSUInteger removed = 0;
        unsigned long long bytes = 0;
        NSString *message = @"进程退出后清理完成";
        NSDirectoryEnumerator *entries = [NSFileManager.defaultManager enumeratorAtURL:root includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsPackageDescendants errorHandler:^BOOL(NSURL *url,NSError *error) { return YES; }];
        NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime+10;
        NSUInteger entryIndex = 0;
        for (NSURL *entry in entries) {
            // 0.3.8 优化：原实现每个文件都 dispatch_sync 到主线程查一次进程状态，
            // 千级文件时主线程往返成为主要耗时。改为每 200 个文件查一次，语义不变。
            if (entryIndex++ % 200 == 0) {
                __block BOOL running = YES;
                dispatch_sync(dispatch_get_main_queue(), ^{ BOOL known; running = Running(&known); });
                if (running) { message = @"抖音已重新启动，停止清理"; break; }
            }
            if (NSProcessInfo.processInfo.systemUptime > deadline) { message = @"达到时限，下次继续清理"; break; }
            struct stat info;
            if (lstat(entry.path.fileSystemRepresentation,&info)) continue;
            if (S_ISLNK(info.st_mode)) { [entries skipDescendants]; continue; }
            if (!S_ISREG(info.st_mode)) continue;
            NSString *parent = entry.URLByDeletingLastPathComponent.URLByResolvingSymlinksInPath.path;
            if (![parent isEqual:root.path] && ![parent hasPrefix:[root.path stringByAppendingString:@"/"]]) continue;
            if (!unlink(entry.path.fileSystemRepresentation)) { removed++; bytes += info.st_size; }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ busy = NO; Report(message,removed,bytes); });
    });
}
@interface SBIconView : UIView
@end
@interface SBSApplicationShortcutItem : NSObject
@property(nonatomic,copy) NSString *type;
@property(nonatomic,copy) NSString *localizedTitle;
@end
%hook SBIconView
- (void)setApplicationShortcutItems:(NSArray *)items {
    id icon = Read(self,@"icon");
    NSString *bundle = Read(icon,@"applicationBundleID");
    if (![bundle isEqual:DouyinID]) {
        %orig;
        return;
    }
    NSMutableArray *updated = [NSMutableArray arrayWithArray:items ?: @[]];
    for (id item in updated) {
        if ([Read(item,@"type") isEqual:ShortcutType]) {
            %orig;
            return;
        }
    }
    SBSApplicationShortcutItem *item = [NSClassFromString(@"SBSApplicationShortcutItem") new];
    item.type = ShortcutType; item.localizedTitle = @"清理抖音缓存";
    if (item) [updated addObject:item];
    %orig(updated);
}
+ (void)activateShortcut:(id)item withBundleIdentifier:(NSString *)bundle forIconView:(id)view {
    if ([bundle isEqual:DouyinID] && [Read(item,@"type") isEqual:ShortcutType]) { CleanDouyin(); return; }
    %orig;
}
%end
%ctor {
    if (![NSBundle.mainBundle.bundleIdentifier isEqual:@"com.apple.springboard"]) return;
    %init;
    dispatch_async(dispatch_get_main_queue(), ^{
        // 0.3.8 优化：扫描与目录限制原本在 SpringBoard 主线程同步执行（枚举目录、改权限、
        // 反复写 plist），2 秒一次会卡桌面主线程。改到专用串行队列执行，忙时跳过本轮，
        // 不堆积不重入；队列内对 SBApplicationController 的进程状态只做只读查询。
        // 0.3.9 变更：删除原留在主线程的「抖音退出自动清理」判断——它依赖无人写入的
        // settings.plist 名单，在新装设备上永不触发；一并去掉它每 2 秒在主线程读
        // 三份 plist 的开销。抖音手动清理（图标长按菜单）不受影响。
        static dispatch_queue_t workQueue;
        workQueue = dispatch_queue_create("dev.local.cachekeeper.springboard", DISPATCH_QUEUE_SERIAL);
        __block BOOL workBusy = NO;
        NSTimer *timer = [NSTimer timerWithTimeInterval:2 repeats:YES block:^(NSTimer *timer) {
            if (!workBusy) {
                workBusy = YES;
                dispatch_async(workQueue, ^{
                    CKScanRequests();
                    CKApplyDirectorySwitches();
                    dispatch_async(dispatch_get_main_queue(), ^{ workBusy = NO; });
                });
            }
        }];
        [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    });
}
