#import <UIKit/UIKit.h>
#include <roothide.h>
#include <sys/stat.h>
#import "../AxsCacheKeeperPolicy.h"
#import "../AxsCacheKeeperSelection.h"
#import "../AxsCacheKeeperFilza.h"
#import "InspectionPage.h"
#import "../AxsCacheKeeperInspection.h"
#import "../AxsCacheKeeperProbe.h"
#include <dlfcn.h>

@interface CKScanPage : UITableViewController
@property(nonatomic,copy) NSString *bundle;
@property(nonatomic,copy) NSString *appName;
@property(nonatomic,strong) NSArray *rows;
@property(nonatomic,strong) NSDictionary *previous;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic,copy) NSString *token;
@property(nonatomic) NSTimeInterval started;
@property(nonatomic,strong) NSTimer *statusTimer;
@property(nonatomic,copy) NSString *scanError;
@property(nonatomic,strong) NSMutableDictionary *displayCache;
@property(nonatomic,strong) UIBarButtonItem *scanButton;
@property(nonatomic,strong) UIBarButtonItem *enableAllButton;
@property(nonatomic,strong) NSArray *cacheRows;
@property(nonatomic,strong) NSArray *otherRows;
@property(nonatomic) BOOL showOtherData;
@property(nonatomic,strong) NSArray *unknownRows;
@property(nonatomic) BOOL showUnknownData;
@property(nonatomic,copy) NSString *actionStatus;
@property(nonatomic,strong) NSDate *scanUpdated;
@property(nonatomic) int probeRequestToken;
@property(nonatomic) int probeResponseToken;
@property(nonatomic) uint32_t probeNonce;
@property(nonatomic) BOOL probePending;
@property(nonatomic,strong) NSDate *probeStarted;
@property(nonatomic,copy) NSString *probeStatus;
@end
@implementation CKScanPage
- (instancetype)init { self=[super initWithStyle:UITableViewStyleInsetGrouped];if (self) { _probeRequestToken=-1;_probeResponseToken=-1; }return self; }
- (NSString *)file:(NSString *)name {return [jbroot(@"/var/mobile/Library/CacheKeeper") stringByAppendingPathComponent:name];}
- (NSDictionary *)axs_cachekeeper_display:(NSString *)name {
    if (!self.displayCache) self.displayCache=[NSMutableDictionary new];
    if (!self.displayCache[name]) self.displayCache[name]=[NSDictionary dictionaryWithContentsOfFile:[self file:name]] ?: @{};
    return self.displayCache[name];
}
- (void)axs_cachekeeper_reload {
    [self axs_cachekeeper_check_probe];
    self.displayCache=nil;
    NSDictionary *report=[self axs_cachekeeper_display:[@"Status/" stringByAppendingFormat:@"%@.auto.plist",self.bundle]];
    NSArray *rows=axs_cachekeeper_display_rows(self.rows,report[@"discoveredPaths"]);
    NSDictionary *directories=[self axs_cachekeeper_display:@"directories.plist"];
    NSDictionary *states=[self axs_cachekeeper_display:@"appEnabled.plist"];
    self.cacheRows=axs_cachekeeper_prioritized_rows(rows,directories[self.bundle],states[self.bundle]);
    self.otherRows=axs_cachekeeper_known_readonly_rows(rows);
    self.unknownRows=axs_cachekeeper_unknown_rows(rows);
    self.enableAllButton.enabled=!self.timer && self.cacheRows.count>0;
    [self.tableView reloadData];
}
- (void)viewDidLoad {
    [super viewDidLoad];self.title=self.appName;
    NSDictionary *history=[NSDictionary dictionaryWithContentsOfFile:[self file:@"snapshots.plist"]];
    self.rows=axs_cachekeeper_parent_rows(history[self.bundle][@"rows"]);
    self.previous=@{@"rows":history[self.bundle][@"previousRows"]?:@[]};
    self.scanError=history[self.bundle][@"error"];
    self.scanUpdated=history[self.bundle][@"updated"];
    self.scanButton=[[UIBarButtonItem alloc] initWithTitle:@"检测目录" style:UIBarButtonItemStylePlain target:self action:@selector(scan)];
    self.enableAllButton=[[UIBarButtonItem alloc] initWithTitle:@"一键开启" style:UIBarButtonItemStylePlain target:self action:@selector(axs_cachekeeper_enable_all)];
    self.enableAllButton.accessibilityLabel=@"开启自动模式、网络磁盘缓存限制与新增缓存自动发现";
    self.navigationItem.rightBarButtonItems=@[self.enableAllButton,self.scanButton];
    [self axs_cachekeeper_reload];
}
- (void)scan {
    if (self.timer) return;
    self.actionStatus=nil;
    self.token=NSUUID.UUID.UUIDString;
    NSError *error=nil;
    if (![@{@"bundle":self.bundle,@"token":self.token} writeToURL:[NSURL fileURLWithPath:[self file:@"request.plist"]] error:&error]) {
        [self message:[NSString stringWithFormat:@"无法写入检测请求：%@（%@/%ld）。请检查配置目录是否存在、可写后重试。",error.localizedDescription,error.domain,(long)error.code]];return;
    }
    self.started=NSProcessInfo.processInfo.systemUptime;
    self.scanButton.enabled=NO;
    self.enableAllButton.enabled=NO;
    self.title=@"正在检测…";
    __weak typeof(self) weak=self;
    self.timer=[NSTimer scheduledTimerWithTimeInterval:.5 repeats:YES block:^(NSTimer *timer){[weak check];}];
    [self axs_cachekeeper_reload];
}
- (void)check {
    NSDictionary *result=[NSDictionary dictionaryWithContentsOfFile:[self file:@"scan.plist"]];
    if ([result[@"token"] isEqual:self.token]) {
        [self.timer invalidate];self.timer=nil;self.scanButton.enabled=YES;self.title=self.appName;
        self.rows=axs_cachekeeper_parent_rows(result[@"rows"]);
        self.previous=@{@"rows":result[@"previousRows"]?:@[]};
        self.scanError=result[@"error"];
        self.scanUpdated=result[@"updated"];
        [self axs_cachekeeper_reload];
        if (self.scanError.length) { [self message:self.scanError];return; }
        if (!self.rows.count) [self message:@"没有检测到候选目录。请先打开该应用再返回检测，或检查插件是否已加载。"];return;
    }
    if (NSProcessInfo.processInfo.systemUptime-self.started>25) {
        [self.timer invalidate];self.timer=nil;self.title=self.appName;self.scanButton.enabled=YES;
        [self axs_cachekeeper_reload];
        [self message:@"尚未收到检测结果。可点击“检测目录”仅重试此 APP；巨大目录可点击该目录进入深度检测。持续无响应时再检查桌面进程是否加载插件及配置目录访问。"];
    }
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated]; [self axs_cachekeeper_reload];
    __weak typeof(self) weak=self;
    if (!self.statusTimer) self.statusTimer=[NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *timer){[weak axs_cachekeeper_reload];}];
}
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated]; [self.statusTimer invalidate]; self.statusTimer=nil; }
- (void)dealloc {
    [self.timer invalidate];[self.statusTimer invalidate];
    if (_probeRequestToken>=0) notify_cancel(_probeRequestToken);
    if (_probeResponseToken>=0) notify_cancel(_probeResponseToken);
}
- (void)axs_cachekeeper_begin_probe {
    NSDictionary *states=[NSDictionary dictionaryWithContentsOfFile:[self file:@"appEnabled.plist"]];
    if (!axs_cachekeeper_app_enabled(states[self.bundle])) { self.probePending=NO;self.probeStatus=@"此 APP 未开启，不发送网络诊断请求。";[self axs_cachekeeper_reload];return; }
    if (self.probeRequestToken>=0) notify_cancel(self.probeRequestToken);
    if (self.probeResponseToken>=0) notify_cancel(self.probeResponseToken);
    self.probeRequestToken=-1;self.probeResponseToken=-1;
    int requestToken=-1,responseToken=-1;
    uint32_t error=notify_register_check(axs_cachekeeper_probe_name(self.bundle,NO).UTF8String,&requestToken);
    if (error==NOTIFY_STATUS_OK) error=notify_register_check(axs_cachekeeper_probe_name(self.bundle,YES).UTF8String,&responseToken);
    self.probeRequestToken=requestToken;self.probeResponseToken=responseToken;
    self.probeNonce=arc4random_uniform(UINT32_MAX-1)+1;
    uint64_t request=axs_cachekeeper_probe_request(self.probeNonce,NSDate.date.timeIntervalSince1970);
    if (error==NOTIFY_STATUS_OK) error=notify_set_state(requestToken,request);
    if (error==NOTIFY_STATUS_OK) error=notify_post(axs_cachekeeper_probe_name(self.bundle,NO).UTF8String);
    self.probePending=error==NOTIFY_STATUS_OK;self.probeStarted=NSDate.date;
    self.probeStatus=error ? [NSString stringWithFormat:@"诊断请求发送失败（notify %u）",error] : @"请求已发送。请在 5 分钟内打开此 APP 一次，再返回这里查看；无需先允许共享文件写入。";
    [self axs_cachekeeper_reload];
}
- (void)axs_cachekeeper_check_probe {
    if (!self.probePending) return;
    uint64_t response=0;
    uint32_t error=notify_get_state(self.probeResponseToken,&response);
    if (error!=NOTIFY_STATUS_OK) { self.probeStatus=[NSString stringWithFormat:@"诊断响应读取失败（notify %u）",error];self.probePending=NO;return; }
    if ((uint32_t)(response>>32)==self.probeNonce && (uint32_t)response) {
        self.probePending=NO;self.probeStatus=axs_cachekeeper_probe_description((uint32_t)response);
        NSError *writeError=nil;
        if (![@{@"updated":NSDate.date,@"result":@((uint32_t)response),@"message":self.probeStatus}
            writeToURL:[NSURL fileURLWithPath:[self file:[NSString stringWithFormat:@"Status/%@.probe.plist",self.bundle]]] error:&writeError])
            self.probeStatus=[self.probeStatus stringByAppendingFormat:@"\n诊断记录保存失败：%@",writeError.localizedDescription];
    } else if (-self.probeStarted.timeIntervalSinceNow>300) {
        self.probePending=NO;self.probeStatus=@"5 分钟内未收到 APP 响应。请确认 RootHide 允许此 APP 注入 CacheKeeper，再重新检查；通知通信失败也可能造成无响应，不能单凭这一项断定未注入。";
    } else if (-self.probeStarted.timeIntervalSinceNow>15) self.probeStatus=@"仍未收到 APP 响应。请打开此 APP 一次再返回；持续无响应请核对 RootHide 的应用注入设置。";
}
- (void)message:(NSString *)text {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"目录检测" message:text preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:alert animated:YES completion:nil];
}
- (void)axs_cachekeeper_filza_error:(NSString *)reason path:(NSString *)path {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Filza 目录打开失败" message:reason preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"复制目录路径" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        UIPasteboard.generalPasteboard.string=path;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)axs_cachekeeper_open_filza:(NSString *)path {
    Class proxyClass=NSClassFromString(@"LSApplicationProxy");
    SEL lookup=NSSelectorFromString(@"applicationProxyForIdentifier:");
    id proxy=[proxyClass respondsToSelector:lookup] ? ((id(*)(id,SEL,id))objc_msgSend)(proxyClass,lookup,AxsCacheKeeperFilzaBundleID) : nil;
    SEL bundleSelector=NSSelectorFromString(@"bundleURL");
    NSURL *bundle=[proxy respondsToSelector:bundleSelector] ? ((id(*)(id,SEL))objc_msgSend)(proxy,bundleSelector) : nil;
    NSDictionary *info=[bundle isKindOfClass:NSURL.class] ? [NSDictionary dictionaryWithContentsOfURL:[bundle URLByAppendingPathComponent:@"Info.plist"]] : nil;
    if (!info) {
        [self axs_cachekeeper_filza_error:@"无法读取系统注册的 Filza 信息；可能未安装、注册未刷新或访问受限。可先在桌面打开 Filza，再试一次。" path:path];return;
    }
    NSURL *url=axs_cachekeeper_filza_url(path,info);
    if (!url) { [self axs_cachekeeper_filza_error:@"目录路径无效，未发送打开请求。" path:path];return; }
    __weak typeof(self) weak=self;
    __block BOOL finished=NO;
    void (^complete)(BOOL,NSError *)=^(BOOL success,NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (finished) return;
            finished=YES;
            if (!success) {
                NSString *details=error ? [NSString stringWithFormat:@"%@（%@/%ld）",error.localizedDescription,error.domain,(long)error.code] : @"系统拒绝了目录打开请求";
                [weak axs_cachekeeper_filza_error:[NSString stringWithFormat:@"Filza %@：%@。这不等于 Filza 未安装。",info[@"CFBundleShortVersionString"] ?: @"",details] path:path];
            } else {
                weak.actionStatus=@"已向 Filza 发送目录打开请求";
                [weak axs_cachekeeper_reload];
            }
        });
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,8*NSEC_PER_SEC),dispatch_get_main_queue(), ^{
        complete(NO,[NSError errorWithDomain:@"CacheKeeper.Filza" code:2 userInfo:@{NSLocalizedDescriptionKey:@"系统未及时返回打开结果"}]);
    });
    if (!url.isFileURL) {
        [UIApplication.sharedApplication openURL:url options:@{} completionHandler:^(BOOL success) {complete(success,nil);}];return;
    }
    // Filza 5 官方包没有 URL scheme，使用已存在的应用标识 + 文件投递接口。
    static void *frontBoard;
    static dispatch_once_t once;
    dispatch_once(&once, ^{frontBoard=dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices",RTLD_LAZY|RTLD_LOCAL);});
    CFStringRef const *keyAddress=frontBoard ? (CFStringRef const *)dlsym(frontBoard,"FBSOpenApplicationOptionKeyPayloadURL") : NULL;
    NSString *payloadKey=keyAddress ? (__bridge NSString *)*keyAddress : nil;
    Class workspaceClass=NSClassFromString(@"LSApplicationWorkspace");
    SEL shared=NSSelectorFromString(@"defaultWorkspace");
    id workspace=[workspaceClass respondsToSelector:shared] ? ((id(*)(id,SEL))objc_msgSend)(workspaceClass,shared) : nil;
    id configuration=[NSClassFromString(@"_LSOpenConfiguration") new];
    axs_cachekeeper_send_filza_document(workspace,configuration,payloadKey,url,complete);
}
- (NSArray *)orderedRows {
    return self.cacheRows ?: @[];
}
- (NSDictionary *)axs_cachekeeper_row_at:(NSIndexPath *)path {
    if (path.section==1 && path.row<self.cacheRows.count) return self.cacheRows[path.row];
    if (path.section==2 && self.showUnknownData && path.row>0 && path.row-1<self.unknownRows.count) return self.unknownRows[path.row-1];
    if (path.section==3 && self.showOtherData && path.row>0 && path.row-1<self.otherRows.count) return self.otherRows[path.row-1];
    return nil;
}
- (UIContextMenuConfiguration *)tableView:(UITableView *)table contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)path point:(CGPoint)point {
    NSString *relative=[self axs_cachekeeper_row_at:path][@"path"];
    if (!relative) return nil;
    NSString *displayPath=relative;
    NSDictionary *history=[self axs_cachekeeper_display:@"snapshots.plist"][self.bundle];
    NSString *home=history[@"home"];
    if ([relative hasPrefix:@"Group/"]) {
        NSArray *parts=[relative componentsSeparatedByString:@"/"];
        if (parts.count<3) return nil;
        home=history[@"groups"][parts[1]];
        relative=[[parts subarrayWithRange:NSMakeRange(2,parts.count-2)] componentsJoinedByString:@"/"];
    }
    if (!axs_cachekeeper_relative_path(relative)) return nil;
    if (!home.length) return nil;
    NSString *fullPath=[home stringByAppendingPathComponent:relative];
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray *suggested) {
        UIAction *open = [UIAction actionWithTitle:@"在 Filza 中打开目录" image:[UIImage systemImageNamed:@"folder"] identifier:nil handler:^(UIAction *action) {
            [self axs_cachekeeper_open_filza:fullPath];
        }];
        UIAction *inspect=[UIAction actionWithTitle:@"深度检测／查看档案" image:[UIImage systemImageNamed:@"doc.text.magnifyingglass"] identifier:nil handler:^(UIAction *action) {
            [self.navigationController pushViewController:[[AxsCacheKeeperInspectionPage alloc] initWithBundle:self.bundle path:displayPath] animated:YES];
        }];
        return [UIMenu menuWithTitle:@"" children:@[inspect,open]];
    }];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { return 4; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    if (section==0) return 6;
    if (section==1) return MAX((NSUInteger)1,self.cacheRows.count);
    if (section==2) return self.unknownRows.count ? 1+(self.showUnknownData ? self.unknownRows.count : 0) : 0;
    return self.otherRows.count ? 1+(self.showOtherData ? self.otherRows.count : 0) : 0;
}
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {
    if (section==0) return @"缓存控制";
    if (section==1) {
        return [NSString stringWithFormat:@"可管理缓存 · 已选置顶 · %lu 个父目录\n大小快照：%@（点击检测目录刷新）",(unsigned long)self.cacheRows.count,self.scanUpdated ? axs_cachekeeper_time_string(self.scanUpdated) : @"尚未检测"];
    }
    if (section==2) return self.unknownRows.count ? @"用途未知 · 待分析" : nil;
    return self.otherRows.count ? @"混合用途与共享数据" : nil;
}
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
    if (section==0) return @"一键开启 = 自动模式 + 网络磁盘缓存限制 + 新增缓存自动发现。可能增加流量和重复加载，网络选项可随时关闭。";
    if (section==2) return self.unknownRows.count ? @"点击目录进入只读深度检测：类型组成、文件时间与最大文件。未知不等于必需，也不等于垃圾。退出后先做全目录内容审查：无数据证据的自动清理，检出数据证据的自动仅清理其中的日志文件（数据与未知内容保留），无需手动定级。每目录开关默认开启（自动审查）；关闭则保留该目录，不自动清理。" : nil;
    if (section==3) return self.otherRows.count ? @"这些目录可能同时包含资源、业务状态或缓存，尚未逐项确认；不自动清理。已知敏感持久化目录已隐藏。" : nil;
    NSDictionary *footerStates=[self axs_cachekeeper_display:@"appEnabled.plist"];
    NSString *message=axs_cachekeeper_full_clear(footerStates[self.bundle]) ?
        @"检测目录只更新大小快照，不删除 APP 文件；等待期间显示值不会自行重算。首次使用产生的缓存也处理；仅在 APP 完全退出、文件超过 60 秒并通过预检后处理。全量清理已开启：标准缓存目录内的全部文件都清空（含数据库与未知文件）；未知目录退出后先做全目录内容审查，无数据证据的自动清理，检出数据证据的自动仅清理其中的日志文件。已选目录内新增内容自动覆盖；手动关闭的目录保持排除。点击目录查看实际删除和失败记录。" :
        @"检测目录只更新大小快照，不删除 APP 文件；等待期间显示值不会自行重算。首次使用产生的缓存也处理；仅在 APP 完全退出、文件超过 60 秒并通过预检后删除可识别媒体；未知目录退出后先做全目录内容审查，无数据证据的自动清理，检出数据证据的自动仅清理其中的日志文件。已选目录内新增内容自动覆盖；新增标准缓存根按自动发现选项纳入，手动关闭的目录保持排除。点击目录查看实际删除和失败记录。";
    return self.scanError.length ? [self.scanError stringByAppendingFormat:@"\n%@",message] : message;
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    if (path.section==0 && path.row==0) {
        UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.textLabel.text=@"此 APP 缓存控制";
        NSDictionary *report = [self axs_cachekeeper_display:[@"Status/" stringByAppendingFormat:@"%@.auto.plist",self.bundle]];
        cell.detailTextLabel.numberOfLines = 0;
        cell.detailTextLabel.text = axs_cachekeeper_summary(nil,report);
        NSDictionary *states=[self axs_cachekeeper_display:@"appEnabled.plist"];
        NSDictionary *selected=[self axs_cachekeeper_display:@"directories.plist"];
        UISwitch *toggle=[UISwitch new];
        toggle.on=axs_cachekeeper_app_enabled(states[self.bundle]);
        if (!toggle.on) cell.detailTextLabel.text=@"未开启；打开总开关、单项开启或一键开启后才生效";
        else if (!axs_cachekeeper_selected_paths(selected,states,self.bundle).count && !axs_cachekeeper_auto_discover(states[self.bundle])) cell.detailTextLabel.text=@"总开关已开启；未选择文件清理目录，网络缓存按独立选项执行";
        if (self.actionStatus.length) cell.detailTextLabel.text=[self.actionStatus stringByAppendingFormat:@"\n%@",cell.detailTextLabel.text];
        [toggle addTarget:self action:@selector(master:) forControlEvents:UIControlEventValueChanged];cell.accessoryView=toggle;
        return cell;
    }
    if (path.section==0 && path.row==1) {
        UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        NSDictionary *states=[self axs_cachekeeper_display:@"appEnabled.plist"];
        UILabel *label=[UILabel new];label.text=@"选择一种模式";label.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];label.adjustsFontForContentSizeCategory=YES;
        UISegmentedControl *control=[[UISegmentedControl alloc] initWithItems:@[@"自动",@"只禁止",@"只清理"]];
        NSArray *modes=@[@"auto",@"prevent",@"clean"];
        control.selectedSegmentIndex=[modes indexOfObject:axs_cachekeeper_mode(states[self.bundle])];
        control.accessibilityLabel=@"缓存控制模式，三选一";
        [control addTarget:self action:@selector(axs_cachekeeper_mode_changed:) forControlEvents:UIControlEventValueChanged];
        UILabel *detail=[UILabel new];detail.numberOfLines=0;detail.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];detail.textColor=UIColor.secondaryLabelColor;detail.adjustsFontForContentSizeCategory=YES;
        detail.text=@"自动：网络限制 + 退出后清理\n只禁止：限制网络缓存 + 锁定已选缓存目录写入（可读不可写），不删除已有文件；APP 完全退出后上锁，切换模式或关闭总开关后解锁\n只清理：允许网络缓存，仅退出后清理";
        UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:@[label,control,detail]];
        stack.axis=UILayoutConstraintAxisVertical;stack.spacing=10;stack.translatesAutoresizingMaskIntoConstraints=NO;
        [cell.contentView addSubview:stack];
        UILayoutGuide *margins=cell.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[[stack.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
            [stack.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],[stack.topAnchor constraintEqualToAnchor:margins.topAnchor],
            [stack.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor],[control.heightAnchor constraintGreaterThanOrEqualToConstant:44]]];
        cell.selectionStyle=UITableViewCellSelectionStyleNone;return cell;
    }
    if (path.section==0 && path.row==2) {
        UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.textLabel.text=@"禁止网络磁盘缓存";
        NSDictionary *states=[self axs_cachekeeper_display:@"appEnabled.plist"];
        UISwitch *toggle=[UISwitch new];toggle.on=axs_cachekeeper_url_cache_enabled(states[self.bundle]);
        toggle.enabled=axs_cachekeeper_wants_restriction(states[self.bundle]);
        cell.detailTextLabel.text=toggle.enabled ? @"仅限标准 NSURLCache，可能增加流量；不改变内存缓存" : @"只清理模式不限制网络缓存；选项已保留";
        cell.detailTextLabel.numberOfLines=0;
        [toggle addTarget:self action:@selector(axs_cachekeeper_network_changed:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView=toggle;return cell;
    }
    if (path.section==0 && path.row==3) {
        UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.textLabel.text=@"自动纳入新增缓存目录";
        cell.detailTextLabel.text=@"退出后定期检查标准缓存根；手动关闭的目录不会重开";cell.detailTextLabel.numberOfLines=0;
        NSDictionary *states=[self axs_cachekeeper_display:@"appEnabled.plist"];
        UISwitch *toggle=[UISwitch new];toggle.on=axs_cachekeeper_auto_discover(states[self.bundle]);
        [toggle addTarget:self action:@selector(axs_cachekeeper_discovery_changed:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView=toggle;return cell;
    }
    if (path.section==0 && path.row==4) {
        UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.textLabel.text=@"标准缓存目录全量清理";
        cell.detailTextLabel.text=@"开启后，该 APP 完全退出时清空其 Library/Caches、tmp 等标准缓存目录内的全部文件（含数据库与未知文件），按平台缓存契约处理；草稿、离线下载若存于这些目录会一并删除。仅对已开启的缓存目录生效，其他目录仍按原规则；一键开启不会打开此项。";cell.detailTextLabel.numberOfLines=0;
        NSDictionary *states=[self axs_cachekeeper_display:@"appEnabled.plist"];
        UISwitch *toggle=[UISwitch new];toggle.on=axs_cachekeeper_full_clear(states[self.bundle]);
        [toggle addTarget:self action:@selector(axs_cachekeeper_fullclear_changed:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView=toggle;return cell;
    }
    if (path.section==0 && path.row==5) {
        UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.textLabel.text=@"检查网络限制";cell.textLabel.textColor=UIColor.systemBlueColor;cell.detailTextLabel.numberOfLines=0;
        NSDictionary *previous=[self axs_cachekeeper_display:[NSString stringWithFormat:@"Status/%@.probe.plist",self.bundle]];
        cell.detailTextLabel.text=self.probeStatus ?: (previous[@"message"] ? [NSString stringWithFormat:@"上次诊断（%@）：%@\n点击重新检查",axs_cachekeeper_time_string(previous[@"updated"]),previous[@"message"]] : @"点击后打开此 APP 一次，再返回查看注入、配置读取和网络容量的实际结果");
        cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;return cell;
    }
    if ((path.section==2 || path.section==3) && path.row==0) {
        UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        BOOL unknown=path.section==2,expanded=unknown ? self.showUnknownData : self.showOtherData;
        NSArray *items=unknown ? self.unknownRows : self.otherRows;
        unsigned long long bytes=0;BOOL complete=YES;
        for (NSDictionary *row in items) {bytes+=[row[@"bytes"] unsignedLongLongValue];complete&=[row[@"complete"] boolValue];}
        cell.textLabel.text=[NSString stringWithFormat:@"%@%lu 项%@",expanded ? @"收起 " : @"展开 ",(unsigned long)items.count,unknown ? @"用途未知目录" : @"混合／共享数据"];
        cell.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];cell.textLabel.textColor=UIColor.systemBlueColor;
        cell.detailTextLabel.text=[NSString stringWithFormat:@"已统计 %.2f MB%@ · %@",bytes/1048576.0,complete ? @"" : @"（未统计完整）",unknown ? @"退出后内容审查，无数据证据即自动清理" : @"不自动处理"];cell.detailTextLabel.numberOfLines=0;
        cell.imageView.image=[UIImage systemImageNamed:unknown ? @"questionmark.folder" : @"folder"];
        cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;cell.accessibilityValue=expanded ? @"已展开" : @"已折叠";return cell;
    }
    NSDictionary *row=[self axs_cachekeeper_row_at:path];
    if (!row) {
        UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.textLabel.text=self.timer ? @"正在检测缓存目录…" : @"尚无可管理缓存目录";
        cell.detailTextLabel.text=@"先使用一次目标 APP 并退出，再点“检测目录”；其他业务数据不会自动当成缓存";
        cell.detailTextLabel.numberOfLines=0;cell.selectionStyle=UITableViewCellSelectionStyleNone;return cell;
    }
    NSString *relative=row[@"path"];
    NSDictionary *config=[self axs_cachekeeper_display:@"directories.plist"];
    BOOL enabled=NO, partial=NO;
    NSDictionary *master=[self axs_cachekeeper_display:@"appEnabled.plist"];
    id viewState=master[self.bundle];
    NSArray *available=axs_cachekeeper_enableable_paths(self.cacheRows);
    NSArray *effective=axs_cachekeeper_effective_paths(config[self.bundle],viewState,available);
    enabled=axs_cachekeeper_row_selected(relative,effective);
    for (NSString *selected in effective) if ([selected hasPrefix:[relative stringByAppendingString:@"/"]]) partial=YES;
    long long previous=0;BOOL compared=NO;
    for (NSDictionary *old in self.previous[@"rows"]) if ([old[@"path"] isEqual:relative]) {previous=[old[@"bytes"] longLongValue];compared=YES;break;}
    UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text=[relative isEqual:@"Library/Caches"]?@"Library/Caches · 标准缓存":relative;cell.textLabel.numberOfLines=0;cell.detailTextLabel.numberOfLines=0;
    NSString *growth=compared?[NSString stringWithFormat:@" · 变化 %+.2f MB",([row[@"bytes"] longLongValue]-previous)/1048576.0]:@" · 首次检测";
    BOOL masterOn=axs_cachekeeper_app_enabled(master[self.bundle]);
    BOOL manageable=axs_cachekeeper_row_manageable(row);
    BOOL judged=[axs_cachekeeper_log_paths(viewState) containsObject:relative];
    NSString *state=!manageable?@"仅供分析":(!masterOn?@"APP 未开启：不处理任何目录":(enabled?(axs_cachekeeper_wants_cleanup(master[self.bundle])?(axs_cachekeeper_full_clear_path(master[self.bundle],relative)?@"已纳入；全量清理开启，退出后清空该目录全部文件":@"已纳入；退出后处理通过预检的缓存"):@"只禁止模式：不删除文件，目录写入锁定见顶部状态"):@"未开启／已手动排除"));
    if (partial) state=[state stringByAppendingString:@"（保留旧配置中选定的部分子目录）"];
    if (judged) state=!masterOn ? @"已定级：日志目录；APP 未开启，不处理" :
        (axs_cachekeeper_wants_cleanup(master[self.bundle]) ? @"已定级：日志目录；退出后仅清理日志特征文件，数据与未知内容保留" : @"已定级：日志目录；只禁止模式不删除文件");
    if ([axs_cachekeeper_directory_kind(relative) isEqual:@"unknown"] && !judged) {
        // 未定级未知目录不走“已纳入/未开启”那套文案：它由 B 案内容审查决定，行文须与实际一致。
        BOOL excluded=axs_cachekeeper_row_selected(relative,axs_cachekeeper_exclusions(viewState));
        state=excluded ? @"已保留：不自动清理" : (!masterOn ? @"APP 未开启：不处理任何目录" :
            (axs_cachekeeper_wants_cleanup(master[self.bundle]) ? @"退出后内容审查，无数据证据即自动清理" : @"只禁止模式：不删除、不锁定"));
    }
    NSString *size=row[@"bytes"] ? [NSString stringWithFormat:@"%.2f MB%@%@",[row[@"bytes"] doubleValue]/1048576,growth,[row[@"complete"] boolValue]?@"":@" · 大小未统计完"] : @"自动发现，大小待检测";
    NSDictionary *snapshot=[self axs_cachekeeper_display:@"snapshots.plist"][self.bundle];
    NSString *trend=axs_cachekeeper_growth_evidence(relative,snapshot[@"recentScans"] ?: @[],snapshot);
    cell.detailTextLabel.text=[NSString stringWithFormat:@"%@\n%@\n%@\n%@\n点击查看档案／补测大小",size,axs_cachekeeper_directory_description(relative),state,trend];
    if (manageable) {
        UISwitch *toggle=[UISwitch new];toggle.on=enabled;toggle.enabled=!self.timer;toggle.accessibilityIdentifier=relative;
        [toggle addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];cell.accessoryView=toggle;
    } else if (judged) {
        UISwitch *toggle=[UISwitch new];toggle.on=YES;toggle.enabled=!self.timer;toggle.accessibilityIdentifier=relative;
        [toggle addTarget:self action:@selector(axs_cachekeeper_log_toggle:) forControlEvents:UIControlEventValueChanged];cell.accessoryView=toggle;
    } else if ([axs_cachekeeper_directory_kind(relative) isEqual:@"unknown"]) {
        // 未定级未知目录的逐项保留开关：默认开（参与自动内容审查），关则整目录保留。
        BOOL excluded=axs_cachekeeper_row_selected(relative,axs_cachekeeper_exclusions(viewState));
        UISwitch *toggle=[UISwitch new];toggle.on=!excluded;toggle.enabled=!self.timer;toggle.accessibilityIdentifier=relative;
        [toggle addTarget:self action:@selector(axs_cachekeeper_exclude_toggle:) forControlEvents:UIControlEventValueChanged];cell.accessoryView=toggle;
    }
    return cell;
}
- (void)master:(UISwitch *)toggle {
    self.actionStatus=nil;
    NSMutableDictionary *selected=axs_cachekeeper_edit_configuration([self file:@"directories.plist"]);
    NSMutableDictionary *states=axs_cachekeeper_edit_configuration([self file:@"appEnabled.plist"]);
    if (!selected || !states) { [self message:@"原配置存在但不可读，已停止保存。"]; [self axs_cachekeeper_reload]; return; }
    states[self.bundle]=axs_cachekeeper_app_state(states[self.bundle],toggle.on);
    if (![states writeToFile:[self file:@"appEnabled.plist"] atomically:YES]) [self message:@"总开关保存失败。"];
    else axs_cachekeeper_notify_preferences();
    [self axs_cachekeeper_reload];
}
- (void)save:(NSString *)relative enabled:(BOOL)enabled {
    NSString *error=axs_cachekeeper_update_selection(jbroot(@"/var/mobile/Library/CacheKeeper"),self.bundle,@[relative],enabled);
    if (error) [self message:error]; else axs_cachekeeper_notify_preferences();
    self.actionStatus=error ?: (enabled ? @"已开启该缓存目录并保存" : @"已关闭该目录，自动发现不会重新开启");
    [self axs_cachekeeper_reload];
}
- (void)toggle:(UISwitch *)toggle {
    if (self.timer) { [self axs_cachekeeper_reload];return; }
    [self save:toggle.accessibilityIdentifier enabled:toggle.on];
}
- (void)axs_cachekeeper_enable_all {
    if (self.timer) return;
    NSString *error=axs_cachekeeper_one_click(jbroot(@"/var/mobile/Library/CacheKeeper"),self.bundle,self.cacheRows);
    if (error) [self message:error]; else axs_cachekeeper_notify_preferences();
    self.actionStatus=error ?: [NSString stringWithFormat:@"已保存：%lu 个缓存目录 · 自动模式 · 网络限制开启 · 新缓存自动纳入",(unsigned long)axs_cachekeeper_enableable_paths(self.cacheRows).count];
    [self axs_cachekeeper_reload];
}
- (void)axs_cachekeeper_save_mode:(NSString *)mode {
    NSString *path=[self file:@"appEnabled.plist"];
    NSMutableDictionary *states=axs_cachekeeper_edit_configuration(path);
    if (!states) { [self message:@"原配置存在但不可读，已停止保存。"];return; }
    BOOL enabled=axs_cachekeeper_app_enabled(states[self.bundle]);
    NSMutableDictionary *state=axs_cachekeeper_app_state(states[self.bundle],enabled);
    state[@"mode"]=mode;states[self.bundle]=state;
    if (![mode isEqual:@"clean"]) state[@"urlCache"]=@YES;
    if (![states writeToFile:path atomically:YES]) [self message:@"模式保存失败。"];
    else axs_cachekeeper_notify_preferences();
    self.actionStatus=nil;
    [self axs_cachekeeper_reload];
}
- (void)axs_cachekeeper_network_changed:(UISwitch *)toggle {
    NSString *path=[self file:@"appEnabled.plist"];
    NSMutableDictionary *states=axs_cachekeeper_edit_configuration(path);
    if (!states) { [self message:@"原配置不可读，停止保存。"];[self axs_cachekeeper_reload];return; }
    NSMutableDictionary *state=axs_cachekeeper_app_state(states[self.bundle],axs_cachekeeper_app_enabled(states[self.bundle]));
    state[@"urlCache"]=@(toggle.on);states[self.bundle]=state;
    if (![states writeToFile:path atomically:YES]) [self message:@"网络选项保存失败。"];
    else axs_cachekeeper_notify_preferences();
    self.actionStatus=nil;
    [self axs_cachekeeper_reload];
}
- (void)axs_cachekeeper_mode_changed:(UISegmentedControl *)control {
    NSArray *modes=@[@"auto",@"prevent",@"clean"];
    if (control.selectedSegmentIndex<0 || control.selectedSegmentIndex>=modes.count) return;
    [self axs_cachekeeper_save_mode:modes[control.selectedSegmentIndex]];
}
- (void)axs_cachekeeper_discovery_changed:(UISwitch *)toggle {
    NSString *path=[self file:@"appEnabled.plist"];
    NSMutableDictionary *states=axs_cachekeeper_edit_configuration(path);
    if (!states) { [self message:@"原配置不可读，停止保存。"];[self axs_cachekeeper_reload];return; }
    NSMutableDictionary *state=axs_cachekeeper_app_state(states[self.bundle],axs_cachekeeper_app_enabled(states[self.bundle]));
    state[@"autoDiscover"]=@(toggle.on);states[self.bundle]=state;
    if (![states writeToFile:path atomically:YES]) [self message:@"自动发现设置保存失败。"];
    else axs_cachekeeper_notify_preferences();
    self.actionStatus=nil;[self axs_cachekeeper_reload];
}
- (void)axs_cachekeeper_fullclear_changed:(UISwitch *)toggle {
    NSString *path=[self file:@"appEnabled.plist"];
    NSMutableDictionary *states=axs_cachekeeper_edit_configuration(path);
    if (!states) { [self message:@"原配置不可读，停止保存。"];[self axs_cachekeeper_reload];return; }
    NSMutableDictionary *state=axs_cachekeeper_app_state(states[self.bundle],axs_cachekeeper_app_enabled(states[self.bundle]));
    state[@"fullClear"]=@(toggle.on);states[self.bundle]=state;
    if (![states writeToFile:path atomically:YES]) [self message:@"全量清理设置保存失败。"];
    else axs_cachekeeper_notify_preferences();
    self.actionStatus=toggle.on ? @"已开启标准缓存目录全量清理；该 APP 完全退出后生效" : @"已关闭全量清理；恢复为仅清理可识别媒体";
    [self axs_cachekeeper_reload];
}
- (void)axs_cachekeeper_log_toggle:(UISwitch *)toggle {
    if (self.timer) { [self axs_cachekeeper_reload];return; }
    NSString *error=axs_cachekeeper_set_log_path(jbroot(@"/var/mobile/Library/CacheKeeper"),self.bundle,toggle.accessibilityIdentifier,toggle.on);
    if (error) [self message:error]; else axs_cachekeeper_notify_preferences();
    self.actionStatus=error ?: (toggle.on ? @"已定级为日志目录；完全退出后按日志规则清理" : @"已取消日志目录定级；恢复为用途未知，按内容审查处理");
    [self axs_cachekeeper_reload];
}
- (void)axs_cachekeeper_exclude_toggle:(UISwitch *)toggle {
    if (self.timer) { [self axs_cachekeeper_reload];return; }
    NSString *error=axs_cachekeeper_set_excluded_path(jbroot(@"/var/mobile/Library/CacheKeeper"),self.bundle,toggle.accessibilityIdentifier,!toggle.on);
    if (error) [self message:error]; else axs_cachekeeper_notify_preferences();
    self.actionStatus=error ?: (toggle.on ? @"已恢复该目录的自动内容审查" : @"已保留该目录，不自动清理");
    [self axs_cachekeeper_reload];
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    if (path.section==0 && path.row==5) { [self axs_cachekeeper_begin_probe];return; }
    NSDictionary *row=[self axs_cachekeeper_row_at:path];
    if (row) { [self.navigationController pushViewController:[[AxsCacheKeeperInspectionPage alloc] initWithBundle:self.bundle path:row[@"path"]] animated:YES];return; }
    if (path.section==2 && path.row==0) { self.showUnknownData=!self.showUnknownData;[self axs_cachekeeper_reload]; }
    if (path.section==3 && path.row==0) {
        self.showOtherData=!self.showOtherData;
        [self axs_cachekeeper_reload];
    }
}
@end
