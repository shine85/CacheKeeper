#import <Foundation/Foundation.h>
#import "../AxsCacheKeeperDiagnostics.h"
#import "../AxsCacheKeeperDirectories.h"
#import "../AxsCacheKeeperRecords.h"
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
    error=nil;
    NSArray *cacheRoots=axs_cachekeeper_discover_cache_roots([NSURL fileURLWithPath:gone],&error);
    axs_cachekeeper_scan_test_check(cacheRoots.count==0 && [error.domain isEqual:NSPOSIXErrorDomain] && error.code==ENOENT,
        @"cache discovery must also reject the missing primary container");
    NSString *empty=[folder stringByAppendingPathComponent:@"empty-home"];
    axs_cachekeeper_scan_test_check([fm createDirectoryAtPath:empty withIntermediateDirectories:NO attributes:nil error:nil],
        @"existing empty primary container must be created");
    error=nil;
    targets=axs_cachekeeper_scan_targets([NSURL fileURLWithPath:empty],@{},&error);
    axs_cachekeeper_scan_test_check(targets.count==0 && !error, @"optional Library absence must remain a valid empty result");
    cacheRoots=axs_cachekeeper_discover_cache_roots([NSURL fileURLWithPath:empty],&error);
    axs_cachekeeper_scan_test_check(cacheRoots.count==0 && !error, @"optional cache roots can all be absent inside a valid home");
    puts("PASS: scan diagnostics missing-home behavior");
}

