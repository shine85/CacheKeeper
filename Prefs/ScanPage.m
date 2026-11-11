#import <UIKit/UIKit.h>
#include <roothide.h>
#include <sys/stat.h>
#import "../AxsCacheKeeperPolicy.h"
#import "../AxsCacheKeeperSelection.h"

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
@property(nonatomic) BOOL viewOnlyExpanded;
@property(nonatomic,strong) NSMutableDictionary *displayCache;
@property(nonatomic,strong) UIBarButtonItem *scanButton;
@property(nonatomic,strong) UIBarButtonItem *enableAllButton;
@end
@implementation CKScanPage
- (instancetype)init {return [super initWithStyle:UITableViewStyleInsetGrouped];}
- (NSString *)file:(NSString *)name {return [jbroot(@"/var/mobile/Library/CacheKeeper") stringByAppendingPathComponent:name];}
- (NSDictionary *)axs_cachekeeper_display:(NSString *)name {
    if (!self.displayCache) self.displayCache=[NSMutableDictionary new];
    if (!self.displayCache[name]) self.displayCache[name]=[NSDictionary dictionaryWithContentsOfFile:[self file:name]] ?: @{};
    return self.displayCache[name];
}
- (void)axs_cachekeeper_reload {
    self.displayCache=nil;
    self.enableAllButton.enabled=!self.timer && axs_cachekeeper_enableable_paths(self.rows).count>0;
    [self.tableView reloadData];
}
- (void)viewDidLoad {
    [super viewDidLoad];self.title=self.appName;
    NSDictionary *history=[NSDictionary dictionaryWithContentsOfFile:[self file:@"snapshots.plist"]];
    self.rows=axs_cachekeeper_parent_rows(history[self.bundle][@"rows"]);
    self.previous=@{@"rows":history[self.bundle][@"previousRows"]?:@[]};
    self.scanError=history[self.bundle][@"error"];
    self.scanButton=[[UIBarButtonItem alloc] initWithTitle:@"检测目录" style:UIBarButtonItemStylePlain target:self action:@selector(scan)];
    self.enableAllButton=[[UIBarButtonItem alloc] initWithTitle:@"一键开启" style:UIBarButtonItemStylePlain target:self action:@selector(axs_cachekeeper_enable_all)];
    self.enableAllButton.accessibilityLabel=@"开启此 APP 检测到的全部可管理缓存目录";
    self.navigationItem.rightBarButtonItems=@[self.enableAllButton,self.scanButton];
    [self axs_cachekeeper_reload];
}
- (void)scan {
    if (self.timer) return;
    self.token=NSUUID.UUID.UUIDString;
    if (![@{@"bundle":self.bundle,@"token":self.token} writeToFile:[self file:@"request.plist"] atomically:YES]) { [self message:@"无法提交检测，请重新安装插件。"];return; }
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
        [self axs_cachekeeper_reload];
        if (self.scanError.length) { [self message:self.scanError];return; }
        if (!self.rows.count) [self message:@"没有检测到候选目录。请先打开该应用再返回检测，或检查插件是否已加载。"];return;
    }
    if (NSProcessInfo.processInfo.systemUptime-self.started>25) {
        [self.timer invalidate];self.timer=nil;self.title=self.appName;self.scanButton.enabled=YES;
        [self axs_cachekeeper_reload];
        [self message:@"检测超时，请注销桌面后重试。"];
    }
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated]; [self axs_cachekeeper_reload];
    __weak typeof(self) weak=self;
    if (!self.statusTimer) self.statusTimer=[NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *timer){[weak axs_cachekeeper_reload];}];
}
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated]; [self.statusTimer invalidate]; self.statusTimer=nil; }
- (void)dealloc {[self.timer invalidate];[self.statusTimer invalidate];}
- (void)message:(NSString *)text {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"目录检测" message:text preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:alert animated:YES completion:nil];
}
- (NSArray *)orderedRows {
    NSArray *rows = axs_cachekeeper_size_ordered_rows(self.rows);
    NSDictionary *config = [self axs_cachekeeper_display:@"directories.plist"];
    NSArray *selected = axs_cachekeeper_selectable_paths(config[self.bundle], [self tiers]);
    if (!selected.count) return rows;
    NSMutableArray *enabledRows = [NSMutableArray new];
    NSMutableArray *otherRows = [NSMutableArray new];
    for (NSDictionary *row in rows) {
        BOOL on = NO;
        for (NSString *path in selected) {
            if ([path isEqual:row[@"path"]] || [path hasPrefix:[row[@"path"] stringByAppendingString:@"/"]]) { on = YES; break; }
        }
        [(on ? enabledRows : otherRows) addObject:row];
    }
    return [enabledRows arrayByAddingObjectsFromArray:otherRows];
}
- (UIContextMenuConfiguration *)tableView:(UITableView *)table contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)path point:(CGPoint)point {
    BOOL summary = NO;
    NSDictionary *directoryRow = [self directoryRowAtIndexPath:path summary:&summary];
    if (!directoryRow) return nil;
    NSString *relative = directoryRow[@"path"];
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
    NSURLComponents *url = [NSURLComponents new];
    url.scheme = @"filza";
    url.host = @"";
    url.path = [home stringByAppendingPathComponent:relative];
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray *suggested) {
        UIAction *open = [UIAction actionWithTitle:@"在 Filza 中打开目录" image:[UIImage systemImageNamed:@"folder"] identifier:nil handler:^(UIAction *action) {
            [UIApplication.sharedApplication openURL:url.URL options:@{} completionHandler:^(BOOL success) {
                if (!success) [self message:@"无法打开 Filza，请确认已安装。"];
            }];
        }];
        return [UIMenu menuWithTitle:@"" children:@[open]];
    }];
}
- (NSDictionary *)tiers { return axs_cachekeeper_tiers_by_path(self.rows); }
- (NSArray *)manageableRows {
    NSDictionary *tiers = [self tiers];
    NSMutableArray *result = [NSMutableArray new];
    for (NSDictionary *row in [self orderedRows]) if (axs_cachekeeper_selectable_path(row[@"path"], tiers)) [result addObject:row];
    return result;
}
- (NSArray *)viewOnlyRows {
    NSDictionary *tiers = [self tiers];
    NSMutableArray *result = [NSMutableArray new];
    for (NSDictionary *row in [self orderedRows]) if (!axs_cachekeeper_selectable_path(row[@"path"], tiers)) [result addObject:row];
    return result;
}
- (NSInteger)summaryRowIndex {
    return [self viewOnlyRows].count ? 3 + (NSInteger)[self manageableRows].count : -1;
}
- (NSDictionary *)directoryRowAtIndexPath:(NSIndexPath *)path summary:(BOOL *)summary {
    if (summary) *summary = NO;
    NSInteger index = path.row - 3;
    if (index < 0) return nil;
    NSArray *manageable = [self manageableRows];
    if (index < (NSInteger)manageable.count) return manageable[index];
    NSArray *viewOnly = [self viewOnlyRows];
    if (!viewOnly.count) return nil;
    if (index == (NSInteger)manageable.count) { if (summary) *summary = YES; return nil; }
    if (!self.viewOnlyExpanded) return nil;
    NSInteger viewIndex = index - (NSInteger)manageable.count - 1;
    return viewIndex < (NSInteger)viewOnly.count ? viewOnly[viewIndex] : nil;
}
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    NSInteger count = 3 + [self manageableRows].count;
    NSArray *viewOnly = [self viewOnlyRows];
    if (viewOnly.count) count += 1 + (self.viewOnlyExpanded ? (NSInteger)viewOnly.count : 0);
    return count;
}
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
    NSString *message=@"检测后可一键开启全部可管理目录，也可逐项开启，均直接打开此 APP 总开关，无需再次确认。仅查看目录与 Group/ 共享容器不纳入；模式和网络选项保持原选择。首次运行已有缓存也检查，不按开启时间保留；仅在 APP 完全退出且文件超过 60 秒后清理通过数据预检的媒体。已选父目录内新增文件/子目录自动覆盖，新顶级目录需重新检测选择。未知目录经内容抽检全量为媒体、无数据标记的，定为缓存特征，可逐项开启（不纳入一键开启）。";
    return self.scanError.length ? [self.scanError stringByAppendingFormat:@"\n%@",message] : message;
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    if (path.row==0) {
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
        else if (!axs_cachekeeper_selected_paths_tiered(selected,states,[self tiers],self.bundle).count) cell.detailTextLabel.text=@"总开关已开启；未选择文件清理目录，网络缓存按独立选项执行";
        [toggle addTarget:self action:@selector(master:) forControlEvents:UIControlEventValueChanged];cell.accessoryView=toggle;
        return cell;
    }
    if (path.row==1) {
        UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.textLabel.text=@"缓存控制模式";
        cell.detailTextLabel.text=@"自动：按独立开关限制网络缓存，并在退出后清理";
        cell.detailTextLabel.numberOfLines=0;
        NSDictionary *states=[self axs_cachekeeper_display:@"appEnabled.plist"];
        NSDictionary *names=@{@"auto":@"自动",@"prevent":@"只禁止",@"clean":@"只清理"};
        UILabel *label=[UILabel new];label.text=names[axs_cachekeeper_mode(states[self.bundle])];[label sizeToFit];
        cell.accessoryView=label;cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;return cell;
    }
    if (path.row==2) {
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
    BOOL summary = NO;
    NSDictionary *row = [self directoryRowAtIndexPath:path summary:&summary];
    if (summary) {
        NSArray *viewOnly = [self viewOnlyRows];
        NSDictionary *tiers = [self tiers];
        unsigned long long bytes = 0;
        NSDictionary *largest = nil;
        NSUInteger dataCount = 0, unknownCount = 0, sharedCount = 0;
        for (NSDictionary *item in viewOnly) {
            bytes += [item[@"bytes"] unsignedLongLongValue];
            if (!largest || [item[@"bytes"] unsignedLongLongValue] > [largest[@"bytes"] unsignedLongLongValue]) largest = item;
            NSString *tier = tiers[item[@"path"]];
            if ([tier isEqual:@"data"]) dataCount++;
            else if ([tier isEqual:@"shared"]) sharedCount++;
            else unknownCount++;
        }
        NSMutableArray *parts = [NSMutableArray new];
        if (dataCount) [parts addObject:[NSString stringWithFormat:@"数据 %lu", (unsigned long)dataCount]];
        if (unknownCount) [parts addObject:[NSString stringWithFormat:@"未确认 %lu", (unsigned long)unknownCount]];
        if (sharedCount) [parts addObject:[NSString stringWithFormat:@"共享 %lu", (unsigned long)sharedCount]];
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.textLabel.text = @"仅查看目录（不锁不删）";
        cell.textLabel.font = [UIFont boldSystemFontOfSize:cell.textLabel.font.pointSize];
        cell.detailTextLabel.numberOfLines = 0;
        cell.detailTextLabel.text = [NSString stringWithFormat:@"共 %lu 个 · 合计 %.2f MB%@\n构成：%@；插件不处理，点击%@",
            (unsigned long)viewOnly.count, bytes / 1048576.0,
            largest ? [NSString stringWithFormat:@" · 最大：%@ %.2f MB", largest[@"path"], [largest[@"bytes"] doubleValue] / 1048576.0] : @"",
            [parts componentsJoinedByString:@" · "], self.viewOnlyExpanded ? @"收起" : @"展开"];
        return cell;
    }
    if (!row) return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    NSString *relative = row[@"path"];
    NSDictionary *config=[self axs_cachekeeper_display:@"directories.plist"];
    BOOL enabled=NO, partial=NO;
    for (NSString *selected in axs_cachekeeper_selectable_paths(config[self.bundle], [self tiers])) {
        if ([selected isEqual:relative]) enabled=YES;
        else if ([selected hasPrefix:[relative stringByAppendingString:@"/"]]) { enabled=YES;partial=YES; }
    }
    long long previous=0;BOOL compared=NO;
    for (NSDictionary *old in self.previous[@"rows"]) if ([old[@"path"] isEqual:relative]) {previous=[old[@"bytes"] longLongValue];compared=YES;break;}
    UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text=[relative isEqual:@"Library/Caches"]?@"Library/Caches · 标准缓存":relative;cell.textLabel.numberOfLines=0;cell.detailTextLabel.numberOfLines=0;
    NSString *growth=compared?[NSString stringWithFormat:@" · 变化 %+.2f MB",([row[@"bytes"] longLongValue]-previous)/1048576.0]:@" · 首次检测";
    NSDictionary *master=[self axs_cachekeeper_display:@"appEnabled.plist"];
    BOOL masterOn=axs_cachekeeper_app_enabled(master[self.bundle]);
    BOOL manageable=axs_cachekeeper_selectable_path(relative, [self tiers]);
    NSString *tier=[self tiers][relative];
    NSString *viewOnlyState = [tier isEqual:@"shared"] ? @"共享数据：仅查看，不锁不删" :
        ([tier isEqual:@"data"] ? ((axs_cachekeeper_known_data_path(relative) || axs_cachekeeper_protected_path(relative)) ? @"应用数据：仅查看，不锁不删" : @"检出数据文件：仅查看，不锁不删") : @"用途未确认：仅查看，不锁不删");
    NSString *detail = axs_cachekeeper_directory_description(relative);
    if (!axs_cachekeeper_cache_path(relative) && [row[@"evidence"] isKindOfClass:NSDictionary.class])
        detail = axs_cachekeeper_evidence_summary(relative, row[@"evidence"]);
    NSString *state=!manageable?viewOnlyState:(enabled?(!masterOn?@"已选中，等待打开 APP 总开关":(axs_cachekeeper_wants_cleanup(master[self.bundle])?@"已选中；退出后仅清理超过 60 秒的普通缓存":@"只禁止模式：不删除目录内文件")):@"未选中");
    if (partial) state=[state stringByAppendingString:@"（保留旧配置中选定的部分子目录）"];
    cell.detailTextLabel.text=[NSString stringWithFormat:@"%.2f MB%@%@\n%@\n%@\n%@",[row[@"bytes"] doubleValue]/1048576,growth,[row[@"complete"] boolValue]?@"":@" · 大小未统计完",
        detail,manageable?@"可选择清理（受文件保护规则约束）":@"仅查看（不锁不删）",state];
    UISwitch *toggle=[UISwitch new];toggle.on=enabled && manageable;toggle.enabled=manageable && !self.timer;toggle.accessibilityIdentifier=relative;
    [toggle addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];cell.accessoryView=toggle;
    return cell;
}
- (void)master:(UISwitch *)toggle {
    NSMutableDictionary *selected=axs_cachekeeper_edit_configuration([self file:@"directories.plist"]);
    NSMutableDictionary *states=axs_cachekeeper_edit_configuration([self file:@"appEnabled.plist"]);
    if (!selected || !states) { [self message:@"原配置存在但不可读，已停止保存。"]; [self axs_cachekeeper_reload]; return; }
    if (toggle.on && !selected[self.bundle]) {
        selected[self.bundle]=axs_cachekeeper_activation_paths(nil);
        if (![selected writeToFile:[self file:@"directories.plist"] atomically:YES]) { toggle.on=NO; [self message:@"目录选择保存失败。"];return; }
    }
    states[self.bundle]=axs_cachekeeper_app_state(states[self.bundle],toggle.on);
    if (![states writeToFile:[self file:@"appEnabled.plist"] atomically:YES]) [self message:@"总开关保存失败。"];
    else axs_cachekeeper_notify_preferences();
    [self axs_cachekeeper_reload];
}
- (void)save:(NSString *)relative enabled:(BOOL)enabled {
    NSString *error=axs_cachekeeper_update_selection(jbroot(@"/var/mobile/Library/CacheKeeper"),self.bundle,@[relative],enabled);
    if (error) [self message:error]; else axs_cachekeeper_notify_preferences();
    [self axs_cachekeeper_reload];
}
- (void)toggle:(UISwitch *)toggle {
    if (self.timer) { [self axs_cachekeeper_reload];return; }
    [self save:toggle.accessibilityIdentifier enabled:toggle.on];
}
- (void)axs_cachekeeper_enable_all {
    if (self.timer) return;
    NSArray *paths=axs_cachekeeper_enableable_paths(self.rows);
    NSString *error=axs_cachekeeper_update_selection(jbroot(@"/var/mobile/Library/CacheKeeper"),self.bundle,paths,YES);
    if (error) [self message:error]; else axs_cachekeeper_notify_preferences();
    [self axs_cachekeeper_reload];
}
- (void)axs_cachekeeper_save_mode:(NSString *)mode {
    NSString *path=[self file:@"appEnabled.plist"];
    NSMutableDictionary *states=axs_cachekeeper_edit_configuration(path);
    if (!states) { [self message:@"原配置存在但不可读，已停止保存。"];return; }
    BOOL enabled=axs_cachekeeper_app_enabled(states[self.bundle]);
    NSMutableDictionary *state=axs_cachekeeper_app_state(states[self.bundle],enabled);
    state[@"mode"]=mode;states[self.bundle]=state;
    if (![states writeToFile:path atomically:YES]) [self message:@"模式保存失败。"];
    else axs_cachekeeper_notify_preferences();
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
    [self axs_cachekeeper_reload];
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    if (path.row == [self summaryRowIndex]) { self.viewOnlyExpanded = !self.viewOnlyExpanded; [self axs_cachekeeper_reload]; return; }
    if (path.row!=1) return;
    UIAlertController *choice=[UIAlertController alertControllerWithTitle:@"缓存控制模式" message:@"禁止只作用于标准 NSURLCache，可能增加流量并影响离线访问；自建视频或图片缓存仍需退出后清理。" preferredStyle:UIAlertControllerStyleAlert];
    NSDictionary *names=@{@"auto":@"自动：禁止 + 清理",@"prevent":@"只禁止：不删文件",@"clean":@"只清理：允许网络缓存"};
    for (NSString *mode in @[@"auto",@"prevent",@"clean"]) {
        [choice addAction:[UIAlertAction actionWithTitle:names[mode] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[self axs_cachekeeper_save_mode:mode];}]];
    }
    [choice addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:choice animated:YES completion:nil];
}
@end
