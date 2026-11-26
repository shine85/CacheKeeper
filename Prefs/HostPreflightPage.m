#import "HostPreflightPage.h"
#import "../AxsCacheKeeperHostPreflight.h"

@interface AxsCacheKeeperHostPreflightPage ()
@property(nonatomic,strong) AxsCacheKeeperHostPreflight *axs_cachekeeper_batch;
@property(nonatomic,strong) NSTimer *axs_cachekeeper_timer;
@property(nonatomic,strong) UITextView *text;
@property(nonatomic,strong) UIButton *axs_cachekeeper_actionButton,*axs_cachekeeper_retryButton;
@property(nonatomic) BOOL axs_cachekeeper_backgrounded,axs_cachekeeper_departing;
@end

@implementation AxsCacheKeeperHostPreflightPage
- (instancetype)initWithStatusDirectory:(NSString *)directory panelVersion:(NSString *)version {
    if (!(self=[super init])) return nil;
    _axs_cachekeeper_batch=[[AxsCacheKeeperHostPreflight alloc] initWithStatusDirectory:directory panelVersion:version];
    if (!_axs_cachekeeper_batch) return nil;
    self.title=@"五 APP 宿主集中预检";
    return self;
}
- (UIButton *)axs_cachekeeper_button:(NSString *)title action:(SEL)action {
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];
    button.configuration=[UIButtonConfiguration tintedButtonConfiguration];
    button.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    button.titleLabel.adjustsFontForContentSizeCategory=YES;
    [button setTitle:title forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}
- (void)viewDidLoad {
    [super viewDidLoad];self.view.backgroundColor=UIColor.systemBackgroundColor;
    self.text=[UITextView new];self.text.editable=NO;
    self.text.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];self.text.adjustsFontForContentSizeCategory=YES;
    self.text.accessibilityLabel=@"五 APP 宿主观察结果";
    self.axs_cachekeeper_actionButton=[self axs_cachekeeper_button:@"开始五项只读预检" action:@selector(axs_cachekeeper_action)];
    self.axs_cachekeeper_retryButton=[self axs_cachekeeper_button:@"重试保存失败项" action:@selector(axs_cachekeeper_retry_saving)];
    UIStackView *buttons=[[UIStackView alloc] initWithArrangedSubviews:@[self.axs_cachekeeper_actionButton,self.axs_cachekeeper_retryButton]];
    buttons.axis=UILayoutConstraintAxisVertical;buttons.spacing=8;
    for (UIView *view in @[self.text,buttons]) {view.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:view];}
    UILayoutGuide *safe=self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.text.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [self.text.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.text.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.text.bottomAnchor constraintEqualToAnchor:buttons.topAnchor constant:-12],
        [buttons.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [buttons.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [buttons.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12]]];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(axs_cachekeeper_background:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(axs_cachekeeper_foreground:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [self axs_cachekeeper_render];
}
- (void)axs_cachekeeper_render {
    NSDictionary *snapshot=[self.axs_cachekeeper_batch snapshot];
    NSMutableString *text=[NSMutableString stringWithString:@"开始后，在 5 分钟内依次打开下面的 APP，再返回本页查看。无需 SSH，不会自动启动或关闭 APP。\n只观察已加载插件的版本、已有访问结果、APP 开关配置可读性和诊断发布状态；不会改变清理或限写设置。\n\n自报告未经身份认证；无响应不能断定未注入，已响应也不证明缓存适配或清理效果。返回诊断页后汇总并导出，已保存结果会进入同一份报告。\n\n"];
    [text appendFormat:@"本轮终态：%@/%@\n\n",snapshot[@"completed"] ?: @0,snapshot[@"total"] ?: @0];
    BOOL failedSave=NO;
    NSDictionary *states=@{@"idle":@"尚未开始",@"pending":@"等待本轮响应",@"observed":@"已收到本轮自报告",@"timedOut":@"等待超时",@"cancelled":@"已取消",@"transportError":@"通知通信失败",@"invalidResponse":@"响应校验失败",@"clockChanged":@"时钟变化，会话失效"};
    for (NSDictionary *row in snapshot[@"rows"]) {
        [text appendFormat:@"%@：%@\n",row[@"name"],states[row[@"state"]] ?: @"状态无效"];
        if ([row[@"state"] isEqual:@"observed"]) [text appendFormat:@"%@\n",row[@"summary"]];
        if ([row[@"saveState"] isEqual:@"failed"]) {
            failedSave=YES;[text appendFormat:@"结果保存失败（代码 %@）；当前结果仍保留，可重试保存。\n",row[@"saveErrorCode"]];
        } else if ([row[@"saveState"] isEqual:@"succeeded"]) [text appendString:@"本轮结果已保存。\n"];
        [text appendString:@"\n"];
    }
    if (![self.text.text isEqual:text]) self.text.text=text;
    [self.axs_cachekeeper_actionButton setTitle:self.axs_cachekeeper_batch.running ? @"取消本轮等待" : @"开始新一轮五项预检" forState:UIControlStateNormal];
    self.axs_cachekeeper_retryButton.hidden=!failedSave;
}
- (void)axs_cachekeeper_update_timer {
    if (!self.axs_cachekeeper_batch.running || self.axs_cachekeeper_backgrounded || self.axs_cachekeeper_departing) {
        [self.axs_cachekeeper_timer invalidate];self.axs_cachekeeper_timer=nil;return;
    }
    if (self.axs_cachekeeper_timer) return;
    __weak typeof(self) weak=self;
    self.axs_cachekeeper_timer=[NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {(void)timer;[weak axs_cachekeeper_poll];}];
}
- (void)axs_cachekeeper_action {
    if (self.axs_cachekeeper_batch.running) [self.axs_cachekeeper_batch cancel];
    else [self.axs_cachekeeper_batch startWithTimeout:300];
    [self axs_cachekeeper_poll];
}
- (void)axs_cachekeeper_poll {
    [self.axs_cachekeeper_batch poll];[self axs_cachekeeper_render];[self axs_cachekeeper_update_timer];
}
- (void)axs_cachekeeper_retry_saving {
    [self.axs_cachekeeper_batch retrySaving];[self axs_cachekeeper_render];
}
- (void)axs_cachekeeper_background:(NSNotification *)notification {
    (void)notification;self.axs_cachekeeper_backgrounded=YES;[self axs_cachekeeper_update_timer];
}
- (void)axs_cachekeeper_foreground:(NSNotification *)notification {
    (void)notification;self.axs_cachekeeper_backgrounded=NO;
    if (self.navigationController.topViewController==self && !self.isBeingDismissed && !self.navigationController.isBeingDismissed)
        self.axs_cachekeeper_departing=NO;
    if (!self.axs_cachekeeper_departing) [self axs_cachekeeper_poll];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];self.axs_cachekeeper_departing=NO;[self axs_cachekeeper_poll];
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];self.axs_cachekeeper_departing=YES;[self axs_cachekeeper_update_timer];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    // Switching apps keeps the controller in the navigation stack. A real departure releases requests.
    BOOL removed=!self.navigationController || ![self.navigationController.viewControllers containsObject:self];
    BOOL covered=self.navigationController && self.navigationController.topViewController!=self;
    if (removed || covered || self.isBeingDismissed || self.navigationController.isBeingDismissed) {
        [self.axs_cachekeeper_batch cancel];[self axs_cachekeeper_update_timer];
    } else if (!self.axs_cachekeeper_backgrounded) self.axs_cachekeeper_departing=NO;
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_axs_cachekeeper_timer invalidate];[_axs_cachekeeper_batch cancel];
}
@end
