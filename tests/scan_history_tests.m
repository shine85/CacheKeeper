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

    // Swiftgram history must bind each closed diagnostic to the round that produced it.
    NSString *swiftHome=[base stringByAppendingPathComponent:@"swiftgram-home"];
    NSString *swiftFolder=[base stringByAppendingPathComponent:@"swiftgram-status"];
    axs_cachekeeper_history_test_directory(swiftFolder);
    __block NSUInteger swiftRound=0;
    AxsCacheKeeperScanService *swiftService=[[AxsCacheKeeperScanService alloc] initWithFolder:swiftFolder resolver:^NSDictionary *(NSString *bundle){
        axs_cachekeeper_history_test_check([bundle isEqual:@"app.swiftgram.ios"],"Swiftgram history uses its exact bundle identity");
        NSString *resolved=[swiftHome stringByAppendingPathComponent:[NSString stringWithFormat:@"round-%lu",(unsigned long)swiftRound]];
        if (swiftRound!=4) axs_cachekeeper_history_test_directory([resolved stringByAppendingPathComponent:@"Library/Caches"]);
        else resolved=[resolved stringByAppendingPathComponent:@"missing"];
        return @{ @"home":[NSURL fileURLWithPath:resolved], @"groups":@{} };
    } writer:nil];
    for(NSUInteger round=0;round<6;round++) {
        swiftRound=round;
        axs_cachekeeper_history_test_request(swiftFolder,[NSString stringWithFormat:@"swift-%lu",(unsigned long)round],@"app.swiftgram.ios");
        axs_cachekeeper_history_test_finish(swiftService);
    }
    NSDictionary *swift=[axs_cachekeeper_history_test_read(swiftFolder,@"snapshots.plist") objectForKey:@"app.swiftgram.ios"];
    NSArray *swiftRecent=swift[@"recentScans"];
    NSDictionary *failedRound=swiftRecent[2],*latestRound=swiftRecent.lastObject;
    axs_cachekeeper_history_test_check(swiftRecent.count==4,"Swiftgram history is capped to the latest four scans");
    NSMutableArray *roundHomes=[NSMutableArray new];for(NSDictionary *entry in swiftRecent) [roundHomes addObject:entry[@"home"] ?: @""];
    axs_cachekeeper_history_test_check([roundHomes isEqual:@[[swiftHome stringByAppendingPathComponent:@"round-2"],
        [swiftHome stringByAppendingPathComponent:@"round-3"],[swiftHome stringByAppendingPathComponent:@"round-4/missing"],
        [swiftHome stringByAppendingPathComponent:@"round-5"]]],
        "Swiftgram history keeps each of the latest four unique rounds exactly once");
    axs_cachekeeper_history_test_check([failedRound[@"scanDiagnosticsState"] isEqual:@"available"] &&
        [failedRound[@"scanDiagnostics"][ @"containerState"] isEqual:@"rootMissing"] &&
        ![failedRound[@"scanDiagnostics"][ @"measurementComplete"] boolValue] &&
        [failedRound[@"scanDiagnostics"][ @"errors"][0][ @"stage"] isEqual:@"rootStat"] &&
        [failedRound[@"scanDiagnostics"][ @"errors"][0][ @"errorDomain"] isEqual:@"posix"] &&
        [failedRound[@"scanDiagnostics"][ @"errors"][0][ @"errorCode"] intValue]==ENOENT &&
        [failedRound[@"scanDiagnostics"][ @"errors"][0][ @"count"] unsignedIntValue]==1 &&
        [failedRound[@"scanDiagnostics"][ @"statErrors"] unsignedIntValue]==1 &&
        ![failedRound[@"scanDiagnostics"][ @"errorsTruncated"] boolValue] &&
        [failedRound[@"scanDiagnostics"][ @"omittedErrorCount"] unsignedIntValue]==0,
        "Swiftgram keeps the third retained round's root failure stage, domain, code and count");
    axs_cachekeeper_history_test_check([latestRound[@"scanDiagnosticsState"] isEqual:@"available"] &&
        [latestRound[@"scanDiagnostics"][ @"measurementComplete"] boolValue] &&
        ![latestRound[@"scanDiagnostics"][ @"enumerationErrors"] unsignedIntegerValue],
        "Swiftgram successful round does not inherit an older failure");

    // Persist a capped diagnostic, then publish a real successful round
    // through ScanService and inspect the rewritten plist.
    NSString *truncatedFolder=[base stringByAppendingPathComponent:@"swiftgram-truncated-status"];
    NSString *truncatedHome=[base stringByAppendingPathComponent:@"swiftgram-truncated-home"];
    axs_cachekeeper_history_test_directory(truncatedFolder);
    axs_cachekeeper_history_test_directory([truncatedHome stringByAppendingPathComponent:@"Library/Caches"]);
    NSMutableDictionary *truncatedDiagnostics=[axs_cachekeeper_scan_diagnostics_new() mutableCopy];
    truncatedDiagnostics[@"measurementComplete"]=@NO;
    truncatedDiagnostics[@"enumerationErrors"]=@17;
    for(NSInteger code=1;code<=17;code++)
        axs_cachekeeper_scan_error(truncatedDiagnostics,@"home",@"enumerate",@"readFailure",@"posix",code,1);
    NSDictionary *truncatedSeed=@{@"app.swiftgram.ios":@{@"updated":date,@"rows":@[],@"complete":@NO,
        @"error":@"swiftgram-truncated-history-error-canary",@"scanDiagnostics":truncatedDiagnostics}};
    axs_cachekeeper_history_test_check(axs_cachekeeper_records_valid(truncatedSeed,@"snapshots.plist") &&
        [truncatedSeed writeToFile:[truncatedFolder stringByAppendingPathComponent:@"snapshots.plist"] atomically:YES],
        "truncated Swiftgram diagnostic fixture is valid and persisted");
    AxsCacheKeeperScanService *truncatedService=[[AxsCacheKeeperScanService alloc] initWithFolder:truncatedFolder
        resolver:^NSDictionary *(NSString *bundle){
            axs_cachekeeper_history_test_check([bundle isEqual:@"app.swiftgram.ios"],"truncated history service uses Swiftgram identity");
            return @{ @"home":[NSURL fileURLWithPath:truncatedHome], @"groups":@{} };
        } writer:nil];
    axs_cachekeeper_history_test_request(truncatedFolder,@"swift-after-truncation",@"app.swiftgram.ios");
    axs_cachekeeper_history_test_finish(truncatedService);
    NSDictionary *truncatedSaved=axs_cachekeeper_history_test_read(truncatedFolder,@"snapshots.plist")[@"app.swiftgram.ios"];
    NSArray *truncatedRecent=truncatedSaved[@"recentScans"];
    NSDictionary *truncatedPrior=truncatedRecent.firstObject,*truncatedLatest=truncatedRecent.lastObject;
    axs_cachekeeper_history_test_check(truncatedRecent.count==2 &&
        [truncatedPrior[@"scanDiagnosticsState"] isEqual:@"available"] &&
        [truncatedPrior[@"scanDiagnostics"][ @"errorsTruncated"] boolValue] &&
        [truncatedPrior[@"scanDiagnostics"][ @"omittedErrorCount"] unsignedIntegerValue]==1 &&
        [truncatedPrior[@"scanDiagnostics"][ @"errors"] count]==AxsCacheKeeperScanErrorLimit &&
        [truncatedPrior[@"scanDiagnostics"][ @"enumerationErrors"] unsignedIntegerValue]==17 &&
        [truncatedLatest[@"scanDiagnosticsState"] isEqual:@"available"] &&
        [truncatedLatest[@"scanDiagnostics"][ @"measurementComplete"] boolValue] &&
        ![truncatedLatest[@"scanDiagnostics"][ @"errorsTruncated"] boolValue] &&
        [truncatedLatest[@"scanDiagnostics"][ @"omittedErrorCount"] unsignedIntegerValue]==0,
        "Swiftgram service publication retains truncated diagnostics and omitted-error count across rounds");

    NSDictionary *legacyEntry=@{@"updated":date,@"home":@"/private/swiftgram-home-canary",@"rows":@[],@"error":@"swiftgram-error-canary"};
    NSDictionary *legacyHistory=@{@"app.swiftgram.ios":@{@"recentScans":@[legacyEntry]}};
    NSArray *legacyProjected=axs_cachekeeper_recent_scans(legacyHistory[@"app.swiftgram.ios"]);
    axs_cachekeeper_history_test_check([legacyProjected[0][@"scanDiagnosticsState"] isEqual:@"unknown"] &&
        !legacyProjected[0][@"scanDiagnostics"] && !legacyProjected[0][@"error"] &&
        [legacyProjected[0][@"home"] isEqual:legacyEntry[@"home"]] && [legacyProjected[0][@"rows"] isEqual:legacyEntry[@"rows"]],
        "legacy Swiftgram history retains scan data and drops unprojected error text");
    NSMutableDictionary *legacyTopLevel=[legacyHistory[@"app.swiftgram.ios"] mutableCopy];
    legacyTopLevel[@"updated"]=[NSDate dateWithTimeIntervalSince1970:1700000001];legacyTopLevel[@"rows"]=@[];
    NSArray *migratedLegacy=axs_cachekeeper_recent_scans(legacyTopLevel);
    axs_cachekeeper_history_test_check(migratedLegacy.count==2 &&
        [migratedLegacy[1][@"scanDiagnosticsState"] isEqual:@"unknown"] && !migratedLegacy[1][@"scanDiagnostics"],
        "legacy top-level snapshot is appended once as unknown during history migration");
    NSMutableDictionary *saturatedDiagnostics=[axs_cachekeeper_scan_diagnostics_new() mutableCopy];
    saturatedDiagnostics[@"measurementComplete"]=@NO;
    saturatedDiagnostics[@"enumerationErrors"]=@(UINT32_MAX);
    saturatedDiagnostics[@"errors"]=[@[@{@"scope":@"home",@"stage":@"enumerate",@"reason":@"readFailure",
        @"errorDomain":@"posix",@"errorCode":@(EIO),@"count":@(UINT32_MAX)}] mutableCopy];
    axs_cachekeeper_scan_error(saturatedDiagnostics,@"home",@"enumerate",@"readFailure",@"posix",EIO,1);
    NSDictionary *saturatedError=saturatedDiagnostics[@"errors"][0];
    axs_cachekeeper_history_test_check([saturatedError[@"count"] unsignedLongLongValue]==UINT32_MAX &&
        [saturatedDiagnostics[@"errorsTruncated"] boolValue] &&
        [saturatedDiagnostics[@"omittedErrorCount"] unsignedLongLongValue]==1 &&
        ![saturatedDiagnostics[@"measurementComplete"] boolValue] &&
        axs_cachekeeper_scan_diagnostics_projection(saturatedDiagnostics),
        "saturated repeated Swiftgram error count marks omitted lower bound and incomplete measurement");
    NSMutableDictionary *saturatedAggregate=[axs_cachekeeper_scan_diagnostics_new() mutableCopy];
    saturatedAggregate[@"entriesVisited"]=@(UINT32_MAX);
    axs_cachekeeper_scan_count(saturatedAggregate,@"entriesVisited",1);
    axs_cachekeeper_history_test_check([saturatedAggregate[@"entriesVisited"] unsignedLongLongValue]==UINT32_MAX &&
        [saturatedAggregate[@"errorsTruncated"] boolValue] &&
        ![saturatedAggregate[@"measurementComplete"] boolValue] &&
        axs_cachekeeper_scan_diagnostics_projection(saturatedAggregate),
        "saturated Swiftgram aggregate count remains explicitly incomplete");
    axs_cachekeeper_scan_count(saturatedAggregate,@"entriesVisited",UINT64_MAX);
    axs_cachekeeper_history_test_check([saturatedAggregate[@"entriesVisited"] unsignedLongLongValue]==UINT32_MAX &&
        axs_cachekeeper_scan_diagnostics_projection(saturatedAggregate),
        "large Swiftgram aggregate increment saturates without unsigned addition wrapping");
    axs_cachekeeper_scan_error(saturatedDiagnostics,@"home",@"enumerate",@"readFailure",@"posix",EIO,UINT64_MAX);
    axs_cachekeeper_history_test_check([saturatedDiagnostics[@"errors"][0][@"count"] unsignedLongLongValue]==UINT32_MAX &&
        [saturatedDiagnostics[@"omittedErrorCount"] unsignedLongLongValue]==UINT32_MAX &&
        axs_cachekeeper_scan_diagnostics_projection(saturatedDiagnostics),
        "large repeated Swiftgram error increment preserves saturated retained and omitted counts");
    NSMutableDictionary *largeInitialError=axs_cachekeeper_scan_diagnostics_new();
    axs_cachekeeper_scan_error(largeInitialError,@"home",@"enumerate",@"readFailure",@"posix",EIO,UINT64_MAX);
    axs_cachekeeper_history_test_check([largeInitialError[@"errors"][0][@"count"] unsignedLongLongValue]==UINT32_MAX &&
        [largeInitialError[@"omittedErrorCount"] unsignedLongLongValue]==UINT32_MAX &&
        [largeInitialError[@"errorsTruncated"] boolValue] && ![largeInitialError[@"measurementComplete"] boolValue] &&
        axs_cachekeeper_scan_diagnostics_projection(largeInitialError),
        "large first Swiftgram error retains a valid clipped count with explicit incomplete measurement");
    NSMutableDictionary *closedFailure=[axs_cachekeeper_scan_diagnostics_new() mutableCopy];
    closedFailure[@"containerState"]=@"unreadable";
    closedFailure[@"discoveryComplete"]=@NO;
    closedFailure[@"measurementComplete"]=@NO;
    closedFailure[@"statErrors"]=@1;
    axs_cachekeeper_scan_error(closedFailure,@"home",@"rootStat",@"rootMissing",@"posix",ENOENT,1);
    NSDictionary *sameTimeRound=@{@"updated":date,@"rows":@[],@"home":@"/private/swiftgram-home-canary",
        @"scanDiagnosticsState":@"available",@"scanDiagnostics":closedFailure};
    NSMutableArray *sameTimeRows=[@[@{@"path":@"Library/Caches/new-round"}] mutableCopy];
    NSArray *sameTimeRounds=axs_cachekeeper_recent_scans(@{@"recentScans":@[sameTimeRound],
        @"updated":date,@"rows":sameTimeRows,@"home":sameTimeRound[@"home"],
        @"scanDiagnosticsState":@"available",@"scanDiagnostics":closedFailure});
    axs_cachekeeper_history_test_check(sameTimeRounds.count==2 &&
        [sameTimeRounds[0][@"updated"] isEqual:sameTimeRounds[1][@"updated"]] &&
        ![sameTimeRounds[0][@"rows"] isEqual:sameTimeRounds[1][@"rows"]],
        "different Swiftgram snapshots in the same timestamp remain distinct rounds");
    NSArray *sameClosedRounds=axs_cachekeeper_recent_scans(@{@"recentScans":@[sameTimeRound],
        @"updated":date,@"rows":sameTimeRound[@"rows"],@"home":sameTimeRound[@"home"],
        @"scanDiagnosticsState":@"available",@"scanDiagnostics":sameTimeRound[@"scanDiagnostics"]});
    axs_cachekeeper_history_test_check(sameClosedRounds.count==1,
        "an identical closed Swiftgram snapshot is not duplicated during normalization");

    NSMutableDictionary *sameTimestampDiagnostics=[closedFailure mutableCopy];
    NSMutableDictionary *changedTimestampDiagnostics=[sameTimestampDiagnostics mutableCopy];
    changedTimestampDiagnostics[@"statErrors"]=@2;
    NSMutableDictionary *changedError=[sameTimestampDiagnostics[@"errors"][0] mutableCopy];
    changedError[@"count"]=@2;
    changedTimestampDiagnostics[@"errors"]=@[changedError];
    NSArray *sameTimeDiagnosticRounds=axs_cachekeeper_recent_scans(@{@"recentScans":@[sameTimeRound],
        @"updated":date,@"rows":sameTimeRound[@"rows"],@"home":sameTimeRound[@"home"],
        @"scanDiagnosticsState":@"available",@"scanDiagnostics":changedTimestampDiagnostics});
    axs_cachekeeper_history_test_check(sameTimeDiagnosticRounds.count==2 &&
        ![sameTimeDiagnosticRounds[0][@"scanDiagnostics"] isEqual:sameTimeDiagnosticRounds[1][@"scanDiagnostics"]],
        "different Swiftgram diagnostic projections in the same timestamp remain distinct rounds");
    NSDictionary *legacyCurrent=@{@"updated":date,@"rows":@[],@"home":@"/private/swiftgram-home-canary"};
    NSArray *legacyDuplicate=axs_cachekeeper_recent_scans(@{@"recentScans":@[legacyCurrent],
        @"updated":legacyCurrent[@"updated"],@"rows":legacyCurrent[@"rows"],@"home":legacyCurrent[@"home"]});
    axs_cachekeeper_history_test_check(legacyDuplicate.count==1 &&
        [legacyDuplicate[0][@"scanDiagnosticsState"] isEqual:@"unknown"],
        "equivalent legacy current and recent projections normalize to one unknown round");

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
