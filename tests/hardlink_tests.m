#import <Foundation/Foundation.h>
#import "../AxsCacheKeeperSweep.h"
#import "../AxsCacheKeeperCleanupJob.h"
#import "../AxsCacheKeeperCleanupSchedule.h"
#import "../AxsCacheKeeperReleaseEvidenceStatus.h"
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

static void hlcheck(BOOL ok, NSString *message) {
    if (!ok) { fprintf(stderr,"FAIL: hardlink: %s\n",message.UTF8String); exit(1); }
}
static NSString *hldir(NSString *home, NSString *relative) {
    NSString *path=[home stringByAppendingPathComponent:relative];
    hlcheck([NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil],@"create fixture directory");
    return path;
}
static void hlput(NSString *path) {
    hlcheck([@"hardlink payload" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil],@"create fixture file");
}
static void hllink(NSString *source, NSString *alias) {
    hlcheck(!link(source.fileSystemRepresentation,alias.fileSystemRepresentation),@"create real inode alias");
}
static AxsCacheKeeperSweep *hlsweep(NSString *home, NSString *root, NSDictionary *state, int (^unlinkFile)(int,const char *)) {
    NSTimeInterval future=NSDate.date.timeIntervalSince1970+600;
    return [[AxsCacheKeeperSweep alloc] initWithRoot:root bundle:@"test.hardlink" version:@"1" containerPath:home state:state
        clock:^NSTimeInterval{return future;} unlinkFile:unlinkFile ?: ^int(int fd,const char *name){return unlinkat(fd,name,0);}];
}
static AxsCacheKeeperCleanupJob *hljob(NSArray *sweeps, NSTimeInterval (^clock)(void)) {
    return [[AxsCacheKeeperCleanupJob alloc] initWithSweeps:sweeps signature:@"hardlink-fixture" instance:@"1" clock:clock ?: ^NSTimeInterval{return 10;}];
}
static void hlready(AxsCacheKeeperCleanupJob *job) {
    for (NSUInteger cycle=0;job.phase==AxsCacheKeeperCleanupPhaseChecking && cycle<10000;cycle++)
        [job advanceCycleWithPerRootLimit:16 gate:^BOOL{return YES;}];
    hlcheck(job.phase==AxsCacheKeeperCleanupPhaseReady,@"complete preflight without deleting");
    hlcheck(job.removed==0,@"preflight never unlinks");
}
static void hlfinish(AxsCacheKeeperCleanupJob *job) {
    for (NSUInteger cycle=0;job.phase!=AxsCacheKeeperCleanupPhaseFinished && cycle<10000;cycle++)
        [job advanceCycleWithPerRootLimit:16 gate:^BOOL{return YES;}];
    hlcheck(job.phase==AxsCacheKeeperCleanupPhaseFinished,@"job reaches a terminal state");
}
static NSUInteger hlopenfds(void) {
    NSUInteger count=0;
    for (int fd=0;fd<MIN(getdtablesize(),4096);fd++) if (fcntl(fd,F_GETFD)!=-1) count++;
    return count;
}

