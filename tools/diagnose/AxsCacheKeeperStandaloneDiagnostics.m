#import "AxsCacheKeeperStandaloneDiagnostics.h"
#import "AxsCacheKeeperCapacityService.h"
#import "AxsCacheKeeperCapacityStatus.h"
#import "AxsCacheKeeperHostEvidence.h"
#import "AxsCacheKeeperImageCacheStatus.h"
#import "AxsCacheKeeperWebKitStatus.h"
#import "AxsCacheKeeperGurdStatus.h"
#include <CommonCrypto/CommonDigest.h>
#include <TargetConditionals.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <math.h>

static const NSUInteger AxsCacheKeeperDiagnoseReportLimit=32*1024*1024;
static const NSUInteger AxsCacheKeeperDiagnoseStateLimit=256*1024;
static const NSUInteger AxsCacheKeeperDiagnoseSavedReportLimit=2*1024*1024;
#ifndef AXS_CACHEKEEPER_DIAGNOSE_VERSION
#define AXS_CACHEKEEPER_DIAGNOSE_VERSION "development"
#endif
#ifndef AXS_CACHEKEEPER_DIAGNOSE_SOURCE
#define AXS_CACHEKEEPER_DIAGNOSE_SOURCE "unrecorded"
#endif
static NSArray *AxsCacheKeeperDiagnoseTargets(void) {return @[@"com.baidu.netdisk",@"com.tencent.mqq",@"com.ss.iphone.ugc.Aweme",@"com.360buy.jdmobile",@"app.swiftgram.ios"];}
static NSDictionary *AxsCacheKeeperDiagnoseError(NSString *state,NSInteger code) {return @{@"state":state,@"errorCode":@(code)};}
static BOOL AxsCacheKeeperDiagnoseFail(NSError **error,int code) {if(error)*error=[NSError errorWithDomain:NSPOSIXErrorDomain code:code ?: EIO userInfo:nil];return NO;}
static id AxsCacheKeeperDiagnoseJSON(id value,NSUInteger depth) {
    if(depth>32)return NSNull.null;
    if([value isKindOfClass:NSDate.class])return @([value timeIntervalSince1970]);
    if([value isKindOfClass:NSString.class] || value==NSNull.null)return value;
    if([value isKindOfClass:NSNumber.class])return isfinite([value doubleValue]) ? value : NSNull.null;
    if([value isKindOfClass:NSArray.class]){NSMutableArray *out=[NSMutableArray new];for(id item in value)[out addObject:AxsCacheKeeperDiagnoseJSON(item,depth+1)];return out;}
    if([value isKindOfClass:NSDictionary.class]){NSMutableDictionary *out=[NSMutableDictionary new];for(id key in value)if([key isKindOfClass:NSString.class])out[key]=AxsCacheKeeperDiagnoseJSON(value[key],depth+1);return out;}
    return NSNull.null;
}
static NSDictionary *AxsCacheKeeperDiagnoseRead(NSString *folder,NSString *name,NSUInteger limit) {
    NSError *error=nil;id value=axs_cachekeeper_capacity_read_plist(folder,name,limit,&error);
    if(!value)return AxsCacheKeeperDiagnoseError(error.code==ENOENT ? @"missing" : [error.domain isEqual:NSCocoaErrorDomain] ? @"invalid" : @"readError",error.code);
    if(![value isKindOfClass:NSDictionary.class])return AxsCacheKeeperDiagnoseError(@"invalid",EINVAL);
    return @{@"state":@"available",@"data":value};
}
static NSDictionary *AxsCacheKeeperDiagnoseConfiguration(id value) {
    if([value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID())return @{@"enabled":value};
    if(![value isKindOfClass:NSDictionary.class])return @{@"state":value ? @"invalid" : @"missing"};
    NSMutableDictionary *out=[NSMutableDictionary new];
    for(NSString *key in @[@"enabled",@"urlCache",@"webKitDiskCache",@"autoDiscover"]){id item=value[key];if(item && axs_cachekeeper_input_boolean(item))out[key]=item;else if(item)out[@"invalidFields"]=@YES;}
    if([@[@"auto",@"prevent",@"clean"] containsObject:value[@"mode"]])out[@"mode"]=value[@"mode"];else if(value[@"mode"])out[@"invalidFields"]=@YES;
    return out;
}
static NSDictionary *AxsCacheKeeperDiagnoseCleanup(id value) {
    if(![value isKindOfClass:NSDictionary.class])return nil;
    NSMutableDictionary *out=[NSMutableDictionary new];
    for(NSString *key in @[@"removed",@"bytes",@"confirmedRemoved",@"confirmedBytes",@"failed",@"lastRemoved",@"lastBytes"]){
        if(value[key] && !axs_cachekeeper_release_uint(value[key],NULL))return nil;if(value[key])out[key]=value[key];
    }
    if([value[@"updated"] isKindOfClass:NSDate.class])out[@"updated"]=value[@"updated"];
    if([@[@"waiting",@"cleaning",@"complete",@"error"] containsObject:value[@"phase"]])out[@"phase"]=value[@"phase"];
    // Paths, arbitrary messages and old request identifiers never enter this report.
    return out;
}
NSDictionary *axs_cachekeeper_diagnose_saved(NSString *folder,NSArray<NSString *> *requested) {
    NSDictionary *configuration=AxsCacheKeeperDiagnoseRead(folder,@"appEnabled.plist",1024*1024);
    NSMutableOrderedSet *bundles=[NSMutableOrderedSet orderedSetWithArray:requested ?: AxsCacheKeeperDiagnoseTargets()];
    if(!requested)for(NSString *bundle in [configuration[@"data"] allKeys])if(axs_cachekeeper_bundle_id(bundle))[bundles addObject:bundle];
    NSMutableArray *apps=[NSMutableArray new];NSUInteger omitted=bundles.count>64 ? bundles.count-64 : 0,readBytes=0,reportBytes=0;
    BOOL limited=NO;NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+3;
    for(NSString *bundle in bundles){
        if(apps.count>=64)break;if(!axs_cachekeeper_bundle_id(bundle))continue;
        NSMutableDictionary *app=[@{@"bundle":bundle,@"configuration":AxsCacheKeeperDiagnoseConfiguration(configuration[@"data"][bundle])} mutableCopy];
        for(NSArray *pair in @[@[@"network",@"network"],@[@"host",@"host"],@[@"image",@"imagecache"],@[@"webkit",@"webkit"],@[@"gurd",@"gurd"],@[@"cleanup",@"auto"]]){
            if(readBytes>=8*1024*1024 || NSProcessInfo.processInfo.systemUptime>=deadline){app[pair[0]]=@{@"state":@"budgetExceeded"};limited=YES;continue;}
            NSDictionary *read=AxsCacheKeeperDiagnoseRead([folder stringByAppendingPathComponent:@"Status"],[NSString stringWithFormat:@"%@.%@.plist",bundle,pair[1]],AxsCacheKeeperDiagnoseStateLimit);
            // Charge the maximum attempted read; reserialized plist size is not input size.
            readBytes+=AxsCacheKeeperDiagnoseStateLimit;
            if(![read[@"state"] isEqual:@"available"]){app[pair[0]]=read;continue;}
            id raw=read[@"data"];NSDictionary *projection=nil;
            if([pair[0] isEqual:@"network"])projection=axs_cachekeeper_network_projection(raw);
            else if([pair[0] isEqual:@"host"])projection=axs_cachekeeper_host_projection(raw);
            else if([pair[0] isEqual:@"image"])projection=axs_cachekeeper_image_cache_projection(raw);
            else if([pair[0] isEqual:@"webkit"])projection=axs_cachekeeper_webkit_projection(raw);
            else if([pair[0] isEqual:@"gurd"])projection=axs_cachekeeper_gurd_receipt_projection(raw);
            else projection=AxsCacheKeeperDiagnoseCleanup(raw);
            app[pair[0]]=projection ? @{@"state":@"available",@"data":AxsCacheKeeperDiagnoseJSON(projection,0)} : AxsCacheKeeperDiagnoseError(@"invalid",EINVAL);
        }
        NSData *row=[NSJSONSerialization dataWithJSONObject:app options:0 error:nil];
        if(!row || row.length>AxsCacheKeeperDiagnoseSavedReportLimit-reportBytes){omitted=bundles.count-apps.count;limited=YES;break;}
        reportBytes+=row.length;[apps addObject:app];
    }
    return @{@"state":limited || omitted ? @"partial" : @"complete",@"observation":@"savedRecords",@"capturedAt":@(NSDate.date.timeIntervalSince1970),@"configurationSource":configuration[@"state"],@"nonAtomic":@YES,@"apps":apps,@"omittedApps":@(omitted),@"recordsAreNotLiveVerification":@YES};
}
static NSString *AxsCacheKeeperDiagnoseDigest(NSString *text) {
    NSData *bytes=[text dataUsingEncoding:NSUTF8StringEncoding];unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(bytes.bytes,(CC_LONG)bytes.length,digest);
    NSMutableString *out=[NSMutableString new];for(NSUInteger i=0;i<sizeof(digest);i++)[out appendFormat:@"%02x",digest[i]];return out;
}
static NSString *AxsCacheKeeperDiagnoseFaultSubject(NSString *name) {
    NSString *lower=name.lowercaseString;
    for(NSArray *pair in @[@[@"baidunetdisk",@"baidu"],@[@"netdisk",@"baidu"],@[@"aweme",@"douyin"],@[@"qq-",@"qq"],@[@"jd4iphone",@"jd"],@[@"swiftgram",@"swiftgram"],@[@"springboard",@"springboard"]])if([lower hasPrefix:pair[0]])return pair[1];
    if([lower hasPrefix:@"jetsamevent"])return @"unattributedSystemEvent";
    return nil;
}
NSDictionary *axs_cachekeeper_diagnose_fault_metadata(NSArray<NSString *> *folders) {
    NSMutableArray *records=[NSMutableArray new],*sources=[NSMutableArray new];NSUInteger inspected=0;BOOL truncated=NO;
    NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+2;
    for(NSUInteger index=0;index<folders.count;index++){
        NSString *folder=folders[index];int fd=axs_cachekeeper_open_directory(folder);
        if(fd<0){[sources addObject:@{@"source":@(index+1),@"state":errno==ENOENT ? @"missing" : @"readError",@"errorCode":@(errno)}];continue;}
        DIR *directory=fdopendir(fd);if(!directory){int code=errno;close(fd);[sources addObject:@{@"source":@(index+1),@"state":@"readError",@"errorCode":@(code)}];continue;}
        int code=0;
        while(YES){
            if(inspected>=1024 || records.count>=128 || NSProcessInfo.processInfo.systemUptime>=deadline){truncated=YES;break;}
            errno=0;struct dirent *entry=readdir(directory);if(!entry){code=errno;break;}
            if(!strcmp(entry->d_name,".") || !strcmp(entry->d_name,".."))continue;inspected++;
            NSString *name=[NSFileManager.defaultManager stringWithFileSystemRepresentation:entry->d_name length:strlen(entry->d_name)];
            NSString *kind=name.pathExtension.lowercaseString,*subject=AxsCacheKeeperDiagnoseFaultSubject(name);
            if(!subject || ![@[@"ips",@"crash",@"spin",@"hang"] containsObject:kind])continue;
            struct stat info;if(fstatat(fd,entry->d_name,&info,AT_SYMLINK_NOFOLLOW)){code=errno;continue;}
            if(!S_ISREG(info.st_mode) || info.st_size<0)continue;
            NSString *identifier=AxsCacheKeeperDiagnoseDigest([NSString stringWithFormat:@"%lu:%@",(unsigned long)index,name]);
            [records addObject:@{@"id":identifier,@"subjectHint":subject,@"association":@"filenameOnlyUnverified",@"kind":kind,@"bytes":@((uint64_t)info.st_size),@"modifiedAt":@(info.st_mtimespec.tv_sec),@"source":@(index+1)}];
        }
        if(closedir(directory) && !code)code=errno;
        [sources addObject:@{@"source":@(index+1),@"state":code ? @"readError" : truncated ? @"partial" : @"complete",@"errorCode":@(code)}];
        if(truncated)break;
    }
    BOOL available=NO;for(NSDictionary *source in sources)if([source[@"state"] isEqual:@"complete"] || [source[@"state"] isEqual:@"partial"])available=YES;
    return @{@"state":truncated ? @"partial" : available ? @"available" : @"unavailable",@"sources":sources,@"records":records,@"entriesExamined":@(inspected),@"contentRead":@NO,@"systemSamplingTriggered":@NO};
}
NSDictionary *axs_cachekeeper_diagnose_processes(void) {
    int mib[3]={CTL_KERN,KERN_PROC,KERN_PROC_ALL};size_t size=0;NSMutableData *data=nil;int code=0;
    for(NSUInteger attempt=0;attempt<3;attempt++){
        if(sysctl(mib,3,NULL,&size,NULL,0)){code=errno;break;}
        if(size>4*1024*1024){code=EFBIG;break;}
        data=[NSMutableData dataWithLength:size+32*sizeof(struct kinfo_proc)];size=data.length;
        if(!sysctl(mib,3,data.mutableBytes,&size,NULL,0)){code=0;break;}code=errno;data=nil;if(code!=ENOMEM)break;
    }
    NSString *scope=@"fixedExecutableNameHeuristicNotBundleIdentity";
    if(!data || code || size%sizeof(struct kinfo_proc))return @{@"state":@"unavailable",@"errorCode":@(code ?: EIO),@"identityScope":scope,@"records":@[]};
    NSDictionary *names=@{@"BaiduNetdisk":@"baidu",@"netdisk":@"baidu",@"QQ":@"qq",@"Aweme":@"douyin",@"JD4iPhone":@"jd",@"Swiftgram":@"swiftgram",@"SpringBoard":@"springboard"};
    NSMutableArray *records=[NSMutableArray new];struct kinfo_proc *entries=data.mutableBytes;
    for(NSUInteger i=0;i<size/sizeof(*entries);i++){
        char command[sizeof(entries[i].kp_proc.p_comm)+1]={0};memcpy(command,entries[i].kp_proc.p_comm,sizeof(entries[i].kp_proc.p_comm));
        NSString *name=[[NSString alloc] initWithBytes:command length:strnlen(command,sizeof(command)) encoding:NSUTF8StringEncoding],*subject=name ? names[name] : nil;
        if(!subject)continue;
        struct timeval start=entries[i].kp_proc.p_starttime;
        if(records.count>=64)return @{@"state":@"partial",@"identityScope":scope,@"records":records,@"limit":@64};
        [records addObject:@{@"subjectHint":subject,@"pid":@(entries[i].kp_proc.p_pid),@"startedSeconds":@((long long)start.tv_sec),@"startedMicroseconds":@(start.tv_usec),@"kernelState":@((int)entries[i].kp_proc.p_stat)}];
    }
    return @{@"state":@"available",@"identityScope":scope,@"records":records,@"absenceDoesNotProveAppExit":@YES};
}
NSDictionary *axs_cachekeeper_diagnose_system_plan(NSError **error) {
#if TARGET_OS_IPHONE
    static void *framework;static dispatch_once_t once;dispatch_once(&once,^{framework=dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",RTLD_LAZY|RTLD_LOCAL);});
    if(!framework){AxsCacheKeeperDiagnoseFail(error,ENOENT);return nil;}
#endif
    NSMutableDictionary *cache=[NSMutableDictionary new];NSDictionary *plan=nil,*coverage=nil,*registry=nil;
    NSArray *installed=axs_cachekeeper_installed_applications_with_capacity_plan(cache,&coverage,&registry,&plan,error);
    if(!plan)return nil;
    NSMutableArray *metadata=[NSMutableArray new];
    for(NSDictionary *entry in installed){
        if(!axs_cachekeeper_bundle_id(entry[@"id"]))continue;
        NSMutableDictionary *row=[@{@"bundle":entry[@"id"]} mutableCopy];
        for(NSString *key in @[@"version",@"build",@"installationState"])
            if([entry[key] isKindOfClass:NSString.class] && [entry[key] length]<=128)row[key]=entry[key];
        [metadata addObject:row];
    }
    NSMutableDictionary *out=[plan mutableCopy];out[@"applicationMetadata"]=metadata;return out;
}
NSDictionary *axs_cachekeeper_diagnose_capacity(NSString *folder,NSDictionary *(^provider)(NSError **),NSTimeInterval seconds) {
    NSString *epoch=NSUUID.UUID.UUIDString,*request=[folder stringByAppendingPathComponent:@"capacityRequest.plist"];NSError *error=nil;
    if(!axs_cachekeeper_capacity_write_request(request,epoch,NO,&error))return AxsCacheKeeperDiagnoseError(@"outputError",error.code);
    __block NSDictionary *last=nil;__block NSArray *metadata=@[];
    AxsCacheKeeperCapacityService *service=[[AxsCacheKeeperCapacityService alloc] initWithFolder:folder provider:^NSDictionary *(NSError **error){
        NSDictionary *plan=provider ? provider(error) : nil;
        if([plan[@"applicationMetadata"] isKindOfClass:NSArray.class])metadata=[plan[@"applicationMetadata"] copy];
        return plan;
    } writer:^BOOL(NSDictionary *record,NSString *path){
        (void)path;last=[record copy];return YES;
    }];
    NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+seconds;BOOL active=YES,budget=NO;
    while(active){@autoreleasepool{
        if(NSProcessInfo.processInfo.systemUptime>=deadline){budget=YES;break;}
        active=[service tick];if(active)usleep(1000);
    }}
    if(active){
        if(!axs_cachekeeper_capacity_write_request(request,epoch,YES,&error))return @{@"state":@"outputError",@"errorCode":@(error.code),@"record":AxsCacheKeeperDiagnoseJSON(last ?: @{},0)};
        for(NSUInteger i=0;i<3 && active;i++)active=[service tick];
    }
    NSDictionary *closed=axs_cachekeeper_capacity_projection(last);
    if(![closed isKindOfClass:NSDictionary.class])closed=@{@"state":@"invalid"};
    NSData *encoded=[NSJSONSerialization dataWithJSONObject:AxsCacheKeeperDiagnoseJSON(closed,0) options:0 error:nil];
    if(!encoded || encoded.length>20*1024*1024)return @{@"state":@"partial",@"stopReason":@"reportBudget",@"record":@{@"state":@"omitted"},@"observedRoots":closed[@"totalRoots"] ?: @0,@"completedRoots":closed[@"completedRoots"] ?: @0};
    return @{@"state":active ? @"partial" : [closed[@"state"] isEqual:@"complete"] ? @"complete" : @"partial",@"stopReason":budget ? @"timeBudget" : @"serviceFinished",@"record":AxsCacheKeeperDiagnoseJSON(closed,0),@"applicationMetadata":metadata,@"metadataScope":@"displayEligibleRegistrations",@"liveSample":@YES};
}
BOOL axs_cachekeeper_diagnose_write_json(NSDictionary *report,NSString *directory,NSError **error) {
    if(error)*error=nil;NSData *bytes=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:error];
    if(!bytes || bytes.length>AxsCacheKeeperDiagnoseReportLimit)return AxsCacheKeeperDiagnoseFail(error,EFBIG);
    int parent=axs_cachekeeper_open_directory(directory);if(parent<0)return AxsCacheKeeperDiagnoseFail(error,errno);
    struct stat parentBefore,target;BOOL ok=!fstat(parent,&parentBefore);int check=fstatat(parent,"report.json",&target,AT_SYMLINK_NOFOLLOW);
    if(!check && !S_ISREG(target.st_mode))ok=NO;else if(check && errno!=ENOENT)ok=NO;
    NSString *temporary=[@".report-" stringByAppendingString:NSUUID.UUID.UUIDString];
    int fd=ok ? openat(parent,temporary.fileSystemRepresentation,O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC|O_WRONLY,0600) : -1;
    if(fd<0){int code=errno;close(parent);return AxsCacheKeeperDiagnoseFail(error,code);}
    NSUInteger written=0;while(ok && written<bytes.length){ssize_t count=write(fd,(const char *)bytes.bytes+written,bytes.length-written);if(count<0 && errno==EINTR)continue;if(count<=0){ok=NO;break;}written+=(NSUInteger)count;}
    if(ok)ok=!fsync(fd);if(close(fd))ok=NO;
    struct stat parentNow;if(ok)ok=!lstat(directory.fileSystemRepresentation,&parentNow) && S_ISDIR(parentNow.st_mode) && parentNow.st_dev==parentBefore.st_dev && parentNow.st_ino==parentBefore.st_ino;
    if(ok)ok=!renameat(parent,temporary.fileSystemRepresentation,parent,"report.json");
    int code=errno;if(!ok)unlinkat(parent,temporary.fileSystemRepresentation,0);close(parent);return ok ?: AxsCacheKeeperDiagnoseFail(error,code);
}
static NSArray *AxsCacheKeeperDiagnoseLargest(NSDictionary *record) {
    if(![record isKindOfClass:NSDictionary.class] || ![record[@"roots"] isKindOfClass:NSArray.class] || ![record[@"entries"] isKindOfClass:NSArray.class])return @[];
    NSMutableArray *apps=[NSMutableArray new];NSMutableDictionary *roots=[NSMutableDictionary new];
    for(NSDictionary *root in record[@"roots"])roots[root[@"id"]]=root;
    for(NSDictionary *entry in record[@"entries"]){
        uint64_t logical=0,allocated=0;NSUInteger completed=0,observed=0,shared=0;
        for(NSNumber *identifier in entry[@"rootIds"]){NSDictionary *root=roots[identifier],*measure=root[@"measurement"];if(!root)continue;observed++;logical+=[measure[@"logicalBytes"] unsignedLongLongValue];allocated+=[measure[@"allocatedBytes"] unsignedLongLongValue];shared += [root[@"owners"] count]>1;if([measure[@"state"] isEqual:@"complete"])completed++;}
        BOOL complete=[entry[@"state"] isEqual:@"registered"] && observed>0 && completed==[entry[@"rootIds"] count];
        [apps addObject:@{@"bundle":entry[@"bundle"],@"state":complete ? @"complete" : observed ? @"partial" : @"notMeasured",@"observedLogicalBytes":@(logical),@"observedAllocatedBytes":@(allocated),@"observedRoots":@(observed),@"declaredRoots":@([entry[@"rootIds"] count]),@"sharedRoots":@(shared)}];
    }
    [apps sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [b[@"observedLogicalBytes"] compare:a[@"observedLogicalBytes"]];}];
    return apps.count>20 ? [apps subarrayWithRange:NSMakeRange(0,20)] : apps;
}
static NSDictionary *AxsCacheKeeperDiagnoseFaultChanges(NSDictionary *before,NSDictionary *after) {
    NSMutableDictionary *old=[NSMutableDictionary new];for(NSDictionary *row in before[@"records"])old[row[@"id"]]=row;
    NSUInteger added=0,changed=0;for(NSDictionary *row in after[@"records"]){if(!old[row[@"id"]])added++;else if(![old[row[@"id"]] isEqual:row])changed++;}
    return @{@"newlyObserved":@(added),@"changed":@(changed),@"comparisonScope":@"boundedDirectoryMetadataOnly",@"missingDoesNotProveNoCrash":@YES};
}
int axs_cachekeeper_diagnose_collect(NSString *outputBase,NSString *pluginFolder,NSArray<NSString *> *faultFolders,NSTimeInterval duration,int readyDescriptor) {
    @autoreleasepool {
    int base=axs_cachekeeper_open_directory(outputBase);if(base<0)return 20;
    NSString *run=[@"CacheKeeper-" stringByAppendingString:NSUUID.UUID.UUIDString];
    if(mkdirat(base,run.fileSystemRepresentation,0700)){close(base);return 21;}close(base);
    NSString *output=[outputBase stringByAppendingPathComponent:run],*capacityFolder=[output stringByAppendingPathComponent:@"capacity"];
    if(![NSFileManager.defaultManager createDirectoryAtPath:capacityFolder withIntermediateDirectories:NO attributes:nil error:nil])return 21;
    NSTimeInterval started=NSDate.date.timeIntervalSince1970,begin=NSProcessInfo.processInfo.systemUptime;
    NSMutableArray *samples=[NSMutableArray new];
    NSDictionary *savedBefore=axs_cachekeeper_diagnose_saved(pluginFolder,nil),*faultBefore=axs_cachekeeper_diagnose_fault_metadata(faultFolders);
    NSMutableDictionary *report=[@{@"schemaVersion":@1,@"toolVersion":@AXS_CACHEKEEPER_DIAGNOSE_VERSION,@"sourceRevision":@AXS_CACHEKEEPER_DIAGNOSE_SOURCE,
        @"environment":@{@"operatingSystem":NSProcessInfo.processInfo.operatingSystemVersionString,@"architecture":sizeof(void *)==8 ? @"64bit" : @"32bit"},
        @"state":@"running",@"startedAt":@(started),@"durationSeconds":@(duration),
        @"safety":@{@"configurationModified":@NO,@"resourcesDeleted":@NO,@"businessContentRead":@NO,@"processMemoryRead":@NO,@"processAttached":@NO,@"systemSamplingTriggered":@NO},
        @"scope":@{@"capacity":@"currentSystemRegistryAllApplicationsWithinBudget",@"processes":@"fixedExecutableNameHeuristic",@"faults":@"existingSystemMetadataOnly"},
        @"savedBefore":savedBefore,@"faultsBefore":faultBefore,@"capacity":@{@"state":@"running"},
        @"limitations":@[@"No thread stack was collected; this report cannot determine the photo browsing hang root cause.",@"Kernel process names do not authenticate app bundle identity or prove foreground responsiveness.",@"Capacity is a non-atomic metadata traversal; shared roots, incomplete roots and retained content are not reclaimable bytes.",@"Private resource adapters and previously blocked runtime collection are not executed."]} mutableCopy];
    begin=NSProcessInfo.processInfo.systemUptime;NSTimeInterval windowStarted=NSDate.date.timeIntervalSince1970;
    [samples addObject:@{@"elapsed":@0,@"observation":axs_cachekeeper_diagnose_processes()}];report[@"processWindow"]=@{@"state":@"running",@"startedAt":@(windowStarted),@"samples":[samples copy]};
    NSError *writeError=nil;if(!axs_cachekeeper_diagnose_write_json(report,output,&writeError))return 22;
    if(readyDescriptor>=0){
        NSData *ready=[NSJSONSerialization dataWithJSONObject:@{@"state":@"started",@"pid":@(getpid()),@"report":[output stringByAppendingPathComponent:@"report.json"],@"completion":@"pending"} options:0 error:nil];
        NSUInteger offset=0;while(offset<ready.length){ssize_t count=write(readyDescriptor,(const char *)ready.bytes+offset,ready.length-offset);if(count<0 && errno==EINTR)continue;if(count<=0){close(readyDescriptor);return 23;}offset+=(NSUInteger)count;}
        (void)write(readyDescriptor,"\n",1);close(readyDescriptor);
    }
    NSObject *lock=[NSObject new];__block NSDictionary *capacity=nil;dispatch_semaphore_t capacityDone=dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        @autoreleasepool{NSDictionary *result=axs_cachekeeper_diagnose_capacity(capacityFolder,^NSDictionary *(NSError **error){return axs_cachekeeper_diagnose_system_plan(error);},duration);
        @synchronized(lock){capacity=result;}dispatch_semaphore_signal(capacityDone);}
    });
    NSTimeInterval next=begin+1,published=begin;
    while(NSProcessInfo.processInfo.systemUptime<begin+duration){@autoreleasepool{
        NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
        if(now>=next){[samples addObject:@{@"elapsed":@(now-begin),@"observation":axs_cachekeeper_diagnose_processes()}];next=now+1;}
        if(now-published>=5){report[@"processWindow"]=@{@"state":@"running",@"startedAt":@(windowStarted),@"samples":[samples copy]};@synchronized(lock){if(capacity)report[@"capacity"]=capacity;}
            if(!axs_cachekeeper_diagnose_write_json(report,output,&writeError))return 22;published=now;}
        usleep(50000);
    }}
    [samples addObject:@{@"elapsed":@(NSProcessInfo.processInfo.systemUptime-begin),@"observation":axs_cachekeeper_diagnose_processes()}];
    (void)dispatch_semaphore_wait(capacityDone,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC));
    @synchronized(lock){report[@"capacity"]=capacity ?: @{@"state":@"partial",@"stopReason":@"workerDeadlineExceeded",@"recordUnavailable":@YES,@"cursorClosure":@"notObservedBeforeProcessExit"};}
    report[@"largestObservedApplications"]=AxsCacheKeeperDiagnoseLargest(report[@"capacity"][@"record"]);
    report[@"savedAfter"]=axs_cachekeeper_diagnose_saved(pluginFolder,nil);
    NSDictionary *faultAfter=axs_cachekeeper_diagnose_fault_metadata(faultFolders);report[@"faultsAfter"]=faultAfter;report[@"faultChanges"]=AxsCacheKeeperDiagnoseFaultChanges(faultBefore,faultAfter);
    BOOL processAvailable=NO,processComplete=YES;for(NSDictionary *sample in samples){BOOL available=[sample[@"observation"][@"state"] isEqual:@"available"];processAvailable|=available;processComplete&=available;}
    report[@"processWindow"]=@{@"state":processComplete ? @"complete" : processAvailable ? @"partial" : @"unavailable",@"startedAt":@(windowStarted),@"finishedAt":@(NSDate.date.timeIntervalSince1970),@"samples":[samples copy],@"responsivenessMeasured":@NO};
    BOOL complete=[report[@"capacity"][@"state"] isEqual:@"complete"] && processComplete &&
        [faultBefore[@"state"] isEqual:@"available"] && [faultAfter[@"state"] isEqual:@"available"] &&
        [savedBefore[@"configurationSource"] isEqual:@"available"] && [report[@"savedAfter"][@"configurationSource"] isEqual:@"available"] &&
        [savedBefore[@"state"] isEqual:@"complete"] && [report[@"savedAfter"][@"state"] isEqual:@"complete"];
    report[@"state"]=complete ? @"complete" : @"partial";
    report[@"finishedAt"]=@(NSDate.date.timeIntervalSince1970);
    if(!axs_cachekeeper_diagnose_write_json(report,output,&writeError))return 22;
    return [report[@"state"] isEqual:@"complete"] ? 0 : 2;
    }
}
