#pragma once
#import <Foundation/Foundation.h>
#import "AxsCacheKeeperImageEffect.h"
#include <math.h>
static inline NSArray *axs_cachekeeper_image_sample_states(void) {
    return @[@"complete",@"readError",@"changed",@"nonFlat",@"entryLimit",@"timeLimit",@"overflow",@"closeError",@"pathChanged"];
}
static inline NSString *axs_cachekeeper_image_sample_message(NSString *state) {
    NSDictionary *messages=@{@"complete":@"采样完成",@"readError":@"读取失败",@"changed":@"采样时目录发生变化",
        @"nonFlat":@"存在子目录或链接",@"entryLimit":@"条目超过采样上限",@"timeLimit":@"采样时间不足",
        @"overflow":@"数值超过精确范围",@"closeError":@"关闭观测句柄失败",@"pathChanged":@"目录或缓存实例身份已变化"};
    return messages[state] ?: @"状态未知";
}
static inline NSDictionary *axs_cachekeeper_image_sample_record(AxsCacheKeeperImageSample sample) {
    NSArray *states=axs_cachekeeper_image_sample_states();if ((NSUInteger)sample.state>=states.count) return nil;
    return @{@"state":states[sample.state],@"files":@(sample.files),@"logicalBytes":@(sample.logicalBytes),@"allocatedBytes":@(sample.allocatedBytes)};
}
static inline BOOL axs_cachekeeper_image_sample_parse(id value,AxsCacheKeeperImageSample *sample) {
    NSArray *keys=@[@"state",@"files",@"logicalBytes",@"allocatedBytes"];
    if (![value isKindOfClass:NSDictionary.class] || [value count]!=keys.count || ![[NSSet setWithArray:[value allKeys]] isEqual:[NSSet setWithArray:keys]]) return NO;
    NSUInteger state=[axs_cachekeeper_image_sample_states() indexOfObject:value[@"state"]];if (state==NSNotFound) return NO;
    for (NSString *key in @[@"files",@"logicalBytes",@"allocatedBytes"]) {
        id n=value[key];if (![n isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)n)==CFBooleanGetTypeID()) return NO;
        double number=[n doubleValue];if (!isfinite(number) || number<0 || number>AXS_CACHEKEEPER_IMAGE_EXACT_MAX || floor(number)!=number) return NO;
    }
    if ([value[@"files"] unsignedLongLongValue]>100000 || (![value[@"files"] unsignedLongLongValue] &&
        ([value[@"logicalBytes"] unsignedLongLongValue] || [value[@"allocatedBytes"] unsignedLongLongValue]))) return NO;
    *sample=(AxsCacheKeeperImageSample){(AxsCacheKeeperImageSampleState)state,[value[@"files"] unsignedLongLongValue],
        [value[@"logicalBytes"] unsignedLongLongValue],[value[@"allocatedBytes"] unsignedLongLongValue]};return YES;
}
static inline NSDictionary *axs_cachekeeper_image_effect_record(AxsCacheKeeperImageSample before,AxsCacheKeeperImageSample after) {
    NSDictionary *first=axs_cachekeeper_image_sample_record(before),*last=axs_cachekeeper_image_sample_record(after);if (!first || !last) return nil;
    NSString *result=@[@"unverified",@"empty",@"residual"][axs_cachekeeper_image_effect_result(before,after)];
    return @{@"scope":@"sdkFlatDirectoryEntries",@"result":result,@"before":first,
        @"after":last,@"physicalRelease":@"notMeasured"};
}
static inline NSDictionary *axs_cachekeeper_image_effect_projection(id value) {
    NSArray *keys=@[@"scope",@"result",@"before",@"after",@"physicalRelease"];
    if (![value isKindOfClass:NSDictionary.class] || [value count]!=keys.count || ![[NSSet setWithArray:[value allKeys]] isEqual:[NSSet setWithArray:keys]] ||
        ![value[@"scope"] isEqual:@"sdkFlatDirectoryEntries"] || ![value[@"physicalRelease"] isEqual:@"notMeasured"]) return nil;
    AxsCacheKeeperImageSample before,after;
    if (!axs_cachekeeper_image_sample_parse(value[@"before"],&before) || !axs_cachekeeper_image_sample_parse(value[@"after"],&after)) return nil;
    NSDictionary *record=axs_cachekeeper_image_effect_record(before,after);
    return [record isEqual:value] ? record : nil;
}
