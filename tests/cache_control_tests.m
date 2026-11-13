#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <unistd.h>
#import "../AxsCacheKeeperPolicy.h"
#import "../AxsCacheKeeperFileAccess.h"
#import "../AxsCacheKeeperSweep.h"
#import "../AxsCacheKeeperCleanupRules.h"
#import "../AxsCacheKeeperNetworkCache.h"
#import "../AxsCacheKeeperDirectories.h"
#import "../AxsCacheKeeperSelection.h"
#import "../AxsCacheKeeperFilza.h"
#import "../AxsCacheKeeperProcess.h"
#import "../AxsCacheKeeperProcessObservation.h"
#import "../AxsCacheKeeperCleanupJob.h"
#import "../AxsCacheKeeperReceipts.h"
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

extern void axs_cachekeeper_run_plan_repair_tests(NSString *fixture);

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
        // 进程观测统一记录（审查 P1-2，方案任务 2）：真实生产模块驱动，注入单调时钟。
        NSString *obsBundle=@"com.example.obs";
        [AxsCacheKeeperProcessObservation observeBundle:obsBundle state:AxsCacheKeeperExecSuspended identity:@"1:100.000000" atMonotonicTime:0];
        require(![AxsCacheKeeperProcessObservation allowsSuspendedCleanupForBundle:obsBundle identity:@"1:100.000000" atMonotonicTime:59], @"挂起未满 60 秒不放行");
        [AxsCacheKeeperProcessObservation observeBundle:obsBundle state:AxsCacheKeeperExecSuspended identity:@"1:100.000000" atMonotonicTime:61];
        require([AxsCacheKeeperProcessObservation allowsSuspendedCleanupForBundle:obsBundle identity:@"1:100.000000" atMonotonicTime:61], @"同实例挂起满 60 秒放行");
        [AxsCacheKeeperProcessObservation observeBundle:obsBundle state:AxsCacheKeeperExecExecuting identity:@"1:100.000000" atMonotonicTime:61.1];
        require(![AxsCacheKeeperProcessObservation allowsSuspendedCleanupForBundle:obsBundle identity:@"1:100.000000" atMonotonicTime:61.2], @"看到执行后旧窗口立即失效");
        [AxsCacheKeeperProcessObservation observeBundle:obsBundle state:AxsCacheKeeperExecSuspended identity:@"1:100.000000" atMonotonicTime:61.2];
        require(![AxsCacheKeeperProcessObservation allowsSuspendedCleanupForBundle:obsBundle identity:@"1:100.000000" atMonotonicTime:120], @"新窗口未满 60 秒不放行");
        require([AxsCacheKeeperProcessObservation allowsSuspendedCleanupForBundle:obsBundle identity:@"1:100.000000" atMonotonicTime:121.3], @"新窗口满 60 秒放行");
        [AxsCacheKeeperProcessObservation observeBundle:obsBundle state:AxsCacheKeeperExecUnknown identity:nil atMonotonicTime:122];
        require(![AxsCacheKeeperProcessObservation allowsSuspendedCleanupForBundle:obsBundle identity:@"1:100.000000" atMonotonicTime:200], @"Unknown 观测清除窗口");
        [AxsCacheKeeperProcessObservation observeBundle:obsBundle state:AxsCacheKeeperExecSuspended identity:@"1:100.000000" atMonotonicTime:200];
        [AxsCacheKeeperProcessObservation observeBundle:obsBundle state:AxsCacheKeeperExecSuspended identity:@"1:200.000000" atMonotonicTime:201];
        require(![AxsCacheKeeperProcessObservation allowsSuspendedCleanupForBundle:obsBundle identity:@"1:200.000000" atMonotonicTime:260], @"实例变化（PID 复用/启动时间改变）重新计时");
        require([AxsCacheKeeperProcessObservation allowsSuspendedCleanupForBundle:obsBundle identity:@"1:200.000000" atMonotonicTime:261], @"新实例满 60 秒放行");
        [AxsCacheKeeperProcessObservation observeBundle:obsBundle state:AxsCacheKeeperExecSuspended identity:nil atMonotonicTime:262];
        require(![AxsCacheKeeperProcessObservation allowsSuspendedCleanupForBundle:obsBundle identity:@"1:200.000000" atMonotonicTime:400], @"身份缺失的挂起观测不继承窗口");
        [AxsCacheKeeperProcessObservation observeBundle:obsBundle state:AxsCacheKeeperExecSuspended identity:@"1:200.000000" atMonotonicTime:400];
        [AxsCacheKeeperProcessObservation observeBundle:obsBundle state:AxsCacheKeeperExecAbsent identity:nil atMonotonicTime:401];
        require(![AxsCacheKeeperProcessObservation allowsSuspendedCleanupForBundle:obsBundle identity:@"1:200.000000" atMonotonicTime:500], @"消失观测清除窗口，不借旧窗口");
        // 任务 2 补齐：停用期间的观测中断须失效旧窗口。Suspended@500 后停用（以 Unknown 观测
        // 模拟跳过清除），重开后同实例挂起@561 不得继承 t=500，须到新窗口满 60 秒才放行。
        NSString *disableBundle=@"com.example.disable";
        [AxsCacheKeeperProcessObservation observeBundle:disableBundle state:AxsCacheKeeperExecSuspended identity:@"1:300.000000" atMonotonicTime:500];
        [AxsCacheKeeperProcessObservation observeBundle:disableBundle state:AxsCacheKeeperExecUnknown identity:nil atMonotonicTime:530];
        [AxsCacheKeeperProcessObservation observeBundle:disableBundle state:AxsCacheKeeperExecSuspended identity:@"1:300.000000" atMonotonicTime:561];
        require(![AxsCacheKeeperProcessObservation allowsSuspendedCleanupForBundle:disableBundle identity:@"1:300.000000" atMonotonicTime:561], @"停用清除后重开挂起不得继承旧起点");
        require([AxsCacheKeeperProcessObservation allowsSuspendedCleanupForBundle:disableBundle identity:@"1:300.000000" atMonotonicTime:621], @"停用清除后新窗口满 60 秒放行");
        // 配置不可读：invalidateAll 清除全部 bundle 的挂起起点。
        [AxsCacheKeeperProcessObservation observeBundle:disableBundle state:AxsCacheKeeperExecSuspended identity:@"1:300.000000" atMonotonicTime:700];
        [AxsCacheKeeperProcessObservation observeBundle:obsBundle state:AxsCacheKeeperExecSuspended identity:@"1:200.000000" atMonotonicTime:700];
        [AxsCacheKeeperProcessObservation invalidateAllBundles];
        [AxsCacheKeeperProcessObservation observeBundle:disableBundle state:AxsCacheKeeperExecSuspended identity:@"1:300.000000" atMonotonicTime:761];
        require(![AxsCacheKeeperProcessObservation allowsSuspendedCleanupForBundle:disableBundle identity:@"1:300.000000" atMonotonicTime:761], @"invalidateAll 后旧起点作废");
        require(![AxsCacheKeeperProcessObservation allowsSuspendedCleanupForBundle:obsBundle identity:@"1:200.000000" atMonotonicTime:761], @"invalidateAll 清除全部 bundle");
        // 任务 2 补齐（修订方案）：beginCycle 差集清理＋最近执行实例。启用集合用真实配置解析
        //（axs_cachekeeper_app_enabled）从伪造的状态字典导出，测配置入口与模块的组合，不只测孤立模块。
        NSString *cycleA=@"com.example.cycle-a";
        NSString *cycleB=@"com.example.cycle-b";
        [AxsCacheKeeperProcessObservation observeBundle:cycleA state:AxsCacheKeeperExecExecuting identity:@"1:400.000000" atMonotonicTime:790];
        [AxsCacheKeeperProcessObservation observeBundle:cycleA state:AxsCacheKeeperExecSuspended identity:@"1:400.000000" atMonotonicTime:800];
        [AxsCacheKeeperProcessObservation observeBundle:cycleB state:AxsCacheKeeperExecExecuting identity:@"1:401.000000" atMonotonicTime:790];
        [AxsCacheKeeperProcessObservation observeBundle:cycleB state:AxsCacheKeeperExecSuspended identity:@"1:401.000000" atMonotonicTime:800];
        // B 的配置键直接移除（字典中不存在），C 显式停用；只有 A 在启用集合内。
        NSDictionary *cycleStates = @{cycleA: @{@"enabled": @YES}, @"com.example.cycle-c": @{@"enabled": @NO}};
        NSMutableSet *cycleEnabled = [NSMutableSet new];
        for (NSString *bundle in cycleStates) if (axs_cachekeeper_bundle_id(bundle) && axs_cachekeeper_app_enabled(cycleStates[bundle])) [cycleEnabled addObject:bundle];
        [AxsCacheKeeperProcessObservation beginCycleWithEnabledBundles:cycleEnabled configurationReadable:YES];
        require([AxsCacheKeeperProcessObservation allowsSuspendedCleanupForBundle:cycleA identity:@"1:400.000000" atMonotonicTime:861], @"差集清理保留启用 bundle 的窗口");
        require(![AxsCacheKeeperProcessObservation allowsSuspendedCleanupForBundle:cycleB identity:@"1:401.000000" atMonotonicTime:861], @"配置键移除的 bundle 窗口作废");
        require([[AxsCacheKeeperProcessObservation lastExecutingIdentityForBundle:cycleA] isEqual:@"1:400.000000"], @"启用 bundle 的执行实例保留");
        require([AxsCacheKeeperProcessObservation lastExecutingIdentityForBundle:cycleB] == nil, @"配置键移除的 bundle 执行实例记录清除");
        // B 重新加入启用集合：须重新挂起满 60 秒，不能继承旧窗口。
        [AxsCacheKeeperProcessObservation observeBundle:cycleB state:AxsCacheKeeperExecSuspended identity:@"1:401.000000" atMonotonicTime:900];
        require(![AxsCacheKeeperProcessObservation allowsSuspendedCleanupForBundle:cycleB identity:@"1:401.000000" atMonotonicTime:900], @"重新加入后须重计挂起窗口");
        require([AxsCacheKeeperProcessObservation allowsSuspendedCleanupForBundle:cycleB identity:@"1:401.000000" atMonotonicTime:960], @"重新加入后新窗口满 60 秒放行");
        // 配置不可读：beginCycle 全部作废。
        [AxsCacheKeeperProcessObservation beginCycleWithEnabledBundles:[NSSet set] configurationReadable:NO];
        require(![AxsCacheKeeperProcessObservation allowsSuspendedCleanupForBundle:cycleA identity:@"1:400.000000" atMonotonicTime:1061], @"配置不可读时全部窗口作废");
        require([AxsCacheKeeperProcessObservation lastExecutingIdentityForBundle:cycleA] == nil, @"配置不可读时执行实例记录清除");
        // 最近执行实例生命周期：挂起/消失不抹除历史，新实例更新，nil 身份不覆盖。
        NSString *execBundle=@"com.example.exec";
        [AxsCacheKeeperProcessObservation observeBundle:execBundle state:AxsCacheKeeperExecExecuting identity:@"1:500.000000" atMonotonicTime:1100];
        require([[AxsCacheKeeperProcessObservation lastExecutingIdentityForBundle:execBundle] isEqual:@"1:500.000000"], @"Executing 记录执行实例");
        [AxsCacheKeeperProcessObservation observeBundle:execBundle state:AxsCacheKeeperExecSuspended identity:@"1:500.000000" atMonotonicTime:1110];
        require([[AxsCacheKeeperProcessObservation lastExecutingIdentityForBundle:execBundle] isEqual:@"1:500.000000"], @"挂起不抹除执行实例历史");
        [AxsCacheKeeperProcessObservation observeBundle:execBundle state:AxsCacheKeeperExecExecuting identity:@"1:600.000000" atMonotonicTime:1120];
        require([[AxsCacheKeeperProcessObservation lastExecutingIdentityForBundle:execBundle] isEqual:@"1:600.000000"], @"新实例运行更新执行实例记录");
        [AxsCacheKeeperProcessObservation observeBundle:execBundle state:AxsCacheKeeperExecAbsent identity:nil atMonotonicTime:1130];
        require([[AxsCacheKeeperProcessObservation lastExecutingIdentityForBundle:execBundle] isEqual:@"1:600.000000"], @"消失不抹除执行实例历史");
        [AxsCacheKeeperProcessObservation observeBundle:execBundle state:AxsCacheKeeperExecExecuting identity:nil atMonotonicTime:1140];
        require([[AxsCacheKeeperProcessObservation lastExecutingIdentityForBundle:execBundle] isEqual:@"1:600.000000"], @"nil 身份不覆盖执行实例记录");
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
        require(!axs_cachekeeper_should_prevent(networkOff) && axs_cachekeeper_can_clean(selection, @{bundle:networkOff}, bundle), @"关闭独立网络开关不关闭自动清理");
        require(!axs_cachekeeper_url_cache_enabled(axs_cachekeeper_app_state(networkOff,NO)), @"修改总开关保留网络选项");
        require(!axs_cachekeeper_activation_paths(nil).count &&
            !axs_cachekeeper_activation_paths(@[]).count, @"新 APP 不默认选择缓存目录，空选择也保持为空");
        require(!axs_cachekeeper_selected_paths(@{@"com.tencent.xin":@[@"Library/Caches"]}, @{}, @"com.tencent.xin").count, @"未开启微信不得因残留目录记录被清理");
        require([axs_cachekeeper_selected_paths(selection, @{bundle:@{@"enabled":@YES,@"restrict":@NO}}, bundle) count] == 1, @"关闭限写不能关闭自动清理");
        require(!axs_cachekeeper_wants_restriction(@{@"enabled":@YES,@"restrict":@NO}), @"独立限写开关");
        require([axs_cachekeeper_app_state(@{@"enabled":@YES,@"restrict":@NO}, NO)[@"mode"] isEqual:@"clean"], @"总开关修改保留模式并兼容旧配置");
        require(axs_cachekeeper_can_clean(selection, @{bundle:@{@"enabled":@YES,@"mode":@"prevent"}}, bundle), @"限制缓存并清理模式同样清理（任务 9：三种模式共用引擎）");
        // 方案任务 8：fullClear 键已废止——状态归一化时丢弃，旧 true/false 归一化后完全相同；
        // 其余选择（模式、网络选项、自动发现、日志定级、手动排除）原样保留。
        NSDictionary *migratedOn = axs_cachekeeper_app_state(@{@"enabled":@YES, @"mode":@"prevent", @"urlCache":@NO, @"autoDiscover":@NO, @"fullClear":@YES, @"logPaths":@[@"Library/alog"], @"excludedPaths":@[@"Library/Caches/keep"]}, YES);
        NSDictionary *migratedOff = axs_cachekeeper_app_state(@{@"enabled":@YES, @"mode":@"prevent", @"urlCache":@NO, @"autoDiscover":@NO, @"fullClear":@NO, @"logPaths":@[@"Library/alog"], @"excludedPaths":@[@"Library/Caches/keep"]}, YES);
        require(migratedOn[@"fullClear"] == nil && [migratedOn isEqual:migratedOff], @"旧 fullClear 键归一化时丢弃，新旧值行为一致");
        require([migratedOn[@"mode"] isEqual:@"prevent"] && ![migratedOn[@"urlCache"] boolValue] && ![migratedOn[@"autoDiscover"] boolValue] &&
            [migratedOn[@"logPaths"] isEqual:@[@"Library/alog"]] && [migratedOn[@"excludedPaths"] isEqual:@[@"Library/Caches/keep"]], @"归一化保留模式、网络选项、自动发现、日志定级与手动排除");
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
            !axs_cachekeeper_can_clean(selection, @{bundle:@{@"enabled":@NO,@"mode":@"auto"}}, bundle), @"快捷操作也不能绕过开启状态");
        NSDictionary *appRows=@{@"system":@{@"bundle":@"com.apple.mobilesafari",@"name":@"Safari"},
            @"wechat":@{@"bundle":@"com.tencent.xin",@"name":@"微信"}};
        require(axs_cachekeeper_application_entry(appRows[@"system"][@"bundle"],@"Safari",@"System",[NSURL fileURLWithPath:@"/Applications/MobileSafari.app"]) != nil, @"已安装系统 APP 也列出");
        require(axs_cachekeeper_application_entry(appRows[@"wechat"][@"bundle"],@"微信",@"User",nil) != nil, @"第三方 APP 不按名称排除");
        require(!axs_cachekeeper_application_entry(@"service",@"服务",@"Plugin",[NSURL fileURLWithPath:@"/Plugins/test.appex"]), @"扩展服务不冒充已安装 APP");
        require(axs_cachekeeper_container_bundle_path(@"/private/var/containers/Bundle/Application/9D2CF640-4735-4F4E-ACF5-3381A3F5A44B/ibisPaintX.app"), @"真实容器包体");
        require(!axs_cachekeeper_container_bundle_path(@"/private/var/containers/Bundle/Application/.jbroot-A9F73A89EAC821EE/Applications/Sileo.app"), @"jbroot 伪容器不算容器");
        require(!axs_cachekeeper_container_bundle_path(@"/var/jb/Applications/Sileo.app") && !axs_cachekeeper_container_bundle_path(@"/Applications/MobileSafari.app") && !axs_cachekeeper_container_bundle_path(nil) && !axs_cachekeeper_container_bundle_path(@"/private/var/containers/Bundle/Application/"), @"非容器路径一律否");
        NSString *configFile=[fixture stringByAppendingPathComponent:@"appEnabled.plist"];
        require([@"broken configuration" writeToFile:configFile atomically:YES encoding:NSUTF8StringEncoding error:nil], @"配置损坏夹具");
        require(!axs_cachekeeper_edit_configuration(configFile) && [[NSString stringWithContentsOfFile:configFile encoding:NSUTF8StringEncoding error:nil] isEqual:@"broken configuration"], @"拒绝覆盖损坏的既有配置");
        require(axs_cachekeeper_edit_configuration([fixture stringByAppendingPathComponent:@"new.plist"]) != nil, @"允许建立新配置");
        require(!axs_cachekeeper_cache_path(@"/Library/Caches") && !axs_cachekeeper_cache_path(@"Library/Caches//a"), @"拒绝非规范路径");
        NSString *summary = axs_cachekeeper_summary(@{@"rows":@[@{}]}, @{@"phase":@"auto", @"message":@"限写失败",
            @"removed":@3, @"bytes":@1048576, @"failed":@1});
        require([summary containsString:@"1 个"] && [summary containsString:@"3 个"] && [summary containsString:@"限写失败"], @"检测与清理结果同时可见");
        NSString *lastSummary = axs_cachekeeper_summary(nil, @{@"removed":@5103, @"bytes":@0, @"lastRemoved":@294, @"lastBytes":@66846720});
        require([lastSummary containsString:@"上次清理：63.75 MB"] && [lastSummary rangeOfString:@"上次清理："].location > [lastSummary rangeOfString:@"累计清理"].location, @"上次清理行紧跟累计清理并显示上轮 MB 数");
        NSString *noLastSummary = axs_cachekeeper_summary(nil, @{@"removed":@5103, @"bytes":@0});
        require(![noLastSummary containsString:@"上次清理"], @"未记录上轮时不显示上次清理行");
        NSString *zeroLastSummary = axs_cachekeeper_summary(nil, @{@"removed":@5103, @"bytes":@0, @"lastRemoved":@0, @"lastBytes":@0});
        require([zeroLastSummary containsString:@"上次清理：0.00 MB"], @"上轮零删除时显示 0.00 MB 而非缺行");
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
        axs_cachekeeper_send_filza_document(workspace,[NSObject new],@"test-payload",modernURL,^(BOOL success,NSError *error){delivered=success;openError=error;});
        require(!delivered && openError, @"Filza 定向配置接口缺失明确失败");
        axs_cachekeeper_send_filza_document(workspace,[AxsTestOpenConfiguration new],@"",modernURL,^(BOOL success,NSError *error){delivered=success;openError=error;});
        require(!delivered && openError, @"Filza Payload 常量缺失明确失败");
        axs_cachekeeper_send_filza_document(workspace,[AxsTestOpenConfiguration new],@"test-payload",legacyURL,^(BOOL success,NSError *error){delivered=success;openError=error;});
        require(!delivered && openError, @"定向文档接口不投递旧 scheme");
        workspace.expectedPath=@"/a-different-directory";
        axs_cachekeeper_send_filza_document(workspace,[AxsTestOpenConfiguration new],@"test-payload",modernURL,^(BOOL success,NSError *error){delivered=success;openError=error;});
        require(!delivered, @"系统拒绝 Filza 请求不得包装成成功");
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
        require([axs_cachekeeper_effective_paths(@[@"Library/Caches"],excludeChild,@[@"Library/Caches"]) isEqual:@[@"Library/Caches"]], @"排除子目录时父根保留，文件级排除裁剪子树（任务 6：不丢合法同级范围）");
        require(![axs_cachekeeper_effective_paths(@[@"Library/Caches/video"],excludeChild,@[]) count], @"排除子树本身仍被移除");
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
        // 任务 6：开启父目录不清除子目录的排除；重新开启被排除的路径本身才清除该排除。
        require(!axs_cachekeeper_update_selection(preferences,@"single.app",@[@"Library/Caches/video"],NO), @"通过标准目录关闭入口建立子目录排除");
        require(!axs_cachekeeper_update_selection(preferences,@"single.app",@[@"Library/Caches"],YES), @"开启父目录");
        require([[NSDictionary dictionaryWithContentsOfFile:statesPath][@"single.app"][@"excludedPaths"] containsObject:@"Library/Caches/video"], @"开启父目录保留子目录排除");
        require(!axs_cachekeeper_update_selection(preferences,@"single.app",@[@"Library/Caches/video"],YES), @"重新开启被排除的路径本身");
        require(![[NSDictionary dictionaryWithContentsOfFile:statesPath][@"single.app"][@"excludedPaths"] containsObject:@"Library/Caches/video"], @"重新开启被排除的路径清除该排除");
        NSData *beforeInvalid=[NSData dataWithContentsOfFile:directoriesPath];
        require(axs_cachekeeper_update_selection(preferences,bundle,@[@"Documents"],YES)!=nil &&
            [[NSData dataWithContentsOfFile:directoriesPath] isEqual:beforeInvalid], @"非法目录不改变现有配置");
        require([@"broken state" writeToFile:statesPath atomically:YES encoding:NSUTF8StringEncoding error:nil], @"损坏状态夹具");
        require(axs_cachekeeper_update_selection(preferences,bundle,enableAll,YES)!=nil &&
            [[NSData dataWithContentsOfFile:directoriesPath] isEqual:beforeInvalid], @"损坏配置时不写入部分选择");

        // ========== 任务 1：统一清理决策（CleanupRules）与平台缓存清理 ==========
        // 假容器 sweep-home：平台根 Library/Caches、tmp；未知目录 Library/Pitaya 等。
        // 日志/未知夹具平铺于 fixture 下（容器即 fixture），相对路径即目录名。
        NSString *sweepHome = [fixture stringByAppendingPathComponent:@"sweep-home"];
        NSString *cache = [sweepHome stringByAppendingPathComponent:@"Library/Caches"];
        NSTimeInterval future = NSDate.date.timeIntervalSince1970 + 120;
        AxsCacheKeeperSweep *(^makeSweep)(NSString *, NSDictionary *) = ^AxsCacheKeeperSweep *(NSString *root, NSDictionary *state) {
            return [[AxsCacheKeeperSweep alloc] initWithRoot:root bundle:bundle version:@"1.0" containerPath:sweepHome state:state ?: @{} clock:^NSTimeInterval { return future; }];
        };
        AxsCacheKeeperSweep *(^makeFlatSweep)(NSString *, NSDictionary *) = ^AxsCacheKeeperSweep *(NSString *root, NSDictionary *state) {
            return [[AxsCacheKeeperSweep alloc] initWithRoot:root bundle:bundle version:@"1.0" containerPath:fixture state:state ?: @{} clock:^NSTimeInterval { return future; }];
        };
        // ---- 任务 1：CleanupRules 决策表（真实规则模块直接调用） ----
        NSDictionary *cleanEvidence = @{@"hasEvidence": @NO, @"hasMediaSignature": @NO, @"readComplete": @YES, @"retentionRanges": @[]};
        NSDictionary *dataEvidence = @{@"hasEvidence": @YES, @"hasMediaSignature": @NO, @"readComplete": @YES, @"retentionRanges": @[]};
        NSDictionary *mediaEvidence = @{@"hasEvidence": @NO, @"hasMediaSignature": @YES, @"readComplete": @YES, @"retentionRanges": @[]};
        NSDictionary *incompleteEvidence = @{@"hasEvidence": @NO, @"hasMediaSignature": @NO, @"readComplete": @NO, @"retentionRanges": @[]};
        NSDictionary *retentionEvidence = @{@"hasEvidence": @NO, @"hasMediaSignature": @NO, @"readComplete": @YES, @"retentionRanges": @[@"Library/Preferences"]};
        NSDictionary *emptyState = @{};
        // 平台缓存：媒体/SQLite/无后缀均可删，不要求逐文件证明下载地址。
        AxsCacheKeeperCleanupDecision *dec = [AxsCacheKeeperCleanupRules decisionForBundle:bundle version:@"1.0" relativePath:@"Library/Caches/a.png" state:emptyState evidence:cleanEvidence];
        require(dec.disposition == AxsCacheKeeperCleanupDelete && dec.basis == AxsCacheKeeperCleanupBasisPlatformCache, @"平台缓存媒体可删");
        dec = [AxsCacheKeeperCleanupRules decisionForBundle:bundle version:@"1.0" relativePath:@"Library/Caches/store.sqlite" state:emptyState evidence:dataEvidence];
        require(dec.disposition == AxsCacheKeeperCleanupDelete && dec.basis == AxsCacheKeeperCleanupBasisPlatformCache, @"平台缓存数据库不因格式保留");
        dec = [AxsCacheKeeperCleanupRules decisionForBundle:bundle version:@"1.0" relativePath:@"tmp/opaque" state:emptyState evidence:cleanEvidence];
        require(dec.disposition == AxsCacheKeeperCleanupDelete && dec.basis == AxsCacheKeeperCleanupBasisPlatformCache, @"tmp 无后缀缓存可删");
        // 顶层 Caches 同名自建目录不获得平台约定。
        dec = [AxsCacheKeeperCleanupRules decisionForBundle:bundle version:@"1.0" relativePath:@"Caches/a.png" state:emptyState evidence:cleanEvidence];
        require(dec.disposition == AxsCacheKeeperCleanupUnresolved, @"顶层 Caches 自建目录不获得平台约定");
        // 未知目录只有普通文件 → Unresolved，零证据不是删除依据。
        dec = [AxsCacheKeeperCleanupRules decisionForBundle:bundle version:@"1.0" relativePath:@"Library/Pitaya/a.png" state:emptyState evidence:cleanEvidence];
        require(dec.disposition == AxsCacheKeeperCleanupUnresolved, @"未知目录零证据内容不自动删");
        // 平台规则不越出缓存根（任务 8：旧 fullClear 范围测试的等价断言）：Logs 已归混合类、
        // 共享与受保护目录除外；平台 Delete 只来自 Library/Caches 与 tmp。
        dec = [AxsCacheKeeperCleanupRules decisionForBundle:bundle version:@"1.0" relativePath:@"Library/Logs/app.log" state:emptyState evidence:cleanEvidence];
        require(dec.disposition != AxsCacheKeeperCleanupDelete || dec.basis != AxsCacheKeeperCleanupBasisPlatformCache, @"Library/Logs 不按平台规则删");
        dec = [AxsCacheKeeperCleanupRules decisionForBundle:bundle version:@"1.0" relativePath:@"Library/Application Support/data.bin" state:emptyState evidence:cleanEvidence];
        require(dec.disposition != AxsCacheKeeperCleanupDelete || dec.basis != AxsCacheKeeperCleanupBasisPlatformCache, @"Application Support 不按平台规则删");
        dec = [AxsCacheKeeperCleanupRules decisionForBundle:bundle version:@"1.0" relativePath:@"Group/com.example/Library/Caches/a.png" state:emptyState evidence:cleanEvidence];
        require(dec.disposition != AxsCacheKeeperCleanupDelete || dec.basis != AxsCacheKeeperCleanupBasisPlatformCache, @"共享容器不按平台规则删");
        NSDictionary *documentsEvidence = @{@"hasEvidence": @NO, @"hasMediaSignature": @NO, @"readComplete": @YES, @"retentionRanges": @[@"Documents"]};
        dec = [AxsCacheKeeperCleanupRules decisionForBundle:bundle version:@"1.0" relativePath:@"Documents/a.png" state:emptyState evidence:documentsEvidence];
        require(dec.disposition == AxsCacheKeeperCleanupKeep, @"Documents 按保留范围保留");
        // 用户排除优先于平台规则（父范围不能绕过子排除），排除外独立范围仍可清。
        NSDictionary *excludedState = @{@"excludedPaths": @[@"Library/Caches/keep"]};
        dec = [AxsCacheKeeperCleanupRules decisionForBundle:bundle version:@"1.0" relativePath:@"Library/Caches/keep/a.png" state:excludedState evidence:cleanEvidence];
        require(dec.disposition == AxsCacheKeeperCleanupKeep && [dec.ruleID isEqualToString:@"user-exclusion"], @"用户排除优先于平台规则");
        dec = [AxsCacheKeeperCleanupRules decisionForBundle:bundle version:@"1.0" relativePath:@"Library/Caches/other/a.png" state:excludedState evidence:cleanEvidence];
        require(dec.disposition == AxsCacheKeeperCleanupDelete, @"排除子树外的独立范围仍可清理");
        // 保留范围优先于平台规则。
        dec = [AxsCacheKeeperCleanupRules decisionForBundle:bundle version:@"1.0" relativePath:@"Library/Preferences/a.txt" state:emptyState evidence:retentionEvidence];
        require(dec.disposition == AxsCacheKeeperCleanupKeep && [dec.ruleID isEqualToString:@"retention-range"], @"保留范围优先于平台规则");
        // 读取不完整 → Keep，本轮不删除。
        dec = [AxsCacheKeeperCleanupRules decisionForBundle:bundle version:@"1.0" relativePath:@"Library/Caches/secret.log" state:emptyState evidence:incompleteEvidence];
        require(dec.disposition == AxsCacheKeeperCleanupDefer && [dec.ruleID isEqualToString:@"read-incomplete"], @"读取不完整本轮不删除");
        // 日志定级：日志名 + 无证据 + 无媒体头 + 不受保护 → Delete/UserLog。
        NSDictionary *logState = @{@"logPaths": @[@"Library/alog"]};
        dec = [AxsCacheKeeperCleanupRules decisionForBundle:bundle version:@"1.0" relativePath:@"Library/alog/app.log" state:logState evidence:cleanEvidence];
        require(dec.disposition == AxsCacheKeeperCleanupDelete && dec.basis == AxsCacheKeeperCleanupBasisUserLog, @"日志定级目录内纯日志可删");
        dec = [AxsCacheKeeperCleanupRules decisionForBundle:bundle version:@"1.0" relativePath:@"Library/alog/data.log" state:logState evidence:dataEvidence];
        require(dec.disposition == AxsCacheKeeperCleanupUnresolved, @"日志文件带数据证据不删除");
        dec = [AxsCacheKeeperCleanupRules decisionForBundle:bundle version:@"1.0" relativePath:@"Library/alog/photo.log.jpg" state:logState evidence:mediaEvidence];
        require(dec.disposition == AxsCacheKeeperCleanupUnresolved, @"日志名但媒体头不删除");
        dec = [AxsCacheKeeperCleanupRules decisionForBundle:bundle version:@"1.0" relativePath:@"Library/alog/inbox.log" state:logState evidence:cleanEvidence];
        require(dec.disposition == AxsCacheKeeperCleanupUnresolved, @"受保护名日志不删除");
        dec = [AxsCacheKeeperCleanupRules decisionForBundle:bundle version:@"1.0" relativePath:@"Library/alog/notes.txt" state:logState evidence:cleanEvidence];
        require(dec.disposition == AxsCacheKeeperCleanupUnresolved, @"非日志名不删除");
        // APP 规则：注册 / 匹配 / 版本 / 规则版本 / 可清范围交集。
        NSString *versionBefore = [AxsCacheKeeperCleanupRules rulesVersion];
        AxsCacheKeeperAppRule *testRule = [[AxsCacheKeeperAppRule alloc] initWithRuleID:@"test-downloads" revision:@"1" appVersion:@"1.0" cleanablePaths:@[@"Library/Downloads/cache"] retentionPaths:@[@"Library/Downloads/drafts"] dependencyPaths:@[@"Library/Downloads/index.json"]];
        [AxsCacheKeeperCleanupRules registerRule:testRule forBundle:bundle];
        require(![[AxsCacheKeeperCleanupRules rulesVersion] isEqualToString:versionBefore], @"注册规则改变规则版本");
        dec = [AxsCacheKeeperCleanupRules decisionForBundle:bundle version:@"1.0" relativePath:@"Library/Downloads/cache/res.bin" state:emptyState evidence:cleanEvidence];
        require(dec.disposition == AxsCacheKeeperCleanupDelete && dec.basis == AxsCacheKeeperCleanupBasisAppRule && [dec.dependencyPaths isEqualToArray:@[@"Library/Downloads/index.json"]], @"APP 规则可清理资源可删且携带依赖");
        dec = [AxsCacheKeeperCleanupRules decisionForBundle:bundle version:@"1.0" relativePath:@"Library/Downloads/drafts/draft.txt" state:emptyState evidence:cleanEvidence];
        require(dec.disposition == AxsCacheKeeperCleanupKeep && dec.basis == AxsCacheKeeperCleanupBasisAppRule, @"APP 规则保留范围保留");
        dec = [AxsCacheKeeperCleanupRules decisionForBundle:bundle version:@"2.0" relativePath:@"Library/Downloads/cache/res.bin" state:emptyState evidence:cleanEvidence];
        require(dec.disposition == AxsCacheKeeperCleanupUnresolved, @"APP 版本不匹配规则失效");
        dec = [AxsCacheKeeperCleanupRules decisionForBundle:bundle version:nil relativePath:@"Library/Downloads/cache/res.bin" state:emptyState evidence:cleanEvidence];
        require(dec.disposition == AxsCacheKeeperCleanupUnresolved, @"版本缺失时带版本规则不匹配");
        require([AxsCacheKeeperCleanupRules hasCleanableRangeForBundle:bundle version:@"1.0" relativePath:@"Library/Downloads"] &&
            [AxsCacheKeeperCleanupRules hasCleanableRangeForBundle:bundle version:@"1.0" relativePath:@"Library/Downloads/cache"] &&
            [AxsCacheKeeperCleanupRules hasCleanableRangeForBundle:bundle version:@"1.0" relativePath:@"Library/Downloads/cache/sub"] &&
            ![AxsCacheKeeperCleanupRules hasCleanableRangeForBundle:bundle version:@"1.0" relativePath:@"Library/Downloads/drafts"] &&
            ![AxsCacheKeeperCleanupRules hasCleanableRangeForBundle:bundle version:@"2.0" relativePath:@"Library/Downloads/cache"], @"可清范围交集：父/自身/子均命中，保留范围与版本不匹配不命中");
        [AxsCacheKeeperCleanupRules removeAllRulesForTesting];
        require([[AxsCacheKeeperCleanupRules rulesVersion] isEqualToString:versionBefore], @"清除测试规则后规则版本恢复");
        // ---- 任务 1：平台缓存主测试（Library/Caches 按用途全清，不按类型保留） ----
        require([fm createDirectoryAtPath:cache withIntermediateDirectories:YES attributes:nil error:nil], @"创建缓存根");
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
        AxsCacheKeeperSweep *fresh = [[AxsCacheKeeperSweep alloc] initWithRoot:cache bundle:bundle version:@"1.0" containerPath:sweepHome state:@{}];
        [fresh advance:30 shouldContinue:^BOOL { return YES; }];
        require(fresh.removed==0 && [fm fileExistsAtPath:[cache stringByAppendingPathComponent:@"new.tmp"]], @"真实新文件不删除");
        require(symlink(outside.fileSystemRepresentation, [cache stringByAppendingPathComponent:@"link"].fileSystemRepresentation) == 0, @"创建链接测试边界");
        AxsCacheKeeperSweep *sweep = makeSweep(cache, @{});
        for (NSUInteger pass = 0; !sweep.complete && pass < 100; pass++) {
            [sweep advance:1 shouldContinue:^BOOL { return YES; }];
        }
        require(sweep.complete && sweep.removed == 9 && sweep.failed == 0 && sweep.changedCount == 0,
            [NSString stringWithFormat:@"平台缓存单项分批全清：媒体/SQLite/无后缀/日志均删（removed=%lu failed=%lu changed=%lu）",(unsigned long)sweep.removed,(unsigned long)sweep.failed,(unsigned long)sweep.changedCount]);
        require(![fm fileExistsAtPath:[dataDirectory stringByAppendingPathComponent:@"business.sqlite"]] &&
            ![fm fileExistsAtPath:[dataDirectory stringByAppendingPathComponent:@"paired.png"]] &&
            ![fm fileExistsAtPath:[dataDirectory stringByAppendingPathComponent:@"assets/attachment.png"]] &&
            ![fm fileExistsAtPath:disguised] &&
            ![fm fileExistsAtPath:[cache stringByAppendingPathComponent:@"unknown-data"]] &&
            ![fm fileExistsAtPath:[dataDirectory stringByAppendingPathComponent:@"000003.log"]], @"平台缓存内数据库、配套媒体、无后缀与日志文件全部删除（格式不单独证明必须保留）");
        require([fm fileExistsAtPath:outside] && [fm fileExistsAtPath:cache], @"保留根目录与链接外用户文件");
        NSString *subfolder=[cache stringByAppendingPathComponent:@"later/deep"];
        require([fm createDirectoryAtPath:subfolder withIntermediateDirectories:YES attributes:nil error:nil], @"已选父目录内新增子目录");
        NSString *laterFile=[subfolder stringByAppendingPathComponent:@"later.cache"];
        writeMedia(laterFile);
        AxsCacheKeeperSweep *nextSweep = makeSweep(cache, @{});
        for (NSUInteger pass=0;!nextSweep.complete && pass<100;pass++) [nextSweep advance:2 shouldContinue:^BOOL{return YES;}];
        require(nextSweep.complete && nextSweep.removed==1 && ![fm fileExistsAtPath:laterFile],
            [NSString stringWithFormat:@"后续扫描自动覆盖父目录中新生子目录，无需新增配置（complete=%d removed=%lu failed=%lu protected=%lu recent=%lu changed=%lu inspected=%lu error=%@）",
                nextSweep.complete,(unsigned long)nextSweep.removed,(unsigned long)nextSweep.failed,(unsigned long)nextSweep.protectedCount,
                (unsigned long)nextSweep.recentCount,(unsigned long)nextSweep.changedCount,(unsigned long)nextSweep.inspected,nextSweep.error]);
        // tmp 同为平台缓存根：媒体、数据库、无后缀均删。
        NSString *tmpRoot=[sweepHome stringByAppendingPathComponent:@"tmp"];
        require([fm createDirectoryAtPath:tmpRoot withIntermediateDirectories:YES attributes:nil error:nil], @"tmp 根夹具");
        writeMedia([tmpRoot stringByAppendingPathComponent:@"clip.mp4"]);
        require([@"SQLite format 3\0payload" writeToFile:[tmpRoot stringByAppendingPathComponent:@"state.sqlite"] atomically:YES encoding:NSUTF8StringEncoding error:nil], @"tmp 数据库夹具");
        writeFile([tmpRoot stringByAppendingPathComponent:@"opaque"]);
        AxsCacheKeeperSweep *tmpSweep = makeSweep(tmpRoot, @{});
        for (NSUInteger pass=0;!tmpSweep.complete && pass<100;pass++) [tmpSweep advance:64 shouldContinue:^BOOL{return YES;}];
        require(tmpSweep.complete && tmpSweep.failed==0 && tmpSweep.removed==3 &&
            ![fm fileExistsAtPath:[tmpRoot stringByAppendingPathComponent:@"clip.mp4"]] &&
            ![fm fileExistsAtPath:[tmpRoot stringByAppendingPathComponent:@"state.sqlite"]] &&
            ![fm fileExistsAtPath:[tmpRoot stringByAppendingPathComponent:@"opaque"]] &&
            [fm fileExistsAtPath:tmpRoot], @"tmp 按平台缓存用途全清，根目录本身保留");
        // 方案任务 8 迁移：旧 fullClear=false 的状态在新标准范围内同样按平台规则全清
        //（数据库、无后缀文件不再因旧开关被类型过滤）；旧 fullClear=true/false 归一化已证明相同。
        NSString *migrateRoot=[sweepHome stringByAppendingPathComponent:@"Library/Caches/job-migrate"];
        require([fm createDirectoryAtPath:migrateRoot withIntermediateDirectories:YES attributes:nil error:nil], @"迁移根夹具");
        writeMedia([migrateRoot stringByAppendingPathComponent:@"clip.mp4"]);
        require([@"SQLite format 3\0payload" writeToFile:[migrateRoot stringByAppendingPathComponent:@"state.sqlite"] atomically:YES encoding:NSUTF8StringEncoding error:nil], @"迁移数据库夹具");
        writeFile([migrateRoot stringByAppendingPathComponent:@"opaque"]);
        AxsCacheKeeperSweep *migrateSweep = makeSweep(migrateRoot, @{@"fullClear":@NO});
        [migrateSweep advance:64 shouldContinue:^BOOL { return YES; }];
        require(migrateSweep.removed==3 && migrateSweep.failed==0 && migrateSweep.unresolvedCount==0 &&
            ![fm fileExistsAtPath:[migrateRoot stringByAppendingPathComponent:@"clip.mp4"]] &&
            ![fm fileExistsAtPath:[migrateRoot stringByAppendingPathComponent:@"state.sqlite"]] &&
            ![fm fileExistsAtPath:[migrateRoot stringByAppendingPathComponent:@"opaque"]] &&
            [fm fileExistsAtPath:migrateRoot], @"旧 fullClear=false 不再类型过滤标准缓存，数据库与无后缀文件同样清理");
        // 方案任务 6：排除子目录时父根保留，文件级排除裁剪子树，合法同级范围继续处理。
        NSString *exclRoot=[sweepHome stringByAppendingPathComponent:@"Library/Caches/job-excl"];
        NSString *exclKeep=[exclRoot stringByAppendingPathComponent:@"keep"];
        require([fm createDirectoryAtPath:exclKeep withIntermediateDirectories:YES attributes:nil error:nil], @"排除同级夹具");
        writeMedia([exclRoot stringByAppendingPathComponent:@"sibling.mp4"]);
        writeMedia([exclKeep stringByAppendingPathComponent:@"kept.mp4"]);
        AxsCacheKeeperSweep *exclSweep = makeSweep(exclRoot, @{@"excludedPaths":@[@"Library/Caches/job-excl/keep"]});
        [exclSweep advance:64 shouldContinue:^BOOL { return YES; }];
        require(exclSweep.removed==1 && exclSweep.protectedCount==1 && exclSweep.failed==0 &&
            ![fm fileExistsAtPath:[exclRoot stringByAppendingPathComponent:@"sibling.mp4"]] &&
            [fm fileExistsAtPath:[exclKeep stringByAppendingPathComponent:@"kept.mp4"]], @"排除子树的文件保留，同级文件照常清理");
        // 保留子树裁剪：平台根内的 Preferences 子树整片保留，其余独立文件照常删除。
        NSString *prefRoot=[sweepHome stringByAppendingPathComponent:@"tmp/pref-root"];
        require([fm createDirectoryAtPath:[prefRoot stringByAppendingPathComponent:@"Preferences"] withIntermediateDirectories:YES attributes:nil error:nil], @"保留子树夹具");
        writeFile([prefRoot stringByAppendingPathComponent:@"Preferences/a.txt"]);
        writeFile([prefRoot stringByAppendingPathComponent:@"plain.txt"]);
        AxsCacheKeeperSweep *prefSweep = makeSweep(prefRoot, @{});
        for (NSUInteger pass=0;!prefSweep.complete && pass<100;pass++) [prefSweep advance:64 shouldContinue:^BOOL{return YES;}];
        require(prefSweep.complete && prefSweep.failed==0 && prefSweep.removed==1 &&
            [fm fileExistsAtPath:[prefRoot stringByAppendingPathComponent:@"Preferences/a.txt"]] &&
            ![fm fileExistsAtPath:[prefRoot stringByAppendingPathComponent:@"plain.txt"]], @"保留子树裁剪只保护自身，独立范围继续清理");
        // 删除失败回执：真实删除返回 EINVAL 时保留文件并准确记录调用阶段。
        NSString *errorRoot=[sweepHome stringByAppendingPathComponent:@"Library/Caches/unlink-error"];
        require([fm createDirectoryAtPath:errorRoot withIntermediateDirectories:YES attributes:nil error:nil], @"失败回执夹具");
        writeMedia([errorRoot stringByAppendingPathComponent:@"old.png"]);
        AxsCacheKeeperSweep *failureSweep=[[AxsCacheKeeperSweep alloc] initWithRoot:errorRoot bundle:bundle version:@"1.0" containerPath:sweepHome state:@{} clock:^NSTimeInterval{return future;} unlinkFile:^int(int fd,const char *name) {
            struct stat parent;require(!fstat(fd,&parent) && S_ISDIR(parent.st_mode) && !strcmp(name,"old.png"), @"删除仍限定已打开父目录和单一文件名");
            errno=EINVAL;return -1;
        }];
        for (NSUInteger pass=0;!failureSweep.complete && pass<20;pass++) [failureSweep advance:2 shouldContinue:^BOOL{return YES;}];
        require(failureSweep.complete && failureSweep.removed==0 && failureSweep.failed==1 && failureSweep.remainingCandidates==1 && failureSweep.remainingBytes==12 &&
            [failureSweep.error containsString:@"unlinkat"] && [failureSweep.failureDetails.firstObject[@"code"] intValue]==EINVAL &&
            [failureSweep.failureDetails.firstObject[@"stage"] isEqual:@"unlinkat"] &&
            [fm fileExistsAtPath:[errorRoot stringByAppendingPathComponent:@"old.png"]], @"真实删除返回 EINVAL 时保留文件并准确记录调用阶段，不能冒充已清理");
        // 深层快照键：大小批次都使用一致的父目录与快照键；平台规则下数据库后代同样删除。
        for (NSNumber *batchLimit in @[@1,@64]) {
            NSString *deepRoot=[sweepHome stringByAppendingPathComponent:[NSString stringWithFormat:@"Library/Caches/deep-keys-%@",batchLimit]];
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
            AxsCacheKeeperSweep *deepSweep = makeSweep(deepRoot, @{});
            for (NSUInteger pass=0;!deepSweep.complete && pass<100;pass++) [deepSweep advance:batchLimit.unsignedIntegerValue shouldContinue:^BOOL{return YES;}];
            require(deepSweep.complete && deepSweep.removed==4 && deepSweep.failed==0 && deepSweep.changedCount==0 &&
                ![fm fileExistsAtPath:attachment], @"大小批次都使用一致的父目录与快照键，平台缓存内数据库后代同样删除");
        }
        // 根目录替换：预检完成后、删除前根被换成链接时停止清理，外部媒体仍保留。
        // 根须为平台根——无候选时删除阶段直接完成，根身份核对不会触发。
        NSString *replacedRoot=[sweepHome stringByAppendingPathComponent:@"Library/Caches/replaced-root"];
        NSString *externalRoot=[fixture stringByAppendingPathComponent:@"external-root"];
        require([fm createDirectoryAtPath:replacedRoot withIntermediateDirectories:YES attributes:nil error:nil] &&
            [fm createDirectoryAtPath:[externalRoot stringByAppendingPathComponent:@"child"] withIntermediateDirectories:YES attributes:nil error:nil], @"根目录替换夹具");
        NSString *externalMedia=[externalRoot stringByAppendingPathComponent:@"keep.png"];
        writeMedia(externalMedia);writeMedia([replacedRoot stringByAppendingPathComponent:@"old.png"]);
        AxsCacheKeeperSweep *replaced = makeSweep(replacedRoot, @{});
        // 拆分接口直接建立“预检完成、尚未删除”的注入点（用户核对要求）：不再经兼容 advance:，
        // 避免 wrapper 的单调用单阶段语义成为测试的前提。
        for (NSUInteger pass=0;replaced.checking && !replaced.complete && pass<20;pass++) [replaced advancePreflight:1];
        require(!replaced.checking && !replaced.complete && replaced.removed==0, @"根替换发生在完整预检后且删除前");
        require([fm moveItemAtPath:replacedRoot toPath:[replacedRoot stringByAppendingString:@"-saved"] error:nil] &&
            !symlink(externalRoot.fileSystemRepresentation,replacedRoot.fileSystemRepresentation), @"预检后用链接替换根目录");
        [replaced advanceDeletion:64 shouldContinue:^BOOL{return YES;}];
        require(replaced.complete && replaced.removed==0 && replaced.failed>0 && [fm fileExistsAtPath:externalMedia], @"根目录被换成链接时停止清理，外部媒体仍保留");
        int linked=axs_cachekeeper_open_directory(replacedRoot);
        require(linked<0, @"共享访问函数继续拒绝末级目录链接");
        linked=axs_cachekeeper_open_directory([replacedRoot stringByAppendingPathComponent:@"child"]);
        require(linked>=0, @"中间目录链接按 #27 跟随（真机容器路径含 /var 等中间链接），仅末级链接拒绝；根替换安全由 sweep 的身份核对保证");
        if (linked>=0) close(linked);
        // 平台缓存全量：同一根内媒体、无后缀、数据库、子目录数据库与媒体全部删除，目录本身保留。
        // 旧 fullClear 开关已不存在——平台规则本身就是全量行为，不再有普通/全量对照。
        NSString *fullRoot=[sweepHome stringByAppendingPathComponent:@"Library/Caches/full-cache"];
        require([fm createDirectoryAtPath:[fullRoot stringByAppendingPathComponent:@"store"] withIntermediateDirectories:YES attributes:nil error:nil], @"全量清理夹具");
        writeMedia([fullRoot stringByAppendingPathComponent:@"clip.mp4"]);
        writeFile([fullRoot stringByAppendingPathComponent:@"blob.bin"]);
        require([@"SQLite format 3\0payload" writeToFile:[fullRoot stringByAppendingPathComponent:@"state.sqlite"] atomically:YES encoding:NSUTF8StringEncoding error:nil], @"全量清理数据库夹具");
        writeFile([fullRoot stringByAppendingPathComponent:@"store/inner.sqlite"]);
        writeMedia([fullRoot stringByAppendingPathComponent:@"store/poster.png"]);
        AxsCacheKeeperSweep *fullSweep = makeSweep(fullRoot, @{});
        for (NSUInteger pass=0;!fullSweep.complete && pass<100;pass++) [fullSweep advance:64 shouldContinue:^BOOL{return YES;}];
        require(fullSweep.complete && fullSweep.failed==0 && fullSweep.removed==5,
            [NSString stringWithFormat:@"平台缓存删除根内全部普通文件（removed=%lu failed=%lu）",(unsigned long)fullSweep.removed,(unsigned long)fullSweep.failed]);
        require(![fm fileExistsAtPath:[fullRoot stringByAppendingPathComponent:@"clip.mp4"]] &&
            ![fm fileExistsAtPath:[fullRoot stringByAppendingPathComponent:@"blob.bin"]] &&
            ![fm fileExistsAtPath:[fullRoot stringByAppendingPathComponent:@"state.sqlite"]] &&
            ![fm fileExistsAtPath:[fullRoot stringByAppendingPathComponent:@"store/inner.sqlite"]] &&
            ![fm fileExistsAtPath:[fullRoot stringByAppendingPathComponent:@"store/poster.png"]] &&
            [fm fileExistsAtPath:fullRoot] && [fm fileExistsAtPath:[fullRoot stringByAppendingPathComponent:@"store"]], @"平台缓存清理后文件清空、目录本身保留");
        // 真机形态（抖音 2026-11-11）：数据文件藏在子目录里而非根级——平台规则删净
        // 该子树内全部文件且不报阶段错误（此前真机 263 项 errno 22 全灭）。
        NSString *nestedRoot=[sweepHome stringByAppendingPathComponent:@"Library/Caches/nested-cache"];
        require([fm createDirectoryAtPath:[nestedRoot stringByAppendingPathComponent:@"vault"] withIntermediateDirectories:YES attributes:nil error:nil], @"嵌套数据子树夹具");
        writeMedia([nestedRoot stringByAppendingPathComponent:@"loose.png"]);
        writeFile([nestedRoot stringByAppendingPathComponent:@"vault/inner.sqlite"]);
        writeMedia([nestedRoot stringByAppendingPathComponent:@"vault/photo.png"]);
        writeMedia([nestedRoot stringByAppendingPathComponent:@"vault/clip.mp4"]);
        AxsCacheKeeperSweep *nestedSweep = makeSweep(nestedRoot, @{});
        for (NSUInteger pass=0;!nestedSweep.complete && pass<100;pass++) [nestedSweep advance:64 shouldContinue:^BOOL{return YES;}];
        require(nestedSweep.complete && nestedSweep.failed==0 && nestedSweep.removed==4 && !nestedSweep.error.length &&
            ![fm fileExistsAtPath:[nestedRoot stringByAppendingPathComponent:@"loose.png"]] &&
            ![fm fileExistsAtPath:[nestedRoot stringByAppendingPathComponent:@"vault/inner.sqlite"]] &&
            ![fm fileExistsAtPath:[nestedRoot stringByAppendingPathComponent:@"vault/photo.png"]] &&
            ![fm fileExistsAtPath:[nestedRoot stringByAppendingPathComponent:@"vault/clip.mp4"]] &&
            [fm fileExistsAtPath:[nestedRoot stringByAppendingPathComponent:@"vault"]],
            [NSString stringWithFormat:@"平台缓存删净嵌套数据子树（removed=%lu failed=%lu error=%@）",(unsigned long)nestedSweep.removed,(unsigned long)nestedSweep.failed,nestedSweep.error]);
        // 日志定级通道（通用机制，2026-11-11）：定级只接受用途未知目录；日志规则只删日志特征文件，
        // 媒体/文本保留，数据文件本体保留（含其内日志文件——数据证据否决）。
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
        AxsCacheKeeperSweep *logSweep = makeFlatSweep(logRoot, @{@"logPaths": @[@"Library/alog"]});
        for (NSUInteger pass=0;!logSweep.complete && pass<100;pass++) [logSweep advance:64 shouldContinue:^BOOL{return YES;}];
        require(logSweep.complete && logSweep.failed==0 && logSweep.removed==4,
            [NSString stringWithFormat:@"日志规则只删日志特征文件（removed=%lu failed=%lu error=%@）",(unsigned long)logSweep.removed,(unsigned long)logSweep.failed,logSweep.error]);
        require(![fm fileExistsAtPath:[logRoot stringByAppendingPathComponent:@"ready/BDALog_20261111_193314.alog.iOS.1128"]] &&
            ![fm fileExistsAtPath:[logRoot stringByAppendingPathComponent:@"ready/today.log"]] &&
            ![fm fileExistsAtPath:[logRoot stringByAppendingPathComponent:@"top.alog"]] &&
            [fm fileExistsAtPath:[logRoot stringByAppendingPathComponent:@"ready/poster.png"]] &&
            [fm fileExistsAtPath:[logRoot stringByAppendingPathComponent:@"ready/notes.txt"]] &&
            [fm fileExistsAtPath:[logRoot stringByAppendingPathComponent:@"vault/inner.sqlite"]] &&
            ![fm fileExistsAtPath:[logRoot stringByAppendingPathComponent:@"vault/inside.log"]], @"日志规则文件级保护：数据文件本体保留，其旁的日志文件照常清理");
        // 混放目录（真机 alog 的 ready/ 形态）：数据名文件、SQLite 头文件与纯日志同目录时，
        // 数据文件只保护自身，不得整目录连坐；深层嵌套（四级）日志必须能走到删除（祖先链记录键回归）。
        NSString *mixedRoot=[fixture stringByAppendingPathComponent:@"mixed-log"];
        require([fm createDirectoryAtPath:[mixedRoot stringByAppendingPathComponent:@"ready"] withIntermediateDirectories:YES attributes:nil error:nil], @"混放日志目录夹具");
        writeFile([mixedRoot stringByAppendingPathComponent:@"ready/pure-one.alog"]);
        writeFile([mixedRoot stringByAppendingPathComponent:@"ready/pure-two.log"]);
        writeFile([mixedRoot stringByAppendingPathComponent:@"ready/000003.log"]);
        require([@"SQLite format 3\0payload" writeToFile:[mixedRoot stringByAppendingPathComponent:@"ready/fake.alog"] atomically:YES encoding:NSUTF8StringEncoding error:nil], @"伪装日志名的数据库夹具");
        writeFile([mixedRoot stringByAppendingPathComponent:@"ready/plain.txt"]);
        AxsCacheKeeperSweep *mixedSweep = makeFlatSweep(mixedRoot, @{@"logPaths": @[@"mixed-log"]});
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
        AxsCacheKeeperSweep *deepLogSweep = makeFlatSweep(deepRoot, @{@"logPaths": @[@"deep-log"]});
        for (NSUInteger pass=0;!deepLogSweep.complete && pass<100;pass++) [deepLogSweep advance:64 shouldContinue:^BOOL{return YES;}];
        require(deepLogSweep.complete && deepLogSweep.failed==0 && deepLogSweep.removed==2 &&
            ![fm fileExistsAtPath:[deepRoot stringByAppendingPathComponent:@"a/b/c/d/deep.alog"]] &&
            ![fm fileExistsAtPath:[deepRoot stringByAppendingPathComponent:@"a/b/mid.log"]],
            [NSString stringWithFormat:@"四级嵌套日志可删（removed=%lu failed=%lu error=%@）",(unsigned long)deepLogSweep.removed,(unsigned long)deepLogSweep.failed,deepLogSweep.error]);
        // 热目录稳定性（2026-11-11 抖音 alog 真机：目录级门下 14 个目录判变化、整轮删除 0）：
        // 预检后同目录兄弟文件被改写时，文件级稳定性门只跳过变化文件本身，其余预检通过的
        // 日志照常删除。任务 1 后稳定性门是通用的——平台根同样只跳过变化文件本身。
        NSString *hotRoot=[fixture stringByAppendingPathComponent:@"hot-log"];
        require([fm createDirectoryAtPath:[hotRoot stringByAppendingPathComponent:@"ready"] withIntermediateDirectories:YES attributes:nil error:nil], @"热日志目录夹具");
        writeFile([hotRoot stringByAppendingPathComponent:@"ready/stable-one.alog"]);
        writeFile([hotRoot stringByAppendingPathComponent:@"ready/stable-two.log"]);
        writeFile([hotRoot stringByAppendingPathComponent:@"ready/keep-changing.log"]);
        AxsCacheKeeperSweep *hotLog = makeFlatSweep(hotRoot, @{@"logPaths": @[@"hot-log"]});
        for (NSUInteger pass=0;hotLog.checking && !hotLog.complete && pass<100;pass++) [hotLog advance:1 shouldContinue:^BOOL{return YES;}];
        require(!hotLog.checking && hotLog.removed==0, @"热目录预检阶段不删除");
        writeFile([hotRoot stringByAppendingPathComponent:@"ready/keep-changing.log"]);
        for (NSUInteger pass=0;!hotLog.complete && pass<100;pass++) [hotLog advance:64 shouldContinue:^BOOL{return YES;}];
        require(hotLog.complete && hotLog.failed==0 && hotLog.removed==2 && hotLog.changedCount>0,
            [NSString stringWithFormat:@"日志规则文件级稳定性门：兄弟变化只跳过自身（removed=%lu failed=%lu changed=%lu error=%@）",(unsigned long)hotLog.removed,(unsigned long)hotLog.failed,(unsigned long)hotLog.changedCount,hotLog.error]);
        require(![fm fileExistsAtPath:[hotRoot stringByAppendingPathComponent:@"ready/stable-one.alog"]] &&
            ![fm fileExistsAtPath:[hotRoot stringByAppendingPathComponent:@"ready/stable-two.log"]] &&
            [fm fileExistsAtPath:[hotRoot stringByAppendingPathComponent:@"ready/keep-changing.log"]], @"变化文件保留、稳定日志删除");
        // 同一场景换平台根：兄弟变化只跳过变化文件本身，不再整目录保留（旧目录级门已删除）。
        NSString *hotRoot2=[sweepHome stringByAppendingPathComponent:@"Library/Caches/hot-full"];
        require([fm createDirectoryAtPath:[hotRoot2 stringByAppendingPathComponent:@"ready"] withIntermediateDirectories:YES attributes:nil error:nil], @"热目录平台根夹具");
        writeFile([hotRoot2 stringByAppendingPathComponent:@"ready/stable-one.alog"]);
        writeFile([hotRoot2 stringByAppendingPathComponent:@"ready/stable-two.log"]);
        writeFile([hotRoot2 stringByAppendingPathComponent:@"ready/keep-changing.log"]);
        AxsCacheKeeperSweep *hotPlatform = makeSweep(hotRoot2, @{});
        for (NSUInteger pass=0;hotPlatform.checking && !hotPlatform.complete && pass<100;pass++) [hotPlatform advance:1 shouldContinue:^BOOL{return YES;}];
        require(!hotPlatform.checking && hotPlatform.removed==0, @"平台根预检阶段不删除");
        writeFile([hotRoot2 stringByAppendingPathComponent:@"ready/keep-changing.log"]);
        for (NSUInteger pass=0;!hotPlatform.complete && pass<100;pass++) [hotPlatform advance:64 shouldContinue:^BOOL{return YES;}];
        require(hotPlatform.complete && hotPlatform.failed==0 && hotPlatform.removed==2 && hotPlatform.changedCount>0 &&
            ![fm fileExistsAtPath:[hotRoot2 stringByAppendingPathComponent:@"ready/stable-one.alog"]] &&
            ![fm fileExistsAtPath:[hotRoot2 stringByAppendingPathComponent:@"ready/stable-two.log"]] &&
            [fm fileExistsAtPath:[hotRoot2 stringByAppendingPathComponent:@"ready/keep-changing.log"]], @"平台根文件级稳定性门：兄弟变化只跳过自身，稳定文件照常删除");
        // 未知目录内容审查（B 案候选集口径仍有效）：清理候选集只取未定级未知目录；
        // 全新 APP 默认自动发现开启，只开总开关即全自动。任务 1 后未知内容无规则即
        // Unresolved，不自动删除——以下测试断言零删除与未确认计数。
        require(axs_cachekeeper_auto_discover(nil) && axs_cachekeeper_auto_discover(@{@"enabled":@YES}), @"全新 APP 默认自动发现开启");
        require(!axs_cachekeeper_auto_discover(@{@"autoDiscover":@NO}), @"已明确关闭自动发现的保持关闭");
        require([axs_cachekeeper_app_state(nil,YES)[@"autoDiscover"] boolValue], @"全新 APP 状态保存默认自动发现开启");
        require([axs_cachekeeper_purge_paths(@[@"Library/tma",@"Library/alog",@"Library/Caches",@"Library/Preferences"],@{@"enabled":@YES,@"logPaths":@[@"Library/alog"]}) isEqual:@[@"Library/tma"]], @"清理候选集只取未定级未知目录");
        NSString *excludeFolder=[fixture stringByAppendingPathComponent:@"exclude-state"];
        require([fm createDirectoryAtPath:excludeFolder withIntermediateDirectories:YES attributes:nil error:nil], @"排除状态夹具");
        require(!axs_cachekeeper_set_excluded_path(excludeFolder,@"com.example.app",@"Library/tma",YES), @"未知目录可单独保留");
        NSDictionary *excludedState2=[NSDictionary dictionaryWithContentsOfFile:[excludeFolder stringByAppendingPathComponent:@"appEnabled.plist"]][@"com.example.app"];
        require([axs_cachekeeper_exclusions(excludedState2) containsObject:@"Library/tma"] &&
            ![axs_cachekeeper_purge_paths(@[@"Library/tma",@"Library/Pitaya"],excludedState2) containsObject:@"Library/tma"], @"保留的未知目录退出内容审查候选集");
        require([axs_cachekeeper_exclusions(axs_cachekeeper_app_state(excludedState2,YES)) containsObject:@"Library/tma"], @"切模式/总开关保留未知目录的保留选择");
        require(!axs_cachekeeper_set_excluded_path(excludeFolder,@"com.example.app",@"Library/tma",NO), @"保留可取消，恢复自动审查");
        NSDictionary *unexcludedState=[NSDictionary dictionaryWithContentsOfFile:[excludeFolder stringByAppendingPathComponent:@"appEnabled.plist"]][@"com.example.app"];
        require(![axs_cachekeeper_exclusions(unexcludedState) containsObject:@"Library/tma"] &&
            [axs_cachekeeper_purge_paths(@[@"Library/tma",@"Library/Pitaya"],unexcludedState) containsObject:@"Library/tma"], @"取消保留后恢复为清理候选");
        // 任务 6：排除子目录时未知候选父目录保留，文件级排除裁剪子树，不丢合法同级范围。
        require([axs_cachekeeper_purge_paths(@[@"Library/tma",@"Library/Pitaya"],@{@"enabled":@YES,@"excludedPaths":@[@"Library/tma/keep"]}) containsObject:@"Library/tma"], @"排除子目录时未知候选父目录保留");
        require(![axs_cachekeeper_purge_paths(@[@"Library/tma/keep"],@{@"enabled":@YES,@"excludedPaths":@[@"Library/tma/keep"]}) count], @"排除子树本身退出候选集");
        // 未知目录零证据：4 个文件全部 Unresolved，零删除，残留占用与首条证据可见。
        NSString *purgeRoot=[fixture stringByAppendingPathComponent:@"purge-clean"];
        require([fm createDirectoryAtPath:[purgeRoot stringByAppendingPathComponent:@"runtime"] withIntermediateDirectories:YES attributes:nil error:nil], @"清理目录夹具");
        writeMedia([purgeRoot stringByAppendingPathComponent:@"runtime/model.bin"]);
        writeFile([purgeRoot stringByAppendingPathComponent:@"runtime/config.json"]);
        writeFile([purgeRoot stringByAppendingPathComponent:@"runtime/settings.plist"]);
        writeFile([purgeRoot stringByAppendingPathComponent:@"top.txt"]);
        AxsCacheKeeperSweep *purgeClean = makeFlatSweep(purgeRoot, @{});
        for (NSUInteger pass=0;!purgeClean.complete && pass<100;pass++) [purgeClean advance:64 shouldContinue:^BOOL{return YES;}];
        require(purgeClean.complete && purgeClean.failed==0 && purgeClean.removed==0 && purgeClean.unresolvedCount==4 && purgeClean.unresolvedBytes>0 && purgeClean.unresolvedEvidence.length>0 && !purgeClean.dependencyInvalidated,
            [NSString stringWithFormat:@"未知目录零证据不自动删除，残留占用可见（removed=%lu unresolved=%lu bytes=%llu error=%@）",(unsigned long)purgeClean.removed,(unsigned long)purgeClean.unresolvedCount,purgeClean.unresolvedBytes,purgeClean.error]);
        require([fm fileExistsAtPath:[purgeRoot stringByAppendingPathComponent:@"runtime/model.bin"]] &&
            [fm fileExistsAtPath:[purgeRoot stringByAppendingPathComponent:@"runtime/config.json"]] &&
            [fm fileExistsAtPath:[purgeRoot stringByAppendingPathComponent:@"runtime/settings.plist"]] &&
            [fm fileExistsAtPath:[purgeRoot stringByAppendingPathComponent:@"top.txt"]], @"未知目录零证据根文件全部保留，待专属识别规则");
        // 未知目录含伪装数据库：数据证据不产生删除依据，2 个文件全部 Unresolved。
        NSString *purgeDb=[fixture stringByAppendingPathComponent:@"purge-db"];
        require([fm createDirectoryAtPath:purgeDb withIntermediateDirectories:YES attributes:nil error:nil], @"含数据库的清理目录夹具");
        writeMedia([purgeDb stringByAppendingPathComponent:@"thumb.png"]);
        require([@"SQLite format 3\0payload" writeToFile:[purgeDb stringByAppendingPathComponent:@"hidden.bin"] atomically:YES encoding:NSUTF8StringEncoding error:nil], @"伪装数据库夹具");
        AxsCacheKeeperSweep *purgeDbSweep = makeFlatSweep(purgeDb, @{});
        for (NSUInteger pass=0;!purgeDbSweep.complete && pass<100;pass++) [purgeDbSweep advance:64 shouldContinue:^BOOL{return YES;}];
        require(purgeDbSweep.complete && purgeDbSweep.failed==0 && purgeDbSweep.removed==0 && purgeDbSweep.unresolvedCount==2 &&
            [fm fileExistsAtPath:[purgeDb stringByAppendingPathComponent:@"thumb.png"]] &&
            [fm fileExistsAtPath:[purgeDb stringByAppendingPathComponent:@"hidden.bin"]], @"未知目录含数据库：全部未确认、零删除");
        // 未知目录混放：未定级时 3 个文件全部 Unresolved；定级后只删纯日志。
        NSString *purgeMixedDir=[fixture stringByAppendingPathComponent:@"purge-mixed"];
        require([fm createDirectoryAtPath:purgeMixedDir withIntermediateDirectories:YES attributes:nil error:nil], @"日志与数据混放的清理目录夹具");
        writeFile([purgeMixedDir stringByAppendingPathComponent:@"app.log"]);
        require([@"SQLite format 3\0payload" writeToFile:[purgeMixedDir stringByAppendingPathComponent:@"data.bin"] atomically:YES encoding:NSUTF8StringEncoding error:nil], @"混放数据库夹具");
        writeFile([purgeMixedDir stringByAppendingPathComponent:@"notes.txt"]);
        AxsCacheKeeperSweep *purgeMixedSweep = makeFlatSweep(purgeMixedDir, @{});
        for (NSUInteger pass=0;!purgeMixedSweep.complete && pass<100;pass++) [purgeMixedSweep advance:64 shouldContinue:^BOOL{return YES;}];
        require(purgeMixedSweep.complete && purgeMixedSweep.failed==0 && purgeMixedSweep.removed==0 && purgeMixedSweep.unresolvedCount==3 &&
            [fm fileExistsAtPath:[purgeMixedDir stringByAppendingPathComponent:@"app.log"]] &&
            [fm fileExistsAtPath:[purgeMixedDir stringByAppendingPathComponent:@"data.bin"]] &&
            [fm fileExistsAtPath:[purgeMixedDir stringByAppendingPathComponent:@"notes.txt"]], @"未定级混放目录全部未确认、零删除");
        AxsCacheKeeperSweep *purgeMixedGraded = makeFlatSweep(purgeMixedDir, @{@"logPaths": @[@"purge-mixed"]});
        for (NSUInteger pass=0;!purgeMixedGraded.complete && pass<100;pass++) [purgeMixedGraded advance:64 shouldContinue:^BOOL{return YES;}];
        require(purgeMixedGraded.complete && purgeMixedGraded.failed==0 && purgeMixedGraded.removed==1 &&
            ![fm fileExistsAtPath:[purgeMixedDir stringByAppendingPathComponent:@"app.log"]] &&
            [fm fileExistsAtPath:[purgeMixedDir stringByAppendingPathComponent:@"data.bin"]] &&
            [fm fileExistsAtPath:[purgeMixedDir stringByAppendingPathComponent:@"notes.txt"]], @"定级后混放目录仅删纯日志，数据与未知内容保留");
        // 受保护子目录：Preferences 子树裁剪（不计入未确认），其余文件未确认。
        NSString *purgeNamed=[fixture stringByAppendingPathComponent:@"purge-named"];
        require([fm createDirectoryAtPath:[purgeNamed stringByAppendingPathComponent:@"Preferences"] withIntermediateDirectories:YES attributes:nil error:nil], @"含受保护子目录的清理夹具");
        writeFile([purgeNamed stringByAppendingPathComponent:@"Preferences/a.txt"]);
        writeFile([purgeNamed stringByAppendingPathComponent:@"plain.txt"]);
        AxsCacheKeeperSweep *purgeNamedSweep = makeFlatSweep(purgeNamed, @{});
        for (NSUInteger pass=0;!purgeNamedSweep.complete && pass<100;pass++) [purgeNamedSweep advance:64 shouldContinue:^BOOL{return YES;}];
        require(purgeNamedSweep.complete && purgeNamedSweep.removed==0 && purgeNamedSweep.unresolvedCount==1 &&
            [fm fileExistsAtPath:[purgeNamed stringByAppendingPathComponent:@"Preferences/a.txt"]] &&
            [fm fileExistsAtPath:[purgeNamed stringByAppendingPathComponent:@"plain.txt"]], @"受保护子目录裁剪不计入未确认，其余文件未确认保留");
        // 数据标记子目录名：session-cache 子树裁剪（不计入未确认），其余文件未确认。
        NSString *purgeDirNamed=[fixture stringByAppendingPathComponent:@"purge-dirnamed"];
        require([fm createDirectoryAtPath:[purgeDirNamed stringByAppendingPathComponent:@"session-cache"] withIntermediateDirectories:YES attributes:nil error:nil], @"含数据标记子目录的清理夹具");
        writeFile([purgeDirNamed stringByAppendingPathComponent:@"session-cache/a.txt"]);
        writeFile([purgeDirNamed stringByAppendingPathComponent:@"run.log"]);
        AxsCacheKeeperSweep *purgeDirNamedSweep = makeFlatSweep(purgeDirNamed, @{});
        for (NSUInteger pass=0;!purgeDirNamedSweep.complete && pass<100;pass++) [purgeDirNamedSweep advance:64 shouldContinue:^BOOL{return YES;}];
        require(purgeDirNamedSweep.complete && purgeDirNamedSweep.failed==0 && purgeDirNamedSweep.removed==0 && purgeDirNamedSweep.unresolvedCount==1 &&
            [fm fileExistsAtPath:[purgeDirNamed stringByAppendingPathComponent:@"session-cache/a.txt"]] &&
            [fm fileExistsAtPath:[purgeDirNamed stringByAppendingPathComponent:@"run.log"]], @"数据标记子目录裁剪不计入未确认，其余文件未确认保留");
        // 受保护文件名混放：未定级时 3 个文件全部 Unresolved；定级后只删普通日志，
        // inbox.log（受保护成分）与数据库保留。
        NSString *purgeProtectedFile=[fixture stringByAppendingPathComponent:@"purge-protected-file"];
        require([fm createDirectoryAtPath:purgeProtectedFile withIntermediateDirectories:YES attributes:nil error:nil], @"受保护文件名混放的清理夹具");
        writeFile([purgeProtectedFile stringByAppendingPathComponent:@"app.log"]);
        writeFile([purgeProtectedFile stringByAppendingPathComponent:@"inbox.log"]);
        require([@"SQLite format 3\0payload" writeToFile:[purgeProtectedFile stringByAppendingPathComponent:@"data.bin"] atomically:YES encoding:NSUTF8StringEncoding error:nil], @"受保护文件名混放数据库夹具");
        AxsCacheKeeperSweep *purgeProtectedFileSweep = makeFlatSweep(purgeProtectedFile, @{});
        for (NSUInteger pass=0;!purgeProtectedFileSweep.complete && pass<100;pass++) [purgeProtectedFileSweep advance:64 shouldContinue:^BOOL{return YES;}];
        require(purgeProtectedFileSweep.complete && purgeProtectedFileSweep.failed==0 && purgeProtectedFileSweep.removed==0 && purgeProtectedFileSweep.unresolvedCount==3 &&
            [fm fileExistsAtPath:[purgeProtectedFile stringByAppendingPathComponent:@"app.log"]] &&
            [fm fileExistsAtPath:[purgeProtectedFile stringByAppendingPathComponent:@"inbox.log"]] &&
            [fm fileExistsAtPath:[purgeProtectedFile stringByAppendingPathComponent:@"data.bin"]], @"未定级混放目录全部未确认、零删除");
        AxsCacheKeeperSweep *purgeProtectedFileGraded = makeFlatSweep(purgeProtectedFile, @{@"logPaths": @[@"purge-protected-file"]});
        for (NSUInteger pass=0;!purgeProtectedFileGraded.complete && pass<100;pass++) [purgeProtectedFileGraded advance:64 shouldContinue:^BOOL{return YES;}];
        require(purgeProtectedFileGraded.complete && purgeProtectedFileGraded.failed==0 && purgeProtectedFileGraded.removed==1 &&
            ![fm fileExistsAtPath:[purgeProtectedFile stringByAppendingPathComponent:@"app.log"]] &&
            [fm fileExistsAtPath:[purgeProtectedFile stringByAppendingPathComponent:@"inbox.log"]] &&
            [fm fileExistsAtPath:[purgeProtectedFile stringByAppendingPathComponent:@"data.bin"]], @"定级后受保护路径否决：inbox.log 保留、普通日志删除");
        // 不可读文件：明确失败并延期，不能伪装为正常保护或完整覆盖。
        NSString *purgeUnreadable=[fixture stringByAppendingPathComponent:@"purge-unreadable"];
        require([fm createDirectoryAtPath:purgeUnreadable withIntermediateDirectories:YES attributes:nil error:nil], @"含不可读文件的清理夹具");
        NSString *unreadableLog=[purgeUnreadable stringByAppendingPathComponent:@"secret.log"];
        writeFile(unreadableLog);
        writeMedia([purgeUnreadable stringByAppendingPathComponent:@"thumb.png"]);
        require(!chmod(unreadableLog.fileSystemRepresentation, 0000), @"不可读文件夹具");
        AxsCacheKeeperSweep *purgeUnreadableSweep = makeFlatSweep(purgeUnreadable, @{});
        for (NSUInteger pass=0;!purgeUnreadableSweep.complete && pass<100;pass++) [purgeUnreadableSweep advance:64 shouldContinue:^BOOL{return YES;}];
        chmod(unreadableLog.fileSystemRepresentation, 0644);
        require(purgeUnreadableSweep.complete && purgeUnreadableSweep.failed==1 && purgeUnreadableSweep.removed==0 && purgeUnreadableSweep.deferredCount==1 && purgeUnreadableSweep.unresolvedCount==1 &&
            [fm fileExistsAtPath:unreadableLog] &&
            [fm fileExistsAtPath:[purgeUnreadable stringByAppendingPathComponent:@"thumb.png"]], @"不可读文件计失败并延期、其余未确认，全部保留待重试");
        // 日志门媒体头否决：photo.log.jpg 挂日志名但内容是图片，按文件头否决，真日志仍可删。
        NSString *logMediaDir=[fixture stringByAppendingPathComponent:@"log-media"];
        require([fm createDirectoryAtPath:logMediaDir withIntermediateDirectories:YES attributes:nil error:nil], @"日志目录媒体夹具");
        writeFile([logMediaDir stringByAppendingPathComponent:@"app.log"]);
        writeMedia([logMediaDir stringByAppendingPathComponent:@"photo.log.jpg"]);
        AxsCacheKeeperSweep *logMediaSweep = makeFlatSweep(logMediaDir, @{@"logPaths": @[@"log-media"]});
        for (NSUInteger pass=0;!logMediaSweep.complete && pass<100;pass++) [logMediaSweep advance:64 shouldContinue:^BOOL{return YES;}];
        require(logMediaSweep.complete && logMediaSweep.failed==0 && logMediaSweep.removed==1 &&
            ![fm fileExistsAtPath:[logMediaDir stringByAppendingPathComponent:@"app.log"]] &&
            [fm fileExistsAtPath:[logMediaDir stringByAppendingPathComponent:@"photo.log.jpg"]], @"日志门媒体头否决：挂日志名的图片保留、真日志删除");
        // 热目录日志门（确定性覆盖）：预检后改写的日志只跳过自身，稳定日志删除，数据库保留。
        NSString *hotPurgeRoot=[fixture stringByAppendingPathComponent:@"hot-purge"];
        require([fm createDirectoryAtPath:[hotPurgeRoot stringByAppendingPathComponent:@"ready"] withIntermediateDirectories:YES attributes:nil error:nil], @"热清理目录夹具");
        writeFile([hotPurgeRoot stringByAppendingPathComponent:@"ready/stable-one.log"]);
        writeFile([hotPurgeRoot stringByAppendingPathComponent:@"ready/stable-two.log"]);
        writeFile([hotPurgeRoot stringByAppendingPathComponent:@"ready/keep-changing.log"]);
        require([@"SQLite format 3\0payload" writeToFile:[hotPurgeRoot stringByAppendingPathComponent:@"ready/data.bin"] atomically:YES encoding:NSUTF8StringEncoding error:nil], @"热清理混合证据");
        AxsCacheKeeperSweep *hotPurge = makeFlatSweep(hotPurgeRoot, @{@"logPaths": @[@"hot-purge"]});
        for (NSUInteger pass=0;hotPurge.checking && !hotPurge.complete && pass<100;pass++) [hotPurge advance:1 shouldContinue:^BOOL{return YES;}];
        require(!hotPurge.checking && hotPurge.removed==0, @"清理模式预检阶段不删除");
        writeFile([hotPurgeRoot stringByAppendingPathComponent:@"ready/keep-changing.log"]);
        for (NSUInteger pass=0;!hotPurge.complete && pass<100;pass++) [hotPurge advance:64 shouldContinue:^BOOL{return YES;}];
        require(hotPurge.complete && hotPurge.failed==0 && hotPurge.removed==2 && hotPurge.changedCount>0,
            [NSString stringWithFormat:@"日志门文件级稳定性门：兄弟变化只跳过自身（removed=%lu failed=%lu changed=%lu error=%@）",(unsigned long)hotPurge.removed,(unsigned long)hotPurge.failed,(unsigned long)hotPurge.changedCount,hotPurge.error]);
        require(![fm fileExistsAtPath:[hotPurgeRoot stringByAppendingPathComponent:@"ready/stable-one.log"]] &&
            ![fm fileExistsAtPath:[hotPurgeRoot stringByAppendingPathComponent:@"ready/stable-two.log"]] &&
            [fm fileExistsAtPath:[hotPurgeRoot stringByAppendingPathComponent:@"ready/keep-changing.log"]] &&
            [fm fileExistsAtPath:[hotPurgeRoot stringByAppendingPathComponent:@"ready/data.bin"]], @"变化文件保留、稳定日志删除、数据库保留");
        // 任务 1：APP 专属规则扫除。非标准目录命中经过验证的资源规则时，可清资源删除，
        // 草稿与资源索引与消息记录保留；根为 Downloads 名目录——已验证规则优先于名称启发式。
        AxsCacheKeeperAppRule *appRule = [[AxsCacheKeeperAppRule alloc] initWithRuleID:@"test-downloads" revision:@"1" appVersion:@"1.0" cleanablePaths:@[@"Library/Downloads/cache"] retentionPaths:@[@"Library/Downloads/drafts"] dependencyPaths:@[@"Library/Downloads/index.json"]];
        [AxsCacheKeeperCleanupRules registerRule:appRule forBundle:bundle];
        NSString *downloadsRoot=[sweepHome stringByAppendingPathComponent:@"Library/Downloads"];
        require([fm createDirectoryAtPath:[downloadsRoot stringByAppendingPathComponent:@"cache"] withIntermediateDirectories:YES attributes:nil error:nil] &&
            [fm createDirectoryAtPath:[downloadsRoot stringByAppendingPathComponent:@"drafts"] withIntermediateDirectories:YES attributes:nil error:nil], @"APP 规则夹具");
        writeMedia([downloadsRoot stringByAppendingPathComponent:@"cache/res1.bin"]);
        writeMedia([downloadsRoot stringByAppendingPathComponent:@"cache/res2.bin"]);
        writeFile([downloadsRoot stringByAppendingPathComponent:@"drafts/draft1.txt"]);
        writeFile([downloadsRoot stringByAppendingPathComponent:@"index.json"]);
        require([@"SQLite format 3\0payload" writeToFile:[downloadsRoot stringByAppendingPathComponent:@"messages.db"] atomically:YES encoding:NSUTF8StringEncoding error:nil], @"APP 规则消息库夹具");
        AxsCacheKeeperSweep *appSweep = makeSweep(downloadsRoot, @{});
        for (NSUInteger pass=0;!appSweep.complete && pass<100;pass++) [appSweep advance:64 shouldContinue:^BOOL{return YES;}];
        require(appSweep.complete && appSweep.failed==0 && appSweep.removed==2 && appSweep.unresolvedCount==1 && !appSweep.dependencyInvalidated &&
            ![fm fileExistsAtPath:[downloadsRoot stringByAppendingPathComponent:@"cache/res1.bin"]] &&
            ![fm fileExistsAtPath:[downloadsRoot stringByAppendingPathComponent:@"cache/res2.bin"]] &&
            [fm fileExistsAtPath:[downloadsRoot stringByAppendingPathComponent:@"drafts/draft1.txt"]] &&
            [fm fileExistsAtPath:[downloadsRoot stringByAppendingPathComponent:@"index.json"]] &&
            [fm fileExistsAtPath:[downloadsRoot stringByAppendingPathComponent:@"messages.db"]], @"APP 规则：可清资源删除、草稿与资源索引与消息记录保留");
        // 预检后修改规则依赖（资源索引）：相关范围失效、本轮延期，依赖路径可见。
        writeMedia([downloadsRoot stringByAppendingPathComponent:@"cache/res1.bin"]);
        writeMedia([downloadsRoot stringByAppendingPathComponent:@"cache/res2.bin"]);
        AxsCacheKeeperSweep *appDepSweep = makeSweep(downloadsRoot, @{});
        for (NSUInteger pass=0;appDepSweep.checking && !appDepSweep.complete && pass<100;pass++) [appDepSweep advance:1 shouldContinue:^BOOL{return YES;}];
        require(!appDepSweep.checking && appDepSweep.removed==0, @"依赖测试基线：预检完成、未删除");
        writeFile([downloadsRoot stringByAppendingPathComponent:@"index.json"]);
        for (NSUInteger pass=0;!appDepSweep.complete && pass<100;pass++) [appDepSweep advance:64 shouldContinue:^BOOL{return YES;}];
        require(appDepSweep.complete && appDepSweep.dependencyInvalidated && [appDepSweep.invalidEvidence isEqual:@"Library/Downloads/index.json"] && appDepSweep.removed==0 && appDepSweep.changedCount==2 &&
            [fm fileExistsAtPath:[downloadsRoot stringByAppendingPathComponent:@"cache/res1.bin"]] &&
            [fm fileExistsAtPath:[downloadsRoot stringByAppendingPathComponent:@"cache/res2.bin"]], @"预检后规则依赖变化：相关范围失效、本轮延期");
        // 规则依赖缺失：决定不成立，相关文件本轮延期（计变化），下轮重新预检时重建决定。
        NSString *downloadsMissing=[sweepHome stringByAppendingPathComponent:@"Library/Downloads2"];
        require([fm createDirectoryAtPath:[downloadsMissing stringByAppendingPathComponent:@"cache"] withIntermediateDirectories:YES attributes:nil error:nil], @"依赖缺失夹具");
        writeMedia([downloadsMissing stringByAppendingPathComponent:@"cache/res1.bin"]);
        writeMedia([downloadsMissing stringByAppendingPathComponent:@"cache/res2.bin"]);
        AxsCacheKeeperAppRule *missingRule = [[AxsCacheKeeperAppRule alloc] initWithRuleID:@"test-downloads-missing" revision:@"1" appVersion:@"1.0" cleanablePaths:@[@"Library/Downloads2/cache"] retentionPaths:@[] dependencyPaths:@[@"Library/Downloads2/index.json"]];
        [AxsCacheKeeperCleanupRules registerRule:missingRule forBundle:bundle];
        AxsCacheKeeperSweep *appMissingSweep = makeSweep(downloadsMissing, @{});
        for (NSUInteger pass=0;!appMissingSweep.complete && pass<100;pass++) [appMissingSweep advance:64 shouldContinue:^BOOL{return YES;}];
        require(appMissingSweep.complete && appMissingSweep.dependencyInvalidated && [appMissingSweep.invalidEvidence isEqual:@"Library/Downloads2/index.json"] && appMissingSweep.removed==0 && appMissingSweep.changedCount==2 &&
            [fm fileExistsAtPath:[downloadsMissing stringByAppendingPathComponent:@"cache/res1.bin"]] &&
            [fm fileExistsAtPath:[downloadsMissing stringByAppendingPathComponent:@"cache/res2.bin"]], @"规则依赖缺失：相关文件本轮延期");
        [AxsCacheKeeperCleanupRules removeAllRulesForTesting];
        // 方案任务 3（P1-3）：CleanupJob 状态机与期限/预算。作业时钟注入 jobNow（手动推进），
        // 根时钟用 future（文件已够 60 秒，可删）；近期文件测试的根用真实时钟。
        // 作业根均为平台根（Library/Caches 下）——未知根无可删候选，无法验证删除推进。
        __block NSTimeInterval jobNow = 1000;
        NSTimeInterval (^jobClock)(void) = ^NSTimeInterval { return jobNow; };
        BOOL (^jobGate)(void) = ^BOOL { return YES; };
        // 1. 非对称双根：A 10 文件、B 1 文件。B 先完成预检时 A 仍在预检，B 不得删除；
        // 全部预检完成前期限不得启动；Ready 时零删除、文件完好。
        NSString *jobRootA=[sweepHome stringByAppendingPathComponent:@"Library/Caches/job-a"];
        NSString *jobRootB=[sweepHome stringByAppendingPathComponent:@"Library/Caches/job-b"];
        require([fm createDirectoryAtPath:jobRootA withIntermediateDirectories:YES attributes:nil error:nil], @"作业根 A 夹具");
        require([fm createDirectoryAtPath:jobRootB withIntermediateDirectories:YES attributes:nil error:nil], @"作业根 B 夹具");
        for (int i=0;i<10;i++) writeMedia([jobRootA stringByAppendingPathComponent:[NSString stringWithFormat:@"a%d.png",i]]);
        writeMedia([jobRootB stringByAppendingPathComponent:@"b0.png"]);
        AxsCacheKeeperSweep *jobSweepA = makeSweep(jobRootA, @{});
        AxsCacheKeeperSweep *jobSweepB = makeSweep(jobRootB, @{});
        AxsCacheKeeperCleanupJob *job=[[AxsCacheKeeperCleanupJob alloc] initWithSweeps:@[jobSweepA,jobSweepB] signature:@"job-sig" instance:@"1:100" clock:jobClock];
        for (NSUInteger pass=0;pass<3;pass++) [job advanceCycleWithPerRootLimit:1 gate:jobGate];
        require(job.phase==AxsCacheKeeperCleanupPhaseChecking && !jobSweepB.checking && jobSweepA.checking && jobSweepB.removed==0 && job.removed==0 && job.deleteDeadline==0, @"任一根在预检时，任何根都不删除、期限不启动");
        for (NSUInteger pass=0;job.phase==AxsCacheKeeperCleanupPhaseChecking && pass<100;pass++) [job advanceCycleWithPerRootLimit:1 gate:jobGate];
        require(job.phase==AxsCacheKeeperCleanupPhaseReady && job.removed==0 && job.deleteDeadline==0 &&
            [fm fileExistsAtPath:[jobRootA stringByAppendingPathComponent:@"a0.png"]] &&
            [fm fileExistsAtPath:[jobRootB stringByAppendingPathComponent:@"b0.png"]], @"全部预检完成才 Ready；预检零删除、期限未启动");
        // 2. 首次真实删除推进启动 120 秒期限（jobNow=1000 → 截止 1120）。
        [job advanceCycleWithPerRootLimit:1 gate:jobGate];
        require(job.phase==AxsCacheKeeperCleanupPhaseDeleting && job.deleteDeadline==1120 && job.removed==2, @"首次删除推进启动期限（1000+120）");
        // 3. 期限边界：1119 未到仍继续，1120 到达即触顶收尾，不再删除。
        jobNow=1119;
        [job advanceCycleWithPerRootLimit:1 gate:jobGate];
        require(job.phase==AxsCacheKeeperCleanupPhaseDeleting && job.removed==3, @"期限前一秒仍可删除");
        jobNow=1120;
        [job advanceCycleWithPerRootLimit:1 gate:jobGate];
        require(job.phase==AxsCacheKeeperCleanupPhaseFinished && job.endReason==AxsCacheKeeperCleanupEndReasonLimitReached && job.removed==3 &&
            jobSweepA.removed==2 && jobSweepB.removed==1 &&
            [[fm contentsOfDirectoryAtPath:jobRootA error:nil] count]==8 && [[fm contentsOfDirectoryAtPath:jobRootB error:nil] count]==0 &&
            job.removed + [[fm contentsOfDirectoryAtPath:jobRootA error:nil] count] + [[fm contentsOfDirectoryAtPath:jobRootB error:nil] count]==11,
            @"期限到达即触顶：A 删 2 剩 8，B 删 1 剩 0，总量守恒 11");
        // 4. 空根不启动计时：空根 E＋有文件根 F。Ready 时期限仍为 0；首次删除推进（F）才启动。
        NSString *jobRootE=[sweepHome stringByAppendingPathComponent:@"Library/Caches/job-e"];
        NSString *jobRootF=[sweepHome stringByAppendingPathComponent:@"Library/Caches/job-f"];
        require([fm createDirectoryAtPath:jobRootE withIntermediateDirectories:YES attributes:nil error:nil], @"作业空根夹具");
        require([fm createDirectoryAtPath:jobRootF withIntermediateDirectories:YES attributes:nil error:nil], @"作业有文件根夹具");
        writeMedia([jobRootF stringByAppendingPathComponent:@"f0.png"]);
        writeMedia([jobRootF stringByAppendingPathComponent:@"f1.png"]);
        AxsCacheKeeperSweep *jobSweepE = makeSweep(jobRootE, @{});
        AxsCacheKeeperSweep *jobSweepF = makeSweep(jobRootF, @{});
        jobNow=2000;
        AxsCacheKeeperCleanupJob *jobEF=[[AxsCacheKeeperCleanupJob alloc] initWithSweeps:@[jobSweepE,jobSweepF] signature:@"job-ef" instance:@"1:100" clock:jobClock];
        for (NSUInteger pass=0;jobEF.phase==AxsCacheKeeperCleanupPhaseChecking && pass<100;pass++) [jobEF advanceCycleWithPerRootLimit:64 gate:jobGate];
        require(jobEF.phase==AxsCacheKeeperCleanupPhaseReady && jobEF.deleteDeadline==0 && jobSweepE.inspected==0, @"空根预检 0 项，不启动计时");
        [jobEF advanceCycleWithPerRootLimit:64 gate:jobGate];
        require(jobEF.deleteDeadline==2120 && jobSweepE.complete && jobEF.removed==2 && jobEF.endReason==AxsCacheKeeperCleanupEndReasonCompleted && !jobEF.partial, @"有文件根首次删除推进启动期限，空根同时完成；干净轮 Completed 且非部分完成");
        // 4b. 仅含未确认内容的根不启动计时：U 根 3 个未知文件（无可删候选），V 根 1 个平台文件。
        // Ready 时期限为 0；首次删除推进（V）才启动；U 完成时零删除、未确认计数聚合进作业。
        NSString *jobRootU=[sweepHome stringByAppendingPathComponent:@"Library/Pitaya"];
        NSString *jobRootV=[sweepHome stringByAppendingPathComponent:@"Library/Caches/job-v"];
        require([fm createDirectoryAtPath:jobRootU withIntermediateDirectories:YES attributes:nil error:nil], @"作业未确认根夹具");
        require([fm createDirectoryAtPath:jobRootV withIntermediateDirectories:YES attributes:nil error:nil], @"作业有候选根夹具");
        for (int i=0;i<3;i++) writeMedia([jobRootU stringByAppendingPathComponent:[NSString stringWithFormat:@"u%d.png",i]]);
        writeMedia([jobRootV stringByAppendingPathComponent:@"v0.png"]);
        AxsCacheKeeperSweep *jobSweepU = makeSweep(jobRootU, @{});
        AxsCacheKeeperSweep *jobSweepV = makeSweep(jobRootV, @{});
        jobNow=2500;
        AxsCacheKeeperCleanupJob *jobUV=[[AxsCacheKeeperCleanupJob alloc] initWithSweeps:@[jobSweepU,jobSweepV] signature:@"job-uv" instance:@"1:100" clock:jobClock];
        for (NSUInteger pass=0;jobUV.phase==AxsCacheKeeperCleanupPhaseChecking && pass<100;pass++) [jobUV advanceCycleWithPerRootLimit:64 gate:jobGate];
        require(jobUV.phase==AxsCacheKeeperCleanupPhaseReady && jobUV.deleteDeadline==0 && jobSweepU.unresolvedCount==3 && !jobSweepU.hasDeleteCandidates, @"未确认根预检完成、无可删候选、不启动期限");
        [jobUV advanceCycleWithPerRootLimit:64 gate:jobGate];
        require(jobUV.deleteDeadline==2620 && jobUV.removed==1 && jobSweepU.complete && jobSweepU.removed==0 && jobSweepU.unresolvedCount==3 && jobUV.unresolvedCount==3 && jobUV.endReason==AxsCacheKeeperCleanupEndReasonUnresolved && jobUV.partial, @"有候选根首次删除推进启动期限，未确认根完成且零删除、未确认计数聚合；残留轮报 Unresolved 部分完成");
        // 5. 2000 项全作业共享硬上限：2005 文件单根，触顶收尾，剩 5 个。
        NSString *capRoot=[sweepHome stringByAppendingPathComponent:@"Library/Caches/job-cap"];
        require([fm createDirectoryAtPath:capRoot withIntermediateDirectories:YES attributes:nil error:nil], @"预算上限夹具");
        for (int i=0;i<2005;i++) writeMedia([capRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"f%d.png",i]]);
        AxsCacheKeeperSweep *capSweep = makeSweep(capRoot, @{});
        jobNow=3000;
        AxsCacheKeeperCleanupJob *capJob=[[AxsCacheKeeperCleanupJob alloc] initWithSweeps:@[capSweep] signature:@"job-cap" instance:@"1:100" clock:jobClock];
        for (NSUInteger pass=0;capJob.phase!=AxsCacheKeeperCleanupPhaseFinished && pass<100;pass++) [capJob advanceCycleWithPerRootLimit:256 gate:jobGate];
        require(capJob.endReason==AxsCacheKeeperCleanupEndReasonLimitReached && capJob.removed==AxsCacheKeeperCleanupRoundItemCap && capJob.inspected==2005 && !capJob.partial && capSweep.remainingCandidates==5 && capSweep.remainingBytes==60 &&
            [[fm contentsOfDirectoryAtPath:capRoot error:nil] count]==5, @"2000 项硬封顶，剩余 5 个顺延下轮；预检实际访问 2005 项，触顶不是部分完成");
        // 6. 近期文件根：真实时钟下新建文件均未满 60 秒，整轮完成但 0 删除、recent>0。
        NSString *recentRoot=[sweepHome stringByAppendingPathComponent:@"Library/Caches/job-recent"];
        require([fm createDirectoryAtPath:recentRoot withIntermediateDirectories:YES attributes:nil error:nil], @"近期文件根夹具");
        for (int i=0;i<3;i++) writeMedia([recentRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"r%d.png",i]]);
        AxsCacheKeeperSweep *recentSweep=[[AxsCacheKeeperSweep alloc] initWithRoot:recentRoot bundle:bundle version:@"1.0" containerPath:sweepHome state:@{}];
        jobNow=4000;
        AxsCacheKeeperCleanupJob *recentJob=[[AxsCacheKeeperCleanupJob alloc] initWithSweeps:@[recentSweep] signature:@"job-recent" instance:@"1:100" clock:jobClock];
        for (NSUInteger pass=0;recentJob.phase!=AxsCacheKeeperCleanupPhaseFinished && pass<100;pass++) [recentJob advanceCycleWithPerRootLimit:64 gate:jobGate];
        require(recentJob.endReason==AxsCacheKeeperCleanupEndReasonCompleted && recentJob.deleteDeadline==0 && recentJob.removed==0 && recentJob.recentCount==3 && recentSweep.deferredCount==3 && recentSweep.deferredBytes==36, @"仅近期文件不启动期限，延期类 3 项 · 36 字节");
        // 7. 门控关闭取消轮次：Ready 后门控关闭，作业取消收尾。
        NSString *cancelRoot=[sweepHome stringByAppendingPathComponent:@"Library/Caches/job-cancel"];
        require([fm createDirectoryAtPath:cancelRoot withIntermediateDirectories:YES attributes:nil error:nil], @"取消轮次夹具");
        writeMedia([cancelRoot stringByAppendingPathComponent:@"c0.png"]);
        AxsCacheKeeperSweep *cancelSweep = makeSweep(cancelRoot, @{});
        __block BOOL gateOpen = YES;
        BOOL (^cancelGate)(void) = ^BOOL { return gateOpen; };
        jobNow=5000;
        AxsCacheKeeperCleanupJob *cancelJob=[[AxsCacheKeeperCleanupJob alloc] initWithSweeps:@[cancelSweep] signature:@"job-cancel" instance:@"1:100" clock:jobClock];
        for (NSUInteger pass=0;cancelJob.phase==AxsCacheKeeperCleanupPhaseChecking && pass<100;pass++) [cancelJob advanceCycleWithPerRootLimit:64 gate:cancelGate];
        require(cancelJob.phase==AxsCacheKeeperCleanupPhaseReady, @"取消测试基线：Ready");
        gateOpen = NO;
        [cancelJob advanceCycleWithPerRootLimit:64 gate:cancelGate];
        require(cancelJob.phase==AxsCacheKeeperCleanupPhaseFinished && cancelJob.endReason==AxsCacheKeeperCleanupEndReasonCancelled && cancelJob.removed==0, @"门控关闭取消轮次，不删除");
        // 8. 预检耗时不触发删除期限：10 文件根，perRootLimit=1，每预检周期作业时钟推进 30 秒。
        // 预检走满 300 秒以上；Ready 时期限仍为 0；首次删除推进才从当前时刻起算 120 秒。
        NSString *slowRoot=[sweepHome stringByAppendingPathComponent:@"Library/Caches/job-slow"];
        require([fm createDirectoryAtPath:slowRoot withIntermediateDirectories:YES attributes:nil error:nil], @"慢预检夹具");
        for (int i=0;i<10;i++) writeMedia([slowRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"s%d.png",i]]);
        AxsCacheKeeperSweep *slowSweep = makeSweep(slowRoot, @{});
        jobNow=6000;
        NSTimeInterval slowStart = jobNow;
        AxsCacheKeeperCleanupJob *slowJob=[[AxsCacheKeeperCleanupJob alloc] initWithSweeps:@[slowSweep] signature:@"job-slow" instance:@"1:100" clock:jobClock];
        for (NSUInteger pass=0;slowJob.phase==AxsCacheKeeperCleanupPhaseChecking && pass<100;pass++) { [slowJob advanceCycleWithPerRootLimit:1 gate:jobGate]; jobNow += 30; }
        require(slowJob.phase==AxsCacheKeeperCleanupPhaseReady && slowJob.deleteDeadline==0 && jobNow - slowStart >= 300, @"预检耗时 300 秒以上，期限仍未启动");
        [slowJob advanceCycleWithPerRootLimit:1 gate:jobGate];
        require(slowJob.deleteDeadline==jobNow+120 && slowJob.removed==1, @"首次删除推进从当前时刻起算 120 秒期限");
        // 9. 预算跨根共享：A 根 1999 文件＋B 根 10 文件，perRootLimit=2000 时单删除周期内
        // A 删完 1999 后 B 只删 1 个、剩 9 个——2000 上限是全作业共享，不是每根一份。
        NSString *shareRootA=[sweepHome stringByAppendingPathComponent:@"Library/Caches/job-share-a"];
        NSString *shareRootB=[sweepHome stringByAppendingPathComponent:@"Library/Caches/job-share-b"];
        require([fm createDirectoryAtPath:shareRootA withIntermediateDirectories:YES attributes:nil error:nil], @"跨根预算夹具 A");
        require([fm createDirectoryAtPath:shareRootB withIntermediateDirectories:YES attributes:nil error:nil], @"跨根预算夹具 B");
        for (int i=0;i<1999;i++) writeMedia([shareRootA stringByAppendingPathComponent:[NSString stringWithFormat:@"a%d.png",i]]);
        for (int i=0;i<10;i++) writeMedia([shareRootB stringByAppendingPathComponent:[NSString stringWithFormat:@"b%d.png",i]]);
        AxsCacheKeeperSweep *shareSweepA = makeSweep(shareRootA, @{});
        AxsCacheKeeperSweep *shareSweepB = makeSweep(shareRootB, @{});
        jobNow=7000;
        AxsCacheKeeperCleanupJob *shareJob=[[AxsCacheKeeperCleanupJob alloc] initWithSweeps:@[shareSweepA,shareSweepB] signature:@"job-share" instance:@"1:100" clock:jobClock];
        for (NSUInteger pass=0;shareJob.phase!=AxsCacheKeeperCleanupPhaseFinished && pass<100;pass++) [shareJob advanceCycleWithPerRootLimit:2000 gate:jobGate];
        require(shareJob.endReason==AxsCacheKeeperCleanupEndReasonLimitReached && shareJob.removed==2000 && shareSweepA.removed==1999 && shareSweepB.removed==1 &&
            [[fm contentsOfDirectoryAtPath:shareRootA error:nil] count]==0 && [[fm contentsOfDirectoryAtPath:shareRootB error:nil] count]==9, @"预算全作业共享：1999＋1 封顶，B 根剩 9 个");
        // 10. 多轮精确累计：同一根 4500 文件，分三轮 2000＋2000＋500 删完，合计精确 4500，根清空。
        NSString *multiRoot=[sweepHome stringByAppendingPathComponent:@"Library/Caches/job-multi"];
        require([fm createDirectoryAtPath:multiRoot withIntermediateDirectories:YES attributes:nil error:nil], @"多轮累计夹具");
        for (int i=0;i<4500;i++) writeMedia([multiRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"m%d.png",i]]);
        jobNow=8000;
        NSUInteger multiTotal = 0;
        AxsCacheKeeperSweep *multiSweep1 = makeSweep(multiRoot, @{});
        AxsCacheKeeperCleanupJob *multiJob1=[[AxsCacheKeeperCleanupJob alloc] initWithSweeps:@[multiSweep1] signature:@"job-multi-1" instance:@"1:100" clock:jobClock];
        for (NSUInteger pass=0;multiJob1.phase!=AxsCacheKeeperCleanupPhaseFinished && pass<100;pass++) [multiJob1 advanceCycleWithPerRootLimit:256 gate:jobGate];
        require(multiJob1.endReason==AxsCacheKeeperCleanupEndReasonLimitReached && multiJob1.removed==2000 && multiJob1.inspected==4500 && multiSweep1.remainingCandidates==2500 && multiSweep1.remainingBytes==30000, @"多轮其一：触顶 2000，预检实际访问 4500 项，剩余 2500 项 · 30000 字节");
        multiTotal += multiJob1.removed;
        AxsCacheKeeperSweep *multiSweep2 = makeSweep(multiRoot, @{});
        AxsCacheKeeperCleanupJob *multiJob2=[[AxsCacheKeeperCleanupJob alloc] initWithSweeps:@[multiSweep2] signature:@"job-multi-2" instance:@"1:100" clock:jobClock];
        for (NSUInteger pass=0;multiJob2.phase!=AxsCacheKeeperCleanupPhaseFinished && pass<100;pass++) [multiJob2 advanceCycleWithPerRootLimit:256 gate:jobGate];
        require(multiJob2.endReason==AxsCacheKeeperCleanupEndReasonLimitReached && multiJob2.removed==2000 && multiSweep2.remainingCandidates==500 && multiSweep2.remainingBytes==6000, @"多轮其二：触顶 2000，剩余 500 项 · 6000 字节");
        multiTotal += multiJob2.removed;
        AxsCacheKeeperSweep *multiSweep3 = makeSweep(multiRoot, @{});
        AxsCacheKeeperCleanupJob *multiJob3=[[AxsCacheKeeperCleanupJob alloc] initWithSweeps:@[multiSweep3] signature:@"job-multi-3" instance:@"1:100" clock:jobClock];
        for (NSUInteger pass=0;multiJob3.phase!=AxsCacheKeeperCleanupPhaseFinished && pass<100;pass++) [multiJob3 advanceCycleWithPerRootLimit:256 gate:jobGate];
        require(multiJob3.endReason==AxsCacheKeeperCleanupEndReasonCompleted && multiJob3.removed==500 && multiTotal + multiJob3.removed == 4500 &&
            [[fm contentsOfDirectoryAtPath:multiRoot error:nil] count]==0 && !multiSweep3.hasDeleteCandidates && multiSweep3.remainingCandidates==0, @"多轮其三：删完剩余 500，合计精确 4500，根清空、无候选");
        // 11. 近期文件成熟后处理：复用近期根（3 文件，首轮因未满 60 秒 0 删除），
        // 第二轮用新鲜 future 时钟重新判定，3 个全部删除——近期候选不永久挂起。
        NSTimeInterval future2 = [[NSDate date] timeIntervalSince1970] + 120;
        AxsCacheKeeperSweep *matureSweep = [[AxsCacheKeeperSweep alloc] initWithRoot:recentRoot bundle:bundle version:@"1.0" containerPath:sweepHome state:@{} clock:^NSTimeInterval { return future2; }];
        jobNow=9000;
        AxsCacheKeeperCleanupJob *matureJob=[[AxsCacheKeeperCleanupJob alloc] initWithSweeps:@[matureSweep] signature:@"job-mature" instance:@"1:100" clock:jobClock];
        for (NSUInteger pass=0;matureJob.phase!=AxsCacheKeeperCleanupPhaseFinished && pass<100;pass++) [matureJob advanceCycleWithPerRootLimit:64 gate:jobGate];
        require(matureJob.endReason==AxsCacheKeeperCleanupEndReasonCompleted && matureJob.removed==3 && matureJob.recentCount==0 &&
            [[fm contentsOfDirectoryAtPath:recentRoot error:nil] count]==0, @"近期文件成熟后第二轮全部删除");
        // 批次内期限：时间由每次真实 unlink 推进，不依赖内部检查次数。
        NSString *midRoot=[sweepHome stringByAppendingPathComponent:@"Library/Caches/job-midbatch"];
        require([fm createDirectoryAtPath:midRoot withIntermediateDirectories:YES attributes:nil error:nil], @"批次中期限夹具");
        for (int i=0;i<10;i++) writeMedia([midRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"d%d.png",i]]);
        __block NSTimeInterval midNow=10000;
        AxsCacheKeeperSweep *midSweep=[[AxsCacheKeeperSweep alloc] initWithRoot:midRoot bundle:bundle version:@"1.0" containerPath:sweepHome state:@{} clock:^NSTimeInterval { return future; } unlinkFile:^int(int fd,const char *name) {
            int result=unlinkat(fd,name,0); if (!result) midNow+=24; return result;
        }];
        AxsCacheKeeperCleanupJob *midJob=[[AxsCacheKeeperCleanupJob alloc] initWithSweeps:@[midSweep] signature:@"job-midbatch" instance:@"1:100" clock:^NSTimeInterval { return midNow; }];
        for (NSUInteger pass=0;midJob.phase!=AxsCacheKeeperCleanupPhaseFinished && pass<100;pass++) [midJob advanceCycleWithPerRootLimit:64 gate:jobGate];
        require(midJob.endReason==AxsCacheKeeperCleanupEndReasonLimitReached && midJob.removed==5 && midJob.deleteDeadline==10120 &&
            [[fm contentsOfDirectoryAtPath:midRoot error:nil] count]==5, @"批次中期限到达即停手：删 5 个、剩 5 个、触顶收尾");
        // 任务 1：预检后变化的黑盒语义（候选列表模型）。删除阶段只遍历预检产生的
        // 候选列表：预检后新增的文件不混入旧候选；预检后被改写的文件只跳过自身；
        // 预检后被删的文件计变化；自身删除不误判。无白盒 fileSnapshots 操作。
        NSString *invalNewDb=[sweepHome stringByAppendingPathComponent:@"Library/Caches/inval-newdb"];
        require([fm createDirectoryAtPath:invalNewDb withIntermediateDirectories:YES attributes:nil error:nil], @"分类失效新数据库夹具");
        writeMedia([invalNewDb stringByAppendingPathComponent:@"victim.bin"]);
        writeFile([invalNewDb stringByAppendingPathComponent:@"other.log"]);
        AxsCacheKeeperSweep *invalDb = makeSweep(invalNewDb, @{});
        for (NSUInteger pass=0;invalDb.checking && !invalDb.complete && pass<100;pass++) [invalDb advance:1 shouldContinue:^BOOL{return YES;}];
        require(!invalDb.checking && invalDb.removed==0, @"预检完成、未删除");
        require([@"SQLite format 3\0payload" writeToFile:[invalNewDb stringByAppendingPathComponent:@"state.bin"] atomically:YES encoding:NSUTF8StringEncoding error:nil], @"预检后新增伪装数据库");
        for (NSUInteger pass=0;!invalDb.complete && pass<100;pass++) [invalDb advance:64 shouldContinue:^BOOL{return YES;}];
        require(invalDb.complete && invalDb.removed==2 && invalDb.changedCount==0 &&
            ![fm fileExistsAtPath:[invalNewDb stringByAppendingPathComponent:@"victim.bin"]] &&
            ![fm fileExistsAtPath:[invalNewDb stringByAppendingPathComponent:@"other.log"]] &&
            [fm fileExistsAtPath:[invalNewDb stringByAppendingPathComponent:@"state.bin"]], @"预检后新增文件不混入旧候选：预检文件照常删除，新增文件保留待下轮");
        // 枚举顺序调换：创建顺序相反，同一断言。
        NSString *invalNewDbRev=[sweepHome stringByAppendingPathComponent:@"Library/Caches/inval-newdb-rev"];
        require([fm createDirectoryAtPath:invalNewDbRev withIntermediateDirectories:YES attributes:nil error:nil], @"分类失效顺序夹具");
        writeFile([invalNewDbRev stringByAppendingPathComponent:@"other.log"]);
        writeMedia([invalNewDbRev stringByAppendingPathComponent:@"victim.bin"]);
        AxsCacheKeeperSweep *invalDbRev = makeSweep(invalNewDbRev, @{});
        for (NSUInteger pass=0;invalDbRev.checking && !invalDbRev.complete && pass<100;pass++) [invalDbRev advance:1 shouldContinue:^BOOL{return YES;}];
        require(!invalDbRev.checking && invalDbRev.removed==0, @"顺序夹具预检完成、未删除");
        require([@"SQLite format 3\0payload" writeToFile:[invalNewDbRev stringByAppendingPathComponent:@"state.bin"] atomically:YES encoding:NSUTF8StringEncoding error:nil], @"顺序夹具新增数据库");
        for (NSUInteger pass=0;!invalDbRev.complete && pass<100;pass++) [invalDbRev advance:64 shouldContinue:^BOOL{return YES;}];
        require(invalDbRev.complete && invalDbRev.removed==2 && invalDbRev.changedCount==0 &&
            ![fm fileExistsAtPath:[invalNewDbRev stringByAppendingPathComponent:@"victim.bin"]] &&
            ![fm fileExistsAtPath:[invalNewDbRev stringByAppendingPathComponent:@"other.log"]] &&
            [fm fileExistsAtPath:[invalNewDbRev stringByAppendingPathComponent:@"state.bin"]], @"调换创建顺序后预检后新增文件仍不混入旧候选");
        NSString *invalRewrite=[sweepHome stringByAppendingPathComponent:@"Library/Caches/inval-rewrite"];
        require([fm createDirectoryAtPath:invalRewrite withIntermediateDirectories:YES attributes:nil error:nil], @"分类失效改写夹具");
        NSString *rewriteVictim=[invalRewrite stringByAppendingPathComponent:@"victim.bin"];
        writeMedia(rewriteVictim);
        writeFile([invalRewrite stringByAppendingPathComponent:@"other.log"]);
        AxsCacheKeeperSweep *invalRw = makeSweep(invalRewrite, @{});
        for (NSUInteger pass=0;invalRw.checking && !invalRw.complete && pass<100;pass++) [invalRw advance:1 shouldContinue:^BOOL{return YES;}];
        require(!invalRw.checking && invalRw.removed==0, @"改写夹具预检完成、未删除");
        NSFileHandle *rewriteWriter=[NSFileHandle fileHandleForWritingAtPath:rewriteVictim];
        [rewriteWriter writeData:[@"SQLite format 3\0payload" dataUsingEncoding:NSUTF8StringEncoding]];
        [rewriteWriter closeFile];
        for (NSUInteger pass=0;!invalRw.complete && pass<100;pass++) [invalRw advance:64 shouldContinue:^BOOL{return YES;}];
        require(invalRw.complete && invalRw.removed==1 && invalRw.changedCount==1 && invalRw.changedBytes==12 && invalRw.deferredCount==1 && invalRw.deferredBytes==12 &&
            [fm fileExistsAtPath:rewriteVictim] &&
            ![fm fileExistsAtPath:[invalRewrite stringByAppendingPathComponent:@"other.log"]], @"原地改写只跳过自身：改写文件保留，稳定文件删除；延期类 1 项 · 12 字节（预检快照大小）");
        NSString *invalPrefs=[sweepHome stringByAppendingPathComponent:@"Library/Caches/inval-prefs"];
        require([fm createDirectoryAtPath:invalPrefs withIntermediateDirectories:YES attributes:nil error:nil], @"分类失效受保护子树夹具");
        writeFile([invalPrefs stringByAppendingPathComponent:@"plain.txt"]);
        AxsCacheKeeperSweep *invalPf = makeSweep(invalPrefs, @{});
        for (NSUInteger pass=0;invalPf.checking && !invalPf.complete && pass<100;pass++) [invalPf advance:1 shouldContinue:^BOOL{return YES;}];
        require(!invalPf.checking && invalPf.removed==0, @"受保护子树夹具预检完成、未删除");
        require([fm createDirectoryAtPath:[invalPrefs stringByAppendingPathComponent:@"Preferences"] withIntermediateDirectories:YES attributes:nil error:nil], @"预检后新增 Preferences 子树");
        writeFile([invalPrefs stringByAppendingPathComponent:@"Preferences/a.txt"]);
        for (NSUInteger pass=0;!invalPf.complete && pass<100;pass++) [invalPf advance:64 shouldContinue:^BOOL{return YES;}];
        require(invalPf.complete && invalPf.removed==1 &&
            ![fm fileExistsAtPath:[invalPrefs stringByAppendingPathComponent:@"plain.txt"]] &&
            [fm fileExistsAtPath:[invalPrefs stringByAppendingPathComponent:@"Preferences/a.txt"]], @"预检后新增保留子树不影响已预检文件，子树内容保留待下轮");
        // 近期文件的数据证据不受年龄过滤：近期带数据库头的日志在预检即判未确认
        //（计未确认、不计近期），而不是先当候选、删除时才按年龄跳过。
        NSString *invalRecent=[fixture stringByAppendingPathComponent:@"inval-recent"];
        require([fm createDirectoryAtPath:invalRecent withIntermediateDirectories:YES attributes:nil error:nil], @"分类失效近期证据夹具");
        writeFile([invalRecent stringByAppendingPathComponent:@"stable.log"]);
        NSString *recentDb=[invalRecent stringByAppendingPathComponent:@"fresh.log"];
        require([@"SQLite format 3\0payload" writeToFile:recentDb atomically:YES encoding:NSUTF8StringEncoding error:nil], @"近期数据库头日志");
        require([fm setAttributes:@{NSFileModificationDate:[NSDate dateWithTimeIntervalSince1970:future-30]} ofItemAtPath:recentDb error:nil], @"近期证据改时间戳");
        AxsCacheKeeperSweep *invalRc = makeFlatSweep(invalRecent, @{@"logPaths": @[@"inval-recent"]});
        for (NSUInteger pass=0;!invalRc.complete && pass<100;pass++) [invalRc advance:64 shouldContinue:^BOOL{return YES;}];
        require(invalRc.complete && invalRc.removed==1 && invalRc.unresolvedCount==1 && invalRc.recentCount==0 &&
            ![fm fileExistsAtPath:[invalRecent stringByAppendingPathComponent:@"stable.log"]] &&
            [fm fileExistsAtPath:recentDb], @"近期文件的数据证据不受年龄过滤：预检即判未确认");
        // 硬链接的数据证据不受 nlink 过滤：硬链接数据库头日志在预检即判未确认
        //（计未确认、不计保护），而不是先当候选、删除时才按 nlink 跳过。
        NSString *invalHardlink=[fixture stringByAppendingPathComponent:@"inval-hardlink"];
        require([fm createDirectoryAtPath:invalHardlink withIntermediateDirectories:YES attributes:nil error:nil], @"分类失效硬链接夹具");
        writeFile([invalHardlink stringByAppendingPathComponent:@"stable.log"]);
        NSString *hardlinkSource=[fixture stringByAppendingPathComponent:@"inval-hardlink-source.bin"];
        require([@"SQLite format 3\0payload" writeToFile:hardlinkSource atomically:YES encoding:NSUTF8StringEncoding error:nil], @"硬链接源文件");
        require(!link(hardlinkSource.fileSystemRepresentation,[invalHardlink stringByAppendingPathComponent:@"linked.log"].fileSystemRepresentation), @"预检前建立硬链接数据库头日志");
        AxsCacheKeeperSweep *invalHl = makeFlatSweep(invalHardlink, @{@"logPaths": @[@"inval-hardlink"]});
        for (NSUInteger pass=0;!invalHl.complete && pass<100;pass++) [invalHl advance:64 shouldContinue:^BOOL{return YES;}];
        require(invalHl.complete && invalHl.removed==1 && invalHl.unresolvedCount==1 && invalHl.protectedCount==0 &&
            ![fm fileExistsAtPath:[invalHardlink stringByAppendingPathComponent:@"stable.log"]] &&
            [fm fileExistsAtPath:[invalHardlink stringByAppendingPathComponent:@"linked.log"]], @"硬链接的数据证据不受 nlink 过滤：预检即判未确认");
        NSString *invalMissing=[sweepHome stringByAppendingPathComponent:@"Library/Caches/inval-missing"];
        require([fm createDirectoryAtPath:invalMissing withIntermediateDirectories:YES attributes:nil error:nil], @"分类失效缺失夹具");
        writeMedia([invalMissing stringByAppendingPathComponent:@"a.bin"]);
        writeFile([invalMissing stringByAppendingPathComponent:@"b.bin"]);
        AxsCacheKeeperSweep *invalMs = makeSweep(invalMissing, @{});
        for (NSUInteger pass=0;invalMs.checking && !invalMs.complete && pass<100;pass++) [invalMs advance:1 shouldContinue:^BOOL{return YES;}];
        require(!invalMs.checking && invalMs.removed==0, @"缺失夹具预检完成、未删除");
        require([fm removeItemAtPath:[invalMissing stringByAppendingPathComponent:@"b.bin"] error:nil], @"预检后删除快照文件");
        for (NSUInteger pass=0;!invalMs.complete && pass<100;pass++) [invalMs advance:64 shouldContinue:^BOOL{return YES;}];
        require(invalMs.complete && invalMs.removed==1 && invalMs.changedCount>0 &&
            ![fm fileExistsAtPath:[invalMissing stringByAppendingPathComponent:@"a.bin"]], @"预检后条目缺失计变化，其余文件照常删除");
        NSString *invalUnreadable=[sweepHome stringByAppendingPathComponent:@"Library/Caches/inval-unreadable"];
        require([fm createDirectoryAtPath:invalUnreadable withIntermediateDirectories:YES attributes:nil error:nil], @"分类失效读失败夹具");
        writeMedia([invalUnreadable stringByAppendingPathComponent:@"stable.bin"]);
        AxsCacheKeeperSweep *invalUr = makeSweep(invalUnreadable, @{});
        for (NSUInteger pass=0;invalUr.checking && !invalUr.complete && pass<100;pass++) [invalUr advance:1 shouldContinue:^BOOL{return YES;}];
        require(!invalUr.checking && invalUr.removed==0, @"读失败夹具预检完成、未删除");
        NSString *unreadableNew=[invalUnreadable stringByAppendingPathComponent:@"secret2.bin"];
        require([@"SQLite format 3\0payload" writeToFile:unreadableNew atomically:YES encoding:NSUTF8StringEncoding error:nil], @"预检后新增不可读文件");
        require(!chmod(unreadableNew.fileSystemRepresentation, 0000), @"不可读文件改权限");
        for (NSUInteger pass=0;!invalUr.complete && pass<100;pass++) [invalUr advance:64 shouldContinue:^BOOL{return YES;}];
        chmod(unreadableNew.fileSystemRepresentation, 0644);
        require(invalUr.complete && invalUr.removed==1 && invalUr.failed==0 &&
            ![fm fileExistsAtPath:[invalUnreadable stringByAppendingPathComponent:@"stable.bin"]] &&
            [fm fileExistsAtPath:unreadableNew], @"预检后新增不可读文件不混入旧候选，预检文件照常删除");
        // 自身删除不误判：无外部变化时分批删除全部文件，变化与失败均为 0。
        NSString *invalOwn=[sweepHome stringByAppendingPathComponent:@"Library/Caches/inval-own"];
        require([fm createDirectoryAtPath:invalOwn withIntermediateDirectories:YES attributes:nil error:nil], @"自身删除不误判夹具");
        writeMedia([invalOwn stringByAppendingPathComponent:@"a.bin"]);
        writeFile([invalOwn stringByAppendingPathComponent:@"b.bin"]);
        AxsCacheKeeperSweep *invalOw = makeSweep(invalOwn, @{});
        for (NSUInteger pass=0;!invalOw.complete && pass<100;pass++) [invalOw advance:64 shouldContinue:^BOOL{return YES;}];
        require(invalOw.complete && invalOw.removed==2 && invalOw.changedCount==0 && invalOw.failed==0 &&
            ![fm fileExistsAtPath:[invalOwn stringByAppendingPathComponent:@"a.bin"]] &&
            ![fm fileExistsAtPath:[invalOwn stringByAppendingPathComponent:@"b.bin"]], @"无外部变化时自身删除不误判，全部删除");
        // 平台缓存不做跨文件保护：同一根内数据库不连坐同目录媒体，分批预检未完成前不得删除。
        NSString *lateDir=[sweepHome stringByAppendingPathComponent:@"Library/Caches/late-database"];
        require([fm createDirectoryAtPath:lateDir withIntermediateDirectories:YES attributes:nil error:nil], @"延迟发现数据库夹具");
        writeMedia([lateDir stringByAppendingPathComponent:@"a.png"]);
        writeFile([lateDir stringByAppendingPathComponent:@"z.sqlite"]);
        AxsCacheKeeperSweep *late = makeSweep(lateDir, @{});
        [late advance:1 shouldContinue:^BOOL{return YES;}];
        require(late.removed==0, @"分批预检未完成之前不得删除同目录文件");
        for (NSUInteger pass=0;!late.complete && pass<30;pass++) [late advance:1 shouldContinue:^BOOL{return YES;}];
        require(late.complete && late.removed==2 && ![fm fileExistsAtPath:[lateDir stringByAppendingPathComponent:@"a.png"]] &&
            ![fm fileExistsAtPath:[lateDir stringByAppendingPathComponent:@"z.sqlite"]], @"平台缓存内数据库不连坐同目录媒体，全部删除");
        NSString *changedDir=[sweepHome stringByAppendingPathComponent:@"Library/Caches/changed"];
        require([fm createDirectoryAtPath:changedDir withIntermediateDirectories:YES attributes:nil error:nil], @"变化目录夹具");
        writeMedia([changedDir stringByAppendingPathComponent:@"image.png"]);
        AxsCacheKeeperSweep *changed = makeSweep(changedDir, @{});
        for (NSUInteger pass=0;changed.checking && !changed.complete && pass<20;pass++) [changed advance:1 shouldContinue:^BOOL{return YES;}];
        require(!changed.checking && changed.removed==0, @"预检阶段与删除阶段明确分开");
        writeFile([changedDir stringByAppendingPathComponent:@"new.sqlite"]);
        for (NSUInteger pass=0;!changed.complete && pass<20;pass++) [changed advance:1 shouldContinue:^BOOL{return YES;}];
        require(changed.complete && changed.removed==1 && changed.changedCount==0 && ![fm fileExistsAtPath:[changedDir stringByAppendingPathComponent:@"image.png"]] &&
            [fm fileExistsAtPath:[changedDir stringByAppendingPathComponent:@"new.sqlite"]], @"预检后加入文件不混入旧候选：已预检文件删除，新增文件保留");
        NSString *inplaceDir=[sweepHome stringByAppendingPathComponent:@"Library/Caches/inplace"];
        require([fm createDirectoryAtPath:inplaceDir withIntermediateDirectories:YES attributes:nil error:nil], @"原地变化夹具");
        writeMedia([inplaceDir stringByAppendingPathComponent:@"image.png"]);
        NSString *opaque=[inplaceDir stringByAppendingPathComponent:@"opaque"];
        writeFile(opaque);
        AxsCacheKeeperSweep *inplace = makeSweep(inplaceDir, @{});
        for (NSUInteger pass=0;inplace.checking && !inplace.complete && pass<20;pass++) [inplace advance:1 shouldContinue:^BOOL{return YES;}];
        NSFileHandle *writer=[NSFileHandle fileHandleForWritingAtPath:opaque];
        [writer writeData:[@"SQLite format 3\0payload" dataUsingEncoding:NSUTF8StringEncoding]];[writer closeFile];
        for (NSUInteger pass=0;!inplace.complete && pass<20;pass++) [inplace advance:1 shouldContinue:^BOOL{return YES;}];
        require(inplace.complete && inplace.removed==1 && inplace.changedCount>0 && ![fm fileExistsAtPath:[inplaceDir stringByAppendingPathComponent:@"image.png"]] &&
            [fm fileExistsAtPath:opaque], @"原地改写只跳过自身：改写文件保留，稳定媒体删除");
        // 取消：预检与删除分开推进——预检用 shouldContinue=YES 完成，删除阶段门控关闭即取消。
        NSString *pending = [cache stringByAppendingPathComponent:@"pending"];
        writeFile(pending);
        AxsCacheKeeperSweep *cancelled = [[AxsCacheKeeperSweep alloc] initWithRoot:cache bundle:bundle version:@"1.0" containerPath:sweepHome state:@{}];
        for (NSUInteger pass=0;cancelled.checking && !cancelled.complete && pass<20;pass++) [cancelled advancePreflight:10];
        require(!cancelled.checking && !cancelled.complete && cancelled.removed==0, @"取消测试基线：预检完成、未删除");
        [cancelled advanceDeletion:10 shouldContinue:^BOOL { return NO; }];
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

        // 枚举路径边界回归（0.7.2 真机 errno 22 全灭，49.1 验收截图 2026-11-12）：
        // 反斜杠在 POSIX 文件名中是普通字符，枚举路径已由前缀核对限定在根内，
        // 不应被通用相对路径检查误判越界；目录别名须含解析形态；单条越界只跳过该条。
        NSString *aliasTarget = [fixture stringByAppendingPathComponent:@"alias-target"];
        require([fm createDirectoryAtPath:aliasTarget withIntermediateDirectories:YES attributes:nil error:nil], @"别名夹具");
        NSString *aliasLink = [fixture stringByAppendingPathComponent:@"alias-link"];
        require(!symlink(aliasTarget.fileSystemRepresentation, aliasLink.fileSystemRepresentation), @"建立别名链接");
        NSArray *linkAliases = axs_cachekeeper_directory_aliases(aliasLink);
        require([linkAliases containsObject:aliasTarget], @"目录别名含解析后的真实路径");
        NSString *viaLink = axs_cachekeeper_enumerated_path([aliasTarget stringByAppendingPathComponent:@"x.txt"], aliasLink, linkAliases);
        require([viaLink isEqual:[aliasLink stringByAppendingPathComponent:@"x.txt"]], @"枚举路径经解析别名还原为根形态");
        // 反方向：枚举路径走未解析形态（经链接），根为解析后形态；字符串前缀全未命中，
        // 必须靠两侧解析兜底（51.1 真机：抖音单轮失败 9215 项、零删除，证实此方向真实存在）。
        writeFile([aliasTarget stringByAppendingPathComponent:@"y.txt"]);
        NSArray *targetAliases = axs_cachekeeper_directory_aliases(aliasTarget);
        NSString *viaUnresolved = axs_cachekeeper_enumerated_path([aliasLink stringByAppendingPathComponent:@"y.txt"], aliasTarget, targetAliases);
        require([viaUnresolved isEqual:[aliasTarget stringByAppendingPathComponent:@"y.txt"]], @"枚举路径经解析兜底还原为根形态");
        require(!axs_cachekeeper_enumerated_path(@"/etc/passwd", aliasLink, linkAliases), @"根外路径仍被边界核对拒绝");
        NSString *backslashRoot = [sweepHome stringByAppendingPathComponent:@"Library/Caches/backslash"];
        require([fm createDirectoryAtPath:backslashRoot withIntermediateDirectories:YES attributes:nil error:nil], @"反斜杠夹具");
        NSString *backslashFile = [backslashRoot stringByAppendingPathComponent:@"a\\b.txt"];
        writeFile(backslashFile);
        NSString *plainFile = [backslashRoot stringByAppendingPathComponent:@"plain.txt"];
        writeFile(plainFile);
        AxsCacheKeeperSweep *backslashSweep = makeSweep(backslashRoot, @{});
        for (NSUInteger pass=0;!backslashSweep.complete && pass<100;pass++) [backslashSweep advance:64 shouldContinue:^BOOL{return YES;}];
        require(backslashSweep.complete && backslashSweep.failed == 0 && backslashSweep.removed == 2 &&
            ![fm fileExistsAtPath:backslashFile] && ![fm fileExistsAtPath:plainFile],
            [NSString stringWithFormat:@"反斜杠文件名不终结整根清理（complete=%d removed=%lu failed=%lu）",backslashSweep.complete,(unsigned long)backslashSweep.removed,(unsigned long)backslashSweep.failed]);

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
        NSString *twinRoot=[fixture stringByAppendingPathComponent:@"twin-inspect"];
        NSString *twinOther=[fixture stringByAppendingPathComponent:@"twin-other"];
        require([fm createDirectoryAtPath:twinRoot withIntermediateDirectories:YES attributes:nil error:nil] &&
            [fm createDirectoryAtPath:twinOther withIntermediateDirectories:YES attributes:nil error:nil], @"孪生定位夹具目录");
        NSString *twinFile=[twinRoot stringByAppendingPathComponent:@"shared.bin"];
        writeMedia(twinFile);
        require(!link(twinFile.fileSystemRepresentation, [[twinOther stringByAppendingPathComponent:@"copy.bin"] fileSystemRepresentation]), @"建立跨目录硬链接夹具");
        NSString *innerFile=[twinRoot stringByAppendingPathComponent:@"inner.bin"];
        writeMedia(innerFile);
        require(!link(innerFile.fileSystemRepresentation, [[twinRoot stringByAppendingPathComponent:@"inner-copy.bin"] fileSystemRepresentation]), @"建立同目录硬链接夹具");
        require(!symlink(twinFile.fileSystemRepresentation, [[twinRoot stringByAppendingPathComponent:@"alias"] fileSystemRepresentation]), @"建立符号链接对照夹具");
        AxsCacheKeeperInspection *twinInspection=[[AxsCacheKeeperInspection alloc] initWithRoot:twinRoot searchRoots:@[@{@"path":twinRoot,@"label":@"本目录"},@{@"path":twinOther,@"label":@"别处"}]];
        for (NSUInteger pass=0;!twinInspection.complete && pass<100;pass++) [twinInspection advance:32];
        NSDictionary *twinProfile=[twinInspection report];
        require(twinInspection.complete && [twinProfile[@"hardLinks"] unsignedIntegerValue]==3 && [twinProfile[@"symlinks"] unsignedIntegerValue]==1 && [twinProfile[@"links"] unsignedIntegerValue]==4, @"硬链接与符号链接分别计数");
        require([twinProfile[@"linkTwins"] count]==3, @"跨目录与同目录孪生全部找到");
        NSUInteger crossTwins=0,innerTwins=0;
        for (NSDictionary *twin in twinProfile[@"linkTwins"]) {
            if ([twin[@"twin"] containsString:@"别处/copy.bin"]) crossTwins++;
            if ([twin[@"twin"] containsString:@"本目录/"]) innerTwins++;
        }
        require(crossTwins==1 && innerTwins==2, @"孪生位置按搜索根标注");
        // 任务 7：关联字节按 (设备, inode) 去重——inner.bin 与 inner-copy.bin 是同一份数据，
        // 只计一次：2 个 inode × 12 字节 = 24（旧按源路径计为 3 × 12 = 36）。
        require([twinProfile[@"twinBytes"] unsignedLongLongValue]==24, @"孪生涉及字节按 (设备, inode) 去重");
        require([twinProfile[@"twinCoverageComplete"] boolValue] && [twinProfile[@"twinFailures"] unsignedIntegerValue]==0 &&
            ![twinProfile[@"linkFilesTruncated"] boolValue] && ![twinProfile[@"twinScanTruncated"] boolValue] &&
            ![twinProfile[@"twinDisplayTruncated"] boolValue], @"孪生搜索覆盖完整且无失败、无截断");
        // 任务 7：三链接部分找到——第三个链接所在的目录不在搜索根内，只找到已覆盖的孪生。
        NSString *partialRoot=[fixture stringByAppendingPathComponent:@"twin-partial"];
        NSString *partialSeen=[fixture stringByAppendingPathComponent:@"twin-partial-seen"];
        NSString *partialHidden=[fixture stringByAppendingPathComponent:@"twin-partial-hidden"];
        require([fm createDirectoryAtPath:partialRoot withIntermediateDirectories:YES attributes:nil error:nil] &&
            [fm createDirectoryAtPath:partialSeen withIntermediateDirectories:YES attributes:nil error:nil] &&
            [fm createDirectoryAtPath:partialHidden withIntermediateDirectories:YES attributes:nil error:nil], @"三链接部分夹具");
        NSString *partialFile=[partialRoot stringByAppendingPathComponent:@"triple.bin"];
        writeMedia(partialFile);
        require(!link(partialFile.fileSystemRepresentation, [[partialSeen stringByAppendingPathComponent:@"seen.bin"] fileSystemRepresentation]) &&
            !link(partialFile.fileSystemRepresentation, [[partialHidden stringByAppendingPathComponent:@"hidden.bin"] fileSystemRepresentation]), @"建立三链接夹具");
        AxsCacheKeeperInspection *partialInspection=[[AxsCacheKeeperInspection alloc] initWithRoot:partialRoot searchRoots:@[@{@"path":partialRoot,@"label":@"本目录"},@{@"path":partialSeen,@"label":@"已覆盖"}]];
        for (NSUInteger pass=0;!partialInspection.complete && pass<100;pass++) [partialInspection advance:32];
        NSDictionary *partialProfile=[partialInspection report];
        require(partialInspection.complete && [partialProfile[@"linkTwins"] count]==1 &&
            [partialProfile[@"linkTwins"][0][@"twin"] containsString:@"已覆盖/seen.bin"] &&
            [partialProfile[@"twinCoverageComplete"] boolValue], @"三链接只找到搜索根覆盖的一处，未覆盖的目录不产生孪生");
        // 任务 7：搜索根不可读——不存在的搜索根计入孪生失败，覆盖标记为不完整。
        AxsCacheKeeperInspection *badRootInspection=[[AxsCacheKeeperInspection alloc] initWithRoot:twinRoot searchRoots:@[@{@"path":twinRoot,@"label":@"本目录"},@{@"path":[fixture stringByAppendingPathComponent:@"twin-missing"],@"label":@"缺失"}]];
        for (NSUInteger pass=0;!badRootInspection.complete && pass<100;pass++) [badRootInspection advance:32];
        NSDictionary *badRootProfile=[badRootInspection report];
        require(badRootInspection.complete && [badRootProfile[@"twinFailures"] unsignedIntegerValue]==1 &&
            ![badRootProfile[@"twinCoverageComplete"] boolValue] && [badRootProfile[@"linkTwins"] count]==2, @"不可读搜索根计入孪生失败且覆盖不完整，已覆盖的孪生仍找到");
        // 任务 7：展示截断（每源 3 条）——同一源有 4 个孪生时只记 3 条并标记截断。
        NSString *twinCapRoot=[fixture stringByAppendingPathComponent:@"twin-cap"];
        require([fm createDirectoryAtPath:twinCapRoot withIntermediateDirectories:YES attributes:nil error:nil], @"展示截断夹具");
        NSString *capFile=[twinCapRoot stringByAppendingPathComponent:@"many.bin"];
        writeMedia(capFile);
        NSMutableArray *twinCapRoots=[NSMutableArray arrayWithObject:@{@"path":twinCapRoot,@"label":@"本目录"}];
        for (NSUInteger i=0;i<4;i++) {
            NSString *capOther=[fixture stringByAppendingPathComponent:[NSString stringWithFormat:@"twin-cap-%lu",(unsigned long)i]];
            require([fm createDirectoryAtPath:capOther withIntermediateDirectories:YES attributes:nil error:nil], @"展示截断搜索根夹具");
            require(!link(capFile.fileSystemRepresentation, [[capOther stringByAppendingPathComponent:@"copy.bin"] fileSystemRepresentation]), @"建立多链接夹具");
            [twinCapRoots addObject:@{@"path":capOther,@"label":[NSString stringWithFormat:@"别处%lu",(unsigned long)i]}];
        }
        AxsCacheKeeperInspection *capInspection=[[AxsCacheKeeperInspection alloc] initWithRoot:twinCapRoot searchRoots:twinCapRoots];
        for (NSUInteger pass=0;!capInspection.complete && pass<100;pass++) [capInspection advance:32];
        NSDictionary *capProfile=[capInspection report];
        require(capInspection.complete && [capProfile[@"linkTwins"] count]==3 && [capProfile[@"twinDisplayTruncated"] boolValue] &&
            ![capProfile[@"twinCoverageComplete"] boolValue] && [capProfile[@"twinBytes"] unsignedLongLongValue]==12, @"每源 3 条展示截断并标记，关联字节仍按单 inode 计");
        // 任务 7：展示截断（总 50 条）——20 个源各 3 个孪生时只记 50 条并标记截断，源收集未截断。
        NSString *totalRoot=[fixture stringByAppendingPathComponent:@"twin-total"];
        NSString *totalOther=[fixture stringByAppendingPathComponent:@"twin-total-other"];
        require([fm createDirectoryAtPath:totalRoot withIntermediateDirectories:YES attributes:nil error:nil] &&
            [fm createDirectoryAtPath:totalOther withIntermediateDirectories:YES attributes:nil error:nil], @"总展示截断夹具");
        for (NSUInteger i=0;i<20;i++) {
            NSString *totalFile=[totalRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"f%lu.bin",(unsigned long)i]];
            writeMedia(totalFile);
            for (NSUInteger j=0;j<3;j++)
                require(!link(totalFile.fileSystemRepresentation, [[totalOther stringByAppendingPathComponent:[NSString stringWithFormat:@"f%lu-%lu.bin",(unsigned long)i,(unsigned long)j]] fileSystemRepresentation]), @"建立多源多链接夹具");
        }
        AxsCacheKeeperInspection *totalInspection=[[AxsCacheKeeperInspection alloc] initWithRoot:totalRoot searchRoots:@[@{@"path":totalRoot,@"label":@"本目录"},@{@"path":totalOther,@"label":@"别处"}]];
        for (NSUInteger pass=0;!totalInspection.complete && pass<200;pass++) [totalInspection advance:32];
        NSDictionary *totalProfile=[totalInspection report];
        require(totalInspection.complete && [totalProfile[@"linkTwins"] count]==50 && [totalProfile[@"twinDisplayTruncated"] boolValue] &&
            ![totalProfile[@"linkFilesTruncated"] boolValue] && ![totalProfile[@"twinCoverageComplete"] boolValue], @"总 50 条展示截断并标记，源收集未截断");
        // 任务 7：源收集截断——101 个硬链接源文件只记前 100，标记截断。
        NSString *sourceRoot=[fixture stringByAppendingPathComponent:@"twin-source"];
        NSString *sourceOther=[fixture stringByAppendingPathComponent:@"twin-source-other"];
        require([fm createDirectoryAtPath:sourceRoot withIntermediateDirectories:YES attributes:nil error:nil] &&
            [fm createDirectoryAtPath:sourceOther withIntermediateDirectories:YES attributes:nil error:nil], @"源收集截断夹具");
        for (NSUInteger i=0;i<101;i++) {
            NSString *sourceFile=[sourceRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"s%lu.bin",(unsigned long)i]];
            writeMedia(sourceFile);
            require(!link(sourceFile.fileSystemRepresentation, [[sourceOther stringByAppendingPathComponent:[NSString stringWithFormat:@"s%lu.bin",(unsigned long)i]] fileSystemRepresentation]), @"建立多源夹具");
        }
        AxsCacheKeeperInspection *sourceInspection=[[AxsCacheKeeperInspection alloc] initWithRoot:sourceRoot searchRoots:@[@{@"path":sourceRoot,@"label":@"本目录"},@{@"path":sourceOther,@"label":@"别处"}]];
        for (NSUInteger pass=0;!sourceInspection.complete && pass<200;pass++) [sourceInspection advance:32];
        NSDictionary *sourceProfile=[sourceInspection report];
        require(sourceInspection.complete && [sourceProfile[@"hardLinks"] unsignedIntegerValue]==101 &&
            [sourceProfile[@"linkFilesTruncated"] boolValue] && ![sourceProfile[@"twinCoverageComplete"] boolValue], @"硬链接源文件超 100 截断并标记");
        // 注：搜索截断（扫描超 10 万项）与孪生搜索的 lstat 竞态失败无法在原生测试里确定性触发，
        // 前者需 10 万个文件，后者需枚举与删除的时序竞态；两者与已测路径共用同一计数/标记机制。
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
        // 方案任务 4（P2-1）：Receipts 回执模块——roundID 幂等核算、写失败滞留与恢复、
        // 损坏回执不覆盖、展示更新不改累计。Status 目录指向临时夹具子目录。
        require(job.roundID.length > 0 && jobEF.roundID.length > 0 && ![job.roundID isEqual:jobEF.roundID], @"作业 roundID 唯一且非空");
        NSString *receiptsFolder = [fixture stringByAppendingPathComponent:@"receipts-status"];
        require([fm createDirectoryAtPath:receiptsFolder withIntermediateDirectories:YES attributes:nil error:nil], @"回执夹具目录");
        [AxsCacheKeeperReceipts resetForTesting];
        [AxsCacheKeeperReceipts configureWithStatusFolder:receiptsFolder];
        NSString *receiptBundle = @"test.receipts.app";
        NSString *receiptPath = [[receiptsFolder stringByAppendingPathComponent:receiptBundle] stringByAppendingString:@".auto.plist"];
        // 1. 同轮累计与幂等：r1 100→150，重复提交 150 不重复计入。
        require([AxsCacheKeeperReceipts submitRoundForBundle:receiptBundle roundID:@"r1" removed:100 bytes:1000 endReason:1 phase:@"cleaning" message:@"m1" failed:0 effectivePaths:@[@"Library/Caches"] discoveredPaths:nil directories:nil round:nil coverageComplete:YES], @"回执首轮提交");
        NSDictionary *receipt = [NSDictionary dictionaryWithContentsOfFile:receiptPath];
        require([receipt[@"removed"] unsignedIntegerValue]==100 && [receipt[@"bytes"] unsignedLongLongValue]==1000 && [receipt[@"confirmedRoundID"] isEqual:@"r1"] && [receipt[@"confirmedRemoved"] unsignedIntegerValue]==100 && [receipt[@"coverageComplete"] boolValue], @"首轮累计与已确认轮次，覆盖完整标记落盘");
        require([AxsCacheKeeperReceipts submitRoundForBundle:receiptBundle roundID:@"r1" removed:150 bytes:1500 endReason:1 phase:@"cleaning" message:@"m2" failed:0 effectivePaths:@[@"Library/Caches"] discoveredPaths:nil directories:nil round:nil coverageComplete:YES], @"回执同轮追加提交");
        receipt = [NSDictionary dictionaryWithContentsOfFile:receiptPath];
        require([receipt[@"removed"] unsignedIntegerValue]==150 && [receipt[@"bytes"] unsignedLongLongValue]==1500 && [receipt[@"confirmedRemoved"] unsignedIntegerValue]==150, @"同轮只计差额");
        require([AxsCacheKeeperReceipts submitRoundForBundle:receiptBundle roundID:@"r1" removed:150 bytes:1500 endReason:1 phase:@"cleaning" message:@"m2" failed:0 effectivePaths:@[@"Library/Caches"] discoveredPaths:nil directories:nil round:nil coverageComplete:YES], @"回执重复提交返回成功");
        receipt = [NSDictionary dictionaryWithContentsOfFile:receiptPath];
        require([receipt[@"removed"] unsignedIntegerValue]==150, @"重复提交不重复计入");
        // 2. 新轮次计全量：r2 50 → 累计 200，退役记上次清理。
        require([AxsCacheKeeperReceipts submitRoundForBundle:receiptBundle roundID:@"r2" removed:50 bytes:500 endReason:1 phase:@"complete" message:@"m3" failed:0 effectivePaths:@[@"Library/Caches"] discoveredPaths:nil directories:nil round:@{@"removed":@50, @"bytes":@500} coverageComplete:YES], @"回执新轮提交");
        receipt = [NSDictionary dictionaryWithContentsOfFile:receiptPath];
        require([receipt[@"removed"] unsignedIntegerValue]==200 && [receipt[@"confirmedRoundID"] isEqual:@"r2"] && [receipt[@"lastRemoved"] unsignedIntegerValue]==50 && [receipt[@"lastBytes"] unsignedLongLongValue]==500, @"新轮计全量且退役记上次清理");
        // 3. 非退役提交不改上次清理：r2 追加到 60，累计 210，上次清理仍为 50。
        require([AxsCacheKeeperReceipts submitRoundForBundle:receiptBundle roundID:@"r2" removed:60 bytes:600 endReason:0 phase:@"cleaning" message:@"m4" failed:0 effectivePaths:@[@"Library/Caches"] discoveredPaths:nil directories:nil round:nil coverageComplete:YES], @"回执中途提交");
        receipt = [NSDictionary dictionaryWithContentsOfFile:receiptPath];
        require([receipt[@"removed"] unsignedIntegerValue]==210 && [receipt[@"lastRemoved"] unsignedIntegerValue]==50, @"中途提交不改上次清理");
        // 4. 写失败滞留与恢复：指向不存在的目录，提交失败且待处理；作业替换后新轮提交同样滞留；
        // 建目录后落盘，两轮按序补记，累计精确，不丢不重；一 APP 的待处理不影响其他 APP。
        NSString *missingFolder = [fixture stringByAppendingPathComponent:@"receipts-missing"];
        NSString *failBundle = @"test.receipts.fail";
        [AxsCacheKeeperReceipts resetForTesting];
        [AxsCacheKeeperReceipts configureWithStatusFolder:missingFolder];
        require(![AxsCacheKeeperReceipts submitRoundForBundle:failBundle roundID:@"f1" removed:70 bytes:700 endReason:1 phase:@"complete" message:@"f1" failed:0 effectivePaths:@[] discoveredPaths:nil directories:nil round:@{@"removed":@70, @"bytes":@700} coverageComplete:NO] && [AxsCacheKeeperReceipts hasPendingForBundle:failBundle], @"写失败返回 NO 且待处理");
        require(![AxsCacheKeeperReceipts submitRoundForBundle:failBundle roundID:@"f2" removed:30 bytes:300 endReason:1 phase:@"complete" message:@"f2" failed:0 effectivePaths:@[] discoveredPaths:nil directories:nil round:@{@"removed":@30, @"bytes":@300} coverageComplete:NO] && [AxsCacheKeeperReceipts hasPendingForBundle:failBundle], @"作业替换后新轮提交同样滞留");
        require(![AxsCacheKeeperReceipts hasPendingForBundle:receiptBundle], @"一 APP 的待处理不影响其他 APP");
        require([fm createDirectoryAtPath:missingFolder withIntermediateDirectories:YES attributes:nil error:nil], @"恢复写目录");
        require([AxsCacheKeeperReceipts flushPendingForBundle:failBundle] && ![AxsCacheKeeperReceipts hasPendingForBundle:failBundle], @"恢复后落盘成功");
        NSDictionary *failReceipt = [NSDictionary dictionaryWithContentsOfFile:[[missingFolder stringByAppendingPathComponent:failBundle] stringByAppendingString:@".auto.plist"]];
        require([failReceipt[@"removed"] unsignedIntegerValue]==100 && [failReceipt[@"bytes"] unsignedLongLongValue]==1000 && [failReceipt[@"confirmedRoundID"] isEqual:@"f2"] && [failReceipt[@"lastRemoved"] unsignedIntegerValue]==30 && ![failReceipt[@"coverageComplete"] boolValue], @"两轮按序补记，累计精确 100，上次清理为后一轮，覆盖不完整如实落盘");
        // 5. 同轮失败后重复提交只计一次：c1 100 失败、c1 150 失败，恢复后落盘计 150。
        NSString *missingFolder2 = [fixture stringByAppendingPathComponent:@"receipts-missing2"];
        NSString *coalesceBundle = @"test.receipts.coalesce";
        [AxsCacheKeeperReceipts resetForTesting];
        [AxsCacheKeeperReceipts configureWithStatusFolder:missingFolder2];
        require(![AxsCacheKeeperReceipts submitRoundForBundle:coalesceBundle roundID:@"c1" removed:100 bytes:1000 endReason:0 phase:@"cleaning" message:@"c1" failed:0 effectivePaths:@[] discoveredPaths:nil directories:nil round:nil coverageComplete:YES], @"同轮首次提交失败滞留");
        require(![AxsCacheKeeperReceipts submitRoundForBundle:coalesceBundle roundID:@"c1" removed:150 bytes:1500 endReason:0 phase:@"cleaning" message:@"c2" failed:0 effectivePaths:@[] discoveredPaths:nil directories:nil round:nil coverageComplete:YES], @"同轮追加提交失败滞留");
        require([fm createDirectoryAtPath:missingFolder2 withIntermediateDirectories:YES attributes:nil error:nil], @"恢复写目录二");
        require([AxsCacheKeeperReceipts flushPendingForBundle:coalesceBundle], @"同轮滞留落盘成功");
        NSDictionary *coalesceReceipt = [NSDictionary dictionaryWithContentsOfFile:[[missingFolder2 stringByAppendingPathComponent:coalesceBundle] stringByAppendingString:@".auto.plist"]];
        require([coalesceReceipt[@"removed"] unsignedIntegerValue]==150, @"同轮失败后重复提交只计最新累计一次");
        // 6. 损坏回执不覆盖：写入非 plist 内容后提交失败、文件原样；删除损坏文件后落盘成功。
        NSString *corruptFolder = [fixture stringByAppendingPathComponent:@"receipts-corrupt"];
        require([fm createDirectoryAtPath:corruptFolder withIntermediateDirectories:YES attributes:nil error:nil], @"损坏回执夹具目录");
        NSString *corruptBundle = @"test.receipts.corrupt";
        NSString *corruptPath = [[corruptFolder stringByAppendingPathComponent:corruptBundle] stringByAppendingString:@".auto.plist"];
        require([@"this is not a plist" writeToFile:corruptPath atomically:YES encoding:NSUTF8StringEncoding error:nil], @"写入损坏回执文件");
        [AxsCacheKeeperReceipts resetForTesting];
        [AxsCacheKeeperReceipts configureWithStatusFolder:corruptFolder];
        require(![AxsCacheKeeperReceipts submitRoundForBundle:corruptBundle roundID:@"x1" removed:10 bytes:100 endReason:1 phase:@"complete" message:@"x1" failed:0 effectivePaths:@[] discoveredPaths:nil directories:nil round:@{@"removed":@10, @"bytes":@100} coverageComplete:YES] && [AxsCacheKeeperReceipts hasPendingForBundle:corruptBundle], @"损坏回执提交失败且待处理");
        require([[NSString stringWithContentsOfFile:corruptPath encoding:NSUTF8StringEncoding error:nil] isEqual:@"this is not a plist"], @"损坏回执文件未被覆盖");
        require(![AxsCacheKeeperReceipts flushPendingForBundle:corruptBundle], @"损坏未修复时落盘仍失败");
        require([fm removeItemAtPath:corruptPath error:nil], @"删除损坏回执文件");
        require([AxsCacheKeeperReceipts flushPendingForBundle:corruptBundle] && ![AxsCacheKeeperReceipts hasPendingForBundle:corruptBundle], @"删除损坏文件后落盘成功");
        NSDictionary *corruptReceipt = [NSDictionary dictionaryWithContentsOfFile:corruptPath];
        require([corruptReceipt[@"removed"] unsignedIntegerValue]==10 && [corruptReceipt[@"confirmedRoundID"] isEqual:@"x1"], @"损坏修复后累计正确");
        // 7. 展示更新不改累计：对已有回执更新状态，累计与已确认轮次原样保留。
        [AxsCacheKeeperReceipts resetForTesting];
        [AxsCacheKeeperReceipts configureWithStatusFolder:receiptsFolder];
        require([AxsCacheKeeperReceipts updateStatusForBundle:receiptBundle phase:@"waiting" message:@"wait" failed:0 effectivePaths:@[@"Library/Caches"] discoveredPaths:nil directories:nil], @"展示更新成功");
        receipt = [NSDictionary dictionaryWithContentsOfFile:receiptPath];
        require([receipt[@"removed"] unsignedIntegerValue]==210 && [receipt[@"confirmedRoundID"] isEqual:@"r2"] && [receipt[@"phase"] isEqual:@"waiting"] && [receipt[@"coverageComplete"] boolValue], @"展示更新不改累计与已确认轮次，覆盖标记原样保留");
        // 8. 覆盖完整性变化打破去重：同轮同累计、展示内容完全相同，仅覆盖标记翻转，仍落盘且累计不重复计入。
        require([AxsCacheKeeperReceipts submitRoundForBundle:receiptBundle roundID:@"r2" removed:60 bytes:600 endReason:0 phase:@"waiting" message:@"wait" failed:0 effectivePaths:@[@"Library/Caches"] discoveredPaths:nil directories:nil round:nil coverageComplete:NO], @"覆盖翻转提交");
        receipt = [NSDictionary dictionaryWithContentsOfFile:receiptPath];
        require([receipt[@"removed"] unsignedIntegerValue]==210 && ![receipt[@"coverageComplete"] boolValue], @"覆盖翻转落盘，累计不重复计入");
        axs_cachekeeper_run_plan_repair_tests(fixture);
        puts("PASS: configuration, modes, deduplication, age, protected files, cleanup, cancellation, permission restoration, receipts and URLCache");
    }
    return 0;
}
