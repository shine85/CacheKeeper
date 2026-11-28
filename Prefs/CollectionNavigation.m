#import "CollectionNavigation.h"

BOOL axs_cachekeeper_collection_visible_root(UIViewController *owner) {
    if(!owner.viewIfLoaded.window || owner.presentedViewController || owner.isBeingDismissed)return NO;
    for(UIViewController *child=owner,*parent=child.parentViewController;parent;child=parent,parent=parent.parentViewController) {
        if(parent.presentedViewController || parent.isBeingDismissed || child.transitionCoordinator || parent.transitionCoordinator)return NO;
        if([parent isKindOfClass:UINavigationController.class] && ((UINavigationController *)parent).topViewController!=child)return NO;
    }
    return owner.navigationController!=nil;
}
@interface AxsCacheKeeperCollectionNavigation ()
@property(nonatomic,strong) AxsCacheKeeperCollectionReturn *store;
@property(nonatomic,strong) AxsCacheKeeperCollectionSession *session;
@property(nonatomic,copy) NSDictionary *intent;
@property(nonatomic,weak) UIViewController *owner;
@property(nonatomic,weak) UIGestureRecognizer *gesture;
@property(nonatomic,copy) dispatch_block_t exit;
@property(nonatomic) BOOL gesturePending,exited;
@end
@implementation AxsCacheKeeperCollectionNavigation
- (instancetype)initWithSession:(AxsCacheKeeperCollectionSession *)session intent:(NSDictionary *)intent {
    if(!(self=[super init]))return nil;_session=session;
    _store=[[AxsCacheKeeperCollectionReturn alloc] initWithDirectory:session.storagePath.stringByDeletingLastPathComponent];_intent=[intent copy];return self;
}
- (BOOL)selectPage:(NSString *)page error:(NSError **)error {
    NSDictionary *next=self.intent && !self.exited ? [self.store update:self.intent page:page error:error] : [self.store selectSession:self.session page:page error:error];
    if(!next)return NO;self.intent=next;self.exited=NO;return YES;
}
- (BOOL)clear {
    if(self.exited)return YES;
    NSError *error=nil;if(self.intent && ![self.store clear:self.intent error:&error] && error.code!=ESTALE){
        NSLog(@"[CacheKeeper] 采集返回位置清除失败：%ld",(long)error.code);return NO;}
    self.exited=YES;return YES;
}
- (BOOL)axs_exit {
    if(self.exited){
        @synchronized(AxsCacheKeeperCollectionReturn.class){if([self.store isReleasedIntent:self.intent] && self.returnToParent)self.returnToParent();}
        return YES;
    }
    BOOL current=[[self.store read:NULL] isEqual:self.intent];
    if(![self clear]){
        UIViewController *page=self.owner;
        if(page.viewIfLoaded.window && !page.presentedViewController){UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"退出未保存" message:@"采集返回位置暂时无法清除，请重试返回。" preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];[page presentViewController:alert animated:YES completion:nil];}
        return NO;
    }
    if(current && self.exit)self.exit();
    @synchronized(AxsCacheKeeperCollectionReturn.class){if(current && [self.store isReleasedIntent:self.intent] && self.returnToParent)self.returnToParent();}
    return YES;
}
- (void)attachTo:(UIViewController *)owner exit:(dispatch_block_t)exit {
    self.owner=owner;self.exit=exit;__weak typeof(self) weak=self;
    owner.navigationItem.backAction=[UIAction actionWithHandler:^(UIAction *action){
        (void)action;typeof(self) strong=weak;UIViewController *page=strong.owner;if(!page)return;
        if([strong axs_exit])[page.navigationController popViewControllerAnimated:YES];
    }];
    UIGestureRecognizer *gesture=owner.navigationController.interactivePopGestureRecognizer;
    if(self.gesture!=gesture){[self.gesture removeTarget:self action:@selector(axs_gesture:)];self.gesture=gesture;[gesture addTarget:self action:@selector(axs_gesture:)];}
}
- (void)axs_gesture:(UIGestureRecognizer *)gesture {
    UIViewController *owner=self.owner;
    BOOL departing=[owner.transitionCoordinator viewControllerForKey:UITransitionContextFromViewControllerKey]==owner;
    if(gesture.state!=UIGestureRecognizerStateBegan || self.gesturePending || (owner.navigationController.topViewController!=owner && !departing))return;
    self.gesturePending=YES;__weak typeof(self) weak=self;
    dispatch_async(dispatch_get_main_queue(),^{
        typeof(self) strong=weak;UIViewController *page=strong.owner;
        id<UIViewControllerTransitionCoordinator> transition=page.transitionCoordinator;
        if(!transition || !transition.isInteractive || [transition viewControllerForKey:UITransitionContextFromViewControllerKey]!=page){strong.gesturePending=NO;return;}
        [transition animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context){
            typeof(self) live=weak;live.gesturePending=NO;if(!context.isCancelled)[live axs_exit];
        }];
    });
}
- (void)dealloc {[_gesture removeTarget:self action:@selector(axs_gesture:)];}
@end
