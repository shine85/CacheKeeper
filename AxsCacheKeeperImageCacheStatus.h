#pragma once
#define AXS_CACHEKEEPER_IMAGE_ADMISSION_DEFINED 1
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#define AXS_CACHEKEEPER_IMAGE_ADMISSION_MAX UINT64_C(9007199254740991)
// Shared by the producer and strict receipt projection. These are diagnostic
// outcomes, never authorization decisions or arbitrary SDK strings.
typedef enum {
    AxsCacheKeeperImageReasonNone, AxsCacheKeeperImageReasonNotChecked,
    AxsCacheKeeperImageReasonInitializerReturnedNil, AxsCacheKeeperImageReasonObservationLimit,
    AxsCacheKeeperImageReasonOwnerClass, AxsCacheKeeperImageReasonSDKMethodsChanged,
    AxsCacheKeeperImageReasonDiskMissing, AxsCacheKeeperImageReasonConfigurationMissing,
    AxsCacheKeeperImageReasonQueueMissing, AxsCacheKeeperImageReasonPathMissing,
    AxsCacheKeeperImageReasonPathType, AxsCacheKeeperImageReasonOwnerReleased,
    AxsCacheKeeperImageReasonDiskClass, AxsCacheKeeperImageReasonConfigurationClass,
    AxsCacheKeeperImageReasonConfigurationGetter, AxsCacheKeeperImageReasonMemoryClass,
    AxsCacheKeeperImageReasonMemoryBackend, AxsCacheKeeperImageReasonConfigurationIdentity,
    AxsCacheKeeperImageReasonCustomFileManager, AxsCacheKeeperImageReasonDiskBackend,
    AxsCacheKeeperImageReasonFileManagerClass, AxsCacheKeeperImageReasonInvalidated,
    AxsCacheKeeperImageReasonMemoryIdentity, AxsCacheKeeperImageReasonQueueIdentity,
    AxsCacheKeeperImageReasonPathValueChanged, AxsCacheKeeperImageReasonFileManagerIdentity,
    AxsCacheKeeperImageReasonQueueAttributesChanged, AxsCacheKeeperImageReasonInitialQueueAttributes,
    AxsCacheKeeperImageReasonUnclassified, AxsCacheKeeperImageReasonCount
} AxsCacheKeeperImageReason;
static inline const char *AxsCacheKeeperImageReasonName(unsigned reason) {
    static const char *const names[]={"none","notChecked","initializerReturnedNil","observationLimit",
        "ownerClass","sdkMethodsChanged","diskMissing","configurationMissing","queueMissing","pathMissing",
        "pathType","ownerReleased","diskClass","configurationClass","configurationGetter","memoryClass",
        "memoryBackend","configurationIdentity","customFileManager","diskBackend","fileManagerClass","invalidated",
        "memoryIdentity","queueIdentity","pathValueChanged","fileManagerIdentity","queueAttributesChanged",
        "initialQueueAttributes","unclassified"};
    return names[reason<AxsCacheKeeperImageReasonCount ? reason : AxsCacheKeeperImageReasonUnclassified];
}
static inline AxsCacheKeeperImageReason AxsCacheKeeperImageReasonParse(const char *name) {
    if (name) for (unsigned i=0;i<AxsCacheKeeperImageReasonCount;i++)
        if (!strcmp(name,AxsCacheKeeperImageReasonName(i))) return (AxsCacheKeeperImageReason)i;
    return AxsCacheKeeperImageReasonUnclassified;
}
static inline bool AxsCacheKeeperImageReasonIsEarly(unsigned reason) {
    return reason>=AxsCacheKeeperImageReasonInitializerReturnedNil && reason<=AxsCacheKeeperImageReasonPathType;
}
static inline bool AxsCacheKeeperImageReasonIsLive(unsigned reason) {
    return reason<AxsCacheKeeperImageReasonCount && reason!=AxsCacheKeeperImageReasonInitializerReturnedNil &&
        reason!=AxsCacheKeeperImageReasonObservationLimit && reason!=AxsCacheKeeperImageReasonQueueMissing &&
        reason!=AxsCacheKeeperImageReasonPathMissing && reason!=AxsCacheKeeperImageReasonPathType &&
        reason!=AxsCacheKeeperImageReasonOwnerReleased;
}
typedef struct {
    uint64_t initializerReturns,registered,unregistered,released;
    uint64_t unregisteredReasons[AxsCacheKeeperImageReasonCount];
    bool overflow;
} AxsCacheKeeperImageAdmission;
static inline uint64_t AxsCacheKeeperImageAdmissionSum(uint64_t a,uint64_t b) {
    return a>AXS_CACHEKEEPER_IMAGE_ADMISSION_MAX-b ? AXS_CACHEKEEPER_IMAGE_ADMISSION_MAX : a+b;
}
static inline void AxsCacheKeeperImageAdmissionIncrement(uint64_t *value,bool *overflow) {
    if (*value==AXS_CACHEKEEPER_IMAGE_ADMISSION_MAX) *overflow=true;else ++*value;
}
static inline void AxsCacheKeeperImageAdmissionRecord(AxsCacheKeeperImageAdmission *ledger,AxsCacheKeeperImageReason early) {
    if (early!=AxsCacheKeeperImageReasonNone && !AxsCacheKeeperImageReasonIsEarly(early)) return;
    AxsCacheKeeperImageAdmissionIncrement(&ledger->initializerReturns,&ledger->overflow);
    if (early==AxsCacheKeeperImageReasonNone) AxsCacheKeeperImageAdmissionIncrement(&ledger->registered,&ledger->overflow);
    else {
        AxsCacheKeeperImageAdmissionIncrement(&ledger->unregistered,&ledger->overflow);
        AxsCacheKeeperImageAdmissionIncrement(&ledger->unregisteredReasons[early],&ledger->overflow);
    }
}
static inline void AxsCacheKeeperImageAdmissionRelease(AxsCacheKeeperImageAdmission *ledger) {
    AxsCacheKeeperImageAdmissionIncrement(&ledger->released,&ledger->overflow);
}
static inline bool AxsCacheKeeperImageAdmissionValid(const AxsCacheKeeperImageAdmission *ledger,uint64_t live) {
    uint64_t counts[]={ledger->initializerReturns,ledger->registered,ledger->unregistered,ledger->released};
    bool atLimit=false;
    for (unsigned i=0;i<4;i++) {
        if (counts[i]>AXS_CACHEKEEPER_IMAGE_ADMISSION_MAX) return false;
        atLimit|=counts[i]==AXS_CACHEKEEPER_IMAGE_ADMISSION_MAX;
    }
    uint64_t total=0;bool truncated=false;
    for (unsigned i=0;i<AxsCacheKeeperImageReasonCount;i++) {
        uint64_t count=ledger->unregisteredReasons[i];
        if (count>AXS_CACHEKEEPER_IMAGE_ADMISSION_MAX || (count && !AxsCacheKeeperImageReasonIsEarly(i))) return false;
        truncated|=total>AXS_CACHEKEEPER_IMAGE_ADMISSION_MAX-count;
        total=AxsCacheKeeperImageAdmissionSum(total,count);
    }
    if (live>64) return false;
    truncated|=ledger->registered>AXS_CACHEKEEPER_IMAGE_ADMISSION_MAX-ledger->unregistered ||
        ledger->released>AXS_CACHEKEEPER_IMAGE_ADMISSION_MAX-live;
    return (!truncated || ledger->overflow) && (!ledger->overflow || atLimit) &&
        ledger->initializerReturns==AxsCacheKeeperImageAdmissionSum(ledger->registered,ledger->unregistered) &&
        ledger->unregistered==total && ledger->registered==AxsCacheKeeperImageAdmissionSum(ledger->released,live);
}
#ifdef __OBJC__
#import <Foundation/Foundation.h>
#import "AxsCacheKeeperImageWriteObservation.h"
#import "AxsCacheKeeperOperationInfo.h"
#import "AxsCacheKeeperInstallationCheck.h"
#import "AxsCacheKeeperRuntimeInfo.h"
#import "AxsCacheKeeperImageDiscovery.h"
#import "AxsCacheKeeperImageSourceObservation.h"
#import "AxsCacheKeeperInstallationImageObservation.h"
#include <math.h>

