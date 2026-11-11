#import <UIKit/UIKit.h>
#import <objc/message.h>
#include <roothide.h>

extern "C" void CKScanRequests(void);
extern "C" void CKApplyDirectorySwitches(void);

// 0.4.5：插件定位为纯自动——扫描、基线、限权、自动降级、退后台/退出清理全部
// 由下面的 2 秒引擎驱动，用户不需要对任何 App 做任何手动操作。原图标长按
// 「清理缓存」手动入口（0.4.3 曾通用化）按用户要求删除：手动清理不是这个
// 插件的价值所在，引擎自动完成同样的工作。
%ctor {
    if (![NSBundle.mainBundle.bundleIdentifier isEqual:@"com.apple.springboard"]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        // 0.3.8 定版：扫描与目录限制从 SpringBoard 主线程移到专用串行队列，
        // 忙时跳过本轮，不堆积不重入。
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
