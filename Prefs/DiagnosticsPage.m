#import "DiagnosticsPage.h"
#import "../AxsCacheKeeperDiagnostics.h"
#include <roothide.h>

@interface AxsCacheKeeperDiagnosticsPage ()
@property(nonatomic,strong) AxsCacheKeeperDiagnostics *session;
@property(nonatomic,copy) NSArray *apps;
@property(nonatomic,strong) UITextView *text;
@property(nonatomic,strong) UIButton *startButton;
@property(nonatomic,strong) UIButton *stopButton;
@property(nonatomic,strong) UIButton *exportButton;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic) BOOL exporting;
@end
@implementation AxsCacheKeeperDiagnosticsPage
- (instancetype)initWithApps:(NSArray<NSDictionary *> *)apps {
    self=[super init];if (self) {
        _apps=[apps copy];
        _session=[[AxsCacheKeeperDiagnostics alloc] initWithFolder:jbroot(@"/var/mobile/Library/CacheKeeper")];
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
    self.startButton=[self axs_cachekeeper_button:@"补采已配置 APP" action:@selector(axs_cachekeeper_start)];
    self.stopButton=[self axs_cachekeeper_button:@"停止补采" action:@selector(axs_cachekeeper_stop)];
    self.exportButton=[self axs_cachekeeper_button:@"导出现有记录" action:@selector(axs_cachekeeper_export)];
    UIStackView *buttons=[[UIStackView alloc] initWithArrangedSubviews:@[self.startButton,self.stopButton,self.exportButton]];
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
    self.text.text=[NSString stringWithFormat:@"%@\n\n范围：已保存配置的 %lu 个 APP，包含已关闭的配置。\n\n补采会依次检测目录、读取可见目录的文件类型与最大文件属性，复用现有清理回执。大目录耗时较长，请留在此页；可随时停止并导出部分结果。\n\n导出包含 APP 名称/版本、系统与插件版本、开关、目录统计、保留原因类别、深度检测和硬链接记录。未知目录名、账号和私人文件名会匿名化；不导出文件内容、原始日志或设备标识。\n\n导出后在分享菜单保存到“文件”，将这个 JSON 文件发送给我即可。历史、缺失、失败和截断都会在报告中注明。",self.session.status,(unsigned long)self.session.bundles.count];
    self.startButton.enabled=!self.session.running && !self.exporting && self.session.bundles.count;
    self.stopButton.enabled=self.session.running && !self.exporting;
    self.exportButton.enabled=!self.exporting;
}
- (void)axs_cachekeeper_start {
    NSString *error=[self.session startAt:NSProcessInfo.processInfo.systemUptime];
    if (error) {[self axs_cachekeeper_message:error];return;}
    [self.timer invalidate];__weak typeof(self) weak=self;
    self.timer=[NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        [weak.session advanceAt:NSProcessInfo.processInfo.systemUptime];[weak axs_cachekeeper_refresh];
        if (!weak.session.running) {[timer invalidate];weak.timer=nil;}
    }];[self axs_cachekeeper_refresh];
}
- (void)axs_cachekeeper_stop {
    [self.session stop];[self.timer invalidate];self.timer=nil;[self axs_cachekeeper_refresh];
}
- (void)axs_cachekeeper_message:(NSString *)message {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"诊断采集" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)axs_cachekeeper_export {
    if (self.exporting) return;
    [self axs_cachekeeper_stop];self.exporting=YES;[self axs_cachekeeper_refresh];
    NSBundle *bundle=[NSBundle bundleForClass:self.class];
#if defined(__arm64e__)
    NSString *architecture=@"arm64e";
#else
    NSString *architecture=@"arm64";
#endif
    NSDictionary *environment=@{@"os":UIDevice.currentDevice.systemVersion,@"architecture":architecture,@"pluginVersion":[bundle objectForInfoDictionaryKey:@"CacheKeeperPackageVersion"] ?: @"unknown"};
    // 只读聚合与序列化放后台；期间停止状态机，报告和任务数组不会并发修改。
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        NSDictionary *report=[self.session reportWithApps:self.apps environment:environment];NSError *error=nil;
        NSData *data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:&error];
        NSURL *file=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"CacheKeeper-diagnostics-%@.json",NSUUID.UUID.UUIDString]]];
        BOOL saved=data && [data writeToURL:file options:NSDataWritingAtomic error:&error];
        dispatch_async(dispatch_get_main_queue(),^{
            self.exporting=NO;[self axs_cachekeeper_refresh];
            if (!saved) {[self axs_cachekeeper_message:[NSString stringWithFormat:@"报告保存失败（代码 %ld），请重试。",(long)error.code]];return;}
            if (!self.view.window || self.navigationController.topViewController!=self) {
                NSError *removeError=nil;
                if (![NSFileManager.defaultManager removeItemAtURL:file error:&removeError]) NSLog(@"[CacheKeeper] 已离开页面，诊断临时报告清理失败：%ld",(long)removeError.code);
                return;
            }
            UIActivityViewController *share=[[UIActivityViewController alloc] initWithActivityItems:@[file] applicationActivities:nil];
            share.popoverPresentationController.sourceView=self.exportButton;share.popoverPresentationController.sourceRect=self.exportButton.bounds;
            share.completionWithItemsHandler=^(UIActivityType type,BOOL completed,NSArray *items,NSError *shareError) {
                NSError *removeError=nil;
                if (![NSFileManager.defaultManager removeItemAtURL:file error:&removeError]) NSLog(@"[CacheKeeper] 诊断临时报告清理失败：%ld",(long)removeError.code);
                if (shareError) [self axs_cachekeeper_message:[NSString stringWithFormat:@"分享失败（代码 %ld），可重新导出。",(long)shareError.code]];
            };
            [self presentViewController:share animated:YES completion:nil];
        });
    });
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (self.isMovingFromParentViewController || self.navigationController.isBeingDismissed) [self axs_cachekeeper_stop];
}
- (void)dealloc { [self.timer invalidate]; }
@end
