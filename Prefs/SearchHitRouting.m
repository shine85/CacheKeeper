#import "SearchHitRouting.h"
#import <objc/runtime.h>
#include <math.h>

@interface AxsCacheKeeperSearchHitOwnerBox : NSObject
@property(nonatomic,weak) id<AxsCacheKeeperSearchHitOwner> owner;
@end
@implementation AxsCacheKeeperSearchHitOwnerBox
@end

static char axs_cachekeeper_search_hit_owner_key;
static UIView *(*axs_cachekeeper_search_original_hit)(id,SEL,CGPoint,UIEvent *);

static UIView *axs_cachekeeper_search_bar_hit(id bar,SEL selector,CGPoint point,UIEvent *event) {
    UIView *hit=axs_cachekeeper_search_original_hit(bar,selector,point,event);
    // Preserve buttons, private bar descendants, and every unrelated instance verbatim.
    if (hit!=bar || !NSThread.isMainThread) return hit;
    AxsCacheKeeperSearchHitOwnerBox *box=objc_getAssociatedObject(bar,&axs_cachekeeper_search_hit_owner_key);
    id<AxsCacheKeeperSearchHitOwner> owner=box.owner;
    return owner && [owner axs_cachekeeper_search_passes_point:point fromBar:bar] ? nil : hit;
}

static BOOL axs_cachekeeper_search_bar_region_empty(UINavigationBar *bar,UIView *view,CGRect region,NSUInteger *remaining) {
    if (!*remaining) return NO;
    (*remaining)--;
    if (view.hidden || view.alpha<=0.01) return YES;
    CGRect rect=[view convertRect:view.bounds toView:bar];
    if (!isfinite(rect.origin.x) || !isfinite(rect.origin.y) || !isfinite(rect.size.width) || !isfinite(rect.size.height)) return NO;
    CGRect overlap=CGRectIntersection(region,rect);
    if (!CGRectIsEmpty(overlap) && !CGRectIsNull(overlap)) {
        // Controls retain their space while UIKit temporarily suppresses interaction.
        if (view!=bar && ([view isKindOfClass:UIControl.class] || view.gestureRecognizers.count)) return NO;
        if ([view isKindOfClass:UILabel.class] && (((UILabel *)view).text.length || ((UILabel *)view).attributedText.length)) return NO;
        if ([view isKindOfClass:UIImageView.class] && (((UIImageView *)view).image || ((UIImageView *)view).highlightedImage)) return NO;
        CGPoint center=CGPointMake(CGRectGetMidX(overlap),CGRectGetMidY(overlap));
        UIView *hit=axs_cachekeeper_search_original_hit(bar,@selector(hitTest:withEvent:),center,nil);
        if (hit && hit!=bar) return NO;
    }
    if (view.clipsToBounds) {
        if (CGRectIsEmpty(overlap) || CGRectIsNull(overlap)) return YES;
        region=overlap;
    }
    for (UIView *child in view.subviews)
        if (!axs_cachekeeper_search_bar_region_empty(bar,child,region,remaining)) return NO;
    return YES;
}

@implementation AxsCacheKeeperSearchHitRouting
+ (void)axs_cachekeeper_claim_bar:(UINavigationBar *)bar owner:(id<AxsCacheKeeperSearchHitOwner>)owner {
    NSAssert(NSThread.isMainThread,@"Search hit routing belongs to the main thread");
    if (!bar || !owner) return;
    static dispatch_once_t once;
    dispatch_once(&once,^{
        Class type=UINavigationBar.class;SEL selector=@selector(hitTest:withEvent:);
        Method method=class_getInstanceMethod(type,selector);
        if (!method) return;
        axs_cachekeeper_search_original_hit=(UIView *(*)(id,SEL,CGPoint,UIEvent *))method_getImplementation(method);
        // Materialize an inherited method on UINavigationBar, never mutate UIView's Method.
        if (!class_addMethod(type,selector,(IMP)axs_cachekeeper_search_bar_hit,method_getTypeEncoding(method)))
            axs_cachekeeper_search_original_hit=(UIView *(*)(id,SEL,CGPoint,UIEvent *))method_setImplementation(method,(IMP)axs_cachekeeper_search_bar_hit);
    });
    if (!axs_cachekeeper_search_original_hit) return;
    AxsCacheKeeperSearchHitOwnerBox *existing=objc_getAssociatedObject(bar,&axs_cachekeeper_search_hit_owner_key);
    if (existing.owner==owner) return;
    AxsCacheKeeperSearchHitOwnerBox *box=[AxsCacheKeeperSearchHitOwnerBox new];box.owner=owner;
    objc_setAssociatedObject(bar,&axs_cachekeeper_search_hit_owner_key,box,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
+ (void)axs_cachekeeper_release_bar:(UINavigationBar *)bar owner:(id<AxsCacheKeeperSearchHitOwner>)owner {
    NSAssert(NSThread.isMainThread,@"Search hit routing belongs to the main thread");
    AxsCacheKeeperSearchHitOwnerBox *box=objc_getAssociatedObject(bar,&axs_cachekeeper_search_hit_owner_key);
    if (box.owner==owner) objc_setAssociatedObject(bar,&axs_cachekeeper_search_hit_owner_key,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Leave the chained original IMP installed; another tweak may have installed after us.
}
+ (BOOL)axs_cachekeeper_bar:(UINavigationBar *)bar owner:(id<AxsCacheKeeperSearchHitOwner>)owner has_empty_rect:(CGRect)rect {
    if (!NSThread.isMainThread || !bar || !owner || !axs_cachekeeper_search_original_hit) return NO;
    AxsCacheKeeperSearchHitOwnerBox *box=objc_getAssociatedObject(bar,&axs_cachekeeper_search_hit_owner_key);
    if (box.owner!=owner || class_getMethodImplementation(bar.class,@selector(hitTest:withEvent:))!=(IMP)axs_cachekeeper_search_bar_hit) return NO;
    if (!isfinite(rect.origin.x) || !isfinite(rect.origin.y) || !isfinite(rect.size.width) || !isfinite(rect.size.height) || CGRectIsEmpty(rect)) return NO;
    CGRect overlap=CGRectIntersection(rect,bar.bounds);
    if (CGRectIsEmpty(overlap) || CGRectIsNull(overlap)) return YES;
    NSUInteger remaining=128;
    return axs_cachekeeper_search_bar_region_empty(bar,bar,overlap,&remaining);
}
@end
