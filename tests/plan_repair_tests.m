#import <Foundation/Foundation.h>
#import "../AxsCacheKeeperSweep.h"
#import "../AxsCacheKeeperCleanupJob.h"
#import "../AxsCacheKeeperCleanupRules.h"
#import "../AxsCacheKeeperCleanupSchedule.h"
#import "../AxsCacheKeeperReceipts.h"
#import "../AxsCacheKeeperInspection.h"
#import "../AxsCacheKeeperPolicy.h"
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

static void check(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr,"FAIL: plan repair: %s\n",message.UTF8String); exit(1); }
}
static NSString *makeDir(NSString *home, NSString *relative) {
    NSString *path=[home stringByAppendingPathComponent:relative];
    check([NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil],@"创建目录");
    return path;
}
static void put(NSString *path) {
    check([@"cache payload" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil],@"创建文件");
}
static void finish(AxsCacheKeeperSweep *sweep) {
    for (NSUInteger cycle=0;!sweep.complete && !sweep.cancelled && cycle<1000;cycle++) [sweep advance:16 shouldContinue:^BOOL { return YES; }];
    check(sweep.complete,@"根清理应收尾");
}
static BOOL submit(NSString *bundle, NSString *round, NSUInteger removed, BOOL done) {
    return [AxsCacheKeeperReceipts submitRoundForBundle:bundle roundID:round removed:removed bytes:removed*10
        endReason:done ? AxsCacheKeeperCleanupEndReasonCancelled : 0 phase:done ? @"waiting" : @"cleaning"
        message:@"测试回执" failed:0 effectivePaths:@[] discoveredPaths:nil directories:nil
        round:done ? @{@"removed":@(removed),@"bytes":@(removed*10)} : nil coverageComplete:YES];
}

