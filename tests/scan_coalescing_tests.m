#import <Foundation/Foundation.h>
#import "../AxsCacheKeeperScanTask.h"
#import "../AxsCacheKeeperRecords.h"

static void AxsCacheKeeperCoalescingCheck(BOOL condition,const char *message) {
    if(!condition) {fprintf(stderr,"FAIL: scan coalescing: %s\n",message);exit(1);}
}
static void AxsCacheKeeperCoalescingDirectory(NSString *path) {
    AxsCacheKeeperCoalescingCheck([NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil],"fixture directory");
}
static NSDictionary *AxsCacheKeeperCoalescingRead(NSString *folder,NSString *name) {
    return [NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:name]];
}
static void AxsCacheKeeperCoalescingBatch(NSString *folder,NSString *token,NSArray *bundles,BOOL cancel) {
    AxsCacheKeeperCoalescingCheck([@{@"token":token,@"remaining":bundles,@"total":@(bundles.count),@"completed":@0,@"cancel":@(cancel)}
        writeToFile:[folder stringByAppendingPathComponent:@"batch.plist"] atomically:YES],"batch request");
}
int main(int argc,const char **argv) { @autoreleasepool {
    AxsCacheKeeperCoalescingCheck(argc==2,"unique fixture root");NSString *base=[NSString stringWithUTF8String:argv[1]];
    NSString *folder=[base stringByAppendingPathComponent:@"records"],*home=[base stringByAppendingPathComponent:@"home"];
    AxsCacheKeeperCoalescingDirectory(folder);
    for(NSUInteger directory=0;directory<32;directory++) {
        NSString *child=[home stringByAppendingPathComponent:[NSString stringWithFormat:@"Library/Caches/d%lu",(unsigned long)directory]];
        AxsCacheKeeperCoalescingDirectory(child);
        for(NSUInteger file=0;file<40;file++) AxsCacheKeeperCoalescingCheck([[NSMutableData dataWithLength:16]
            writeToFile:[child stringByAppendingPathComponent:[NSString stringWithFormat:@"f%lu",(unsigned long)file]] atomically:YES],"real cache file");
    }
    NSArray *bundles=@[@"fixture.app0",@"fixture.app1",@"fixture.app2",@"fixture.app3"];
    __block NSTimeInterval now=10;__block NSUInteger writes=0;__block BOOL reject=NO;
    NSDictionary *(^resolver)(NSString *)=^NSDictionary *(NSString *bundle){(void)bundle;return @{@"home":[NSURL fileURLWithPath:home],@"groups":@{}};};
    AxsCacheKeeperScanService *service=[[AxsCacheKeeperScanService alloc] initWithFolder:folder resolver:resolver writer:^BOOL(NSDictionary *record,NSString *path){
        if([path.lastPathComponent isEqual:@"snapshots.plist"]) {writes++;if(reject) return NO;}
        return [record writeToFile:path atomically:YES];
    }];
    service.axs_cachekeeper_clock=^{return now;};
    AxsCacheKeeperCoalescingBatch(folder,@"cohort",bundles,NO);
    [service tick];NSDictionary *first=AxsCacheKeeperCoalescingRead(folder,@"snapshots.plist");
    AxsCacheKeeperCoalescingCheck(first.count==4 && writes==1,"first cohort is one durable publication");
    for(NSString *bundle in bundles) AxsCacheKeeperCoalescingCheck([first[bundle][@"token"] isEqual:@"cohort"] &&
        [first[bundle][@"scanProgress"][@"state"] isEqual:@"running"],"first receipts retain all request identities");
    for(NSUInteger i=0;i<3;i++) {[service tick];now+=.05;}
    AxsCacheKeeperCoalescingCheck(writes==1,"peer first progress does not rewrite shared history");
    now=12;[service tick];AxsCacheKeeperCoalescingCheck(writes==2,"service interval publishes cohort once");
    for(NSUInteger i=0;i<3;i++) {[service tick];now+=.05;}
    AxsCacheKeeperCoalescingCheck(writes==2,"peer progress shares the service interval");

    NSMutableDictionary *external=[AxsCacheKeeperCoalescingRead(folder,@"snapshots.plist") mutableCopy];
    external[@"external.app"]=@{@"bytes":@73,@"complete":@YES};
    AxsCacheKeeperCoalescingCheck([external writeToFile:[folder stringByAppendingPathComponent:@"snapshots.plist"] atomically:YES],"external durable edit");
    NSUInteger ticks=0;while([service tick] && ++ticks<300) {now+=.05;}
    AxsCacheKeeperCoalescingCheck(ticks<300,"bounded cohort completion");
    NSDictionary *finished=AxsCacheKeeperCoalescingRead(folder,@"batch.plist"),*history=AxsCacheKeeperCoalescingRead(folder,@"snapshots.plist");
    AxsCacheKeeperCoalescingCheck([finished[@"completed"] unsignedIntegerValue]==4 && ![finished[@"remaining"] count],"completion follows durable member terminal receipts");
    for(NSString *bundle in bundles) AxsCacheKeeperCoalescingCheck([history[bundle][@"scanProgress"][@"state"] isEqual:@"complete"],"all terminal receipts retained");
    AxsCacheKeeperCoalescingCheck([history[@"external.app"] isEqual:external[@"external.app"]],"external record survives all shared commits");

    AxsCacheKeeperCoalescingBatch(folder,@"cancel-cohort",bundles,NO);[service tick];
    NSMutableDictionary *cancel=[AxsCacheKeeperCoalescingRead(folder,@"batch.plist") mutableCopy];cancel[@"cancel"]=@YES;
    AxsCacheKeeperCoalescingCheck([cancel writeToFile:[folder stringByAppendingPathComponent:@"batch.plist"] atomically:YES],"cancel active cohort");
    NSUInteger before=writes;[service tick];history=AxsCacheKeeperCoalescingRead(folder,@"snapshots.plist");
    AxsCacheKeeperCoalescingCheck(writes==before+1,"cancellation publishes entire cohort once");
    for(NSString *bundle in bundles) AxsCacheKeeperCoalescingCheck([history[bundle][@"scanProgress"][@"state"] isEqual:@"cancelled"],"cancelled members have durable reasons");
    AxsCacheKeeperCoalescingCheck([AxsCacheKeeperCoalescingRead(folder,@"batch.plist")[@"completed"] unsignedIntegerValue]==0,"cancelled cohort is never counted complete");

    AxsCacheKeeperCoalescingBatch(folder,@"failure-cohort",bundles,NO);reject=YES;[service tick];
    AxsCacheKeeperCoalescingCheck([AxsCacheKeeperCoalescingRead(folder,@"batch.plist")[@"scanState"] isEqual:@"saveFailed"],"shared save failure remains visible");
    AxsCacheKeeperCoalescingCheck([AxsCacheKeeperCoalescingRead(folder,@"batch.plist")[@"completed"] unsignedIntegerValue]==0,"failed shared save cannot count any member complete");
    // Mutate real request files after the production history read, rather than
    // accepting a stale token or deriving cancel from a second unrelated read.
    for(NSUInteger mode=0;mode<2;mode++) {
        NSString *changing=[base stringByAppendingPathComponent:[NSString stringWithFormat:@"read-boundary-%lu",(unsigned long)mode]];
        AxsCacheKeeperCoalescingDirectory(changing);
        __block NSUInteger boundaryWrites=0;
        AxsCacheKeeperScanService *boundary=[[AxsCacheKeeperScanService alloc] initWithFolder:changing resolver:resolver writer:^BOOL(NSDictionary *record,NSString *path){
            if([path.lastPathComponent isEqual:@"snapshots.plist"]) boundaryWrites++;
            return [record writeToFile:path atomically:YES];
        }];
        boundary.axs_cachekeeper_clock=^{return now;};now=100;
        AxsCacheKeeperCoalescingBatch(changing,@"before-read",bundles,NO);[boundary tick];
        NSData *beforeRead=[NSData dataWithContentsOfFile:[changing stringByAppendingPathComponent:@"snapshots.plist"]];
        __block BOOL armed=YES;
        boundary.axs_cachekeeper_didReadHistory=^{
            if(!armed) return;armed=NO;
            AxsCacheKeeperCoalescingBatch(changing,mode ? @"before-read" : @"after-read",bundles,mode==1);
        };
        now=102;[boundary tick];
        if(!mode) {
            AxsCacheKeeperCoalescingCheck(boundaryWrites==1 && [[NSData dataWithContentsOfFile:[changing stringByAppendingPathComponent:@"snapshots.plist"]] isEqual:beforeRead],"read-boundary replacement cannot publish any stale member");
            AxsCacheKeeperCoalescingCheck([AxsCacheKeeperCoalescingRead(changing,@"batch.plist")[@"completed"] unsignedIntegerValue]==0,"replacement never acknowledges old completion");
        } else {
            NSDictionary *stopped=AxsCacheKeeperCoalescingRead(changing,@"snapshots.plist");
            AxsCacheKeeperCoalescingCheck(boundaryWrites==2,"read-boundary cancellation commits one cohort");
            for(NSString *bundle in bundles) AxsCacheKeeperCoalescingCheck([stopped[bundle][@"scanProgress"][@"state"] isEqual:@"cancelled"],"read-boundary cancellation terminates every current member");
            AxsCacheKeeperCoalescingCheck([AxsCacheKeeperCoalescingRead(changing,@"batch.plist")[@"completed"] unsignedIntegerValue]==0,"read-boundary cancellation never acknowledges completion");
        }
    }

    NSString *mixed=[base stringByAppendingPathComponent:@"mixed-receipt-failure"];
    AxsCacheKeeperCoalescingDirectory(mixed);__block BOOL failSingle=YES;
    AxsCacheKeeperScanService *mixedService=[[AxsCacheKeeperScanService alloc] initWithFolder:mixed resolver:resolver writer:^BOOL(NSDictionary *record,NSString *path){
        if(failSingle && [path.lastPathComponent isEqual:@"scan.plist"]) return NO;
        return [record writeToFile:path atomically:YES];
    }];
    now=200;mixedService.axs_cachekeeper_clock=^{return now;};
    AxsCacheKeeperCoalescingBatch(mixed,@"mixed-batch",bundles,NO);
    AxsCacheKeeperCoalescingCheck([@{@"token":@"mixed-single",@"bundle":@"fixture.single"} writeToFile:[mixed stringByAppendingPathComponent:@"request.plist"] atomically:YES],"mixed single request");
    [mixedService tick];NSDictionary *mixedHistory=AxsCacheKeeperCoalescingRead(mixed,@"snapshots.plist");
    AxsCacheKeeperCoalescingCheck([mixedHistory[@"fixture.single"][@"scanProgress"][@"state"] isEqual:@"saveFailed"],"single receipt failure remains visible in coalesced history");
    for(NSString *bundle in bundles) AxsCacheKeeperCoalescingCheck([mixedHistory[bundle][@"token"] isEqual:@"mixed-batch"] && [mixedHistory[bundle][@"scanProgress"][@"state"] isEqual:@"running"],"single receipt failure does not fail independent batch members");
    failSingle=NO;ticks=0;while([mixedService tick] && ++ticks<400) now+=.05;
    AxsCacheKeeperCoalescingCheck(ticks<400 && [AxsCacheKeeperCoalescingRead(mixed,@"batch.plist")[@"completed"] unsignedIntegerValue]==4,"mixed cohort completes after receipt recovery");
    AxsCacheKeeperCoalescingCheck([AxsCacheKeeperCoalescingRead(mixed,@"scan.plist")[@"scanProgress"][@"state"] isEqual:@"saveFailed"],"recovered receipt does not promote failed traversal");
    printf("PASS: real shared history coalescing, cadence, terminals, external edits, read-boundary identity/cancel and independent failure channels\n");return 0;
} }
