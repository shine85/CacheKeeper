#import <Foundation/Foundation.h>
#import <objc/runtime.h>
static unsigned ckgateMethodLists;
static Method *ckgateCopyMethodList(Class owner,unsigned *count) {ckgateMethodLists++;return class_copyMethodList(owner,count);}
#define class_copyMethodList ckgateCopyMethodList
#import "../AxsCacheKeeperImageRuntimeSource.h"
#undef class_copyMethodList
#import "../AxsCacheKeeperInstallationImageObservation.h"
#include <stdio.h>

static void ckcheck(BOOL condition,const char *message) {
    if (!condition) {fprintf(stderr,"FAIL: image source observation: %s\n",message);exit(1);}
}
typedef struct {NSData *data;NSUInteger reads;BOOL change,unreadable;} AxsCacheKeeperObservationFixture;
static BOOL ckread(uintptr_t address,void *out,size_t length,void *opaque) {
    AxsCacheKeeperObservationFixture *fixture=opaque;fixture->reads++;
    if (fixture->unreadable || address>fixture->data.length || length>fixture->data.length-address) return NO;
    memcpy(out,(const unsigned char *)fixture->data.bytes+address,length);
    if (fixture->change && fixture->reads==3 && length) ((unsigned char *)out)[length-1]^=1;
    return YES;
}
static NSMutableData *ckmacho(NSUInteger uuidCount) {
    struct mach_header_64 header={.magic=MH_MAGIC_64,.cputype=CPU_TYPE_ARM64,.cpusubtype=CPU_SUBTYPE_ARM64_ALL,.filetype=MH_EXECUTE,
        .ncmds=(uint32_t)uuidCount,.sizeofcmds=(uint32_t)(uuidCount*sizeof(struct uuid_command))};
    NSMutableData *data=[NSMutableData dataWithBytes:&header length:sizeof(header)];
    for (NSUInteger i=0;i<uuidCount;i++) {struct uuid_command uuid={.cmd=LC_UUID,.cmdsize=sizeof(uuid)};memset(uuid.uuid,0xab,16);[data appendBytes:&uuid length:sizeof(uuid)];}
    return data;
}
static NSUInteger ckresolved,ckinitialized,ckbusiness;
@interface AxsCacheKeeperObservationParent : NSObject
- (id)diskCache;
@end
@implementation AxsCacheKeeperObservationParent
- (id)diskCache {ckbusiness++;return nil;}
@end
@interface AxsCacheKeeperObservationCanary : AxsCacheKeeperObservationParent
- (id)initWithNamespace:(id)n diskCacheDirectory:(id)d config:(id)c;
@end
@implementation AxsCacheKeeperObservationCanary
+ (void)initialize {ckinitialized++;}
+ (BOOL)resolveInstanceMethod:(SEL)s {(void)s;ckresolved++;return NO;}
- (id)initWithNamespace:(id)n diskCacheDirectory:(id)d config:(id)c {(void)n;(void)d;(void)c;ckbusiness++;return self;}
@end
static id ckwrapper(id object,SEL selector,id namespace,id directory,id config) {
    (void)selector;(void)namespace;(void)directory;(void)config;ckbusiness++;return object;
}

