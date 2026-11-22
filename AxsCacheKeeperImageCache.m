#import "AxsCacheKeeperImageCache.h"
#import "AxsCacheKeeperImageEffectStatus.h"
#import "AxsCacheKeeperImageLegacySource.h"
#import "AxsCacheKeeperImageRuntimeSource.h"
#import "AxsCacheKeeperPolicy.h"
#import "AxsCacheKeeperCleanupRules.h"
#import <objc/runtime.h>
#import <objc/message.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <dirent.h>
#include <unistd.h>

static const void *AxsCacheKeeperImageBindingKey=&AxsCacheKeeperImageBindingKey;
static const void *AxsCacheKeeperImageQueueKey=&AxsCacheKeeperImageQueueKey;
static __weak AxsCacheKeeperImageCache *axs_cachekeeper_image_observer;
static id (*axs_cachekeeper_image_init_original)(id __attribute__((ns_consumed)),SEL,id,id,id) __attribute__((ns_returns_retained));
static IMP axs_cachekeeper_image_data_original,axs_cachekeeper_image_extended_original;
static IMP axs_cachekeeper_image_remove_original;
static Class axs_cachekeeper_image_class,axs_cachekeeper_disk_class,axs_cachekeeper_image_config_class,axs_cachekeeper_memory_class;
static NSArray<NSDictionary *> *axs_cachekeeper_image_methods;
static NSUInteger axs_cachekeeper_image_installation_failure_index;
static AxsCacheKeeperImageContract axs_cachekeeper_image_contract;
// Non-NULL only for the production fingerprint source captured at hook publication.
static const void *axs_cachekeeper_image_legacy_base;

