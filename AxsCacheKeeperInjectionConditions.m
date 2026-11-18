#import "AxsCacheKeeperInjectionConditions.h"
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>

static NSDictionary *AxsCacheKeeperInjectionReadFailure(int code) {
    return @{@"state":code==ENOENT ? @"missing" : @"unreadable",@"errorCode":@(code)};
}
NSDictionary *axs_cachekeeper_injection_conditions_read(NSString *path) {
    if (![path isKindOfClass:NSString.class] || !path.length) return AxsCacheKeeperInjectionReadFailure(EINVAL);
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK);
    if (fd<0) return AxsCacheKeeperInjectionReadFailure(errno);
    struct stat before={0};
    if (fstat(fd,&before)!=0) {int code=errno;close(fd);return AxsCacheKeeperInjectionReadFailure(code);}
    if (!S_ISREG(before.st_mode)) {close(fd);return AxsCacheKeeperInjectionReadFailure(EINVAL);}
    // Preferences are small; bound the read before allocating, and reject a changing file.
    if (before.st_size<0 || before.st_size>8*1024*1024) {close(fd);return AxsCacheKeeperInjectionReadFailure(EFBIG);}
    NSMutableData *bytes=[NSMutableData dataWithLength:(NSUInteger)before.st_size];
    NSUInteger offset=0;
    unsigned interrupted=0;
    while (offset<bytes.length) {
        ssize_t count=read(fd,(char *)bytes.mutableBytes+offset,bytes.length-offset);
        if (count<0 && errno==EINTR) {
            if (++interrupted>8) {close(fd);return AxsCacheKeeperInjectionReadFailure(EINTR);}
            continue;
        }
        if (count<=0) {int code=count<0 ? errno : EIO;close(fd);return AxsCacheKeeperInjectionReadFailure(code);}
        interrupted=0;
        offset+=(NSUInteger)count;
    }
    struct stat after={0};
    if (fstat(fd,&after)!=0) {int code=errno;close(fd);return AxsCacheKeeperInjectionReadFailure(code);}
    close(fd);
    if (before.st_size!=after.st_size || before.st_mtimespec.tv_sec!=after.st_mtimespec.tv_sec ||
        before.st_mtimespec.tv_nsec!=after.st_mtimespec.tv_nsec || before.st_ctimespec.tv_sec!=after.st_ctimespec.tv_sec ||
        before.st_ctimespec.tv_nsec!=after.st_ctimespec.tv_nsec) return AxsCacheKeeperInjectionReadFailure(EAGAIN);
    NSError *error=nil;
    id plist=[NSPropertyListSerialization propertyListWithData:bytes options:NSPropertyListImmutable format:NULL error:&error];
    if (![plist isKindOfClass:NSDictionary.class]) return @{@"state":@"invalid",@"errorCode":@(error.code)};
    return @{@"state":@"available",@"data":plist};
}
static BOOL AxsCacheKeeperInjectionBoolean(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID();
}
static BOOL AxsCacheKeeperInjectionInteger(id value) {
    return [value isKindOfClass:NSNumber.class] && !AxsCacheKeeperInjectionBoolean(value) &&
        !CFNumberIsFloatType((__bridge CFNumberRef)value);
}
static BOOL AxsCacheKeeperInjectionList(id value) {
    if (![value isKindOfClass:NSArray.class]) return NO;
    for (id item in value) if (![item isKindOfClass:NSString.class]) return NO;
    return YES;
}
NSDictionary *axs_cachekeeper_injection_conditions_projection(NSDictionary *snapshot,NSString *bundle) {
    NSMutableDictionary *out=[@{@"source":@"choicySavedPreferences",@"sourceState":@"invalid",@"savedDecision":@"unknown"} mutableCopy];
    if (![snapshot isKindOfClass:NSDictionary.class]) return out;
    NSString *state=snapshot[@"state"];
    if (![@[@"available",@"missing",@"unreadable",@"invalid"] containsObject:state ?: NSNull.null]) return out;
    out[@"sourceState"]=state;
    id error=snapshot[@"errorCode"];
    if (AxsCacheKeeperInjectionInteger(error) && [error longLongValue]>=INT32_MIN && [error longLongValue]<=INT32_MAX)
        out[@"readErrorCode"]=@([error intValue]);
    if ([state isEqual:@"missing"]) {out[@"savedDecision"]=@"noConfiguration";return out;}
    if (![state isEqual:@"available"]) return out;
    id plist=snapshot[@"data"];
    if (![plist isKindOfClass:NSDictionary.class] || ![bundle isKindOfClass:NSString.class] || !bundle.length) return out;
    id apps=plist[@"appSettings"];
    if (apps && ![apps isKindOfClass:NSDictionary.class]) return out;
    id app=apps[bundle];
    out[@"appConfigurationPresent"]=@(app!=nil);
    if (app && ![app isKindOfClass:NSDictionary.class]) return out;
    app=app ?: @{};
    for (NSString *key in @[@"tweakInjectionDisabled",@"customTweakConfigurationEnabled",@"overwriteGlobalTweakConfiguration"]) {
        id value=app[key];
        if (value && !AxsCacheKeeperInjectionBoolean(value)) return out;
        out[key]=@([value boolValue]);
    }
    id mode=app[@"allowDenyMode"];
    if (mode && (!AxsCacheKeeperInjectionInteger(mode) || ([mode longLongValue]!=1 && [mode longLongValue]!=2))) return out;
    out[@"allowDenyMode"]=mode ?: @1;
    BOOL overwrite=[app[@"overwriteGlobalTweakConfiguration"] boolValue];
    id global=overwrite ? nil : plist[@"globalDeniedTweaks"];
    if (global && !AxsCacheKeeperInjectionList(global)) return out;
    out[@"globalDeniesCacheKeeper"]=@([global containsObject:@"CacheKeeper"]);
    NSArray *allowed=nil,*denied=nil;
    if ([app[@"customTweakConfigurationEnabled"] boolValue]) {
        BOOL allow=[out[@"allowDenyMode"] integerValue]==1;
        id list=app[allow ? @"allowedTweaks" : @"deniedTweaks"];
        if (list && !AxsCacheKeeperInjectionList(list)) return out;
        out[@"selectedListPresent"]=@(list!=nil);
        if (list) out[@"selectedListContainsCacheKeeper"]=@([list containsObject:@"CacheKeeper"]);
        if (allow) allowed=list;else denied=list;
    }
    // Choicy b6c9297: saved global overwrite is independent of custom-list enablement.
    // Environment overrides and actual loader state are deliberately outside this projection.
    NSString *decision=@"notRestricted";
    if ([app[@"tweakInjectionDisabled"] boolValue]) decision=@"injectionDisabled";
    else if ([global containsObject:@"CacheKeeper"]) decision=@"globallyDenied";
    else if (allowed && ![allowed containsObject:@"CacheKeeper"]) decision=@"notAllowlisted";
    else if ([denied containsObject:@"CacheKeeper"]) decision=@"denylisted";
    out[@"savedDecision"]=decision;
    return [out copy];
}
NSString *axs_cachekeeper_injection_conditions_summary(NSDictionary *projection) {
    NSDictionary *labels=@{@"noConfiguration":@"未找到保存配置",@"unknown":@"读取或格式异常，条件未知",
        @"injectionDisabled":@"保存为禁用插件注入",@"globallyDenied":@"全局拒绝 CacheKeeper",
        @"notAllowlisted":@"允许名单未包含 CacheKeeper",@"denylisted":@"拒绝名单包含 CacheKeeper",
        @"notRestricted":@"未见针对 CacheKeeper 的保存限制"};
    NSString *label=labels[projection[@"savedDecision"] ?: @""] ?: labels[@"unknown"];
    return [NSString stringWithFormat:@"Choicy 保存条件：%@。保存条件不能证明当前进程是否注入；启动环境可覆盖配置，以当前宿主记录为准。",label];
}
