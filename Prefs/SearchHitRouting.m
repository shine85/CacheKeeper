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

static BOOL axs_cachekeeper_search_finite_rect(CGRect rect) {
    return isfinite(rect.origin.x) && isfinite(rect.origin.y) && isfinite(rect.size.width) && isfinite(rect.size.height);
}
static NSArray *axs_cachekeeper_search_rect_values(CGRect rect) {
    return axs_cachekeeper_search_finite_rect(rect) ? @[@(rect.origin.x),@(rect.origin.y),@(rect.size.width),@(rect.size.height)] : @[];
}
static BOOL axs_cachekeeper_search_region_rejected(NSMutableDictionary *report,NSString *reason,UIView *view,CGRect overlap,UIView *hit) {
    if (report) {
        report[@"reason"]=reason;
        report[@"viewClass"]=view ? NSStringFromClass(view.class) : @"nil";
        report[@"kind"]=[view isKindOfClass:UIControl.class] ? @"control" : [view isKindOfClass:UILabel.class] ? @"label" :
            [view isKindOfClass:UIImageView.class] ? @"image" : [view isKindOfClass:UINavigationBar.class] ? @"bar" : @"view";
        report[@"intersection"]=axs_cachekeeper_search_rect_values(overlap);
        report[@"hitClass"]=hit ? NSStringFromClass(hit.class) : @"nil";
    }
    return NO;
}
static BOOL axs_cachekeeper_search_bar_region_empty(UINavigationBar *bar,UIView *view,CGRect region,NSUInteger *remaining,NSMutableDictionary *report) {
    if (!*remaining) return axs_cachekeeper_search_region_rejected(report,@"viewLimit",view,region,nil);
    (*remaining)--;
    if (view.hidden || view.alpha<=0.01) return YES;
    CGRect rect=[view convertRect:view.bounds toView:bar];
    if (!axs_cachekeeper_search_finite_rect(rect)) return axs_cachekeeper_search_region_rejected(report,@"viewGeometry",view,rect,nil);
    CGRect overlap=CGRectIntersection(region,rect);
    if (!CGRectIsEmpty(overlap) && !CGRectIsNull(overlap)) {
        // Controls retain their space while UIKit temporarily suppresses interaction.
        if (view!=bar && [view isKindOfClass:UIControl.class]) return axs_cachekeeper_search_region_rejected(report,@"control",view,overlap,nil);
        if (view!=bar && view.gestureRecognizers.count) return axs_cachekeeper_search_region_rejected(report,@"gesture",view,overlap,nil);
        if ([view isKindOfClass:UILabel.class] && (((UILabel *)view).text.length || ((UILabel *)view).attributedText.length))
            return axs_cachekeeper_search_region_rejected(report,@"text",view,overlap,nil);
        if ([view isKindOfClass:UIImageView.class] && (((UIImageView *)view).image || ((UIImageView *)view).highlightedImage))
            return axs_cachekeeper_search_region_rejected(report,@"image",view,overlap,nil);
        CGPoint center=CGPointMake(CGRectGetMidX(overlap),CGRectGetMidY(overlap));
        UIView *hit=axs_cachekeeper_search_original_hit(bar,@selector(hitTest:withEvent:),center,nil);
        if (hit && hit!=bar) return axs_cachekeeper_search_region_rejected(report,@"originalHit",view,overlap,hit);
    }
    if (view.clipsToBounds) {
        if (CGRectIsEmpty(overlap) || CGRectIsNull(overlap)) return YES;
        region=overlap;
    }
    for (UIView *child in view.subviews)
        if (!axs_cachekeeper_search_bar_region_empty(bar,child,region,remaining,report)) return NO;
    return YES;
}
static BOOL axs_cachekeeper_search_bar_rect_empty(UINavigationBar *bar,id<AxsCacheKeeperSearchHitOwner> owner,CGRect rect,NSMutableDictionary *report) {
    if (!NSThread.isMainThread) return axs_cachekeeper_search_region_rejected(report,@"thread",nil,rect,nil);
    if (!bar || !owner || !axs_cachekeeper_search_original_hit) return axs_cachekeeper_search_region_rejected(report,@"routeUnavailable",bar,rect,nil);
    AxsCacheKeeperSearchHitOwnerBox *box=objc_getAssociatedObject(bar,&axs_cachekeeper_search_hit_owner_key);
    if (box.owner!=owner) return axs_cachekeeper_search_region_rejected(report,@"owner",bar,rect,nil);
    if (class_getMethodImplementation(bar.class,@selector(hitTest:withEvent:))!=(IMP)axs_cachekeeper_search_bar_hit)
        return axs_cachekeeper_search_region_rejected(report,@"implementation",bar,rect,nil);
    if (!axs_cachekeeper_search_finite_rect(rect) || CGRectIsEmpty(rect)) return axs_cachekeeper_search_region_rejected(report,@"requestedGeometry",bar,rect,nil);
    CGRect overlap=CGRectIntersection(rect,bar.bounds);
    if (CGRectIsEmpty(overlap) || CGRectIsNull(overlap)) return YES;
    NSUInteger remaining=128;
    BOOL empty=axs_cachekeeper_search_bar_region_empty(bar,bar,overlap,&remaining,report);
    if (report) report[@"visited"]=@(128-remaining);
    return empty;
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
    return axs_cachekeeper_search_bar_rect_empty(bar,owner,rect,nil);
}
+ (NSDictionary *)axs_cachekeeper_bar:(UINavigationBar *)bar owner:(id<AxsCacheKeeperSearchHitOwner>)owner inspect_rect:(CGRect)rect {
    NSMutableDictionary *report=[@{@"requested":axs_cachekeeper_search_rect_values(rect),@"reason":@"empty"} mutableCopy];
    report[@"empty"]=@(axs_cachekeeper_search_bar_rect_empty(bar,owner,rect,report));
    return report;
}
@end
