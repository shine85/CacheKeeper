#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#import "../AxsCacheKeeperInstallation.h"
#import "../AxsCacheKeeperSweep.h"
#import "../AxsCacheKeeperCleanupJob.h"
#import "../AxsCacheKeeperDiagnostics.h"

static void aicheck(BOOL ok, NSString *message) {
    if (!ok) { fprintf(stderr,"FAIL: installation: %s\n",message.UTF8String);exit(1); }
}
static void aidetail(NSError *error, NSInteger code, NSString *target, NSString *operation, int number);
static void aiput(NSString *path, NSData *data) {
    aicheck([NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil],@"创建夹具目录");
    aicheck([data writeToFile:path options:NSDataWritingAtomic error:nil],@"写入夹具");
}
static void aiinfo(NSString *root, NSDictionary *changes) {
    NSMutableDictionary *info=[@{@"CFBundleIdentifier":@"test.installation",@"CFBundleVersion":@"100",@"CFBundleShortVersionString":@"1.0",@"CFBundleExecutable":@"Main"} mutableCopy];
    [info addEntriesFromDictionary:changes];
    aiput([root stringByAppendingPathComponent:@"Info.plist"],[NSPropertyListSerialization dataWithPropertyList:info format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil]);
}
static NSString *aibundle(NSString *fixture, NSString *name) {
    NSString *root=[[fixture stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"Fixture.app"];
    aiinfo(root,@{});aiput([root stringByAppendingPathComponent:@"Main"],[@"executable fixture" dataUsingEncoding:NSUTF8StringEncoding]);
    return root;
}

#if defined(AXS_CACHEKEEPER_INSTALLATION_TESTING)
// Only the hard-to-reproduce read result is substituted; each call still receives a real Info FD.
static NSUInteger aiReadFailures,aiReadCalls,aiReadLimit,aiShortReadCalls;
static int aiReadError;
ssize_t axs_cachekeeper_installation_test_read(int fd, void *buffer, size_t length) {
    if (aiReadLimit) { aiShortReadCalls++;return read(fd,buffer,MIN(length,aiReadLimit)); }
    if (!aiReadFailures) return read(fd,buffer,length);
    struct stat attributes;
    aicheck(fstat(fd,&attributes)==0 && S_ISREG(attributes.st_mode) && length>0,@"失败注入必须作用于真实已打开Info文件");
    aiReadFailures--;aiReadCalls++;
    errno=aiReadError ? aiReadError : EACCES;
    return aiReadError ? -1 : 0;
}
#endif

// Only the system application registry is substituted; snapshots, file access and cleanup stay real.
@interface AxsCacheKeeperInstallationTestProxy : NSObject
@property(nonatomic,copy) NSString *applicationIdentifier,*applicationType,*localizedName,*shortVersionString;
@property(nonatomic,strong) NSURL *bundleURL;
@end
@implementation AxsCacheKeeperInstallationTestProxy
@end

@interface AxsCacheKeeperInstallationCoverageTestProxy : AxsCacheKeeperInstallationTestProxy
@property(nonatomic,strong) id dataContainerURL,groupContainerURLs,plugInKitPlugins,containerURL;
@end
@implementation AxsCacheKeeperInstallationCoverageTestProxy
@end
@interface AxsCacheKeeperInstallationCoverageTestOwner : NSObject
@property(nonatomic,copy) NSString *bundleIdentifier;
@end
@implementation AxsCacheKeeperInstallationCoverageTestOwner
@end
@interface AxsCacheKeeperInstallationCoverageTestPlugin : NSObject
@property(nonatomic,strong) id pluginIdentifier,containingBundle,dataContainerURL;
@end
@implementation AxsCacheKeeperInstallationCoverageTestPlugin
@end
@interface AxsCacheKeeperInstallationCoverageScalarTestProxy : AxsCacheKeeperInstallationTestProxy
- (NSUInteger)dataContainerURL;
@end
static NSUInteger aiScalarGetterCalls;
@implementation AxsCacheKeeperInstallationCoverageScalarTestProxy
- (NSUInteger)dataContainerURL {aiScalarGetterCalls++;return 1;}
@end
@interface AxsCacheKeeperInstallationTestWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allInstalledApplications;
@end
static NSArray *aiinstalled;
@implementation AxsCacheKeeperInstallationTestWorkspace
+ (instancetype)defaultWorkspace {
    static AxsCacheKeeperInstallationTestWorkspace *workspace;static dispatch_once_t once;
    // The IMP also runs with the system class as self; always construct the test workspace explicitly.
    dispatch_once(&once,^{workspace=[AxsCacheKeeperInstallationTestWorkspace new];});return workspace;
}
- (NSArray *)allInstalledApplications { return aiinstalled; }
@end

static BOOL axs_cachekeeper_installation_test_getter_abi(Method method) {
    if (!method) return NO;
    NSMethodSignature *signature=[NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    return signature.numberOfArguments==2 && signature.methodReturnType[0]=='@' && signature.methodReturnLength==sizeof(id) &&
        ([signature getArgumentTypeAtIndex:0][0]=='@' || [signature getArgumentTypeAtIndex:0][0]=='#') &&
        [signature getArgumentTypeAtIndex:1][0]==':';
}

static AxsCacheKeeperInstallationCoverageTestPlugin *aiplugin(NSString *identifier,NSString *owner,id url) {
    AxsCacheKeeperInstallationCoverageTestPlugin *plugin=[AxsCacheKeeperInstallationCoverageTestPlugin new];
    AxsCacheKeeperInstallationCoverageTestOwner *parent=[AxsCacheKeeperInstallationCoverageTestOwner new];parent.bundleIdentifier=owner;
    plugin.pluginIdentifier=identifier;plugin.containingBundle=parent;plugin.dataContainerURL=url;return plugin;
}
static void aicoverage(NSString *root) {
    // Mutations that skip System metadata, substitute containerURL, or retain an old membership fail these assertions.
    AxsCacheKeeperInstallationCoverageTestProxy *user=[AxsCacheKeeperInstallationCoverageTestProxy new];
    user.applicationIdentifier=@"test.installation";user.applicationType=@"User";user.localizedName=@"测试";
    user.shortVersionString=@"1.0";user.bundleURL=[NSURL fileURLWithPath:root];
    NSURL *home=[NSURL URLWithString:@"file:///var/mobile/Containers/Data/Application/test-home"],*group=[NSURL URLWithString:@"file:///private/var/mobile/Containers/Shared/AppGroup/test-group"],
        *extension=[NSURL URLWithString:@"file:///private/var/mobile/Containers/Data/PluginKitPlugin/test-extension"];
    user.dataContainerURL=home;user.groupContainerURLs=@{@"group.test.shared":group};
    user.plugInKitPlugins=@[aiplugin(@"test.plugin.first",user.applicationIdentifier,extension),aiplugin(@"test.plugin.second",user.applicationIdentifier,extension)];
    AxsCacheKeeperInstallationCoverageTestProxy *system=[AxsCacheKeeperInstallationCoverageTestProxy new];
    system.applicationIdentifier=@"com.apple.coverage-test";system.applicationType=@"System";system.bundleURL=[NSURL fileURLWithPath:@"/Applications/Coverage.app"];
    system.containerURL=[NSURL fileURLWithPath:@"/var/mobile"];system.groupContainerURLs=@{@"group.test.shared":group};
    system.plugInKitPlugins=@[aiplugin(@"test.plugin.system",system.applicationIdentifier,home)];
    aiinstalled=@[user,system];NSMutableDictionary *cache=[NSMutableDictionary new];NSDictionary *coverage=nil;
    NSArray *apps=axs_cachekeeper_installed_applications_with_container_coverage(cache,&coverage,nil);
    aicheck(apps.count==1 && [apps.firstObject[@"id"] isEqual:@"test.installation"],@"System登记进入摘要且仍被原展示列表过滤");
    aicheck([coverage[@"state"] isEqual:@"available"] && [coverage[@"observedRegistrations"] isEqual:@2] &&
        [coverage[@"home"][@"registeredURLCount"] isEqual:@1] && [coverage[@"home"][@"notProvidedCount"] isEqual:@1],@"无独立home不采用/var/mobile回退");
    aicheck([coverage[@"group"][@"registeredURLCount"] isEqual:@1] && [coverage[@"group"][@"associationCount"] isEqual:@2] &&
        [coverage[@"extension"][@"registeredURLCount"] isEqual:@2] && [coverage[@"extension"][@"associationCount"] isEqual:@3] &&
        [coverage[@"allRolesUniqueRegisteredURLCount"] isEqual:@3],@"共享组、同URL两扩展、跨角色同URL登记正确去重，保留归属关联");
    AxsCacheKeeperDiagnostics *diagnostics=[[AxsCacheKeeperDiagnostics alloc] initWithFolder:root];
    NSMutableDictionary *injected=[coverage mutableCopy];injected[@"rawURL"]=home;injected[@"privateOwner"]=user.applicationIdentifier;
    NSDictionary *exported=[diagnostics reportWithApps:apps environment:@{@"containerCoverage":injected}];
    aicheck([exported[@"containerCoverage"][@"allRolesUniqueRegisteredURLCount"] isEqual:@3] &&
        [exported[@"containerCoverage"][@"scope"] isEqual:@"allSystemRegistrations"] &&
        [exported[@"containerCoverage"][@"mode"] isEqual:@"systemMetadata"] &&
        [exported[@"containerCoverage"][@"filesystemAccess"] isEqual:@"notChecked"] &&
        [exported[@"containerCoverage"][@"cleanupEligibility"] isEqual:@"notGranted"] &&
        !exported[@"containerCoverage"][@"rawURL"] && !exported[@"containerCoverage"][@"privateOwner"] &&
        [exported[@"collection"][@"rescanned"] isEqual:@NO],@"同一诊断消费者严格投影计数，元数据覆盖不冒充访问或重新扫描");
    NSDictionary *snapshot=cache[user.applicationIdentifier][@"installation"],*entry=apps.firstObject;
    system.plugInKitPlugins=@[];aiinstalled=@[user];
    NSArray *refreshed=axs_cachekeeper_installed_applications_with_container_coverage(cache,&coverage,nil);
    aicheck(refreshed.firstObject==entry && cache[user.applicationIdentifier][@"installation"]==snapshot &&
        [coverage[@"observedRegistrations"] isEqual:@1] && [coverage[@"extension"][@"associationCount"] isEqual:@2],@"同cache新枚举移除APP/插件且未变安装不重读Info");
    user.plugInKitPlugins=@[];
    axs_cachekeeper_installed_applications_with_container_coverage(cache,&coverage,nil);
    aicheck([coverage[@"extension"][@"state"] isEqual:@"available"] && [coverage[@"extension"][@"registeredURLCount"] isEqual:@0],@"正确空扩展集合表示已观察零登记");
    user.plugInKitPlugins=@[aiplugin(@"test.plugin.new",user.applicationIdentifier,[NSURL URLWithString:@"file:///private/var/new-extension"])];aiinstalled=@[user,system];
    axs_cachekeeper_installed_applications_with_container_coverage(cache,&coverage,nil);
    aicheck([coverage[@"observedRegistrations"] isEqual:@2] && [coverage[@"extension"][@"registeredURLCount"] isEqual:@1],@"新增登记与插件由相同入口自动刷新");
    user.plugInKitPlugins=@[aiplugin(@"test.plugin.mismatch",@"test.other.owner",extension)];aiinstalled=@[user];
    axs_cachekeeper_installed_applications_with_container_coverage(cache,&coverage,nil);
    aicheck([coverage[@"state"] isEqual:@"partial"] && [coverage[@"extension"][@"ownerMismatchCount"] isEqual:@1] &&
        [coverage[@"extension"][@"associationCount"] isEqual:@0] && [coverage[@"countsAreLowerBounds"] isEqual:@YES],@"真实containingBundle.bundleIdentifier失配拒绝关联且整体保留partial");
    user.plugInKitPlugins=@[aiplugin(@"test.plugin.conflict",user.applicationIdentifier,extension),aiplugin(@"test.plugin.conflict",user.applicationIdentifier,home)];
    axs_cachekeeper_installed_applications_with_container_coverage(cache,&coverage,nil);
    aicheck([coverage[@"extension"][@"associationCount"] isEqual:@0] && [coverage[@"extension"][@"invalidAssociationCount"] unsignedIntegerValue]>0,@"重复插件ID的矛盾URL不能保留先到关联");
    // A plugin ID has one owner within this observation, even when its URLs coincide.
    user.groupContainerURLs=@{};system.groupContainerURLs=@{};user.dataContainerURL=nil;system.dataContainerURL=nil;
    for (NSNumber *sameURL in @[@YES,@NO]) {
        user.plugInKitPlugins=@[aiplugin(@"test.plugin.shared",user.applicationIdentifier,extension)];
        system.plugInKitPlugins=@[aiplugin(@"test.plugin.shared",system.applicationIdentifier,[sameURL boolValue] ? extension : home)];
        for (NSArray *registrations in @[@[user,system],@[system,user],@[user,system,user],@[system,user,system]]) {
            aiinstalled=registrations;
            NSArray *conflicted=axs_cachekeeper_installed_applications_with_container_coverage(cache,&coverage,nil);
            aicheck(conflicted.count==1 && [conflicted.firstObject[@"id"] isEqual:user.applicationIdentifier],@"跨owner插件冲突不改变原APP展示列表");
            aicheck([coverage[@"extension"][@"associationCount"] isEqual:@0] && [coverage[@"extension"][@"registeredURLCount"] isEqual:@0] &&
                [coverage[@"extension"][@"invalidAssociationCount"] unsignedIntegerValue]>0 && [coverage[@"state"] isEqual:@"partial"] &&
                [coverage[@"countsAreLowerBounds"] isEqual:@YES] && [axs_cachekeeper_container_coverage_projection(coverage)[@"state"] isEqual:@"partial"],
                @"同ID跨owner不论URL、顺序或第三次重复均撤销且不能复活关联");
        }
    }
    user.dataContainerURL=home;aiinstalled=@[user];
    user.groupContainerURLs=nil;user.plugInKitPlugins=nil;
    axs_cachekeeper_installed_applications_with_container_coverage(cache,&coverage,nil);
    aicheck([coverage[@"group"][@"state"] isEqual:@"unavailable"] && [coverage[@"group"][@"notProvidedCount"] isEqual:@1] &&
        !coverage[@"group"][@"registeredURLCount"] && [coverage[@"extension"][@"notProvidedCount"] isEqual:@1],@"nil来源不冒充空集合且不导出零登记计数");
    user.groupContainerURLs=@{};user.plugInKitPlugins=@[];
    axs_cachekeeper_installed_applications_with_container_coverage(cache,&coverage,nil);
    aicheck([coverage[@"group"][@"state"] isEqual:@"available"] && [coverage[@"group"][@"registeredURLCount"] isEqual:@0],@"正确空组字典与nil区别保留");
    AxsCacheKeeperInstallationTestProxy *legacy=[AxsCacheKeeperInstallationTestProxy new];legacy.applicationIdentifier=@"test.legacy";legacy.applicationType=@"User";
    aiinstalled=@[legacy];axs_cachekeeper_installed_applications_with_container_coverage(cache,&coverage,nil);
    aicheck([coverage[@"home"][@"missingSelectorCount"] isEqual:@1] && !coverage[@"home"][@"registeredURLCount"],@"selector缺失明确不可用且不补零");
    aiinstalled=@[user];user.groupContainerURLs=@42;user.dataContainerURL=[NSURL URLWithString:@"file://remote.example/private/data"];
    user.plugInKitPlugins=@[aiplugin(@"test.plugin.no-owner",nil,extension),@42];
    axs_cachekeeper_installed_applications_with_container_coverage(cache,&coverage,nil);
    aicheck([coverage[@"home"][@"state"] isEqual:@"invalid"] && [coverage[@"group"][@"state"] isEqual:@"invalid"] &&
        [coverage[@"extension"][@"unavailableOwnerCount"] isEqual:@1] && [coverage[@"extension"][@"invalidAssociationCount"] isEqual:@1],@"坏类型、非本地URL、缺父归属分别拒绝");
    NSString *json=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:coverage options:0 error:nil] encoding:NSUTF8StringEncoding];
    for (NSString *secret in @[@"test.installation",@"test.plugin",@"remote.example",@"test-extension",@"/private/",@"/var/mobile"]) aicheck(![json containsString:secret],@"提供器摘要不输出私有URL、owner或扩展ID");
    aiinstalled=(id)@42;NSError *error=nil;coverage=nil;
    aicheck(!axs_cachekeeper_installed_applications_with_container_coverage(cache,&coverage,&error) && error &&
        [coverage[@"state"] isEqual:@"unavailable"] && [coverage[@"sourceState"] isEqual:@"invalid"] && !coverage[@"observedRegistrations"],@"坏系统枚举不复用旧摘要或填零");
    aidetail(error,7,@"registry",@"enumerate",0);
    aiinstalled=nil;axs_cachekeeper_installed_applications_with_container_coverage(cache,&coverage,nil);
    aicheck([coverage[@"sourceState"] isEqual:@"unavailable"],@"系统枚举nil与坏类型分别记录");
    exported=[diagnostics reportWithApps:nil environment:@{@"containerCoverage":coverage}];
    aicheck([exported[@"containerCoverage"][@"state"] isEqual:@"unavailable"] && !exported[@"containerCoverage"][@"observedRegistrations"],@"枚举失败仍进入相同报告且不复用旧计数");
    aiinstalled=@[];axs_cachekeeper_installed_applications_with_container_coverage(cache,&coverage,nil);
    aicheck([axs_cachekeeper_container_coverage_projection(coverage)[@"state"] isEqual:@"available"] &&
        [coverage[@"home"][@"registeredURLCount"] isEqual:@0],@"成功空系统枚举是明确零登记，仍可投影");
    AxsCacheKeeperInstallationCoverageScalarTestProxy *scalar=[AxsCacheKeeperInstallationCoverageScalarTestProxy new];scalar.applicationIdentifier=@"test.scalar";
    aiinstalled=@[scalar];axs_cachekeeper_installed_applications_with_container_coverage(cache,&coverage,nil);
    aicheck(aiScalarGetterCalls==0 && [coverage[@"home"][@"state"] isEqual:@"invalid"] &&
        [coverage[@"home"][@"invalidSourceCount"] isEqual:@1],@"运行时非对象返回类型在调用前拒绝");
    NSMutableArray *bounded=[NSMutableArray new];for (NSUInteger i=0;i<4097;i++) [bounded addObject:system];aiinstalled=bounded;
    axs_cachekeeper_installed_applications_with_container_coverage(cache,&coverage,nil);
    aicheck([coverage[@"observedRegistrations"] isEqual:@4096] && [coverage[@"truncatedRegistrationCount"] isEqual:@1] &&
        [coverage[@"countsAreLowerBounds"] isEqual:@YES] && [axs_cachekeeper_container_coverage_projection(coverage)[@"state"] isEqual:@"partial"],@"系统登记超界明确截断并仅报告计数下界");
}

