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

// 权限记录 permissions.plist 由两方共用：旧版残留权限的恢复，以及只禁止模式的目录写锁
// （用户 2026-11-11 在对话中确认：选了只禁止就同时锁已选缓存目录；仅在 APP 完全退出后上锁/解锁，
// 关模式、关总开关或卸载时按记录恢复。记录格式 {inode, device, mode} 两方通用。）
// 任务 9 起生产侧不再新施加写锁（lock_paths 仅供测试验证记录机制），本文件只剩恢复路径在用：
// 每轮恢复全部记录；恢复失败只拦受影响的范围（见 failedPaths），不再一并拦下全部 APP。
NSDictionary *axs_cachekeeper_restore_paths(NSArray *paths, NSString *file) {
    NSDictionary *stored = [NSDictionary dictionaryWithContentsOfFile:file];
    if ((!stored && [NSFileManager.defaultManager fileExistsAtPath:file]) || !file.length)
        return @{@"failed":@1, @"unlocatedFailures":@1, @"applied":@0, @"failedPaths":@[], @"error":@"权限恢复记录不可读"};
    NSMutableDictionary *records = [stored mutableCopy] ?: [NSMutableDictionary new];
    NSUInteger applied = 0, failed = 0;
    NSMutableArray *failedPaths = [NSMutableArray new];
    NSString *message = @"";
    for (NSString *path in (paths ?: records.allKeys)) {
        NSDictionary *saved = records[path];
        if (!saved) continue;
        if (![path isKindOfClass:NSString.class] || ![saved isKindOfClass:NSDictionary.class] ||
            ![saved[@"inode"] isKindOfClass:NSNumber.class] || ![saved[@"device"] isKindOfClass:NSNumber.class] ||
            ![saved[@"mode"] isKindOfClass:NSNumber.class]) {
            failed++; if ([path isKindOfClass:NSString.class]) [failedPaths addObject:path]; message = @"原权限记录损坏，保留记录等待修复"; continue;
        }
        int fd = axs_cachekeeper_open_directory(path);
        if (fd < 0 && errno == ENOTDIR) fd = axs_cachekeeper_open_regular_file(path);
        if (fd < 0) {
            if (errno == ENOENT) { [records removeObjectForKey:path]; continue; }
            failed++; [failedPaths addObject:path]; message = [NSString stringWithFormat:@"恢复条目访问失败（errno %d）", errno]; continue;
        }
        struct stat info;
        if (fstat(fd, &info)) { failed++; [failedPaths addObject:path]; message = @"无法核对条目身份"; close(fd); continue; }
        if (!S_ISDIR(info.st_mode) && !S_ISREG(info.st_mode)) {
            failed++; [failedPaths addObject:path]; message = @"条目类型异常，保留记录等待修复"; close(fd); continue;
        }
        if ([saved[@"inode"] unsignedLongLongValue] != info.st_ino || [saved[@"device"] unsignedLongLongValue] != info.st_dev) {
            [records removeObjectForKey:path]; close(fd); continue;
        }
        mode_t mode = [saved[@"mode"] unsignedIntValue] & 07777;
        if (S_ISREG(info.st_mode) && info.st_nlink != 1 && (info.st_mode & 07777) != mode) {
            failed++; [failedPaths addObject:path]; message=@"条目现有共享硬链接，未更改共享 inode 权限，保留恢复记录";
            close(fd); continue;
        }
        if (fchmod(fd, mode) || fstat(fd, &info) || (info.st_mode & 07777) != mode) {
            failed++; [failedPaths addObject:path]; message = [NSString stringWithFormat:@"恢复原权限失败（errno %d）", errno];
        } else { applied++; [records removeObjectForKey:path]; }
        close(fd);
    }
    if (![records isEqual:stored ?: @{}] && ![records writeToFile:file atomically:YES]) {
        failed++; message = @"恢复记录保存失败，将在下次重试";
    }
    return @{@"failed":@(failed), @"unlocatedFailures":@(failed-failedPaths.count), @"applied":@(applied), @"failedPaths":failedPaths, @"error":message};
}
// 只禁止模式的目录写锁：先把未记录条目的原始权限写入记录并落盘，再逐项去掉写权限并核对；
// 任一项失败回滚本轮已改条目。已无写权限的条目跳过，重复调用只补锁被改回的条目。
// 任务 9 起生产侧不再新施加写锁（Scanner 不再调用本函数）；保留本函数供测试验证
// 记录机制（记录格式与恢复路径共用），以及未来确有需要的定向锁定时复用。
NSDictionary *axs_cachekeeper_lock_paths(NSArray *roots, NSString *file) {
    NSDictionary *stored = [NSDictionary dictionaryWithContentsOfFile:file];
    if ((!stored && [NSFileManager.defaultManager fileExistsAtPath:file]) || !file.length)
        return @{@"failed":@1, @"locked":@0, @"error":@"权限记录不可读，未锁定任何目录"};
    NSMutableDictionary *records = [stored mutableCopy] ?: [NSMutableDictionary new];
    NSMutableArray<NSDictionary *> *targets = [NSMutableArray new];
    __block BOOL enumerationFailed = NO;
    for (NSString *root in roots ?: @[]) {
        struct stat info;
        if (![root isEqual:[NSURL fileURLWithPath:root].URLByResolvingSymlinksInPath.path] ||
            lstat(root.fileSystemRepresentation, &info) || !S_ISDIR(info.st_mode))
            return @{@"failed":@1, @"locked":@0, @"error":@"缓存目录不可访问或包含符号链接，未锁定"};
        NSMutableArray<NSString *> *found = [NSMutableArray arrayWithObject:root];
        NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtURL:[NSURL fileURLWithPath:root isDirectory:YES]
            includingPropertiesForKeys:nil options:0 errorHandler:^BOOL(NSURL *url, NSError *error) { enumerationFailed = YES; return YES; }];
        if (!enumerator) return @{@"failed":@1, @"locked":@0, @"error":@"无法打开缓存目录，未锁定"};
        for (NSURL *entry in enumerator) {
            struct stat child;
            if (lstat(entry.path.fileSystemRepresentation, &child)) { enumerationFailed = YES; continue; }
            if (S_ISLNK(child.st_mode) || (!S_ISDIR(child.st_mode) && !S_ISREG(child.st_mode))) continue;
            [found addObject:entry.path];
            if (found.count > 100000) return @{@"failed":@1, @"locked":@0, @"error":@"目录条目过多，未锁定"};
        }
        if (enumerationFailed) return @{@"failed":@1, @"locked":@0, @"error":@"目录遍历不完整，未锁定"};
        for (NSString *path in found) {
            struct stat current;
            if (lstat(path.fileSystemRepresentation, &current))
                return @{@"failed":@1, @"locked":@0, @"error":@"锁定前文件状态变化，未锁定"};
            if ((current.st_mode & 0222) == 0) continue;
            // 硬链接文件与根外路径共享同一 inode，上锁会波及根外；目录的链接数恒 ≥2（子目录计数），只对普通文件判定（审计第 7 项）。
            if (S_ISREG(current.st_mode) && current.st_nlink != 1) continue;
            [targets addObject:@{@"path":path, @"mode":@(current.st_mode & 07777),
                @"inode":@(current.st_ino), @"device":@(current.st_dev)}];
        }
    }
    if (!targets.count) return @{@"failed":@0, @"locked":@0, @"error":@""};
    BOOL journalChanged = NO;
    for (NSDictionary *target in targets) {
        NSDictionary *saved = records[target[@"path"]];
        // 身份不符时刷新记录：路径被重建（新 inode）后旧记录永远无法恢复新对象，
        // 不刷新则新对象被锁后永久无法恢复；身份相符时保留旧记录（其 mode 是首次锁定前的原始权限）。
        if (!saved || [saved[@"inode"] unsignedLongLongValue] != [target[@"inode"] unsignedLongLongValue] ||
            [saved[@"device"] unsignedLongLongValue] != [target[@"device"] unsignedLongLongValue]) {
            records[target[@"path"]] = @{@"inode":target[@"inode"], @"device":target[@"device"], @"mode":target[@"mode"]};
            journalChanged = YES;
        }
    }
    if (journalChanged && ![records writeToFile:file atomically:YES])
        return @{@"failed":@1, @"locked":@0, @"error":@"权限记录保存失败，未锁定"};
    NSMutableArray<NSString *> *changed = [NSMutableArray new];
    for (NSDictionary *target in targets) {
        NSString *path = target[@"path"];
        int fd = axs_cachekeeper_open_directory(path);
        if (fd < 0 && errno == ENOTDIR) fd = axs_cachekeeper_open_regular_file(path);
        struct stat current;
        BOOL identityOK = fd >= 0 && !fstat(fd, &current) &&
            current.st_ino == [target[@"inode"] unsignedLongLongValue] &&
            current.st_dev == [target[@"device"] unsignedLongLongValue];
        BOOL chmodOK = identityOK && !fchmod(fd, (mode_t)([target[@"mode"] unsignedIntValue] & ~0222));
        // fchmod 已生效即纳入回滚集：核对失败时该项已被锁定，不纳入则回滚漏掉它（审计第 7 项）。
        if (chmodOK) [changed addObject:path];
        BOOL verified = chmodOK && !fstat(fd, &current) && (current.st_mode & 0222) == 0;
        if (fd >= 0) close(fd);
        if (!verified) {
            NSDictionary *rollback = axs_cachekeeper_restore_paths(changed, file);
            // 回滚结果如实报告：未完全成功时明确说清，不谎称已回滚；locked 报回滚后仍锁定的余数。
            NSString *error = [rollback[@"failed"] unsignedIntegerValue] ?
                @"锁定中途失败，回滚未完全成功，请检查权限记录" :
                @"锁定中途失败，已回滚本轮改动";
            return @{@"failed":@1, @"locked":@(changed.count - [rollback[@"applied"] unsignedIntegerValue]), @"error":error};
        }
    }
    return @{@"failed":@0, @"locked":@(changed.count), @"error":@""};
}
NSDictionary *CKPermissions(NSURL *home, BOOL enabled) {
    if (enabled) return @{@"failed":@1,@"error":@"目录写锁已停止新施加，旧记录由桌面进程按记录恢复，此入口不执行锁定"};
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
