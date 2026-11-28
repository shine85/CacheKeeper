#import "AxsCacheKeeperHostEvidence.h"
#import "AxsCacheKeeperRuntimeInfo.h"
#import "AxsCacheKeeperPolicy.h"
#include <notify.h>
#include <string.h>

static const NSUInteger AxsCacheKeeperHostLogicalWordCount=12;
static const NSUInteger AxsCacheKeeperHostFrameCount=24;
static uint32_t axs_cachekeeper_host_frame_marker(NSUInteger index) {return 0x434b4800U|(uint32_t)(index+1);}
static NSArray *axs_cachekeeper_host_config_states(void) { return @[@"notPermitted",@"missing",@"unreadable",@"invalid",@"readable"]; }
static NSArray *axs_cachekeeper_host_publish_states(void) { return @[@"notAttempted",@"succeeded",@"failed"]; }
static BOOL axs_cachekeeper_host_number(id value,double minimum,double maximum,BOOL integral) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()) return NO;
    double n=[value doubleValue];return isfinite(n) && n>=minimum && n<=maximum && (!integral || trunc(n)==n);
}
static BOOL axs_cachekeeper_host_boolean(id value) { return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID(); }
uint64_t axs_cachekeeper_host_request(uint32_t nonce,NSTimeInterval epoch) {
    if (!nonce || !isfinite(epoch) || epoch<1 || epoch>UINT32_MAX || trunc(epoch)!=epoch) return 0;
    return ((uint64_t)nonce<<32)|(uint32_t)epoch;
}
BOOL axs_cachekeeper_host_request_fresh(uint64_t request,NSTimeInterval now) {
    return request>>32 && (uint32_t)request!=0 && isfinite(now) && now>=1 && now<=UINT32_MAX && now>=(uint32_t)request && now-(uint32_t)request<=300;
}
NSString *axs_cachekeeper_host_name(NSString *bundle,uint64_t request,uint64_t tag,NSInteger frame) {
    if (!axs_cachekeeper_bundle_id(bundle)) return nil;
    NSString *base=[@"dev.local.cachekeeper.host.v1." stringByAppendingString:bundle];
    if (!request) return [base stringByAppendingString:@".request"];
    if (!tag) return [base stringByAppendingFormat:@".%016llx.announce",(unsigned long long)request];
    return [base stringByAppendingFormat:@".%016llx.%016llx.%ld",(unsigned long long)request,(unsigned long long)tag,(long)frame];
}
NSString *axs_cachekeeper_host_version_state(id value,NSString *panelVersion) {
    if (!value) return @"notRecorded";
    NSDictionary *info=axs_cachekeeper_runtime_info_projection(value);
    if (!info) return @"invalid";
    if (![panelVersion isKindOfClass:NSString.class] || !axs_cachekeeper_runtime_info_projection(@{@"schemaVersion":@1,@"packageVersion":panelVersion,@"firstObserved":@1})) return @"panelVersionUnknown";
    return [info[@"packageVersion"] isEqual:panelVersion] ? @"currentVersion" : @"differentVersion";
}
NSDictionary *axs_cachekeeper_host_projection(id value) {
    if (![value isKindOfClass:NSDictionary.class] || !axs_cachekeeper_host_number(value[@"schemaVersion"],1,1,YES) ||
        ![value[@"source"] isEqual:@"hostAutomatic"] || ![value[@"configurationReadScope"] isEqual:@"appEnabled"] || ![value[@"transportTrust"] isEqual:@"unauthenticated"] ||
        !axs_cachekeeper_host_number(value[@"updated"],1,UINT32_MAX,NO) || !axs_cachekeeper_runtime_info_projection(value[@"runtimeInfo"]) ||
        [value[@"runtimeInfo"][@"firstObserved"] doubleValue]>[value[@"updated"] doubleValue]+1) return nil;
    for (NSString *key in @[@"existingContainerGatePassed",@"authorizationAttempted",@"sharedAccessGranted"])
        if (!axs_cachekeeper_host_boolean(value[key])) return nil;
    if (!axs_cachekeeper_host_number(value[@"authorizationCode"],INT32_MIN,INT32_MAX,YES) ||
        !axs_cachekeeper_host_number(value[@"previousPublishErrorCode"],INT32_MIN,INT32_MAX,YES) ||
        ![axs_cachekeeper_host_config_states() containsObject:value[@"configurationReadState"]] ||
        ![axs_cachekeeper_host_publish_states() containsObject:value[@"previousPublishState"]]) return nil;
    BOOL attempted=[value[@"authorizationAttempted"] boolValue],access=[value[@"sharedAccessGranted"] boolValue];
    if ((!attempted && ([value[@"authorizationCode"] intValue] || access)) ||
        (!access && ![value[@"configurationReadState"] isEqual:@"notPermitted"]) ||
        (access && [value[@"configurationReadState"] isEqual:@"notPermitted"]) ||
        (![value[@"previousPublishState"] isEqual:@"failed"] && [value[@"previousPublishErrorCode"] intValue])) return nil;
    NSArray *keys=@[@"schemaVersion",@"source",@"transportTrust",@"updated",@"runtimeInfo",@"existingContainerGatePassed",@"authorizationAttempted",@"sharedAccessGranted",@"authorizationCode",@"configurationReadScope",@"configurationReadState",@"previousPublishState",@"previousPublishErrorCode"];
    NSMutableDictionary *out=[[value dictionaryWithValuesForKeys:keys] mutableCopy];out[@"runtimeInfo"]=axs_cachekeeper_runtime_info_projection(value[@"runtimeInfo"]);return [out copy];
}
NSDictionary *axs_cachekeeper_host_observed_projection(id value) {
    if (![value isKindOfClass:NSDictionary.class] || ![value[@"source"] isEqual:@"panelObserved"] ||
        !axs_cachekeeper_host_number(value[@"updated"],1,UINT32_MAX,NO) ||
        ![@[@"observed",@"timedOut",@"cancelled",@"transportError",@"clockChanged",@"invalidResponse"] containsObject:value[@"state"]]) return nil;
    NSMutableDictionary *out=[@{@"source":@"panelObserved",@"state":value[@"state"],@"updated":value[@"updated"],@"transportTrust":@"unauthenticated"} mutableCopy];
    if ([value[@"state"] isEqual:@"observed"]) {NSDictionary *data=axs_cachekeeper_host_projection(value[@"data"]);if (!data) return nil;out[@"data"]=data;}
    if (value[@"multipleResponders"]) {if (!axs_cachekeeper_host_boolean(value[@"multipleResponders"])) return nil;out[@"multipleResponders"]=value[@"multipleResponders"];}
    return out;
}
NSDictionary *axs_cachekeeper_network_projection(id value) {
    if (![value isKindOfClass:NSDictionary.class] || !axs_cachekeeper_input_boolean(value[@"prevent"]) || !axs_cachekeeper_input_boolean(value[@"applied"])) return nil;
    if (value[@"updated"] && (![value[@"updated"] isKindOfClass:NSDate.class] || !isfinite([value[@"updated"] timeIntervalSince1970]))) return nil;
    NSMutableDictionary *out=[@{@"prevent":@([value[@"prevent"] boolValue]),@"applied":@([value[@"applied"] boolValue]),@"effectVerification":@"notVerified",@"updatedState":value[@"updated"] ? @"recorded" : @"notRecorded"} mutableCopy];
    if (value[@"policyObservation"]) {
        if (![value[@"policyObservation"] isEqual:@"disabledInProcess"] || [value[@"prevent"] boolValue] ||
            ![value[@"applied"] boolValue] || !value[@"updated"] || !value[@"runtimeInfo"]) return nil;
        out[@"policyObservation"]=@"disabledInProcess";
    }
    if (value[@"updated"]) out[@"updated"]=@([value[@"updated"] timeIntervalSince1970]);
    if (value[@"runtimeInfo"]) {NSDictionary *info=axs_cachekeeper_runtime_info_projection(value[@"runtimeInfo"]);if (!info) return nil;out[@"runtimeInfo"]=info;}
    return out;
}
NSArray *axs_cachekeeper_host_encode(NSDictionary *value,uint64_t request) {
    NSDictionary *s=axs_cachekeeper_host_projection(value);if (!s || !(request>>32)) return nil;
    NSData *version=[s[@"runtimeInfo"][@"packageVersion"] dataUsingEncoding:NSASCIIStringEncoding allowLossyConversion:NO];
    if (!version.length || version.length>48) return nil;
    uint64_t words[AxsCacheKeeperHostLogicalWordCount];memset(words,0,sizeof(words));words[0]=request;
    words[1]=0x434B480100000000ULL|((uint64_t)AxsCacheKeeperHostFrameCount<<16)|version.length;
    double updated=[s[@"updated"] doubleValue],first=[s[@"runtimeInfo"][@"firstObserved"] doubleValue];
    memcpy(&words[2],&updated,8);memcpy(&words[5],&first,8);
    words[3]=[s[@"existingContainerGatePassed"] boolValue]|((uint64_t)[s[@"authorizationAttempted"] boolValue]<<1)|((uint64_t)[s[@"sharedAccessGranted"] boolValue]<<2)|
        ((uint64_t)[axs_cachekeeper_host_config_states() indexOfObject:s[@"configurationReadState"]]<<8)|((uint64_t)[axs_cachekeeper_host_publish_states() indexOfObject:s[@"previousPublishState"]]<<12);
    words[4]=(uint32_t)[s[@"authorizationCode"] intValue]|((uint64_t)(uint32_t)[s[@"previousPublishErrorCode"] intValue]<<32);
    const uint8_t *bytes=version.bytes;for (NSUInteger i=0;i<version.length;i++) words[6+i/8]|=(uint64_t)bytes[i]<<((i%8)*8);
    // Registering a missing notify name yields state 0. Every physical frame therefore
    // carries a nonzero marker and its exact index, even when all payload bits are zero.
    NSMutableArray *out=[NSMutableArray new];
    for (NSUInteger i=0;i<AxsCacheKeeperHostFrameCount;i++) {
        uint32_t payload=(uint32_t)(words[i/2]>>((i%2)*32));
        [out addObject:@(((uint64_t)axs_cachekeeper_host_frame_marker(i)<<32)|payload)];
    }
    return out;
}
NSDictionary *axs_cachekeeper_host_decode(NSArray *frames,uint64_t request,NSTimeInterval now) {
    if (![frames isKindOfClass:NSArray.class] || frames.count!=AxsCacheKeeperHostFrameCount || !axs_cachekeeper_host_request_fresh(request,now)) return nil;
    uint64_t w[AxsCacheKeeperHostLogicalWordCount];memset(w,0,sizeof(w));
    for (NSUInteger i=0;i<AxsCacheKeeperHostFrameCount;i++) {
        id n=frames[i];if (![n isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)n)==CFBooleanGetTypeID() || [n doubleValue]<0 || !isfinite([n doubleValue]) || strcmp([n objCType],@encode(double))==0 || strcmp([n objCType],@encode(float))==0) return nil;
        uint64_t physical=[n unsignedLongLongValue];
        if ((uint32_t)(physical>>32)!=axs_cachekeeper_host_frame_marker(i)) return nil;
        w[i/2]|=(uint64_t)(uint32_t)physical<<((i%2)*32);
    }
    NSUInteger length=w[1]&0xffff;uint64_t header=0x434B480100000000ULL|((uint64_t)AxsCacheKeeperHostFrameCount<<16)|length;
    if (w[0]!=request || w[1]!=header || !length || length>48 || (w[3]&~0x0000000000007707ULL)) return nil;
    NSUInteger config=(w[3]>>8)&7,publish=(w[3]>>12)&7;if (config>=5 || publish>=3) return nil;
    uint8_t bytes[48];for (NSUInteger i=0;i<48;i++) {bytes[i]=(w[6+i/8]>>((i%8)*8))&0xff;if (i>=length && bytes[i]) return nil;}
    NSString *version=[[NSString alloc] initWithBytes:bytes length:length encoding:NSASCIIStringEncoding];if (!version) return nil;
    double updated,first;memcpy(&updated,&w[2],8);memcpy(&first,&w[5],8);
    if (!isfinite(updated) || !isfinite(first) || first>updated+1 || updated<(uint32_t)request || updated>now+1) return nil;
    return axs_cachekeeper_host_projection(@{@"schemaVersion":@1,@"source":@"hostAutomatic",@"transportTrust":@"unauthenticated",@"updated":@(updated),
        @"runtimeInfo":@{@"schemaVersion":@1,@"packageVersion":version,@"firstObserved":@(first)},@"existingContainerGatePassed":@((BOOL)((w[3]&1)!=0)),@"authorizationAttempted":@((BOOL)((w[3]&2)!=0)),@"sharedAccessGranted":@((BOOL)((w[3]&4)!=0)),
        @"authorizationCode":@((int32_t)w[4]),@"configurationReadScope":@"appEnabled",@"configurationReadState":axs_cachekeeper_host_config_states()[config],@"previousPublishState":axs_cachekeeper_host_publish_states()[publish],@"previousPublishErrorCode":@((int32_t)(w[4]>>32))});
}
#if !defined(AXS_CACHEKEEPER_HOST_CLIENT_ONLY) || !defined(AXS_CACHEKEEPER_HOST_SERVER_ONLY)
static void axs_cachekeeper_host_cancel_tokens(NSMutableArray *tokens) {for (NSNumber *n in tokens) notify_cancel(n.intValue);[tokens removeAllObjects];}
static uint32_t axs_cachekeeper_host_register(NSString *name,NSMutableArray *tokens,int *token) {
    *token=-1;uint32_t status=notify_register_check(name.UTF8String,token);
    if (status==NOTIFY_STATUS_OK) [tokens addObject:@(*token)];else if (*token>=0) {notify_cancel(*token);*token=-1;}return status;
}