static id AxsCacheKeeperImageGet(id object, const char *name) {
    return ((id (*)(id,SEL))objc_msgSend)(object,sel_registerName(name));
}
typedef struct {
    NSUInteger ownerIndex;
    BOOL classMethod;
    const char *selector;
    const char *result;
    NSUInteger argumentCount;
    const char *arguments[3];
} AxsCacheKeeperImageMethodSpec;
// The receipt's methodIndex is one-based in this stable contract order.
static const AxsCacheKeeperImageMethodSpec AxsCacheKeeperImageMethodSpecs[AxsCacheKeeperImageMethodCount]={
    {0,NO,"initWithNamespace:diskCacheDirectory:config:","@",3,{"@","@","@"}},
    {0,NO,"diskCache","@",0,{NULL,NULL,NULL}},
    {0,NO,"diskCachePath","@",0,{NULL,NULL,NULL}},
    {0,NO,"config","@",0,{NULL,NULL,NULL}},
    {0,NO,"ioQueue","@",0,{NULL,NULL,NULL}},
    {0,NO,"memoryCache","@",0,{NULL,NULL,NULL}},
    {1,NO,"diskCachePath","@",0,{NULL,NULL,NULL}},
    {1,NO,"config","@",0,{NULL,NULL,NULL}},
    {1,NO,"fileManager","@",0,{NULL,NULL,NULL}},
    {2,NO,"fileManager","@",0,{NULL,NULL,NULL}},
    {2,NO,"ioQueueAttributes","@",0,{NULL,NULL,NULL}},
    {2,NO,"diskCacheClass","#",0,{NULL,NULL,NULL}},
    {2,NO,"memoryCacheClass","#",0,{NULL,NULL,NULL}},
    {2,NO,"copyWithZone:","@",1,{@encode(NSZone *),NULL,NULL}},
    {2,YES,"defaultCacheConfig","@",0,{NULL,NULL,NULL}},
    {3,NO,"config","@",0,{NULL,NULL,NULL}},
    {3,NO,"initWithConfig:","@",1,{"@",NULL,NULL}},
    {3,NO,"commonInit","v",0,{NULL,NULL,NULL}},
    {1,NO,"initWithCachePath:config:","@",2,{"@","@",NULL}},
    {1,NO,"commonInit","v",0,{NULL,NULL,NULL}},
    {1,NO,"removeAllData","v",0,{NULL,NULL,NULL}},
    {1,NO,"cachePathForKey:","@",1,{"@",NULL,NULL}},
    {1,NO,"cachePathForKey:inPath:","@",2,{"@","@",NULL}},
    {1,NO,"setData:forKey:","v",2,{"@","@",NULL}},
    {1,NO,"setExtendedData:forKey:","v",2,{"@","@",NULL}},
};
static NSString *AxsCacheKeeperImageMethodFailure(Class cls, const AxsCacheKeeperImageMethodSpec *spec, const void *image, NSMutableArray *methods) {
    SEL sel=sel_registerName(spec->selector);Method method=class_getInstanceMethod(cls,sel);
    if (!method) return @"missingMethod";
    // All admitted selectors are implemented by the exact SDK class, never an inherited method.
    unsigned count=0;Method *list=class_copyMethodList(cls,&count);BOOL own=NO;
    for (unsigned i=0;i<count;i++) if (method_getName(list[i])==sel) {own=YES;break;}
    free(list);if (!own) return @"inheritedMethod";
    const char *encoding=method_getTypeEncoding(method);NSMethodSignature *signature=nil;
    if (!encoding) return @"signature";
    @try {signature=[NSMethodSignature signatureWithObjCTypes:encoding];}
    @catch (NSException *exception) {(void)exception;return @"signature";}
    if (!signature) return @"signature";
    if (strcmp(signature.methodReturnType,spec->result)) return @"returnType";
    if (signature.numberOfArguments!=spec->argumentCount+2) return @"argumentCount";
    for (NSUInteger i=0;i<spec->argumentCount;i++)
        if (strcmp([signature getArgumentTypeAtIndex:i+2],spec->arguments[i])) return @"argumentType";
    Dl_info info={0};IMP implementation=method_getImplementation(method);
    if (!dladdr(AxsCacheKeeperImageLegacyCodeAddress((const void *)implementation),&info) || info.dli_fbase!=image) return @"methodImage";
    [methods addObject:@{@"class":cls,@"selector":NSStringFromSelector(sel),@"implementation":[NSValue valueWithPointer:(const void *)implementation]}];
    return nil;
}
static NSDictionary *AxsCacheKeeperImageMethodsCheckSnapshot(BOOL captureRelations) {
    NSArray *methods;NSUInteger installationFailure;const void *legacyBase;
    @synchronized(AxsCacheKeeperImageCache.class) {
        methods=axs_cachekeeper_image_methods;installationFailure=axs_cachekeeper_image_installation_failure_index;
        legacyBase=axs_cachekeeper_image_legacy_base;
    }
    NSDictionary *(^helpers)(void)=nil;
    if (legacyBase) helpers=^NSDictionary *{
        AxsCacheKeeperImageLegacyLayout layout;
        AxsCacheKeeperImageLegacyCheck check=AxsCacheKeeperImageLegacyMainLayoutCheck(legacyBase,&layout);
        if (check.accepted) check=AxsCacheKeeperImageLegacyHelpersCheck(&layout);
        return @{@"schemaVersion":@1,@"accepted":check.accepted ? @YES : @NO,@"stage":@(check.stage),@"reason":@(check.reason),@"methodIndex":@(check.methodIndex),@"helperIndex":@(check.helperIndex)};
    };
    return AxsCacheKeeperImageMethodsCheck(methods,installationFailure,helpers,AxsCacheKeeperImageLegacyCodeAddress,captureRelations);
}
static BOOL AxsCacheKeeperImageMethodsUnchangedAtIndex(NSUInteger *changedIndex) {
    NSDictionary *check=AxsCacheKeeperImageMethodsCheckSnapshot(NO);
    if (changedIndex) *changedIndex=[check[@"methodIndex"] unsignedIntegerValue];
    return [check[@"accepted"] boolValue];
}
static BOOL AxsCacheKeeperImageMethodsUnchanged(void) {
    return AxsCacheKeeperImageMethodsUnchangedAtIndex(NULL);
}
static BOOL AxsCacheKeeperImageKnownUUID(const void *base) {
    const struct mach_header_64 *header=base;
    if (!header || header->magic!=MH_MAGIC_64 || header->sizeofcmds>1024*1024) return NO;
    const uint8_t *cursor=(const uint8_t *)(header+1),*end=cursor+header->sizeofcmds;
    for (uint32_t i=0;i<header->ncmds && cursor+sizeof(struct load_command)<=end;i++) {
        const struct load_command *command=(const struct load_command *)cursor;
        if (command->cmdsize<sizeof(*command) || cursor+command->cmdsize>end) return NO;
        if (command->cmd==LC_UUID && command->cmdsize>=sizeof(struct uuid_command)) {
            const uint8_t *bytes=((const struct uuid_command *)command)->uuid;
            NSMutableString *uuid=[NSMutableString new];for (NSUInteger n=0;n<16;n++) [uuid appendFormat:@"%02x",bytes[n]];
            return [@[@"09cd59491b343f699783df2203df4d6b",@"e1086dce261835c288c6cd0679d12ea5",@"bae1e24de9d43605a3cc24c3c5f9a309"] containsObject:uuid];
        }
        cursor+=command->cmdsize;
    }
    return NO;
}
static NSDictionary *AxsCacheKeeperImageSourceCheckValue(AxsCacheKeeperImageLegacyCheck check) {
    return axs_cachekeeper_image_source_check_projection(@{@"schemaVersion":@1,@"accepted":@(check.accepted),
        @"stage":[NSString stringWithUTF8String:check.stage],@"reason":[NSString stringWithUTF8String:check.reason],@"methodIndex":@(check.methodIndex),@"helperIndex":@(check.helperIndex)});
}
// Bounded metadata observation only. No image path, pointer, UUID or code leaves this function.
static BOOL AxsCacheKeeperImageReadObservedUUID(const void *base,unsigned char uuid[16]) {
    struct mach_header_64 header;
    if (!AxsCacheKeeperImageLegacyRead((uintptr_t)base,&header,sizeof(header),VM_PROT_READ) ||
        header.magic!=MH_MAGIC_64 || header.sizeofcmds>65536 || !header.ncmds || header.ncmds>header.sizeofcmds/sizeof(struct load_command)) return NO;
    size_t length=sizeof(header)+header.sizeofcmds;unsigned char *copy=malloc(length);if (!copy) return NO;
    BOOL valid=AxsCacheKeeperImageLegacyRead((uintptr_t)base,copy,length,VM_PROT_READ) && !memcmp(copy,&header,sizeof(header));
    size_t cursor=sizeof(header);NSUInteger found=0;
    for (uint32_t index=0;valid && index<header.ncmds;index++) {
        if (cursor>length || length-cursor<sizeof(struct load_command)) {valid=NO;break;}
        struct load_command *command=(void *)(copy+cursor);
        if (command->cmdsize<sizeof(*command) || command->cmdsize>length-cursor || command->cmdsize%8) {valid=NO;break;}
        if (command->cmd==LC_UUID) {
            if (command->cmdsize!=sizeof(struct uuid_command) || ++found!=1) {valid=NO;break;}
            memcpy(uuid,((struct uuid_command *)command)->uuid,16);
        }
        cursor+=command->cmdsize;
    }
    free(copy);return valid && cursor==length && found==1;
}
static BOOL AxsCacheKeeperImageObservedIMP(const void *implementation,const void *main,const unsigned char mainUUID[16],BOOL mainResolved,BOOL *isMain,BOOL *sameUUID) {
    *isMain=NO;*sameUUID=NO;Dl_info info={0};
    if (!implementation || !dladdr(AxsCacheKeeperImageLegacyCodeAddress(implementation),&info) || !info.dli_fbase) return NO;
    unsigned char uuid[16];
    // resolved covers the whole base/UUID relation, rather than presenting a failed UUID read as unequal.
    if (!mainResolved || !AxsCacheKeeperImageReadObservedUUID(info.dli_fbase,uuid)) return NO;
    *isMain=info.dli_fbase==main;*sameUUID=!memcmp(mainUUID,uuid,16);
    return YES;
}
static NSDictionary *AxsCacheKeeperImageLoadedRelation(Class __unsafe_unretained classes[4]) {
    AxsCacheKeeperExecutableImage executable=AxsCacheKeeperImageExecutable();const void *main=executable.header;
    const char *mainName=main ? _dyld_get_image_name(executable.index) : NULL;
    unsigned char mainUUID[16];BOOL mainResolved=AxsCacheKeeperImageReadObservedUUID(main,mainUUID);
    static const unsigned char contractUUID[16]={0xb2,0xb9,0xd3,0x0a,0x1c,0xaf,0x31,0xb4,0x82,0xca,0xc7,0x76,0xe7,0xeb,0x2b,0xa1};
    NSUInteger present=0,known=0,names=0;
    Class helper=NSClassFromString(@"SDFileAttributeHelper");
    for (NSUInteger index=0;index<5;index++) {
        Class owner=index<4 ? classes[index] : helper;if (!owner) continue;present|=1U<<index;
        const char *name=class_getImageName(owner);if (name && mainName) {known|=1U<<index;if (!strcmp(name,mainName)) names|=1U<<index;}
    }
    // Public runtime image names do not authenticate the loaded class metadata (including PAC).
    // No class address stripping or guessed runtime layout: unresolved is separate from unequal.
    NSMutableDictionary *value=[@{@"schemaVersion":@1,@"classPresentMask":@(present),@"classNameKnownMask":@(known),@"classNameEqualsMainMask":@(names),
        @"classResolvedMask":@0,@"classLoadedMainMask":@0,@"classUUIDMatchesMainMask":@0,
        @"mainUUIDResolved":@(mainResolved),@"mainUUIDMatchesContract":@((BOOL)(mainResolved && !memcmp(mainUUID,contractUUID,16))),@"mainLayoutChecked":@NO} mutableCopy];
    Method initializer=classes[0] ? class_getInstanceMethod(classes[0],sel_registerName(AxsCacheKeeperImageMethodSpecs[0].selector)) : NULL;
    BOOL saved=classes[0] && classes[0]==axs_cachekeeper_image_class && axs_cachekeeper_image_init_original;
    const void *initial=saved ? (const void *)axs_cachekeeper_image_init_original : (initializer ? (const void *)method_getImplementation(initializer) : NULL);
    BOOL isMain=NO,sameUUID=NO;
    value[@"initializerUsesSavedOriginal"]=@(saved);value[@"initializerResolved"]=@(AxsCacheKeeperImageObservedIMP(initial,main,mainUUID,mainResolved,&isMain,&sameUUID));
    value[@"initializerBaseIsMain"]=@(isMain);value[@"initializerUUIDMatchesMain"]=@(sameUUID);
    const void *originals[4]={(const void *)axs_cachekeeper_image_init_original,(const void *)axs_cachekeeper_image_remove_original,
        (const void *)axs_cachekeeper_image_data_original,(const void *)axs_cachekeeper_image_extended_original};
    NSUInteger resolved=0,bases=0,uuids=0;
    for (NSUInteger index=0;index<4;index++) {
        if (!index && saved) {
            if ([value[@"initializerResolved"] boolValue]) resolved|=1;
            if ([value[@"initializerBaseIsMain"] boolValue]) bases|=1;
            if ([value[@"initializerUUIDMatchesMain"] boolValue]) uuids|=1;
            continue;
        }
        if (AxsCacheKeeperImageObservedIMP(originals[index],main,mainUUID,mainResolved,&isMain,&sameUUID)) resolved|=1U<<index;
        if (isMain) bases|=1U<<index;if (sameUUID) uuids|=1U<<index;
    }
    value[@"originalResolvedMask"]=@(resolved);value[@"originalBaseIsMainMask"]=@(bases);value[@"originalUUIDMatchesMainMask"]=@(uuids);
    resolved=0;bases=0;uuids=0;
    const char *selectors[2]={"setExtendedAttribute:value:atPath:traverseLink:overwrite:error:","removeExtendedAttribute:atPath:traverseLink:error:"};
    for (NSUInteger index=0;index<2;index++) {
        Method method=helper ? class_getClassMethod(helper,sel_registerName(selectors[index])) : NULL;
        if (AxsCacheKeeperImageObservedIMP(method ? (const void *)method_getImplementation(method) : NULL,main,mainUUID,mainResolved,&isMain,&sameUUID)) resolved|=1U<<index;
        if (isMain) bases|=1U<<index;if (sameUUID) uuids|=1U<<index;
    }
    value[@"helperResolvedMask"]=@(resolved);value[@"helperBaseIsMainMask"]=@(bases);value[@"helperUUIDMatchesMainMask"]=@(uuids);
    return axs_cachekeeper_image_loaded_relation_projection(value);
}
static NSDictionary *AxsCacheKeeperImageDiscoveryCheck(NSUInteger mask, NSString *kind, NSString *source, NSString *stage, NSString *failure, NSUInteger methodIndex) {
    return @{@"schemaVersion":@1,@"classMask":@(mask),@"imageKind":kind,@"source":source,
        @"stage":stage,@"failure":failure,@"methodIndex":@(methodIndex)};
}
// Call under the SDK registry lock. The initializer hook belongs to this plugin; its saved
// original identifies the SDK image even after hooks are installed or subsequently changed.
static BOOL AxsCacheKeeperImageSourceInfo(Class image, Dl_info *info) {
    Method initializer=class_getInstanceMethod(image,sel_registerName(AxsCacheKeeperImageMethodSpecs[0].selector));
    if (!initializer) return NO;
    IMP implementation=image==axs_cachekeeper_image_class && axs_cachekeeper_image_init_original ?
        (IMP)axs_cachekeeper_image_init_original : method_getImplementation(initializer);
    return dladdr(AxsCacheKeeperImageLegacyCodeAddress((const void *)implementation),info) && info->dli_fbase;
}
static NSDictionary *AxsCacheKeeperImageDiscover(AxsCacheKeeperImageContract pinnedTestContract, Class __unsafe_unretained classes[4], NSMutableArray **validatedMethods, AxsCacheKeeperImageContract *validatedContract, const void **validatedLegacyBase) {
    if (validatedMethods) *validatedMethods=nil;
    if (validatedContract) *validatedContract=AxsCacheKeeperImageContractUnknown;
    if (validatedLegacyBase) *validatedLegacyBase=NULL;
    classes[0]=NSClassFromString(@"SDImageCache");classes[1]=NSClassFromString(@"SDDiskCache");
    classes[2]=NSClassFromString(@"SDImageCacheConfig");classes[3]=NSClassFromString(@"SDMemoryCache");
    __block NSDictionary *sourceCheck=nil;
    NSDictionary *loadedRelation=AxsCacheKeeperImageLoadedRelation(classes);
    NSDictionary *(^finish)(NSUInteger,NSString *,NSString *,NSString *,NSString *,NSUInteger)=^NSDictionary *(NSUInteger mask,NSString *kind,NSString *source,NSString *stage,NSString *failure,NSUInteger index) {
        NSMutableDictionary *check=[AxsCacheKeeperImageDiscoveryCheck(mask,kind,source,stage,failure,index) mutableCopy];
        check[@"schemaVersion"]=@2;check[@"loadedRelation"]=loadedRelation;
        if (sourceCheck) {
            check[@"sourceCheck"]=sourceCheck;
            if ([@[@"layout",@"mainWindow",@"helperOwner",@"helperABI",@"helperWindow",@"complete"] containsObject:sourceCheck[@"stage"]]) {
                NSMutableDictionary *relation=[loadedRelation mutableCopy];relation[@"mainLayoutChecked"]=@YES;check[@"loadedRelation"]=[relation copy];
            }
        }
        return axs_cachekeeper_image_discovery_projection(check);
    };
    NSUInteger mask=0;for (NSUInteger i=0;i<4;i++) if (classes[i]) mask|=1u<<i;
    Class image=classes[0];const char *imageName=image ? class_getImageName(image) : NULL;
    NSString *kind=@"unknown";NSBundle *bundle=image ? [NSBundle bundleForClass:image] : nil;
    if (imageName) {
        AxsCacheKeeperExecutableImage executable=AxsCacheKeeperImageExecutable();
        const char *mainImage=executable.header ? _dyld_get_image_name(executable.index) : NULL;
        kind=mainImage && !strcmp(imageName,mainImage) ? @"main" :
            ([bundle.bundlePath.pathExtension isEqual:@"framework"] ? @"framework" : @"other");
    }
    if (mask!=15) return finish(mask,kind,@"unknown",@"classes",@"missingClass",0);
    for (NSUInteger i=0;i<4;i++) if (!class_getImageName(classes[i]))
        return finish(mask,kind,@"unknown",@"image",@"missingImage",0);
    for (NSUInteger i=1;i<4;i++) if (strcmp(imageName,class_getImageName(classes[i])))
        return finish(mask,kind,@"unknown",@"image",@"mixedImages",0);
    if (!class_getInstanceMethod(image,sel_registerName(AxsCacheKeeperImageMethodSpecs[0].selector)))
        return finish(mask,kind,@"unknown",@"image",@"missingInitializer",0);
    Dl_info info={0};
    if (!AxsCacheKeeperImageSourceInfo(image,&info))
        return finish(mask,kind,@"unknown",@"image",@"imageLookup",0);
    NSString *version=bundle.infoDictionary[@"CFBundleShortVersionString"],*source=@"rejected";
    AxsCacheKeeperImageContract contract=AxsCacheKeeperImageContractUnknown;
    const void *sourceImplementations[AxsCacheKeeperImageMethodCount]={NULL};
    BOOL framework=[bundle.bundlePath.pathExtension isEqual:@"framework"] && [bundle.bundlePath.lastPathComponent isEqual:@"SDWebImage.framework"];
    if (framework && [@[@"5.15.5",@"5.21.7"] containsObject:version]) {source=@"frameworkVersion";contract=AxsCacheKeeperImageContractModern;}
    else if (AxsCacheKeeperImageKnownUUID(info.dli_fbase)) {source=@"imageUUID";contract=AxsCacheKeeperImageContractModern;}
    else {
        for (NSUInteger index=0;index<AxsCacheKeeperImageMethodCount;index++) {
            const AxsCacheKeeperImageMethodSpec *spec=&AxsCacheKeeperImageMethodSpecs[index];
            Class cls=classes[spec->ownerIndex];if (spec->classMethod) cls=object_getClass(cls);
            Method method=class_getInstanceMethod(cls,sel_registerName(spec->selector));
            if (method) sourceImplementations[index]=(const void *)method_getImplementation(method);
        }
        if (image==axs_cachekeeper_image_class && axs_cachekeeper_image_init_original) {
            sourceImplementations[0]=(const void *)axs_cachekeeper_image_init_original;
            sourceImplementations[20]=(const void *)axs_cachekeeper_image_remove_original;
            sourceImplementations[23]=(const void *)axs_cachekeeper_image_data_original;
            sourceImplementations[24]=(const void *)axs_cachekeeper_image_extended_original;
        }
        AxsCacheKeeperImageLegacyCheck result=AxsCacheKeeperImageLegacySourceCheck(info.dli_fbase,sourceImplementations);
        sourceCheck=AxsCacheKeeperImageSourceCheckValue(result);
        if (result.accepted) {
            source=@"imageFingerprint";contract=AxsCacheKeeperImageContractFixedSerialLegacy;
        }
    }
#if AXS_CACHEKEEPER_IMAGE_TESTING
    if (contract==AxsCacheKeeperImageContractUnknown &&
        (pinnedTestContract==AxsCacheKeeperImageContractModern || pinnedTestContract==AxsCacheKeeperImageContractFixedSerialLegacy)) {
        source=@"testPinned";contract=pinnedTestContract;
    }
#else
    (void)pinnedTestContract;
#endif
    if ([source isEqual:@"rejected"]) {
        if (axs_cachekeeper_image_legacy_base==info.dli_fbase && !AxsCacheKeeperImageLegacyHelpersMatch(info.dli_fbase))
            return finish(mask,kind,@"imageFingerprint",@"method",@"methodsChanged",0);
        return finish(mask,kind,source,@"source",@"unknownSource",0);
    }
    if (axs_cachekeeper_image_init_original) {
        NSUInteger changedIndex=0;
        if (contract!=axs_cachekeeper_image_contract || image!=axs_cachekeeper_image_class || classes[1]!=axs_cachekeeper_disk_class ||
            classes[2]!=axs_cachekeeper_image_config_class || classes[3]!=axs_cachekeeper_memory_class ||
            !AxsCacheKeeperImageMethodsUnchangedAtIndex(&changedIndex))
            return finish(mask,kind,source,@"method",@"methodsChanged",changedIndex);
    } else {
        NSMutableArray *methods=[NSMutableArray new];
        for (NSUInteger index=0;index<AxsCacheKeeperImageMethodCount;index++) {
            const AxsCacheKeeperImageMethodSpec *spec=&AxsCacheKeeperImageMethodSpecs[index];
            Class cls=classes[spec->ownerIndex];if (spec->classMethod) cls=object_getClass(cls);
            // Slot 11 stays in the contract: this source requires the API to be absent,
            // not present with a nil value. Its initializer's serial queue is fingerprinted.
            if (contract==AxsCacheKeeperImageContractFixedSerialLegacy && index==10) {
                if (class_getInstanceMethod(cls,sel_registerName(spec->selector)))
                    return finish(mask,kind,source,@"method",@"unexpectedMethod",index+1);
                [methods addObject:@{@"class":cls,@"selector":NSStringFromSelector(sel_registerName(spec->selector)),@"absent":@YES}];continue;
            }
            NSString *failure=AxsCacheKeeperImageMethodFailure(cls,spec,info.dli_fbase,methods);
            if (failure) return finish(mask,kind,source,@"method",failure,index+1);
            // Bind the ABI record to the exact IMP that passed the fingerprint gate;
            // do not learn a same-image swizzle between the two checks.
            if ([source isEqual:@"imageFingerprint"] &&
                [methods.lastObject[@"implementation"] pointerValue]!=sourceImplementations[index])
                return finish(mask,kind,source,@"method",@"methodsChanged",index+1);
        }
        if (validatedMethods) *validatedMethods=methods;
    }
    if (validatedContract) *validatedContract=contract;
    if (validatedLegacyBase && [source isEqual:@"imageFingerprint"]) *validatedLegacyBase=info.dli_fbase;
    return finish(mask,kind,source,@"complete",@"none",0);
}

