#import "DiagnosticsPage.h"
#import "../AxsCacheKeeperDiagnostics.h"
#import "../AxsCacheKeeperInstallation.h"
#import "../AxsCacheKeeperDiagnosticChannel.h"
#import "../AxsCacheKeeperSearchDiagnostics.h"
#import "../AxsCacheKeeperPDFSession.h"
#import "../AxsCacheKeeperFilza.h"
#import "../AxsCacheKeeperCapacityStatus.h"
#include <dlfcn.h>
#include <roothide.h>

@interface AxsCacheKeeperDiagnosticsPage () <UITextViewDelegate>
@property(nonatomic,strong) NSMutableDictionary *installationCache;
@property(nonatomic,strong) dispatch_queue_t collectionQueue;
@property(nonatomic,strong) UITextView *text;
@property(nonatomic,strong) UIButton *collectButton;
@property(nonatomic,strong) UIButton *exportButton;
@property(nonatomic,strong) UIButton *axs_cachekeeper_capacityButton;
@property(nonatomic,strong) NSTimer *axs_cachekeeper_capacityTimer;
@property(nonatomic,copy) NSString *axs_cachekeeper_capacityEpoch;
@property(nonatomic,copy) NSDictionary *axs_cachekeeper_capacitySnapshot;
@property(nonatomic,copy) NSDictionary *axs_cachekeeper_capacityPendingStop;
@property(nonatomic) NSTimeInterval axs_cachekeeper_capacityStarted;
@property(nonatomic) BOOL axs_cachekeeper_capacityReading;
@property(nonatomic) BOOL axs_cachekeeper_capacityStopping;
@property(nonatomic) NSTimeInterval axs_cachekeeper_capacityStopStarted;
@property(nonatomic,copy) NSString *axs_cachekeeper_capacityError;
@property(nonatomic,strong) UIProgressView *progressView;
@property(nonatomic,strong) UILabel *progressLabel;
@property(nonatomic,strong) NSData *reportData;
@property(nonatomic,copy) NSString *status;
@property(nonatomic) NSUInteger completed;
@property(nonatomic) NSUInteger total;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL collecting;
@property(nonatomic) BOOL sharing;
@property(nonatomic,copy) NSDictionary *axs_cachekeeper_searchSnapshot;
@property(nonatomic,strong) AxsCacheKeeperPDFSession *axs_cachekeeper_pdfSession;
@property(nonatomic,copy) NSString *axs_cachekeeper_pdfBundle;
@property(nonatomic,copy) NSString *axs_cachekeeper_pdfRelative;
@property(nonatomic,copy) NSDictionary *axs_cachekeeper_pdfSnapshot;
@property(nonatomic) BOOL axs_cachekeeper_pdfReady;
@property(nonatomic) BOOL axs_cachekeeper_pdfFinished;
@property(nonatomic) BOOL axs_cachekeeper_pdfReportable;
@end

static void AxsCacheKeeperRemoveDiagnosticShare(NSURL *file) {
    NSError *error=nil;
    if (![NSFileManager.defaultManager removeItemAtURL:file error:&error])
        NSLog(@"[CacheKeeper] 诊断临时分享文件清理失败：%ld",(long)error.code);
}

