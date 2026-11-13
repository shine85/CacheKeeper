#import <Foundation/Foundation.h>
#import "../AxsCacheKeeperPolicy.h"
#import "../AxsCacheKeeperCleanupRules.h"
#import "../AxsCacheKeeperSweep.h"
#import "../AxsCacheKeeperCleanupSchedule.h"
#import "../AxsCacheKeeperCleanupJob.h"
#import "../AxsCacheKeeperProcessObservation.h"
#import "../AxsCacheKeeperDependencySnapshot.h"
#import "../AxsCacheKeeperInspection.h"
#include <unistd.h>
#include <errno.h>

static void ckcheck(BOOL value, NSString *message) {
    if (!value) { fprintf(stderr,"FAIL: review followup: %s\n",message.UTF8String);exit(1); }
}
static NSString *ckdir(NSString *parent,NSString *relative) {
    NSString *path=[parent stringByAppendingPathComponent:relative];
    ckcheck([NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil],@"建立夹具目录");return path;
}
static void ckput(NSString *path,NSString *contents) {
    ckcheck([contents writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil],@"写入夹具文件");
}
static void ckfinish(AxsCacheKeeperSweep *sweep) {
    for (NSUInteger n=0;n<10000 && !sweep.complete && !sweep.cancelled;n++) [sweep advance:8 shouldContinue:^BOOL {return YES;}];
    ckcheck(sweep.complete && !sweep.cancelled,@"清理范围应完成");
}
static void ckpreflight(AxsCacheKeeperSweep *sweep) {
    for (NSUInteger n=0;n<10000 && sweep.checking && !sweep.complete;n++) [sweep advancePreflight:4];
    ckcheck(!sweep.checking && !sweep.complete && sweep.removed==0,@"预检完成且尚未删除");
}
static NSString *cksignature(NSString *bundle) {
    return [NSString stringWithFormat:@"instance-I:%lu",(unsigned long)[AxsCacheKeeperProcessObservation revisionForBundle:bundle]];
}
void axs_cachekeeper_run_review_followup_tests(NSString *fixture) {
    NSFileManager *fm=NSFileManager.defaultManager;
    NSString *home=ckdir(fixture,@"review-followup"), *bundle=@"test.review.followup";
    NSTimeInterval future=NSDate.date.timeIntervalSince1970+600;
    AxsCacheKeeperSweep *(^sweep)(NSString *,NSDictionary *,NSString *)=^AxsCacheKeeperSweep *(NSString *root,NSDictionary *state,NSString *version) {
        return [[AxsCacheKeeperSweep alloc] initWithRoot:root bundle:bundle version:version containerPath:home state:state clock:^NSTimeInterval {return future;}];
    };
    [AxsCacheKeeperCleanupRules removeAllRulesForTesting];

    // 名称保护不能过滤用户保留意图；真正执行父根清理，排除内容须逐个完整。
    NSArray *excluded=[@[@"Library/Caches/database",@"Library/Caches/sqlite",@"Library/Caches/realm",
        @"Library/Caches/state.json",@"Library/Caches/state.plist",@"Library/Caches/state.db"] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableDictionary *previous=[@{@"enabled":@YES,@"mode":@"auto",@"urlCache":@NO,@"autoDiscover":@NO,
        @"fullClear":@NO,@"excludedPaths":excluded} mutableCopy];
    NSMutableArray *payloads=[NSMutableArray new];
    for (NSString *relative in excluded) {
        NSString *path=[ckdir(home,relative) stringByAppendingPathComponent:@"unique"];
        ckput(path,@"must stay");[payloads addObject:path];
    }
    NSString *root=[home stringByAppendingPathComponent:@"Library/Caches"];
    NSString *ordinary=[root stringByAppendingPathComponent:@"ordinary"];ckput(ordinary,@"can go");
    NSDictionary *normalized=axs_cachekeeper_app_state(previous,YES);
    ckcheck([axs_cachekeeper_exclusions(normalized) isEqual:excluded] && !normalized[@"fullClear"],@"迁移保留格式词排除，移除旧 fullClear");
    AxsCacheKeeperSweep *excludedSweep=sweep(root,normalized,@"1.0");ckfinish(excludedSweep);
    ckcheck(excludedSweep.removed==1 && ![fm fileExistsAtPath:ordinary],@"独立缓存恰好删除一项");
    for (NSString *path in payloads) ckcheck([[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] isEqual:@"must stay"],@"已排除内容完整保留");
    ckcheck(axs_cachekeeper_exclusions(@{@"excludedPaths":@[@"../outside",@"/absolute",@"a//b"]}).count==0,@"越界/无效排除路径仍被拒绝");
    for (NSNumber *network in @[@NO,@YES]) {
        previous[@"urlCache"]=network;
        NSDictionary *current=previous;
        for (NSString *mode in @[@"clean",@"prevent",@"auto"]) {
            current=axs_cachekeeper_state_with_mode(current,mode);
            ckcheck([current[@"urlCache"] isEqual:network] && [current[@"mode"] isEqual:mode] &&
                ![current[@"autoDiscover"] boolValue] && [current[@"excludedPaths"] isEqual:excluded],@"模式往返保留网络、发现与排除选择");
        }
    }

    // 已确认必需例外在 APP 升级/版本缺失时继续保留，独立平台缓存仍能处理。
    [AxsCacheKeeperCleanupRules registerRule:[[AxsCacheKeeperAppRule alloc] initWithRuleID:@"preserve-business" revision:@"1" appVersion:@"1.0"
        cleanablePaths:@[@"Library/Resources"] retentionPaths:@[@"Library/Caches/business"] dependencyPaths:@[]] forBundle:bundle];
    NSString *business=[ckdir(home,@"Library/Caches/business") stringByAppendingPathComponent:@"record"];ckput(business,@"unique business");
    for (NSString *version in @[@"2.0",@""]) {
        AxsCacheKeeperCleanupDecision *decision=[AxsCacheKeeperCleanupRules decisionForBundle:bundle version:version relativePath:@"Library/Caches/business/record" state:@{} evidence:@{}];
        ckcheck(decision.disposition==AxsCacheKeeperCleanupKeep,@"版本失配不得撤销已确认保留");
    }
    ckput(ordinary,@"can go again");AxsCacheKeeperSweep *upgrade=sweep(root,normalized,@"2.0");ckfinish(upgrade);
    ckcheck(upgrade.removed==1 && [fm fileExistsAtPath:business],@"升级后保留业务例外且独立缓存被删");
    [AxsCacheKeeperCleanupRules removeAllRulesForTesting];

    // 完整目录依赖分批采集；后代原地变化、成员增删、不可读/链接均不能放行旧决定。
    NSString *dependencies=ckdir(home,@"Library/Index/deep");
    for (NSUInteger n=0;n<40;n++) ckput([dependencies stringByAppendingPathComponent:[NSString stringWithFormat:@"%lu",(unsigned long)n]],@"original");
    NSString *depRoot=dependencies.stringByDeletingLastPathComponent;
    AxsCacheKeeperDependencySnapshot *snapshot=[[AxsCacheKeeperDependencySnapshot alloc] initWithPath:depRoot];
    ckcheck([snapshot advance:3]==3 && !snapshot.complete,@"大集合采集遵守本批预算");
    for (NSUInteger n=0;n<1000 && !snapshot.complete;n++) [snapshot advance:3];
    ckcheck(snapshot.valid && snapshot.complete,@"依赖集合采集完整");
    [snapshot beginVerification];
    for (NSUInteger n=0;n<1000 && !snapshot.complete;n++) [snapshot advance:3];
    ckcheck(snapshot.valid,@"稳定集合复核通过");
    [snapshot beginVerification];NSUInteger verificationSteps=0;
    while (!snapshot.complete) { [snapshot advance:1];verificationSteps++; }
    NSString *resources=ckdir(home,@"Library/Resources");NSString *download=[resources stringByAppendingPathComponent:@"download"];
    ckput(download,@"resource");
    [AxsCacheKeeperCleanupRules registerRule:[[AxsCacheKeeperAppRule alloc] initWithRuleID:@"directory-dependency" revision:@"1" appVersion:@"1.0"
        cleanablePaths:@[@"Library/Resources"] retentionPaths:@[] dependencyPaths:@[@"Library/Index"]] forBundle:bundle];
    AxsCacheKeeperSweep *sameTurn=sweep(resources,@{},@"1.0");ckpreflight(sameTurn);
    for (NSUInteger n=0;n<verificationSteps;n++) [sameTurn advanceDeletion:1 shouldContinue:^BOOL {return YES;}];
    ckcheck(sameTurn.removed==1 && ![fm fileExistsAtPath:download],@"完整核验结束的同次推进处理候选，不跨周期复用");
    ckput(download,@"resource");
    AxsCacheKeeperSweep *stale=sweep(resources,@{},@"1.0");ckpreflight(stale);
    struct stat before,after;ckcheck(!lstat(depRoot.fileSystemRepresentation,&before),@"记录依赖根");
    ckput([dependencies stringByAppendingPathComponent:@"0"],@"changed in place and larger");
    ckcheck(!lstat(depRoot.fileSystemRepresentation,&after) && before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec &&
        before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec,@"后代改写不改变根目录时间戳");
    ckfinish(stale);
    ckcheck(stale.removed==0 && stale.changedCount==1 && stale.dependencyInvalidated && [fm fileExistsAtPath:download],@"后代变化否决旧删除计划");
    ckfinish(sweep(resources,@{},@"1.0"));ckcheck(![fm fileExistsAtPath:download],@"稳定后新轮实际回收");
    for (NSString *operation in @[@"add",@"remove",@"link"]) {
        AxsCacheKeeperDependencySnapshot *mutation=[[AxsCacheKeeperDependencySnapshot alloc] initWithPath:depRoot];
        while (!mutation.complete) [mutation advance:8];
        NSString *extra=[dependencies stringByAppendingPathComponent:operation];
        if ([operation isEqual:@"remove"]) ckcheck([fm removeItemAtPath:[dependencies stringByAppendingPathComponent:@"1"] error:nil],@"删除测试依赖成员");
        else if ([operation isEqual:@"link"]) ckcheck(!symlink("0",extra.fileSystemRepresentation),@"创建测试依赖链接");
        else ckput(extra,@"new member");
        [mutation beginVerification];while (!mutation.complete) [mutation advance:8];
        ckcheck(!mutation.valid,@"依赖成员增删和链接使集合失效");
    }
    [AxsCacheKeeperCleanupRules removeAllRulesForTesting];

    NSString *sharedRoot=ckdir(home,@"Library/SharedResources");
    NSString *firstRoot=ckdir(sharedRoot,@"A"),*secondRoot=ckdir(sharedRoot,@"B");
    ckput([firstRoot stringByAppendingPathComponent:@"x"],@"first");ckput([secondRoot stringByAppendingPathComponent:@"y"],@"second");
    [AxsCacheKeeperCleanupRules registerRule:[[AxsCacheKeeperAppRule alloc] initWithRuleID:@"shared-dependency" revision:@"1" appVersion:@"1.0"
        cleanablePaths:@[@"Library/SharedResources"] retentionPaths:@[] dependencyPaths:@[@"Library/SharedResources"]] forBundle:bundle];
    AxsCacheKeeperCleanupJob *sharedJob=[[AxsCacheKeeperCleanupJob alloc] initWithSweeps:@[sweep(firstRoot,@{},@"1.0"),sweep(secondRoot,@{},@"1.0")]
        signature:@"shared" instance:@"" clock:^NSTimeInterval {return 100;}];
    for (NSUInteger n=0;n<1000 && sharedJob.phase!=AxsCacheKeeperCleanupPhaseFinished;n++) [sharedJob advanceCycleWithPerRootLimit:4 gate:^BOOL {return YES;}];
    ckcheck(sharedJob.phase==AxsCacheKeeperCleanupPhaseFinished && sharedJob.removed==2 && sharedJob.changedCount==0 &&
        ![fm contentsOfDirectoryAtPath:firstRoot error:nil].count && ![fm contentsOfDirectoryAtPath:secondRoot error:nil].count,@"同轮自身删除推进所有范围的共同依赖，不使 sibling 误延期");
    [AxsCacheKeeperCleanupRules removeAllRulesForTesting];

    // 忙碌入口已看到同实例再次执行，之后直接终止也必须打断旧静默和未知登记。
    [AxsCacheKeeperProcessObservation invalidateAllBundles];
    [AxsCacheKeeperProcessObservation observeBundle:bundle state:AxsCacheKeeperExecExecuting identity:@"I" atMonotonicTime:1];
    [AxsCacheKeeperProcessObservation observeBundle:bundle state:AxsCacheKeeperExecSuspended identity:@"I" atMonotonicTime:2];
    NSString *oldSignature=cksignature(bundle);
    NSDictionary *done=@{@"signature":oldSignature,@"finishedAt":@100,@"endReason":@(AxsCacheKeeperCleanupEndReasonCompleted),@"coverageComplete":@YES};
    ckcheck([AxsCacheKeeperCleanupSchedule shouldSkipSummary:done signature:oldSignature now:101],@"干净静默生效");
    [AxsCacheKeeperProcessObservation observeBundle:bundle state:AxsCacheKeeperExecExecuting identity:@"I" atMonotonicTime:101];
    [AxsCacheKeeperProcessObservation observeBundle:bundle state:AxsCacheKeeperExecTerminated identity:nil atMonotonicTime:102];
    ckcheck([[AxsCacheKeeperProcessObservation lastExecutingIdentityForBundle:bundle] isEqual:@"I"] &&
        ![AxsCacheKeeperCleanupSchedule shouldSkipSummary:done signature:cksignature(bundle) now:103],@"同实例短暂活动打断干净静默");
    NSString *beforeRecheck=cksignature(bundle);[AxsCacheKeeperProcessObservation requestRecheckForBundle:bundle];
    ckcheck(![beforeRecheck isEqual:cksignature(bundle)],@"普通检测请求使旧登记签名失效");
    ckcheck(![AxsCacheKeeperCleanupSchedule shouldSkipSummary:done signature:oldSignature now:99] &&
        ![AxsCacheKeeperCleanupSchedule shouldSkipSummary:done signature:oldSignature now:1900],@"异常时钟与静默边界不继续跳过");
    ckcheck(![AxsCacheKeeperProcessObservation allowsSuspendedCleanupForBundle:bundle identity:@"I" atMonotonicTime:200],@"重检不绕过挂起门控");
    [AxsCacheKeeperProcessObservation observeBundle:bundle state:AxsCacheKeeperExecSuspended identity:@"I" atMonotonicTime:300];
    [AxsCacheKeeperProcessObservation requestRecheckForBundle:bundle];
    ckcheck(![AxsCacheKeeperProcessObservation allowsSuspendedCleanupForBundle:bundle identity:@"I" atMonotonicTime:359] &&
        [AxsCacheKeeperProcessObservation allowsSuspendedCleanupForBundle:bundle identity:@"I" atMonotonicTime:360],@"挂起期间重检仍需满60秒且不改变真实挂起起点");

    // 孪生搜索真实推进到注入上限；单条 lstat 失败时零匹配也必须覆盖不完整。
    NSString *source=ckdir(home,@"twins-source"),*search=ckdir(home,@"twins-search");
    NSString *sourceFile=[source stringByAppendingPathComponent:@"one"];ckput(sourceFile,@"linked");
    ckcheck(!link(sourceFile.fileSystemRepresentation,[[search stringByAppendingPathComponent:@"twin"] fileSystemRepresentation]),@"创建孪生硬链接");
    for (NSUInteger n=0;n<6;n++) ckput([search stringByAppendingPathComponent:[NSString stringWithFormat:@"other%lu",(unsigned long)n]],@"ordinary");
    NSArray *searchRoots=@[@{@"path":search,@"label":@"别处"}];
    AxsCacheKeeperInspection *limited=[[AxsCacheKeeperInspection alloc] initWithRoot:source searchRoots:searchRoots searchLimit:3 stat:^int(const char *p,struct stat *info) {return lstat(p,info);}];
    for (NSUInteger n=0;n<100 && !limited.complete;n++) [limited advance:2];
    NSDictionary *limitedReport=[limited report];
    ckcheck(limited.complete && [limitedReport[@"twinScanned"] unsignedIntegerValue]==3 &&
        [limitedReport[@"twinScanTruncated"] boolValue] && ![limitedReport[@"twinCoverageComplete"] boolValue],@"搜索预算精确触顶并报告截断");
    AxsCacheKeeperInspection *failed=[[AxsCacheKeeperInspection alloc] initWithRoot:source searchRoots:searchRoots searchLimit:100000 stat:^int(const char *p,struct stat *info) {
        if ([[[NSString stringWithUTF8String:p] lastPathComponent] isEqual:@"twin"]) {errno=EIO;return -1;}return lstat(p,info);
    }];
    for (NSUInteger n=0;n<100 && !failed.complete;n++) [failed advance:2];
    NSDictionary *failedReport=[failed report];
    ckcheck(failed.complete && [failedReport[@"twinFailures"] unsignedIntegerValue]==1 && [failedReport[@"linkTwins"] count]==0 &&
        ![failedReport[@"twinCoverageComplete"] boolValue] && ![failedReport[@"twinScanTruncated"] boolValue],@"零匹配的搜索读取失败与截断分开报告");
    puts("PASS: review followup: exclusions, mode preservation, activity/recheck, dependency collections, upgrade retention and twin boundaries");
}
