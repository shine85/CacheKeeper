#pragma once
#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

// 输入为规范绝对路径；每一级都不跟随链接，避免权限操作逃出目标目录。
static inline int axs_cachekeeper_open_directory(NSString *path) {
    if (![path hasPrefix:@"/"]) { errno = EINVAL; return -1; }
    int fd = open("/", O_RDONLY | O_DIRECTORY);
    if (fd < 0) return -1;
    for (NSString *part in [path componentsSeparatedByString:@"/"]) {
        if (!part.length) continue;
        if ([part isEqual:@"."] || [part isEqual:@".."]) { close(fd); errno = EINVAL; return -1; }
        int next = openat(fd, part.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        int error = errno;
        close(fd);
        if (next < 0) { errno = error; return -1; }
        fd = next;
    }
    return fd;
}
