#import <UIKit/UIKit.h>
#import <libSandy.h>
#include <roothide.h>
#include <unistd.h>

// 0.3.9 变更：整条删除旧版进程内清理路径（原 Selected()/Clean()）。
// 它唯一的名单来源是 settings.plist 的 apps 键，而现版本没有任何代码写这个
// 文件：新装设备上文件恒不存在，Selected() 恒为 NO，启动/退后台清理从不
// 触发，属死代码。进程内组件今后只负责生命周期信号上报
// （Status/<包名>.background.plist，基线建立依赖它）；实际清理由 SpringBoard
// 侧的基线/权限锁路径完成。与删除前在新装设备上的实际行为完全一致。
// 若今后要恢复「指定 App 退后台清 Caches」，应先在设置页补上写入方再恢复清理。
__attribute__((constructor)) static void Start(void) {
    @autoreleasepool {
        if (![NSHomeDirectory() containsString:@"/Containers/Data/Application/"] ||
            ![NSBundle.mainBundle.bundlePath.pathExtension isEqual:@"app"] ||
            [NSBundle.mainBundle.bundleIdentifier hasPrefix:@"com.apple."]) return;
        if (libSandy_applyProfile("CacheKeeperAccess") != kLibSandySuccess) return;
        // 0.4.0 可选硬手段：设置页开启「禁止网络缓存生成」后，把共享 NSURLCache 的
        // 内存与磁盘容量置 0，系统网络缓存不再生成落盘（唯一能真正禁止生成的品类）。
        // 登录与 Cookie 不存放在 NSURLCache 中，不受影响；代价是重复内容需重新下载。
        NSDictionary *policy = [NSDictionary dictionaryWithContentsOfFile:jbroot(@"/var/mobile/Library/CacheKeeper/policy.plist")][NSBundle.mainBundle.bundleIdentifier];
        // 0.4.6：未被用户开启的 App，插件在其进程内什么都不做——这个独立的
        // 网络缓存开关同样受总开关约束。
        NSNumber *masterOn = [NSDictionary dictionaryWithContentsOfFile:jbroot(@"/var/mobile/Library/CacheKeeper/appEnabled.plist")][NSBundle.mainBundle.bundleIdentifier];
        if ([masterOn boolValue] && [policy[@"urlCache"] boolValue])
            [NSURLCache setSharedURLCache:[[NSURLCache alloc] initWithMemoryCapacity:0 diskCapacity:0 diskPath:nil]];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *report = [jbroot(@"/var/mobile/Library/CacheKeeper/Status") stringByAppendingPathComponent:[NSBundle.mainBundle.bundleIdentifier stringByAppendingString:@".background.plist"]];
            NSDate *launched = NSDate.date;
            void (^markActive)(void) = ^{ [@{@"active":@YES,@"pid":@(getpid()),@"launched":launched} writeToFile:report atomically:YES]; };
            markActive();
            [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { markActive(); }];
            [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                [@{@"time":NSDate.date,@"pid":@(getpid()),@"launched":launched} writeToFile:report atomically:YES];
            }];
        });
    }
}
