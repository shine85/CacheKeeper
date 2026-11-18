#pragma once
#import <Foundation/Foundation.h>
#include <math.h>

static inline BOOL axs_cachekeeper_scope_integer(id value,NSUInteger maximum) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()) return NO;
    double number=[value doubleValue];
    return isfinite(number) && number>=0 && floor(number)==number && number<=(double)maximum;
}

static inline BOOL axs_cachekeeper_scope_keys(id value,NSArray *keys) {
    return [value isKindOfClass:NSDictionary.class] && [value count]==keys.count &&
        [[NSSet setWithArray:[value allKeys]] isEqual:[NSSet setWithArray:keys]];
}
// URL tokens remain registration facts. Scope IDs describe only a successfully sampled root FD.
static inline NSDictionary *axs_cachekeeper_container_scope_projection(id value,NSSet *registeredTokens,NSDictionary *ownersByToken) {
    if (!axs_cachekeeper_scope_keys(value,@[@"schemaVersion",@"state",@"identityBasis",@"scopeLifetime",@"deletionAuthorization",@"accesses",@"scopes"]) ||
        !axs_cachekeeper_scope_integer(value[@"schemaVersion"],1) || [value[@"schemaVersion"] unsignedIntegerValue]!=1 ||
        ![@[@"complete",@"partial"] containsObject:value[@"state"]] || ![value[@"identityBasis"] isEqual:@"rootDeviceInodeAtObservation"] ||
        ![value[@"scopeLifetime"] isEqual:@"thisInventoryOnly"] || ![value[@"deletionAuthorization"] isEqual:@"notGranted"] ||
        ![value[@"accesses"] isKindOfClass:NSArray.class] || ![value[@"scopes"] isKindOfClass:NSArray.class] ||
        [value[@"accesses"] count]!=registeredTokens.count || [value[@"scopes"] count]>4096) return nil;
    NSMutableDictionary *accesses=[NSMutableDictionary new];NSMutableSet *scopeIDs=[NSMutableSet new],*scopedTokens=[NSMutableSet new];BOOL complete=YES;
    for (NSDictionary *row in value[@"accesses"]) {
        if (!axs_cachekeeper_scope_keys(row,@[@"token",@"state",@"scope"]) || ![registeredTokens containsObject:row[@"token"]] || accesses[row[@"token"]] ||
            ![@[@"observed",@"missing",@"unreadable",@"invalidRoot",@"identityChanged",@"notChecked"] containsObject:row[@"state"]] ||
            !axs_cachekeeper_scope_integer(row[@"scope"],[value[@"scopes"] count]) ||
            ([row[@"state"] isEqual:@"observed"]!=([row[@"scope"] unsignedIntegerValue]>0))) return nil;
        accesses[row[@"token"]]=row;if (![row[@"state"] isEqual:@"observed"]) complete=NO;
    }
    NSUInteger index=0;
    for (NSDictionary *scope in value[@"scopes"]) {
        if (!axs_cachekeeper_scope_keys(scope,@[@"index",@"tokens",@"owners"]) || !axs_cachekeeper_scope_integer(scope[@"index"],4096) ||
            [scope[@"index"] unsignedIntegerValue]!=++index || ![scope[@"tokens"] isKindOfClass:NSArray.class] || ![scope[@"tokens"] count] ||
            ![scope[@"owners"] isKindOfClass:NSArray.class]) return nil;
        NSMutableSet *tokens=[NSMutableSet new],*owners=[NSMutableSet new];
        for (id token in scope[@"tokens"]) {
            NSDictionary *access=accesses[token];
            if (!access || [tokens containsObject:token] || [scopedTokens containsObject:token] || [access[@"scope"] unsignedIntegerValue]!=index) return nil;
            [tokens addObject:token];[scopedTokens addObject:token];[owners unionSet:ownersByToken[token] ?: [NSSet set]];
        }
        NSSet *provided=[NSSet setWithArray:scope[@"owners"]];
        if (provided.count!=[scope[@"owners"] count] || ![provided isEqual:owners]) return nil;
        [scopeIDs addObject:@(index)];
    }
    for (NSDictionary *access in accesses.allValues) if ([access[@"state"] isEqual:@"observed"] &&
        (![scopeIDs containsObject:access[@"scope"]] || ![scopedTokens containsObject:access[@"token"]])) return nil;
    if ([value[@"state"] isEqual:@"complete"]!=complete) return nil;
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    return data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:nil] : nil;
}
