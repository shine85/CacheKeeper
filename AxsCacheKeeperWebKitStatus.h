#pragma once
#import <Foundation/Foundation.h>
#import "AxsCacheKeeperInstallationDetail.h"
#import "AxsCacheKeeperInstallationCheck.h"
#import "AxsCacheKeeperRuntimeInfo.h"
#include <math.h>

static inline BOOL axs_cachekeeper_webkit_boolean(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID();
}
static inline BOOL axs_cachekeeper_webkit_counter(id value) {
    if (![value isKindOfClass:NSNumber.class] || axs_cachekeeper_webkit_boolean(value)) return NO;
    double number=[value doubleValue];
    return isfinite(number) && number>=0 && number<=9007199254740991.0 && floor(number)==number;
}
static inline NSDictionary *axs_cachekeeper_webkit_installation_check(id value) {
    return axs_cachekeeper_installation_check_projection(value);
}
// A closed projection prevents runtime identities or website content entering saved/exported state.
static inline NSDictionary *axs_cachekeeper_webkit_projection(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *installationCheck=nil;
    NSArray *keys=@[@"schemaVersion",@"requested",@"timedOut",@"state",@"reason",@"persistentStores",@"nonPersistentStores",@"submitted",@"completed",@"pending",@"updated",@"bytesState"];
    // Optional for existing receipts; new data still obeys an exact, content-free schema.
    if (value[@"installationCheck"]) {
        installationCheck=axs_cachekeeper_webkit_installation_check(value[@"installationCheck"]);
        if (!installationCheck) return nil;
        keys=[keys arrayByAddingObject:@"installationCheck"];
    }
    if (value[@"runtimeInfo"]) {
        if (!axs_cachekeeper_runtime_info_projection(value[@"runtimeInfo"])) return nil;
        keys=[keys arrayByAddingObject:@"runtimeInfo"];
    }
    if ([value count]!=keys.count || ![[NSSet setWithArray:[value allKeys]] isEqual:[NSSet setWithArray:keys]]) return nil;
    if (!axs_cachekeeper_webkit_counter(value[@"schemaVersion"]) || [value[@"schemaVersion"] unsignedIntegerValue]!=1 ||
        !axs_cachekeeper_webkit_boolean(value[@"requested"]) || !axs_cachekeeper_webkit_boolean(value[@"timedOut"])) return nil;
    NSArray *states=@[@"disabled",@"notObserved",@"nonPersistentOnly",@"ready",@"queued",@"submitted",@"completed",@"waitingTimedOut",@"blocked",@"stale",@"unsupported"];
    NSArray *reasons=@[@"none",@"appDisabled",@"notAuthorized",@"configurationUnreadable",@"configurationInvalid",@"exclusionUnrepresentable",@"installationUnverified",@"installationChanged",@"processUnverified",@"storeUnavailable",@"unsupported",@"noBackgroundTime",@"foregroundAgain",@"inFlight",@"authorizationChanged",@"reportWriteFailed",@"interruptedUnknown"];
    if (![states containsObject:value[@"state"]] || ![reasons containsObject:value[@"reason"]] ||
        ![value[@"bytesState"] isEqual:@"notMeasured"] || ![value[@"updated"] isKindOfClass:NSDate.class] ||
        !isfinite([value[@"updated"] timeIntervalSince1970])) return nil;
    for (NSString *key in @[@"persistentStores",@"nonPersistentStores",@"submitted",@"completed",@"pending"])
        if (!axs_cachekeeper_webkit_counter(value[key])) return nil;
    if ([value[@"pending"] unsignedIntegerValue]>1 || [value[@"completed"] unsignedLongLongValue]>[value[@"submitted"] unsignedLongLongValue]) return nil;
    unsigned long long submitted=[value[@"submitted"] unsignedLongLongValue],completed=[value[@"completed"] unsignedLongLongValue],pending=[value[@"pending"] unsignedLongLongValue];
    if (pending!=submitted-completed) return nil;
    if ([value[@"state"] isEqual:@"completed"] && (!completed || pending)) return nil;
    if ([@[@"submitted",@"waitingTimedOut"] containsObject:value[@"state"]] && !pending) return nil;
    if ([value[@"state"] isEqual:@"waitingTimedOut"] && ![value[@"timedOut"] boolValue]) return nil;
    NSMutableDictionary *result=[value mutableCopy];
    if (installationCheck) result[@"installationCheck"]=installationCheck;
    return [result copy];
}
static inline NSString *axs_cachekeeper_webkit_message(id value) {
    NSDictionary *record=axs_cachekeeper_webkit_projection(value);
    if (!record) return @"网页缓存回执不可用或字段无效";
    NSString *reason=record[@"reason"],*state=record[@"state"];
    if (![record[@"pending"] boolValue] && [reason isEqual:@"installationUnverified"] && record[@"installationCheck"]) {
        NSDictionary *check=record[@"installationCheck"];
        if ([check[@"state"] isEqual:@"versionUnknown"]) return @"安装版本信息不完整，本轮未执行";
        if ([check[@"state"] isEqual:@"invalid"]) return @"安装校验诊断无效，本轮未执行";
        NSArray *errors=@[@"安装校验未返回具体错误",@"安装标识或包 URL 无效",@"安装目录不可读或身份已变化",
            @"安装信息或主程序文件不可读或身份已变化",@"安装信息读取不完整或超出大小上限",@"安装信息内容无效",
            @"安装版本或身份已变化",@"系统应用列表不可用"];
        if ([check[@"state"] isEqual:@"failed"]) {
            NSDictionary *detail=check[@"detail"];
            NSString *message=errors[[check[@"errorCode"] unsignedIntegerValue]];
            if (detail) {
                NSDictionary *targets=@{@"input":@"校验输入",@"root":@"安装目录",@"info":@"安装信息文件",@"main":@"主程序",@"snapshot":@"安装快照",@"registry":@"系统应用列表"};
                message=[message stringByAppendingFormat:@"（%@ / %@，errno=%@）",targets[detail[@"target"]],detail[@"operation"],detail[@"errno"]];
            }
            return [message stringByAppendingString:@"，本轮未执行"];
        }
    }
    if ([record[@"pending"] boolValue]) return [record[@"timedOut"] boolValue] ?
        @"系统清理回调等待超时；原请求仍在等待，未启动后续回收" :
        @"已提交网页磁盘缓存回收，等待系统回调；不代表已测得释放空间";
    NSDictionary *messages=@{@"appDisabled":@"此 APP 未开启，本轮未执行",@"notAuthorized":@"未开启网页磁盘缓存回收",
        @"configurationUnreadable":@"配置不可读，本轮未执行",@"configurationInvalid":@"配置字段无效，本轮未执行",
        @"exclusionUnrepresentable":@"存在手动保留目录；系统接口不能逐路径排除，本轮未执行",
        @"installationUnverified":@"当前安装身份尚未核实，本轮未执行",@"installationChanged":@"安装身份已变化，等待重新观察网页数据存储",
        @"processUnverified":@"进程实例尚未核实，本轮未执行",@"storeUnavailable":@"已观察的数据存储已释放，本轮未执行",
        @"unsupported":@"系统网页缓存接口不可用，本轮未执行",@"noBackgroundTime":@"后台执行时间不可用，未启动后续回收",
        @"foregroundAgain":@"APP 已恢复前台，未启动后续回收",@"authorizationChanged":@"设置已变化，未启动后续回收",
        @"reportWriteFailed":@"运行回执无法保存，未启动回收",@"interruptedUnknown":@"上次请求中断，实际结果未知"};
    if (messages[reason]) return messages[reason];
    if ([state isEqual:@"completed"]) return [NSString stringWithFormat:@"系统清理回调已完成（%@ 个）；释放空间未单独测量",record[@"completed"]];
    if ([state isEqual:@"notObserved"]) return @"尚未观察到此 APP 使用网页数据存储；本轮未执行";
    if ([state isEqual:@"nonPersistentOnly"]) return @"仅观察到无痕数据存储，没有本轮磁盘回收目标";
    if ([state isEqual:@"queued"]) return @"正在复核配置、安装身份及后台执行时间";
    return @"已观察到网页磁盘缓存能力，等待 APP 使用后转入后台";
}