@interface AxsCacheKeeperImageBinding : NSObject
@property(nonatomic,weak) id owner;
@property(nonatomic,weak) id disk;
@property(nonatomic,weak) id config;
@property(nonatomic,weak) id memory;
@property(nonatomic,strong) id initialAttributes;
@property(nonatomic) AxsCacheKeeperImageContract contract;
@property(nonatomic,weak) id initialFileManager;
@property(nonatomic,copy) NSString *initialReason;
@property(atomic) AxsCacheKeeperImageReason admissionReason;
@property(nonatomic) BOOL releaseRecorded; // Protected by the owning engine's registry lock.
@property(nonatomic) BOOL rootRefreshAttempted;
@property(atomic) BOOL invalidated;
@property(nonatomic,strong) dispatch_queue_t queue;
@property(nonatomic,copy) NSString *path;
@property(nonatomic,copy) NSString *relative;
@property(atomic,copy) NSString *home;
@property(atomic,copy) NSString *installation;
@property(atomic,copy) NSArray *identity;
@property(nonatomic,weak) AxsCacheKeeperImageCache *engine;
@property(atomic) BOOL restricted;
@property(nonatomic) BOOL eligible;
@property(atomic) BOOL pending;
@property(nonatomic) NSUInteger flight;
@property(nonatomic) NSUInteger operationOwner,operationAction,operationEvent;
@property(nonatomic) NSTimeInterval flightDeadline;
@property(atomic) BOOL pluginRemoving;
@property(nonatomic) NSUInteger blockedWrites;
@property(nonatomic,copy) NSString *reason;
@end
@implementation AxsCacheKeeperImageBinding
@end

@interface AxsCacheKeeperImageCache () {
    AxsCacheKeeperImageAdmission _admission;
}
@property(nonatomic,strong) dispatch_queue_t work;
@property(nonatomic,copy) AxsCacheKeeperImageContextProvider provider;
@property(nonatomic,copy) void (^observer)(NSDictionary *);
@property(nonatomic,strong) NSMutableArray<AxsCacheKeeperImageBinding *> *bindings;
@property(atomic,copy) NSDictionary *context;
@property(nonatomic,copy) NSDictionary *lastReceipt;
@property(nonatomic) NSUInteger generation;
@property(nonatomic,strong) NSMutableDictionary *operationHistory;
@property(nonatomic) NSUInteger operationEvent,operationOwner,installationGeneration;
@property(nonatomic,copy) NSString *operationInstallation;
@property(nonatomic) BOOL foreground;
@property(nonatomic) BOOL hasTime;
@property(atomic) BOOL supported;
@property(nonatomic) AxsCacheKeeperImageContract pinnedTestContract;
@property(atomic,copy) NSDictionary *discoveryCheck;
@property(atomic,copy) NSDictionary *runtimeSourceObservation;
@property(nonatomic,copy) NSDictionary *firstSDKMethodsRejection;
@property(nonatomic) BOOL runtimeObservationPending;
@property(nonatomic) BOOL discoveryRefreshPending;
@property(nonatomic) BOOL admissionPublishPending;
@property(atomic) BOOL capacityExceeded;
@property(nonatomic) NSUInteger queued,submitted,completed,skipped;
@property(nonatomic,copy) NSString *state;
@property(nonatomic,copy) NSString *reason;
- (void)axs_cachekeeper_observe:(id)owner sourceReason:(NSString *)sourceReason attributes:(id)attributes contract:(AxsCacheKeeperImageContract)contract;
- (void)axs_cachekeeper_observeCreatedRoot:(AxsCacheKeeperImageBinding *)binding;
- (void)axs_cachekeeper_unregistered:(AxsCacheKeeperImageReason)reason;
- (void)axs_cachekeeper_unregistered:(AxsCacheKeeperImageReason)reason methodsCheck:(NSDictionary *)check;
- (void)axs_cachekeeper_publish;
@end