// A rejected gate must preserve the first cause; diagnostics never decide admission.
static Method ckown(Class owner,SEL selector) {
    unsigned count=0;Method *methods=class_copyMethodList(owner,&count);Method found=NULL;
    for (unsigned i=0;i<count;i++) if (method_getName(methods[i])==selector) {found=methods[i];break;}
    free(methods);return found;
}
static NSUInteger ckgateInitialized,ckgateResolved,ckgateBusiness;
static IMP ckgateBefore;
static id ckchanged(id owner,SEL selector) {(void)selector;return owner;}
@interface AxsCacheKeeperGateCanary : NSObject
- (id)axs_cachekeeper_value;
@end
@implementation AxsCacheKeeperGateCanary
+ (void)initialize {ckgateInitialized++;method_setImplementation(ckown(self,sel_registerName("axs_cachekeeper_value")),(IMP)ckchanged);}
+ (BOOL)resolveInstanceMethod:(SEL)s {(void)s;ckgateResolved++;return NO;}
- (id)axs_cachekeeper_value {ckgateBusiness++;return self;}
@end
static NSMutableArray *ckgateRecords(Class owner,SEL selector,IMP expected) {
    NSDictionary *record=@{@"class":owner,@"selector":NSStringFromSelector(selector),@"implementation":[NSValue valueWithPointer:(const void *)expected]};
    NSMutableArray *records=[NSMutableArray new];for (NSUInteger i=0;i<25;i++) [records addObject:record];return records;
}
static void ckgate(void) {
    Class owner=objc_getClass("AxsCacheKeeperGateCanary");SEL selector=sel_registerName("axs_cachekeeper_value");
    Method method=ckown(owner,selector);ckgateBefore=method_getImplementation(method);
    NSMutableArray *records=ckgateRecords(owner,selector,ckgateBefore);
    NSDictionary *result=AxsCacheKeeperImageMethodsCheck(records,4,^NSDictionary *{abort();},AxsCacheKeeperImageLegacyCodeAddress,YES);
    ckcheck([result[@"cause"] isEqual:@"installationOriginal"] && [result[@"methodIndex"] isEqual:@4] && !ckgateInitialized,"installation failure short-circuits all helper and runtime reads");
    NSDictionary *helper=@{@"schemaVersion":@1,@"accepted":@NO,@"stage":@"helperWindow",@"reason":@"digest",@"methodIndex":@0,@"helperIndex":@2};
    result=AxsCacheKeeperImageMethodsCheck(records,0,^NSDictionary *{return helper;},AxsCacheKeeperImageLegacyCodeAddress,YES);
    ckcheck([result[@"cause"] isEqual:@"legacyHelper"] && [result[@"helperStage"] isEqual:@"helperWindow"] && [result[@"helperReason"] isEqual:@"digest"] && [result[@"helperIndex"] isEqual:@2] && !ckgateInitialized,"helper failure preserves stage reason and index before method lookup");
    ckgateMethodLists=0;
    result=AxsCacheKeeperImageMethodsCheck(records,0,nil,AxsCacheKeeperImageLegacyCodeAddress,YES);
    ckcheck([result[@"cause"] isEqual:@"implementation"] && [result[@"methodIndex"] isEqual:@1] && ![result[@"accepted"] boolValue],"initialize swizzle cannot become a new baseline");
    ckcheck(ckgateMethodLists==2,"one owner snapshot and failing owner reread");

    ckcheck([result[@"methodRawMatchesStoredBefore"] boolValue] && ![result[@"methodRawMatchesStoredAfter"] boolValue] && ![result[@"classRawMatchesStored"] boolValue] && ![result[@"methodIMPStable"] boolValue] && [result[@"methodIdentityStable"] boolValue],"single lookup captures before and after initialization relation");
    ckcheck(ckgateInitialized==1 && !ckgateResolved && !ckgateBusiness,"diagnostics do not resolve or call business methods");
    ckcheck(axs_cachekeeper_image_methods_check_projection(result)!=nil,"closed implementation diagnostic projects");
    NSMutableDictionary *canonical=[result mutableCopy];canonical[@"classCanonicalMatchesStored"]=@YES;
    ckcheck(axs_cachekeeper_image_methods_check_projection(canonical)!=nil && ![canonical[@"accepted"] boolValue],"canonical equality is diagnostic and does not authorize raw mismatch");
    for (NSString *key in @[@"methodPresentBefore",@"methodIdentityStable",@"methodRawMatchesStoredBefore",@"classCanonicalMatchesStored"]) {
        NSMutableDictionary *wrong=[result mutableCopy];wrong[key]=@1;ckcheck(!axs_cachekeeper_image_methods_check_projection(wrong),"relation flags require actual booleans");
    }

    NSMutableDictionary *inconsistent=[result mutableCopy];inconsistent[@"methodIMPStable"]=@YES;
    ckcheck(!axs_cachekeeper_image_methods_check_projection(inconsistent),"stable IMP cannot contradict before and after raw relations");
    inconsistent=[result mutableCopy];inconsistent[@"relationState"]=@"notCollected";
    ckcheck(!axs_cachekeeper_image_methods_check_projection(inconsistent),"not collected state rejects populated relation data");
    NSMutableDictionary *bad=[result mutableCopy];bad[@"address"]=@"0x1234";ckcheck(!axs_cachekeeper_image_methods_check_projection(bad),"gate projection rejects unknown pointer fields");
    bad=[result mutableCopy];bad[@"classRawMatchesStored"]=@YES;ckcheck(!axs_cachekeeper_image_methods_check_projection(bad),"rejection cannot claim raw class equality");

    records[10]=@{@"class":owner,@"selector":@"missingObservationGate",@"absent":@YES};
    NSDictionary *rejectedBeforeMissing=AxsCacheKeeperImageMethodsCheck(records,0,nil,AxsCacheKeeperImageLegacyCodeAddress,YES);
    ckcheck([rejectedBeforeMissing[@"methodIndex"] isEqual:@1] && !ckgateResolved,"first rejection stops before later absent-slot resolver");
    records=ckgateRecords(owner,selector,ckgateBefore);
    method_setImplementation(method,ckgateBefore);
    ckgateMethodLists=0;
    result=AxsCacheKeeperImageMethodsCheck(records,0,nil,AxsCacheKeeperImageLegacyCodeAddress,NO);
    ckcheck([result[@"accepted"] boolValue] && ckgateMethodLists==0,"ordinary raw gate performs no method-list diagnostics");
    ckgateMethodLists=0;
    result=AxsCacheKeeperImageMethodsCheck(records,0,nil,AxsCacheKeeperImageLegacyCodeAddress,YES);
    ckcheck(ckgateMethodLists==1,"diagnostic gate enumerates each owner once");
    Class other=objc_getClass("AxsCacheKeeperObservationParent");SEL otherSelector=sel_registerName("diskCache");
    class_getMethodImplementation(other,otherSelector);IMP otherIMP=method_getImplementation(ckown(other,otherSelector));
    records[24]=@{@"class":other,@"selector":@"diskCache",@"implementation":[NSValue valueWithPointer:(const void *)otherIMP]};
    ckgateMethodLists=0;NSDictionary *multiple=AxsCacheKeeperImageMethodsCheck(records,0,nil,AxsCacheKeeperImageLegacyCodeAddress,YES);
    ckcheck([multiple[@"accepted"] boolValue] && ckgateMethodLists==2,"each distinct diagnostic owner is enumerated once");
    records=ckgateRecords(owner,selector,ckgateBefore);

    ckcheck([result[@"accepted"] boolValue] && [result[@"cause"] isEqual:@"complete"],"restored method matches original baseline");
    [records removeLastObject];result=AxsCacheKeeperImageMethodsCheck(records,0,nil,AxsCacheKeeperImageLegacyCodeAddress,YES);
    ckcheck([result[@"cause"] isEqual:@"methodCount"] && [result[@"methodsCount"] isEqual:@24] && [result[@"methodIndex"] isEqual:@0],"incomplete method table has an explicit cause");
    records=ckgateRecords(owner,selector,ckgateBefore);records[10]=@{@"class":owner,@"selector":NSStringFromSelector(selector),@"absent":@YES};
    result=AxsCacheKeeperImageMethodsCheck(records,0,nil,AxsCacheKeeperImageLegacyCodeAddress,YES);
    ckcheck([result[@"cause"] isEqual:@"unexpectedMethod"] && [result[@"methodIndex"] isEqual:@11],"absent contract slot appearing is rejected");
    NSData *data=[NSJSONSerialization dataWithJSONObject:result options:0 error:nil];NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    for (NSString *canary in @[@"AxsCacheKeeperGateCanary",@"axs_cachekeeper_value",@"address",@"0x",@"/private/"]) ckcheck(![text containsString:canary],"gate diagnostic exports no class selector pointer or path");
}

