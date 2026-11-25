#import <Foundation/Foundation.h>
#import "../AxsCacheKeeperCapacityService.h"
#import "../AxsCacheKeeperCapacityStatus.h"
#import "../AxsCacheKeeperCapacity.h"
#include <fcntl.h>
#include <unistd.h>
#include <sys/time.h>

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
    NSDictionary *measurement=result[@"roots"][0][@"measurement"],*failure=measurement[@"sourceFailure"];
    ckcheck([failure[@"stage"] isEqual:@"sourceStat"] && [failure[@"reason"] isEqual:@"statFailed"] &&
        [failure[@"errorDomain"] isEqual:@"posix"] && [failure[@"errorCode"] isEqual:@(ENOENT)] && !measurement[@"cursorErrors"],
        "missing source preserves actual lstat errno without a synthetic cursor");
    ckcheck([result[@"lifecycle"][@"cursorClosure"] isEqual:@"notObserved"] && !result[@"lifecycle"][@"cursorClosedAt"],
        "source failure without cursor never claims observed cursor closure");
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
        NSDictionary *failure=row[@"measurement"][@"sourceFailure"];
        ckcheck([failure[@"stage"] isEqual:@"sourceStat"] &&
            [failure[@"reason"] isEqual:(wasFile.boolValue ? @"notDirectory" : @"statFailed")] &&
            [failure[@"errorDomain"] isEqual:(wasFile.boolValue ? @"none" : @"posix")] &&
            (wasFile.boolValue ? !failure[@"errorCode"] : [failure[@"errorCode"] isEqual:@(ENOENT)]) &&
            !row[@"measurement"][@"cursorErrors"],
            "source missing and non-directory evidence survives later replacement without cursor errno");
    }
}
static NSMutableDictionary *ckmutablePlist(NSDictionary *value) {
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    return [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainersAndLeaves format:nil error:nil];
}
static void cksourceAliasBeforeOpen(NSString *base) {
    for (NSString *mode in @[@"identity",@"missing",@"file"]) {
        NSString *fixture=ckdirectory(base,[@"source-alias-" stringByAppendingString:mode]);
        NSString *folder=ckdirectory(fixture,@"status"),*first=ckdirectory(fixture,@"first");
        for (NSUInteger i=0;i<800;i++) ckfile([first stringByAppendingPathComponent:[NSString stringWithFormat:@"f%lu",(unsigned long)i]],1);
        NSString *second=ckdirectory(fixture,@"second"),*moved=[fixture stringByAppendingPathComponent:@"moved"];
        NSDictionary *plan=ckplan(@[ckroot(first,@"resource-1",@[@"test.a"]),ckroot(second,@"resource-2",@[@"test.b"])],@[@"test.a",@"test.b"],NO);
        __block BOOL replaced=NO;
        AxsCacheKeeperCapacityService *service=[[AxsCacheKeeperCapacityService alloc] initWithFolder:folder provider:^NSDictionary *(NSError **e) {(void)e;return plan;}
            writer:^BOOL(NSDictionary *record,NSString *path) {
                BOOL ok=axs_cachekeeper_capacity_atomic_write(record,path.stringByDeletingLastPathComponent,path.lastPathComponent,32*1024*1024,nil);
                if (!replaced) {replaced=YES;ckcheck(!rename(second.fileSystemRepresentation,moved.fileSystemRepresentation),"move source alias fixture");
                    if ([mode isEqual:@"identity"]) {ckdirectory(fixture,@"second");ckfile([second stringByAppendingPathComponent:@"must-not-open"],8192);}
                    else if ([mode isEqual:@"file"]) ckfile(second,8192);}
                return ok;
            }];
        ckrequest(folder,NSUUID.UUID.UUIDString,NO);ckfinish(service);NSDictionary *result=ckresult(folder),*m=result[@"roots"][1][@"measurement"];
        NSString *reason=[mode isEqual:@"identity"] ? @"identityChanged" : [mode isEqual:@"missing"] ? @"statFailed" : @"notDirectory";
        NSDictionary *failure=m[@"sourceFailure"];
        ckcheck([result[@"state"] isEqual:@"partial"] && [m[@"state"] isEqual:@"identityChanged"] && [m[@"entries"] isEqual:@0] &&
            [failure[@"stage"] isEqual:@"aliasRecheck"] && [failure[@"reason"] isEqual:reason] &&
            [failure[@"errorDomain"] isEqual:([mode isEqual:@"missing"] ? @"posix" : @"none")] &&
            ([mode isEqual:@"missing"] ? [failure[@"errorCode"] isEqual:@(ENOENT)] : !failure[@"errorCode"]) && !m[@"cursorErrors"],
            "alias mismatch before open has source evidence without opening replacement or cursor errno");
    }
}
static NSDictionary *ckerrorSummary(NSUInteger enumeration,NSUInteger stat,BOOL truncated,NSUInteger omitted,NSArray *errors) {
    return @{@"enumerationErrors":@(enumeration),@"statErrors":@(stat),@"errorsTruncated":@(truncated),@"omittedErrorCount":@(omitted),@"errors":errors};
}
static NSDictionary *ckerrorRow(NSString *stage,NSUInteger count) {
    return @{@"stage":stage,@"reason":@"readFailure",@"errorDomain":@"posix",@"errorCode":@(EIO),@"count":@(count)};
}
static void ckerrorSchema(NSString *base) {
    // Removing count reconciliation or complete/error exclusion must fail here.
    NSString *folder=ckdirectory(base,@"error-schema-status"),*root=ckdirectory(base,@"error-schema-root");ckfile([root stringByAppendingPathComponent:@"file"],1);
    NSDictionary *plan=ckplan(@[ckroot(root,@"resource-1",@[@"test.a"])],@[@"test.a"],NO);
    AxsCacheKeeperCapacityService *service=[[AxsCacheKeeperCapacityService alloc] initWithFolder:folder provider:^NSDictionary *(NSError **e) {(void)e;return plan;} writer:nil];
    ckrequest(folder,NSUUID.UUID.UUIDString,NO);ckfinish(service);NSDictionary *original=ckresult(folder);
    ckcheck([original[@"state"] isEqual:@"complete"],"schema fixture is an actual complete measurement");
    NSDictionary *enumOne=ckerrorRow(@"enumerate",1),*statOne=ckerrorRow(@"entryStat",1);
    NSArray *invalid=@[ckerrorSummary(0,0,NO,0,@[enumOne]),ckerrorSummary(1,0,NO,0,@[]),
        ckerrorSummary(0,1,NO,0,@[enumOne]),ckerrorSummary(1,0,YES,2,@[enumOne]),
        ckerrorSummary(0,0,YES,0,@[]),ckerrorSummary(1,0,NO,1,@[enumOne]),
        ckerrorSummary(1,0,NO,0,@[ckerrorRow(@"enumerate",2)])];
    for (NSDictionary *errors in invalid) {
        NSMutableDictionary *bad=ckmutablePlist(original);bad[@"state"]=@"partial";bad[@"completedRoots"]=@0;bad[@"failedRoots"]=@1;
        bad[@"roots"][0][@"measurement"][@"state"]=@"readError";bad[@"roots"][0][@"measurement"][@"cursorErrors"]=errors;
        ckcheck([axs_cachekeeper_capacity_projection(bad)[@"state"] isEqual:@"invalid"],"contradictory cursor counts and detail fail closed");
    }
    NSMutableDictionary *bad=ckmutablePlist(original);bad[@"roots"][0][@"measurement"][@"cursorErrors"]=ckerrorSummary(1,0,NO,0,@[enumOne]);
    ckcheck([axs_cachekeeper_capacity_projection(bad)[@"state"] isEqual:@"invalid"],"complete measurement cannot carry cursor errors");
    bad=ckmutablePlist(original);bad[@"roots"][0][@"measurement"][@"sourceFailure"]=@{@"stage":@"sourceStat",@"reason":@"notDirectory",@"errorDomain":@"none"};
    ckcheck([axs_cachekeeper_capacity_projection(bad)[@"state"] isEqual:@"invalid"],"complete measurement cannot carry source failure");
    NSArray *badSources=@[
        @{@"stage":@"inputValidation",@"reason":@"statFailed",@"errorDomain":@"posix",@"errorCode":@(ENOENT)},
        @{@"stage":@"sourceStat",@"reason":@"identityChanged",@"errorDomain":@"none"},
        @{@"stage":@"sourceStat",@"reason":@"statFailed",@"errorDomain":@"posix",@"errorCode":@YES},
        @{@"stage":@"sourceStat",@"reason":@"statFailed",@"errorDomain":@"posix",@"errorCode":@0},
        @{@"stage":@"sourceStat",@"reason":@"notDirectory",@"errorDomain":@"none",@"errorCode":@(ENOTDIR)}];
    for (NSDictionary *failure in badSources) {
        bad=ckmutablePlist(original);bad[@"state"]=@"partial";bad[@"completedRoots"]=@0;bad[@"failedRoots"]=@1;
        bad[@"roots"][0][@"measurement"][@"state"]=@"readError";bad[@"roots"][0][@"measurement"][@"sourceFailure"]=failure;
        ckcheck([axs_cachekeeper_capacity_projection(bad)[@"state"] isEqual:@"invalid"],"source failure rejects invented domain errno and stage combinations");
    }
    NSArray *valid=@[ckerrorSummary(1,1,NO,0,@[enumOne,statOne]),ckerrorSummary(3,1,YES,2,@[enumOne,statOne]),
        ckerrorSummary(UINT32_MAX,0,YES,0,@[ckerrorRow(@"enumerate",UINT32_MAX)]),
        ckerrorSummary(UINT32_MAX,1,YES,1,@[ckerrorRow(@"enumerate",UINT32_MAX)]),
        ckerrorSummary(UINT32_MAX,UINT32_MAX,YES,UINT32_MAX,@[enumOne,statOne]),
        ckerrorSummary(UINT32_MAX,0,YES,0,@[ckerrorRow(@"enumerate",UINT32_MAX),
            @{@"stage":@"enumerate",@"reason":@"permissionDenied",@"errorDomain":@"posix",@"errorCode":@(EACCES),@"count":@1}])];
    for (NSDictionary *errors in valid) {
        NSMutableDictionary *record=ckmutablePlist(original);record[@"state"]=@"partial";record[@"completedRoots"]=@0;record[@"failedRoots"]=@1;
        record[@"roots"][0][@"measurement"][@"state"]=@"readError";record[@"roots"][0][@"measurement"][@"cursorErrors"]=errors;
        ckcheck(axs_cachekeeper_capacity_atomic_write(record,folder,@"capacityResult.plist",32*1024*1024,nil),"write valid error schema fixture");
        NSDictionary *closed=ckresult(folder);NSData *json=[NSJSONSerialization dataWithJSONObject:closed options:0 error:nil];
        NSDictionary *decoded=json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
        ckcheck([closed[@"state"] isEqual:@"partial"] && [decoded[@"roots"][0][@"measurement"][@"cursorErrors"] isEqual:errors],
            "valid truncated and saturated errors survive saved result and JSON");
    }
    NSMutableDictionary *legacy=ckmutablePlist(original);[legacy[@"roots"][0][@"measurement"] removeObjectForKey:@"cursorErrors"];
    ckcheck([axs_cachekeeper_capacity_projection(legacy)[@"state"] isEqual:@"complete"],"legacy measurement without errors stays optional");
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
    record=[ckresult(folder) mutableCopy];NSString *summaryEpoch=record[@"epoch"];
    uint64_t finishedAt=[record[@"finishedAt"] unsignedLongLongValue];
    ckcheck(finishedAt>1,"service terminal fixture has a positive finishedAt");
    NSDictionary *binding=@{@"epoch":summaryEpoch,@"terminalState":record[@"state"],@"terminalFinishedAt":record[@"finishedAt"],@"summarizedAt":@(finishedAt+1)};
    NSDictionary *closedBinding=axs_cachekeeper_capacity_summary_binding(binding,record);
    ckcheck([closedBinding[@"state"] isEqual:@"current"] && [closedBinding[@"epoch"] isEqual:summaryEpoch],"summary binds the same terminal epoch after finishedAt");
    ckcheck([axs_cachekeeper_capacity_summary_binding(closedBinding,record) isEqual:closedBinding],"closed five-field binding survives reprojection");
    NSMutableDictionary *wrong=[binding mutableCopy];wrong[@"epoch"]=NSUUID.UUID.UUIDString;
    ckcheck([axs_cachekeeper_capacity_summary_binding(wrong,record)[@"state"] isEqual:@"stale"],"summary from another epoch stays stale");
    wrong=[binding mutableCopy];wrong[@"summarizedAt"]=@(finishedAt-1);
    ckcheck([axs_cachekeeper_capacity_summary_binding(wrong,record)[@"state"] isEqual:@"stale"],"summary before terminal finish stays stale");
    wrong=[binding mutableCopy];wrong[@"terminalFinishedAt"]=@YES;
    ckcheck([axs_cachekeeper_capacity_summary_binding(wrong,record)[@"state"] isEqual:@"stale"],"boolean terminal time is rejected");
    wrong=[binding mutableCopy];wrong[@"extraPrivatePath"]=@"private-canary";
    ckcheck([axs_cachekeeper_capacity_summary_binding(wrong,record)[@"state"] isEqual:@"stale"],"unknown binding fields fail closed");
    wrong=[binding mutableCopy];wrong[@"state"]=@"current";wrong[@"extraPrivatePath"]=@"private-canary";
    ckcheck([axs_cachekeeper_capacity_summary_binding(wrong,record)[@"state"] isEqual:@"stale"],"unknown binding fields fail closed when state is present");
    for (NSString *key in @[@"epoch",@"terminalState",@"terminalFinishedAt",@"summarizedAt"]) {
        wrong=[closedBinding mutableCopy];[wrong removeObjectForKey:key];
        ckcheck([axs_cachekeeper_capacity_summary_binding(wrong,record)[@"state"] isEqual:@"stale"],"missing required binding field fails closed");
        wrong[@"extraPrivatePath"]=@"private-canary";
        ckcheck([axs_cachekeeper_capacity_summary_binding(wrong,record)[@"state"] isEqual:@"stale"],"unknown field cannot replace a required binding field");
    }
    ckcheck([axs_cachekeeper_capacity_summary_binding(nil,record)[@"state"] isEqual:@"unknown"],"legacy record without summary binding remains unknown");
    NSDictionary *report=@{@"capacityMeasurement":@{@"epoch":summaryEpoch,@"state":record[@"state"],@"finishedAt":record[@"finishedAt"],@"summaryBinding":closedBinding}};
    ckcheck(axs_cachekeeper_capacity_summary_is_current(report) && axs_cachekeeper_capacity_report_exportable(report),"current summary is exportable only while bound to terminal measurement");
    NSDictionary *unbound=axs_cachekeeper_capacity_report_measurement(record,104);
    ckcheck([unbound[@"summaryBinding"][@"state"] isEqual:@"unknown"],"diagnostic summarization cannot invent a current binding");
    NSMutableDictionary *staleInput=[record mutableCopy];staleInput[@"summaryBinding"]=@{@"state":@"stale"};
    NSDictionary *preserved=axs_cachekeeper_capacity_report_measurement(staleInput,104);
    ckcheck([preserved[@"summaryBinding"][@"state"] isEqual:@"stale"],"diagnostic projection preserves an upstream stale binding");
    NSMutableDictionary *staleReport=[report mutableCopy];staleReport[@"capacityMeasurement"]=@{@"epoch":summaryEpoch,@"state":record[@"state"],@"finishedAt":record[@"finishedAt"],@"summaryBinding":@{@"state":@"stale"}};
    ckcheck(!axs_cachekeeper_capacity_report_exportable(staleReport),"stale measurement summary is not exportable");
    NSDictionary *runningReport=@{@"capacityMeasurement":@{@"schemaVersion":@1,@"state":@"running",@"epoch":summaryEpoch}};
    ckcheck(!axs_cachekeeper_capacity_report_exportable(runningReport),"running measurement is never exportable as current");
    ckcheck(axs_cachekeeper_capacity_report_exportable(@{@"capacityMeasurement":@{@"schemaVersion":@1,@"state":@"notMeasured"}}),"no measurement does not block ordinary diagnostic export");
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
static NSDictionary *ckhistory(NSDictionary *record,NSString *epoch) {
    for (NSDictionary *item in record[@"terminalHistory"][@"records"]) if ([item[@"epoch"] isEqual:epoch]) return item;
    return nil;
}
static void ckhistoryBehavior(NSString *base) {
    NSString *folder=ckdirectory(base,@"history-status"),*root=ckdirectory(base,@"history-root");
    for (NSUInteger i=0;i<800;i++) ckfile([root stringByAppendingPathComponent:[NSString stringWithFormat:@"private-%lu",(unsigned long)i]],1);
    NSDictionary *plan=ckplan(@[ckroot(root,@"resource-1",@[@"test.a"])],@[@"test.a"],NO);
    AxsCacheKeeperCapacityService *service=[[AxsCacheKeeperCapacityService alloc] initWithFolder:folder provider:^NSDictionary *(NSError **e) {(void)e;return plan;} writer:nil];
    NSString *a=NSUUID.UUID.UUIDString,*b=NSUUID.UUID.UUIDString;ckrequest(folder,a,NO);[service tick];ckrequest(folder,a,YES);ckfinish(service);
    ckrequest(folder,b,NO);ckfinish(service);NSDictionary *result=ckresult(folder),*item=ckhistory(result,a);
    ckcheck([item[@"state"] isEqual:@"cancelled"] && [item[@"resultPublication"] isEqual:@"saved"] &&
        item[@"publicationObservedAt"] && item[@"lifecycle"][@"cancelObservedAt"],
        "saved cancellation remains in next epoch terminal history");
    ckcheck([item[@"lifecycle"][@"cursorClosure"] isEqual:@"observedZero"] && item[@"lifecycle"][@"cursorClosedAt"] &&
        [result[@"lifecycle"][@"previousObservedEpoch"] isEqual:a],"history links consecutive observations with real cursor closure evidence");
    NSString *json=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:result[@"terminalHistory"] options:0 error:nil] encoding:NSUTF8StringEncoding];
    ckcheck(![json containsString:root] && ![json containsString:@"private-"] && ![json containsString:@"resource-"],"terminal history contains no paths names or root identities");
    service=nil;service=[[AxsCacheKeeperCapacityService alloc] initWithFolder:folder provider:^NSDictionary *(NSError **e) {(void)e;return plan;} writer:nil];
    for (NSUInteger i=0;i<18;i++) {ckrequest(folder,NSUUID.UUID.UUIDString,NO);ckfinish(service);}
    result=ckresult(folder);NSArray *records=result[@"terminalHistory"][@"records"];
    ckcheck(records.count==16 && [result[@"terminalHistory"][@"omittedCount"] unsignedIntegerValue]==3 && !ckhistory(result,a),
        "history has a fixed bound and visible omissions after restart");
    NSMutableSet *epochs=[NSMutableSet new];for (NSDictionary *row in records) [epochs addObject:row[@"epoch"]];
    ckcheck(epochs.count==records.count,"history retry and recovery never duplicate epochs");
    NSMutableDictionary *legacy=[result mutableCopy];[legacy removeObjectForKey:@"terminalHistory"];[legacy removeObjectForKey:@"lifecycle"];
    ckcheck([axs_cachekeeper_capacity_projection(legacy)[@"state"] isEqual:@"complete"],"old schema one records remain readable without new evidence");
    NSMutableDictionary *bad=ckmutablePlist(result);bad[@"terminalHistory"][@"records"][0][@"resultPublication"]=@"durable";
    ckcheck([axs_cachekeeper_capacity_projection(bad)[@"state"] isEqual:@"invalid"],"unknown publication evidence fails closed");
    bad=ckmutablePlist(result);[bad[@"terminalHistory"][@"records"] addObject:bad[@"terminalHistory"][@"records"][0]];
    ckcheck([axs_cachekeeper_capacity_projection(bad)[@"state"] isEqual:@"invalid"],"history exceeding fixed limit is invalid");
    bad=ckmutablePlist(result);[bad[@"terminalHistory"][@"records"] removeLastObject];
    bad[@"terminalHistory"][@"records"][1]=bad[@"terminalHistory"][@"records"][0];
    ckcheck([axs_cachekeeper_capacity_projection(bad)[@"state"] isEqual:@"invalid"],"duplicate history epochs are invalid");
    bad=ckmutablePlist(result);bad[@"terminalHistory"][@"records"][0][@"privatePath"]=root;
    NSDictionary *projected=axs_cachekeeper_capacity_projection(bad);
    ckcheck(!projected[@"terminalHistory"][@"records"][0][@"privatePath"],"history projection strips unknown private fields");
    bad=ckmutablePlist(result);bad[@"lifecycle"][@"cursorClosure"]=@"notObserved";
    ckcheck([axs_cachekeeper_capacity_projection(bad)[@"state"] isEqual:@"invalid"],"closure timestamp without zero observation is invalid");
}
static void ckhistoryFailure(NSString *base) {
    NSString *folder=ckdirectory(base,@"history-failure-status"),*root=ckdirectory(base,@"history-failure-root");
    for (NSUInteger i=0;i<800;i++) ckfile([root stringByAppendingPathComponent:[NSString stringWithFormat:@"f%lu",(unsigned long)i]],1);
    NSDictionary *plan=ckplan(@[ckroot(root,@"resource-1",@[@"test.a"])],@[@"test.a"],NO);__block BOOL blockCancel=YES;
    AxsCacheKeeperCapacityService *service=[[AxsCacheKeeperCapacityService alloc] initWithFolder:folder provider:^NSDictionary *(NSError **e) {(void)e;return plan;}
        writer:^BOOL(NSDictionary *record,NSString *path) {
            if (blockCancel && [record[@"state"] isEqual:@"cancelled"]) {
                ckcheck([NSFileManager.defaultManager removeItemAtPath:path error:nil],"remove own running fixture before failed cancellation");
                ckcheck([NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:NO attributes:nil error:nil],"actual cancellation write failure target");
            }
            return axs_cachekeeper_capacity_atomic_write(record,path.stringByDeletingLastPathComponent,path.lastPathComponent,32*1024*1024,nil);
        }];
    NSString *a=NSUUID.UUID.UUIDString,*b=NSUUID.UUID.UUIDString;ckrequest(folder,a,NO);[service tick];ckrequest(folder,a,YES);[service tick];
    ckcheck([ckresult(folder)[@"state"] isEqual:@"invalid"],"failed cancellation has no readable saved terminal");
    ckcheck([NSFileManager.defaultManager removeItemAtPath:[folder stringByAppendingPathComponent:@"capacityResult.plist"] error:nil],"remove own cancellation failure target");
    blockCancel=NO;ckrequest(folder,b,NO);ckfinish(service);NSDictionary *item=ckhistory(ckresult(folder),a);
    ckcheck([item[@"resultPublication"] isEqual:@"notSaved"] && !item[@"publicationObservedAt"] && [item[@"supersededBy"] isEqual:b] &&
        [item[@"failure"][@"code"] isEqual:@"writeFailed"],"superseded failed cancel never claims a saved full result");
    ckrequest(folder,a,YES);ckfinish(service);ckcheck([ckresult(folder)[@"epoch"] isEqual:b],"late cancel cannot replace B with historical A");
    NSString *coldFolder=ckdirectory(base,@"history-cold-status"),*c=NSUUID.UUID.UUIDString;
    @autoreleasepool {AxsCacheKeeperCapacityService *first=[[AxsCacheKeeperCapacityService alloc] initWithFolder:coldFolder provider:^NSDictionary *(NSError **e) {(void)e;return plan;} writer:nil];ckrequest(coldFolder,c,NO);[first tick];}
    AxsCacheKeeperCapacityService *cold=[[AxsCacheKeeperCapacityService alloc] initWithFolder:coldFolder provider:nil writer:nil];ckfinish(cold);
    NSDictionary *receipt=ckresult(coldFolder)[@"lifecycle"];
    ckcheck([receipt[@"cursorClosure"] isEqual:@"notObserved"] && !receipt[@"cursorClosedAt"],"restart never invents old process descriptor closure");
    NSString *retryFolder=ckdirectory(base,@"history-retry-status"),*r=NSUUID.UUID.UUIDString;__block BOOL fail=YES;
    AxsCacheKeeperCapacityService *retry=[[AxsCacheKeeperCapacityService alloc] initWithFolder:retryFolder provider:^NSDictionary *(NSError **e) {(void)e;return plan;}
        writer:^BOOL(NSDictionary *record,NSString *path) {
            if (fail && [record[@"state"] isEqual:@"cancelled"]) {
                ckcheck([NSFileManager.defaultManager removeItemAtPath:path error:nil],"remove running retry fixture");
                ckcheck([NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:NO attributes:nil error:nil],"real cancelled retry failure");
            }
            return axs_cachekeeper_capacity_atomic_write(record,path.stringByDeletingLastPathComponent,path.lastPathComponent,32*1024*1024,nil);
        }];
    ckrequest(retryFolder,r,NO);[retry tick];ckrequest(retryFolder,r,YES);[retry tick];
    NSNumber *finished=[[retry valueForKey:@"record"] objectForKey:@"finishedAt"];
    ckcheck([NSFileManager.defaultManager removeItemAtPath:[retryFolder stringByAppendingPathComponent:@"capacityResult.plist"] error:nil],"remove retry failure target");
    fail=NO;[NSThread sleepForTimeInterval:1.05];ckfinish(retry);
    ckcheck([ckresult(retryFolder)[@"finishedAt"] isEqual:finished],"cancel publication retry preserves terminal observation time");
    ckrequest(retryFolder,NSUUID.UUID.UUIDString,NO);ckfinish(retry);
    item=ckhistory(ckresult(retryFolder),r);
    ckcheck([item[@"resultPublication"] isEqual:@"saved"] && item[@"publicationObservedAt"],"successful cancellation retry is saved only after writer success");
}
static void ckcursorErrors(NSString *base) {
    // Change real metadata after the FD opens, leaving dev/ino untouched so the
    // service alias check passes and the production cursor detects the change.
    NSString *second=ckdirectory(base,@"cursor-metadata-root"),*status=ckdirectory(base,@"cursor-metadata-status");
    NSDictionary *plan=ckplan(@[ckroot(second,@"resource-1",@[@"test.a"])],@[@"test.a"],NO);__block BOOL replaced=NO;
    AxsCacheKeeperCapacityService *service=[[AxsCacheKeeperCapacityService alloc] initWithFolder:status provider:^NSDictionary *(NSError **e) {(void)e;return plan;}
        writer:^BOOL(NSDictionary *record,NSString *path) {
            BOOL ok=axs_cachekeeper_capacity_atomic_write(record,path.stringByDeletingLastPathComponent,path.lastPathComponent,32*1024*1024,nil);
            if (!replaced) {replaced=YES;ckfile([second stringByAppendingPathComponent:@"private-error-canary"],1);
                struct stat info;ckcheck(!lstat(second.fileSystemRepresentation,&info),"read actual root time for error fixture");
                struct timeval times[2]={{info.st_atimespec.tv_sec,0},{info.st_mtimespec.tv_sec+5,0}};
                ckcheck(!utimes(second.fileSystemRepresentation,times),"force real root metadata change independently of timestamp granularity");
            }return ok;
        }];
    ckrequest(status,NSUUID.UUID.UUIDString,NO);ckfinish(service);NSDictionary *result=ckresult(status);
    NSDictionary *errors=result[@"roots"][0][@"measurement"][@"cursorErrors"],*error=[errors[@"errors"] firstObject];
    ckcheck([result[@"state"] isEqual:@"partial"] && [error[@"errorCode"] isEqual:@(ESTALE)] && [error[@"stage"] isEqual:@"enumerate"] &&
        [error[@"count"] isEqual:@1] && !error[@"scope"],"real cursor error survives service schema and saved result");
    NSMutableDictionary *legacy=ckmutablePlist(result);[legacy[@"roots"][0][@"measurement"] removeObjectForKey:@"cursorErrors"];
    ckcheck([axs_cachekeeper_capacity_projection(legacy)[@"state"] isEqual:@"partial"],"old measurement without cursor errors is valid");
    NSMutableDictionary *bad=ckmutablePlist(result);bad[@"roots"][0][@"measurement"][@"cursorErrors"][@"errors"][0][@"errorCode"]=@YES;
    ckcheck([axs_cachekeeper_capacity_projection(bad)[@"state"] isEqual:@"invalid"],"cursor error numeric fields reject booleans");
}
static void ckprivateLayout(NSString *base) {
    NSString *folder=ckdirectory(base,@"layout-status"),*path=ckdirectory(base,@"layout-root");
    ckfile([ckdirectory(path,@"PRIVATE_OUTER/PRIVATE_ACCOUNT/postbox/media/cache") stringByAppendingPathComponent:@"opaque"],17);
    ckfile([ckdirectory(path,@"PRIVATE_OUTER/PRIVATE_ACCOUNT/postbox/media/short-cache") stringByAppendingPathComponent:@"opaque"],23);
    ckfile([ckdirectory(path,@"PRIVATE_OUTER/PRIVATE_ACCOUNT/postbox/media/animation-cache") stringByAppendingPathComponent:@"opaque"],29);
    ckfile([ckdirectory(path,@"PRIVATE_OUTER/PRIVATE_ACCOUNT/postbox/db") stringByAppendingPathComponent:@"opaque"],31);
    ckfile([ckdirectory(path,@"PRIVATE_OUTER/logs") stringByAppendingPathComponent:@"opaque"],5);
    __block NSArray *owners=@[@"app.swiftgram.ios"];
    AxsCacheKeeperCapacityService *service=[[AxsCacheKeeperCapacityService alloc] initWithFolder:folder provider:^NSDictionary *(NSError **e){(void)e;return ckplan(@[ckroot(path,@"resource-1",owners)],owners,NO);} writer:nil];
    ckrequest(folder,NSUUID.UUID.UUIDString,NO);ckfinish(service);
    NSDictionary *result=ckresult(folder),*measurement=result[@"roots"][0][@"measurement"];
    ckcheck([result[@"state"] isEqual:@"complete"] && [measurement[@"layoutProfile"] isEqual:@"swiftgramGroupStructureV1"],"registered Swiftgram group gets structural profile");
    NSMutableDictionary *nodes=[NSMutableDictionary new];for (NSDictionary *node in measurement[@"nodes"]) nodes[node[@"category"]]=node;
    ckcheck([nodes[@"postboxMedia"][@"logicalBytes"] isEqual:@69] && [nodes[@"postboxMediaCache"][@"logicalBytes"] isEqual:@17] && [nodes[@"postboxMediaShortCache"][@"logicalBytes"] isEqual:@23] && [nodes[@"postboxMediaAnimationCache"][@"logicalBytes"] isEqual:@29] && [nodes[@"postboxDatabase"][@"logicalBytes"] isEqual:@31] && [nodes[@"logs"][@"logicalBytes"] isEqual:@5],"service persists independently measured private structure");
    NSData *data=[NSJSONSerialization dataWithJSONObject:result options:0 error:nil];NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    ckcheck([text rangeOfString:@"PRIVATE_"].location==NSNotFound && [measurement[@"deletionAuthorization"] isEqual:@"notGranted"],"private labels expose no names and grant no deletion");
    ckbadTree(result,^(NSMutableDictionary *m){[m removeObjectForKey:@"layoutProfile"];},"legacy measurement cannot contain private structure");
    ckbadTree(result,^(NSMutableDictionary *m){m[@"layoutProfile"]=@"futureUnsupported";},"unknown layout profile is rejected");
    ckbadTree(result,^(NSMutableDictionary *m){for (NSMutableDictionary *n in m[@"nodes"]) if ([n[@"category"] isEqual:@"postboxMedia"]) n[@"category"]=@"logs";},"private category in wrong depth is rejected");
    ckbadTree(result,^(NSMutableDictionary *m){for (NSMutableDictionary *n in m[@"nodes"]) if ([n[@"category"] isEqual:@"postboxMediaShortCache"]) n[@"parent"]=nodes[@"postboxDatabase"][@"id"];},"short cache cannot be projected under database");
    owners=@[@"app.swiftgram.ios",@"test.other"];
    ckrequest(folder,NSUUID.UUID.UUIDString,NO);ckfinish(service);
    NSDictionary *shared=ckresult(folder),*sharedMeasurement=shared[@"roots"][0][@"measurement"];
    ckcheck([shared[@"state"] isEqual:@"complete"] && !sharedMeasurement[@"layoutProfile"] && [sharedMeasurement[@"logicalBytes"] isEqual:@105],"new owner relation revokes specialized labels without changing totals");
    NSMutableDictionary *forged=[shared mutableCopy],*row=[shared[@"roots"][0] mutableCopy];row[@"measurement"]=measurement;forged[@"roots"]=@[row];
    ckcheck([axs_cachekeeper_capacity_projection(forged)[@"state"] isEqual:@"invalid"],"shared owners cannot import a specialized measurement profile");
}
int main(int argc,const char **argv) {
    @autoreleasepool {
        ckcheck(argc==3,"expected fixture directory and case");NSString *base=[NSString stringWithUTF8String:argv[1]],*name=[NSString stringWithUTF8String:argv[2]];
        if ([name isEqual:@"all"] || [name isEqual:@"private-layout"]) ckprivateLayout(base);
        if ([name isEqual:@"all"] || [name isEqual:@"shared"] || [name isEqual:@"projection"]) ckshared(base);
        if ([name isEqual:@"all"] || [name isEqual:@"cancel"]) ckcancel(base);
        if ([name isEqual:@"all"] || [name isEqual:@"save"]) cksave(base);
        if ([name isEqual:@"all"] || [name isEqual:@"restart"]) ckrestart(base);
        if ([name isEqual:@"all"] || [name isEqual:@"replace"]) ckreplacement(base);
        if ([name isEqual:@"all"] || [name isEqual:@"late-cancel"]) cklateCancel(base);
        if ([name isEqual:@"all"] || [name isEqual:@"gates"]) ckrequestGates(base);
        if ([name isEqual:@"all"] || [name isEqual:@"excluded"]) ckexcluded(base);
        if ([name isEqual:@"all"] || [name isEqual:@"partial"]) ckpartial(base);
        if ([name isEqual:@"all"] || [name isEqual:@"alias-replace"]) ckaliasReplacement(base);
        if ([name isEqual:@"unobserved"]) ckunobservedRoot(base);
        if ([name isEqual:@"all"] || [name isEqual:@"nodes"]) cknodeProjection(base);
        if ([name isEqual:@"all"] || [name isEqual:@"history"]) ckhistoryBehavior(base);
        if ([name isEqual:@"all"] || [name isEqual:@"history-failure"]) ckhistoryFailure(base);
        if ([name isEqual:@"all"] || [name isEqual:@"cursor-errors"]) ckcursorErrors(base);
        if ([name isEqual:@"all"] || [name isEqual:@"source-errors"]) {ckactualMissingRoot(base);ckunobservedRoot(base);cksourceAliasBeforeOpen(base);}
        if ([name isEqual:@"source-alias"]) cksourceAliasBeforeOpen(base);
        if ([name isEqual:@"all"] || [name isEqual:@"error-schema"]) ckerrorSchema(base);
        if ([name isEqual:@"all"]) {ckremovedRequest(base);ckrootBudget(base);ckproviderFailure(base);}
        if ([name isEqual:@"all"] || [name isEqual:@"projection"]) ckprojection(base);
        puts("PASS: capacity service real metadata, request gates, shared aliases, cancellation, persistence and restart");
    }return 0;
}
