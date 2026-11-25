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
 return [@[@"none",@"configurationInvalid",@"appDisabled",@"installationUnverified",@"installationChanged",@"configurationChanged",@"scopeNotAuthorized",@"excludedOverlap",@"scopeUnproven",@"unsupportedHost",@"identityMismatch",@"sourceUnavailable",@"sourceException",@"hostNotReady",@"scopeInvalid",@"rootUnavailable",@"rootIdentityChanged",@"reportWriteFailed",@"noBackgroundTime",@"foreground",@"expired",@"revoked",@"beforeSampleFailed",@"afterSampleFailed",@"hostException",@"historyRejected",@"historyInterrupted",@"notRecorded"] containsObject:reason];
}
static inline NSDictionary *axs_cachekeeper_gurd_scope_unproven_default(void) {
 return @{@"state":@"scopeUnproven",@"hostBundle":@"com.ss.iphone.ugc.Aweme",@"hostVersion":@"41.2.0",@"hostBuild":@"412021",
  @"hostIdentity":@"aweme-core-window-set-v1",@"candidateSource":@"unavailable",@"predicateVersion":@"unavailable",
  @"rootIdentity":@"unavailable",@"candidateCount":@0,@"candidateDigest":@"",@"excludedCount":@0,@"exclusionDigest":@""};
}
static inline NSDictionary *axs_cachekeeper_gurd_scope_proof_projection(id value) {
 NSArray *keys=@[@"state",@"hostBundle",@"hostVersion",@"hostBuild",@"hostIdentity",@"candidateSource",@"predicateVersion",@"rootIdentity",@"candidateCount",@"candidateDigest",@"excludedCount",@"exclusionDigest"];
 if(!axs_cachekeeper_gurd_keys(value,keys) || ![@[@"complete",@"scopeUnproven",@"identityMismatch"] containsObject:value[@"state"]] ||
 ![value[@"hostBundle"] isEqual:@"com.ss.iphone.ugc.Aweme"] || ![value[@"hostVersion"] isEqual:@"41.2.0"] ||
 ![value[@"hostBuild"] isEqual:@"412021"] || ![value[@"hostIdentity"] isEqual:@"aweme-core-window-set-v1"] ||
 ![value[@"candidateSource"] isKindOfClass:NSString.class] || ![value[@"predicateVersion"] isKindOfClass:NSString.class] ||
 ![value[@"rootIdentity"] isKindOfClass:NSString.class] || ![value[@"rootIdentity"] length] ||
 !axs_cachekeeper_gurd_integer(value[@"candidateCount"],9007199254740991ULL) ||
 !axs_cachekeeper_gurd_integer(value[@"excludedCount"],9007199254740991ULL) ||
 ![value[@"candidateDigest"] isKindOfClass:NSString.class] || ![value[@"exclusionDigest"] isKindOfClass:NSString.class]) return nil;
 BOOL complete=[value[@"state"] isEqual:@"complete"];
 if(complete && (![@[@"testFixture",@"productionPredicateV1"] containsObject:value[@"candidateSource"]] || ![value[@"predicateVersion"] length] ||
   ![value[@"candidateDigest"] isEqual:[value[@"candidateDigest"] lowercaseString]] || [value[@"candidateDigest"] length]!=64 ||
   ![value[@"exclusionDigest"] isEqual:[value[@"exclusionDigest"] lowercaseString]] || [value[@"exclusionDigest"] length]!=64)) return nil;
 if(!complete && ([value[@"candidateCount"] unsignedLongLongValue] || [value[@"excludedCount"] unsignedLongLongValue] ||
   [value[@"candidateDigest"] length] || [value[@"exclusionDigest"] length])) return nil;
 return [value copy];
}
static inline NSDictionary *axs_cachekeeper_gurd_sample_projection(id value) {
 if(!axs_cachekeeper_gurd_keys(value,@[@"state",@"files",@"logicalBytes",@"allocatedBytes",@"entries",@"errorCode"]) ||
 ![@[@"complete",@"partial",@"cancelled",@"readError",@"identityChanged",@"entryLimit",@"depthLimit",@"timeLimit",@"inodeLimit",@"invalidMetadata",@"linkEncountered",@"closeError",@"notRecorded"] containsObject:value[@"state"]]) return nil;
 for(NSString *key in @[@"files",@"logicalBytes",@"allocatedBytes",@"entries"]) if(!axs_cachekeeper_gurd_integer(value[key],9007199254740991ULL)) return nil;
 if(!axs_cachekeeper_gurd_integer(value[@"errorCode"],255) || [value[@"files"] unsignedLongLongValue]>[value[@"entries"] unsignedLongLongValue]) return nil;
 if([value[@"state"] isEqual:@"complete"] && [value[@"errorCode"] unsignedIntegerValue]) return nil;
 if([value[@"state"] isEqual:@"notRecorded"])
  for(NSString *key in @[@"files",@"logicalBytes",@"allocatedBytes",@"entries",@"errorCode"]) if([value[key] unsignedLongLongValue]) return nil;
 return [value copy];
}
static inline NSArray *axs_cachekeeper_gurd_operation_keys(BOOL withScope) {
 NSArray *keys=@[@"event",@"runtimeInfo",@"configuration",@"phase",@"reason",@"submission",@"hostCompletion",@"observation",@"before",@"after",@"logicalDecrease",@"allocatedDecrease",@"physicalUniqueReclaimed"];
 return withScope ? [keys arrayByAddingObject:@"scopeProof"] : keys;
}
static inline BOOL axs_cachekeeper_gurd_legacy_runtime(id runtime) {
 NSDictionary *valid=axs_cachekeeper_runtime_info_projection(runtime);
 return valid && [@[@"0.7.2-201.1",@"0.7.2-202.1"] containsObject:valid[@"packageVersion"]];
}
static inline BOOL axs_cachekeeper_gurd_legacy_scope(id value) {
 return axs_cachekeeper_gurd_keys(value,@[@"state",@"source"]) && [value[@"state"] isEqual:@"notRecorded"] &&
  [value[@"source"] isEqual:@"legacyReceiptV1"];
}
// Legacy provenance is accepted only as historical evidence, never as a host binding proof.
static inline NSString *axs_cachekeeper_gurd_operation_failure(id value,NSString **stage) {
 *stage=@"operation";
 if(!axs_cachekeeper_gurd_keys(value,axs_cachekeeper_gurd_operation_keys(YES))) return @"fields";
 if(!axs_cachekeeper_runtime_info_projection(value[@"runtimeInfo"])) return @"runtimeInfo";
 if(!axs_cachekeeper_gurd_integer(value[@"event"],9007199254740991ULL) || !axs_cachekeeper_gurd_integer(value[@"configuration"],9007199254740991ULL) ||
 ![@[@"preparing",@"samplingBefore",@"submitted",@"observed",@"skipped",@"cancelled",@"interruptedAfterSubmission",@"legacyUnknown"] containsObject:value[@"phase"]] ||
 !axs_cachekeeper_gurd_reason(value[@"reason"]) || ![@[@"notSubmitted",@"submitted",@"enteredUnknown",@"notRecorded"] containsObject:value[@"submission"]] ||
 ![@[@"notProvided",@"notRecorded"] containsObject:value[@"hostCompletion"]] ||
 ![@[@"pending",@"reduced",@"unchanged",@"increased",@"partial",@"notObserved",@"notRecorded"] containsObject:value[@"observation"]] ||
 ![value[@"physicalUniqueReclaimed"] isEqual:@"notMeasured"] || !axs_cachekeeper_gurd_integer(value[@"logicalDecrease"],9007199254740991ULL) ||
 !axs_cachekeeper_gurd_integer(value[@"allocatedDecrease"],9007199254740991ULL)) return @"values";
 BOOL legacy=axs_cachekeeper_gurd_legacy_scope(value[@"scopeProof"]);
 *stage=@"scopeProof";
 if(legacy ? !axs_cachekeeper_gurd_legacy_runtime(value[@"runtimeInfo"]) : !axs_cachekeeper_gurd_scope_proof_projection(value[@"scopeProof"]))
  return legacy ? @"legacyRuntime" : @"proof";
 *stage=@"operation";
 if(legacy && [value[@"reason"] isEqual:@"scopeUnproven"]) return @"legacyReason";
 for(NSString *key in @[@"before",@"after"]) {
  *stage=key;
  if(!axs_cachekeeper_gurd_sample_projection(value[key])) return @"sample";
  if(legacy && [@[@"partial",@"closeError"] containsObject:value[key][@"state"]]) return @"legacySampleState";
 }
 *stage=@"operation";
 NSString *phase=value[@"phase"],*submission=value[@"submission"],*observation=value[@"observation"];
 if([phase isEqual:@"legacyUnknown"]) {
  if(![submission isEqual:@"notRecorded"] || ![value[@"hostCompletion"] isEqual:@"notRecorded"] || ![observation isEqual:@"notRecorded"] || (!legacy && ![value[@"scopeProof"][@"state"] isEqual:@"scopeUnproven"]) ||
  ![value[@"before"][@"state"] isEqual:@"notRecorded"] || ![value[@"after"][@"state"] isEqual:@"notRecorded"]) return @"semantics";
 } else {
  if(![value[@"hostCompletion"] isEqual:@"notProvided"] || [submission isEqual:@"notRecorded"] || [observation isEqual:@"notRecorded"]) return @"semantics";
  if([@[@"preparing",@"samplingBefore",@"skipped",@"cancelled"] containsObject:phase] && (![submission isEqual:@"notSubmitted"] || ![observation isEqual:@"notObserved"])) return @"semantics";
  if([phase isEqual:@"submitted"] && (![submission isEqual:@"submitted"] || ![observation isEqual:@"pending"] || ![value[@"before"][@"state"] isEqual:@"complete"] || ![value[@"after"][@"state"] isEqual:@"notRecorded"])) return @"semantics";
  if([phase isEqual:@"observed"] && (![submission isEqual:@"submitted"] || ![@[@"reduced",@"unchanged",@"increased"] containsObject:observation] || ![value[@"reason"] isEqual:@"none"])) return @"semantics";
  if([phase isEqual:@"interruptedAfterSubmission"] && (![@[@"submitted",@"enteredUnknown"] containsObject:submission] || ![observation isEqual:@"partial"])) return @"semantics";
 }
BOOL submitted=[value[@"submission"] isEqual:@"submitted"];
 BOOL measured=[@[@"reduced",@"unchanged",@"increased"] containsObject:value[@"observation"]];
 if(measured && (!submitted || (!legacy && ![value[@"scopeProof"][@"state"] isEqual:@"complete"]) || ![value[@"before"][@"state"] isEqual:@"complete"] || ![value[@"after"][@"state"] isEqual:@"complete"])) return @"measurement";
 if(!measured && ([value[@"logicalDecrease"] unsignedLongLongValue] || [value[@"allocatedDecrease"] unsignedLongLongValue])) return @"measurement";
 if(measured) {
  uint64_t before=[value[@"before"][@"logicalBytes"] unsignedLongLongValue],after=[value[@"after"][@"logicalBytes"] unsignedLongLongValue];
  uint64_t ba=[value[@"before"][@"allocatedBytes"] unsignedLongLongValue],aa=[value[@"after"][@"allocatedBytes"] unsignedLongLongValue];
  NSString *observation=(after<before || aa<ba) ? @"reduced" : (after>before || aa>ba) ? @"increased" : @"unchanged";
  if(![value[@"observation"] isEqual:observation] || [value[@"logicalDecrease"] unsignedLongLongValue]!=(before>after ? before-after : 0) ||
  [value[@"allocatedDecrease"] unsignedLongLongValue]!=(ba>aa ? ba-aa : 0)) return @"measurement";
 }
 return nil;
}
static inline NSDictionary *axs_cachekeeper_gurd_operation_projection(id value) {
 NSString *stage=nil;return axs_cachekeeper_gurd_operation_failure(value,&stage) ? nil : [value copy];
}
static inline NSDictionary *axs_cachekeeper_gurd_rejected(NSString *stage,NSString *code,NSNumber *index,id schema,id runtime) {
 NSMutableDictionary *failure=[@{@"stage":stage,@"code":code} mutableCopy];
 if(index) failure[@"operationIndex"]=index;
 if(axs_cachekeeper_gurd_integer(schema,9007199254740991ULL)) failure[@"sourceSchemaVersion"]=schema;
 NSDictionary *validRuntime=axs_cachekeeper_runtime_info_projection(runtime);if(validRuntime) failure[@"runtimeInfo"]=validRuntime;
 return @{@"state":@"invalid",@"rejection":[failure copy]};
}
// A single reader accepts known historical schemas and returns canonical schema 2.
static inline NSDictionary *axs_cachekeeper_gurd_receipt_decode(id value) {
 if(![value isKindOfClass:NSDictionary.class]) return axs_cachekeeper_gurd_rejected(@"receipt",@"type",nil,nil,nil);
 id schema=value[@"schemaVersion"],runtime=value[@"runtimeInfo"];
 if(!axs_cachekeeper_gurd_keys(value,@[@"schemaVersion",@"updated",@"runtimeInfo",@"family",@"contract",@"state",@"reason",@"restriction",@"background",@"operations"]))
  return axs_cachekeeper_gurd_rejected(@"receipt",@"fields",nil,schema,runtime);
 if(!axs_cachekeeper_gurd_integer(schema,2) || [schema unsignedIntegerValue]<1)
  return axs_cachekeeper_gurd_rejected(@"receipt",@"schemaVersion",nil,schema,runtime);
 if(!axs_cachekeeper_runtime_info_projection(runtime)) return axs_cachekeeper_gurd_rejected(@"receipt",@"runtimeInfo",nil,schema,nil);
 if(![value[@"updated"] isKindOfClass:NSDate.class] || !isfinite([value[@"updated"] timeIntervalSince1970]) || [value[@"updated"] timeIntervalSince1970]<=0 ||
 ![value[@"family"] isEqual:@"gurd"] || ![value[@"contract"] isEqual:@"aweme412021WhitelistV1"] ||
 ![@[@"idle",@"running",@"disabled",@"blocked",@"submitted",@"observed",@"interrupted"] containsObject:value[@"state"]] ||
 !axs_cachekeeper_gurd_reason(value[@"reason"]) || ![value[@"restriction"] isEqual:@"unsupported"] ||
 !axs_cachekeeper_gurd_bool(value[@"background"]) || ![value[@"operations"] isKindOfClass:NSArray.class] || [value[@"operations"] count]>16)
  return axs_cachekeeper_gurd_rejected(@"receipt",@"values",nil,schema,runtime);
 NSMutableArray *operations=[NSMutableArray new];uint64_t previous=0;NSUInteger index=0;
 for(id source in value[@"operations"]) {
  id operation=source;id operationRuntime=[source isKindOfClass:NSDictionary.class] ? source[@"runtimeInfo"] : nil;
  if(axs_cachekeeper_gurd_keys(source,axs_cachekeeper_gurd_operation_keys(NO))) {
   if([schema unsignedIntegerValue]!=1) return axs_cachekeeper_gurd_rejected(@"operation",@"missingScopeProof",@(index),schema,operationRuntime);
   if(!axs_cachekeeper_runtime_info_projection(operationRuntime)) return axs_cachekeeper_gurd_rejected(@"operation",@"runtimeInfo",@(index),schema,nil);
   if(!axs_cachekeeper_gurd_legacy_runtime(operationRuntime)) return axs_cachekeeper_gurd_rejected(@"operation",@"legacyRuntime",@(index),schema,operationRuntime);
   NSMutableDictionary *migrated=[source mutableCopy];migrated[@"scopeProof"]=@{@"state":@"notRecorded",@"source":@"legacyReceiptV1"};operation=migrated;
  }
  NSString *stage=nil,*code=axs_cachekeeper_gurd_operation_failure(operation,&stage);
  if(code) return axs_cachekeeper_gurd_rejected(stage,code,@(index),schema,operationRuntime);
  uint64_t event=[operation[@"event"] unsignedLongLongValue];
  if(event<=previous) return axs_cachekeeper_gurd_rejected(@"operation",@"eventOrder",@(index),schema,operationRuntime);
  previous=event;[operations addObject:[operation copy]];index++;
 }
 NSMutableDictionary *canonical=[value mutableCopy];canonical[@"schemaVersion"]=@2;canonical[@"operations"]=[operations copy];
 return @{@"state":@"available",@"data":[canonical copy]};
}
static inline NSDictionary *axs_cachekeeper_gurd_receipt_projection(id value) {
 return axs_cachekeeper_gurd_receipt_decode(value)[@"data"];
}
// Consumers call this only with canonical data from the decoder above.
static inline NSString *axs_cachekeeper_gurd_scope_verification(NSDictionary *canonicalReceipt) {
 for(NSDictionary *operation in canonicalReceipt[@"operations"])
  if(axs_cachekeeper_gurd_legacy_scope(operation[@"scopeProof"])) return @"legacyScopeNotRecorded";
 return @"scopeObservationOnly";
}
