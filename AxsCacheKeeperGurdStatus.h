#pragma once
#import <Foundation/Foundation.h>
#include <math.h>
#import "AxsCacheKeeperRuntimeInfo.h"
// Closed technical codes only; public snapshots never contain resource names or paths.
static inline BOOL axs_cachekeeper_gurd_keys(id value,NSArray *keys) {
 return [value isKindOfClass:NSDictionary.class] && [value count]==keys.count &&
 [[NSSet setWithArray:[value allKeys]] isEqual:[NSSet setWithArray:keys]];
}
static inline BOOL axs_cachekeeper_gurd_integer(id value,uint64_t maximum) {
 if(![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()) return NO;
 double number=[value doubleValue];return isfinite(number) && number>=0 && floor(number)==number && number<=maximum;
}
static inline BOOL axs_cachekeeper_gurd_bool(id value) {
 return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID();
}
static inline BOOL axs_cachekeeper_gurd_reason(id reason) {
 return [@[@"none",@"configurationInvalid",@"appDisabled",@"installationUnverified",@"installationChanged",@"configurationChanged",@"scopeNotAuthorized",@"excludedOverlap",@"unsupportedHost",@"identityMismatch",@"sourceUnavailable",@"sourceException",@"hostNotReady",@"scopeInvalid",@"rootUnavailable",@"rootIdentityChanged",@"reportWriteFailed",@"noBackgroundTime",@"foreground",@"expired",@"revoked",@"beforeSampleFailed",@"afterSampleFailed",@"hostException",@"historyRejected",@"historyInterrupted",@"notRecorded"] containsObject:reason];
}
static inline NSDictionary *axs_cachekeeper_gurd_sample_projection(id value) {
 if(!axs_cachekeeper_gurd_keys(value,@[@"state",@"files",@"logicalBytes",@"allocatedBytes",@"entries",@"errorCode"]) ||
 ![@[@"complete",@"cancelled",@"readError",@"identityChanged",@"entryLimit",@"depthLimit",@"timeLimit",@"inodeLimit",@"invalidMetadata",@"linkEncountered",@"notRecorded"] containsObject:value[@"state"]]) return nil;
 for(NSString *key in @[@"files",@"logicalBytes",@"allocatedBytes",@"entries"]) if(!axs_cachekeeper_gurd_integer(value[key],9007199254740991ULL)) return nil;
 if(!axs_cachekeeper_gurd_integer(value[@"errorCode"],255) || [value[@"files"] unsignedLongLongValue]>[value[@"entries"] unsignedLongLongValue]) return nil;
 if([value[@"state"] isEqual:@"complete"] && [value[@"errorCode"] unsignedIntegerValue]) return nil;
 if([value[@"state"] isEqual:@"notRecorded"])
  for(NSString *key in @[@"files",@"logicalBytes",@"allocatedBytes",@"entries",@"errorCode"]) if([value[key] unsignedLongLongValue]) return nil;
 return [value copy];
}
static inline NSDictionary *axs_cachekeeper_gurd_operation_projection(id value) {
 NSArray *keys=@[@"event",@"runtimeInfo",@"configuration",@"phase",@"reason",@"submission",@"hostCompletion",@"observation",@"before",@"after",@"logicalDecrease",@"allocatedDecrease",@"physicalUniqueReclaimed"];
 if(!axs_cachekeeper_gurd_keys(value,keys) || !axs_cachekeeper_gurd_integer(value[@"event"],9007199254740991ULL) ||
 !axs_cachekeeper_runtime_info_projection(value[@"runtimeInfo"]) || !axs_cachekeeper_gurd_integer(value[@"configuration"],9007199254740991ULL) ||
 ![@[@"preparing",@"samplingBefore",@"submitted",@"observed",@"skipped",@"cancelled",@"interruptedAfterSubmission",@"legacyUnknown"] containsObject:value[@"phase"]] ||
 !axs_cachekeeper_gurd_reason(value[@"reason"]) || ![@[@"notSubmitted",@"submitted",@"enteredUnknown",@"notRecorded"] containsObject:value[@"submission"]] ||
 ![@[@"notProvided",@"notRecorded"] containsObject:value[@"hostCompletion"]] ||
 ![@[@"pending",@"reduced",@"unchanged",@"increased",@"partial",@"notObserved",@"notRecorded"] containsObject:value[@"observation"]] ||
 ![value[@"physicalUniqueReclaimed"] isEqual:@"notMeasured"] || !axs_cachekeeper_gurd_sample_projection(value[@"before"]) ||
 !axs_cachekeeper_gurd_sample_projection(value[@"after"]) || !axs_cachekeeper_gurd_integer(value[@"logicalDecrease"],9007199254740991ULL) ||
 !axs_cachekeeper_gurd_integer(value[@"allocatedDecrease"],9007199254740991ULL)) return nil;
 NSString *phase=value[@"phase"],*submission=value[@"submission"],*observation=value[@"observation"];
 if([phase isEqual:@"legacyUnknown"]) {
  if(![submission isEqual:@"notRecorded"] || ![value[@"hostCompletion"] isEqual:@"notRecorded"] || ![observation isEqual:@"notRecorded"] ||
  ![value[@"before"][@"state"] isEqual:@"notRecorded"] || ![value[@"after"][@"state"] isEqual:@"notRecorded"]) return nil;
 } else {
  if(![value[@"hostCompletion"] isEqual:@"notProvided"] || [submission isEqual:@"notRecorded"] || [observation isEqual:@"notRecorded"]) return nil;
  if([@[@"preparing",@"samplingBefore",@"skipped",@"cancelled"] containsObject:phase] && (![submission isEqual:@"notSubmitted"] || ![observation isEqual:@"notObserved"])) return nil;
  if([phase isEqual:@"submitted"] && (![submission isEqual:@"submitted"] || ![observation isEqual:@"pending"] || ![value[@"before"][@"state"] isEqual:@"complete"] || ![value[@"after"][@"state"] isEqual:@"notRecorded"])) return nil;
  if([phase isEqual:@"observed"] && (![submission isEqual:@"submitted"] || ![@[@"reduced",@"unchanged",@"increased"] containsObject:observation] || ![value[@"reason"] isEqual:@"none"])) return nil;
  if([phase isEqual:@"interruptedAfterSubmission"] && (![@[@"submitted",@"enteredUnknown"] containsObject:submission] || ![observation isEqual:@"partial"])) return nil;
 }
BOOL submitted=[value[@"submission"] isEqual:@"submitted"];
 BOOL measured=[@[@"reduced",@"unchanged",@"increased"] containsObject:value[@"observation"]];
 if(measured && (!submitted || ![value[@"before"][@"state"] isEqual:@"complete"] || ![value[@"after"][@"state"] isEqual:@"complete"])) return nil;
 if(!measured && ([value[@"logicalDecrease"] unsignedLongLongValue] || [value[@"allocatedDecrease"] unsignedLongLongValue])) return nil;
 if(measured) {
  uint64_t before=[value[@"before"][@"logicalBytes"] unsignedLongLongValue],after=[value[@"after"][@"logicalBytes"] unsignedLongLongValue];
  uint64_t ba=[value[@"before"][@"allocatedBytes"] unsignedLongLongValue],aa=[value[@"after"][@"allocatedBytes"] unsignedLongLongValue];
  NSString *observation=(after<before || aa<ba) ? @"reduced" : (after>before || aa>ba) ? @"increased" : @"unchanged";
  if(![value[@"observation"] isEqual:observation] || [value[@"logicalDecrease"] unsignedLongLongValue]!=(before>after ? before-after : 0) ||
  [value[@"allocatedDecrease"] unsignedLongLongValue]!=(ba>aa ? ba-aa : 0)) return nil;
 }
 return [value copy];
}
static inline NSDictionary *axs_cachekeeper_gurd_receipt_projection(id value) {
 if(!axs_cachekeeper_gurd_keys(value,@[@"schemaVersion",@"updated",@"runtimeInfo",@"family",@"contract",@"state",@"reason",@"restriction",@"background",@"operations"]) ||
 !axs_cachekeeper_gurd_integer(value[@"schemaVersion"],1) || [value[@"schemaVersion"] unsignedIntegerValue]!=1 ||
 ![value[@"updated"] isKindOfClass:NSDate.class] || !isfinite([value[@"updated"] timeIntervalSince1970]) || [value[@"updated"] timeIntervalSince1970]<=0 || !axs_cachekeeper_runtime_info_projection(value[@"runtimeInfo"]) ||
 ![value[@"family"] isEqual:@"gurd"] || ![value[@"contract"] isEqual:@"aweme412021WhitelistV1"] ||
 ![@[@"idle",@"running",@"disabled",@"blocked",@"submitted",@"observed",@"interrupted"] containsObject:value[@"state"]] ||
 !axs_cachekeeper_gurd_reason(value[@"reason"]) || ![value[@"restriction"] isEqual:@"unsupported"] ||
 !axs_cachekeeper_gurd_bool(value[@"background"]) || ![value[@"operations"] isKindOfClass:NSArray.class] || [value[@"operations"] count]>16) return nil;
 NSUInteger previous=0;for(id operation in value[@"operations"]) {if(!axs_cachekeeper_gurd_operation_projection(operation) || [operation[@"event"] unsignedIntegerValue]<=previous) return nil;previous=[operation[@"event"] unsignedIntegerValue];}
 return [value copy];
}
