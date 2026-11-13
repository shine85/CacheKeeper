#import <UIKit/UIKit.h>
#import <Preferences/PSViewController.h>
#import <objc/message.h>
#include <roothide.h>
#include <sys/stat.h>
#import "../AxsCacheKeeperPolicy.h"
#import "DiagnosticsPage.h"

static id axs_cachekeeper_app_property(id object, NSString *name) {
    SEL selector=NSSelectorFromString(name);
    return [object respondsToSelector:selector] ? ((id(*)(id,SEL))objc_msgSend)(object,selector) : nil;
}

@interface UIImage (CacheKeeperIcon)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleID format:(int)format scale:(double)scale;
@end

@interface CKScanPage : UITableViewController
@property(nonatomic,copy) NSString *bundle;
@property(nonatomic,copy) NSString *appName;
@end

// 分类 Tab：0 已开启，1 用户应用（App Store），2 巨魔应用（TrollStore），3 收藏应用。
// 系统应用不进缓存管家，分两层排除：①包体不在真实容器里的 System 应用——真实容器是
// Application/ 后恰好两级的 <UUID>/<App>.app；Roothide 的 jbroot 藏在容器目录下
// （.jbroot-<hex>/Applications/，三级），仅含子串会把 Sileo 等越狱应用误判为容器应用
// （#66 真机）；②bundle ID 以 com.apple. 开头且为 System 类型的——Apple 系统应用经
// App Store 更新后包体也在容器目录下，仍报 System 类型，仅凭容器路径无法排除
// （#62 真机：备忘录/播客等 10 个系统应用仍在巨魔应用）。商店下载的 Apple
// 应用（如 Apple Store、iMovie）报 User 类型，不受第②层影响。
// 来源判据是 applicationType，不是收据：巨魔应用报 @"System"（CoreTrust 系统级信任），商店
// 应用报 @"User"；解密的商店 IPA 包内常带原始 StoreKit 收据，收据判据会把巨魔应用误判为
// 商店应用（#60 真机：轻悦时光落在用户应用）。
@interface CKSettings : PSViewController <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@property(nonatomic,strong) UITableView *table;
@property(nonatomic,strong) UISegmentedControl *tabs;
@property(nonatomic,strong) UIView *tabWrap;
@property(nonatomic,strong) UISearchBar *searchBar;
@property(nonatomic,assign) NSInteger selectedTab;
@property(nonatomic,strong) NSArray *apps;
@property(nonatomic,strong) NSArray *sections;
@property(nonatomic,strong) NSSet *favorites;
@property(nonatomic,strong) NSMutableDictionary *iconCache;
@property(nonatomic,strong) NSTimer *batchTimer;
@property(nonatomic,strong) NSDictionary *scanHistory;
@property(nonatomic,copy) NSString *appsError;
@property(nonatomic,strong) NSDictionary *directoriesSnapshot;
@property(nonatomic,strong) NSDictionary *statesSnapshot;
@property(nonatomic,strong) NSDictionary *batchSnapshot;
@property(nonatomic,strong) NSMutableDictionary *appsByID;
@property(nonatomic,copy) NSString *lastStatusMtime;
@property(nonatomic,assign) NSInteger lastSelectedTab;
@property(nonatomic,copy) NSString *lastQuery;
@property(nonatomic) BOOL axs_cachekeeper_menuVisible;
@property(nonatomic) BOOL axs_cachekeeper_refreshPending;
@end
@implementation CKSettings
- (void)loadView {
    // 自有内容根，避免 Preferences 的默认容器布局参与搜索栏命中区域。
    self.view=[[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.view.backgroundColor=UIColor.systemGroupedBackgroundColor;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"缓存管家";
    self.apps = @[];
    self.sections = @[];
    self.favorites = [NSSet set];
    self.iconCache = [NSMutableDictionary new];
    self.appsByID = [NSMutableDictionary new];
    self.selectedTab = 0;
    // 搜索栏用普通 UISearchBar 直接放进视图，不用 UISearchController：控制器激活后的
    // 呈现层会挡住 Tab 条的点按（#59 真机：搜索后点不了顶栏）；普通搜索栏没有呈现行为，
    // 搜索中切 Tab 照常过滤显示。外观位置不变，仍在 Tab 条上方。
    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectZero];
    self.searchBar.placeholder = @"搜索应用";
    self.searchBar.delegate = self;
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchBar.accessibilityIdentifier=@"CacheKeeperAppSearch";
    [self.view addSubview:self.searchBar];
    self.tabWrap = [[UIView alloc] initWithFrame:CGRectZero];
    self.tabWrap.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.tabs = [[UISegmentedControl alloc] initWithItems:@[@"已开启", @"用户应用", @"巨魔应用", @"收藏应用"]];
    self.tabs.selectedSegmentIndex = 0;
    [self.tabs addTarget:self action:@selector(tabChanged:) forControlEvents:UIControlEventValueChanged];
    [self.tabWrap addSubview:self.tabs];
    [self.view addSubview:self.tabWrap];
    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.table.keyboardDismissMode=UIScrollViewKeyboardDismissModeOnDrag;
    self.table.dataSource = self; self.table.delegate = self;
    [self.view addSubview:self.table];
    // 横滑只在列表内切组，不参与搜索输入、光标选择或分段按钮的触摸仲裁。
    UISwipeGestureRecognizer *swipeLeft=[[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(swipeTab:)];
    swipeLeft.direction=UISwipeGestureRecognizerDirectionLeft;
    swipeLeft.cancelsTouchesInView=NO;swipeLeft.delaysTouchesBegan=NO;
    [self.table addGestureRecognizer:swipeLeft];
    UISwipeGestureRecognizer *swipeRight=[[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(swipeTab:)];
    swipeRight.direction=UISwipeGestureRecognizerDirectionRight;
    swipeRight.cancelsTouchesInView=NO;swipeRight.delaysTouchesBegan=NO;
    [self.table addGestureRecognizer:swipeRight];
    self.navigationItem.rightBarButtonItems=@[
        [[UIBarButtonItem alloc] initWithTitle:@"检测全部" style:UIBarButtonItemStylePlain target:self action:@selector(scanAll)],
        [[UIBarButtonItem alloc] initWithTitle:@"诊断" style:UIBarButtonItemStylePlain target:self action:@selector(axs_cachekeeper_diagnostics)]];
    for (UIView *view in @[self.searchBar,self.tabWrap,self.tabs,self.table]) view.translatesAutoresizingMaskIntoConstraints=NO;
    UILayoutGuide *safe=self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.searchBar.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.searchBar.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.searchBar.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.searchBar.heightAnchor constraintEqualToConstant:56],
        [self.tabWrap.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor],
        [self.tabWrap.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.tabWrap.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.tabWrap.heightAnchor constraintEqualToConstant:46],
        [self.tabs.topAnchor constraintEqualToAnchor:self.tabWrap.topAnchor constant:7],
        [self.tabs.leadingAnchor constraintEqualToAnchor:self.tabWrap.leadingAnchor constant:16],
        [self.tabs.trailingAnchor constraintEqualToAnchor:self.tabWrap.trailingAnchor constant:-16],
        [self.tabs.heightAnchor constraintEqualToConstant:32],
        [self.table.topAnchor constraintEqualToAnchor:self.tabWrap.bottomAnchor],
        [self.table.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.table.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.table.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor]]];
}
- (void)axs_cachekeeper_diagnostics {
    [self.searchBar resignFirstResponder];
    [self.navigationController pushViewController:[[AxsCacheKeeperDiagnosticsPage alloc] initWithApps:self.apps] animated:YES];
}
- (void)tabChanged:(UISegmentedControl *)sender {
    self.selectedTab = sender.selectedSegmentIndex;
    [self updateBatch];
    [self.table setContentOffset:CGPointZero animated:NO];
}
- (void)swipeTab:(UISwipeGestureRecognizer *)gesture {
    NSInteger next=(self.selectedTab + (gesture.direction==UISwipeGestureRecognizerDirectionLeft ? 1 : -1) + 4) % 4;
    self.selectedTab=next;
    self.tabs.selectedSegmentIndex=next;
    [self updateBatch];
    [self.table setContentOffset:CGPointZero animated:NO];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { return MAX(1, (NSInteger)self.sections.count); }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    if (section >= self.sections.count) return 0;
    return [self.sections[section][@"apps"] count];
}
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {
    if (section >= self.sections.count) return nil;
    return self.sections[section][@"title"];
}
- (NSArray *)sectionIndexTitlesForTableView:(UITableView *)table {
    if (self.sections.count < 2) return nil;
    NSMutableArray *titles = [NSMutableArray new];
    for (NSDictionary *section in self.sections) [titles addObject:section[@"title"]];
    return titles;
}
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
    if (section != (NSInteger)MAX(1, self.sections.count) - 1) return nil;
    if (self.appsError) return self.appsError;
    NSUInteger shown = 0;
    for (NSDictionary *item in self.sections) shown += [item[@"apps"] count];
    if (!shown) {
        if (self.selectedTab == 0) return @"暂无已开启缓存控制的 APP，在「用户应用」或「巨魔应用」里打开开关即可。";
        if (self.selectedTab == 3) return @"暂无收藏，长按应用选择「收藏应用」。";
        return @"此分类下没有 APP。";
    }
    return [NSString stringWithFormat:@"共 %lu 个 APP（不含系统应用）· 点击设置，默认不开启。\n只有主动开启的 APP 才应用缓存控制；可打开总开关，也可在检测后单项或一键开启。检测和切换模式不启用 APP，微信等特殊 APP 保持关闭即可。", (unsigned long)self.apps.count];
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    NSDictionary *app = self.sections[path.section][@"apps"][path.row];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.imageView.image = [self axs_cachekeeper_icon:app];
    cell.imageView.layer.cornerRadius = 10;
    cell.imageView.clipsToBounds = YES;
    BOOL starred = [self.favorites containsObject:app[@"id"]];
    cell.textLabel.text = starred ? [app[@"name"] stringByAppendingString:@" ★"] : app[@"name"];
    NSDictionary *status = [NSDictionary dictionaryWithContentsOfFile:[jbroot(@"/var/mobile/Library/CacheKeeper/Status") stringByAppendingPathComponent:[app[@"id"] stringByAppendingString:@".auto.plist"]]];
    cell.detailTextLabel.numberOfLines = 0;
    NSDictionary *scan=self.scanHistory[app[@"id"]];
    NSString *bundleLine = app[@"version"] ? [NSString stringWithFormat:@"%@ · %@", app[@"id"], app[@"version"]] : app[@"id"];
    NSString *summaryText=[bundleLine stringByAppendingFormat:@"\n%@", axs_cachekeeper_summary(scan,status)];
    NSMutableAttributedString *summaryStyled=[[NSMutableAttributedString alloc] initWithString:summaryText];
    NSRange totalLine=[summaryText rangeOfString:@"累计清理 "];
    NSRange lastLine=[summaryText rangeOfString:@"上次清理："];
    NSUInteger redStart=totalLine.location!=NSNotFound?totalLine.location:lastLine.location;
    if (redStart!=NSNotFound) {
        NSUInteger scanFrom=(lastLine.location!=NSNotFound && lastLine.location>=redStart)?lastLine.location:redStart;
        NSUInteger lineEnd=scanFrom;
        while (lineEnd<summaryText.length && [summaryText characterAtIndex:lineEnd]!='\n') lineEnd++;
        [summaryStyled addAttribute:NSForegroundColorAttributeName value:UIColor.systemRedColor range:NSMakeRange(redStart,lineEnd-redStart)];
    }
    cell.detailTextLabel.attributedText=summaryStyled;
    UISwitch *toggle = [UISwitch new]; toggle.accessibilityIdentifier = app[@"id"];
    NSDictionary *directories=self.directoriesSnapshot;
    NSDictionary *states=self.statesSnapshot;
    toggle.on=axs_cachekeeper_app_enabled(states[app[@"id"]]);
    if (!toggle.on) cell.detailTextLabel.text=[[bundleLine stringByAppendingString:@"\n未开启缓存控制\n"] stringByAppendingString:axs_cachekeeper_summary(scan,nil)];
    else if (!axs_cachekeeper_selected_paths(directories,states,app[@"id"]).count && !axs_cachekeeper_auto_discover(states[app[@"id"]])) cell.detailTextLabel.text=[bundleLine stringByAppendingString:@"\n总开关已开启；没有文件清理目录，网络缓存按独立选项执行"];
    [toggle addTarget:self action:@selector(changed:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle; cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}
// 长按菜单由 UITableView 代理方法提供（iOS 13+ 标准做法），不要给每个 cell 挂 UIContextMenuInteraction：
// 列表每秒刷新会重建 cell，挂在 cell 上的手势随 cell 一起被销毁，长按永远等不到菜单（#62 真机：长按无菜单）。
- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    (void)tableView; (void)point;
    if (indexPath.section >= self.sections.count) return nil;
    NSDictionary *app = self.sections[indexPath.section][@"apps"][indexPath.row];
    NSString *bundle = app[@"id"];
    BOOL favorited = [self.favorites containsObject:bundle];
    __weak typeof(self) weak = self;
    UIAction *favorite = [UIAction actionWithTitle:favorited ? @"取消收藏" : @"收藏应用" image:[UIImage systemImageNamed:favorited ? @"star.slash" : @"star"] identifier:nil handler:^(__kindof UIAction *action) { [weak axs_cachekeeper_set_favorite:bundle favorite:!favorited]; }];
    UIAction *launch = [UIAction actionWithTitle:@"启动" image:[UIImage systemImageNamed:@"arrow.up.forward.app"] identifier:nil handler:^(__kindof UIAction *action) { [weak axs_cachekeeper_launch:bundle]; }];
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) { return [UIMenu menuWithTitle:app[@"name"] children:@[favorite, launch]]; }];
}
- (void)tableView:(UITableView *)tableView willDisplayContextMenuWithConfiguration:(UIContextMenuConfiguration *)configuration animator:(id<UIContextMenuInteractionAnimating>)animator {
    self.axs_cachekeeper_menuVisible=YES;
}
- (void)tableView:(UITableView *)tableView willEndContextMenuInteractionWithConfiguration:(UIContextMenuConfiguration *)configuration animator:(id<UIContextMenuInteractionAnimating>)animator {
    void (^apply)(void)=^{
        self.axs_cachekeeper_menuVisible=NO;
        if (self.axs_cachekeeper_refreshPending) { self.axs_cachekeeper_refreshPending=NO; [self updateBatch]; }
    };
    if (animator) [animator addCompletion:apply]; else apply();
}
- (void)axs_cachekeeper_set_favorite:(NSString *)bundle favorite:(BOOL)favorite {
    NSString *path = jbroot(@"/var/mobile/Library/CacheKeeper/favorites.plist");
    NSArray *existing = [NSArray arrayWithContentsOfFile:path];
    NSMutableArray *saved = existing ? [existing mutableCopy] : [NSMutableArray new];
    if (favorite) { if (![saved containsObject:bundle]) [saved addObject:bundle]; }
    else [saved removeObject:bundle];
    if (![saved writeToFile:path atomically:YES]) {
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"保存失败" message:@"收藏未保存，请检查安装与目录权限。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
    [self updateBatch];
}
- (void)axs_cachekeeper_launch:(NSString *)bundle {
    id manager=axs_cachekeeper_app_property(NSClassFromString(@"LSApplicationWorkspace"),@"defaultWorkspace");
    SEL open=NSSelectorFromString(@"openApplicationWithBundleID:");
    if (manager && [manager respondsToSelector:open]) ((BOOL(*)(id,SEL,NSString *))objc_msgSend)(manager,open,bundle);
}
- (UIImage *)axs_cachekeeper_icon:(NSDictionary *)app {
    NSString *bundle = app[@"id"];
    UIImage *cached = self.iconCache[bundle];
    if (cached) return cached;
    UIImage *icon = nil;
    if ([UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)])
        icon = [UIImage _applicationIconImageForBundleIdentifier:bundle format:0 scale:UIScreen.mainScreen.scale];
    UIImage *result = icon ? [self axs_cachekeeper_scaled_icon:icon] : [self axs_cachekeeper_placeholder_icon:app[@"name"]];
    if (result) self.iconCache[bundle] = result;
    return result;
}
- (UIImage *)axs_cachekeeper_scaled_icon:(UIImage *)icon {
    CGFloat side = 44;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(side, side), NO, UIScreen.mainScreen.scale);
    [icon drawInRect:CGRectMake(0, 0, side, side)];
    UIImage *scaled = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return scaled ?: icon;
}
- (UIImage *)axs_cachekeeper_placeholder_icon:(NSString *)name {
    CGFloat side = 44;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(side, side), NO, UIScreen.mainScreen.scale);
    [[UIColor systemGray4Color] setFill];
    UIRectFill(CGRectMake(0, 0, side, side));
    NSString *letter = name.length ? [[name substringToIndex:1] uppercaseString] : @"?";
    NSDictionary *attrs = @{NSFontAttributeName:[UIFont boldSystemFontOfSize:20], NSForegroundColorAttributeName:UIColor.whiteColor};
    CGSize size = [letter sizeWithAttributes:attrs];
    [letter drawAtPoint:CGPointMake((side-size.width)/2, (side-size.height)/2) withAttributes:attrs];
    UIImage *placeholder = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return placeholder;
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated]; self.axs_cachekeeper_menuVisible=NO; self.axs_cachekeeper_refreshPending=NO; [self updateBatch];
    if (!self.batchTimer) {
        __weak typeof(self) weak=self;
        self.batchTimer=[NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer){[weak updateBatch];}];
    }
}
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated];[self.batchTimer invalidate];self.batchTimer=nil; }
- (void)dealloc { [self.batchTimer invalidate]; }
- (NSString *)axs_cachekeeper_source_for_type:(NSString *)type {
    return [type isEqual:@"System"] ? @"troll" : @"user";
}
// 重查已安装应用，返回列表是否变化（任务 5）：安装/卸载/版本/名称变化都刷新列表。
// 拼音按 bundle ID 缓存，每秒重查只重算新增或版本/名称变化的条目；已卸载的图标缓存同步清理。
// 列表按 bundle ID 排序后比较内容（allValues 顺序不稳定，不能直接比较）。
- (BOOL)axs_cachekeeper_reload_apps {
    id manager=axs_cachekeeper_app_property(NSClassFromString(@"LSApplicationWorkspace"),@"defaultWorkspace");
    NSArray *installed=axs_cachekeeper_app_property(manager,@"allInstalledApplications");
    if (![installed isKindOfClass:NSArray.class]) {
        self.appsError=@"无法读取系统应用列表，请检查插件加载情况；没有修改任何 APP 的开关。";
        if (!self.apps.count) return NO;
        self.apps=@[];return YES;
    }
    self.appsError=nil;
    NSMutableDictionary *apps=[NSMutableDictionary new];
    for (id proxy in installed) {
        NSString *type=axs_cachekeeper_app_property(proxy,@"applicationType");
        NSURL *url=axs_cachekeeper_app_property(proxy,@"bundleURL");
        NSString *bundleID=axs_cachekeeper_app_property(proxy,@"applicationIdentifier");
        BOOL isContainer=axs_cachekeeper_container_bundle_path(url.path);
        if ([type isEqual:@"System"] && !isContainer) continue;
        if ([type isEqual:@"System"] && [bundleID hasPrefix:@"com.apple."]) continue;
        NSString *name=axs_cachekeeper_app_property(proxy,@"localizedName");
        NSString *effectiveName=([name isKindOfClass:NSString.class] && name.length) ? name : bundleID;
        NSString *version=axs_cachekeeper_app_property(proxy,@"shortVersionString");
        version=([version isKindOfClass:NSString.class] && version.length) ? version : @"";
        NSDictionary *cached=self.appsByID[bundleID];
        if (cached && [cached[@"name"] isEqual:effectiveName] && [(cached[@"version"] ?: @"") isEqual:version] && [cached[@"source"] isEqual:[self axs_cachekeeper_source_for_type:type]]) { apps[bundleID]=cached;continue; }
        NSDictionary *app=axs_cachekeeper_application_entry(bundleID,name,type,url);
        if (!app) continue;
        NSString *pinyin=[effectiveName stringByApplyingTransform:NSStringTransformMandarinToLatin reverse:NO] ?: effectiveName;
        pinyin=[pinyin stringByApplyingTransform:NSStringTransformStripCombiningMarks reverse:NO] ?: pinyin;
        NSMutableDictionary *entry=[app mutableCopy];
        entry[@"source"]=[self axs_cachekeeper_source_for_type:type];
        if (version.length) entry[@"version"]=version;
        entry[@"pinyin"]=pinyin;
        apps[bundleID]=entry;
    }
    NSArray *sorted=[apps.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b) { return [a[@"id"] compare:b[@"id"]]; }];
    if ([sorted isEqualToArray:self.apps]) return NO;
    self.apps=sorted;self.appsByID=apps;
    for (NSString *bundle in self.iconCache.allKeys) if (!apps[bundle]) [self.iconCache removeObjectForKey:bundle];
    return YES;
}
// 回执变化信号（任务 5）：回执由 Receipts 模块原子写入（临时文件＋重命名），
// 每次落盘都更新 Status 目录 mtime；只比目录 mtime，不必每秒读全部回执文件。
- (NSString *)axs_cachekeeper_status_mtime {
    struct stat info;
    if (stat([jbroot(@"/var/mobile/Library/CacheKeeper/Status") fileSystemRepresentation], &info)) return @"missing";
    return [NSString stringWithFormat:@"%lld.%09ld", (long long)info.st_mtimespec.tv_sec, (long)info.st_mtimespec.tv_nsec];
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
- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText { [self updateBatch]; }
- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar { [searchBar resignFirstResponder]; }
- (void)searchBarTextDidBeginEditing:(UISearchBar *)searchBar { [searchBar setShowsCancelButton:YES animated:YES]; }
- (void)searchBarTextDidEndEditing:(UISearchBar *)searchBar { [searchBar setShowsCancelButton:NO animated:YES]; }
- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar { searchBar.text = @""; [searchBar resignFirstResponder]; [self updateBatch]; }
- (void)updateBatch {
    // 菜单关闭后重新读取最新输入；不在菜单期间推进用于判等的快照。
    if (self.axs_cachekeeper_menuVisible) { self.axs_cachekeeper_refreshPending=YES; return; }
    NSDictionary *states = [NSDictionary dictionaryWithContentsOfFile:jbroot(@"/var/mobile/Library/CacheKeeper/appEnabled.plist")] ?: @{};
    NSDictionary *directories=[NSDictionary dictionaryWithContentsOfFile:jbroot(@"/var/mobile/Library/CacheKeeper/directories.plist")] ?: @{};
    NSArray *savedFavorites=[NSArray arrayWithContentsOfFile:jbroot(@"/var/mobile/Library/CacheKeeper/favorites.plist")];
    NSSet *favorites=[NSSet setWithArray:[savedFavorites isKindOfClass:NSArray.class] ? savedFavorites : @[]];
    NSDictionary *history=[NSDictionary dictionaryWithContentsOfFile:jbroot(@"/var/mobile/Library/CacheKeeper/snapshots.plist")] ?: @{};
    NSDictionary *batch=[NSDictionary dictionaryWithContentsOfFile:jbroot(@"/var/mobile/Library/CacheKeeper/batch.plist")] ?: @{};
    NSString *query = self.searchBar.text ?: @"";
    BOOL appsChanged=[self axs_cachekeeper_reload_apps];
    NSString *statusMtime=[self axs_cachekeeper_status_mtime];
    // 每秒定时刷新：输入（Tab/查询/各快照/应用列表/回执目录 mtime）无变化时跳过重建与
    // reloadData——无谓的全量重建每秒销毁重建全部 cell，既抖动又打断长按手势（#62）。
    // 快照用 isEqual: 真实内容比较，不用 .hash（哈希碰撞会漏刷；旧键还漏了回执与应用列表，
    // 只变回执或安装/卸载时列表不刷新，P2-2）。清理进行中快照在变，仍会正常刷新。
    if (!appsChanged && self.selectedTab==self.lastSelectedTab && [query isEqual:self.lastQuery] &&
        [states isEqual:self.statesSnapshot] && [directories isEqual:self.directoriesSnapshot] &&
        [favorites isEqual:self.favorites] && [history isEqual:self.scanHistory] &&
        [batch isEqual:self.batchSnapshot] && [statusMtime isEqual:self.lastStatusMtime]) return;
    self.statesSnapshot=states;self.directoriesSnapshot=directories;self.favorites=favorites;
    self.scanHistory=history;self.batchSnapshot=batch;self.lastStatusMtime=statusMtime;
    self.lastSelectedTab=self.selectedTab;self.lastQuery=query;
    NSMutableArray *matches = [NSMutableArray new];
    for (NSDictionary *app in self.apps) {
        NSString *name = app[@"name"], *bundle = app[@"id"];
        NSString *pinyin = app[@"pinyin"] ?: name;
        if (query.length && ![name localizedCaseInsensitiveContainsString:query] &&
            ![bundle localizedCaseInsensitiveContainsString:query] && ![pinyin localizedCaseInsensitiveContainsString:query]) continue;
        if (self.selectedTab == 0 && !axs_cachekeeper_app_enabled(states[bundle])) continue;
        if (self.selectedTab == 1 && ![app[@"source"] isEqual:@"user"]) continue;
        if (self.selectedTab == 2 && ![app[@"source"] isEqual:@"troll"]) continue;
        if (self.selectedTab == 3 && ![self.favorites containsObject:bundle]) continue;
        [matches addObject:app];
    }
    [matches sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult order = [a[@"pinyin"] localizedStandardCompare:b[@"pinyin"]];
        return order == NSOrderedSame ? [a[@"id"] compare:b[@"id"]] : order;
    }];
    NSMutableArray *sections = [NSMutableArray new];
    NSMutableDictionary *byLetter = [NSMutableDictionary new];
    NSMutableArray *letters = [NSMutableArray new];
    for (NSDictionary *app in matches) {
        NSString *pinyin = app[@"pinyin"];
        NSString *first = pinyin.length ? [[pinyin substringToIndex:1] uppercaseString] : @"#";
        unichar c = [first characterAtIndex:0];
        if (c < 'A' || c > 'Z') first = @"#";
        NSMutableArray *group = byLetter[first];
        if (!group) { group = [NSMutableArray new]; byLetter[first] = group; [letters addObject:first]; }
        [group addObject:app];
    }
    [letters sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        if ([a isEqual:@"#"]) return NSOrderedDescending;
        if ([b isEqual:@"#"]) return NSOrderedAscending;
        return [a compare:b];
    }];
    for (NSString *letter in letters) [sections addObject:@{@"title":letter, @"apps":[byLetter[letter] copy]}];
    self.sections = sections;

    BOOL active=[batch[@"remaining"] count]>0;
    self.navigationItem.rightBarButtonItem.enabled=!active;
    self.navigationItem.rightBarButtonItem.title=active?[NSString stringWithFormat:@"%@/%@",batch[@"completed"],batch[@"total"]]:@"检测全部";
    [self.table reloadData];
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    if (path.section >= self.sections.count) return;
    NSDictionary *app=self.sections[path.section][@"apps"][path.row];
    CKScanPage *page=[CKScanPage new];page.bundle=app[@"id"];page.appName=app[@"name"];
    [self.navigationController pushViewController:page animated:YES];
}
- (void)changed:(UISwitch *)toggle {
    NSString *bundle=toggle.accessibilityIdentifier;
    NSString *directoryPath=jbroot(@"/var/mobile/Library/CacheKeeper/directories.plist");
    NSMutableDictionary *directories=axs_cachekeeper_edit_configuration(directoryPath);
    NSMutableDictionary *states=axs_cachekeeper_edit_configuration(jbroot(@"/var/mobile/Library/CacheKeeper/appEnabled.plist"));
    if (!directories || !states) { [self axs_cachekeeper_configuration_error]; [self updateBatch]; return; }
    states[bundle]=axs_cachekeeper_app_state(states[bundle],toggle.on);
    if (![states writeToFile:jbroot(@"/var/mobile/Library/CacheKeeper/appEnabled.plist") atomically:YES]) {
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
