#import <Foundation/Foundation.h>
#import "../AxsCacheKeeperDiagnostics.h"
#import "../AxsCacheKeeperDirectories.h"
#include <errno.h>
#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>

static void axs_cachekeeper_scan_test_check(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr,"FAIL: scan diagnostics: %s\n",message.UTF8String);exit(1); }
}

static void axs_cachekeeper_scan_test_write(NSString *folder, NSDictionary *scan) {
    NSError *error=nil;
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:@{@"test.scan.diagnostics":scan}
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    axs_cachekeeper_scan_test_check(data && [data writeToFile:[folder stringByAppendingPathComponent:@"snapshots.plist"]
        options:NSDataWritingAtomic error:&error], @"binary plist fixture must be writable");
}

static NSDictionary *axs_cachekeeper_scan_test_export(NSString *folder, id diagnostics) {
    NSMutableDictionary *row=[@{@"path":@"Library/Caches",@"bytes":@37,@"complete":@NO,@"manageable":@YES} mutableCopy];
    NSMutableDictionary *scan=[@{@"updated":[NSDate dateWithTimeIntervalSince1970:100],@"rows":@[row]} mutableCopy];
    if (diagnostics) { scan[@"scanDiagnostics"]=diagnostics;row[@"scanDiagnostics"]=diagnostics; }
    axs_cachekeeper_scan_test_write(folder,scan);
    AxsCacheKeeperDiagnostics *session=[[AxsCacheKeeperDiagnostics alloc] initWithFolder:folder];
    NSDictionary *report=[session reportWithApps:@[@{@"id":@"test.scan.diagnostics",@"version":@"1.0"}] environment:@{}];
    axs_cachekeeper_scan_test_check([report[@"apps"] count]==1, @"real report must contain fixture application");
    return report;
}

static NSDictionary *axs_cachekeeper_scan_test_data(NSDictionary *report) {
    return report[@"apps"][0][@"scan"][@"data"];
}

static NSDictionary *axs_cachekeeper_scan_test_valid(void) {
    // The scanner and exporter share this fixed contract. Errors can coexist with a budget stop.
    return @{@"containerState":@"available",@"discoveryComplete":@YES,@"measurementComplete":@NO,
        @"timeBudgetExceeded":@YES,@"entryLimitExceeded":@NO,@"entriesVisited":@3,
        @"enumerationErrors":@1,@"statErrors":@0,@"errorsTruncated":@NO,@"omittedErrorCount":@0,
        @"errors":@[@{@"scope":@"group",@"stage":@"enumerate",@"reason":@"readFailure",
            @"errorDomain":@"posix",@"errorCode":@(EIO),@"count":@1}]};
}

static void axs_cachekeeper_scan_test_invalid(NSString *folder, id invalid) {
    NSDictionary *report=axs_cachekeeper_scan_test_export(folder,invalid);
    NSDictionary *scan=axs_cachekeeper_scan_test_data(report);
    axs_cachekeeper_scan_test_check([scan[@"scanDiagnostics"] isEqual:@{@"state":@"invalid"}] &&
        [scan[@"rows"][0][@"scanDiagnostics"] isEqual:@{@"state":@"invalid"}],
        @"invalid diagnostics must be rejected at both export depths");
    NSData *data=[NSJSONSerialization dataWithJSONObject:report options:0 error:nil];
    NSString *json=data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    axs_cachekeeper_scan_test_check(data && ![json containsString:@"private-scan-sentinel"],
        @"rejected diagnostics must remain serializable and private");
}

