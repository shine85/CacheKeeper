#import "AxsCacheKeeperInstallation.h"
#import "AxsCacheKeeperPolicy.h"
#import <objc/message.h>
#import <CommonCrypto/CommonDigest.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>
#include <math.h>

#if defined(AXS_CACHEKEEPER_INSTALLATION_TESTING)
extern ssize_t axs_cachekeeper_installation_test_read(int fd, void *buffer, size_t length);
#define axs_cachekeeper_installation_read axs_cachekeeper_installation_test_read
#else
#define axs_cachekeeper_installation_read read
#endif

static BOOL axs_cachekeeper_installation_error(NSError **error, NSInteger code, NSString *message,
                                              NSString *target, NSString *operation, int number) {
    if (error) *error=[NSError errorWithDomain:@"dev.local.cachekeeper.installation" code:code
        userInfo:@{NSLocalizedDescriptionKey:message,@"detail":@{@"target":target,@"operation":operation,@"errno":@(number)}}];
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
        axs_cachekeeper_installation_error(error,1,@"系统安装包 URL 不可用",@"input",@"url",0);return nil;
    }
    NSString *path=url.path;
    // lstat("link/") follows a directory link; remove only trailing separators before checking.
    while (path.length>1 && [path hasSuffix:@"/"]) path=[path substringToIndex:path.length-1];
    if ([path.pathComponents containsObject:@".."] || [path.pathComponents containsObject:@"."] || !axs_cachekeeper_installation_component(path.lastPathComponent)) {
        axs_cachekeeper_installation_error(error,1,@"系统安装包路径无效",@"input",@"path",0);return nil;
    }
    return path;
}
// Resolve parent aliases such as /var, while refusing a symlink at the package root itself.
// The original path is rechecked against the open FD after every sample.
static int axs_cachekeeper_installation_open_root(NSString *path, NSError **error) {
    struct stat before,opened;
    if (lstat(path.fileSystemRepresentation,&before)) {
        int number=errno;axs_cachekeeper_installation_error(error,2,@"无法读取安装包目录属性",@"root",@"stat",number);return -1;
    }
    if (!S_ISDIR(before.st_mode)) {
        axs_cachekeeper_installation_error(error,2,@"安装包不是目录或为链接",@"root",@"type",0);return -1;
    }
    // The root FD is used only for metadata and relative child opens, never enumeration.
    int fd=open(path.fileSystemRepresentation,O_SEARCH|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    if (fd<0) {
        int number=errno;axs_cachekeeper_installation_error(error,2,@"无法打开安装包目录",@"root",@"open",number);return -1;
    }
    if (fstat(fd,&opened)) {
        int number=errno;close(fd);axs_cachekeeper_installation_error(error,2,@"无法读取已打开安装目录属性",@"root",@"fstat",number);return -1;
    }
    if (!S_ISDIR(opened.st_mode)) {
        close(fd);axs_cachekeeper_installation_error(error,2,@"已打开安装包不是目录",@"root",@"type",0);return -1;
    }
    if (!axs_cachekeeper_installation_same(before,opened)) {
        close(fd);axs_cachekeeper_installation_error(error,2,@"安装包目录在打开时变化",@"root",@"openIdentity",0);return -1;
    }
    return fd;
}
static int axs_cachekeeper_installation_open_file(int root, const char *name, NSString *target, struct stat *identity, NSError **error) {
    struct stat before,opened;
    if (fstatat(root,name,&before,AT_SYMLINK_NOFOLLOW)) {
        int number=errno;axs_cachekeeper_installation_error(error,3,@"无法读取安装文件属性",target,@"stat",number);return -1;
    }
    if (!S_ISREG(before.st_mode)) {
        axs_cachekeeper_installation_error(error,3,@"安装文件为链接或不是普通文件",target,@"type",0);return -1;
    }
    int fd=openat(root,name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    if (fd<0) {
        int number=errno;axs_cachekeeper_installation_error(error,3,@"无法打开安装文件",target,@"open",number);return -1;
    }
    if (fstat(fd,&opened)) {
        int number=errno;close(fd);axs_cachekeeper_installation_error(error,3,@"无法读取已打开安装文件属性",target,@"fstat",number);return -1;
    }
    if (!S_ISREG(opened.st_mode)) {
        close(fd);axs_cachekeeper_installation_error(error,3,@"已打开安装文件不是普通文件",target,@"type",0);return -1;
    }
    if (!axs_cachekeeper_installation_same(before,opened)) {
        close(fd);axs_cachekeeper_installation_error(error,3,@"安装文件在打开时变化",target,@"openIdentity",0);return -1;
    }
    *identity=opened;return fd;
}
static BOOL axs_cachekeeper_installation_recheck(int root, int fd, const char *name, NSString *path,
    NSString *target, struct stat before, NSError **error) {
    struct stat a,b;
    if (fstat(fd,&a)) {
        int number=errno;return axs_cachekeeper_installation_error(error,6,@"无法复核已打开安装身份",target,@"recheckFD",number);
    }
    if (path ? lstat(path.fileSystemRepresentation,&b) : fstatat(root,name,&b,AT_SYMLINK_NOFOLLOW)) {
        int number=errno;return axs_cachekeeper_installation_error(error,6,@"无法复核当前安装路径身份",target,@"recheckPath",number);
    }
    if (!axs_cachekeeper_installation_same(before,a) || !axs_cachekeeper_installation_same(a,b))
        return axs_cachekeeper_installation_error(error,6,@"安装文件在读取期间变化，等待安装稳定",target,@"recheckIdentity",0);
    return YES;
}
static BOOL axs_cachekeeper_installation_check(int root, int info, int executable, NSString *path, NSString *name,
    struct stat rootBefore, struct stat infoBefore, struct stat executableBefore, NSError **error) {
    return axs_cachekeeper_installation_recheck(root,root,NULL,path,@"root",rootBefore,error) &&
        axs_cachekeeper_installation_recheck(root,info,"Info.plist",nil,@"info",infoBefore,error) &&
        axs_cachekeeper_installation_recheck(root,executable,name.fileSystemRepresentation,nil,@"main",executableBefore,error);
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
    if (!axs_cachekeeper_bundle_id(bundleIdentifier) || !axs_cachekeeper_installation_string(bundleIdentifier,YES)) {
        axs_cachekeeper_installation_error(error,1,@"系统安装标识无效",@"input",@"identifier",0);return nil;
    }
    if (systemShortVersion && !axs_cachekeeper_installation_string(systemShortVersion,NO)) {
        axs_cachekeeper_installation_error(error,1,@"系统安装版本类型无效",@"input",@"version",0);return nil;
    }
    NSString *path=axs_cachekeeper_installation_path(bundleURL,error);if (!path) return nil;
    int root=axs_cachekeeper_installation_open_root(path,error);if (root<0) return nil;
    int info=-1,executable=-1;NSDictionary *result=nil;
    @try {
        struct stat rootStat,infoStat,executableStat;
        if (fstat(root,&rootStat)) {
            int number=errno;axs_cachekeeper_installation_error(error,2,@"无法确认安装包目录身份",@"root",@"snapshotStat",number);return nil;
        }
        info=axs_cachekeeper_installation_open_file(root,"Info.plist",@"info",&infoStat,error);if (info<0) return nil;
        if (infoStat.st_size<=0 || infoStat.st_size>1024*1024) {
            axs_cachekeeper_installation_error(error,4,@"安装信息为空或超过 1 MiB 读取上限",@"info",@"size",0);return nil;
        }
        NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)infoStat.st_size];
        size_t offset=0;NSUInteger interrupts=0;
        while (offset<data.length) {
            ssize_t count=axs_cachekeeper_installation_read(info,(unsigned char *)data.mutableBytes+offset,data.length-offset);
            int number=count<0 ? errno : 0;
            if (count<0 && number==EINTR && ++interrupts<=4) continue;
            if (count<=0) { axs_cachekeeper_installation_error(error,4,@"安装信息读取不完整",@"info",@"read",number);return nil; }
            offset+=(size_t)count;
        }
        id plist=[NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:nil];
        if (!plist) { axs_cachekeeper_installation_error(error,5,@"无法解析安装信息",@"info",@"parse",0);return nil; }
        if (![plist isKindOfClass:NSDictionary.class]) {
            axs_cachekeeper_installation_error(error,5,@"安装信息不是字典",@"info",@"metadataType",0);return nil;
        }
        NSString *identifier=plist[@"CFBundleIdentifier"],*name=plist[@"CFBundleExecutable"],*build=plist[@"CFBundleVersion"],*version=plist[@"CFBundleShortVersionString"];
        if (!axs_cachekeeper_installation_string(identifier,YES)) {
            axs_cachekeeper_installation_error(error,5,@"安装信息标识无效",@"info",@"identifier",0);return nil;
        }
        if (![identifier isEqual:bundleIdentifier]) {
            axs_cachekeeper_installation_error(error,5,@"安装信息标识与系统登记不符",@"info",@"identifierMismatch",0);return nil;
        }
        if (!axs_cachekeeper_installation_component(name)) {
            axs_cachekeeper_installation_error(error,5,@"安装信息可执行名称无效",@"info",@"executable",0);return nil;
        }
        if (build && !axs_cachekeeper_installation_string(build,NO)) {
            axs_cachekeeper_installation_error(error,5,@"安装信息构建号类型无效",@"info",@"build",0);return nil;
        }
        if (version && !axs_cachekeeper_installation_string(version,NO)) {
            axs_cachekeeper_installation_error(error,5,@"安装信息版本类型无效",@"info",@"version",0);return nil;
        }
        if (version.length && systemShortVersion.length && ![version isEqual:systemShortVersion]) {
            axs_cachekeeper_installation_error(error,6,@"系统版本与安装包版本不一致，等待安装稳定",@"info",@"versionMismatch",0);return nil;
        }
        executable=axs_cachekeeper_installation_open_file(root,name.fileSystemRepresentation,@"main",&executableStat,error);if (executable<0) return nil;
        if (!axs_cachekeeper_installation_check(root,info,executable,path,name,rootStat,infoStat,executableStat,error)) return nil;
        NSArray *rootIdentity=axs_cachekeeper_installation_stat(rootStat),*infoIdentity=axs_cachekeeper_installation_stat(infoStat),*executableIdentity=axs_cachekeeper_installation_stat(executableStat);
        NSString *fingerprint=axs_cachekeeper_installation_fingerprint(@[path,bundleIdentifier,version ?: @"",build ?: @"",rootIdentity,infoIdentity,executableIdentity]);
        if (!fingerprint) { axs_cachekeeper_installation_error(error,5,@"无法生成安装身份",@"snapshot",@"fingerprint",0);return nil; }
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
    if (![snapshot isKindOfClass:NSDictionary.class])
        return axs_cachekeeper_installation_error(error,1,@"安装身份不可用",@"snapshot",@"shape",0);
    if (!axs_cachekeeper_installation_component(snapshot[@"_executable"]))
        return axs_cachekeeper_installation_error(error,1,@"安装身份可执行名称无效",@"snapshot",@"executable",0);
    if (currentSystemShortVersion && !axs_cachekeeper_installation_string(currentSystemShortVersion,NO))
        return axs_cachekeeper_installation_error(error,1,@"系统安装版本类型无效",@"input",@"version",0);
    NSString *path=axs_cachekeeper_installation_path(currentBundleURL,error);if (!path) return NO;
    if (![path isEqual:snapshot[@"_path"]])
        return axs_cachekeeper_installation_error(error,6,@"系统安装位置已改变，旧作业已失效",@"snapshot",@"path",0);
    if (![(currentSystemShortVersion ?: @"") isEqual:snapshot[@"_systemVersion"]])
        return axs_cachekeeper_installation_error(error,6,@"系统安装版本已改变，旧作业已失效",@"snapshot",@"version",0);
    int root=axs_cachekeeper_installation_open_root(path,error);if (root<0) return NO;
    int info=-1,executable=-1;BOOL valid=NO;
    @try {
        struct stat rootStat,infoStat,executableStat;
        if (fstat(root,&rootStat)) {
            int number=errno;return axs_cachekeeper_installation_error(error,2,@"无法复核安装目录",@"root",@"snapshotStat",number);
        }
        info=axs_cachekeeper_installation_open_file(root,"Info.plist",@"info",&infoStat,error);if (info<0) return NO;
        NSString *name=snapshot[@"_executable"];
        executable=axs_cachekeeper_installation_open_file(root,name.fileSystemRepresentation,@"main",&executableStat,error);if (executable<0) return NO;
        if (![axs_cachekeeper_installation_stat(rootStat) isEqual:snapshot[@"_root"]])
            return axs_cachekeeper_installation_error(error,6,@"安装目录身份已变化，旧作业已失效",@"root",@"snapshotIdentity",0);
        if (![axs_cachekeeper_installation_stat(infoStat) isEqual:snapshot[@"_info"]])
            return axs_cachekeeper_installation_error(error,6,@"安装信息身份已变化，旧作业已失效",@"info",@"snapshotIdentity",0);
        if (![axs_cachekeeper_installation_stat(executableStat) isEqual:snapshot[@"_main"]])
            return axs_cachekeeper_installation_error(error,6,@"主程序身份已变化，旧作业已失效",@"main",@"snapshotIdentity",0);
        valid=axs_cachekeeper_installation_check(root,info,executable,path,name,rootStat,infoStat,executableStat,error);
    } @finally { if (executable>=0) close(executable);if (info>=0) close(info);close(root); }
    return valid;
}
static id axs_cachekeeper_installation_property(id object, NSString *name) {
    SEL selector=NSSelectorFromString(name);
    return [object respondsToSelector:selector] ? ((id(*)(id,SEL))objc_msgSend)(object,selector) : nil;
}
// These private system getters are object-returning, zero-argument selectors in the checked SDK.
// A missing getter, nil response, and incompatible runtime signature remain separate facts.
static id axs_cachekeeper_coverage_property(id object, NSString *name, NSString **state) {
    SEL selector=NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) { *state=@"missingSelector";return nil; }
    NSMethodSignature *signature=[object methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments!=2 || signature.methodReturnType[0]!='@' ||
        signature.methodReturnLength!=sizeof(id)) { *state=@"invalid";return nil; }
    @try {
        id value=((id(*)(id,SEL))objc_msgSend)(object,selector);
        *state=value ? @"available" : @"unavailable";return value;
    } @catch (NSException *exception) {
        (void)exception;*state=@"invalid";return nil;
    }
}
static NSString *axs_cachekeeper_coverage_url(id value) {
    if (![value isKindOfClass:NSURL.class]) return nil;
    NSURL *url=value;
    if (!url.isFileURL || url.host.length || url.user.length || url.password.length || url.port || url.query || url.fragment ||
        !axs_cachekeeper_installation_string(url.absoluteString,YES) || url.absoluteString.length>PATH_MAX ||
        !axs_cachekeeper_installation_string(url.path,YES) || !url.path.isAbsolutePath || [url.path isEqual:@"/"] ||
        [url.path.pathComponents containsObject:@".."] || [url.path.pathComponents containsObject:@"."]) return nil;
    // Exact URL string identity only: do not resolve aliases, stat directories, or imply physical uniqueness.
    return url.absoluteString;
}
static NSArray *axs_cachekeeper_coverage_count_keys(void) {
    return @[@"observedSourceCount",@"missingSelectorCount",@"notProvidedCount",@"invalidSourceCount",@"invalidAssociationCount",
        @"ownerMismatchCount",@"unavailableOwnerCount",@"truncatedCount"];
}
static NSMutableDictionary *axs_cachekeeper_coverage_role(void) {
    NSMutableDictionary *role=[NSMutableDictionary new];
    for (NSString *key in axs_cachekeeper_coverage_count_keys()) role[key]=@0;
    role[@"_associations"]=[NSMutableDictionary new];role[@"_invalidAssociations"]=[NSMutableSet new];return role;
}
static void axs_cachekeeper_coverage_increment(NSMutableDictionary *role, NSString *key) {
    role[key]=@([role[key] unsignedIntegerValue]+1);
}
static BOOL axs_cachekeeper_coverage_source(NSMutableDictionary *role, NSString *state) {
    if ([state isEqual:@"available"]) return YES;
    axs_cachekeeper_coverage_increment(role,[state isEqual:@"missingSelector"] ? @"missingSelectorCount" :
        [state isEqual:@"invalid"] ? @"invalidSourceCount" : @"notProvidedCount");return NO;
}
static void axs_cachekeeper_coverage_associate(NSMutableDictionary *role, NSArray *identity, NSString *url) {
    NSMutableDictionary *associations=role[@"_associations"];NSMutableSet *invalid=role[@"_invalidAssociations"];
    if ([invalid containsObject:identity]) return;
    NSString *previous=associations[identity];
    if (previous && ![previous isEqual:url]) {
        [associations removeObjectForKey:identity];[invalid addObject:identity];
        axs_cachekeeper_coverage_increment(role,@"invalidAssociationCount");return;
    }
    associations[identity]=url;
}
static BOOL axs_cachekeeper_coverage_budget(NSMutableDictionary *role, NSUInteger *used) {
    // Shared per-role work budget bounds private URL/identifier sets across all owners.
    if (*used>=16384) { axs_cachekeeper_coverage_increment(role,@"truncatedCount");return NO; }
    (*used)++;return YES;
}
static void axs_cachekeeper_coverage_registration(id proxy, NSString *owner, NSMutableDictionary *home,
    NSMutableDictionary *group, NSMutableDictionary *extension, NSUInteger *groupUsed, NSUInteger *extensionUsed) {
    NSString *state=nil;
    id value=axs_cachekeeper_coverage_property(proxy,@"dataContainerURL",&state);
    if ([state isEqual:@"unavailable"]) {
        // A present dataContainerURL getter returning nil explicitly reports no independent home.
        axs_cachekeeper_coverage_increment(home,@"observedSourceCount");axs_cachekeeper_coverage_increment(home,@"notProvidedCount");
    } else if (axs_cachekeeper_coverage_source(home,state)) {
        NSString *url=axs_cachekeeper_coverage_url(value);
        if (url) { axs_cachekeeper_coverage_increment(home,@"observedSourceCount");axs_cachekeeper_coverage_associate(home,@[owner,@"home"],url); }
        else axs_cachekeeper_coverage_increment(home,@"invalidSourceCount");
    }
    value=axs_cachekeeper_coverage_property(proxy,@"groupContainerURLs",&state);
    if (axs_cachekeeper_coverage_source(group,state)) {
        if (![value isKindOfClass:NSDictionary.class]) axs_cachekeeper_coverage_increment(group,@"invalidSourceCount");
        else {
            axs_cachekeeper_coverage_increment(group,@"observedSourceCount");
            for (id identifier in value) {
                if (!axs_cachekeeper_coverage_budget(group,groupUsed)) break;
                NSString *url=axs_cachekeeper_coverage_url(value[identifier]);
                if (!axs_cachekeeper_bundle_id(identifier) || !url) axs_cachekeeper_coverage_increment(group,@"invalidAssociationCount");
                else axs_cachekeeper_coverage_associate(group,@[owner,identifier],url);
            }
        }
    }
    // Extensions and groups are sampled even when no independent home exists.
    value=axs_cachekeeper_coverage_property(proxy,@"plugInKitPlugins",&state);
    if (!axs_cachekeeper_coverage_source(extension,state)) return;
    if (![value isKindOfClass:NSArray.class]) { axs_cachekeeper_coverage_increment(extension,@"invalidSourceCount");return; }
    axs_cachekeeper_coverage_increment(extension,@"observedSourceCount");
    for (id plugin in value) {
        if (!axs_cachekeeper_coverage_budget(extension,extensionUsed)) break;
        NSString *identifierState=nil,*parentState=nil,*ownerState=nil,*urlState=nil;
        id identifier=axs_cachekeeper_coverage_property(plugin,@"pluginIdentifier",&identifierState);
        if (!axs_cachekeeper_bundle_id(identifier)) {
            if (![identifierState isEqual:@"available"]) axs_cachekeeper_coverage_source(extension,identifierState);
            axs_cachekeeper_coverage_increment(extension,@"invalidAssociationCount");continue;
        }
        id parent=axs_cachekeeper_coverage_property(plugin,@"containingBundle",&parentState);
        id containingOwner=parent ? axs_cachekeeper_coverage_property(parent,@"bundleIdentifier",&ownerState) : nil;
        if (!axs_cachekeeper_bundle_id(containingOwner)) {
            if (![parentState isEqual:@"available"]) axs_cachekeeper_coverage_source(extension,parentState);
            else if (![ownerState isEqual:@"available"]) axs_cachekeeper_coverage_source(extension,ownerState);
            axs_cachekeeper_coverage_increment(extension,@"unavailableOwnerCount");continue;
        }
        if (![containingOwner isEqual:owner]) { axs_cachekeeper_coverage_increment(extension,@"ownerMismatchCount");continue; }
        // Plugin identity spans owners; a contradictory observation revokes the ID for this sample.
        NSArray *identity=@[identifier];
        NSMutableSet *invalid=extension[@"_invalidAssociations"];
        if ([invalid containsObject:identity]) continue;
        NSMutableDictionary *owners=extension[@"_pluginOwners"];
        if (!owners) extension[@"_pluginOwners"]=owners=[NSMutableDictionary new];
        NSString *previousOwner=owners[identifier];
        if (previousOwner && ![previousOwner isEqual:owner]) {
            [extension[@"_associations"] removeObjectForKey:identity];[invalid addObject:identity];
            axs_cachekeeper_coverage_increment(extension,@"invalidAssociationCount");continue;
        }
        owners[identifier]=owner;
        id dataURL=axs_cachekeeper_coverage_property(plugin,@"dataContainerURL",&urlState);
        if (!axs_cachekeeper_coverage_source(extension,urlState)) continue;
        NSString *url=axs_cachekeeper_coverage_url(dataURL);
        if (!url) { axs_cachekeeper_coverage_increment(extension,@"invalidAssociationCount");continue; }
        axs_cachekeeper_coverage_associate(extension,identity,url);
    }
}
static NSDictionary *axs_cachekeeper_coverage_finish_role(NSMutableDictionary *role, BOOL home, NSMutableSet *allURLs) {
    NSMutableDictionary *out=[NSMutableDictionary new];
    NSUInteger issues=0;
    for (NSString *key in axs_cachekeeper_coverage_count_keys()) {
        out[key]=role[key];
        if (![key isEqual:@"observedSourceCount"] && !(home && [key isEqual:@"notProvidedCount"])) issues += [role[key] unsignedIntegerValue];
    }
    BOOL observed=[role[@"observedSourceCount"] unsignedIntegerValue]>0;
    out[@"state"]=observed ? (issues ? @"partial" : @"available") :
        ([role[@"invalidSourceCount"] unsignedIntegerValue] ? @"invalid" : @"unavailable");
    if (observed) {
        NSDictionary *associations=role[@"_associations"];
        NSSet *urls=[NSSet setWithArray:associations.allValues];[allURLs unionSet:urls];
        out[@"registeredURLCount"]=@(urls.count);out[@"associationCount"]=@(associations.count);
    }
    return out;
}
static NSMutableDictionary *axs_cachekeeper_coverage_base(NSString *state) {
    return [@{@"schemaVersion":@1,@"state":state,@"scope":@"allSystemRegistrations",@"mode":@"systemMetadata",
        @"registeredURLIdentity":@"exactURLString",@"filesystemAccess":@"notChecked",@"cleanupEligibility":@"notGranted"} mutableCopy];
}
static BOOL axs_cachekeeper_coverage_number(id value) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()) return NO;
    double number=[value doubleValue];return isfinite(number) && number>=0 && number==trunc(number) && number<=9007199254740991.0;
}
NSDictionary *axs_cachekeeper_container_coverage_projection(id coverage) {
    NSMutableDictionary *out=axs_cachekeeper_coverage_base(coverage ? @"invalid" : @"notObserved");
    if (![coverage isKindOfClass:NSDictionary.class]) return out;
    if (!axs_cachekeeper_coverage_number(coverage[@"schemaVersion"]) || [coverage[@"schemaVersion"] integerValue]!=1 ||
        ![@[@"available",@"partial",@"unavailable"] containsObject:coverage[@"state"]] ||
        ![@[@"available",@"unavailable",@"invalid",@"missingSelector"] containsObject:coverage[@"sourceState"]]) return out;
    if (![coverage[@"sourceState"] isEqual:@"available"]) {
        if (![coverage[@"state"] isEqual:@"unavailable"] || coverage[@"observedRegistrations"]) return out;
        out[@"state"]=@"unavailable";out[@"sourceState"]=coverage[@"sourceState"];return out;
    }
    for (NSString *key in @[@"observedRegistrations",@"invalidRegistrationCount",@"truncatedRegistrationCount",@"allRolesUniqueRegisteredURLCount"])
        if (!axs_cachekeeper_coverage_number(coverage[key])) return out;
    if ([coverage[@"observedRegistrations"] unsignedIntegerValue]>4096 ||
        [coverage[@"invalidRegistrationCount"] unsignedIntegerValue]>[coverage[@"observedRegistrations"] unsignedIntegerValue]) return out;
    id lower=coverage[@"countsAreLowerBounds"];
    if (![lower isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)lower)!=CFBooleanGetTypeID()) return out;
    NSMutableDictionary *roles=[NSMutableDictionary new];BOOL partial=NO;NSUInteger totalURLs=0,maxURLs=0;
    for (NSString *name in @[@"home",@"group",@"extension"]) {
        id role=coverage[name];
        if (![role isKindOfClass:NSDictionary.class] || ![@[@"available",@"partial",@"unavailable",@"invalid"] containsObject:role[@"state"]]) return out;
        NSMutableDictionary *projected=[@{@"state":role[@"state"]} mutableCopy];
        for (NSString *key in axs_cachekeeper_coverage_count_keys()) {
            if (!axs_cachekeeper_coverage_number(role[key])) return out;projected[key]=role[key];
        }
        NSUInteger sourceCount=[role[@"observedSourceCount"] unsignedIntegerValue],issues=0;
        if (sourceCount>[coverage[@"observedRegistrations"] unsignedIntegerValue]-[coverage[@"invalidRegistrationCount"] unsignedIntegerValue] ||
            ([name isEqual:@"home"] && [role[@"notProvidedCount"] unsignedIntegerValue]>sourceCount)) return out;
        for (NSString *key in axs_cachekeeper_coverage_count_keys())
            if (![key isEqual:@"observedSourceCount"] && !([name isEqual:@"home"] && [key isEqual:@"notProvidedCount"])) issues+=[role[key] unsignedIntegerValue];
        BOOL observed=sourceCount>0;
        BOOL emptyRegistry=[coverage[@"observedRegistrations"] unsignedIntegerValue]==0 &&
            ![coverage[@"invalidRegistrationCount"] unsignedIntegerValue] && ![coverage[@"truncatedRegistrationCount"] unsignedIntegerValue];
        BOOL exactEmpty=emptyRegistry && [role[@"state"] isEqual:@"available"];
        NSString *expected=observed ? (issues ? @"partial" : @"available") :
            ([role[@"invalidSourceCount"] unsignedIntegerValue] ? @"invalid" : @"unavailable");
        if (exactEmpty ? (issues || [role[@"notProvidedCount"] unsignedIntegerValue]) : ![role[@"state"] isEqual:expected]) return out;
        if (observed || exactEmpty) {
            if (!axs_cachekeeper_coverage_number(role[@"registeredURLCount"]) || !axs_cachekeeper_coverage_number(role[@"associationCount"]) ||
                [role[@"registeredURLCount"] unsignedLongLongValue]>[role[@"associationCount"] unsignedLongLongValue]) return out;
            NSUInteger associations=[role[@"associationCount"] unsignedIntegerValue],urls=[role[@"registeredURLCount"] unsignedIntegerValue];
            if ((associations>0 && urls==0) || (exactEmpty && associations) ||
                ([name isEqual:@"home"] && associations>sourceCount-[role[@"notProvidedCount"] unsignedIntegerValue])) return out;
            projected[@"registeredURLCount"]=role[@"registeredURLCount"];projected[@"associationCount"]=role[@"associationCount"];
            NSUInteger count=[role[@"registeredURLCount"] unsignedIntegerValue];totalURLs+=count;maxURLs=MAX(maxURLs,count);
        } else if (role[@"registeredURLCount"] || role[@"associationCount"]) return out;
        if (![role[@"state"] isEqual:@"available"]) partial=YES;
        roles[name]=projected;
    }
    partial=partial || [coverage[@"invalidRegistrationCount"] unsignedIntegerValue] || [coverage[@"truncatedRegistrationCount"] unsignedIntegerValue];
    NSUInteger unique=[coverage[@"allRolesUniqueRegisteredURLCount"] unsignedIntegerValue];
    if (unique>totalURLs || unique<maxURLs || [lower boolValue]!=partial ||
        ![coverage[@"state"] isEqual:partial ? @"partial" : @"available"]) return out;
    out[@"state"]=coverage[@"state"];out[@"sourceState"]=@"available";out[@"countsAreLowerBounds"]=lower;
    for (NSString *key in @[@"observedRegistrations",@"invalidRegistrationCount",@"truncatedRegistrationCount",@"allRolesUniqueRegisteredURLCount"]) out[key]=coverage[key];
    [out addEntriesFromDictionary:roles];return out;
}
NSArray *axs_cachekeeper_installed_applications_with_container_coverage(NSMutableDictionary *cache, NSDictionary **coverage, NSError **error) {
    if (error) *error=nil;
    NSString *sourceState=nil;
    id manager=axs_cachekeeper_coverage_property(NSClassFromString(@"LSApplicationWorkspace"),@"defaultWorkspace",&sourceState);
    id installed=manager ? axs_cachekeeper_coverage_property(manager,@"allInstalledApplications",&sourceState) : nil;
    if (![installed isKindOfClass:NSArray.class]) {
        if (installed) sourceState=@"invalid";
        if (coverage) {NSMutableDictionary *failure=axs_cachekeeper_coverage_base(@"unavailable");failure[@"sourceState"]=sourceState;*coverage=[failure copy];}
        axs_cachekeeper_installation_error(error,7,@"系统应用列表不可用",@"registry",@"enumerate",0);return nil;
    }
    NSMutableDictionary *home=coverage ? axs_cachekeeper_coverage_role() : nil,*group=coverage ? axs_cachekeeper_coverage_role() : nil,
        *extension=coverage ? axs_cachekeeper_coverage_role() : nil;
    NSUInteger registrations=0,invalidRegistrations=0,groupUsed=0,extensionUsed=0;
    NSMutableDictionary *apps=[NSMutableDictionary new],*nextCache=[NSMutableDictionary new];
    for (id proxy in installed) { @autoreleasepool {
        NSString *type=axs_cachekeeper_installation_property(proxy,@"applicationType");
        NSURL *url=axs_cachekeeper_installation_property(proxy,@"bundleURL");
        NSString *bundle=axs_cachekeeper_installation_property(proxy,@"applicationIdentifier");
        if (coverage && registrations<4096) {
            registrations++;
            if (axs_cachekeeper_bundle_id(bundle)) axs_cachekeeper_coverage_registration(proxy,bundle,home,group,extension,&groupUsed,&extensionUsed);
            else invalidRegistrations++;
        }
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
    if (coverage) {
        NSMutableSet *allURLs=[NSMutableSet new];
        NSDictionary *h=axs_cachekeeper_coverage_finish_role(home,YES,allURLs),*g=axs_cachekeeper_coverage_finish_role(group,NO,allURLs),
            *e=axs_cachekeeper_coverage_finish_role(extension,NO,allURLs);
        NSUInteger truncated=[installed count]-registrations;
        // Empty registry is an observed empty source, unlike a missing getter or nil response.
        if (![installed count]) {
            NSMutableDictionary *empty=[h mutableCopy];empty[@"state"]=@"available";empty[@"registeredURLCount"]=@0;empty[@"associationCount"]=@0;
            h=empty;g=empty;e=empty;
        }
        BOOL partial=invalidRegistrations || truncated || ![h[@"state"] isEqual:@"available"] || ![g[@"state"] isEqual:@"available"] || ![e[@"state"] isEqual:@"available"];
        NSMutableDictionary *result=axs_cachekeeper_coverage_base(partial ? @"partial" : @"available");
        [result addEntriesFromDictionary:@{@"sourceState":@"available",@"observedRegistrations":@(registrations),@"invalidRegistrationCount":@(invalidRegistrations),
            @"truncatedRegistrationCount":@(truncated),@"allRolesUniqueRegisteredURLCount":@(allURLs.count),@"countsAreLowerBounds":@(partial),@"home":h,@"group":g,@"extension":e}];
        *coverage=[result copy];
    }
    [cache setDictionary:nextCache];
    return [apps.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [a[@"id"] compare:b[@"id"]];}];
}
NSArray *axs_cachekeeper_installed_applications(NSMutableDictionary *cache, NSError **error) {
    return axs_cachekeeper_installed_applications_with_container_coverage(cache,NULL,error);
}
