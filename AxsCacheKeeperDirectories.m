#import "AxsCacheKeeperDirectories.h"
#import "AxsCacheKeeperPolicy.h"
#import "AxsCacheKeeperFileAccess.h"
#import "AxsCacheKeeperScanDiagnostics.h"
#include <errno.h>

static NSError *axs_cachekeeper_scan_local_error(void) {
    return [NSError errorWithDomain:@"dev.local.cachekeeper.scan" code:1
        userInfo:@{NSLocalizedDescriptionKey:@"目录来源无效或读取期间已变化"}];
}
static void axs_cachekeeper_scan_failure(NSMutableDictionary *diagnostics, NSString *scope, NSString *stage,
                                         NSError *error, NSString *reason, BOOL discovery, BOOL statFailure) {
    NSString *domain=@"other";NSInteger code=0;
    NSError *source=error;
    id underlying=error.userInfo[NSUnderlyingErrorKey];
    if ([underlying isKindOfClass:NSError.class] && [[underlying domain] isEqual:NSPOSIXErrorDomain]) source=underlying;
    if ([source.domain isEqual:NSPOSIXErrorDomain] && source.code>=0 && source.code<=255) {domain=@"posix";code=source.code;}
    else if ([source.domain isEqual:NSCocoaErrorDomain] && source.code>=0 && source.code<=INT32_MAX) {domain=@"cocoa";code=source.code;}
    else if (!error) domain=@"none";
    if (!reason) reason=([domain isEqual:@"posix"] && (code==EACCES || code==EPERM)) ||
        ([domain isEqual:@"cocoa"] && code==NSFileReadNoPermissionError) ? @"permissionDenied" : @"readFailure";
    if (discovery) diagnostics[@"discoveryComplete"]=@NO;
    diagnostics[@"measurementComplete"]=@NO;
    if (statFailure) axs_cachekeeper_scan_count(diagnostics,@"statErrors",1);
    else if ([stage isEqual:@"listChildren"] || [stage isEqual:@"enumerate"])
        axs_cachekeeper_scan_count(diagnostics,@"enumerationErrors",1);
    axs_cachekeeper_scan_error(diagnostics,scope,stage,reason,domain,code,1);
}
static void axs_cachekeeper_scan_first_error(NSError **output, NSError *error) {
    if (output && !*output) *output=error;
}
static int axs_cachekeeper_scan_open_root(NSURL *root, NSString *scope, BOOL primary,
                                          NSMutableDictionary *diagnostics, NSError **error, struct stat *identity) {
    if (![root isKindOfClass:NSURL.class] || !root.isFileURL || !root.path.isAbsolutePath) {
        NSString *state=root || [diagnostics[@"containerState"] isEqual:@"invalidHome"] ? @"invalidHome" : @"noHome";
        if (primary) diagnostics[@"containerState"]=state;
        axs_cachekeeper_scan_failure(diagnostics,scope,@"containerResolve",nil,state,YES,NO);
        axs_cachekeeper_scan_first_error(error,axs_cachekeeper_scan_local_error());return -1;
    }
    struct stat original;
    if (lstat(root.fileSystemRepresentation,&original)) {
        int code=errno;NSError *failure=[NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
        if (primary) diagnostics[@"containerState"]=code==ENOENT ? @"rootMissing" : @"unreadable";
        axs_cachekeeper_scan_failure(diagnostics,scope,@"rootStat",failure,code==ENOENT ? @"rootMissing" : nil,YES,YES);
        axs_cachekeeper_scan_first_error(error,failure);return -1;
    }
    int fd=axs_cachekeeper_open_directory(root.path);
    if (fd<0) {
        int code=errno;NSError *failure=[NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
        if (primary) diagnostics[@"containerState"]=code==ENOENT ? @"rootMissing" : @"unreadable";
        axs_cachekeeper_scan_failure(diagnostics,scope,@"rootOpen",failure,code==ENOENT ? @"rootMissing" : nil,YES,NO);
        axs_cachekeeper_scan_first_error(error,failure);return -1;
    }
    struct stat opened;
    if (fstat(fd,&opened)) {
        int code=errno;close(fd);NSError *failure=[NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
        if (primary) diagnostics[@"containerState"]=@"unreadable";
        axs_cachekeeper_scan_failure(diagnostics,scope,@"rootStat",failure,nil,YES,YES);
        axs_cachekeeper_scan_first_error(error,failure);return -1;
    }
    // Ancestor aliases are valid when the final entry and opened descriptor identify the same directory.
    if (!S_ISDIR(original.st_mode) || original.st_dev!=opened.st_dev || original.st_ino!=opened.st_ino) {
        close(fd);if (primary) diagnostics[@"containerState"]=@"invalidHome";
        axs_cachekeeper_scan_failure(diagnostics,scope,@"rootRecheck",nil,@"identityChanged",YES,NO);
        axs_cachekeeper_scan_first_error(error,axs_cachekeeper_scan_local_error());return -1;
    }
    if (identity) *identity=opened;
    return fd;
}
static BOOL axs_cachekeeper_scan_recheck_root(NSURL *root, const struct stat *identity, NSString *scope, BOOL primary,
                                             NSMutableDictionary *diagnostics, NSError **error) {
    struct stat current;
    if (lstat(root.fileSystemRepresentation,&current)) {
        int code=errno;NSError *failure=[NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
        if (primary) diagnostics[@"containerState"]=code==ENOENT ? @"rootMissing" : @"unreadable";
        axs_cachekeeper_scan_failure(diagnostics,scope,@"rootRecheck",failure,code==ENOENT ? @"rootMissing" : nil,YES,YES);
        axs_cachekeeper_scan_first_error(error,failure);return NO;
    }
    if (!S_ISDIR(current.st_mode) || current.st_dev!=identity->st_dev || current.st_ino!=identity->st_ino) {
        if (primary) diagnostics[@"containerState"]=@"invalidHome";
        axs_cachekeeper_scan_failure(diagnostics,scope,@"rootRecheck",nil,@"identityChanged",YES,NO);
        axs_cachekeeper_scan_first_error(error,axs_cachekeeper_scan_local_error());return NO;
    }
    return YES;
}

NSArray<NSString *> *axs_cachekeeper_discover_cache_roots(NSURL *home, NSError **error) {
    if (error) *error=nil;
    NSMutableDictionary *diagnostics=axs_cachekeeper_scan_diagnostics_new();struct stat homeIdentity;
    int homeFD=axs_cachekeeper_scan_open_root(home,@"home",YES,diagnostics,error,&homeIdentity);
    if (homeFD<0) return @[];
    NSMutableArray *paths=[NSMutableArray new];
    NSMutableSet *identities=[NSMutableSet new];
    for (NSString *relative in axs_cachekeeper_cache_roots()) {
        NSString *path=[home.path stringByAppendingPathComponent:relative];
        int fd=axs_cachekeeper_open_directory(path);
        if (fd<0) {
            int code=errno;
            if (code!=ENOENT && code!=ENOTDIR) axs_cachekeeper_scan_first_error(error,[NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil]);
            continue;
        }
        struct stat info;
        if (!fstat(fd,&info)) {
            NSArray *identity=@[@(info.st_dev),@(info.st_ino)];
            if (![identities containsObject:identity]) { [identities addObject:identity];[paths addObject:relative]; }
        } else {int code=errno;axs_cachekeeper_scan_first_error(error,[NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil]);}
        close(fd);
    }
    BOOL same=axs_cachekeeper_scan_recheck_root(home,&homeIdentity,@"home",YES,diagnostics,error);close(homeFD);
    return same ? axs_cachekeeper_parent_paths(paths) : @[];
}

static NSArray<NSString *> *axs_cachekeeper_scan_directory_body(NSURL *home, NSString *scope, NSError **error,
                                                                NSMutableDictionary *diagnostics) {
    if (error) *error=nil;
    struct stat homeIdentity;int homeFD=axs_cachekeeper_scan_open_root(home,scope,YES,diagnostics,error,&homeIdentity);
    if (homeFD<0) return @[];
    NSMutableArray *paths=[NSMutableArray new];
    NSFileManager *fm=NSFileManager.defaultManager;
    // Library 自身过宽，展示它的一级用途分类；其他父目录均不再展开。
    for (NSString *base in @[@"",@"Library"]) {
        NSURL *root=base.length ? [home URLByAppendingPathComponent:base] : home;
        struct stat rootInfo=homeIdentity;int rootFD=homeFD;
        if (base.length) {
            struct stat optional;
            if (lstat(root.fileSystemRepresentation,&optional)) {
                int code=errno;
                if (code==ENOENT) continue;
                NSError *failure=[NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
                axs_cachekeeper_scan_failure(diagnostics,scope,@"rootStat",failure,nil,YES,YES);
                axs_cachekeeper_scan_first_error(error,failure);continue;
            }
            rootFD=axs_cachekeeper_scan_open_root(root,scope,NO,diagnostics,error,&rootInfo);
            if (rootFD<0) continue;
        }
        NSError *readError=nil;
        NSArray *entries=[fm contentsOfDirectoryAtURL:root includingPropertiesForKeys:nil options:0 error:&readError];
        if (readError || !entries) {
            axs_cachekeeper_scan_failure(diagnostics,scope,@"listChildren",readError,readError ? nil : @"enumeratorUnavailable",YES,NO);
            axs_cachekeeper_scan_first_error(error,readError ?: axs_cachekeeper_scan_local_error());
        }
        for (NSURL *entry in entries) {
            if (!base.length && [entry.lastPathComponent isEqual:@"Library"]) continue;
            struct stat info;
            if (lstat(entry.fileSystemRepresentation,&info)) {
                int code=errno;NSError *failure=[NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
                axs_cachekeeper_scan_failure(diagnostics,scope,@"entryStat",failure,nil,YES,YES);
                axs_cachekeeper_scan_first_error(error,failure);
                continue;
            }
            if (!S_ISDIR(info.st_mode) || S_ISLNK(info.st_mode)) continue;
            NSString *relative=base.length ? [base stringByAppendingPathComponent:entry.lastPathComponent] : entry.lastPathComponent;
            if (!axs_cachekeeper_hidden_directory(relative)) [paths addObject:relative];
        }
        if (base.length) {axs_cachekeeper_scan_recheck_root(root,&rootInfo,scope,NO,diagnostics,error);close(rootFD);}
    }
    BOOL same=axs_cachekeeper_scan_recheck_root(home,&homeIdentity,scope,YES,diagnostics,error);close(homeFD);
    return same ? axs_cachekeeper_parent_paths(paths) : @[];
}
NSArray<NSString *> *axs_cachekeeper_scan_directories(NSURL *home, NSError **error) {
    return axs_cachekeeper_scan_directory_body(home,@"home",error,axs_cachekeeper_scan_diagnostics_new());
}

NSArray<NSString *> *axs_cachekeeper_purge_candidates(NSURL *home, NSError **error) {
    // 直接复用目录枚举：相对路径字符串，未知目录与缓存根都在内；
    // 类型/定级/排除的过滤由 axs_cachekeeper_purge_paths 负责，此处不做任何筛选。
    return axs_cachekeeper_scan_directories(home, error);
}

NSDictionary<NSString *,NSURL *> *axs_cachekeeper_valid_group_homes(NSDictionary *groups) {
    if (![groups isKindOfClass:NSDictionary.class]) return @{};
    NSMutableDictionary *result=[NSMutableDictionary new];
    for (NSString *identifier in groups) {
        if (!axs_cachekeeper_bundle_id(identifier)) continue;
        NSURL *url=groups[identifier];
        if (![url isKindOfClass:NSURL.class] || !url.isFileURL) continue;
        url=url.URLByResolvingSymlinksInPath;
        if (![[NSUUID alloc] initWithUUIDString:url.lastPathComponent] ||
            ![url.URLByDeletingLastPathComponent.path hasSuffix:@"/Containers/Shared/AppGroup"]) continue;
        result[identifier]=url;
    }
    return result;
}

NSArray<NSDictionary *> *axs_cachekeeper_scan_targets(NSURL *home, NSDictionary *groups, NSError **error) {
    return axs_cachekeeper_scan_targets_diagnostics(home,groups,NO,error,NULL);
}
NSArray<NSDictionary *> *axs_cachekeeper_scan_targets_diagnostics(NSURL *home, NSDictionary *groups, BOOL homeWasRejected, NSError **error,
                                                                 NSDictionary **output) {
    if (error) *error=nil;
    NSMutableDictionary *diagnostics=axs_cachekeeper_scan_diagnostics_new();
    if (!home && homeWasRejected) diagnostics[@"containerState"]=@"invalidHome";
    NSMutableArray *targets=[NSMutableArray new];
    NSError *scanError=nil;
    for (NSString *path in axs_cachekeeper_scan_directory_body(home,@"home",&scanError,diagnostics))
        [targets addObject:@{@"path":path,@"root":[home URLByAppendingPathComponent:path],@"scope":@"home",@"readOnly":@(!axs_cachekeeper_cache_path(path))}];
    if (scanError && error) *error=scanError;
    NSDictionary *valid=axs_cachekeeper_valid_group_homes(groups);
    NSMutableSet *visited=[NSMutableSet new];
    for (NSString *identifier in [valid.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSURL *group=valid[identifier];
        if ([visited containsObject:group.path]) continue;
        [visited addObject:group.path];
        scanError=nil;
        NSMutableDictionary *groupDiagnostics=axs_cachekeeper_scan_diagnostics_new();
        for (NSString *path in axs_cachekeeper_scan_directory_body(group,@"group",&scanError,groupDiagnostics))
            [targets addObject:@{@"path":[NSString stringWithFormat:@"Group/%@/%@",identifier,path],
                @"root":[group URLByAppendingPathComponent:path],@"scope":@"group",@"readOnly":@YES}];
        axs_cachekeeper_scan_merge(diagnostics,groupDiagnostics);
        if (scanError && error && !*error) *error=scanError;
    }
    if (output) *output=[diagnostics copy];return targets;
}

static NSDictionary *axs_cachekeeper_measure_directory_body(NSURL *root, NSTimeInterval deadline, NSUInteger entryLimit,
    NSTimeInterval (^clock)(void), int (^statBlock)(const char *,struct stat *),
    NSEnumerator<NSURL *> *(^enumerator)(NSURL *,BOOL (^)(NSURL *,NSError *))) {
    NSMutableDictionary *diagnostics=axs_cachekeeper_scan_diagnostics_new();
    unsigned long long bytes=0;struct stat identity;
    int fd=axs_cachekeeper_scan_open_root(root,@"home",YES,diagnostics,NULL,&identity);
    if (fd>=0) {
        NSEnumerator *entries=enumerator(root,^BOOL(NSURL *url,NSError *error) {
            (void)url;axs_cachekeeper_scan_failure(diagnostics,@"home",@"enumerate",error,nil,NO,NO);
            if (clock()>deadline) {diagnostics[@"timeBudgetExceeded"]=@YES;return NO;}
            return YES;
        });
        if (!entries) axs_cachekeeper_scan_failure(diagnostics,@"home",@"enumerate",nil,@"enumeratorUnavailable",NO,NO);
        while (entries) { @autoreleasepool {
            if (clock()>deadline) {diagnostics[@"timeBudgetExceeded"]=@YES;diagnostics[@"measurementComplete"]=@NO;break;}
            NSURL *entry=[entries nextObject];if (!entry) break;
            if (clock()>deadline) {diagnostics[@"timeBudgetExceeded"]=@YES;diagnostics[@"measurementComplete"]=@NO;break;}
            if ([diagnostics[@"entriesVisited"] unsignedLongLongValue]>=entryLimit) {
                diagnostics[@"entryLimitExceeded"]=@YES;diagnostics[@"measurementComplete"]=@NO;break;
            }
            axs_cachekeeper_scan_count(diagnostics,@"entriesVisited",1);
            struct stat info;
            if (statBlock(entry.fileSystemRepresentation,&info)) {
                int code=errno;NSError *failure=[NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
                axs_cachekeeper_scan_failure(diagnostics,@"home",@"entryStat",failure,nil,NO,YES);continue;
            }
            if (S_ISREG(info.st_mode) && info.st_size>0) bytes+=(unsigned long long)info.st_size;
        } }
        if (clock()>deadline) {diagnostics[@"timeBudgetExceeded"]=@YES;diagnostics[@"measurementComplete"]=@NO;}
        axs_cachekeeper_scan_recheck_root(root,&identity,@"home",YES,diagnostics,NULL);close(fd);
    }
    return @{@"bytes":@(bytes),@"complete":diagnostics[@"measurementComplete"],@"scanDiagnostics":[diagnostics copy]};
}
NSDictionary *axs_cachekeeper_measure_directory(NSURL *root, NSTimeInterval deadline, NSUInteger entryLimit) {
    return axs_cachekeeper_measure_directory_body(root,deadline,entryLimit,^NSTimeInterval {return NSProcessInfo.processInfo.systemUptime;},
        ^int(const char *path,struct stat *info) {return lstat(path,info);},
        ^NSEnumerator<NSURL *> *(NSURL *url,BOOL (^handler)(NSURL *,NSError *)) {
            return [NSFileManager.defaultManager enumeratorAtURL:url includingPropertiesForKeys:nil options:0 errorHandler:handler];
        });
}
#if defined(AXS_CACHEKEEPER_SCAN_TESTING)
NSDictionary *axs_cachekeeper_measure_directory_dependencies(NSURL *root, NSTimeInterval deadline, NSUInteger entryLimit,
    NSTimeInterval (^clock)(void), int (^statBlock)(const char *,struct stat *),
    NSEnumerator<NSURL *> *(^enumerator)(NSURL *,BOOL (^)(NSURL *,NSError *))) {
    return axs_cachekeeper_measure_directory_body(root,deadline,entryLimit,clock,statBlock,enumerator);
}
#endif
