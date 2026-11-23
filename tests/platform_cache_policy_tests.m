// Calls the production Rules/Sweep with real files. Only pread is observed/failed
// at the syscall boundary by the runner; file opens and identity checks stay real.
#import <Foundation/Foundation.h>
#import "AxsCacheKeeperPolicy.h"
#import "AxsCacheKeeperCleanupRules.h"
#import "AxsCacheKeeperSweep.h"
#import "AxsCacheKeeperCleanupJob.h"
#include <unistd.h>
#include <errno.h>

static NSUInteger axs_cachekeeper_platform_reads;
static BOOL axs_cachekeeper_platform_fail_reads;
ssize_t axs_cachekeeper_platform_test_pread(int fd,void *buffer,size_t size,off_t offset) {
    axs_cachekeeper_platform_reads++;
    if (axs_cachekeeper_platform_fail_reads) {errno=EIO;return -1;}
    return pread(fd,buffer,size,offset);
}
static void pc(BOOL condition,const char *message) {
    if (!condition) {fprintf(stderr,"FAIL: platform-cache: %s\n",message);exit(1);}
}
static AxsCacheKeeperCleanupDecision *pcdecision(NSString *bundle,NSString *version,NSString *path,NSDictionary *state,BOOL read) {
    return [AxsCacheKeeperCleanupRules decisionForBundle:bundle version:version relativePath:path state:state
        evidence:@{@"readComplete":@(read),@"hasEvidence":@NO,@"hasMediaSignature":@NO}];
}
static NSArray *pcallowed(void) { return @[@"ordinary",@"images",@"data-store"]; }
static NSArray *pcretained(void) { return @[@"account",@"offline",@"drafts",@"session-cache",@"WebKit",@"authors",@"tokenizer",@"com.apple.nsurlsessiond"]; }
static void pcnames(void) {
    for (NSString *part in pcretained()) {
        NSString *path=[@"Library/Caches" stringByAppendingPathComponent:part];
        pc(axs_cachekeeper_retention_path(path) && !axs_cachekeeper_cache_path(path),"unverified name migration does not expand previous deletion scope");
        AxsCacheKeeperCleanupDecision *decision=pcdecision(@"test.platform",@"1",[path stringByAppendingPathComponent:@"payload"],@{},YES);
        pc(decision.disposition==AxsCacheKeeperCleanupKeep && [decision.reason containsString:@"用途尚未核实"],"name hint is not described as confirmed necessary data");
    }
    for (NSString *path in @[@"../tmp",@"Library/CachesExtra/authors",@"/tmp/authors",@"tmp/../authors",@"tmp\\authors"])
        pc(!axs_cachekeeper_cache_path(path),"invalid and lookalike roots never acquire platform selection");
}
static void pcread(void) {
    AxsCacheKeeperCleanupDecision *decision=pcdecision(@"test.platform",@"1",@"Library/Caches/ordinary/payload",@{},NO);
    pc(decision.disposition==AxsCacheKeeperCleanupDelete && decision.basis==AxsCacheKeeperCleanupBasisPlatformCache,"platform purpose does not require content readability");
    for (NSString *root in @[@"tmp",@"Library/Caches"])
        pc(pcdecision(@"test.platform",@"1",[root stringByAppendingPathComponent:@"ordinary/Cache.db"],@{},NO).basis==AxsCacheKeeperCleanupBasisPlatformCache,"platform database format does not require header reads");
    decision=pcdecision(@"test.platform",@"1",@"Library/alog/app.log",@{@"logPaths":@[@"Library/alog"]},NO);
    pc(decision.disposition==AxsCacheKeeperCleanupDefer && [decision.ruleID isEqual:@"read-incomplete"],"generic logs still defer when content reads fail");
    decision=pcdecision(@"com.ss.iphone.ugc.Aweme",@"41.1.0",@"Library/alog/ready/BDALog_20261111_193314.alog.iOS.1128",@{@"processExited":@YES},NO);
    pc(decision.disposition==AxsCacheKeeperCleanupDefer,"exact ALog still requires content reads");
    for (NSString *path in @[@"Documents/ordinary/payload",@"Library/Application Support/payload",@"Group/id/Library/Caches/payload",@"Caches/payload"])
        pc(pcdecision(@"test.platform",@"1",path,@{},YES).disposition!=AxsCacheKeeperCleanupDelete,"platform purpose never crosses container storage roles");
}
static NSString *pcput(NSString *home,NSString *relative) {
    NSString *path=[home stringByAppendingPathComponent:relative];
    pc([NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil],"create real fixture directory");
    pc([@"platform payload" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil],"write real fixture");
    return path;
}
static AxsCacheKeeperSweep *pcsweep(NSString *home,NSString *root,NSString *bundle,NSDictionary *state,BOOL mature) {
    NSTimeInterval now=NSDate.date.timeIntervalSince1970+(mature ? 600 : 0);
    return [[AxsCacheKeeperSweep alloc] initWithRoot:[home stringByAppendingPathComponent:root] bundle:bundle version:@"1" containerPath:home state:state clock:^NSTimeInterval{return now;}];
}
static void pcfinish(AxsCacheKeeperSweep *sweep) {
    for (NSUInteger i=0;i<2000 && !sweep.complete;i++) [sweep advance:16 shouldContinue:^BOOL{return YES;}];
    pc(sweep.complete,"real sweep terminates within bounded advances");
}
static void pcpread(NSString *fixture) {
    NSString *home=[fixture stringByAppendingPathComponent:@"pread"];
    NSString *path=pcput(home,@"Library/Caches/ordinary/Cache.db");
    AxsCacheKeeperSweep *sweep=pcsweep(home,@"Library/Caches",@"test.platform",@{},YES);
    axs_cachekeeper_platform_reads=0;axs_cachekeeper_platform_fail_reads=YES;
    pcfinish(sweep);
    pc(axs_cachekeeper_platform_reads==0,"standard sweep performs no content pread");
    pc(sweep.removed==1 && !sweep.failed && ![NSFileManager.defaultManager fileExistsAtPath:path],"standard sweep deletes a real file despite content read fault");
    NSString *log=pcput(home,@"Library/alog/app.log");
    sweep=pcsweep(home,@"Library/alog",@"test.platform",@{@"logPaths":@[@"Library/alog"]},YES);
    axs_cachekeeper_platform_reads=0;pcfinish(sweep);
    pc(axs_cachekeeper_platform_reads>0 && sweep.removed==0 && sweep.failed>0 && [NSFileManager.defaultManager fileExistsAtPath:log],"nonplatform sweep records real content read failure and preserves file");
    axs_cachekeeper_platform_fail_reads=NO;
}
static void pcsafety(NSString *fixture) {
    NSFileManager *fm=NSFileManager.defaultManager;
    for (NSString *root in @[@"Library/Caches",@"tmp"]) {
        NSString *home=[fixture stringByAppendingPathComponent:[root isEqual:@"tmp"] ? @"tmp-sweep" : @"cache-sweep"];
        for (NSString *part in pcallowed()) pcput(home,[[root stringByAppendingPathComponent:part] stringByAppendingPathComponent:@"payload"]);
        for (NSString *part in pcretained()) pcput(home,[[root stringByAppendingPathComponent:part] stringByAppendingPathComponent:@"payload"]);
        NSString *excluded=pcput(home,[root stringByAppendingPathComponent:@"excluded/payload"]);
        NSString *unavailable=pcput(home,[root stringByAppendingPathComponent:@"unavailable/payload"]);
        NSDictionary *state=@{@"excludedPaths":@[[root stringByAppendingPathComponent:@"excluded"]],@"unavailablePaths":@[[root stringByAppendingPathComponent:@"unavailable"]]};
        AxsCacheKeeperSweep *sweep=pcsweep(home,root,@"test.platform",state,YES);pcfinish(sweep);
        pc(sweep.removed==pcallowed().count && !sweep.failed,"real sweep removes every allowed name without pruning siblings");
        for (NSString *part in pcretained()) pc([fm fileExistsAtPath:[[home stringByAppendingPathComponent:[root stringByAppendingPathComponent:part]] stringByAppendingPathComponent:@"payload"]],"real necessary data remains");
        pc([fm fileExistsAtPath:excluded] && [fm fileExistsAtPath:unavailable],"user exclusion and failed restore keep their real files");
    }
    NSString *home=[fixture stringByAppendingPathComponent:@"identity"];
    NSString *path=pcput(home,@"tmp/ordinary/payload");
    AxsCacheKeeperSweep *sweep=pcsweep(home,@"tmp",@"test.platform",@{},NO);pcfinish(sweep);
    pc(sweep.recentCount==1 && !sweep.removed && [fm fileExistsAtPath:path],"content bypass never bypasses file maturity");
    sweep=pcsweep(home,@"tmp",@"test.platform",@{},YES);
    while (sweep.checking) [sweep advancePreflight:16];
    pcput(home,@"tmp/ordinary/payload");pcfinish(sweep);
    pc(!sweep.removed && sweep.changedCount>0 && [fm fileExistsAtPath:path],"replacement inode after preflight remains untouched");
    NSString *alias=[home stringByAppendingPathComponent:@"outside-hardlink"];
    pc(!link(path.fileSystemRepresentation,alias.fileSystemRepresentation),"create real external hard link");
    sweep=pcsweep(home,@"tmp",@"test.platform",@{},YES);pcfinish(sweep);
    pc(!sweep.removed && sweep.hardLinkRetainedCount==1 && [fm fileExistsAtPath:alias],"external hard link prevents ordinary reclamation");
    NSString *outside=pcput(home,@"outside/payload"),*symbolic=[home stringByAppendingPathComponent:@"tmp/symbolic"];
    pc(!symlink(outside.fileSystemRepresentation,symbolic.fileSystemRepresentation),"create real symbolic link");
    sweep=pcsweep(home,@"tmp",@"test.platform",@{},YES);pcfinish(sweep);
    struct stat info;pc(!sweep.removed && !lstat(symbolic.fileSystemRepresentation,&info) && S_ISLNK(info.st_mode) && [fm fileExistsAtPath:outside],"symbolic link is neither followed nor deleted");
}
static void pcdependencies(NSString *fixture) {
    NSString *bundle=@"test.platform.dependencies";
    AxsCacheKeeperAppRule *rule=[[AxsCacheKeeperAppRule alloc] initWithRuleID:@"private-resource" revision:@"1" appVersion:@"1"
        cleanablePaths:@[@"Library/Caches/resources"] retentionPaths:@[@"Library/Caches/resources/protected.idx"]
        dependencyPaths:@[@"Library/Caches/index",@"Library/Caches/resources/protected.idx"]];
    [AxsCacheKeeperCleanupRules registerRule:rule forBundle:bundle];
    for (NSString *version in @[@"1",@"2"]) {
        for (NSString *path in @[@"Library/Caches/index",@"Library/Caches/index/child",@"Library/Caches/resources/protected.idx"])
            pc(pcdecision(bundle,version,path,@{},NO).disposition==AxsCacheKeeperCleanupKeep,"explicit retention and dependencies without precise authorization remain kept across versions");
        pc([AxsCacheKeeperCleanupRules hasRetentionRangeForBundle:bundle version:version relativePath:@"Library/Caches"],"whole-owner operation cannot cross a dependency descendant");
        pc(pcdecision(bundle,version,@"Library/Caches/index-neighbor/payload",@{},YES).basis==AxsCacheKeeperCleanupBasisPlatformCache,"dependency component boundary preserves independent adjacent resources");
    }
    AxsCacheKeeperCleanupDecision *decision=pcdecision(bundle,@"1",@"Library/Caches/resources/ordinary",@{},NO);
    pc(decision.disposition==AxsCacheKeeperCleanupDefer,"precise private resource cannot fall through to read-free platform decision");
    decision=pcdecision(bundle,@"1",@"Library/Caches/resources/ordinary",@{},YES);
    pc(decision.basis==AxsCacheKeeperCleanupBasisAppRule && [decision.dependencyPaths isEqual:rule.dependencyPaths],"precise resource retains all declared dependencies");
    NSString *home=[fixture stringByAppendingPathComponent:@"dependencies"];
    NSString *index=pcput(home,@"Library/Caches/index/child"),*inner=pcput(home,@"Library/Caches/resources/protected.idx");
    NSString *resource=pcput(home,@"Library/Caches/resources/ordinary"),*adjacent=pcput(home,@"Library/Caches/index-neighbor/payload");
    AxsCacheKeeperSweep *sweep=pcsweep(home,@"Library/Caches",bundle,@{},YES);pcfinish(sweep);
    pc(sweep.removed==2 && !sweep.failed && [NSFileManager.defaultManager fileExistsAtPath:index] && [NSFileManager.defaultManager fileExistsAtPath:inner] && ![NSFileManager.defaultManager fileExistsAtPath:resource] && ![NSFileManager.defaultManager fileExistsAtPath:adjacent],"parent sweep keeps dependencies while reclaiming resource and independent sibling");
    NSString *missingHome=[fixture stringByAppendingPathComponent:@"missing-dependencies"];
    resource=pcput(missingHome,@"Library/Caches/resources/ordinary");adjacent=pcput(missingHome,@"Library/Caches/ordinary/payload");
    sweep=pcsweep(missingHome,@"Library/Caches",bundle,@{},YES);pcfinish(sweep);
    pc(sweep.removed==1 && sweep.dependencyInvalidated && [NSFileManager.defaultManager fileExistsAtPath:resource] && ![NSFileManager.defaultManager fileExistsAtPath:adjacent],"missing private dependency defers only dependent deletion");
}
static void pccollectiondependencies(NSString *fixture) {
    NSString *bundle=@"test.platform.collections";
    for (NSString *root in @[@"Library/SharedResources",@"Library/Caches/shared-resources"]) {
        AxsCacheKeeperAppRule *rule=[[AxsCacheKeeperAppRule alloc] initWithRuleID:@"shared-dependency" revision:@"1" appVersion:@"1"
            cleanablePaths:@[root] retentionPaths:@[] dependencyPaths:@[root]];
        [AxsCacheKeeperCleanupRules registerRule:rule forBundle:bundle];
        NSString *first=[root stringByAppendingPathComponent:@"A/x"],*second=[root stringByAppendingPathComponent:@"B/y"];
        AxsCacheKeeperCleanupDecision *decision=pcdecision(bundle,@"1",first,@{},YES);
        pc(decision.disposition==AxsCacheKeeperCleanupDelete && decision.basis==AxsCacheKeeperCleanupBasisAppRule &&
            [decision.dependencyPaths isEqual:@[root]],"precise rule can reclaim members of its revalidated dependency collection");
        pc(pcdecision(bundle,@"1",first,@{},NO).disposition==AxsCacheKeeperCleanupDefer,"dependency collection still requires complete content reads");
        decision=pcdecision(bundle,@"2",first,@{},YES);
        pc(decision.disposition!=AxsCacheKeeperCleanupDelete,"version mismatch cannot authorize dependency collection through platform fallback");
        if (axs_cachekeeper_platform_cache_scope(root)) {
            pc(decision.disposition==AxsCacheKeeperCleanupKeep,"platform fallback keeps declared dependencies without matching app authorization");
            pc(pcdecision(bundle,@"2",[root stringByAppendingString:@"-adjacent/payload"],@{},YES).basis==AxsCacheKeeperCleanupBasisPlatformCache,
                "dependency fallback respects path component boundaries");
        }
        NSString *home=[fixture stringByAppendingPathComponent:axs_cachekeeper_platform_cache_scope(root) ? @"platform-collection" : @"private-collection"];
        NSString *firstPath=pcput(home,first),*secondPath=pcput(home,second);
        AxsCacheKeeperSweep *a=pcsweep(home,[root stringByAppendingPathComponent:@"A"],bundle,@{},YES);
        AxsCacheKeeperSweep *b=pcsweep(home,[root stringByAppendingPathComponent:@"B"],bundle,@{},YES);
        AxsCacheKeeperCleanupJob *job=[[AxsCacheKeeperCleanupJob alloc] initWithSweeps:@[a,b] signature:@"shared-dependency" instance:@""
            clock:^NSTimeInterval{return 100;}];
        for (NSUInteger i=0;i<1000 && job.phase!=AxsCacheKeeperCleanupPhaseFinished;i++)
            [job advanceCycleWithPerRootLimit:4 gate:^BOOL{return YES;}];
        pc(job.phase==AxsCacheKeeperCleanupPhaseFinished && job.removed==2 && job.changedCount==0 && job.failed==0 &&
            !a.dependencyInvalidated && !b.dependencyInvalidated && ![NSFileManager.defaultManager fileExistsAtPath:firstPath] &&
            ![NSFileManager.defaultManager fileExistsAtPath:secondPath],"cross-sweep own removals update shared dependency snapshots and delete both real files");
    }
}
void axs_cachekeeper_run_app_retention_tests(NSString *fixture);
int main(int argc,const char *argv[]) { @autoreleasepool {
    if (argc!=3) return 2;
    NSString *mode=@(argv[1]),*fixture=@(argv[2]);
    [AxsCacheKeeperCleanupRules removeAllRulesForTesting];
    if ([mode isEqual:@"names"]) pcnames();
    else if ([mode isEqual:@"read"]) pcread();
    else if ([mode isEqual:@"pread"]) pcpread(fixture);
    else if ([mode isEqual:@"all"]) {pcnames();pcread();pcpread(fixture);pcsafety(fixture);pcdependencies(fixture);pccollectiondependencies(fixture);axs_cachekeeper_run_app_retention_tests(fixture);}
    else return 2;
    printf("PASS: platform-cache %s\n",mode.UTF8String);
    return 0;
}}
