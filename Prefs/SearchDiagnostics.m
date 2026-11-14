#import "SearchDiagnostics.h"

@interface AxsCacheKeeperSearchDiagnostics ()
@property(nonatomic,weak) UITextField *field;
@property(nonatomic,weak) UIView *input;
@property(nonatomic,weak) UIView *root;
@property(nonatomic,weak) UIView *table;
@property(nonatomic,weak) UIViewController *owner;
@property(nonatomic,strong) NSMutableArray *events;
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
@implementation AxsCacheKeeperSearchDiagnostics
- (instancetype)initWithField:(UITextField *)field input:(UIView *)input root:(UIView *)root table:(UIView *)table owner:(UIViewController *)owner {
    if (!(self=[super init])) return nil;
    _field=field;_input=input;_root=root;_table=table;_owner=owner;
    [self axs_cachekeeper_begin];return self;
}
- (void)axs_cachekeeper_begin {
    if (self.recording) return;
    self.events=[NSMutableArray new];self.truncated=NO;self.hasTouchTimestamp=NO;
    self.started=NSProcessInfo.processInfo.systemUptime;self.recording=YES;
}
- (NSString *)axs_cachekeeper_hit_role:(UIView *)view {
    if (!view) return @"none";
    if (self.field && (view==self.field || [view isDescendantOfView:self.field])) return @"field";
    if (self.input && (view==self.input || [view isDescendantOfView:self.input])) return @"search";
    if (self.table && (view==self.table || [view isDescendantOfView:self.table])) return @"table";
    return @"other";
}
- (void)axs_cachekeeper_record:(AxsCacheKeeperSearchEvent)event {
    [self axs_cachekeeper_record:event observedHit:@"notObserved"];
}
- (void)axs_cachekeeper_record:(AxsCacheKeeperSearchEvent)event observedHit:(NSString *)observedHit {
    if (!NSThread.isMainThread || !self.recording || self.capturing || event>=axs_cachekeeper_search_event_names().count) return;
    self.capturing=YES;
    UIWindow *window=self.root.window ?: self.field.window;
    CGPoint center=[self.field convertPoint:CGPointMake(CGRectGetMidX(self.field.bounds),CGRectGetMidY(self.field.bounds)) toView:window];
    BOOL validCenter=window && isfinite(center.x) && isfinite(center.y) && fabs(center.x)<=1000000 && fabs(center.y)<=1000000;
    // nil event and capturing guard prevent this diagnostic query from recording itself.
    UIView *hit=validCenter ? [window hitTest:center withEvent:nil] : nil;
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
        @"ancestors":[ancestors copy],@"ancestorsTruncated":ancestor ? @YES : @NO};
    if (self.events.count==AxsCacheKeeperSearchEventLimit) { [self.events removeObjectAtIndex:0];self.truncated=YES; }
    [self.events addObject:entry];self.capturing=NO;
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
    return axs_cachekeeper_search_diagnostics_projection(@{@"schemaVersion":@1,@"probeRevision":@1,
        @"state":self.recording ? @"recording" : @"frozen",@"truncated":@(self.truncated),@"events":self.events ?: @[]});
}
- (NSDictionary *)axs_cachekeeper_freeze:(AxsCacheKeeperSearchEvent)event {
    [self axs_cachekeeper_record:event];self.recording=NO;
    return [self axs_cachekeeper_snapshot];
}
- (void)axs_cachekeeper_clear {
    self.recording=NO;self.events=nil;self.truncated=NO;self.hasTouchTimestamp=NO;
}
@end

@implementation AxsCacheKeeperSearchRootView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit=[super hitTest:point withEvent:event];
    [self.axs_cachekeeper_diagnostics axs_cachekeeper_observe_hit:hit point:point event:event];
    return hit;
}
@end
