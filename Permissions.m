#import <Foundation/Foundation.h>
#import "AxsCacheKeeperPolicy.h"
#import "AxsCacheKeeperFileAccess.h"
#if CK_STANDALONE_RESTORE
#include <mach-o/dyld.h>
#include <stdlib.h>
static NSString *jbroot(NSString *path) {
    char buffer[4096]; uint32_t size = sizeof(buffer);
    if (_NSGetExecutablePath(buffer, &size)) return nil;
    char *resolved = realpath(buffer, NULL);
    if (!resolved) return nil;
    NSString *executable = [NSString stringWithUTF8String:resolved]; free(resolved);
    NSString *root = executable.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
    return [root stringByAppendingPathComponent:path];
}
#else
#include <roothide.h>
#endif

// 仅恢复旧版修改的权限。禁止再锁缓存根，以免连带阻断数据库或登录态写入。
NSDictionary *axs_cachekeeper_restore_paths(NSArray *paths, NSString *file) {
    NSDictionary *stored = [NSDictionary dictionaryWithContentsOfFile:file];
    if ((!stored && [NSFileManager.defaultManager fileExistsAtPath:file]) || !file.length)
        return @{@"failed":@1, @"applied":@0, @"error":@"权限恢复记录不可读"};
    NSMutableDictionary *records = [stored mutableCopy] ?: [NSMutableDictionary new];
    NSUInteger applied = 0, failed = 0;
    NSString *message = @"";
    for (NSString *path in (paths ?: records.allKeys)) {
        NSDictionary *saved = records[path];
        if (!saved) continue;
        if (![path isKindOfClass:NSString.class] || ![saved isKindOfClass:NSDictionary.class] ||
            ![saved[@"inode"] isKindOfClass:NSNumber.class] || ![saved[@"device"] isKindOfClass:NSNumber.class] ||
            ![saved[@"mode"] isKindOfClass:NSNumber.class]) {
            failed++; message = @"原权限记录损坏，保留记录等待修复"; continue;
        }
        int fd = axs_cachekeeper_open_directory(path);
        if (fd < 0) {
            if (errno == ENOENT) { [records removeObjectForKey:path]; continue; }
            failed++; message = [NSString stringWithFormat:@"恢复目录访问失败（errno %d）", errno]; continue;
        }
        struct stat info;
        if (fstat(fd, &info)) { failed++; message = @"无法核对目录身份"; close(fd); continue; }
        if ([saved[@"inode"] unsignedLongLongValue] != info.st_ino || [saved[@"device"] unsignedLongLongValue] != info.st_dev) {
            [records removeObjectForKey:path]; close(fd); continue;
        }
        mode_t mode = [saved[@"mode"] unsignedIntValue] & 07777;
        if (fchmod(fd, mode) || fstat(fd, &info) || (info.st_mode & 07777) != mode) {
            failed++; message = [NSString stringWithFormat:@"恢复原权限失败（errno %d）", errno];
        } else { applied++; [records removeObjectForKey:path]; }
        close(fd);
    }
    if (![records isEqual:stored ?: @{}] && ![records writeToFile:file atomically:YES]) {
        failed++; message = @"恢复记录保存失败，将在下次重试";
    }
    return @{@"failed":@(failed), @"applied":@(applied), @"error":message};
}
NSDictionary *CKPermissions(NSURL *home, BOOL enabled) {
    if (enabled) return @{@"failed":@1,@"error":@"不再支持目录 chmod 限写"};
    NSString *journal = jbroot(@"/var/mobile/Library/CacheKeeper/permissions.plist");
    NSArray *paths = nil;
    if (home) {
        NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:journal];
        NSMutableArray *matching = [NSMutableArray new];
        for (NSString *path in saved) if ([path hasPrefix:[home.path stringByAppendingString:@"/"]]) [matching addObject:path];
        paths = matching;
    }
    NSDictionary *result = axs_cachekeeper_restore_paths(paths, journal);
    if ([result[@"failed"] unsignedIntegerValue]) NSLog(@"[CacheKeeper] %@", result[@"error"]);
    return result;
}
