#pragma once
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import "AxsCacheKeeperPolicy.h"

static NSString *const AxsCacheKeeperFilzaBundleID=@"com.tigisoftware.Filza";

static inline NSURL *axs_cachekeeper_filza_url(NSString *path, NSDictionary *info) {
    if (![path isKindOfClass:NSString.class] || ![path hasPrefix:@"/"] || path.length<2 ||
        !axs_cachekeeper_relative_path([path substringFromIndex:1])) return nil;
    BOOL registered=NO;
    id types=info[@"CFBundleURLTypes"];
    if ([types isKindOfClass:NSArray.class]) for (id type in types) {
        id schemes=[type isKindOfClass:NSDictionary.class] ? type[@"CFBundleURLSchemes"] : nil;
        if ([schemes isKindOfClass:NSArray.class]) for (id scheme in schemes)
            if ([scheme isKindOfClass:NSString.class] && [scheme caseInsensitiveCompare:@"filza"]==NSOrderedSame) registered=YES;
    }
    if (!registered) return [NSURL fileURLWithPath:path isDirectory:YES];
    NSURLComponents *url=[NSURLComponents new];url.scheme=@"filza";url.host=@"";url.path=path;
    return url.URL;
}

// 通过系统应用启动请求携带文件 URL；成功回调只表示请求被接受，不等于已观察到目标目录。
static inline void axs_cachekeeper_send_filza_document(id workspace, id configuration, NSString *payloadKey,
    NSURL *url, void (^completion)(BOOL,NSError *)) {
    SEL setter=NSSelectorFromString(@"setFrontBoardOptions:");
    SEL opener=NSSelectorFromString(@"openApplicationWithBundleIdentifier:usingConfiguration:completionHandler:");
    if (![workspace respondsToSelector:opener] || ![configuration respondsToSelector:setter] || !payloadKey.length || !url.isFileURL) {
        completion(NO,[NSError errorWithDomain:@"CacheKeeper.Filza" code:1 userInfo:@{NSLocalizedDescriptionKey:@"当前系统没有可用的定向文件打开接口"}]);return;
    }
    ((void(*)(id,SEL,id))objc_msgSend)(configuration,setter,@{payloadKey:url});
    ((void(*)(id,SEL,id,id,id))objc_msgSend)(workspace,opener,AxsCacheKeeperFilzaBundleID,configuration,completion);
}
