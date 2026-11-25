#pragma once
#import "../AxsCacheKeeperGurdStatus.h"

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

// Normalized from the five operation descriptions collected on 2026-11-24.
// This is a typed fixture, not a byte replay of the unavailable original plist.
static NSDictionary *axs_cachekeeper_gurd_legacy_export_fixture(void) {
    NSMutableDictionary *receipt=[axs_cachekeeper_gurd_export_fixture() mutableCopy];
    NSDictionary *runtime=@{@"schemaVersion":@1,@"packageVersion":@"0.7.2-202.1",@"firstObserved":@1795503054.096321};
    NSArray *samples=@[
        @{@"state":@"identityChanged",@"files":@0,@"logicalBytes":@0,@"allocatedBytes":@0,@"entries":@1,@"errorCode":@70},
        @{@"state":@"timeLimit",@"files":@3548,@"logicalBytes":@272287950,@"allocatedBytes":@281485312,@"entries":@5066,@"errorCode":@0},
        @{@"state":@"timeLimit",@"files":@4426,@"logicalBytes":@291641850,@"allocatedBytes":@303509504,@"entries":@6016,@"errorCode":@0},
        @{@"state":@"notRecorded",@"files":@0,@"logicalBytes":@0,@"allocatedBytes":@0,@"entries":@0,@"errorCode":@0},
        @{@"state":@"timeLimit",@"files":@982,@"logicalBytes":@73503908,@"allocatedBytes":@75927552,@"entries":@1449,@"errorCode":@0}];
    NSMutableArray *operations=[NSMutableArray new];
    for(NSUInteger i=0;i<samples.count;i++) {
        NSMutableDictionary *operation=[receipt[@"operations"][0] mutableCopy];
        [operation removeObjectForKey:@"scopeProof"];
        operation[@"runtimeInfo"]=i<3 ? @{@"schemaVersion":@1,@"packageVersion":@"0.7.2-202.1",@"firstObserved":@1795498764.568249} : runtime;
        operation[@"event"]=@(i+1);operation[@"configuration"]=@(i<3 ? i+1 : i-2);
        operation[@"reason"]=i==3 ? @"appDisabled" : @"beforeSampleFailed";operation[@"before"]=samples[i];
        [operations addObject:operation];
    }
    receipt[@"runtimeInfo"]=runtime;receipt[@"updated"]=[NSDate dateWithTimeIntervalSince1970:1795504834];
    receipt[@"reason"]=@"beforeSampleFailed";receipt[@"operations"]=operations;return receipt;
}
