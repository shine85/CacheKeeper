#pragma once
#import <Foundation/Foundation.h>
#import "AxsCacheKeeperOperationInfo.h"
#import "AxsCacheKeeperInstallationCheck.h"
#import "AxsCacheKeeperRuntimeInfo.h"
#import "AxsCacheKeeperImageDiscovery.h"
#include <math.h>

static inline BOOL axs_cachekeeper_image_counter(id value) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()) return NO;
    double number=[value doubleValue];
    return isfinite(number) && number>=0 && number<=9007199254740991.0 && floor(number)==number;
}
// No cache keys, URLs, filesystem paths or installation identities cross this boundary.
static inline NSDictionary *axs_cachekeeper_image_cache_raw_projection(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    NSArray *keys=@[@"schemaVersion",@"sdk",@"state",@"reason",@"observed",@"eligible",@"restricted",@"writesBlocked",
        @"queued",@"submitted",@"apiCompleted",@"skipped",@"pending",@"updated",@"bytesState"];
    if (value[@"installationCheck"]) {
        if (!axs_cachekeeper_installation_check_projection(value[@"installationCheck"])) return nil;
        keys=[keys arrayByAddingObject:@"installationCheck"];
    }
    if (value[@"runtimeInfo"]) {
        if (!axs_cachekeeper_runtime_info_projection(value[@"runtimeInfo"])) return nil;
        keys=[keys arrayByAddingObject:@"runtimeInfo"];
    }
    if (value[@"discoveryCheck"]) {
        if (!axs_cachekeeper_image_discovery_projection(value[@"discoveryCheck"])) return nil;
        keys=[keys arrayByAddingObject:@"discoveryCheck"];
    }
    if (value[@"operationHistory"]) {
        if (!axs_cachekeeper_operation_history_validate(value[@"operationHistory"],@"image")) return nil;
        keys=[keys arrayByAddingObject:@"operationHistory"];
    }
    if ([value count]!=keys.count || ![[NSSet setWithArray:[value allKeys]] isEqual:[NSSet setWithArray:keys]]) return nil;
    for (NSString *key in @[@"schemaVersion",@"observed",@"eligible",@"restricted",@"writesBlocked",@"queued",@"submitted",@"apiCompleted",@"skipped",@"pending"])
        if (!axs_cachekeeper_image_counter(value[key])) return nil;
    if ([value[@"schemaVersion"] unsignedIntegerValue]!=1 || ![value[@"sdk"] isEqual:@"SDWebImage"] ||
        ![value[@"bytesState"] isEqual:@"notMeasured"] || ![value[@"updated"] isKindOfClass:NSDate.class] ||
        !isfinite([value[@"updated"] timeIntervalSince1970])) return nil;
    if (![@[@"disabled",@"notObserved",@"unsupported",@"ready",@"restricting",@"queued",@"apiCompleted",@"blocked",@"timedOut"] containsObject:value[@"state"]] ||
        ![@[@"none",@"appDisabled",@"configurationInvalid",@"installationUnverified",@"installationChanged",@"unsupportedSDK",
            @"unsupportedInstance",@"observationLimit",@"scopeNotAuthorized",@"scopeUnverified",@"pathChanged",@"overlappingOwners",@"ownerChanged",
            @"authorizationChanged",@"foregroundAgain",@"noBackgroundTime",@"deadlineExceeded",@"inFlight",@"reportWriteFailed"] containsObject:value[@"reason"]]) return nil;
    unsigned long long observed=[value[@"observed"] unsignedLongLongValue], eligible=[value[@"eligible"] unsignedLongLongValue];
    unsigned long long queued=[value[@"queued"] unsignedLongLongValue], submitted=[value[@"submitted"] unsignedLongLongValue];
    unsigned long long completed=[value[@"apiCompleted"] unsignedLongLongValue], skipped=[value[@"skipped"] unsignedLongLongValue];
    unsigned long long pending=[value[@"pending"] unsignedLongLongValue];
    if (eligible>observed || [value[@"restricted"] unsignedLongLongValue]>eligible || submitted>queued || completed>submitted ||
        skipped>queued-submitted || pending!=queued-completed-skipped || pending>64) return nil;
    if ([value[@"state"] isEqual:@"timedOut"] && !pending) return nil;
    if ([value[@"state"] isEqual:@"apiCompleted"] && (!completed || pending)) return nil;
    return [value copy];
}
static inline NSDictionary *axs_cachekeeper_image_cache_projection_with_aliases(id value,NSMutableDictionary *aliases) {
    NSDictionary *raw=axs_cachekeeper_image_cache_raw_projection(value);if (!raw) return nil;
    NSMutableDictionary *result=[raw mutableCopy];
    if (raw[@"operationHistory"]) {
        NSDictionary *history=axs_cachekeeper_operation_history_projection(raw[@"operationHistory"],aliases);
        if (!history) return nil;result[@"operationHistory"]=history;
    }
    return [result copy];
}
static inline NSDictionary *axs_cachekeeper_image_cache_projection(id value) {
    return axs_cachekeeper_image_cache_projection_with_aliases(value,[NSMutableDictionary new]);
}
static inline NSString *axs_cachekeeper_image_cache_message(id value) {
    NSDictionary *record=axs_cachekeeper_image_cache_raw_projection(value);
    if (!record) return @"图片缓存回执不可用或字段无效";
    NSDictionary *discovery=record[@"discoveryCheck"];
    if ([record[@"reason"] isEqual:@"unsupportedSDK"] && discovery) {
        if ([discovery[@"stage"] isEqual:@"classes"])
            return [discovery[@"classMask"] unsignedIntegerValue] ? @"图片缓存组件尚不完整，未启用适配" : @"此进程尚未发现 SDWebImage 图片缓存";
        if ([discovery[@"stage"] isEqual:@"source"]) return @"已发现图片缓存组件，当前实现尚未核验";
        if ([@[@"image",@"method"] containsObject:discovery[@"stage"]]) return @"图片缓存接口或来源与已核验契约不符，保持原行为";
    }
    NSDictionary *messages=@{@"appDisabled":@"此 APP 未开启，图片缓存保持原行为",
        @"configurationInvalid":@"配置不可读或字段无效，未限制或清理图片缓存",
        @"installationUnverified":@"安装身份尚未核实，本轮未执行",
        @"installationChanged":@"安装身份已变化，等待重新观察图片缓存实例",
        @"unsupportedSDK":@"尚未识别到已适配的 SDWebImage 实现",
        @"unsupportedInstance":@"此图片缓存使用自定义后端或队列，保持原行为",
        @"observationLimit":@"图片缓存实例超过观察上限，本进程保持原行为",
        @"scopeNotAuthorized":@"图片缓存范围未获授权或与保留目录重叠，保持原行为",
        @"scopeUnverified":@"图片缓存目录未通过完整检查，本轮未清理",
        @"pathChanged":@"图片缓存目录身份已变化，本轮未执行",
        @"overlappingOwners":@"多个缓存实例共用或重叠目录，未限制或清理",
        @"ownerChanged":@"缓存实例、配置或队列已变化，保持原行为",
        @"authorizationChanged":@"设置已变化，已停止尚未执行的图片缓存清理",
        @"foregroundAgain":@"APP 已回到前台，已停止尚未执行的图片缓存清理",
        @"noBackgroundTime":@"后台时间不足，已停止尚未执行的图片缓存清理",
        @"deadlineExceeded":@"图片缓存队列等待超时，已取消尚未执行的清理",
        @"inFlight":@"原图片缓存请求仍在等待，不重复提交",
        @"reportWriteFailed":@"图片缓存回执无法保存，未启动清理"};
    if ([record[@"state"] isEqual:@"timedOut"]) return @"图片缓存队列等待超时；原请求尚未结束，不重复提交";
    if (messages[record[@"reason"]]) return messages[record[@"reason"]];
    if ([record[@"state"] isEqual:@"notObserved"]) return @"尚未观察到 APP 实际创建的已适配图片缓存";
    if ([record[@"pending"] unsignedIntegerValue]) return @"图片缓存清理已排队，执行前再次核对授权";
    return [NSString stringWithFormat:@"已适配 %@ 个实例，限制写盘 %@ 次，清理 API 完成 %@ 次；释放空间未单独测量",
        record[@"eligible"],record[@"writesBlocked"],record[@"apiCompleted"]];
}
