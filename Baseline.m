#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>

// Use birth time so a later write to a preloaded file cannot classify it as new.
// 0.4.0/0.4.1 红线（禁区）：数据库与 cookies 类文件永不删、永不锁（不只靠目录层避开，文件名再兜底一层）。
static BOOL CKProtectedName(NSString *name) {
    NSString *n = name.lowercaseString;
    return [n hasSuffix:@".db"] || [n hasSuffix:@".sqlite"] || [n hasSuffix:@".sqlite3"] ||
        [n hasSuffix:@".realm"] || [n hasSuffix:@".db-journal"] || [n hasSuffix:@".sqlite-journal"] ||
        [n containsString:@".db-wal"] || [n containsString:@".db-shm"] ||
        [n containsString:@".sqlite-wal"] || [n containsString:@".sqlite-shm"] ||
        [n containsString:@"cookies"];
}
// 0.4.0 红线：60 秒内刚生成的文件不动（可能仍在写入），留到下一轮清理。
static BOOL CKTooFresh(struct stat info) {
    NSTimeInterval birth = info.st_birthtimespec.tv_sec + info.st_birthtimespec.tv_nsec / 1e9;
    return birth > 0 && birth > NSDate.date.timeIntervalSince1970 - 60;
}

static BOOL NewEntry(struct stat info, NSTimeInterval cutoff) {
    return info.st_birthtimespec.tv_sec > 0 &&
        info.st_birthtimespec.tv_sec + info.st_birthtimespec.tv_nsec / 1e9 > cutoff;
}

static BOOL RemoveEntry(NSURL *entry, NSString *root, struct stat expected) {
    NSURL *parent = entry.URLByDeletingLastPathComponent;
    if (![parent.path isEqual:root] && ![parent.path hasPrefix:[root stringByAppendingString:@"/"]]) return NO;
    char *resolvedParent = realpath(parent.fileSystemRepresentation, NULL);
    if (!resolvedParent) return NO;
    BOOL sameParent = [parent.path isEqual:@(resolvedParent)];
    free(resolvedParent);
    if (!sameParent) return NO;
    int fd = open(parent.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (fd < 0) return NO;
    BOOL removed = NO;
    struct stat directory, current;
    const char *name = entry.lastPathComponent.fileSystemRepresentation;
    if (!fstat(fd, &directory) && !fstatat(fd, name, &current, AT_SYMLINK_NOFOLLOW) &&
        current.st_ino == expected.st_ino && current.st_dev == expected.st_dev) {
        mode_t original = directory.st_mode & 0777;
        int flags = S_ISDIR(current.st_mode) ? AT_REMOVEDIR : 0;
        removed = unlinkat(fd, name, flags) == 0;
        if (!removed && (errno == EACCES || errno == EPERM) && !(original & S_IWUSR)) {
            if (!fchmod(fd, original | S_IWUSR)) {
                removed = unlinkat(fd, name, flags) == 0;
                fchmod(fd, original);
            }
        }
    }
    close(fd);
    return removed;
}

NSArray *CKBaselineDirectories(NSString *root, NSTimeInterval cutoff, BOOL cleanup, NSUInteger *removed, unsigned long long *bytes, BOOL *protectedRoot) {
    NSURL *url = [NSURL fileURLWithPath:root isDirectory:YES];
    if (![root isEqual:url.URLByResolvingSymlinksInPath.path]) return @[];
    char *resolvedRoot = realpath(root.fileSystemRepresentation, NULL);
    if (!resolvedRoot) return @[];
    NSString *canonical = @(resolvedRoot);
    free(resolvedRoot);
    url = [NSURL fileURLWithPath:canonical isDirectory:YES];
    NSMutableArray *directories = [NSMutableArray arrayWithObject:root];
    NSMutableArray *newDirectories = [NSMutableArray array];
    NSMutableArray *newFiles = [NSMutableArray array];
    // 0.4.4 边界修正（用户指出）：对整根目录限写会连带挡住其中数据库的日志文件
    // （-wal/-shm 必须在数据库同目录创建/删除）、登录态文件的轮换新建，与“永不锁”
    // 冲突。改为先识别“数据目录”——直接装有数据库/cookies 类文件的目录：
    // 这类目录一律不进锁定清单，其内的新生普通文件也不删（可能与数据配套）。
    NSMutableSet *protectedDirs = [NSMutableSet set];
    // 枚举时限 1 秒、30000 条上限（0.3.8 定版，避免大目录反复从头扫）。
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 1.0;
    NSUInteger entryCount = 0;
    NSDirectoryEnumerator *entries = [NSFileManager.defaultManager enumeratorAtURL:url
        includingPropertiesForKeys:nil options:0 errorHandler:nil];
    for (NSURL *entry in entries) {
        if (++entryCount > 30000 || NSProcessInfo.processInfo.systemUptime > deadline) break;
        struct stat info;
        if (lstat(entry.fileSystemRepresentation,&info)) continue;
        if (S_ISLNK(info.st_mode)) { [entries skipDescendants]; continue; }
        if (S_ISDIR(info.st_mode)) {
            if (!CKProtectedName(entry.lastPathComponent)) [directories addObject:entry.path];
            if (cleanup && NewEntry(info, cutoff) && !CKProtectedName(entry.lastPathComponent) && !CKTooFresh(info)) [newDirectories addObject:entry];
        } else if (S_ISREG(info.st_mode)) {
            if (CKProtectedName(entry.lastPathComponent)) {
                [protectedDirs addObject:entry.URLByDeletingLastPathComponent.path];
            } else if (cleanup && NewEntry(info, cutoff) && !CKTooFresh(info)) {
                // 删除推迟到枚举结束后统一执行：要先知道哪些目录是数据目录。
                [newFiles addObject:@{@"url":entry,@"inode":@(info.st_ino),@"device":@(info.st_dev),@"size":@(info.st_size)}];
            }
        }
    }
    if (protectedRoot) *protectedRoot = [protectedDirs containsObject:canonical];
    if (cleanup) {
        for (NSDictionary *file in newFiles) {
            NSURL *entry = file[@"url"];
            if ([protectedDirs containsObject:entry.URLByDeletingLastPathComponent.path]) continue;
            struct stat now;
            if (lstat(entry.fileSystemRepresentation,&now) ||
                now.st_ino != [file[@"inode"] unsignedLongLongValue] ||
                now.st_dev != (dev_t)[file[@"device"] unsignedLongLongValue]) continue;
            if (RemoveEntry(entry, canonical, now)) {
                if (removed) (*removed)++;
                if (bytes) *bytes += [file[@"size"] unsignedLongLongValue];
            }
        }
    }
    for (NSURL *entry in newDirectories.reverseObjectEnumerator) {
        if ([protectedDirs containsObject:entry.URLByDeletingLastPathComponent.path]) continue;
        struct stat info;
        if (!lstat(entry.fileSystemRepresentation,&info) && S_ISDIR(info.st_mode) &&
            NewEntry(info, cutoff)) RemoveEntry(entry, canonical, info);
    }
    [directories removeObjectsInArray:protectedDirs.allObjects];
    return directories;
}
