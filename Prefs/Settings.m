#import <UIKit/UIKit.h>
#import <Preferences/PSViewController.h>
#import <objc/message.h>
#include <roothide.h>
#import "../AxsCacheKeeperPolicy.h"

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

// 分类 Tab：0 已开启，1 用户应用（App Store），2 巨魔应用（无商店收据），3 收藏应用。
// 系统应用不进缓存管家（加载时直接排除）。
@interface CKSettings : PSViewController <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating, UIContextMenuInteractionDelegate>
@property(nonatomic,strong) UITableView *table;
@property(nonatomic,strong) UISegmentedControl *tabs;
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
@end
@implementation CKSettings
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"缓存管家";
    self.apps = @[];
    self.sections = @[];
    self.favorites = [NSSet set];
    self.iconCache = [NSMutableDictionary new];
    self.selectedTab = 0;
    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = @"搜索应用";
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    CGFloat tabHeight = 46;
    UIView *tabWrap = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, tabHeight)];
    tabWrap.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.tabs = [[UISegmentedControl alloc] initWithItems:@[@"已开启", @"用户应用", @"巨魔应用", @"收藏应用"]];
    self.tabs.frame = CGRectMake(16, 7, self.view.bounds.size.width - 32, 32);
    self.tabs.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.tabs.selectedSegmentIndex = 0;
    [self.tabs addTarget:self action:@selector(tabChanged:) forControlEvents:UIControlEventValueChanged];
    [tabWrap addSubview:self.tabs];
    [self.view addSubview:tabWrap];
    self.table = [[UITableView alloc] initWithFrame:CGRectMake(0, tabHeight, self.view.bounds.size.width, self.view.bounds.size.height - tabHeight) style:UITableViewStyleInsetGrouped];
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.table.dataSource = self; self.table.delegate = self;
    [self.view addSubview:self.table];
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"检测全部" style:UIBarButtonItemStylePlain target:self action:@selector(scanAll)];
}
- (void)tabChanged:(UISegmentedControl *)sender {
    self.selectedTab = sender.selectedSegmentIndex;
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
    [cell addInteraction:[[UIContextMenuInteraction alloc] initWithDelegate:self]];
    return cell;
}
- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location {
    UITableViewCell *cell = (UITableViewCell *)interaction.view;
    NSIndexPath *path = [self.table indexPathForCell:cell];
    if (!path || path.section >= self.sections.count) return nil;
    NSDictionary *app = self.sections[path.section][@"apps"][path.row];
    NSString *bundle = app[@"id"];
    BOOL favorited = [self.favorites containsObject:bundle];
    __weak typeof(self) weak = self;
    UIAction *favorite = [UIAction actionWithTitle:favorited ? @"取消收藏" : @"收藏应用" image:[UIImage systemImageNamed:favorited ? @"star.slash" : @"star"] identifier:nil handler:^(__kindof UIAction *action) { [weak axs_cachekeeper_set_favorite:bundle favorite:!favorited]; }];
    UIAction *launch = [UIAction actionWithTitle:@"启动" image:[UIImage systemImageNamed:@"arrow.up.forward.app"] identifier:nil handler:^(__kindof UIAction *action) { [weak axs_cachekeeper_launch:bundle]; }];
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) { return [UIMenu menuWithTitle:app[@"name"] children:@[favorite, launch]]; }];
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
    [super viewWillAppear:animated];[self axs_cachekeeper_reload_apps];[self updateBatch];
    if (!self.batchTimer) {
        __weak typeof(self) weak=self;
        self.batchTimer=[NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer){[weak updateBatch];}];
    }
}
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated];[self.batchTimer invalidate];self.batchTimer=nil; }
- (void)dealloc { [self.batchTimer invalidate]; }
- (NSString *)axs_cachekeeper_source_for_proxy:(id)proxy bundleURL:(NSURL *)url {
    if (axs_cachekeeper_app_property(proxy,@"appStoreReceiptURL")) return @"user";
    NSString *base = url.path;
    if ([base isKindOfClass:NSString.class] && base.length) {
        NSFileManager *files = NSFileManager.defaultManager;
        if ([files fileExistsAtPath:[base stringByAppendingPathComponent:@"StoreKit/receipt"]] ||
            [files fileExistsAtPath:[base stringByAppendingPathComponent:@"_MASReceipt/receipt"]]) return @"user";
    }
    return @"troll";
}
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
        NSString *type=axs_cachekeeper_app_property(proxy,@"applicationType");
        if ([type isEqual:@"System"]) continue;
        NSURL *url=axs_cachekeeper_app_property(proxy,@"bundleURL");
        NSDictionary *app=axs_cachekeeper_application_entry(axs_cachekeeper_app_property(proxy,@"applicationIdentifier"),
            axs_cachekeeper_app_property(proxy,@"localizedName"),type,url);
        if (!app) continue;
        NSString *name=app[@"name"];
        NSString *pinyin=[name stringByApplyingTransform:NSStringTransformMandarinToLatin reverse:NO] ?: name;
        pinyin=[pinyin stringByApplyingTransform:NSStringTransformStripCombiningMarks reverse:NO] ?: pinyin;
        NSMutableDictionary *entry=[app mutableCopy];
        entry[@"source"]=[self axs_cachekeeper_source_for_proxy:proxy bundleURL:url];
        NSString *version=axs_cachekeeper_app_property(proxy,@"shortVersionString");
        if ([version isKindOfClass:NSString.class] && version.length) entry[@"version"]=version;
        entry[@"pinyin"]=pinyin;
        apps[app[@"id"]]=entry;
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
    NSArray *savedFavorites=[NSArray arrayWithContentsOfFile:jbroot(@"/var/mobile/Library/CacheKeeper/favorites.plist")];
    self.favorites=[NSSet setWithArray:[savedFavorites isKindOfClass:NSArray.class] ? savedFavorites : @[]];
    NSString *query = self.navigationItem.searchController.searchBar.text;
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

    self.scanHistory=[NSDictionary dictionaryWithContentsOfFile:jbroot(@"/var/mobile/Library/CacheKeeper/snapshots.plist")];
    NSDictionary *batch=[NSDictionary dictionaryWithContentsOfFile:jbroot(@"/var/mobile/Library/CacheKeeper/batch.plist")];
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