static void ckparser(void) {
    AxsCacheKeeperObservationFixture fixture={.data=ckmacho(1)};
    NSDictionary *value=AxsCacheKeeperImageMachOObservation(0,ckread,&fixture);
    ckcheck([value[@"state"] isEqual:@"complete"] && [value[@"uuid"] isEqual:@"abababababababababababababababab"],"unique UUID parses from real bytes");
    fixture.data=ckmacho(0);fixture.reads=0;
    ckcheck([AxsCacheKeeperImageMachOObservation(0,ckread,&fixture)[@"state"] isEqual:@"missingUUID"],"missing UUID is unresolved, not unequal");
    fixture.data=ckmacho(2);fixture.reads=0;
    ckcheck([AxsCacheKeeperImageMachOObservation(0,ckread,&fixture)[@"state"] isEqual:@"invalid"],"duplicate UUID is rejected");
    NSMutableData *bad=ckmacho(1);((struct uuid_command *)((unsigned char *)bad.mutableBytes+sizeof(struct mach_header_64)))->cmdsize=7;
    fixture.data=bad;fixture.reads=0;
    ckcheck([AxsCacheKeeperImageMachOObservation(0,ckread,&fixture)[@"state"] isEqual:@"invalid"],"misaligned command rejected");
    fixture.data=ckmacho(1);fixture.reads=0;fixture.change=YES;
    ckcheck([AxsCacheKeeperImageMachOObservation(0,ckread,&fixture)[@"state"] isEqual:@"changed"],"second exact metadata read detects change");
    fixture.change=NO;fixture.unreadable=YES;
    ckcheck([AxsCacheKeeperImageMachOObservation(0,ckread,&fixture)[@"state"] isEqual:@"unreadable"],"reader failure remains explicit");
    const void *implementations[25];for (NSUInteger i=0;i<25;i++) implementations[i]=i==10 ? NULL : (const void *)(uintptr_t)(i+1);
    AxsCacheKeeperImageLegacyCheck rejected=AxsCacheKeeperImageLegacySourceCheck((const void *)(uintptr_t)1,implementations);
    ckcheck(!rejected.accepted && !strcmp(rejected.reason,"notMainBase"),"non-main source still rejects before any layout read");
}
static NSMutableDictionary *ckclosed(void) {
    NSDictionary *metadata=@{@"state":@"complete",@"cpuType":@(CPU_TYPE_ARM64),@"cpuSubtype":@(CPU_SUBTYPE_ARM64_ALL),@"fileType":@(MH_EXECUTE),@"uuid":@"abababababababababababababababab"};
    NSMutableArray *classes=[NSMutableArray new],*methods=[NSMutableArray new],*originals=[NSMutableArray new];
    for (NSUInteger i=0;i<5;i++) [classes addObject:@{@"index":@(i+1),@"present":@NO,@"nameState":@"unavailable",@"module":@0}];
    for (NSUInteger i=0;i<27;i++) [methods addObject:@{@"index":@(i+1),@"state":@"missing",@"module":@0,@"wrapper":@"notCompared"}];
    for (NSUInteger i=0;i<4;i++) [originals addObject:@{@"index":@(i+1),@"present":@NO,@"module":@0,@"currentRelation":@"notCompared"}];
    return [@{@"schemaVersion":@1,@"state":@"complete",@"dyldState":@"complete",@"observedDyldImages":@1,@"observedMethods":@0,
        @"modules":@[@{@"index":@1,@"metadata":metadata,@"dyldMatches":@1,@"dyldIndex":@0,@"contractUUIDRelation":@"different"}],
        @"classes":classes,@"methods":methods,@"originals":originals,@"mainModule":@1,@"candidateModule":@0,@"initializerUsesSavedOriginal":@NO,@"mappingBackingIdentity":@"notVerified"} mutableCopy];
}
static void ckclosure(void) {
    NSMutableDictionary *value=ckclosed();ckcheck(axs_cachekeeper_image_runtime_observation_projection(value)!=nil,"closed complete metadata baseline");
    for (NSString *state in @[@"partial",@"changed"]) {
        value=ckclosed();value[@"dyldState"]=state;
        ckcheck(!axs_cachekeeper_image_runtime_observation_projection(value),"complete cannot contradict a partial/changed loader view");
        value[@"state"]=@"partial";ckcheck(axs_cachekeeper_image_runtime_observation_projection(value)!=nil,"honest partial loader view remains valid");
    }
    value=ckclosed();NSMutableArray *rows=[value[@"methods"] mutableCopy];NSMutableDictionary *row=[rows[3] mutableCopy];row[@"state"]=@"partial";rows[3]=row;value[@"methods"]=rows;
    ckcheck(!axs_cachekeeper_image_runtime_observation_projection(value),"partial method cannot claim complete sampling");
    value[@"state"]=@"partial";ckcheck(axs_cachekeeper_image_runtime_observation_projection(value)!=nil,"bounded partial method is retained");
    value=ckclosed();NSMutableDictionary *module=[value[@"modules"][0] mutableCopy];module[@"metadata"]=@{@"state":@"invalid"};module[@"contractUUIDRelation"]=@"notResolved";value[@"modules"]=@[module];
    ckcheck(!axs_cachekeeper_image_runtime_observation_projection(value),"invalid module metadata cannot claim complete sampling");
    value[@"state"]=@"partial";ckcheck(axs_cachekeeper_image_runtime_observation_projection(value)!=nil,"invalid metadata remains explicit in partial sampling");
    value=ckclosed();module=[value[@"modules"][0] mutableCopy];module[@"dyldMatches"]=@2;[module removeObjectForKey:@"dyldIndex"];value[@"modules"]=@[module];
    ckcheck(!axs_cachekeeper_image_runtime_observation_projection(value),"module matches cannot exceed the observed loader table");
    value=ckclosed();value[@"observedDyldImages"]=@2;module=[value[@"modules"][0] mutableCopy];module[@"dyldIndex"]=@1;value[@"modules"]=@[module];
    ckcheck(!axs_cachekeeper_image_runtime_observation_projection(value),"main module must refer to loader index zero");
    value[@"schemaVersion"]=@2;
    ckcheck(axs_cachekeeper_image_runtime_observation_projection(value)!=nil,"v2 executable may follow a launcher dylib");
    module=[module mutableCopy];NSMutableDictionary *metadata=[module[@"metadata"] mutableCopy];
    metadata[@"fileType"]=@(MH_DYLIB);module[@"metadata"]=metadata;value[@"modules"]=@[module];
    ckcheck(!axs_cachekeeper_image_runtime_observation_projection(value),"v2 main module cannot be a launcher dylib");
    for (NSString *failure in @[@"unreadable",@"invalid",@"changed"]) {
        value=ckclosed();value[@"schemaVersion"]=@2;value[@"state"]=@"partial";value[@"mainModule"]=@0;
        module=[value[@"modules"][0] mutableCopy];module[@"metadata"]=@{@"state":failure};module[@"contractUUIDRelation"]=@"notResolved";value[@"modules"]=@[module];
        ckcheck(axs_cachekeeper_image_runtime_observation_projection(value)!=nil,"v2 unresolved main retains explicit partial metadata failures");
        value[@"mainModule"]=@1;ckcheck(!axs_cachekeeper_image_runtime_observation_projection(value),"v2 metadata failure never authenticates executable identity");
    }
    for (NSUInteger unreadable=0;unreadable<2;unreadable++) {
        struct mach_header_64 invalid={0};const void *base=unreadable ? (const void *)(uintptr_t)1 : &invalid;
        NSMutableArray *collected=[NSMutableArray new];
        AxsCacheKeeperImageObservationContext context={.modules=collected,.deadline=NSProcessInfo.processInfo.systemUptime+1,.dyldCount=1};
        context.dyldHeaders[0]=base;
        ckcheck(!axs_cachekeeper_image_observation_main_module(&context,base) && context.partial && collected.count==1,
            "collector retains failed main metadata without authenticating it");
        value=ckclosed();value[@"schemaVersion"]=@2;value[@"state"]=@"partial";value[@"mainModule"]=@0;value[@"modules"]=collected;
        ckcheck(axs_cachekeeper_image_runtime_observation_projection(value)!=nil,"collector failures survive runtime projection");
    }
    value=ckclosed();rows=[value[@"methods"] mutableCopy];row=[rows[1] mutableCopy];row[@"state"]=@"own";row[@"module"]=@1;row[@"wrapper"]=@"matches";rows[1]=row;value[@"methods"]=rows;
    ckcheck(!axs_cachekeeper_image_runtime_observation_projection(value),"wrapper comparison is limited to four installed hook slots");
    value=ckclosed();rows=[value[@"originals"] mutableCopy];row=[rows[0] mutableCopy];row[@"present"]=@YES;row[@"module"]=@1;row[@"currentRelation"]=@"same";rows[0]=row;value[@"originals"]=rows;
    ckcheck(!axs_cachekeeper_image_runtime_observation_projection(value),"missing current method cannot claim saved original equality");
    value=ckclosed();module=[value[@"modules"][0] mutableCopy];module[@"index"]=@2;module[@"dyldMatches"]=@0;[module removeObjectForKey:@"dyldIndex"];value[@"modules"]=@[value[@"modules"][0],module];
    rows=[value[@"methods"] mutableCopy];row=[rows[0] mutableCopy];row[@"state"]=@"own";row[@"module"]=@1;rows[0]=row;value[@"methods"]=rows;value[@"candidateModule"]=@1;
    rows=[value[@"originals"] mutableCopy];row=[rows[0] mutableCopy];row[@"present"]=@YES;row[@"module"]=@2;row[@"currentRelation"]=@"same";rows[0]=row;value[@"originals"]=rows;
    ckcheck(!axs_cachekeeper_image_runtime_observation_projection(value),"equal IMP identity cannot contradict two known modules");
    value=ckclosed();NSDictionary *relation=@{@"schemaVersion":@1,@"installationImage":@{@"schemaVersion":@1,@"state":@"observed",@"reason":@"none",@"mappingBackingIdentity":@"notVerified",@"container":@"thin",@"metadata":value[@"modules"][0][@"metadata"]},
        @"mainUUIDRelation":@"same",@"candidateUUIDRelation":@"notCompared",@"mappingBackingIdentity":@"notVerified"};
    ckcheck(axs_cachekeeper_installed_runtime_relation_matches(relation,value),"same metadata is only an observed UUID relation");
    value[@"dyldState"]=@"changed";
    ckcheck(!axs_cachekeeper_installed_runtime_relation_matches(relation,value),"contradictory complete view cannot compare as same");
    value[@"state"]=@"partial";
    ckcheck(!axs_cachekeeper_installed_runtime_relation_matches(relation,value),"honest partial view does not claim a current UUID comparison");
    NSMutableDictionary *uncompared=[relation mutableCopy];uncompared[@"mainUUIDRelation"]=@"notCompared";
    ckcheck(axs_cachekeeper_installed_runtime_relation_matches(uncompared,value),"partial view keeps explicit unverified relation");
}
int main(void) {@autoreleasepool {
    ckgate();
    ckparser();ckclosure();
    Class __unsafe_unretained classes[5]={objc_getClass("AxsCacheKeeperObservationCanary"),Nil,Nil,Nil,Nil};
    AxsCacheKeeperImageObservationMethod specs[27]={0};
    for (NSUInteger i=0;i<27;i++) {specs[i].ownerIndex=0;specs[i].selector="missingObservationCanary";}
    specs[0].selector="initWithNamespace:diskCacheDirectory:config:";specs[1].selector="diskCache";
    const void *originals[4]={NULL},*wrappers[4]={NULL};
    NSDictionary *value=AxsCacheKeeperImageRuntimeObservation(classes,specs,originals,wrappers,NO);
    ckcheck(value && axs_cachekeeper_image_runtime_observation_projection(value),"production runtime schema is closed");
    ckcheck([value[@"methods"][0][@"state"] isEqual:@"own"] && [value[@"methods"][1][@"state"] isEqual:@"inherited"] &&
        [value[@"methods"][2][@"state"] isEqual:@"missing"],"own/inherited/missing metadata states");
    ckcheck(!ckresolved && !ckinitialized && !ckbusiness,"metadata collection does not resolve, initialize or call business methods");
    unsigned ownCount=0;Method *own=class_copyMethodList(classes[0],&ownCount);Method initializer=NULL;
    for (unsigned i=0;i<ownCount;i++) if (method_getName(own[i])==sel_registerName(specs[0].selector)) initializer=own[i];
    ckcheck(initializer!=NULL,"actual own initializer metadata found");free(own);
    IMP original=method_getImplementation(initializer);originals[0]=(const void *)original;
    NSDictionary *same=AxsCacheKeeperImageRuntimeObservation(classes,specs,originals,wrappers,YES);
    ckcheck([same[@"originals"][0][@"currentRelation"] isEqual:@"same"],"saved original identity is separately observed");
    method_setImplementation(initializer,(IMP)ckwrapper);wrappers[0]=(const void *)ckwrapper;
    NSDictionary *swizzled=AxsCacheKeeperImageRuntimeObservation(classes,specs,originals,wrappers,YES);
    ckcheck([swizzled[@"methods"][0][@"wrapper"] isEqual:@"matches"] && [swizzled[@"originals"][0][@"currentRelation"] isEqual:@"different"],"current wrapper and saved original remain distinct after real swizzle");
    method_setImplementation(initializer,original);
    ckcheck(!ckresolved && !ckinitialized && !ckbusiness,"real swizzle observation still performs no business calls");
    NSMutableDictionary *bad=[value mutableCopy];bad[@"rawPath"]=@"/private/observation-canary";
    ckcheck(!axs_cachekeeper_image_runtime_observation_projection(bad),"unknown top-level metadata cannot leak");
    NSMutableArray *modules=[value[@"modules"] mutableCopy];NSMutableDictionary *module=[modules[0] mutableCopy];
    module[@"address"]=@"0x1234";modules[0]=module;bad=[value mutableCopy];bad[@"modules"]=modules;
    ckcheck(!axs_cachekeeper_image_runtime_observation_projection(bad),"unknown nested address cannot leak");
    modules=[value[@"modules"] mutableCopy];modules[0]=@"private-module-canary";bad=[value mutableCopy];bad[@"modules"]=modules;
    ckcheck(!axs_cachekeeper_image_runtime_observation_projection(bad),"non-dictionary module rejects without messaging arbitrary values");
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    for (NSString *canary in @[@"AxsCacheKeeperObservationCanary",@"missingObservationCanary",@"/private/",@"rawPath",@"address",@"offset"])
        ckcheck(![text containsString:canary],"runtime projection emits no names, paths, addresses or offsets");
    puts("PASS: image source observation parser/runtime/privacy");return 0;
}}