void axs_cachekeeper_run_plan_repair_tests(NSString *fixture) {
    NSFileManager *fm=NSFileManager.defaultManager;
    NSString *home=makeDir(fixture,@"plan-repairs");
    NSString *bundle=@"test.plan.repair";
    NSTimeInterval future=NSDate.date.timeIntervalSince1970+600;
    AxsCacheKeeperSweep *(^sweepFor)(NSString *,NSDictionary *)=^AxsCacheKeeperSweep *(NSString *root,NSDictionary *state) {
        return [[AxsCacheKeeperSweep alloc] initWithRoot:root bundle:bundle version:@"1.0" containerPath:home state:state clock:^NSTimeInterval { return future; }];
    };
    [AxsCacheKeeperCleanupRules removeAllRulesForTesting];

    // 生产入口须能回收已确认的 ALog，而非只有测试注册规则能删除。
    // 任何按目录全删、版本泛化、挂起放行或取消内容否决都会破坏本组断言。
    {
    NSString *alogBundle=@"com.ss.iphone.ugc.Aweme";
    NSString *alogVersion=@"41.1.0";
    NSDictionary *exited=@{@"processExited":@YES};
    NSDictionary *clearLog=@{@"readComplete":@YES,@"hasEvidence":@NO,@"hasMediaSignature":@NO};
    NSString *alogPath=@"Library/alog/ready/BDALog_20261111_193314.alog.iOS.1128";
    AxsCacheKeeperCleanupDecision *alogDecision=[AxsCacheKeeperCleanupRules decisionForBundle:alogBundle version:alogVersion relativePath:alogPath state:exited evidence:clearLog];
    check(alogDecision.disposition==AxsCacheKeeperCleanupDelete && alogDecision.basis==AxsCacheKeeperCleanupBasisAppRule,
        @"内置抖音规则应识别已退出进程的 ALog 日志，不能仍全部待识别");
    for (NSString *otherVersion in @[@"",@"41.1.1",@"41.1.0.1"])
        check([AxsCacheKeeperCleanupRules decisionForBundle:alogBundle version:otherVersion relativePath:alogPath state:exited evidence:clearLog].disposition!=AxsCacheKeeperCleanupDelete,@"未验版本不继承 ALog 删除授权");
    check([AxsCacheKeeperCleanupRules decisionForBundle:@"com.example.other" version:alogVersion relativePath:alogPath state:exited evidence:clearLog].disposition!=AxsCacheKeeperCleanupDelete,@"同名目录不跨 APP 放行");
    for (NSString *wrongPath in @[@"Library/alog/ready/notes.txt",@"Library/alog/ready/app.log",@"Library/alog/ready/BDALog_broken.alog.iOS.1128",
        @"Library/alog/ready/BDALog_20261111_193314.alog.iOS.1128.pdf",@"Library/alog/ready/BDALog_20261111_193314.alog.iOS.1128\n",
        @"Library/alog/drafts/BDALog_20261111_193314.alog.iOS.1128",@"Library/alog-other/ready/BDALog_20261111_193314.alog.iOS.1128"])
        check([AxsCacheKeeperCleanupRules decisionForBundle:alogBundle version:alogVersion relativePath:wrongPath state:exited evidence:clearLog].disposition!=AxsCacheKeeperCleanupDelete,@"未知文件、额外后缀与邻近/保留路径不放行");
    for (NSDictionary *veto in @[@{@"readComplete":@NO},@{@"readComplete":@YES,@"hasEvidence":@YES},@{@"readComplete":@YES,@"hasMediaSignature":@YES},@{}])
        check([AxsCacheKeeperCleanupRules decisionForBundle:alogBundle version:alogVersion relativePath:alogPath state:exited evidence:veto].disposition!=AxsCacheKeeperCleanupDelete,@"读取或用途证据不齐不能当日志删除");
    for (NSDictionary *state in @[@{},@{@"processExited":@NO},@{@"processExited":@NO,@"logPaths":@[@"Library/alog"]},@{@"processExited":@YES,@"excludedPaths":@[@"Library/alog/ready"]}])
        check([AxsCacheKeeperCleanupRules decisionForBundle:alogBundle version:alogVersion relativePath:alogPath state:state evidence:clearLog].disposition!=AxsCacheKeeperCleanupDelete,@"挂起/未知进程与用户排除保持保留");

    NSString *alogRoot=makeDir(home,@"Library/alog");
    makeDir(home,@"Library/alog/ready");
    NSString *readyLog=[home stringByAppendingPathComponent:alogPath];
    put(readyLog);
    NSString *unknown=[alogRoot stringByAppendingPathComponent:@"ready/notes.txt"];put(unknown);
    NSString *database=[alogRoot stringByAppendingPathComponent:@"ready/BDALog_20261111_193315.alog.iOS.1128"];
    check([@"SQLite format 3\0payload" writeToFile:database atomically:YES encoding:NSUTF8StringEncoding error:nil],@"写伪装日志的数据库");
    NSString *media=[alogRoot stringByAppendingPathComponent:@"ready/BDALog_20261111_193316.alog.iOS.1128"];
    const unsigned char png[]={0x89,'P','N','G',13,10,26,10,0,0,0,0};
    check([[NSData dataWithBytes:png length:sizeof(png)] writeToFile:media atomically:YES],@"写伪装日志的媒体");
    NSString *shared=[alogRoot stringByAppendingPathComponent:@"ready/BDALog_20261111_193317.alog.iOS.1128"];put(shared);
    NSString *outside=[home stringByAppendingPathComponent:@"shared-original"];check(link(shared.fileSystemRepresentation,outside.fileSystemRepresentation)==0,@"创建日志硬链接对照");
    AxsCacheKeeperSweep *alogRecent=[[AxsCacheKeeperSweep alloc] initWithRoot:alogRoot bundle:alogBundle version:alogVersion containerPath:home state:exited];finish(alogRecent);
    check(alogRecent.removed==0 && alogRecent.recentCount>=1 && [fm fileExistsAtPath:readyLog],@"新日志仍遵守年龄门");
    AxsCacheKeeperSweep *alogSuspended=[[AxsCacheKeeperSweep alloc] initWithRoot:alogRoot bundle:alogBundle version:alogVersion containerPath:home state:@{@"processExited":@NO,@"logPaths":@[@"Library/alog"]} clock:^NSTimeInterval{return future;}];finish(alogSuspended);
    check(alogSuspended.removed==0 && [fm fileExistsAtPath:readyLog],@"用户日志定级不能绕过专属日志的进程退出约束");
    NSDictionary *alogWait=[AxsCacheKeeperCleanupSchedule registrationForSweep:alogSuspended signature:@"alog-wait" now:10];
    check([alogWait[@"appRuleWaitingForExit"] boolValue] && [[AxsCacheKeeperCleanupSchedule carriedReport:alogWait][@"appRuleID"] isEqual:@"douyin-alog"],@"等待退出的规则说明在结转回执中保持可诊断");
    AxsCacheKeeperSweep *alogReal=[[AxsCacheKeeperSweep alloc] initWithRoot:alogRoot bundle:alogBundle version:alogVersion containerPath:home state:exited clock:^NSTimeInterval{return future;}];finish(alogReal);
    check(alogReal.removed==1 && alogReal.bytes==13 && ![fm fileExistsAtPath:readyLog],@"成熟日志真实删除且回执等于实际删量");
    for (NSString *kept in @[unknown,database,media,shared,outside]) check([fm fileExistsAtPath:kept],@"同目录未知、数据库、媒体与根外硬链接保持完整");
    put(readyLog);
    AxsCacheKeeperSweep *alogAgain=[[AxsCacheKeeperSweep alloc] initWithRoot:alogRoot bundle:alogBundle version:alogVersion containerPath:home state:exited clock:^NSTimeInterval{return future;}];finish(alogAgain);
    check(alogAgain.removed==1 && ![fm fileExistsAtPath:readyLog],@"第二轮新产生日志成熟后仍实际回收");
    }

    // 根在范围检查后消失时，失败对象仍须有稳定报告键，不能让调度器以 nil 作字典键。
    AxsCacheKeeperSweep *missingRoot=sweepFor([home stringByAppendingPathComponent:@"Library/Caches/disappeared"],@{});
    check(missingRoot.complete && missingRoot.failed==1 && [missingRoot.relativePath isEqual:@"Library/Caches/disappeared"],@"构造失败仍保留目录标识");
    NSDictionary *missingReport=@{missingRoot.relativePath:[missingRoot directoryReport]};
    check(![missingReport[@"Library/Caches/disappeared"][@"measurementComplete"] boolValue],@"缺失根报告失败且不伪造测量结果");

    // 精确资源规则不得放开必要状态父树；平台内同样保留依赖和唯一副本。
    NSString *root=makeDir(home,@"Library/Caches");
    NSString *resource=makeDir(home,@"Library/Caches/offline/cache");
    NSString *unique=[root stringByAppendingPathComponent:@"offline/unique.bin"];
    NSString *index=[root stringByAppendingPathComponent:@"offline/index.json"];
    put(unique); put(index); put([resource stringByAppendingPathComponent:@"download"]);
    put([root stringByAppendingPathComponent:@"ordinary"]);
    NSString *draft=makeDir(home,@"Library/Caches/drafts"); put([draft stringByAppendingPathComponent:@"unsent"]);
    [AxsCacheKeeperCleanupRules registerRule:[[AxsCacheKeeperAppRule alloc] initWithRuleID:@"fixture-offline" revision:@"1" appVersion:@"1.0"
        cleanablePaths:@[@"Library/Caches/offline/cache"] retentionPaths:@[] dependencyPaths:@[@"Library/Caches/offline/index.json"]] forBundle:bundle];
    AxsCacheKeeperSweep *scoped=sweepFor(root,@{}); finish(scoped);
    check(scoped.removed==2 && [fm fileExistsAtPath:unique] && [fm fileExistsAtPath:index] && [fm fileExistsAtPath:[draft stringByAppendingPathComponent:@"unsent"]],@"资源和普通缓存删除，父树唯一副本、索引与草稿完整");
    put([resource stringByAppendingPathComponent:@"stale"]);
    AxsCacheKeeperSweep *dependency=sweepFor(resource,@{});
    while (dependency.checking && !dependency.complete) [dependency advancePreflight:8];
    put(index); finish(dependency);
    check(dependency.removed==0 && dependency.changedCount==1 && dependency.dependencyInvalidated,@"平台内 APP 规则的索引变化仍否决删除");
    AxsCacheKeeperSweep *retry=sweepFor(resource,@{}); finish(retry); check(retry.removed==1,@"依赖稳定后下轮恢复删除");
    [AxsCacheKeeperCleanupRules removeAllRulesForTesting];

    // 枚举和决策都分批；第一批报告不制造残留零值。
    NSString *batchRoot=makeDir(home,@"Library/Caches/batched");
    for (NSUInteger i=0;i<20;i++) put([batchRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"%lu.bin",(unsigned long)i]]);
    AxsCacheKeeperSweep *batch=sweepFor(batchRoot,@{});
    [batch advancePreflight:4]; NSDictionary *partial=[batch directoryReport];
    check(batch.inspected==4 && batch.checking && !partial[@"remaining"] && !partial[@"unresolved"] && ![partial[@"measurementComplete"] boolValue],@"预检未测完时残留未知");
    while (batch.inspected<20) [batch advancePreflight:4];
    [batch advancePreflight:4];
    check(batch.checking && batch.remainingCandidates<=4 && batch.removed==0,@"枚举结束不能无界决策全树");
    finish(batch); check(batch.removed==20 && batch.remainingCandidates==0,@"分批预检最终处理全部候选");

    // 读取失败真实报错、短重试；恢复访问后实际删除。
    NSString *readRoot=makeDir(home,@"Library/Caches/read-retry"); NSString *secret=[readRoot stringByAppendingPathComponent:@"secret"];
    put(secret); check(!chmod(secret.fileSystemRepresentation,0000),@"禁止读取夹具");
    AxsCacheKeeperSweep *readFailure=sweepFor(readRoot,@{}); finish(readFailure);
    check(readFailure.failed==1 && readFailure.deferredCount==1 && !readFailure.coverageComplete && [fm fileExistsAtPath:secret],@"读取失败不冒充正常保留");
    check(!chmod(secret.fileSystemRepresentation,0644),@"恢复读取夹具");
    AxsCacheKeeperSweep *readRetry=sweepFor(readRoot,@{}); finish(readRetry); check(readRetry.removed==1,@"访问恢复后正向删除");

    // 未知与近期日志混放：不能登记跳过整根；时间成熟后须真正删除日志。
    NSString *mixed=makeDir(home,@"Library/diagnostics"); put([mixed stringByAppendingPathComponent:@"ordinary.log"]); put([mixed stringByAppendingPathComponent:@"opaque"]);
    NSDictionary *logs=@{@"logPaths":@[@"Library/diagnostics"]};
    AxsCacheKeeperSweep *recent=[[AxsCacheKeeperSweep alloc] initWithRoot:mixed bundle:bundle version:@"1.0" containerPath:home state:logs]; finish(recent);
    check(recent.unresolvedCount==1 && recent.recentCount==1 && ![AxsCacheKeeperCleanupSchedule registrationForSweep:recent signature:@"mix" now:10],@"混合近期根不登记为纯未知");
    AxsCacheKeeperSweep *mature=sweepFor(mixed,logs); finish(mature);
    check(mature.removed==1 && mature.unresolvedCount==1 && ![fm fileExistsAtPath:[mixed stringByAppendingPathComponent:@"ordinary.log"]],@"近期日志成熟后下轮删除");
    NSDictionary *registration=[AxsCacheKeeperCleanupSchedule registrationForSweep:mature signature:@"mix" now:10];
    check(registration!=nil,@"纯未知范围可登记");
    check([AxsCacheKeeperCleanupSchedule checkRoot:mixed registration:registration signature:@"mix" now:20 stat:nil error:nil]==AxsCacheKeeperRangeUnchanged,@"纯未知稳定范围沿用");
    for (NSNumber *code in @[@EACCES,@EIO,@ENOENT]) {
        NSString *error=nil;
        AxsCacheKeeperRangeState result=[AxsCacheKeeperCleanupSchedule checkRoot:mixed registration:registration signature:@"mix" now:20 stat:^int(const char *path,struct stat *info) {
            (void)path; (void)info; errno=code.intValue; return -1;
        } error:&error];
        check(result==(code.intValue==ENOENT ? AxsCacheKeeperRangeMissing : AxsCacheKeeperRangeFailed),@"lstat 故障不读未初始化输出或命中稳定跳过");
        check(code.intValue==ENOENT || error.length,@"不可访问错误可展示");
    }
    check([AxsCacheKeeperCleanupSchedule checkRoot:mixed registration:registration signature:@"new-rule" now:20 stat:nil error:nil]==AxsCacheKeeperRangeScan &&
        [AxsCacheKeeperCleanupSchedule checkRoot:mixed registration:registration signature:@"mix" now:1810 stat:nil error:nil]==AxsCacheKeeperRangeScan,@"规则变化或登记到期重新分析后代");
    AxsCacheKeeperCleanupJob *empty=[[AxsCacheKeeperCleanupJob alloc] initWithSweeps:@[] signature:@"empty" instance:@"" clock:^NSTimeInterval { return 1; }];
    [empty advanceCycleWithPerRootLimit:4 gate:^BOOL { return YES; }];
    NSDictionary *carried=[AxsCacheKeeperCleanupSchedule carriedReport:registration];
    NSDictionary *summary=[AxsCacheKeeperCleanupSchedule summaryForJob:empty directories:@{@"Library/diagnostics":carried} externalFailures:0 discoveryComplete:YES];
    check([summary[@"endReason"] integerValue]==AxsCacheKeeperCleanupEndReasonUnresolved && [summary[@"unresolved"] unsignedIntegerValue]==1 &&
        [AxsCacheKeeperCleanupSchedule quietIntervalForSummary:summary]==30,@"全部结转未知仍为部分完成，不进入干净静默");

    // 身份/年龄核验中跨期限：首文件成功，下一文件核验时到期，实际 unlink 不得开始。
    NSString *boundaryRoot=makeDir(home,@"Library/Caches/boundary"); put([boundaryRoot stringByAppendingPathComponent:@"one"]); put([boundaryRoot stringByAppendingPathComponent:@"two"]);
    __block NSTimeInterval monotonic=1000; __block NSUInteger unlinks=0, ageReadsAfterFirst=0;
    AxsCacheKeeperSweep *boundary=[[AxsCacheKeeperSweep alloc] initWithRoot:boundaryRoot bundle:bundle version:@"1.0" containerPath:home state:@{} clock:^NSTimeInterval {
        if (unlinks && ++ageReadsAfterFirst==2) monotonic=1120; // 第二文件 open/fstat 之后的年龄复核
        return future;
    } unlinkFile:^int(int fd,const char *name) {
        check(monotonic<1120,@"不得在到期后开始 unlink"); int result=unlinkat(fd,name,0); if (!result) unlinks++; return result;
    }];
    AxsCacheKeeperCleanupJob *boundaryJob=[[AxsCacheKeeperCleanupJob alloc] initWithSweeps:@[boundary] signature:@"boundary" instance:@"" clock:^NSTimeInterval { return monotonic; }];
    for (NSUInteger i=0;boundaryJob.phase!=AxsCacheKeeperCleanupPhaseFinished && i<100;i++) [boundaryJob advanceCycleWithPerRootLimit:16 gate:^BOOL { return YES; }];
    check(boundaryJob.endReason==AxsCacheKeeperCleanupEndReasonLimitReached && boundaryJob.removed==1 && unlinks==1 && boundary.remainingCandidates==1 && [fm contentsOfDirectoryAtPath:boundaryRoot error:nil].count==1,@"核验跨期限后剩余文件完整且计数未丢");

    // 权限恢复失败只排除该路径；独立 sibling 与 tmp 仍可删。
    NSString *restoreRoot=makeDir(home,@"Library/Caches/restore"); NSString *blocked=makeDir(home,@"Library/Caches/restore/blocked");
    NSString *blockedFile=[blocked stringByAppendingPathComponent:@"keep"]; put(blockedFile); put([restoreRoot stringByAppendingPathComponent:@"good"]);
    NSString *tmpRoot=makeDir(home,@"tmp"); put([tmpRoot stringByAppendingPathComponent:@"good"]);
    NSArray *exclusions=[AxsCacheKeeperCleanupSchedule restoreExclusions:@{@"failedPaths":@[blocked]} home:home];
    AxsCacheKeeperSweep *restoreSweep=sweepFor(restoreRoot,@{@"unavailablePaths":exclusions}); finish(restoreSweep);
    AxsCacheKeeperSweep *tmpSweep=sweepFor(tmpRoot,@{}); finish(tmpSweep);
    check(restoreSweep.removed==1 && tmpSweep.removed==1 && [fm fileExistsAtPath:blockedFile],@"恢复失败子树隔离、独立范围继续");
    NSString *locked=makeDir(home,@"locked"); NSString *shared=[locked stringByAppendingPathComponent:@"data"]; put(shared);
    NSString *journal=[home stringByAppendingPathComponent:@"permissions.plist"];
    check([axs_cachekeeper_lock_paths(@[locked],journal)[@"failed"] unsignedIntegerValue]==0,@"旧锁夹具");
    NSString *outside=[home stringByAppendingPathComponent:@"outside-link"];
    check(!link(shared.fileSystemRepresentation,outside.fileSystemRepresentation),@"上锁后新增根外硬链接");
    NSDictionary *restore=axs_cachekeeper_restore_paths(nil,journal); struct stat mode;
    check([restore[@"failedPaths"] containsObject:shared] && !lstat(outside.fileSystemRepresentation,&mode) && !(mode.st_mode&0222),@"共享 inode 权限不被恢复操作连带修改");
    check(!unlink(outside.fileSystemRepresentation),@"移除夹具外部链接");
    check([axs_cachekeeper_restore_paths(nil,journal)[@"failed"] unsignedIntegerValue]==0,@"恢复单链接后旧权限可恢复");
    put(journal); NSDictionary *broken=axs_cachekeeper_restore_paths(nil,journal);
    NSDictionary *brokenSummary=[AxsCacheKeeperCleanupSchedule summaryForJob:empty directories:@{} externalFailures:[broken[@"unlocatedFailures"] unsignedIntegerValue] discoveryComplete:YES];
    check([brokenSummary[@"failed"] unsignedIntegerValue]==1 && ![brokenSummary[@"coverageComplete"] boolValue],@"不可定位 journal 错误仍进入可见报告");

    // 孪生源扫描失败不能标成搜索完整。
    AxsCacheKeeperInspection *missing=[[AxsCacheKeeperInspection alloc] initWithRoot:[home stringByAppendingPathComponent:@"missing"] searchRoots:@[]];
    for (NSUInteger i=0;!missing.complete && i<10;i++) [missing advance:8];
    check(![[missing report][@"twinCoverageComplete"] boolValue],@"主扫描失败使孪生源覆盖不完整");

    // 同轮乱序：正常写入与写失败积压都不能把 150 降回 100 后重复/少记。
    NSString *status=makeDir(home,@"Status"); NSString *receiptPath=[status stringByAppendingPathComponent:[bundle stringByAppendingString:@".auto.plist"]];
    [AxsCacheKeeperReceipts resetForTesting]; [AxsCacheKeeperReceipts configureWithStatusFolder:status];
    NSString *legacyBundle=@"test.receipt.legacy";
    NSString *legacyPath=[status stringByAppendingPathComponent:[legacyBundle stringByAppendingString:@".auto.plist"]];
    check([@{@"confirmedRoundID":@"legacy",@"confirmedRemoved":@100,@"confirmedBytes":@1000,
        @"removed":@100,@"bytes":@1000,@"confirmedFinished":@{}} writeToFile:legacyPath atomically:YES],@"旧回执多余字段异常夹具");
    check(submit(legacyBundle,@"legacy",101,NO) && [[NSDictionary dictionaryWithContentsOfFile:legacyPath][@"removed"] unsignedIntegerValue]==101,@"无用途的旧字段不参与回执处理，累计仍精确");
    check(submit(bundle,@"r1",150,NO) && submit(bundle,@"r1",100,NO) && submit(bundle,@"r1",150,YES),@"正常乱序提交");
    check([[NSDictionary dictionaryWithContentsOfFile:receiptPath][@"removed"] unsignedIntegerValue]==150,@"150→100→150 累计恰好 150");
    check([fm removeItemAtPath:receiptPath error:nil],@"重置夹具回执");
    check(!chmod(status.fileSystemRepresentation,0500),@"模拟写失败");
    check(!submit(bundle,@"r2",150,YES) && !submit(bundle,@"r2",100,NO),@"写失败积压乱序");
    check(!chmod(status.fileSystemRepresentation,0700),@"恢复存储");
    [AxsCacheKeeperReceipts flushAllPending];
    NSDictionary *saved=[NSDictionary dictionaryWithContentsOfFile:receiptPath];
    check([saved[@"removed"] unsignedIntegerValue]==150 && [saved[@"lastRemoved"] unsignedIntegerValue]==150 && ![AxsCacheKeeperReceipts hasPendingForBundle:bundle],@"停用后无需清理资格即可补记终态 150");

    // 作业取消结算也走生产 helper，写失败、停用、恢复后累计精确。
    NSString *cancelRoot=makeDir(home,@"Library/Caches/retire"); put([cancelRoot stringByAppendingPathComponent:@"a"]); put([cancelRoot stringByAppendingPathComponent:@"b"]);
    AxsCacheKeeperSweep *cancelSweep=sweepFor(cancelRoot,@{});
    AxsCacheKeeperCleanupJob *cancelJob=[[AxsCacheKeeperCleanupJob alloc] initWithSweeps:@[cancelSweep] signature:@"retire" instance:@"" clock:^NSTimeInterval { return 100; }];
    while (cancelJob.phase==AxsCacheKeeperCleanupPhaseChecking) [cancelJob advanceCycleWithPerRootLimit:16 gate:^BOOL { return YES; }];
    [cancelJob advanceCycleWithPerRootLimit:1 gate:^BOOL { return YES; }]; check(cancelJob.removed==1,@"取消前真实删 1 项");
    check(!chmod(status.fileSystemRepresentation,0500),@"取消写失败");
    check(![AxsCacheKeeperCleanupSchedule retireJob:cancelJob bundle:bundle message:@"停用"],@"取消终态等待保存");
    check(!chmod(status.fileSystemRepresentation,0700),@"取消存储恢复"); [AxsCacheKeeperReceipts flushAllPending];
    saved=[NSDictionary dictionaryWithContentsOfFile:receiptPath];
    check([saved[@"removed"] unsignedIntegerValue]==151 && [saved[@"lastRemoved"] unsignedIntegerValue]==1 && [saved[@"endReason"] integerValue]==AxsCacheKeeperCleanupEndReasonCancelled,@"取消后补记精确累计与终态");
    [AxsCacheKeeperReceipts resetForTesting];
    puts("PASS: plan repairs: delete boundary, bounded preflight, exact scope, scheduling, residuals, receipts, restore and coverage");
}