static NSString *AxsCacheKeeperImageConfigKind(id config) {
    Class actual=object_getClass(config);
    if (actual==axs_cachekeeper_image_config_class) return @"standard";
    // SDMemoryCache observes maxMemoryCost/maxMemoryCount on this same configuration.
    // Admit only its direct system KVO wrapper, not arbitrary SDK subclasses.
    if (actual && class_getSuperclass(actual)==axs_cachekeeper_image_config_class &&
        !strcmp(class_getName(actual),"NSKVONotifying_SDImageCacheConfig") &&
        ((Class (*)(id,SEL))objc_msgSend)(config,@selector(class))==axs_cachekeeper_image_config_class) return @"standardKVO";
    return @"unsupported";
}
static NSString *AxsCacheKeeperImageConfigurationReason(id config) {
    if ([AxsCacheKeeperImageConfigKind(config) isEqual:@"unsupported"]) return @"configurationClass";
    if (!AxsCacheKeeperImageMethodsUnchanged()) return @"sdkMethodsChanged";
    NSArray *methods;@synchronized(AxsCacheKeeperImageCache.class) {methods=axs_cachekeeper_image_methods;}
    for (NSDictionary *entry in methods) if (entry[@"class"]==axs_cachekeeper_image_config_class) {
        if ([entry[@"absent"] boolValue]) {
            if (class_getInstanceMethod(object_getClass(config),NSSelectorFromString(entry[@"selector"]))) return @"configurationGetter";
        } else if ((const void *)class_getMethodImplementation(object_getClass(config),NSSelectorFromString(entry[@"selector"]))!=[entry[@"implementation"] pointerValue])
            return @"configurationGetter";
    }
    return nil;
}
static NSString *AxsCacheKeeperImageStructureReason(id owner,id disk,id config) {
    if (!owner) return @"ownerReleased";
    if (!disk) return @"diskMissing";
    if (!config) return @"configurationMissing";
    if (object_getClass(owner)!=axs_cachekeeper_image_class) return @"ownerClass";
    if (object_getClass(disk)!=axs_cachekeeper_disk_class) return @"diskClass";
    NSString *reason=AxsCacheKeeperImageConfigurationReason(config);if (reason) return reason;
    if (object_getClass(AxsCacheKeeperImageGet(owner,"memoryCache"))!=axs_cachekeeper_memory_class) return @"memoryClass";
    if (((Class (*)(id,SEL))objc_msgSend)(config,sel_registerName("memoryCacheClass"))!=axs_cachekeeper_memory_class) return @"memoryBackend";
    if (AxsCacheKeeperImageGet(owner,"diskCache")!=disk || AxsCacheKeeperImageGet(owner,"config")!=config ||
        AxsCacheKeeperImageGet(disk,"config")!=config || AxsCacheKeeperImageGet(AxsCacheKeeperImageGet(owner,"memoryCache"),"config")!=config) return @"configurationIdentity";
    if (AxsCacheKeeperImageGet(config,"fileManager")) return @"customFileManager";
    if (((Class (*)(id,SEL))objc_msgSend)(config,sel_registerName("diskCacheClass"))!=axs_cachekeeper_disk_class) return @"diskBackend";
    if (object_getClass(AxsCacheKeeperImageGet(disk,"fileManager"))!=NSFileManager.class) return @"fileManagerClass";
    return nil;
}
static BOOL AxsCacheKeeperImageSerialAttributes(id attributes) {
    return !attributes || attributes==dispatch_queue_attr_make_with_autorelease_frequency(DISPATCH_QUEUE_SERIAL,DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM);
}
static NSString *AxsCacheKeeperImageInstanceReason(AxsCacheKeeperImageBinding *binding) {
    id owner=binding.owner;
    if (binding.invalidated) return @"invalidated";
    if (binding.initialReason) return binding.initialReason;
    if (!owner) return @"ownerReleased";
    if (object_getClass(owner)!=axs_cachekeeper_image_class) return @"ownerClass";
    if (!AxsCacheKeeperImageMethodsUnchanged()) return @"sdkMethodsChanged";
    // A replaced member may remain alive through SDK/autorelease references.
    // Classify the current owner members, then bind them to the admitted identity.
    id disk=AxsCacheKeeperImageGet(owner,"diskCache"),config=AxsCacheKeeperImageGet(owner,"config");
    NSString *reason=AxsCacheKeeperImageStructureReason(owner,disk,config);if (reason) return reason;
    if (disk!=binding.disk || config!=binding.config) return @"configurationIdentity";
    if (AxsCacheKeeperImageGet(owner,"memoryCache")!=binding.memory) return @"memoryIdentity";
    if (AxsCacheKeeperImageGet(owner,"ioQueue")!=binding.queue) return @"queueIdentity";
    if (![AxsCacheKeeperImageGet(owner,"diskCachePath") isEqual:binding.path] ||
        ![AxsCacheKeeperImageGet(disk,"diskCachePath") isEqual:binding.path]) return @"pathValueChanged";
    if (AxsCacheKeeperImageGet(disk,"fileManager")!=binding.initialFileManager) return @"fileManagerIdentity";
    if (binding.contract==AxsCacheKeeperImageContractModern) {
        id attr=AxsCacheKeeperImageGet(config,"ioQueueAttributes");
        if (attr!=binding.initialAttributes || !AxsCacheKeeperImageSerialAttributes(attr)) return @"queueAttributesChanged";
    } else if (binding.contract!=AxsCacheKeeperImageContractFixedSerialLegacy) return @"sdkMethodsChanged";
    return nil;
}
static BOOL AxsCacheKeeperImageInstanceUnchanged(AxsCacheKeeperImageBinding *binding) {
    NSString *reason=AxsCacheKeeperImageInstanceReason(binding);
    binding.admissionReason=reason ? AxsCacheKeeperImageReasonParse(reason.UTF8String) : AxsCacheKeeperImageReasonNone;
    return !reason;
}
static BOOL AxsCacheKeeperImageBlocksWrite(id disk) {
    AxsCacheKeeperImageBinding *binding=objc_getAssociatedObject(disk,AxsCacheKeeperImageBindingKey);
    if (binding.restricted && binding.contract==AxsCacheKeeperImageContractFixedSerialLegacy && !AxsCacheKeeperImageExecutable().header) {
        [binding.engine requestDiscoveryRefresh];return NO;
    }
    if (!binding.restricted || !binding.engine || binding.disk!=disk || !AxsCacheKeeperImageInstanceUnchanged(binding)) return NO;
    @synchronized(binding) { if (!binding.restricted) return NO;binding.blockedWrites++; }
    return YES;
}
static void AxsCacheKeeperImageSetData(id disk,SEL selector,id data,id key) {
    IMP original;@synchronized(AxsCacheKeeperImageCache.class) {original=axs_cachekeeper_image_data_original;}
    if (!data || !key || !AxsCacheKeeperImageBlocksWrite(disk)) {
        ((void (*)(id,SEL,id,id))original)(disk,selector,data,key);
        AxsCacheKeeperImageBinding *binding=objc_getAssociatedObject(disk,AxsCacheKeeperImageBindingKey);
        if (data && key) [binding.engine axs_cachekeeper_observeCreatedRoot:binding];
    }
}
static void AxsCacheKeeperImageSetExtendedData(id disk,SEL selector,id data,id key) {
    IMP original;@synchronized(AxsCacheKeeperImageCache.class) {original=axs_cachekeeper_image_extended_original;}
    // nil removes existing metadata in the SDK; it is not an added cache write.
    if (!data || !key || !AxsCacheKeeperImageBlocksWrite(disk)) ((void (*)(id,SEL,id,id))original)(disk,selector,data,key);
}
static id AxsCacheKeeperImageInit(id object __attribute__((ns_consumed)),SEL selector,id space,id directory,id config) __attribute__((ns_returns_retained));
static id AxsCacheKeeperImageInit(id object __attribute__((ns_consumed)),SEL selector,id space,id directory,id config) {
    __typeof__(axs_cachekeeper_image_init_original) original;
    AxsCacheKeeperImageContract contract;
    @synchronized(AxsCacheKeeperImageCache.class) {original=axs_cachekeeper_image_init_original;contract=axs_cachekeeper_image_contract;}
    // Capture before the SDK constructs its queue or invokes configurable initializers.
    // A custom backend cannot become trusted by changing the copied config before returning.
    id source=config ?: ((id (*)(id,SEL))objc_msgSend)(axs_cachekeeper_image_config_class,sel_registerName("defaultCacheConfig"));
    NSString *reason=AxsCacheKeeperImageConfigurationReason(source);id attributes=nil;
    if (!reason) {
        if (contract==AxsCacheKeeperImageContractModern) attributes=AxsCacheKeeperImageGet(source,"ioQueueAttributes");
        if (((Class (*)(id,SEL))objc_msgSend)(source,sel_registerName("memoryCacheClass"))!=axs_cachekeeper_memory_class) reason=@"memoryBackend";
        else if (((Class (*)(id,SEL))objc_msgSend)(source,sel_registerName("diskCacheClass"))!=axs_cachekeeper_disk_class) reason=@"diskBackend";
        else if (AxsCacheKeeperImageGet(source,"fileManager")) reason=@"customFileManager";
        else if (contract==AxsCacheKeeperImageContractModern && !AxsCacheKeeperImageSerialAttributes(attributes)) reason=@"initialQueueAttributes";
        else if (contract==AxsCacheKeeperImageContractUnknown) reason=@"sdkMethodsChanged";
    }
    id owner=original(object,selector,space,directory,config);
    [axs_cachekeeper_image_observer axs_cachekeeper_observe:owner sourceReason:reason attributes:attributes contract:contract];return owner;
}

