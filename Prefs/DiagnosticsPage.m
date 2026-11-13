#import "DiagnosticsPage.h"
#import "../AxsCacheKeeperDiagnostics.h"
#include <roothide.h>

@interface AxsCacheKeeperDiagnosticsPage ()
@property(nonatomic,copy) NSArray *apps;
@property(nonatomic,strong) UITextView *text;
@property(nonatomic,strong) UIButton *collectButton;
@property(nonatomic,strong) UIButton *exportButton;
@property(nonatomic,strong) UIProgressView *progressView;
@property(nonatomic,strong) UILabel *progressLabel;
@property(nonatomic,strong) NSData *reportData;
@property(nonatomic,copy) NSString *status;
@property(nonatomic) NSUInteger completed;
@property(nonatomic) NSUInteger total;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL collecting;
@property(nonatomic) BOOL sharing;
@end

static void AxsCacheKeeperRemoveDiagnosticShare(NSURL *file) {
    NSError *error=nil;
    if (![NSFileManager.defaultManager removeItemAtURL:file error:&error])
        NSLog(@"[CacheKeeper] 诊断临时分享文件清理失败：%ld",(long)error.code);
}

@implementation AxsCacheKeeperDiagnosticsPage
- (instancetype)initWithApps:(NSArray<NSDictionary *> *)apps {
    self=[super init];if (self) {
        _apps=[apps copy];
        _status=@"尚未采集；采集结果仅保留在当前页面内存中。";
    }return self;
}
- (UIButton *)axs_cachekeeper_button:(NSString *)title action:(SEL)action {
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];
    button.configuration=[UIButtonConfiguration tintedButtonConfiguration];
    [button setTitle:title forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:48].active=YES;return button;
}
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"诊断采集";self.view.backgroundColor=UIColor.systemGroupedBackgroundColor;
    self.text=[UITextView new];self.text.editable=NO;self.text.backgroundColor=UIColor.clearColor;
    self.text.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];self.text.adjustsFontForContentSizeCategory=YES;
    self.text.text=@"快速汇总已配置 APP 的现有记录，包含已关闭的配置。每个 APP 读取一次，总数固定；不会自动检测目录或深度扫描。\n\n报告包含 APP 与插件版本、开关、目录统计、清理回执、网络状态和已有深度档案。每条记录保留原时间，缺失、损坏和覆盖不完整会明确标注。\n\n未知路径、账号和私人文件名会匿名化；不导出文件内容、原始日志或设备标识。\n\n采集后只保留内存报告，不自动保存。手动点“导出报告”后，才生成临时分享文件；分享结束清理副本。只有你主动“存储到文件”的报告会保留。离开本页会释放内存报告。\n\n需要新数据时，在具体 APP 的目录页执行检测，再回来采集即可。";
    self.collectButton=[self axs_cachekeeper_button:@"采集诊断" action:@selector(axs_cachekeeper_collect)];
    self.exportButton=[self axs_cachekeeper_button:@"导出报告" action:@selector(axs_cachekeeper_export)];
    self.progressLabel=[UILabel new];self.progressLabel.numberOfLines=0;
    self.progressLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];self.progressLabel.adjustsFontForContentSizeCategory=YES;
    self.progressView=[[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressView.accessibilityLabel=@"已读取的 APP 记录";
    UIStackView *buttons=[[UIStackView alloc] initWithArrangedSubviews:@[self.progressLabel,self.progressView,self.collectButton,self.exportButton]];
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
    [self axs_cachekeeper_refresh];
}
- (void)axs_cachekeeper_refresh {
    self.progressLabel.text=self.status;
    self.progressView.progress=self.total ? (float)self.completed/self.total : 0;
    self.collectButton.enabled=!self.collecting && !self.sharing;
    self.exportButton.enabled=self.reportData && !self.collecting && !self.sharing;
}
- (void)axs_cachekeeper_collect {
    if (self.collecting || self.sharing) return;
    self.collecting=YES;self.reportData=nil;self.completed=0;self.total=0;
    self.status=@"正在读取配置和已有记录…";[self axs_cachekeeper_refresh];
    NSUInteger generation=++self.generation;
    NSBundle *bundle=[NSBundle bundleForClass:self.class];
#if defined(__arm64e__)
    NSString *architecture=@"arm64e";
#else
    NSString *architecture=@"arm64";
#endif
    NSDictionary *environment=@{@"os":UIDevice.currentDevice.systemVersion,@"architecture":architecture,@"pluginVersion":[bundle objectForInfoDictionaryKey:@"CacheKeeperPackageVersion"] ?: @"unknown"};
    NSArray *apps=self.apps;__weak typeof(self) weak=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        AxsCacheKeeperDiagnostics *session=[[AxsCacheKeeperDiagnostics alloc] initWithFolder:jbroot(@"/var/mobile/Library/CacheKeeper")];
        NSDictionary *report=[session reportWithApps:apps environment:environment progress:^(NSUInteger completed,NSUInteger total) {
            dispatch_async(dispatch_get_main_queue(),^{
                AxsCacheKeeperDiagnosticsPage *page=weak;if (!page || page.generation!=generation) return;
                page.completed=completed;page.total=total;
                page.status=[NSString stringWithFormat:@"正在汇总 %lu/%lu 个 APP 的已保存记录",(unsigned long)completed,(unsigned long)total];
                [page axs_cachekeeper_refresh];
            });
        }];
        NSError *error=nil;
        NSData *data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:&error];
        dispatch_async(dispatch_get_main_queue(),^{
            AxsCacheKeeperDiagnosticsPage *page=weak;if (!page || page.generation!=generation) return;
            page.collecting=NO;page.reportData=data;
            page.status=data ? [NSString stringWithFormat:@"已汇总 %lu/%lu 个 APP。报告仅在内存，点击“导出报告”保存。",(unsigned long)page.completed,(unsigned long)page.total] : @"报告生成失败，尚未保存；可以重新采集。";
            if (data && (![@[@"available",@"missing"] containsObject:report[@"sourceStates"][@"configuration"]] || ![@[@"available",@"missing"] containsObject:report[@"sourceStates"][@"selection"]]))
                page.status=@"报告已在内存生成，但部分配置损坏或不可读；可导出查看错误状态。";
            [page axs_cachekeeper_refresh];
            if (!data && page.view.window) [page axs_cachekeeper_message:[NSString stringWithFormat:@"报告生成失败（代码 %ld）。",(long)error.code]];
        });
    });
}
- (void)axs_cachekeeper_message:(NSString *)message {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"诊断采集" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)axs_cachekeeper_export {
    if (self.collecting || self.sharing || !self.reportData) return;
    self.sharing=YES;[self axs_cachekeeper_refresh];
    NSData *data=self.reportData;NSUInteger generation=self.generation;__weak typeof(self) weak=self;
    // 只有用户明确点击导出才落盘，采集阶段只保留 NSData。
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        NSError *error=nil;
        NSURL *file=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"CacheKeeper-diagnostics-%@.json",NSUUID.UUID.UUIDString]]];
        BOOL saved=[data writeToURL:file options:NSDataWritingAtomic error:&error];
        dispatch_async(dispatch_get_main_queue(),^{
            AxsCacheKeeperDiagnosticsPage *page=weak;
            if (!page || page.generation!=generation || !page.view.window || page.navigationController.topViewController!=page) {
                if (saved) AxsCacheKeeperRemoveDiagnosticShare(file);
                if (page && page.generation==generation) {page.sharing=NO;[page axs_cachekeeper_refresh];}
                return;
            }
            if (!saved) {page.sharing=NO;[page axs_cachekeeper_refresh];[page axs_cachekeeper_message:[NSString stringWithFormat:@"报告保存失败（代码 %ld），请重试。",(long)error.code]];return;}
            UIActivityViewController *share=[[UIActivityViewController alloc] initWithActivityItems:@[file] applicationActivities:nil];
            share.popoverPresentationController.sourceView=page.exportButton;share.popoverPresentationController.sourceRect=page.exportButton.bounds;
            share.completionWithItemsHandler=^(UIActivityType type,BOOL completed,NSArray *items,NSError *shareError) {
                AxsCacheKeeperRemoveDiagnosticShare(file);
                AxsCacheKeeperDiagnosticsPage *owner=weak;if (!owner || owner.generation!=generation) return;
                owner.sharing=NO;[owner axs_cachekeeper_refresh];
                if (shareError && owner.view.window) [owner axs_cachekeeper_message:[NSString stringWithFormat:@"分享失败（代码 %ld），可重新导出。",(long)shareError.code]];
            };
            [page presentViewController:share animated:YES completion:nil];
        });
    });
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (!self.isMovingFromParentViewController && !self.isBeingDismissed && !self.navigationController.isBeingDismissed) return;
    __weak typeof(self) weak=self;
    void (^releaseReport)(void)=^{
        AxsCacheKeeperDiagnosticsPage *page=weak;if (!page) return;
        page.generation++;page.reportData=nil;page.collecting=NO;page.sharing=NO;
        page.completed=0;page.total=0;page.status=@"尚未采集；采集结果仅保留在当前页面内存中。";
        [page axs_cachekeeper_refresh];
    };
    // 交互式返回可能取消；只有实际离页才丢弃结果和回调。
    id<UIViewControllerTransitionCoordinator> coordinator=self.transitionCoordinator;
    if (coordinator) [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        if (!context.isCancelled) releaseReport();
    }];
    else releaseReport();
}
@end