static void axs_cachekeeper_scan_test_export_boundary(NSString *folder) {
    NSDictionary *valid=axs_cachekeeper_scan_test_valid();
    NSDictionary *report=axs_cachekeeper_scan_test_export(folder,valid);
    NSDictionary *scan=axs_cachekeeper_scan_test_data(report);
    axs_cachekeeper_scan_test_check([scan[@"scanDiagnostics"] isEqual:valid],
        @"valid scanDiagnostics must survive real report export");
    axs_cachekeeper_scan_test_check(axs_cachekeeper_record_valid(@{@"scanDiagnostics":valid},0) &&
        !axs_cachekeeper_record_valid(@{@"scanDiagnostics":@{@"containerState":@"available"}},0),
        @"persisted record validation must use the complete diagnostic schema");
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

static void axs_cachekeeper_scan_test_measurement(NSString *folder) {
    NSFileManager *fm=NSFileManager.defaultManager;
    NSString *root=[folder stringByAppendingPathComponent:@"content"];
    axs_cachekeeper_scan_test_check([fm createDirectoryAtPath:root withIntermediateDirectories:NO attributes:nil error:nil],@"create real measurement root");
    NSURL *url=[NSURL fileURLWithPath:root];
    NSDictionary *row=axs_cachekeeper_measure_directory(url,NSProcessInfo.processInfo.systemUptime+10,100000);
    axs_cachekeeper_scan_test_check([row[@"complete"] boolValue] && [row[@"bytes"] isEqual:@0] &&
        [row[@"scanDiagnostics"][@"entriesVisited"] isEqual:@0],@"empty real directory is fully measured");
    NSString *missing=[folder stringByAppendingPathComponent:@"missing"];
    row=axs_cachekeeper_measure_directory([NSURL fileURLWithPath:missing],NSProcessInfo.processInfo.systemUptime+10,100000);
    axs_cachekeeper_scan_test_check(![row[@"complete"] boolValue] &&
        [row[@"scanDiagnostics"][@"containerState"] isEqual:@"rootMissing"] &&
        [row[@"scanDiagnostics"][@"errors"][0][@"errorCode"] integerValue]==ENOENT,
        @"measurement of a missing root reports real ENOENT");
    NSString *outside=[folder stringByAppendingPathComponent:@"outside"];
    axs_cachekeeper_scan_test_check([@"outside-private-scan-sentinel" writeToFile:outside atomically:YES encoding:NSUTF8StringEncoding error:nil],@"create outside sentinel");
    row=axs_cachekeeper_measure_directory([NSURL fileURLWithPath:outside],NSProcessInfo.processInfo.systemUptime+10,100000);
    axs_cachekeeper_scan_test_check(![row[@"complete"] boolValue] && [row[@"bytes"] isEqual:@0],@"regular file root cannot appear as an empty complete directory");
    NSString *link=[folder stringByAppendingPathComponent:@"linked-root"];
    axs_cachekeeper_scan_test_check([fm createSymbolicLinkAtPath:link withDestinationPath:root error:nil],@"create terminal root link");
    row=axs_cachekeeper_measure_directory([NSURL fileURLWithPath:link],NSProcessInfo.processInfo.systemUptime+10,100000);
    axs_cachekeeper_scan_test_check(![row[@"complete"] boolValue] && [row[@"bytes"] isEqual:@0],@"terminal root symlink is rejected");

    axs_cachekeeper_scan_test_check([fm createDirectoryAtPath:[root stringByAppendingPathComponent:@"nested"] withIntermediateDirectories:NO attributes:nil error:nil] &&
        [@"abc" writeToFile:[root stringByAppendingPathComponent:@"a.bin"] atomically:YES encoding:NSUTF8StringEncoding error:nil] &&
        [@"12345" writeToFile:[root stringByAppendingPathComponent:@"nested/b.bin"] atomically:YES encoding:NSUTF8StringEncoding error:nil] &&
        [fm createSymbolicLinkAtPath:[root stringByAppendingPathComponent:@"outside-link"] withDestinationPath:outside error:nil],@"create real files and a non-followed child link");
    row=axs_cachekeeper_measure_directory(url,NSProcessInfo.processInfo.systemUptime+10,100000);
    axs_cachekeeper_scan_test_check([row[@"complete"] boolValue] && [row[@"bytes"] isEqual:@8] &&
        [row[@"scanDiagnostics"][@"entriesVisited"] isEqual:@4],@"measurement counts entries separately and excludes symlink target bytes");
    NSString *ancestor=[folder stringByAppendingPathComponent:@"parent-alias"];
    axs_cachekeeper_scan_test_check([fm createSymbolicLinkAtPath:ancestor withDestinationPath:folder error:nil],@"create ancestor alias");
    NSURL *aliased=[NSURL fileURLWithPath:[ancestor stringByAppendingPathComponent:@"content"]];
    row=axs_cachekeeper_measure_directory(aliased,NSProcessInfo.processInfo.systemUptime+10,100000);
    axs_cachekeeper_scan_test_check([row[@"complete"] boolValue] && [row[@"bytes"] isEqual:@8],@"same-inode ancestor alias remains readable");
    NSError *aliasError=nil;
    NSArray *aliasDirectories=axs_cachekeeper_scan_directories(aliased,&aliasError);
    axs_cachekeeper_scan_test_check(!aliasError && [aliasDirectories containsObject:@"nested"],@"directory discovery accepts an equivalent ancestor alias");
    axs_cachekeeper_discover_cache_roots(aliased,&aliasError);
    axs_cachekeeper_scan_test_check(!aliasError,@"cache discovery also accepts equivalent ancestor aliases");

    NSEnumerator<NSURL *> *(^enumerate)(NSURL *,BOOL (^)(NSURL *,NSError *))=
        ^NSEnumerator<NSURL *> *(NSURL *directory,BOOL (^handler)(NSURL *,NSError *)) {
            return [fm enumeratorAtURL:directory includingPropertiesForKeys:nil options:0 errorHandler:handler];
        };
    int (^realStat)(const char *,struct stat *)=^int(const char *path,struct stat *info) {return lstat(path,info);};
    row=axs_cachekeeper_measure_directory_dependencies(url,10,4,^NSTimeInterval {return 0;},realStat,enumerate);
    axs_cachekeeper_scan_test_check([row[@"complete"] boolValue] && [row[@"bytes"] isEqual:@8] &&
        [row[@"scanDiagnostics"][@"entriesVisited"] isEqual:@4] && ![row[@"scanDiagnostics"][@"entryLimitExceeded"] boolValue],
        @"an exact entry-limit match is complete after the enumerator reaches its end");
    row=axs_cachekeeper_measure_directory_dependencies(url,10,1,^NSTimeInterval {return 0;},realStat,enumerate);
    axs_cachekeeper_scan_test_check(![row[@"complete"] boolValue] &&
        [row[@"scanDiagnostics"][@"entryLimitExceeded"] boolValue] && [row[@"scanDiagnostics"][@"entriesVisited"] isEqual:@1] &&
        ![row[@"scanDiagnostics"][@"timeBudgetExceeded"] boolValue],@"entry cap measures only the visited prefix without claiming completeness");
    row=axs_cachekeeper_measure_directory_dependencies(url,10,100000,^NSTimeInterval {return 0;},
        ^int(const char *path,struct stat *info) {
            if ([[NSString stringWithUTF8String:path].lastPathComponent isEqual:@"a.bin"]) {errno=EACCES;return -1;}
            return lstat(path,info);
        },enumerate);
    NSDictionary *statFailure=row[@"scanDiagnostics"];
    axs_cachekeeper_scan_test_check(![row[@"complete"] boolValue] && [row[@"bytes"] isEqual:@5] &&
        [statFailure[@"statErrors"] isEqual:@1] && [statFailure[@"entriesVisited"] isEqual:@4] &&
        [statFailure[@"errors"][0][@"errorCode"] integerValue]==EACCES &&
        [statFailure[@"errors"][0][@"reason"] isEqual:@"permissionDenied"],@"stat failure preserves exact errno and other measured entries");
    __block NSTimeInterval now=0;__block BOOL stopped=NO;
    row=axs_cachekeeper_measure_directory_dependencies(url,10,100000,^NSTimeInterval {return now;},realStat,
        ^NSEnumerator<NSURL *> *(NSURL *directory,BOOL (^handler)(NSURL *,NSError *)) {
            NSError *failure=[NSError errorWithDomain:NSPOSIXErrorDomain code:EACCES userInfo:@{NSLocalizedDescriptionKey:@"private-scan-sentinel"}];
            axs_cachekeeper_scan_test_check(handler(directory,failure),@"enumeration error can continue while budget remains");
            now=11;stopped=!handler(directory,failure);
            return enumerate(directory,handler);
        });
    NSDictionary *timed=row[@"scanDiagnostics"];
    axs_cachekeeper_scan_test_check(stopped && ![row[@"complete"] boolValue] && [row[@"bytes"] isEqual:@0] &&
        [timed[@"timeBudgetExceeded"] boolValue] && [timed[@"enumerationErrors"] isEqual:@2] &&
        [timed[@"errors"][0][@"count"] isEqual:@2],@"enumeration error callback stops at deadline and retains both failures");
    NSDictionary *exported=axs_cachekeeper_scan_test_export(folder,timed);
    axs_cachekeeper_scan_test_check([axs_cachekeeper_scan_test_data(exported)[@"scanDiagnostics"] isEqual:timed],@"real collected errors survive the same export schema");
    row=axs_cachekeeper_measure_directory_dependencies(url,10,100000,^NSTimeInterval {return 0;},realStat,
        ^NSEnumerator<NSURL *> *(NSURL *directory,BOOL (^handler)(NSURL *,NSError *)) {(void)directory;(void)handler;return nil;});
    axs_cachekeeper_scan_test_check(![row[@"complete"] boolValue] && [row[@"scanDiagnostics"][@"enumerationErrors"] isEqual:@1] &&
        [row[@"scanDiagnostics"][@"errors"][0][@"reason"] isEqual:@"enumeratorUnavailable"] &&
        [row[@"scanDiagnostics"][@"errors"][0][@"errorDomain"] isEqual:@"none"],@"nil enumerator without NSError never invents an errno");

    NSString *swapRoot=[folder stringByAppendingPathComponent:@"replaced-root"];
    NSString *movedRoot=[folder stringByAppendingPathComponent:@"original-root"];
    axs_cachekeeper_scan_test_check([fm createDirectoryAtPath:swapRoot withIntermediateDirectories:NO attributes:nil error:nil] &&
        [@"abc" writeToFile:[swapRoot stringByAppendingPathComponent:@"payload"] atomically:YES encoding:NSUTF8StringEncoding error:nil],@"create root-replacement fixture");
    __block BOOL replaced=NO;
    row=axs_cachekeeper_measure_directory_dependencies([NSURL fileURLWithPath:swapRoot],10,100000,^NSTimeInterval {return 0;},
        ^int(const char *path,struct stat *info) {
            int result=lstat(path,info);
            if (!replaced && result==0) {
                axs_cachekeeper_scan_test_check([fm moveItemAtPath:swapRoot toPath:movedRoot error:nil] &&
                    [fm createDirectoryAtPath:swapRoot withIntermediateDirectories:NO attributes:nil error:nil],@"replace only the controlled fixture root");
                replaced=YES;
            }
            return result;
        },enumerate);
    BOOL identityChanged=NO;
    for (NSDictionary *failure in row[@"scanDiagnostics"][@"errors"])
        if ([failure[@"stage"] isEqual:@"rootRecheck"] && [failure[@"reason"] isEqual:@"identityChanged"]) identityChanged=YES;
    axs_cachekeeper_scan_test_check(replaced && identityChanged && ![row[@"complete"] boolValue],@"root replacement invalidates a seemingly finished traversal");

    NSString *group=[folder stringByAppendingPathComponent:@"Containers/Shared/AppGroup/11111111-1111-1111-1111-111111111111"];
    NSString *missingGroup=[folder stringByAppendingPathComponent:@"Containers/Shared/AppGroup/22222222-2222-2222-2222-222222222222"];
    axs_cachekeeper_scan_test_check([fm createDirectoryAtPath:[group stringByAppendingPathComponent:@"Library/Caches"] withIntermediateDirectories:YES attributes:nil error:nil],@"create controlled shared root");
    NSDictionary *groups=@{@"group.scan.good":[NSURL fileURLWithPath:group],@"group.scan.alias":[NSURL fileURLWithPath:group],
        @"group.scan.missing":[NSURL fileURLWithPath:missingGroup]};
    NSDictionary *discovery=nil;NSError *error=nil;
    NSArray *targets=axs_cachekeeper_scan_targets_diagnostics(nil,groups,NO,&error,&discovery);
    axs_cachekeeper_scan_test_check(targets.count==1 && [targets[0][@"scope"] isEqual:@"group"] && [targets[0][@"readOnly"] boolValue] &&
        [discovery[@"containerState"] isEqual:@"noHome"] && ![discovery[@"discoveryComplete"] boolValue] &&
        [discovery[@"errors"] count]==2,@"absent primary home preserves readable shared rows and distinct group errors without duplicates");
    BOOL homeError=NO,groupError=NO;
    for (NSDictionary *failure in discovery[@"errors"]) {
        if ([failure[@"scope"] isEqual:@"home"] && [failure[@"reason"] isEqual:@"noHome"] && [failure[@"errorDomain"] isEqual:@"none"]) homeError=YES;
        if ([failure[@"scope"] isEqual:@"group"] && [failure[@"reason"] isEqual:@"rootMissing"] && [failure[@"errorCode"] integerValue]==ENOENT) groupError=YES;
    }
    axs_cachekeeper_scan_test_check(homeError && groupError,@"primary absence cannot overwrite a shared-root syscall error");
    axs_cachekeeper_scan_targets_diagnostics(nil,@{},YES,&error,&discovery);
    axs_cachekeeper_scan_test_check([discovery[@"containerState"] isEqual:@"invalidHome"] &&
        [discovery[@"errors"][0][@"reason"] isEqual:@"invalidHome"],@"rejected metadata is distinct from a missing system home URL");
    axs_cachekeeper_scan_targets_diagnostics(url,groups,NO,&error,&discovery);
    NSMutableDictionary *aggregate=[discovery mutableCopy];
    axs_cachekeeper_scan_merge(aggregate,axs_cachekeeper_scan_scope(statFailure,@"group"));
    axs_cachekeeper_scan_merge(aggregate,axs_cachekeeper_scan_scope(timed,@"group"));
    axs_cachekeeper_scan_test_check([aggregate[@"containerState"] isEqual:@"available"] &&
        [aggregate[@"entriesVisited"] isEqual:@4] && [aggregate[@"statErrors"] isEqual:@2] &&
        [aggregate[@"enumerationErrors"] isEqual:@2] && [aggregate[@"timeBudgetExceeded"] boolValue] &&
        ![aggregate[@"measurementComplete"] boolValue] && axs_cachekeeper_scan_diagnostics_projection(aggregate),
        @"app aggregation retains primary identity and independently sums discovery and measurement errors");
    puts("PASS: scan diagnostics real measurement and discovery");
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
        else if ([mode isEqual:@"measurement"]) axs_cachekeeper_scan_test_measurement(folder);
        else axs_cachekeeper_scan_test_check(NO,@"unsupported fixture mode");
    }
    return 0;
}
