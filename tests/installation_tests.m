#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#include <sys/stat.h>
#include <unistd.h>
#import "../AxsCacheKeeperInstallation.h"
#import "../AxsCacheKeeperSweep.h"
#import "../AxsCacheKeeperCleanupJob.h"

static void aicheck(BOOL ok, NSString *message) {
    if (!ok) { fprintf(stderr,"FAIL: installation: %s\n",message.UTF8String);exit(1); }
}
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

// Only the system application registry is substituted; snapshots, file access and cleanup stay real.
@interface AxsCacheKeeperInstallationTestProxy : NSObject
@property(nonatomic,copy) NSString *applicationIdentifier,*applicationType,*localizedName,*shortVersionString;
@property(nonatomic,strong) NSURL *bundleURL;
@end
@implementation AxsCacheKeeperInstallationTestProxy
@end
@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allInstalledApplications;
@end
static NSArray *aiinstalled;
@implementation LSApplicationWorkspace
+ (instancetype)defaultWorkspace { static LSApplicationWorkspace *workspace;static dispatch_once_t once;dispatch_once(&once,^{workspace=[self new];});return workspace; }
- (NSArray *)allInstalledApplications { return aiinstalled; }
@end

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

void axs_cachekeeper_run_installation_tests(NSString *fixture) {
    dispatch_sync(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{ @autoreleasepool {
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
        aiinstalled=nil;
        puts("PASS: installation identity, bounded metadata, shared provider and real cleanup cancellation");
    }});
}
