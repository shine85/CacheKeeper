#import <Foundation/Foundation.h>
#import "../AxsCacheKeeperDiagnostics.h"
#import "../AxsCacheKeeperRecords.h"

static void ckcheck(BOOL condition, NSString *message) {
    if (!condition) {fprintf(stderr,"FAIL: inspection export: %s\n",message.UTF8String);exit(1);}
}
int main(int argc, char **argv) { @autoreleasepool {
    if (argc!=2) return 2;
    NSString *folder=[NSString stringWithUTF8String:argv[1]];
    ckcheck([NSFileManager.defaultManager createDirectoryAtPath:[folder stringByAppendingPathComponent:@"Status"] withIntermediateDirectories:YES attributes:nil error:nil],@"fixture directory");
    NSString *path=[folder stringByAppendingPathComponent:@"Status/test.inspection.inspection.plist"];
    NSMutableDictionary *record=[@{@"files":@1,@"mainReadFailure":@{@"state":@"notRecorded"},
        @"twinReadFailure":@{@"stage":@"entryName",@"errorDomain":@"posix",@"errorCode":@22},
        @"invalidNameRecords":@0,@"twinInvalidNameRecords":@1,@"nameDisplayOmitted":@2,@"twinNameDisplayOmitted":@3,
        @"largest":@[@{@"path":@"<名称未展示>",@"pathOperable":@NO}],
        @"linkTwins":@[@{@"source":@"opaque",@"twin":@"other",@"sourceOperable":@NO,@"twinOperable":@YES}],
        @"rawComponents":@[@"raw-name-private-canary"]} mutableCopy];
    AxsCacheKeeperDiagnostics *session=[[AxsCacheKeeperDiagnostics alloc] initWithFolder:folder];
    NSDictionary *(^read)(void)=^NSDictionary *{
        ckcheck([record writeToFile:path atomically:YES],@"fixture receipt");
        NSData *before=[NSData dataWithContentsOfFile:path];
        NSDictionary *report=[session reportWithApps:@[@{@"id":@"test.inspection"}] environment:@{}];
        NSData *json=[NSJSONSerialization dataWithJSONObject:report options:0 error:nil];
        ckcheck(json!=nil && [[NSData dataWithContentsOfFile:path] isEqual:before],@"JSON export never mutates source");
        ckcheck(![[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] containsString:@"raw-name-private-canary"],@"raw bytes and unknown fields stay private");
        return report[@"apps"][0][@"inspection"][@"data"];
    };
    NSDictionary *out=read();
    ckcheck([out[@"twinReadFailure"] isEqual:record[@"twinReadFailure"]] && [out[@"mainReadFailure"] isEqual:record[@"mainReadFailure"]],@"main and twin failures remain separate");
    for (NSString *key in @[@"invalidNameRecords",@"twinInvalidNameRecords",@"nameDisplayOmitted",@"twinNameDisplayOmitted"])
        ckcheck([out[key] isEqual:record[key]],@"finite name counters survive export");
    ckcheck([out[@"largest"][0][@"pathOperable"] isEqual:@NO] && [out[@"linkTwins"][0][@"sourceOperable"] isEqual:@NO] && [out[@"linkTwins"][0][@"twinOperable"] isEqual:@YES],@"opaque display cannot become an actionable path");
    for (id bad in @[@YES,@(-1),@0.5,@"private-counter"]) {
        record[@"nameDisplayOmitted"]=bad;out=read();
        ckcheck([out[@"invalidRecord"] boolValue] && !out[@"nameDisplayOmitted"],@"invalid name counter rejected");
    }
    [record removeObjectForKey:@"nameDisplayOmitted"];
    record[@"largest"]=@[@{@"path":@"opaque",@"pathOperable":@1}];out=read();
    ckcheck([out[@"largest"][0][@"invalidRecord"] boolValue] && !out[@"largest"][0][@"pathOperable"],@"integer is not an operability boolean");
    record[@"twinReadFailure"]=@{@"stage":@"entryName",@"errorDomain":@"posix",@"errorCode":@22,@"rawPath":@"raw-name-private-canary"};
    ckcheck([read()[@"twinReadFailure"] isEqual:@{@"state":@"invalid"}],@"failure payload is closed");
    [record removeObjectForKey:@"twinReadFailure"];[record removeObjectForKey:@"mainReadFailure"];
    out=read();ckcheck(!out[@"mainReadFailure"] && !out[@"twinReadFailure"] && !out[@"nameDisplayOmitted"],@"historical absence remains absent");
    for (NSString *key in @[@"invalidNameRecords",@"twinInvalidNameRecords",@"nameDisplayOmitted",@"twinNameDisplayOmitted"]) {
        for (id bad in @[@{},@"wrong",@YES,@(-1),@0.5]) {
            NSDictionary *envelope=@{@"reports":@{@"Library/Caches":@{key:bad}}};
            ckcheck([envelope writeToFile:path atomically:YES],@"bad UI fixture write");
            NSError *error=nil;
            ckcheck(!axs_cachekeeper_read_records(path,&error) && error!=nil,@"UI saved-record reader rejects invalid name counters");
        }
    }
    ckcheck(axs_cachekeeper_record_valid(@{@"reports":@{@"Library/Caches":@{@"files":@1}}},0),@"legacy UI records need not invent new counters");
    puts("PASS: inspection export separation, finite fields, privacy and saved-record roundtrip");
    return 0;
}}