static void aicleanup(NSString *fixture, NSString *name, NSDictionary *snapshot, NSURL *url, BOOL allow) {
    NSString *home=[fixture stringByAppendingPathComponent:name];
    NSString *path=[home stringByAppendingPathComponent:@"Library/Caches/payload"];
    aiput(path,[@"cache payload" dataUsingEncoding:NSUTF8StringEncoding]);
    NSTimeInterval future=NSDate.date.timeIntervalSince1970+600;
    AxsCacheKeeperSweep *sweep=[[AxsCacheKeeperSweep alloc] initWithRoot:path.stringByDeletingLastPathComponent bundle:@"test.installation" version:@"1.0" containerPath:home state:@{} clock:^NSTimeInterval{return future;}];
    AxsCacheKeeperCleanupJob *job=[[AxsCacheKeeperCleanupJob alloc] initWithSweeps:@[sweep] signature:@"installation-fixture" instance:@"" clock:^NSTimeInterval{return 10;}];
    // Keep preflight real; deletion must still validate the package identity bound before mutation.
    for (NSUInteger i=0;i<1000 && job.phase==AxsCacheKeeperCleanupPhaseChecking;i++) [job advanceCycleWithPerRootLimit:8 gate:^BOOL{return YES;}];
    aicheck(job.removed==0 && job.phase==AxsCacheKeeperCleanupPhaseReady,@"真实作业预检结束且未删除");
    for (NSUInteger i=0;i<1000 && job.phase!=AxsCacheKeeperCleanupPhaseFinished;i++)
        [job advanceCycleWithPerRootLimit:8 gate:^BOOL{return axs_cachekeeper_validate_installation_snapshot(snapshot,url,@"1.0",nil);}];
    aicheck(job.phase==AxsCacheKeeperCleanupPhaseFinished,@"门控作业有界结束");
    aicheck(job.removed==(allow ? 1 : 0) && [NSFileManager.defaultManager fileExistsAtPath:path]!=allow,@"安装失效零删除；未变化对照真实删除");
    if (!allow) aicheck(job.endReason==AxsCacheKeeperCleanupEndReasonCancelled,@"失效门控明确取消作业");
}

