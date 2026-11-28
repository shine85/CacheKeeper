#import "HostPreflightPage.h"
#import "CollectionNavigation.h"
#import "../AxsCacheKeeperHostPreflight.h"

@interface AxsCacheKeeperHostPreflightPage ()
@property(nonatomic,strong) AxsCacheKeeperHostPreflight *axs_cachekeeper_batch;
@property(nonatomic,strong) NSTimer *axs_cachekeeper_timer;
@property(nonatomic,strong) UITextView *text;
@property(nonatomic,strong) UIButton *axs_cachekeeper_actionButton,*axs_cachekeeper_retryButton;
@property(nonatomic,strong) AxsCacheKeeperCollectionSession *axs_cachekeeper_collectionSession;
@property(nonatomic) BOOL axs_cachekeeper_backgrounded,axs_cachekeeper_departing;
@property(nonatomic) NSTimeInterval axs_cachekeeper_roundStartedAt;
@end

@implementation AxsCacheKeeperHostPreflightPage
- (instancetype)initWithStatusDirectory:(NSString *)directory panelVersion:(NSString *)version {
    return [self initWithStatusDirectory:directory panelVersion:version collectionSession:nil];
}
- (instancetype)initWithStatusDirectory:(NSString *)directory panelVersion:(NSString *)version collectionSession:(AxsCacheKeeperCollectionSession *)session {
    if (!(self=[super init])) return nil;
    _axs_cachekeeper_batch=[[AxsCacheKeeperHostPreflight alloc] initWithStatusDirectory:directory panelVersion:version];
    if (!_axs_cachekeeper_batch) return nil;
    _axs_cachekeeper_collectionSession=session;
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
    if (self.axs_cachekeeper_collectionSession) [text appendFormat:@"集中采集会话 %@\n",self.axs_cachekeeper_collectionSession.sessionID];
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
    if (self.axs_cachekeeper_batch.running) {
        [self.collectionNavigation clear];
        [self.axs_cachekeeper_batch cancel];
        NSError *error=nil;
        if (self.axs_cachekeeper_collectionSession && ![self.axs_cachekeeper_collectionSession finishPhase:@"hostPreflight" result:@{@"state":@"cancelled"} error:&error])
            self.text.text=[NSString stringWithFormat:@"取消已请求，但会话记录失败（代码 %@）；恢复时将按中断处理。\n\n%@",@(error.code),self.text.text];
    } else {
        NSError *sessionError=nil;
        if(self.collectionNavigation && ![self.collectionNavigation selectPage:@"host" error:&sessionError]){self.text.text=@"返回位置无法保存，未重启宿主请求。";return;}
        NSString *phaseState=self.axs_cachekeeper_collectionSession.reportProjection[@"phases"][@"hostPreflight"][@"state"];
        BOOL retrying=self.axs_cachekeeper_collectionSession && [@[@"interrupted",@"cancelled"] containsObject:phaseState];
        BOOL prepared=!retrying || [self.axs_cachekeeper_collectionSession prepareRetryForPhase:@"hostPreflight" error:&sessionError];
        if (prepared && self.axs_cachekeeper_collectionSession)
            prepared=[self.axs_cachekeeper_collectionSession beginPhase:@"hostPreflight" error:&sessionError];
        if (!prepared) {
            self.text.text=[NSString stringWithFormat:@"会话阶段无法持久化，未发送宿主请求（代码 %@）。\n\n%@",@(sessionError.code),self.text.text];
            [self axs_cachekeeper_render];return;
        }
        self.axs_cachekeeper_roundStartedAt=floor(NSDate.date.timeIntervalSince1970);
        if (![self.axs_cachekeeper_batch startWithTimeout:300] && self.axs_cachekeeper_collectionSession) {
            NSError *finishError=nil;
            [self.axs_cachekeeper_collectionSession finishPhase:@"hostPreflight" result:@{@"state":@"failed"} error:&finishError];
            self.text.text=[NSString stringWithFormat:@"宿主批次启动失败，会话记录 %@。\n\n%@",@(finishError.code),self.text.text];
        }
    }
    [self axs_cachekeeper_poll];
}
- (void)axs_cachekeeper_poll {
    [self.axs_cachekeeper_batch poll];
    NSDictionary *snapshot=[self.axs_cachekeeper_batch snapshot];
    if (self.axs_cachekeeper_collectionSession && ![snapshot[@"running"] boolValue] &&
        [snapshot[@"completed"] unsignedIntegerValue]==[snapshot[@"total"] unsignedIntegerValue] &&
        [snapshot[@"total"] unsignedIntegerValue]>0 &&
        [self.axs_cachekeeper_collectionSession.reportProjection[@"phases"][@"hostPreflight"][@"state"] isEqual:@"running"]) {
        NSMutableArray *rows=[NSMutableArray new];
        for (NSDictionary *row in snapshot[@"rows"]) {
            NSMutableDictionary *evidence=[@{@"bundle":row[@"bundle"],@"state":row[@"state"],@"saveState":row[@"saveState"],
                @"transportTrust":@"unauthenticated",@"roundStartedAt":@(self.axs_cachekeeper_roundStartedAt),
                @"observationFreshness":@"notObserved"} mutableCopy];
            NSDictionary *result=[row[@"result"] isKindOfClass:NSDictionary.class] ? row[@"result"] : nil;
            if (result) evidence[@"receipt"]=result;
            NSNumber *sourceUpdated=[result[@"data"] isKindOfClass:NSDictionary.class] ? result[@"data"][@"updated"] : nil;
            if (sourceUpdated) {
                BOOL current=[sourceUpdated doubleValue]>=self.axs_cachekeeper_roundStartedAt;
                evidence[@"sourceUpdated"]=sourceUpdated;
                evidence[@"observationFreshness"]=current ? @"currentRound" : @"stale";
                evidence[@"multipleResponders"]=result[@"multipleResponders"] ?: @NO;
            }
            [rows addObject:[evidence copy]];
        }
        BOOL complete=YES;
        for (NSDictionary *row in rows) if (![row[@"state"] isEqual:@"observed"] || ![row[@"saveState"] isEqual:@"succeeded"] ||
            ![row[@"transportTrust"] isEqual:@"unauthenticated"] || ![row[@"observationFreshness"] isEqual:@"currentRound"] ||
            [row[@"multipleResponders"] boolValue]) complete=NO;
        NSError *error=nil;
        if (![self.axs_cachekeeper_collectionSession finishPhase:@"hostPreflight" result:@{@"state":complete ? @"complete" : @"partial",
            @"roundStartedAt":@(self.axs_cachekeeper_roundStartedAt),@"transportTrust":@"unauthenticated",@"apps":rows} error:&error])
            self.text.text=[NSString stringWithFormat:@"宿主结果已观测，但会话阶段保存失败（代码 %@）；后续阶段不会开始。\n\n%@",@(error.code),self.text.text];
    }
    [self axs_cachekeeper_render];[self axs_cachekeeper_update_timer];
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
    __weak typeof(self) weak=self;
    [self.collectionNavigation attachTo:self exit:^{
        typeof(self) page=weak;BOOL running=page.axs_cachekeeper_batch.running;[page.axs_cachekeeper_batch cancel];
        if(running)[page.axs_cachekeeper_collectionSession finishPhase:@"hostPreflight" result:@{@"state":@"interrupted",@"reason":@"userBack"} error:NULL];
    }];
    if([self.axs_cachekeeper_collectionSession.reportProjection[@"phases"][@"hostPreflight"][@"state"] isEqual:@"interrupted"])
        self.text.text=[@"原宿主请求随页面或进程结束，未自动重发。可在此明确重启预检。\n\n" stringByAppendingString:self.text.text];
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];self.axs_cachekeeper_departing=YES;[self axs_cachekeeper_update_timer];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if(self.collectionNavigation){[self.axs_cachekeeper_timer invalidate];self.axs_cachekeeper_timer=nil;return;}
    // Switching apps keeps the controller in the navigation stack. A real departure releases requests.
    BOOL removed=!self.navigationController || ![self.navigationController.viewControllers containsObject:self];
    BOOL covered=self.navigationController && self.navigationController.topViewController!=self;
    if (removed || covered || self.isBeingDismissed || self.navigationController.isBeingDismissed) {
        BOOL wasRunning=self.axs_cachekeeper_batch.running;
        [self.axs_cachekeeper_batch cancel];[self axs_cachekeeper_update_timer];
        if (wasRunning && self.axs_cachekeeper_collectionSession && [self.axs_cachekeeper_collectionSession.reportProjection[@"phases"][@"hostPreflight"][@"state"] isEqual:@"running"])
            [self.axs_cachekeeper_collectionSession finishPhase:@"hostPreflight" result:@{@"state":@"interrupted",@"reason":@"pageLeft"} error:NULL];
    } else if (!self.axs_cachekeeper_backgrounded) self.axs_cachekeeper_departing=NO;
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_axs_cachekeeper_timer invalidate];[_axs_cachekeeper_batch cancel];
}
@end
