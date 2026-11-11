#import "InspectionPage.h"
#include <roothide.h>

@interface AxsCacheKeeperInspectionPage ()
@property(nonatomic,copy) NSString *bundle;
@property(nonatomic,copy) NSString *relative;
@property(nonatomic,copy) NSString *token;
@property(nonatomic,strong) UITextView *textView;
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
- (void)axs_cachekeeper_refresh {
    NSDictionary *report=[NSDictionary dictionaryWithContentsOfFile:[self axs_cachekeeper_file:[NSString stringWithFormat:@"Status/%@.inspection.plist",self.bundle]]][@"reports"][self.relative];
    BOOL matches=!self.token || [report[@"token"] isEqual:self.token];
    if (matches && ([report[@"complete"] boolValue] || [report[@"cancelled"] boolValue])) self.stopping=NO;
    NSMutableString *text=[NSMutableString stringWithFormat:@"%@\n\n完整枚举本目录，每个普通文件读取最多 4 KB 文件头；不设总文件数上限。链接与敏感目录跳过，不修改 APP 文件。点击右上角深度检测开始，也可再次检测。\n\n",self.relative];
    if (self.requestError.length) [text appendFormat:@"%@\n\n",self.requestError];
    if (self.stopping) [text appendString:@"已请求停止，等待当前请求的停止回执。\n\n"];
    NSDictionary *cleanup=[NSDictionary dictionaryWithContentsOfFile:[self axs_cachekeeper_file:[NSString stringWithFormat:@"Status/%@.auto.plist",self.bundle]]][@"directories"][self.relative];
    if (cleanup) [text appendFormat:@"最近一轮清理记录（%@）：%@\n删除 %@ 个文件 · %.2f MB；保留受保护／未知 %@ 项、近期文件 %@ 项，变化目录 %@ 项，失败 %@ 项。\n%@\n\n",cleanup[@"updated"],[cleanup[@"cancelled"] boolValue] ? @"已中止" : [cleanup[@"complete"] boolValue] ? @"检查完成" : @"尚未完成",cleanup[@"removed"],[cleanup[@"bytes"] doubleValue]/1048576,cleanup[@"protected"],cleanup[@"recent"],cleanup[@"changed"],cleanup[@"failed"],cleanup[@"error"] ?: @""];
    else [text appendString:@"本目录尚无清理回执；占用减少不能据此归因于插件。\n\n"];
    if (![report[@"path"] isEqual:self.relative] || (self.token && ![report[@"token"] isEqual:self.token])) {
        [text appendString:self.token ? @"等待检测服务响应…" : @"尚无本目录档案。"];
        if (self.submitted && -self.submitted.timeIntervalSinceNow>30) [text appendString:@"\n尚未收到回执：可能正在切换任务、桌面服务未加载或回执无法写入；可再次检测。持续失败请提供插件版本与此页面信息。"];
        self.textView.text=text;return;
    }
    BOOL complete=[report[@"complete"] boolValue],cancelled=[report[@"cancelled"] boolValue];
    [text appendFormat:@"%@ · %@\n读取 %lu 个普通文件，%.2f MB\n%@\n\n",cancelled ? @"已停止（部分结果）" : complete ? ([report[@"coverageComplete"] boolValue] ? @"枚举完成" : @"结束但未完整读取") : @"正在分批读取",report[@"updated"] ?: @"",(unsigned long)[report[@"files"] unsignedIntegerValue],[report[@"bytes"] doubleValue]/1048576,report[@"evidence"] ?: @""];
    if (!complete && !cancelled && -[report[@"updated"] timeIntervalSinceNow]>30) [text appendString:@"进度超过 30 秒未更新；可以停止后重检，当前不能判定已完成。\n"];
    [text appendFormat:@"读取失败 %@ 项；扫描中变化 %@ 项；跳过链接 %@ 项、敏感目录 %@ 项。\n%@\n\n文件类型组成：\n",report[@"failures"] ?: @0,report[@"changed"] ?: @0,report[@"links"] ?: @0,report[@"hidden"] ?: @0,report[@"error"] ?: @""];
    for (NSString *kind in [report[@"types"] allKeys]) [text appendFormat:@"%@：%@ 个 · %.2f MB\n",kind,report[@"types"][kind][@"count"],[report[@"types"][kind][@"bytes"] doubleValue]/1048576];
    [text appendString:@"\n文件时间（取创建、修改和状态变更中最近时间）：\n"];
    for (NSString *age in @[@"不足 60 秒",@"60 秒至 1 天",@"1 至 30 天",@"30 天以上"]) [text appendFormat:@"%@：%@ 个\n",age,report[@"ages"][age] ?: @0];
    [text appendString:@"\n最大的 10 个文件：\n"];
    for (NSDictionary *file in report[@"largest"]) [text appendFormat:@"%@ · %.2f MB · %@\n",file[@"path"],[file[@"bytes"] doubleValue]/1048576,file[@"type"]];
    [text appendString:@"\n这是读取期间的观察结果，不是原子快照。文件格式、旧文件和持续增长都不能单独证明可删；本页不会自动扩大清理范围。"];
    self.textView.text=text;
}
@end