static void aidetail(NSError *error, NSInteger code, NSString *target, NSString *operation, int number) {
    NSDictionary *expected=@{@"target":target,@"operation":operation,@"errno":@(number)};
    aicheck([error.domain isEqual:@"dev.local.cachekeeper.installation"] && error.code==code,
        @"精准详情不改变原有安装错误域及错误码");
    NSDictionary *detail=error.userInfo[@"detail"];
    aicheck([[detail dictionaryWithValuesForKeys:@[@"target",@"operation",@"errno"]] isEqual:expected],
        [NSString stringWithFormat:@"安装失败必须保留准确阶段及即时errno: %@/%@",target,operation]);
    aicheck([axs_cachekeeper_installation_detail_projection(detail) isEqual:detail],
        @"生产安装失败详情通过唯一严格投影");
    if ([@[@"openIdentity",@"recheckIdentity",@"snapshotIdentity"] containsObject:operation])
        aicheck([detail[@"identity"][@"differenceMask"] unsignedIntegerValue]>0,@"真实身份变化必须保留非零字段差异");
    else aicheck([detail isEqual:expected],@"普通错误不混入身份差异字段");
}

static void aidetail_projection(void) {
    NSDictionary *valid=@{@"target":@"info",@"operation":@"stat",@"errno":@(ENOENT)};
    aicheck([axs_cachekeeper_installation_detail_projection(valid) isEqual:valid],@"固定安装详情可投影");
    for (id invalid in @[NSNull.null,@42,@[],@{},@{@"target":@"info",@"operation":@"stat"}])
        aicheck(!axs_cachekeeper_installation_detail_projection(invalid),@"非详情结构不能投影");
    aicheck(!axs_cachekeeper_installation_detail_projection(nil),@"旧错误无detail仍明确缺失");
    for (id number in @[@YES,@(-1),@0,@1.5,@((double)INT_MAX+1),@(NAN),@(INFINITY),@"2",NSNull.null]) {
        NSMutableDictionary *invalid=[valid mutableCopy];invalid[@"errno"]=number;
        aicheck(!axs_cachekeeper_installation_detail_projection(invalid),@"系统错误必须是正整数errno且不是BOOL");
    }
    for (NSDictionary *change in @[
        @{@"target":@"private/path"},@{@"operation":@"unknown"},@{@"target":@1},@{@"operation":@[]},
        @{@"path":@"/private/installation"},@{@"description":@"sensitive error"},
        @{@"target":@"main",@"operation":@"parse",@"errno":@0},
        @{@"operation":@"type",@"errno":@(EACCES)}]) {
        NSMutableDictionary *invalid=[valid mutableCopy];[invalid addEntriesFromDictionary:change];
        aicheck(!axs_cachekeeper_installation_detail_projection(invalid),@"未知字段、角色阶段不匹配及语义旧errno拒绝导出");
    }
    for (NSNumber *number in @[@0,@(EIO),@(EINTR)])
        aicheck(axs_cachekeeper_installation_detail_projection(@{@"target":@"info",@"operation":@"read",@"errno":number})!=nil,
            @"Info提前EOF与系统读取错误都能表达");
    NSMutableString *target=[@"info" mutableCopy],*operation=[@"stat" mutableCopy];
    NSMutableDictionary *source=[@{@"target":target,@"operation":operation,@"errno":@(ENOENT)} mutableCopy];
    NSDictionary *projected=axs_cachekeeper_installation_detail_projection(source);
    [target appendString:@"/private"];[operation appendString:@" changed"];source[@"errno"]=@(EACCES);
    aicheck([projected isEqual:valid],@"投影固定值不受调用方可变容器污染");
}

