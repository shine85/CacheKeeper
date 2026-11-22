#import <Foundation/Foundation.h>
#import "../AxsCacheKeeperReceipts.h"
#import "../AxsCacheKeeperReleaseEvidenceStatus.h"
#import "../AxsCacheKeeperCleanupHistory.h"
#import "../AxsCacheKeeperPolicy.h"
#import "../AxsCacheKeeperPresentation.h"
#include <sys/stat.h>

static void ck_release_check(BOOL value, NSString *message) {
    if (!value) { fprintf(stderr,"FAIL: release receipt: %s\n",message.UTF8String); exit(1); }
}
static NSDictionary *ck_release_sample(NSUInteger revision, NSString *state) {
    return @{@"schemaVersion":@1,@"roundID":@"A0274912-2134-4AD8-8E0A-C91B9DCB104F",@"revision":@(revision),@"state":state,
        @"attempts":@1,@"succeeded":@1,@"failed":@0,@"postMissing":@0,@"detailsOmitted":@0,@"identitiesOmitted":@0,
        @"volumesOmitted":@0,@"overflow":@NO,@"uniqueExtents":@"notMeasured",@"reclaimedPhysicalBytes":@"notMeasured",@"volumes":@[],
        @"details":@[@{@"attemptID":@1,@"rootID":@1,@"objectID":@1,@"kind":@"ordinary",@"result":@0,@"errno":@0,
            @"pre":@{@"state":@"observed",@"errno":@0,@"size":@12,@"blocks":@8,@"nlink":@1},
            @"post":@{@"state":@"observed",@"errno":@0,@"size":@12,@"blocks":@8,@"nlink":@0},
            @"identityMatch":@"same",@"linkTransition":@"decremented"}]};
}
static BOOL ck_release_submit(NSString *bundle, NSDictionary *evidence) {
    return [AxsCacheKeeperReceipts submitRoundForBundle:bundle roundID:evidence[@"roundID"] removed:1 bytes:12
        endReason:0 phase:@"cleaning" message:@"测试" failed:0 effectivePaths:@[] discoveredPaths:nil directories:nil
        round:nil coverageComplete:YES releaseEvidence:evidence];
}
static NSDictionary *ck_cleanup_context(NSString *mode, NSString *version) {
    return axs_cachekeeper_cleanup_context(mode,YES,YES,NO,YES,@"0.7.2-188.1",version,@"110",@"platform-cache:2;test.app:test-rule:1",@[@"Library/Caches"],@[],@[]);
}
static BOOL ck_cleanup_submit(NSString *bundle, NSString *roundID, NSUInteger removed, NSUInteger reason,
    NSUInteger failed, NSDictionary *context) {
    return [AxsCacheKeeperReceipts submitRoundForBundle:bundle roundID:roundID removed:removed bytes:removed*12
        endReason:reason phase:reason ? @"complete" : @"cleaning" message:@"测试清理历史" failed:failed
        effectivePaths:@[@"Library/Caches/private-canary"] discoveredPaths:nil directories:@{@"private-directory-canary":@{}}
        round:reason ? @{@"removed":@(removed),@"bytes":@(removed*12)} : nil coverageComplete:!failed
        releaseEvidence:nil cleanupContext:context];
}
static NSDictionary *ck_cleanup_read(NSString *folder, NSString *bundle) {
    return [NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:[bundle stringByAppendingString:@".auto.plist"]]];
}
int main(int argc, const char **argv) { @autoreleasepool {
    ck_release_check(argc==2,@"fixture argument");
    NSString *folder=[NSString stringWithUTF8String:argv[1]];
    ck_release_check([NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil],@"fixture directory");
    NSDictionary *running=ck_release_sample(1,@"recording"), *finished=ck_release_sample(2,@"finished");
    ck_release_check([axs_cachekeeper_release_evidence_projection(running,nil) isEqual:running],@"literal ordinary unlink evidence is accepted");
    ck_release_check(!axs_cachekeeper_release_evidence_projection(running,@"wrong-round"),@"evidence cannot cross cleanup rounds");
    NSMutableDictionary *bad=[running mutableCopy];bad[@"privatePath"]=@"secret-canary";
    ck_release_check(!axs_cachekeeper_release_evidence_projection(bad,nil),@"unknown root fields are rejected");
    bad=[running mutableCopy];NSMutableDictionary *detail=[running[@"details"][0] mutableCopy];detail[@"inode"]=@123;
    bad[@"details"]=@[detail];ck_release_check(!axs_cachekeeper_release_evidence_projection(bad,nil),@"raw identity fields are rejected");
    bad=[running mutableCopy];bad[@"succeeded"]=@0;
    ck_release_check(!axs_cachekeeper_release_evidence_projection(bad,nil),@"contradictory totals are rejected");
    bad=[running mutableCopy];bad[@"attempts"]=@YES;
    ck_release_check(!axs_cachekeeper_release_evidence_projection(bad,nil),@"boolean counters are rejected");
    bad=[running mutableCopy];bad[@"reclaimedPhysicalBytes"]=@4096;
    ck_release_check(!axs_cachekeeper_release_evidence_projection(bad,nil),@"observations never certify physical release");
    bad=[running mutableCopy];detail=[running[@"details"][0] mutableCopy];
    detail[@"post"]=@{@"state":@"invalidMetadata",@"errno":@0};detail[@"identityMatch"]=@"notObserved";detail[@"linkTransition"]=@"notObserved";
    bad[@"details"]=@[detail];bad[@"postMissing"]=@1;
    ck_release_check(axs_cachekeeper_release_evidence_projection(bad,nil)!=nil,@"invalid metadata stays explicit without manufactured errno");
    NSMutableDictionary *volume=[@{@"volumeID":@1,@"state":@"observed",@"closeErrno":@0,
        @"before":@{@"state":@"observed",@"errno":@0,@"blockSize":@4096,@"freeBlocks":@100,@"availableBlocks":@80,@"uptime":@10},
        @"after":@{@"state":@"observed",@"errno":@0,@"blockSize":@4096,@"freeBlocks":@98,@"availableBlocks":@81,@"uptime":@13},
        @"freeBytesDelta":@(-8192),@"availableBytesDelta":@4096,@"elapsedSeconds":@3} mutableCopy];
    bad=[finished mutableCopy];bad[@"volumes"]=@[volume];
    ck_release_check(axs_cachekeeper_release_evidence_projection(bad,nil)!=nil,@"negative and positive volume deltas survive unchanged");
    NSString *volumeText=axs_cachekeeper_presentation_release_evidence(bad);
    ck_release_check([volumeText containsString:@"空闲空间变化 -8192 B"] && [volumeText containsString:@"可用空间变化 +4096 B"] &&
        [volumeText containsString:@"观察间隔 3.000 秒"] && [volumeText containsString:@"不能归为本次释放"],@"actual signed volume changes and time are visible without attribution");
    ck_release_check([volumeText containsString:@"最后一个链接消失 1 次"] && [volumeText containsString:@"仍有链接 0 次"],@"last-link evidence is visible without claiming released blocks");
    NSMutableDictionary *zeroVolume=[volume mutableCopy];zeroVolume[@"after"]=volume[@"before"];zeroVolume[@"elapsedSeconds"]=@0;
    zeroVolume[@"freeBytesDelta"]=@0;zeroVolume[@"availableBytesDelta"]=@0;
    NSMutableDictionary *zero=[finished mutableCopy];zero[@"volumes"]=@[zeroVolume];
    ck_release_check([axs_cachekeeper_presentation_release_evidence(zero) containsString:@"可用空间变化 +0 B"],@"observed zero change is distinct from missing data");
    ck_release_check(![axs_cachekeeper_presentation_release_evidence(finished) containsString:@"可用空间变化"],@"missing volume observation never invents a zero delta");
    volume[@"freeBytesDelta"]=@0;ck_release_check(!axs_cachekeeper_release_evidence_projection(bad,nil),@"volume delta cannot be clamped or invented");
    [AxsCacheKeeperReceipts resetForTesting];[AxsCacheKeeperReceipts configureWithStatusFolder:folder];
    NSString *bundle=@"test.release.receipt", *path=[folder stringByAppendingPathComponent:@"test.release.receipt.auto.plist"];
    ck_release_check(ck_release_submit(bundle,running),@"first evidence saved");
    ck_release_check(ck_release_submit(bundle,finished),@"evidence-only revision saved within deduplication window");
    NSDictionary *saved=[NSDictionary dictionaryWithContentsOfFile:path];
    ck_release_check([saved[@"releaseEvidence"] isEqual:finished] && [saved[@"removed"] isEqual:@1],@"terminal evidence survives deduplication without double counting");
    ck_release_check(ck_release_submit(bundle,running),@"stale submission handled");
    saved=[NSDictionary dictionaryWithContentsOfFile:path];
    ck_release_check([saved[@"releaseEvidence"] isEqual:finished],@"stale revision cannot overwrite terminal evidence");
    ck_release_check([AxsCacheKeeperReceipts updateStatusForBundle:bundle phase:@"waiting" message:@"关闭" failed:0 effectivePaths:@[] discoveredPaths:nil directories:nil],@"status update saved");
    saved=[NSDictionary dictionaryWithContentsOfFile:path];
    ck_release_check([saved[@"releaseEvidence"] isEqual:finished],@"status update preserves evidence");
    NSString *text=axs_cachekeeper_presentation_release_evidence(finished);
    ck_release_check([text containsString:@"1"] && [text containsString:@"物理释放量未测定"],@"presentation reports unlink facts without physical claims");
    ck_release_check([axs_cachekeeper_presentation_release_evidence(nil) containsString:@"未记录"],@"old receipts do not become measured zero");
    NSDate *directoryTime=[NSDate dateWithTimeIntervalSince1970:100],*appTime=[NSDate dateWithTimeIntervalSince1970:200];
    NSDictionary *appReport=@{@"confirmedRoundID":finished[@"roundID"],@"releaseEvidence":finished,@"updated":appTime};
    for (NSDictionary *directory in @[@{@"updated":directoryTime,@"removed":@0,@"complete":@YES,@"measurementComplete":@YES,@"coverageComplete":@YES},
        @{@"updated":directoryTime,@"skipped":@YES,@"unresolved":@1}]) {
        NSString *directoryText=axs_cachekeeper_presentation_receipt(directory,appReport);
        ck_release_check([directoryText containsString:@"APP 已保存轮次的全部清理范围"] && [directoryText containsString:@"非本目录统计"] &&
            [directoryText containsString:axs_cachekeeper_presentation_time(directoryTime)] &&
            [directoryText containsString:[NSString stringWithFormat:@"状态记录时间：%@",axs_cachekeeper_presentation_time(appTime)]],
            @"directory and carried records distinguish app-wide evidence scope and time");
    }
    NSString *blockedFolder=[folder stringByAppendingPathComponent:@"not-a-directory"];
    ck_release_check([@"block" writeToFile:blockedFolder atomically:YES encoding:NSUTF8StringEncoding error:nil],@"write failure fixture");
    [AxsCacheKeeperReceipts configureWithStatusFolder:blockedFolder];
    NSString *retryBundle=@"test.release.retry";
    ck_release_check(!ck_release_submit(retryBundle,running) && !ck_release_submit(retryBundle,finished) &&
        !ck_release_submit(retryBundle,running) && [AxsCacheKeeperReceipts hasPendingForBundle:retryBundle],@"failed writes retain latest evidence revision");
    [AxsCacheKeeperReceipts configureWithStatusFolder:folder];
    ck_release_check([AxsCacheKeeperReceipts flushPendingForBundle:retryBundle],@"pending evidence retry succeeds");
    NSDictionary *retried=[NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:@"test.release.retry.auto.plist"]];
    ck_release_check([retried[@"releaseEvidence"] isEqual:finished] && [retried[@"removed"] isEqual:@1],@"pending stale snapshot cannot lose terminal evidence or double count");
    // A fresh round is allowed, and an old caller never carries prior-round evidence into it.
    ck_release_check([AxsCacheKeeperReceipts submitRoundForBundle:bundle roundID:@"legacy-next" removed:0 bytes:0 endReason:0
        phase:@"cleaning" message:@"旧调用方" failed:0 effectivePaths:@[] discoveredPaths:nil directories:nil round:nil coverageComplete:YES],@"legacy caller remains supported");
    saved=[NSDictionary dictionaryWithContentsOfFile:path];
    ck_release_check(!saved[@"releaseEvidence"] && [saved[@"removed"] isEqual:@1],@"new legacy round does not inherit previous evidence");
    // The next empty terminal round must not erase the preceding effective deletion.
    NSString *historyBundle=@"test.release.history";
    ck_release_check([AxsCacheKeeperReceipts submitRoundForBundle:historyBundle roundID:finished[@"roundID"] removed:1 bytes:12
        endReason:1 phase:@"complete" message:@"有效轮" failed:0 effectivePaths:@[] discoveredPaths:nil directories:nil
        round:@{@"removed":@1,@"bytes":@12} coverageComplete:YES releaseEvidence:finished],@"effective terminal round saved");
    ck_release_check([AxsCacheKeeperReceipts submitRoundForBundle:historyBundle roundID:@"next-empty" removed:0 bytes:0
        endReason:1 phase:@"complete" message:@"空轮" failed:0 effectivePaths:@[] discoveredPaths:nil directories:nil
        round:@{@"removed":@0,@"bytes":@0} coverageComplete:YES],@"next empty terminal round saved");
    NSDictionary *history=[NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:@"test.release.history.auto.plist"]];
    ck_release_check([history[@"lastBytes"] isEqual:@0] && [history[@"lastRemoved"] isEqual:@0] &&
        [history[@"lastEffectiveCleanup"][@"bytes"] isEqual:@12] &&
        [history[@"lastEffectiveCleanup"][@"roundID"] isEqual:finished[@"roundID"]] &&
        [history[@"lastEffectiveCleanup"][@"releaseEvidence"] isEqual:finished],@"empty round preserves preceding effective cleanup and its own evidence");
    ck_release_check(ck_release_submit(historyBundle,running) &&
        [ck_cleanup_read(folder,historyBundle)[@"lastEffectiveCleanup"] isEqual:history[@"lastEffectiveCleanup"]],@"old evidence revision cannot replace effective terminal history");
    ck_release_check([history[@"cleanupHistory"][@"rounds"] count]==2 &&
        [history[@"cleanupHistory"][@"rounds"][0][@"context"] isEqual:@{@"state":@"notRecorded"}],@"legacy callers preserve terminal history with unknown context");
    ck_release_check([AxsCacheKeeperReceipts updateStatusForBundle:historyBundle phase:@"waiting" message:@"保留历史" failed:0
        effectivePaths:@[] discoveredPaths:nil directories:nil],@"history status fixture saved");
    ck_release_check([ck_cleanup_read(folder,historyBundle)[@"cleanupHistory"] isEqual:history[@"cleanupHistory"]] &&
        [ck_cleanup_read(folder,historyBundle)[@"lastEffectiveCleanup"] isEqual:history[@"lastEffectiveCleanup"]],@"status writer preserves effective and bounded terminal history");
    NSString *revisionBundle=@"test.cleanup.revision";
    ck_release_check([AxsCacheKeeperReceipts submitRoundForBundle:revisionBundle roundID:finished[@"roundID"] removed:1 bytes:12
        endReason:1 phase:@"complete" message:@"终态版本" failed:0 effectivePaths:@[] discoveredPaths:nil directories:nil
        round:@{@"removed":@1,@"bytes":@12} coverageComplete:YES releaseEvidence:finished],@"effective revision fixture");
    NSDictionary *revisionSaved=ck_cleanup_read(folder,revisionBundle);
    ck_release_check(ck_release_submit(revisionBundle,running) &&
        [ck_cleanup_read(folder,revisionBundle)[@"lastEffectiveCleanup"] isEqual:revisionSaved[@"lastEffectiveCleanup"]] &&
        [ck_cleanup_read(folder,revisionBundle)[@"releaseEvidence"] isEqual:finished],@"stale same-round revision preserves current and effective evidence");
    NSDictionary *autoContext=ck_cleanup_context(@"auto",@"1.0"),*preventContext=ck_cleanup_context(@"prevent",@"2.0");
    ck_release_check(autoContext && preventContext,@"public configuration with actual rule-version grammar is accepted");
    NSString *canonicalID=axs_cachekeeper_cleanup_configuration_id(autoContext,@[@"tmp",@"Library/Caches",@"tmp"],@[@"Library/Caches/keep"],@[@"Library/logs"]);
    ck_release_check([canonicalID isEqual:axs_cachekeeper_cleanup_configuration_id(autoContext,@[@"Library/Caches",@"tmp"],@[@"Library/Caches/keep"],@[@"Library/logs"])],
        @"configuration identity canonicalizes ordering and duplicate relative paths");
    ck_release_check(![canonicalID isEqual:axs_cachekeeper_cleanup_configuration_id(autoContext,@[@"Library/Caches"],@[@"Library/Caches/keep"],@[@"Library/logs"])] &&
        ![canonicalID isEqual:axs_cachekeeper_cleanup_configuration_id(autoContext,@[@"Library/Caches",@"tmp"],@[],@[@"Library/logs"])] &&
        ![canonicalID isEqual:axs_cachekeeper_cleanup_configuration_id(autoContext,@[@"Library/Caches",@"tmp"],@[@"Library/Caches/keep"],@[])],
        @"selected exclusions and log changes each produce a distinct configuration identity");
    ck_release_check(!axs_cachekeeper_cleanup_configuration_id(autoContext,@[@"/private/absolute-canary"],@[],@[]) &&
        !axs_cachekeeper_cleanup_configuration_id(autoContext,@[@"C:\\private\\absolute-canary"],@[],@[]) &&
        !axs_cachekeeper_cleanup_configuration_id(autoContext,@[@"Library/../private-canary"],@[],@[]),@"configuration hashing rejects absolute and traversal paths");
    NSMutableArray *legalPaths=[NSMutableArray arrayWithArray:@[@"Library/Caches/a:b",@"Library/Caches/a\nb"]];
    for (NSUInteger i=0;i<4097;i++) [legalPaths addObject:[NSString stringWithFormat:@"Library/Caches/keep-%lu",(unsigned long)i]];
    NSString *legalID=axs_cachekeeper_cleanup_configuration_id(autoContext,@[@"Library/Caches"],legalPaths,@[]);
    ck_release_check(axs_cachekeeper_input_strings(legalPaths,axs_cachekeeper_relative_path) && legalID &&
        [legalID isEqual:axs_cachekeeper_cleanup_configuration_id(autoContext,@[@"Library/Caches"],legalPaths.reverseObjectEnumerator.allObjects,@[])],
        @"configuration hashing accepts all existing legal relative paths and collection sizes");
    NSString *boundedBundle=@"test.cleanup.bounded";
    ck_release_check(ck_cleanup_submit(boundedBundle,@"a",1,0,0,autoContext) &&
        ck_cleanup_submit(boundedBundle,@"a",2,0,0,autoContext) && ck_cleanup_submit(boundedBundle,@"a",2,1,0,autoContext),@"incremental round then final saved");
    NSDictionary *bounded=ck_cleanup_read(folder,boundedBundle),*firstEffective=bounded[@"lastEffectiveCleanup"];
    ck_release_check([bounded[@"removed"] isEqual:@2] && [bounded[@"cleanupHistory"][@"rounds"] count]==1 &&
        [firstEffective[@"bytes"] isEqual:@24],@"incremental snapshots produce one exact terminal round");
    ck_release_check(ck_cleanup_submit(boundedBundle,@"a",2,1,0,autoContext),@"duplicate terminal accepted");
    bounded=ck_cleanup_read(folder,boundedBundle);
    ck_release_check([bounded[@"removed"] isEqual:@2] && [bounded[@"lastEffectiveCleanup"] isEqual:firstEffective] &&
        [bounded[@"cleanupHistory"][@"rounds"] count]==1,@"duplicate terminal preserves original time and exact cumulative totals");
    ck_release_check(!ck_cleanup_submit(boundedBundle,@"a",2,1,0,preventContext),@"same round refuses a changed public context");
    // A mismatched producer must not poison future valid snapshots already on the queue.
    ck_release_check(ck_cleanup_submit(boundedBundle,@"a",2,1,0,autoContext),@"valid original context recovers rejected submission");
    for (NSUInteger i=0;i<18;i++) {
        NSString *identifier=[NSString stringWithFormat:@"empty-%02lu",(unsigned long)i];
        ck_release_check(ck_cleanup_submit(boundedBundle,identifier,0,1,0,i<9 ? autoContext : preventContext),@"empty terminal appended");
    }
    bounded=ck_cleanup_read(folder,boundedBundle);NSArray *rows=bounded[@"cleanupHistory"][@"rounds"];
    ck_release_check(rows.count==16 && [bounded[@"cleanupHistory"][@"capacity"] isEqual:@16] &&
        [bounded[@"cleanupHistory"][@"truncatedCount"] isEqual:@3] && [rows[0][@"roundID"] isEqual:@"empty-02"] &&
        [rows[6][@"context"][@"mode"] isEqual:@"auto"] && [rows[7][@"context"][@"mode"] isEqual:@"prevent"] &&
        [bounded[@"lastEffectiveCleanup"] isEqual:firstEffective],@"sixteen terminal rounds retain mode switch while effective result survives truncation");
    ck_release_check(ck_cleanup_submit(boundedBundle,@"a",2,1,0,autoContext) &&
        ck_cleanup_submit(boundedBundle,@"empty-17",0,1,0,preventContext),@"retained effective duplicate and current duplicate handled");
    bounded=ck_cleanup_read(folder,boundedBundle);
    ck_release_check([bounded[@"removed"] isEqual:@2] && [bounded[@"confirmedRoundID"] isEqual:@"empty-17"] &&
        [bounded[@"cleanupHistory"][@"truncatedCount"] isEqual:@3],@"delayed old effective round cannot increment or replace latest round");
    [AxsCacheKeeperReceipts resetForTesting];[AxsCacheKeeperReceipts configureWithStatusFolder:folder];
    ck_release_check([AxsCacheKeeperReceipts updateStatusForBundle:boundedBundle phase:@"waiting" message:@"重启后等待" failed:0
        effectivePaths:@[] discoveredPaths:nil directories:nil],@"restart status update reads history");
    NSDictionary *restarted=ck_cleanup_read(folder,boundedBundle);
    ck_release_check([restarted[@"cleanupHistory"] isEqual:bounded[@"cleanupHistory"]] &&
        [restarted[@"lastEffectiveCleanup"] isEqual:firstEffective] && [restarted[@"cleanupContext"] isEqual:preventContext],@"status and restart preserve all frozen evidence fields");
    NSString *restartDisplay=axs_cachekeeper_presentation_receipt(@{},restarted);
    ck_release_check([restartDisplay containsString:[NSString stringWithFormat:@"该轮结束时间：%@",
        axs_cachekeeper_presentation_time(rows.lastObject[@"finishedAt"])]] &&
        [restartDisplay containsString:@"状态记录时间："] && [restartDisplay containsString:@"该回执配置：限制缓存并清理"] &&
        ![restartDisplay containsString:@"APP 本轮全部清理范围"],@"status-only persistence keeps historical cleanup time in detail");
    ck_release_check(ck_cleanup_submit(boundedBundle,@"partial-cancel",3,4,1,autoContext) &&
        ck_cleanup_submit(boundedBundle,@"failed-empty",0,5,2,preventContext),@"cancelled partial cleanup and empty failure saved");
    bounded=ck_cleanup_read(folder,boundedBundle);rows=bounded[@"cleanupHistory"][@"rounds"];
    ck_release_check([bounded[@"lastEffectiveCleanup"][@"roundID"] isEqual:@"partial-cancel"] &&
        [bounded[@"lastEffectiveCleanup"][@"endReason"] isEqual:@4] && [rows.lastObject[@"endReason"] isEqual:@5] &&
        [rows.lastObject[@"failed"] isEqual:@2],@"cancelled partial result survives a later failed empty round");
    ck_release_check([AxsCacheKeeperReceipts updateStatusForBundle:boundedBundle phase:@"waiting" message:@"APP 重开后等待" failed:0
        effectivePaths:@[] discoveredPaths:nil directories:nil],@"failure history status-only update saved");
    NSDictionary *failureStatus=ck_cleanup_read(folder,boundedBundle);
    ck_release_check([failureStatus[@"failed"] isEqual:@0],@"new status clears only current failures");
    NSString *failureSummary=axs_cachekeeper_summary(nil,failureStatus);
    NSArray *summaryLines=[failureSummary componentsSeparatedByString:@"\n"];
    NSString *latestLine=nil,*effectiveLine=nil;
    for (NSString *line in summaryLines) {
        if ([line hasPrefix:@"最近一轮："]) latestLine=line;
        if ([line hasPrefix:@"最近实际清理："]) effectiveLine=line;
    }
    ck_release_check([latestLine containsString:@"该轮失败 2 项"] && [latestLine containsString:@"该轮覆盖未完整"] &&
        ![latestLine containsString:@"该轮已中止"] && [effectiveLine containsString:@"该轮失败 1 项"] &&
        [effectiveLine containsString:@"该轮已中止"] && [effectiveLine containsString:@"该轮覆盖未完整"] &&
        ![failureSummary containsString:@"本轮失败"],@"policy summary preserves each frozen failure cancellation and coverage after status-only update");
    ck_release_check(ck_cleanup_submit(boundedBundle,@"partial-failed",4,5,1,preventContext),@"failed partial cleanup saved");
    bounded=ck_cleanup_read(folder,boundedBundle);
    ck_release_check([bounded[@"removed"] isEqual:@9] && [bounded[@"lastEffectiveCleanup"][@"bytes"] isEqual:@48] &&
        [bounded[@"lastEffectiveCleanup"][@"endReason"] isEqual:@5],@"failure retains successful partial deletions without claiming completion");
    NSString *summary=axs_cachekeeper_summary(nil,bounded);
    ck_release_check([summary containsString:@"最近一轮"] && [summary containsString:@"最近实际清理"] &&
        [summary containsString:@"禁止缓存"] && [summary containsString:@"0.7.2-188.1"] && [summary containsString:@"2.0"],@"policy summary displays historical mode and versions for each result");
    NSDictionary *exported=axs_cachekeeper_cleanup_history_projection(bounded,YES);
    NSString *json=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:exported options:0 error:nil] encoding:NSUTF8StringEncoding];
    ck_release_check([NSJSONSerialization isValidJSONObject:exported] && ![json containsString:@"private-canary"] &&
        ![json containsString:@"private-directory-canary"] && ![json containsString:@"signature"] &&
        [exported[@"lastEffectiveCleanup"][@"finishedAt"] isKindOfClass:NSNumber.class],@"history export is JSON-safe without directory lists or private identity");
    NSDictionary *legacy=axs_cachekeeper_cleanup_history_projection(@{@"removed":@999,@"bytes":@999999},NO);
    ck_release_check([legacy[@"cleanupHistory"] isEqual:@{@"state":@"notRecorded"}] &&
        [legacy[@"lastEffectiveCleanup"] isEqual:@{@"state":@"notRecorded"}],@"legacy totals never manufacture terminal history");
    NSMutableDictionary *privateContext=[autoContext mutableCopy];privateContext[@"installationFingerprint"]=@"private-installation-canary";
    ck_release_check(!axs_cachekeeper_cleanup_context_projection(privateContext),@"private installation field is rejected");
    privateContext=[autoContext mutableCopy];privateContext[@"appVersion"]=@"/private/version-path";
    ck_release_check(!axs_cachekeeper_cleanup_context_projection(privateContext),@"version field cannot carry an absolute path");
    for (NSArray *badField in @[@[@"capacity",@17],@[@"truncatedCount",@YES],@[@"truncatedCount",@(-1)],
        @[@"rounds",@"not-an-array"],@[@"schemaVersion",@2]]) {
        NSMutableDictionary *badEnvelope=[bounded mutableCopy],*badHistory=[bounded[@"cleanupHistory"] mutableCopy];
        badHistory[badField[0]]=badField[1];badEnvelope[@"cleanupHistory"]=badHistory;
        ck_release_check(!axs_cachekeeper_cleanup_history_projection(badEnvelope,NO),@"new history rejects malformed types version and bounds");
    }
    NSMutableDictionary *incompleteEnvelope=[bounded mutableCopy];[incompleteEnvelope removeObjectForKey:@"lastEffectiveCleanup"];
    ck_release_check(!axs_cachekeeper_cleanup_history_projection(incompleteEnvelope,NO),@"partial new envelope is invalid rather than legacy");
    incompleteEnvelope=[bounded mutableCopy];incompleteEnvelope[@"cleanupContext"]=autoContext;
    ck_release_check(!axs_cachekeeper_cleanup_history_projection(incompleteEnvelope,NO),@"current terminal context cannot disagree with same round history");
    NSString *corruptBundle=@"test.cleanup.corrupt",*corruptPath=[folder stringByAppendingPathComponent:@"test.cleanup.corrupt.auto.plist"];
    NSMutableDictionary *corrupt=[bounded mutableCopy];NSMutableDictionary *corruptHistory=[bounded[@"cleanupHistory"] mutableCopy];
    corruptHistory[@"rounds"]=@[@{@"privatePath":@"private-history-canary"}];corrupt[@"cleanupHistory"]=corruptHistory;
    ck_release_check(!axs_cachekeeper_cleanup_history_projection(corrupt,YES) && [corrupt writeToFile:corruptPath atomically:YES],@"malformed new history fixture");
    NSData *corruptData=[NSData dataWithContentsOfFile:corruptPath];
    ck_release_check(!ck_cleanup_submit(corruptBundle,@"recovery",1,1,0,autoContext) &&
        ![AxsCacheKeeperReceipts updateStatusForBundle:corruptBundle phase:@"waiting" message:@"保留损坏证据" failed:0 effectivePaths:@[] discoveredPaths:nil directories:nil] &&
        [[NSData dataWithContentsOfFile:corruptPath] isEqual:corruptData] && [AxsCacheKeeperReceipts hasPendingForBundle:corruptBundle],@"malformed history blocks both writers without overwriting or dropping pending result");
    ck_release_check([@{} writeToFile:corruptPath atomically:YES] && [AxsCacheKeeperReceipts flushPendingForBundle:corruptBundle],@"explicit fixture repair permits pending retry");
    ck_release_check([ck_cleanup_read(folder,corruptBundle)[@"lastEffectiveCleanup"][@"removed"] isEqual:@1],@"retry retains terminal partial result");
    [AxsCacheKeeperReceipts configureWithStatusFolder:blockedFolder];
    NSString *queueBundle=@"test.cleanup.queue";
    ck_release_check(!ck_cleanup_submit(queueBundle,@"cancelled",2,4,1,autoContext) &&
        !ck_cleanup_submit(queueBundle,@"empty",0,1,0,preventContext),@"two terminal contexts remain queued on write failure");
    [AxsCacheKeeperReceipts configureWithStatusFolder:folder];
    ck_release_check([AxsCacheKeeperReceipts flushPendingForBundle:queueBundle],@"ordered pending history retry");
    NSDictionary *queued=ck_cleanup_read(folder,queueBundle);
    ck_release_check([queued[@"removed"] isEqual:@2] && [queued[@"lastEffectiveCleanup"][@"context"] isEqual:autoContext] &&
        [queued[@"cleanupHistory"][@"rounds"] count]==2 && [queued[@"cleanupContext"] isEqual:preventContext],@"retry preserves effective cancelled result and each original context");
    NSString *frozenBundle=@"test.cleanup.frozen";
    ck_release_check(ck_cleanup_submit(frozenBundle,@"finished",2,5,3,autoContext),@"original failed terminal is saved");
    NSDictionary *originalTerminal=ck_cleanup_read(folder,frozenBundle);
    ck_release_check(ck_cleanup_submit(frozenBundle,@"finished",2,4,0,autoContext) &&
        [ck_cleanup_read(folder,frozenBundle) isEqual:originalTerminal],
        @"retirement cannot replace an already persisted terminal boundary");
    ck_release_check(!ck_cleanup_submit(frozenBundle,@"finished",3,1,0,autoContext) &&
        ![AxsCacheKeeperReceipts hasPendingForBundle:frozenBundle] &&
        ck_cleanup_submit(frozenBundle,@"finished",2,5,3,autoContext) &&
        ck_cleanup_submit(frozenBundle,@"new-round",0,1,0,autoContext),
        @"rejected terminal growth cannot poison pending queue or block a valid next round");
    NSString *pendingFrozenBundle=@"test.cleanup.pending-frozen";
    [AxsCacheKeeperReceipts configureWithStatusFolder:blockedFolder];
    ck_release_check(!ck_cleanup_submit(pendingFrozenBundle,@"finished",2,5,3,autoContext) &&
        !ck_cleanup_submit(pendingFrozenBundle,@"finished",2,4,0,autoContext),@"terminal retry remains pending while output is unavailable");
    [AxsCacheKeeperReceipts configureWithStatusFolder:folder];
    ck_release_check([AxsCacheKeeperReceipts flushPendingForBundle:pendingFrozenBundle],@"original terminal retry flushes");
    NSDictionary *pendingTerminal=ck_cleanup_read(folder,pendingFrozenBundle)[@"cleanupHistory"][@"rounds"][0];
    ck_release_check([pendingTerminal[@"failed"] isEqual:@3] && [pendingTerminal[@"endReason"] isEqual:@5] &&
        ![pendingTerminal[@"coverageComplete"] boolValue],@"pending retirement preserves first terminal failures reason and coverage");
    puts("PASS: release receipt schema, revisions, deduplication, preservation and presentation");
} return 0; }
