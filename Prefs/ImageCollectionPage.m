#import "ImageCollectionPage.h"
#import "../AxsCacheKeeperImageCollection.h"

@interface AxsCacheKeeperImageCollectionPage ()
@property(nonatomic,strong) AxsCacheKeeperImageCollectionSession *session;
@property(nonatomic,strong) UITextView *text;
@property(nonatomic,strong) UIButton *startButton,*nextButton,*cancelButton,*retryButton;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic,copy) NSString *message;
@end
@implementation AxsCacheKeeperImageCollectionPage
- (instancetype)initWithFolder:(NSString *)folder sessionID:(NSString *)identifier {
    if (!(self=[super init])) return nil;
    NSError *error=nil;_session=[[AxsCacheKeeperImageCollectionSession alloc] initWithFolder:folder sessionID:identifier error:&error];
    _message=error ? [NSString stringWithFormat:@"会话不可用（%@）。",@(error.code)] : @"尚未开始，现有设置保持不变。";
    return self;
}
- (UIButton *)axs_button:(NSString *)title action:(SEL)action {
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];[button setTitle:title forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];button.titleLabel.numberOfLines=0;return button;
}
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"已支持图片 SDK · 三阶段";self.view.backgroundColor=UIColor.systemBackgroundColor;
    self.text=[UITextView new];self.text.editable=NO;self.text.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.startButton=[self axs_button:@"开始图片 SDK 三阶段采集" action:@selector(axs_start)];
    self.nextButton=[self axs_button:@"保存当前实际结果并进入下一阶段" action:@selector(axs_next)];
    self.cancelButton=[self axs_button:@"取消并恢复当前设置" action:@selector(axs_cancel)];
    self.retryButton=[self axs_button:@"重发当前请求 · 不延长租期" action:@selector(axs_retry)];
    UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:@[self.text,self.startButton,self.nextButton,self.retryButton,self.cancelButton]];
    stack.axis=UILayoutConstraintAxisVertical;stack.spacing=12;stack.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:stack];
    UILayoutGuide *safe=self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[[stack.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [stack.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12],
        [stack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16]]];
    [self axs_render:nil];
    __weak typeof(self) weak=self;self.timer=[NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {(void)timer;[weak axs_poll];}];
}
- (void)axs_render:(NSDictionary *)status {
    NSDictionary *report=self.session.reportProjection;
    NSString *state=status[@"state"] ?: report[@"state"] ?: @"unavailable";
    NSString *phase=status[@"phase"] ?: report[@"phase"] ?: @"notStarted";
    NSDictionary *tips=@{@"prevent":@"进入所选 APP，打开原来会加载图片的页面，保持普通操作，再返回本页。",
        @"clean":@"进入所选 APP 产生普通图片负载，再离开 APP 回本页，让既有后台清理执行；等待真实完成回执。",
        @"disabled":@"图片限制已临时关闭；进入相同页面产生非空图片写入，再回本页核对放行。",
        @"restore":@"已请求撤销临时覆盖。若尚未确认，请打开所选 APP 再回来；只有宿主确认采用当前设置才算恢复。"};
    self.text.text=[NSString stringWithFormat:@"仅覆盖所选 APP 当前已支持的图片 SDK 合格实例，不覆盖 Documents 主体或未知资源。必须已启用原 APP 设置，所有原目录与保留规则保持生效。\n\n点开始后从已有合格回执选择 APP，再顺序执行限制、只清理、关闭、恢复。每阶段最多5分钟；不会修改用户配置文件。配置变化或租期失效会中断临时覆盖。\n\nAPP：%@\n阶段：%@\n状态：%@\n%@\n\n%@\n\n已保存阶段：%@。未触发写入记为未触发，放行仅代表原 writer 被调用，不代表磁盘持久化。完整回执并入集中报告。",report[@"bundle"] ?: @"未选择",phase,state,tips[phase] ?: @"已有回执只是候选，必须取得本阶段宿主确认。",self.message ?: @"",@([report[@"events"] count])];
    self.startButton.enabled=self.session && [report[@"state"] isEqual:@"idle"];
    self.nextButton.enabled=[state isEqual:@"observing"];
    self.retryButton.enabled=[state isEqual:@"awaitingHost"];
    self.cancelButton.enabled=self.session && ![report[@"state"] isEqual:@"idle"] && ![report[@"state"] isEqual:@"complete"];
}
- (void)axs_poll {
    NSError *error=nil;NSDictionary *status=[self.session poll:&error];
    if (error) self.message=[NSString stringWithFormat:@"回执尚不可读（%@）；等待并不代表成功。",@(error.code)];
    [self axs_render:status];
}
- (void)axs_start {
    NSError *error=nil;NSArray *modules=[self.session availableModules:&error];
    if (!modules.count) {self.message=error ? [NSString stringWithFormat:@"现有图片回执不可读（%@）。",@(error.code)] : @"没有近期且已准入的图片 SDK 回执；请先正常打开已支持 APP，再回本页。";[self axs_render:nil];return;}
    UIAlertController *choice=[UIAlertController alertControllerWithTitle:@"选择已有图片 SDK 模块" message:@"选择后开始有限临时测试；范围由宿主再次验证。" preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weak=self;
    for (NSDictionary *module in modules) [choice addAction:[UIAlertAction actionWithTitle:module[@"bundle"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        (void)action;typeof(self) page=weak;if (!page) return;NSError *failure=nil;BOOL ok=[page.session startWithBundle:module[@"bundle"] error:&failure];
        page.message=ok ? @"请求已保存，等待宿主确认；尚未判定生效。" : [NSString stringWithFormat:@"未能开始（%@）；未修改用户配置。",@(failure.code)];[page axs_poll];
    }]];
    [choice addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    choice.popoverPresentationController.sourceView=self.startButton;choice.popoverPresentationController.sourceRect=self.startButton.bounds;
    [self presentViewController:choice animated:YES completion:nil];
}
- (void)axs_next {NSError *error=nil;BOOL ok=[self.session captureAndAdvance:&error];self.message=ok ? @"当前阶段实际结果已保存，等待下一阶段确认。" : [NSString stringWithFormat:@"尚不能推进（%@），没有把等待或失败算成功。",@(error.code)];[self axs_poll];}
- (void)axs_cancel {NSError *error=nil;BOOL ok=[self.session cancel:&error];self.message=ok ? @"已发出恢复请求，等待宿主确认。" : [NSString stringWithFormat:@"恢复请求未完成（%@）；租期仍有上限，可再次取消。",@(error.code)];[self axs_poll];}
- (void)axs_retry {NSError *error=nil;BOOL ok=[self.session retryPublishing:&error];self.message=ok ? @"已重发原请求，编号和到期时间未变。" : [NSString stringWithFormat:@"原请求无法重发（%@）；可取消并恢复。",@(error.code)];[self axs_poll];}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.isMovingFromParentViewController || self.isBeingDismissed || ![self.navigationController.viewControllers containsObject:self]) {
        NSError *error=nil;
        if (![self.session.reportProjection[@"state"] isEqual:@"idle"] && ![self.session.reportProjection[@"state"] isEqual:@"complete"] && ![self.session cancel:&error])
            NSLog(@"[CacheKeeper] 图片采集离页恢复请求失败：%ld",(long)error.code);
        [self.timer invalidate];self.timer=nil;
    }
}
- (void)dealloc {[_timer invalidate];}
@end