#if defined(AXS_CACHEKEEPER_INSTALLATION_TESTING)
static void aidetail_reads(NSString *fixture) {
    NSString *root=aibundle(fixture,@"read-failures");NSURL *url=[NSURL fileURLWithPath:root];
    // Losing errno, treating EOF as errno, or allowing a fifth retry all break these assertions.
    for (NSArray *test in @[@[@(EIO),@1,@NO],@[@0,@1,@NO],@[@(EINTR),@4,@YES],@[@(EINTR),@5,@NO]]) {
        aiReadError=[test[0] intValue];aiReadFailures=[test[1] unsignedIntegerValue];aiReadCalls=0;
        @try {
            NSError *error=[NSError errorWithDomain:@"old" code:99 userInfo:nil];
            NSDictionary *snapshot=axs_cachekeeper_installation_snapshot(url,@"test.installation",@"1.0",&error);
            if ([test[2] boolValue]) aicheck(snapshot && !error,@"四次EINTR后真实读取成功，清空旧错");
            else { aicheck(!snapshot,@"真实Info读取失败或EOF不能创建安装身份");aidetail(error,4,@"info",@"read",aiReadError); }
            aicheck(aiReadCalls==[test[1] unsignedIntegerValue],@"读取中断重试次数保持有界");
        } @finally { aiReadFailures=0;aiReadCalls=0;aiReadError=0; }
    }
    aiReadLimit=13;aiShortReadCalls=0;
    @try {
        NSError *error=nil;
        aicheck(axs_cachekeeper_installation_snapshot(url,@"test.installation",@"1.0",&error)!=nil && !error && aiShortReadCalls>1,
            @"真实Info正数短读继续累积，不能误报EOF或截断解析");
    } @finally { aiReadLimit=0;aiShortReadCalls=0; }
}
#endif

