#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <unistd.h>
#import "../AxsCacheKeeperPolicy.h"
#import "../AxsCacheKeeperFileAccess.h"
#import "../AxsCacheKeeperSweep.h"
#import "../AxsCacheKeeperNetworkCache.h"
#import "../AxsCacheKeeperDirectories.h"
#import "../AxsCacheKeeperSelection.h"
#import "../AxsCacheKeeperFilza.h"
#import "../AxsCacheKeeperProcess.h"
#import "../AxsCacheKeeperInspection.h"
#import "../AxsCacheKeeperProbe.h"
#import "../AxsCacheKeeperFileAccess.h"
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
@interface AxsTestProcessState : NSObject
@property(nonatomic) NSInteger taskState;
@end
@implementation AxsTestProcessState
@end
// 数据安全测试白盒入口：仅用于验证删除阶段重标混合（审计第 2 项）。文件级稳定性门
//（inode/设备/mtime/ctime）已拦下预检后被改写的文件，黑盒无法让带新证据的文件走到
// 删除门，故直接刷新预检记录以单独验证复核逻辑。
@interface AxsCacheKeeperSweep (DataSafetyTestAccess)
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSMutableDictionary *> *fileSnapshots;
- (NSArray *)axs_cachekeeper_snapshot:(struct stat)info;
@end
@interface AxsTestProcess : NSObject
@property(nonatomic,copy) NSString *bundleIdentifier;
@property(nonatomic) BOOL running;
@property(nonatomic,strong) id state;
@property(nonatomic) int pid;
- (BOOL)isRunning;
@end
@implementation AxsTestProcess
- (BOOL)isRunning { return self.running; }
@end
@interface AxsTestTaskState : NSObject
@property(nonatomic) NSInteger taskState;
@end
@implementation AxsTestTaskState
@end
@interface AxsTestProcessManager : NSObject
@property(nonatomic,strong) id allApplicationProcesses;
@property(nonatomic,strong) AxsTestProcess *systemApplicationProcess;
@end
@implementation AxsTestProcessManager
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
        uint64_t probeRequest=axs_cachekeeper_probe_request(123,1000);
        require(axs_cachekeeper_probe_fresh(probeRequest,1000) && axs_cachekeeper_probe_fresh(probeRequest,1300) &&
            !axs_cachekeeper_probe_fresh(probeRequest,1301) && !axs_cachekeeper_probe_fresh(probeRequest,999) &&
            !axs_cachekeeper_probe_fresh(axs_cachekeeper_probe_request(0,1000),1000), @"诊断请求必须带有效随机标识且五分钟内有效");
        require([axs_cachekeeper_probe_description(axs_cachekeeper_probe_result(1,2)) containsString:@"授权失败"] &&
            [axs_cachekeeper_probe_description(axs_cachekeeper_probe_result(2,257)) containsString:@"配置读取失败"] &&
            [axs_cachekeeper_probe_description(axs_cachekeeper_probe_result(7,0)) containsString:@"写入失败"], @"注入、配置、容量和文件回执不混为同一状态");
        NSString *probeName=axs_cachekeeper_probe_name(NSUUID.UUID.UUIDString,NO);
        int sender=-1,receiver=-1;uint64_t observed=0;
        require(notify_register_check(probeName.UTF8String,&sender)==NOTIFY_STATUS_OK &&
            notify_register_check(probeName.UTF8String,&receiver)==NOTIFY_STATUS_OK &&
            notify_set_state(sender,probeRequest)==NOTIFY_STATUS_OK && notify_get_state(receiver,&observed)==NOTIFY_STATUS_OK &&
            observed==probeRequest, @"实际 Darwin state API 的多个注册可以读取同一诊断请求");
        notify_cancel(sender);notify_cancel(receiver);
        NSString *reason=nil;
        require(axs_cachekeeper_process_state(nil,bundle,&reason)==AxsCacheKeeperProcessUnknown && reason.length, @"缺少进程接口不能判断已退出");
        AxsTestProcessManager *manager=[AxsTestProcessManager new];manager.allApplicationProcesses=@[];
        require(axs_cachekeeper_process_state(manager,bundle,&reason)==AxsCacheKeeperProcessUnknown, @"系统未就绪时空进程列表不能放行");
        AxsTestProcess *system=[AxsTestProcess new];system.running=YES;manager.systemApplicationProcess=system;
        require(axs_cachekeeper_process_state(manager,bundle,&reason)==AxsCacheKeeperProcessStopped, @"完整进程清单中不存在 APP 时可确认退出");
        manager.allApplicationProcesses=nil;
        require(axs_cachekeeper_process_state(manager,bundle,&reason)==AxsCacheKeeperProcessUnknown, @"nil 清单不能模拟空数组成功");
        AxsTestProcess *application=[AxsTestProcess new];application.bundleIdentifier=bundle;manager.allApplicationProcesses=@[application];
        require(axs_cachekeeper_process_state(manager,bundle,&reason)==AxsCacheKeeperProcessRunning, @"保留启动或退出中的进程记录，不依赖瞬时 isRunning");
        AxsTestTaskState *task=[AxsTestTaskState new];task.taskState=2;application.state=task;
        require(axs_cachekeeper_process_state(manager,bundle,&reason)==AxsCacheKeeperProcessRunning &&
            [reason containsString:@"taskState=2"], @"有进程记录时仍禁止清理，并保留执行状态原始值供诊断");
        application.state=nil;
        require(axs_cachekeeper_process_state(manager,bundle,&reason)==AxsCacheKeeperProcessRunning &&
            [reason containsString:@"taskState=不可读"], @"执行状态接口缺失只能报告不可读，不能模拟退出");
        manager.allApplicationProcesses=@[[NSObject new]];
        require(axs_cachekeeper_process_state(manager,bundle,&reason)==AxsCacheKeeperProcessUnknown, @"不完整的进程记录不得授权删除");
        AxsTestProcessState *execState=[AxsTestProcessState new];
        application.state=execState;
        application.pid=NSProcessInfo.processInfo.processIdentifier;
        manager.allApplicationProcesses=@[application];
        NSString *execIdentity=nil; NSInteger rawTaskState=-1;
        execState.taskState=1;
        require(axs_cachekeeper_process_exec_state(manager,bundle,&execIdentity,&rawTaskState,&reason)==AxsCacheKeeperExecExecuting && rawTaskState==1, @"taskState=1 判为执行中");
        execState.taskState=2;
        require(axs_cachekeeper_process_exec_state(manager,bundle,&execIdentity,&rawTaskState,&reason)==AxsCacheKeeperExecSuspended && execIdentity.length, @"taskState=2 判为已挂起且能取实例标识");
        execState.taskState=3;
        require(axs_cachekeeper_process_exec_state(manager,bundle,&execIdentity,&rawTaskState,&reason)==AxsCacheKeeperExecTerminated && rawTaskState==3, @"taskState=3 判为已终止");
        execState.taskState=7;
        require(axs_cachekeeper_process_exec_state(manager,bundle,&execIdentity,&rawTaskState,&reason)==AxsCacheKeeperExecUnknown, @"未知 taskState 一律不放行");
        // 多记录汇总（审计第 5 项）：同一 APP 多条记录时取最保守态，而非首条记录。
        AxsTestProcess *second=[AxsTestProcess new];second.bundleIdentifier=bundle;second.pid=NSProcessInfo.processInfo.processIdentifier;
        AxsTestProcessState *secondState=[AxsTestProcessState new];second.state=secondState;
        application.state=execState;execState.taskState=3;secondState.taskState=2;
        manager.allApplicationProcesses=@[application,second];
        require(axs_cachekeeper_process_exec_state(manager,bundle,&execIdentity,&rawTaskState,&reason)==AxsCacheKeeperExecSuspended && rawTaskState==2, @"已终止+已挂起两条记录时取最保守的已挂起");
        execState.taskState=2;secondState.taskState=1;
        require(axs_cachekeeper_process_exec_state(manager,bundle,&execIdentity,&rawTaskState,&reason)==AxsCacheKeeperExecExecuting && rawTaskState==1, @"已挂起+执行中两条记录时取最保守的执行中");
        execState.taskState=3;secondState.taskState=3;
        require(axs_cachekeeper_process_exec_state(manager,bundle,&execIdentity,&rawTaskState,&reason)==AxsCacheKeeperExecTerminated && rawTaskState==3, @"两条已终止记录仍判为已终止");
        manager.allApplicationProcesses=@[application];
        application.state=nil;
        require(axs_cachekeeper_process_exec_state(manager,bundle,&execIdentity,&rawTaskState,&reason)==AxsCacheKeeperExecUnknown, @"读不到进程状态对象时不放行");
        manager.allApplicationProcesses=@[];
        require(axs_cachekeeper_process_exec_state(manager,bundle,&execIdentity,&rawTaskState,&reason)==AxsCacheKeeperExecAbsent, @"完整清单中无记录判为进程消失");
        manager.allApplicationProcesses=@[application];
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
        require(!axs_cachekeeper_full_clear(nil) && !axs_cachekeeper_full_clear(@{}) &&
            !axs_cachekeeper_full_clear(@{@"fullClear":@"yes"}) &&
            axs_cachekeeper_full_clear(@{@"fullClear":@YES}) && !axs_cachekeeper_full_clear(@{@"fullClear":@NO}), @"全量清理默认关闭且只认明确的布尔真值");
        require(!axs_cachekeeper_full_clear(axs_cachekeeper_app_state(nil,YES)), @"新 APP 经状态构建后全量清理仍默认关闭");
        require(axs_cachekeeper_full_clear(axs_cachekeeper_app_state(@{@"enabled":@YES,@"fullClear":@YES},NO)), @"总开关与模式保存必须保留已开启的全量清理");
        require(!axs_cachekeeper_full_clear(axs_cachekeeper_app_state(@{@"enabled":@YES},YES)), @"状态构建不能凭空打开全量清理");
        NSDictionary *fullOn=@{@"enabled":@YES,@"fullClear":@YES};
        require(axs_cachekeeper_full_clear_path(fullOn,@"Library/Caches") && axs_cachekeeper_full_clear_path(fullOn,@"tmp") &&
            !axs_cachekeeper_full_clear_path(fullOn,@"Caches") && !axs_cachekeeper_full_clear_path(fullOn,@"Cache") &&
            !axs_cachekeeper_full_clear_path(fullOn,@"cache") && !axs_cachekeeper_full_clear_path(fullOn,@".cache"), @"全量清理只作用于 Library/Caches 与 tmp，顶层 Caches/Cache/cache/.cache 不在平台缓存契约内");
        require(!axs_cachekeeper_full_clear_path(fullOn,@"Library/Logs") &&
            !axs_cachekeeper_full_clear_path(fullOn,@"Library/Application Support") &&
            !axs_cachekeeper_full_clear_path(fullOn,@"Group/com.example/Library/Caches") &&
            !axs_cachekeeper_full_clear_path(fullOn,@"Documents") &&
            !axs_cachekeeper_full_clear_path(@{@"enabled":@YES},@"Library/Caches"), @"全量清理不越出缓存根：Logs 已归混合类、共享与受保护目录除外、未开开关不生效");
        NSDate *fixedDate=[NSDate dateWithTimeIntervalSince1970:1762852378];
        NSString *shown=axs_cachekeeper_time_string(fixedDate);
        NSDateFormatter *expect=[NSDateFormatter new];expect.dateFormat=@"yyyy-MM-dd HH:mm:ss";expect.timeZone=NSTimeZone.localTimeZone;expect.locale=[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        require([shown isEqual:[expect stringFromDate:fixedDate]] && shown.length==19 && ![shown containsString:@"+0000"], @"界面时间按设备本地时区显示，不用 NSDate 的 UTC 描述");
        require([axs_cachekeeper_time_string(nil) isEqual:@"时间未知"] && [axs_cachekeeper_time_string(@"2026") isEqual:@"时间未知"], @"非日期值显示时间未知");
        NSString *summaryText=axs_cachekeeper_summary(nil,@{@"updated":fixedDate,@"removed":@0,@"bytes":@0});
        require([summaryText containsString:shown] && ![summaryText containsString:@"+0000"], @"摘要中的最近检查使用本地时间");
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
        NSTimeZone *previousZone=NSTimeZone.defaultTimeZone;
        [NSTimeZone setDefaultTimeZone:[NSTimeZone timeZoneWithName:@"Asia/Shanghai"]];
        NSDate *epoch=[NSDate dateWithTimeIntervalSince1970:0];
        require([axs_cachekeeper_format_time(epoch,[NSTimeZone timeZoneWithName:@"Asia/Shanghai"]) isEqual:@"1970-01-01 08:00:00"] &&
            [axs_cachekeeper_format_time(epoch,[NSTimeZone timeZoneWithName:@"America/Los_Angeles"]) isEqual:@"1969-12-31 16:00:00"], @"实际格式器支持正负时差与跨日，不能使用 UTC 日期描述");
        NSCalendar *deviceCalendar=[[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
        deviceCalendar.timeZone=NSTimeZone.localTimeZone;
        NSDateComponents *deviceParts=[deviceCalendar components:NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay|NSCalendarUnitHour|NSCalendarUnitMinute|NSCalendarUnitSecond fromDate:epoch];
        NSString *deviceTime=[NSString stringWithFormat:@"%04ld-%02ld-%02ld %02ld:%02ld:%02ld",(long)deviceParts.year,(long)deviceParts.month,(long)deviceParts.day,(long)deviceParts.hour,(long)deviceParts.minute,(long)deviceParts.second];
        NSString *localSummary=axs_cachekeeper_summary(nil,@{@"updated":epoch});
        require([localSummary containsString:deviceTime] && ![localSummary containsString:@"+0000"],
            [NSString stringWithFormat:@"回执跟随设备时区而非进程默认时区（actual=%@; expected=%@）",localSummary,deviceTime]);
        [NSTimeZone setDefaultTimeZone:previousZone];
        require([axs_cachekeeper_time_string(@"broken date") isEqual:@"时间未知"], @"损坏时间字段显示未知而非伪造时间");
        NSArray *pathAliases=@[@"/private/var/example/cache",@"/var/example/cache"];
        require([axs_cachekeeper_enumerated_path(@"/var/example/cache/deep/file.png",pathAliases[0],pathAliases)
            isEqual:@"/private/var/example/cache/deep/file.png"] &&
            [axs_cachekeeper_enumerated_path(@"/private/var/example/cache/deep/",pathAliases[0],pathAliases)
            isEqual:@"/private/var/example/cache/deep"], @"仅转换根别名与目录尾斜杠，不改变后代路径");
        for (NSString *invalid in @[@"/var/example/cache-other/file",@"/var/example/cache/../outside",@"/var/example/cache/a//file",@"/var/example/cache/a/./file",@"/var/example/cache"])
            require(!axs_cachekeeper_enumerated_path(invalid,pathAliases[0],pathAliases), @"拒绝越界前缀、空组件与路径穿越");

        NSString *home=[fixture stringByAppendingPathComponent:@"app-home"];
        NSArray *directoryRoots=@[@"tmp",@"Library/Caches",@"Library/Logs",@"Library/Application Support",@"Library/HTTPStorages",@"Library/WebKit",@"Library/Cookies",@"Library/SplashBoard",@"Library/Saved Application State",@"Documents",@"CustomData",@".cache"];
        for (NSString *relative in directoryRoots) require([fm createDirectoryAtPath:[home stringByAppendingPathComponent:[relative stringByAppendingPathComponent:@"child/deep"]] withIntermediateDirectories:YES attributes:nil error:nil], @"目录扫描夹具");
        NSError *scanError=nil;
        NSArray *found=axs_cachekeeper_scan_directories([NSURL fileURLWithPath:home],&scanError);
        require(!scanError && ![found containsObject:@"Documents"] && ![found containsObject:@"Library/WebKit"] &&
            ![found containsObject:@"Library/Cookies"] && [found containsObject:@"Library/Application Support"] && [found containsObject:@"CustomData"], @"隐藏明确保护目录，混合用途与未知目录仍待分析");
        NSArray *purgeFound=axs_cachekeeper_purge_candidates([NSURL fileURLWithPath:home],&scanError);
        require([purgeFound containsObject:@"CustomData"] && [purgeFound containsObject:@"Library/Caches"], @"清理候选发现包含未知目录与缓存根（不能用 readOnly 过滤）");
        NSArray *purgeKept=axs_cachekeeper_purge_paths(purgeFound,@{@"enabled":@YES});
        require([purgeKept containsObject:@"CustomData"] && ![purgeKept containsObject:@"Library/Caches"] && ![purgeKept containsObject:@"Library/Logs"], @"清理候选集只保留未知目录");
        require([axs_cachekeeper_directory_kind(@"Library/Application Support") isEqual:@"mixed"] &&
            [axs_cachekeeper_directory_kind(@"CustomData") isEqual:@"unknown"] &&
            [axs_cachekeeper_directory_kind(@"Library/Preferences") isEqual:@"protected"], @"不把所有白名单外目录都当成必需数据");
        require(axs_cachekeeper_hidden_directory(@"Group/group.example/Library/Cookies") &&
            !axs_cachekeeper_hidden_directory(@"Library/Application Support"), @"共享敏感目录同样隐藏，混合数据不武断认定必需");
        NSArray *sorted=axs_cachekeeper_prioritized_rows(@[@{@"path":@"tmp",@"bytes":@1},@{@"path":@"Library/Caches",@"bytes":@999},@{@"path":@"Library/Logs",@"bytes":@500}],@[@"tmp"],@{@"enabled":@YES});
        require([sorted[0][@"path"] isEqual:@"Library/Caches"] && [sorted[1][@"path"] isEqual:@"tmp"], @"新 APP 默认自动发现开启：自动纳入的缓存根与已选同组置顶，同组按大小排序");
        NSArray *sortedOff=axs_cachekeeper_prioritized_rows(@[@{@"path":@"tmp",@"bytes":@1},@{@"path":@"Library/Caches",@"bytes":@999},@{@"path":@"Library/Logs",@"bytes":@500}],@[@"tmp"],@{@"enabled":@YES,@"autoDiscover":@NO});
        require([sortedOff[0][@"path"] isEqual:@"tmp"] && [sortedOff[1][@"path"] isEqual:@"Library/Caches"], @"明确关闭自动发现时，仅已选置顶，同组按大小排序");
        NSArray *sortedAuto=axs_cachekeeper_prioritized_rows(sorted,@[],@{@"enabled":@YES,@"autoDiscover":@YES,@"excludedPaths":@[@"Library/Caches"]});
        require([sortedAuto.lastObject[@"path"] isEqual:@"Library/Caches"], @"自动纳入与排除使用同一开启排序依据");
        NSArray *offSorted=axs_cachekeeper_prioritized_rows(sorted,@[@"tmp"],@{@"enabled":@NO,@"autoDiscover":@YES});
        require([offSorted.firstObject[@"path"] isEqual:@"Library/Caches"] && !axs_cachekeeper_effective_paths(@[@"tmp"],@{@"enabled":@NO,@"autoDiscover":@YES},@[@"Library/Caches"]).count, @"关闭 APP 时，残留选择和自动发现都不能点亮开关或置顶");
        require(!axs_cachekeeper_cache_path(@"Library/Logs") && [axs_cachekeeper_directory_kind(@"Library/Logs") isEqual:@"mixed"], @"日志不提供不能实际清理的开关");
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
        require([axs_cachekeeper_effective_paths(@[@"tmp"],automaticState,discovered) isEqual:@[@"Library/Caches",@"tmp"]], @"自动发现只纳入有清理支持的缓存根并按父目录去重");
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
        NSString *errorRoot=[fixture stringByAppendingPathComponent:@"unlink-error"];
        require([fm createDirectoryAtPath:errorRoot withIntermediateDirectories:YES attributes:nil error:nil], @"失败回执夹具");
        writeMedia([errorRoot stringByAppendingPathComponent:@"old.png"]);
        AxsCacheKeeperSweep *failureSweep=[[AxsCacheKeeperSweep alloc] initWithRoot:errorRoot clock:^NSTimeInterval{return future;} unlinkFile:^int(int fd,const char *name) {
            struct stat parent;require(!fstat(fd,&parent) && S_ISDIR(parent.st_mode) && !strcmp(name,"old.png"), @"删除仍限定已打开父目录和单一文件名");
            errno=EINVAL;return -1;
        }];
        for (NSUInteger pass=0;!failureSweep.complete && pass<20;pass++) [failureSweep advance:2 shouldContinue:^BOOL{return YES;}];
        require(failureSweep.complete && failureSweep.removed==0 && failureSweep.failed==1 &&
            [failureSweep.error containsString:@"unlinkat"] && [failureSweep.failureDetails.firstObject[@"code"] intValue]==EINVAL &&
            [failureSweep.failureDetails.firstObject[@"stage"] isEqual:@"unlinkat"] &&
            [fm fileExistsAtPath:[errorRoot stringByAppendingPathComponent:@"old.png"]], @"真实删除返回 EINVAL 时保留文件并准确记录调用阶段，不能冒充已清理");
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
        for (NSNumber *batchLimit in @[@1,@64]) {
            NSString *deepRoot=[fixture stringByAppendingPathComponent:[NSString stringWithFormat:@"deep-keys-%@",batchLimit]];
            require([fm createDirectoryAtPath:[deepRoot stringByAppendingPathComponent:@"a/b/c/d"] withIntermediateDirectories:YES attributes:nil error:nil], @"四级快照键夹具");
            writeMedia([deepRoot stringByAppendingPathComponent:@"root.png"]);
            writeMedia([deepRoot stringByAppendingPathComponent:@"a/b/c/d/image.png"]);
            require([fm createDirectoryAtPath:[deepRoot stringByAppendingPathComponent:@"store/assets"] withIntermediateDirectories:YES attributes:nil error:nil], @"数据库关联目录夹具");
            writeFile([deepRoot stringByAppendingPathComponent:@"store/data.sqlite"]);
            NSString *attachment=[deepRoot stringByAppendingPathComponent:@"store/assets/keep.png"];
            writeMedia(attachment);
            AxsCacheKeeperInspection *deepInspection=[[AxsCacheKeeperInspection alloc] initWithRoot:deepRoot];
            for (NSUInteger pass=0;!deepInspection.complete && pass<80;pass++) [deepInspection advance:batchLimit.unsignedIntegerValue];
            NSDictionary *deepProfile=[deepInspection report];
            require([deepProfile[@"coverageComplete"] boolValue] && [deepProfile[@"files"] unsignedIntegerValue]==4, @"深度检测用同一规范路径读取完整四级目录");
            AxsCacheKeeperSweep *deepSweep=[[AxsCacheKeeperSweep alloc] initWithRoot:deepRoot clock:^NSTimeInterval{return future;}];
            for (NSUInteger pass=0;!deepSweep.complete && pass<100;pass++) [deepSweep advance:batchLimit.unsignedIntegerValue shouldContinue:^BOOL{return YES;}];
            require(deepSweep.complete && deepSweep.removed==2 && deepSweep.failed==0 && deepSweep.changedCount==0 &&
                [fm fileExistsAtPath:attachment], @"大小批次都使用一致的父目录与快照键，数据库后代继续保留");
        }
        NSString *replacedRoot=[fixture stringByAppendingPathComponent:@"replaced-root"];
        NSString *externalRoot=[fixture stringByAppendingPathComponent:@"external-root"];
        require([fm createDirectoryAtPath:replacedRoot withIntermediateDirectories:YES attributes:nil error:nil] &&
            [fm createDirectoryAtPath:[externalRoot stringByAppendingPathComponent:@"child"] withIntermediateDirectories:YES attributes:nil error:nil], @"根目录替换夹具");
        NSString *externalMedia=[externalRoot stringByAppendingPathComponent:@"keep.png"];
        writeMedia(externalMedia);writeMedia([replacedRoot stringByAppendingPathComponent:@"old.png"]);
        AxsCacheKeeperSweep *replaced=[[AxsCacheKeeperSweep alloc] initWithRoot:replacedRoot clock:^NSTimeInterval{return future;}];
        for (NSUInteger pass=0;replaced.checking && !replaced.complete && pass<20;pass++) [replaced advance:1 shouldContinue:^BOOL{return YES;}];
        require(!replaced.checking && !replaced.complete && replaced.removed==0, @"根替换发生在完整预检后且删除前");
        require([fm moveItemAtPath:replacedRoot toPath:[replacedRoot stringByAppendingString:@"-saved"] error:nil] &&
            !symlink(externalRoot.fileSystemRepresentation,replacedRoot.fileSystemRepresentation), @"预检后用链接替换根目录");
        [replaced advance:64 shouldContinue:^BOOL{return YES;}];
        require(replaced.complete && replaced.removed==0 && replaced.failed>0 && [fm fileExistsAtPath:externalMedia], @"根目录被换成链接时停止清理，外部媒体仍保留");
        int linked=axs_cachekeeper_open_directory(replacedRoot);
        require(linked<0, @"共享访问函数继续拒绝末级目录链接");
        linked=axs_cachekeeper_open_directory([replacedRoot stringByAppendingPathComponent:@"child"]);
        require(linked>=0, @"中间目录链接按 #27 跟随（真机容器路径含 /var 等中间链接），仅末级链接拒绝；根替换安全由 sweep 的身份核对保证");
        if (linked>=0) close(linked);
        NSString *fullRoot=[fixture stringByAppendingPathComponent:@"full-cache"];
        require([fm createDirectoryAtPath:[fullRoot stringByAppendingPathComponent:@"store"] withIntermediateDirectories:YES attributes:nil error:nil], @"全量清理夹具");
        writeMedia([fullRoot stringByAppendingPathComponent:@"clip.mp4"]);
        writeFile([fullRoot stringByAppendingPathComponent:@"blob.bin"]);
        require([@"SQLite format 3\0payload" writeToFile:[fullRoot stringByAppendingPathComponent:@"state.sqlite"] atomically:YES encoding:NSUTF8StringEncoding error:nil], @"全量清理数据库夹具");
        writeFile([fullRoot stringByAppendingPathComponent:@"store/inner.sqlite"]);
        writeMedia([fullRoot stringByAppendingPathComponent:@"store/poster.png"]);
        AxsCacheKeeperSweep *mediaOnly=[[AxsCacheKeeperSweep alloc] initWithRoot:fullRoot clock:^NSTimeInterval{return future;}];
        for (NSUInteger pass=0;!mediaOnly.complete && pass<100;pass++) [mediaOnly advance:64 shouldContinue:^BOOL{return YES;}];
        require(mediaOnly.complete && mediaOnly.removed==0 &&
            [fm fileExistsAtPath:[fullRoot stringByAppendingPathComponent:@"clip.mp4"]] &&
            [fm fileExistsAtPath:[fullRoot stringByAppendingPathComponent:@"state.sqlite"]], @"对照：根目录含数据库时普通模式整根保留");
        AxsCacheKeeperSweep *fullSweep=[[AxsCacheKeeperSweep alloc] initWithRoot:fullRoot clock:^NSTimeInterval{return future;} fullClear:YES];
        for (NSUInteger pass=0;!fullSweep.complete && pass<100;pass++) [fullSweep advance:64 shouldContinue:^BOOL{return YES;}];
        require(fullSweep.complete && fullSweep.failed==0 && fullSweep.removed==5,
            [NSString stringWithFormat:@"全量清理删除根内全部普通文件（removed=%lu failed=%lu）",(unsigned long)fullSweep.removed,(unsigned long)fullSweep.failed]);
        require(![fm fileExistsAtPath:[fullRoot stringByAppendingPathComponent:@"clip.mp4"]] &&
            ![fm fileExistsAtPath:[fullRoot stringByAppendingPathComponent:@"blob.bin"]] &&
            ![fm fileExistsAtPath:[fullRoot stringByAppendingPathComponent:@"state.sqlite"]] &&
            ![fm fileExistsAtPath:[fullRoot stringByAppendingPathComponent:@"store/inner.sqlite"]] &&
            ![fm fileExistsAtPath:[fullRoot stringByAppendingPathComponent:@"store/poster.png"]] &&
            [fm fileExistsAtPath:fullRoot] && [fm fileExistsAtPath:[fullRoot stringByAppendingPathComponent:@"store"]], @"全量清理后文件清空、目录本身保留");
        // 真机形态（抖音 2026-11-11）：数据文件藏在子目录里而非根级——普通模式只删根级散落媒体、整棵数据子树保留；
        // 全量清理必须能删净该子树内全部文件且不报阶段错误（此前真机 263 项 errno 22 全灭）。
        NSString *nestedRoot=[fixture stringByAppendingPathComponent:@"nested-cache"];
        require([fm createDirectoryAtPath:[nestedRoot stringByAppendingPathComponent:@"vault"] withIntermediateDirectories:YES attributes:nil error:nil], @"嵌套数据子树夹具");
        writeMedia([nestedRoot stringByAppendingPathComponent:@"loose.png"]);
        writeFile([nestedRoot stringByAppendingPathComponent:@"vault/inner.sqlite"]);
        writeMedia([nestedRoot stringByAppendingPathComponent:@"vault/photo.png"]);
        writeMedia([nestedRoot stringByAppendingPathComponent:@"vault/clip.mp4"]);
        AxsCacheKeeperSweep *nestedMedia=[[AxsCacheKeeperSweep alloc] initWithRoot:nestedRoot clock:^NSTimeInterval{return future;}];
        for (NSUInteger pass=0;!nestedMedia.complete && pass<100;pass++) [nestedMedia advance:64 shouldContinue:^BOOL{return YES;}];
        require(nestedMedia.complete && nestedMedia.removed==1 && nestedMedia.failed==0 &&
            ![fm fileExistsAtPath:[nestedRoot stringByAppendingPathComponent:@"loose.png"]] &&
            [fm fileExistsAtPath:[nestedRoot stringByAppendingPathComponent:@"vault/photo.png"]] &&
            [fm fileExistsAtPath:[nestedRoot stringByAppendingPathComponent:@"vault/inner.sqlite"]], @"普通模式删根级媒体、数据子树整棵保留");
        AxsCacheKeeperSweep *nestedFull=[[AxsCacheKeeperSweep alloc] initWithRoot:nestedRoot clock:^NSTimeInterval{return future;} fullClear:YES];
        for (NSUInteger pass=0;!nestedFull.complete && pass<100;pass++) [nestedFull advance:64 shouldContinue:^BOOL{return YES;}];
        require(nestedFull.complete && nestedFull.failed==0 && nestedFull.removed==3 && !nestedFull.error.length &&
            ![fm fileExistsAtPath:[nestedRoot stringByAppendingPathComponent:@"vault/inner.sqlite"]] &&
            ![fm fileExistsAtPath:[nestedRoot stringByAppendingPathComponent:@"vault/photo.png"]] &&
            ![fm fileExistsAtPath:[nestedRoot stringByAppendingPathComponent:@"vault/clip.mp4"]] &&
            [fm fileExistsAtPath:[nestedRoot stringByAppendingPathComponent:@"vault"]],
            [NSString stringWithFormat:@"全量清理删净嵌套数据子树（removed=%lu failed=%lu error=%@）",(unsigned long)nestedFull.removed,(unsigned long)nestedFull.failed,nestedFull.error]);
        // 日志定级通道（通用机制，2026-11-11）：定级只接受用途未知目录；日志模式只删日志特征文件，
        // 媒体/文本保留，数据子树整棵保留（含其内日志文件）。
        require(axs_cachekeeper_log_file_name(@"BDALog_20261111_193314.alog.iOS.1128"), @"复合后缀日志名命中");
        require(axs_cachekeeper_log_file_name(@"app.log") && axs_cachekeeper_log_file_name(@"mm.xlog"), @"标准日志扩展名命中");
        require(!axs_cachekeeper_log_file_name(@"photo.jpg") && !axs_cachekeeper_log_file_name(@"notes.txt") && !axs_cachekeeper_log_file_name(@"catalog"), @"非日志名不命中");
        NSDictionary *judgedState=@{@"enabled":@YES,@"logPaths":@[@"Library/alog",@"Library/Caches",@"Documents",@"Library",@"Library/Preferences"]};
        require([axs_cachekeeper_log_paths(judgedState) isEqual:@[@"Library/alog"]], @"定级路径只接受用途未知目录");
        NSDictionary *judgedEnabled=@{@"enabled":@YES,@"mode":@"auto",@"logPaths":@[@"Library/alog"]};
        require([axs_cachekeeper_effective_paths(@[],judgedEnabled,@[]) containsObject:@"Library/alog"], @"定级目录进入有效根");
        require([axs_cachekeeper_app_state(judgedEnabled,YES)[@"logPaths"] isEqual:@[@"Library/alog"]], @"状态保存保留定级清单");
        NSString *gradeFolder=[fixture stringByAppendingPathComponent:@"grade-config"];
        require([fm createDirectoryAtPath:gradeFolder withIntermediateDirectories:YES attributes:nil error:nil], @"定级配置夹具");
        require(!axs_cachekeeper_set_log_path(gradeFolder,@"com.example.app",@"Library/alog",YES), @"定级保存成功");
        NSDictionary *gradeStates=[NSDictionary dictionaryWithContentsOfFile:[gradeFolder stringByAppendingPathComponent:@"appEnabled.plist"]];
        require([axs_cachekeeper_log_paths(gradeStates[@"com.example.app"]) isEqual:@[@"Library/alog"]], @"定级回读一致");
        require(axs_cachekeeper_set_log_path(gradeFolder,@"com.example.app",@"Library/Caches",YES).length>0, @"标准缓存根不可定级");
        require(!axs_cachekeeper_set_log_path(gradeFolder,@"com.example.app",@"Library/alog",NO), @"取消定级成功");
        require(axs_cachekeeper_log_paths([NSDictionary dictionaryWithContentsOfFile:[gradeFolder stringByAppendingPathComponent:@"appEnabled.plist"]][@"com.example.app"]).count==0, @"取消定级回读为空");
        NSString *logRoot=[fixture stringByAppendingPathComponent:@"Library/alog"];
        require([fm createDirectoryAtPath:[logRoot stringByAppendingPathComponent:@"ready"] withIntermediateDirectories:YES attributes:nil error:nil], @"日志目录夹具");
        require([fm createDirectoryAtPath:[logRoot stringByAppendingPathComponent:@"vault"] withIntermediateDirectories:YES attributes:nil error:nil], @"日志目录数据子树夹具");
        writeFile([logRoot stringByAppendingPathComponent:@"ready/BDALog_20261111_193314.alog.iOS.1128"]);
        writeFile([logRoot stringByAppendingPathComponent:@"ready/today.log"]);
        writeMedia([logRoot stringByAppendingPathComponent:@"ready/poster.png"]);
        writeFile([logRoot stringByAppendingPathComponent:@"ready/notes.txt"]);
        writeFile([logRoot stringByAppendingPathComponent:@"top.alog"]);
        writeFile([logRoot stringByAppendingPathComponent:@"vault/inner.sqlite"]);
        writeFile([logRoot stringByAppendingPathComponent:@"vault/inside.log"]);
        AxsCacheKeeperSweep *logSweep=[[AxsCacheKeeperSweep alloc] initWithRoot:logRoot clock:^NSTimeInterval{return future;} fullClear:NO logMode:YES];
        for (NSUInteger pass=0;!logSweep.complete && pass<100;pass++) [logSweep advance:64 shouldContinue:^BOOL{return YES;}];
        require(logSweep.complete && logSweep.failed==0 && logSweep.removed==4,
            [NSString stringWithFormat:@"日志模式只删日志特征文件（removed=%lu failed=%lu error=%@）",(unsigned long)logSweep.removed,(unsigned long)logSweep.failed,logSweep.error]);
        require(![fm fileExistsAtPath:[logRoot stringByAppendingPathComponent:@"ready/BDALog_20261111_193314.alog.iOS.1128"]] &&
            ![fm fileExistsAtPath:[logRoot stringByAppendingPathComponent:@"ready/today.log"]] &&
            ![fm fileExistsAtPath:[logRoot stringByAppendingPathComponent:@"top.alog"]] &&
            [fm fileExistsAtPath:[logRoot stringByAppendingPathComponent:@"ready/poster.png"]] &&
            [fm fileExistsAtPath:[logRoot stringByAppendingPathComponent:@"ready/notes.txt"]] &&
            [fm fileExistsAtPath:[logRoot stringByAppendingPathComponent:@"vault/inner.sqlite"]] &&
            ![fm fileExistsAtPath:[logRoot stringByAppendingPathComponent:@"vault/inside.log"]], @"日志模式文件级保护：数据文件本体保留，其旁的日志文件照常清理");
        // 混放目录（真机 alog 的 ready/ 形态）：数据名文件、SQLite 头文件与纯日志同目录时，
        // 数据文件只保护自身，不得整目录连坐；深层嵌套（四级）日志必须能走到删除（祖先链记录键回归）。
        NSString *mixedRoot=[fixture stringByAppendingPathComponent:@"mixed-log"];
        require([fm createDirectoryAtPath:[mixedRoot stringByAppendingPathComponent:@"ready"] withIntermediateDirectories:YES attributes:nil error:nil], @"混放日志目录夹具");
        writeFile([mixedRoot stringByAppendingPathComponent:@"ready/pure-one.alog"]);
        writeFile([mixedRoot stringByAppendingPathComponent:@"ready/pure-two.log"]);
        writeFile([mixedRoot stringByAppendingPathComponent:@"ready/000003.log"]);
        require([@"SQLite format 3\0payload" writeToFile:[mixedRoot stringByAppendingPathComponent:@"ready/fake.alog"] atomically:YES encoding:NSUTF8StringEncoding error:nil], @"伪装日志名的数据库夹具");
        writeFile([mixedRoot stringByAppendingPathComponent:@"ready/plain.txt"]);
        AxsCacheKeeperSweep *mixedSweep=[[AxsCacheKeeperSweep alloc] initWithRoot:mixedRoot clock:^NSTimeInterval{return future;} fullClear:NO logMode:YES];
        for (NSUInteger pass=0;!mixedSweep.complete && pass<100;pass++) [mixedSweep advance:64 shouldContinue:^BOOL{return YES;}];
        require(mixedSweep.complete && mixedSweep.failed==0 && mixedSweep.removed==2,
            [NSString stringWithFormat:@"混放目录只删纯日志（removed=%lu failed=%lu error=%@）",(unsigned long)mixedSweep.removed,(unsigned long)mixedSweep.failed,mixedSweep.error]);
        require(![fm fileExistsAtPath:[mixedRoot stringByAppendingPathComponent:@"ready/pure-one.alog"]] &&
            ![fm fileExistsAtPath:[mixedRoot stringByAppendingPathComponent:@"ready/pure-two.log"]] &&
            [fm fileExistsAtPath:[mixedRoot stringByAppendingPathComponent:@"ready/000003.log"]] &&
            [fm fileExistsAtPath:[mixedRoot stringByAppendingPathComponent:@"ready/fake.alog"]] &&
            [fm fileExistsAtPath:[mixedRoot stringByAppendingPathComponent:@"ready/plain.txt"]], @"数据名文件、数据库头文件与非日志文件保留");
        NSString *deepRoot=[fixture stringByAppendingPathComponent:@"deep-log"];
        require([fm createDirectoryAtPath:[deepRoot stringByAppendingPathComponent:@"a/b/c/d"] withIntermediateDirectories:YES attributes:nil error:nil], @"深层日志目录夹具");
        writeFile([deepRoot stringByAppendingPathComponent:@"a/b/c/d/deep.alog"]);
        writeFile([deepRoot stringByAppendingPathComponent:@"a/b/mid.log"]);
        AxsCacheKeeperSweep *deepSweep=[[AxsCacheKeeperSweep alloc] initWithRoot:deepRoot clock:^NSTimeInterval{return future;} fullClear:NO logMode:YES];
        for (NSUInteger pass=0;!deepSweep.complete && pass<100;pass++) [deepSweep advance:64 shouldContinue:^BOOL{return YES;}];
        require(deepSweep.complete && deepSweep.failed==0 && deepSweep.removed==2 &&
            ![fm fileExistsAtPath:[deepRoot stringByAppendingPathComponent:@"a/b/c/d/deep.alog"]] &&
            ![fm fileExistsAtPath:[deepRoot stringByAppendingPathComponent:@"a/b/mid.log"]],
            [NSString stringWithFormat:@"四级嵌套日志可删（removed=%lu failed=%lu error=%@）",(unsigned long)deepSweep.removed,(unsigned long)deepSweep.failed,deepSweep.error]);
        // 热目录稳定性（2026-11-11 抖音 alog 真机：目录级门下 14 个目录判变化、整轮删除 0）：
        // 预检后同目录兄弟文件被改写时，日志模式只跳过变化文件本身，其余预检通过的日志照常删除；
        // 目录级模式（全量清理对照）则整目录跳过，两档差异必须保持。
        NSString *hotRoot=[fixture stringByAppendingPathComponent:@"hot-log"];
        require([fm createDirectoryAtPath:[hotRoot stringByAppendingPathComponent:@"ready"] withIntermediateDirectories:YES attributes:nil error:nil], @"热日志目录夹具");
        writeFile([hotRoot stringByAppendingPathComponent:@"ready/stable-one.alog"]);
        writeFile([hotRoot stringByAppendingPathComponent:@"ready/stable-two.log"]);
        writeFile([hotRoot stringByAppendingPathComponent:@"ready/keep-changing.log"]);
        AxsCacheKeeperSweep *hotLog=[[AxsCacheKeeperSweep alloc] initWithRoot:hotRoot clock:^NSTimeInterval{return future;} fullClear:NO logMode:YES];
        for (NSUInteger pass=0;hotLog.checking && !hotLog.complete && pass<100;pass++) [hotLog advance:1 shouldContinue:^BOOL{return YES;}];
        require(!hotLog.checking && hotLog.removed==0, @"热目录预检阶段不删除");
        writeFile([hotRoot stringByAppendingPathComponent:@"ready/keep-changing.log"]);
        for (NSUInteger pass=0;!hotLog.complete && pass<100;pass++) [hotLog advance:64 shouldContinue:^BOOL{return YES;}];
        require(hotLog.complete && hotLog.failed==0 && hotLog.removed==2 && hotLog.changedCount>0,
            [NSString stringWithFormat:@"日志模式文件级稳定性门：兄弟变化只跳过自身（removed=%lu failed=%lu changed=%lu error=%@）",(unsigned long)hotLog.removed,(unsigned long)hotLog.failed,(unsigned long)hotLog.changedCount,hotLog.error]);
        require(![fm fileExistsAtPath:[hotRoot stringByAppendingPathComponent:@"ready/stable-one.alog"]] &&
            ![fm fileExistsAtPath:[hotRoot stringByAppendingPathComponent:@"ready/stable-two.log"]] &&
            [fm fileExistsAtPath:[hotRoot stringByAppendingPathComponent:@"ready/keep-changing.log"]], @"变化文件保留、稳定日志删除");
        NSString *hotRoot2=[fixture stringByAppendingPathComponent:@"hot-full"];
        require([fm createDirectoryAtPath:[hotRoot2 stringByAppendingPathComponent:@"ready"] withIntermediateDirectories:YES attributes:nil error:nil], @"热目录对照夹具");
        writeFile([hotRoot2 stringByAppendingPathComponent:@"ready/stable-one.alog"]);
        writeFile([hotRoot2 stringByAppendingPathComponent:@"ready/stable-two.log"]);
        writeFile([hotRoot2 stringByAppendingPathComponent:@"ready/keep-changing.log"]);
        AxsCacheKeeperSweep *hotFull=[[AxsCacheKeeperSweep alloc] initWithRoot:hotRoot2 clock:^NSTimeInterval{return future;} fullClear:YES];
        for (NSUInteger pass=0;hotFull.checking && !hotFull.complete && pass<100;pass++) [hotFull advance:1 shouldContinue:^BOOL{return YES;}];
        writeFile([hotRoot2 stringByAppendingPathComponent:@"ready/keep-changing.log"]);
        for (NSUInteger pass=0;!hotFull.complete && pass<100;pass++) [hotFull advance:64 shouldContinue:^BOOL{return YES;}];
        require(hotFull.complete && hotFull.removed==0 &&
            [fm fileExistsAtPath:[hotRoot2 stringByAppendingPathComponent:@"ready/stable-one.alog"]], @"对照：目录级稳定性门下兄弟变化整目录保留");
        // 未知目录自动清理（B 案，2026-11-12）：预检即全目录内容审查，任一数据证据整根出局；
        // 零证据的目录按文件级稳定性门全清（含媒体、文本、运行时文件与配置类 .plist/.json）；
        // 全新 APP 默认自动发现开启，只开总开关即全自动。
        require(axs_cachekeeper_auto_discover(nil) && axs_cachekeeper_auto_discover(@{@"enabled":@YES}), @"全新 APP 默认自动发现开启");
        require(!axs_cachekeeper_auto_discover(@{@"autoDiscover":@NO}), @"已明确关闭自动发现的保持关闭");
        require([axs_cachekeeper_app_state(nil,YES)[@"autoDiscover"] boolValue], @"全新 APP 状态保存默认自动发现开启");
        require([axs_cachekeeper_purge_paths(@[@"Library/tma",@"Library/alog",@"Library/Caches",@"Library/Preferences"],@{@"enabled":@YES,@"logPaths":@[@"Library/alog"]}) isEqual:@[@"Library/tma"]], @"清理候选集只取未定级未知目录");
        NSString *excludeFolder=[fixture stringByAppendingPathComponent:@"exclude-state"];
        require([fm createDirectoryAtPath:excludeFolder withIntermediateDirectories:YES attributes:nil error:nil], @"排除状态夹具");
        require(!axs_cachekeeper_set_excluded_path(excludeFolder,@"com.example.app",@"Library/tma",YES), @"未知目录可单独保留");
        NSDictionary *excludedState=[NSDictionary dictionaryWithContentsOfFile:[excludeFolder stringByAppendingPathComponent:@"appEnabled.plist"]][@"com.example.app"];
        require([axs_cachekeeper_exclusions(excludedState) containsObject:@"Library/tma"] &&
            ![axs_cachekeeper_purge_paths(@[@"Library/tma",@"Library/Pitaya"],excludedState) containsObject:@"Library/tma"], @"保留的未知目录退出内容审查候选集");
        require([axs_cachekeeper_exclusions(axs_cachekeeper_app_state(excludedState,YES)) containsObject:@"Library/tma"], @"切模式/总开关保留未知目录的保留选择");
        require(!axs_cachekeeper_set_excluded_path(excludeFolder,@"com.example.app",@"Library/tma",NO), @"保留可取消，恢复自动审查");
        NSDictionary *unexcludedState=[NSDictionary dictionaryWithContentsOfFile:[excludeFolder stringByAppendingPathComponent:@"appEnabled.plist"]][@"com.example.app"];
        require(![axs_cachekeeper_exclusions(unexcludedState) containsObject:@"Library/tma"] &&
            [axs_cachekeeper_purge_paths(@[@"Library/tma",@"Library/Pitaya"],unexcludedState) containsObject:@"Library/tma"], @"取消保留后恢复为清理候选");
        NSString *purgeRoot=[fixture stringByAppendingPathComponent:@"purge-clean"];
        require([fm createDirectoryAtPath:[purgeRoot stringByAppendingPathComponent:@"runtime"] withIntermediateDirectories:YES attributes:nil error:nil], @"清理目录夹具");
        writeMedia([purgeRoot stringByAppendingPathComponent:@"runtime/model.bin"]);
        writeFile([purgeRoot stringByAppendingPathComponent:@"runtime/config.json"]);
        writeFile([purgeRoot stringByAppendingPathComponent:@"runtime/settings.plist"]);
        writeFile([purgeRoot stringByAppendingPathComponent:@"top.txt"]);
        AxsCacheKeeperSweep *purgeClean=[[AxsCacheKeeperSweep alloc] initWithRoot:purgeRoot clock:^NSTimeInterval{return future;} fullClear:NO logMode:NO purgeMode:YES];
        for (NSUInteger pass=0;!purgeClean.complete && pass<100;pass++) [purgeClean advance:64 shouldContinue:^BOOL{return YES;}];
        require(purgeClean.complete && purgeClean.failed==0 && purgeClean.removed==4 && !purgeClean.purgeBlocked && !purgeClean.purgeEvidence,
            [NSString stringWithFormat:@"无数据证据的未知目录全清（removed=%lu failed=%lu error=%@）",(unsigned long)purgeClean.removed,(unsigned long)purgeClean.failed,purgeClean.error]);
        require(![fm fileExistsAtPath:[purgeRoot stringByAppendingPathComponent:@"runtime/model.bin"]] &&
            ![fm fileExistsAtPath:[purgeRoot stringByAppendingPathComponent:@"runtime/config.json"]] &&
            ![fm fileExistsAtPath:[purgeRoot stringByAppendingPathComponent:@"runtime/settings.plist"]] &&
            ![fm fileExistsAtPath:[purgeRoot stringByAppendingPathComponent:@"top.txt"]], @"运行时文件与配置类文件随目录清理");
        NSString *purgeDb=[fixture stringByAppendingPathComponent:@"purge-db"];
        require([fm createDirectoryAtPath:purgeDb withIntermediateDirectories:YES attributes:nil error:nil], @"含数据库的清理目录夹具");
        writeMedia([purgeDb stringByAppendingPathComponent:@"thumb.png"]);
        require([@"SQLite format 3\0payload" writeToFile:[purgeDb stringByAppendingPathComponent:@"hidden.bin"] atomically:YES encoding:NSUTF8StringEncoding error:nil], @"伪装数据库夹具");
        AxsCacheKeeperSweep *purgeDbSweep=[[AxsCacheKeeperSweep alloc] initWithRoot:purgeDb clock:^NSTimeInterval{return future;} fullClear:NO logMode:NO purgeMode:YES];
        for (NSUInteger pass=0;!purgeDbSweep.complete && pass<100;pass++) [purgeDbSweep advance:64 shouldContinue:^BOOL{return YES;}];
        require(purgeDbSweep.complete && purgeDbSweep.failed==0 && purgeDbSweep.removed==0 && purgeDbSweep.purgeMixed && !purgeDbSweep.purgeBlocked && [purgeDbSweep.purgeEvidence isEqual:@"hidden.bin"] &&
            [fm fileExistsAtPath:[purgeDb stringByAppendingPathComponent:@"thumb.png"]] &&
            [fm fileExistsAtPath:[purgeDb stringByAppendingPathComponent:@"hidden.bin"]], @"伪装数据库自动降级为日志门、非日志文件零删除");
        NSString *purgeMixedDir=[fixture stringByAppendingPathComponent:@"purge-mixed"];
        require([fm createDirectoryAtPath:purgeMixedDir withIntermediateDirectories:YES attributes:nil error:nil], @"日志与数据混放的清理目录夹具");
        writeFile([purgeMixedDir stringByAppendingPathComponent:@"app.log"]);
        require([@"SQLite format 3\0payload" writeToFile:[purgeMixedDir stringByAppendingPathComponent:@"data.bin"] atomically:YES encoding:NSUTF8StringEncoding error:nil], @"混放数据库夹具");
        writeFile([purgeMixedDir stringByAppendingPathComponent:@"notes.txt"]);
        AxsCacheKeeperSweep *purgeMixedSweep=[[AxsCacheKeeperSweep alloc] initWithRoot:purgeMixedDir clock:^NSTimeInterval{return future;} fullClear:NO logMode:NO purgeMode:YES];
        for (NSUInteger pass=0;!purgeMixedSweep.complete && pass<100;pass++) [purgeMixedSweep advance:64 shouldContinue:^BOOL{return YES;}];
        require(purgeMixedSweep.complete && purgeMixedSweep.failed==0 && purgeMixedSweep.removed==1 && purgeMixedSweep.purgeMixed && !purgeMixedSweep.purgeBlocked && [purgeMixedSweep.purgeEvidence isEqual:@"data.bin"] &&
            ![fm fileExistsAtPath:[purgeMixedDir stringByAppendingPathComponent:@"app.log"]] &&
            [fm fileExistsAtPath:[purgeMixedDir stringByAppendingPathComponent:@"data.bin"]] &&
            [fm fileExistsAtPath:[purgeMixedDir stringByAppendingPathComponent:@"notes.txt"]], @"混放目录自动仅清理日志文件、数据与未知内容保留");
        NSString *purgeNamed=[fixture stringByAppendingPathComponent:@"purge-named"];
        require([fm createDirectoryAtPath:[purgeNamed stringByAppendingPathComponent:@"Preferences"] withIntermediateDirectories:YES attributes:nil error:nil], @"含受保护子目录的清理夹具");
        writeFile([purgeNamed stringByAppendingPathComponent:@"Preferences/a.txt"]);
        writeFile([purgeNamed stringByAppendingPathComponent:@"plain.txt"]);
        AxsCacheKeeperSweep *purgeNamedSweep=[[AxsCacheKeeperSweep alloc] initWithRoot:purgeNamed clock:^NSTimeInterval{return future;} fullClear:NO logMode:NO purgeMode:YES];
        for (NSUInteger pass=0;!purgeNamedSweep.complete && pass<100;pass++) [purgeNamedSweep advance:64 shouldContinue:^BOOL{return YES;}];
        require(purgeNamedSweep.complete && purgeNamedSweep.removed==0 && purgeNamedSweep.purgeBlocked && !purgeNamedSweep.purgeMixed && [purgeNamedSweep.purgeEvidence isEqual:@"Preferences"] &&
            [fm fileExistsAtPath:[purgeNamed stringByAppendingPathComponent:@"Preferences/a.txt"]] &&
            [fm fileExistsAtPath:[purgeNamed stringByAppendingPathComponent:@"plain.txt"]], @"受保护子目录整根出局、连日志也不删（审计第 1 项：预检即按受保护路径否决）");
        NSString *purgeDirNamed=[fixture stringByAppendingPathComponent:@"purge-dirnamed"];
        require([fm createDirectoryAtPath:[purgeDirNamed stringByAppendingPathComponent:@"session-cache"] withIntermediateDirectories:YES attributes:nil error:nil], @"含数据标记子目录的清理夹具");
        writeFile([purgeDirNamed stringByAppendingPathComponent:@"session-cache/a.txt"]);
        writeFile([purgeDirNamed stringByAppendingPathComponent:@"run.log"]);
        AxsCacheKeeperSweep *purgeDirNamedSweep=[[AxsCacheKeeperSweep alloc] initWithRoot:purgeDirNamed clock:^NSTimeInterval{return future;} fullClear:NO logMode:NO purgeMode:YES];
        for (NSUInteger pass=0;!purgeDirNamedSweep.complete && pass<100;pass++) [purgeDirNamedSweep advance:64 shouldContinue:^BOOL{return YES;}];
        require(purgeDirNamedSweep.complete && purgeDirNamedSweep.failed==0 && purgeDirNamedSweep.removed==0 && purgeDirNamedSweep.purgeBlocked && !purgeDirNamedSweep.purgeMixed && [purgeDirNamedSweep.purgeEvidence isEqual:@"session-cache"] &&
            [fm fileExistsAtPath:[purgeDirNamed stringByAppendingPathComponent:@"session-cache/a.txt"]] &&
            [fm fileExistsAtPath:[purgeDirNamed stringByAppendingPathComponent:@"run.log"]], @"数据标记子目录名整根出局、连日志也不删");
        // 数据安全（审计第 1 项）：混合目录日志门受保护路径否决。inbox.log 含受保护成分
        //（inbox）但无数据标记，旧日志门只看名字会删掉它；现须保留，普通日志仍可删。
        NSString *purgeProtectedFile=[fixture stringByAppendingPathComponent:@"purge-protected-file"];
        require([fm createDirectoryAtPath:purgeProtectedFile withIntermediateDirectories:YES attributes:nil error:nil], @"受保护文件名混放的清理夹具");
        writeFile([purgeProtectedFile stringByAppendingPathComponent:@"app.log"]);
        writeFile([purgeProtectedFile stringByAppendingPathComponent:@"inbox.log"]);
        require([@"SQLite format 3\0payload" writeToFile:[purgeProtectedFile stringByAppendingPathComponent:@"data.bin"] atomically:YES encoding:NSUTF8StringEncoding error:nil], @"受保护文件名混放数据库夹具");
        AxsCacheKeeperSweep *purgeProtectedFileSweep=[[AxsCacheKeeperSweep alloc] initWithRoot:purgeProtectedFile clock:^NSTimeInterval{return future;} fullClear:NO logMode:NO purgeMode:YES];
        for (NSUInteger pass=0;!purgeProtectedFileSweep.complete && pass<100;pass++) [purgeProtectedFileSweep advance:64 shouldContinue:^BOOL{return YES;}];
        require(purgeProtectedFileSweep.complete && purgeProtectedFileSweep.failed==0 && purgeProtectedFileSweep.removed==1 && purgeProtectedFileSweep.purgeMixed && !purgeProtectedFileSweep.purgeBlocked && ([purgeProtectedFileSweep.purgeEvidence isEqual:@"inbox.log"] || [purgeProtectedFileSweep.purgeEvidence isEqual:@"data.bin"]) &&
            ![fm fileExistsAtPath:[purgeProtectedFile stringByAppendingPathComponent:@"app.log"]] &&
            [fm fileExistsAtPath:[purgeProtectedFile stringByAppendingPathComponent:@"inbox.log"]] &&
            [fm fileExistsAtPath:[purgeProtectedFile stringByAppendingPathComponent:@"data.bin"]], @"混合目录日志门受保护路径否决：inbox.log 保留、普通日志删除");
        // 数据安全（审计第 3 项）：清理模式读不到内容的文件须落盘保护（入 dataFiles、计失败），
        // 否则混合后日志门会按名字删掉它；删除阶段亦查 dataFiles。
        NSString *purgeUnreadable=[fixture stringByAppendingPathComponent:@"purge-unreadable"];
        require([fm createDirectoryAtPath:purgeUnreadable withIntermediateDirectories:YES attributes:nil error:nil], @"含不可读文件的清理夹具");
        NSString *unreadableLog=[purgeUnreadable stringByAppendingPathComponent:@"secret.log"];
        writeFile(unreadableLog);
        writeMedia([purgeUnreadable stringByAppendingPathComponent:@"thumb.png"]);
        require(!chmod(unreadableLog.fileSystemRepresentation, 0000), @"不可读文件夹具");
        AxsCacheKeeperSweep *purgeUnreadableSweep=[[AxsCacheKeeperSweep alloc] initWithRoot:purgeUnreadable clock:^NSTimeInterval{return future;} fullClear:NO logMode:NO purgeMode:YES];
        for (NSUInteger pass=0;!purgeUnreadableSweep.complete && pass<100;pass++) [purgeUnreadableSweep advance:64 shouldContinue:^BOOL{return YES;}];
        chmod(unreadableLog.fileSystemRepresentation, 0644);
        require(purgeUnreadableSweep.complete && purgeUnreadableSweep.failed>0 && purgeUnreadableSweep.removed==0 && purgeUnreadableSweep.purgeMixed && [purgeUnreadableSweep.purgeEvidence isEqual:@"secret.log"] &&
            [fm fileExistsAtPath:unreadableLog] &&
            [fm fileExistsAtPath:[purgeUnreadable stringByAppendingPathComponent:@"thumb.png"]], @"不可读文件落盘保护：计失败、入保护集、混合后不按名字删除");
        // 数据安全（审计第 3 项）：日志门媒体头否决。photo.log.jpg 挂日志名但内容是图片，
        // 旧日志门只看名字会删掉它；现按文件头否决，真日志仍可删。
        NSString *logMediaDir=[fixture stringByAppendingPathComponent:@"log-media"];
        require([fm createDirectoryAtPath:logMediaDir withIntermediateDirectories:YES attributes:nil error:nil], @"日志目录媒体夹具");
        writeFile([logMediaDir stringByAppendingPathComponent:@"app.log"]);
        writeMedia([logMediaDir stringByAppendingPathComponent:@"photo.log.jpg"]);
        AxsCacheKeeperSweep *logMediaSweep=[[AxsCacheKeeperSweep alloc] initWithRoot:logMediaDir clock:^NSTimeInterval{return future;} fullClear:NO logMode:YES purgeMode:NO];
        for (NSUInteger pass=0;!logMediaSweep.complete && pass<100;pass++) [logMediaSweep advance:64 shouldContinue:^BOOL{return YES;}];
        require(logMediaSweep.complete && logMediaSweep.failed==0 && logMediaSweep.removed==1 &&
            ![fm fileExistsAtPath:[logMediaDir stringByAppendingPathComponent:@"app.log"]] &&
            [fm fileExistsAtPath:[logMediaDir stringByAppendingPathComponent:@"photo.log.jpg"]], @"日志门媒体头否决：挂日志名的图片保留、真日志删除");
        // 数据安全（审计第 2 项）：删除阶段重标混合。预检零证据后文件内容变为数据库，
        // 删除时复核须重标混合、改走日志门（数据库保留、同目录日志仍可删）。文件级稳定
        // 性门会拦下被改写的文件，故用白盒刷新预检记录以单独验证复核逻辑（见文件头注释）。
        NSString *staleDir=[fixture stringByAppendingPathComponent:@"stale-classification"];
        require([fm createDirectoryAtPath:staleDir withIntermediateDirectories:YES attributes:nil error:nil], @"分类过期夹具");
        NSString *victim=[staleDir stringByAppendingPathComponent:@"victim.bin"];
        writeMedia(victim);
        writeFile([staleDir stringByAppendingPathComponent:@"other.log"]);
        AxsCacheKeeperSweep *stale=[[AxsCacheKeeperSweep alloc] initWithRoot:staleDir clock:^NSTimeInterval{return future;} fullClear:NO logMode:NO purgeMode:YES];
        for (NSUInteger pass=0;stale.checking && !stale.complete && pass<100;pass++) [stale advance:1 shouldContinue:^BOOL{return YES;}];
        require(!stale.checking && stale.removed==0 && !stale.purgeMixed, @"预检零证据：分类过期测试基线");
        NSFileHandle *victimWriter=[NSFileHandle fileHandleForWritingAtPath:victim];
        [victimWriter writeData:[@"SQLite format 3\0payload" dataUsingEncoding:NSUTF8StringEncoding]];
        [victimWriter closeFile];
        struct stat victimStat;
        require(!stat(victim.fileSystemRepresentation,&victimStat), @"读取改写后文件状态");
        stale.fileSnapshots[staleDir][@"victim.bin"]=[stale axs_cachekeeper_snapshot:victimStat];
        for (NSUInteger pass=0;!stale.complete && pass<100;pass++) [stale advance:64 shouldContinue:^BOOL{return YES;}];
        require(stale.complete && stale.purgeMixed && stale.removed==1 && [stale.purgeEvidence isEqual:@"victim.bin"] &&
            [fm fileExistsAtPath:victim] &&
            ![fm fileExistsAtPath:[staleDir stringByAppendingPathComponent:@"other.log"]], @"删除阶段检出新数据证据重标混合：数据库保留、同目录日志仍可删");
        NSString *hotPurgeRoot=[fixture stringByAppendingPathComponent:@"hot-purge"];
        require([fm createDirectoryAtPath:[hotPurgeRoot stringByAppendingPathComponent:@"ready"] withIntermediateDirectories:YES attributes:nil error:nil], @"热清理目录夹具");
        writeFile([hotPurgeRoot stringByAppendingPathComponent:@"ready/stable-one.bin"]);
        writeFile([hotPurgeRoot stringByAppendingPathComponent:@"ready/stable-two.txt"]);
        writeFile([hotPurgeRoot stringByAppendingPathComponent:@"ready/keep-changing.bin"]);
        AxsCacheKeeperSweep *hotPurge=[[AxsCacheKeeperSweep alloc] initWithRoot:hotPurgeRoot clock:^NSTimeInterval{return future;} fullClear:NO logMode:NO purgeMode:YES];
        for (NSUInteger pass=0;hotPurge.checking && !hotPurge.complete && pass<100;pass++) [hotPurge advance:1 shouldContinue:^BOOL{return YES;}];
        require(!hotPurge.checking && hotPurge.removed==0, @"清理模式预检阶段不删除");
        writeFile([hotPurgeRoot stringByAppendingPathComponent:@"ready/keep-changing.bin"]);
        for (NSUInteger pass=0;!hotPurge.complete && pass<100;pass++) [hotPurge advance:64 shouldContinue:^BOOL{return YES;}];
        require(hotPurge.complete && hotPurge.failed==0 && hotPurge.removed==2 && hotPurge.changedCount>0,
            [NSString stringWithFormat:@"清理模式文件级稳定性门：兄弟变化只跳过自身（removed=%lu failed=%lu changed=%lu error=%@）",(unsigned long)hotPurge.removed,(unsigned long)hotPurge.failed,(unsigned long)hotPurge.changedCount,hotPurge.error]);
        require(![fm fileExistsAtPath:[hotPurgeRoot stringByAppendingPathComponent:@"ready/stable-one.bin"]] &&
            ![fm fileExistsAtPath:[hotPurgeRoot stringByAppendingPathComponent:@"ready/stable-two.txt"]] &&
            [fm fileExistsAtPath:[hotPurgeRoot stringByAppendingPathComponent:@"ready/keep-changing.bin"]], @"变化文件保留、稳定文件删除");
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

        // 路径解析回归（真机 2026-11-11：删除在「打开缓存根」以 ENOTDIR 全灭）：中间组件是符号链接时
        // 逐级打开必须跟随（与内核一致，如 /var→/private/var）；末级目标本身是链接仍须拒绝。
        NSString *linkTarget = [fixture stringByAppendingPathComponent:@"link-target"];
        require([fm createDirectoryAtPath:[linkTarget stringByAppendingPathComponent:@"sub"] withIntermediateDirectories:YES attributes:nil error:nil], @"链接中间层夹具");
        NSString *linkPath = [fixture stringByAppendingPathComponent:@"link-mid"];
        require(!symlink(linkTarget.fileSystemRepresentation, linkPath.fileSystemRepresentation), @"建立中间层链接");
        int throughFd = axs_cachekeeper_open_directory([linkPath stringByAppendingPathComponent:@"sub"]);
        struct stat throughInfo;
        require(throughFd >= 0 && !fstat(throughFd, &throughInfo) && S_ISDIR(throughInfo.st_mode), @"经符号链接中间层打开目录成功");
        if (throughFd >= 0) close(throughFd);
        NSString *finalLink = [fixture stringByAppendingPathComponent:@"link-final"];
        require(!symlink(linkTarget.fileSystemRepresentation, finalLink.fileSystemRepresentation), @"建立末级链接");
        require(axs_cachekeeper_open_directory(finalLink) < 0, @"末级目标是符号链接仍拒绝打开");

        NSString *lockRoot = [fixture stringByAppendingPathComponent:@"lock-root"];
        NSString *lockSub = [lockRoot stringByAppendingPathComponent:@"sub"];
        require([fm createDirectoryAtPath:lockSub withIntermediateDirectories:YES attributes:nil error:nil], @"写锁夹具目录");
        writeFile([lockRoot stringByAppendingPathComponent:@"a.txt"]);
        writeFile([lockSub stringByAppendingPathComponent:@"b.txt"]);
        NSString *lockOutside = [fixture stringByAppendingPathComponent:@"lock-outside"];
        writeFile(lockOutside);
        require(!symlink(lockOutside.fileSystemRepresentation, [lockRoot stringByAppendingPathComponent:@"link"].fileSystemRepresentation), @"写锁链接夹具");
        chmod(lockRoot.fileSystemRepresentation, 0755); chmod(lockSub.fileSystemRepresentation, 0755);
        chmod([lockRoot stringByAppendingPathComponent:@"a.txt"].fileSystemRepresentation, 0644);
        chmod([lockSub stringByAppendingPathComponent:@"b.txt"].fileSystemRepresentation, 0600);
        NSString *lockJournal = [fixture stringByAppendingPathComponent:@"lock-permissions.plist"];
        NSDictionary *lockResult = axs_cachekeeper_lock_paths(@[lockRoot], lockJournal);
        require([lockResult[@"failed"] unsignedIntegerValue] == 0 && [lockResult[@"locked"] unsignedIntegerValue] == 4,
            [NSString stringWithFormat:@"写锁覆盖根、子目录与两个文件（locked=%@ error=%@）", lockResult[@"locked"], lockResult[@"error"]]);
        struct stat lockInfo;
        require(!lstat(lockRoot.fileSystemRepresentation, &lockInfo) && (lockInfo.st_mode & 0222) == 0 &&
            !lstat(lockSub.fileSystemRepresentation, &lockInfo) && (lockInfo.st_mode & 0222) == 0 &&
            !lstat([lockRoot stringByAppendingPathComponent:@"a.txt"].fileSystemRepresentation, &lockInfo) && (lockInfo.st_mode & 0777) == 0444 &&
            !lstat([lockSub stringByAppendingPathComponent:@"b.txt"].fileSystemRepresentation, &lockInfo) && (lockInfo.st_mode & 0777) == 0400, @"锁定后目录与文件均不可写且保留其他权限位");
        require(!lstat(lockOutside.fileSystemRepresentation, &lockInfo) && (lockInfo.st_mode & 0222) != 0, @"符号链接指向的外部文件不被锁定");
        FILE *blocked = fopen([lockRoot stringByAppendingPathComponent:@"a.txt"].fileSystemRepresentation, "a");
        require(!blocked, @"锁定后追加写入被系统拒绝");
        require(![fm createFileAtPath:[lockRoot stringByAppendingPathComponent:@"new.txt"] contents:nil attributes:nil], @"锁定后新建文件被系统拒绝");
        NSDictionary *lockRecords = [NSDictionary dictionaryWithContentsOfFile:lockJournal];
        require([lockRecords[lockRoot][@"mode"] unsignedIntValue] == 0755 &&
            [lockRecords[[lockSub stringByAppendingPathComponent:@"b.txt"]][@"mode"] unsignedIntValue] == 0600 &&
            !lockRecords[[lockRoot stringByAppendingPathComponent:@"link"]], @"先记录原始权限再锁定，链接不入记录");
        NSDictionary *relock = axs_cachekeeper_lock_paths(@[lockRoot], lockJournal);
        require([relock[@"failed"] unsignedIntegerValue] == 0 && [relock[@"locked"] unsignedIntegerValue] == 0 &&
            [[NSDictionary dictionaryWithContentsOfFile:lockJournal][lockRoot][@"mode"] unsignedIntValue] == 0755, @"重复锁定不覆盖原始权限记录");
        NSDictionary *unlockResult = axs_cachekeeper_restore_paths(nil, lockJournal);
        require([unlockResult[@"failed"] unsignedIntegerValue] == 0 &&
            !lstat(lockRoot.fileSystemRepresentation, &lockInfo) && (lockInfo.st_mode & 0777) == 0755 &&
            !lstat([lockSub stringByAppendingPathComponent:@"b.txt"].fileSystemRepresentation, &lockInfo) && (lockInfo.st_mode & 0777) == 0600 &&
            ![NSDictionary dictionaryWithContentsOfFile:lockJournal].count, @"按记录精确恢复目录与文件权限并清空记录");

        // 写锁硬链接保护（审计第 7 项）：硬链接文件与根外路径共享同一 inode，上锁会波及根外，必须跳过。
        NSString *hardRoot = [fixture stringByAppendingPathComponent:@"lock-hard"];
        NSString *hardFile = [hardRoot stringByAppendingPathComponent:@"shared.txt"];
        NSString *hardOutside = [fixture stringByAppendingPathComponent:@"lock-hard-outside"];
        require([fm createDirectoryAtPath:hardRoot withIntermediateDirectories:YES attributes:nil error:nil], @"硬链接写锁夹具");
        writeFile(hardFile);
        chmod(hardFile.fileSystemRepresentation, 0644);
        require(!link(hardFile.fileSystemRepresentation, hardOutside.fileSystemRepresentation), @"建立硬链接");
        NSString *hardJournal = [fixture stringByAppendingPathComponent:@"lock-hard-permissions.plist"];
        NSDictionary *hardResult = axs_cachekeeper_lock_paths(@[hardRoot], hardJournal);
        require([hardResult[@"failed"] unsignedIntegerValue] == 0 && [hardResult[@"locked"] unsignedIntegerValue] == 1 &&
            !lstat(hardFile.fileSystemRepresentation, &lockInfo) && (lockInfo.st_mode & 0777) == 0644 &&
            !lstat(hardOutside.fileSystemRepresentation, &lockInfo) && (lockInfo.st_mode & 0777) == 0644 &&
            ![NSDictionary dictionaryWithContentsOfFile:hardJournal][hardFile], @"硬链接文件不被锁定、不入记录，根目录仍锁定");
        NSDictionary *hardUnlock = axs_cachekeeper_restore_paths(nil, hardJournal);
        require([hardUnlock[@"failed"] unsignedIntegerValue] == 0 &&
            !lstat(hardRoot.fileSystemRepresentation, &lockInfo) && (lockInfo.st_mode & 0777) == 0755, @"硬链接测试后恢复根目录权限");

        // 写锁记录身份刷新（审计第 7 项）：文件被重建（新 inode）后再次锁定，记录须刷新为新身份，
        // 否则恢复时身份核对失败会删记录却不恢复，新文件永久锁定。
        NSString *rebuildRoot = [fixture stringByAppendingPathComponent:@"lock-rebuild"];
        NSString *rebuildFile = [rebuildRoot stringByAppendingPathComponent:@"rebuilt.txt"];
        require([fm createDirectoryAtPath:rebuildRoot withIntermediateDirectories:YES attributes:nil error:nil], @"重建写锁夹具");
        writeFile(rebuildFile);
        chmod(rebuildFile.fileSystemRepresentation, 0644);
        NSString *rebuildJournal = [fixture stringByAppendingPathComponent:@"lock-rebuild-permissions.plist"];
        NSDictionary *firstLock = axs_cachekeeper_lock_paths(@[rebuildRoot], rebuildJournal);
        require([firstLock[@"failed"] unsignedIntegerValue] == 0, @"首次锁定成功");
        struct stat oldInfo;
        require(!lstat(rebuildFile.fileSystemRepresentation, &oldInfo) && (oldInfo.st_mode & 0222) == 0, @"首次锁定后文件不可写");
        chmod(rebuildRoot.fileSystemRepresentation, 0755);
        require([fm removeItemAtPath:rebuildFile error:nil], @"删除旧文件");
        writeFile(rebuildFile);
        chmod(rebuildFile.fileSystemRepresentation, 0644);
        struct stat newInfo;
        require(!lstat(rebuildFile.fileSystemRepresentation, &newInfo) && newInfo.st_ino != oldInfo.st_ino, @"重建文件获得新 inode");
        NSDictionary *secondLock = axs_cachekeeper_lock_paths(@[rebuildRoot], rebuildJournal);
        require([secondLock[@"failed"] unsignedIntegerValue] == 0 &&
            [[NSDictionary dictionaryWithContentsOfFile:rebuildJournal][rebuildFile][@"inode"] unsignedLongLongValue] == newInfo.st_ino, @"重建后再次锁定刷新记录为新身份");
        NSDictionary *rebuildUnlock = axs_cachekeeper_restore_paths(nil, rebuildJournal);
        require([rebuildUnlock[@"failed"] unsignedIntegerValue] == 0 &&
            !lstat(rebuildFile.fileSystemRepresentation, &lockInfo) && (lockInfo.st_mode & 0777) == 0644, @"刷新记录后恢复新文件权限，不永久锁定");

        NSString *inspectionRoot=[fixture stringByAppendingPathComponent:@"inspection"];
        require([fm createDirectoryAtPath:inspectionRoot withIntermediateDirectories:YES attributes:nil error:nil], @"建立深度检测目录");
        for (NSUInteger i=0;i<600;i++) writeMedia([inspectionRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"%lu.bin",(unsigned long)i]]);
        writeFile([inspectionRoot stringByAppendingPathComponent:@"ordinary.txt"]);
        require([[@"{\"example\":true}" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:[inspectionRoot stringByAppendingPathComponent:@"data.json"] atomically:YES], @"JSON 检测夹具");
        const unsigned char zip[]={0x50,0x4b,3,4,0};
        require([[NSData dataWithBytes:zip length:sizeof(zip)] writeToFile:[inspectionRoot stringByAppendingPathComponent:@"archive"] atomically:YES], @"压缩格式夹具");
        require(!symlink(inspectionRoot.fileSystemRepresentation,[[inspectionRoot stringByAppendingPathComponent:@"loop"] fileSystemRepresentation]), @"检测链接环夹具");
        AxsCacheKeeperInspection *inspection=[[AxsCacheKeeperInspection alloc] initWithRoot:inspectionRoot];
        [inspection advance:32];require(!inspection.complete, @"深度检测必须可分批，不能把一批当成完成");
        for (NSUInteger pass=0;!inspection.complete && pass<100;pass++) [inspection advance:32];
        NSDictionary *profile=[inspection report];
        require(inspection.complete && [profile[@"coverageComplete"] boolValue] && [profile[@"files"] unsignedIntegerValue]==603 &&
            [profile[@"types"][@"媒体文件头"][@"count"] unsignedIntegerValue]==600, @"全量枚举超过 512 个文件并保留类型组成");
        require([profile[@"types"][@"JSON 数据"][@"count"] unsignedIntegerValue]==1 &&
            [profile[@"types"][@"归档或压缩文件"][@"count"] unsignedIntegerValue]==1 &&
            [profile[@"types"][@"文本头特征（用途未定）"][@"count"] unsignedIntegerValue]==1, @"JSON、压缩和文本识别只形成证据");
        require([profile[@"largest"] count]==10 && [profile[@"links"] unsignedIntegerValue]==1 &&
            [fm fileExistsAtPath:[inspectionRoot stringByAppendingPathComponent:@"599.bin"]], @"档案只读，最大文件列表有界，链接不跟随");
        NSDictionary *h1=@{@"updated":NSDate.date,@"home":@"same",@"rows":@[@{@"path":@"tmp",@"bytes":@1,@"complete":@YES}]};
        NSDictionary *h2=@{@"updated":NSDate.date,@"home":@"same",@"rows":@[@{@"path":@"tmp",@"bytes":@2,@"complete":@YES}]};
        NSDictionary *h3=@{@"updated":NSDate.date,@"home":@"same",@"rows":@[@{@"path":@"tmp",@"bytes":@3,@"complete":@YES}]};
        require([axs_cachekeeper_growth_evidence(@"tmp",@[h1,h2],h3) containsString:@"持续增长"], @"连续完整快照提供增长旁证");
        NSMutableDictionary *partial=[h2 mutableCopy];partial[@"rows"]=@[@{@"path":@"tmp",@"bytes":@2,@"complete":@NO}];
        require([axs_cachekeeper_growth_evidence(@"tmp",@[h1,partial],h3) containsString:@"需至少"], @"不完整统计不能产生增长结论");
        partial=[h3 mutableCopy];partial[@"recentScans"]=@[h1,h1,h1,h2,h2];
        require(axs_cachekeeper_recent_scans(partial).count==4, @"只保留最近四次旧记录加本轮，防止快照递归膨胀");

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
        puts("PASS: configuration, modes, deduplication, age, protected files, cleanup, cancellation, permission restoration and URLCache");
    }
    return 0;
}