#endif

#if !defined(AXS_CACHEKEEPER_HOST_CLIENT_ONLY)
@interface AxsCacheKeeperHostEvidenceServer ()
@property(nonatomic,copy) NSString *axs_cachekeeper_bundle,*axs_cachekeeper_folder;
@property(nonatomic,strong) NSDictionary *axs_cachekeeper_runtimeInfo,*axs_cachekeeper_current;
@property(nonatomic,strong) dispatch_queue_t axs_cachekeeper_queue;
@property(nonatomic,strong) NSMutableArray *axs_cachekeeper_responseTokens;
@property(nonatomic) int axs_cachekeeper_requestToken;
@property(nonatomic) BOOL axs_cachekeeper_invalidated,axs_cachekeeper_eligible,axs_cachekeeper_attempted,axs_cachekeeper_access,axs_cachekeeper_scheduled;
@property(nonatomic) int32_t axs_cachekeeper_authorizationCode;
@property(nonatomic) uint64_t axs_cachekeeper_lastRequest,axs_cachekeeper_lastTag;
@property(nonatomic) int axs_cachekeeper_announceToken;
@property(nonatomic) NSTimeInterval axs_cachekeeper_lastAnswer;
@property(nonatomic,copy) NSString *axs_cachekeeper_publishState;
@property(nonatomic) int32_t axs_cachekeeper_publishCode;
@end
@implementation AxsCacheKeeperHostEvidenceServer
- (instancetype)initWithBundle:(NSString *)bundle folder:(NSString *)folder runtimeInfo:(NSDictionary *)runtimeInfo {
    if (!(self=[super init]) || !axs_cachekeeper_bundle_id(bundle) || !axs_cachekeeper_runtime_info_projection(runtimeInfo)) return nil;
    _axs_cachekeeper_bundle=[bundle copy];_axs_cachekeeper_folder=[folder copy];_axs_cachekeeper_runtimeInfo=@{@"schemaVersion":@1,@"packageVersion":[runtimeInfo[@"packageVersion"] copy],@"firstObserved":runtimeInfo[@"firstObserved"]};_axs_cachekeeper_requestToken=-1;_axs_cachekeeper_announceToken=-1;
    _axs_cachekeeper_publishState=@"notAttempted";_axs_cachekeeper_responseTokens=[NSMutableArray new];_axs_cachekeeper_queue=dispatch_queue_create("dev.local.cachekeeper.host.evidence",DISPATCH_QUEUE_SERIAL);
    __weak typeof(self) weak=self;
    uint32_t status=notify_register_dispatch(axs_cachekeeper_host_name(bundle,0,0,0).UTF8String,&_axs_cachekeeper_requestToken,_axs_cachekeeper_queue,^(int token) {(void)token;[weak axs_cachekeeper_answer];});
    if (status!=NOTIFY_STATUS_OK) {if (_axs_cachekeeper_requestToken>=0) notify_cancel(_axs_cachekeeper_requestToken);_axs_cachekeeper_requestToken=-1;}
    // A request can predate application launch; posts are only hints.
    return self;
}
- (void)axs_cachekeeper_sample {
    NSString *config=@"notPermitted";
    if (self.axs_cachekeeper_access) {
        NSError *error=nil;NSDictionary *input=axs_cachekeeper_read_input([self.axs_cachekeeper_folder stringByAppendingPathComponent:@"appEnabled.plist"],&error);
        config=input ? @"readable" : (!error ? @"missing" : (([error.domain isEqual:@"dev.local.cachekeeper.configuration"] || ([error.domain isEqual:NSCocoaErrorDomain] && error.code==NSPropertyListReadCorruptError)) ? @"invalid" : @"unreadable"));
    }
    NSMutableDictionary *snapshot=[@{@"schemaVersion":@1,@"source":@"hostAutomatic",@"transportTrust":@"unauthenticated",@"updated":@(NSDate.date.timeIntervalSince1970),@"runtimeInfo":self.axs_cachekeeper_runtimeInfo,
        @"existingContainerGatePassed":@(self.axs_cachekeeper_eligible),@"authorizationAttempted":@(self.axs_cachekeeper_attempted),@"sharedAccessGranted":@(self.axs_cachekeeper_access),@"authorizationCode":@(self.axs_cachekeeper_authorizationCode),@"configurationReadScope":@"appEnabled",@"configurationReadState":config,
        @"previousPublishState":self.axs_cachekeeper_publishState,@"previousPublishErrorCode":@(self.axs_cachekeeper_publishCode)} mutableCopy];
    if (self.axs_cachekeeper_access) {
        NSError *error=nil;NSString *path=[self.axs_cachekeeper_folder stringByAppendingPathComponent:[NSString stringWithFormat:@"Status/%@.host.plist",self.axs_cachekeeper_bundle]];
        BOOL saved=[snapshot writeToURL:[NSURL fileURLWithPath:path] error:&error];
        self.axs_cachekeeper_publishState=saved ? @"succeeded" : @"failed";self.axs_cachekeeper_publishCode=saved ? 0 : (int32_t)MAX(INT32_MIN,MIN(INT32_MAX,error.code));
        // The saved file records the previous attempt. Only memory reports this attempt.
        snapshot[@"previousPublishState"]=self.axs_cachekeeper_publishState;snapshot[@"previousPublishErrorCode"]=@(self.axs_cachekeeper_publishCode);
    }
    self.axs_cachekeeper_current=[snapshot copy];
}
- (void)axs_cachekeeper_observeContainer:(BOOL)eligible authorizationAttempted:(BOOL)attempted authorizationCode:(int32_t)code sharedAccess:(BOOL)access {
    dispatch_async(self.axs_cachekeeper_queue,^{if (self.axs_cachekeeper_invalidated) return;self.axs_cachekeeper_eligible=eligible;self.axs_cachekeeper_attempted=attempted;self.axs_cachekeeper_authorizationCode=attempted ? code : 0;self.axs_cachekeeper_access=attempted && access;[self axs_cachekeeper_sample];[self axs_cachekeeper_answer];});
}
- (void)axs_cachekeeper_answer {
    uint64_t request=0;if (self.axs_cachekeeper_invalidated || !self.axs_cachekeeper_current || self.axs_cachekeeper_requestToken<0 || notify_get_state(self.axs_cachekeeper_requestToken,&request)!=NOTIFY_STATUS_OK || !axs_cachekeeper_host_request_fresh(request,NSDate.date.timeIntervalSince1970)) return;
    if (request==self.axs_cachekeeper_lastRequest && self.axs_cachekeeper_lastTag && self.axs_cachekeeper_announceToken>=0) {
        if (notify_set_state(self.axs_cachekeeper_announceToken,self.axs_cachekeeper_lastTag)==NOTIFY_STATUS_OK) notify_post(axs_cachekeeper_host_name(self.axs_cachekeeper_bundle,request,0,0).UTF8String);return;
    }
    NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
    if (now-self.axs_cachekeeper_lastAnswer<.1) {
        if (!self.axs_cachekeeper_scheduled) {self.axs_cachekeeper_scheduled=YES;__weak typeof(self) weak=self;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.1*NSEC_PER_SEC)),self.axs_cachekeeper_queue,^{weak.axs_cachekeeper_scheduled=NO;[weak axs_cachekeeper_answer];});}return;
    }
    self.axs_cachekeeper_lastAnswer=now;
    // Lifecycle observation may already have sampled after this request. Freeze it once.
    if ([self.axs_cachekeeper_current[@"updated"] doubleValue]<(uint32_t)request) [self axs_cachekeeper_sample];
    NSArray *frames=axs_cachekeeper_host_encode(self.axs_cachekeeper_current,request);if (!frames) return;
    axs_cachekeeper_host_cancel_tokens(self.axs_cachekeeper_responseTokens);self.axs_cachekeeper_lastRequest=0;self.axs_cachekeeper_lastTag=0;self.axs_cachekeeper_announceToken=-1;
    uint64_t tag=0;while (!tag) arc4random_buf(&tag,sizeof(tag));
    for (NSUInteger i=0;i<frames.count;i++) {int token=-1;
        if (axs_cachekeeper_host_register(axs_cachekeeper_host_name(self.axs_cachekeeper_bundle,request,tag,(NSInteger)i),self.axs_cachekeeper_responseTokens,&token)!=NOTIFY_STATUS_OK || notify_set_state(token,[frames[i] unsignedLongLongValue])!=NOTIFY_STATUS_OK) {axs_cachekeeper_host_cancel_tokens(self.axs_cachekeeper_responseTokens);return;}
    }
    int announce=-1;
    if (axs_cachekeeper_host_register(axs_cachekeeper_host_name(self.axs_cachekeeper_bundle,request,0,0),self.axs_cachekeeper_responseTokens,&announce)!=NOTIFY_STATUS_OK || notify_set_state(announce,tag)!=NOTIFY_STATUS_OK) {axs_cachekeeper_host_cancel_tokens(self.axs_cachekeeper_responseTokens);return;}
    self.axs_cachekeeper_lastRequest=request;self.axs_cachekeeper_lastTag=tag;self.axs_cachekeeper_announceToken=announce;notify_post(axs_cachekeeper_host_name(self.axs_cachekeeper_bundle,request,0,0).UTF8String);
    __weak typeof(self) weak=self;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,301LL*NSEC_PER_SEC),self.axs_cachekeeper_queue,^{
        typeof(self) strong=weak;if (strong.axs_cachekeeper_lastRequest==request) {axs_cachekeeper_host_cancel_tokens(strong.axs_cachekeeper_responseTokens);strong.axs_cachekeeper_lastRequest=0;strong.axs_cachekeeper_lastTag=0;strong.axs_cachekeeper_announceToken=-1;}
    });
}
- (NSDictionary *)axs_cachekeeper_snapshot {__block NSDictionary *s;dispatch_sync(self.axs_cachekeeper_queue,^{s=self.axs_cachekeeper_current;});return s;}
- (void)axs_cachekeeper_invalidate {dispatch_sync(self.axs_cachekeeper_queue,^{self.axs_cachekeeper_invalidated=YES;if (self.axs_cachekeeper_requestToken>=0) notify_cancel(self.axs_cachekeeper_requestToken);self.axs_cachekeeper_requestToken=-1;axs_cachekeeper_host_cancel_tokens(self.axs_cachekeeper_responseTokens);});}
- (void)dealloc {if (_axs_cachekeeper_requestToken>=0) notify_cancel(_axs_cachekeeper_requestToken);axs_cachekeeper_host_cancel_tokens(_axs_cachekeeper_responseTokens);}
@end