static void aidetail_files(NSString *fixture) {
    // These fail if file roles are merged, syscall errno is lost, or semantic rejection reads stale errno.
    NSArray *cases=@[
        @[@"missing-root",@"root",@"stat",@2,@(ENOENT)],@[@"missing-info",@"info",@"stat",@3,@(ENOENT)],
        @[@"missing-main",@"main",@"stat",@3,@(ENOENT)],@[@"root-file",@"root",@"type",@2,@0],
        @[@"root-link",@"root",@"type",@2,@0],@[@"info-link",@"info",@"type",@3,@0],
        @[@"main-link",@"main",@"type",@3,@0],@[@"info-directory",@"info",@"type",@3,@0],
        @[@"main-directory",@"main",@"type",@3,@0],@[@"info-fifo",@"info",@"type",@3,@0],
        @[@"main-fifo",@"main",@"type",@3,@0]];
    for (NSArray *test in cases) {
        NSString *name=test[0],*target=test[1],*root=aibundle(fixture,[name stringByAppendingString:@"-detail"]);
        NSString *file=[target isEqual:@"root"] ? root : [root stringByAppendingPathComponent:[target isEqual:@"info"] ? @"Info.plist" : @"Main"];
        NSString *old=[file stringByAppendingString:@".old"];
        aicheck([NSFileManager.defaultManager moveItemAtPath:file toPath:old error:nil],@"移走真实安装夹具");
        if ([name hasSuffix:@"link"]) aicheck(symlink(old.fileSystemRepresentation,file.fileSystemRepresentation)==0,@"创建真实链接夹具");
        if ([name hasSuffix:@"directory"]) aicheck(mkdir(file.fileSystemRepresentation,0700)==0,@"创建目录代替安装文件");
        if ([name hasSuffix:@"fifo"]) aicheck(mkfifo(file.fileSystemRepresentation,0600)==0,@"创建真实管道夹具");
        if ([name isEqual:@"root-file"]) aiput(file,[@"not a directory" dataUsingEncoding:NSUTF8StringEncoding]);
        errno=EACCES;NSError *error=nil;
        aicheck(!axs_cachekeeper_installation_snapshot([NSURL fileURLWithPath:root],@"test.installation",@"1.0",&error),@"无效真实安装文件拒绝建立身份");
        aidetail(error,[test[3] integerValue],target,test[2],[test[4] intValue]);
    }
    NSArray *metadata=@[
        @[@"identifier-type",@{@"CFBundleIdentifier":@7},@"identifier"],
        @[@"identifier-mismatch",@{@"CFBundleIdentifier":@"different.app"},@"identifierMismatch"],
        @[@"executable-type",@{@"CFBundleExecutable":@[]},@"executable"],
        @[@"executable-parent",@{@"CFBundleExecutable":@"../Main"},@"executable"],
        @[@"build-type",@{@"CFBundleVersion":@100},@"build"],
        @[@"version-type",@{@"CFBundleShortVersionString":@1},@"version"]];
    for (NSArray *test in metadata) {
        NSString *root=aibundle(fixture,test[0]);aiinfo(root,test[1]);NSError *error=nil;errno=EACCES;
        aicheck(!axs_cachekeeper_installation_snapshot([NSURL fileURLWithPath:root],@"test.installation",@"1.0",&error),@"坏安装字段拒绝");
        aidetail(error,5,@"info",test[2],0);
    }
    NSArray *contents=@[
        @[@"empty-info",NSData.data,@"size",@4],
        @[@"large-info",[NSMutableData dataWithLength:1024*1024+1],@"size",@4],
        @[@"malformed-info",[@"<?xml version=\"1.0\"?><plist><dict>" dataUsingEncoding:NSUTF8StringEncoding],@"parse",@5],
        @[@"array-info",[NSPropertyListSerialization dataWithPropertyList:@[@1] format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil],@"metadataType",@5]];
    for (NSArray *test in contents) {
        NSString *root=aibundle(fixture,test[0]);aiput([root stringByAppendingPathComponent:@"Info.plist"],test[1]);NSError *error=nil;errno=EACCES;
        aicheck(!axs_cachekeeper_installation_snapshot([NSURL fileURLWithPath:root],@"test.installation",@"1.0",&error),@"坏Info内容有界拒绝");
        aidetail(error,[test[3] integerValue],@"info",test[2],0);
    }
    NSString *root=aibundle(fixture,@"snapshot-detail");NSURL *url=[NSURL fileURLWithPath:root];
    NSError *error=[NSError errorWithDomain:@"old" code:99 userInfo:nil];
    NSDictionary *snapshot=axs_cachekeeper_installation_snapshot(url,@"test.installation",@"1.0",&error);
    aicheck(snapshot && !error,@"建立有效快照清空旧错");
    error=[NSError errorWithDomain:@"old" code:99 userInfo:nil];
    aicheck(axs_cachekeeper_validate_installation_snapshot(snapshot,url,@"1.0",&error) && !error,@"成功复核清空旧错");
    errno=EACCES;aicheck(!axs_cachekeeper_installation_snapshot(url,@"test.installation",@"2.0",&error),@"真实系统与Info版本差拒绝");
    aidetail(error,6,@"info",@"versionMismatch",0);
    errno=EACCES;aicheck(!axs_cachekeeper_validate_installation_snapshot(snapshot,url,@"2.0",&error),@"快照系统版本变化拒绝");
    aidetail(error,6,@"snapshot",@"version",0);
    errno=EACCES;aicheck(!axs_cachekeeper_validate_installation_snapshot(snapshot,[NSURL fileURLWithPath:[root stringByAppendingString:@".moved"]],@"1.0",&error),@"快照位置变化拒绝");
    aidetail(error,6,@"snapshot",@"path",0);
    errno=EACCES;aicheck(!axs_cachekeeper_installation_snapshot(nil,@"test.installation",@"1.0",&error),@"缺系统URL拒绝");
    aidetail(error,1,@"input",@"url",0);
    errno=EACCES;aicheck(!axs_cachekeeper_installation_snapshot(url,@"bad/id",@"1.0",&error),@"坏系统标识拒绝");
    aidetail(error,1,@"input",@"identifier",0);
    errno=EACCES;aicheck(!axs_cachekeeper_installation_snapshot(url,@"test.installation",(id)@1,&error),@"坏系统版本类型拒绝");
    aidetail(error,1,@"input",@"version",0);
    errno=EACCES;aicheck(!axs_cachekeeper_validate_installation_snapshot(nil,url,@"1.0",&error),@"缺快照拒绝");
    aidetail(error,1,@"snapshot",@"shape",0);
    errno=EACCES;aicheck(!axs_cachekeeper_validate_installation_snapshot(@{},url,@"1.0",&error),@"快照缺可执行名拒绝");
    aidetail(error,1,@"snapshot",@"executable",0);
    errno=EACCES;aicheck(!axs_cachekeeper_validate_installation_snapshot(snapshot,url,(id)@1,&error),@"复核系统版本坏类型拒绝");
    aidetail(error,1,@"input",@"version",0);
    NSString *bounded=aibundle(fixture,@"exact-size-limit");
    NSMutableData *xml=[[NSPropertyListSerialization dataWithPropertyList:@{@"CFBundleIdentifier":@"test.installation",@"CFBundleVersion":@"100",
        @"CFBundleShortVersionString":@"1.0",@"CFBundleExecutable":@"Main"} format:NSPropertyListXMLFormat_v1_0 options:0 error:nil] mutableCopy];
    NSUInteger length=xml.length;[xml setLength:1024*1024];memset((unsigned char *)xml.mutableBytes+length,' ',xml.length-length);
    aiput([bounded stringByAppendingPathComponent:@"Info.plist"],xml);
    aicheck(axs_cachekeeper_installation_snapshot([NSURL fileURLWithPath:bounded],@"test.installation",@"1.0",&error)!=nil && !error,
        @"真实有效Info在1MiB边界内仍可读取，未错误收紧大小限制");
    for (NSString *target in @[@"root",@"info",@"main"]) {
        NSString *changed=aibundle(fixture,[target stringByAppendingString:@"-identity-detail"]);NSURL *changedURL=[NSURL fileURLWithPath:changed];
        NSDictionary *bound=axs_cachekeeper_installation_snapshot(changedURL,@"test.installation",@"1.0",nil);
        aicheck(bound!=nil,@"身份变化前建立真实快照");
        if ([target isEqual:@"root"]) {
            struct stat attributes;aicheck(lstat(changed.fileSystemRepresentation,&attributes)==0,@"读取目录模式夹具");
            aicheck(chmod(changed.fileSystemRepresentation,(attributes.st_mode & 07777)^S_IXGRP)==0,@"更改安装目录元数据");
        }
        else {
            NSString *path=[changed stringByAppendingPathComponent:[target isEqual:@"info"] ? @"Info.plist" : @"Main"];
            aicheck([[@"different file content and length" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path options:0 error:nil],@"原地改写被绑定的真实文件");
        }
        errno=EACCES;aicheck(!axs_cachekeeper_validate_installation_snapshot(bound,changedURL,@"1.0",&error),@"任何绑定文件身份变化均撤销旧快照");
        aidetail(error,6,target,@"snapshotIdentity",0);
        NSUInteger mask=[error.userInfo[@"detail"][@"identity"][@"differenceMask"] unsignedIntegerValue];
        aicheck((mask&([target isEqual:@"root"] ? 4 : 64))!=0,@"真实目录模式或文件长度变化保留对应差异位");
    }
}

static void ai_search_only_root(NSString *fixture) {
    NSString *root=aibundle(fixture,@"search-only-root");NSURL *url=[NSURL fileURLWithPath:root];
    struct stat original,observed;
    aicheck(lstat(root.fileSystemRepresentation,&original)==0,@"记录安装根夹具原权限");
    NSError *snapshotError=nil,*validateError=nil;NSDictionary *snapshot=nil;
    BOOL verified=NO,unchanged=NO;int legacy=-1,legacyError=0,restored=-1;
    aicheck(chmod(root.fileSystemRepresentation,0111)==0,@"安装根只授予遍历权限");
    @try {
        legacy=open(root.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);legacyError=errno;
        snapshot=axs_cachekeeper_installation_snapshot(url,@"test.installation",@"1.0",&snapshotError);
        verified=snapshot && axs_cachekeeper_validate_installation_snapshot(snapshot,url,@"1.0",&validateError);
        unchanged=lstat(root.fileSystemRepresentation,&observed)==0 && (observed.st_mode&07777)==0111;
    } @finally {
        if (legacy>=0) close(legacy);
        restored=chmod(root.fileSystemRepresentation,original.st_mode&07777);
    }
    aicheck(restored==0,@"恢复仅遍历安装根夹具权限");
    aicheck(legacy<0 && legacyError==EACCES,@"真实非root负对照：旧安装根O_RDONLY错误要求枚举权限");
    aicheck(snapshot && !snapshotError && [snapshot[@"installationState"] isEqual:@"verified"] &&
        [snapshot[@"build"] isEqual:@"100"] && snapshot[@"_info"] && snapshot[@"_main"] &&
        verified && !validateError && unchanged,@"0111安装根可读取Info和核验主程序，快照与复核均成功且不改权限");

    for (NSString *target in @[@"root",@"info",@"main"]) {
        NSString *deniedRoot=aibundle(fixture,[target stringByAppendingString:@"-permission-denied"]);
        NSString *file=[target isEqual:@"root"] ? deniedRoot : [deniedRoot stringByAppendingPathComponent:[target isEqual:@"info"] ? @"Info.plist" : @"Main"];
        struct stat rootMode,fileMode,afterRoot,afterFile;
        aicheck(lstat(deniedRoot.fileSystemRepresentation,&rootMode)==0 && lstat(file.fileSystemRepresentation,&fileMode)==0,
            @"记录权限负例原权限");
        BOOL isRoot=[target isEqual:@"root"];int childRestricted=0,rootRestored=-1,childRestored=0;
        mode_t restrictedRoot=isRoot ? 0000 : 0111;
        NSError *error=nil;NSDictionary *denied=nil;BOOL modesUnchanged=NO;
        aicheck(chmod(deniedRoot.fileSystemRepresentation,restrictedRoot)==0,@"限制安装根测试权限");
        @try {
            if (!isRoot) childRestricted=chmod(file.fileSystemRepresentation,0000);
            if (!childRestricted) denied=axs_cachekeeper_installation_snapshot([NSURL fileURLWithPath:deniedRoot],@"test.installation",@"1.0",&error);
            modesUnchanged=lstat(deniedRoot.fileSystemRepresentation,&afterRoot)==0 && (afterRoot.st_mode&07777)==restrictedRoot &&
                (isRoot || (lstat(file.fileSystemRepresentation,&afterFile)==0 && (afterFile.st_mode&07777)==0000));
        } @finally {
            if (!isRoot) childRestored=chmod(file.fileSystemRepresentation,fileMode.st_mode&07777);
            rootRestored=chmod(deniedRoot.fileSystemRepresentation,rootMode.st_mode&07777);
        }
        aicheck(childRestricted==0 && childRestored==0 && rootRestored==0,@"权限负例限制成功并恢复全部夹具权限");
        aicheck(!denied && modesUnchanged,@"O_SEARCH不放行0000根或不可读Info/Main，拒绝时不修改权限");
        aidetail(error,isRoot ? 2 : 3,target,@"open",EACCES);
    }
}

void axs_cachekeeper_run_installation_tests(NSString *fixture) {
    dispatch_sync(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{ @autoreleasepool {
        aidetail_projection();
        ai_search_only_root([fixture stringByAppendingPathComponent:@"search-permissions"]);
        aidetail_files([fixture stringByAppendingPathComponent:@"failure-details"]);
#if defined(AXS_CACHEKEEPER_INSTALLATION_TESTING)
        aidetail_reads([fixture stringByAppendingPathComponent:@"failure-details"]);
#endif
        NSFileManager *fm=NSFileManager.defaultManager;
        NSArray *cases=@[@"unchanged",@"build",@"info-replace",@"info-inplace",@"executable-replace",@"executable-inplace",@"bundle-replace",@"bundle-link",@"url-change",@"missing-info",@"missing-executable",@"info-link",@"executable-link",@"info-fifo",@"executable-fifo"];
        for (NSString *name in cases) {
            NSString *root=aibundle(fixture,name);NSURL *url=[NSURL fileURLWithPath:root];NSError *error=nil;
            NSDictionary *snapshot=axs_cachekeeper_installation_snapshot(url,@"test.installation",@"1.0",&error);
            aicheck(snapshot && !error && [snapshot[@"build"] isEqual:@"100"],@"真实安装快照有实际构建号");
            if ([name isEqual:@"build"]) aiinfo(root,@{@"CFBundleVersion":@"101"});
            if ([name isEqual:@"info-replace"]) aiinfo(root,@{});
            if ([name isEqual:@"executable-replace"]) aiput([root stringByAppendingPathComponent:@"Main"],[@"replacement" dataUsingEncoding:NSUTF8StringEncoding]);
            if ([name hasSuffix:@"inplace"]) {
                NSString *file=[root stringByAppendingPathComponent:[name hasPrefix:@"info"] ? @"Info.plist" : @"Main"];
                NSData *content=[name hasPrefix:@"info"] ? [NSPropertyListSerialization dataWithPropertyList:@{@"CFBundleIdentifier":@"test.installation",@"CFBundleVersion":@"101",@"CFBundleShortVersionString":@"1.0",@"CFBundleExecutable":@"Main"} format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil] : [@"new main executable" dataUsingEncoding:NSUTF8StringEncoding];
                struct stat before,after;
                aicheck(lstat(root.fileSystemRepresentation,&before)==0 && [content writeToFile:file options:0 error:nil] && lstat(root.fileSystemRepresentation,&after)==0,@"原地改写已有安装文件");
                aicheck(before.st_ino==after.st_ino && before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec,@"原地改写夹具保持目录身份，以文件身份捕获变化");
            }
            if ([name isEqual:@"bundle-replace"]) {
                aicheck([fm moveItemAtPath:root toPath:[root stringByAppendingString:@".old"] error:nil],@"保留旧安装目录");
                aibundle(fixture,name);
            }
            if ([name isEqual:@"bundle-link"]) {
                aicheck([fm moveItemAtPath:root toPath:[root stringByAppendingString:@".old"] error:nil],@"移走真实安装包");
                aicheck(symlink([root stringByAppendingString:@".old"].fileSystemRepresentation,root.fileSystemRepresentation)==0,@"建立拒绝包目录链接");
                url=[NSURL fileURLWithPath:[root stringByAppendingString:@"/"] isDirectory:YES];
            }
            if ([name isEqual:@"url-change"]) url=[NSURL fileURLWithPath:aibundle(fixture,@"new-location")];
            for (NSString *part in @[@"info",@"executable"]) if ([name containsString:part] && ([name hasPrefix:@"missing"] || [name hasSuffix:@"link"] || [name hasSuffix:@"fifo"])) {
                NSString *file=[root stringByAppendingPathComponent:[part isEqual:@"info"] ? @"Info.plist" : @"Main"];
                aicheck([fm moveItemAtPath:file toPath:[file stringByAppendingString:@".old"] error:nil],@"移走安装文件");
                if ([name hasSuffix:@"link"]) aicheck(symlink([file stringByAppendingString:@".old"].fileSystemRepresentation,file.fileSystemRepresentation)==0,@"建立拒绝链接");
                if ([name hasSuffix:@"fifo"]) aicheck(mkfifo(file.fileSystemRepresentation,0600)==0,@"建立拒绝命名管道");
            }
            BOOL unchanged=[name isEqual:@"unchanged"];
            aicheck(axs_cachekeeper_validate_installation_snapshot(snapshot,url,@"1.0",&error)==unchanged,@"同版本文件或安装位置变化拒绝旧身份");
            aicheck(unchanged || error!=nil,@"失效提供明确原因");
            aicleanup(fixture,[name stringByAppendingString:@"-cleanup"],snapshot,url,unchanged);
            if ([name hasSuffix:@"fifo"] || [name hasSuffix:@"link"] || [name hasPrefix:@"missing"]) {
                error=nil;aicheck(!axs_cachekeeper_installation_snapshot(url,@"test.installation",@"1.0",&error) && error,@"缺文件、链接和特殊文件不能成为新身份");
            }
        }
        for (NSDictionary *bad in @[@{@"CFBundleIdentifier":@"different.app"},@{@"CFBundleIdentifier":@12},@{@"CFBundleExecutable":@[@"Main"]},@{@"CFBundleExecutable":@"../Main"},@{@"CFBundleExecutable":@"a/Main"},@{@"CFBundleVersion":@100},@{@"CFBundleShortVersionString":@1}]) {
            NSString *root=aibundle(fixture,NSUUID.UUID.UUIDString);aiinfo(root,bad);NSError *error=nil;
            aicheck(!axs_cachekeeper_installation_snapshot([NSURL fileURLWithPath:root],@"test.installation",@"1.0",&error) && error,@"坏字段类型和可执行路径拒绝");
        }
        NSString *unknown=aibundle(fixture,@"unknown-version");
        aiput([unknown stringByAppendingPathComponent:@"Info.plist"],[NSPropertyListSerialization dataWithPropertyList:@{@"CFBundleIdentifier":@"test.installation",@"CFBundleExecutable":@"Main"} format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil]);
        NSDictionary *unknownSnapshot=axs_cachekeeper_installation_snapshot([NSURL fileURLWithPath:unknown],@"test.installation",nil,nil);
        aicheck(unknownSnapshot && !unknownSnapshot[@"build"] && !unknownSnapshot[@"version"] && [unknownSnapshot[@"installationState"] isEqual:@"versionUnknown"],@"缺版本明确未知，无伪造版本");
        aicheck(axs_cachekeeper_validate_installation_snapshot(unknownSnapshot,[NSURL fileURLWithPath:unknown],nil,nil),@"未知版本可按不变物理身份保守复核");
        aicheck(!axs_cachekeeper_validate_installation_snapshot(unknownSnapshot,[NSURL fileURLWithPath:unknown],@"new",nil),@"系统版本从未知变化时旧快照失效");
        NSString *invalid=aibundle(fixture,@"invalid-plist");
        aiput([invalid stringByAppendingPathComponent:@"Info.plist"],[NSPropertyListSerialization dataWithPropertyList:@[@"not a dictionary"] format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil]);
        aicheck(!axs_cachekeeper_installation_snapshot([NSURL fileURLWithPath:invalid],@"test.installation",@"1.0",nil),@"非字典安装信息拒绝");
        unichar zero=0;NSString *nulName=[@"Main" stringByAppendingString:[NSString stringWithCharacters:&zero length:1]];
        aiinfo(invalid,@{@"CFBundleExecutable":nulName});
        aicheck(!axs_cachekeeper_installation_snapshot([NSURL fileURLWithPath:invalid],@"test.installation",@"1.0",nil),@"可执行名称NUL拒绝");
        aiinfo(invalid,@{});
        aicheck(!axs_cachekeeper_installation_snapshot([NSURL fileURLWithPath:invalid],@"test.installation",@"2.0",nil),@"系统与Info版本冲突等待稳定");
        NSString *oversize=aibundle(fixture,@"oversize");aiput([oversize stringByAppendingPathComponent:@"Info.plist"],[NSMutableData dataWithLength:1024*1024+1]);
        aicheck(!axs_cachekeeper_installation_snapshot([NSURL fileURLWithPath:oversize],@"test.installation",@"1.0",nil),@"超限Info有界拒绝");
        Class workspaceClass=NSClassFromString(@"LSApplicationWorkspace");
        aicheck(workspaceClass!=Nil,@"运行环境缺少真实LSApplicationWorkspace，无法执行提供器测试");
        Method systemGetter=class_getClassMethod(workspaceClass,NSSelectorFromString(@"defaultWorkspace"));
        Method fixtureGetter=class_getClassMethod(AxsCacheKeeperInstallationTestWorkspace.class,@selector(defaultWorkspace));
        aicheck(axs_cachekeeper_installation_test_getter_abi(systemGetter) && axs_cachekeeper_installation_test_getter_abi(fixtureGetter),
            @"系统或替身defaultWorkspace缺失，或不符合id(id,SEL) getter ABI");
        IMP originalGetter=method_getImplementation(systemGetter),testGetter=method_getImplementation(fixtureGetter);
        aicheck(originalGetter && testGetter,@"系统及替身getter必须有可恢复的实现");
        @try {
        aicheck(method_setImplementation(systemGetter,testGetter)==originalGetter,@"只替换已有系统getter并保存原实现");
        NSString *root=aibundle(fixture,@"provider");AxsCacheKeeperInstallationTestProxy *proxy=[AxsCacheKeeperInstallationTestProxy new];
        proxy.applicationIdentifier=@"test.installation";proxy.applicationType=@"User";proxy.localizedName=@"测试";proxy.shortVersionString=@"1.0";proxy.bundleURL=[NSURL fileURLWithPath:root];aiinstalled=@[proxy];
        NSMutableDictionary *cache=[NSMutableDictionary new];
        NSDictionary *originalEntry=axs_cachekeeper_installed_applications(cache,nil).firstObject;
        NSDictionary *originalInstallation=cache[@"test.installation"][@"installation"];
        aicheck([originalEntry[@"build"] isEqual:@"100"] && originalInstallation,@"共享提供器读取构建");
        // The incremental contract must avoid rebuilding an unchanged package, then evict both old objects on change.
        NSDictionary *unchangedEntry=axs_cachekeeper_installed_applications(cache,nil).firstObject;
        aicheck(unchangedEntry==originalEntry && cache[@"test.installation"][@"entry"]==originalEntry &&
            cache[@"test.installation"][@"installation"]==originalInstallation,@"未变安装复用同一安装快照与显示条目，避免重复解析Info");
        aiinfo(root,@{@"CFBundleVersion":@"101"});
        NSDictionary *updated=axs_cachekeeper_installed_applications(cache,nil).firstObject;
        NSDictionary *updatedInstallation=cache[@"test.installation"][@"installation"];
        aicheck([updated[@"build"] isEqual:@"101"] && !updated[@"fingerprint"] && !updated[@"bundleURL"],@"相同短版本缓存刷新构建且不导出内部路径身份");
        aicheck(updated!=originalEntry && cache[@"test.installation"][@"entry"]==updated &&
            updatedInstallation && updatedInstallation!=originalInstallation && [updatedInstallation[@"build"] isEqual:@"101"] &&
            [originalEntry[@"build"] isEqual:@"100"],
            @"Info构建变化后替换旧安装快照和显示条目，旧条目保持原始构建");
        aicheck([fm removeItemAtPath:[root stringByAppendingPathComponent:@"Info.plist"] error:nil],@"制造安装快照不可用");
        NSDictionary *missing=axs_cachekeeper_installed_applications(cache,nil).firstObject;
        aicheck([missing[@"id"] isEqual:@"test.installation"] && [missing[@"installationState"] isEqual:@"unavailable"] && !missing[@"build"],@"安装未知保留APP且不复用旧构建");
        aiinfo(root,@{@"CFBundleVersion":@"102"});
        NSDictionary *restored=axs_cachekeeper_installed_applications(cache,nil).firstObject;
        aicheck([restored[@"build"] isEqual:@"102"] && [restored[@"installationState"] isEqual:@"verified"],@"缺失后恢复重新采集真实安装，不复活旧身份");
        NSString *future=aibundle(fixture,@"future-app");aiinfo(future,@{@"CFBundleIdentifier":@"test.future.app"});
        AxsCacheKeeperInstallationTestProxy *newProxy=[AxsCacheKeeperInstallationTestProxy new];
        newProxy.applicationIdentifier=@"test.future.app";newProxy.applicationType=@"User";newProxy.localizedName=@"新增APP";newProxy.shortVersionString=@"1.0";newProxy.bundleURL=[NSURL fileURLWithPath:future];
        aiinstalled=@[proxy,newProxy];
        NSArray *newApps=axs_cachekeeper_installed_applications(cache,nil);
        NSDictionary *futureEntry=nil;for (NSDictionary *entry in newApps) if ([entry[@"id"] isEqual:@"test.future.app"]) futureEntry=entry;
        aicheck(newApps.count==2 && [futureEntry[@"build"] isEqual:@"100"],@"未来新增APP经同一提供器自动纳入，无版本名单");
        for (NSDictionary *entry in newApps) aicheck(!entry[@"installation"] && !entry[@"_path"] && !entry[@"fingerprint"],@"返回数组不含内部安装缓存");
        aiinstalled=@[newProxy];aicheck(axs_cachekeeper_installed_applications(cache,nil).count==1 && !cache[@"test.installation"],@"卸载APP从提供器缓存移除");
        NSString *trollRoot=aibundle(fixture,@"containers/Bundle/Application/troll-id");
        proxy.applicationType=@"System";proxy.bundleURL=[NSURL fileURLWithPath:trollRoot];aiinstalled=@[proxy];
        NSMutableDictionary *trollCache=[NSMutableDictionary new];
        aicheck(axs_cachekeeper_installed_applications(trollCache,nil).count==1,@"第三方系统分类的真实容器APP可管理");
        proxy.bundleURL=nil;
        for (NSUInteger round=0;round<2;round++) {
            NSArray *temporarilyUnknown=axs_cachekeeper_installed_applications(trollCache,nil);
            aicheck(temporarilyUnknown.count==1 && [temporarilyUnknown[0][@"installationState"] isEqual:@"unavailable"] &&
                !temporarilyUnknown[0][@"build"] && !trollCache[@"test.installation"][@"installation"],
                @"已知第三方System应用URL暂缺时保留不可用条目，但撤销旧安装授权");
        }
        proxy.bundleURL=[NSURL fileURLWithPath:root];
        aicheck(axs_cachekeeper_installed_applications(trollCache,nil).count==0,@"当前有效路径明确在管理范围外时不复用旧分类");
        proxy.bundleURL=nil;
        aicheck(axs_cachekeeper_installed_applications(trollCache,nil).count==0,@"未知System来源不能凭缺路径扩展管理边界");
        aicoverage(root);
        } @finally {
            method_setImplementation(systemGetter,originalGetter);
            aiinstalled=nil;
        }
        aicheck(method_getImplementation(systemGetter)==originalGetter,@"提供器测试完成后恢复系统getter实现");
        puts("PASS: installation identity, bounded metadata, shared provider and real cleanup cancellation");
    }});
}