static inline BOOL axs_cachekeeper_image_counter(id value) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()) return NO;
    double number=[value doubleValue];
    return isfinite(number) && number>=0 && number<=9007199254740991.0 && floor(number)==number;
}
#ifndef AXS_CACHEKEEPER_STATUS_IMMUTABLE_COPY_DEFINED
#define AXS_CACHEKEEPER_STATUS_IMMUTABLE_COPY_DEFINED 1
static inline id axs_cachekeeper_status_immutable_copy(id value) {
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    return data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:nil] : nil;
}
#endif
static inline NSDictionary *axs_cachekeeper_image_admission_projection(id value,NSUInteger live) {
    if (![value isKindOfClass:NSDictionary.class] || [value count]!=8) return nil;
    NSArray *keys=@[@"schemaVersion",@"initializerReturns",@"registered",@"unregistered",@"released",@"overflow",@"unregisteredReasons",@"liveReasons"];
    if (![[NSSet setWithArray:[value allKeys]] isEqual:[NSSet setWithArray:keys]]) return nil;
    for (NSString *key in [keys subarrayWithRange:NSMakeRange(0,5)]) if (!axs_cachekeeper_image_counter(value[key])) return nil;
    if ([value[@"schemaVersion"] unsignedIntegerValue]!=1 ||
        ![value[@"overflow"] isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value[@"overflow"])!=CFBooleanGetTypeID()) return nil;
    AxsCacheKeeperImageAdmission ledger={.initializerReturns=[value[@"initializerReturns"] unsignedLongLongValue],
        .registered=[value[@"registered"] unsignedLongLongValue],.unregistered=[value[@"unregistered"] unsignedLongLongValue],
        .released=[value[@"released"] unsignedLongLongValue],.overflow=[value[@"overflow"] boolValue]};
    uint64_t liveTotal=0;
    for (NSString *field in @[@"unregisteredReasons",@"liveReasons"]) {
        NSDictionary *reasons=value[field];
        if (![reasons isKindOfClass:NSDictionary.class] || reasons.count>AxsCacheKeeperImageReasonCount) return nil;
        for (id key in reasons) {
            if (![key isKindOfClass:NSString.class]) return nil;
            AxsCacheKeeperImageReason reason=AxsCacheKeeperImageReasonParse([key UTF8String]);
            // Exact comparison also rejects embedded NUL strings.
            if (![key isEqual:@(AxsCacheKeeperImageReasonName(reason))] || !axs_cachekeeper_image_counter(reasons[key])) return nil;
            uint64_t count=[reasons[key] unsignedLongLongValue];if (!count) return nil;
            if ([field isEqual:@"unregisteredReasons"]) ledger.unregisteredReasons[reason]=count;
            else {
                if (count>64 || !AxsCacheKeeperImageReasonIsLive(reason)) return nil;
                liveTotal+=count;
            }
        }
    }
    return liveTotal==live && AxsCacheKeeperImageAdmissionValid(&ledger,live) ? axs_cachekeeper_status_immutable_copy(value) : nil;
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
    if (value[@"sdkMethodsRejectionObservation"]) {
        NSDictionary *rejection=axs_cachekeeper_image_sdk_rejection_projection(value[@"sdkMethodsRejectionObservation"]);
        if (!rejection) return nil;
        keys=[keys arrayByAddingObject:@"sdkMethodsRejectionObservation"];
    }
    if (value[@"runtimeSourceObservation"]) {
        if (!axs_cachekeeper_image_runtime_observation_projection(value[@"runtimeSourceObservation"])) return nil;
        keys=[keys arrayByAddingObject:@"runtimeSourceObservation"];
    }
    if (value[@"installedRuntimeRelation"]) {
        if (!axs_cachekeeper_installed_runtime_relation_projection(value[@"installedRuntimeRelation"]) ||
            !axs_cachekeeper_installed_runtime_relation_matches(value[@"installedRuntimeRelation"],value[@"runtimeSourceObservation"])) return nil;
        keys=[keys arrayByAddingObject:@"installedRuntimeRelation"];
    }
    if (value[@"operationHistory"]) {
        if (!axs_cachekeeper_operation_history_validate(value[@"operationHistory"],@"image")) return nil;
        keys=[keys arrayByAddingObject:@"operationHistory"];
    }
    if (value[@"writeObservation"]) {
        if (!axs_cachekeeper_write_observation_projection(value[@"writeObservation"])) return nil;
        keys=[keys arrayByAddingObject:@"writeObservation"];
    }
    if (value[@"instanceAdmission"]) keys=[keys arrayByAddingObject:@"instanceAdmission"];
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
    if (value[@"instanceAdmission"] && !axs_cachekeeper_image_admission_projection(value[@"instanceAdmission"],(NSUInteger)observed)) return nil;
    NSDictionary *rejection=value[@"sdkMethodsRejectionObservation"],*admission=value[@"instanceAdmission"];
    NSDictionary *rejectionCheck=rejection[@"check"];
    // A revoked main view may register a closed observation before readmission.
    // Its first rejection survives recovery/release without inventing another return.
    BOOL registeredMainView=[admission[@"registered"] unsignedLongLongValue]>0 &&
        [rejectionCheck[@"cause"] isEqual:@"legacyHelper"] && [rejectionCheck[@"helperStage"] isEqual:@"mainIdentity"] &&
        [rejectionCheck[@"helperReason"] isEqual:@"notMainBase"] && [rejectionCheck[@"methodsCount"] unsignedIntegerValue]==25 &&
        ![rejectionCheck[@"methodIndex"] unsignedIntegerValue] && ![rejectionCheck[@"helperIndex"] unsignedIntegerValue];
    if ([rejection[@"state"] isEqual:@"recorded"] &&
        (!admission || [rejection[@"initializerOrdinal"] unsignedLongLongValue]>[admission[@"initializerReturns"] unsignedLongLongValue] ||
         (![admission[@"unregisteredReasons"][@"sdkMethodsChanged"] unsignedLongLongValue] && !registeredMainView))) return nil;
    return axs_cachekeeper_status_immutable_copy(value);
}
static inline NSDictionary *axs_cachekeeper_image_cache_projection_with_aliases(id value,NSMutableDictionary *aliases) {
    NSDictionary *raw=axs_cachekeeper_image_cache_raw_projection(value);if (!raw) return nil;
    NSMutableDictionary *result=[raw mutableCopy];
    // The cumulative blocked counter outlives the bounded writer epochs and
    // cannot be attributed to the strict writer observation in this export.
    [result removeObjectForKey:@"writesBlocked"];
    if (!result[@"sdkMethodsRejectionObservation"]) result[@"sdkMethodsRejectionObservation"]=@{@"schemaVersion":@1,@"state":@"notRecorded"};
    if (raw[@"operationHistory"]) {
        NSDictionary *history=axs_cachekeeper_operation_history_projection(raw[@"operationHistory"],aliases);
        if (!history) return nil;result[@"operationHistory"]=history;
    }
    return [result copy];
}
static inline NSDictionary *axs_cachekeeper_image_cache_projection(id value) {
    return axs_cachekeeper_image_cache_projection_with_aliases(value,[NSMutableDictionary new]);
}
static inline NSString *axs_cachekeeper_image_admission_reason_message(NSString *reason) {
    NSDictionary *messages=@{@"initializerReturnedNil":@"初始化未返回实例",@"observationLimit":@"观察数量已达上限",
        @"ownerClass":@"实例类型不符",@"sdkMethodsChanged":@"SDK 方法身份已变化",@"diskMissing":@"磁盘缓存成员缺失",
        @"configurationMissing":@"配置成员缺失",@"queueMissing":@"队列成员缺失",@"pathMissing":@"缓存路径缺失",
        @"pathType":@"缓存路径类型不符",@"diskClass":@"磁盘缓存类型不符",@"configurationClass":@"配置类型不符",
        @"configurationGetter":@"配置读取方法不符",@"memoryClass":@"内存缓存类型不符",@"memoryBackend":@"内存后端配置不符",
        @"configurationIdentity":@"配置对象身份不一致",@"customFileManager":@"使用自定义文件管理器",
        @"diskBackend":@"磁盘后端配置不符",@"fileManagerClass":@"文件管理器类型不符",@"invalidated":@"实例准入已失效",
        @"memoryIdentity":@"内存缓存身份已变化",@"queueIdentity":@"队列身份已变化",@"pathValueChanged":@"缓存路径值已变化",
        @"fileManagerIdentity":@"文件管理器身份已变化",@"queueAttributesChanged":@"队列属性已变化",
        @"initialQueueAttributes":@"初始队列属性不受支持",@"notChecked":@"实例检查被前序门阻止",
        @"unclassified":@"实例检查未通过"};
    return messages[reason];
}
static inline NSString *axs_cachekeeper_image_admission_reason_summary(NSDictionary *counts) {
    NSMutableArray *parts=[NSMutableArray new];
    for (unsigned i=0;i<AxsCacheKeeperImageReasonCount;i++) {
        NSString *key=@(AxsCacheKeeperImageReasonName(i)),*message=axs_cachekeeper_image_admission_reason_message(key);
        if (counts[key] && message) [parts addObject:[NSString stringWithFormat:@"%@ %@ 次",message,counts[key]]];
    }
    return [parts componentsJoinedByString:@"；"];
}
static inline NSString *axs_cachekeeper_image_cache_message(id value) {
    NSDictionary *record=axs_cachekeeper_image_cache_raw_projection(value);
    if (!record) return @"图片缓存回执不可用或字段无效";
    NSDictionary *admission=record[@"instanceAdmission"];
    if ([record[@"reason"] isEqual:@"unsupportedInstance"] && admission && [record[@"observed"] unsignedIntegerValue]) {
        NSString *details=axs_cachekeeper_image_admission_reason_summary(admission[@"liveReasons"]);
        if (details.length) return [@"图片缓存保持原行为：" stringByAppendingString:details];
    }
    if (admission && ![record[@"observed"] unsignedIntegerValue] && ![record[@"pending"] unsignedIntegerValue] &&
        ([@[@"none",@"unsupportedInstance",@"ownerChanged"] containsObject:record[@"reason"]])) {
        if ([admission[@"released"] unsignedLongLongValue])
            return [NSString stringWithFormat:@"已登记的图片缓存实例已释放（%@ 次）；当前无存活实例；清理 API 累计完成 %@ 次",
                admission[@"released"],record[@"apiCompleted"]];
        if ([admission[@"unregistered"] unsignedLongLongValue])
            return [@"已观察初始化返回，但未登记：" stringByAppendingString:axs_cachekeeper_image_admission_reason_summary(admission[@"unregisteredReasons"])];
    }
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
        @"unsupportedInstance":@"图片缓存实例未通过准入检查，保持原行为",
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
    if (!record[@"writeObservation"])
        return [NSString stringWithFormat:@"SDWebImage 写入观测未记录；清理 API 累计完成 %@ 次；释放空间未单独测量",record[@"apiCompleted"]];
    NSDictionary *observation=record[@"writeObservation"];
    NSMutableArray *rows=[NSMutableArray new];
    for (NSDictionary *epoch in observation[@"epochs"]) {
        NSDictionary *data=epoch[@"data"],*extended=epoch[@"extended"];
        if ([data[@"attempts"] unsignedLongLongValue] || [extended[@"attempts"] unsignedLongLongValue])
            [rows addObject:[NSString stringWithFormat:@"%@ data %@/%@/%@, extended %@/%@/%@",epoch[@"mode"],data[@"attempts"],data[@"blocked"],data[@"allowed"],extended[@"attempts"],extended[@"blocked"],extended[@"allowed"]]];
    }
    NSString *writerSummary=rows.count ? [rows componentsJoinedByString:@"；"] : @"本记录没有 SDWebImage 写入尝试观测";
    return [NSString stringWithFormat:@"SDWebImage 写入观测：%@；清理 API 累计完成 %@ 次；释放空间未单独测量",
        writerSummary,record[@"apiCompleted"]];
}
#endif
