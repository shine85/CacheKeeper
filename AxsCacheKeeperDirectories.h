#pragma once
#import <Foundation/Foundation.h>

NSArray<NSString *> *axs_cachekeeper_scan_directories(NSURL *home, NSError **error);
// B 案清理候选发现：返回家目录下所有可枚举目录的相对路径（未知目录也在内）。
// 注意：不能用 scan_targets 的 readOnly 过滤——它标记的是“非标准缓存路径”而非文件系统只读，
// 未知目录全是 readOnly=YES，过滤后候选集恒为空，B 案静默失效（#37 真机教训）。
NSArray<NSString *> *axs_cachekeeper_purge_candidates(NSURL *home, NSError **error);
NSDictionary<NSString *,NSURL *> *axs_cachekeeper_valid_group_homes(NSDictionary *groups);
NSArray<NSDictionary *> *axs_cachekeeper_scan_targets(NSURL *home, NSDictionary *groups, NSError **error);
NSArray<NSString *> *axs_cachekeeper_discover_cache_roots(NSURL *home, NSError **error);
