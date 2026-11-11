#import <UIKit/UIKit.h>
#import <objc/message.h>
#import "AxsCacheKeeperPolicy.h"
#include <roothide.h>

static NSString *const DouyinID = @"com.ss.iphone.ugc.Aweme";
static NSString *const ShortcutType = @"dev.local.cachekeeper.clean";
static id Read(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] ? ((id(*)(id,SEL))objc_msgSend)(object,selector) : nil;
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
    NSDictionary *directories=[NSDictionary dictionaryWithContentsOfFile:jbroot(@"/var/mobile/Library/CacheKeeper/directories.plist")];
    NSDictionary *states=[NSDictionary dictionaryWithContentsOfFile:jbroot(@"/var/mobile/Library/CacheKeeper/appEnabled.plist")];
    if (!axs_cachekeeper_can_clean(directories,states,bundle)) {
        NSMutableArray *filtered=[NSMutableArray new];
        BOOL removed=NO;
        for (id item in items) {
            if ([Read(item,@"type") isEqual:ShortcutType]) removed=YES;
            else [filtered addObject:item];
        }
        if (removed) %orig(filtered); else %orig;
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
    if ([bundle isEqual:DouyinID] && [Read(item,@"type") isEqual:ShortcutType]) { axs_cachekeeper_request_cleanup(DouyinID); return; }
    %orig;
}
%end
%ctor {
    if (![NSBundle.mainBundle.bundleIdentifier isEqual:@"com.apple.springboard"]) return;
    %init;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTimer *timer = [NSTimer timerWithTimeInterval:2 repeats:YES block:^(NSTimer *timer) {
            CKScanRequests();
            CKInspectRequests();
            CKApplyDirectorySwitches();
        }];
        [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    });
}
