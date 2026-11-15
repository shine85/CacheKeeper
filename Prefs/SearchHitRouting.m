#import "SearchHitRouting.h"
#import <objc/runtime.h>

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
@end
