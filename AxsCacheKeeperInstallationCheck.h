#pragma once
#import <Foundation/Foundation.h>
#import "AxsCacheKeeperInstallationDetail.h"

// Display-only contract shared by cache runtimes; execution still requires the private snapshot.
static inline NSDictionary *axs_cachekeeper_installation_check_projection(id value) {
    if (![value isKindOfClass:NSDictionary.class] || [value count]!=(value[@"detail"] ? 3 : 2) ||
        ![value[@"state"] isKindOfClass:NSString.class] ||
        ![@[@"notRequested",@"verified",@"versionUnknown",@"failed",@"invalid"] containsObject:value[@"state"]]) return nil;
    NSUInteger code;
    if (!axs_cachekeeper_installation_detail_number(value[@"errorCode"],7,&code) ||
        (![value[@"state"] isEqual:@"failed"] && code)) return nil;
    NSMutableDictionary *result=[@{@"state":[value[@"state"] copy],@"errorCode":@(code)} mutableCopy];
    if (value[@"detail"]) {
        NSDictionary *detail=axs_cachekeeper_installation_detail_projection(value[@"detail"]);
        if (!detail || ![value[@"state"] isEqual:@"failed"] || !code) return nil;
        result[@"detail"]=detail;
    }
    return [result copy];
}
static inline NSDictionary *axs_cachekeeper_installation_check_result(BOOL requested, NSDictionary *snapshot, NSError *error) {
    if (!requested) return @{@"state":@"notRequested",@"errorCode":@0};
    if (snapshot) {
        NSString *state=[snapshot isKindOfClass:NSDictionary.class] ? snapshot[@"installationState"] : nil;
        BOOL known=[state isKindOfClass:NSString.class] && ([state isEqual:@"verified"] || [state isEqual:@"versionUnknown"]);
        if (error || !known) return @{@"state":@"invalid",@"errorCode":@0};
        return @{@"state":[state copy],@"errorCode":@0};
    }
    NSInteger code=[error.domain isEqual:@"dev.local.cachekeeper.installation"] && error.code>=1 && error.code<=7 ? error.code : 0;
    NSMutableDictionary *result=[@{@"state":@"failed",@"errorCode":@(code)} mutableCopy];
    if (code && error.userInfo[@"detail"]) {
        NSDictionary *detail=axs_cachekeeper_installation_detail_projection(error.userInfo[@"detail"]);
        if (!detail) return @{@"state":@"invalid",@"errorCode":@0};
        result[@"detail"]=detail;
    }
    return [result copy];
}