static void axs_cachekeeper_scan_test_missing_home(NSString *folder) {
    NSFileManager *fm=NSFileManager.defaultManager;
    NSString *gone=[folder stringByAppendingPathComponent:@"removed-home"];
    axs_cachekeeper_scan_test_check([fm createDirectoryAtPath:gone withIntermediateDirectories:NO attributes:nil error:nil],
        @"controlled primary container must be created");
    axs_cachekeeper_scan_test_check([fm removeItemAtPath:gone error:nil], @"only controlled empty primary container is removed");
    NSError *error=nil;
    NSArray *targets=axs_cachekeeper_scan_targets([NSURL fileURLWithPath:gone],@{},&error);
    axs_cachekeeper_scan_test_check(targets.count==0 && [error.domain isEqual:NSPOSIXErrorDomain] && error.code==ENOENT,
        @"missing primary container must return ENOENT");
    NSString *empty=[folder stringByAppendingPathComponent:@"empty-home"];
    axs_cachekeeper_scan_test_check([fm createDirectoryAtPath:empty withIntermediateDirectories:NO attributes:nil error:nil],
        @"existing empty primary container must be created");
    error=nil;
    targets=axs_cachekeeper_scan_targets([NSURL fileURLWithPath:empty],@{},&error);
    axs_cachekeeper_scan_test_check(targets.count==0 && !error, @"optional Library absence must remain a valid empty result");
    puts("PASS: scan diagnostics missing-home behavior");
}

