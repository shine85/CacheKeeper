#import <Foundation/Foundation.h>
#if CK_STANDALONE_RESTORE
#include <mach-o/dyld.h>
#include <stdlib.h>
static NSString *jbroot(NSString *path) {
    char buffer[4096]; uint32_t size=sizeof(buffer);
    if (_NSGetExecutablePath(buffer,&size)) return nil;
    char *resolved=realpath(buffer,NULL);
    if (!resolved) return nil;
    NSString *executable=[NSString stringWithUTF8String:resolved]; free(resolved);
    NSString *root=executable.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
    return [root stringByAppendingPathComponent:path];
}
#else
#include <roothide.h>
#endif
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

void CKSetPaths(NSArray *paths, BOOL enabled) {
    NSString *file = jbroot(@"/var/mobile/Library/CacheKeeper/permissions.plist");
    NSMutableDictionary *records = [[NSDictionary dictionaryWithContentsOfFile:file] mutableCopy] ?: [NSMutableDictionary new];
    if (enabled) {
        // 0.3.8 优化（不改“恢复记录先落盘、然后才改权限”的安全顺序）：
        // 原实现每遇到一个新目录就把 permissions.plist 原子写一遍，目录上百时写上百次。
        // 改为两段式：先收集全部新记录并整表写一次，成功后才统一改权限；
        // 写失败时本轮只处理此前已有记录的目录，新目录一律不动。
        // 另外，已处于限写状态（属主写位已清）的目录跳过重复 fchmod。
        NSMutableSet *ready = [NSMutableSet set];
        NSMutableSet *fresh = [NSMutableSet set];
        for (NSString *path in paths) {
            if (![path isEqual:[NSURL fileURLWithPath:path].URLByResolvingSymlinksInPath.path]) continue;
            int fd = open(path.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);
            if (fd < 0) continue;
            struct stat info;
            if (fstat(fd,&info)) { close(fd); continue; }
            close(fd);
            NSDictionary *saved = records[path];
            if (saved && [saved[@"inode"] unsignedLongLongValue] == info.st_ino && [saved[@"device"] unsignedLongLongValue] == info.st_dev) {
                [ready addObject:path];
            } else {
                records[path] = @{@"mode":@(info.st_mode & 0777),@"inode":@(info.st_ino),@"device":@(info.st_dev)};
                [fresh addObject:path];
            }
        }
        if (fresh.count && [records writeToFile:file atomically:YES]) [ready unionSet:fresh];
        for (NSString *path in ready) {
            int fd = open(path.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);
            if (fd < 0) continue;
            struct stat info;
            NSDictionary *saved = records[path];
            if (!fstat(fd,&info) && saved && [saved[@"inode"] unsignedLongLongValue] == info.st_ino && [saved[@"device"] unsignedLongLongValue] == info.st_dev && (info.st_mode & S_IWUSR)) {
                fchmod(fd,(info.st_mode & 0777) & ~S_IWUSR);
            }
            close(fd);
        }
    } else {
        for (NSString *path in (paths ?: records.allKeys)) {
            if (![path isEqual:[NSURL fileURLWithPath:path].URLByResolvingSymlinksInPath.path]) continue;
            int fd = open(path.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);
            if (fd < 0) continue;
            struct stat info; NSDictionary *saved = records[path];
            // 0.3.8 优化：权限已等于原值时视为已恢复，不再重复 fchmod（记录照常清除）
            mode_t wantedMode = [saved[@"mode"] unsignedIntValue];
            if (!fstat(fd,&info) && saved && [saved[@"inode"] unsignedLongLongValue] == info.st_ino && [saved[@"device"] unsignedLongLongValue] == info.st_dev && ((info.st_mode & 0777) == wantedMode || !fchmod(fd,wantedMode))) [records removeObjectForKey:path];
            close(fd);
        }
        [records writeToFile:file atomically:YES];
    }
}

void CKPermissions(NSURL *home, BOOL enabled) {
    NSArray *paths = home ? @[[home.path stringByAppendingPathComponent:@"Library/Application Support/gurd_cache"], [home.path stringByAppendingPathComponent:@"Library/Caches/TTPlayerCache"]] : nil;
    CKSetPaths(paths, enabled);
}
