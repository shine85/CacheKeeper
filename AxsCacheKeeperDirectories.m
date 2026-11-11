#import "AxsCacheKeeperDirectories.h"
#import "AxsCacheKeeperPolicy.h"
#import "AxsCacheKeeperFileAccess.h"
#include <errno.h>

NSArray<NSString *> *axs_cachekeeper_discover_cache_roots(NSURL *home, NSError **error) {
    if (error) *error=nil;
    if (![home isKindOfClass:NSURL.class] || !home.isFileURL) {
        if (error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];
        return @[];
    }
    NSMutableArray *paths=[NSMutableArray new];
    NSMutableSet *identities=[NSMutableSet new];
    for (NSString *relative in axs_cachekeeper_cache_roots()) {
        NSString *path=[home.path stringByAppendingPathComponent:relative];
        int fd=axs_cachekeeper_open_directory(path);
        if (fd<0) {
            if (errno!=ENOENT && errno!=ENOTDIR && error && !*error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"无法检查缓存目录 %@",relative]}];
            continue;
        }
        struct stat info;
        if (!fstat(fd,&info)) {
            NSArray *identity=@[@(info.st_dev),@(info.st_ino)];
            if (![identities containsObject:identity]) { [identities addObject:identity];[paths addObject:relative]; }
        } else if (error && !*error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        close(fd);
    }
    return axs_cachekeeper_parent_paths(paths);
}

NSArray<NSString *> *axs_cachekeeper_scan_directories(NSURL *home, NSError **error) {
    if (error) *error=nil;
    if (![home isKindOfClass:NSURL.class] || !home.isFileURL) {
        if (error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];
        return @[];
    }
    NSMutableArray *paths=[NSMutableArray new];
    NSFileManager *fm=NSFileManager.defaultManager;
    // Library 自身过宽，展示它的一级用途分类；其他父目录均不再展开。
    for (NSString *base in @[@"",@"Library"]) {
        NSURL *root=base.length ? [home URLByAppendingPathComponent:base] : home;
        if (![root.path isEqual:root.URLByResolvingSymlinksInPath.path]) {
            if (error && !*error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:ELOOP userInfo:nil];
            continue;
        }
        struct stat rootInfo;
        if (lstat(root.fileSystemRepresentation,&rootInfo)) {
            if (errno!=ENOENT && error && !*error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
            continue;
        }
        NSError *readError=nil;
        NSArray *entries=[fm contentsOfDirectoryAtURL:root includingPropertiesForKeys:nil options:0 error:&readError];
        if (readError && error && !*error) *error=readError;
        for (NSURL *entry in entries) {
            if (!base.length && [entry.lastPathComponent isEqual:@"Library"]) continue;
            struct stat info;
            if (lstat(entry.fileSystemRepresentation,&info)) {
                if (errno!=ENOENT && error && !*error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
                continue;
            }
            if (!S_ISDIR(info.st_mode) || S_ISLNK(info.st_mode)) continue;
            NSString *relative=base.length ? [base stringByAppendingPathComponent:entry.lastPathComponent] : entry.lastPathComponent;
            if (!axs_cachekeeper_hidden_directory(relative)) [paths addObject:relative];
        }
    }
    return axs_cachekeeper_parent_paths(paths);
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
    if (error) *error=nil;
    NSMutableArray *targets=[NSMutableArray new];
    NSError *scanError=nil;
    if (home) for (NSString *path in axs_cachekeeper_scan_directories(home,&scanError))
        [targets addObject:@{@"path":path,@"root":[home URLByAppendingPathComponent:path],@"readOnly":@(!axs_cachekeeper_cache_path(path))}];
    if (scanError && error) *error=scanError;
    NSDictionary *valid=axs_cachekeeper_valid_group_homes(groups);
    NSMutableSet *visited=[NSMutableSet new];
    for (NSString *identifier in [valid.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSURL *group=valid[identifier];
        if ([visited containsObject:group.path]) continue;
        [visited addObject:group.path];
        scanError=nil;
        for (NSString *path in axs_cachekeeper_scan_directories(group,&scanError))
            [targets addObject:@{@"path":[NSString stringWithFormat:@"Group/%@/%@",identifier,path],
                @"root":[group URLByAppendingPathComponent:path],@"readOnly":@YES}];
        if (scanError && error && !*error) *error=scanError;
    }
    return targets;
}
