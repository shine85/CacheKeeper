#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>

// Use birth time so a later write to a preloaded file cannot classify it as new.
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

NSArray *CKBaselineDirectories(NSString *root, NSTimeInterval cutoff, BOOL cleanup, NSUInteger *removed, unsigned long long *bytes) {
    NSURL *url = [NSURL fileURLWithPath:root isDirectory:YES];
    if (![root isEqual:url.URLByResolvingSymlinksInPath.path]) return @[];
    char *resolvedRoot = realpath(root.fileSystemRepresentation, NULL);
    if (!resolvedRoot) return @[];
    NSString *canonical = @(resolvedRoot);
    free(resolvedRoot);
    url = [NSURL fileURLWithPath:canonical isDirectory:YES];
    NSMutableArray *directories = [NSMutableArray arrayWithObject:root];
    NSMutableArray *newDirectories = [NSMutableArray array];
    // 0.3.8 优化：原时限只有 75ms，大目录一轮枚举不完，锁定清单缺尾部目录、
    // 清理要靠多轮重试从头再扫。调用方已移出 SpringBoard 主线程（见 Desktop.xm），
    // 时限放宽到 1 秒，并加 30000 条上限兜底，避免病态目录无限占用。
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
            [directories addObject:entry.path];
            if (cleanup && NewEntry(info, cutoff)) [newDirectories addObject:entry];
        } else if (cleanup && S_ISREG(info.st_mode) && NewEntry(info, cutoff)) {
            if (RemoveEntry(entry, canonical, info)) {
                if (removed) (*removed)++;
                if (bytes) *bytes += info.st_size;
            }
        }
    }
    for (NSURL *entry in newDirectories.reverseObjectEnumerator) {
        struct stat info;
        if (!lstat(entry.fileSystemRepresentation,&info) && S_ISDIR(info.st_mode) &&
            NewEntry(info, cutoff)) RemoveEntry(entry, canonical, info);
    }
    return directories;
}