static void axs_cachekeeper_scan_test_export_boundary(NSString *folder) {
    NSDictionary *valid=axs_cachekeeper_scan_test_valid();
    NSDictionary *report=axs_cachekeeper_scan_test_export(folder,valid);
    NSDictionary *scan=axs_cachekeeper_scan_test_data(report);
    axs_cachekeeper_scan_test_check([scan[@"scanDiagnostics"] isEqual:valid],
        @"valid scanDiagnostics must survive real report export");
    axs_cachekeeper_scan_test_check([scan[@"rows"][0][@"scanDiagnostics"] isEqual:valid],
        @"row diagnostics must survive nested report export");
    axs_cachekeeper_scan_test_check([scan[@"rows"][0][@"bytes"] isEqual:@37] &&
        ![scan[@"rows"][0][@"complete"] boolValue], @"partial legacy row values must not become complete");

    for (NSArray *combination in @[@[@"noHome",@"containerResolve",@"noHome",@"none",@0],
        @[@"rootMissing",@"rootStat",@"rootMissing",@"posix",@(ENOENT)],
        @[@"unreadable",@"listChildren",@"permissionDenied",@"posix",@(EACCES)],
        @[@"unreadable",@"listChildren",@"permissionDenied",@"cocoa",@(NSFileReadNoPermissionError)]]) {
        NSMutableDictionary *sample=[valid mutableCopy];
        sample[@"containerState"]=combination[0];sample[@"discoveryComplete"]=@NO;
        sample[@"timeBudgetExceeded"]=@NO;sample[@"entriesVisited"]=@0;sample[@"enumerationErrors"]=@0;
        sample[@"errors"]=@[@{@"scope":@"home",@"stage":combination[1],@"reason":combination[2],
            @"errorDomain":combination[3],@"errorCode":combination[4],@"count":@1}];
        report=axs_cachekeeper_scan_test_export(folder,sample);
        axs_cachekeeper_scan_test_check([axs_cachekeeper_scan_test_data(report)[@"scanDiagnostics"] isEqual:sample],
            @"container absence and observed system errors must retain distinct evidence");
    }

    NSMutableDictionary *private=[valid mutableCopy];
    NSMutableDictionary *privateError=[valid[@"errors"][0] mutableCopy];
    for (NSString *key in @[@"path",@"home",@"message",@"detail",@"underlyingError",@"userInfo"])
        private[key]=privateError[key]=@"/private-scan-sentinel/account/token";
    private[@"errors"]=@[privateError];
    report=axs_cachekeeper_scan_test_export(folder,private);
    axs_cachekeeper_scan_test_check([axs_cachekeeper_scan_test_data(report)[@"scanDiagnostics"] isEqual:valid] &&
        [axs_cachekeeper_scan_test_data(report)[@"rows"][0][@"scanDiagnostics"] isEqual:valid],
        @"unknown fields and raw paths must be dropped at all diagnostic depths");
    NSData *encoded=[NSJSONSerialization dataWithJSONObject:report options:0 error:nil];
    NSString *json=encoded ? [[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding] : nil;
    axs_cachekeeper_scan_test_check(encoded && ![json containsString:@"private-scan-sentinel"], @"private error text must never enter JSON");

    for (id shape in @[@42,@[],@"private-scan-sentinel"])
        axs_cachekeeper_scan_test_invalid(folder,shape);
    for (NSString *key in valid) {
        NSMutableDictionary *partial=[valid mutableCopy];[partial removeObjectForKey:key];
        axs_cachekeeper_scan_test_invalid(folder,partial);
    }
    NSMutableDictionary *bad=[valid mutableCopy];bad[@"containerState"]=@"private-scan-sentinel";
    axs_cachekeeper_scan_test_invalid(folder,bad);
    for (NSString *key in @[@"discoveryComplete",@"measurementComplete",@"timeBudgetExceeded",@"entryLimitExceeded",@"errorsTruncated"]) {
        bad=[valid mutableCopy];bad[key]=@"true";axs_cachekeeper_scan_test_invalid(folder,bad);
        bad=[valid mutableCopy];bad[key]=@2;axs_cachekeeper_scan_test_invalid(folder,bad);
    }
    NSArray *invalidNumbers=@[@(-1),@(NAN),@(INFINITY),@0.5,@(INT64_MAX),@YES,@"private-scan-sentinel"];
    for (NSString *key in @[@"entriesVisited",@"enumerationErrors",@"statErrors",@"omittedErrorCount"])
        for (id value in invalidNumbers) {bad=[valid mutableCopy];bad[key]=value;axs_cachekeeper_scan_test_invalid(folder,bad);}
    for (NSString *key in @[@"scope",@"stage",@"reason",@"errorDomain"]) {
        NSMutableDictionary *failure=[valid[@"errors"][0] mutableCopy];failure[key]=@"private-scan-sentinel";
        bad=[valid mutableCopy];bad[@"errors"]=@[failure];axs_cachekeeper_scan_test_invalid(folder,bad);
    }
    for (NSString *key in @[@"errorCode",@"count"]) for (id value in invalidNumbers) {
        NSMutableDictionary *failure=[valid[@"errors"][0] mutableCopy];failure[key]=value;
        bad=[valid mutableCopy];bad[@"errors"]=@[failure];axs_cachekeeper_scan_test_invalid(folder,bad);
    }
    bad=[valid mutableCopy];bad[@"errors"]=@[@"private-scan-sentinel"];
    axs_cachekeeper_scan_test_invalid(folder,bad);
    // Collector owns truncation. The export boundary rejects oversized input rather than silently losing errors.
    NSMutableArray *oversized=[NSMutableArray new];
    for (NSUInteger index=0;index<17;index++) [oversized addObject:valid[@"errors"][0]];
    bad=[valid mutableCopy];bad[@"errors"]=oversized;axs_cachekeeper_scan_test_invalid(folder,bad);

    report=axs_cachekeeper_scan_test_export(folder,nil);scan=axs_cachekeeper_scan_test_data(report);
    axs_cachekeeper_scan_test_check(!scan[@"scanDiagnostics"] && !scan[@"rows"][0][@"scanDiagnostics"],
        @"old records without diagnostics must not invent a successful diagnosis");
    puts("PASS: scan diagnostics real export boundary");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        axs_cachekeeper_scan_test_check(argc==3, @"mode and unique fixture directory are required");
        NSString *mode=[NSString stringWithUTF8String:argv[1]];
        NSString *folder=[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]].URLByResolvingSymlinksInPath.path;
        NSFileManager *fm=NSFileManager.defaultManager;
        axs_cachekeeper_scan_test_check(![fm fileExistsAtPath:folder] &&
            [fm createDirectoryAtPath:folder withIntermediateDirectories:NO attributes:nil error:nil], @"fixture directory must be new");
        if ([mode isEqual:@"missing-home"]) axs_cachekeeper_scan_test_missing_home(folder);
        else if ([mode isEqual:@"export"]) axs_cachekeeper_scan_test_export_boundary(folder);
        else axs_cachekeeper_scan_test_check(NO,@"unsupported fixture mode");
    }
    return 0;
}
