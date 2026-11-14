#import "AxsCacheKeeperInstallation.h"
#import "AxsCacheKeeperPolicy.h"
#import <objc/message.h>
#import <CommonCrypto/CommonDigest.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>

static BOOL axs_cachekeeper_installation_error(NSError **error, NSInteger code, NSString *message) {
    if (error) *error=[NSError errorWithDomain:@"dev.local.cachekeeper.installation" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
static BOOL axs_cachekeeper_installation_string(id value, BOOL nonempty) {
    if (![value isKindOfClass:NSString.class] || (nonempty && ![value length])) return NO;
    unichar zero=0;
    return [value rangeOfString:[NSString stringWithCharacters:&zero length:1]].location==NSNotFound;
}
static BOOL axs_cachekeeper_installation_component(id value) {
    return axs_cachekeeper_installation_string(value,YES) && ![value isEqual:@"."] && ![value isEqual:@".."] &&
        [value rangeOfString:@"/"].location==NSNotFound;
}
static NSArray *axs_cachekeeper_installation_stat(struct stat st) {
    return @[@(st.st_dev),@(st.st_ino),@(st.st_mode),@(st.st_nlink),@(st.st_uid),@(st.st_gid),@(st.st_size),
        @(st.st_mtimespec.tv_sec),@(st.st_mtimespec.tv_nsec),@(st.st_ctimespec.tv_sec),@(st.st_ctimespec.tv_nsec)];
}
static BOOL axs_cachekeeper_installation_same(struct stat a, struct stat b) {
    return [axs_cachekeeper_installation_stat(a) isEqual:axs_cachekeeper_installation_stat(b)];
}
static NSString *axs_cachekeeper_installation_path(NSURL *url, NSError **error) {
    if (![url isKindOfClass:NSURL.class] || !url.isFileURL || !axs_cachekeeper_installation_string(url.path,YES) || !url.path.isAbsolutePath) {
        axs_cachekeeper_installation_error(error,1,@"系统安装包 URL 不可用");return nil;
    }
    NSString *path=url.path;
    // lstat("link/") follows a directory link; remove only trailing separators before checking.
    while (path.length>1 && [path hasSuffix:@"/"]) path=[path substringToIndex:path.length-1];
    if ([path.pathComponents containsObject:@".."] || [path.pathComponents containsObject:@"."] || !axs_cachekeeper_installation_component(path.lastPathComponent)) {
        axs_cachekeeper_installation_error(error,1,@"系统安装包路径无效");return nil;
    }
    return path;
}
// Resolve parent aliases such as /var, while refusing a symlink at the package root itself.
// The original path is rechecked against the open FD after every sample.
static int axs_cachekeeper_installation_open_root(NSString *path, NSError **error) {
    struct stat before,opened;
    if (lstat(path.fileSystemRepresentation,&before) || !S_ISDIR(before.st_mode)) {
        axs_cachekeeper_installation_error(error,2,@"安装包目录缺失、不可读或为链接");return -1;
    }
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    if (fd<0 || fstat(fd,&opened) || !S_ISDIR(opened.st_mode) || !axs_cachekeeper_installation_same(before,opened)) {
        if (fd>=0) close(fd);
        axs_cachekeeper_installation_error(error,2,@"安装包目录在读取时变化或无法打开");return -1;
    }
    return fd;
}
static int axs_cachekeeper_installation_open_file(int root, const char *name, struct stat *identity, NSError **error) {
    struct stat before,opened;
    if (fstatat(root,name,&before,AT_SYMLINK_NOFOLLOW) || !S_ISREG(before.st_mode)) {
        axs_cachekeeper_installation_error(error,3,@"安装文件缺失、为链接或不是普通文件");return -1;
    }
    int fd=openat(root,name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    if (fd<0 || fstat(fd,&opened) || !S_ISREG(opened.st_mode) || !axs_cachekeeper_installation_same(before,opened)) {
        if (fd>=0) close(fd);
        axs_cachekeeper_installation_error(error,3,@"安装文件在读取时变化或无法打开");return -1;
    }
    *identity=opened;return fd;
}
static BOOL axs_cachekeeper_installation_check(int root, int info, int executable, NSString *path, NSString *name,
                                              struct stat rootBefore, struct stat infoBefore, struct stat executableBefore) {
    struct stat a,b;
    if (fstat(root,&a) || lstat(path.fileSystemRepresentation,&b) || !axs_cachekeeper_installation_same(rootBefore,a) || !axs_cachekeeper_installation_same(a,b)) return NO;
    if (fstat(info,&a) || fstatat(root,"Info.plist",&b,AT_SYMLINK_NOFOLLOW) || !axs_cachekeeper_installation_same(infoBefore,a) || !axs_cachekeeper_installation_same(a,b)) return NO;
    if (fstat(executable,&a) || fstatat(root,name.fileSystemRepresentation,&b,AT_SYMLINK_NOFOLLOW) || !axs_cachekeeper_installation_same(executableBefore,a) || !axs_cachekeeper_installation_same(a,b)) return NO;
    return YES;
}
static NSString *axs_cachekeeper_installation_fingerprint(NSArray *parts) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:parts options:0 error:nil];
    if (!data) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
    NSMutableString *result=[NSMutableString new];
    for (NSUInteger i=0;i<sizeof(digest);i++) [result appendFormat:@"%02x",digest[i]];
    return result;
}
NSDictionary *axs_cachekeeper_installation_snapshot(NSURL *bundleURL, NSString *bundleIdentifier, NSString *systemShortVersion, NSError **error) {
    if (error) *error=nil;
    if (!axs_cachekeeper_bundle_id(bundleIdentifier) || !axs_cachekeeper_installation_string(bundleIdentifier,YES) ||
        (systemShortVersion && !axs_cachekeeper_installation_string(systemShortVersion,NO))) {
        axs_cachekeeper_installation_error(error,1,@"系统安装标识或版本类型无效");return nil;
    }
    NSString *path=axs_cachekeeper_installation_path(bundleURL,error);if (!path) return nil;
    int root=axs_cachekeeper_installation_open_root(path,error);if (root<0) return nil;
    int info=-1,executable=-1;NSDictionary *result=nil;
    @try {
        struct stat rootStat,infoStat,executableStat;
        if (fstat(root,&rootStat)) { axs_cachekeeper_installation_error(error,2,@"无法确认安装包目录身份");return nil; }
        info=axs_cachekeeper_installation_open_file(root,"Info.plist",&infoStat,error);if (info<0) return nil;
        if (infoStat.st_size<=0 || infoStat.st_size>1024*1024) { axs_cachekeeper_installation_error(error,4,@"安装信息为空或超过 1 MiB 读取上限");return nil; }
        NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)infoStat.st_size];
        size_t offset=0;NSUInteger interrupts=0;
        while (offset<data.length) {
            ssize_t count=read(info,(unsigned char *)data.mutableBytes+offset,data.length-offset);
            if (count<0 && errno==EINTR && ++interrupts<=4) continue;
            if (count<=0) { axs_cachekeeper_installation_error(error,4,@"安装信息读取不完整");return nil; }
            offset+=(size_t)count;
        }
        id plist=[NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:nil];
        if (![plist isKindOfClass:NSDictionary.class]) { axs_cachekeeper_installation_error(error,5,@"安装信息不是有效字典");return nil; }
        NSString *identifier=plist[@"CFBundleIdentifier"],*name=plist[@"CFBundleExecutable"],*build=plist[@"CFBundleVersion"],*version=plist[@"CFBundleShortVersionString"];
        if (!axs_cachekeeper_installation_string(identifier,YES) || ![identifier isEqual:bundleIdentifier] || !axs_cachekeeper_installation_component(name) ||
            (build && !axs_cachekeeper_installation_string(build,NO)) || (version && !axs_cachekeeper_installation_string(version,NO))) {
            axs_cachekeeper_installation_error(error,5,@"安装信息标识、版本或可执行名称无效");return nil;
        }
        if (version.length && systemShortVersion.length && ![version isEqual:systemShortVersion]) {
            axs_cachekeeper_installation_error(error,6,@"系统版本与安装包版本不一致，等待安装稳定");return nil;
        }
        executable=axs_cachekeeper_installation_open_file(root,name.fileSystemRepresentation,&executableStat,error);if (executable<0) return nil;
        if (!axs_cachekeeper_installation_check(root,info,executable,path,name,rootStat,infoStat,executableStat)) {
            axs_cachekeeper_installation_error(error,6,@"安装文件在读取期间变化，等待安装稳定");return nil;
        }
        NSArray *rootIdentity=axs_cachekeeper_installation_stat(rootStat),*infoIdentity=axs_cachekeeper_installation_stat(infoStat),*executableIdentity=axs_cachekeeper_installation_stat(executableStat);
        NSString *fingerprint=axs_cachekeeper_installation_fingerprint(@[path,bundleIdentifier,version ?: @"",build ?: @"",rootIdentity,infoIdentity,executableIdentity]);
        if (!fingerprint) { axs_cachekeeper_installation_error(error,5,@"无法生成安装身份");return nil; }
        NSMutableDictionary *snapshot=[@{@"fingerprint":fingerprint,@"installationState":build.length && version.length ? @"verified" : @"versionUnknown",
            @"_path":path,@"_systemVersion":systemShortVersion ?: @"",@"_executable":name,@"_root":rootIdentity,@"_info":infoIdentity,@"_main":executableIdentity} mutableCopy];
        if (build.length) snapshot[@"build"]=build;
        if (version.length) snapshot[@"version"]=version;
        result=[snapshot copy];
    } @finally { if (executable>=0) close(executable);if (info>=0) close(info);close(root); }
    return result;
}
BOOL axs_cachekeeper_validate_installation_snapshot(NSDictionary *snapshot, NSURL *currentBundleURL, NSString *currentSystemShortVersion, NSError **error) {
    if (error) *error=nil;
    if (![snapshot isKindOfClass:NSDictionary.class] || !axs_cachekeeper_installation_component(snapshot[@"_executable"]) ||
        (currentSystemShortVersion && !axs_cachekeeper_installation_string(currentSystemShortVersion,NO)))
        return axs_cachekeeper_installation_error(error,1,@"安装身份不可用");
    NSString *path=axs_cachekeeper_installation_path(currentBundleURL,error);if (!path) return NO;
    if (![path isEqual:snapshot[@"_path"]] || ![(currentSystemShortVersion ?: @"") isEqual:snapshot[@"_systemVersion"]])
        return axs_cachekeeper_installation_error(error,6,@"系统安装位置或版本已改变，旧作业已失效");
    int root=axs_cachekeeper_installation_open_root(path,error);if (root<0) return NO;
    int info=-1,executable=-1;BOOL valid=NO;
    @try {
        struct stat rootStat,infoStat,executableStat;
        if (fstat(root,&rootStat)) return axs_cachekeeper_installation_error(error,2,@"无法复核安装目录");
        info=axs_cachekeeper_installation_open_file(root,"Info.plist",&infoStat,error);if (info<0) return NO;
        NSString *name=snapshot[@"_executable"];
        executable=axs_cachekeeper_installation_open_file(root,name.fileSystemRepresentation,&executableStat,error);if (executable<0) return NO;
        valid=[axs_cachekeeper_installation_stat(rootStat) isEqual:snapshot[@"_root"]] && [axs_cachekeeper_installation_stat(infoStat) isEqual:snapshot[@"_info"]] &&
            [axs_cachekeeper_installation_stat(executableStat) isEqual:snapshot[@"_main"]] &&
            axs_cachekeeper_installation_check(root,info,executable,path,name,rootStat,infoStat,executableStat);
        if (!valid) axs_cachekeeper_installation_error(error,6,@"安装包、Info 或主程序身份已变化，旧作业已失效");
    } @finally { if (executable>=0) close(executable);if (info>=0) close(info);close(root); }
    return valid;
}
static id axs_cachekeeper_installation_property(id object, NSString *name) {
    SEL selector=NSSelectorFromString(name);
    return [object respondsToSelector:selector] ? ((id(*)(id,SEL))objc_msgSend)(object,selector) : nil;
}
NSArray *axs_cachekeeper_installed_applications(NSMutableDictionary *cache, NSError **error) {
    if (error) *error=nil;
    id manager=axs_cachekeeper_installation_property(NSClassFromString(@"LSApplicationWorkspace"),@"defaultWorkspace");
    NSArray *installed=axs_cachekeeper_installation_property(manager,@"allInstalledApplications");
    if (![installed isKindOfClass:NSArray.class]) { axs_cachekeeper_installation_error(error,7,@"系统应用列表不可用");return nil; }
    NSMutableDictionary *apps=[NSMutableDictionary new],*nextCache=[NSMutableDictionary new];
    for (id proxy in installed) { @autoreleasepool {
        NSString *type=axs_cachekeeper_installation_property(proxy,@"applicationType");
        NSURL *url=axs_cachekeeper_installation_property(proxy,@"bundleURL");
        NSString *bundle=axs_cachekeeper_installation_property(proxy,@"applicationIdentifier");
        if (!axs_cachekeeper_bundle_id(bundle)) continue;
        NSDictionary *previous=cache[bundle];
        BOOL container=[url isKindOfClass:NSURL.class] && axs_cachekeeper_container_bundle_path(url.path);
        BOOL missingLocation=![url isKindOfClass:NSURL.class] || !url.isFileURL || !url.path.length;
        // Preserve only an already established display classification when LS temporarily omits the URL.
        // The unavailable snapshot below still evicts every former deletion identity and build value.
        BOOL knownThirdParty=missingLocation && [previous[@"entry"][@"source"] isEqual:@"troll"];
        if ([type isEqual:@"System"] && ((!container && !knownThirdParty) || [bundle hasPrefix:@"com.apple."])) continue;
        NSString *name=axs_cachekeeper_installation_property(proxy,@"localizedName");
        NSDictionary *app=axs_cachekeeper_application_entry(bundle,name,type,url);if (!app) continue;
        NSString *effectiveName=app[@"name"];
        NSString *systemVersion=axs_cachekeeper_installation_property(proxy,@"shortVersionString");
        NSError *installationError=nil;
        NSDictionary *snapshot=previous[@"installation"];
        // Existing packages get bounded stat checks. Only new/changed packages re-read Info.plist.
        if (!snapshot || !axs_cachekeeper_validate_installation_snapshot(snapshot,url,systemVersion,nil))
            snapshot=axs_cachekeeper_installation_snapshot(url,bundle,systemVersion,&installationError);
        NSDictionary *cached=previous[@"entry"];
        NSString *source=[type isEqual:@"System"] ? @"troll" : @"user";
        if (snapshot && snapshot==previous[@"installation"] && [cached[@"name"] isEqual:effectiveName] && [cached[@"source"] isEqual:source]) {
            apps[bundle]=cached;nextCache[bundle]=previous;continue;
        }
        NSString *pinyin=[cached[@"name"] isEqual:effectiveName] ? cached[@"pinyin"] : nil;
        if (!pinyin) {
            pinyin=[effectiveName stringByApplyingTransform:NSStringTransformMandarinToLatin reverse:NO] ?: effectiveName;
            pinyin=[pinyin stringByApplyingTransform:NSStringTransformStripCombiningMarks reverse:NO] ?: pinyin;
        }
        NSMutableDictionary *entry=[app mutableCopy];entry[@"source"]=source;entry[@"pinyin"]=pinyin;
        entry[@"installationState"]=snapshot[@"installationState"] ?: @"unavailable";
        if (snapshot[@"version"]) entry[@"version"]=snapshot[@"version"];
        if (snapshot[@"build"]) entry[@"build"]=snapshot[@"build"];
        if (installationError) entry[@"installationError"]=installationError.localizedDescription;
        apps[bundle]=[entry copy];
        // Failed snapshots evict the former identity; the visible APP remains with an explicit state.
        nextCache[bundle]=snapshot ? @{@"installation":snapshot,@"entry":apps[bundle]} : @{@"entry":apps[bundle]};
    }}
    [cache setDictionary:nextCache];
    return [apps.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [a[@"id"] compare:b[@"id"]];}];
}
