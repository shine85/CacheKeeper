#import "ImageCollectionPage.h"
#import "CollectionNavigation.h"
#import "../AxsCacheKeeperImageCollection.h"

@interface AxsCacheKeeperImageCollectionPage ()
@property(nonatomic,strong) AxsCacheKeeperImageCollectionSession *session;
@property(nonatomic,strong) UITextView *text;
@property(nonatomic,strong) UIButton *startButton,*nextButton,*cancelButton,*retryButton,*skipButton,*selectButton;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic,copy) NSString *message;
@property(nonatomic) BOOL entrySaved;
@property(nonatomic) BOOL preparationReading;
@property(nonatomic,copy) NSDictionary *preparationStatus;
@property(nonatomic,strong) dispatch_queue_t preparationQueue;
@property(nonatomic) NSUInteger preparationGeneration;
@property(nonatomic) BOOL backgrounded;
@end
@implementation AxsCacheKeeperImageCollectionPage
- (instancetype)initWithFolder:(NSString *)folder sessionID:(NSString *)identifier {
    if (!(self=[super init])) return nil;
    NSError *error=nil;_session=[[AxsCacheKeeperImageCollectionSession alloc] initWithFolder:folder sessionID:identifier error:&error];
    _message=error ? [NSString stringWithFormat:@"会话不可用（%@）。",@(error.code)] : @"尚未开始，现有设置保持不变。";
    return self;
}
- (instancetype)initWithSession:(AxsCacheKeeperImageCollectionSession *)session {
    if (!(self=[super init])) return nil;
    _session=session;_message=@"请选择执行图片阶段，或明确跳过并记录。";return self;
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
    self.skipButton=[self axs_button:@"跳过图片阶段并记录" action:@selector(axs_skip)];
    self.selectButton=[self axs_button:@"重新选择 APP" action:@selector(axs_choose)];
    UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:@[self.text,self.startButton,self.selectButton,self.nextButton,self.retryButton,self.cancelButton,self.skipButton]];
    stack.axis=UILayoutConstraintAxisVertical;stack.spacing=12;stack.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:stack];
    UILayoutGuide *safe=self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[[stack.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [stack.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12],
        [stack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16]]];
    NSError *entryError=nil;self.entrySaved=[self.session recordEntry:&entryError];
    if (!self.entrySaved) self.message=[NSString stringWithFormat:@"入口记录未保存（%@），请重试；未发出测试请求。",@(entryError.code)];
    self.preparationQueue=dispatch_queue_create("dev.local.cachekeeper.image.preparation",DISPATCH_QUEUE_SERIAL);
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(axs_foreground:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(axs_background:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [self axs_render:nil];
    [self axs_start_timer];
    [self axs_poll];
}
- (NSString *)axs_name:(NSString *)bundle {return self.applicationNames[bundle] ?: bundle;}
- (NSString *)axs_reason:(NSString *)reason {
    return @{@"none":@"可以开始",@"appDisabled":@"原 APP 开关未启用",@"receiptStale":@"历史回执已过期，等待打开 APP 刷新",@"receiptMissing":@"尚无图片 SDK 回执",
        @"receiptInvalid":@"回执校验失败",@"receiptReadFailed":@"回执读取失败",@"receiptFromFuture":@"回执时间异常",@"noEligibleOwner":@"当前没有合格图片 SDK 实例",
        @"pendingAction":@"等待原清理任务结束",@"configurationInvalid":@"原配置不可用",@"awaitingNewReceipt":@"等待所选 APP 发布新回执"}[reason] ?: @"尚未满足执行条件";
}
- (NSString *)axs_preflight_summary {
    NSUInteger disabled=0,unknown=0,unavailable=0;
    NSMutableArray *related=[NSMutableArray new];
    for (NSDictionary *row in self.session.reportProjection[@"preflight"][@"modules"]) {
        if ([row[@"reason"] isEqual:@"appDisabled"]) {disabled++;continue;}
        if ([@[@"receiptMissing",@"noEligibleOwner"] containsObject:row[@"reason"]]) {unknown++;continue;}
        unavailable++;
        if (related.count<8) [related addObject:[NSString stringWithFormat:@"%@：%@",[self axs_name:row[@"bundle"]],[self axs_reason:row[@"reason"]]]];
    }
    return [NSString stringWithFormat:@"未开启 %lu 个；未发现合格 SDK %lu 个；其他待处理 %lu 个。\n%@\n完整技术原因保留在报告中。",(unsigned long)disabled,(unsigned long)unknown,(unsigned long)unavailable,[related componentsJoinedByString:@"\n"]];
}
- (void)axs_render:(NSDictionary *)status {
    NSDictionary *report=self.session.reportProjection;
    NSString *state=status[@"state"] ?: report[@"state"] ?: @"unavailable";
    NSString *phase=status[@"phase"] ?: report[@"phase"] ?: @"notStarted";
    BOOL preparing=[report[@"state"] isEqual:@"idle"] && report[@"preparation"];
    NSDictionary *tips=@{@"prevent":@"进入所选 APP，打开原来会加载图片的页面，保持普通操作，再返回本页。",
        @"clean":@"进入所选 APP 产生普通图片负载，再离开 APP 回本页，让既有后台清理执行；等待真实完成回执。",
        @"disabled":@"图片限制已临时关闭；进入相同页面产生非空图片写入，再回本页核对放行。",
        @"restore":@"已请求撤销临时覆盖。若尚未确认，请打开所选 APP 再回来；只有宿主确认采用当前设置才算恢复。"};
    self.text.text=[NSString stringWithFormat:@"仅覆盖所选 APP 当前已支持的图片 SDK 合格实例，不覆盖 Documents 主体或未知资源。必须已启用原 APP 设置，所有原目录与保留规则保持生效。\n\n点开始后从已有合格回执选择 APP，再顺序执行限制、只清理、关闭、恢复。每阶段最多5分钟；不会修改用户配置文件。配置变化或租期失效会中断临时覆盖。\n\nAPP：%@\n阶段：%@\n状态：%@\n%@\n\n%@\n\n已保存阶段：%@。未触发写入记为未触发，放行仅代表原 writer 被调用，不代表磁盘持久化。完整回执并入集中报告。",report[@"bundle"] ?: @"未选择",phase,state,tips[phase] ?: @"已有回执只是候选，必须取得本阶段宿主确认。",self.message ?: @"",@([report[@"events"] count])];
    if ([report[@"state"] isEqual:@"idle"]) {
        NSString *reason=[self axs_reason:self.preparationStatus[@"reason"] ?: report[@"selectedCheck"][@"reason"]];
        self.text.text=[NSString stringWithFormat:@"图片阶段尚未执行，原 APP 设置保持不变。\n\n%@\n\n%@\n\n%@",
            preparing ? [NSString stringWithFormat:@"已选择：%@\n准备状态：%@\n请手动打开这个 APP，进入平常会加载图片的页面，再回到这里。返回时会自动重新检查；取得新回执后，点“确认开始图片阶段”。",[self axs_name:report[@"bundle"]],reason] :
            @"先选择有历史合格 SDK 回执的 APP。历史过期只要求刷新，不授权执行。随后仅需打开所选 APP，无需重复五 APP 预检或容量测量。",
            self.message ?: @"",[self axs_preflight_summary]];
    } else {
        NSMutableString *evidence=[NSMutableString new];
        for(NSDictionary *event in report[@"events"]){
            NSDictionary *data=event[@"writers"][@"data"],*extended=event[@"writers"][@"extended"];
            [evidence appendFormat:@"\n%@：数据写入 %@ 次，阻断 %@，放行 %@；扩展写入 %@ 次。",@{@"prevent":@"限制阶段",@"clean":@"清理阶段",@"disabled":@"关闭阶段"}[event[@"phase"]] ?: @"已保存阶段",data[@"nonemptyAttempts"] ?: @0,data[@"nonemptyBlocked"] ?: @0,data[@"nonemptyAllowed"] ?: @0,extended[@"nonemptyAttempts"] ?: @0];
            if([event[@"cleanupActions"] unsignedIntegerValue]>0)[evidence appendFormat:@" 已观察清理 %@ 次，其中有实际文件减少 %@ 次；%@。",event[@"cleanupActions"],event[@"cleanupPositiveActions"], [event[@"cleanupCoverageComplete"] boolValue] ? @"当前清理证据完整" : @"范围完整性仍未确认"];
        }
        if([report[@"state"] isEqual:@"complete"])[evidence appendFormat:@"\n已确认恢复当前设置；阶段验证%@，不等于全部测试通过。",[report[@"verificationState"] isEqual:@"passed"] ? @"通过" : @"仍有未触发或证据不足项"];
        self.text.text=[self.text.text stringByAppendingString:evidence];
    }
    BOOL ready=[self.preparationStatus[@"state"] isEqual:@"readyToStart"];
    [self.startButton setTitle:preparing ? (ready ? @"确认开始图片阶段" : @"重新检查所选 APP") : @"选择图片采集 APP" forState:UIControlStateNormal];
    self.startButton.enabled=self.entrySaved && [report[@"state"] isEqual:@"idle"] && !self.preparationReading;
    self.selectButton.hidden=!preparing;self.selectButton.enabled=preparing && !self.preparationReading;
    self.nextButton.enabled=[state isEqual:@"observing"];
    self.retryButton.enabled=self.session && (!self.entrySaved || [state isEqual:@"awaitingHost"]);
    [self.retryButton setTitle:self.entrySaved ? @"重发当前请求 · 不延长租期" : @"重试保存入口记录" forState:UIControlStateNormal];
    self.skipButton.enabled=self.entrySaved && [report[@"state"] isEqual:@"idle"] && !self.preparationReading;
    self.cancelButton.enabled=self.session && ![report[@"state"] isEqual:@"idle"] && ![self.session readyForReport];
}
- (void)axs_poll {
    if ([self.session.reportProjection[@"state"] isEqual:@"idle"] && self.session.reportProjection[@"preparation"]) {
        if (self.preparationReading) return;self.preparationReading=YES;[self axs_render:nil];
        NSUInteger generation=self.preparationGeneration;NSString *bundle=self.session.reportProjection[@"bundle"];
        __weak typeof(self) weak=self;AxsCacheKeeperImageCollectionSession *session=self.session;
        dispatch_async(self.preparationQueue,^{NSError *error=nil;NSDictionary *prepared=[session refreshPreparation:&error];
            dispatch_async(dispatch_get_main_queue(),^{typeof(self) page=weak;if (!page) return;page.preparationReading=NO;
                if (page.preparationGeneration!=generation || ![page.session.reportProjection[@"bundle"] isEqual:bundle]) {page.preparationStatus=nil;return;}
                page.preparationStatus=prepared;
                page.message=error ? [NSString stringWithFormat:@"准备检查或保存失败（%@），可以重试；未发出执行请求。",@(error.code)] :
                    [prepared[@"state"] isEqual:@"readyToStart"] ? @"已收到新的合格回执。请确认开始；当前尚未发出执行请求。" : @"只等待所选 APP 的新回执，未运行图片阶段。";
                [page axs_render:nil];});
        });return;
    }
    NSError *error=nil;NSDictionary *status=[self.session poll:&error];
    if (error) self.message=[NSString stringWithFormat:@"回执尚不可读（%@）；等待并不代表成功。",@(error.code)];
    else if([status[@"reason"] isEqual:@"processChanged"])self.message=@"APP 已重新启动，本阶段没有取得原进程的有效回执。请取消并确认恢复；不会自动绑定新进程或重发请求。";
    else if([status[@"state"] isEqual:@"interrupted"])self.message=@"本阶段已中断或租期已失效，未自动续期。可取消并确认恢复，已保存阶段仍保留。";
    else if([status[@"state"] isEqual:@"restorationUnconfirmed"])self.message=@"恢复尚未获得宿主确认，不能视为已恢复。原请求与记录已保留。";
    [self axs_render:status];
}
- (void)axs_start {
    if (self.preparationReading) return;
    if (self.session.reportProjection[@"preparation"] && [self.session.reportProjection[@"state"] isEqual:@"idle"]) {
        if (![self.preparationStatus[@"state"] isEqual:@"readyToStart"]) {[self axs_poll];return;}
        NSError *failure=nil;BOOL ok=[self.session startWithBundle:self.session.reportProjection[@"bundle"] error:&failure];
        self.message=ok ? @"执行请求已保存，等待宿主确认。" : [NSString stringWithFormat:@"当前准入条件已变化（%@），重新检查后再确认。",@(failure.code)];
        self.preparationStatus=nil;[self axs_poll];return;
    }
    [self axs_choose];
}
- (void)axs_choose {
    if (self.preparationReading) return;
    NSError *error=nil;NSArray *modules=[self.session availableModules:&error];
    if (!modules.count) {
        self.message=error ? [NSString stringWithFormat:@"候选检查或保存失败（%@），可重试；未发出请求。",@(error.code)] :
            @"尚无可选择的已知图片 SDK。未启用或未发现合格实例的 APP 不会自动开启；原因已记录。";
        [self axs_render:nil];return;
    }
    UIAlertController *choice=[UIAlertController alertControllerWithTitle:@"选择图片采集 APP" message:@"选择只开始准备。打开所选 APP 刷新回执后，仍需你确认才能执行图片阶段。" preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weak=self;
    for (NSDictionary *module in modules) [choice addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@ · %@",[self axs_name:module[@"bundle"]],
        [module[@"state"] isEqual:@"requiresRefresh"] ? @"待刷新" : @"准备核验"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        (void)action;[weak axs_start_bundle:module[@"bundle"]];
    }]];
    [choice addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    choice.popoverPresentationController.sourceView=self.startButton;choice.popoverPresentationController.sourceRect=self.startButton.bounds;
    [self presentViewController:choice animated:YES completion:nil];
}
- (void)axs_start_bundle:(NSString *)bundle {
    self.preparationGeneration++;NSError *failure=nil;BOOL ok=[self.session prepareBundle:bundle error:&failure];self.preparationStatus=nil;
    self.message=ok ? @"目标已保存。请打开所选 APP 刷新回执，再回来确认开始。" : [NSString stringWithFormat:@"未能准备（%@）；%@。可重试或明确跳过。",@(failure.code),
        [failure.userInfo[@"entryEvidenceSaved"] boolValue] ? @"失败原因已保存" : @"失败记录保存未确认"];
    [self axs_poll];
}
- (void)axs_start_timer {
    if(self.timer)return;__weak typeof(self) weak=self;
    self.timer=[NSTimer scheduledTimerWithTimeInterval:5 repeats:YES block:^(NSTimer *timer){(void)timer;if(weak.view.window && UIApplication.sharedApplication.applicationState==UIApplicationStateActive)[weak axs_poll];}];
}
- (void)axs_foreground:(NSNotification *)notification {(void)notification;self.backgrounded=NO;[self axs_start_timer];[self axs_poll];}
- (void)axs_background:(NSNotification *)notification {(void)notification;self.backgrounded=YES;}
- (void)axs_next {NSError *error=nil;BOOL ok=[self.session captureAndAdvance:&error];self.message=ok ? @"当前阶段实际结果已保存，等待下一阶段确认。" : [NSString stringWithFormat:@"尚不能推进（%@），没有把等待或失败算成功。",@(error.code)];[self axs_poll];}
- (void)axs_cancel {NSError *error=nil;BOOL ok=[self.session cancel:&error];if(ok)[self.collectionNavigation clear];self.message=ok ? @"已发出恢复请求，等待宿主确认。" : [NSString stringWithFormat:@"恢复请求未完成（%@）；租期仍有上限，可再次取消。",@(error.code)];[self axs_poll];}
- (void)axs_retry {
    NSError *error=nil;
    if (!self.entrySaved) {self.entrySaved=[self.session recordEntry:&error];self.message=self.entrySaved ? @"入口记录已保存，可选择执行或跳过。" : [NSString stringWithFormat:@"入口记录仍未保存（%@）。",@(error.code)];[self axs_render:nil];return;}
    BOOL ok=[self.session retryPublishing:&error];self.message=ok ? @"已重发原请求，编号和到期时间未变。" : [NSString stringWithFormat:@"原请求无法重发（%@）；可取消并恢复。",@(error.code)];[self axs_poll];
}
- (void)axs_skip {if (self.preparationReading) return;self.preparationGeneration++;NSError *error=nil;BOOL ok=[self.session skip:&error];if(ok)[self.collectionNavigation clear];self.message=ok ? @"已记录跳过；图片功能未验证。返回向导汇总并导出。" : [NSString stringWithFormat:@"跳过决定未保存（%@），请重试。",@(error.code)];[self axs_render:nil];}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];[self axs_start_timer];__weak typeof(self) weak=self;
    [self.collectionNavigation attachTo:self exit:^{
        typeof(self) page=weak;
        if(![page.session.reportProjection[@"state"] isEqual:@"idle"] && ![page.session readyForReport]) [page.session cancel:NULL];
    }];
    [self axs_poll];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if(self.collectionNavigation){self.preparationGeneration++;[self.timer invalidate];self.timer=nil;return;}
    if (self.isMovingFromParentViewController || self.isBeingDismissed || ![self.navigationController.viewControllers containsObject:self]) {
        self.preparationGeneration++;
        NSError *error=nil;
        if (!self.backgrounded && UIApplication.sharedApplication.applicationState==UIApplicationStateActive &&
            ![self.session.reportProjection[@"state"] isEqual:@"idle"] && ![self.session readyForReport] && ![self.session cancel:&error])
            NSLog(@"[CacheKeeper] 图片采集离页恢复请求失败：%ld",(long)error.code);
        [self.timer invalidate];self.timer=nil;
    }
}
- (void)dealloc {[_timer invalidate];[NSNotificationCenter.defaultCenter removeObserver:self];}
@end
