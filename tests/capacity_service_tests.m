#import <Foundation/Foundation.h>
#import "../AxsCacheKeeperCapacityService.h"
#import "../AxsCacheKeeperCapacityStatus.h"
#import "../AxsCacheKeeperCapacity.h"
#include <fcntl.h>
#include <unistd.h>

static void ckcheck(BOOL value,const char *message) {
    if (!value) {fprintf(stderr,"FAIL: capacity service: %s\n",message);exit(1);}
}
static NSString *ckdirectory(NSString *base,NSString *name) {
    NSString *path=[base stringByAppendingPathComponent:name];
    ckcheck([NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil],"create isolated fixture");return path;
}
static void ckfile(NSString *path,NSUInteger length) {
    ckcheck([[NSMutableData dataWithLength:length] writeToFile:path atomically:YES],"write synthetic fixture");
}
static NSString *ckrequestPath(NSString *folder) {return [folder stringByAppendingPathComponent:@"capacityRequest.plist"];}
static NSDictionary *ckresult(NSString *folder) {return axs_cachekeeper_capacity_read_result([folder stringByAppendingPathComponent:@"capacityResult.plist"],nil);}
static void ckrequest(NSString *folder,NSString *epoch,BOOL cancel) {
    ckcheck(axs_cachekeeper_capacity_write_request(ckrequestPath(folder),epoch,cancel,nil),"write real request");
}
// Only the LS boundary is replaced. All directory/inode measurements, service
// scheduling and request/result persistence run through the production modules.
static NSDictionary *ckplan(NSArray *roots,NSArray *bundles,BOOL partial) {
    NSMutableDictionary *roles=[NSMutableDictionary new];NSMutableArray *entries=[NSMutableArray new];NSMutableSet *tokens=[NSMutableSet new];
    for (NSString *role in @[@"home",@"group",@"extension"]) {
        NSMutableSet *roleTokens=[NSMutableSet new];NSUInteger associations=0;
        for (NSDictionary *root in roots) if ([root[@"roles"] containsObject:role]) {[roleTokens addObject:root[@"token"]];associations+=[root[@"owners"] count];}
        roles[role]=@{@"state":@"available",@"observedSourceCount":@(bundles.count),@"missingSelectorCount":@0,
            @"notProvidedCount":[role isEqual:@"home"] ? @(bundles.count) : @0,@"invalidSourceCount":@0,@"invalidAssociationCount":@0,
            @"ownerMismatchCount":@0,@"unavailableOwnerCount":@0,@"truncatedCount":@0,@"registeredURLCount":@(roleTokens.count),@"associationCount":@(associations)};
        [tokens unionSet:roleTokens];
    }
    for (NSString *bundle in bundles) {
        NSMutableDictionary *relationships=[NSMutableDictionary new];
        for (NSString *role in @[@"home",@"group",@"extension"]) {
            NSMutableArray *related=[NSMutableArray new];
            for (NSDictionary *root in roots) if ([root[@"roles"] containsObject:role] && [root[@"owners"] containsObject:bundle]) [related addObject:root[@"token"]];
            relationships[role]=@{@"state":[role isEqual:@"home"] ? @"notProvided" : @"available",@"tokens":related};
        }
        [entries addObject:@{@"bundle":bundle,@"displayEligible":@YES,@"sourceClassification":@"user",@"relationships":relationships}];
    }
    NSMutableDictionary *registry=[@{@"schemaVersion":@1,@"state":partial ? @"partial" : @"available",@"sourceState":@"available",
        @"observedRegistrations":@(bundles.count),@"invalidRegistrationCount":@0,@"truncatedRegistrationCount":partial ? @1 : @0,
        @"allRolesUniqueRegisteredURLCount":@(tokens.count),@"countsAreLowerBounds":@(partial),@"sourceSampledAt":@100,@"entries":entries} mutableCopy];
    [registry addEntriesFromDictionary:roles];
    NSDictionary *closed=axs_cachekeeper_registry_inventory_projection(registry);
    ckcheck(![closed[@"state"] isEqual:@"invalid"],"test LS fixture is a valid public inventory");
    return @{@"state":closed[@"state"],@"sourceSampledAt":@100,@"registry":closed,@"roots":roots};
}
static NSDictionary *ckroot(NSString *path,NSString *token,NSArray *owners) {
    return @{@"token":token,@"url":[NSURL fileURLWithPath:path],@"owners":owners,@"roles":@[@"group"]};
}
static void ckfinish(AxsCacheKeeperCapacityService *service) {
    for (NSUInteger i=0;i<1000;i++) if (![service tick]) return;
    ckcheck(NO,"bounded fixture service settles");
}
static void ckshared(NSString *base) {
    NSString *folder=ckdirectory(base,@"shared-status"),*root=ckdirectory(base,@"private-shared-container");
    ckfile([root stringByAppendingPathComponent:@"private-name"],8192);
    NSString *alias=ckdirectory(base,@"aliases"),*parent=[alias stringByAppendingPathComponent:@"parent"];
    ckcheck(!symlink(base.fileSystemRepresentation,parent.fileSystemRepresentation),"intermediate system-style alias fixture");
    NSString *aliasRoot=[parent stringByAppendingPathComponent:@"private-shared-container"];
    NSDictionary *plan=ckplan(@[ckroot(root,@"resource-1",@[@"test.a"]),ckroot(aliasRoot,@"resource-2",@[@"test.b"])],@[@"test.a",@"test.b",@"test.nohome"],NO);
    AxsCacheKeeperCapacityService *service=[[AxsCacheKeeperCapacityService alloc] initWithFolder:folder provider:^NSDictionary *(NSError **error) {(void)error;return plan;} writer:nil];
    NSString *epoch=NSUUID.UUID.UUIDString;ckrequest(folder,epoch,NO);ckfinish(service);
    NSDictionary *result=ckresult(folder),*row=[result[@"roots"] firstObject];
    ckcheck([result[@"state"] isEqual:@"complete"] && [result[@"totalRoots"] isEqual:@1] && [result[@"roots"] count]==1 && [row[@"owners"] isEqual:@[@"test.a",@"test.b"]],"alias/shared root measured once with union owners");
    ckcheck([row[@"measurement"][@"logicalBytes"] isEqual:@8192] && [row[@"measurement"][@"entries"] isEqual:@2],"real container bytes measured instead of saved/fake totals");
    NSDictionary *nohome=[result[@"entries"] lastObject];ckcheck([nohome[@"state"] isEqual:@"noRegisteredRoots"] && !nohome[@"logicalBytes"] && [nohome[@"rootIds"] count]==0,"no registered root is not a zero-byte measurement");
    NSString *json=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:result options:0 error:nil] encoding:NSUTF8StringEncoding];
    ckcheck(![json containsString:root] && ![json containsString:@"private-name"] && [result[@"deletionAuthorization"] isEqual:@"notGranted"],"persisted observations contain no paths or deletion grants");
}
static void ckcancel(NSString *base) {
    NSString *folder=ckdirectory(base,@"cancel-status"),*root=ckdirectory(base,@"cancel-container");
    for (NSUInteger i=0;i<1200;i++) ckfile([root stringByAppendingPathComponent:[NSString stringWithFormat:@"f%lu",(unsigned long)i]],1);
    NSDictionary *plan=ckplan(@[ckroot(root,@"resource-1",@[@"test.a"])],@[@"test.a"],NO);__block NSUInteger calls=0;
    AxsCacheKeeperCapacityService *service=[[AxsCacheKeeperCapacityService alloc] initWithFolder:folder provider:^NSDictionary *(NSError **e) {(void)e;calls++;return plan;} writer:nil];
    NSString *old=NSUUID.UUID.UUIDString;ckrequest(folder,old,NO);[service tick];[service tick];
    NSDictionary *running=ckresult(folder);ckcheck([running[@"state"] isEqual:@"running"] && [running[@"roots"] count]==1,"current root snapshot is included while running");
    ckrequest(folder,old,YES);ckfinish(service);NSDictionary *cancelled=ckresult(folder);
    ckcheck([cancelled[@"state"] isEqual:@"cancelled"] && [cancelled[@"completedRoots"] isEqual:@0],"cancel closes active measurement before completion");
    NSString *fresh=NSUUID.UUID.UUIDString;ckrequest(folder,fresh,NO);ckfinish(service);NSDictionary *result=ckresult(folder);
    ckcheck([result[@"epoch"] isEqual:fresh] && [result[@"state"] isEqual:@"complete"] && calls==2 && [result[@"roots"][0][@"measurement"][@"entries"] isEqual:@1201],"new epoch remeasures after cancellation");
}
static void cksave(NSString *base) {
    NSString *folder=ckdirectory(base,@"save-status"),*root=ckdirectory(base,@"save-container");ckfile([root stringByAppendingPathComponent:@"canary"],123);
    NSDictionary *plan=ckplan(@[ckroot(root,@"resource-1",@[@"test.a"])],@[@"test.a"],NO);__block BOOL fail=YES;__block NSUInteger writes=0;
    AxsCacheKeeperCapacityService *service=[[AxsCacheKeeperCapacityService alloc] initWithFolder:folder provider:^NSDictionary *(NSError **e) {(void)e;return plan;}
        writer:^BOOL(NSDictionary *record,NSString *path) {
            writes++;
            // Exercise a real non-regular target rejection, not an injected NO.
            if (fail) ckcheck([NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:NO attributes:nil error:nil],"create actual write failure target");
            return axs_cachekeeper_capacity_atomic_write(record,path.stringByDeletingLastPathComponent,path.lastPathComponent,32*1024*1024,nil);
        }];
    ckrequest(folder,NSUUID.UUID.UUIDString,NO);[service tick];[service tick];
    ckcheck([ckresult(folder)[@"state"] isEqual:@"invalid"] && writes==1,"failed first publication cannot advance or claim saved success");
    ckcheck([NSFileManager.defaultManager removeItemAtPath:[folder stringByAppendingPathComponent:@"capacityResult.plist"] error:nil],"remove isolated write failure target");
    fail=NO;[NSThread sleepForTimeInterval:1.05];ckfinish(service);NSDictionary *result=ckresult(folder);
    ckcheck([result[@"state"] isEqual:@"partial"] && [result[@"failure"][@"code"] isEqual:@"writeFailed"] &&
        [result[@"roots"][0][@"measurement"][@"entries"] isEqual:@1],"writer recovery saves stopped partial observation without unmeasured advancement");
    ckrequest(folder,NSUUID.UUID.UUIDString,NO);ckfinish(service);ckcheck([ckresult(folder)[@"state"] isEqual:@"complete"],"new epoch resumes actual measurement after writer failure");
    NSString *terminalFolder=ckdirectory(base,@"terminal-save-status");__block BOOL terminalBlocked=NO;
    AxsCacheKeeperCapacityService *terminal=[[AxsCacheKeeperCapacityService alloc] initWithFolder:terminalFolder provider:^NSDictionary *(NSError **e) {(void)e;return plan;}
        writer:^BOOL(NSDictionary *record,NSString *path) {
            if ([record[@"state"] isEqual:@"complete"] && !terminalBlocked) {
                terminalBlocked=YES;ckcheck([NSFileManager.defaultManager removeItemAtPath:path error:nil],"remove owned running result for failure fixture");
                ckcheck([NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:NO attributes:nil error:nil],"terminal write failure fixture");
            }
            return axs_cachekeeper_capacity_atomic_write(record,path.stringByDeletingLastPathComponent,path.lastPathComponent,32*1024*1024,nil);
        }];
    ckrequest(terminalFolder,NSUUID.UUID.UUIDString,NO);[terminal tick];[terminal tick];
    ckcheck(terminalBlocked && [ckresult(terminalFolder)[@"state"] isEqual:@"invalid"],"terminal publication has a real filesystem failure");
    ckcheck([NSFileManager.defaultManager removeItemAtPath:[terminalFolder stringByAppendingPathComponent:@"capacityResult.plist"] error:nil],"remove isolated terminal failure target");
    [NSThread sleepForTimeInterval:1.05];ckfinish(terminal);NSDictionary *terminalResult=ckresult(terminalFolder);
    ckcheck([terminalResult[@"state"] isEqual:@"partial"] && [terminalResult[@"failure"][@"code"] isEqual:@"writeFailed"] &&
        [terminalResult[@"completedRoots"] isEqual:@1],"failed terminal save cannot later claim successful completion");
}
static void ckrestart(NSString *base) {
    NSString *folder=ckdirectory(base,@"restart-status"),*root=ckdirectory(base,@"restart-container");
    for (NSUInteger i=0;i<800;i++) ckfile([root stringByAppendingPathComponent:[NSString stringWithFormat:@"f%lu",(unsigned long)i]],1);
    NSDictionary *plan=ckplan(@[ckroot(root,@"resource-1",@[@"test.a"])],@[@"test.a"],NO);NSString *epoch=NSUUID.UUID.UUIDString;ckrequest(folder,epoch,NO);
    @autoreleasepool {AxsCacheKeeperCapacityService *first=[[AxsCacheKeeperCapacityService alloc] initWithFolder:folder provider:^NSDictionary *(NSError **e) {(void)e;return plan;} writer:nil];[first tick];}
    __block NSUInteger calls=0;AxsCacheKeeperCapacityService *second=[[AxsCacheKeeperCapacityService alloc] initWithFolder:folder provider:^NSDictionary *(NSError **e) {(void)e;calls++;return plan;} writer:nil];
    ckfinish(second);ckcheck([ckresult(folder)[@"state"] isEqual:@"interrupted"] && calls==0,"cold restart interrupts saved running epoch without recollecting provider");
    ckrequest(folder,NSUUID.UUID.UUIDString,NO);ckfinish(second);ckcheck(calls==1 && [ckresult(folder)[@"state"] isEqual:@"complete"],"restart accepts only a new epoch");
}
static void ckreplacement(NSString *base) {
    NSString *folder=ckdirectory(base,@"replacement-status"),*root=ckdirectory(base,@"replacement-container");ckfile([root stringByAppendingPathComponent:@"data"],13);
    NSDictionary *plan=ckplan(@[ckroot(root,@"resource-1",@[@"test.a"])],@[@"test.a"],NO);NSString *old=NSUUID.UUID.UUIDString,*fresh=NSUUID.UUID.UUIDString;__block BOOL changed=NO;
    AxsCacheKeeperCapacityService *service=[[AxsCacheKeeperCapacityService alloc] initWithFolder:folder provider:^NSDictionary *(NSError **e) {
        (void)e;if (!changed) {changed=YES;ckrequest(folder,fresh,NO);}return plan;
    } writer:nil];
    ckrequest(folder,old,NO);[service tick];ckcheck(![ckresult(folder)[@"epoch"] isEqual:old],"provider-time replacement never publishes old epoch");
    ckfinish(service);ckcheck([ckresult(folder)[@"epoch"] isEqual:fresh] && [ckresult(folder)[@"state"] isEqual:@"complete"],"replacement uses a fresh provider plan");
}
static void cklateCancel(NSString *base) {
    NSString *root=ckdirectory(base,@"late-cancel-root");
    for (NSUInteger i=0;i<1200;i++) ckfile([root stringByAppendingPathComponent:[NSString stringWithFormat:@"f%lu",(unsigned long)i]],1);
    NSDictionary *plan=ckplan(@[ckroot(root,@"resource-1",@[@"test.a"])],@[@"test.a"],NO);
    NSString *folder=ckdirectory(base,@"late-cancel-status"),*a=NSUUID.UUID.UUIDString,*b=NSUUID.UUID.UUIDString;__block NSUInteger calls=0;
    AxsCacheKeeperCapacityService *service=[[AxsCacheKeeperCapacityService alloc] initWithFolder:folder provider:^NSDictionary *(NSError **e) {(void)e;calls++;return plan;} writer:nil];
    ckrequest(folder,a,NO);[service tick];ckrequest(folder,b,NO);[service tick];ckrequest(folder,a,YES);[service tick];
    ckcheck([ckresult(folder)[@"epoch"] isEqual:b] && [ckresult(folder)[@"state"] isEqual:@"running"] && calls==2,
        "late cancel A must not terminate active B");
    ckfinish(service);NSDictionary *result=ckresult(folder);
    ckcheck([result[@"epoch"] isEqual:b] && [result[@"state"] isEqual:@"complete"] && [result[@"roots"][0][@"measurement"][@"entries"] isEqual:@1201] && calls==2,
        "B completes real traversal despite stale cancel A");
    ckcheck(![service tick] && [ckresult(folder) isEqual:result],"residual cancel A cannot overwrite terminal B");
    NSString *unseen=NSUUID.UUID.UUIDString;ckrequest(folder,unseen,YES);ckfinish(service);
    ckcheck([ckresult(folder) isEqual:result] && calls==2,"unknown cancel cannot replace an already saved observation");
    __block NSUInteger coldCalls=0;
    AxsCacheKeeperCapacityService *cold=[[AxsCacheKeeperCapacityService alloc] initWithFolder:folder provider:^NSDictionary *(NSError **e) {(void)e;coldCalls++;return plan;} writer:nil];
    ckrequest(folder,a,YES);ckfinish(cold);
    ckcheck([ckresult(folder) isEqual:result] && coldCalls==0,"cold completed B cannot be overwritten by late cancel A");

    // A stale cancel published while provider B was running must also be ignored
    // at both publication checks, without recollecting source A.
    NSString *publication=ckdirectory(base,@"late-cancel-publication"),*p=NSUUID.UUID.UUIDString;__block NSUInteger publicationCalls=0;
    AxsCacheKeeperCapacityService *publish=[[AxsCacheKeeperCapacityService alloc] initWithFolder:publication provider:^NSDictionary *(NSError **e) {
        (void)e;publicationCalls++;ckrequest(publication,a,YES);return plan;
    } writer:nil];
    ckrequest(publication,p,NO);[publish tick];
    ckcheck([ckresult(publication)[@"epoch"] isEqual:p] && [ckresult(publication)[@"state"] isEqual:@"running"],"late cancel during provider cannot discard pending B publication");
    ckfinish(publish);ckcheck([ckresult(publication)[@"state"] isEqual:@"complete"] && publicationCalls==1,"pending B publication continues despite stale cancel");

    NSString *retryFolder=ckdirectory(base,@"late-cancel-retry"),*r=NSUUID.UUID.UUIDString;__block BOOL fail=YES;__block NSUInteger retryCalls=0;
    AxsCacheKeeperCapacityService *retry=[[AxsCacheKeeperCapacityService alloc] initWithFolder:retryFolder provider:^NSDictionary *(NSError **e) {(void)e;retryCalls++;return plan;}
        writer:^BOOL(NSDictionary *record,NSString *path) {
            if (fail) ckcheck([NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:NO attributes:nil error:nil],"actual late-cancel writer failure fixture");
            return axs_cachekeeper_capacity_atomic_write(record,path.stringByDeletingLastPathComponent,path.lastPathComponent,32*1024*1024,nil);
        }];
    ckrequest(retryFolder,r,NO);[retry tick];ckrequest(retryFolder,a,YES);[retry tick];
    ckcheck([NSFileManager.defaultManager removeItemAtPath:[retryFolder stringByAppendingPathComponent:@"capacityResult.plist"] error:nil],"remove isolated retry failure target");
    fail=NO;[NSThread sleepForTimeInterval:1.05];ckfinish(retry);NSDictionary *retryResult=ckresult(retryFolder);
    ckcheck([retryResult[@"epoch"] isEqual:r] && [retryResult[@"state"] isEqual:@"partial"] && [retryResult[@"failure"][@"code"] isEqual:@"writeFailed"] && retryCalls==1,
        "late cancel cannot replace B pending failed publication");

    NSString *restartFolder=ckdirectory(base,@"late-cancel-restart"),*s=NSUUID.UUID.UUIDString;
    @autoreleasepool {
        AxsCacheKeeperCapacityService *first=[[AxsCacheKeeperCapacityService alloc] initWithFolder:restartFolder provider:^NSDictionary *(NSError **e) {(void)e;return plan;} writer:nil];
        ckrequest(restartFolder,s,NO);[first tick];
    }
    ckrequest(restartFolder,a,YES);__block NSUInteger restartCalls=0;
    AxsCacheKeeperCapacityService *restarted=[[AxsCacheKeeperCapacityService alloc] initWithFolder:restartFolder provider:^NSDictionary *(NSError **e) {(void)e;restartCalls++;return plan;} writer:nil];
    ckfinish(restarted);ckcheck([ckresult(restartFolder)[@"epoch"] isEqual:s] && [ckresult(restartFolder)[@"state"] isEqual:@"interrupted"] && restartCalls==0,
        "late cancel cannot erase cold-restart B interruption");
}
static void ckrequestGates(NSString *base) {
    NSString *folder=ckdirectory(base,@"gates-status"),*root=ckdirectory(base,@"gates-container");NSString *canary=[root stringByAppendingPathComponent:@"appEnabled.plist"];
    NSData *before=[@"protected synthetic configuration" dataUsingEncoding:NSUTF8StringEncoding];ckcheck([before writeToFile:canary atomically:YES],"config canary fixture");__block NSUInteger calls=0;
    NSDictionary *plan=ckplan(@[ckroot(root,@"resource-1",@[@"test.a"])],@[@"test.a"],NO);
    AxsCacheKeeperCapacityService *service=[[AxsCacheKeeperCapacityService alloc] initWithFolder:folder provider:^NSDictionary *(NSError **e) {(void)e;calls++;return plan;} writer:nil];
    NSDictionary *bad=@{@"schemaVersion":@1,@"epoch":NSUUID.UUID.UUIDString,@"operation":@"start",@"path":root};
    ckcheck([bad writeToFile:ckrequestPath(folder) atomically:YES],"bad request fixture");[service tick];
    ckcheck(calls==0 && [ckresult(folder)[@"state"] isEqual:@"notMeasured"],"unknown request field cannot access provider or containers");
    ckrequest(folder,NSUUID.UUID.UUIDString,YES);ckfinish(service);ckcheck(calls==0 && [ckresult(folder)[@"state"] isEqual:@"cancelled"],"cancel without start never accesses provider");
    ckcheck([[NSData dataWithContentsOfFile:canary] isEqual:before],"requests do not alter configuration or private canary");
    NSError *error=nil;ckcheck(!axs_cachekeeper_capacity_write_request([folder stringByAppendingPathComponent:@"wrong.plist"],NSUUID.UUID.UUIDString,NO,&error) && error!=nil,"helpers require exact full file path");
    ckcheck([NSFileManager.defaultManager removeItemAtPath:ckrequestPath(folder) error:nil],"remove owned request fixture");
    ckcheck(!symlink(canary.fileSystemRepresentation,ckrequestPath(folder).fileSystemRepresentation),"request symlink fixture");[service tick];ckcheck(calls==0,"symlink request cannot reach provider");
}
static void ckexcluded(NSString *base) {
    NSString *folder=ckdirectory(base,@"excluded-status"),*root=ckdirectory(base,@"excluded-container");ckfile([root stringByAppendingPathComponent:@"keep"],900);
    NSDictionary *plan=ckplan(@[ckroot(root,@"resource-1",@[@"test.a",@"com.tencent.qy.xin"])],@[@"test.a",@"com.tencent.qy.xin"],NO);
    AxsCacheKeeperCapacityService *service=[[AxsCacheKeeperCapacityService alloc] initWithFolder:folder provider:^NSDictionary *(NSError **e) {(void)e;return plan;} writer:nil];
    ckrequest(folder,NSUUID.UUID.UUIDString,NO);ckfinish(service);NSDictionary *result=ckresult(folder);
    ckcheck([result[@"roots"] count]==0 && [result[@"totalRoots"] isEqual:@0] && [result[@"entries"][0][@"state"] isEqual:@"excluded"] &&
        [result[@"entries"][1][@"state"] isEqual:@"sourcePartial"] && [result[@"state"] isEqual:@"partial"],"shared excluded owner suppresses whole root and keeps coverage partial");
}
static void ckpartial(NSString *base) {
    NSString *folder=ckdirectory(base,@"partial-status"),*root=ckdirectory(base,@"partial-container");ckfile([root stringByAppendingPathComponent:@"keep"],7);
    NSDictionary *plan=ckplan(@[ckroot(root,@"resource-1",@[@"test.a"])],@[@"test.a"],YES);
    AxsCacheKeeperCapacityService *service=[[AxsCacheKeeperCapacityService alloc] initWithFolder:folder provider:^NSDictionary *(NSError **e) {(void)e;return plan;} writer:nil];
    ckrequest(folder,NSUUID.UUID.UUIDString,NO);ckfinish(service);NSDictionary *result=ckresult(folder);
    ckcheck([result[@"state"] isEqual:@"partial"] && [result[@"completedRoots"] isEqual:@1] && [result[@"failedRoots"] isEqual:@0] &&
        [result[@"entries"][0][@"state"] isEqual:@"sourcePartial"],"partial registry cannot produce complete measurement");
}
static void ckaliasReplacement(NSString *base) {
    NSString *folder=ckdirectory(base,@"alias-replace-status"),*root=ckdirectory(base,@"alias-first");
    for (NSUInteger i=0;i<800;i++) ckfile([root stringByAppendingPathComponent:[NSString stringWithFormat:@"f%lu",(unsigned long)i]],1);
    NSString *other=ckdirectory(base,@"alias-other-base"),*newRoot=ckdirectory(other,@"alias-first");ckfile([newRoot stringByAppendingPathComponent:@"different-data"],8192);
    NSString *parent=[base stringByAppendingPathComponent:@"alias-parent"];
    ckcheck(!symlink(base.fileSystemRepresentation,parent.fileSystemRepresentation),"alias original parent fixture");
    NSDictionary *plan=ckplan(@[ckroot(root,@"resource-1",@[@"test.a"]),ckroot([parent stringByAppendingPathComponent:@"alias-first"],@"resource-2",@[@"test.b"])],@[@"test.a",@"test.b"],NO);
    AxsCacheKeeperCapacityService *service=[[AxsCacheKeeperCapacityService alloc] initWithFolder:folder provider:^NSDictionary *(NSError **e) {(void)e;return plan;} writer:nil];
    ckrequest(folder,NSUUID.UUID.UUIDString,NO);[service tick];
    ckcheck(!unlink(parent.fileSystemRepresentation) && !symlink(other.fileSystemRepresentation,parent.fileSystemRepresentation),"replace actual registered alias with another directory");
    ckfinish(service);NSDictionary *result=ckresult(folder);
    ckcheck([result[@"state"] isEqual:@"partial"] && [result[@"failedRoots"] isEqual:@1] &&
        [result[@"roots"][0][@"measurement"][@"state"] isEqual:@"identityChanged"],"changed alias cannot attribute old measurement to union owners as complete");
}
static void ckremovedRequest(NSString *base) {
    NSString *folder=ckdirectory(base,@"removed-request-status"),*root=ckdirectory(base,@"removed-request-root");
    for (NSUInteger i=0;i<800;i++) ckfile([root stringByAppendingPathComponent:[NSString stringWithFormat:@"f%lu",(unsigned long)i]],1);
    NSDictionary *plan=ckplan(@[ckroot(root,@"resource-1",@[@"test.a"])],@[@"test.a"],NO);
    AxsCacheKeeperCapacityService *service=[[AxsCacheKeeperCapacityService alloc] initWithFolder:folder provider:^NSDictionary *(NSError **e) {(void)e;return plan;} writer:nil];
    ckrequest(folder,NSUUID.UUID.UUIDString,NO);[service tick];
    ckcheck([NSFileManager.defaultManager removeItemAtPath:ckrequestPath(folder) error:nil],"remove own active request");ckfinish(service);
    ckcheck([ckresult(folder)[@"state"] isEqual:@"cancelled"] && [ckresult(folder)[@"completedRoots"] isEqual:@0],"missing request closes current root without successful completion");
}
static void ckrootBudget(NSString *base) {
    NSString *folder=ckdirectory(base,@"budget-status");NSMutableArray *roots=[NSMutableArray new];
    for (NSUInteger i=0;i<4097;i++) [roots addObject:ckroot([base stringByAppendingPathComponent:[NSString stringWithFormat:@"not-opened-%lu",(unsigned long)i]],
        [NSString stringWithFormat:@"resource-%lu",(unsigned long)i+1],@[@"test.a"])];
    NSDictionary *plan=ckplan(roots,@[@"test.a"],NO);
    AxsCacheKeeperCapacityService *service=[[AxsCacheKeeperCapacityService alloc] initWithFolder:folder provider:^NSDictionary *(NSError **e) {(void)e;return plan;} writer:nil];
    ckrequest(folder,NSUUID.UUID.UUIDString,NO);ckfinish(service);NSDictionary *result=ckresult(folder);
    ckcheck([result[@"state"] isEqual:@"partial"] && [result[@"roots"] count]==0 && [result[@"failure"][@"code"] isEqual:@"rootBudget"],"over-budget source never opens roots or silently truncates complete coverage");
}
static void ckproviderFailure(NSString *base) {
    NSString *folder=ckdirectory(base,@"provider-failure-status");
    AxsCacheKeeperCapacityService *service=[[AxsCacheKeeperCapacityService alloc] initWithFolder:folder provider:^NSDictionary *(NSError **e) {
        if (e) *e=[NSError errorWithDomain:@"SyntheticProviderUnavailable" code:1 userInfo:nil];return nil;
    } writer:nil];
    ckrequest(folder,NSUUID.UUID.UUIDString,NO);ckfinish(service);NSDictionary *result=ckresult(folder);
    ckcheck([result[@"state"] isEqual:@"unavailable"] && [result[@"failure"][@"stage"] isEqual:@"provider"] && [result[@"roots"] count]==0,"unavailable provider yields explicit saved failure without containers");
}
static void ckactualMissingRoot(NSString *base) {
    NSString *folder=ckdirectory(base,@"missing-root-status");
    NSDictionary *plan=ckplan(@[ckroot([base stringByAppendingPathComponent:@"missing-container"],@"resource-1",@[@"test.a"])],@[@"test.a"],NO);
    AxsCacheKeeperCapacityService *service=[[AxsCacheKeeperCapacityService alloc] initWithFolder:folder provider:^NSDictionary *(NSError **e) {(void)e;return plan;} writer:nil];
    ckrequest(folder,NSUUID.UUID.UUIDString,NO);ckfinish(service);NSDictionary *result=ckresult(folder);
    ckcheck([result[@"state"] isEqual:@"partial"] && [result[@"failedRoots"] isEqual:@1] &&
        [result[@"roots"][0][@"measurement"][@"state"] isEqual:@"readError"],"actual missing root is failed coverage not empty successful storage");
}
static void ckunobservedRoot(NSString *base) {
    for (NSNumber *wasFile in @[@NO,@YES]) {
        NSString *suffix=wasFile.boolValue ? @"file" : @"missing";
        NSString *folder=ckdirectory(base,[@"unobserved-status-" stringByAppendingString:suffix]);
        NSString *waiting=ckdirectory(base,[@"first-root-" stringByAppendingString:suffix]);
        for (NSUInteger i=0;i<800;i++) ckfile([waiting stringByAppendingPathComponent:[NSString stringWithFormat:@"f%lu",(unsigned long)i]],1);
        NSString *late=[base stringByAppendingPathComponent:[@"unobserved-root-" stringByAppendingString:suffix]];
        if (wasFile.boolValue) ckfile(late,27);
        NSDictionary *plan=ckplan(@[ckroot(waiting,@"resource-1",@[@"test.a"]),ckroot(late,@"resource-2",@[@"test.b"])],@[@"test.a",@"test.b"],NO);
        AxsCacheKeeperCapacityService *service=[[AxsCacheKeeperCapacityService alloc] initWithFolder:folder provider:^NSDictionary *(NSError **e) {(void)e;return plan;} writer:nil];
        ckrequest(folder,NSUUID.UUID.UUIDString,NO);[service tick];
        if (wasFile.boolValue) ckcheck([NSFileManager.defaultManager removeItemAtPath:late error:nil],"replace isolated non-directory registration");
        NSString *newRoot=ckdirectory(base,[@"unobserved-root-" stringByAppendingString:suffix]);ckfile([newRoot stringByAppendingPathComponent:@"new-data"],8192);
        ckfinish(service);NSDictionary *result=ckresult(folder),*row=result[@"roots"][1];
        ckcheck([result[@"state"] isEqual:@"partial"] && [result[@"completedRoots"] isEqual:@1] && [result[@"failedRoots"] isEqual:@1] &&
            [row[@"measurement"][@"state"] isEqual:@"readError"] && [row[@"measurement"][@"entries"] isEqual:@0],
            "unobserved source root cannot measure a later created directory as complete");
    }
}
static NSMutableDictionary *ckmutablePlist(NSDictionary *value) {
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    return [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainersAndLeaves format:nil error:nil];
}
static void ckbadTree(NSDictionary *record,void (^change)(NSMutableDictionary *),const char *message) {
    NSMutableDictionary *copy=ckmutablePlist(record),*measurement=copy[@"roots"][0][@"measurement"];change(measurement);
    ckcheck(!axs_cachekeeper_capacity_measurement(measurement) && [axs_cachekeeper_capacity_projection(copy)[@"state"] isEqual:@"invalid"],message);
}
static void cknodeProjection(NSString *base) {
    NSString *folder=ckdirectory(base,@"node-projection-status"),*root=ckdirectory(base,@"node-projection-root");
    NSString *library=ckdirectory(root,@"Library"),*caches=ckdirectory(library,@"Caches"),*leaf=ckdirectory(caches,@"private-leaf");
    ckfile([leaf stringByAppendingPathComponent:@"private-file"],123);ckfile([root stringByAppendingPathComponent:@"direct-file"],8192);
    NSString *documents=ckdirectory(root,@"Documents");ckfile([documents stringByAppendingPathComponent:@"document-canary"],456);
    ckdirectory(root,@"tmp");ckdirectory(library,@"Application Support");
    NSDictionary *plan=ckplan(@[ckroot(root,@"resource-1",@[@"test.a"])],@[@"test.a"],NO);
    AxsCacheKeeperCapacityService *service=[[AxsCacheKeeperCapacityService alloc] initWithFolder:folder provider:^NSDictionary *(NSError **e) {(void)e;return plan;} writer:nil];
    ckrequest(folder,NSUUID.UUID.UUIDString,NO);ckfinish(service);NSDictionary *record=ckresult(folder),*measurement=record[@"roots"][0][@"measurement"];
    ckcheck([record[@"state"] isEqual:@"complete"] && axs_cachekeeper_capacity_measurement(measurement)!=nil,"real depth-three tree and parent direct-file remainder are valid");
    NSArray *nodes=measurement[@"nodes"];__block NSUInteger cacheIndex=NSNotFound,libraryIndex=NSNotFound,leafIndex=NSNotFound;NSMutableArray *children=[NSMutableArray new];
    for (NSUInteger i=0;i<nodes.count;i++) {
        if ([nodes[i][@"category"] isEqual:@"Caches"]) cacheIndex=i;
        if ([nodes[i][@"category"] isEqual:@"Library"]) libraryIndex=i;
        if ([nodes[i][@"parent"] isEqual:@1]) [children addObject:@(i)];
    }
    ckcheck(cacheIndex!=NSNotFound && libraryIndex!=NSNotFound,"real fixture contains Library and Caches");
    for (NSUInteger i=0;i<nodes.count;i++) if ([nodes[i][@"parent"] isEqual:nodes[cacheIndex][@"id"]]) leafIndex=i;
    ckcheck(leafIndex!=NSNotFound && children.count>=2 && [nodes[leafIndex][@"entries"] unsignedLongLongValue]>=2,
        "depth-three leaf retains a direct file entry for an isolated depth RED");
    ckbadTree(record,^(NSMutableDictionary *m){m[@"nodes"][cacheIndex][@"parent"]=@999;},"missing anonymous parent is invalid");
    ckbadTree(record,^(NSMutableDictionary *m){m[@"nodes"][cacheIndex][@"parent"]=m[@"nodes"][cacheIndex][@"id"];},"self parent is invalid");
    ckbadTree(record,^(NSMutableDictionary *m){m[@"nodes"][libraryIndex][@"category"]=@"Caches";},"cache category outside Library depth two is invalid");
    ckbadTree(record,^(NSMutableDictionary *m){m[@"nodes"][cacheIndex][@"parent"]=@1;},"cache category with root parent is invalid");
    ckbadTree(record,^(NSMutableDictionary *m){m[@"nodes"][leafIndex][@"category"]=@"Documents";},"Documents category below depth one is invalid");
    ckbadTree(record,^(NSMutableDictionary *m){
        [m[@"nodes"] addObject:[@{@"id":@(nodes.count+1),@"parent":nodes[leafIndex][@"id"],@"category":@"unknown",@"logicalBytes":@0,@"allocatedBytes":@0,@"entries":@1} mutableCopy]];
    },"anonymous directory depth four is invalid");
    for (NSString *key in @[@"logicalBytes",@"allocatedBytes",@"entries"]) {
        ckbadTree(record,^(NSMutableDictionary *m){m[@"nodes"][[children[0] unsignedIntegerValue]][key]=@([m[key] unsignedLongLongValue]+1);},"child cannot exceed parent aggregate");
        ckbadTree(record,^(NSMutableDictionary *m){
            // Raise both children to the individual bound: descendants remain
            // valid, and only the sibling sum exceeds their parent's budget.
            uint64_t each=[m[key] unsignedLongLongValue]-([key isEqual:@"entries"] ? 1 : 0);
            ckcheck(each>0,"sibling fixture has a positive individual bound");
            m[@"nodes"][[children[0] unsignedIntegerValue]][key]=@(each);m[@"nodes"][[children[1] unsignedIntegerValue]][key]=@(each);
        },"direct sibling sums cannot exceed parent aggregate");
    }
    ckbadTree(record,^(NSMutableDictionary *m){
        uint64_t sum=0;
        for (NSNumber *index in children) sum+=[m[@"nodes"][[index unsignedIntegerValue]][@"entries"] unsignedLongLongValue];
        uint64_t total=[m[@"entries"] unsignedLongLongValue];
        ckcheck(sum<total,"parent entry fixture retains a real direct-file remainder");
        NSMutableDictionary *child=m[@"nodes"][[children[0] unsignedIntegerValue]];
        // Preserve every descendant and raise one child so direct children sum
        // to total exactly. Dropping maximum-- would now accept this bad tree.
        child[@"entries"]=@([child[@"entries"] unsignedLongLongValue]+total-sum);
    },"directory entries must retain the parent's own entry");
    ckbadTree(record,^(NSMutableDictionary *m){m[@"nodes"][leafIndex][@"entries"]=@0;},"directory node cannot have zero entries");
    ckbadTree(record,^(NSMutableDictionary *m){m[@"nodeLimit"]=@1;},"anonymous node budget is enforced");
    ckbadTree(record,^(NSMutableDictionary *m){m[@"nodes"][leafIndex][@"logicalBytes"]=@9007199254740992ULL;},"unsafe anonymous aggregate is invalid");
}
static void ckprojection(NSString *base) {
    ckcheck([axs_cachekeeper_capacity_projection(nil)[@"state"] isEqual:@"notMeasured"] && [axs_cachekeeper_capacity_projection(@{@"schemaVersion":@1,@"state":@"invalid"})[@"state"] isEqual:@"invalid"],"projection distinguishes missing and invalid");
    NSString *folder=[base stringByAppendingPathComponent:@"shared-status"];NSMutableDictionary *record=[ckresult(folder) mutableCopy];record[@"privatePath"]=base;
    ckcheck(!axs_cachekeeper_capacity_projection(record)[@"privatePath"],"projection drops unknown private fields");
    record[@"totalRoots"]=@YES;ckcheck([axs_cachekeeper_capacity_projection(record)[@"state"] isEqual:@"invalid"],"boolean is not a numeric count");
    record=[ckresult(folder) mutableCopy];record[@"updatedAt"]=@9007199254740992ULL;ckcheck([axs_cachekeeper_capacity_projection(record)[@"state"] isEqual:@"invalid"],"unsafe numeric value invalidates known field");
    record=[ckresult(folder) mutableCopy];record[@"updatedAt"]=@0;record[@"finishedAt"]=@0;ckcheck([axs_cachekeeper_capacity_projection(record)[@"state"] isEqual:@"complete"],"wall-clock correction does not invalidate monotonic measurement");
    NSDictionary *original=ckresult(folder);NSMutableDictionary *row=[original[@"roots"][0] mutableCopy],*measurement=[row[@"measurement"] mutableCopy];
    measurement[@"uniqueInodes"]=@0;row[@"measurement"]=measurement;record=[original mutableCopy];record[@"roots"]=@[row];
    ckcheck([axs_cachekeeper_capacity_projection(record)[@"state"] isEqual:@"invalid"],"inconsistent inode counts cannot be projected as complete");
    row=[original[@"roots"][0] mutableCopy];row[@"owners"]=@[@"test.a"];record=[original mutableCopy];record[@"roots"]=@[row];
    ckcheck([axs_cachekeeper_capacity_projection(record)[@"state"] isEqual:@"invalid"],"saved root and entry ownership must agree in both directions");
    record=[original mutableCopy];record[@"sourceSampledAt"]=@101;
    ckcheck([axs_cachekeeper_capacity_projection(record)[@"state"] isEqual:@"invalid"],"saved source timestamp must match its own registry observation");
    row=[original[@"roots"][0] mutableCopy];measurement=[row[@"measurement"] mutableCopy];NSMutableDictionary *node=[measurement[@"nodes"][0] mutableCopy];
    node[@"category"]=@"Caches";measurement[@"nodes"]=@[node];row[@"measurement"]=measurement;record=[original mutableCopy];record[@"roots"]=@[row];
    ckcheck([axs_cachekeeper_capacity_projection(record)[@"state"] isEqual:@"invalid"],"root category cannot invent a cache attribution");
    NSError *error=nil;NSString *missing=[[ckdirectory(base,@"missing-result-status") stringByAppendingPathComponent:@"capacityResult.plist"] copy];
    ckcheck([axs_cachekeeper_capacity_read_result(missing,&error)[@"state"] isEqual:@"notMeasured"] && !error,"missing file is not a malformed saved observation");
    ckcheck(!symlink([folder stringByAppendingPathComponent:@"capacityResult.plist"].fileSystemRepresentation,missing.fileSystemRepresentation),"result symlink fixture");
    ckcheck([axs_cachekeeper_capacity_read_result(missing,&error)[@"state"] isEqual:@"invalid"] && error!=nil,"result read rejects symlink without following it");
}
int main(int argc,const char **argv) {
    @autoreleasepool {
        ckcheck(argc==3,"expected fixture directory and case");NSString *base=[NSString stringWithUTF8String:argv[1]],*name=[NSString stringWithUTF8String:argv[2]];
        if ([name isEqual:@"all"] || [name isEqual:@"shared"]) ckshared(base);
        if ([name isEqual:@"all"] || [name isEqual:@"cancel"]) ckcancel(base);
        if ([name isEqual:@"all"] || [name isEqual:@"save"]) cksave(base);
        if ([name isEqual:@"all"] || [name isEqual:@"restart"]) ckrestart(base);
        if ([name isEqual:@"all"] || [name isEqual:@"replace"]) ckreplacement(base);
        if ([name isEqual:@"all"] || [name isEqual:@"late-cancel"]) cklateCancel(base);
        if ([name isEqual:@"all"] || [name isEqual:@"gates"]) ckrequestGates(base);
        if ([name isEqual:@"all"] || [name isEqual:@"excluded"]) ckexcluded(base);
        if ([name isEqual:@"all"] || [name isEqual:@"partial"]) ckpartial(base);
        if ([name isEqual:@"all"] || [name isEqual:@"alias-replace"]) ckaliasReplacement(base);
        if ([name isEqual:@"all"] || [name isEqual:@"unobserved"]) ckunobservedRoot(base);
        if ([name isEqual:@"all"] || [name isEqual:@"nodes"]) cknodeProjection(base);
        if ([name isEqual:@"all"]) {ckremovedRequest(base);ckrootBudget(base);ckproviderFailure(base);ckactualMissingRoot(base);}
        if ([name isEqual:@"all"]) ckprojection(base);
        puts("PASS: capacity service real metadata, request gates, shared aliases, cancellation, persistence and restart");
    }return 0;
}
