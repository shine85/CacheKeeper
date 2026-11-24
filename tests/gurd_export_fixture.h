#pragma once
#import "AxsCacheKeeperGurdStatus.h"

// Producer-shaped receipt; external host execution is not simulated here.
static NSDictionary *axs_cachekeeper_gurd_export_fixture(void) {
    NSDictionary *before=@{@"state":@"complete",@"files":@2,@"logicalBytes":@4096,@"allocatedBytes":@8192,@"entries":@3,@"errorCode":@0};
    NSDictionary *after=@{@"state":@"complete",@"files":@1,@"logicalBytes":@1024,@"allocatedBytes":@4096,@"entries":@2,@"errorCode":@0};
    NSDictionary *runtime=@{@"schemaVersion":@1,@"packageVersion":@"0.7.2-201.1",@"firstObserved":@1794799900};
    NSDictionary *operation=@{@"event":@1,@"runtimeInfo":runtime,@"configuration":@1,@"phase":@"observed",@"reason":@"none",
        @"submission":@"submitted",@"hostCompletion":@"notProvided",@"observation":@"reduced",
        @"before":before,@"after":after,@"logicalDecrease":@3072,@"allocatedDecrease":@4096,@"physicalUniqueReclaimed":@"notMeasured"};
    return @{@"schemaVersion":@1,@"updated":[NSDate dateWithTimeIntervalSince1970:1794800000],
        @"runtimeInfo":runtime,
        @"family":@"gurd",@"contract":@"aweme412021WhitelistV1",@"state":@"observed",@"reason":@"none",
        @"restriction":@"unsupported",@"background":@YES,@"operations":@[operation]};
}