@implementation AxsCacheKeeperDiagnosticsPage
- (instancetype)init {
    return [self initWithSearchSnapshot:nil];
}
- (instancetype)initWithSearchSnapshot:(NSDictionary *)snapshot {
    self=[super init];if (self) {
        _axs_cachekeeper_searchSnapshot=snapshot ? axs_cachekeeper_search_diagnostics_projection(snapshot) : nil;
        _installationCache=[NSMutableDictionary new];
        _collectionQueue=dispatch_queue_create("dev.local.cachekeeper.diagnostics",DISPATCH_QUEUE_SERIAL);
        _status=@"尚未采集；采集结果仅保留在当前页面内存中。";
    }return self;
}
- (instancetype)initWithPDFBundle:(NSString *)bundle relativeDirectory:(NSString *)relative {
    self=[self init];if (self) {
        _axs_cachekeeper_pdfBundle=[bundle copy];_axs_cachekeeper_pdfRelative=[relative copy];
        _axs_cachekeeper_pdfSession=[[AxsCacheKeeperPDFSession alloc] initWithBundle:bundle relativeDirectory:relative];
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
    self.text.text=@"快速汇总安装快照与当前配置中 APP 的现有记录，包含新装未配置和已关闭的 APP。新装未配置 APP 保持禁用。每轮总数固定；不会自动检测目录或深度扫描。\n\n报告包含实际提供的 APP 名称、版本与构建号、插件版本、开关、目录统计、清理回执、网络状态、宿主自动／面板只读观察、按原始记录派生的统一能力摘要和已有深度档案。不会主动唤醒或探测全机 APP，也不会改变模式。宿主信号未经认证，不证明清理、写入限制或关闭恢复效果。每条记录保留原时间，缺失、损坏和覆盖不完整会明确标注。每次采集重新获取安装列表；安装信息仅反映本轮快照；未在快照中出现不代表已卸载，来源缺失或损坏会标记不可用。\n\n未知路径、账号和私人文件名会匿名化；不导出文件内容、原始日志或设备标识。搜索状态附带本次主页面最近 16 条几何、命中与编辑事件；不含输入文字。进入诊断前已冻结，不把切页收起键盘计为搜索异常。\n\n采集后只保留内存报告，不自动保存。手动点“导出报告”后，才生成临时分享文件；分享结束清理副本。只有你主动“存储到文件”的报告会保留。离开本页会释放内存报告。\n\n需要新数据时，在具体 APP 的目录页执行检测，再回来采集即可。";
    self.collectButton=[self axs_cachekeeper_button:@"汇总已保存诊断" action:@selector(axs_cachekeeper_collect)];
    self.axs_cachekeeper_capacityButton=[self axs_cachekeeper_button:@"重新测量全容器占用 · 只读" action:@selector(axs_cachekeeper_capacity_action)];
    self.exportButton=[self axs_cachekeeper_button:@"导出报告" action:@selector(axs_cachekeeper_export)];
    self.progressLabel=[UILabel new];self.progressLabel.numberOfLines=0;
    self.progressLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];self.progressLabel.adjustsFontForContentSizeCategory=YES;
    self.progressView=[[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressView.accessibilityLabel=@"已读取的 APP 记录";
    UIStackView *buttons=[[UIStackView alloc] initWithArrangedSubviews:@[self.progressLabel,self.progressView,self.axs_cachekeeper_capacityButton,self.collectButton,self.exportButton]];
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
    if (!self.axs_cachekeeper_pdfSession) {
        self.text.text=[self.text.text stringByAppendingString:@"\n\n“重新测量全容器占用”是独立的实际只读测量：从系统登记容器覆盖 Documents、Library、Group 和扩展，不改变清理范围。全程只读文件元数据；未知目录匿名展示并保留，不读取文稿内容、不清理或唤醒 APP。风起云涌不参与。没有登记容器、读取失败与不完整分别报告，不能把缺失当 0。逻辑大小与已分配字节不是可释放空间，也不覆盖安装资源或孤立容器。可随时停止，离开本页停止；取消后用新的测量重新开始。\n测量结束后点击“汇总已保存诊断”，再导出同一份报告；汇总和导出不会再次测量磁盘。"];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(axs_cachekeeper_capacity_background:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    }
    if (self.axs_cachekeeper_pdfSession) {
        [buttons removeArrangedSubview:self.axs_cachekeeper_capacityButton];[self.axs_cachekeeper_capacityButton removeFromSuperview];
        self.title=@"定位 PDF · 只读";self.text.delegate=self;
        UIButton *cancel=[self axs_cachekeeper_button:@"停止并释放本次定位" action:@selector(axs_cachekeeper_pdf_cancel)];
        [buttons insertArrangedSubview:cancel atIndex:3];
        self.collecting=YES;self.status=@"正在验证服务身份与所选目录的实际读取权限…";
        [self.collectButton setTitle:@"开始定位 PDF" forState:UIControlStateNormal];
        [self axs_cachekeeper_pdf_text];[self axs_cachekeeper_refresh];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(axs_cachekeeper_pdf_background:) name:UIApplicationDidEnterBackgroundNotification object:nil];
        __weak typeof(self) weak=self;
        [self.axs_cachekeeper_pdfSession probe:^(NSDictionary *snapshot) {
            AxsCacheKeeperDiagnosticsPage *page=weak;if (!page || [page.axs_cachekeeper_pdfSnapshot isEqual:snapshot]) return;
            page.axs_cachekeeper_pdfSnapshot=snapshot;NSString *state=snapshot[@"state"];
            page.axs_cachekeeper_pdfReady=[state isEqual:@"ready"] && [snapshot[@"containerReadable"] boolValue];
            page.axs_cachekeeper_pdfFinished=[state isEqual:@"finished"];
            page.axs_cachekeeper_pdfReportable=![@[@"probing",@"ready",@"running"] containsObject:state];
            page.collecting=[@[@"probing",@"running"] containsObject:state];
            if (page.axs_cachekeeper_pdfReady) page.status=@"同一服务已只读打开所选目录，可开始定位。";
            else if ([state isEqual:@"running"]) page.status=[NSString stringWithFormat:@"已枚举 %@ 项，实际格式样本 %@ 字节；可随时停止。",snapshot[@"enumeratedCount"] ?: @0,snapshot[@"sampleBytes"] ?: @0];
            else if (page.axs_cachekeeper_pdfFinished) page.status=@"定位已停止，正在并入同一份诊断报告…";
            else if (![state isEqual:@"probing"]) {
                page.generation++;page.reportData=nil;page.status=[NSString stringWithFormat:@"定位不可用：%@，代码 %@。返回目录页后可重新检查。",snapshot[@"stage"] ?: @"session",snapshot[@"errorCode"] ?: @0];
            }
            [page axs_cachekeeper_pdf_text];[page axs_cachekeeper_refresh];
            if (page.axs_cachekeeper_pdfReportable) [page axs_cachekeeper_collect];
        }];
    }
}
- (void)axs_cachekeeper_refresh {
    self.progressLabel.text=self.status;
    self.progressView.progress=self.total ? (float)self.completed/self.total : 0;
    self.collectButton.enabled=!self.collecting && !self.sharing && !self.axs_cachekeeper_capacityEpoch && (!self.axs_cachekeeper_pdfSession || self.axs_cachekeeper_pdfReady);
    NSDictionary *report=self.reportData ? [NSJSONSerialization JSONObjectWithData:self.reportData options:NSJSONReadingFragmentsAllowed error:NULL] : nil;
    self.exportButton.enabled=self.reportData && axs_cachekeeper_capacity_report_exportable(report) && !self.collecting && !self.sharing && !self.axs_cachekeeper_capacityEpoch;
    BOOL unconfirmedStop=self.axs_cachekeeper_capacityStopping && NSProcessInfo.processInfo.systemUptime-self.axs_cachekeeper_capacityStopStarted>=10;
    self.axs_cachekeeper_capacityButton.enabled=!self.collecting && !self.sharing && (!self.axs_cachekeeper_capacityStopping || unconfirmedStop);
    [self.axs_cachekeeper_capacityButton setTitle:unconfirmedStop ? @"放弃等待 · 停止尚未确认" : self.axs_cachekeeper_capacityEpoch ? @"停止全容器测量" : @"重新测量全容器占用 · 只读" forState:UIControlStateNormal];
}
- (NSString *)axs_cachekeeper_capacity_file:(NSString *)name {
    return [jbroot(@"/var/mobile/Library/CacheKeeper") stringByAppendingPathComponent:name];
}
- (BOOL)axs_cachekeeper_capacity_write_stop:(NSString *)epoch error:(NSError **)error {
    return axs_cachekeeper_capacity_write_request([self axs_cachekeeper_capacity_file:@"capacityRequest.plist"],epoch,YES,error);
}
- (void)axs_cachekeeper_capacity_action {
    if (self.collecting || self.sharing || self.axs_cachekeeper_pdfSession) return;
    if (self.axs_cachekeeper_capacityStopping) {
        if (NSProcessInfo.processInfo.systemUptime-self.axs_cachekeeper_capacityStopStarted<10) return;
        [self axs_cachekeeper_capacity_stop];self.axs_cachekeeper_capacityError=@"cancelNotConfirmed";
        self.status=@"已放弃本页等待并重发停止请求，服务是否停止仍未确认。可汇总最后保存观测（不会称为完成）或以新轮重新测量。";
        [self axs_cachekeeper_refresh];return;
    }
    NSError *error=nil;
    if (self.axs_cachekeeper_capacityEpoch) {
        BOOL saved=[self axs_cachekeeper_capacity_write_stop:self.axs_cachekeeper_capacityEpoch error:&error];
        if (!saved) {
            self.axs_cachekeeper_capacityError=@"cancelRequestWriteFailed";
            self.axs_cachekeeper_capacityPendingStop=@{@"epoch":self.axs_cachekeeper_capacityEpoch,@"attemptedAt":@((uint64_t)NSDate.date.timeIntervalSince1970),@"requestWrite":@"failed",@"confirmation":@"unconfirmed"};
            self.status=[NSString stringWithFormat:@"停止请求未保存（代码 %ld），测量可能仍在继续；可重试停止。",(long)error.code];
        } else {
            self.axs_cachekeeper_capacityError=nil;
            self.axs_cachekeeper_capacityPendingStop=@{@"epoch":self.axs_cachekeeper_capacityEpoch,@"attemptedAt":@((uint64_t)NSDate.date.timeIntervalSince1970),@"requestWrite":@"saved",@"confirmation":@"unconfirmed"};
            self.axs_cachekeeper_capacityStopping=YES;self.axs_cachekeeper_capacityStopStarted=NSProcessInfo.processInfo.systemUptime;self.status=@"已请求停止；等待服务关闭本轮读取并保存实际终态…";
        }
        [self axs_cachekeeper_refresh];return;
    }
    NSString *epoch=NSUUID.UUID.UUIDString;
    if (!axs_cachekeeper_capacity_write_request([self axs_cachekeeper_capacity_file:@"capacityRequest.plist"],epoch,NO,&error)) {
        self.status=[NSString stringWithFormat:@"测量请求保存失败（代码 %ld），没有开始测量。",(long)error.code];[self axs_cachekeeper_refresh];return;
    }
    self.axs_cachekeeper_capacityEpoch=epoch;self.axs_cachekeeper_capacitySnapshot=nil;self.axs_cachekeeper_capacityPendingStop=nil;self.axs_cachekeeper_capacityError=nil;
    self.axs_cachekeeper_capacityStarted=NSProcessInfo.processInfo.systemUptime;self.axs_cachekeeper_capacityStopping=NO;
    self.generation++;self.reportData=nil;self.total=0;self.completed=0;
    self.status=@"请求已保存，正在等待服务获取本轮全登记容器并开始只读测量…";
    self.progressView.accessibilityLabel=@"已完成测量的登记容器根";
    __weak typeof(self) weak=self;
    self.axs_cachekeeper_capacityTimer=[NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
        AxsCacheKeeperDiagnosticsPage *page=weak;if (!page) {[timer invalidate];return;}[page axs_cachekeeper_capacity_poll];
    }];
    [self axs_cachekeeper_refresh];[self axs_cachekeeper_capacity_poll];
}
- (void)axs_cachekeeper_capacity_poll {
    if (!self.axs_cachekeeper_capacityEpoch || self.axs_cachekeeper_capacityReading) return;
    self.axs_cachekeeper_capacityReading=YES;
    NSString *epoch=self.axs_cachekeeper_capacityEpoch,*path=[self axs_cachekeeper_capacity_file:@"capacityResult.plist"];
    NSUInteger generation=self.generation;__weak typeof(self) weak=self;
    dispatch_async(self.collectionQueue,^{
        NSError *error=nil;NSDictionary *result=axs_cachekeeper_capacity_read_result(path,&error);
        dispatch_async(dispatch_get_main_queue(),^{
            AxsCacheKeeperDiagnosticsPage *page=weak;if (!page) return;
            page.axs_cachekeeper_capacityReading=NO;
            if (page.generation!=generation || ![page.axs_cachekeeper_capacityEpoch isEqual:epoch]) return;
            if (!result || ![result[@"epoch"] isEqual:epoch]) {
                if (error) page.status=[NSString stringWithFormat:@"测量结果暂不可读（代码 %ld）；尚未确认完成，可停止或继续等待。",(long)error.code];
                else if (NSProcessInfo.processInfo.systemUptime-page.axs_cachekeeper_capacityStarted>20)
                    page.status=@"尚未收到本轮服务结果；旧测量未混入。本轮未确认开始，可停止后重试。";
                [page axs_cachekeeper_refresh];return;
            }
            page.axs_cachekeeper_capacitySnapshot=result;page.total=[result[@"totalRoots"] unsignedIntegerValue];page.completed=[result[@"completedRoots"] unsignedIntegerValue];
            NSString *state=result[@"state"];
            page.status=[NSString stringWithFormat:@"全容器测量 %@：完整 %lu/%lu 根，失败 %@；未知用途数据保持不动。",state,(unsigned long)page.completed,(unsigned long)page.total,result[@"failedRoots"] ?: @0];
            if (![state isEqual:@"running"]) {
                if (page.axs_cachekeeper_capacityPendingStop) {
                    NSDictionary *exported=[page axs_cachekeeper_capacity_export:result saved:result stop:page.axs_cachekeeper_capacityPendingStop];
                    page.axs_cachekeeper_capacitySnapshot=exported;page.axs_cachekeeper_capacityPendingStop=nil;
                }
                [page.axs_cachekeeper_capacityTimer invalidate];page.axs_cachekeeper_capacityTimer=nil;
                page.axs_cachekeeper_capacityEpoch=nil;page.axs_cachekeeper_capacityStopping=NO;
                page.status=[page.status stringByAppendingString:@" 已保留本轮原始时间；点“汇总已保存诊断”后导出。"];
                [page axs_cachekeeper_capacity_text:result];
            }
            [page axs_cachekeeper_refresh];
        });
    });
}
- (void)axs_cachekeeper_capacity_text:(NSDictionary *)result {
    NSMutableString *text=[NSMutableString stringWithFormat:@"本轮全容器只读测量：%@\n源登记时间：%@；开始：%@；最后观测：%@\n结束根 %@/%@，失败 %@。\n\n每根单独计量；共享容器只测一次，关联多个 APP 不重复求全机总量。无登记容器不表示占用 0。风起云涌已排除。\n逻辑字节 / 已分配字节均非可清理量；用途未验证的资源保持不动，APFS 唯一 extents 和实际可释放空间未测量。\n\n已分配量最大的 50 个登记根（全部根和匿名层次见导出报告）：\n",result[@"state"],result[@"sourceSampledAt"],result[@"startedAt"],result[@"updatedAt"],result[@"completedRoots"],result[@"totalRoots"],result[@"failedRoots"]];
    NSArray *roots=[result[@"roots"] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b) {
        NSComparisonResult order=[b[@"measurement"][@"allocatedBytes"] compare:a[@"measurement"][@"allocatedBytes"]];
        return order==NSOrderedSame ? [a[@"id"] compare:b[@"id"]] : order;
    }];
    NSUInteger index=0;
    for (NSDictionary *root in roots) {
        if (index++>=50) break;
        NSDictionary *measurement=root[@"measurement"];
        [text appendFormat:@"\n根 %@ · %@\n%@\n状态 %@；",root[@"id"],[root[@"roles"] componentsJoinedByString:@" / "],[root[@"owners"] componentsJoinedByString:@", "],measurement[@"state"]];
        if (![measurement[@"entries"] unsignedLongLongValue] && ![measurement[@"state"] isEqual:@"complete"])
            [text appendString:@"尚未取得有效容量，不能填 0。\n"];
        else [text appendFormat:@"%@逻辑 %.3f GB / 分配 %.3f GB\n",[measurement[@"state"] isEqual:@"complete"] ? @"" : @"不完整观测：",[measurement[@"logicalBytes"] doubleValue]/1e9,[measurement[@"allocatedBytes"] doubleValue]/1e9];
        NSArray *nodes=[measurement[@"nodes"] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b) {return [b[@"allocatedBytes"] compare:a[@"allocatedBytes"]];}];
        NSUInteger shown=0;
        for (NSDictionary *node in nodes) {
            if (![node[@"parent"] unsignedIntegerValue]) continue;
            if (shown++>=3) break;
            [text appendFormat:@"  匿名节点 %@ · %@：逻辑 %.3f GB / 分配 %.3f GB\n",node[@"id"],node[@"category"],[node[@"logicalBytes"] doubleValue]/1e9,[node[@"allocatedBytes"] doubleValue]/1e9];
        }
        if ([measurement[@"layoutProfile"] isEqual:@"swiftgramGroupStructureV1"]) {
            NSDictionary *labels=@{@"postboxDatabase":@"Postbox 数据库",@"postboxMedia":@"Postbox 媒体",@"postboxMediaCache":@"媒体缓存子目录",@"postboxMediaShortCache":@"短期媒体缓存子目录",@"postboxMediaAnimationCache":@"动画媒体缓存子目录",@"logs":@"日志目录"};
            [text appendString:@"  私有资源结构分类（本轮观察，不授予清理；父子容量不要相加）：\n"];
            NSUInteger classified=0;
            for (NSDictionary *node in nodes) {
                NSString *label=labels[node[@"category"]];if (!label) continue;
                if (classified++>=12) { [text appendString:@"  其余分类节点见导出报告。\n"];break; }
                [text appendFormat:@"  %@ · 节点 %@：逻辑 %.3f GB / 分配 %.3f GB\n",label,node[@"id"],[node[@"logicalBytes"] doubleValue]/1e9,[node[@"allocatedBytes"] doubleValue]/1e9];
            }
            if (!classified) [text appendString:@"  本轮未识别出这些结构，不表示占用为 0。\n"];
        }
    }
    NSMutableArray *noRoots=[NSMutableArray new];
    for (NSDictionary *entry in result[@"entries"]) if ([entry[@"state"] isEqual:@"noRegisteredRoots"]) [noRoots addObject:entry[@"bundle"]];
    [text appendFormat:@"\n没有登记数据根的 APP（不能补 0）：%@\n\n点击“汇总已保存诊断”，再“导出报告”。汇总不会重复测量；保存观测的时间不表示导出时仍是相同占用。",[noRoots componentsJoinedByString:@", "]];
    self.text.text=text;
}
- (void)axs_cachekeeper_capacity_stop {
    NSString *epoch=self.axs_cachekeeper_capacityEpoch;
    if (epoch) {
        NSError *error=nil;
        BOOL saved=[self axs_cachekeeper_capacity_write_stop:epoch error:&error];
        if (!saved) {
            self.axs_cachekeeper_capacityError=@"cancelRequestWriteFailed";
            NSLog(@"[CacheKeeper] 容量测量停止请求保存失败：%ld",(long)error.code);
        } else self.axs_cachekeeper_capacityError=nil;
        self.axs_cachekeeper_capacityPendingStop=@{@"epoch":epoch,@"attemptedAt":@((uint64_t)NSDate.date.timeIntervalSince1970),
            @"requestWrite":saved ? @"saved" : @"failed",@"confirmation":@"unconfirmed"};
    }
    [self.axs_cachekeeper_capacityTimer invalidate];self.axs_cachekeeper_capacityTimer=nil;
    self.axs_cachekeeper_capacityEpoch=nil;self.axs_cachekeeper_capacityStopping=NO;
}
- (NSDictionary *)axs_cachekeeper_capacity_export:(NSDictionary *)snapshot saved:(NSDictionary *)saved stop:(NSDictionary *)stop {
    BOOL frozen=snapshot[@"epoch"] && ![snapshot[@"state"] isEqual:@"running"];
    NSString *wanted=snapshot[@"epoch"] ?: stop[@"epoch"];
    NSDictionary *capacity=saved;
    NSString *savedState=[saved[@"state"] isKindOfClass:NSString.class] ? saved[@"state"] : @"";
    BOOL savedTerminal=[@[@"complete",@"partial",@"cancelled",@"interrupted",@"unavailable"] containsObject:savedState];
    BOOL staleFrozen=frozen && (!savedTerminal ||
        ![saved[@"epoch"] isEqual:snapshot[@"epoch"]] || ![saved[@"state"] isEqual:snapshot[@"state"]] ||
        ![saved[@"finishedAt"] isEqual:snapshot[@"finishedAt"]]);
    BOOL savedSupersedesSnapshot=NO;
    if (frozen && staleFrozen) {
        NSDictionary *history=saved[@"terminalHistory"];
        for (NSDictionary *terminal in history[@"records"]) {
            if ([terminal[@"epoch"] isEqual:snapshot[@"epoch"]]) {savedSupersedesSnapshot=YES;break;}
        }
        savedSupersedesSnapshot |= [saved[@"lifecycle"][@"previousObservedEpoch"] isEqual:snapshot[@"epoch"]];
    }
    if (frozen && savedTerminal && [saved[@"epoch"] isEqual:snapshot[@"epoch"]]) capacity=saved;
    else if (frozen && savedSupersedesSnapshot) capacity=saved;
    else if (frozen) capacity=snapshot;
    else if (wanted && ![saved[@"epoch"] isEqual:wanted]) capacity=snapshot;
    if (!capacity) capacity=@{@"schemaVersion":@1,@"state":@"notMeasured"};
    NSMutableDictionary *out=[capacity mutableCopy];
    if (frozen && staleFrozen && [capacity[@"epoch"] isEqual:snapshot[@"epoch"]]) out[@"summaryBinding"]=@{@"state":@"stale"};
    if (stop) {
        NSMutableDictionary *receipt=[stop mutableCopy];
        if ([capacity[@"epoch"] isEqual:stop[@"epoch"]] && ![capacity[@"state"] isEqual:@"running"]) receipt[@"confirmation"]=@"terminalObserved";
        else {
            // Summary-only history must not be represented as a full result.
            for (NSDictionary *terminal in saved[@"terminalHistory"][@"records"]) if ([terminal[@"epoch"] isEqual:stop[@"epoch"]]) {
                receipt[@"confirmation"]=@"terminalHistoryObserved";receipt[@"terminal"]=terminal;break;
            }
        }
        out[@"clientStop"]=receipt;
    }
    return axs_cachekeeper_capacity_projection(out);
}
- (void)axs_cachekeeper_capacity_background:(NSNotification *)notification {
    (void)notification;if (!self.axs_cachekeeper_capacityEpoch) return;
    [self axs_cachekeeper_capacity_stop];self.status=self.axs_cachekeeper_capacityError ? @"进入后台时停止请求保存失败；尚未确认服务停止。" : @"进入后台已请求停止测量；回到本页后可汇总已保存实际终态或重新测量。";
    [self axs_cachekeeper_refresh];
}
- (void)axs_cachekeeper_collect {
    if (self.collecting || self.sharing || self.axs_cachekeeper_capacityEpoch) return;
    if (self.axs_cachekeeper_pdfSession && self.axs_cachekeeper_pdfReady) {
        self.axs_cachekeeper_pdfReady=NO;self.collecting=YES;self.reportData=nil;
        self.status=@"正在复核安装与目录身份并开始有界定位…";[self axs_cachekeeper_refresh];[self.axs_cachekeeper_pdfSession start];return;
    }
    if (self.axs_cachekeeper_pdfSession && !self.axs_cachekeeper_pdfReportable) return;
    self.collecting=YES;self.reportData=nil;self.completed=0;self.total=0;
    self.status=@"正在获取当前安装列表、配置和已有记录…";[self axs_cachekeeper_refresh];
    self.progressView.accessibilityLabel=@"已读取的 APP 保存记录";
    NSUInteger generation=++self.generation;
    NSBundle *bundle=[NSBundle bundleForClass:self.class];
#if defined(__arm64e__)
    NSString *architecture=@"arm64e";
#else
    NSString *architecture=@"arm64";
#endif
    NSMutableDictionary *environment=[@{@"os":UIDevice.currentDevice.systemVersion,@"architecture":architecture,@"pluginVersion":[bundle objectForInfoDictionaryKey:@"CacheKeeperPackageVersion"] ?: @"unknown"} mutableCopy];
    if (self.axs_cachekeeper_searchSnapshot) environment[@"searchUI"]=self.axs_cachekeeper_searchSnapshot;
    if (self.axs_cachekeeper_pdfSnapshot) {
        NSMutableDictionary *pdf=[self.axs_cachekeeper_pdfSnapshot mutableCopy];pdf[@"bundle"]=self.axs_cachekeeper_pdfBundle;pdf[@"path"]=self.axs_cachekeeper_pdfRelative;
        environment[@"pdfLocate"]=pdf;
    }
    NSString *capacityPath=[self axs_cachekeeper_capacity_file:@"capacityResult.plist"];
    NSDictionary *capacitySnapshot=self.axs_cachekeeper_capacitySnapshot;
    NSDictionary *capacityStop=self.axs_cachekeeper_capacityPendingStop;
    NSMutableDictionary *installationCache=self.installationCache;__weak typeof(self) weak=self;
    dispatch_async(self.collectionQueue,^{
        NSMutableDictionary *collectionEnvironment=[environment mutableCopy];
        NSError *capacityError=nil;
        NSDictionary *saved=axs_cachekeeper_capacity_read_result(capacityPath,&capacityError);
        NSDictionary *capacity=[weak axs_cachekeeper_capacity_export:capacitySnapshot saved:saved stop:capacityStop];
        BOOL capacityMatchesSavedTerminal=[capacity[@"epoch"] isEqual:saved[@"epoch"]] &&
            ![@[@"running",@"invalid",@"notMeasured"] containsObject:saved[@"state"]] &&
            [saved[@"finishedAt"] isEqual:capacity[@"finishedAt"]];
        BOOL bindingNotStale=![capacity[@"summaryBinding"][@"state"] isEqual:@"stale"];
        if (capacityMatchesSavedTerminal && bindingNotStale) {
            NSMutableDictionary *bound=[capacity mutableCopy];
            NSDictionary *binding=@{@"epoch":saved[@"epoch"],@"terminalState":saved[@"state"],
                @"terminalFinishedAt":saved[@"finishedAt"],@"summarizedAt":@((uint64_t)NSDate.date.timeIntervalSince1970)};
            bound[@"summaryBinding"]=axs_cachekeeper_capacity_summary_binding(binding,capacity);
            capacity=axs_cachekeeper_capacity_projection(bound);
        } else if (capacity[@"epoch"] && [capacity[@"state"] isEqual:@"running"]) {
            NSMutableDictionary *unbound=[capacity mutableCopy];unbound[@"summaryBinding"]=@{@"state":@"unknown"};
            capacity=axs_cachekeeper_capacity_projection(unbound);
        }
        collectionEnvironment[@"capacityMeasurement"]=capacity ?: @{@"schemaVersion":@1,@"state":capacityError ? @"invalid" : @"notMeasured"};
        collectionEnvironment[@"diagnosticChannel"]=axs_cachekeeper_diagnostic_channel_hello();
        // Reuse unchanged package metadata, but obtain current membership on every collection.
        NSError *installationError=nil;
        NSDictionary *containerCoverage=nil,*registryInventory=nil;
        NSArray *apps=axs_cachekeeper_installed_applications_with_registry_inventory(installationCache,&containerCoverage,&registryInventory,&installationError);
        collectionEnvironment[@"containerCoverage"]=containerCoverage;
        collectionEnvironment[@"registryInventory"]=registryInventory;
        if (installationError) apps=nil;
        AxsCacheKeeperDiagnostics *session=[[AxsCacheKeeperDiagnostics alloc] initWithFolder:jbroot(@"/var/mobile/Library/CacheKeeper")];
        NSDictionary *report=[session reportWithApps:apps environment:collectionEnvironment progress:^(NSUInteger completed,NSUInteger total) {
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
            if (capacity[@"epoch"] && ![capacity[@"state"] isEqual:@"running"] && [capacity[@"summaryBinding"][@"state"] isEqual:@"current"]) {
                page.axs_cachekeeper_capacitySnapshot=capacity;page.axs_cachekeeper_capacityPendingStop=nil;
            }
            page.status=data ? [NSString stringWithFormat:@"已汇总 %lu/%lu 个展示或配置 APP；全机清单含 %lu 项，仅汇总元数据与已有记录。点击“导出报告”保存。",(unsigned long)page.completed,(unsigned long)page.total,(unsigned long)[report[@"storageInventory"][@"entries"] count]] : @"报告生成失败，尚未保存；可以重新采集。";
            if (data && [capacity[@"clientStop"][@"confirmation"] isEqual:@"unconfirmed"])
                page.status=[page.status stringByAppendingString:@" 容量停止尚未确认；running 仅为最后保存观测，不代表服务当前仍运行。"];
            else if (data && [capacity[@"clientStop"][@"confirmation"] isEqual:@"terminalHistoryObserved"])
                page.status=[page.status stringByAppendingString:@" 容量停止仅取得历史终态摘要，完整结果保存状态见回执。"];
            if (data && (![@[@"available",@"missing"] containsObject:report[@"sourceStates"][@"configuration"]] || ![@[@"available",@"missing"] containsObject:report[@"sourceStates"][@"selection"]] || ![report[@"sourceStates"][@"installedApplications"] isEqual:@"available"]))
                page.status=@"报告已在内存生成，但安装列表或部分配置不可用；可导出查看来源状态。";
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
    NSDictionary *report=self.reportData ? [NSJSONSerialization JSONObjectWithData:self.reportData options:NSJSONReadingFragmentsAllowed error:NULL] : nil;
    if (self.collecting || self.sharing || !self.reportData || !axs_cachekeeper_capacity_report_exportable(report) || self.axs_cachekeeper_capacityEpoch) return;
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
        [page axs_cachekeeper_capacity_stop];page.axs_cachekeeper_capacitySnapshot=nil;
        page.generation++;page.reportData=nil;page.collecting=NO;page.sharing=NO;
        page.axs_cachekeeper_searchSnapshot=nil;
        [page.axs_cachekeeper_pdfSession cancel];page.axs_cachekeeper_pdfSnapshot=nil;page.axs_cachekeeper_pdfReady=NO;page.axs_cachekeeper_pdfFinished=NO;page.axs_cachekeeper_pdfReportable=NO;
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
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    // Capacity-only completion handling leaves PDF/share and cancelled transitions unchanged.
    if (!self.axs_cachekeeper_capacityEpoch || self.sharing) return;
    BOOL pushed=self.navigationController && self.navigationController.topViewController!=self;
    BOOL covered=self.presentedViewController && !self.view.window;
    if (!pushed && !covered && self.view.window) return;
    [self axs_cachekeeper_capacity_stop];self.generation++;self.reportData=nil;self.axs_cachekeeper_capacitySnapshot=nil;
    self.status=@"实际离页已请求停止测量；服务终态以保存记录为准。";
    [self axs_cachekeeper_refresh];
}
- (void)dealloc {[NSNotificationCenter.defaultCenter removeObserver:self];[self.axs_cachekeeper_pdfSession cancel];[self axs_cachekeeper_capacity_stop];}
- (void)axs_cachekeeper_pdf_background:(NSNotification *)notification {(void)notification;[self axs_cachekeeper_pdf_cancel];}
- (void)axs_cachekeeper_pdf_cancel {
    [self.axs_cachekeeper_pdfSession cancel];self.generation++;self.reportData=nil;self.collecting=NO;
    self.axs_cachekeeper_pdfSnapshot=nil;self.axs_cachekeeper_pdfReady=NO;self.axs_cachekeeper_pdfFinished=NO;self.axs_cachekeeper_pdfReportable=NO;
    self.status=@"已请求停止；本页候选及报告已释放，服务在当前读取返回后释放资源。返回目录页可重新检查。";[self axs_cachekeeper_pdf_text];[self axs_cachekeeper_refresh];
}
- (void)axs_cachekeeper_pdf_text {
    NSMutableAttributedString *text=[[NSMutableAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@\n\n只定位当前 APP 的这一个数据目录。最多枚举 10000 项、读取 16 MiB 格式样本或运行 5 秒，每项最多读取 4 KB；单次系统读取可能延迟停止。不会搜索其他容器或删除文件。\n\nPDF 特征候选不代表就是测试文件，也不证明可以删除；硬链接路径数与逻辑大小不等于实际占用。未命中且覆盖不全，不能据此判断目录没有 PDF。\n\n",self.axs_cachekeeper_pdfRelative]];
    NSDictionary *snapshot=self.axs_cachekeeper_pdfSnapshot;
    if (self.axs_cachekeeper_pdfReportable && !self.axs_cachekeeper_pdfFinished)
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"未执行或会话已失效：%@，代码 %@。具体阶段可随同一份诊断报告导出。\n",snapshot[@"stage"] ?: @"session",snapshot[@"errorCode"] ?: @0]]];
    if (self.axs_cachekeeper_pdfFinished) {
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"停止原因：%@；覆盖%@。\nPDF 路径 %@ 个，展示最多 10 个%@。\n枚举 %@ 项，样本 %@ 字节；读取失败 %@，文件变化 %@。\n\n",snapshot[@"stopReason"] ?: @"error",[snapshot[@"coverageComplete"] boolValue] ? @"完整" : @"不完整",snapshot[@"pdfPathCount"] ?: @0,[snapshot[@"pdfCandidatesTruncated"] boolValue] ? @"（已截断）" : @"",snapshot[@"enumeratedCount"] ?: @0,snapshot[@"sampleBytes"] ?: @0,snapshot[@"readFailureCount"] ?: @0,snapshot[@"changedCount"] ?: @0]]];
        NSUInteger index=0;
        for (NSDictionary *candidate in snapshot[@"pdfCandidates"]) {
            NSString *line=[NSString stringWithFormat:@"%@ · %.2f MB · 链接数 %@\n",candidate[@"path"],[candidate[@"bytes"] doubleValue]/1048576,candidate[@"linkCount"]];
            [text appendAttributedString:[[NSAttributedString alloc] initWithString:line attributes:@{NSLinkAttributeName:[NSURL URLWithString:[NSString stringWithFormat:@"cachekeeper-pdf://candidate/%lu",(unsigned long)index++]]}]];
        }
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n点击候选会重新验证安装与文件身份，再向 Filza 投递所在目录；投递成功不代表已观察到 Filza 展示结果。\n\n手动导出的同一份 JSON 会匿名化候选路径。候选与报告只在本页内存，停止、返回或切到后台后释放。"]];
    }
    [text addAttribute:NSFontAttributeName value:[UIFont preferredFontForTextStyle:UIFontTextStyleBody] range:NSMakeRange(0,text.length)];self.text.attributedText=text;
}
- (BOOL)textView:(UITextView *)textView shouldInteractWithURL:(NSURL *)url inRange:(NSRange)range interaction:(UITextItemInteraction)interaction {
    (void)textView;(void)range;(void)interaction;
    if (![url.scheme isEqual:@"cachekeeper-pdf"] || !self.axs_cachekeeper_pdfFinished) return NO;
    [self axs_cachekeeper_pdf_filza:(NSUInteger)url.lastPathComponent.integerValue generation:self.generation];return NO;
}
- (void)axs_cachekeeper_pdf_filza:(NSUInteger)index generation:(NSUInteger)generation {
    __weak typeof(self) weak=self;
    dispatch_async(self.collectionQueue,^{
        Class proxyClass=NSClassFromString(@"LSApplicationProxy");SEL lookup=NSSelectorFromString(@"applicationProxyForIdentifier:");
        id proxy=[proxyClass respondsToSelector:lookup] ? ((id(*)(id,SEL,id))objc_msgSend)(proxyClass,lookup,AxsCacheKeeperFilzaBundleID) : nil;
        SEL bundleSelector=NSSelectorFromString(@"bundleURL");NSURL *bundle=[proxy respondsToSelector:bundleSelector] ? ((id(*)(id,SEL))objc_msgSend)(proxy,bundleSelector) : nil;
        NSDictionary *info=[bundle isKindOfClass:NSURL.class] ? [NSDictionary dictionaryWithContentsOfURL:[bundle URLByAppendingPathComponent:@"Info.plist"]] : nil;
        dispatch_async(dispatch_get_main_queue(),^{
            AxsCacheKeeperDiagnosticsPage *page=weak;if (!page || page.generation!=generation || !page.view.window) return;
            if (!info) {[page axs_cachekeeper_message:@"无法读取 Filza 的系统注册信息，未发送打开请求。"];return;}
            [page.axs_cachekeeper_pdfSession resolveCandidate:index completion:^(NSString *directory,NSDictionary *status) {
            AxsCacheKeeperDiagnosticsPage *current=weak;if (!current || current.generation!=generation || !current.view.window) return;
            NSURL *url=directory ? axs_cachekeeper_filza_url(directory,info) : nil;
            if (!url) {[current axs_cachekeeper_message:[NSString stringWithFormat:@"候选已失效或无法读取（%@/%@），未发送打开请求。",status[@"stage"] ?: @"candidate",status[@"errorCode"] ?: @0]];return;}
            __block BOOL finished=NO;
            void (^complete)(BOOL,NSError *)=^(BOOL success,NSError *error) {dispatch_async(dispatch_get_main_queue(),^{
                AxsCacheKeeperDiagnosticsPage *owner=weak;if (finished || !owner || owner.generation!=generation) return;finished=YES;
                owner.status=success ? @"已向 Filza 投递目录打开请求。" : [NSString stringWithFormat:@"Filza 打开请求失败（代码 %ld），未确认目录展示。",(long)error.code];[owner axs_cachekeeper_refresh];
            });};
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,8*NSEC_PER_SEC),dispatch_get_main_queue(),^{complete(NO,[NSError errorWithDomain:@"CacheKeeper.Filza" code:ETIMEDOUT userInfo:nil]);});
            if (!url.isFileURL) {[UIApplication.sharedApplication openURL:url options:@{} completionHandler:^(BOOL success){complete(success,nil);}];return;}
            static void *frontBoard;static dispatch_once_t once;dispatch_once(&once,^{frontBoard=dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices",RTLD_LAZY|RTLD_LOCAL);});
            CFStringRef const *address=frontBoard ? (CFStringRef const *)dlsym(frontBoard,"FBSOpenApplicationOptionKeyPayloadURL") : NULL;
            NSString *key=address ? (__bridge NSString *)*address : nil;Class workspaceClass=NSClassFromString(@"LSApplicationWorkspace");SEL shared=NSSelectorFromString(@"defaultWorkspace");
            id workspace=[workspaceClass respondsToSelector:shared] ? ((id(*)(id,SEL))objc_msgSend)(workspaceClass,shared) : nil;
            axs_cachekeeper_send_filza_document(workspace,[NSClassFromString(@"_LSOpenConfiguration") new],key,url,complete);
            }];
        });
    });
}
@end
