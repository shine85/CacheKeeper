#import "AxsCacheKeeperImageCache.h"
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

static id AxsCacheKeeperImageGet(id object, const char *name) {
    return ((id (*)(id,SEL))objc_msgSend)(object,sel_registerName(name));
}
static BOOL AxsCacheKeeperImageMethod(Class cls, const char *selector, const char *result, NSArray<NSString *> *arguments, const void *image, NSMutableArray *methods) {
    SEL sel=sel_registerName(selector);Method method=class_getInstanceMethod(cls,sel);
    if (!method) return NO;
    // All admitted selectors are implemented by the exact SDK class, never an inherited method.
    unsigned count=0;Method *list=class_copyMethodList(cls,&count);BOOL own=NO;
    for (unsigned i=0;i<count;i++) if (method_getName(list[i])==sel) {own=YES;break;}
    free(list);if (!own) return NO;
    NSMethodSignature *signature=[NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if (!signature || strcmp(signature.methodReturnType,result) || signature.numberOfArguments!=arguments.count+2) return NO;
    for (NSUInteger i=0;i<arguments.count;i++) if (strcmp([signature getArgumentTypeAtIndex:i+2],arguments[i].UTF8String)) return NO;
    Dl_info info={0};IMP implementation=method_getImplementation(method);
    if (!dladdr((const void *)implementation,&info) || info.dli_fbase!=image) return NO;
    [methods addObject:@{@"class":cls,@"selector":NSStringFromSelector(sel),@"implementation":[NSValue valueWithPointer:(const void *)implementation]}];
    return YES;
}
static BOOL AxsCacheKeeperImageMethodsUnchanged(void) {
    NSArray *methods;@synchronized(AxsCacheKeeperImageCache.class) {methods=axs_cachekeeper_image_methods;}
    for (NSDictionary *entry in methods) {
        IMP actual=class_getMethodImplementation(entry[@"class"],NSSelectorFromString(entry[@"selector"]));
        if ((const void *)actual!=[entry[@"implementation"] pointerValue]) return NO;
    }
    return methods.count>0;
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

@interface AxsCacheKeeperImageBinding : NSObject
@property(nonatomic,weak) id owner;
@property(nonatomic,weak) id disk;
@property(nonatomic,weak) id config;
@property(nonatomic,weak) id memory;
@property(nonatomic,strong) id initialAttributes;
@property(nonatomic,weak) id initialFileManager;
@property(nonatomic,copy) NSString *initialReason;
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
@property(nonatomic) NSTimeInterval flightDeadline;
@property(atomic) BOOL pluginRemoving;
@property(nonatomic) NSUInteger blockedWrites;
@property(nonatomic,copy) NSString *reason;
@end
@implementation AxsCacheKeeperImageBinding
@end

@interface AxsCacheKeeperImageCache ()
@property(nonatomic,strong) dispatch_queue_t work;
@property(nonatomic,copy) AxsCacheKeeperImageContextProvider provider;
@property(nonatomic,copy) void (^observer)(NSDictionary *);
@property(nonatomic,strong) NSMutableArray<AxsCacheKeeperImageBinding *> *bindings;
@property(atomic,copy) NSDictionary *context;
@property(nonatomic,copy) NSDictionary *lastReceipt;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL foreground;
@property(nonatomic) BOOL hasTime;
@property(atomic) BOOL supported;
@property(nonatomic) BOOL pinnedTestSDK;
@property(atomic) BOOL capacityExceeded;
@property(nonatomic) NSUInteger queued,submitted,completed,skipped;
@property(nonatomic,copy) NSString *state;
@property(nonatomic,copy) NSString *reason;
- (void)axs_cachekeeper_observe:(id)owner sourceReason:(NSString *)sourceReason attributes:(id)attributes;
- (void)axs_cachekeeper_observeCreatedRoot:(AxsCacheKeeperImageBinding *)binding;
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
    for (NSDictionary *entry in methods) if (entry[@"class"]==axs_cachekeeper_image_config_class &&
        (const void *)class_getMethodImplementation(object_getClass(config),NSSelectorFromString(entry[@"selector"]))!=[entry[@"implementation"] pointerValue])
        return @"configurationGetter";
    return nil;
}
static NSString *AxsCacheKeeperImageStructureReason(id owner,id disk,id config) {
    if (!owner || !disk || !config) return @"ownerReleased";
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
    id owner=binding.owner,disk=binding.disk,config=binding.config;
    if (binding.invalidated) return @"invalidated";
    if (binding.initialReason) return binding.initialReason;
    NSString *reason=AxsCacheKeeperImageStructureReason(owner,disk,config);if (reason) return reason;
    if (AxsCacheKeeperImageGet(owner,"memoryCache")!=binding.memory) return @"memoryIdentity";
    if (AxsCacheKeeperImageGet(owner,"ioQueue")!=binding.queue) return @"queueIdentity";
    if (![AxsCacheKeeperImageGet(owner,"diskCachePath") isEqual:binding.path] ||
        ![AxsCacheKeeperImageGet(disk,"diskCachePath") isEqual:binding.path]) return @"pathValueChanged";
    if (AxsCacheKeeperImageGet(disk,"fileManager")!=binding.initialFileManager) return @"fileManagerIdentity";
    id attr=AxsCacheKeeperImageGet(config,"ioQueueAttributes");
    if (attr!=binding.initialAttributes || !AxsCacheKeeperImageSerialAttributes(attr)) return @"queueAttributesChanged";
    return nil;
}
static BOOL AxsCacheKeeperImageInstanceUnchanged(AxsCacheKeeperImageBinding *binding) {
    return !AxsCacheKeeperImageInstanceReason(binding);
}
static BOOL AxsCacheKeeperImageBlocksWrite(id disk) {
    AxsCacheKeeperImageBinding *binding=objc_getAssociatedObject(disk,AxsCacheKeeperImageBindingKey);
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
    @synchronized(AxsCacheKeeperImageCache.class) {original=axs_cachekeeper_image_init_original;}
    // Capture before the SDK constructs its queue or invokes configurable initializers.
    // A custom backend cannot become trusted by changing the copied config before returning.
    id source=config ?: ((id (*)(id,SEL))objc_msgSend)(axs_cachekeeper_image_config_class,sel_registerName("defaultCacheConfig"));
    NSString *reason=AxsCacheKeeperImageConfigurationReason(source);id attributes=nil;
    if (!reason) {
        attributes=AxsCacheKeeperImageGet(source,"ioQueueAttributes");
        if (((Class (*)(id,SEL))objc_msgSend)(source,sel_registerName("memoryCacheClass"))!=axs_cachekeeper_memory_class) reason=@"memoryBackend";
        else if (((Class (*)(id,SEL))objc_msgSend)(source,sel_registerName("diskCacheClass"))!=axs_cachekeeper_disk_class) reason=@"diskBackend";
        else if (AxsCacheKeeperImageGet(source,"fileManager")) reason=@"customFileManager";
        else if (!AxsCacheKeeperImageSerialAttributes(attributes)) reason=@"initialQueueAttributes";
    }
    id owner=original(object,selector,space,directory,config);
    [axs_cachekeeper_image_observer axs_cachekeeper_observe:owner sourceReason:reason attributes:attributes];return owner;
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
static NSString *AxsCacheKeeperImageRelative(NSString *home,NSString *path) {
    if (![home isKindOfClass:NSString.class] || ![path isKindOfClass:NSString.class] || !path.isAbsolutePath) return nil;
    NSArray *components=[path componentsSeparatedByString:@"/"];
    for (NSUInteger i=1;i<components.count;i++)
        if (![components[i] length] || [components[i] isEqual:@"."] || [components[i] isEqual:@".."] || [components[i] containsString:@"\\"]) return nil;
    // Foundation may return either /var or /private/var for the same system container.
    NSString *resolved=home.stringByResolvingSymlinksInPath;
    for (NSString *base in @[home,home.stringByStandardizingPath,resolved,resolved.stringByStandardizingPath]) {
        NSString *prefix=[base stringByAppendingString:@"/"];
        if ([path hasPrefix:prefix]) {
            NSString *relative=[path substringFromIndex:prefix.length];
            if (axs_cachekeeper_relative_path(relative) && ([relative hasPrefix:@"Library/Caches/"] || [relative hasPrefix:@"tmp/"])) return relative;
        }
    }
    return nil;
}
static NSString *AxsCacheKeeperImageScopeReason(NSDictionary *context,AxsCacheKeeperImageBinding *binding) {
    if (![context[@"valid"] boolValue] || !axs_cachekeeper_state_valid(context[@"appState"]) ||
        !axs_cachekeeper_input_strings(context[@"selected"],axs_cachekeeper_relative_path)) return @"configurationInvalid";
    if (!axs_cachekeeper_app_enabled(context[@"appState"])) return @"appDisabled";
    if (![context[@"installation"] isKindOfClass:NSString.class] || ![context[@"installation"] length]) return @"installationUnverified";
    if (binding.installation && ![binding.installation isEqual:context[@"installation"]]) return @"installationChanged";
    NSString *relative=AxsCacheKeeperImageRelative(context[@"home"],binding.path);
    if (!relative || axs_cachekeeper_retention_path(relative)) return @"scopeNotAuthorized";
    for (NSString *excluded in axs_cachekeeper_exclusions(context[@"appState"]))
        if (axs_cachekeeper_paths_overlap(relative,excluded)) return @"scopeNotAuthorized";
    if ([AxsCacheKeeperCleanupRules hasRetentionRangeForBundle:context[@"bundle"] version:context[@"version"] relativePath:relative]) return @"scopeNotAuthorized";
    NSArray *allowed=axs_cachekeeper_effective_paths(context[@"selected"],context[@"appState"],@[@"Library/Caches",@"tmp"]);
    for (NSString *root in allowed) if (axs_cachekeeper_path_inside(relative,root)) return nil;
    return @"scopeNotAuthorized";
}
static BOOL AxsCacheKeeperImageOverlaps(NSString *left,NSString *right) {
    return left.length && right.length && axs_cachekeeper_paths_overlap(left,right);
}
// Standard SDDiskCache owns a flat directory. A nested/linked/necessary-state entry is not
// representable by removeAllData; leave this owner to the existing per-file cleanup engine.
static BOOL AxsCacheKeeperImageFlatScope(int rootFD,NSString *relative) {
    int copy=dup(rootFD);if (copy<0) return NO;DIR *directory=fdopendir(copy);
    if (!directory) {close(copy);return NO;}
    NSUInteger count=0;BOOL valid=YES;NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+0.25;
    struct dirent *entry;errno=0;
    while ((entry=readdir(directory))) {
        if (!strcmp(entry->d_name,".") || !strcmp(entry->d_name,"..")) continue;
        NSString *name=[NSFileManager.defaultManager stringWithFileSystemRepresentation:entry->d_name length:strlen(entry->d_name)];
        struct stat status;
        if (!name || ++count>100000 || NSProcessInfo.processInfo.systemUptime>deadline ||
            fstatat(rootFD,entry->d_name,&status,AT_SYMLINK_NOFOLLOW) || !S_ISREG(status.st_mode)) {valid=NO;break;}
        errno=0;
    }
    (void)relative;if (errno) valid=NO;closedir(directory);return valid;
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

@implementation AxsCacheKeeperImageCache
- (instancetype)initWithContextProvider:(AxsCacheKeeperImageContextProvider)provider observer:(void (^)(NSDictionary *))observer {
    if ((self=[super init])) {
        _provider=[provider copy];_bindings=[NSMutableArray new];
        _work=dispatch_queue_create("dev.local.cachekeeper.images",DISPATCH_QUEUE_SERIAL);
        _state=@"notObserved";_reason=@"none";_foreground=YES;
        [self axs_cachekeeper_publish];
        _observer=[observer copy];
    }return self;
}
#if AXS_CACHEKEEPER_IMAGE_TESTING
- (void)usePinnedSDKForIntegrationTests { self.pinnedTestSDK=YES; }
- (NSDictionary *)instanceDiagnosticsForIntegrationTests:(id)owner {
    for (AxsCacheKeeperImageBinding *binding in [self axs_cachekeeper_bindings]) if (binding.owner==owner)
        return @{@"initialReason":binding.initialReason ?: @"none",@"currentReason":AxsCacheKeeperImageInstanceReason(binding) ?: @"none",
            @"configKind":AxsCacheKeeperImageConfigKind(binding.config)};
    return @{@"initialReason":@"notObserved",@"currentReason":@"notObserved",@"configKind":@"unsupported"};
}
#endif
- (void)startObserving {
    @synchronized(AxsCacheKeeperImageCache.class) {
        if (axs_cachekeeper_image_init_original) {
            self.supported=AxsCacheKeeperImageMethodsUnchanged();axs_cachekeeper_image_observer=self;return;
        }
        Class image=NSClassFromString(@"SDImageCache"),disk=NSClassFromString(@"SDDiskCache"),config=NSClassFromString(@"SDImageCacheConfig"),memory=NSClassFromString(@"SDMemoryCache");
        const char *imageName=image ? class_getImageName(image) : NULL;
        Dl_info imageInfo={0};Method initializer=image ? class_getInstanceMethod(image,sel_registerName("initWithNamespace:diskCacheDirectory:config:")) : NULL;
        if (!imageName || !disk || !config || !memory || !initializer ||
            strcmp(imageName,class_getImageName(disk) ?: "") || strcmp(imageName,class_getImageName(config) ?: "") || strcmp(imageName,class_getImageName(memory) ?: "") ||
            !dladdr((const void *)method_getImplementation(initializer),&imageInfo)) return;
        NSBundle *bundle=[NSBundle bundleForClass:image];NSString *version=bundle.infoDictionary[@"CFBundleShortVersionString"];
        BOOL framework=[bundle.bundlePath.pathExtension isEqual:@"framework"] && [bundle.bundlePath.lastPathComponent isEqual:@"SDWebImage.framework"];
        BOOL known=(framework && [@[@"5.15.5",@"5.21.7"] containsObject:version]) || AxsCacheKeeperImageKnownUUID(imageInfo.dli_fbase);
#if AXS_CACHEKEEPER_IMAGE_TESTING
        known=known || self.pinnedTestSDK;
#endif
        if (!known) return;
        NSMutableArray *methods=[NSMutableArray new];
        if (!AxsCacheKeeperImageMethod(image,"initWithNamespace:diskCacheDirectory:config:","@",@[@"@",@"@",@"@"],imageInfo.dli_fbase,methods)) return;
        for (NSString *name in @[@"diskCache",@"diskCachePath",@"config",@"ioQueue",@"memoryCache"])
            if (!AxsCacheKeeperImageMethod(image,name.UTF8String,"@",@[],imageInfo.dli_fbase,methods)) return;
        for (NSString *name in @[@"diskCachePath",@"config",@"fileManager"])
            if (!AxsCacheKeeperImageMethod(disk,name.UTF8String,"@",@[],imageInfo.dli_fbase,methods)) return;
        for (NSString *name in @[@"fileManager",@"ioQueueAttributes"])
            if (!AxsCacheKeeperImageMethod(config,name.UTF8String,"@",@[],imageInfo.dli_fbase,methods)) return;
        if (!AxsCacheKeeperImageMethod(config,"diskCacheClass","#",@[],imageInfo.dli_fbase,methods) ||
            !AxsCacheKeeperImageMethod(config,"memoryCacheClass","#",@[],imageInfo.dli_fbase,methods) ||
            !AxsCacheKeeperImageMethod(config,"copyWithZone:","@",@[[NSString stringWithUTF8String:@encode(NSZone *)]],imageInfo.dli_fbase,methods) ||
            !AxsCacheKeeperImageMethod(object_getClass(config),"defaultCacheConfig","@",@[],imageInfo.dli_fbase,methods) ||
            !AxsCacheKeeperImageMethod(memory,"config","@",@[],imageInfo.dli_fbase,methods) ||
            !AxsCacheKeeperImageMethod(memory,"initWithConfig:","@",@[@"@"],imageInfo.dli_fbase,methods) ||
            !AxsCacheKeeperImageMethod(memory,"commonInit","v",@[],imageInfo.dli_fbase,methods) ||
            !AxsCacheKeeperImageMethod(disk,"initWithCachePath:config:","@",@[@"@",@"@"],imageInfo.dli_fbase,methods) ||
            !AxsCacheKeeperImageMethod(disk,"commonInit","v",@[],imageInfo.dli_fbase,methods) ||
            !AxsCacheKeeperImageMethod(disk,"removeAllData","v",@[],imageInfo.dli_fbase,methods) ||
            !AxsCacheKeeperImageMethod(disk,"cachePathForKey:","@",@[@"@"],imageInfo.dli_fbase,methods) ||
            !AxsCacheKeeperImageMethod(disk,"cachePathForKey:inPath:","@",@[@"@",@"@"],imageInfo.dli_fbase,methods) ||
            !AxsCacheKeeperImageMethod(disk,"setData:forKey:","v",@[@"@",@"@"],imageInfo.dli_fbase,methods) ||
            !AxsCacheKeeperImageMethod(disk,"setExtendedData:forKey:","v",@[@"@",@"@"],imageInfo.dli_fbase,methods)) return;
        axs_cachekeeper_image_class=image;axs_cachekeeper_disk_class=disk;axs_cachekeeper_image_config_class=config;axs_cachekeeper_memory_class=memory;
        axs_cachekeeper_image_init_original=(__typeof__(axs_cachekeeper_image_init_original))method_setImplementation(initializer,(IMP)AxsCacheKeeperImageInit);
        axs_cachekeeper_image_data_original=method_setImplementation(class_getInstanceMethod(disk,sel_registerName("setData:forKey:")),(IMP)AxsCacheKeeperImageSetData);
        axs_cachekeeper_image_extended_original=method_setImplementation(class_getInstanceMethod(disk,sel_registerName("setExtendedData:forKey:")),(IMP)AxsCacheKeeperImageSetExtendedData);
        axs_cachekeeper_image_remove_original=method_setImplementation(class_getInstanceMethod(disk,sel_registerName("removeAllData")),(IMP)AxsCacheKeeperImageRemoveAll);
        NSMutableArray *installed=[NSMutableArray new];
        for (NSDictionary *entry in methods) {
            NSMutableDictionary *record=[entry mutableCopy];record[@"implementation"]=[NSValue valueWithPointer:(const void *)class_getMethodImplementation(entry[@"class"],NSSelectorFromString(entry[@"selector"]))];[installed addObject:record];
        }
        axs_cachekeeper_image_methods=installed;axs_cachekeeper_image_observer=self;self.supported=YES;
    }
}
- (NSArray<AxsCacheKeeperImageBinding *> *)axs_cachekeeper_bindings {
    @synchronized(self) {return [self.bindings copy];}
}
- (void)axs_cachekeeper_cancel {
    @synchronized(self) {self.generation++;for (AxsCacheKeeperImageBinding *binding in self.bindings) binding.restricted=NO;}
}
- (void)axs_cachekeeper_observe:(id)owner sourceReason:(NSString *)sourceReason attributes:(id)attributes {
    if (!owner || self.capacityExceeded || object_getClass(owner)!=axs_cachekeeper_image_class || !AxsCacheKeeperImageMethodsUnchanged()) return;
    id disk=AxsCacheKeeperImageGet(owner,"diskCache"),config=AxsCacheKeeperImageGet(owner,"config");
    if (!disk || !config) return;
    AxsCacheKeeperImageBinding *binding=[AxsCacheKeeperImageBinding new];binding.owner=owner;binding.disk=disk;binding.config=config;
    binding.queue=AxsCacheKeeperImageGet(owner,"ioQueue");binding.path=[AxsCacheKeeperImageGet(owner,"diskCachePath") copy];binding.engine=self;
    if (!binding.queue || !binding.path.length) return;
    binding.initialReason=sourceReason ?: AxsCacheKeeperImageStructureReason(owner,disk,config);
    if (!binding.initialReason) {
        binding.memory=AxsCacheKeeperImageGet(owner,"memoryCache");
        binding.initialAttributes=attributes;
        binding.initialFileManager=AxsCacheKeeperImageGet(disk,"fileManager");
        if (AxsCacheKeeperImageGet(config,"ioQueueAttributes")!=attributes) binding.initialReason=@"queueAttributesChanged";
    }
    if (!binding.initialReason)
        dispatch_queue_set_specific(binding.queue,AxsCacheKeeperImageQueueKey,(__bridge void *)binding,NULL);
    binding.home=self.context[@"home"] ?: NSHomeDirectory();
    binding.relative=AxsCacheKeeperImageRelative(binding.home,binding.path);
    @synchronized(self) {
        [self.bindings filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(AxsCacheKeeperImageBinding *item,NSDictionary *unused) {return item.owner || item.pending;}]];
        if (self.bindings.count>=64) {
            // An untracked owner might share any existing path. Stop all previously admitted
            // instances for this process instead of pretending that discovery is complete.
            self.capacityExceeded=YES;self.generation++;
            for (AxsCacheKeeperImageBinding *item in self.bindings) {item.invalidated=YES;item.restricted=NO;}
            dispatch_async(self.work,^{[self axs_cachekeeper_refresh];});return;
        }
        // Registry changes share the same final commit generation as configuration changes.
        // An older refresh snapshot must not re-enable a gate after a new owner appears.
        self.generation++;
        // Revoke conflicting gates immediately, before another SDK queue can write or clear.
        for (AxsCacheKeeperImageBinding *other in self.bindings)
            if ((other.owner || other.pending) && AxsCacheKeeperImageOverlaps(binding.relative,other.relative)) other.restricted=NO;
        [self.bindings addObject:binding];
    }
    // A custom backend never receives a binding; its original methods remain untouched.
    if (object_getClass(disk)==axs_cachekeeper_disk_class) objc_setAssociatedObject(disk,AxsCacheKeeperImageBindingKey,binding,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_async(self.work,^{[self axs_cachekeeper_refresh];});
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
    dispatch_async(self.work,^{[self axs_cachekeeper_refresh];});
}
- (void)axs_cachekeeper_refresh {
    NSUInteger generation;@synchronized(self) {generation=self.generation;}
    NSDictionary *context=self.provider ? self.provider() : @{};
    @synchronized(self) {if (generation!=self.generation) return;}
    self.context=context;
    NSArray *bindings=[self axs_cachekeeper_bindings];
    for (AxsCacheKeeperImageBinding *binding in bindings) {
        binding.restricted=NO;binding.eligible=NO;
        NSString *reason=AxsCacheKeeperImageScopeReason(context,binding);
        if (!reason && !AxsCacheKeeperImageInstanceUnchanged(binding)) reason=@"unsupportedInstance";
        NSString *relative=!reason ? AxsCacheKeeperImageRelative(context[@"home"],binding.path) : nil;
        NSArray *identity=relative ? AxsCacheKeeperImagePathIdentity(context[@"home"],relative,NULL) : nil;
        if (!reason && (!identity || (binding.identity && ![binding.identity isEqual:identity]))) reason=@"pathChanged";
        if (!reason) for (AxsCacheKeeperImageBinding *other in bindings)
            if (other!=binding && (other.owner || other.pending) && AxsCacheKeeperImageOverlaps(relative,AxsCacheKeeperImageRelative(context[@"home"],other.path))) {reason=@"overlappingOwners";break;}
        binding.reason=reason ?: @"none";
        if (!reason) {
            binding.installation=context[@"installation"];binding.relative=relative;binding.home=context[@"home"];
            @synchronized(binding) {if (!binding.identity) binding.identity=identity;}
            binding.eligible=YES;
            @synchronized(self) {if (generation==self.generation) binding.restricted=axs_cachekeeper_wants_restriction(context[@"appState"]);}
        }
    }
    @synchronized(self) {if (generation!=self.generation) return;}
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
    [self axs_cachekeeper_publish];
}
- (void)refreshWithCompletion:(void (^)(void))completion {
    [self axs_cachekeeper_cancel];
    dispatch_async(self.work,^{[self startObserving];[self axs_cachekeeper_refresh];if (completion) completion();});
}
- (void)didBecomeActive {
    @synchronized(self) {self.foreground=YES;self.hasTime=NO;}
    [self refreshWithCompletion:nil];
}
- (void)expireBackgroundTime {
    @synchronized(self) {self.hasTime=NO;self.generation++;}
    dispatch_async(self.work,^{self.reason=@"noBackgroundTime";[self axs_cachekeeper_publish];});
}
- (void)didEnterBackgroundWithTime:(BOOL)hasTime {
    @synchronized(self) {self.foreground=NO;self.hasTime=hasTime;}
    dispatch_async(self.work,^{
        [self axs_cachekeeper_refresh];
        for (AxsCacheKeeperImageBinding *binding in [self axs_cachekeeper_bindings]) {
            if (binding.pending) {self.reason=@"inFlight";continue;}
            if (!binding.eligible) continue;
            NSUInteger generation;BOOL allowed;
            @synchronized(self) {generation=self.generation;allowed=self.hasTime && !self.foreground;}
            if (!allowed) {self.reason=@"noBackgroundTime";continue;}
            binding.pending=YES;NSUInteger flight=++binding.flight;binding.flightDeadline=NSProcessInfo.processInfo.systemUptime+15;
            @synchronized(self) {self.queued++;}self.state=@"queued";[self axs_cachekeeper_publish];
            dispatch_async(binding.queue,^{[self axs_cachekeeper_execute:binding generation:generation];});
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,15*NSEC_PER_SEC),self.work,^{
                if (binding.pending && binding.flight==flight) {self.state=@"timedOut";self.reason=@"inFlight";[self axs_cachekeeper_publish];}
            });
        }
        [self axs_cachekeeper_publish];
    });
}
- (void)axs_cachekeeper_execute:(AxsCacheKeeperImageBinding *)binding generation:(NSUInteger)generation {
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
    if (!reason && !AxsCacheKeeperImageFlatScope(fd,binding.relative)) reason=@"scopeUnverified";
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
        if (!reason) {self.submitted++;submitted=YES;}
    }
    if (submitted) {
        binding.pluginRemoving=YES;
        ((void (*)(id,SEL))objc_msgSend)(disk,sel_registerName("removeAllData"));
        binding.pluginRemoving=NO;
    }
    (void)owner;if (fd>=0) close(fd);
    dispatch_async(self.work,^{
        binding.pending=NO;
        @synchronized(self) {
            if (submitted) {
                self.completed++;
                if (binding.invalidated) {binding.restricted=NO;binding.eligible=NO;}
            }
            else self.skipped++;
            if (generation==self.generation) {
                self.reason=reason ?: @"none";
                if (self.queued==self.completed+self.skipped) self.state=submitted ? @"apiCompleted" : @"blocked";
            }
        }
        [self axs_cachekeeper_publish];
    });
}
- (void)axs_cachekeeper_publish {
    NSUInteger observed=0,eligible=0,restricted=0,writes=0;
    for (AxsCacheKeeperImageBinding *binding in [self axs_cachekeeper_bindings]) {
        if (binding.owner) observed++;
        if (binding.owner && binding.eligible) eligible++;
        if (binding.owner && binding.restricted) restricted++;
        @synchronized(binding) {writes+=binding.blockedWrites;}
    }
    NSDictionary *receipt;
    @synchronized(self) {
        NSString *state=self.state;
        NSUInteger pending=self.queued-self.completed-self.skipped;
        if (!pending && [state isEqual:@"timedOut"]) state=@"ready";
        if (pending && [state isEqual:@"apiCompleted"]) state=@"queued";
        receipt=@{@"schemaVersion":@1,@"sdk":@"SDWebImage",@"state":state ?: @"notObserved",@"reason":self.reason ?: @"none",
            @"observed":@(observed),@"eligible":@(eligible),@"restricted":@(restricted),@"writesBlocked":@(writes),
            @"queued":@(self.queued),@"submitted":@(self.submitted),@"apiCompleted":@(self.completed),@"skipped":@(self.skipped),
            @"pending":@(pending),@"updated":NSDate.date,@"bytesState":@"notMeasured"};
        self.lastReceipt=receipt;
    }
    if (self.observer) self.observer(receipt);
}
- (NSDictionary *)receipt { @synchronized(self) {return self.lastReceipt;} }
@end
