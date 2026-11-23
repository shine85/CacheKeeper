#import <Foundation/Foundation.h>
#import "../AxsCacheKeeperCleanupSchedule.h"
#import "../AxsCacheKeeperSweep.h"
#import "../AxsCacheKeeperCleanupJob.h"
#import "../AxsCacheKeeperReceipts.h"
#include <unistd.h>
#include <errno.h>

static void ckcheck(BOOL value,const char *message) {if (!value) {fprintf(stderr,"FAIL: cleanup observation: %s\n",message);exit(1);}}
static void put(NSString *path) {ckcheck([@"rebuildable cache" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil],"fixture write");}
static AxsCacheKeeperSweep *sweep(NSString *root,NSString *home,BOOL mature) {
    return [[AxsCacheKeeperSweep alloc] initWithRoot:root bundle:@"test.observation" version:@"1" containerPath:home state:@{} clock:^NSTimeInterval {return NSDate.date.timeIntervalSince1970+(mature ? 600 : 0);}];
}
static void finish(AxsCacheKeeperSweep *s) {for (int i=0;i<1000 && !s.complete && !s.cancelled;i++) [s advance:16 shouldContinue:^BOOL{return YES;}];ckcheck(s.complete && !s.cancelled,"fixture finishes");}
int main(int argc,const char **argv) {@autoreleasepool {
    if (argc!=2) return 2;NSString *home=[NSString stringWithUTF8String:argv[1]],*root=[home stringByAppendingPathComponent:@"Library/Caches"];
    ckcheck([NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil],"fixture directory");
    AxsCacheKeeperSweep *empty=sweep(root,home,YES);finish(empty);
    NSDictionary *registration=[AxsCacheKeeperCleanupSchedule registrationForSweep:empty signature:@"one" now:10];
    ckcheck(registration!=nil,"stable cache observation prevents repeated empty rounds");
    ckcheck([AxsCacheKeeperCleanupSchedule checkRoot:root registration:registration signature:@"one" now:44 stat:nil error:nil]==AxsCacheKeeperRangeUnchanged,"metadata checked before unchanged reuse");
    ckcheck(![AxsCacheKeeperCleanupSchedule hasWorkForSweeps:@[] diagnostics:@{} externalFailures:0 manual:NO],"unchanged observation creates no job");
    ckcheck([AxsCacheKeeperCleanupSchedule hasWorkForSweeps:@[] diagnostics:@{} externalFailures:0 manual:YES] && [AxsCacheKeeperCleanupSchedule hasWorkForSweeps:@[] diagnostics:@{} externalFailures:1 manual:NO],"manual and failures remain work");
    NSString *newFile=[root stringByAppendingPathComponent:@"new"];put(newFile);
    ckcheck(![AxsCacheKeeperCleanupSchedule registrationForSweep:empty signature:@"one" now:45],"post-observation new file cannot be learned as stable");
    ckcheck([AxsCacheKeeperCleanupSchedule checkRoot:root registration:registration signature:@"one" now:45 stat:nil error:nil]==AxsCacheKeeperRangeScan,"new root content starts new work");
    AxsCacheKeeperSweep *young=sweep(root,home,NO);finish(young);
    ckcheck(young.recentCount==1 && ![AxsCacheKeeperCleanupSchedule registrationForSweep:young signature:@"one" now:45] && [NSFileManager.defaultManager fileExistsAtPath:newFile],"young file stays pending and retained");
    AxsCacheKeeperSweep *ready=sweep(root,home,YES);finish(ready);
    ckcheck(ready.removed==1 && ![NSFileManager.defaultManager fileExistsAtPath:newFile],"mature cache really removed");
    ckcheck(![AxsCacheKeeperCleanupSchedule registrationForSweep:ready signature:@"one" now:46],"deleting sweep must be fully observed next short cycle");
    AxsCacheKeeperSweep *settled=sweep(root,home,YES);finish(settled);
    registration=[AxsCacheKeeperCleanupSchedule registrationForSweep:settled signature:@"one" now:46];ckcheck(registration!=nil,"deletion-free settled observation registers");
    ckcheck([AxsCacheKeeperCleanupSchedule checkRoot:root registration:registration signature:@"changed" now:47 stat:nil error:nil]==AxsCacheKeeperRangeScan && [AxsCacheKeeperCleanupSchedule checkRoot:root registration:registration signature:@"one" now:1846 stat:nil error:nil]==AxsCacheKeeperRangeScan,"configuration and expiry revalidate");
    for (NSNumber *code in @[@EIO,@EACCES,@ENOENT]) {NSString *error=nil;AxsCacheKeeperRangeState state=[AxsCacheKeeperCleanupSchedule checkRoot:root registration:registration signature:@"one" now:47 stat:^int(const char *p,struct stat *s){(void)p;(void)s;errno=code.intValue;return -1;} error:&error];ckcheck(state==(code.intValue==ENOENT ? AxsCacheKeeperRangeMissing : AxsCacheKeeperRangeFailed),"metadata failures cannot reuse observation");}
    NSDictionary *carried=[AxsCacheKeeperCleanupSchedule carriedReport:registration];ckcheck(![carried[@"measurementComplete"] boolValue] && ![carried[@"coverageComplete"] boolValue],"carried observation never claims fresh measurement");
    put(newFile);NSString *sibling=[root stringByAppendingPathComponent:@"new-sibling"];
    AxsCacheKeeperSweep *concurrent=[[AxsCacheKeeperSweep alloc] initWithRoot:root bundle:@"test.observation" version:@"1" containerPath:home state:@{} clock:^NSTimeInterval{return NSDate.date.timeIntervalSince1970+600;} unlinkFile:^int(int fd,const char *name) {
        int result=unlinkat(fd,name,0);if (!result) put(sibling);return result;
    }];finish(concurrent);
    ckcheck(concurrent.removed==1 && [NSFileManager.defaultManager fileExistsAtPath:sibling] &&
        ![AxsCacheKeeperCleanupSchedule registrationForSweep:concurrent signature:@"one" now:48],"unlink callback new sibling never enters stable registration");
    AxsCacheKeeperSweep *next=sweep(root,home,YES);finish(next);ckcheck(next.removed==1 && ![NSFileManager.defaultManager fileExistsAtPath:sibling],"concurrent new sibling is handled by next short observation");

    NSString *status=[home stringByAppendingPathComponent:@"Status"],*bundle=@"test.observation";
    ckcheck([NSFileManager.defaultManager createDirectoryAtPath:status withIntermediateDirectories:YES attributes:nil error:nil],"receipt directory");
    [AxsCacheKeeperReceipts resetForTesting];[AxsCacheKeeperReceipts configureWithStatusFolder:status];
    ckcheck([AxsCacheKeeperReceipts submitRoundForBundle:bundle roundID:@"previous-effective" removed:2 bytes:20 endReason:AxsCacheKeeperCleanupEndReasonCompleted phase:@"complete" message:@"fixture" failed:0 effectivePaths:@[@"Library/Caches"] discoveredPaths:nil directories:nil round:@{@"removed":@2,@"bytes":@20} coverageComplete:YES],"effective historical receipt");
    NSString *receiptPath=[status stringByAppendingPathComponent:[bundle stringByAppendingString:@".auto.plist"]];
    NSData *original=[NSData dataWithContentsOfFile:receiptPath];
    AxsCacheKeeperSweep *quiet=sweep(root,home,YES);finish(quiet);
    NSMutableDictionary *ranges=[@{@"Library/Caches":[AxsCacheKeeperCleanupSchedule registrationForSweep:quiet signature:@"one" now:50]} mutableCopy];
    for (NSUInteger cycle=0;cycle<3;cycle++) {
        [AxsCacheKeeperReceipts flushAllPending];NSMutableDictionary *diagnostics=[NSMutableDictionary new];
        NSArray *work=[AxsCacheKeeperCleanupSchedule sweepsForRanges:@[@"Library/Caches",@"missing"] home:home bundle:bundle version:@"1" state:@{} signature:@"one" registrations:ranges exclusions:@[] restoreError:nil now:84+34*cycle diagnostics:diagnostics];
        ckcheck(![AxsCacheKeeperCleanupSchedule hasWorkForSweeps:work diagnostics:diagnostics externalFailures:0 manual:NO],"production range plan returns no job for unchanged or missing roots");
        ckcheck([[NSData dataWithContentsOfFile:receiptPath] isEqual:original],"three observation cycles preserve exact receipt history and effective deletion totals");
    }
    put(newFile);NSMutableDictionary *diagnostics=[NSMutableDictionary new];
    NSArray *newWork=[AxsCacheKeeperCleanupSchedule sweepsForRanges:@[@"Library/Caches"] home:home bundle:bundle version:@"1" state:@{} signature:@"one" registrations:ranges exclusions:@[] restoreError:nil now:153 diagnostics:diagnostics];
    ckcheck(newWork.count==1 && [AxsCacheKeeperCleanupSchedule hasWorkForSweeps:newWork diagnostics:diagnostics externalFailures:0 manual:NO],"production range plan notices new file");
    AxsCacheKeeperCleanupJob *cancel=[[AxsCacheKeeperCleanupJob alloc] initWithSweeps:newWork signature:@"one" instance:@"" clock:^NSTimeInterval{return 153;}];
    [cancel advanceCycleWithPerRootLimit:16 gate:^BOOL{return NO;}];
    ckcheck(cancel.endReason==AxsCacheKeeperCleanupEndReasonCancelled && !cancel.removed && [NSFileManager.defaultManager fileExistsAtPath:newFile],"new work cancelled before unlink");
    ckcheck(!chmod(status.fileSystemRepresentation,0500),"receipt write failure fixture");
    ckcheck(![AxsCacheKeeperCleanupSchedule retireJob:cancel bundle:bundle message:@"cancelled"] && [AxsCacheKeeperReceipts hasPendingForBundle:bundle],"cancelled receipt waits for real storage recovery");
    ckcheck(!chmod(status.fileSystemRepresentation,0700),"receipt storage recovery");
    [AxsCacheKeeperReceipts flushAllPending];NSDictionary *saved=[NSDictionary dictionaryWithContentsOfFile:receiptPath];
    ckcheck(![AxsCacheKeeperReceipts hasPendingForBundle:bundle] && [saved[@"removed"] unsignedIntegerValue]==2 && [saved[@"lastEffectiveCleanup"][@"roundID"] isEqual:@"previous-effective"],"flush before observation preserves effective round despite cancellation and write failure");
    [AxsCacheKeeperReceipts resetForTesting];
    puts("PASS: cleanup observation real files, maturation, metadata, expiry and no-work scheduling");return 0;
}}
