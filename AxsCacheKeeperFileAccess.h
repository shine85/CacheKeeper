#pragma once
#import <Foundation/Foundation.h>
#import "AxsCacheKeeperPolicy.h"
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

// Foundation 的根路径别名仅在指向同一目录时可用；不解析后代链接。
static inline NSArray<NSString *> *axs_cachekeeper_directory_aliases(NSString *root) {
    NSMutableArray *aliases=[NSMutableArray arrayWithObject:root];
    NSString *standard=root.stringByStandardizingPath;
    struct stat original,alternate;
    if (![standard isEqual:root] && !lstat(root.fileSystemRepresentation,&original) &&
        !lstat(standard.fileSystemRepresentation,&alternate) && S_ISDIR(alternate.st_mode) &&
        original.st_ino==alternate.st_ino && original.st_dev==alternate.st_dev) [aliases addObject:standard];
    return aliases;
}
static inline NSString *axs_cachekeeper_enumerated_path(NSString *path, NSString *root, NSArray<NSString *> *aliases) {
    if (![path isKindOfClass:NSString.class]) return nil;
    NSString *trimmed=path;
    while (trimmed.length>1 && [trimmed hasSuffix:@"/"]) trimmed=[trimmed substringToIndex:trimmed.length-1];
    for (NSString *alias in aliases) {
        NSString *prefix=[alias stringByAppendingString:@"/"];
        if (![trimmed hasPrefix:prefix]) continue;
        NSString *relative=[trimmed substringFromIndex:prefix.length];
        if (!axs_cachekeeper_relative_path(relative)) return nil;
        return [root stringByAppendingFormat:@"/%@",relative];
    }
    return nil;
}

// 输入为规范绝对路径；每一级都不跟随链接，避免权限操作逃出目标目录。
static inline int axs_cachekeeper_open_directory(NSString *path) {
    if (![path hasPrefix:@"/"]) { errno = EINVAL; return -1; }
    int fd = open("/", O_RDONLY | O_DIRECTORY);
    if (fd < 0) return -1;
    NSMutableArray<NSString *> *parts = [NSMutableArray new];
    for (NSString *part in [path componentsSeparatedByString:@"/"]) if (part.length) [parts addObject:part];
    NSUInteger index = 0;
    for (NSString *part in parts) {
        if ([part isEqual:@"."] || [part isEqual:@".."]) { close(fd); errno = EINVAL; return -1; }
        // 中间组件按内核路径解析跟随符号链接（/var→/private/var、越狱根链接等系统形态）；
        // 只有末级目标目录保持 NOFOLLOW，防目标本身被换成链接。调用方均另有身份核对兜底。
        // 旧实现逐级 NOFOLLOW：中间任一组件是链接就以 ENOTDIR 失败（真机 2026-11-11 删除全灭于此）。
        BOOL last = ++index == parts.count;
        int next = openat(fd, part.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | (last ? O_NOFOLLOW : 0));
        int error = errno;
        close(fd);
        if (next < 0) { errno = error; return -1; }
        fd = next;
    }
    return fd;
}

// 与目录版同一链路：逐级打开父目录后以 NOFOLLOW 打开末级普通文件，供权限恢复核对身份后 fchmod。
static inline int axs_cachekeeper_open_regular_file(NSString *path) {
    if (![path hasPrefix:@"/"]) { errno = EINVAL; return -1; }
    NSString *name = path.lastPathComponent;
    if (!name.length || [name isEqual:@"."] || [name isEqual:@".."]) { errno = EINVAL; return -1; }
    int fd = axs_cachekeeper_open_directory(path.stringByDeletingLastPathComponent);
    if (fd < 0) return -1;
    int file = openat(fd, name.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    int error = errno;
    close(fd);
    errno = error;
    return file;
}
