#pragma once
#import <Foundation/Foundation.h>
#import "AxsCacheKeeperPolicy.h"
#import "AxsCacheKeeperCapacityStatus.h"
#import "AxsCacheKeeperImageWriteObservation.h"
#include <CommonCrypto/CommonDigest.h>

static NSString *const AxsCacheKeeperImageCollectionChanged=@"dev.local.cachekeeper.image.collection";
static NSString *const AxsCacheKeeperImageCollectionBundle=@"com.baidu.netdisk";
static const NSTimeInterval AxsCacheKeeperImageCollectionLease=300;

static inline BOOL axs_cachekeeper_image_collection_id(id value) {
    return [value isKindOfClass:NSString.class] && [value length]==32 &&
        [value rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet].location==NSNotFound;
}
static inline NSString *axs_cachekeeper_image_collection_sha(NSData *data) {
    if (!data || data.length>UINT32_MAX) return nil;unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes,(CC_LONG)data.length,digest);NSMutableString *out=[NSMutableString new];
    for (NSUInteger i=0;i<sizeof(digest);i++) [out appendFormat:@"%02x",digest[i]];return out;
}
static inline NSString *axs_cachekeeper_image_collection_baseline(NSDictionary *context) {
    if (!axs_cachekeeper_state_valid(context[@"appState"]) || ![context[@"selected"] isKindOfClass:NSArray.class]) return nil;
    NSDictionary *value=@{@"bundle":context[@"bundle"] ?: @"",@"state":context[@"appState"],@"selected":context[@"selected"]};
    if (![NSJSONSerialization isValidJSONObject:value]) return nil;
    return axs_cachekeeper_image_collection_sha([NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:NULL]);
}
static inline BOOL axs_cachekeeper_image_collection_request(id value) {
    NSArray *keys=@[@"schemaVersion",@"sessionID",@"requestID",@"bundle",@"phase",@"step",@"issuedAt",@"expiresAt",@"baselineSHA256",@"processFirstObserved"];
    if (![value isKindOfClass:NSDictionary.class] || [value count]!=10 || ![value[@"schemaVersion"] isEqual:@1] ||
        ![[NSSet setWithArray:[value allKeys]] isEqual:[NSSet setWithArray:keys]] ||
        !axs_cachekeeper_image_collection_id(value[@"sessionID"]) || !axs_cachekeeper_image_collection_id(value[@"requestID"]) ||
        !axs_cachekeeper_bundle_id(value[@"bundle"]) ||
        ![@[@"prevent",@"clean",@"disabled",@"restore"] containsObject:value[@"phase"]] ||
        ![value[@"baselineSHA256"] isKindOfClass:NSString.class] || [value[@"baselineSHA256"] length]!=64) return NO;
    for (NSString *key in @[@"step",@"issuedAt",@"expiresAt",@"processFirstObserved"])
        if (![value[key] isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value[key])==CFBooleanGetTypeID() ||
            !isfinite([value[key] doubleValue]) || [value[key] doubleValue]<1) return NO;
    NSUInteger phase=[@[@"prevent",@"clean",@"disabled",@"restore"] indexOfObject:value[@"phase"]];
    return [value[@"step"] doubleValue]==phase+1 &&
        [value[@"baselineSHA256"] rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet].location==NSNotFound &&
        [value[@"expiresAt"] doubleValue]>[value[@"issuedAt"] doubleValue] &&
        [value[@"expiresAt"] doubleValue]-[value[@"issuedAt"] doubleValue]<=AxsCacheKeeperImageCollectionLease;
}
static inline NSDictionary *axs_cachekeeper_image_collection_read(NSString *folder,NSError **error) {
    NSError *failure=nil;
    id value=axs_cachekeeper_capacity_read_plist(folder,@"imageCollectionRequest.plist",4096,&failure);
    if (!value && failure.code==ENOENT) failure=nil;
    if (value && !axs_cachekeeper_image_collection_request(value)) {failure=[NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];value=nil;}
    if (error) *error=failure;return value;
}
// Only the image provider calls this; base configuration and all scope/identity fields remain authoritative.
static inline NSDictionary *axs_cachekeeper_image_collection_context(NSDictionary *base,NSDictionary *request,NSTimeInterval now) {
    if (!axs_cachekeeper_image_collection_request(request) || ![base[@"bundle"] isEqual:request[@"bundle"]]) return base;
    NSString *state=@"applied";
    if (![base[@"valid"] boolValue]) state=@"unavailable";
    else if ([request[@"phase"] isEqual:@"restore"]) state=@"restored";
    else if (![base[@"processFirstObserved"] isEqual:request[@"processFirstObserved"]]) state=@"unavailable";
    else if (now<[request[@"issuedAt"] doubleValue] || now>=[request[@"expiresAt"] doubleValue]) state=@"expired";
    else if (![axs_cachekeeper_image_collection_baseline(base) isEqual:request[@"baselineSHA256"]]) state=@"configurationChanged";
    else if (!axs_cachekeeper_app_enabled(base[@"appState"]) || ![base[@"installation"] length]) state=@"unavailable";
    NSMutableDictionary *context=[base mutableCopy];
    if ([state isEqual:@"applied"]) {
        NSMutableDictionary *effective=axs_cachekeeper_app_state(base[@"appState"],![request[@"phase"] isEqual:@"disabled"]);
        if (![request[@"phase"] isEqual:@"disabled"]) effective[@"mode"]=request[@"phase"];
        context[@"appState"]=effective;
    }
    context[@"imageCollection"]=@{@"sessionID":request[@"sessionID"],@"requestID":request[@"requestID"],@"phase":request[@"phase"],
        @"step":request[@"step"],@"expiresAt":request[@"expiresAt"],@"disposition":state,@"configuration":@0,@"installation":@0,@"epochs":@[],@"baselines":@{},@"events":@[]};
    return context;
}
NSDictionary *axs_cachekeeper_image_collection_cleanup(NSDictionary *receipt,NSDictionary *request);

@interface AxsCacheKeeperImageCollectionSession : NSObject
- (instancetype)initWithFolder:(NSString *)folder sessionID:(NSString *)sessionID error:(NSError **)error;
- (BOOL)start:(NSError **)error;
- (BOOL)startWithBundle:(NSString *)bundle error:(NSError **)error;
- (BOOL)recordEntry:(NSError **)error;
- (BOOL)skip:(NSError **)error;
- (BOOL)readyForReport;
- (BOOL)prepareBundle:(NSString *)bundle error:(NSError **)error;
- (NSDictionary *)refreshPreparation:(NSError **)error;
- (NSArray<NSDictionary *> *)availableModules:(NSError **)error;
- (BOOL)captureAndAdvance:(NSError **)error;
- (BOOL)cancel:(NSError **)error;
- (BOOL)retryPublishing:(NSError **)error;
- (NSDictionary *)poll:(NSError **)error;
- (NSDictionary *)reportProjection;
@end
