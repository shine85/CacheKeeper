#import <UIKit/UIKit.h>
#import <Preferences/PSViewController.h>
#import <objc/message.h>
#include <math.h>
#include <roothide.h>
#import "../AxsCacheKeeperPolicy.h"
#import "../AxsCacheKeeperAppList.h"
#import "../AxsCacheKeeperInstallation.h"
#import "../AxsCacheKeeperPresentation.h"
#import "DiagnosticsPage.h"
#import "SearchInput.h"
#import "SearchDiagnostics.h"

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
@interface CKSettings : PSViewController <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic,strong) UITableView *table;
@property(nonatomic,strong) UISegmentedControl *tabs;
@property(nonatomic,strong) UIView *tabWrap;
@property(nonatomic,strong) AxsCacheKeeperSearchInput *axs_cachekeeper_searchInput;
@property(nonatomic,strong) NSLayoutConstraint *axs_cachekeeper_searchTop;
@property(nonatomic,weak) UINavigationBar *axs_cachekeeper_hostBar;
@property(nonatomic,strong) NSArray<NSDictionary *> *axs_cachekeeper_compactClaims;
@property(nonatomic) BOOL axs_cachekeeper_updatingTitle;
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
@property(nonatomic,strong) NSDictionary *statusSnapshot;
@property(nonatomic,strong) NSDictionary *sourceErrors;
@property(nonatomic,strong) AxsCacheKeeperAppList *axs_cachekeeper_appList;
@property(nonatomic,strong) NSDictionary *axs_cachekeeper_pendingSnapshot;
@property(nonatomic,strong) NSNumber *axs_cachekeeper_snapshotRevision;
@property(nonatomic) NSTimeInterval axs_cachekeeper_lastApplicationsRefresh;
@property(nonatomic) BOOL axs_cachekeeper_visible;
@property(nonatomic) BOOL axs_cachekeeper_menuVisible;
@property(nonatomic) BOOL axs_cachekeeper_renderPending;
@property(nonatomic,strong) AxsCacheKeeperSearchDiagnostics *axs_cachekeeper_searchDiagnostics;
@end
@implementation CKSettings
- (void)loadView {
    // 自有内容根，避免 Preferences 的默认容器布局参与搜索栏命中区域。
    self.view=[[AxsCacheKeeperSearchRootView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.view.backgroundColor=UIColor.systemGroupedBackgroundColor;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"缓存管家";
    self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;
    self.apps = @[];
    self.sections = @[];
    self.favorites = [NSSet set];
    self.iconCache = [NSMutableDictionary new];
    self.selectedTab = 0;
    self.axs_cachekeeper_searchInput=[AxsCacheKeeperSearchInput new];
    __weak typeof(self) inputOwner=self;
    self.axs_cachekeeper_searchInput.axs_cachekeeper_changed_handler=^{ [inputOwner axs_cachekeeper_render]; };
    self.axs_cachekeeper_searchInput.axs_cachekeeper_focus_failed=^{
        typeof(self) owner=inputOwner;if (!owner || owner.presentedViewController) return;
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"搜索暂时无法编辑" message:@"输入控件未获得焦点。请退出此页后重新进入；若重复发生，请反馈是否能看到取消按钮。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [owner presentViewController:alert animated:YES completion:nil];
    };
    [self.view addSubview:self.axs_cachekeeper_searchInput];
    self.tabWrap = [[UIView alloc] initWithFrame:CGRectZero];
    self.tabWrap.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.tabs = [[UISegmentedControl alloc] initWithItems:@[@"已开启", @"用户应用", @"巨魔应用", @"收藏应用"]];
    self.tabs.selectedSegmentIndex = 0;
    [self.tabs addTarget:self action:@selector(tabChanged:) forControlEvents:UIControlEventValueChanged];
    [self.tabWrap addSubview:self.tabs];
    [self.view addSubview:self.tabWrap];
    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.table.keyboardDismissMode=UIScrollViewKeyboardDismissModeOnDrag;
    self.table.rowHeight=UITableViewAutomaticDimension;
    self.table.estimatedRowHeight=72;
    self.table.sectionHeaderTopPadding=0;
    self.table.contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentNever;
    self.table.dataSource = self; self.table.delegate = self;
    [self.view addSubview:self.table];
    self.axs_cachekeeper_searchDiagnostics=[[AxsCacheKeeperSearchDiagnostics alloc] initWithField:self.axs_cachekeeper_searchInput.axs_cachekeeper_field input:self.axs_cachekeeper_searchInput root:self.view table:self.table owner:self];
    self.axs_cachekeeper_searchInput.axs_cachekeeper_diagnostics=self.axs_cachekeeper_searchDiagnostics;
    ((AxsCacheKeeperSearchRootView *)self.view).axs_cachekeeper_diagnostics=self.axs_cachekeeper_searchDiagnostics;
    [self.axs_cachekeeper_searchDiagnostics axs_cachekeeper_record:AxsCacheKeeperSearchEventLoaded];
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
    for (UIView *view in @[self.axs_cachekeeper_searchInput,self.tabWrap,self.tabs,self.table]) view.translatesAutoresizingMaskIntoConstraints=NO;
    UILayoutGuide *safe=self.view.safeAreaLayoutGuide;
    self.axs_cachekeeper_searchTop=[self.axs_cachekeeper_searchInput.topAnchor constraintEqualToAnchor:safe.topAnchor];
    [NSLayoutConstraint activateConstraints:@[
        self.axs_cachekeeper_searchTop,
        [self.axs_cachekeeper_searchInput.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.axs_cachekeeper_searchInput.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.axs_cachekeeper_searchInput.heightAnchor constraintGreaterThanOrEqualToConstant:44],
        [self.tabWrap.topAnchor constraintEqualToAnchor:self.axs_cachekeeper_searchInput.bottomAnchor],
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
    self.appsError=@"正在读取应用列表…";
    NSMutableDictionary *metadataCache=[NSMutableDictionary new];
    __weak typeof(self) weak=self;
    self.axs_cachekeeper_appList=[[AxsCacheKeeperAppList alloc] initWithFolder:jbroot(@"/var/mobile/Library/CacheKeeper") applicationsProvider:^NSArray *(NSError **error) {
        return axs_cachekeeper_installed_applications(metadataCache,error);
    } completion:^(NSDictionary *snapshot) {
        typeof(self) strong=weak;
        if (!strong || !strong.axs_cachekeeper_visible || UIApplication.sharedApplication.applicationState!=UIApplicationStateActive) return;
        strong.axs_cachekeeper_pendingSnapshot=snapshot;
        [strong axs_cachekeeper_apply_pending_snapshot];
    }];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(axs_cachekeeper_application_active:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(axs_cachekeeper_application_inactive:) name:UIApplicationWillResignActiveNotification object:nil];
}
- (void)axs_cachekeeper_diagnostics {
    // Freeze before our own resign/push so navigation does not masquerade as spontaneous focus loss.
    NSDictionary *snapshot=[self.axs_cachekeeper_searchDiagnostics axs_cachekeeper_freeze:AxsCacheKeeperSearchEventDiagnostics];
    [self.axs_cachekeeper_searchInput axs_cachekeeper_dismiss_keyboard];
    [self.navigationController pushViewController:[[AxsCacheKeeperDiagnosticsPage alloc] initWithSearchSnapshot:snapshot] animated:YES];
}
- (void)tabChanged:(UISegmentedControl *)sender {
    self.selectedTab = sender.selectedSegmentIndex;
    [self axs_cachekeeper_render];
    [self.table setContentOffset:CGPointZero animated:NO];
}
- (void)swipeTab:(UISwipeGestureRecognizer *)gesture {
    NSInteger next=(self.selectedTab + (gesture.direction==UISwipeGestureRecognizerDirectionLeft ? 1 : -1) + 4) % 4;
    self.selectedTab=next;
    self.tabs.selectedSegmentIndex=next;
    [self axs_cachekeeper_render];
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
- (CGFloat)tableView:(UITableView *)table heightForHeaderInSection:(NSInteger)section {
    (void)table;(void)section;
    return MAX(28,[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote].lineHeight+12);
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
        if (self.axs_cachekeeper_searchInput.axs_cachekeeper_text.length) return @"没有匹配的应用，可换个名称或包名搜索。";
        if (self.selectedTab == 0) return @"暂无已开启缓存控制的 APP，在「用户应用」或「巨魔应用」里打开开关即可。";
        if (self.selectedTab == 3) return @"暂无收藏，长按应用选择「收藏应用」。";
        return @"此分类下没有 APP。";
    }
    return [NSString stringWithFormat:@"当前 %lu 个应用 · 点击查看详情\n仅对已开启的应用执行缓存控制。", (unsigned long)shown];
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    NSDictionary *app = self.sections[path.section][@"apps"][path.row];
    UITableViewCell *cell=[table dequeueReusableCellWithIdentifier:@"AxsCacheKeeperAppCell"];
    if (!cell) cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"AxsCacheKeeperAppCell"];
    UIListContentConfiguration *content=[UIListContentConfiguration subtitleCellConfiguration];
    content.image=[self axs_cachekeeper_icon:app];
    content.imageProperties.maximumSize=CGSizeMake(36,36);
    content.imageProperties.reservedLayoutSize=CGSizeMake(36,36);
    content.imageProperties.cornerRadius=8;
    content.imageToTextPadding=12;
    content.directionalLayoutMargins=NSDirectionalEdgeInsetsMake(10,16,10,16);
    BOOL starred = [self.favorites containsObject:app[@"id"]];
    content.text=starred ? [app[@"name"] stringByAppendingString:@" ★"] : app[@"name"];
    content.textProperties.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    content.textProperties.numberOfLines=0;
    content.secondaryTextProperties.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    content.secondaryTextProperties.color=UIColor.secondaryLabelColor;
    content.secondaryTextProperties.numberOfLines=0;
    NSDictionary *status=self.statusSnapshot[app[@"id"]];
    NSString *bundleLine = app[@"version"] ? [NSString stringWithFormat:@"%@ · %@", app[@"id"], app[@"version"]] : app[@"id"];
    UISwitch *toggle = [UISwitch new]; toggle.accessibilityIdentifier = app[@"id"];
    NSDictionary *directories=self.directoriesSnapshot;
    NSDictionary *states=self.statesSnapshot;
    toggle.on=axs_cachekeeper_app_enabled(states[app[@"id"]]);
    toggle.enabled=!self.sourceErrors[@"appEnabled.plist"] && !self.sourceErrors[@"directories.plist"];
    NSString *record=toggle.on ? axs_cachekeeper_presentation_app_record(status) : nil;
    if (toggle.on && !status && !axs_cachekeeper_selected_paths(directories,states,app[@"id"]).count && !axs_cachekeeper_auto_discover(states[app[@"id"]])) record=@"未选清理目录 · 点击设置";
    if (!toggle.enabled) record=@"配置读取失败 · 暂不可修改";
    else if (self.sourceErrors[[NSString stringWithFormat:@"Status/%@.auto.plist",app[@"id"]]]) record=@"清理记录读取失败";
    content.secondaryText=record ? [bundleLine stringByAppendingFormat:@"\n%@",record] : bundleLine;
    cell.contentConfiguration=content;
    cell.accessibilityHint=@"轻点查看应用详情；右侧开关控制是否启用";
    toggle.accessibilityLabel=[app[@"name"] stringByAppendingString:@"缓存控制"];
    [toggle addTarget:self action:@selector(changed:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle; cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}
// 长按菜单由 UITableView 代理方法提供（iOS 13+ 标准做法），不要给每个 cell 挂 UIContextMenuInteraction：
// 列表每秒刷新会重建 cell，挂在 cell 上的手势随 cell 一起被销毁，长按永远等不到菜单（#62 真机：长按无菜单）。
- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    (void)tableView; (void)point;
    if (indexPath.section >= self.sections.count || indexPath.row >= [self.sections[indexPath.section][@"apps"] count]) return nil;
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
        [self axs_cachekeeper_apply_pending_snapshot];
    };
    if (animator) [animator addCompletion:apply]; else apply();
}
- (void)axs_cachekeeper_set_favorite:(NSString *)bundle favorite:(BOOL)favorite {
    NSString *path = jbroot(@"/var/mobile/Library/CacheKeeper/favorites.plist");
    NSError *readError=nil;
    NSArray *existing=[AxsCacheKeeperAppList axs_cachekeeper_read_source_at_path:path name:@"favorites.plist" error:&readError];
    if (readError) {
        [self axs_cachekeeper_configuration_error];[self axs_cachekeeper_refresh_after_write];return;
    }
    NSMutableArray *saved = existing ? [existing mutableCopy] : [NSMutableArray new];
    if (favorite) { if (![saved containsObject:bundle]) [saved addObject:bundle]; }
    else [saved removeObject:bundle];
    if (![saved writeToFile:path atomically:YES]) {
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"保存失败" message:@"收藏未保存，请检查安装与目录权限。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    } else self.favorites=[NSSet setWithArray:saved];
    [self axs_cachekeeper_refresh_after_write];
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
- (CGFloat)axs_cachekeeper_search_inset_for_bar:(UINavigationBar *)bar window:(UIWindow *)window safe:(CGRect)safe {
    UIView *root=self.view;
    if (!bar || bar.window!=window || [bar isDescendantOfView:root]) return 0;
    CGRect rect=[bar convertRect:bar.bounds toView:root];
    if (!isfinite(rect.origin.x) || !isfinite(rect.origin.y) ||
        !isfinite(rect.size.width) || !isfinite(rect.size.height)) return 0;
    for (UIView *ancestor=bar;ancestor;ancestor=ancestor.superview) {
        if (ancestor.hidden || ancestor.alpha<=0.01 || !ancestor.userInteractionEnabled) return 0;
        if (ancestor!=bar && ancestor.clipsToBounds)
            rect=CGRectIntersection(rect,[ancestor convertRect:ancestor.bounds toView:root]);
        if (ancestor==window) break;
    }
    if (CGRectIsEmpty(rect) || CGRectIsNull(rect) ||
        CGRectGetMaxX(rect)<=CGRectGetMinX(safe) || CGRectGetMinX(rect)>=CGRectGetMaxX(safe) ||
        CGRectGetMinY(rect)>CGRectGetMinY(safe)+1.0/window.screen.scale) return 0;
    return MAX(0,CGRectGetMaxY(rect)-CGRectGetMinY(safe));
}
- (NSArray<NSDictionary *> *)axs_cachekeeper_compact_candidates {
    // Every ancestor navigation controller whose current top contains this page owns a title
    // that can cover the search. 125.1 device proved the innermost match is not always the bar
    // the geometry probe measures (the harness models one outer bar; the device has more), so
    // collect all of them instead of stopping at the first. An unrelated overlay bar remains
    // untouched and is handled by the geometry clearance below.
    NSMutableArray<NSDictionary *> *candidates=[NSMutableArray new];
    UIViewController *child=self;
    for (UIViewController *parent=child.parentViewController;parent;child=parent,parent=parent.parentViewController) {
        if (![parent isKindOfClass:UINavigationController.class]) continue;
        UINavigationController *navigation=(UINavigationController *)parent;
        UINavigationBar *bar=navigation.navigationBar;
        if (navigation.topViewController!=child || bar.topItem!=child.navigationItem ||
            child==self || bar.hidden || bar.alpha<=0.01 || bar.window!=self.view.window) continue;
        [candidates addObject:@{@"navigation":navigation,@"item":child.navigationItem}];
    }
    return [candidates copy];
}
- (void)axs_cachekeeper_restore_compact_title {
    NSArray<NSDictionary *> *claims=self.axs_cachekeeper_compactClaims;
    self.axs_cachekeeper_compactClaims=nil;
    for (NSDictionary *claim in claims) {
        UINavigationItem *item=claim[@"item"];
        if (item.largeTitleDisplayMode==UINavigationItemLargeTitleDisplayModeNever)
            item.largeTitleDisplayMode=[claim[@"previousMode"] integerValue];
        UINavigationBar *bar=claim[@"bar"];
        if (bar && !bar.prefersLargeTitles)
            bar.prefersLargeTitles=[claim[@"previousPrefersLargeTitles"] boolValue];
    }
    // Let the hosts grow their bars back with the transition; never force them synchronously here.
    for (NSDictionary *candidate in [self axs_cachekeeper_compact_candidates])
        [[candidate[@"navigation"] view] setNeedsLayout];
}
- (void)axs_cachekeeper_update_compact_title {
    if (!self.axs_cachekeeper_visible || !self.view.window || self.axs_cachekeeper_updatingTitle) return;
    NSArray<NSDictionary *> *candidates=[self axs_cachekeeper_compact_candidates];
    NSMutableArray *items=[NSMutableArray new];
    for (NSDictionary *candidate in candidates) [items addObject:candidate[@"item"]];
    NSArray *claimed=[self.axs_cachekeeper_compactClaims valueForKey:@"item"] ?: @[];
    if ([items isEqualToArray:claimed]) return;
    self.axs_cachekeeper_updatingTitle=YES;
    [self axs_cachekeeper_restore_compact_title];
    NSMutableArray<NSDictionary *> *claims=[NSMutableArray new];
    for (NSDictionary *candidate in candidates) {
        UINavigationItem *item=candidate[@"item"];
        UINavigationBar *bar=[candidate[@"navigation"] navigationBar];
        // Save before the setters: UIKit may synchronously lay out the container.
        [claims addObject:@{@"item":item,@"previousMode":@(item.largeTitleDisplayMode),
            @"bar":bar,@"previousPrefersLargeTitles":@(bar.prefersLargeTitles)}];
        item.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;
        // 126.1 device: the mode alone does not shrink the bar — its frame stayed 91pt for
        // seconds with the mode at Never, and forcing layout never re-applied the height.
        // Switching the bar off large titles is the setter that makes the host recompute the
        // frame; it is restored on release, like the mode.
        bar.prefersLargeTitles=NO;
        // Hint the hosts to shrink their bars; the synchronous force runs in viewDidAppear,
        // after the push transition, so the animation is not disturbed.
        [[candidate[@"navigation"] view] setNeedsLayout];
    }
    self.axs_cachekeeper_compactClaims=[claims copy];
    self.axs_cachekeeper_updatingTitle=NO;
}
- (void)axs_cachekeeper_layout_compact_navigation {
    // The mode change can land after the push transition captured the bar's height, leaving a
    // stale expanded frame (123.1 device: the bar still measured ~91pt, so the geometry
    // clearance held ~49pt and the search box sat ~58pt below the bar). Force every claimed
    // host to lay out now that the transition is over, then re-probe so the inset drops to
    // the true bar.
    BOOL forced=NO;
    for (NSDictionary *candidate in [self axs_cachekeeper_compact_candidates]) {
        UINavigationController *navigation=candidate[@"navigation"];
        UINavigationBar *bar=navigation.navigationBar;
        if (bar.bounds.size.height<=44.5) continue;
        [navigation.view setNeedsLayout];[navigation.view layoutIfNeeded];
        // The layout pass does not always re-apply the bar height (126.1 device: the frame
        // stayed 91pt for seconds with the mode at Never). Ask the bar for its own fitting
        // size, which is compact while the mode is Never, and take it.
        if (bar.bounds.size.height>44.5) [bar sizeToFit];
        forced=YES;
    }
    if (forced) [self axs_cachekeeper_update_search_top];
}
- (BOOL)axs_cachekeeper_update_search_top {
    if (!self.isViewLoaded || !self.axs_cachekeeper_visible || !self.axs_cachekeeper_searchTop) return NO;
    UIView *root=self.view;UIWindow *window=root.window;
    if (!window) { self.axs_cachekeeper_hostBar=nil;return NO; }
    [self axs_cachekeeper_update_compact_title];
    CGRect safe=root.safeAreaLayoutGuide.layoutFrame;
    if (CGRectIsEmpty(safe) || !isfinite(safe.origin.x) || !isfinite(safe.origin.y) ||
        !isfinite(safe.size.width) || !isfinite(safe.size.height)) return NO;
    CGFloat pixel=1.0/window.screen.scale;
    // Probe the original safe edge, never the shifted field: the latter oscillates after clearing the bar.
    CGFloat xs[]={CGRectGetMinX(safe)+pixel,CGRectGetMidX(safe),CGRectGetMaxX(safe)-pixel};
    UINavigationBar *observed=nil;CGFloat inset=0;
    for (NSUInteger i=0;i<3;i++) {
        CGPoint point=[root convertPoint:CGPointMake(xs[i],CGRectGetMinY(safe)+pixel) toView:window];
        for (UIView *hit=[window hitTest:point withEvent:nil];hit;hit=hit.superview) {
            if (![hit isKindOfClass:UINavigationBar.class]) continue;
            CGFloat candidate=[self axs_cachekeeper_search_inset_for_bar:(UINavigationBar *)hit window:window safe:safe];
            if (candidate>inset) { observed=(UINavigationBar *)hit;inset=candidate; }
        }
    }
    // A temporary menu may cover all probes; revalidate the actual bar instead of retaining an old height.
    if (!observed) {
        inset=[self axs_cachekeeper_search_inset_for_bar:self.axs_cachekeeper_hostBar window:window safe:safe];
        if (inset>0) observed=self.axs_cachekeeper_hostBar;
    }
    self.axs_cachekeeper_hostBar=observed;
    if (fabs(self.axs_cachekeeper_searchTop.constant-inset)<pixel/2) return NO;
    self.axs_cachekeeper_searchTop.constant=inset;
    [root setNeedsLayout];return YES;
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self axs_cachekeeper_update_search_top];
}
- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    [self axs_cachekeeper_update_search_top];
}
- (void)viewWillAppear:(BOOL)animated {
    self.axs_cachekeeper_hostBar=nil;
    [self.axs_cachekeeper_searchDiagnostics axs_cachekeeper_begin];
    [self.axs_cachekeeper_searchDiagnostics axs_cachekeeper_record:AxsCacheKeeperSearchEventWillAppear];
    [super viewWillAppear:animated];
    self.axs_cachekeeper_visible=YES;self.axs_cachekeeper_menuVisible=NO;
    [self axs_cachekeeper_update_search_top];
    [self axs_cachekeeper_application_active:nil];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self axs_cachekeeper_update_search_top];[self.view layoutIfNeeded];
    [self axs_cachekeeper_layout_compact_navigation];
    [self.axs_cachekeeper_searchDiagnostics axs_cachekeeper_record:AxsCacheKeeperSearchEventDidAppear];
}
- (void)viewWillDisappear:(BOOL)animated {
    [self.axs_cachekeeper_searchDiagnostics axs_cachekeeper_freeze:AxsCacheKeeperSearchEventWillDisappear];
    self.axs_cachekeeper_visible=NO;self.axs_cachekeeper_menuVisible=NO;
    [self axs_cachekeeper_restore_compact_title];
    [super viewWillDisappear:animated];
    self.axs_cachekeeper_hostBar=nil;
    [self.axs_cachekeeper_searchInput axs_cachekeeper_dismiss_keyboard];
    [self axs_cachekeeper_application_inactive:nil];
}
- (void)dealloc { [self.batchTimer invalidate];[NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.axs_cachekeeper_searchDiagnostics axs_cachekeeper_clear];
    self.axs_cachekeeper_searchTop.constant=0;
}
- (void)axs_cachekeeper_application_active:(NSNotification *)notification {
    (void)notification;
    if (!self.axs_cachekeeper_visible || UIApplication.sharedApplication.applicationState!=UIApplicationStateActive) return;
    self.axs_cachekeeper_lastApplicationsRefresh=NSProcessInfo.processInfo.systemUptime;
    [self.axs_cachekeeper_appList requestRefreshApplications:YES];
    if (!self.batchTimer) {
        __weak typeof(self) weak=self;
        self.batchTimer=[NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer){ (void)timer;[weak updateBatch]; }];
    }
}
- (void)axs_cachekeeper_application_inactive:(NSNotification *)notification {
    (void)notification;
    [self.batchTimer invalidate];self.batchTimer=nil;
    [self.axs_cachekeeper_appList invalidate];
    self.axs_cachekeeper_pendingSnapshot=nil;
}
- (void)scanAll {
    NSString *path=jbroot(@"/var/mobile/Library/CacheKeeper/batch.plist");
    NSError *readError=nil;
    NSDictionary *existing=[AxsCacheKeeperAppList axs_cachekeeper_read_source_at_path:path name:@"batch.plist" error:&readError];
    if (readError) {
        [self axs_cachekeeper_configuration_error];[self axs_cachekeeper_refresh_after_write];return;
    }
    if ([existing[@"remaining"] count] && ![existing[@"error"] length]) return;
    NSMutableArray *bundles=[NSMutableArray array];
    for (NSDictionary *app in self.apps) [bundles addObject:app[@"id"]];
    if (!bundles.count) return;
    NSDictionary *request=@{@"token":NSUUID.UUID.UUIDString,@"remaining":bundles,@"total":@(bundles.count),@"completed":@0};
    if (![request writeToFile:path atomically:YES]) {
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"无法开始检测" message:@"请检查插件安装后重试。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    } else self.batchSnapshot=request;
    [self axs_cachekeeper_refresh_after_write];
}
- (void)updateBatch {
    if (!self.axs_cachekeeper_visible || UIApplication.sharedApplication.applicationState!=UIApplicationStateActive) return;
    // The outer Settings navigation bar can expand without laying out this inner controller.
    // 124.1 device: the bar re-expanded after appearance (inset 0 -> 47pt between didAppear
    // and the first 1s sample), so a viewDidAppear-only force cannot catch it. Enforce the
    // compact claim on every tick; the helper returns early while the bar is compact.
    [self axs_cachekeeper_layout_compact_navigation];
    [self axs_cachekeeper_update_search_top];[self.view layoutIfNeeded];
    [self.axs_cachekeeper_searchDiagnostics axs_cachekeeper_sample];
    // Poll only cached source metadata each second. Installed-app metadata has a separate cadence.
    NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
    BOOL apps=now-self.axs_cachekeeper_lastApplicationsRefresh>=30;
    if (apps) self.axs_cachekeeper_lastApplicationsRefresh=now;
    [self.axs_cachekeeper_appList requestRefreshApplications:apps];
    [self axs_cachekeeper_apply_pending_snapshot];
}
- (void)axs_cachekeeper_refresh_after_write {
    // A pre-write read must never undo a switch/favorite change or a newly created batch request.
    [self.axs_cachekeeper_appList invalidate];self.axs_cachekeeper_pendingSnapshot=nil;
    [self axs_cachekeeper_render];
    if (self.axs_cachekeeper_visible) [self.axs_cachekeeper_appList requestRefreshApplications:NO];
}
- (BOOL)axs_cachekeeper_can_render {
    return self.axs_cachekeeper_visible && !self.axs_cachekeeper_menuVisible &&
        !self.table.tracking && !self.table.dragging && !self.table.decelerating;
}
- (void)axs_cachekeeper_apply_pending_snapshot {
    if (![self axs_cachekeeper_can_render]) return;
    NSDictionary *snapshot=self.axs_cachekeeper_pendingSnapshot;self.axs_cachekeeper_pendingSnapshot=nil;
    if (snapshot && ![snapshot[@"revision"] isEqual:self.axs_cachekeeper_snapshotRevision]) {
        self.axs_cachekeeper_snapshotRevision=snapshot[@"revision"];
        self.apps=snapshot[@"apps"];self.statesSnapshot=snapshot[@"states"];
        self.directoriesSnapshot=snapshot[@"directories"];self.favorites=[NSSet setWithArray:snapshot[@"favorites"]];
        self.scanHistory=snapshot[@"history"];self.batchSnapshot=snapshot[@"batch"];
        self.statusSnapshot=snapshot[@"statuses"];self.sourceErrors=snapshot[@"errors"];
        NSMutableSet *identifiers=[NSMutableSet new];
        for (NSDictionary *app in self.apps) [identifiers addObject:app[@"id"]];
        for (NSString *bundle in self.iconCache.allKeys) if (![identifiers containsObject:bundle]) [self.iconCache removeObjectForKey:bundle];
        NSMutableOrderedSet *failed=[NSMutableOrderedSet new];
        NSDictionary *names=@{@"applications":@"系统应用列表",@"appEnabled.plist":@"开关配置",@"directories.plist":@"目录配置",
            @"favorites.plist":@"收藏",@"snapshots.plist":@"检测记录",@"batch.plist":@"检测进度"};
        for (NSString *name in [self.sourceErrors.allKeys sortedArrayUsingSelector:@selector(compare:)])
            [failed addObject:names[name] ?: @"清理回执"];
        self.appsError=failed.count ? [NSString stringWithFormat:@"%@读取失败，保留上次可读结果；尚无旧记录的项目暂不显示。",[failed.array componentsJoinedByString:@"、"]] : nil;
        if ([self.batchSnapshot[@"error"] length]) self.appsError=[NSString stringWithFormat:@"%@\n批量检测已停止：%@。修复后可点重试。",self.appsError ?: @"",self.batchSnapshot[@"error"]];
        self.axs_cachekeeper_renderPending=YES;
    }
    if (self.axs_cachekeeper_renderPending) [self axs_cachekeeper_render];
}
- (void)axs_cachekeeper_render {
    if (![self axs_cachekeeper_can_render]) { self.axs_cachekeeper_renderPending=YES;return; }
    self.axs_cachekeeper_renderPending=NO;
    self.sections=[AxsCacheKeeperAppList sectionsForApps:self.apps states:self.statesSnapshot favorites:self.favorites tab:self.selectedTab query:self.axs_cachekeeper_searchInput.axs_cachekeeper_text];
    BOOL stopped=[self.batchSnapshot[@"error"] length]>0;
    BOOL active=[self.batchSnapshot[@"remaining"] count]>0 && !stopped;
    self.navigationItem.rightBarButtonItem.enabled=!active && self.apps.count>0 && !self.sourceErrors[@"batch.plist"];
    self.navigationItem.rightBarButtonItem.title=active ? [NSString stringWithFormat:@"%@/%@",self.batchSnapshot[@"completed"],self.batchSnapshot[@"total"]] : stopped ? @"重试检测" : @"检测全部";
    [self.table reloadData];
}
- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    (void)scrollView;if (!decelerate) [self axs_cachekeeper_apply_pending_snapshot];
}
- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView { (void)scrollView;[self axs_cachekeeper_apply_pending_snapshot]; }
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    if (path.section >= self.sections.count || path.row >= [self.sections[path.section][@"apps"] count]) return;
    NSDictionary *app=self.sections[path.section][@"apps"][path.row];
    CKScanPage *page=[CKScanPage new];page.bundle=app[@"id"];page.appName=app[@"name"];
    [self.navigationController pushViewController:page animated:YES];
}
- (void)changed:(UISwitch *)toggle {
    NSString *bundle=toggle.accessibilityIdentifier;
    NSString *directoryPath=jbroot(@"/var/mobile/Library/CacheKeeper/directories.plist");
    NSError *readError=nil;
    [AxsCacheKeeperAppList axs_cachekeeper_read_source_at_path:directoryPath name:@"directories.plist" error:&readError];
    if (readError) { [self axs_cachekeeper_configuration_error];[self axs_cachekeeper_refresh_after_write];return; }
    NSDictionary *savedStates=[AxsCacheKeeperAppList axs_cachekeeper_read_source_at_path:jbroot(@"/var/mobile/Library/CacheKeeper/appEnabled.plist") name:@"appEnabled.plist" error:&readError];
    if (readError) { [self axs_cachekeeper_configuration_error];[self axs_cachekeeper_refresh_after_write];return; }
    NSMutableDictionary *states=savedStates ? [savedStates mutableCopy] : [NSMutableDictionary new];
    states[bundle]=axs_cachekeeper_app_state(states[bundle],toggle.on);
    if (![states writeToFile:jbroot(@"/var/mobile/Library/CacheKeeper/appEnabled.plist") atomically:YES]) {
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"保存失败" message:@"缓存控制设置未完整保存，请检查安装与目录权限。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    } else { self.statesSnapshot=[states copy];axs_cachekeeper_notify_preferences(); }
    [self axs_cachekeeper_refresh_after_write];
}
- (void)axs_cachekeeper_configuration_error {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"配置不可读" message:@"原配置存在但读取失败，已停止保存以保护其他 APP 的设置。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
