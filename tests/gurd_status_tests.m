#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#ifndef AXS_CACHEKEEPER_GURD_STATUS_HEADER
#define AXS_CACHEKEEPER_GURD_STATUS_HEADER "AxsCacheKeeperGurdStatus.h"
#endif
#import AXS_CACHEKEEPER_GURD_STATUS_HEADER

static void require(BOOL condition,NSString *message) {
    if (!condition) {fprintf(stderr,"FAIL: gurd-status: %s\n",message.UTF8String);exit(1);}
}
static NSDictionary *runtime(NSString *version) {
    return @{@"schemaVersion":@1,@"packageVersion":version,@"firstObserved":@1795498764.568249};
}
static NSDictionary *sample(NSString *state,NSUInteger files,NSUInteger logical,NSUInteger allocated,NSUInteger entries,NSUInteger error) {
    return @{@"state":state,@"files":@(files),@"logicalBytes":@(logical),@"allocatedBytes":@(allocated),@"entries":@(entries),@"errorCode":@(error)};
}
static NSDictionary *emptySample(void) {return sample(@"notRecorded",0,0,0,0,0);}
// Normalized from the saved 202.1 device description, not a raw plist replay.
static NSMutableDictionary *historicalOperation(NSUInteger event,NSDictionary *before,NSString *reason) {
    return [@{@"event":@(event),@"runtimeInfo":runtime(@"0.7.2-202.1"),@"configuration":@1,
        @"phase":@"skipped",@"reason":reason,@"submission":@"notSubmitted",@"hostCompletion":@"notProvided",
        @"observation":@"notObserved",@"before":before,@"after":emptySample(),@"logicalDecrease":@0,
        @"allocatedDecrease":@0,@"physicalUniqueReclaimed":@"notMeasured"} mutableCopy];
}
static NSMutableDictionary *receipt(NSArray *operations) {
    return [@{@"schemaVersion":@1,@"updated":[NSDate dateWithTimeIntervalSince1970:1795504834],
        @"runtimeInfo":runtime(@"0.7.2-202.1"),@"family":@"gurd",@"contract":@"aweme412021WhitelistV1",
        @"state":@"blocked",@"reason":@"beforeSampleFailed",@"restriction":@"unsupported",@"background":@YES,
        @"operations":operations} mutableCopy];
}
static NSMutableDictionary *historicalReceipt(void) {
    NSMutableDictionary *a=historicalOperation(1,sample(@"identityChanged",0,0,0,1,70),@"beforeSampleFailed");
    NSMutableDictionary *b=historicalOperation(2,sample(@"timeLimit",3548,272287950,281485312,5066,0),@"beforeSampleFailed");b[@"configuration"]=@2;
    NSMutableDictionary *c=historicalOperation(3,sample(@"timeLimit",4426,291641850,303509504,6016,0),@"beforeSampleFailed");c[@"configuration"]=@3;
    NSMutableDictionary *d=historicalOperation(4,emptySample(),@"appDisabled");
    NSMutableDictionary *e=historicalOperation(5,sample(@"timeLimit",982,73503908,75927552,1449,0),@"beforeSampleFailed");e[@"configuration"]=@2;
    NSDictionary *later=@{@"schemaVersion":@1,@"packageVersion":@"0.7.2-202.1",@"firstObserved":@1795503054.096321};
    d[@"runtimeInfo"]=later;e[@"runtimeInfo"]=later;
    NSMutableDictionary *value=receipt(@[a,b,c,d,e]);value[@"runtimeInfo"]=later;return value;
}
static NSDictionary *migration(void) {
    NSDictionary *original=historicalReceipt();NSDictionary *projected=axs_cachekeeper_gurd_receipt_projection(original);
    require(projected && [projected[@"schemaVersion"] isEqual:@2] && [projected[@"operations"] count]==5 &&
        [projected[@"operations"][0][@"scopeProof"] isEqual:@{@"state":@"notRecorded",@"source":@"legacyReceiptV1"}],
        @"schema1 historical records migrate without losing scope provenance");
    for(NSUInteger i=0;i<5;i++) {
        NSMutableDictionary *operation=[projected[@"operations"][i] mutableCopy];[operation removeObjectForKey:@"scopeProof"];
        require([operation isEqual:original[@"operations"][i]],@"migration retains every recorded historical field");
    }
    require(!original[@"operations"][0][@"scopeProof"] && [original[@"schemaVersion"] isEqual:@1],@"migration does not mutate its input");
    require([projected[@"runtimeInfo"] isEqual:original[@"runtimeInfo"]] && [projected[@"updated"] isEqual:original[@"updated"]],@"migration retains producer and timestamp");
    return projected;
}
#if !defined(AXS_CACHEKEEPER_GURD_MIGRATION_RED)
static NSDictionary *completeProof(void) {
    NSMutableDictionary *proof=[axs_cachekeeper_gurd_scope_unproven_default() mutableCopy];
    proof[@"state"]=@"complete";proof[@"candidateSource"]=@"testFixture";proof[@"predicateVersion"]=@"fixture-v1";
    proof[@"rootIdentity"]=@"fixture-root";proof[@"candidateCount"]=@1;
    proof[@"candidateDigest"]=[@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0];
    proof[@"exclusionDigest"]=[@"b" stringByPaddingToLength:64 withString:@"b" startingAtIndex:0];return proof;
}
static NSMutableDictionary *observedOperation(void) {
    NSMutableDictionary *value=historicalOperation(1,sample(@"complete",2,100,8192,3,0),@"none");
    value[@"phase"]=@"observed";value[@"submission"]=@"submitted";value[@"observation"]=@"reduced";
    value[@"after"]=sample(@"complete",1,40,4096,2,0);value[@"logicalDecrease"]=@60;value[@"allocatedDecrease"]=@4096;return value;
}
static NSDictionary *rejected(id value,NSString *stage,NSString *code,NSNumber *index) {
    NSDictionary *result=axs_cachekeeper_gurd_receipt_decode(value),*failure=result[@"rejection"];
    require([result[@"state"] isEqual:@"invalid"] && !result[@"data"] && failure,@"rejected receipt has no canonical data");
    require([failure[@"stage"] isEqual:stage] && [failure[@"code"] isEqual:code],@"rejection names its exact closed stage and code");
    require(index ? [failure[@"operationIndex"] isEqual:index] : !failure[@"operationIndex"],@"rejection operation index matches the failed source entry");
    NSSet *allowed=[NSSet setWithArray:@[@"stage",@"code",@"operationIndex",@"sourceSchemaVersion",@"runtimeInfo"]];
    require([[NSSet setWithArray:failure.allKeys] isSubsetOfSet:allowed],@"rejection has only closed technical fields");
    NSData *json=[NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    require(json && ![[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] containsString:@"PRIVATE-CANARY"],@"rejection never exports input canaries");
    require(!axs_cachekeeper_gurd_receipt_projection(value),@"compatibility projection shares the same rejection");return failure;
}
static void allCases(NSString *folder) {
    NSDictionary *canonical=migration();
    require([axs_cachekeeper_gurd_receipt_projection(canonical) isEqual:canonical],@"canonical schema2 projection is idempotent");
    require([axs_cachekeeper_gurd_scope_verification(canonical) isEqual:@"legacyScopeNotRecorded"],@"historical scope is explicitly unrecorded");
    require(!axs_cachekeeper_gurd_scope_proof_projection(canonical[@"operations"][0][@"scopeProof"]),@"legacy marker is not a production scope proof");
    NSMutableDictionary *observed=observedOperation(),*source=receipt(@[observed]);
    NSDictionary *projected=axs_cachekeeper_gurd_receipt_projection(source),*operation=projected[@"operations"][0];
    require(projected && [operation[@"phase"] isEqual:@"observed"] && [operation[@"logicalDecrease"] isEqual:@60] &&
        [operation[@"before"] isEqual:observed[@"before"]] && [operation[@"after"] isEqual:observed[@"after"]],@"legacy observation retains actual numerical history without a proof claim");
    require([axs_cachekeeper_gurd_scope_verification(projected) isEqual:@"legacyScopeNotRecorded"],@"legacy measured bytes do not imply proven scope");
    for(NSString *phase in @[@"preparing",@"samplingBefore",@"submitted",@"interruptedAfterSubmission",@"legacyUnknown"]) {
        NSMutableDictionary *pending=historicalOperation(1,emptySample(),@"none");pending[@"phase"]=phase;
        if([phase isEqual:@"submitted"]) {pending[@"submission"]=@"submitted";pending[@"observation"]=@"pending";pending[@"before"]=sample(@"complete",1,10,4096,2,0);}
        if([phase isEqual:@"interruptedAfterSubmission"]) {pending[@"submission"]=@"enteredUnknown";pending[@"observation"]=@"partial";pending[@"reason"]=@"hostException";}
        if([phase isEqual:@"legacyUnknown"]) {pending[@"submission"]=@"notRecorded";pending[@"observation"]=@"notRecorded";pending[@"hostCompletion"]=@"notRecorded";pending[@"reason"]=@"notRecorded";}
        NSDictionary *decoded=axs_cachekeeper_gurd_receipt_projection(receipt(@[pending]));
        require(decoded && [decoded[@"operations"][0][@"phase"] isEqual:phase] && [decoded[@"operations"][0][@"submission"] isEqual:pending[@"submission"]],@"decoding retains old lifecycle facts for the restore layer to close");
    }
    NSMutableDictionary *current=[observed mutableCopy];current[@"event"]=@6;current[@"runtimeInfo"]=runtime(@"0.7.2-211.1");current[@"scopeProof"]=completeProof();
    NSMutableArray *mixed=[canonical[@"operations"] mutableCopy];[mixed addObject:current];
    source=[canonical mutableCopy];source[@"operations"]=mixed;source[@"runtimeInfo"]=current[@"runtimeInfo"];
    projected=axs_cachekeeper_gurd_receipt_projection(source);
    require(projected && [axs_cachekeeper_gurd_scope_verification(projected) isEqual:@"legacyScopeNotRecorded"],@"new receipt producer cannot relabel mixed historical scope");
    require([axs_cachekeeper_gurd_receipt_projection(projected) isEqual:projected],@"mixed canonical history is idempotent");
    source=receipt(@[current]);source[@"runtimeInfo"]=current[@"runtimeInfo"];
    require([axs_cachekeeper_gurd_receipt_projection(source)[@"schemaVersion"] isEqual:@2],@"schema1 original fourteen-field receipts upgrade to schema2");
    require([axs_cachekeeper_gurd_scope_verification(axs_cachekeeper_gurd_receipt_projection(source)) isEqual:@"scopeObservationOnly"],@"modern scope observation keeps its separate meaning");
    for(NSNumber *format in @[@(NSPropertyListXMLFormat_v1_0),@(NSPropertyListBinaryFormat_v1_0)]) {
        NSData *bytes=[NSPropertyListSerialization dataWithPropertyList:historicalReceipt() format:format.unsignedIntegerValue options:0 error:nil];
        NSString *path=[folder stringByAppendingPathComponent:[NSString stringWithFormat:@"legacy-%@.plist",format]];
        require(bytes && [bytes writeToFile:path options:NSDataWritingAtomic error:nil],@"historical plist fixture is actually written");
        NSData *saved=[NSData dataWithContentsOfFile:path];id read=[NSPropertyListSerialization propertyListWithData:saved options:NSPropertyListImmutable format:NULL error:nil];
        require([axs_cachekeeper_gurd_receipt_projection(read) isEqual:canonical] && [[NSData dataWithContentsOfFile:path] isEqual:bytes],@"XML and binary plist decode preserve source bytes and canonical fields");
    }
    NSMutableDictionary *bad=[observed mutableCopy];bad[@"runtimeInfo"]=runtime(@"0.7.2-211.1");
    NSDictionary *failure=rejected(receipt(@[bad]),@"operation",@"legacyRuntime",@0);
    require([failure[@"runtimeInfo"] isEqual:bad[@"runtimeInfo"]] && [failure[@"sourceSchemaVersion"] isEqual:@1],@"rejection retains only validated failing producer and source schema");
    source=receipt(@[observed]);source[@"schemaVersion"]=@2;rejected(source,@"operation",@"missingScopeProof",@0);
    bad=[observed mutableCopy];bad[@"runtimeInfo"]=runtime(@"0.7.2-200.1");rejected(receipt(@[bad]),@"operation",@"legacyRuntime",@0);
    bad=[observed mutableCopy];bad[@"runtimeInfo"]=runtime(@"0.7.2-201.1");require(axs_cachekeeper_gurd_receipt_projection(receipt(@[bad]))!=nil,@"confirmed 201.1 producer is explicitly supported");
    bad=[observed mutableCopy];bad[@"rawPath"]=@"PRIVATE-CANARY";rejected(receipt(@[bad]),@"operation",@"fields",@0);
    bad=[observed mutableCopy];bad[@"event"]=@YES;rejected(receipt(@[bad]),@"operation",@"values",@0);
    bad=[observed mutableCopy];bad[@"runtimeInfo"]=@{@"schemaVersion":@1,@"packageVersion":@"PRIVATE-CANARY",@"firstObserved":@1};
    failure=rejected(receipt(@[bad]),@"operation",@"runtimeInfo",@0);require(!failure[@"runtimeInfo"],@"invalid producer text never appears in rejection");
    bad=[observed mutableCopy];bad[@"logicalDecrease"]=@61;rejected(receipt(@[bad]),@"operation",@"measurement",@0);
    bad=[observed mutableCopy];bad[@"allocatedDecrease"]=@0;rejected(receipt(@[bad]),@"operation",@"measurement",@0);
    bad=[observed mutableCopy];bad[@"observation"]=@"increased";rejected(receipt(@[bad]),@"operation",@"measurement",@0);
    bad=[observed mutableCopy];bad[@"submission"]=@"notSubmitted";rejected(receipt(@[bad]),@"operation",@"semantics",@0);
    bad=[observed mutableCopy];bad[@"before"]=sample(@"complete",1,100,4096,1,13);rejected(receipt(@[bad]),@"before",@"sample",@0);
    bad=[observed mutableCopy];bad[@"before"]=sample(@"partial",1,100,4096,1,0);rejected(receipt(@[bad]),@"before",@"legacySampleState",@0);
    bad=[observed mutableCopy];bad[@"reason"]=@"scopeUnproven";rejected(receipt(@[bad]),@"operation",@"legacyReason",@0);
    bad=[current mutableCopy];bad[@"scopeProof"]=@{@"state":@"notRecorded",@"source":@"legacyReceiptV1"};rejected(receipt(@[bad]),@"scopeProof",@"legacyRuntime",@0);
    bad=[canonical[@"operations"][0] mutableCopy];bad[@"scopeProof"]=@{@"state":@"notRecorded",@"source":@"PRIVATE-CANARY"};rejected(receipt(@[bad]),@"scopeProof",@"proof",@0);
    source=receipt(@[observed,observed]);rejected(source,@"operation",@"eventOrder",@1);
    rejected(receipt(@[NSNull.null]),@"operation",@"fields",@0);
    source=receipt(@[observed]);source[@"rawPath"]=@"PRIVATE-CANARY";rejected(source,@"receipt",@"fields",nil);
    source=receipt(@[observed]);source[@"schemaVersion"]=@"PRIVATE-CANARY";failure=rejected(source,@"receipt",@"schemaVersion",nil);require(!failure[@"sourceSchemaVersion"],@"invalid schema type is not exported");
    source=receipt(@[observed]);source[@"schemaVersion"]=@3;rejected(source,@"receipt",@"schemaVersion",nil);
    source=receipt(@[observed]);source[@"schemaVersion"]=@YES;rejected(source,@"receipt",@"schemaVersion",nil);
    source=receipt(@[observed]);source[@"background"]=@1;rejected(source,@"receipt",@"values",nil);
    rejected(@"PRIVATE-CANARY",@"receipt",@"type",nil);
    puts("PASS: gurd-status schema migration, strict rejection and historical evidence");
}
#endif
int main(int argc,const char *argv[]) {@autoreleasepool {
#if defined(AXS_CACHEKEEPER_GURD_MIGRATION_RED)
    (void)argc;(void)argv;migration();return 0;
#else
    require(argc==2,@"fixture directory argument is present");allCases([NSString stringWithUTF8String:argv[1]]);return 0;
#endif
}}
