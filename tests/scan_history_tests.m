#import <Foundation/Foundation.h>
#import "../AxsCacheKeeperScanTask.h"
#import "../AxsCacheKeeperRecords.h"
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

static void axs_cachekeeper_history_test_check(BOOL condition,const char *message) {
    if(!condition) {fprintf(stderr,"FAIL: scan history: %s\n",message);exit(1);}
}
static void axs_cachekeeper_history_test_directory(NSString *path) {
    axs_cachekeeper_history_test_check([NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil],"fixture directory");
}
static NSDictionary *axs_cachekeeper_history_test_read(NSString *folder,NSString *name) {
    return [NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:name]];
}
static void axs_cachekeeper_history_test_request(NSString *folder,NSString *token,NSString *bundle) {
    axs_cachekeeper_history_test_check([@{@"token":token,@"bundle":bundle} writeToFile:[folder stringByAppendingPathComponent:@"request.plist"] atomically:YES],"request fixture");
}
static void axs_cachekeeper_history_test_finish(AxsCacheKeeperScanService *service) {
    NSUInteger ticks=0;while([service tick] && ++ticks<300) {}
    axs_cachekeeper_history_test_check(ticks<300,"bounded completion");
}
int main(int argc,const char **argv) { @autoreleasepool {
    axs_cachekeeper_history_test_check(argc==2,"unique fixture path");NSString *base=[NSString stringWithUTF8String:argv[1]];
    NSString *folder=[base stringByAppendingPathComponent:@"history"],*home=[base stringByAppendingPathComponent:@"home"];
    axs_cachekeeper_history_test_directory(folder);axs_cachekeeper_history_test_directory(home);
    for(NSUInteger i=0;i<24;i++) axs_cachekeeper_history_test_directory([home stringByAppendingPathComponent:[NSString stringWithFormat:@"root%lu",(unsigned long)i]]);
    NSMutableDictionary *seed=[NSMutableDictionary new];NSDate *date=[NSDate dateWithTimeIntervalSince1970:1700000000];
    for(NSUInteger app=0;app<134;app++) {
        NSMutableArray *rows=[NSMutableArray new];
        for(NSUInteger root=0;root<24;root++) [rows addObject:@{@"path":[NSString stringWithFormat:@"Library/fixture%lu",(unsigned long)root],
            @"bytes":@(root+11),@"manageable":@NO,@"complete":@YES,@"scanDiagnostics":axs_cachekeeper_scan_diagnostics_new()}];
        NSMutableArray *recent=[NSMutableArray new];for(NSUInteger n=0;n<4;n++) [recent addObject:@{@"updated":date,@"rows":rows}];
        seed[[NSString stringWithFormat:@"fixture.app%lu",(unsigned long)app]]=@{@"rows":rows,@"previousRows":rows,@"recentScans":recent,@"updated":date,@"complete":@YES};
    }
    NSMutableDictionary *sentinel=[seed[@"fixture.app0"] mutableCopy];sentinel[@"error"]=@"history-external-A";seed[@"fixture.app0"]=sentinel;
    NSString *history=[folder stringByAppendingPathComponent:@"snapshots.plist"];
    axs_cachekeeper_history_test_check([seed writeToFile:history atomically:YES],"old XML history fixture");
    NSUInteger xmlSize=[[NSData dataWithContentsOfFile:history] length];axs_cachekeeper_history_test_check(xmlSize>8000000,"large realistic history");
    NSDictionary *(^resolver)(NSString *)=^NSDictionary *(NSString *bundle){(void)bundle;return @{@"home":[NSURL fileURLWithPath:home],@"groups":@{}};};
    AxsCacheKeeperScanService *service=[[AxsCacheKeeperScanService alloc] initWithFolder:folder resolver:resolver writer:nil];
    axs_cachekeeper_history_test_request(folder,@"first",@"active.app");axs_cachekeeper_history_test_finish(service);
    NSData *binary=[NSData dataWithContentsOfFile:history];NSPropertyListFormat format=0;
    NSDictionary *result=[NSPropertyListSerialization propertyListWithData:binary options:NSPropertyListImmutable format:&format error:nil];
    axs_cachekeeper_history_test_check(format==NSPropertyListBinaryFormat_v1_0,"history writes compact binary plist");
    axs_cachekeeper_history_test_check(binary.length<xmlSize/2,"history output avoids repeated XML expansion");
    for(NSString *key in seed) axs_cachekeeper_history_test_check([result[key] isEqual:seed[key]],"legacy history remains intact");
    axs_cachekeeper_history_test_check(axs_cachekeeper_records_valid(result,@"snapshots.plist"),"current validators read binary history");
    NSUInteger decoded=service.axs_cachekeeper_historyDecodeCount;
    axs_cachekeeper_history_test_check(decoded==1,"unchanged saved history decoded once");
    axs_cachekeeper_history_test_request(folder,@"second",@"active.app");axs_cachekeeper_history_test_finish(service);
    axs_cachekeeper_history_test_check(service.axs_cachekeeper_historyDecodeCount==decoded,"own successful writes reuse validated bytes");
    NSDictionary *performance=axs_cachekeeper_history_test_read(folder,@"scanPerformance.plist");
    axs_cachekeeper_history_test_check(axs_cachekeeper_scan_performance_projection(performance)!=nil && ![performance[@"active"] boolValue],"final service timings validate");
    axs_cachekeeper_history_test_check([performance[@"historyWrites"] unsignedIntegerValue]>0 && [performance[@"historyReads"] unsignedIntegerValue]>0 && [performance[@"historyDecodes"] unsignedIntegerValue]==0,"timings include final writes and own-write decode reuse");

    // Same inode, length and mtime are insufficient: compare the actual bytes.
    NSMutableData *externalBytes=[[NSData dataWithContentsOfFile:history] mutableCopy];
    NSData *oldText=[@"history-external-A" dataUsingEncoding:NSASCIIStringEncoding];
    NSData *newText=[@"history-external-B" dataUsingEncoding:NSASCIIStringEncoding];
    NSRange sentinelRange=[externalBytes rangeOfData:oldText options:0 range:NSMakeRange(0,externalBytes.length)];
    axs_cachekeeper_history_test_check(sentinelRange.location!=NSNotFound,"binary contains unique ASCII fixture");
    [externalBytes replaceBytesInRange:sentinelRange withBytes:newText.bytes length:newText.length];
    struct stat original;axs_cachekeeper_history_test_check(stat(history.fileSystemRepresentation,&original)==0,"history original metadata");
    axs_cachekeeper_history_test_check([externalBytes writeToFile:history options:0 error:nil],"external in-place mutation");
    struct timespec times[2]={original.st_atimespec,original.st_mtimespec};axs_cachekeeper_history_test_check(utimensat(AT_FDCWD,history.fileSystemRepresentation,times,0)==0,"restore mtime");
    struct stat replaced;axs_cachekeeper_history_test_check(stat(history.fileSystemRepresentation,&replaced)==0 &&
        replaced.st_ino==original.st_ino && replaced.st_size==original.st_size &&
        replaced.st_mtimespec.tv_sec==original.st_mtimespec.tv_sec && replaced.st_mtimespec.tv_nsec==original.st_mtimespec.tv_nsec,"same inode size and mtime fixture verified");
    axs_cachekeeper_history_test_request(folder,@"third",@"active.app");axs_cachekeeper_history_test_finish(service);
    axs_cachekeeper_history_test_check(service.axs_cachekeeper_historyDecodeCount==decoded+1,"changed bytes force decode despite metadata resemblance");
    axs_cachekeeper_history_test_check([axs_cachekeeper_history_test_read(folder,@"snapshots.plist")[@"fixture.app0"][@"error"] isEqual:@"history-external-B"],"external history edit survives next commit");

    NSMutableDictionary *added=[axs_cachekeeper_history_test_read(folder,@"snapshots.plist") mutableCopy];
    added[@"external.app"]=@{@"bytes":@73,@"complete":@YES};
    axs_cachekeeper_history_test_check([added writeToFile:history atomically:YES],"external record and XML replacement");
    axs_cachekeeper_history_test_request(folder,@"external-add",@"active.app");axs_cachekeeper_history_test_finish(service);
    axs_cachekeeper_history_test_check([axs_cachekeeper_history_test_read(folder,@"snapshots.plist")[@"external.app"] isEqual:added[@"external.app"]],"external newly added record survives merge");

    NSString *held=[folder stringByAppendingPathComponent:@"held.plist"];
    axs_cachekeeper_history_test_check([NSFileManager.defaultManager moveItemAtPath:history toPath:held error:nil],"hold history fixture");
    axs_cachekeeper_history_test_directory(history);
    axs_cachekeeper_history_test_request(folder,@"nonregular",@"active.app");[service tick];
    BOOL isDirectory=NO;[NSFileManager.defaultManager fileExistsAtPath:history isDirectory:&isDirectory];
    axs_cachekeeper_history_test_check(isDirectory && [axs_cachekeeper_history_test_read(folder,@"scan.plist")[@"scanProgress"][@"state"] isEqual:@"saveFailed"],"nonregular history is preserved with explicit failure");
    axs_cachekeeper_history_test_check([NSFileManager.defaultManager removeItemAtPath:history error:nil] && [NSFileManager.defaultManager moveItemAtPath:held toPath:history error:nil],"restore only controlled history fixture");

    NSData *corrupt=[@"not a property list" dataUsingEncoding:NSUTF8StringEncoding];
    axs_cachekeeper_history_test_check([corrupt writeToFile:history atomically:YES],"corrupt history fixture");
    axs_cachekeeper_history_test_request(folder,@"corrupt",@"active.app");[service tick];
    axs_cachekeeper_history_test_check([[NSData dataWithContentsOfFile:history] isEqual:corrupt],"corruption is never overwritten from cache");
    axs_cachekeeper_history_test_check([axs_cachekeeper_history_test_read(folder,@"scan.plist")[@"scanProgress"][@"state"] isEqual:@"saveFailed"],"corruption reports explicit save failure");

    NSString *cancelFolder=[base stringByAppendingPathComponent:@"cancel-during-advance"];axs_cachekeeper_history_test_directory(cancelFolder);
    NSString *small=[base stringByAppendingPathComponent:@"small"];axs_cachekeeper_history_test_directory([small stringByAppendingPathComponent:@"Library/Caches"]);
    __block NSUInteger resolves=0;
    AxsCacheKeeperScanService *cancelService=[[AxsCacheKeeperScanService alloc] initWithFolder:cancelFolder resolver:^NSDictionary *(NSString *bundle){
        (void)bundle;
        if(++resolves==2) {NSMutableDictionary *batch=[axs_cachekeeper_history_test_read(cancelFolder,@"batch.plist") mutableCopy];batch[@"cancel"]=@YES;
            axs_cachekeeper_history_test_check([batch writeToFile:[cancelFolder stringByAppendingPathComponent:@"batch.plist"] atomically:YES],"cancel during advance");}
        return @{@"home":[NSURL fileURLWithPath:small],@"groups":@{}};
    } writer:nil];
    axs_cachekeeper_history_test_check([@{@"token":@"cancel",@"remaining":@[@"cancel.app"],@"total":@1,@"completed":@0}
        writeToFile:[cancelFolder stringByAppendingPathComponent:@"batch.plist"] atomically:YES],"batch cancel fixture");
    [cancelService tick];NSDictionary *cancelled=axs_cachekeeper_history_test_read(cancelFolder,@"batch.plist");
    axs_cachekeeper_history_test_check([cancelled[@"completed"] unsignedIntegerValue]==0 && [cancelled[@"remaining"] count]==1,"mid-advance cancellation never counts as completion");
    axs_cachekeeper_history_test_check([axs_cachekeeper_history_test_read(cancelFolder,@"snapshots.plist")[@"cancel.app"][@"scanProgress"][@"state"] isEqual:@"cancelled"],"mid-advance cancellation persists terminal reason");
    axs_cachekeeper_history_test_check([cancelled[@"started"] isKindOfClass:NSDate.class] && [cancelled[@"finished"] isKindOfClass:NSDate.class],"batch dates record first running receipt and stop");

    NSString *failureFolder=[base stringByAppendingPathComponent:@"writer-failure"];axs_cachekeeper_history_test_directory(failureFolder);
    __block BOOL fail=NO;
    AxsCacheKeeperScanService *failureService=[[AxsCacheKeeperScanService alloc] initWithFolder:failureFolder resolver:resolver writer:^BOOL(NSDictionary *record,NSString *path){
        if(fail && [path.lastPathComponent isEqual:@"snapshots.plist"]) return NO;
        return [record writeToFile:path atomically:YES];
    }];
    axs_cachekeeper_history_test_request(failureFolder,@"seed",@"write.app");axs_cachekeeper_history_test_finish(failureService);
    NSData *persisted=[NSData dataWithContentsOfFile:[failureFolder stringByAppendingPathComponent:@"snapshots.plist"]];
    fail=YES;axs_cachekeeper_history_test_request(failureFolder,@"fail",@"write.app");[failureService tick];
    axs_cachekeeper_history_test_check([[NSData dataWithContentsOfFile:[failureFolder stringByAppendingPathComponent:@"snapshots.plist"]] isEqual:persisted],"failed custom write preserves durable bytes");
    axs_cachekeeper_history_test_check([axs_cachekeeper_history_test_read(failureFolder,@"scan.plist")[@"scanProgress"][@"state"] isEqual:@"saveFailed"],"failed writer returns explicit terminal state");
    fail=NO;axs_cachekeeper_history_test_finish(failureService);
    NSDictionary *failed=axs_cachekeeper_history_test_read(failureFolder,@"snapshots.plist")[@"write.app"];
    axs_cachekeeper_history_test_check([failed[@"scanProgress"][@"state"] isEqual:@"saveFailed"] && ![failed[@"complete"] boolValue],"successful retry does not promote failed scan to success");
    printf("PASS: binary history, exact-byte decode reuse, external mutation, corruption and mid-advance cancellation (XML=%lu binary=%lu)\n",(unsigned long)xmlSize,(unsigned long)binary.length);
    return 0;
} }
