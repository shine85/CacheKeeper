#import <UIKit/UIKit.h>
#include <roothide.h>
#include <sys/stat.h>

@interface CKScanPage : UITableViewController
@property(nonatomic,copy) NSString *bundle;
@property(nonatomic,copy) NSString *appName;
@property(nonatomic,strong) NSArray *rows;
@property(nonatomic,strong) NSDictionary *previous;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic,copy) NSString *token;
@property(nonatomic,strong) NSMutableDictionary *fileCache;
@property(nonatomic) NSTimeInterval started;
@end
@implementation CKScanPage
- (instancetype)init {return [super initWithStyle:UITableViewStyleInsetGrouped];}
- (NSString *)file:(NSString *)name {return [jbroot(@"/var/mobile/Library/CacheKeeper") stringByAppendingPathComponent:name];}
// 0.3.8 优化：cellForRow 原来每行重读 directories/appEnabled/permissions/snapshots 四份 plist，
// 改为按刷新周期缓存；写配置或检测完成后置空缓存，数据时效不变
- (NSDictionary *)cached:(NSString *)name {
    if (!self.fileCache) self.fileCache = [NSMutableDictionary new];
    NSDictionary *value = self.fileCache[name];
    if (!value) { value = [NSDictionary dictionaryWithContentsOfFile:[self file:name]] ?: @{}; self.fileCache[name] = value; }
    return value;
}
- (void)viewDidLoad {
    [super viewDidLoad];self.title=self.appName;
    NSDictionary *history=[self cached:@"snapshots.plist"];
    self.rows=[self collapseRows:history[self.bundle][@"rows"]?:@[]];
    self.previous=@{@"rows":history[self.bundle][@"previousRows"]?:@[]};
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"检测目录" style:UIBarButtonItemStylePlain target:self action:@selector(scan)];
}
- (void)scan {
    if (self.timer) return;
    self.token=NSUUID.UUID.UUIDString;
    if (![@{@"bundle":self.bundle,@"token":self.token} writeToFile:[self file:@"request.plist"] atomically:YES]) { [self message:@"无法提交检测，请重新安装插件。"];return; }
    self.started=NSProcessInfo.processInfo.systemUptime;
    self.navigationItem.rightBarButtonItem.enabled=NO;
    self.title=@"正在检测…";
    __weak typeof(self) weak=self;
    self.timer=[NSTimer scheduledTimerWithTimeInterval:.5 repeats:YES block:^(NSTimer *timer){[weak check];}];
}
- (void)check {
    NSDictionary *result=[NSDictionary dictionaryWithContentsOfFile:[self file:@"scan.plist"]];
    if ([result[@"token"] isEqual:self.token]) {
        [self.timer invalidate];self.timer=nil;self.navigationItem.rightBarButtonItem.enabled=YES;self.title=self.appName;
        self.rows=[self collapseRows:result[@"rows"]?:@[]];
        self.previous=@{@"rows":result[@"previousRows"]?:@[]};
        self.fileCache=nil;
        [self.tableView reloadData];
        if (!self.rows.count) [self message:@"没有检测到候选目录。请先打开该应用再返回检测，或检查插件是否已加载。"];return;
    }
    if (NSProcessInfo.processInfo.systemUptime-self.started>25) {
        [self.timer invalidate];self.timer=nil;self.title=self.appName;self.navigationItem.rightBarButtonItem.enabled=YES;
        [self message:@"检测超时，请注销桌面后重试。"]; 
    }
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; self.fileCache=nil; [self.tableView reloadData]; }
- (void)dealloc {[self.timer invalidate];}
- (void)message:(NSString *)text {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"目录检测" message:text preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:alert animated:YES completion:nil];
}
- (NSArray *)orderedRows {
    NSArray *selected = [self cached:@"directories.plist"][self.bundle];
    NSMutableArray *enabled = [NSMutableArray new], *other = [NSMutableArray new];
    for (NSDictionary *row in self.rows) [([selected containsObject:row[@"path"]] ? enabled : other) addObject:row];
    return [enabled arrayByAddingObjectsFromArray:other];
}
- (UIContextMenuConfiguration *)tableView:(UITableView *)table contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)path point:(CGPoint)point {
    if (path.section != 0 || path.row == 0) return nil;
    NSString *relative = [self orderedRows][path.row-1][@"path"];
    NSArray *selected = [self cached:@"directories.plist"][self.bundle];
    if (![selected containsObject:relative]) return nil;
    NSString *full = [self fullPath:relative];
    if (!full.length) return nil;
    NSURLComponents *url = [NSURLComponents new];
    url.scheme = @"filza";
    url.host = @"";
    url.path = full;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray *suggested) {
        UIAction *open = [UIAction actionWithTitle:@"在 Filza 中打开目录" image:[UIImage systemImageNamed:@"folder"] identifier:nil handler:^(UIAction *action) {
            [UIApplication.sharedApplication openURL:url.URL options:@{} completionHandler:^(BOOL success) {
                if (!success) [self message:@"无法打开 Filza，请确认已安装。"];
            }];
        }];
        return [UIMenu menuWithTitle:@"" children:@[open]];
    }];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table {return 2;}
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? self.rows.count + 1 : 3;
}
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {
    return section == 1 ? @"清理策略" : nil;
}
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
    if (section == 1) return @"候选中的 Group/ 开头条目是 App Group 共享容器（主 App 与小组件/扩展共用），规则相同。自动：先限制写入；限制未生效、限权后仍有新文件生成、或应用反复秒退时，自动降级为只清理（原因显示在上方状态行）。只禁止：只限制写入，不自动降级。只清理：不限制写入，仅在 App 退后台/退出后清理基线后新建的缓存文件。目录只按根目录管理（父目录优先，子条目忽略）；60 秒内新建的文件不动；数据库、登录数据、Documents、Preferences、WebKit、Cookies 永不限制、永不删除。重新打开目录开关或切换策略会清除降级记录、重新尝试。";
    return @"检测会为尚未配置的 App 自动预选 Library/Caches，总开关保持关闭；打开 App 总开关才会应用。候选只列根目录：Library/Caches、tmp、Library/HTTPStorages（可选，内部可能混有 cookies 类文件），以及 Application Support 的一级子目录（可能存放重要资源，谨慎开启）。已有文件不会自动删除；清理只发生在 App 退后台或退出后。开关约 2 秒内应用，首次安装需注销。";
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    if (path.section == 1) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.detailTextLabel.numberOfLines = 0;
        if (path.row == 0) {
            cell.textLabel.text = @"限制策略";
            cell.detailTextLabel.text = @"自动（推荐）／只禁止写入／只事后清理";
            UISegmentedControl *control = [[UISegmentedControl alloc] initWithItems:@[@"自动", @"只禁止", @"只清理"]];
            NSArray *modes = @[@"auto", @"lock", @"clean"];
            control.selectedSegmentIndex = [modes indexOfObject:[self mode]];
            [control addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = control;
        } else if (path.row == 1) {
            cell.textLabel.text = @"禁止网络缓存生成";
            cell.detailTextLabel.text = @"系统网络缓存不落盘（硬手段）；不影响登录，重复内容需重新下载，下次启动 App 生效";
            UISwitch *toggle = [UISwitch new];
            toggle.on = [[self policyEntry][@"urlCache"] boolValue];
            [toggle addTarget:self action:@selector(urlCacheChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
        } else {
            cell.textLabel.text = @"当前生效状态";
            NSDictionary *snapshot = [self cached:@"snapshots.plist"][self.bundle];
            NSMutableArray *homes = [NSMutableArray new];
            if ([snapshot[@"home"] length]) [homes addObject:snapshot[@"home"]];
            for (NSString *gid in snapshot[@"groups"]) [homes addObject:snapshot[@"groups"][gid]];
            NSDictionary *fallback = [self cached:@"fallback.plist"];
            NSMutableArray *notes = [NSMutableArray new];
            for (NSString *key in fallback) {
                NSDictionary *entry = fallback[key];
                if (!entry[@"reason"]) continue;
                for (NSString *h in homes)
                    if ([key hasPrefix:[h stringByAppendingString:@"/"]]) {
                        [notes addObject:[NSString stringWithFormat:@"%@：%@", [key substringFromIndex:h.length + 1], entry[@"reason"]]];
                        break;
                    }
            }
            NSString *mode = [self mode];
            NSString *modeText = [mode isEqual:@"lock"] ? @"只禁止写入" : [mode isEqual:@"clean"] ? @"只事后清理" : @"自动（优先禁止写入）";
            cell.detailTextLabel.text = notes.count ? [notes componentsJoinedByString:@"\n"] : [NSString stringWithFormat:@"策略：%@ · 未发生自动降级", modeText];
        }
        return cell;
    }
    if (path.row==0) {
        UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.textLabel.text=@"此 App 限制写入总开关";
        NSDictionary *report = [NSDictionary dictionaryWithContentsOfFile:[[self file:@"Status"] stringByAppendingPathComponent:[self.bundle stringByAppendingString:@".auto.plist"]]];
        cell.detailTextLabel.numberOfLines = 0;
        cell.detailTextLabel.text = report
            ? [NSString stringWithFormat:@"自动清理累计 %@ 个文件 · %.2f MB\n最近检查 %@",report[@"removed"],[report[@"bytes"] doubleValue]/1048576,report[@"updated"]]
            : @"等待自动清理记录，目录大小以检测时间为准";
        NSDictionary *states=[self cached:@"appEnabled.plist"];
        NSDictionary *selected=[self cached:@"directories.plist"];
        UISwitch *toggle=[UISwitch new];
        // 0.4.6：总开关就是用户的人选结果——没亲手开过的就是关
        toggle.on=[states[self.bundle] boolValue];
        [toggle addTarget:self action:@selector(master:) forControlEvents:UIControlEventValueChanged];cell.accessoryView=toggle;
        return cell;
    }
    NSDictionary *row=[self orderedRows][path.row-1];NSString *relative=row[@"path"];
    NSDictionary *config=[self cached:@"directories.plist"];
    BOOL enabled=[config[self.bundle] containsObject:relative];
    long long previous=0;BOOL compared=NO;
    for (NSDictionary *old in self.previous[@"rows"]) if ([old[@"path"] isEqual:relative]) {previous=[old[@"bytes"] longLongValue];compared=YES;break;}
    UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text=[relative isEqual:@"Library/Caches"]?@"Library/Caches · 自动预选":relative;cell.textLabel.numberOfLines=0;cell.detailTextLabel.numberOfLines=0;
    NSString *growth=compared?[NSString stringWithFormat:@" · 变化 %+.2f MB",([row[@"bytes"] longLongValue]-previous)/1048576.0]:@" · 首次检测";
    NSDictionary *records=[self cached:@"permissions.plist"];
    NSString *full=[self fullPath:relative];
    struct stat info;BOOL blocked=full && !lstat(full.fileSystemRepresentation,&info) && !(info.st_mode&S_IWUSR);
    NSDictionary *master=[self cached:@"appEnabled.plist"];
    BOOL masterOn=!master[self.bundle] || [master[self.bundle] boolValue];
    NSString *state=enabled?(!masterOn?@"已选中，等待打开 App 总开关":(blocked && records[full]?@"已限制写入":@"等待基线或权限应用，请打开 App 完成加载再返回桌面")):@"未选中";
    cell.detailTextLabel.text=[NSString stringWithFormat:@"%.2f MB%@%@\n%@",[row[@"bytes"] doubleValue]/1048576,growth,[row[@"complete"] boolValue]?@"":@" · 大小未统计完",state];
    UISwitch *toggle=[UISwitch new];toggle.on=enabled;toggle.accessibilityIdentifier=relative;
    [toggle addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];cell.accessoryView=toggle;
    return cell;
}
// 0.4.0 策略（policy.plist）：mode = auto|lock|clean，urlCache = 禁止网络缓存生成
- (NSDictionary *)policyEntry { return [self cached:@"policy.plist"][self.bundle] ?: @{}; }
- (NSString *)mode { return [self policyEntry][@"mode"] ?: @"auto"; }
- (void)savePolicy:(NSDictionary *)entry {
    NSMutableDictionary *all = [[NSDictionary dictionaryWithContentsOfFile:[self file:@"policy.plist"]] mutableCopy] ?: [NSMutableDictionary new];
    all[self.bundle] = entry;
    if (![all writeToFile:[self file:@"policy.plist"] atomically:YES]) { [self message:@"策略保存失败。"]; return; }
    self.fileCache = nil;
}
// 0.4.0 重新启用（打开目录开关/总开关/切换策略）即视为重新尝试：清掉该 App 的
// 降级记录，让“自动”模式重新走一遍 限权 -> 判定 -> 降级 的流程。
- (void)clearFallback {
    NSString *home = [self cached:@"snapshots.plist"][self.bundle][@"home"];
    if (!home.length) return;
    NSMutableDictionary *fallback = [[NSDictionary dictionaryWithContentsOfFile:[self file:@"fallback.plist"]] mutableCopy];
    if (!fallback) return;
    NSMutableArray *prefixes = [NSMutableArray arrayWithObject:[home stringByAppendingString:@"/"]];
    NSDictionary *groups = [self cached:@"snapshots.plist"][self.bundle][@"groups"];
    for (NSString *gid in groups) [prefixes addObject:[groups[gid] stringByAppendingString:@"/"]];
    BOOL changed = NO;
    for (NSString *key in fallback.allKeys)
        for (NSString *prefix in prefixes)
            if ([key hasPrefix:prefix]) { [fallback removeObjectForKey:key]; changed = YES; break; }
    if (changed) [fallback writeToFile:[self file:@"fallback.plist"] atomically:YES];
}
- (void)modeChanged:(UISegmentedControl *)control {
    NSArray *modes = @[@"auto", @"lock", @"clean"];
    NSMutableDictionary *entry = [[self policyEntry] mutableCopy];
    entry[@"mode"] = modes[control.selectedSegmentIndex];
    [self savePolicy:entry];
    [self clearFallback];
    [self.tableView reloadData];
}
- (void)urlCacheChanged:(UISwitch *)toggle {
    NSMutableDictionary *entry = [[self policyEntry] mutableCopy];
    entry[@"urlCache"] = @(toggle.on);
    [self savePolicy:entry];
    [self.tableView reloadData];
}
// 0.4.0 父目录优先：旧快照里可能残留父子并存的候选行，显示前先归并。
- (NSArray *)collapseRows:(NSArray *)rows {
    NSMutableArray *out = [NSMutableArray new];
    for (NSDictionary *row in rows) {
        NSString *path = row[@"path"]; BOOL child = NO;
        for (NSDictionary *other in rows) {
            NSString *otherPath = other[@"path"];
            if (otherPath.length < path.length && [path hasPrefix:[otherPath stringByAppendingString:@"/"]]) { child = YES; break; }
        }
        if (!child) [out addObject:row];
    }
    return out;
}
// 0.4.2 共享容器路径解析：Group/<组ID>/<相对路径> 按快照里的 groups 映射拼全路径
- (NSString *)fullPath:(NSString *)relative {
    NSDictionary *history = [self cached:@"snapshots.plist"][self.bundle];
    if ([relative hasPrefix:@"Group/"]) {
        NSString *rest = [relative substringFromIndex:6];
        NSRange slash = [rest rangeOfString:@"/"];
        if (slash.location != NSNotFound) {
            NSString *groupHome = history[@"groups"][[rest substringToIndex:slash.location]];
            if (groupHome.length) return [groupHome stringByAppendingPathComponent:[rest substringFromIndex:slash.location + 1]];
        }
        return nil;
    }
    NSString *home = history[@"home"];
    return home.length ? [home stringByAppendingPathComponent:relative] : nil;
}
- (void)master:(UISwitch *)toggle {
    NSDictionary *selected=[self cached:@"directories.plist"];
    if (toggle.on && ![selected[self.bundle] count]) {
        toggle.on=NO;
        for (NSDictionary *row in self.rows) {
            if ([row[@"path"] isEqual:@"Library/Caches"]) { [self save:@"Library/Caches" enabled:YES];return; }
        }
        [self message:@"尚未检测到标准缓存目录，请先打开该 App 再重新检测。"];
        return;
    }
    NSMutableDictionary *states=[[self cached:@"appEnabled.plist"] mutableCopy]?:[NSMutableDictionary new];
    states[self.bundle]=@(toggle.on);
    if (![states writeToFile:[self file:@"appEnabled.plist"] atomically:YES]) [self message:@"总开关保存失败。"];
    if (toggle.on) [self clearFallback];
    self.fileCache=nil;
    [self.tableView reloadData];
}
- (void)save:(NSString *)relative enabled:(BOOL)enabled {
    NSMutableDictionary *config=[[self cached:@"directories.plist"] mutableCopy]?:[NSMutableDictionary new];
    NSMutableArray *paths=[config[self.bundle] mutableCopy]?:[NSMutableArray new];
    if (enabled && ![paths containsObject:relative]) [paths addObject:relative];
    if (!enabled) [paths removeObject:relative];
    config[self.bundle]=paths;
    if (enabled) {
        NSMutableDictionary *states=[[self cached:@"appEnabled.plist"] mutableCopy]?:[NSMutableDictionary new];
        states[self.bundle]=@YES;
        if (![states writeToFile:[self file:@"appEnabled.plist"] atomically:YES]) { [self message:@"保存失败。"];return; }
    }
    if (![config writeToFile:[self file:@"directories.plist"] atomically:YES]) [self message:@"保存失败，开关未应用。"];
    else if (enabled) [self clearFallback];
    self.fileCache=nil;
    [self.tableView reloadData];
}
- (void)toggle:(UISwitch *)toggle {
    NSString *relative=toggle.accessibilityIdentifier;
    if (!toggle.on) {[self save:relative enabled:NO];return;}
    toggle.on=NO;
    UIAlertController *confirm=[UIAlertController alertControllerWithTitle:@"限制此目录写入？" message:[relative stringByAppendingString:@"\n可能影响该 App 的功能。可随时关闭恢复原权限。"] preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"开启限制" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){[self save:relative enabled:YES];}]];
    [self presentViewController:confirm animated:YES completion:nil];
}
@end
