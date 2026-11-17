#import <Foundation/Foundation.h>
#import "../AxsCacheKeeperScanTask.h"
#import "../AxsCacheKeeperRecords.h"
#import "../AxsCacheKeeperDirectories.h"
#include <unistd.h>

static void axs_cachekeeper_test_check(BOOL ok, const char *message) { if (!ok) {fprintf(stderr,"FAIL: scan tasks: %s\n",message);exit(1);} }
static void axs_cachekeeper_test_directory(NSString *path) {axs_cachekeeper_test_check([NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil],"create fixture");}
static void axs_cachekeeper_test_file(NSString *path, NSUInteger size) {axs_cachekeeper_test_check([[NSMutableData dataWithLength:size] writeToFile:path atomically:YES],"write fixture");}
static NSDictionary *axs_cachekeeper_test_read(NSString *folder, NSString *name) { return [NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:name]]; }
static void axs_cachekeeper_test_request(NSString *folder, NSString *token, NSString *bundle, BOOL cancel) {
    axs_cachekeeper_test_check([@{@"token":token,@"bundle":bundle,@"cancel":@(cancel)} writeToFile:[folder stringByAppendingPathComponent:@"request.plist"] atomically:YES],"request write");
}
int main(int argc, const char **argv) { @autoreleasepool {
    axs_cachekeeper_test_check(argc==2,"fixture argument");NSString *base=[NSString stringWithUTF8String:argv[1]];
    NSString *tree=[base stringByAppendingPathComponent:@"tree"];axs_cachekeeper_test_directory(tree);
    unsigned long long expected=0;
    for (NSUInteger i=0;i<60;i++) {NSString *sub=[tree stringByAppendingPathComponent:[NSString stringWithFormat:@"d%lu",(unsigned long)i]];axs_cachekeeper_test_directory(sub);
        for(NSUInteger j=0;j<4;j++){NSUInteger size=i+j+1;axs_cachekeeper_test_file([sub stringByAppendingPathComponent:[NSString stringWithFormat:@"f%lu",(unsigned long)j]],size);expected+=size;}}
    NSString *outside=[base stringByAppendingPathComponent:@"outside"];axs_cachekeeper_test_directory(outside);axs_cachekeeper_test_file([outside stringByAppendingPathComponent:@"secret"],10000);
    axs_cachekeeper_test_check(symlink(outside.fileSystemRepresentation,[tree stringByAppendingPathComponent:@"link"].fileSystemRepresentation)==0,"symlink fixture");
    AxsCacheKeeperScanCursor *cursor=[[AxsCacheKeeperScanCursor alloc] initWithRoot:[NSURL fileURLWithPath:tree] entryLimit:10000 depthLimit:64];
    NSUInteger slices=0;while([cursor.state isEqual:@"running"] && slices++<1000) { [cursor advanceEntries:3 seconds:1];axs_cachekeeper_test_check(cursor.openDirectoryCount<=64,"bounded descriptors"); }
    axs_cachekeeper_test_check([cursor.state isEqual:@"complete"] && [cursor.result[@"bytes"] unsignedLongLongValue]==expected,"small slices equal full traversal without symlink escape");
    axs_cachekeeper_test_check(slices>50 && cursor.openDirectoryCount==0,"continued cursor and released descriptors");
    AxsCacheKeeperScanCursor *full=[[AxsCacheKeeperScanCursor alloc] initWithRoot:[NSURL fileURLWithPath:tree] entryLimit:10000 depthLimit:64];[full advanceEntries:10000 seconds:10];
    axs_cachekeeper_test_check([full.result[@"bytes"] isEqual:cursor.result[@"bytes"]],"one traversal agrees with repeated small budgets");
    cursor=[[AxsCacheKeeperScanCursor alloc] initWithRoot:[NSURL fileURLWithPath:tree] entryLimit:5 depthLimit:64];[cursor advanceEntries:100 seconds:1];
    axs_cachekeeper_test_check([cursor.state isEqual:@"entryLimit"] && ![cursor.result[@"complete"] boolValue] && cursor.openDirectoryCount==0,"entry limit is terminal partial");
    cursor=[[AxsCacheKeeperScanCursor alloc] initWithRoot:[NSURL fileURLWithPath:tree] entryLimit:10000 depthLimit:64];[cursor advanceEntries:3 seconds:1];[cursor stopWithState:@"cancelled"];
    NSDictionary *cancelled=cursor.result;[cursor advanceEntries:100 seconds:1];axs_cachekeeper_test_check([cursor.result isEqual:cancelled] && cursor.openDirectoryCount==0,"cancel freezes partial and closes cursor");
    NSString *moving=[base stringByAppendingPathComponent:@"moving"];axs_cachekeeper_test_directory(moving);axs_cachekeeper_test_file([moving stringByAppendingPathComponent:@"x"],7);
    cursor=[[AxsCacheKeeperScanCursor alloc] initWithRoot:[NSURL fileURLWithPath:moving] entryLimit:100 depthLimit:64];
    axs_cachekeeper_test_check([NSFileManager.defaultManager moveItemAtPath:moving toPath:[moving stringByAppendingString:@"-old"] error:nil],"replace root");axs_cachekeeper_test_directory(moving);[cursor advanceEntries:10 seconds:1];
    axs_cachekeeper_test_check([cursor.state isEqual:@"identityChanged"] && ![cursor.result[@"complete"] boolValue],"replaced root cannot complete");
    NSString *empty=[base stringByAppendingPathComponent:@"empty"];axs_cachekeeper_test_directory(empty);
    cursor=[[AxsCacheKeeperScanCursor alloc] initWithRoot:[NSURL fileURLWithPath:empty] entryLimit:10 depthLimit:64];[cursor advanceEntries:10 seconds:1];axs_cachekeeper_test_check([cursor.state isEqual:@"complete"] && [cursor.result[@"bytes"] unsignedLongLongValue]==0,"empty directory completes");
    cursor=[[AxsCacheKeeperScanCursor alloc] initWithRoot:[NSURL fileURLWithPath:[base stringByAppendingPathComponent:@"absent"]] entryLimit:10 depthLimit:64];axs_cachekeeper_test_check([cursor.state isEqual:@"readError"] && ![cursor.result[@"complete"] boolValue],"missing root reports error");
    cursor=[[AxsCacheKeeperScanCursor alloc] initWithRoot:[NSURL fileURLWithPath:tree] entryLimit:10000 depthLimit:1];[cursor advanceEntries:10 seconds:1];axs_cachekeeper_test_check([cursor.state isEqual:@"depthLimit"] && cursor.openDirectoryCount==0,"depth limit is partial and releases resources");
    cursor=[[AxsCacheKeeperScanCursor alloc] initWithRoot:[NSURL fileURLWithPath:tree] entryLimit:10000 depthLimit:64];[cursor advanceEntries:3 seconds:1];[cursor stopWithState:@"timeLimit"];
    axs_cachekeeper_test_check([cursor.result[@"scanDiagnostics"][@"timeBudgetExceeded"] boolValue] && ![cursor.result[@"complete"] boolValue] && cursor.openDirectoryCount==0,"task time stop is terminal partial");
    NSString *wide=[base stringByAppendingPathComponent:@"wide"];axs_cachekeeper_test_directory(wide);
    for(NSUInteger i=0;i<270;i++) axs_cachekeeper_test_directory([wide stringByAppendingPathComponent:[NSString stringWithFormat:@"d%lu",(unsigned long)i]]);
    NSDictionary *discovery=nil;NSArray *targets=axs_cachekeeper_bounded_scan_targets([NSURL fileURLWithPath:wide],@{},NO,&discovery);
    axs_cachekeeper_test_check(targets.count<=256 && ![discovery[@"discoveryComplete"] boolValue] && ![discovery[@"measurementComplete"] boolValue],"wide discovery bounded and explicitly partial");
    axs_cachekeeper_test_check(axs_cachekeeper_record_valid(@{@"rows":@[],@"updated":NSDate.date},0),"old receipts remain valid without progress");
    NSString *home=[base stringByAppendingPathComponent:@"home"];axs_cachekeeper_test_directory([home stringByAppendingPathComponent:@"Library/Caches"]);
    for(NSUInteger i=0;i<1600;i++) axs_cachekeeper_test_file([home stringByAppendingPathComponent:[NSString stringWithFormat:@"Library/Caches/f%lu",(unsigned long)i]],1);
    NSString *small=[base stringByAppendingPathComponent:@"small"];axs_cachekeeper_test_directory([small stringByAppendingPathComponent:@"Library/Caches"]);axs_cachekeeper_test_file([small stringByAppendingPathComponent:@"Library/Caches/x"],5);
    __block NSString *resolved=home;
    NSDictionary *(^resolver)(NSString *)=^NSDictionary *(NSString *bundle){return @{@"home":[NSURL fileURLWithPath:[bundle isEqual:@"small.app"] ? small : resolved],@"groups":@{}};};
    NSString *folder=[base stringByAppendingPathComponent:@"service"];axs_cachekeeper_test_directory(folder);
    AxsCacheKeeperScanService *service=[[AxsCacheKeeperScanService alloc] initWithFolder:folder resolver:resolver writer:nil];
    __block NSUInteger accepted=0;service.acceptedRequest=^(NSString *bundle,BOOL diagnostic){(void)bundle;if(!diagnostic) accepted++;};
    axs_cachekeeper_test_request(folder,@"one",@"large.app",NO);[service tick];NSDictionary *first=axs_cachekeeper_test_read(folder,@"scan.plist");
    axs_cachekeeper_test_check(accepted==1,"ordinary request acceptance notified once");[service tick];axs_cachekeeper_test_check(accepted==1,"continuation does not refresh process policy");
    axs_cachekeeper_test_check([first[@"scanProgress"][@"state"] isEqual:@"running"] && ![first[@"complete"] boolValue],"first partial receipt remains running");
    axs_cachekeeper_test_request(folder,@"two",@"large.app",NO);[service tick];axs_cachekeeper_test_check([axs_cachekeeper_test_read(folder,@"scan.plist")[@"token"] isEqual:@"two"],"replacement request never publishes old generation");
    axs_cachekeeper_test_request(folder,@"two",@"large.app",YES);[service tick];axs_cachekeeper_test_check([axs_cachekeeper_test_read(folder,@"scan.plist")[@"scanProgress"][@"state"] isEqual:@"cancelled"],"cancel request publishes explicit terminal");
    axs_cachekeeper_test_request(folder,@"identity",@"large.app",NO);[service tick];resolved=small;[service tick];axs_cachekeeper_test_check([axs_cachekeeper_test_read(folder,@"scan.plist")[@"scanProgress"][@"state"] isEqual:@"identityChanged"],"container replacement stops prior bytes");resolved=home;
    axs_cachekeeper_test_request(folder,@"restart",@"large.app",NO);[service tick];service=nil;
    service=[[AxsCacheKeeperScanService alloc] initWithFolder:folder resolver:resolver writer:nil];[service tick];axs_cachekeeper_test_check([axs_cachekeeper_test_read(folder,@"scan.plist")[@"scanProgress"][@"state"] isEqual:@"interrupted"],"restart invalidates persisted running cursor");
    __block BOOL failHistory=YES;
    service=[[AxsCacheKeeperScanService alloc] initWithFolder:folder resolver:resolver writer:^BOOL(NSDictionary *record,NSString *path){if(failHistory && [path.lastPathComponent isEqual:@"snapshots.plist"]) return NO;return [record writeToFile:path atomically:YES];}];
    axs_cachekeeper_test_request(folder,@"save",@"large.app",NO);[service tick];axs_cachekeeper_test_check([axs_cachekeeper_test_read(folder,@"scan.plist")[@"scanProgress"][@"state"] isEqual:@"saveFailed"],"save failure never becomes complete");
    failHistory=NO;[service tick];axs_cachekeeper_test_check([axs_cachekeeper_test_read(folder,@"scan.plist")[@"scanProgress"][@"state"] isEqual:@"saveFailed"],"save retry does not restart traversal");
    NSDictionary *batch=@{@"token":@"batch",@"remaining":@[@"large.app",@"small.app"],@"total":@2,@"completed":@0};axs_cachekeeper_test_check([batch writeToFile:[folder stringByAppendingPathComponent:@"batch.plist"] atomically:YES],"batch request");
    for(NSUInteger i=0;i<3;i++) [service tick];
    axs_cachekeeper_test_check([axs_cachekeeper_test_read(folder,@"snapshots.plist")[@"small.app"][@"scanProgress"][@"state"] isEqual:@"complete"],"small batch member completes while large task remains active");
    axs_cachekeeper_test_check([axs_cachekeeper_test_read(folder,@"batch.plist")[@"completed"] unsignedIntegerValue]==1,"batch completed counts terminal members only");
    for(NSUInteger i=0;i<30 && [axs_cachekeeper_test_read(folder,@"batch.plist")[@"remaining"] count];i++) [service tick];
    axs_cachekeeper_test_check([axs_cachekeeper_test_read(folder,@"batch.plist")[@"completed"] unsignedIntegerValue]==2,"batch finishes continued large task");
    NSDictionary *completed=axs_cachekeeper_test_read(folder,@"snapshots.plist")[@"large.app"];
    axs_cachekeeper_test_request(folder,@"history",@"large.app",NO);[service tick];
    NSDictionary *partial=axs_cachekeeper_test_read(folder,@"scan.plist");
    axs_cachekeeper_test_check([partial[@"previousRows"] isEqual:completed[@"rows"]],"first slice keeps pre-task history");
    NSArray *recent=partial[@"recentScans"];
    for(NSUInteger i=0;i<10;i++) [service tick];
    NSDictionary *finished=axs_cachekeeper_test_read(folder,@"scan.plist");
    axs_cachekeeper_test_check([finished[@"recentScans"] isEqual:recent] && [finished[@"previousRows"] isEqual:completed[@"rows"]],"continuations never append fake history");
    NSMutableDictionary *privateProgress=[finished[@"scanProgress"] mutableCopy];privateProgress[@"privatePath"]=@"/private/secret";
    axs_cachekeeper_test_check(!axs_cachekeeper_scan_progress_projection(privateProgress)[@"privatePath"],"progress projection removes unknown private fields");
    NSMutableDictionary *malformed=[finished mutableCopy];[malformed removeObjectForKey:@"scanDiagnostics"];
    axs_cachekeeper_test_check(!axs_cachekeeper_record_valid(malformed,0),"progress without diagnostics rejected");
    NSString *receiptFailure=[base stringByAppendingPathComponent:@"receipt-failure"];axs_cachekeeper_test_directory(receiptFailure);
    __block BOOL failReceipt=YES;
    AxsCacheKeeperScanService *failure=[[AxsCacheKeeperScanService alloc] initWithFolder:receiptFailure resolver:resolver writer:^BOOL(NSDictionary *record,NSString *path){if(failReceipt && [path.lastPathComponent isEqual:@"scan.plist"]) return NO;return [record writeToFile:path atomically:YES];}];
    axs_cachekeeper_test_request(receiptFailure,@"unwritable",@"small.app",NO);[failure tick];
    axs_cachekeeper_test_check([axs_cachekeeper_test_read(receiptFailure,@"snapshots.plist")[@"small.app"][@"scanProgress"][@"state"] isEqual:@"saveFailed"],"receipt write failure visible in history and never complete");
    failReceipt=NO;[failure tick];axs_cachekeeper_test_check([axs_cachekeeper_test_read(receiptFailure,@"scan.plist")[@"scanProgress"][@"state"] isEqual:@"saveFailed"],"receipt retry remains failed without rescan");
    NSString *batchFailure=[base stringByAppendingPathComponent:@"batch-failure"];axs_cachekeeper_test_directory(batchFailure);
    __block NSUInteger writes=0;__block NSUInteger resolvedCount=0;
    failure=[[AxsCacheKeeperScanService alloc] initWithFolder:batchFailure resolver:^NSDictionary *(NSString *bundle){resolvedCount++;return resolver(bundle);} writer:^BOOL(NSDictionary *record,NSString *path){if([path.lastPathComponent isEqual:@"batch.plist"] && [record[@"completed"] unsignedIntegerValue]==1 && writes++==0) return NO;return [record writeToFile:path atomically:YES];}];
    axs_cachekeeper_test_check([@{@"token":@"retry",@"remaining":@[@"small.app"],@"total":@1,@"completed":@0} writeToFile:[batchFailure stringByAppendingPathComponent:@"batch.plist"] atomically:YES],"batch retry fixture");
    [failure tick];NSUInteger before=resolvedCount;[failure tick];
    axs_cachekeeper_test_check([axs_cachekeeper_test_read(batchFailure,@"batch.plist")[@"completed"] unsignedIntegerValue]==1 && resolvedCount==before,"batch progress retry does not enumerate again");
    axs_cachekeeper_test_check([@{@"token":@"cancel-batch",@"remaining":@[@"large.app"],@"total":@1,@"completed":@0} writeToFile:[batchFailure stringByAppendingPathComponent:@"batch.plist"] atomically:YES],"batch cancel fixture");[failure tick];
    NSMutableDictionary *stop=[axs_cachekeeper_test_read(batchFailure,@"batch.plist") mutableCopy];stop[@"cancel"]=@YES;axs_cachekeeper_test_check([stop writeToFile:[batchFailure stringByAppendingPathComponent:@"batch.plist"] atomically:YES],"batch stop write");[failure tick];
    axs_cachekeeper_test_check([axs_cachekeeper_test_read(batchFailure,@"batch.plist")[@"completed"] unsignedIntegerValue]==0 && [axs_cachekeeper_test_read(batchFailure,@"batch.plist")[@"scanState"] isEqual:@"cancelled"],"batch cancel does not count partial as completed");
    axs_cachekeeper_test_check([axs_cachekeeper_test_read(batchFailure,@"snapshots.plist")[@"large.app"][@"scanProgress"][@"state"] isEqual:@"cancelled"],"batch cancel freezes task");
    axs_cachekeeper_test_check([@{@"token":@"old-batch",@"remaining":@[@"large.app"],@"total":@1,@"completed":@0} writeToFile:[batchFailure stringByAppendingPathComponent:@"batch.plist"] atomically:YES],"old batch");[failure tick];
    axs_cachekeeper_test_check([@{@"token":@"new-batch",@"remaining":@[@"small.app"],@"total":@1,@"completed":@0} writeToFile:[batchFailure stringByAppendingPathComponent:@"batch.plist"] atomically:YES],"new batch");[failure tick];
    axs_cachekeeper_test_check([axs_cachekeeper_test_read(batchFailure,@"batch.plist")[@"token"] isEqual:@"new-batch"] && [axs_cachekeeper_test_read(batchFailure,@"snapshots.plist")[@"large.app"][@"scanProgress"][@"state"] isEqual:@"superseded"],"batch token replacement retires old task");
    axs_cachekeeper_test_check(axs_cachekeeper_records_valid(axs_cachekeeper_test_read(folder,@"snapshots.plist"),@"snapshots.plist"),"real persisted records validate");
    // Deterministic review regressions: actual plist writes and real directories,
    // with only failure/time/scheduling boundaries injected.
    NSString *pendingFolder=[base stringByAppendingPathComponent:@"pending-cancel"];axs_cachekeeper_test_directory(pendingFolder);
    __block BOOL rejectProgress=YES;
    AxsCacheKeeperScanService *pendingService=[[AxsCacheKeeperScanService alloc] initWithFolder:pendingFolder resolver:resolver writer:^BOOL(NSDictionary *record,NSString *path){
        if(rejectProgress && [path.lastPathComponent isEqual:@"batch.plist"] && [record[@"completed"] unsignedIntegerValue]) return NO;
        return [record writeToFile:path atomically:YES];
    }];
    axs_cachekeeper_test_check([@{@"token":@"pending",@"remaining":@[@"small.app",@"large.app"],@"total":@2,@"completed":@0} writeToFile:[pendingFolder stringByAppendingPathComponent:@"batch.plist"] atomically:YES],"pending cancel setup");
    [pendingService tick];
    NSMutableDictionary *pendingStop=[axs_cachekeeper_test_read(pendingFolder,@"batch.plist") mutableCopy];pendingStop[@"cancel"]=@YES;
    axs_cachekeeper_test_check([pendingStop writeToFile:[pendingFolder stringByAppendingPathComponent:@"batch.plist"] atomically:YES],"pending cancel request");
    rejectProgress=NO;[pendingService tick];NSDictionary *stoppedBatch=axs_cachekeeper_test_read(pendingFolder,@"batch.plist");
    axs_cachekeeper_test_check([stoppedBatch[@"cancel"] boolValue] && [stoppedBatch[@"scanState"] isEqual:@"cancelled"] && [stoppedBatch[@"completed"] unsignedIntegerValue]==1,"pending progress preserves later cancel and acknowledged completion");
    NSDictionary *stoppedLarge=axs_cachekeeper_test_read(pendingFolder,@"snapshots.plist")[@"large.app"];
    axs_cachekeeper_test_check([stoppedLarge[@"scanProgress"][@"state"] isEqual:@"cancelled"] && [stoppedLarge[@"scanProgress"][@"entriesVisited"] unsignedIntegerValue]==0,"remaining member never advances after pending cancel");

    NSString *blockedFolder=[base stringByAppendingPathComponent:@"blocked-batch"];axs_cachekeeper_test_directory(blockedFolder);
    AxsCacheKeeperScanService *blocked=[[AxsCacheKeeperScanService alloc] initWithFolder:blockedFolder resolver:resolver writer:^BOOL(NSDictionary *record,NSString *path){
        if([path.lastPathComponent isEqual:@"batch.plist"]) return NO;
        return [record writeToFile:path atomically:YES];
    }];
    axs_cachekeeper_test_check([@{@"token":@"blocked",@"remaining":@[@"large.app"],@"total":@1,@"completed":@0} writeToFile:[blockedFolder stringByAppendingPathComponent:@"batch.plist"] atomically:YES],"blocked batch setup");
    [blocked tick];axs_cachekeeper_test_request(blockedFolder,@"independent",@"small.app",NO);[blocked tick];
    axs_cachekeeper_test_check([axs_cachekeeper_test_read(blockedFolder,@"scan.plist")[@"scanProgress"][@"state"] isEqual:@"complete"],"permanent batch save failure cannot starve single completion");
    axs_cachekeeper_test_request(blockedFolder,@"cancel-independent",@"other.large",NO);[blocked tick];
    axs_cachekeeper_test_request(blockedFolder,@"cancel-independent",@"other.large",YES);[blocked tick];
    axs_cachekeeper_test_check([axs_cachekeeper_test_read(blockedFolder,@"scan.plist")[@"scanProgress"][@"state"] isEqual:@"cancelled"],"permanent batch save failure cannot starve single cancellation");

    for(NSUInteger variant=0;variant<3;variant++) {
        NSString *overlap=[base stringByAppendingPathComponent:[NSString stringWithFormat:@"overlap-%lu",(unsigned long)variant]];axs_cachekeeper_test_directory(overlap);
        __block BOOL rejectRetire=variant==2;
        AxsCacheKeeperScanService *overlapService=[[AxsCacheKeeperScanService alloc] initWithFolder:overlap resolver:resolver writer:^BOOL(NSDictionary *record,NSString *path){
            if(rejectRetire && [path.lastPathComponent isEqual:@"snapshots.plist"] && [record[@"large.app"][@"scanProgress"][@"state"] isEqual:@"superseded"]) return NO;
            return [record writeToFile:path atomically:YES];
        }];
        NSDictionary *overlapBatch=@{@"token":@"overlap-batch",@"remaining":@[@"large.app"],@"total":@1,@"completed":@0};
        if(variant==2) {axs_cachekeeper_test_check([overlapBatch writeToFile:[overlap stringByAppendingPathComponent:@"batch.plist"] atomically:YES],"existing batch setup");[overlapService tick];}
        axs_cachekeeper_test_request(overlap,@"overlap-single",@"large.app",NO);
        if(variant==1) [overlapService tick];
        axs_cachekeeper_test_check([overlapBatch writeToFile:[overlap stringByAppendingPathComponent:@"batch.plist"] atomically:YES],"overlap request");[overlapService tick];
        axs_cachekeeper_test_check([axs_cachekeeper_test_read(overlap,@"batch.plist")[@"completed"] unsignedIntegerValue]==0,"overlap has no phantom batch completion");
        axs_cachekeeper_test_check([axs_cachekeeper_test_read(overlap,@"snapshots.plist")[@"large.app"][@"token"] isEqual:@"overlap-single"],"deferred batch never overwrites active single");
        rejectRetire=NO;
        for(NSUInteger i=0;i<30 && [axs_cachekeeper_test_read(overlap,@"batch.plist")[@"remaining"] count];i++) [overlapService tick];
        axs_cachekeeper_test_check([axs_cachekeeper_test_read(overlap,@"batch.plist")[@"completed"] unsignedIntegerValue]==1 &&
            [axs_cachekeeper_test_read(overlap,@"snapshots.plist")[@"large.app"][@"token"] isEqual:@"overlap-batch"] &&
            [axs_cachekeeper_test_read(overlap,@"snapshots.plist")[@"large.app"][@"scanProgress"][@"state"] isEqual:@"complete"],"deferred batch completion has matching durable terminal");
    }
    NSString *timed=[base stringByAppendingPathComponent:@"time-gate"];axs_cachekeeper_test_directory(timed);
    __block NSTimeInterval now=1000;
    AxsCacheKeeperScanService *timedService=[[AxsCacheKeeperScanService alloc] initWithFolder:timed resolver:resolver writer:nil];
    timedService.axs_cachekeeper_clock=^NSTimeInterval{return now;};
    axs_cachekeeper_test_request(timed,@"time",@"large.app",NO);[timedService tick];now=1301;[timedService tick];
    axs_cachekeeper_test_check([axs_cachekeeper_test_read(timed,@"scan.plist")[@"scanProgress"][@"state"] isEqual:@"timeLimit"] && ![axs_cachekeeper_test_read(timed,@"scan.plist")[@"complete"] boolValue],"service enforces 300-second gate using injected monotonic clock");

    for(NSUInteger mutation=0;mutation<3;mutation++) {
        NSString *changing=[base stringByAppendingPathComponent:[NSString stringWithFormat:@"discovery-%lu",(unsigned long)mutation]];
        NSString *library=[changing stringByAppendingPathComponent:@"Library"];axs_cachekeeper_test_directory([library stringByAppendingPathComponent:@"Caches"]);
        __block BOOL injected=NO;NSDictionary *changedDiagnostics=nil;
        NSArray *changedTargets=axs_cachekeeper_bounded_scan_targets_dependencies([NSURL fileURLWithPath:changing],@{},NO,&changedDiagnostics,^(NSString *stage,NSURL *root){
            (void)stage;if(injected || ![root.lastPathComponent isEqual:@"Library"]) return;injected=YES;
            if(mutation==0) {axs_cachekeeper_test_check([NSFileManager.defaultManager moveItemAtPath:library toPath:[library stringByAppendingString:@"-old"] error:nil],"replace Library during discovery");axs_cachekeeper_test_directory([library stringByAppendingPathComponent:@"Caches"]);}
            if(mutation<2) axs_cachekeeper_test_directory([library stringByAppendingPathComponent:@"Additional"]);
            else axs_cachekeeper_test_check([NSFileManager.defaultManager moveItemAtPath:[library stringByAppendingPathComponent:@"Caches"] toPath:[changing stringByAppendingPathComponent:@"removed"] error:nil],"remove discovered entry");
        });
        axs_cachekeeper_test_check(injected && changedTargets.count>0 && ![changedDiagnostics[@"discoveryComplete"] boolValue],"Library replacement or entry mutation invalidates discovery");
    }
    NSString *handoff=[base stringByAppendingPathComponent:@"handoff-home"];NSString *handoffLibrary=[handoff stringByAppendingPathComponent:@"Library"];
    axs_cachekeeper_test_directory([handoffLibrary stringByAppendingPathComponent:@"Caches"]);
    NSString *handoffFolder=[base stringByAppendingPathComponent:@"handoff-service"];axs_cachekeeper_test_directory(handoffFolder);
    AxsCacheKeeperScanService *handoffService=[[AxsCacheKeeperScanService alloc] initWithFolder:handoffFolder resolver:^NSDictionary *(NSString *bundle){(void)bundle;return @{@"home":[NSURL fileURLWithPath:handoff],@"groups":@{}};} writer:nil];
    handoffService.acceptedRequest=^(NSString *bundle,BOOL diagnostic){(void)bundle;(void)diagnostic;
        axs_cachekeeper_test_check([NSFileManager.defaultManager moveItemAtPath:handoffLibrary toPath:[handoffLibrary stringByAppendingString:@"-old"] error:nil],"replace Library after discovery");
        axs_cachekeeper_test_directory([handoffLibrary stringByAppendingPathComponent:@"Caches"]);axs_cachekeeper_test_directory([handoffLibrary stringByAppendingPathComponent:@"Additional"]);
    };
    axs_cachekeeper_test_request(handoffFolder,@"handoff",@"large.app",NO);[handoffService tick];
    axs_cachekeeper_test_check([axs_cachekeeper_test_read(handoffFolder,@"scan.plist")[@"scanProgress"][@"state"] isEqual:@"identityChanged"] && ![axs_cachekeeper_test_read(handoffFolder,@"scan.plist")[@"complete"] boolValue],"discovery identity is never resampled from replacement tree");
    puts("PASS: scan cursor continuation, identity, errors, limits, cancellation, restart, save failure and fair batch behavior");return 0;
} }
