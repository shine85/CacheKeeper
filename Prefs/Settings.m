#import <UIKit/UIKit.h>
#import <Preferences/PSViewController.h>
#import <objc/message.h>
#include <roothide.h>

@interface CKScanPage : UITableViewController
@property(nonatomic,copy) NSString *bundle;
@property(nonatomic,copy) NSString *appName;
@end

@interface CKSettings : PSViewController <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating>
@property(nonatomic,strong) UITableView *table;
@property(nonatomic,strong) NSArray *apps;
@property(nonatomic,strong) NSArray *visibleApps;
@property(nonatomic,strong) NSTimer *batchTimer;
@property(nonatomic,strong) NSDictionary *scanHistory;
@property(nonatomic,strong) NSDictionary *directoriesCache;
@property(nonatomic,strong) NSDictionary *statesCache;
@property(nonatomic,copy) NSString *lastFingerprint;
@end
@implementation CKSettings
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"缓存管家";
    Class workspace = NSClassFromString(@"LSApplicationWorkspace");
    id manager = ((id(*)(id,SEL))objc_msgSend)(workspace,NSSelectorFromString(@"defaultWorkspace"));
    NSArray *installed = ((id(*)(id,SEL))objc_msgSend)(manager,NSSelectorFromString(@"allInstalledApplications"));
    NSMutableArray *apps = [NSMutableArray array];
    for (id app in installed) {
        NSString *type = [app valueForKey:@"applicationType"];
        NSString *bundle = [app valueForKey:@"applicationIdentifier"];
        NSString *name = [app valueForKey:@"localizedName"];
        if (bundle.length && ([type isEqual:@"User"] || (![bundle hasPrefix:@"com.apple."] && [[[app valueForKey:@"bundleURL"] pathExtension] isEqual:@"app"]))) [apps addObject:@{@"id":bundle,@"name":name ?: bundle}];
    }
    self.apps = apps;
    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = @"搜索应用";
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.table.dataSource = self; self.table.delegate = self;
    [self.view addSubview:self.table];
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"检测全部" style:UIBarButtonItemStylePlain target:self action:@selector(scanAll)];
}
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { return self.visibleApps.count; }
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section { return @"检测全部后点应用管理目录 · 右侧开关限制写入"; }
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
    return @"选择已安装的 App 检测目录，再开启需要的写入限制。首次加载完成后退到后台建立缓存基线，关闭限制后恢复原权限。首次安装请注销桌面。";
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    NSDictionary *app = self.visibleApps[path.row];
    // 0.3.8 优化：启用 cell 复用（原来每行新建，滚动时反复分配）
    UITableViewCell *cell = [table dequeueReusableCellWithIdentifier:@"app"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"app"];
    cell.textLabel.text = app[@"name"]; NSDictionary *status = [NSDictionary dictionaryWithContentsOfFile:[jbroot(@"/var/mobile/Library/CacheKeeper/Status") stringByAppendingPathComponent:[app[@"id"] stringByAppendingString:@".plist"]]];
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.text = status ? [NSString stringWithFormat:@"%@ · 清理 %@ 个 · %.2f MB · %@", status[@"mode"], status[@"removed"], [status[@"bytes"] doubleValue]/1048576, status[@"updated"]] : @"尚无清理记录，请开启后完全退出并重新打开应用";
    NSDictionary *scan=self.scanHistory[app[@"id"]];
    if (scan) cell.detailTextLabel.text=[NSString stringWithFormat:@"检测到 %lu 个候选目录 · %@\n点击查看目录与限制写入开关",(unsigned long)[scan[@"rows"] count],scan[@"updated"]];
    // 0.3.9 修复：原 else 无条件执行，会把上一行刚写好的清理统计文案覆盖掉，
    // 使「清理 N 个 · x MB」在列表页永远显示不出来。改为仅在既无检测记录、
    // 也无清理记录时才显示未检测提示。
    else if (!status) cell.detailTextLabel.text=@"尚未检测 · 点击右上角检测全部";
    UISwitch *toggle = [UISwitch new]; toggle.accessibilityIdentifier = app[@"id"];
    // 0.3.8 优化：原来每行都从磁盘重读这两份 plist，列表一刷新就是 N 次读盘；改用 updateBatch 刷新的缓存
    NSDictionary *directories=self.directoriesCache ?: [NSDictionary dictionaryWithContentsOfFile:jbroot(@"/var/mobile/Library/CacheKeeper/directories.plist")];
    NSDictionary *states=self.statesCache ?: [NSDictionary dictionaryWithContentsOfFile:jbroot(@"/var/mobile/Library/CacheKeeper/appEnabled.plist")];
    toggle.on=[directories[app[@"id"]] count] && (!states[app[@"id"]] || [states[app[@"id"]] boolValue]);
    [toggle addTarget:self action:@selector(changed:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle; cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];[self.table reloadData];[self updateBatch];
    if (!self.batchTimer) {
        __weak typeof(self) weak=self;
        self.batchTimer=[NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer){[weak updateBatch];}];
    }
}
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated];[self.batchTimer invalidate];self.batchTimer=nil; }
- (void)dealloc { [self.batchTimer invalidate]; }
- (void)scanAll {
    NSString *path=jbroot(@"/var/mobile/Library/CacheKeeper/batch.plist");
    NSDictionary *existing=[NSDictionary dictionaryWithContentsOfFile:path];
    if ([existing[@"remaining"] count]) return;
    NSMutableArray *bundles=[NSMutableArray array];
    for (NSDictionary *app in self.apps) [bundles addObject:app[@"id"]];
    if (!bundles.count) return;
    NSDictionary *request=@{@"token":NSUUID.UUID.UUIDString,@"remaining":bundles,@"total":@(bundles.count),@"completed":@0};
    if (![request writeToFile:path atomically:YES]) {
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"无法开始检测" message:@"请检查插件安装后重试。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
    [self updateBatch];
}
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController { [self updateBatch]; }
- (void)updateBatch {
    // 0.3.8 优化：本方法由 1 秒定时器驱动，原来每秒都重读 4 份 plist、全表 reloadData，
    // 页面静置时也在空转。用“搜索词 + 相关文件修改时间”做指纹，无变化直接返回；
    // 任一配置文件或 Status 目录有更新，指纹变化，仍在 1 秒内刷新，行为不变。
    NSString *currentQuery = self.navigationItem.searchController.searchBar.text ?: @"";
    NSMutableString *fingerprint = [NSMutableString stringWithString:currentQuery];
    NSString *base = jbroot(@"/var/mobile/Library/CacheKeeper");
    for (NSString *name in @[@"batch.plist",@"snapshots.plist",@"directories.plist",@"appEnabled.plist",@"Status"]) {
        NSDate *mtime = [NSFileManager.defaultManager attributesOfItemAtPath:[base stringByAppendingPathComponent:name] error:nil][NSFileModificationDate];
        [fingerprint appendFormat:@"|%f",mtime.timeIntervalSince1970];
    }
    if ([fingerprint isEqualToString:self.lastFingerprint]) return;
    self.lastFingerprint = fingerprint;
    NSDictionary *directories = [NSDictionary dictionaryWithContentsOfFile:jbroot(@"/var/mobile/Library/CacheKeeper/directories.plist")];
    NSDictionary *states = [NSDictionary dictionaryWithContentsOfFile:jbroot(@"/var/mobile/Library/CacheKeeper/appEnabled.plist")];
    self.directoriesCache = directories;
    self.statesCache = states;
    NSString *query = self.navigationItem.searchController.searchBar.text;
    NSMutableDictionary *sortKeys = [NSMutableDictionary new];
    NSMutableSet *enabled = [NSMutableSet new];
    NSMutableArray *matches = [NSMutableArray new];
    for (NSDictionary *app in self.apps) {
        NSString *name = app[@"name"], *bundle = app[@"id"];
        NSString *pinyin = [name stringByApplyingTransform:NSStringTransformMandarinToLatin reverse:NO] ?: name;
        pinyin = [pinyin stringByApplyingTransform:NSStringTransformStripCombiningMarks reverse:NO] ?: pinyin;
        if (query.length && ![name localizedCaseInsensitiveContainsString:query] &&
            ![bundle localizedCaseInsensitiveContainsString:query] && ![pinyin localizedCaseInsensitiveContainsString:query]) continue;
        if ([directories[bundle] count] && (!states[bundle] || [states[bundle] boolValue])) [enabled addObject:bundle];
        sortKeys[bundle] = pinyin;
        [matches addObject:app];
    }
    self.visibleApps = [matches sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        BOOL left = [enabled containsObject:a[@"id"]], right = [enabled containsObject:b[@"id"]];
        if (left != right) return left ? NSOrderedAscending : NSOrderedDescending;
        NSComparisonResult order = [sortKeys[a[@"id"]] localizedStandardCompare:sortKeys[b[@"id"]]];
        return order == NSOrderedSame ? [a[@"id"] compare:b[@"id"]] : order;
    }];

    self.scanHistory=[NSDictionary dictionaryWithContentsOfFile:jbroot(@"/var/mobile/Library/CacheKeeper/snapshots.plist")];
    NSDictionary *batch=[NSDictionary dictionaryWithContentsOfFile:jbroot(@"/var/mobile/Library/CacheKeeper/batch.plist")];
    BOOL active=[batch[@"remaining"] count]>0;
    self.navigationItem.rightBarButtonItem.enabled=!active;
    self.navigationItem.rightBarButtonItem.title=active?[NSString stringWithFormat:@"%@/%@",batch[@"completed"],batch[@"total"]]:@"检测全部";
    [self.table reloadData];
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    NSDictionary *app=self.visibleApps[path.row];
    CKScanPage *page=[CKScanPage new];page.bundle=app[@"id"];page.appName=app[@"name"];
    [self.navigationController pushViewController:page animated:YES];
}
- (void)changed:(UISwitch *)toggle {
    NSString *bundle=toggle.accessibilityIdentifier;
    NSString *directoryPath=jbroot(@"/var/mobile/Library/CacheKeeper/directories.plist");
    NSMutableDictionary *directories=[[NSDictionary dictionaryWithContentsOfFile:directoryPath] mutableCopy]?:[NSMutableDictionary new];
    if (toggle.on && ![directories[bundle] count]) {
        BOOL found=NO;
        for (NSDictionary *row in self.scanHistory[bundle][@"rows"]) if ([row[@"path"] isEqual:@"Library/Caches"]) found=YES;
        if (!found) { toggle.on=NO; [self scanAll];return; }
        directories[bundle]=@[@"Library/Caches"];
    }
    NSMutableDictionary *states=[[NSDictionary dictionaryWithContentsOfFile:jbroot(@"/var/mobile/Library/CacheKeeper/appEnabled.plist")] mutableCopy]?:[NSMutableDictionary new];
    states[bundle]=@(toggle.on);
    if ([states writeToFile:jbroot(@"/var/mobile/Library/CacheKeeper/appEnabled.plist") atomically:YES]) [directories writeToFile:directoryPath atomically:YES];
    [self updateBatch];
}
@end
