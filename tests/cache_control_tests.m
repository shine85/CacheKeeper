#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <unistd.h>
#import "../AxsCacheKeeperPolicy.h"
#import "../AxsCacheKeeperSweep.h"
#import "../AxsCacheKeeperNetworkCache.h"
#import "../AxsCacheKeeperDirectories.h"
#import "../AxsCacheKeeperSelection.h"
#import "../AxsCacheKeeperFilza.h"
#import <objc/runtime.h>

static void require(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static void writeFile(NSString *path) {
    require([@"cache payload" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil], @"创建测试文件");
}
static void writeMedia(NSString *path) {
    const unsigned char image[]={0x89,'P','N','G',13,10,26,10,0,0,0,0};
    require([[NSData dataWithBytes:image length:sizeof(image)] writeToFile:path atomically:YES], @"创建可识别的缓存文件");
}

@interface AxsTestOpenConfiguration : NSObject
@property(nonatomic,copy) NSDictionary *frontBoardOptions;
@end
@implementation AxsTestOpenConfiguration
@end
@interface AxsTestWorkspace : NSObject
@property(nonatomic,copy) NSString *expectedPath;
- (void)openApplicationWithBundleIdentifier:(NSString *)bundle usingConfiguration:(AxsTestOpenConfiguration *)config completionHandler:(void (^)(BOOL,NSError *))completion;
@end
@implementation AxsTestWorkspace
- (void)openApplicationWithBundleIdentifier:(NSString *)bundle usingConfiguration:(AxsTestOpenConfiguration *)config completionHandler:(void (^)(BOOL,NSError *))completion {
    NSURL *url=config.frontBoardOptions[@"test-payload"];
    BOOL accepted=[bundle isEqual:@"com.tigisoftware.Filza"] && url.isFileURL && [url.path isEqual:self.expectedPath];
    completion(accepted,nil);
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        require(argc == 2, @"需要传入项目 tmp 内的测试目录");
        NSString *fixture = [NSURL fileURLWithPath:@(argv[1])].URLByResolvingSymlinksInPath.path;
        NSFileManager *fm = NSFileManager.defaultManager;
        require(![fm fileExistsAtPath:fixture], @"测试目录必须是新目录");
        require([fm createDirectoryAtPath:fixture withIntermediateDirectories:YES attributes:nil error:nil], @"创建测试目录");
        NSString *bundle = @"test.cache.app";
        NSDictionary *selection = @{bundle:@[@"Library/Caches/a", @"Library/Caches", @"Library/Caches/a",
            @"Library/Application Support", @"Library/Caches/../Preferences", @"Library/CachesOther"]};
        require([axs_cachekeeper_selected_paths(selection, @{bundle:@YES}, bundle) isEqual:@[@"Library/Caches"]], @"过滤保护目录并去掉父子重复选择");
        require(!axs_cachekeeper_selected_paths(selection, @{bundle:@NO}, bundle).count, @"关闭总开关禁止处理");
        require(!axs_cachekeeper_selected_paths(selection, @{}, bundle).count, @"只有目录选择、没有明确总开关时必须关闭");
        require(!axs_cachekeeper_selected_paths(selection, nil, bundle).count, @"总开关配置文件缺失时必须关闭");
        require(!axs_cachekeeper_app_enabled(nil) && !axs_cachekeeper_app_enabled(@{}), @"新 APP 与损坏状态默认关闭");
        NSDictionary *explicitOn=@{@"enabled":@YES,@"mode":@"auto"};
        require(axs_cachekeeper_app_enabled(explicitOn) && !axs_cachekeeper_selected_paths(@{bundle:@[]},@{bundle:explicitOn},bundle).count, @"取消全部目录不伪装成总开关关闭；明确开启与待选目录分别显示");
        require(!axs_cachekeeper_app_enabled(axs_cachekeeper_app_state(nil,NO)), @"仅设置模式不能从缺省状态开启 APP");
        require(!axs_cachekeeper_url_cache_enabled(axs_cachekeeper_app_state(nil,YES)), @"新 APP 网络缓存选项默认关闭");
        require(axs_cachekeeper_url_cache_enabled(explicitOn), @"现有已开启自动模式保持原有网络行为");
        NSDictionary *networkOff=@{@"enabled":@YES,@"mode":@"auto",@"urlCache":@NO};
        require(!axs_cachekeeper_should_prevent(networkOff) && axs_cachekeeper_wants_cleanup(networkOff), @"关闭独立网络开关不关闭自动清理");
        require(!axs_cachekeeper_url_cache_enabled(axs_cachekeeper_app_state(networkOff,NO)), @"修改总开关保留网络选项");
        require(!axs_cachekeeper_activation_paths(nil).count &&
            !axs_cachekeeper_activation_paths(@[]).count, @"新 APP 不默认选择缓存目录，空选择也保持为空");
        require(!axs_cachekeeper_selected_paths(@{@"com.tencent.xin":@[@"Library/Caches"]}, @{}, @"com.tencent.xin").count, @"未开启微信不得因残留目录记录被清理");
        require([axs_cachekeeper_selected_paths(selection, @{bundle:@{@"enabled":@YES,@"restrict":@NO}}, bundle) count] == 1, @"关闭限写不能关闭自动清理");
        require(!axs_cachekeeper_wants_restriction(@{@"enabled":@YES,@"restrict":@NO}), @"独立限写开关");
        require([axs_cachekeeper_app_state(@{@"enabled":@YES,@"restrict":@NO}, NO)[@"mode"] isEqual:@"clean"], @"总开关修改保留模式并兼容旧配置");
        require(!axs_cachekeeper_wants_cleanup(@{@"mode":@"prevent"}), @"只禁止不能删除文件");
        require([axs_cachekeeper_parent_paths(@[@"tmp/a/b",@"tmp",@"tmp/a",@"Library/Caches/video",@"Library/Caches"]) isEqual:@[@"Library/Caches",@"tmp"]], @"父目录优先忽略所有后代");
        for (NSString *protectedPath in @[@"tmp/login/avatar.jpg",@"tmp/WebKit/cache.tmp",@"Library/Caches/Cache.db",@"Library/Caches/Cookies/file.tmp",@"Library/Preferences"]) {
            require(!axs_cachekeeper_cache_path(protectedPath), @"受保护目录不可纳入清理");
        }
        struct stat ageInfo = {0};
        ageInfo.st_birthtimespec.tv_sec=100;ageInfo.st_mtimespec.tv_sec=100;ageInfo.st_ctimespec.tv_sec=100;
        require(!axs_cachekeeper_old_enough(ageInfo,159) && axs_cachekeeper_old_enough(ageInfo,160), @"60 秒边界");
        ageInfo.st_mtimespec.tv_sec=155;
        require(!axs_cachekeeper_old_enough(ageInfo,160), @"已有文件刚追加也必须保留");
        require(!axs_cachekeeper_selected_paths(@{}, @{}, bundle).count, @"未选中 APP 不处理");
        require(axs_cachekeeper_can_clean(selection, @{bundle:@YES}, bundle), @"明确开启的 APP 可以清理");
        require(!axs_cachekeeper_can_clean(selection, @{}, bundle) &&
            !axs_cachekeeper_can_clean(selection, @{bundle:@{@"enabled":@YES,@"mode":@"prevent"}}, bundle), @"快捷操作也不能绕过开启状态或只禁止模式");
        NSDictionary *appRows=@{@"system":@{@"bundle":@"com.apple.mobilesafari",@"name":@"Safari"},
            @"wechat":@{@"bundle":@"com.tencent.xin",@"name":@"微信"}};
        require(axs_cachekeeper_application_entry(appRows[@"system"][@"bundle"],@"Safari",@"System",[NSURL fileURLWithPath:@"/Applications/MobileSafari.app"]) != nil, @"已安装系统 APP 也列出");
        require(axs_cachekeeper_application_entry(appRows[@"wechat"][@"bundle"],@"微信",@"User",nil) != nil, @"第三方 APP 不按名称排除");
        require(!axs_cachekeeper_application_entry(@"service",@"服务",@"Plugin",[NSURL fileURLWithPath:@"/Plugins/test.appex"]), @"扩展服务不冒充已安装 APP");
        NSString *configFile=[fixture stringByAppendingPathComponent:@"appEnabled.plist"];
        require([@"broken configuration" writeToFile:configFile atomically:YES encoding:NSUTF8StringEncoding error:nil], @"配置损坏夹具");
        require(!axs_cachekeeper_edit_configuration(configFile) && [[NSString stringWithContentsOfFile:configFile encoding:NSUTF8StringEncoding error:nil] isEqual:@"broken configuration"], @"拒绝覆盖损坏的既有配置");
        require(axs_cachekeeper_edit_configuration([fixture stringByAppendingPathComponent:@"new.plist"]) != nil, @"允许建立新配置");
        require(!axs_cachekeeper_cache_path(@"/Library/Caches") && !axs_cachekeeper_cache_path(@"Library/Caches//a"), @"拒绝非规范路径");
        NSString *summary = axs_cachekeeper_summary(@{@"rows":@[@{}]}, @{@"phase":@"auto", @"message":@"限写失败",
            @"removed":@3, @"bytes":@1048576, @"failed":@1});
        require([summary containsString:@"1 个"] && [summary containsString:@"3 个"] && [summary containsString:@"限写失败"], @"检测与清理结果同时可见");

        NSString *home=[fixture stringByAppendingPathComponent:@"app-home"];
        NSArray *directoryRoots=@[@"tmp",@"Library/Caches",@"Library/Logs",@"Library/Application Support",@"Library/HTTPStorages",@"Library/WebKit",@"Library/Cookies",@"Library/SplashBoard",@"Library/Saved Application State",@"Documents",@"CustomData",@".cache"];
        for (NSString *relative in directoryRoots) require([fm createDirectoryAtPath:[home stringByAppendingPathComponent:[relative stringByAppendingPathComponent:@"child/deep"]] withIntermediateDirectories:YES attributes:nil error:nil], @"目录扫描夹具");
        NSError *scanError=nil;
        NSArray *found=axs_cachekeeper_scan_directories([NSURL fileURLWithPath:home],&scanError);
        require(!scanError && ![found containsObject:@"Documents"] && ![found containsObject:@"Library/WebKit"] &&
            ![found containsObject:@"Library/Cookies"] && [found containsObject:@"Library/Application Support"] && [found containsObject:@"CustomData"], @"隐藏明确保护目录，混合用途与未知目录仍待分析");
        require([axs_cachekeeper_directory_kind(@"Library/Application Support") isEqual:@"mixed"] &&
            [axs_cachekeeper_directory_kind(@"CustomData") isEqual:@"unknown"] &&
            [axs_cachekeeper_directory_kind(@"Library/Preferences") isEqual:@"protected"], @"不把所有白名单外目录都当成必需数据");
        require(axs_cachekeeper_hidden_directory(@"Group/group.example/Library/Cookies") &&
            !axs_cachekeeper_hidden_directory(@"Library/Application Support"), @"共享敏感目录同样隐藏，混合数据不武断认定必需");
        NSArray *sorted=axs_cachekeeper_prioritized_rows(@[@{@"path":@"tmp",@"bytes":@1},@{@"path":@"Library/Caches",@"bytes":@999},@{@"path":@"Library/Logs",@"bytes":@500}],@[@"tmp"],@{@"enabled":@YES});
        require([sorted[0][@"path"] isEqual:@"tmp"] && [sorted[1][@"path"] isEqual:@"Library/Caches"], @"已开启置顶，同组按大小排序");
        NSArray *sortedAuto=axs_cachekeeper_prioritized_rows(sorted,@[],@{@"enabled":@YES,@"autoDiscover":@YES,@"excludedPaths":@[@"Library/Caches"]});
        require([sortedAuto.lastObject[@"path"] isEqual:@"Library/Caches"], @"自动纳入与排除使用同一开启排序依据");
        require([axs_cachekeeper_directory_description(@"Library/Application Support") containsString:@"业务数据"] &&
            !axs_cachekeeper_cache_path(@"Library/Application Support"), @"业务数据明确标注且不可自动清理");
        NSArray *largeFirst=axs_cachekeeper_size_ordered_rows(@[@{@"path":@"tmp",@"bytes":@1},@{@"path":@"Documents",@"bytes":@500},@{@"path":@"tmp/child",@"bytes":@999}]);
        require(largeFirst.count==2 && [largeFirst[0][@"path"] isEqual:@"Documents"], @"去重后按占用降序便于定位");
        NSString *group=[fixture stringByAppendingPathComponent:@"Containers/Shared/AppGroup/11111111-1111-1111-1111-111111111111"];
        require([fm createDirectoryAtPath:[group stringByAppendingPathComponent:@"Library/Caches/deep"] withIntermediateDirectories:YES attributes:nil error:nil], @"共享容器夹具");
        NSDictionary *groups=axs_cachekeeper_valid_group_homes(@{@"group.example":[NSURL fileURLWithPath:group],@"bad":[NSURL fileURLWithPath:home]});
        require(groups.count==1, @"共享容器仅接受有效系统容器路径");
        NSArray *targets=axs_cachekeeper_scan_targets([NSURL fileURLWithPath:home],groups,&scanError);
        NSPredicate *groupRows=[NSPredicate predicateWithBlock:^BOOL(NSDictionary *row,NSDictionary *bindings){ return [row[@"path"] hasPrefix:@"Group/"]; }];
        NSArray *shared=[targets filteredArrayUsingPredicate:groupRows];
        require(!scanError && shared.count==1 && [shared[0][@"path"] isEqual:@"Group/group.example/Library/Caches"] && [shared[0][@"readOnly"] boolValue], @"共享容器按父目录统计并显式只读");
        require(!axs_cachekeeper_cache_path(shared[0][@"path"]), @"手工改配置也不能清理共享容器");

        NSArray *detectedRows=@[@{@"path":@"Library/Caches",@"manageable":@YES},
            @{@"path":@"Library/Caches/video",@"manageable":@YES},@{@"path":@"tmp",@"manageable":@YES},
            @{@"path":@"Documents",@"manageable":@YES},@{@"path":@"Library/Application Support"},
            @{@"path":@"Group/group.example/Library/Caches",@"manageable":@YES},
            @{@"path":@"Library/Logs",@"manageable":@NO}];
        NSArray *enableAll=axs_cachekeeper_enableable_paths(detectedRows);
        require([enableAll isEqual:@[@"Library/Caches",@"tmp"]], @"一键开启仅选择可管理父目录，拒绝共享和受保护目录");
        NSString *preferences=[fixture stringByAppendingPathComponent:@"preferences"];
        require([fm createDirectoryAtPath:preferences withIntermediateDirectories:YES attributes:nil error:nil], @"创建配置测试目录");
        NSString *statesPath=[preferences stringByAppendingPathComponent:@"appEnabled.plist"];
        NSString *directoriesPath=[preferences stringByAppendingPathComponent:@"directories.plist"];
        NSDictionary *otherState=@{@"enabled":@NO,@"mode":@"auto",@"urlCache":@NO};
        require([@{bundle:@{@"enabled":@NO,@"mode":@"clean",@"urlCache":@YES},@"com.tencent.xin":otherState} writeToFile:statesPath atomically:YES], @"建立已有模式与特殊 APP 配置");
        require([@{@"com.tencent.xin":@[@"Library/Caches"]} writeToFile:directoriesPath atomically:YES], @"建立其他 APP 目录配置");
        require(!axs_cachekeeper_update_selection(preferences,bundle,enableAll,YES), @"一键开启保存成功");
        NSDictionary *savedStates=[NSDictionary dictionaryWithContentsOfFile:statesPath];
        NSDictionary *savedDirectories=[NSDictionary dictionaryWithContentsOfFile:directoriesPath];
        require(axs_cachekeeper_app_enabled(savedStates[bundle]) && [savedDirectories[bundle] isEqual:enableAll], @"一键开启同时打开本 APP 总开关与所选目录");
        require([savedStates[bundle][@"mode"] isEqual:@"clean"] && [savedStates[bundle][@"urlCache"] boolValue] &&
            [savedStates[@"com.tencent.xin"] isEqual:otherState], @"保留当前模式、网络选项和其他 APP 状态");
        require(!axs_cachekeeper_one_click(preferences,bundle,detectedRows), @"一键配置自动管理");
        savedStates=[NSDictionary dictionaryWithContentsOfFile:statesPath];
        require([savedStates[bundle][@"mode"] isEqual:@"auto"] && axs_cachekeeper_should_prevent(savedStates[bundle]) &&
            axs_cachekeeper_auto_discover(savedStates[bundle]), @"一键开启自动模式、网络限制和新增缓存发现");
        require([savedStates[@"com.tencent.xin"] isEqual:otherState], @"一键预设不影响其他 APP");
        require(axs_cachekeeper_manageable_rows(detectedRows).count==2 &&
            axs_cachekeeper_readonly_rows(detectedRows).count==3, @"可管理目录与待分析目录独立，敏感目录彻底隐藏");
        require([axs_cachekeeper_unknown_rows(detectedRows) count]==0 && [axs_cachekeeper_known_readonly_rows(detectedRows) count]==3, @"已知混合/共享数据不混入未知目录");
        NSString *filzaPath=[home stringByAppendingPathComponent:@"Library/Caches/中文 #?% folder"];
        NSDictionary *legacyInfo=@{@"CFBundleURLTypes":@[@{@"CFBundleURLSchemes":@[@"filza"]} ]};
        NSURL *legacyURL=axs_cachekeeper_filza_url(filzaPath,legacyInfo);
        NSURL *modernURL=axs_cachekeeper_filza_url(filzaPath,@{@"CFBundleShortVersionString":@"5.0.1"});
        require([legacyURL.scheme isEqual:@"filza"] && [legacyURL.path isEqual:filzaPath] && !legacyURL.query && !legacyURL.fragment, @"Filza 4 scheme 保留特殊路径字符");
        require(modernURL.isFileURL && [modernURL.path isEqual:filzaPath], @"Filza 5 未注册 scheme 时生成定向文件 URL");
        require(!axs_cachekeeper_filza_url(@"/private/var/../root",@{}) && !axs_cachekeeper_filza_url(@"relative",@{}), @"不投递不规范或相对路径");
        AxsTestWorkspace *workspace=[AxsTestWorkspace new];workspace.expectedPath=filzaPath;
        __block BOOL delivered=NO;__block NSError *openError=nil;
        axs_cachekeeper_send_filza_document(workspace,[AxsTestOpenConfiguration new],@"test-payload",modernURL,^(BOOL success,NSError *error){delivered=success;openError=error;});
        require(delivered && !openError, @"现代文件投递保持指定应用、文件 URL 和回调契约");
        axs_cachekeeper_send_filza_document([NSObject new],[AxsTestOpenConfiguration new],@"test-payload",modernURL,^(BOOL success,NSError *error){delivered=success;openError=error;});
        require(!delivered && openError, @"目标 API 不存在时明确失败，不模拟打开成功");
        NSDictionary *automaticState=savedStates[bundle];
        NSArray *discovered=@[@"Library/Caches",@"tmp",@"Library/Logs",@"Library/Application Support",@"Group/group.example/Library/Caches"];
        require([axs_cachekeeper_effective_paths(@[@"tmp"],automaticState,discovered) isEqual:@[@"Library/Caches",@"Library/Logs",@"tmp"]], @"自动发现只纳入标准缓存根并按父目录去重");
        require(!axs_cachekeeper_update_selection(preferences,bundle,@[@"Library/Caches"],NO), @"直接取消父目录");
        require([([NSDictionary dictionaryWithContentsOfFile:directoriesPath][bundle]) isEqual:@[@"tmp"]], @"取消不影响其他已选目录");
        NSDictionary *afterExclusion=[NSDictionary dictionaryWithContentsOfFile:statesPath][bundle];
        require(![axs_cachekeeper_effective_paths(@[@"tmp"],afterExclusion,discovered) containsObject:@"Library/Caches"], @"手动关闭的目录不会被自动发现重新开启");
        NSArray *knownRows=axs_cachekeeper_display_rows(@[@{@"path":@"tmp",@"bytes":@1}],@[@"Library/Caches",@"tmp"]);
        require(knownRows.count==2 && axs_cachekeeper_manageable_rows(knownRows).count==2, @"已发现但手动排除的目录仍可显示并重新开启");
        require(axs_cachekeeper_can_clean(@{},@{bundle:automaticState},bundle) &&
            !axs_cachekeeper_can_clean(@{},@{bundle:axs_cachekeeper_app_state(automaticState,NO)},bundle), @"自动发现为唯一来源时允许快捷请求，关闭总开关仍拒绝");
        NSDictionary *excludeChild=@{@"enabled":@YES,@"autoDiscover":@YES,@"excludedPaths":@[@"Library/Caches/video"]};
        require(![axs_cachekeeper_effective_paths(@[@"Library/Caches"],excludeChild,@[@"Library/Caches"]) count], @"自动发现父目录不能绕过对子目录的手动排除");
        require([axs_cachekeeper_app_state(afterExclusion,YES)[@"excludedPaths"] containsObject:@"Library/Caches"] &&
            axs_cachekeeper_auto_discover(axs_cachekeeper_app_state(afterExclusion,YES)), @"切模式/总开关保留自动发现与排除选择");
        require(!axs_cachekeeper_effective_paths(@[@"tmp"],axs_cachekeeper_app_state(afterExclusion,NO),discovered).count, @"总开关关闭时新增缓存不能被纳入处理");
        NSError *discoveryError=nil;
        NSArray *existingRoots=axs_cachekeeper_discover_cache_roots([NSURL fileURLWithPath:home],&discoveryError);
        require(!discoveryError && [existingRoots containsObject:@"tmp"] && [existingRoots containsObject:@".cache"] &&
            ![existingRoots containsObject:@"Library/Application Support"], @"真实文件系统发现仅扫描固定缓存根");
        NSString *newRoot=[home stringByAppendingPathComponent:@"Cache"];
        require([fm createDirectoryAtPath:newRoot withIntermediateDirectories:NO attributes:nil error:nil], @"新顶级缓存目录夹具");
        require([axs_cachekeeper_discover_cache_roots([NSURL fileURLWithPath:home],&discoveryError) containsObject:@"Cache"], @"后续检测发现新增顶级标准缓存目录");
        require(!axs_cachekeeper_update_selection(preferences,@"single.app",@[@"Library/Caches/video"],YES), @"单项开启无需另开总开关");
        require(axs_cachekeeper_app_enabled([NSDictionary dictionaryWithContentsOfFile:statesPath][@"single.app"]), @"单项开启仅激活对应 APP");
        NSData *beforeInvalid=[NSData dataWithContentsOfFile:directoriesPath];
        require(axs_cachekeeper_update_selection(preferences,bundle,@[@"Documents"],YES)!=nil &&
            [[NSData dataWithContentsOfFile:directoriesPath] isEqual:beforeInvalid], @"非法目录不改变现有配置");
        require([@"broken state" writeToFile:statesPath atomically:YES encoding:NSUTF8StringEncoding error:nil], @"损坏状态夹具");
        require(axs_cachekeeper_update_selection(preferences,bundle,enableAll,YES)!=nil &&
            [[NSData dataWithContentsOfFile:directoriesPath] isEqual:beforeInvalid], @"损坏配置时不写入部分选择");

        NSString *cache = [fixture stringByAppendingPathComponent:@"cache"];
        require([fm createDirectoryAtPath:cache withIntermediateDirectories:NO attributes:nil error:nil], @"创建缓存根");
        NSString *outside = [fixture stringByAppendingPathComponent:@"user-document"];
        writeFile(outside);
        writeMedia([cache stringByAppendingPathComponent:@"old.cache"]);
        writeMedia([cache stringByAppendingPathComponent:@"new.tmp"]);
        NSString *dataDirectory=[cache stringByAppendingPathComponent:@"store"];
        require([fm createDirectoryAtPath:[dataDirectory stringByAppendingPathComponent:@"assets"] withIntermediateDirectories:YES attributes:nil error:nil], @"业务数据目录夹具");
        writeFile([dataDirectory stringByAppendingPathComponent:@"session.cache"]);
        writeFile([dataDirectory stringByAppendingPathComponent:@"business.sqlite"]);
        writeMedia([dataDirectory stringByAppendingPathComponent:@"paired.png"]);
        writeMedia([dataDirectory stringByAppendingPathComponent:@"assets/attachment.png"]);
        writeFile([cache stringByAppendingPathComponent:@"unknown-data"]);
        writeFile([dataDirectory stringByAppendingPathComponent:@"000003.log"]);
        NSString *disguised=[dataDirectory stringByAppendingPathComponent:@"opaque.cache"];
        require([@"SQLite format 3\0payload" writeToFile:disguised atomically:YES encoding:NSUTF8StringEncoding error:nil], @"数据库内容测试");
        AxsCacheKeeperSweep *fresh = [[AxsCacheKeeperSweep alloc] initWithRoot:cache];
        [fresh advance:30 shouldContinue:^BOOL { return YES; }];
        require(fresh.removed==0 && [fm fileExistsAtPath:[cache stringByAppendingPathComponent:@"new.tmp"]], @"真实新文件不删除");
        require(symlink(outside.fileSystemRepresentation, [cache stringByAppendingPathComponent:@"link"].fileSystemRepresentation) == 0, @"创建链接测试边界");
        NSTimeInterval future=NSDate.date.timeIntervalSince1970+120;
        AxsCacheKeeperSweep *sweep = [[AxsCacheKeeperSweep alloc] initWithRoot:cache clock:^NSTimeInterval { return future; }];
        for (NSUInteger pass = 0; !sweep.complete && pass < 100; pass++) {
            [sweep advance:1 shouldContinue:^BOOL { return YES; }];
        }
        require(sweep.complete && sweep.removed == 2 && sweep.failed == 0, @"单项分批仍能完成遍历并删除新旧缓存");
        require([fm fileExistsAtPath:outside] && [fm fileExistsAtPath:cache], @"保留根目录与链接外用户文件");
        NSString *subfolder=[cache stringByAppendingPathComponent:@"later/deep"];
        require([fm createDirectoryAtPath:subfolder withIntermediateDirectories:YES attributes:nil error:nil], @"已选父目录内新增子目录");
        NSString *laterFile=[subfolder stringByAppendingPathComponent:@"later.cache"];
        writeMedia(laterFile);
        AxsCacheKeeperSweep *nextSweep=[[AxsCacheKeeperSweep alloc] initWithRoot:cache clock:^NSTimeInterval{return NSDate.date.timeIntervalSince1970+120;}];
        for (NSUInteger pass=0;!nextSweep.complete && pass<100;pass++) [nextSweep advance:2 shouldContinue:^BOOL{return YES;}];
        require(nextSweep.complete && nextSweep.removed==1 && ![fm fileExistsAtPath:laterFile],
            [NSString stringWithFormat:@"后续扫描自动覆盖父目录中新生子目录，无需新增配置（complete=%d removed=%lu failed=%lu protected=%lu recent=%lu changed=%lu inspected=%lu error=%@）",
                nextSweep.complete,(unsigned long)nextSweep.removed,(unsigned long)nextSweep.failed,(unsigned long)nextSweep.protectedCount,
                (unsigned long)nextSweep.recentCount,(unsigned long)nextSweep.changedCount,(unsigned long)nextSweep.inspected,nextSweep.error]);
        require([fm fileExistsAtPath:[dataDirectory stringByAppendingPathComponent:@"business.sqlite"]] &&
            [fm fileExistsAtPath:[dataDirectory stringByAppendingPathComponent:@"paired.png"]] &&
            [fm fileExistsAtPath:[dataDirectory stringByAppendingPathComponent:@"assets/attachment.png"]] && [fm fileExistsAtPath:disguised], @"数据库目录及配套媒体、后代整体保留，其他独立目录仍可清理");
        NSString *lateDir=[fixture stringByAppendingPathComponent:@"late-database"];
        require([fm createDirectoryAtPath:lateDir withIntermediateDirectories:YES attributes:nil error:nil], @"延迟发现数据库夹具");
        writeMedia([lateDir stringByAppendingPathComponent:@"a.png"]);
        writeFile([lateDir stringByAppendingPathComponent:@"z.sqlite"]);
        AxsCacheKeeperSweep *late=[[AxsCacheKeeperSweep alloc] initWithRoot:lateDir clock:^NSTimeInterval{return future;}];
        [late advance:1 shouldContinue:^BOOL{return YES;}];
        require(late.removed==0, @"分批预检未完成之前不得删除同目录文件");
        for (NSUInteger pass=0;!late.complete && pass<30;pass++) [late advance:1 shouldContinue:^BOOL{return YES;}];
        require(late.complete && late.removed==0 && [fm fileExistsAtPath:[lateDir stringByAppendingPathComponent:@"a.png"]], @"晚发现数据库仍保护早枚举文件");
        NSString *changedDir=[fixture stringByAppendingPathComponent:@"changed"];
        require([fm createDirectoryAtPath:changedDir withIntermediateDirectories:YES attributes:nil error:nil], @"变化目录夹具");
        writeMedia([changedDir stringByAppendingPathComponent:@"image.png"]);
        AxsCacheKeeperSweep *changed=[[AxsCacheKeeperSweep alloc] initWithRoot:changedDir clock:^NSTimeInterval{return future;}];
        for (NSUInteger pass=0;changed.checking && !changed.complete && pass<20;pass++) [changed advance:1 shouldContinue:^BOOL{return YES;}];
        require(!changed.checking && changed.removed==0, @"预检阶段与删除阶段明确分开");
        writeFile([changedDir stringByAppendingPathComponent:@"new.sqlite"]);
        for (NSUInteger pass=0;!changed.complete && pass<20;pass++) [changed advance:1 shouldContinue:^BOOL{return YES;}];
        require(changed.complete && changed.removed==0 && changed.changedCount>0 && [fm fileExistsAtPath:[changedDir stringByAppendingPathComponent:@"image.png"]], @"预检后加入数据库时保留原目录文件并报告跳过");
        NSString *inplaceDir=[fixture stringByAppendingPathComponent:@"inplace"];
        require([fm createDirectoryAtPath:inplaceDir withIntermediateDirectories:YES attributes:nil error:nil], @"原地变化夹具");
        writeMedia([inplaceDir stringByAppendingPathComponent:@"image.png"]);
        NSString *opaque=[inplaceDir stringByAppendingPathComponent:@"opaque"];
        writeFile(opaque);
        AxsCacheKeeperSweep *inplace=[[AxsCacheKeeperSweep alloc] initWithRoot:inplaceDir clock:^NSTimeInterval{return future;}];
        for (NSUInteger pass=0;inplace.checking && !inplace.complete && pass<20;pass++) [inplace advance:1 shouldContinue:^BOOL{return YES;}];
        NSFileHandle *writer=[NSFileHandle fileHandleForWritingAtPath:opaque];
        [writer writeData:[@"SQLite format 3\0payload" dataUsingEncoding:NSUTF8StringEncoding]];[writer closeFile];
        for (NSUInteger pass=0;!inplace.complete && pass<20;pass++) [inplace advance:1 shouldContinue:^BOOL{return YES;}];
        require(inplace.complete && inplace.removed==0 && [fm fileExistsAtPath:[inplaceDir stringByAppendingPathComponent:@"image.png"]], @"已有未知文件原地变为数据库仍保护同目录媒体");
        require([fm fileExistsAtPath:[dataDirectory stringByAppendingPathComponent:@"000003.log"]], @"未知数据库 WAL 不因 log 后缀删除");
        NSString *pending = [cache stringByAppendingPathComponent:@"pending"];
        writeFile(pending);
        AxsCacheKeeperSweep *cancelled = [[AxsCacheKeeperSweep alloc] initWithRoot:cache];
        [cancelled advance:10 shouldContinue:^BOOL { return NO; }];
        require(cancelled.cancelled && [fm fileExistsAtPath:pending], @"APP 重启或开关关闭后停止删除");

        NSString *journal = [fixture stringByAppendingPathComponent:@"permissions.plist"];
        struct stat info;
        require(!lstat(cache.fileSystemRepresentation,&info), @"读取原目录身份");
        require([@{cache:@{@"inode":@(info.st_ino),@"device":@(info.st_dev),@"mode":@0770}} writeToFile:journal atomically:YES], @"建立旧版本权限恢复记录");
        chmod(cache.fileSystemRepresentation, 0550);
        NSDictionary *restored = axs_cachekeeper_restore_paths(@[cache], journal);
        require(!lstat(cache.fileSystemRepresentation, &info) && (info.st_mode & 0777) == 0770 && [restored[@"failed"] unsignedIntegerValue] == 0, @"精确恢复原目录权限");
        require([@"invalid journal" writeToFile:journal atomically:YES encoding:NSUTF8StringEncoding error:nil], @"损坏记录测试");
        NSDictionary *rejected = axs_cachekeeper_restore_paths(@[cache], journal);
        require([rejected[@"failed"] unsignedIntegerValue] > 0 && !lstat(cache.fileSystemRepresentation, &info) && (info.st_mode & 0777) == 0770, @"损坏记录不能改变目录权限");

        IMP originalSetter=method_getImplementation(class_getInstanceMethod(NSURLCache.class,@selector(setDiskCapacity:)));
        IMP originalInitializer=method_getImplementation(class_getInstanceMethod(NSURLCache.class,@selector(initWithMemoryCapacity:diskCapacity:diskPath:)));
        require(axs_cachekeeper_configure_network_cache(NO), @"未启用状态可直接返回");
        require(originalSetter==method_getImplementation(class_getInstanceMethod(NSURLCache.class,@selector(setDiskCapacity:))) &&
            originalInitializer==method_getImplementation(class_getInstanceMethod(NSURLCache.class,@selector(initWithMemoryCapacity:diskCapacity:diskPath:))), @"未启用时不安装 NSURLCache Hook");
        require(axs_cachekeeper_configure_network_cache(YES), @"网络缓存禁止可应用");
        NSURLCache *network=[[NSURLCache alloc] initWithMemoryCapacity:1048576 diskCapacity:8388608 diskPath:[fixture stringByAppendingPathComponent:@"network"]];
        require(network.diskCapacity==0 && network.memoryCapacity==1048576, @"新实例禁止磁盘缓存但保留内存容量");
        network.diskCapacity=16777216;
        require(network.diskCapacity==0, @"APP 不能立即把禁止状态覆盖");
        require(axs_cachekeeper_configure_network_cache(NO) && network.diskCapacity==16777216, @"关闭后恢复 APP 最新请求的容量");
        network.diskCapacity=33554432;
        require(axs_cachekeeper_configure_network_cache(NO) && network.diskCapacity==33554432, @"关闭后重复刷新不得重写 APP 容量");
        // 证据通道：抽检定级、保存校验、用户判定与纵向旁证。
        NSDictionary *allMedia=@{@"files":@3,@"data":@0,@"media":@3,@"other":@0,@"unchecked":@0,@"complete":@YES};
        NSDictionary *withData=@{@"files":@3,@"data":@1,@"media":@2,@"other":@0,@"unchecked":@0,@"complete":@YES};
        NSDictionary *partial=@{@"files":@3,@"data":@0,@"media":@2,@"other":@0,@"unchecked":@1,@"complete":@YES};
        require([axs_cachekeeper_evidence_grade(allMedia) isEqual:@"cachelike"], @"全量媒体且无数据标记才定级缓存特征");
        require([axs_cachekeeper_evidence_grade(withData) isEqual:@"data"], @"检出数据文件优先定级为数据");
        require([axs_cachekeeper_evidence_grade(partial) isEqual:@""], @"有未查文件时不定级");
        require([axs_cachekeeper_evidence_grade(@{@"files":@0,@"data":@0,@"media":@0,@"other":@0,@"unchecked":@0,@"complete":@YES}) isEqual:@""], @"空目录不定级");
        require(axs_cachekeeper_probe_eligible(@"Library/SomeSDK") && axs_cachekeeper_probe_eligible(@"Library/Application Support"), @"未知与混合目录可走证据通道");
        require(!axs_cachekeeper_probe_eligible(@"Documents") && !axs_cachekeeper_probe_eligible(@"Library/Caches") &&
            !axs_cachekeeper_probe_eligible(@"Group/g.example/Library/Caches") && !axs_cachekeeper_probe_eligible(@"Library/Preferences"), @"受保护、白名单与共享目录不走证据通道");
        NSArray *gradedRows=@[@{@"path":@"Library/SomeSDK",@"evidence":allMedia},
            @{@"path":@"Library/DataBox",@"evidence":withData},
            @{@"path":@"Group/g.example/Library/SomeSDK",@"evidence":allMedia}];
        require([axs_cachekeeper_cachelike_paths(gradedRows) isEqual:[NSSet setWithObject:@"Library/SomeSDK"]], @"只有主容器内全量媒体的未知目录进入缓存特征集合");
        NSSet *extraSet=axs_cachekeeper_extra_selectable(gradedRows,@{@"judgedPaths":@[@"Library/Manual"]});
        require([extraSet containsObject:@"Library/SomeSDK"] && [extraSet containsObject:@"Library/Manual"] && extraSet.count==2, @"证据通道集合由定级目录与用户判定目录组成");
        NSDictionary *tieredState=@{@"enabled":@YES,@"mode":@"auto",@"judgedPaths":@[@"Library/Manual"]};
        require([axs_cachekeeper_effective_paths_tiered(@[@"Library/SomeSDK",@"Library/DataBox",@"Documents"],tieredState,@[],extraSet) isEqual:@[@"Library/SomeSDK"]], @"分级有效路径只接受定级目录，数据与受保护目录仍拒绝");
        require([axs_cachekeeper_effective_paths_tiered(@[@"Library/Manual"],tieredState,@[],extraSet) isEqual:@[@"Library/Manual"]], @"用户判定目录可进入有效路径");
        NSDictionary *tieredExcluded=@{@"enabled":@YES,@"mode":@"auto",@"judgedPaths":@[@"Library/Manual"],@"excludedPaths":@[@"Library/Manual"]};
        require(![axs_cachekeeper_effective_paths_tiered(@[@"Library/Manual"],tieredExcluded,@[],extraSet) count], @"手动排除对证据通道同样有效");
        NSString *gradedPreferences=[fixture stringByAppendingPathComponent:@"graded-preferences"];
        require([fm createDirectoryAtPath:gradedPreferences withIntermediateDirectories:YES attributes:nil error:nil], @"定级保存夹具目录");
        NSString *gradedStates=[gradedPreferences stringByAppendingPathComponent:@"appEnabled.plist"];
        NSString *gradedDirectories=[gradedPreferences stringByAppendingPathComponent:@"directories.plist"];
        NSString *gradedSnapshots=[gradedPreferences stringByAppendingPathComponent:@"snapshots.plist"];
        require([@{bundle:@{@"rows":gradedRows}} writeToFile:gradedSnapshots atomically:YES], @"定级保存夹具快照");
        require([@{} writeToFile:gradedStates atomically:YES] && [@{} writeToFile:gradedDirectories atomically:YES], @"定级保存夹具配置");
        require(!axs_cachekeeper_update_selection(gradedPreferences,bundle,@[@"Library/SomeSDK"],YES), @"抽检定级目录可单项开启");
        require([[NSDictionary dictionaryWithContentsOfFile:gradedDirectories][bundle] isEqual:@[@"Library/SomeSDK"]], @"定级目录写入选择");
        require(axs_cachekeeper_update_selection(gradedPreferences,bundle,@[@"Library/DataBox"],YES)!=nil, @"检出数据文件的目录不能开启");
        require(axs_cachekeeper_update_selection(gradedPreferences,bundle,@[@"Library/Never"],YES)!=nil, @"未抽检定级的未知目录不能开启");
        require([@{bundle:@{@"rows":@[@{@"path":@"Library/SomeSDK",@"evidence":partial}]}} writeToFile:gradedSnapshots atomically:YES], @"重新定级夹具");
        require(!axs_cachekeeper_update_selection(gradedPreferences,bundle,@[@"Library/SomeSDK"],NO), @"目录被重新定级后仍可关闭");
        require([@{bundle:@{@"rows":gradedRows}} writeToFile:gradedSnapshots atomically:YES], @"恢复定级夹具");
        require(!axs_cachekeeper_save_judged(gradedPreferences,bundle,@"Library/Manual",YES), @"用户判定开启成功");
        NSDictionary *judgedStates=[NSDictionary dictionaryWithContentsOfFile:gradedStates];
        NSDictionary *judgedDirectories=[NSDictionary dictionaryWithContentsOfFile:gradedDirectories];
        require([axs_cachekeeper_judged_paths(judgedStates[bundle]) isEqual:@[@"Library/Manual"]] && [judgedDirectories[bundle] containsObject:@"Library/Manual"], @"判定记录与目录选择同时落盘");
        require([axs_cachekeeper_selected_paths_tiered(judgedDirectories,judgedStates,bundle,gradedRows) containsObject:@"Library/Manual"], @"判定目录进入分级已选路径");
        require(axs_cachekeeper_save_judged(gradedPreferences,bundle,@"Library/DataBox",YES)!=nil, @"已检出数据文件的目录在保存层拒绝判定");
        require(!axs_cachekeeper_save_judged(gradedPreferences,bundle,@"Library/Manual",NO), @"取消用户判定成功");
        require(![axs_cachekeeper_judged_paths([NSDictionary dictionaryWithContentsOfFile:gradedStates][bundle]) count] &&
            ![[NSDictionary dictionaryWithContentsOfFile:gradedDirectories][bundle] containsObject:@"Library/Manual"], @"取消判定同时撤销选择");
        NSDate *now=NSDate.date;
        NSArray *flatGens=@[@{@"rows":@[@{@"path":@"Library/SomeSDK",@"bytes":@100}],@"updated":now},
            @{@"rows":@[@{@"path":@"Library/SomeSDK",@"bytes":@100}],@"updated":[now dateByAddingTimeInterval:-4*86400]},
            @{@"rows":@[@{@"path":@"Library/SomeSDK",@"bytes":@100}],@"updated":[now dateByAddingTimeInterval:-8*86400]}];
        require([axs_cachekeeper_trend_label(flatGens,@"Library/SomeSDK") isEqual:@"多次检测大小无变化"], @"三代同大小且跨度足够时标注无变化");
        NSArray *growingGens=@[@{@"rows":@[@{@"path":@"Library/SomeSDK",@"bytes":@300}],@"updated":now},
            @{@"rows":@[@{@"path":@"Library/SomeSDK",@"bytes":@200}],@"updated":[now dateByAddingTimeInterval:-86400]},
            @{@"rows":@[@{@"path":@"Library/SomeSDK",@"bytes":@100}],@"updated":[now dateByAddingTimeInterval:-2*86400]}];
        require([axs_cachekeeper_trend_label(growingGens,@"Library/SomeSDK") isEqual:@"近几次检测持续增长"], @"大小逐代增长时标注持续增长");
        require(!axs_cachekeeper_trend_label(@[flatGens[0],flatGens[1]],@"Library/SomeSDK"), @"不足三代不给纵向结论");

        puts("PASS: configuration, modes, deduplication, age, protected files, cleanup, cancellation, permission restoration and URLCache");
    }
    return 0;
}