// Resolves only the system-provided home alias. Every component below that root is opened
// without following links. Identity includes each ancestor, not only the leaf inode.
static NSArray *AxsCacheKeeperImagePathIdentity(NSString *home,NSString *relative,int *resultFD) {
    if (resultFD) *resultFD=-1;
    if (!home.length || !axs_cachekeeper_relative_path(relative)) return nil;
    int fd=open(home.stringByResolvingSymlinksInPath.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if (fd<0) return nil;
    NSMutableArray *identity=[NSMutableArray new];struct stat status;
    if (fstat(fd,&status)) {close(fd);return nil;}
    [identity addObject:@[@(status.st_dev),@(status.st_ino)]];
    for (NSString *part in relative.pathComponents) {
        int next=openat(fd,part.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        close(fd);fd=next;
        if (fd<0 || fstat(fd,&status) || !S_ISDIR(status.st_mode)) {if (fd>=0) close(fd);return nil;}
        [identity addObject:@[@(status.st_dev),@(status.st_ino)]];
    }
    if (resultFD) *resultFD=fd;else close(fd);
    return identity;
}
static NSArray<NSString *> *AxsCacheKeeperImageHomeBases(NSString *home) {
    if (![home isKindOfClass:NSString.class]) return @[];
    // Cache only within one worker refresh. FD identity checks still resolve/open the
    // current home for each owner, so this is never authorization across refreshes.
    NSString *resolved=home.stringByResolvingSymlinksInPath;
    return @[home,home.stringByStandardizingPath,resolved,resolved.stringByStandardizingPath];
}
static NSString *AxsCacheKeeperImageRelativeWithBases(NSArray<NSString *> *bases,NSString *path) {
    if (!bases.count || ![path isKindOfClass:NSString.class] || !path.isAbsolutePath) return nil;
    NSArray *components=[path componentsSeparatedByString:@"/"];
    for (NSUInteger i=1;i<components.count;i++)
        if (![components[i] length] || [components[i] isEqual:@"."] || [components[i] isEqual:@".."] || [components[i] containsString:@"\\"]) return nil;
    // Foundation may return either /var or /private/var for the same system container.
    for (NSString *base in bases) {
        NSString *prefix=[base stringByAppendingString:@"/"];
        if ([path hasPrefix:prefix]) {
            NSString *relative=[path substringFromIndex:prefix.length];
            if (axs_cachekeeper_relative_path(relative) && ([relative hasPrefix:@"Library/Caches/"] || [relative hasPrefix:@"tmp/"])) return relative;
        }
    }
    return nil;
}
static NSString *AxsCacheKeeperImageRelative(NSString *home,NSString *path) {
    return AxsCacheKeeperImageRelativeWithBases(AxsCacheKeeperImageHomeBases(home),path);
}
static NSString *AxsCacheKeeperImageScopeReasonWithRelative(NSDictionary *context,AxsCacheKeeperImageBinding *binding,NSString *relative) {
    if (![context[@"valid"] boolValue] || !axs_cachekeeper_state_valid(context[@"appState"]) ||
        !axs_cachekeeper_input_strings(context[@"selected"],axs_cachekeeper_relative_path)) return @"configurationInvalid";
    if (!axs_cachekeeper_app_enabled(context[@"appState"])) return @"appDisabled";
    if (![context[@"installation"] isKindOfClass:NSString.class] || ![context[@"installation"] length]) return @"installationUnverified";
    if (binding.installation && ![binding.installation isEqual:context[@"installation"]]) return @"installationChanged";
    if (!relative || axs_cachekeeper_retention_path(relative)) return @"scopeNotAuthorized";
    for (NSString *excluded in axs_cachekeeper_exclusions(context[@"appState"]))
        if (axs_cachekeeper_paths_overlap(relative,excluded)) return @"scopeNotAuthorized";
    if ([AxsCacheKeeperCleanupRules hasRetentionRangeForBundle:context[@"bundle"] version:context[@"version"] relativePath:relative]) return @"scopeNotAuthorized";
    NSArray *allowed=axs_cachekeeper_effective_paths(context[@"selected"],context[@"appState"],@[@"Library/Caches",@"tmp"]);
    for (NSString *root in allowed) if (axs_cachekeeper_path_inside(relative,root)) return nil;
    return @"scopeNotAuthorized";
}
static NSString *AxsCacheKeeperImageScopeReason(NSDictionary *context,AxsCacheKeeperImageBinding *binding) {
    return AxsCacheKeeperImageScopeReasonWithRelative(context,binding,AxsCacheKeeperImageRelative(context[@"home"],binding.path));
}
static BOOL AxsCacheKeeperImageOverlaps(NSString *left,NSString *right) {
    return left.length && right.length && axs_cachekeeper_paths_overlap(left,right);
}
// Standard SDDiskCache owns a flat directory. A nested/linked/necessary-state entry is not
// representable by removeAllData; leave this owner to the existing per-file cleanup engine.
static AxsCacheKeeperImageSample AxsCacheKeeperImageFlatSample(int rootFD) {
    AxsCacheKeeperImageSample sample={0};struct stat before,after;
    if (fstat(rootFD,&before) || !S_ISDIR(before.st_mode)) {sample.state=AxsCacheKeeperImageSampleReadError;return sample;}
    // A separate open description prevents earlier enumeration from hiding entries.
    int copy=openat(rootFD,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if (copy<0) {sample.state=AxsCacheKeeperImageSampleReadError;return sample;}
    DIR *directory=fdopendir(copy);
    if (!directory) {sample.state=close(copy) ? AxsCacheKeeperImageSampleCloseError : AxsCacheKeeperImageSampleReadError;return sample;}
    NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+0.25;
    struct dirent *entry;
    for (;;) {
        if (NSProcessInfo.processInfo.systemUptime>deadline) {sample.state=AxsCacheKeeperImageSampleTimeLimit;break;}
        errno=0;entry=readdir(directory);
        if (!entry) {if (errno) sample.state=AxsCacheKeeperImageSampleReadError;break;}
        if (!strcmp(entry->d_name,".") || !strcmp(entry->d_name,"..")) continue;
        if (![NSFileManager.defaultManager stringWithFileSystemRepresentation:entry->d_name length:strlen(entry->d_name)]) {sample.state=AxsCacheKeeperImageSampleNonFlat;break;}
        struct stat status;
        if (fstatat(rootFD,entry->d_name,&status,AT_SYMLINK_NOFOLLOW) || status.st_size<0 || status.st_blocks<0) {sample.state=AxsCacheKeeperImageSampleReadError;break;}
        if (!S_ISREG(status.st_mode)) {sample.state=AxsCacheKeeperImageSampleNonFlat;break;}
        if ((uint64_t)status.st_blocks>AXS_CACHEKEEPER_IMAGE_EXACT_MAX/512) {sample.state=AxsCacheKeeperImageSampleOverflow;break;}
        if (!axs_cachekeeper_image_sample_add(&sample,(uint64_t)status.st_size,(uint64_t)status.st_blocks*512)) break;
    }
    if (sample.state==AxsCacheKeeperImageSampleComplete) {
        if (fstat(rootFD,&after)) sample.state=AxsCacheKeeperImageSampleReadError;
        else if (before.st_dev!=after.st_dev || before.st_ino!=after.st_ino || before.st_nlink!=after.st_nlink ||
            before.st_mtimespec.tv_sec!=after.st_mtimespec.tv_sec || before.st_mtimespec.tv_nsec!=after.st_mtimespec.tv_nsec ||
            before.st_ctimespec.tv_sec!=after.st_ctimespec.tv_sec || before.st_ctimespec.tv_nsec!=after.st_ctimespec.tv_nsec) sample.state=AxsCacheKeeperImageSampleChanged;
    }
    if (closedir(directory)) sample.state=AxsCacheKeeperImageSampleCloseError;
    return sample;
}
static BOOL AxsCacheKeeperImageSameAncestors(NSArray *before,NSArray *after) {
    return before.count>1 && after.count==before.count &&
        [[before subarrayWithRange:NSMakeRange(0,before.count-1)] isEqual:[after subarrayWithRange:NSMakeRange(0,after.count-1)]];
}
static void AxsCacheKeeperImageRemoveAll(id disk,SEL selector) {
    IMP original;@synchronized(AxsCacheKeeperImageCache.class) {original=axs_cachekeeper_image_remove_original;}
    AxsCacheKeeperImageBinding *binding=objc_getAssociatedObject(disk,AxsCacheKeeperImageBindingKey);
    __attribute__((objc_precise_lifetime)) id owner=binding.owner;
    BOOL pluginRemoving=binding.pluginRemoving;
    NSArray *before=nil;
    if (owner && binding.home && dispatch_get_specific(AxsCacheKeeperImageQueueKey)==(__bridge void *)binding &&
        AxsCacheKeeperImageInstanceUnchanged(binding)) {
        NSArray *actual=AxsCacheKeeperImagePathIdentity(binding.home,binding.relative,NULL);
        if (actual && (!binding.identity || [actual isEqual:binding.identity])) before=actual;
    }
    // APP-initiated clears are always passed through, including disabled/unrecognized instances.
    ((void (*)(id,SEL))original)(disk,selector);
    if (!before) return;
    NSArray *after=AxsCacheKeeperImagePathIdentity(binding.home,binding.relative,NULL);
    @synchronized(binding) {
        if (AxsCacheKeeperImageSameAncestors(before,after) && AxsCacheKeeperImageInstanceUnchanged(binding) &&
            (!binding.identity || [binding.identity isEqual:before] || [binding.identity isEqual:after]))
            binding.identity=after;
        else {binding.invalidated=YES;binding.restricted=NO;}
    }
    // The SDK's legitimate clear recreates its root. Observe that exact transition, then reread
    // policy; an arbitrary path replacement never gets this identity-refresh privilege.
    if (!pluginRemoving) [binding.engine refreshWithCompletion:nil];
}

void axs_cachekeeper_image_runtime_view_changed(void) {
    atomic_fetch_add(&axs_cachekeeper_image_observation_generation,1);
}
static NSDictionary *AxsCacheKeeperImageCollectRuntimeObservation(void) {
    Class __unsafe_unretained classes[5]={objc_getClass("SDImageCache"),objc_getClass("SDDiskCache"),objc_getClass("SDImageCacheConfig"),objc_getClass("SDMemoryCache"),objc_getClass("SDFileAttributeHelper")};
    AxsCacheKeeperImageObservationMethod specs[27];
    for (NSUInteger i=0;i<25;i++) specs[i]=(AxsCacheKeeperImageObservationMethod){AxsCacheKeeperImageMethodSpecs[i].ownerIndex,AxsCacheKeeperImageMethodSpecs[i].classMethod,AxsCacheKeeperImageMethodSpecs[i].selector};
    specs[25]=(AxsCacheKeeperImageObservationMethod){4,YES,"setExtendedAttribute:value:atPath:traverseLink:overwrite:error:"};
    specs[26]=(AxsCacheKeeperImageObservationMethod){4,YES,"removeExtendedAttribute:atPath:traverseLink:error:"};
    BOOL saved=NO;const void *originals[4]={NULL};
    @synchronized(AxsCacheKeeperImageCache.class) {
        saved=classes[0] && classes[0]==axs_cachekeeper_image_class && axs_cachekeeper_image_init_original;
        if (saved) {
            originals[0]=(const void *)axs_cachekeeper_image_init_original;originals[1]=(const void *)axs_cachekeeper_image_remove_original;
            originals[2]=(const void *)axs_cachekeeper_image_data_original;originals[3]=(const void *)axs_cachekeeper_image_extended_original;
        }
    }
    const void *wrappers[4]={(const void *)AxsCacheKeeperImageInit,(const void *)AxsCacheKeeperImageRemoveAll,(const void *)AxsCacheKeeperImageSetData,(const void *)AxsCacheKeeperImageSetExtendedData};
    return AxsCacheKeeperImageRuntimeObservation(classes,specs,originals,wrappers,saved);
}
static NSDictionary *AxsCacheKeeperImageInstalledRelation(NSDictionary *installation,NSDictionary *runtime) {
    NSDictionary *disk=axs_cachekeeper_installation_image_observation_projection(installation);
    if (!disk) return nil;
    NSString *uuid=disk[@"metadata"][@"uuid"];
    NSMutableDictionary *out=[@{@"schemaVersion":@1,@"installationImage":disk,@"mappingBackingIdentity":@"notVerified"} mutableCopy];
    for (NSArray *pair in @[@[@"mainModule",@"mainUUIDRelation"],@[@"candidateModule",@"candidateUUIDRelation"]]) {
        NSUInteger module=[runtime[pair[0]] unsignedIntegerValue];NSString *loaded=nil;
        if ([runtime[@"state"] isEqual:@"complete"] && module && module<=[runtime[@"modules"] count]) loaded=runtime[@"modules"][module-1][@"metadata"][@"uuid"];
        out[pair[1]]=uuid && loaded ? ([uuid isEqual:loaded] ? @"same" : @"different") : @"notCompared";
    }
    return axs_cachekeeper_installed_runtime_relation_projection(out);
}
@implementation AxsCacheKeeperImageCache
- (instancetype)initWithContextProvider:(AxsCacheKeeperImageContextProvider)provider observer:(void (^)(NSDictionary *))observer {
    if ((self=[super init])) {
        _provider=[provider copy];_bindings=[NSMutableArray new];
        _operationHistory=axs_cachekeeper_operation_history_create(@"image",nil);
        // Weak getters and SDK calls may return autoreleased objects. Close their
        // lifetime at each worker item instead of inheriting the global queue pool.
        _work=dispatch_queue_create("dev.local.cachekeeper.images",DISPATCH_QUEUE_SERIAL_WITH_AUTORELEASE_POOL);
        _state=@"notObserved";_reason=@"none";_foreground=YES;
        _discoveryCheck=AxsCacheKeeperImageDiscoveryCheck(0,@"unknown",@"unknown",@"notChecked",@"none",0);
        [self axs_cachekeeper_publish];
        _observer=[observer copy];
    }return self;
}
#if AXS_CACHEKEEPER_IMAGE_TESTING
- (void)usePinnedSDKForIntegrationTests { self.pinnedTestContract=AxsCacheKeeperImageContractModern; }
- (void)usePinnedLegacySDKForIntegrationTests { self.pinnedTestContract=AxsCacheKeeperImageContractFixedSerialLegacy; }
- (NSDictionary *)instanceDiagnosticsForIntegrationTests:(id)owner {
    for (AxsCacheKeeperImageBinding *binding in [self axs_cachekeeper_bindings]) if (binding.owner==owner)
        return @{@"initialReason":binding.initialReason ?: @"none",@"currentReason":AxsCacheKeeperImageInstanceReason(binding) ?: @"none",
            @"configKind":AxsCacheKeeperImageConfigKind(binding.config)};
    return @{@"initialReason":@"notObserved",@"currentReason":@"notObserved",@"configKind":@"unsupported"};
}
- (NSDictionary *)discoveryDiagnosticsForIntegrationTests {
    AxsCacheKeeperImageRefreshExecutable();
    @synchronized(AxsCacheKeeperImageCache.class) {
        Class __unsafe_unretained classes[4]={Nil,Nil,Nil,Nil};
        return AxsCacheKeeperImageDiscover(self.pinnedTestContract,classes,NULL,NULL,NULL);
    }
}
- (NSDictionary *)methodDiagnosticsForIntegrationTests:(NSUInteger)index ownerClass:(Class)ownerClass {
    if (!index || index>AxsCacheKeeperImageMethodCount || !ownerClass) return nil;
    @synchronized(AxsCacheKeeperImageCache.class) {
        const AxsCacheKeeperImageMethodSpec *spec=&AxsCacheKeeperImageMethodSpecs[index-1];
        Class cls=spec->classMethod ? object_getClass(ownerClass) : ownerClass;
        Dl_info info={0};
        if (!AxsCacheKeeperImageSourceInfo(NSClassFromString(@"SDImageCache"),&info))
            return @{@"methodIndex":@(index),@"failure":@"imageLookup"};
        NSString *failure=AxsCacheKeeperImageMethodFailure(cls,spec,info.dli_fbase,nil);
        return @{@"methodIndex":@(index),@"failure":failure ?: @"none"};
    }
}
#endif
- (void)axs_cachekeeper_request_runtime_observation {
    @synchronized(self) {if (self.runtimeObservationPending) return;self.runtimeObservationPending=YES;}
    dispatch_async(self.work,^{
        @synchronized(self) {self.runtimeObservationPending=NO;}
        self.runtimeSourceObservation=AxsCacheKeeperImageCollectRuntimeObservation();[self axs_cachekeeper_publish];
    });
}
- (void)startObserving {
    @try {
    AxsCacheKeeperImageRefreshExecutable();
    @synchronized(AxsCacheKeeperImageCache.class) {
        Class __unsafe_unretained classes[4]={Nil,Nil,Nil,Nil};NSMutableArray *methods=nil;
        AxsCacheKeeperImageContract contract=AxsCacheKeeperImageContractUnknown;const void *legacyBase=NULL;
        self.discoveryCheck=AxsCacheKeeperImageDiscover(self.pinnedTestContract,classes,&methods,&contract,&legacyBase);
        self.supported=[self.discoveryCheck[@"stage"] isEqual:@"complete"];
        if (!self.supported) return;
        if (axs_cachekeeper_image_init_original) {axs_cachekeeper_image_observer=self;return;}
        Class image=classes[0],disk=classes[1];
        Method initializer=class_getInstanceMethod(image,sel_registerName(AxsCacheKeeperImageMethodSpecs[0].selector));
        axs_cachekeeper_image_class=image;axs_cachekeeper_disk_class=disk;axs_cachekeeper_image_config_class=classes[2];axs_cachekeeper_memory_class=classes[3];
        axs_cachekeeper_image_contract=contract;
        axs_cachekeeper_image_legacy_base=legacyBase;
        axs_cachekeeper_image_init_original=(__typeof__(axs_cachekeeper_image_init_original))method_setImplementation(initializer,(IMP)AxsCacheKeeperImageInit);
        axs_cachekeeper_image_data_original=method_setImplementation(class_getInstanceMethod(disk,sel_registerName("setData:forKey:")),(IMP)AxsCacheKeeperImageSetData);
        axs_cachekeeper_image_extended_original=method_setImplementation(class_getInstanceMethod(disk,sel_registerName("setExtendedData:forKey:")),(IMP)AxsCacheKeeperImageSetExtendedData);
        axs_cachekeeper_image_remove_original=method_setImplementation(class_getInstanceMethod(disk,sel_registerName("removeAllData")),(IMP)AxsCacheKeeperImageRemoveAll);
        NSMutableArray *installed=[NSMutableArray new];
        for (NSUInteger index=0;index<methods.count;index++) {
            NSDictionary *entry=methods[index];NSMutableDictionary *record=[entry mutableCopy];
            Class cls=entry[@"class"];NSString *selector=entry[@"selector"];IMP replacement=NULL,original=NULL;
            if (cls==image && [selector isEqual:@"initWithNamespace:diskCacheDirectory:config:"]) {
                replacement=(IMP)AxsCacheKeeperImageInit;original=(IMP)axs_cachekeeper_image_init_original;
            } else if (cls==disk && [selector isEqual:@"setData:forKey:"]) {
                replacement=(IMP)AxsCacheKeeperImageSetData;original=axs_cachekeeper_image_data_original;
            } else if (cls==disk && [selector isEqual:@"setExtendedData:forKey:"]) {
                replacement=(IMP)AxsCacheKeeperImageSetExtendedData;original=axs_cachekeeper_image_extended_original;
            } else if (cls==disk && [selector isEqual:@"removeAllData"]) {
                replacement=(IMP)AxsCacheKeeperImageRemoveAll;original=axs_cachekeeper_image_remove_original;
            }
            // Preserve the admitted IMPs. Only our four known wrappers may replace them;
            // a concurrent swizzle must never become the next trusted baseline.
            if (replacement) {
                if ((const void *)original!=[entry[@"implementation"] pointerValue] && !axs_cachekeeper_image_installation_failure_index)
                    axs_cachekeeper_image_installation_failure_index=index+1;
                record[@"implementation"]=[NSValue valueWithPointer:(const void *)replacement];
            }
            [installed addObject:record];
        }
        axs_cachekeeper_image_methods=installed;axs_cachekeeper_image_observer=self;
        self.discoveryCheck=AxsCacheKeeperImageDiscover(self.pinnedTestContract,classes,NULL,NULL,NULL);
        self.supported=[self.discoveryCheck[@"stage"] isEqual:@"complete"];
    }
    } @finally {[self axs_cachekeeper_request_runtime_observation];}
}
- (void)restoreOperationHistory:(id)history {
    // Called before observation starts; the component queue orders later refreshes.
    @synchronized(self) {axs_cachekeeper_operation_restore(self.operationHistory,history);}
    [self axs_cachekeeper_publish];
}
- (void)loadOperationHistoryFromPath:(NSString *)path {
    dispatch_async(self.work,^{[self restoreOperationHistory:axs_cachekeeper_operation_load(path,@"image")];});
}
// Event creation and child registration belong to work. Public triggers capture the
// generation immediately, but cannot finish an event while its worker registers children.
- (NSDictionary *)axs_cachekeeper_operation_context {
    @synchronized(self) {return @{@"configuration":@(self.generation),@"installation":@(self.installationGeneration)};}
}
- (NSUInteger)axs_cachekeeper_begin_event:(NSString *)trigger context:(NSDictionary *)context current:(BOOL)current {
    // Refresh status is independent from cancellation policy. Every real context/discovery
    // refresh is requested; only configuration refreshes supersede an unfinished event.
    BOOL supersede=[trigger isEqual:@"configuration"];
    NSUInteger event=axs_cachekeeper_operation_begin_with_policy(self.operationHistory,trigger,[context[@"configuration"] unsignedIntegerValue],[context[@"installation"] unsignedIntegerValue],YES,supersede);
    if (current) self.operationEvent=event;
    return event;
}
- (void)axs_cachekeeper_schedule_refresh:(NSString *)trigger {
    NSDictionary *context=[self axs_cachekeeper_operation_context];
    dispatch_async(self.work,^{
        NSUInteger event=[self axs_cachekeeper_begin_event:trigger context:context current:YES];
        [self axs_cachekeeper_refresh_event:event];axs_cachekeeper_operation_finish(self.operationHistory,event);[self axs_cachekeeper_publish];
    });
}
- (void)requestDiscoveryRefresh {
    @synchronized(self) {
        if (self.discoveryRefreshPending) return;
        self.discoveryRefreshPending=YES;
    }
    NSDictionary *context=[self axs_cachekeeper_operation_context];
    dispatch_async(self.work,^{
        @synchronized(self) {self.discoveryRefreshPending=NO;}
        NSDictionary *before=self.discoveryCheck;
        [self startObserving];
        BOOL changed=![before isEqual:self.discoveryCheck];
        NSUInteger event=[self axs_cachekeeper_begin_event:@"imageLoad" context:context current:changed];
        if (!changed) {axs_cachekeeper_operation_refresh(self.operationHistory,event,@"applied");axs_cachekeeper_operation_finish(self.operationHistory,event);[self axs_cachekeeper_publish];return;}
        // Unchanged loader observations are separate receipts, not cancellation authority.
        // A changed contract retains the existing synchronous generation revocation.
        [self axs_cachekeeper_cancel];[self axs_cachekeeper_refresh_event:event];axs_cachekeeper_operation_finish(self.operationHistory,event);[self axs_cachekeeper_publish];
    });
}
- (NSArray<AxsCacheKeeperImageBinding *> *)axs_cachekeeper_bindings {
    @synchronized(self) {return [self.bindings copy];}
}
- (void)axs_cachekeeper_cancel {
    @synchronized(self) {self.generation++;for (AxsCacheKeeperImageBinding *binding in self.bindings) binding.restricted=NO;}
}
- (void)axs_cachekeeper_unregistered:(AxsCacheKeeperImageReason)reason {
    [self axs_cachekeeper_unregistered:reason methodsCheck:nil];
}
- (void)axs_cachekeeper_unregistered:(AxsCacheKeeperImageReason)reason methodsCheck:(NSDictionary *)check {
    @synchronized(self) {
        AxsCacheKeeperImageAdmissionRecord(&_admission,reason);
        if (reason==AxsCacheKeeperImageReasonSDKMethodsChanged && !self.firstSDKMethodsRejection && check) {
            self.firstSDKMethodsRejection=axs_cachekeeper_image_sdk_rejection_projection(@{@"schemaVersion":@1,@"state":@"recorded",
                @"initializerOrdinal":@(_admission.initializerReturns),@"check":check});
        }
        // Early exits update evidence only. They must not replace a live owner's
        // authorization state or invoke additional SDK getters on publication.
        if (self.admissionPublishPending) return;
        self.admissionPublishPending=YES;
    }
    dispatch_async(self.work,^{
        @synchronized(self) {self.admissionPublishPending=NO;}
        [self axs_cachekeeper_publish];
    });
}
- (void)axs_cachekeeper_observe:(id)owner sourceReason:(NSString *)sourceReason attributes:(id)attributes contract:(AxsCacheKeeperImageContract)contract {
    @autoreleasepool {
    if (!owner) {[self axs_cachekeeper_unregistered:AxsCacheKeeperImageReasonInitializerReturnedNil];return;}
    if (self.capacityExceeded) {[self axs_cachekeeper_unregistered:AxsCacheKeeperImageReasonObservationLimit];return;}
    if (object_getClass(owner)!=axs_cachekeeper_image_class) {[self axs_cachekeeper_unregistered:AxsCacheKeeperImageReasonOwnerClass];return;}
    NSDictionary *methodsCheck=AxsCacheKeeperImageMethodsCheckSnapshot(YES);
    if (![methodsCheck[@"accepted"] boolValue]) {[self axs_cachekeeper_unregistered:AxsCacheKeeperImageReasonSDKMethodsChanged methodsCheck:methodsCheck];return;}
    id disk=AxsCacheKeeperImageGet(owner,"diskCache"),config=AxsCacheKeeperImageGet(owner,"config");
    if (!disk || !config) {[self axs_cachekeeper_unregistered:!disk ? AxsCacheKeeperImageReasonDiskMissing : AxsCacheKeeperImageReasonConfigurationMissing];return;}
    AxsCacheKeeperImageBinding *binding=[AxsCacheKeeperImageBinding new];binding.owner=owner;binding.disk=disk;binding.config=config;binding.contract=contract;
    binding.queue=AxsCacheKeeperImageGet(owner,"ioQueue");id path=AxsCacheKeeperImageGet(owner,"diskCachePath");binding.engine=self;
    if (!binding.queue) {[self axs_cachekeeper_unregistered:AxsCacheKeeperImageReasonQueueMissing];return;}
    if (path && ![path isKindOfClass:NSString.class]) {[self axs_cachekeeper_unregistered:AxsCacheKeeperImageReasonPathType];return;}
    binding.path=[path copy];
    if (!binding.path.length) {[self axs_cachekeeper_unregistered:AxsCacheKeeperImageReasonPathMissing];return;}
    binding.initialReason=sourceReason ?: AxsCacheKeeperImageStructureReason(owner,disk,config);
    if (!binding.initialReason) {
        binding.memory=AxsCacheKeeperImageGet(owner,"memoryCache");
        binding.initialAttributes=attributes;
        binding.initialFileManager=AxsCacheKeeperImageGet(disk,"fileManager");
        if (contract==AxsCacheKeeperImageContractModern && AxsCacheKeeperImageGet(config,"ioQueueAttributes")!=attributes)
            binding.initialReason=@"queueAttributesChanged";
    }
    if (!binding.initialReason)
        dispatch_queue_set_specific(binding.queue,AxsCacheKeeperImageQueueKey,(__bridge void *)binding,NULL);
    binding.admissionReason=binding.initialReason ? AxsCacheKeeperImageReasonParse(binding.initialReason.UTF8String) : AxsCacheKeeperImageReasonNotChecked;
    binding.home=self.context[@"home"] ?: NSHomeDirectory();
    binding.relative=AxsCacheKeeperImageRelative(binding.home,binding.path);
    @synchronized(self) {
        [self.bindings filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(AxsCacheKeeperImageBinding *item,NSDictionary *unused) {
            (void)unused;
            __attribute__((objc_precise_lifetime)) id liveOwner=item.owner;
            if (!liveOwner && !item.releaseRecorded) {item.releaseRecorded=YES;AxsCacheKeeperImageAdmissionRelease(&self->_admission);}
            return liveOwner || item.pending;
        }]];
        if (self.capacityExceeded || self.bindings.count>=64) {
            // An untracked owner might share any existing path. Stop all previously admitted
            // instances for this process instead of pretending that discovery is complete.
            self.capacityExceeded=YES;self.generation++;
            for (AxsCacheKeeperImageBinding *item in self.bindings) {item.invalidated=YES;item.restricted=NO;}
            AxsCacheKeeperImageAdmissionRecord(&_admission,AxsCacheKeeperImageReasonObservationLimit);
            [self axs_cachekeeper_schedule_refresh:@"imageLoad"];return;
        }
        // Registry changes share the same final commit generation as configuration changes.
        // An older refresh snapshot must not re-enable a gate after a new owner appears.
        self.generation++;
        // Revoke conflicting gates immediately, before another SDK queue can write or clear.
        for (AxsCacheKeeperImageBinding *other in self.bindings)
            if ((other.owner || other.pending) && AxsCacheKeeperImageOverlaps(binding.relative,other.relative)) other.restricted=NO;
        binding.operationOwner=++self.operationOwner;
        [self.bindings addObject:binding];
        AxsCacheKeeperImageAdmissionRecord(&_admission,AxsCacheKeeperImageReasonNone);
    }
    // A custom backend never receives a binding; its original methods remain untouched.
    if (object_getClass(disk)==axs_cachekeeper_disk_class) objc_setAssociatedObject(disk,AxsCacheKeeperImageBindingKey,binding,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self axs_cachekeeper_schedule_refresh:@"imageLoad"];
    }
}
- (void)axs_cachekeeper_observeCreatedRoot:(AxsCacheKeeperImageBinding *)binding {
    // 5.15.5 creates the root on first SDK write. Recheck each unbound owner at most once;
    // failed writes/scopes then wait for normal configuration or lifecycle refreshes.
    // This also covers a write racing the initial worker probe, without polling in the hook.
    NSDictionary *context=self.context;
    if (![context[@"valid"] boolValue] || !axs_cachekeeper_app_enabled(context[@"appState"])) return;
    @synchronized(binding) {
        if (!binding || binding.initialReason || binding.identity || binding.invalidated || binding.rootRefreshAttempted) return;
        binding.rootRefreshAttempted=YES;
    }
    [self axs_cachekeeper_schedule_refresh:@"imageLoad"];
}
- (void)axs_cachekeeper_refresh_event:(NSUInteger)event {
    // End SDK getter temporaries before completion or the next state transition,
    // including direct refreshes within a still-running worker item.
    @autoreleasepool {
    NSUInteger generation;@synchronized(self) {generation=self.generation;}
    NSDictionary *context=self.provider ? self.provider() : @{};
    @synchronized(self) {if (generation!=self.generation) {axs_cachekeeper_operation_refresh(self.operationHistory,event,@"obsolete");return;}}
    self.context=context;
    @synchronized(self) {if (![self.operationInstallation isEqual:context[@"installation"]]) {self.operationInstallation=context[@"installation"];self.installationGeneration++;}}
    NSArray *bindings=[self axs_cachekeeper_bindings];
    NSArray *homeBases=AxsCacheKeeperImageHomeBases(context[@"home"]);
    NSMutableArray *relativePaths=[NSMutableArray arrayWithCapacity:bindings.count];
    for (AxsCacheKeeperImageBinding *binding in bindings)
        [relativePaths addObject:AxsCacheKeeperImageRelativeWithBases(homeBases,binding.path) ?: NSNull.null];
    for (NSUInteger index=0;index<bindings.count;index++) {
        AxsCacheKeeperImageBinding *binding=bindings[index];
        NSString *relative=relativePaths[index]==NSNull.null ? nil : relativePaths[index];
        binding.restricted=NO;binding.eligible=NO;
        NSString *reason=AxsCacheKeeperImageScopeReasonWithRelative(context,binding,relative);
        if (reason) binding.admissionReason=binding.initialReason ? AxsCacheKeeperImageReasonParse(binding.initialReason.UTF8String) : AxsCacheKeeperImageReasonNotChecked;
        if (!reason && !AxsCacheKeeperImageInstanceUnchanged(binding)) reason=@"unsupportedInstance";
        NSArray *identity=!reason && relative ? AxsCacheKeeperImagePathIdentity(context[@"home"],relative,NULL) : nil;
        if (!reason && (!identity || (binding.identity && ![binding.identity isEqual:identity]))) reason=@"pathChanged";
        if (!reason) for (NSUInteger otherIndex=0;otherIndex<bindings.count;otherIndex++) {
            AxsCacheKeeperImageBinding *other=bindings[otherIndex];
            NSString *otherRelative=relativePaths[otherIndex]==NSNull.null ? nil : relativePaths[otherIndex];
            if (other!=binding && (other.owner || other.pending) && AxsCacheKeeperImageOverlaps(relative,otherRelative)) {reason=@"overlappingOwners";break;}
        }
        binding.reason=reason ?: @"none";
        if (!reason) {
            binding.installation=context[@"installation"];binding.relative=relative;binding.home=context[@"home"];
            @synchronized(binding) {if (!binding.identity) binding.identity=identity;}
            binding.eligible=YES;
            @synchronized(self) {if (generation==self.generation) binding.restricted=axs_cachekeeper_wants_restriction(context[@"appState"]);}
        }
    }
    @synchronized(self) {if (generation!=self.generation) {axs_cachekeeper_operation_refresh(self.operationHistory,event,@"obsolete");return;}}
    axs_cachekeeper_operation_refresh(self.operationHistory,event,@"applied");
    self.reason=@"none";self.state=@"ready";
    if (![context[@"valid"] boolValue]) {self.reason=@"configurationInvalid";self.state=@"blocked";}
    else if (!axs_cachekeeper_app_enabled(context[@"appState"])) {self.reason=@"appDisabled";self.state=@"disabled";}
    else if (self.capacityExceeded) {self.reason=@"observationLimit";self.state=@"blocked";}
    else if (!self.supported) {self.reason=@"unsupportedSDK";self.state=@"unsupported";}
    else if (!bindings.count) self.state=@"notObserved";
    else {
        BOOL eligible=NO,restricted=NO;for (AxsCacheKeeperImageBinding *binding in bindings) {eligible|=binding.eligible;restricted|=binding.restricted;}
        if (!eligible) {self.state=@"blocked";self.reason=((AxsCacheKeeperImageBinding *)bindings.firstObject).reason;}
        else if (restricted) self.state=@"restricting";
    }
    axs_cachekeeper_operation_event_reason(self.operationHistory,event,self.reason);
    [self axs_cachekeeper_publish];
    }
}
- (void)refreshWithCompletion:(void (^)(void))completion {
    [self axs_cachekeeper_cancel];
    NSDictionary *context=[self axs_cachekeeper_operation_context];
    dispatch_async(self.work,^{NSUInteger event=[self axs_cachekeeper_begin_event:@"configuration" context:context current:YES];[self startObserving];[self axs_cachekeeper_refresh_event:event];axs_cachekeeper_operation_finish(self.operationHistory,event);[self axs_cachekeeper_publish];if (completion) completion();});
}
- (void)didBecomeActive {
    @synchronized(self) {self.foreground=YES;self.hasTime=NO;}
    [self axs_cachekeeper_cancel];
    NSDictionary *context=[self axs_cachekeeper_operation_context];
    dispatch_async(self.work,^{NSUInteger event=[self axs_cachekeeper_begin_event:@"foreground" context:context current:YES];[self startObserving];[self axs_cachekeeper_refresh_event:event];axs_cachekeeper_operation_finish(self.operationHistory,event);[self axs_cachekeeper_publish];});
}
- (void)expireBackgroundTime {
    @synchronized(self) {self.hasTime=NO;self.generation++;}
    dispatch_async(self.work,^{self.reason=@"noBackgroundTime";[self axs_cachekeeper_publish];});
}
- (void)didEnterBackgroundWithTime:(BOOL)hasTime {
    @synchronized(self) {self.foreground=NO;self.hasTime=hasTime;}
    NSDictionary *context=[self axs_cachekeeper_operation_context];
    dispatch_async(self.work,^{
        NSUInteger event=[self axs_cachekeeper_begin_event:@"background" context:context current:YES];
        [self axs_cachekeeper_refresh_event:event];
        for (AxsCacheKeeperImageBinding *binding in [self axs_cachekeeper_bindings]) {
            if (binding.pending) {self.reason=@"inFlight";continue;}
            if (!binding.eligible) continue;
            NSUInteger generation;BOOL allowed;
            @synchronized(self) {generation=self.generation;allowed=self.hasTime && !self.foreground;}
            if (!allowed) {self.reason=@"noBackgroundTime";continue;}
            // Only this serial worker can create/finish events. Bind the child before
            // publishing pending state; reentrant observers can only enqueue later events.
            NSUInteger action=axs_cachekeeper_operation_action(self.operationHistory,event,binding.operationOwner);
            NSAssert(action!=0,@"Image worker must register a child before submitting SDK work");
            if (!action) {self.reason=@"reportWriteFailed";self.state=@"blocked";[self axs_cachekeeper_publish];continue;}
            binding.operationEvent=event;binding.operationAction=action;
            binding.pending=YES;NSUInteger flight=++binding.flight;binding.flightDeadline=NSProcessInfo.processInfo.systemUptime+15;
            @synchronized(self) {self.queued++;}self.state=@"queued";[self axs_cachekeeper_publish];
            dispatch_async(binding.queue,^{[self axs_cachekeeper_execute:binding generation:generation event:event action:action];});
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,15*NSEC_PER_SEC),self.work,^{
                if (binding.pending && binding.flight==flight) {
                    axs_cachekeeper_operation_timeout(self.operationHistory,action);
                    @synchronized(self) {if (event==self.operationEvent) {self.state=@"timedOut";self.reason=@"inFlight";}}
                    [self axs_cachekeeper_publish];
                }
            });
        }
        axs_cachekeeper_operation_event_reason(self.operationHistory,event,self.reason);
        axs_cachekeeper_operation_finish(self.operationHistory,event);
        [self axs_cachekeeper_publish];
    });
}
- (void)axs_cachekeeper_execute:(AxsCacheKeeperImageBinding *)binding generation:(NSUInteger)generation event:(NSUInteger)event action:(NSUInteger)action {
    @autoreleasepool {
    // This block runs on the actual SDK queue. Configuration and the installation snapshot are
    // checked here, not only before dispatch; no second asynchronous SDK clear is submitted.
    __attribute__((objc_precise_lifetime)) id owner=binding.owner;
    __attribute__((objc_precise_lifetime)) id disk=binding.disk;
    NSDictionary *context=self.provider ? self.provider() : @{};
    NSString *reason=NSProcessInfo.processInfo.systemUptime>=binding.flightDeadline ? @"deadlineExceeded" : AxsCacheKeeperImageScopeReason(context,binding);int fd=-1;
    if (!reason && ![context[@"reportWritable"] boolValue]) reason=@"reportWriteFailed";
    if (!reason && (!owner || !disk || !AxsCacheKeeperImageInstanceUnchanged(binding))) reason=@"ownerChanged";
    NSArray *identity=!reason ? AxsCacheKeeperImagePathIdentity(context[@"home"],binding.relative,&fd) : nil;
    if (!reason && ![identity isEqual:binding.identity]) reason=@"pathChanged";
    AxsCacheKeeperImageSample before={.state=AxsCacheKeeperImageSampleReadError},after={.state=AxsCacheKeeperImageSamplePathChanged};
    if (!reason) {before=AxsCacheKeeperImageFlatSample(fd);if (before.state!=AxsCacheKeeperImageSampleComplete) reason=@"scopeUnverified";}
    if (!reason) for (AxsCacheKeeperImageBinding *other in [self axs_cachekeeper_bindings])
        if (other!=binding && (other.owner || other.pending) && AxsCacheKeeperImageOverlaps(binding.relative,AxsCacheKeeperImageRelative(context[@"home"],other.path))) {reason=@"overlappingOwners";break;}
    BOOL submitted=NO;
    @synchronized(self) {
        if (!reason && generation!=self.generation) reason=@"authorizationChanged";
        if (!reason && NSProcessInfo.processInfo.systemUptime>=binding.flightDeadline) reason=@"deadlineExceeded";
        if (!reason && self.foreground) reason=@"foregroundAgain";
        if (!reason && !self.hasTime) reason=@"noBackgroundTime";
        // This is the synchronous API commit boundary. A later configuration change cannot
        // cancel a removeAllData already executing; the unfinished flight remains recorded.
        if (!reason) {self.submitted++;submitted=YES;axs_cachekeeper_operation_transition(self.operationHistory,action,@"submitted",NO);}
    }
    if (submitted) {
        binding.pluginRemoving=YES;
        ((void (*)(id,SEL))objc_msgSend)(disk,sel_registerName("removeAllData"));
        binding.pluginRemoving=NO;
        int afterFD=-1;NSArray *afterIdentity=AxsCacheKeeperImagePathIdentity(context[@"home"],binding.relative,&afterFD);
        BOOL unchanged=NO;
        @synchronized(binding) {unchanged=!binding.invalidated && [afterIdentity isEqual:binding.identity];}
        if (unchanged && AxsCacheKeeperImageSameAncestors(identity,afterIdentity) && AxsCacheKeeperImageInstanceUnchanged(binding))
            after=AxsCacheKeeperImageFlatSample(afterFD);
        if (after.state==AxsCacheKeeperImageSampleComplete &&
            ![afterIdentity isEqual:AxsCacheKeeperImagePathIdentity(context[@"home"],binding.relative,NULL)]) after.state=AxsCacheKeeperImageSamplePathChanged;
        if (afterFD>=0 && close(afterFD)) after.state=AxsCacheKeeperImageSampleCloseError;
    }
    (void)owner;if (fd>=0 && close(fd)) after.state=AxsCacheKeeperImageSampleCloseError;
    NSDictionary *effect=submitted ? axs_cachekeeper_image_effect_record(before,after) : nil;
    dispatch_async(self.work,^{
        binding.pending=NO;
        if (submitted) axs_cachekeeper_operation_image_effect(self.operationHistory,action,effect);
        else axs_cachekeeper_operation_transition_reason(self.operationHistory,action,@"skipped",reason ?: @"none",NO);
        @synchronized(self) {
            if (submitted) {
                self.completed++;
                if (binding.invalidated) {binding.restricted=NO;binding.eligible=NO;}
            }
            else self.skipped++;
            if (generation==self.generation && event==self.operationEvent) {
                self.reason=reason ?: @"none";
                if (self.queued==self.completed+self.skipped) self.state=submitted ? @"apiCompleted" : @"blocked";
            }
        }
        [self axs_cachekeeper_publish];
    });
    }
}
- (void)axs_cachekeeper_publish {
    // Direct and dispatch_sync calls do not inherit the queue's per-item pool.
    @autoreleasepool {
    NSDictionary *receipt;
    @synchronized(self) {
        NSUInteger observed=0,eligible=0,restricted=0,writes=0;
        NSMutableDictionary *liveReasons=[NSMutableDictionary new],*unregisteredReasons=[NSMutableDictionary new];
        for (AxsCacheKeeperImageBinding *binding in self.bindings) {
            // One weak load per owner closes the live/released counts in the same
            // registry snapshot. No owner is retained by the saved receipt.
            __attribute__((objc_precise_lifetime)) id owner=binding.owner;
            if (owner) {
                observed++;if (binding.eligible) eligible++;if (binding.restricted) restricted++;
                NSString *reason=@(AxsCacheKeeperImageReasonName(binding.admissionReason));
                liveReasons[reason]=@([liveReasons[reason] unsignedIntegerValue]+1);
            } else if (!binding.releaseRecorded) {
                binding.releaseRecorded=YES;AxsCacheKeeperImageAdmissionRelease(&_admission);
            }
            @synchronized(binding) {writes+=binding.blockedWrites;}
        }
        for (unsigned i=0;i<AxsCacheKeeperImageReasonCount;i++)
            if (_admission.unregisteredReasons[i]) unregisteredReasons[@(AxsCacheKeeperImageReasonName(i))]=@(_admission.unregisteredReasons[i]);
        NSDictionary *admission=@{@"schemaVersion":@1,@"initializerReturns":@(_admission.initializerReturns),
            @"registered":@(_admission.registered),@"unregistered":@(_admission.unregistered),@"released":@(_admission.released),
            @"overflow":@(_admission.overflow),@"unregisteredReasons":[unregisteredReasons copy],@"liveReasons":[liveReasons copy]};
        NSString *state=self.state;
        NSUInteger pending=self.queued-self.completed-self.skipped;
        if (!pending && [state isEqual:@"timedOut"]) state=@"ready";
        if (pending && [state isEqual:@"apiCompleted"]) state=@"queued";
        receipt=@{@"schemaVersion":@1,@"sdk":@"SDWebImage",@"state":state ?: @"notObserved",@"reason":self.reason ?: @"none",
            @"observed":@(observed),@"eligible":@(eligible),@"restricted":@(restricted),@"writesBlocked":@(writes),
            @"queued":@(self.queued),@"submitted":@(self.submitted),@"apiCompleted":@(self.completed),@"skipped":@(self.skipped),
            @"pending":@(pending),@"updated":NSDate.date,@"bytesState":@"notMeasured",@"discoveryCheck":self.discoveryCheck,
            @"instanceAdmission":admission};
        {NSMutableDictionary *record=[receipt mutableCopy];record[@"sdkMethodsRejectionObservation"]=self.firstSDKMethodsRejection ?: @{@"schemaVersion":@1,@"state":@"notRecorded"};receipt=record;}
        if (self.runtimeSourceObservation) {
            NSMutableDictionary *record=[receipt mutableCopy];record[@"runtimeSourceObservation"]=self.runtimeSourceObservation;receipt=record;
        }
        NSDictionary *installedRelation=AxsCacheKeeperImageInstalledRelation(self.context[@"installationImage"],self.runtimeSourceObservation);
        if (installedRelation) {NSMutableDictionary *record=[receipt mutableCopy];record[@"installedRuntimeRelation"]=installedRelation;receipt=record;}
        if (self.context[@"installationCheck"]) {
            NSMutableDictionary *record=[receipt mutableCopy];
            record[@"installationCheck"]=axs_cachekeeper_installation_check_projection(self.context[@"installationCheck"]) ?: @{@"state":@"invalid",@"errorCode":@0};
            receipt=record;
        }
        NSMutableDictionary *withHistory=[receipt mutableCopy];withHistory[@"operationHistory"]=axs_cachekeeper_operation_snapshot(self.operationHistory);receipt=[withHistory copy];
        self.lastReceipt=receipt;
        // Publish under the snapshot lock so an older callback cannot replace newer cumulative history.
        if (self.observer) self.observer(receipt);
    }
    }
}
- (NSDictionary *)receipt { @synchronized(self) {return self.lastReceipt;} }
@end