#endif

#if !defined(AXS_CACHEKEEPER_HOST_SERVER_ONLY)
@interface AxsCacheKeeperHostEvidenceClient ()
@property(nonatomic,copy) NSString *axs_cachekeeper_bundle;
@property(nonatomic,strong) NSMutableArray *axs_cachekeeper_tokens;
@property(nonatomic,strong) NSDictionary *axs_cachekeeper_result;
@property(nonatomic) uint64_t axs_cachekeeper_request,axs_cachekeeper_lastSeenTag;
@property(nonatomic) int axs_cachekeeper_announceToken;
@property(nonatomic) NSTimeInterval axs_cachekeeper_deadline,axs_cachekeeper_startUptime,axs_cachekeeper_startEpoch;
@property(nonatomic) BOOL axs_cachekeeper_multiple;
@end
@implementation AxsCacheKeeperHostEvidenceClient
- (instancetype)initWithBundle:(NSString *)bundle {if (!(self=[super init]) || !axs_cachekeeper_bundle_id(bundle)) return nil;_axs_cachekeeper_bundle=[bundle copy];_axs_cachekeeper_tokens=[NSMutableArray new];_axs_cachekeeper_result=@{@"state":@"idle"};return self;}
- (void)axs_cachekeeper_finish:(NSString *)state data:(NSDictionary *)data {
    NSMutableDictionary *result=[@{@"state":state,@"source":@"panelObserved",@"transportTrust":@"unauthenticated",@"updated":@(NSDate.date.timeIntervalSince1970),@"multipleResponders":@(self.axs_cachekeeper_multiple)} mutableCopy];if (data) result[@"data"]=data;
    self.axs_cachekeeper_result=result;axs_cachekeeper_host_cancel_tokens(self.axs_cachekeeper_tokens);
}
- (BOOL)axs_cachekeeper_beginWithTimeout:(NSTimeInterval)timeout {
    [self axs_cachekeeper_cancel];self.axs_cachekeeper_multiple=NO;self.axs_cachekeeper_lastSeenTag=0;
    if (!isfinite(timeout) || timeout<=0 || timeout>300) {[self axs_cachekeeper_finish:@"transportError" data:nil];return NO;}
    self.axs_cachekeeper_startUptime=NSProcessInfo.processInfo.systemUptime;self.axs_cachekeeper_startEpoch=NSDate.date.timeIntervalSince1970;self.axs_cachekeeper_deadline=self.axs_cachekeeper_startUptime+timeout;
    self.axs_cachekeeper_request=axs_cachekeeper_host_request(arc4random_uniform(UINT32_MAX-1)+1,floor(self.axs_cachekeeper_startEpoch));
    int requestToken=-1;
    uint32_t status=self.axs_cachekeeper_request ? axs_cachekeeper_host_register(axs_cachekeeper_host_name(self.axs_cachekeeper_bundle,0,0,0),self.axs_cachekeeper_tokens,&requestToken) : NOTIFY_STATUS_INVALID_REQUEST;
    if (status==NOTIFY_STATUS_OK) status=axs_cachekeeper_host_register(axs_cachekeeper_host_name(self.axs_cachekeeper_bundle,self.axs_cachekeeper_request,0,0),self.axs_cachekeeper_tokens,&_axs_cachekeeper_announceToken);
    if (status==NOTIFY_STATUS_OK) status=notify_set_state(requestToken,self.axs_cachekeeper_request);
    if (status==NOTIFY_STATUS_OK) status=notify_post(axs_cachekeeper_host_name(self.axs_cachekeeper_bundle,0,0,0).UTF8String);
    if (status!=NOTIFY_STATUS_OK) {[self axs_cachekeeper_finish:@"transportError" data:nil];return NO;}
    self.axs_cachekeeper_result=@{@"state":@"pending"};return YES;
}
- (NSDictionary *)axs_cachekeeper_poll {
    if (![self.axs_cachekeeper_result[@"state"] isEqual:@"pending"]) return self.axs_cachekeeper_result;
    NSTimeInterval uptime=NSProcessInfo.processInfo.systemUptime,epoch=NSDate.date.timeIntervalSince1970;
    // Expiry is checked before considering even a perfectly matching response.
    if (uptime>=self.axs_cachekeeper_deadline) {[self axs_cachekeeper_finish:@"timedOut" data:nil];return self.axs_cachekeeper_result;}
    if (fabs((epoch-self.axs_cachekeeper_startEpoch)-(uptime-self.axs_cachekeeper_startUptime))>2) {[self axs_cachekeeper_finish:@"clockChanged" data:nil];return self.axs_cachekeeper_result;}
    for (NSUInteger attempt=0;attempt<2;attempt++) {
        uint64_t tag=0;if (notify_get_state(self.axs_cachekeeper_announceToken,&tag)!=NOTIFY_STATUS_OK) {[self axs_cachekeeper_finish:@"transportError" data:nil];break;}if (!tag) break;
        if (self.axs_cachekeeper_lastSeenTag && self.axs_cachekeeper_lastSeenTag!=tag) self.axs_cachekeeper_multiple=YES;self.axs_cachekeeper_lastSeenTag=tag;
        NSMutableArray *readTokens=[NSMutableArray new],*frames=[NSMutableArray new];BOOL failed=NO;
        for (NSUInteger i=0;i<AxsCacheKeeperHostFrameCount;i++) {int token=-1;uint64_t word=0;
            if (axs_cachekeeper_host_register(axs_cachekeeper_host_name(self.axs_cachekeeper_bundle,self.axs_cachekeeper_request,tag,(NSInteger)i),readTokens,&token)!=NOTIFY_STATUS_OK || notify_get_state(token,&word)!=NOTIFY_STATUS_OK) {failed=YES;break;}[frames addObject:@(word)];
        }
        uint64_t after=0;uint32_t status=notify_get_state(self.axs_cachekeeper_announceToken,&after);axs_cachekeeper_host_cancel_tokens(readTokens);
        if (NSProcessInfo.processInfo.systemUptime>=self.axs_cachekeeper_deadline) {[self axs_cachekeeper_finish:@"timedOut" data:nil];break;}
        if (failed || status!=NOTIFY_STATUS_OK) {[self axs_cachekeeper_finish:@"transportError" data:nil];break;}
        if (tag!=after) {self.axs_cachekeeper_multiple=YES;continue;}
        NSDictionary *data=axs_cachekeeper_host_decode(frames,self.axs_cachekeeper_request,epoch);
        if (!data) {[self axs_cachekeeper_finish:@"invalidResponse" data:nil];break;}
        [self axs_cachekeeper_finish:@"observed" data:data];break;
    }
    return self.axs_cachekeeper_result;
}
- (void)axs_cachekeeper_cancel {if ([self.axs_cachekeeper_result[@"state"] isEqual:@"pending"]) [self axs_cachekeeper_finish:@"cancelled" data:nil];else axs_cachekeeper_host_cancel_tokens(self.axs_cachekeeper_tokens);}
- (NSUInteger)axs_cachekeeper_activeTokenCount {return self.axs_cachekeeper_tokens.count;}
- (void)dealloc {axs_cachekeeper_host_cancel_tokens(_axs_cachekeeper_tokens);}
@end

