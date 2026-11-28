#import <Foundation/Foundation.h>
#import "AxsCacheKeeperStandaloneDiagnostics.h"
#import "AxsCacheKeeperCapacityStatus.h"
#include <unistd.h>
#include <fcntl.h>

static void axs_cachekeeper_standalone_require(BOOL condition,const char *message) {if(!condition){fprintf(stderr,"FAIL: standalone: %s\n",message);exit(1);}}
static NSString *axs_cachekeeper_standalone_directory(NSString *base,NSString *name) {
    NSString *path=[base stringByAppendingPathComponent:name];axs_cachekeeper_standalone_require([NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil],"create fixture");return path;
}
static NSDictionary *axs_cachekeeper_standalone_plan(NSString *path) {
    NSDictionary *empty=@{@"state":@"available",@"tokens":@[]};
    NSDictionary *registry=@{@"schemaVersion":@1,@"state":@"available",@"sourceState":@"available",@"observedRegistrations":@1,@"invalidRegistrationCount":@0,@"truncatedRegistrationCount":@0,@"allRolesUniqueRegisteredURLCount":@1,@"countsAreLowerBounds":@NO,@"sourceSampledAt":@100,
        @"home":@{@"state":@"available",@"observedSourceCount":@1,@"missingSelectorCount":@0,@"notProvidedCount":@0,@"invalidSourceCount":@0,@"invalidAssociationCount":@0,@"ownerMismatchCount":@0,@"unavailableOwnerCount":@0,@"truncatedCount":@0,@"registeredURLCount":@1,@"associationCount":@1},
        @"group":@{@"state":@"available",@"observedSourceCount":@1,@"missingSelectorCount":@0,@"notProvidedCount":@0,@"invalidSourceCount":@0,@"invalidAssociationCount":@0,@"ownerMismatchCount":@0,@"unavailableOwnerCount":@0,@"truncatedCount":@0,@"registeredURLCount":@0,@"associationCount":@0},
        @"extension":@{@"state":@"available",@"observedSourceCount":@1,@"missingSelectorCount":@0,@"notProvidedCount":@0,@"invalidSourceCount":@0,@"invalidAssociationCount":@0,@"ownerMismatchCount":@0,@"unavailableOwnerCount":@0,@"truncatedCount":@0,@"registeredURLCount":@0,@"associationCount":@0},
        @"entries":@[@{@"bundle":@"test.capacity",@"displayEligible":@YES,@"sourceClassification":@"user",@"relationships":@{@"home":@{@"state":@"available",@"tokens":@[@"resource-1"]},@"group":empty,@"extension":empty}}]};
    axs_cachekeeper_standalone_require(![axs_cachekeeper_registry_inventory_projection(registry)[@"state"] isEqual:@"invalid"],"registry fixture valid");
    return @{@"state":@"available",@"sourceSampledAt":@100,@"registry":registry,@"roots":@[@{@"token":@"resource-1",@"url":[NSURL fileURLWithPath:path],@"roles":@[@"home"],@"owners":@[@"test.capacity"]}]};
}
int main(int argc,const char *argv[]) {@autoreleasepool {
    axs_cachekeeper_standalone_require(argc==2,"fixture root supplied");NSString *base=[NSString stringWithUTF8String:argv[1]];
    NSString *saved=axs_cachekeeper_standalone_directory(base,@"saved"),*status=axs_cachekeeper_standalone_directory(saved,@"Status");
    NSString *configuration=[saved stringByAppendingPathComponent:@"appEnabled.plist"];
    NSDictionary *state=@{@"test.capacity":@{@"enabled":@YES,@"mode":@"clean",@"urlCache":@NO,@"autoDiscover":@YES,@"private":@"NEVER_EXPORT_PRIVATE"}};
    axs_cachekeeper_standalone_require([state writeToFile:configuration atomically:YES],"write configuration fixture");
    NSData *before=[NSData dataWithContentsOfFile:configuration];
    NSDictionary *read=axs_cachekeeper_diagnose_saved(saved,@[@"test.capacity"]);
    NSString *json=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:read options:0 error:nil] encoding:NSUTF8StringEncoding];
    axs_cachekeeper_standalone_require([read[@"apps"] count]==1 && ![json containsString:@"NEVER_EXPORT_PRIVATE"],"unknown configuration is never exported");
    axs_cachekeeper_standalone_require([[NSData dataWithContentsOfFile:configuration] isEqual:before],"saved read leaves configuration bytes unchanged");
    axs_cachekeeper_standalone_require([[@"malformed" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:[status stringByAppendingPathComponent:@"test.capacity.imagecache.plist"] atomically:YES],"write malformed state");
    read=axs_cachekeeper_diagnose_saved(saved,@[@"test.capacity"]);
    axs_cachekeeper_standalone_require([read[@"apps"][0][@"image"][@"state"] isEqual:@"invalid"],"malformed state remains invalid");
    NSString *privateFile=[base stringByAppendingPathComponent:@"private-canary"];
    axs_cachekeeper_standalone_require([@{@"private":@"NEVER_EXPORT_SYMLINK"} writeToFile:privateFile atomically:YES],"private canary");
    NSString *link=[status stringByAppendingPathComponent:@"test.capacity.network.plist"];
    axs_cachekeeper_standalone_require(!symlink(privateFile.fileSystemRepresentation,link.fileSystemRepresentation),"create source link");
    read=axs_cachekeeper_diagnose_saved(saved,@[@"test.capacity"]);
    axs_cachekeeper_standalone_require(![read[@"apps"][0][@"network"][@"state"] isEqual:@"available"],"source symlink is rejected");
    NSString *large=[status stringByAppendingPathComponent:@"test.capacity.host.plist"];
    int largeFD=open(large.fileSystemRepresentation,O_CREAT|O_WRONLY,0600);axs_cachekeeper_standalone_require(largeFD>=0 && !ftruncate(largeFD,2*1024*1024),"oversize source fixture");close(largeFD);
    read=axs_cachekeeper_diagnose_saved(saved,@[@"test.capacity"]);
    axs_cachekeeper_standalone_require(![read[@"apps"][0][@"host"][@"state"] isEqual:@"available"],"oversize technical state is rejected");
    NSString *faults=axs_cachekeeper_standalone_directory(base,@"faults");
    axs_cachekeeper_standalone_require([[@"SECRET_CRASH_BODY" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:[faults stringByAppendingPathComponent:@"BaiduNetdisk-private-2026.ips"] atomically:YES],"existing crash fixture");
    NSDictionary *metadata=axs_cachekeeper_diagnose_fault_metadata(@[faults]);
    json=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:metadata options:0 error:nil] encoding:NSUTF8StringEncoding];
    axs_cachekeeper_standalone_require([metadata[@"records"] count]==1 && ![json containsString:@"SECRET_CRASH_BODY"] && ![json containsString:@"private-2026"] && ![json containsString:faults],"fault metadata contains neither names nor contents");
    NSString *capacityHome=axs_cachekeeper_standalone_directory(base,@"container"),*capacityOutput=axs_cachekeeper_standalone_directory(base,@"capacity");
    axs_cachekeeper_standalone_require([[NSMutableData dataWithLength:8192] writeToFile:[capacityHome stringByAppendingPathComponent:@"private-business-name"] atomically:YES],"real capacity file");
    NSDictionary *source=axs_cachekeeper_standalone_plan(capacityHome);
    NSDictionary *capacity=axs_cachekeeper_diagnose_capacity(capacityOutput,^NSDictionary *(NSError **error){(void)error;return source;},10);
    axs_cachekeeper_standalone_require([capacity[@"record"][@"state"] isEqual:@"complete"] && [capacity[@"record"][@"roots"][0][@"measurement"][@"logicalBytes"] isEqual:@8192],"capacity advances real service and counts actual bytes");
    axs_cachekeeper_standalone_require([capacity[@"record"][@"deletionAuthorization"] isEqual:@"notGranted"] && [NSFileManager.defaultManager fileExistsAtPath:[capacityHome stringByAppendingPathComponent:@"private-business-name"]],"capacity preserves files and grants no deletion");
    json=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:capacity options:0 error:nil] encoding:NSUTF8StringEncoding];
    axs_cachekeeper_standalone_require(![json containsString:capacityHome] && ![json containsString:@"private-business-name"],"capacity does not export private axs_cachekeeper_standalone_plan");
    NSDictionary *limited=axs_cachekeeper_diagnose_capacity(axs_cachekeeper_standalone_directory(base,@"limited"),^NSDictionary *(NSError **error){(void)error;usleep(20000);return source;},.001);
    axs_cachekeeper_standalone_require([limited[@"stopReason"] isEqual:@"timeBudget"] && [limited[@"record"][@"state"] isEqual:@"cancelled"] && [limited[@"record"][@"lifecycle"][@"cursorClosure"] isEqual:@"observedZero"],"capacity deadline closes actual service cursor and preserves partial result");
    NSDictionary *unavailable=axs_cachekeeper_diagnose_capacity(axs_cachekeeper_standalone_directory(base,@"unavailable"),^NSDictionary *(NSError **error){if(error)*error=[NSError errorWithDomain:NSPOSIXErrorDomain code:EACCES userInfo:nil];return nil;},1);
    axs_cachekeeper_standalone_require([unavailable[@"record"][@"state"] isEqual:@"unavailable"] && [unavailable[@"state"] isEqual:@"partial"],"registry denial is never empty successful inventory");
    NSString *output=axs_cachekeeper_standalone_directory(base,@"output");NSError *error=nil;
    axs_cachekeeper_standalone_require(axs_cachekeeper_diagnose_write_json(@{@"state":@"complete"},output,&error),"atomic JSON writes actual file");
    axs_cachekeeper_standalone_require([NSFileManager.defaultManager createDirectoryAtPath:[output stringByAppendingPathComponent:@"bad"] withIntermediateDirectories:NO attributes:nil error:nil],"output failure folder");
    axs_cachekeeper_standalone_require(!axs_cachekeeper_diagnose_write_json(@{@"state":@"complete"},[output stringByAppendingPathComponent:@"missing"],&error) && error,"missing output fails explicitly");
    NSString *nonregular=axs_cachekeeper_standalone_directory(base,@"nonregular");axs_cachekeeper_standalone_directory(nonregular,@"report.json");
    axs_cachekeeper_standalone_require(!axs_cachekeeper_diagnose_write_json(@{@"state":@"complete"},nonregular,&error),"nonregular report destination is never replaced");
    NSString *symlinkOutput=axs_cachekeeper_standalone_directory(base,@"symlink-output");axs_cachekeeper_standalone_require(!symlink(privateFile.fileSystemRepresentation,[symlinkOutput stringByAppendingPathComponent:@"report.json"].fileSystemRepresentation),"create destination link");
    axs_cachekeeper_standalone_require(!axs_cachekeeper_diagnose_write_json(@{@"state":@"complete"},symlinkOutput,&error),"report destination symlink is never followed");
    NSDictionary *process=axs_cachekeeper_diagnose_processes();
    axs_cachekeeper_standalone_require([@[@"available",@"unavailable",@"partial"] containsObject:process[@"state"]] && process[@"identityScope"],"real sysctl returns an explicit capability state");
    puts("PASS: standalone real files, private projection, process capability and capacity service");return 0;
}}
