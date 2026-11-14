#import "SearchDiagnostics.h"

@interface AxsCacheKeeperSearchDiagnostics ()
@property(nonatomic,weak) UITextField *field;
@property(nonatomic,weak) UIView *input;
@property(nonatomic,weak) UIView *root;
@property(nonatomic,weak) UIView *table;
@property(nonatomic,weak) UIViewController *owner;
@property(nonatomic,strong) NSMutableArray *events;
@property(nonatomic,copy) NSDictionary *lastSample;
@property(nonatomic) NSTimeInterval started;
@property(nonatomic) NSTimeInterval lastTouchTimestamp;
@property(nonatomic) BOOL hasTouchTimestamp;
@property(nonatomic) BOOL recording;
@property(nonatomic) BOOL capturing;
@property(nonatomic) BOOL truncated;
@end

static NSDictionary *axs_cachekeeper_search_rect(CGRect rect,BOOL available) {
    BOOL valid=available && !CGRectIsNull(rect) && !CGRectIsInfinite(rect) &&
        isfinite(rect.origin.x) && fabs(rect.origin.x)<=1000000 && isfinite(rect.origin.y) && fabs(rect.origin.y)<=1000000 &&
        isfinite(rect.size.width) && rect.size.width>=0 && rect.size.width<=1000000 &&
        isfinite(rect.size.height) && rect.size.height>=0 && rect.size.height<=1000000;
    if (!valid) rect=CGRectZero;
    return @{@"valid":@(valid),@"x":@(rect.origin.x),@"y":@(rect.origin.y),@"width":@(rect.size.width),@"height":@(rect.size.height)};
}
static NSDictionary *axs_cachekeeper_search_view(UIView *view,UIWindow *window,CGPoint center) {
    BOOL attached=view && window && view.window==window;
    // C comparisons/logical expressions have type int; this contract requires actual CFBoolean values.
    return @{@"bounds":axs_cachekeeper_search_rect(view.bounds,view!=nil),
        @"windowRect":axs_cachekeeper_search_rect(attached ? [view convertRect:view.bounds toView:window] : CGRectZero,attached),
        @"hidden":@(view.hidden),@"alpha":@(view.alpha),@"interaction":@(view.userInteractionEnabled),@"clips":@(view.clipsToBounds),
        @"centerInsideBounds":(attached && CGRectContainsPoint(view.bounds,[view convertPoint:center fromView:window])) ? @YES : @NO};
}
static BOOL axs_cachekeeper_search_contains(UIView *container,UIView *view) {
    return container && view && (view==container || [view isDescendantOfView:container]);
}
static NSString *axs_cachekeeper_search_kind(UIView *view) {
    if (!view) return @"none";
    if ([view isKindOfClass:UITextField.class]) return @"textField";
    if ([view isKindOfClass:UINavigationBar.class]) return @"navigationBar";
    if ([view isKindOfClass:UIToolbar.class]) return @"toolbar";
    if ([view isKindOfClass:UITabBar.class]) return @"tabBar";
    if ([view isKindOfClass:UIControl.class]) return @"control";
    if ([view isKindOfClass:UIScrollView.class]) return @"scrollView";
    if ([view isKindOfClass:UIStackView.class]) return @"stackView";
    if ([view isKindOfClass:UIVisualEffectView.class]) return @"visualEffect";
    if ([view isKindOfClass:UIImageView.class]) return @"image";
    if ([view isKindOfClass:UILabel.class]) return @"label";
    if ([view isKindOfClass:UIWindow.class]) return @"window";
    return @"view";
}
@implementation AxsCacheKeeperSearchDiagnostics
- (instancetype)initWithField:(UITextField *)field input:(UIView *)input root:(UIView *)root table:(UIView *)table owner:(UIViewController *)owner {
    if (!(self=[super init])) return nil;
    _field=field;_input=input;_root=root;_table=table;_owner=owner;
    [self axs_cachekeeper_begin];return self;
}
- (void)axs_cachekeeper_begin {
    if (self.recording) return;
    self.events=[NSMutableArray new];self.lastSample=nil;self.truncated=NO;self.hasTouchTimestamp=NO;
    self.started=NSProcessInfo.processInfo.systemUptime;self.recording=YES;
}
- (NSString *)axs_cachekeeper_hit_role:(UIView *)view {
    if (!view) return @"none";
    if (axs_cachekeeper_search_contains(self.field,view)) return @"field";
    if (axs_cachekeeper_search_contains(self.input,view)) return @"search";
    if (axs_cachekeeper_search_contains(self.table,view)) return @"table";
    return @"other";
}
- (NSDictionary *)axs_cachekeeper_hit_descriptor:(UIView *)view navigationBar:(UIView *)bar navigationContainer:(UIView *)container window:(UIWindow *)window center:(CGPoint)center {
    NSString *role=[self axs_cachekeeper_hit_role:view];
    if ([role isEqual:@"other"]) {
        if (axs_cachekeeper_search_contains(bar,view)) role=@"navigationBar";
        else if (axs_cachekeeper_search_contains(self.root,view)) role=@"root";
        else if (axs_cachekeeper_search_contains(container,view)) role=@"navigationContainer";
        else if (view==window) role=@"window";
    }
    return @{@"role":role,@"kind":axs_cachekeeper_search_kind(view),@"view":axs_cachekeeper_search_view(view,window,center)};
}
- (void)axs_cachekeeper_record:(AxsCacheKeeperSearchEvent)event {
    [self axs_cachekeeper_record:event observedHit:@"notObserved"];
}
- (void)axs_cachekeeper_sample {
    if (!NSThread.isMainThread || !self.recording || self.capturing) return;
    UIWindow *window=self.root.window;UITextField *field=self.field;
    if (!window || field.window!=window || field.bounds.size.width<=0 || field.bounds.size.height<=0) return;
    [self axs_cachekeeper_record:AxsCacheKeeperSearchEventSampled];
}
- (void)axs_cachekeeper_record:(AxsCacheKeeperSearchEvent)event observedHit:(NSString *)observedHit {
    if (!NSThread.isMainThread || !self.recording || self.capturing || event>=axs_cachekeeper_search_event_names().count) return;
    self.capturing=YES;
    @try {
        UIWindow *window=self.root.window ?: self.field.window;
        CGPoint fieldCenter=CGPointMake(CGRectGetMidX(self.field.bounds),CGRectGetMidY(self.field.bounds));
        CGPoint center=[self.field convertPoint:fieldCenter toView:window];
        BOOL validCenter=self.field && window && self.field.window==window && isfinite(center.x) && isfinite(center.y) && fabs(center.x)<=1000000 && fabs(center.y)<=1000000;
        // nil event and capturing guard prevent this diagnostic query from recording itself.
        UIView *hit=validCenter ? [window hitTest:center withEvent:nil] : nil;
        CGPoint rootCenter=[self.field convertPoint:fieldCenter toView:self.root];
        BOOL validRootCenter=validCenter && self.root.window==window && isfinite(rootCenter.x) && isfinite(rootCenter.y) &&
            fabs(rootCenter.x)<=1000000 && fabs(rootCenter.y)<=1000000;
        UIView *rootHit=validRootCenter ? [self.root hitTest:rootCenter withEvent:nil] : nil;
        UINavigationController *navigation=self.owner.navigationController;
        UIView *bar=navigation.navigationBar;UIView *container=navigation.viewIfLoaded;
        NSMutableArray *hitAncestors=[NSMutableArray new];UIView *hitAncestor=hit.superview;
        for (NSUInteger i=0;hitAncestor && i<AxsCacheKeeperSearchAncestorLimit;i++,hitAncestor=hitAncestor.superview) {
            [hitAncestors addObject:[self axs_cachekeeper_hit_descriptor:hitAncestor navigationBar:bar navigationContainer:container window:window center:center]];
        }
        NSDictionary *route=@{@"rootCenterHit":[self axs_cachekeeper_hit_role:rootHit],
            @"windowHit":[self axs_cachekeeper_hit_descriptor:hit navigationBar:bar navigationContainer:container window:window center:center],
            @"hitAncestors":[hitAncestors copy],@"hitAncestorsTruncated":hitAncestor ? @YES : @NO,
            @"navigationBar":axs_cachekeeper_search_view(bar,window,center),
            @"windowHitInsideRoot":axs_cachekeeper_search_contains(self.root,hit) ? @YES : @NO,
            @"windowHitInsideNavigationBar":axs_cachekeeper_search_contains(bar,hit) ? @YES : @NO,
            @"sameHit":(hit && hit==rootHit) ? @YES : @NO};
        NSString *scene=@"unattached";
        if (window.windowScene) switch (window.windowScene.activationState) {
            case UISceneActivationStateUnattached: scene=@"unattached";break;
            case UISceneActivationStateForegroundActive: scene=@"foregroundActive";break;
            case UISceneActivationStateForegroundInactive: scene=@"foregroundInactive";break;
            case UISceneActivationStateBackground: scene=@"background";break;
            default: scene=@"unknown";break;
        }
        NSMutableArray *ancestors=[NSMutableArray new];UIView *ancestor=self.field.superview;
        for (NSUInteger i=0;ancestor && i<AxsCacheKeeperSearchAncestorLimit;i++,ancestor=ancestor.superview) {
            NSString *role=ancestor==self.input ? @"search" : ancestor==self.root ? @"root" : ancestor==self.table ? @"table" : ancestor==window ? @"window" : @"other";
            [ancestors addObject:@{@"role":role,@"view":axs_cachekeeper_search_view(ancestor,window,center)}];
        }
        NSTimeInterval elapsed=NSProcessInfo.processInfo.systemUptime-self.started;
        NSDictionary *entry=@{@"event":axs_cachekeeper_search_event_names()[event],@"elapsedMs":@((NSUInteger)MIN(3600000,MAX(0,elapsed*1000))),
            @"observedHit":observedHit,@"centerHit":[self axs_cachekeeper_hit_role:hit],@"firstResponder":@(self.field.isFirstResponder),
            @"fieldEnabled":@(self.field.enabled),@"fieldCanBecomeFirstResponder":@(self.field.canBecomeFirstResponder),
            @"presented":self.owner.presentedViewController ? @YES : @NO,@"windowAttached":window ? @YES : @NO,@"windowKey":@(window.isKeyWindow),
            @"windowHidden":@(window.hidden),@"windowInteraction":@(window.userInteractionEnabled),@"windowAlpha":@(window.alpha),@"scene":scene,
            @"field":axs_cachekeeper_search_view(self.field,window,center),@"input":axs_cachekeeper_search_view(self.input,window,center),
            @"root":axs_cachekeeper_search_view(self.root,window,center),@"table":axs_cachekeeper_search_view(self.table,window,center),
            @"ancestors":[ancestors copy],@"ancestorsTruncated":ancestor ? @YES : @NO,@"hitRoute":route};
        if (event==AxsCacheKeeperSearchEventSampled) {
            NSMutableDictionary *state=[entry mutableCopy];
            // Table contentOffset changes on ordinary scrolling and must not evict search touch evidence.
            [state removeObjectsForKeys:@[@"event",@"elapsedMs",@"observedHit",@"table"]];
            if ([state isEqual:self.lastSample]) return;
            self.lastSample=state;
        }
        if (self.events.count==AxsCacheKeeperSearchEventLimit) { [self.events removeObjectAtIndex:0];self.truncated=YES; }
        [self.events addObject:entry];
    } @finally {
        self.capturing=NO;
    }
}
- (void)axs_cachekeeper_observe_hit:(UIView *)hit point:(CGPoint)point event:(UIEvent *)event {
    if (!self.recording || self.capturing || !event || event.type!=UIEventTypeTouches || !self.input || !self.root ||
        (self.hasTouchTimestamp && self.lastTouchTimestamp==event.timestamp)) return;
    CGRect search=[self.input convertRect:self.input.bounds toView:self.root];
    if (!CGRectContainsPoint(search,point)) return;
    self.hasTouchTimestamp=YES;self.lastTouchTimestamp=event.timestamp;
    [self axs_cachekeeper_record:AxsCacheKeeperSearchEventRootHit observedHit:[self axs_cachekeeper_hit_role:hit]];
}
- (NSDictionary *)axs_cachekeeper_snapshot {
    return axs_cachekeeper_search_diagnostics_projection(@{@"schemaVersion":@1,@"probeRevision":@2,
        @"state":self.recording ? @"recording" : @"frozen",@"truncated":@(self.truncated),@"events":self.events ?: @[]});
}
- (NSDictionary *)axs_cachekeeper_freeze:(AxsCacheKeeperSearchEvent)event {
    [self axs_cachekeeper_record:event];self.recording=NO;
    return [self axs_cachekeeper_snapshot];
}
- (void)axs_cachekeeper_clear {
    self.recording=NO;self.events=nil;self.lastSample=nil;self.truncated=NO;self.hasTouchTimestamp=NO;
}
@end

@implementation AxsCacheKeeperSearchRootView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit=[super hitTest:point withEvent:event];
    [self.axs_cachekeeper_diagnostics axs_cachekeeper_observe_hit:hit point:point event:event];
    return hit;
}
@end
