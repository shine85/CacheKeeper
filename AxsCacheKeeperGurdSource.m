#import "AxsCacheKeeperGurdSource.h"
#import "AxsCacheKeeperPolicy.h"
#import "AxsCacheKeeperImageLegacySource.h"
#import "AxsCacheKeeperImageMachOObservation.h"
#include <fcntl.h>
#include <unistd.h>
#include <dlfcn.h>
// Captured fixed-version windows: statecode (3), complete facade (1328),
// whitelist and transaction region (4860); none are claimed whole-image hashes.
static const struct {uintptr_t offset;size_t length;const char *sha256;} AxsCacheKeeperGurdWindows[]={
    {318013552,64,"04d88982b69c235c6f3defe44d88b8a21ae7bd507e8325a67597332c2e9a7448"},
    {322842192,64,"ce12b36316757bf25e85792d93b0f6cdb865de37883a10c1aa7e5b23574310f8"},
    {318010328,64,"49b942e8c0fc861e56f8e083437ba8f070082c579a2371acfe19377dd69f1f0b"},
    {564613572,1328,"70368d13cdfedfe4988857c56cc1c72725c81be583776a32398a251cfe02c016"},
    {564686120,4860,"62bd2a6f8ddf3f259f866e4e3381d7a55d5dcf6d4e3d09d4ccdcc031f9f5f196"},
};
static NSArray *axs_cachekeeper_gurd_path_identity(NSString *home,NSString *relative,int *rootFD) {
 if(rootFD) *rootFD=-1;
 if(![home isKindOfClass:NSString.class] || !home.isAbsolutePath || !axs_cachekeeper_relative_path(relative)) {errno=EINVAL;return nil;}
 NSString *resolved=home.stringByResolvingSymlinksInPath;
 int fd=open(resolved.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
 NSMutableArray *chain=[NSMutableArray new];struct stat info;
 if(fd<0) return nil;
 if(fstat(fd,&info) || !S_ISDIR(info.st_mode)) {int code=errno ?: ENOTDIR;close(fd);errno=code;return nil;}
 [chain addObject:@[@(info.st_dev),@(info.st_ino)]];
 for(NSString *part in relative.pathComponents) {
  int next=openat(fd,part.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);int code=next<0 ? errno : 0;
  if(close(fd) && !code) code=errno;fd=next;
  if(code) {if(fd>=0) close(fd);errno=code;return nil;}
  if(fstat(fd,&info)) {code=errno;close(fd);errno=code;return nil;}
  if(!S_ISDIR(info.st_mode)) {close(fd);errno=ENOTDIR;return nil;}
  [chain addObject:@[@(info.st_dev),@(info.st_ino)]];
 }
 if(rootFD) *rootFD=fd;else if(close(fd)) return nil;return [chain copy];
}
NSDictionary *axs_cachekeeper_gurd_bind_root(NSString *root,NSString *home,NSString *installation,NSString **reason) {
 if(reason) *reason=nil;
 if(![root isKindOfClass:NSString.class] || !root.isAbsolutePath || ![home isKindOfClass:NSString.class] || !home.isAbsolutePath ||
 ![installation isKindOfClass:NSString.class] || !installation.length) {if(reason) *reason=@"scopeInvalid";return nil;}
 NSString *relative=nil;
 for(NSString *base in @[home,home.stringByResolvingSymlinksInPath]) {
  NSString *prefix=[base stringByAppendingString:@"/"];
  if([root hasPrefix:prefix]) {relative=[root substringFromIndex:prefix.length];break;}
 }
 if(!axs_cachekeeper_relative_path(relative) || ![relative hasPrefix:@"Library/Application Support/"]) {if(reason) *reason=@"scopeInvalid";return nil;}
 NSArray *identity=axs_cachekeeper_gurd_path_identity(home,relative,NULL);
 if(!identity) {if(reason) *reason=@"rootUnavailable";return nil;}
 NSString *path=[home.stringByResolvingSymlinksInPath stringByAppendingPathComponent:relative];
 struct stat info;
 if(lstat(root.fileSystemRepresentation,&info) || !S_ISDIR(info.st_mode) ||
 info.st_dev!=[identity.lastObject[0] longLongValue] || info.st_ino!=[identity.lastObject[1] unsignedLongLongValue]) {if(reason) *reason=@"rootIdentityChanged";return nil;}
 return @{@"root":path,@"getterRoot":root,@"home":home,@"installation":installation,@"relative":relative,@"identity":identity};
}
NSString *axs_cachekeeper_gurd_binding_reason(NSDictionary *binding,NSString *home,NSString *installation) {
 if(![binding[@"installation"] isEqual:installation] || ![binding[@"home"] isEqual:home]) return @"installationChanged";
 NSArray *current=axs_cachekeeper_gurd_path_identity(home,binding[@"relative"],NULL);
 if(!current) return @"rootUnavailable";
 if(![current isEqual:binding[@"identity"]]) return @"rootIdentityChanged";
 struct stat info;NSArray *leaf=current.lastObject;
 if(lstat([binding[@"getterRoot"] fileSystemRepresentation],&info) || !S_ISDIR(info.st_mode) ||
 info.st_dev!=[leaf[0] longLongValue] || info.st_ino!=[leaf[1] unsignedLongLongValue]) return @"rootIdentityChanged";
 return nil;
}
int axs_cachekeeper_gurd_open_root(NSDictionary *binding) {
 int fd=-1;NSArray *identity=axs_cachekeeper_gurd_path_identity(binding[@"home"],binding[@"relative"],&fd);
 if(!identity) return -1;
 if(![identity isEqual:binding[@"identity"]]) {if(fd>=0) close(fd);errno=ESTALE;return -1;}return fd;
}
static BOOL axs_cachekeeper_gurd_read(uintptr_t address,void *buffer,size_t length,void *context) {
 (void)context;return AxsCacheKeeperImageLegacyRead(address,buffer,length,VM_PROT_READ);
}
static Method axs_cachekeeper_gurd_method(Class cls,const char *selector) {
 Class meta=object_getClass(cls);unsigned count=0;Method found=NULL,*list=class_copyMethodList(meta,&count);
 if(count>4096 || (count && !list)) {free(list);return NULL;}
 for(unsigned i=0;i<count;i++) if(method_getName(list[i])==sel_registerName(selector)) {if(found) {found=NULL;break;}found=list[i];}
 free(list);return found;
}
static NSString *axs_cachekeeper_gurd_identity(NSDictionary *context,IMP originals[4]) {
 NSBundle *main=NSBundle.mainBundle;
 if(![context[@"bundle"] isEqual:@"com.ss.iphone.ugc.Aweme"] || ![context[@"version"] isEqual:@"41.2.0"] || ![context[@"build"] isEqual:@"412021"] ||
 ![main.bundleIdentifier isEqual:context[@"bundle"]] || ![[main objectForInfoDictionaryKey:@"CFBundleShortVersionString"] isEqual:context[@"version"]] ||
 ![[main objectForInfoDictionaryKey:@"CFBundleVersion"] isEqual:context[@"build"]]) return @"unsupportedHost";
 static const char *classes[]={"IESGurdKit","IESGurdKit","IESGurdFilePaths","IESGurdKit","IESGurdFileBusinessManager"};
 static const char *selectors[]={"enable","didSetup","cacheRootDirectoryPath","clearCacheExceptWhitelist:","clearCache:"};
 static const char *types[]={"B16@0:8","B16@0:8","@16@0:8","v20@0:8B16","v20@0:8B16"};
 static const uintptr_t offsets[]={318013552,322842192,318010328,564613800,564688084};
 const void *base=NULL;Method methods[5]={NULL};IMP implementations[5]={NULL};
 for(NSUInteger i=0;i<5;i++) {
  Class cls=objc_getClass(classes[i]);if(!cls) return @"sourceUnavailable";
  Method method=axs_cachekeeper_gurd_method(cls,selectors[i]);const char *type=method ? method_getTypeEncoding(method) : NULL;
  IMP implementation=method ? method_getImplementation(method) : NULL;Dl_info info={0};
  if(!type || strcmp(type,types[i]) || !implementation || !dladdr(AxsCacheKeeperImageLegacyCodeAddress((const void *)implementation),&info) || !info.dli_fbase ||
  (base && base!=info.dli_fbase) || !info.dli_fname || !class_getImageName(cls) || strcmp(class_getImageName(cls),info.dli_fname)) return @"identityMismatch";
  base=info.dli_fbase;if((uintptr_t)AxsCacheKeeperImageLegacyCodeAddress((const void *)implementation)!=(uintptr_t)base+offsets[i]) return @"identityMismatch";
  methods[i]=method;implementations[i]=implementation;
 }
 uint32_t count=_dyld_image_count(),matches=0;if(count>4096) return @"identityMismatch";
 for(uint32_t i=0;i<count;i++) if((const void *)_dyld_get_image_header(i)==base) {
  const char *name=_dyld_get_image_name(i);if(!name || ![[NSString stringWithUTF8String:name].lastPathComponent isEqual:@"AwemeCore"]) return @"identityMismatch";matches++;
 }
 if(matches!=1) return @"identityMismatch";
 NSDictionary *metadata=AxsCacheKeeperImageMachOObservation((uintptr_t)base,axs_cachekeeper_gurd_read,NULL);
 if(![metadata[@"state"] isEqual:@"complete"] || ![metadata[@"uuid"] isEqual:@"cc3b646814e43c7fa8708f1eb5f4adeb"] ||
 [metadata[@"fileType"] unsignedIntegerValue]!=MH_DYLIB || [metadata[@"cpuType"] intValue]!=CPU_TYPE_ARM64) return @"identityMismatch";
 for(NSUInteger i=0;i<sizeof(AxsCacheKeeperGurdWindows)/sizeof(AxsCacheKeeperGurdWindows[0]);i++) {
  size_t length=AxsCacheKeeperGurdWindows[i].length;unsigned char first[4860],second[4860],digest[CC_SHA256_DIGEST_LENGTH];
  uintptr_t address=(uintptr_t)base+AxsCacheKeeperGurdWindows[i].offset;
  if(length>sizeof(first) || !AxsCacheKeeperImageLegacyRead(address,first,length,VM_PROT_READ|VM_PROT_EXECUTE) ||
  !AxsCacheKeeperImageLegacyRead(address,second,length,VM_PROT_READ|VM_PROT_EXECUTE) || memcmp(first,second,length)) return @"identityMismatch";
  CC_SHA256(first,(CC_LONG)length,digest);char hex[65];for(NSUInteger n=0;n<32;n++) snprintf(hex+n*2,3,"%02x",digest[n]);
  if(strcmp(hex,AxsCacheKeeperGurdWindows[i].sha256)) return @"identityMismatch";
 }
 if(count!=_dyld_image_count()) return @"identityMismatch";
 for(NSUInteger i=0;i<5;i++) if(method_getImplementation(methods[i])!=implementations[i]) return @"identityMismatch";
 if(originals) for(NSUInteger i=0;i<4;i++) originals[i]=implementations[i];return nil;
}
@implementation AxsCacheKeeperGurdSource
- (NSDictionary *)prepareWithContext:(NSDictionary *)context reason:(NSString **)reason {
 IMP methods[4]={NULL};NSString *failure=axs_cachekeeper_gurd_identity(context,methods);if(reason) *reason=failure;if(failure) return nil;
 @try {
  Class kit=objc_getClass("IESGurdKit");
  if(!((BOOL (*)(id,SEL))methods[0])(kit,sel_registerName("enable")) || !((BOOL (*)(id,SEL))methods[1])(kit,sel_registerName("didSetup"))) {if(reason) *reason=@"hostNotReady";return nil;}
  id root=((id (*)(id,SEL))methods[2])(objc_getClass("IESGurdFilePaths"),sel_registerName("cacheRootDirectoryPath"));
  return axs_cachekeeper_gurd_bind_root(root,context[@"home"],context[@"installation"],reason);
 } @catch(NSException *exception) {(void)exception;if(reason) *reason=@"sourceException";return nil;}
}
- (NSString *)validateBinding:(NSDictionary *)binding context:(NSDictionary *)context {
 NSString *failure=axs_cachekeeper_gurd_identity(context,NULL);if(failure) return failure;
 return axs_cachekeeper_gurd_binding_reason(binding,context[@"home"],context[@"installation"]);
}
- (BOOL)submitBinding:(NSDictionary *)binding context:(NSDictionary *)context authorization:(BOOL (^)(void))authorization reason:(NSString **)reason {
 // Re-read setup and the actual host root immediately before the verified call;
 // never convert a prepared path or caller directory selection into host scope.
 NSString *failure=nil;NSDictionary *current=[self prepareWithContext:context reason:&failure];
 if(!failure && (!current || ![current isEqual:binding])) failure=@"rootIdentityChanged";
 IMP methods[4]={NULL};if(!failure) failure=axs_cachekeeper_gurd_identity(context,methods);
 if(!failure) failure=axs_cachekeeper_gurd_binding_reason(binding,context[@"home"],context[@"installation"]);
 if(failure) {if(reason) *reason=failure;return NO;}
 if(!authorization || !authorization()) {if(reason) *reason=@"revoked";return NO;}
 // Preserve authenticated IMP for invocation; the host owns its channel queues.
 // Exceptions propagate so the engine can retain enteredUnknown truthfully.
 ((void (*)(id,SEL,BOOL))methods[3])(objc_getClass("IESGurdKit"),sel_registerName("clearCacheExceptWhitelist:"),YES);
 if(reason) *reason=nil;return YES;
}
@end
