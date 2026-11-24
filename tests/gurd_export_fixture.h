#pragma once
#import "AxsCacheKeeperGurdStatus.h"

// Producer-shaped receipt; external host execution is not simulated here.
static NSDictionary *axs_cachekeeper_gurd_export_fixture(void) {
    NSDictionary *before=@{@"state":@"notRecorded",@"files":@0,@"logicalBytes":@0,@"allocatedBytes":@0,@"entries":@0,@"errorCode":@0};
    NSDictionary *after=before;
    NSDictionary *runtime=@{@"schemaVersion":@1,@"packageVersion":@"0.7.2-201.1",@"firstObserved":@1794799900};
    NSDictionary *proof=@{@"state":@"scopeUnproven",@"hostBundle":@"com.ss.iphone.ugc.Aweme",@"hostVersion":@"41.2.0",@"hostBuild":@"412021",
        @"hostIdentity":@"aweme-core-window-set-v1",@"candidateSource":@"unavailable",@"predicateVersion":@"unavailable",@"rootIdentity":@"fixture-root",
        @"candidateCount":@0,@"candidateDigest":@"",@"excludedCount":@0,@"exclusionDigest":@""};
    NSDictionary *operation=@{@"event":@1,@"runtimeInfo":runtime,@"configuration":@1,@"phase":@"skipped",@"reason":@"scopeUnproven",
        @"submission":@"notSubmitted",@"hostCompletion":@"notProvided",@"observation":@"notObserved",@"scopeProof":proof,
        @"before":before,@"after":after,@"logicalDecrease":@0,@"allocatedDecrease":@0,@"physicalUniqueReclaimed":@"notMeasured"};
    return @{@"schemaVersion":@1,@"updated":[NSDate dateWithTimeIntervalSince1970:1794800000],
        @"runtimeInfo":runtime,
        @"family":@"gurd",@"contract":@"aweme412021WhitelistV1",@"state":@"blocked",@"reason":@"scopeUnproven",
        @"restriction":@"unsupported",@"background":@YES,@"operations":@[operation]};
}
