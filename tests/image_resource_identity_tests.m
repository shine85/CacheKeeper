#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "../AxsCacheKeeperInstallation.h"
#include <mach-o/loader.h>
#include <mach-o/fat.h>
#include <libkern/OSByteOrder.h>
#include <sys/stat.h>
#include <unistd.h>
#import <dispatch/dispatch.h>

static void ckrequire(BOOL value,const char *message) {if (!value) {fprintf(stderr,"FAIL: image resource identity: %s\n",message);exit(1);}}
// dispatch_sync to a global queue may run inline; this fixture must exercise the actual off-main gate.
static void ckbackground(void (^work)(void)) {
    dispatch_semaphore_t complete=dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        @autoreleasepool {
            ckrequire(!NSThread.isMainThread,"installation fixture executes on a real background thread");
            work();dispatch_semaphore_signal(complete);
        }
    });
    ckrequire(dispatch_semaphore_wait(complete,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))==0,
        "bounded background installation fixture completes");
}
@interface AxsCacheKeeperIdentityProxy : NSObject
@property(nonatomic,strong) id applicationType,applicationIdentifier,bundleURL,localizedName,shortVersionString,dataContainerURL,groupContainerURLs,plugInKitPlugins;
@end
@implementation AxsCacheKeeperIdentityProxy
@end
static NSArray *ckregistrations;
@interface AxsCacheKeeperIdentityWorkspace : NSObject
+ (id)defaultWorkspace;
- (id)allInstalledApplications;
@end
@implementation AxsCacheKeeperIdentityWorkspace
+ (id)defaultWorkspace {return [self new];}
- (id)allInstalledApplications {return ckregistrations;}
@end
static Class ckclass(NSString *name) {return [name isEqual:@"LSApplicationWorkspace"] ? AxsCacheKeeperIdentityWorkspace.class : NSClassFromString(name);}
static BOOL ckreplaceDuringRead;
static NSString *ckreplacementPath;
static NSData *ckreplacementBytes;
static ssize_t ckpread(int fd,void *buffer,size_t length,off_t offset) {
    ssize_t count=pread(fd,buffer,length,offset);
    if (ckreplaceDuringRead && !offset) {
        ckreplaceDuringRead=NO;
        ckrequire([ckreplacementBytes writeToFile:ckreplacementPath atomically:YES],"replace actual executable after FD read");
    }
    return count;
}
#define NSClassFromString ckclass
#define pread ckpread
#import "../AxsCacheKeeperInstallation.m"
#undef NSClassFromString
#undef pread

