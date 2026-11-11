#import <UIKit/UIKit.h>
#import <Preferences/PSViewController.h>
#import <objc/message.h>
#include <roothide.h>
#import "../AxsCacheKeeperPolicy.h"

static id axs_cachekeeper_app_property(id object, NSString *name) {
    SEL selector=NSSelectorFromString(name);
    return [object respondsToSelector:selector] ? ((id(*)(id,SEL))objc_msgSend)(object,selector) : nil;
}

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
@property(nonatomic,copy) NSString *appsError;
@property(nonatomic,strong) NSDictionary *directoriesSnapshot;
@property(nonatomic,strong) NSDictionary *statesSnapshot;
@end
@implementation CKSettings
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"缓存管家";
    self.apps = @[];
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
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {
    return [NSString stringWithFormat:@"已安装 %lu 个 APP · 点击设置，默认不开启",(unsigned long)self.apps.count];
}
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
    return self.appsError ?: @"只有主动开启的 APP 才应用缓存控制；可打开总开关，也可在检测后单项或一键开启。检测和切换模式不启用 APP，微信等特殊 APP 保持关闭即可。";
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    NSDictionary *app = self.visibleApps[path.row];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text = app[@"name"]; NSDictionary *status = [NSDictionary dictionaryWithContentsOfFile:[jbroot(@"/var/mobile/Library/CacheKeeper/Status") stringByAppendingPathComponent:[app[@"id"] stringByAppendingString:@".auto.plist"]]];
    cell.detailTextLabel.numberOfLines = 0;
    NSDictionary *scan=self.scanHistory[app[@"id"]];
    cell.detailTextLabel.text=axs_cachekeeper_summary(scan,status);
    UISwitch *toggle = [UISwitch new]; toggle.accessibilityIdentifier = app[@"id"];
    NSDictionary *directories=self.directoriesSnapshot;
    NSDictionary *states=self.statesSnapshot;
    toggle.on=axs_cachekeeper_app_enabled(states[app[@"id"]]);
    if (!toggle.on) cell.detailTextLabel.text=[@"未开启缓存控制\n" stringByAppendingString:axs_cachekeeper_summary(scan,nil)];
    else if (!axs_cachekeeper_selected_paths(directories,states,app[@"id"]).count) cell.detailTextLabel.text=@"总开关已开启；没有文件清理目录，网络缓存按独立选项执行";
    [toggle addTarget:self action:@selector(changed:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle; cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];[self axs_cachekeeper_reload_apps];[self updateBatch];
    if (!self.batchTimer) {
        __weak typeof(self) weak=self;
        self.batchTimer=[NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer){[weak updateBatch];}];
    }
}
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated];[self.batchTimer invalidate];self.batchTimer=nil; }
- (void)dealloc { [self.batchTimer invalidate]; }
- (void)axs_cachekeeper_reload_apps {
    id manager=axs_cachekeeper_app_property(NSClassFromString(@"LSApplicationWorkspace"),@"defaultWorkspace");
    NSArray *installed=axs_cachekeeper_app_property(manager,@"allInstalledApplications");
    if (![installed isKindOfClass:NSArray.class]) {
        self.appsError=@"无法读取系统应用列表，请检查插件加载情况；没有修改任何 APP 的开关。";
        self.apps=@[];return;
    }
    self.appsError=nil;
    NSMutableDictionary *apps=[NSMutableDictionary new];
    for (id proxy in installed) {
        NSDictionary *app=axs_cachekeeper_application_entry(axs_cachekeeper_app_property(proxy,@"applicationIdentifier"),
            axs_cachekeeper_app_property(proxy,@"localizedName"),axs_cachekeeper_app_property(proxy,@"applicationType"),
            axs_cachekeeper_app_property(proxy,@"bundleURL"));
        if (app) apps[app[@"id"]]=app;
    }
    self.apps=apps.allValues;
}
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
    NSDictionary *states = [NSDictionary dictionaryWithContentsOfFile:jbroot(@"/var/mobile/Library/CacheKeeper/appEnabled.plist")];
    self.statesSnapshot=states;
    self.directoriesSnapshot=[NSDictionary dictionaryWithContentsOfFile:jbroot(@"/var/mobile/Library/CacheKeeper/directories.plist")];
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
        if (axs_cachekeeper_app_enabled(states[bundle])) [enabled addObject:bundle];
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
    NSMutableDictionary *directories=axs_cachekeeper_edit_configuration(directoryPath);
    NSMutableDictionary *states=axs_cachekeeper_edit_configuration(jbroot(@"/var/mobile/Library/CacheKeeper/appEnabled.plist"));
    if (!directories || !states) { [self axs_cachekeeper_configuration_error]; [self updateBatch]; return; }
    if (toggle.on && !directories[bundle]) directories[bundle]=axs_cachekeeper_activation_paths(nil);
    states[bundle]=axs_cachekeeper_app_state(states[bundle],toggle.on);
    if (![directories writeToFile:directoryPath atomically:YES] ||
        ![states writeToFile:jbroot(@"/var/mobile/Library/CacheKeeper/appEnabled.plist") atomically:YES]) {
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"保存失败" message:@"缓存控制设置未完整保存，请检查安装与目录权限。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    } else axs_cachekeeper_notify_preferences();
    [self updateBatch];
}
- (void)axs_cachekeeper_configuration_error {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"配置不可读" message:@"原配置存在但读取失败，已停止保存以保护其他 APP 的设置。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