#endif

NSString *axs_cachekeeper_host_summary(NSDictionary *envelope,NSString *panelVersion) {
    if (![envelope[@"state"] isEqual:@"available"]) return [NSString stringWithFormat:@"记录：%@",envelope[@"state"] ?: @"missing"];
    NSDictionary *data=envelope[@"data"];
    if ([data[@"source"] isEqual:@"panelObserved"]) {if (![data[@"state"] isEqual:@"observed"]) return [NSString stringWithFormat:@"面板观察：%@；无响应不能断定未注入",data[@"state"]];data=data[@"data"];}
    if (!axs_cachekeeper_host_projection(data)) return @"记录：invalid";
    NSString *time=[NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:[data[@"updated"] doubleValue]] dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterMediumStyle];
    return [NSString stringWithFormat:@"宿主 %@（%@）；快照 %@\n容器门：%@；已有授权：%@（%@）\nAPP 开关配置（appEnabled.plist）：%@；上次发布：%@（%@）\n自报告信号未经身份认证；不证明清理或写入限制效果",data[@"runtimeInfo"][@"packageVersion"],axs_cachekeeper_host_version_state(data[@"runtimeInfo"],panelVersion),time,[data[@"existingContainerGatePassed"] boolValue] ? @"通过" : @"未通过",[data[@"sharedAccessGranted"] boolValue] ? @"返回成功" : ([data[@"authorizationAttempted"] boolValue] ? @"返回失败" : @"未尝试"),data[@"authorizationCode"],data[@"configurationReadState"],data[@"previousPublishState"],data[@"previousPublishErrorCode"]];
}
