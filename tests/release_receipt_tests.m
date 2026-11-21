#import <Foundation/Foundation.h>
#import "../AxsCacheKeeperReceipts.h"
#import "../AxsCacheKeeperReleaseEvidenceStatus.h"
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
        ck_release_check([directoryText containsString:@"APP 本轮全部清理范围"] && [directoryText containsString:@"非本目录统计"] &&
            [directoryText containsString:axs_cachekeeper_presentation_time(directoryTime)] &&
            [directoryText containsString:[NSString stringWithFormat:@"APP 回执时间：%@",axs_cachekeeper_presentation_time(appTime)]],
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
    puts("PASS: release receipt schema, revisions, deduplication, preservation and presentation");
} return 0; }
