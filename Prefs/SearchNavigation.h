#pragma once
#import <UIKit/UIKit.h>

// Temporary UIKit state only. Callers must not retain these controller references in claims
// or diagnostics; the latter export only each state's bounded ownership dictionary.
@protocol AxsCacheKeeperSearchNavigationOwner <NSObject>
- (NSArray<NSDictionary *> *)axs_cachekeeper_search_navigation_states;
- (NSDictionary *)axs_cachekeeper_search_layout_state;
@end

static inline NSDictionary *axs_cachekeeper_search_navigation_claim(NSArray<NSDictionary *> *claims,UINavigationItem *item,UINavigationBar *bar) {
    for (NSDictionary *claim in claims)
        if (claim[@"item"]==item && claim[@"bar"]==bar) return claim;
    return nil;
}

static inline NSArray<NSDictionary *> *axs_cachekeeper_search_navigation_states(UIViewController *owner,BOOL appeared,NSArray<NSDictionary *> *claims) {
    NSMutableArray *states=[NSMutableArray new];
    UIWindow *window=owner.viewIfLoaded.window;
    UIViewController *child=owner;
    BOOL transitioning=owner.transitionCoordinator!=nil;
    for (UIViewController *parent=child.parentViewController;parent;child=parent,parent=parent.parentViewController) {
        transitioning=transitioning || parent.transitionCoordinator!=nil;
        if (![parent isKindOfClass:UINavigationController.class]) continue;
        UINavigationController *navigation=(UINavigationController *)parent;
        UINavigationBar *bar=navigation.navigationBar;
        UINavigationItem *item=bar.topItem;
        BOOL topMatches=navigation.topViewController==child;
        BOOL itemMatches=item && item==child.navigationItem;
        NSDictionary *claim=axs_cachekeeper_search_navigation_claim(claims,item,bar);
        BOOL visible=window && bar.window==window;
        for (UIView *view=bar;visible && view;view=view.superview)
            if (view.hidden || view.alpha<=0.01) visible=NO;
        NSString *reason=@"eligible";
        if (!topMatches) reason=@"branchMismatch";
        else if (!visible) reason=@"barUnavailable";
        else if (!item) reason=@"itemUnavailable";
        else if (!claim && transitioning) reason=@"transition";
        else if (!itemMatches && !claim && !appeared) reason=@"awaitingAppearance";
        BOOL eligible=[reason isEqual:@"eligible"];
        NSDictionary *ownership=@{@"topIsDirectChild":topMatches ? @YES : @NO,
            @"topItemIsChildItem":itemMatches ? @YES : @NO,
            @"topItemIsOwnerItem":(item && item==owner.navigationItem) ? @YES : @NO,
            @"candidateEligible":eligible ? @YES : @NO,
            @"claimActive":(eligible && claim && item.largeTitleDisplayMode==UINavigationItemLargeTitleDisplayModeNever) ? @YES : @NO,
            @"transitioning":transitioning ? @YES : @NO,@"appeared":appeared ? @YES : @NO,@"reason":reason};
        NSMutableDictionary *state=[@{@"navigation":navigation,@"bar":bar,@"ownership":ownership} mutableCopy];
        if (item) state[@"item"]=item;
        [states addObject:[state copy]];
        // A matching outer wrapper cannot make an off-top inner page visible again.
        if (!topMatches) break;
    }
    return [states copy];
}