void axs_cachekeeper_run_hardlink_tests(NSString *fixture) {
    NSFileManager *fm=NSFileManager.defaultManager;
    NSString *base=hldir(fixture,@"closed-hardlink-tests");
    // All links must be reclaimed even when their roots are advanced separately; bytes describe paths.
    for (NSString *variant in @[@"same-root",@"cross-root",@"overlap"]) {
        NSString *home=hldir(base,variant),*root=hldir(home,@"Library/Caches"),*second=hldir(home,@"tmp");
        NSString *first=[root stringByAppendingPathComponent:@"source"];
        NSString *alias=[[variant isEqual:@"cross-root"] ? second : root stringByAppendingPathComponent:@"alias"];
        hlput(first);hllink(first,alias);
        NSMutableArray *sweeps=[NSMutableArray arrayWithObject:hlsweep(home,root,@{},nil)];
        if ([variant isEqual:@"cross-root"]) [sweeps addObject:hlsweep(home,second,@{},nil)];
        if ([variant isEqual:@"overlap"]) [sweeps addObject:hlsweep(home,root,@{},nil)];
        AxsCacheKeeperCleanupJob *job=hljob(sweeps,nil);hlready(job);hlfinish(job);
        hlcheck(job.removed==2 && job.bytes==32 && job.failed==0 && job.changedCount==0 && job.hardLinkRetainedCount==0 &&
            ![fm fileExistsAtPath:first] && ![fm fileExistsAtPath:alias],@"closed group is reclaimed once across roots and overlapping observations");
        NSDictionary *evidence=job.releaseEvidence;
        hlcheck(axs_cachekeeper_release_evidence_projection(evidence,job.roundID)!=nil,@"actual closed-group evidence satisfies persisted schema");
        NSArray *details=evidence[@"details"];
        hlcheck([evidence[@"roundID"] isEqual:job.roundID] && [evidence[@"state"] isEqual:@"finished"] &&
            [evidence[@"attempts"] unsignedIntegerValue]==2 && [evidence[@"succeeded"] unsignedIntegerValue]==2 && details.count==2,
            @"release evidence follows the real closed-group syscall count and round");
        hlcheck([details[0][@"objectID"] isEqual:details[1][@"objectID"]] && [details[0][@"objectID"] unsignedIntegerValue]>0 &&
            [details[0][@"pre"][@"nlink"] unsignedIntegerValue]==2 && [details[0][@"post"][@"nlink"] unsignedIntegerValue]==1 &&
            [details[1][@"post"][@"nlink"] unsignedIntegerValue]==0 && [evidence[@"uniqueExtents"] isEqual:@"notMeasured"],
            @"release evidence observes two to one to zero without claiming unique extents");
        hlcheck([evidence[@"volumes"] count]==1 && [evidence[@"volumes"][0][@"state"] isEqual:@"observed"],
            @"release evidence samples the same real volume after file descriptors close");
        for (AxsCacheKeeperSweep *sweep in sweeps) hlcheck(sweep.remainingCandidates==0 && sweep.remainingBytes==0,@"successful group leaves no duplicate residuals");
        NSUInteger before=job.removed;[job advanceCycleWithPerRootLimit:16 gate:^BOOL{return YES;}];
        hlcheck(job.removed==before,@"terminal job cannot double count a group");
    }
    // Missing authority, excluded/retained paths and duplicate observations cannot manufacture closure.
    for (NSString *variant in @[@"outside",@"excluded",@"retained",@"unknown",@"overlap-excluded",@"overlap-open"]) {
        NSString *home=hldir(base,variant),*root=hldir(home,@"Library/Caches");
        NSString *other=hldir(home,[variant isEqual:@"retained"] ? @"Library/Caches/Drafts" :
            [variant isEqual:@"unknown"] ? @"PrivateResources" : @"tmp");
        NSString *first=[root stringByAppendingPathComponent:@"source"],*alias=[other stringByAppendingPathComponent:@"alias"];
        hlput(first);hllink(first,alias);
        NSDictionary *state=[variant isEqual:@"excluded"] ? @{@"excludedPaths":@[@"tmp/alias"]} : @{};
        NSMutableArray *sweeps=[NSMutableArray arrayWithObject:hlsweep(home,root,state,nil)];
        if (![variant isEqual:@"outside"] && ![variant isEqual:@"overlap-open"]) [sweeps addObject:hlsweep(home,other,state,nil)];
        if ([variant isEqual:@"overlap-open"]) [sweeps addObject:hlsweep(home,root,@{},nil)];
        if ([variant isEqual:@"overlap-excluded"]) [sweeps addObject:hlsweep(home,root,@{@"excludedPaths":@[@"Library/Caches/source"]},nil)];
        AxsCacheKeeperCleanupJob *job=hljob(sweeps,nil);hlfinish(job);
        hlcheck(job.removed==0 && [fm fileExistsAtPath:first] && [fm fileExistsAtPath:alias],@"every inode alias requires its own authority");
        if ([variant isEqual:@"overlap-open"]) hlcheck(job.hardLinkRetainedCount==1,@"same directory identity and name is one observed path");
    }
    for (NSString *variant in @[@"added",@"removed",@"replaced",@"equal-link-swap",@"parent-replaced",@"gate-link-change",@"cancel-before"]) {
        NSString *home=hldir(base,variant),*root=hldir(home,@"Library/Caches");
        NSString *first=[root stringByAppendingPathComponent:@"source"],*alias=[root stringByAppendingPathComponent:@"alias"];
        hlput(first);hllink(first,alias);AxsCacheKeeperCleanupJob *job=hljob(@[hlsweep(home,root,@{},nil)],nil);hlready(job);
        if ([variant isEqual:@"added"]) hllink(first,[home stringByAppendingPathComponent:@"external"]);
        if ([variant isEqual:@"removed"]) hlcheck(!unlink(alias.fileSystemRepresentation),@"remove alias after preflight");
        if ([variant isEqual:@"replaced"]) {hlcheck(!unlink(alias.fileSystemRepresentation),@"replace alias after preflight");hlput(alias);}
        if ([variant isEqual:@"equal-link-swap"]) {
            hllink(first,[home stringByAppendingPathComponent:@"external"]);
            hlcheck(!unlink(alias.fileSystemRepresentation),@"swap one observed link for an external link at equal nlink");
        }
        if ([variant isEqual:@"parent-replaced"]) {
            hlcheck(!rename(root.fileSystemRepresentation,[home stringByAppendingPathComponent:@"moved"].fileSystemRepresentation),@"move original cache root");
            hldir(home,@"Library/Caches");hlput(first);hlput(alias);
        }
        if ([variant isEqual:@"cancel-before"]) [job advanceCycleWithPerRootLimit:16 gate:^BOOL{return NO;}];
        else if ([variant isEqual:@"gate-link-change"]) {
            __block NSUInteger gates=0;
            [job advanceCycleWithPerRootLimit:16 gate:^BOOL {
                if (++gates==2) {hlcheck(!unlink(alias.fileSystemRepresentation),@"replace alias while sampling process gate");hlput(alias);}
                return YES;
            }];
            hlfinish(job);
        }
        else hlfinish(job);
        hlcheck(job.removed==0 && [fm fileExistsAtPath:first],@"link or gate changes veto the entire unstarted group");
        if (![variant isEqual:@"cancel-before"]) hlcheck(job.changedCount>0,@"post-preflight changes are diagnosed");
    }
    {
        NSString *home=hldir(base,@"zero-batch"),*root=hldir(home,@"Library/Caches");
        NSString *first=[root stringByAppendingPathComponent:@"source"];hlput(first);hllink(first,[root stringByAppendingPathComponent:@"alias"]);
        AxsCacheKeeperCleanupJob *job=hljob(@[hlsweep(home,root,@{},nil)],nil);hlready(job);
        [job advanceCycleWithPerRootLimit:0 gate:^BOOL{return YES;}];
        hlcheck(job.removed==0 && job.deleteDeadline==0,@"zero batch allowance cannot enter group deletion");hlfinish(job);
    }
    // Failure/cancellation/deadline after one real unlink must preserve truthful counts and allow a new round.
    for (NSString *variant in @[@"partial-failure",@"partial-cancel",@"partial-deadline",@"partial-change",@"partial-equal-swap",@"partial-parent-replaced",@"partial-permission"]) {
        if ([variant isEqual:@"partial-permission"] && !geteuid()) {fprintf(stderr,"SKIP: parent search permission requires an unprivileged user\n");continue;}
        NSString *home=hldir(base,variant),*root=hldir(home,@"Library/Caches"),*parent=hldir(root,@"nested");
        NSString *first=[parent stringByAppendingPathComponent:@"source"],*alias=[parent stringByAppendingPathComponent:@"alias"];
        hlput(first);hllink(first,alias);__block NSUInteger attempts=0;__block NSTimeInterval now=10;
        __block __weak AxsCacheKeeperCleanupJob *weakJob;
        AxsCacheKeeperSweep *sweep=hlsweep(home,root,@{},^int(int fd,const char *name) {
            attempts++;
            if ([variant isEqual:@"partial-failure"] && attempts==2) {errno=EACCES;return -1;}
            int result=unlinkat(fd,name,0);
            if (!result && attempts==1) {
                if ([variant isEqual:@"partial-cancel"]) [weakJob cancel];
                if ([variant isEqual:@"partial-deadline"]) now=130;
                if ([variant isEqual:@"partial-change"]) {
                    NSString *remaining=[fm fileExistsAtPath:first] ? first : alias;
                    hllink(remaining,[home stringByAppendingPathComponent:@"new-external"]);
                }
                if ([variant isEqual:@"partial-equal-swap"]) {
                    NSString *remaining=[fm fileExistsAtPath:first] ? first : alias;
                    hllink(remaining,[home stringByAppendingPathComponent:@"new-external"]);
                    hlcheck(!unlink(remaining.fileSystemRepresentation),@"replace remaining alias at equal post-unlink nlink");
                    hlput(remaining);
                }
                if ([variant isEqual:@"partial-parent-replaced"]) {
                    hlcheck(!rename(parent.fileSystemRepresentation,[home stringByAppendingPathComponent:@"moved"].fileSystemRepresentation),@"move pinned parent after first unlink");
                    hldir(root,@"nested");
                }
                if ([variant isEqual:@"partial-permission"]) hlcheck(!fchmod(fd,0),@"revoke search permission after the first unlink");
            }
            return result;
        });
        AxsCacheKeeperCleanupJob *job=hljob(@[sweep],^NSTimeInterval{return now;});weakJob=job;
        hlready(job);
        NSUInteger descriptors=hlopenfds();hlfinish(job);
        if ([variant isEqual:@"partial-permission"]) hlcheck(!chmod(parent.fileSystemRepresentation,0700),@"restore only fixture permissions");
        hlcheck(hlopenfds()==descriptors,@"every partial exit closes pinned file and parent descriptors");
        NSString *survivingParent=[variant isEqual:@"partial-parent-replaced"] ? [home stringByAppendingPathComponent:@"moved"] : parent;
        hlcheck(job.removed==1 && job.bytes==16 && [fm contentsOfDirectoryAtPath:survivingParent error:nil].count==1,@"partial group records only real path removals");
        if ([variant isEqual:@"partial-failure"]) hlcheck(job.failed==1 && sweep.remainingCandidates==1 && sweep.failureDetails.count>0,@"failed remaining link retains its retry count and errno");
        if ([variant isEqual:@"partial-permission"]) hlcheck(job.failed==1 && job.changedCount==0 && sweep.remainingCandidates==1 &&
            [sweep.failureDetails.lastObject[@"code"] intValue]==EACCES,@"directory access failure remains a failure with errno instead of an inode change");
        if ([variant isEqual:@"partial-cancel"]) hlcheck(job.endReason==AxsCacheKeeperCleanupEndReasonCancelled && sweep.remainingCandidates==1,@"cancellation retains remaining member");
        if ([variant isEqual:@"partial-deadline"]) hlcheck(job.endReason==AxsCacheKeeperCleanupEndReasonLimitReached && sweep.remainingCandidates==1,@"deadline does not start the remaining unlink");
        if ([variant isEqual:@"partial-change"] || [variant isEqual:@"partial-equal-swap"] || [variant isEqual:@"partial-parent-replaced"])
            hlcheck(job.changedCount==1 && sweep.changedBytes==16,@"external inode or parent changes retain exact deferred bytes after an owned unlink");
        else {
            AxsCacheKeeperCleanupJob *retry=hljob(@[hlsweep(home,root,@{},nil)],nil);hlfinish(retry);
            hlcheck(retry.removed==1 && retry.bytes==16 && job.removed+retry.removed==2,@"new round retries only the surviving name without double counting");
        }
    }
    // Group coordination keeps the original batch gate cadence even if it spans roots.
    for (NSString *variant in @[@"gate-batch",@"gate-after-validation"]) {
        NSString *home=hldir(base,variant),*root=hldir(home,@"Library/Caches"),*second=hldir(home,@"tmp");
        NSString *first=[root stringByAppendingPathComponent:@"source"];hlput(first);
        for (NSUInteger i=1;i<5;i++) hllink(first,[(i%2 ? root : second) stringByAppendingPathComponent:[NSString stringWithFormat:@"alias-%lu",(unsigned long)i]]);
        AxsCacheKeeperCleanupJob *job=hljob(@[hlsweep(home,root,@{},nil),hlsweep(home,second,@{},nil)],nil);hlready(job);
        __block NSUInteger gates=0;
        [job advanceCycleWithPerRootLimit:2 gate:^BOOL {
            gates++;
            return [variant isEqual:@"gate-after-validation"] ? gates<2 : job.removed<2;
        }];
        NSUInteger expected=[variant isEqual:@"gate-after-validation"] ? 0 : 2;
        hlcheck(job.endReason==AxsCacheKeeperCleanupEndReasonCancelled && job.removed==expected && job.bytes==expected*16,
            @"gate closes before first unlink or at the existing per-root batch boundary");
        NSUInteger remaining=0;for (AxsCacheKeeperSweep *sweep in job.sweeps) remaining+=sweep.remainingCandidates;
        hlcheck(remaining==5-expected,@"gate cancellation preserves all remaining cross-root candidates");
    }
    // A group spanning roots may not partially consume the shared 2000-path round budget.
    NSString *home=hldir(base,@"over-budget"),*root=hldir(home,@"Library/Caches"),*second=hldir(home,@"tmp");
    NSString *first=[root stringByAppendingPathComponent:@"source"];hlput(first);
    for (NSUInteger i=1;i<=AxsCacheKeeperCleanupRoundItemCap;i++)
        hllink(first,[(i%2 ? root : second) stringByAppendingPathComponent:[NSString stringWithFormat:@"alias-%lu",(unsigned long)i]]);
    NSString *ordinary=[root stringByAppendingPathComponent:@"ordinary"];hlput(ordinary);
    AxsCacheKeeperSweep *one=hlsweep(home,root,@{},nil),*two=hlsweep(home,second,@{},nil);
    AxsCacheKeeperCleanupJob *job=hljob(@[one,two],nil);hlfinish(job);
    hlcheck(job.endReason==AxsCacheKeeperCleanupEndReasonLimitReached && job.removed==1 && job.bytes==16 &&
        one.remainingCandidates+two.remainingCandidates==2001 && one.remainingBytes+two.remainingBytes==2001*16 &&
        [fm fileExistsAtPath:first] && ![fm fileExistsAtPath:ordinary] && job.hardLinkRetainedCount==0 && !job.failed && !job.changedCount,
        @"oversized closed group remains pending without starving an independent ordinary file");
    hlcheck([fm contentsOfDirectoryAtPath:root error:nil].count+[fm contentsOfDirectoryAtPath:second error:nil].count==2001,
        @"all oversized-group names remain and only the independent ordinary file is removed");
    [job advanceCycleWithPerRootLimit:16 gate:^BOOL{return YES;}];
    hlcheck(job.removed==1 && one.remainingCandidates+two.remainingCandidates==2001,@"terminal budget result does not recount pending links");
    // Two independently closed groups fit individually but not together in one round.
    home=hldir(base,@"remaining-budget");root=hldir(home,@"Library/Caches");second=hldir(home,@"tmp");
    NSString *large=[root stringByAppendingPathComponent:@"large"];hlput(large);
    for (NSUInteger i=1;i<AxsCacheKeeperCleanupRoundItemCap-1;i++)
        hllink(large,[(i%2 ? root : second) stringByAppendingPathComponent:[NSString stringWithFormat:@"large-%lu",(unsigned long)i]]);
    NSString *small=[root stringByAppendingPathComponent:@"small"];hlput(small);hllink(small,[second stringByAppendingPathComponent:@"small-alias"]);
    ordinary=[second stringByAppendingPathComponent:@"ordinary"];hlput(ordinary);
    one=hlsweep(home,root,@{},nil);two=hlsweep(home,second,@{},nil);job=hljob(@[one,two],nil);hlfinish(job);
    hlcheck(job.endReason==AxsCacheKeeperCleanupEndReasonLimitReached && job.removed==3 && job.bytes==48 &&
        one.remainingCandidates+two.remainingCandidates==1999 && one.remainingBytes+two.remainingBytes==1999*16 &&
        ![fm fileExistsAtPath:small] && ![fm fileExistsAtPath:ordinary] && [fm fileExistsAtPath:large] &&
        !job.failed && !job.changedCount && job.hardLinkRetainedCount==0,
        @"a group that exceeds remaining budget cannot starve a later ordinary file or be partially started");
    hlcheck([fm contentsOfDirectoryAtPath:root error:nil].count+[fm contentsOfDirectoryAtPath:second error:nil].count==1999,
        @"all large-group names remain after the small group and ordinary file are reclaimed");
    // The observer sees actual ordinary syscalls, including cancellation inside the injected syscall.
    for (NSString *variant in @[@"evidence-ordinary",@"evidence-failure",@"evidence-cancel"]) {
        NSString *eHome=hldir(base,variant),*eRoot=hldir(eHome,@"Library/Caches");
        hlput([eRoot stringByAppendingPathComponent:@"payload"]);
        if ([variant isEqual:@"evidence-cancel"]) hlput([eRoot stringByAppendingPathComponent:@"remaining"]);
        __block __weak AxsCacheKeeperCleanupJob *weakEvidenceJob=nil;
        __block NSDictionary *during=nil;
        AxsCacheKeeperSweep *eSweep=hlsweep(eHome,eRoot,@{},^int(int fd,const char *name) {
            if ([variant isEqual:@"evidence-failure"]) {errno=EACCES;return -1;}
            int result=unlinkat(fd,name,0);
            if ([variant isEqual:@"evidence-cancel"]) {[weakEvidenceJob cancel];during=weakEvidenceJob.releaseEvidence;}
            errno=EACCES;return result;
        });
        AxsCacheKeeperCleanupJob *eJob=hljob(@[eSweep],nil);weakEvidenceJob=eJob;NSUInteger fdCount=hlopenfds();hlfinish(eJob);
        NSDictionary *ev=eJob.releaseEvidence,*detail=[ev[@"details"] firstObject];
        hlcheck(axs_cachekeeper_release_evidence_projection(ev,eJob.roundID)!=nil,@"actual ordinary evidence satisfies persisted schema");
        BOOL failure=[variant isEqual:@"evidence-failure"];
        hlcheck([ev[@"attempts"] unsignedIntegerValue]==1 && [ev[@"succeeded"] unsignedIntegerValue]==(failure?0:1) &&
            [ev[@"failed"] unsignedIntegerValue]==(failure?1:0) && [detail[@"errno"] intValue]==(failure?EACCES:0) &&
            [detail[@"pre"][@"nlink"] unsignedIntegerValue]==1 && [detail[@"post"][@"nlink"] unsignedIntegerValue]==(failure?1:0),
            @"ordinary evidence keeps syscall errno separate from post-stat and stale errno");
        hlcheck(hlopenfds()==fdCount,@"release evidence closes all extra volume descriptors");
        if (during) hlcheck([fm contentsOfDirectoryAtPath:eRoot error:nil].count==1 && ![during[@"state"] isEqual:@"cancelled"] &&
            [during[@"volumes"][0][@"after"][@"state"] isEqual:@"notRecorded"] && [ev[@"state"] isEqual:@"cancelled"],
            @"cancellation inside unlink cannot sample terminal volume until the stack returns");
        uint64_t revision=[ev[@"revision"] unsignedLongLongValue];[eJob cancel];
        hlcheck([eJob.releaseEvidence isEqual:ev] && [eJob.releaseEvidence[@"revision"] unsignedLongLongValue]==revision,
            @"terminal getters and repeated cancellation leave evidence frozen");
    }
    fprintf(stderr,"PASS: closed hardlink authorization, identity, budget, partial outcomes and retries\n");
}
