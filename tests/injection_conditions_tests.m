#import <Foundation/Foundation.h>
#import "../AxsCacheKeeperInjectionConditions.h"
#import "../AxsCacheKeeperDiagnostics.h"
#import "../AxsCacheKeeperHostEvidence.h"
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>

static void CKRequire(BOOL condition,const char *message) {
    if (!condition) {fprintf(stderr,"FAIL: injection conditions: %s\n",message);exit(1);}
}
static NSDictionary *CKProject(NSDictionary *settings, id global) {
    NSMutableDictionary *plist=[@{@"appSettings":@{@"test.injection.app":settings}} mutableCopy];
    if (global) plist[@"globalDeniedTweaks"]=global;
    return axs_cachekeeper_injection_conditions_projection(@{@"state":@"available",@"data":plist},@"test.injection.app");
}
static void CKDecision(NSDictionary *settings,id global,NSString *expected,const char *message) {
    CKRequire([CKProject(settings,global)[@"savedDecision"] isEqual:expected],message);
}
static void CKProjection(void) {
    CKDecision(@{@"customTweakConfigurationEnabled":@YES,@"allowedTweaks":@[]},nil,@"notAllowlisted","valid empty allow list must deny CacheKeeper");
    CKDecision(@{@"customTweakConfigurationEnabled":@YES},nil,@"notRestricted","missing allow list must not mean empty allow list");
    CKDecision(@{@"customTweakConfigurationEnabled":@YES,@"allowedTweaks":@"private-secret"},nil,@"unknown","non-array allow list must remain unknown");
    CKDecision(@{@"customTweakConfigurationEnabled":@YES,@"allowedTweaks":@[@"OtherTweak"]},nil,@"notAllowlisted","Swiftgram saved allow list excludes CacheKeeper");
    CKDecision(@{@"customTweakConfigurationEnabled":@NO,@"allowedTweaks":@[]},nil,@"notRestricted","inactive custom list does not block Baidu");
    CKDecision(@{@"customTweakConfigurationEnabled":@YES,@"allowedTweaks":@[@"CacheKeeper"]},nil,@"notRestricted","dylib basename matches allow list");
    for (NSString *wrong in @[@"CacheKeeper.dylib",@"dev.local.cachekeeper",@"cachekeeper"])
        CKDecision(@{@"customTweakConfigurationEnabled":@YES,@"allowedTweaks":@[wrong]},nil,@"notAllowlisted","matching is exact basename and case");
    CKDecision(@{@"customTweakConfigurationEnabled":@YES,@"allowDenyMode":@2,@"deniedTweaks":@[@"CacheKeeper"]},nil,@"denylisted","mode two is deny list");
    CKDecision(@{@"customTweakConfigurationEnabled":@YES,@"allowDenyMode":@2,@"deniedTweaks":@[]},nil,@"notRestricted","empty deny list does not block");
    for (id bad in @[@YES,@1.0,@3,@"1",NSNull.null])
        CKDecision(@{@"allowDenyMode":bad},nil,@"unknown","mode accepts only integer one or two, never bool or float");
    for (NSString *key in @[@"customTweakConfigurationEnabled",@"tweakInjectionDisabled",@"overwriteGlobalTweakConfiguration"])
        for (id bad in @[@1,@0,@"true",NSNull.null]) CKDecision(@{key:bad},nil,@"unknown","boolean keys reject integer and string coercion");
    CKDecision(@{},@[@"CacheKeeper"],@"globallyDenied","global deny applies with no custom configuration");
    CKDecision(@{@"customTweakConfigurationEnabled":@NO,@"overwriteGlobalTweakConfiguration":@YES},@[@"CacheKeeper"],@"notRestricted","global overwrite works even when custom configuration is off");
    CKDecision(@{@"customTweakConfigurationEnabled":@YES,@"allowedTweaks":@[@"CacheKeeper"]},@[@"CacheKeeper"],@"globallyDenied","global deny precedes allow list");
    CKDecision(@{@"tweakInjectionDisabled":@YES},nil,@"injectionDisabled","saved injection disabled is reported separately");
    CKDecision(@{},@"private-secret",@"unknown","invalid active global list is unknown");
    CKDecision(@{@"overwriteGlobalTweakConfiguration":@YES},@"private-secret",@"notRestricted","overwritten global list is not applied");
    CKDecision(@{@"customTweakConfigurationEnabled":@YES,@"allowedTweaks":@[@1]},nil,@"unknown","invalid selected list member is unknown");
    for (id invalid in @[@[],@"private-secret",NSNull.null]) {
        NSDictionary *result=axs_cachekeeper_injection_conditions_projection(@{@"state":@"available",@"data":invalid},@"test.injection.app");
        CKRequire([result[@"savedDecision"] isEqual:@"unknown"],"invalid top-level plist is unknown");
        result=axs_cachekeeper_injection_conditions_projection(@{@"state":@"available",@"data":@{@"appSettings":invalid}},@"test.injection.app");
        CKRequire([result[@"savedDecision"] isEqual:@"unknown"],"invalid app settings is unknown");
        result=axs_cachekeeper_injection_conditions_projection(@{@"state":@"available",@"data":@{@"appSettings":@{@"test.injection.app":invalid}}},@"test.injection.app");
        CKRequire([result[@"savedDecision"] isEqual:@"unknown"],"invalid app record is unknown");
    }
    for (NSString *state in @[@"unreadable",@"invalid"]) {
        NSDictionary *result=axs_cachekeeper_injection_conditions_projection(@{@"state":state,@"errorCode":@13,@"error":@"private-secret",@"path":@"/private/path"},@"test.injection.app");
        CKRequire([result[@"savedDecision"] isEqual:@"unknown"] && [result[@"readErrorCode"] intValue]==13 && !result[@"path"] && !result[@"error"],"source errors preserve numeric code only");
    }
    for (id badCode in @[@YES,@1.5,@"private-secret"]) {
        NSDictionary *result=axs_cachekeeper_injection_conditions_projection(@{@"state":@"unreadable",@"errorCode":badCode},@"test.injection.app");
        CKRequire(!result[@"readErrorCode"],"invalid error code never exported");
    }
    NSDictionary *private=CKProject(@{@"customTweakConfigurationEnabled":@YES,@"allowedTweaks":@[@"private-secret",@"/private/user/path"]},@[@"another-private-plugin"]);
    NSData *json=[NSJSONSerialization dataWithJSONObject:private options:0 error:NULL];
    NSString *text=[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    CKRequire(json && ![text containsString:@"private"] && ![text containsString:@"another-private-plugin"] && !private[@"data"],"JSON contains only fixed fields, never plugin names or paths");
    CKRequire([axs_cachekeeper_injection_conditions_summary(private) containsString:@"保存"] && [axs_cachekeeper_injection_conditions_summary(private) containsString:@"不能"],"summary cannot claim saved settings prove live blocking");
    puts("PASS: injection projection types, list semantics, global precedence and privacy");
}
static void CKFiles(NSString *folder) {
    NSFileManager *fm=NSFileManager.defaultManager;
    CKRequire([fm createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL],"fixture directory");
    NSString *path=[folder stringByAppendingPathComponent:@"choicy.plist"];
    NSDictionary *read=axs_cachekeeper_injection_conditions_read(path);
    CKRequire([read[@"state"] isEqual:@"missing"] && [read[@"errorCode"] intValue]==ENOENT,"missing file is distinct from unreadable");
    CKRequire([axs_cachekeeper_injection_conditions_projection(read,@"test.injection.app")[@"savedDecision"] isEqual:@"noConfiguration"],"missing file means no saved configuration");
    NSDictionary *plist=@{@"appSettings":@{@"test.injection.app":@{@"customTweakConfigurationEnabled":@YES,@"allowedTweaks":@[]}}};
    CKRequire([plist writeToFile:path atomically:YES],"write actual plist fixture");
    NSData *before=[NSData dataWithContentsOfFile:path];
    read=axs_cachekeeper_injection_conditions_read(path);
    CKRequire([read[@"state"] isEqual:@"available"] && [read[@"data"] isEqual:plist],"real Foundation plist decoding");
    CKRequire([[NSData dataWithContentsOfFile:path] isEqual:before],"readonly reader preserves original bytes");
    CKRequire([@"not a plist" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL],"corrupt fixture");
    read=axs_cachekeeper_injection_conditions_read(path);
    CKRequire([read[@"state"] isEqual:@"invalid"] && [axs_cachekeeper_injection_conditions_projection(read,@"test.injection.app")[@"savedDecision"] isEqual:@"unknown"],"corrupt source is unknown");
    CKRequire([[axs_cachekeeper_injection_conditions_read(folder) objectForKey:@"state"] isEqual:@"unreadable"],"directory is rejected");
    NSString *link=[folder stringByAppendingPathComponent:@"link.plist"];
    CKRequire(symlink(path.fileSystemRepresentation,link.fileSystemRepresentation)==0,"symlink fixture");
    CKRequire([[axs_cachekeeper_injection_conditions_read(link) objectForKey:@"state"] isEqual:@"unreadable"],"symlink source is rejected");
    if (geteuid()!=0) {
        CKRequire(chmod(path.fileSystemRepresentation,0000)==0,"permission fixture");
        read=axs_cachekeeper_injection_conditions_read(path);
        CKRequire([read[@"state"] isEqual:@"unreadable"] && [read[@"errorCode"] intValue]==EACCES,"actual permission failure code");
        CKRequire(chmod(path.fileSystemRepresentation,0600)==0,"restore fixture permission");
    } else puts("SKIP: EACCES fixture cannot be asserted while running as root");
    puts("PASS: actual file read, malformed data, errors, nonregular and symlink rejection");
}
static NSString *CKSavedPath;
static NSUInteger CKPathCalls;
NSString *axs_cachekeeper_test_injection_path(NSString *path) {
    if ([path isEqual:@"/var/mobile/Library/Preferences/com.opa334.choicyprefs.plist"]) {CKPathCalls++;return CKSavedPath;}
    return path;
}
static void CKExport(NSString *folder) {
    NSFileManager *fm=NSFileManager.defaultManager;
    CKRequire([fm createDirectoryAtPath:[folder stringByAppendingPathComponent:@"Status"] withIntermediateDirectories:YES attributes:nil error:NULL],"export fixture directory");
    CKSavedPath=[folder stringByAppendingPathComponent:@"private-choicy.plist"];
    NSDictionary *plist=@{@"appSettings":@{@"test.injection.app":@{@"customTweakConfigurationEnabled":@YES,@"allowedTweaks":@[@"private-secret"]}}};
    CKRequire([plist writeToFile:CKSavedPath atomically:YES],"export preferences fixture");
    NSDictionary *host=@{@"schemaVersion":@1,@"source":@"hostAutomatic",@"transportTrust":@"unauthenticated",@"updated":@1800000001,
        @"runtimeInfo":@{@"schemaVersion":@1,@"packageVersion":@"0.7.2-171.1",@"firstObserved":@1700000000},
        @"existingContainerGatePassed":@YES,@"authorizationAttempted":@YES,@"sharedAccessGranted":@YES,@"authorizationCode":@0,
        @"configurationReadScope":@"appEnabled",@"configurationReadState":@"readable",@"previousPublishState":@"succeeded",@"previousPublishErrorCode":@0};
    CKRequire(axs_cachekeeper_host_projection(host)!=nil,"host fixture is valid production schema");
    CKRequire([host writeToFile:[folder stringByAppendingPathComponent:@"Status/test.injection.app.host.plist"] atomically:YES],"current host fixture");
    CKPathCalls=0;
    AxsCacheKeeperDiagnostics *diagnostics=[[AxsCacheKeeperDiagnostics alloc] initWithFolder:folder];
    NSArray *apps=@[@{@"id":@"test.injection.app"},@{@"id":@"test.injection.other"}];
    NSDictionary *report=[diagnostics reportWithApps:apps environment:@{@"pluginVersion":@"0.7.2-171.1"} progress:^(NSUInteger completed,NSUInteger total){
        if (!completed) CKRequire([@"broken midway" writeToFile:CKSavedPath atomically:YES encoding:NSUTF8StringEncoding error:NULL],"replace after snapshot but before app projections");
    }];
    CKRequire(CKPathCalls==1,"export resolves and reads saved preferences once per report");
    NSDictionary *app=report[@"apps"][0],*other=report[@"apps"][1];
    CKRequire([app[@"savedInjectionConditions"][@"savedDecision"] isEqual:@"notAllowlisted"],"real export contains saved allow-list exclusion");
    CKRequire([other[@"savedInjectionConditions"][@"savedDecision"] isEqual:@"notRestricted"],"every app uses the same pre-callback snapshot");
    CKRequire([app[@"hostAutomatic"][@"state"] isEqual:@"available"] &&
        [app[@"capabilities"][@"hostAutomatic"][@"runtimeVersionState"] isEqual:@"currentVersion"],"positive current host remains authoritative despite saved exclusion");
    NSData *json=[NSJSONSerialization dataWithJSONObject:report options:0 error:NULL];
    NSString *text=[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    CKRequire(json && ![text containsString:@"private-secret"] && ![text containsString:CKSavedPath],"real report JSON never leaks third-party names or source path");
    NSDictionary *next=[diagnostics reportWithApps:apps environment:@{}];
    CKRequire(CKPathCalls==2 && [next[@"apps"][0][@"savedInjectionConditions"][@"savedDecision"] isEqual:@"unknown"],"next export observes changed malformed source instead of stale snapshot");
    puts("PASS: full production export snapshot consistency, runtime precedence and JSON privacy");
}
int main(int argc,char **argv) { @autoreleasepool {
    if (argc!=3) return 2;
    NSString *mode=[NSString stringWithUTF8String:argv[1]],*folder=[NSString stringWithUTF8String:argv[2]];
    if ([mode isEqual:@"projection"]) CKProjection(); else if ([mode isEqual:@"files"]) CKFiles(folder); else if ([mode isEqual:@"export"]) CKExport(folder); else return 2;
}return 0;}
