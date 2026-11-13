#import "InspectionPage.h"
#import "../AxsCacheKeeperPolicy.h"
#import "../AxsCacheKeeperSelection.h"
#include <roothide.h>

@interface AxsCacheKeeperInspectionPage ()
@property(nonatomic,copy) NSString *bundle;
@property(nonatomic,copy) NSString *relative;
@property(nonatomic,copy) NSString *token;
@property(nonatomic,strong) UITextView *textView;
@property(nonatomic,strong) UIBarButtonItem *judgeButton;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic,strong) NSDate *submitted;
@property(nonatomic) BOOL stopping;
@property(nonatomic,copy) NSString *requestError;
@end
@implementation AxsCacheKeeperInspectionPage
- (instancetype)initWithBundle:(NSString *)bundle path:(NSString *)path {
    self=[super init];if (self) { _bundle=[bundle copy];_relative=[path copy]; }return self;
}
- (NSString *)axs_cachekeeper_file:(NSString *)name { return [jbroot(@"/var/mobile/Library/CacheKeeper") stringByAppendingPathComponent:name]; }
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"目录档案 · 只读";
    self.textView=[[UITextView alloc] initWithFrame:self.view.bounds];self.textView.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    self.textView.editable=NO;self.textView.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];self.textView.adjustsFontForContentSizeCategory=YES;
    self.textView.textContainerInset=UIEdgeInsetsMake(16,16,16,16);[self.view addSubview:self.textView];
    self.navigationItem.rightBarButtonItems=@[
        [[UIBarButtonItem alloc] initWithTitle:@"深度检测" style:UIBarButtonItemStylePlain target:self action:@selector(axs_cachekeeper_start)],
        [[UIBarButtonItem alloc] initWithTitle:@"停止" style:UIBarButtonItemStylePlain target:self action:@selector(axs_cachekeeper_stop)]];
    // 日志目录定级只对用途未知类目录开放：先在本页看完深度检测证据，再由用户逐项判定。
    if ([axs_cachekeeper_directory_kind(self.relative) isEqual:@"unknown"]) {
        self.judgeButton=[[UIBarButtonItem alloc] initWithTitle:@"定级·日志" style:UIBarButtonItemStylePlain target:self action:@selector(axs_cachekeeper_judge)];
        self.navigationItem.rightBarButtonItems=[self.navigationItem.rightBarButtonItems arrayByAddingObject:self.judgeButton];
        [self axs_cachekeeper_update_judge_button];
    }
    [self axs_cachekeeper_refresh];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];__weak typeof(self) weak=self;
    self.timer=[NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer){[weak axs_cachekeeper_refresh];}];
}
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated];[self.timer invalidate];self.timer=nil; }
- (void)dealloc { [self.timer invalidate]; }
- (void)axs_cachekeeper_start {
    NSString *token=NSUUID.UUID.UUIDString;NSError *error=nil;
    NSDictionary *request=@{@"bundle":self.bundle,@"path":self.relative,@"token":token};
    if (![request writeToURL:[NSURL fileURLWithPath:[self axs_cachekeeper_file:@"inspectionRequest.plist"]] error:&error]) {
        self.requestError=[NSString stringWithFormat:@"提交检测失败：%@（%@/%ld）。检查插件配置目录是否可写后重试。",error.localizedDescription,error.domain,(long)error.code];[self axs_cachekeeper_refresh];return;
    }
    self.token=token;self.submitted=NSDate.date;self.stopping=NO;self.requestError=nil;[self axs_cachekeeper_refresh];
}
- (void)axs_cachekeeper_stop {
    NSString *file=[self axs_cachekeeper_file:@"inspectionRequest.plist"];
    NSMutableDictionary *request=[[NSDictionary dictionaryWithContentsOfFile:file] mutableCopy];
    if (![request[@"bundle"] isEqual:self.bundle] || ![request[@"path"] isEqual:self.relative]) return;
    request[@"cancel"]=@YES;NSError *error=nil;
    if (![request writeToURL:[NSURL fileURLWithPath:file] error:&error]) self.requestError=[@"停止请求保存失败：" stringByAppendingString:error.localizedDescription];
    else { self.token=request[@"token"];self.stopping=YES;self.requestError=nil; }
    [self axs_cachekeeper_refresh];
}
- (BOOL)axs_cachekeeper_judged {
    NSDictionary *states=[NSDictionary dictionaryWithContentsOfFile:[self axs_cachekeeper_file:@"appEnabled.plist"]];
    return [axs_cachekeeper_log_paths(states[self.bundle]) containsObject:self.relative];
}
- (void)axs_cachekeeper_update_judge_button {
    self.judgeButton.title=[self axs_cachekeeper_judged] ? @"取消定级" : @"定级·日志";
}
- (void)axs_cachekeeper_judge {
    BOOL judged=[self axs_cachekeeper_judged];
    if (!judged) {
        // 证据门：没有一份已完成且读到过普通文件的深度检测档案，不予定级（如 Pitaya 读到 0 个文件）。
        NSDictionary *report=[NSDictionary dictionaryWithContentsOfFile:[self axs_cachekeeper_file:[NSString stringWithFormat:@"Status/%@.inspection.plist",self.bundle]]][@"reports"][self.relative];
        if (![report[@"path"] isEqual:self.relative] || ![report[@"complete"] boolValue] || ![report[@"files"] unsignedIntegerValue]) {
            self.requestError=@"证据不足：请先完成一次深度检测且读到至少 1 个普通文件，再定级为日志目录。";
            [self axs_cachekeeper_refresh];return;
        }
    }
    NSString *error=axs_cachekeeper_set_log_path(jbroot(@"/var/mobile/Library/CacheKeeper"),self.bundle,self.relative,!judged);
    if (error) self.requestError=error;
    else { self.requestError=nil; axs_cachekeeper_notify_preferences(); }
    [self axs_cachekeeper_update_judge_button];
    [self axs_cachekeeper_refresh];
}
- (void)axs_cachekeeper_refresh {
    NSDictionary *report=[NSDictionary dictionaryWithContentsOfFile:[self axs_cachekeeper_file:[NSString stringWithFormat:@"Status/%@.inspection.plist",self.bundle]]][@"reports"][self.relative];
    BOOL matches=!self.token || [report[@"token"] isEqual:self.token];
    if (matches && ([report[@"complete"] boolValue] || [report[@"cancelled"] boolValue])) self.stopping=NO;
    NSMutableString *text=[NSMutableString stringWithFormat:@"%@\n\n完整枚举本目录，每个普通文件读取最多 4 KB 文件头；不设总文件数上限。链接与敏感目录跳过，不修改 APP 文件。点击右上角深度检测开始，也可再次检测。\n\n",self.relative];
    if (self.requestError.length) [text appendFormat:@"%@\n\n",self.requestError];
    if (self.stopping) [text appendString:@"已请求停止，等待当前请求的停止回执。\n\n"];
    NSDictionary *autoReport=[NSDictionary dictionaryWithContentsOfFile:[self axs_cachekeeper_file:[NSString stringWithFormat:@"Status/%@.auto.plist",self.bundle]]];
    NSDictionary *cleanup=autoReport[@"directories"][self.relative];
    if (cleanup) {
        // 轮次状态按残留推导（任务 5）：覆盖不完整或有未确认残留时不显示"完成"，
        // 零删除也不冒充"已经干净"；残留三类互斥（待处理/延期/待识别），失败是独立诊断。
        // 结转报告（skipped）本轮未重扫：只显示已登记的未确认残留，未测量字段不写 0。
        BOOL skipped=[cleanup[@"skipped"] boolValue];
        NSUInteger deferred=cleanup[@"deferred"] ? [cleanup[@"deferred"] unsignedIntegerValue] : [cleanup[@"recent"] unsignedIntegerValue] + [cleanup[@"changed"] unsignedIntegerValue];
        NSString *roundState;
        if (skipped) roundState=@"本轮未重扫（残留为上轮登记）";
        else if ([cleanup[@"cancelled"] boolValue]) roundState=@"已中止";
        else if (![cleanup[@"complete"] boolValue]) roundState=@"尚未完成";
        else if ([cleanup[@"failed"] unsignedIntegerValue]) roundState=[NSString stringWithFormat:@"失败（%@ 项）",cleanup[@"failed"]];
        else if (![autoReport[@"coverageComplete"] boolValue]) roundState=@"发现不完整（本轮未覆盖全部范围）";
        else if ([cleanup[@"unresolved"] unsignedIntegerValue]) roundState=@"待识别";
        else if (deferred) roundState=@"等待延期文件";
        else if ([cleanup[@"remaining"] unsignedIntegerValue]) roundState=[NSString stringWithFormat:@"部分完成（待处理 %@ 项）",cleanup[@"remaining"]];
        else roundState=@"完成";
        if (skipped) [text appendFormat:@"最近一轮清理记录（%@）：%@\n删除 %@ 个文件 · %.2f MB；待识别 %@ 项 · %.2f MB。\n%@\n\n",axs_cachekeeper_time_string(cleanup[@"updated"]),roundState,cleanup[@"removed"] ?: @0,[cleanup[@"bytes"] doubleValue]/1048576,cleanup[@"unresolved"] ?: @0,[cleanup[@"unresolvedBytes"] doubleValue]/1048576,cleanup[@"error"] ?: @""];
        else if (![cleanup[@"measurementComplete"] boolValue]) [text appendFormat:@"最近清理记录（%@）：测量未完成，残留数量与大小未知；已删除 %@ 项，失败 %@ 项。\n%@\n\n",axs_cachekeeper_time_string(cleanup[@"updated"]),cleanup[@"removed"] ?: @0,cleanup[@"failed"] ?: @0,cleanup[@"error"] ?: @""];
        else [text appendFormat:@"最近一轮清理记录（%@）：%@\n删除 %@ 个文件 · %.2f MB；保留受保护 %@ 项，延期 %lu 项 · %.2f MB，失败 %@ 项，待识别 %@ 项 · %.2f MB，待处理 %@ 项 · %.2f MB。\n%@\n\n",axs_cachekeeper_time_string(cleanup[@"updated"]),roundState,cleanup[@"removed"] ?: @0,[cleanup[@"bytes"] doubleValue]/1048576,cleanup[@"protected"] ?: @0,(unsigned long)deferred,[cleanup[@"deferredBytes"] doubleValue]/1048576,cleanup[@"failed"] ?: @0,cleanup[@"unresolved"] ?: @0,[cleanup[@"unresolvedBytes"] doubleValue]/1048576,cleanup[@"remaining"] ?: @0,[cleanup[@"remainingBytes"] doubleValue]/1048576,cleanup[@"error"] ?: @""];
    }
    else [text appendString:@"本目录尚无清理回执；占用减少不能据此归因于插件。\n\n"];
    if ([cleanup[@"purgeClassification"] isEqual:@"invalid"]) [text appendFormat:@"内容审查：规则依赖已变化（%@），相关范围本轮延期，下轮重新预检。\n\n",cleanup[@"purgeEvidence"] ?: @""];
    else if ([cleanup[@"purgeClassification"] isEqual:@"paused"]) [text appendString:@"内容审查：未知内容待识别，暂不自动清理；专属识别规则后续按占用补充。\n\n"];
    if ([self axs_cachekeeper_judged]) [text appendString:@"本目录已定级为日志目录：该 APP 完全退出后，仅清理本目录内的日志特征文件（.log/.alog/.xlog），数据与未知内容保留；可在本页取消定级。\n\n"];
    for (NSDictionary *failure in cleanup[@"failureDetails"]) [text appendFormat:@"失败样本：%@ · errno %@\n%@\n%@\n\n",failure[@"stage"],failure[@"code"],failure[@"path"],failure[@"detail"]];
    if (![report[@"path"] isEqual:self.relative] || (self.token && ![report[@"token"] isEqual:self.token])) {
        [text appendString:self.token ? @"等待检测服务响应…" : @"尚无本目录档案。"];
        if (self.submitted && -self.submitted.timeIntervalSinceNow>30) [text appendString:@"\n尚未收到回执：可能正在切换任务、桌面服务未加载或回执无法写入；可再次检测。持续失败请提供插件版本与此页面信息。"];
        self.textView.text=text;return;
    }
    BOOL complete=[report[@"complete"] boolValue],cancelled=[report[@"cancelled"] boolValue];
    [text appendFormat:@"%@ · %@\n读取 %lu 个普通文件，%.2f MB\n%@\n\n",cancelled ? @"已停止（部分结果）" : complete ? ([report[@"coverageComplete"] boolValue] ? @"枚举完成" : @"结束但未完整读取") : @"正在分批读取",axs_cachekeeper_time_string(report[@"updated"]),(unsigned long)[report[@"files"] unsignedIntegerValue],[report[@"bytes"] doubleValue]/1048576,report[@"evidence"] ?: @""];
    if (!complete && !cancelled && -[report[@"updated"] timeIntervalSinceNow]>30) [text appendString:@"进度超过 30 秒未更新；可以停止后重检，当前不能判定已完成。\n"];
    NSString *linkDetail=report[@"hardLinks"] ? [NSString stringWithFormat:@"跳过链接 %@ 项（硬链接 %@ 项、符号链接 %@ 项）",report[@"links"] ?: @0,report[@"hardLinks"] ?: @0,report[@"symlinks"] ?: @0] : [NSString stringWithFormat:@"跳过链接 %@ 项",report[@"links"] ?: @0];
    [text appendFormat:@"读取失败 %@ 项；扫描中变化 %@ 项；%@、敏感目录 %@ 项。\n%@\n",report[@"failures"] ?: @0,report[@"changed"] ?: @0,linkDetail,report[@"hidden"] ?: @0,report[@"error"] ?: @""];
    NSArray *twins=report[@"linkTwins"];
    // 孪生搜索状态（任务 7）：主扫描与孪生搜索的完整性分开报告；0 匹配时同样展示
    // 搜索失败与截断，不让"未找到"看起来像"已确认无孪生"。三类截断分别标明：
    // 源收集（硬链接源文件超 100 仅记前 100）、搜索（扫描超 10 万项）、展示（每源 3 条/总 50 条）。
    NSMutableArray *twinStatus=[NSMutableArray new];
    if ([report[@"twinCoverageComplete"] boolValue]) [twinStatus addObject:@"孪生搜索覆盖完整"];
    else [twinStatus addObject:@"孪生搜索未完整覆盖"];
    if ([report[@"twinFailures"] unsignedIntegerValue]) [twinStatus addObject:[NSString stringWithFormat:@"搜索失败 %@ 项",report[@"twinFailures"]]];
    if ([report[@"linkFilesTruncated"] boolValue]) [twinStatus addObject:@"源收集已截断（硬链接源文件超 100）"];
    if ([report[@"twinScanTruncated"] boolValue]) [twinStatus addObject:@"搜索已截断（扫描超 10 万项）"];
    if ([report[@"twinDisplayTruncated"] boolValue]) [twinStatus addObject:@"展示已截断（每源 3 条/总 50 条）"];
    NSString *twinStatusLine=[twinStatus componentsJoinedByString:@"；"];
    if ([twins isKindOfClass:NSArray.class] && twins.count) {
        [text appendFormat:@"\n硬链接孪生：%lu 处，涉及 %.2f MB（逻辑关联大小，按设备＋inode 去重，非实测释放空间）：\n",(unsigned long)twins.count,[report[@"twinBytes"] doubleValue]/1048576];
        NSUInteger shown=MIN(twins.count,(NSUInteger)20);
        for (NSUInteger i=0;i<shown;i++) [text appendFormat:@"%@ → %@\n",twins[i][@"source"],twins[i][@"twin"]];
        if (twins.count>shown) [text appendFormat:@"…等 %lu 处\n",(unsigned long)(twins.count-shown)];
        [text appendFormat:@"%@。\n当前清理跳过共享硬链接文件。外部链接仍存在时，删除本目录链接不会释放其数据；即使全部已观察链接均在本范围，也不能保证立即释放空间。\n\n",twinStatusLine];
    } else if ([report[@"hardLinks"] unsignedIntegerValue]) {
        [text appendFormat:@"硬链接文件未在其余位置找到孪生：可能孪生已被删除，或位于本次未覆盖的位置。\n%@。\n\n",twinStatusLine];
    }
    [text appendString:@"\n文件类型组成：\n"];
    for (NSString *kind in [report[@"types"] allKeys]) [text appendFormat:@"%@：%@ 个 · %.2f MB\n",kind,report[@"types"][kind][@"count"],[report[@"types"][kind][@"bytes"] doubleValue]/1048576];
    [text appendString:@"\n文件时间（取创建、修改和状态变更中最近时间）：\n"];
    for (NSString *age in @[@"不足 60 秒",@"60 秒至 1 天",@"1 至 30 天",@"30 天以上"]) [text appendFormat:@"%@：%@ 个\n",age,report[@"ages"][age] ?: @0];
    [text appendString:@"\n最大的 10 个文件：\n"];
    for (NSDictionary *file in report[@"largest"]) [text appendFormat:@"%@ · %.2f MB · %@\n",file[@"path"],[file[@"bytes"] doubleValue]/1048576,file[@"type"]];
    [text appendString:@"\n下一步判断：先确认检测完整。标准 Library/Caches、tmp 按平台缓存用途处理，数据库格式不单独构成保留依据；已确认的登录与业务状态、草稿、唯一副本及用户排除优先保留。非标准下载资源须有匹配的 APP 规则及恢复证据，未知内容暂不清理。可用 APP 自带的‘清理缓存’后重新检测作对照，但不能据此认定整个混合目录可删。\n\n这是读取期间的观察结果，不是原子快照。文件格式、旧文件和持续增长都不能单独证明可删；本页不会自动扩大清理范围。"];
    self.textView.text=text;
}
@end