static NSMutableData *ckimage(void) {
    struct mach_header_64 header={.magic=MH_MAGIC_64,.cputype=CPU_TYPE_ARM64,.cpusubtype=CPU_SUBTYPE_ARM64_ALL,.filetype=MH_EXECUTE,.ncmds=1,.sizeofcmds=sizeof(struct uuid_command)};
    struct uuid_command uuid={.cmd=LC_UUID,.cmdsize=sizeof(uuid)};memset(uuid.uuid,0xab,16);
    NSMutableData *data=[NSMutableData dataWithBytes:&header length:sizeof(header)];[data appendBytes:&uuid length:sizeof(uuid)];return data;
}
static NSData *ckfat(BOOL ambiguous) {
    NSUInteger count=ambiguous ? 2 : 1;NSMutableData *data=[NSMutableData dataWithLength:128+ckimage().length*count];
    struct fat_header header={OSSwapHostToBigInt32(FAT_MAGIC),OSSwapHostToBigInt32((uint32_t)count)};memcpy(data.mutableBytes,&header,sizeof(header));
    for (NSUInteger i=0;i<count;i++) {
        struct fat_arch arch={OSSwapHostToBigInt32(CPU_TYPE_ARM64),OSSwapHostToBigInt32(CPU_SUBTYPE_ARM64_ALL),OSSwapHostToBigInt32((uint32_t)(128+i*ckimage().length)),OSSwapHostToBigInt32((uint32_t)ckimage().length),0};
        memcpy((unsigned char *)data.mutableBytes+sizeof(header)+i*sizeof(arch),&arch,sizeof(arch));
        memcpy((unsigned char *)data.mutableBytes+128+i*ckimage().length,ckimage().bytes,ckimage().length);
    }return data;
}
static NSMutableData *ckfat64(void) {
    NSMutableData *data=[NSMutableData dataWithLength:128+ckimage().length];
    struct fat_header header={OSSwapHostToBigInt32(FAT_MAGIC_64),OSSwapHostToBigInt32(1)};
    struct fat_arch_64 arch={.cputype=(cpu_type_t)OSSwapHostToBigInt32(CPU_TYPE_ARM64),
        .cpusubtype=(cpu_subtype_t)OSSwapHostToBigInt32(CPU_SUBTYPE_ARM64_ALL),
        .offset=OSSwapHostToBigInt64(128),.size=OSSwapHostToBigInt64(ckimage().length),.align=0,.reserved=0};
    memcpy(data.mutableBytes,&header,sizeof(header));memcpy((unsigned char *)data.mutableBytes+sizeof(header),&arch,sizeof(arch));
    memcpy((unsigned char *)data.mutableBytes+128,ckimage().bytes,ckimage().length);return data;
}
static NSString *ckbundle(NSString *folder,NSString *bundle,NSData *executable,NSString *version) {
    NSString *path=[folder stringByAppendingPathComponent:[bundle stringByAppendingString:@".app"]];
    ckrequire([NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil],"create owned bundle fixture");
    ckrequire([@{@"CFBundleIdentifier":bundle,@"CFBundleExecutable":@"Fixture",@"CFBundleShortVersionString":version,@"CFBundleVersion":version} writeToFile:[path stringByAppendingPathComponent:@"Info.plist"] atomically:YES],"write real installation metadata");
    ckrequire([executable writeToFile:[path stringByAppendingPathComponent:@"Fixture"] atomically:YES],"write real executable header fixture");return path;
}
static AxsCacheKeeperIdentityProxy *ckproxy(NSString *bundle,NSString *path) {
    AxsCacheKeeperIdentityProxy *proxy=[AxsCacheKeeperIdentityProxy new];proxy.applicationType=@"User";proxy.applicationIdentifier=bundle;
    proxy.bundleURL=[NSURL fileURLWithPath:path];proxy.localizedName=@"Fixture";proxy.shortVersionString=@"1";proxy.groupContainerURLs=@{};proxy.plugInKitPlugins=@[];return proxy;
}
static NSDictionary *ckentry(NSDictionary *registry,NSString *bundle) {for (NSDictionary *entry in registry[@"entries"]) if ([entry[@"bundle"] isEqual:bundle]) return entry;return nil;}
static void ckscope_counter_rejections(NSDictionary *registry) {
    for (NSNumber *invalid in @[@YES,@1.5,@(NAN),@(INFINITY),@4097,@(-1)]) {
        for (NSUInteger field=0;field<3;field++) {
            NSMutableDictionary *injected=[registry mutableCopy],*scope=[registry[@"scopeObservation"] mutableCopy];
            if (!field) scope[@"schemaVersion"]=invalid;
            else {
                NSString *key=field==1 ? @"scopes" : @"accesses";
                NSMutableArray *rows=[scope[key] mutableCopy];NSUInteger index=0;
                if (field==2) while (index<rows.count && ![rows[index][@"state"] isEqual:@"observed"]) index++;
                ckrequire(index<rows.count,"real root fixture provides an observed scope counter");
                NSMutableDictionary *row=[rows[index] mutableCopy];row[field==1 ? @"index" : @"scope"]=invalid;
                rows[index]=row;scope[key]=rows;
            }
            injected[@"scopeObservation"]=scope;
            ckrequire([axs_cachekeeper_registry_inventory_projection(injected)[@"state"] isEqual:@"invalid"],
                "scope counters reject booleans, fractions, nonfinite, negative and out-of-range values");
        }
    }
    NSDictionary *empty=@{@"schemaVersion":@1,@"state":@"complete",@"identityBasis":@"rootDeviceInodeAtObservation",
        @"scopeLifetime":@"thisInventoryOnly",@"deletionAuthorization":@"notGranted",@"accesses":@[],@"scopes":@[]};
    ckrequire(axs_cachekeeper_container_scope_projection(empty,[NSSet set],@{})!=nil,"empty complete scope remains valid");
    NSMutableDictionary *contradictory=[empty mutableCopy];contradictory[@"state"]=@"partial";
    ckrequire(!axs_cachekeeper_container_scope_projection(contradictory,[NSSet set],@{}),"scope state agrees with actual access coverage");
}
int main(int argc,const char *argv[]) {@autoreleasepool {
    ckrequire(argc==2,"owned fixture folder required");NSString *folder=@(argv[1]);
    NSString *alphaPath=ckbundle(folder,@"test.identity.alpha",ckimage(),@"1"),*betaPath=ckbundle(folder,@"test.identity.beta",ckimage(),@"1");
    __block NSDictionary *observation=nil;ckbackground(^{
        NSDictionary *snapshot=axs_cachekeeper_installation_snapshot([NSURL fileURLWithPath:alphaPath],@"test.identity.alpha",@"1",nil);
        observation=axs_cachekeeper_installation_image_observation(snapshot,[NSURL fileURLWithPath:alphaPath],@"1",CPU_TYPE_ARM64,CPU_SUBTYPE_ARM64_ALL);
    });
    ckrequire([observation[@"state"] isEqual:@"observed"] && [observation[@"container"] isEqual:@"thin"] &&
        [observation[@"mappingBackingIdentity"] isEqual:@"notVerified"],"safe FD metadata does not authenticate mapping backing");
    ckrequire([axs_cachekeeper_installation_image_observation(nil,nil,nil,0,0)[@"reason"] isEqual:@"mainThread"],"main thread does not read executable metadata");
    ckbackground(^{
        NSDictionary *snapshot=axs_cachekeeper_installation_snapshot([NSURL fileURLWithPath:alphaPath],@"test.identity.alpha",@"1",nil);
        ckreplacementPath=[alphaPath stringByAppendingPathComponent:@"Fixture"];ckreplacementBytes=ckimage();ckreplaceDuringRead=YES;
        observation=axs_cachekeeper_installation_image_observation(snapshot,[NSURL fileURLWithPath:alphaPath],@"1",CPU_TYPE_ARM64,CPU_SUBTYPE_ARM64_ALL);
    });
    ckrequire([observation[@"reason"] isEqual:@"changed"],"real replacement during FD metadata read cannot preserve installation binding");
    for (NSUInteger i=0;i<2;i++) {
        ckbundle(folder,@"test.identity.alpha",ckfat(i!=0),@"1");
        ckbackground(^{
            NSDictionary *snapshot=axs_cachekeeper_installation_snapshot([NSURL fileURLWithPath:alphaPath],@"test.identity.alpha",@"1",nil);
            observation=axs_cachekeeper_installation_image_observation(snapshot,[NSURL fileURLWithPath:alphaPath],@"1",CPU_TYPE_ARM64,CPU_SUBTYPE_ARM64_ALL);
        });
        ckrequire(i ? [observation[@"reason"] isEqual:@"ambiguous"] : [observation[@"container"] isEqual:@"fat32"],"fat selection requires exactly one nonoverlapping architecture");
    }
    NSMutableData *outOfBounds=ckfat64();struct fat_arch_64 *fat64=(struct fat_arch_64 *)((unsigned char *)outOfBounds.mutableBytes+sizeof(struct fat_header));
    fat64->size=OSSwapHostToBigInt64(UINT64_MAX);
    NSMutableData *reserved=ckfat64();((struct fat_arch_64 *)((unsigned char *)reserved.mutableBytes+sizeof(struct fat_header)))->reserved=1;
    NSMutableData *overlap=[ckfat(YES) mutableCopy];struct fat_arch *fat32=(struct fat_arch *)((unsigned char *)overlap.mutableBytes+sizeof(struct fat_header));
    fat32[1].offset=fat32[0].offset;
    NSMutableData *misaligned=ckfat64();((struct fat_arch_64 *)((unsigned char *)misaligned.mutableBytes+sizeof(struct fat_header)))->align=OSSwapHostToBigInt32(8);
    NSMutableData *wrongCPU=ckimage();((struct mach_header_64 *)wrongCPU.mutableBytes)->cputype=CPU_TYPE_X86_64;
    NSMutableData *badCommand=ckimage();((struct uuid_command *)((unsigned char *)badCommand.mutableBytes+sizeof(struct mach_header_64)))->cmdsize=7;
    NSMutableData *excessCommands=ckimage();((struct mach_header_64 *)excessCommands.mutableBytes)->sizeofcmds=65537;
    for (NSArray *fixture in @[@[ckfat64(),@"observed",@"none"],@[outOfBounds,@"notVerified",@"invalid"],
        @[reserved,@"notVerified",@"invalid"],@[overlap,@"notVerified",@"invalid"],@[misaligned,@"notVerified",@"invalid"],
        @[wrongCPU,@"notVerified",@"architecture"],@[badCommand,@"notVerified",@"invalid"],@[excessCommands,@"notVerified",@"invalid"]]) {
        ckbundle(folder,@"test.identity.alpha",fixture[0],@"1");
        ckbackground(^{
            NSDictionary *snapshot=axs_cachekeeper_installation_snapshot([NSURL fileURLWithPath:alphaPath],@"test.identity.alpha",@"1",nil);
            observation=axs_cachekeeper_installation_image_observation(snapshot,[NSURL fileURLWithPath:alphaPath],@"1",CPU_TYPE_ARM64,CPU_SUBTYPE_ARM64_ALL);
        });
        ckrequire([observation[@"state"] isEqual:fixture[1]] && [observation[@"reason"] isEqual:fixture[2]],"real disk fat64/bounds/overlap/CPU/command fixture uses strict production parser");
        if ([observation[@"state"] isEqual:@"observed"]) ckrequire([observation[@"container"] isEqual:@"fat64"],"actual fat64 slice metadata is observed");
    }
    ckbundle(folder,@"test.identity.alpha",ckimage(),@"1");
    NSString *real=[folder stringByAppendingPathComponent:@"private-owner-canary"],*shared=[real stringByAppendingPathComponent:@"shared"];
    ckrequire([NSFileManager.defaultManager createDirectoryAtPath:shared withIntermediateDirectories:YES attributes:nil error:nil],"create actual shared root");
    NSString *alias=[folder stringByAppendingPathComponent:@"alias-canary"];
    ckrequire([NSFileManager.defaultManager createSymbolicLinkAtPath:alias withDestinationPath:real error:nil],"create parent alias fixture");
    AxsCacheKeeperIdentityProxy *alpha=ckproxy(@"test.identity.alpha",alphaPath),*beta=ckproxy(@"test.identity.beta",betaPath);
    alpha.dataContainerURL=[NSURL fileURLWithPath:shared];alpha.groupContainerURLs=@{@"private-group-canary":[NSURL fileURLWithPath:shared]};
    beta.groupContainerURLs=@{@"private-group-canary":[NSURL fileURLWithPath:[alias stringByAppendingPathComponent:@"shared"]],@"private-missing-canary":[NSURL fileURLWithPath:[folder stringByAppendingPathComponent:@"missing"]]};
    ckregistrations=@[alpha,beta];NSMutableDictionary *cache=[NSMutableDictionary new];NSDictionary *registry=nil;
    axs_cachekeeper_installed_applications_with_registry_inventory(cache,NULL,&registry,nil);
    ckrequire([ckentry(registry,@"test.identity.alpha")[@"incrementalState"] isEqual:@"firstObserved"],"first installation observation is explicit");
    NSArray *scopes=registry[@"scopeObservation"][@"scopes"];
    ckrequire(scopes.count==1 && [scopes[0][@"tokens"] count]==2 && [scopes[0][@"owners"] count]==2,"real root inode merges parent aliases and preserves both owners");
    ckrequire([registry[@"scopeObservation"][@"state"] isEqual:@"partial"] &&
        [ckentry(registry,@"test.identity.beta")[@"relationships"][@"home"][@"state"] isEqual:@"notProvided"],"missing access and no home do not hide existing group root");
    BOOL missing=NO;for (NSDictionary *row in registry[@"scopeObservation"][@"accesses"]) missing|=[row[@"state"] isEqual:@"missing"];
    ckrequire(missing,"registered missing directory is not falsely accessible");
    ckscope_counter_rejections(registry);
    NSMutableDictionary *injected=[registry mutableCopy];NSMutableDictionary *scope=[registry[@"scopeObservation"] mutableCopy];
    scope[@"rawPath"]=shared;injected[@"scopeObservation"]=scope;
    ckrequire([axs_cachekeeper_registry_inventory_projection(injected)[@"state"] isEqual:@"invalid"],"unknown nested root identity fields fail closed");
    NSString *finalLink=[folder stringByAppendingPathComponent:@"final-link-canary"];
    ckrequire([NSFileManager.defaultManager createSymbolicLinkAtPath:finalLink withDestinationPath:shared error:nil],"create unsafe final-link fixture");
    beta.groupContainerURLs=@{@"private-group-canary":[NSURL fileURLWithPath:finalLink]};
    axs_cachekeeper_installed_applications_with_registry_inventory(cache,NULL,&registry,nil);
    BOOL rejectedLink=NO;for (NSDictionary *row in registry[@"scopeObservation"][@"accesses"]) rejectedLink|=[row[@"state"] isEqual:@"invalidRoot"];
    ckrequire(rejectedLink,"final symlink is refused despite a registered URL");
    beta.groupContainerURLs=@{@"private-group-canary":[NSURL fileURLWithPath:[alias stringByAppendingPathComponent:@"shared"]]};
    axs_cachekeeper_installed_applications_with_registry_inventory(cache,NULL,&registry,nil);
    ckrequire([ckentry(registry,@"test.identity.alpha")[@"incrementalState"] isEqual:@"unchanged"],"unchanged installation reuses validated snapshot");
    ckbundle(folder,@"test.identity.alpha",ckimage(),@"2");alpha.shortVersionString=@"2";
    axs_cachekeeper_installed_applications_with_registry_inventory(cache,NULL,&registry,nil);
    ckrequire([ckentry(registry,@"test.identity.alpha")[@"incrementalState"] isEqual:@"revalidated"],"updated installation recollects metadata");
    ckbundle(folder,@"test.identity.alpha",ckimage(),@"3");
    axs_cachekeeper_installed_applications_with_registry_inventory(cache,NULL,&registry,nil);
    ckrequire([ckentry(registry,@"test.identity.alpha")[@"incrementalState"] isEqual:@"invalidated"] && !cache[@"test.identity.alpha"][@"installation"],"failed updated installation revokes old identity");
    ckregistrations=@[beta];axs_cachekeeper_installed_applications_with_registry_inventory(cache,NULL,&registry,nil);
    ckrequire(!cache[@"test.identity.alpha"] && [registry[@"removedFromProviderCacheCount"] isEqual:@1],"provider removal evicts old identity without calling old receipt current");
    NSData *json=[NSJSONSerialization dataWithJSONObject:registry options:0 error:nil];NSString *text=[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    for (NSString *canary in @[@"private-owner-canary",@"alias-canary",@"private-group-canary",@"private-missing-canary",folder])
        ckrequire(![text containsString:canary],"registry source closure hides all raw paths, identifiers and inode keys");
    puts("PASS: image installation thin/fat, actual roots, aliases, owners and incrementality");return 0;
}}
