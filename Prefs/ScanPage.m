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
    self.rows=history[self.bundle][@"rows"]?:@[];
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
        self.rows=result[@"rows"]?:@[];
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
    if (path.row == 0) return nil;
    NSString *relative = [self orderedRows][path.row-1][@"path"];
    NSArray *selected = [self cached:@"directories.plist"][self.bundle];
    if (![selected containsObject:relative]) return nil;
    NSString *home = [self cached:@"snapshots.plist"][self.bundle][@"home"];
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
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {return self.rows.count+1;}
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
    return @"检测会为尚未配置的 App 自动预选 Library/Caches，总开关保持关闭；打开 App 总开关才会应用限制。已手动配置的选择保持原样。先检测一次，使用 App 后再次检测，可查看目录增长。增长只代表有文件写入，无法自动判断是否可以限制。开启开关取消目录所有者的写入权限，关闭恢复原权限。仅影响目录本身，已有子目录仍可能写入。Application Support 可能存放重要资源，限制后可能影响登录或功能。已有文件不会自动删除。开关约 2 秒内应用，首次安装需注销。";
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
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
        toggle.on=[selected[self.bundle] count] && (!states[self.bundle] || [states[self.bundle] boolValue]);
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
    NSDictionary *history=[self cached:@"snapshots.plist"];
    NSString *full=[history[self.bundle][@"home"] stringByAppendingPathComponent:relative];
    struct stat info;BOOL blocked=full && !lstat(full.fileSystemRepresentation,&info) && !(info.st_mode&S_IWUSR);
    NSDictionary *master=[self cached:@"appEnabled.plist"];
    BOOL masterOn=!master[self.bundle] || [master[self.bundle] boolValue];
    NSString *state=enabled?(!masterOn?@"已选中，等待打开 App 总开关":(blocked && records[full]?@"已限制写入":@"等待基线或权限应用，请打开 App 完成加载再返回桌面")):@"未选中";
    cell.detailTextLabel.text=[NSString stringWithFormat:@"%.2f MB%@%@\n%@",[row[@"bytes"] doubleValue]/1048576,growth,[row[@"complete"] boolValue]?@"":@" · 大小未统计完",state];
    UISwitch *toggle=[UISwitch new];toggle.on=enabled;toggle.accessibilityIdentifier=relative;
    [toggle addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];cell.accessoryView=toggle;
    return cell;
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
