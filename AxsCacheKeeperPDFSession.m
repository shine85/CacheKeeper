#import "AxsCacheKeeperPDFSessionPrivate.h"
#import "AxsCacheKeeperPolicy.h"
#import <TargetConditionals.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <math.h>

static char axs_cachekeeper_pdf_service[128]="dev.local.cachekeeper.diagnostic.pdf.v1";
#if !defined(AXS_CACHEKEEPER_PDF_CLIENT)
static const double axs_cachekeeper_pdf_lease=10;
#endif
static BOOL axs_cachekeeper_pdf_text(id value,NSUInteger maximum) {
    if (![value isKindOfClass:NSString.class] || ![value length] || [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>maximum) return NO;
    unichar zero=0;return [value rangeOfString:[NSString stringWithCharacters:&zero length:1]].location==NSNotFound;
}
static BOOL axs_cachekeeper_pdf_uuid(id value) { return axs_cachekeeper_pdf_text(value,36) && [[NSUUID alloc] initWithUUIDString:value]!=nil; }
static BOOL axs_cachekeeper_pdf_integer(id value,uint64_t maximum) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()) return NO;
    double number=[value doubleValue];return isfinite(number) && number>=0 && number<=maximum && floor(number)==number;
}
BOOL axs_cachekeeper_pdf_request_valid(id value) {
    if (![value isKindOfClass:NSDictionary.class] || [value count]!=8) return NO;
    NSSet *keys=[NSSet setWithArray:@[@"operation",@"bundle",@"relative",@"session",@"generation",@"nonce",@"service",@"candidate"]];
    if (![[NSSet setWithArray:[value allKeys]] isEqual:keys] ||
        ![@[@"probe",@"start",@"poll",@"cancel",@"resolve"] containsObject:value[@"operation"]] ||
        !axs_cachekeeper_pdf_text(value[@"bundle"],255) || !axs_cachekeeper_bundle_id(value[@"bundle"]) ||
        !axs_cachekeeper_pdf_text(value[@"relative"],4095) || !axs_cachekeeper_relative_path(value[@"relative"]) ||
        [value[@"relative"] hasPrefix:@"Group/"] || axs_cachekeeper_protected_path(value[@"relative"]) ||
        !axs_cachekeeper_pdf_uuid(value[@"session"]) || !axs_cachekeeper_pdf_uuid(value[@"nonce"]) ||
        !axs_cachekeeper_pdf_integer(value[@"generation"],UINT32_MAX) || ![value[@"generation"] unsignedIntValue] ||
        !axs_cachekeeper_pdf_integer(value[@"candidate"],10)) return NO;
    BOOL probe=[value[@"operation"] isEqual:@"probe"];
    if (probe ? ![value[@"service"] isEqual:@""] : !axs_cachekeeper_pdf_uuid(value[@"service"])) return NO;
    return [value[@"operation"] isEqual:@"resolve"] ? [value[@"candidate"] unsignedIntegerValue]<10 : [value[@"candidate"] unsignedIntegerValue]==10;
}
BOOL axs_cachekeeper_pdf_reply_matches(NSDictionary *reply,NSDictionary *request,NSString *service) {
    if (![reply isKindOfClass:NSDictionary.class] || reply.count!=8 ||
        ![[NSSet setWithArray:reply.allKeys] isEqual:[NSSet setWithArray:@[@"operation",@"nonce",@"session",@"generation",@"service",@"state",@"report",@"directory"]]]) return NO;
    for (NSString *key in @[@"operation",@"nonce",@"session",@"generation"]) if (![reply[key] isEqual:request[key]]) return NO;
    if (!axs_cachekeeper_pdf_uuid(reply[@"service"]) || (service.length && ![reply[@"service"] isEqual:service])) return NO;
    return [@[@"probing",@"ready",@"running",@"finished",@"unavailable",@"cancelled",@"busy",@"expired",@"rejected"] containsObject:reply[@"state"]] &&
        [axs_cachekeeper_pdf_report_fields(reply[@"report"]) isEqual:reply[@"report"]] && [reply[@"report"][@"state"] isEqual:reply[@"state"]] && [reply[@"directory"] isKindOfClass:NSString.class] &&
        ([request[@"operation"] isEqual:@"resolve"] || ![reply[@"directory"] length]);
}
BOOL axs_cachekeeper_pdf_encode(AxsCacheKeeperPDFMessage *message,NSDictionary *payload,BOOL reply,mach_port_t remote,mach_port_t local) {
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:payload format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if (!data.length || data.length>(reply ? AxsCacheKeeperPDFWireLimit : AxsCacheKeeperPDFRequestLimit)) return NO;
    memset(message,0,sizeof(*message));message->version=1;message->length=(uint32_t)data.length;
    memcpy(message->payload,data.bytes,data.length);
    message->header.msgh_bits=reply ? MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE,0) : MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND,MACH_MSG_TYPE_MAKE_SEND_ONCE);
    message->header.msgh_size=(mach_msg_size_t)round_msg(offsetof(AxsCacheKeeperPDFMessage,payload)+data.length);
    message->header.msgh_remote_port=remote;message->header.msgh_local_port=local;
    message->header.msgh_id=reply ? AxsCacheKeeperPDFReplyID : AxsCacheKeeperPDFRequestID;return YES;
}
BOOL axs_cachekeeper_pdf_decode(const void *bytes,size_t capacity,mach_port_t port,BOOL reply,NSDictionary **payload,audit_token_t *token) {
    if (payload) *payload=nil;if (token) memset(token,0,sizeof(*token));
    if (!bytes || capacity<offsetof(AxsCacheKeeperPDFMessage,payload) || !payload || !token) return NO;
    const AxsCacheKeeperPDFMessage *message=bytes;
    mach_msg_bits_t expected=reply ? MACH_MSGH_BITS(0,MACH_MSG_TYPE_PORT_SEND_ONCE) : MACH_MSGH_BITS(MACH_MSG_TYPE_PORT_SEND_ONCE,MACH_MSG_TYPE_PORT_SEND);
    if (message->version!=1 || !message->length || message->length>(reply ? AxsCacheKeeperPDFWireLimit : AxsCacheKeeperPDFRequestLimit) ||
        message->header.msgh_size!=round_msg(offsetof(AxsCacheKeeperPDFMessage,payload)+message->length) ||
        message->header.msgh_size>sizeof(*message) || message->header.msgh_size>capacity || message->header.msgh_bits!=expected ||
        message->header.msgh_voucher_port || message->header.msgh_local_port!=port ||
        message->header.msgh_id!=(reply ? AxsCacheKeeperPDFReplyID : AxsCacheKeeperPDFRequestID) ||
        (reply ? message->header.msgh_remote_port!=MACH_PORT_NULL : !MACH_PORT_VALID(message->header.msgh_remote_port))) return NO;
    size_t offset=round_msg(message->header.msgh_size);
    if (offset>capacity || capacity-offset<sizeof(mach_msg_audit_trailer_t)) return NO;
    for (size_t i=offsetof(AxsCacheKeeperPDFMessage,payload)+message->length;i<offset;i++) if (((const uint8_t *)bytes)[i]) return NO;
    mach_msg_audit_trailer_t trailer;memcpy(&trailer,(const uint8_t *)bytes+offset,sizeof(trailer));
    if (trailer.msgh_trailer_type!=MACH_MSG_TRAILER_FORMAT_0 || trailer.msgh_trailer_size!=sizeof(trailer)) return NO;
    if (!reply) {
        mach_port_type_t type=0;
        if (mach_port_type(mach_task_self(),message->header.msgh_remote_port,&type)!=KERN_SUCCESS || type!=MACH_PORT_TYPE_SEND_ONCE) return NO;
    }
    id object=[NSPropertyListSerialization propertyListWithData:[NSData dataWithBytes:message->payload length:message->length]
        options:NSPropertyListImmutable format:nil error:nil];
    if (![object isKindOfClass:NSDictionary.class] || (!reply && !axs_cachekeeper_pdf_request_valid(object))) return NO;
    *payload=object;*token=trailer.msgh_audit;return YES;
}
void axs_cachekeeper_pdf_destroy(AxsCacheKeeperPDFBuffer *buffer) {
    buffer->header.msgh_local_port=MACH_PORT_NULL;mach_msg_destroy(&buffer->header);memset(buffer,0,sizeof(*buffer));
}
static BOOL axs_cachekeeper_pdf_send(AxsCacheKeeperPDFMessage *message,int *code) {
    mach_msg_return_t result=mach_msg(&message->header,MACH_SEND_MSG|MACH_SEND_TIMEOUT,message->header.msgh_size,0,MACH_PORT_NULL,1000,MACH_PORT_NULL);
    if (code) *code=result;
    if (result==MACH_MSG_SUCCESS) return YES;
    mach_msg_return_t base=result & ~MACH_MSG_MASK;
    if (base==MACH_SEND_INVALID_DEST || base==MACH_SEND_TIMED_OUT || base==MACH_SEND_INTERRUPTED) {
        // Only the reply's MOVE_SEND_ONCE is transferred ownership. Request COPY/MAKE stay borrowed.
        message->header.msgh_local_port=MACH_PORT_NULL;mach_msg_destroy(&message->header);
    }
    return NO;
}
static BOOL axs_cachekeeper_pdf_receive(mach_port_t port,BOOL reply,AxsCacheKeeperPDFBuffer *buffer,NSDictionary **payload,audit_token_t *token,int *code) {
    memset(buffer,0,sizeof(*buffer));
    mach_msg_option_t options=MACH_RCV_MSG|MACH_RCV_TIMEOUT|MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0)|MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT);
    mach_msg_return_t result=mach_msg(&buffer->header,options,0,sizeof(*buffer),port,reply ? 2000 : 1,MACH_PORT_NULL);
    if (code) *code=result;
    if (result!=MACH_MSG_SUCCESS) {
        if ((result & ~MACH_MSG_MASK)==MACH_RCV_BODY_ERROR) axs_cachekeeper_pdf_destroy(buffer);return NO;
    }
    if (!axs_cachekeeper_pdf_decode(buffer,sizeof(*buffer),port,reply,payload,token)) {if (code) *code=EPROTO;axs_cachekeeper_pdf_destroy(buffer);return NO;}
    return YES;
}
static NSDictionary *axs_cachekeeper_pdf_status(NSString *state,NSString *stage,int code) {
    return @{@"state":state,@"stage":stage,@"errorCode":@(code),@"containerReadable":@NO};
}
static BOOL axs_cachekeeper_pdf_self(BOOL server,audit_token_t *token,AxsCacheKeeperChannelFailure *failure) {
    if (![NSBundle.mainBundle.bundleIdentifier isEqual:server ? @"com.apple.springboard" : @"com.apple.Preferences"]) return NO;
#if TARGET_OS_IPHONE
    NSInteger major=NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;if (major<16 || major>17) return NO;
#endif
    return axs_cachekeeper_channel_self_token(token,failure) && axs_cachekeeper_channel_authenticate(token,server,axs_cachekeeper_channel_now()+2,failure);
}

#if !defined(AXS_CACHEKEEPER_PDF_CLIENT)
@implementation AxsCacheKeeperPDFRoot {
    BOOL (^_validator)(void);
}
- (instancetype)initWithDescriptor:(int)descriptor path:(NSString *)path validator:(BOOL (^)(void))validator {
    self=[super init];if (self) {_descriptor=descriptor;_path=[path copy];_validator=[validator copy];}return self;
}
- (BOOL)validate {return _descriptor>=0 && _validator && _validator();}
- (void)dealloc {if (_descriptor>=0) close(_descriptor);}
@end

@implementation AxsCacheKeeperPDFBinding {
    audit_token_t _client,_server;
    NSDictionary *_identity;
    NSMutableSet *_nonces;
    double _expires;
    BOOL _invalid;
}
- (instancetype)initWithService:(NSString *)service client:(audit_token_t)client server:(audit_token_t)server request:(NSDictionary *)request now:(double)now {
    self=[super init];if (self) {
        _service=[service copy];_client=client;_server=server;_identity=[request copy];_expires=now+axs_cachekeeper_pdf_lease;
        _nonces=[NSMutableSet setWithObject:request[@"nonce"]];
    }return self;
}
- (BOOL)expired:(double)now {return _invalid || !isfinite(now) || now>=_expires;}
- (void)invalidate {_invalid=YES;[_nonces removeAllObjects];}
- (BOOL)accept:(NSDictionary *)request client:(audit_token_t)client server:(audit_token_t)server now:(double)now {
    if ([self expired:now] || !axs_cachekeeper_pdf_request_valid(request) || ![request[@"service"] isEqual:_service] ||
        memcmp(&_client,&client,sizeof(client)) || memcmp(&_server,&server,sizeof(server))) return NO;
    for (NSString *key in @[@"bundle",@"relative",@"session",@"generation"]) if (![request[key] isEqual:_identity[key]]) return NO;
    if ([_nonces containsObject:request[@"nonce"]] || _nonces.count>=512) return NO;
    [_nonces addObject:request[@"nonce"]];_expires=now+axs_cachekeeper_pdf_lease;return YES;
}
@end

@interface AxsCacheKeeperPDFTask : NSObject {
@public
    atomic_bool cancelled;
    audit_token_t client,server;
}
@property(nonatomic,strong) AxsCacheKeeperPDFBinding *binding;
@property(nonatomic,copy) NSString *bundle;
@property(nonatomic,copy) NSString *relative;
@property(nonatomic,copy) NSDictionary *snapshot;
@property(nonatomic,copy) NSString *state;
@property(atomic,strong) AxsCacheKeeperPDFInspection *engine;
@property(nonatomic,strong) AxsCacheKeeperPDFRoot *root;
@property(nonatomic,strong) dispatch_source_t exitSource;
@property(nonatomic) BOOL checking;
@property(nonatomic) BOOL resolving;
@end
@implementation AxsCacheKeeperPDFTask
- (instancetype)init {self=[super init];if (self) atomic_init(&cancelled,false);return self;}
@end
// Sole owner of post-authentication coordination. The Mach ingress below still authenticates
// every request before handing over its owned send-once right; no IPC authentication bypass.
@interface AxsCacheKeeperPDFServiceCoordinator : NSObject
@property(nonatomic,strong) dispatch_queue_t control;
@property(nonatomic,strong) dispatch_queue_t work;
@property(nonatomic,strong) AxsCacheKeeperPDFTask *task;
@property(nonatomic,strong) AxsCacheKeeperPDFTask *draining;
@property(nonatomic,copy) AxsCacheKeeperPDFRootProvider provider;
@property(nonatomic,copy) NSString *instance;
@property(nonatomic,strong) dispatch_source_t source;
@property(nonatomic,strong) dispatch_source_t timer;
@property(nonatomic,strong) NSMutableDictionary<NSArray *,NSNumber *> *recentSessions;
- (instancetype)initWithRootProvider:(AxsCacheKeeperPDFRootProvider)provider;
- (NSTimeInterval)axs_cachekeeper_now;
- (BOOL)axs_cachekeeper_identities_current:(AxsCacheKeeperPDFTask *)task;
- (AxsCacheKeeperPDFInspection *)axs_cachekeeper_engine_for_root:(AxsCacheKeeperPDFRoot *)root relative:(NSString *)relative;
- (void)axs_cachekeeper_invalidate:(AxsCacheKeeperPDFTask *)task;
- (BOOL)axs_cachekeeper_task_gate:(AxsCacheKeeperPDFTask *)task;
- (void)axs_cachekeeper_publish:(AxsCacheKeeperPDFTask *)task state:(NSString *)state snapshot:(NSDictionary *)snapshot;
- (void)axs_cachekeeper_advance:(AxsCacheKeeperPDFTask *)task;
- (void)axs_cachekeeper_probe_task:(AxsCacheKeeperPDFTask *)task;
- (NSDictionary *)axs_cachekeeper_response:(NSDictionary *)request state:(NSString *)state report:(NSDictionary *)report directory:(NSString *)directory;
- (void)axs_cachekeeper_accept_authenticated_request:(NSDictionary *)request reply:(mach_port_t)reply client:(audit_token_t)client server:(audit_token_t)server;
- (void)axs_cachekeeper_check_lifecycle;
- (void)axs_cachekeeper_start_timer;
@end
static void axs_cachekeeper_pdf_reply(mach_port_t reply,NSDictionary *response) {
    AxsCacheKeeperPDFMessage message;int code=0;
    if (axs_cachekeeper_pdf_encode(&message,response,YES,reply,MACH_PORT_NULL)) axs_cachekeeper_pdf_send(&message,&code);
    else mach_port_deallocate(mach_task_self(),reply);
}
@implementation AxsCacheKeeperPDFServiceCoordinator
- (instancetype)initWithRootProvider:(AxsCacheKeeperPDFRootProvider)provider {
    self=[super init];if (self) {
        _control=dispatch_queue_create("dev.local.cachekeeper.pdf.control",DISPATCH_QUEUE_SERIAL);
        _work=dispatch_queue_create("dev.local.cachekeeper.pdf.read",DISPATCH_QUEUE_SERIAL);
        _provider=[provider copy];_instance=NSUUID.UUID.UUIDString;_recentSessions=[NSMutableDictionary new];
    }return self;
}
- (void)dealloc {if (_timer) dispatch_source_cancel(_timer);if (_source) dispatch_source_cancel(_source);}
- (NSTimeInterval)axs_cachekeeper_now {return axs_cachekeeper_channel_now();}
- (BOOL)axs_cachekeeper_identities_current:(AxsCacheKeeperPDFTask *)task {
    AxsCacheKeeperChannelFailure failure={0};double deadline=axs_cachekeeper_channel_now()+2;
    return axs_cachekeeper_channel_authenticate(&task->client,NO,deadline,&failure) &&
        axs_cachekeeper_channel_authenticate(&task->server,YES,deadline,&failure);
}
- (AxsCacheKeeperPDFInspection *)axs_cachekeeper_engine_for_root:(AxsCacheKeeperPDFRoot *)root relative:(NSString *)relative {
    return [[AxsCacheKeeperPDFInspection alloc] initWithContainerFD:root.descriptor relativeDirectory:relative];
}
- (void)axs_cachekeeper_invalidate:(AxsCacheKeeperPDFTask *)task {
    if (!task) return;
    atomic_store(&task->cancelled,true);[task.binding invalidate];[task.engine requestCancellation];
    if (task.exitSource) {dispatch_source_cancel(task.exitSource);task.exitSource=nil;}
    if (self.task==task) {self.task=nil;self.draining=task;}
    // Never wait for a read syscall on the receive/control queue.
    dispatch_async(self.work,^{
        [task.engine cancel];task.engine=nil;task.root=nil;
        dispatch_async(self.control,^{if (self.draining==task) self.draining=nil;});
    });
}
- (BOOL)axs_cachekeeper_task_gate:(AxsCacheKeeperPDFTask *)task {
    if (atomic_load(&task->cancelled)) return NO;
    return [self axs_cachekeeper_identities_current:task] && [task.root validate] && !atomic_load(&task->cancelled);
}
- (void)axs_cachekeeper_publish:(AxsCacheKeeperPDFTask *)task state:(NSString *)state snapshot:(NSDictionary *)snapshot {
    dispatch_async(self.control,^{
        if (self.task!=task || atomic_load(&task->cancelled)) return;
        if ([task.binding expired:[self axs_cachekeeper_now]]) {[self axs_cachekeeper_invalidate:task];return;}
        task.state=state;task.snapshot=snapshot;
    });
}
- (void)axs_cachekeeper_advance:(AxsCacheKeeperPDFTask *)task {
    if (![self axs_cachekeeper_task_gate:task]) {
        [task.engine cancel];task.root=nil;
        [self axs_cachekeeper_publish:task state:@"unavailable" snapshot:axs_cachekeeper_pdf_status(@"unavailable",@"identityRecheck",ESTALE)];return;
    }
    [task.engine advance:64];
    if (![self axs_cachekeeper_task_gate:task]) {
        [task.engine cancel];task.root=nil;
        [self axs_cachekeeper_publish:task state:@"unavailable" snapshot:axs_cachekeeper_pdf_status(@"unavailable",@"identityRecheck",ESTALE)];return;
    }
    NSMutableDictionary *snapshot=[task.engine.report mutableCopy];snapshot[@"containerReadable"]=@YES;
    NSString *state=task.engine.complete ? @"finished" : @"running";snapshot[@"state"]=state;snapshot[@"stage"]=@"none";
    [self axs_cachekeeper_publish:task state:state snapshot:snapshot];
    if (!task.engine.complete) dispatch_async(self.work,^{[self axs_cachekeeper_advance:task];});
}
- (void)axs_cachekeeper_probe_task:(AxsCacheKeeperPDFTask *)task {
    if (atomic_load(&task->cancelled)) return;
    NSString *stage=@"containerResolve";int code=0;
    task.root=self.provider(task.bundle,&stage,&code);
    if (!task.root || ![self axs_cachekeeper_task_gate:task]) {
        task.root=nil;[self axs_cachekeeper_publish:task state:@"unavailable" snapshot:axs_cachekeeper_pdf_status(@"unavailable",code ? stage : @"identityRecheck",code ?: ESTALE)];return;
    }
    // Opening a fresh engine walks and opens the chosen directory but does not enumerate/read files.
    AxsCacheKeeperPDFInspection *probe=[self axs_cachekeeper_engine_for_root:task.root relative:task.relative];
    NSDictionary *result=probe.report;BOOL ready=!probe.complete && [self axs_cachekeeper_task_gate:task];[probe cancel];
    if (!ready) {task.root=nil;[self axs_cachekeeper_publish:task state:@"unavailable" snapshot:axs_cachekeeper_pdf_status(@"unavailable",@"directoryOpen",[result[@"errorCode"] intValue] ?: EACCES)];return;}
    [self axs_cachekeeper_publish:task state:@"ready" snapshot:@{@"state":@"ready",@"stage":@"directoryOpen",@"errorCode":@0,@"containerReadable":@YES}];
}
- (NSDictionary *)axs_cachekeeper_response:(NSDictionary *)request state:(NSString *)state report:(NSDictionary *)report directory:(NSString *)directory {
    return @{@"operation":request[@"operation"],@"nonce":request[@"nonce"],@"session":request[@"session"],@"generation":request[@"generation"],
        @"service":self.instance,@"state":state,@"report":report ?: @{},@"directory":directory ?: @""};
}
- (void)axs_cachekeeper_accept_authenticated_request:(NSDictionary *)request reply:(mach_port_t)reply client:(audit_token_t)client server:(audit_token_t)server {
        AxsCacheKeeperPDFTask *task=self.task;
        if (task && [task.binding expired:[self axs_cachekeeper_now]]) {[self axs_cachekeeper_invalidate:task];task=nil;}
        NSString *operation=request[@"operation"];
        if ([operation isEqual:@"probe"]) {
            if (task || self.draining) {axs_cachekeeper_pdf_reply(reply,[self axs_cachekeeper_response:request state:@"busy" report:axs_cachekeeper_pdf_status(@"busy",@"busy",EBUSY) directory:nil]);return;}
            double now=[self axs_cachekeeper_now];
            for (NSArray *key in [self.recentSessions.allKeys copy])
                if ([self.recentSessions[key] doubleValue]<=now) [self.recentSessions removeObjectForKey:key];
            NSArray *key=@[[NSData dataWithBytes:&client length:sizeof(client)],request[@"session"],request[@"generation"]];
            if (self.recentSessions[key] || self.recentSessions.count>=64) {
                axs_cachekeeper_pdf_reply(reply,[self axs_cachekeeper_response:request state:@"rejected" report:axs_cachekeeper_pdf_status(@"rejected",@"session",EALREADY) directory:nil]);return;
            }
            self.recentSessions[key]=@(now+60);
            task=[AxsCacheKeeperPDFTask new];task->client=client;task->server=server;task.bundle=request[@"bundle"];task.relative=request[@"relative"];
            task.binding=[[AxsCacheKeeperPDFBinding alloc] initWithService:self.instance client:client server:server request:request now:[self axs_cachekeeper_now]];
            task.state=@"probing";task.snapshot=axs_cachekeeper_pdf_status(@"probing",@"containerResolve",0);self.task=task;
            task.exitSource=dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC,(uintptr_t)client.val[5],DISPATCH_PROC_EXIT,self.control);
            if (task.exitSource) {__weak AxsCacheKeeperPDFTask *weak=task;__weak typeof(self) owner=self;dispatch_source_set_event_handler(task.exitSource,^{[owner axs_cachekeeper_invalidate:weak];});dispatch_resume(task.exitSource);}
            dispatch_async(self.work,^{[self axs_cachekeeper_probe_task:task];});
        } else if (!task || ![task.binding accept:request client:client server:server now:[self axs_cachekeeper_now]]) {
            axs_cachekeeper_pdf_reply(reply,[self axs_cachekeeper_response:request state:@"expired" report:axs_cachekeeper_pdf_status(@"expired",@"session",ESTALE) directory:nil]);return;
        } else if ([operation isEqual:@"cancel"]) {
            [self axs_cachekeeper_invalidate:task];axs_cachekeeper_pdf_reply(reply,[self axs_cachekeeper_response:request state:@"cancelled" report:axs_cachekeeper_pdf_status(@"cancelled",@"cancel",0) directory:nil]);return;
        } else if ([operation isEqual:@"start"]) {
            if (![task.state isEqual:@"ready"]) {axs_cachekeeper_pdf_reply(reply,[self axs_cachekeeper_response:request state:@"rejected" report:axs_cachekeeper_pdf_status(@"rejected",@"session",EINVAL) directory:nil]);return;}
            task.state=@"running";task.snapshot=axs_cachekeeper_pdf_status(@"running",@"directoryOpen",0);
            dispatch_async(self.work,^{
                if (atomic_load(&task->cancelled)) return;
                task.engine=[self axs_cachekeeper_engine_for_root:task.root relative:task.relative];
                [self axs_cachekeeper_advance:task];
            });
        } else if ([operation isEqual:@"resolve"]) {
            if (![task.state isEqual:@"finished"] || task.resolving) {axs_cachekeeper_pdf_reply(reply,[self axs_cachekeeper_response:request state:@"rejected" report:axs_cachekeeper_pdf_status(@"rejected",@"candidate",EBUSY) directory:nil]);return;}
            task.resolving=YES;
            dispatch_async(self.work,^{
                NSArray *candidates=task.engine.report[@"pdfCandidates"];NSUInteger index=[request[@"candidate"] unsignedIntegerValue];
                NSString *path=index<candidates.count ? candidates[index][@"path"] : nil;int error=0;
                BOOL valid=path && [self axs_cachekeeper_task_gate:task] && [task.engine revalidateCandidate:path containerFD:task.root.descriptor error:&error] && [self axs_cachekeeper_task_gate:task];
                NSString *directory=valid ? [task.root.path stringByAppendingPathComponent:path.stringByDeletingLastPathComponent] : nil;
                dispatch_async(self.control,^{
                    task.resolving=NO;
                    BOOL current=self.task==task && !atomic_load(&task->cancelled) && ![task.binding expired:[self axs_cachekeeper_now]];
                    axs_cachekeeper_pdf_reply(reply,[self axs_cachekeeper_response:request state:current && valid ? @"finished" : @"expired" report:
                        current && valid ? task.snapshot : axs_cachekeeper_pdf_status(@"expired",@"candidate",error ?: ESTALE) directory:current ? directory : nil]);
                });
            });return;
        }
        axs_cachekeeper_pdf_reply(reply,[self axs_cachekeeper_response:request state:task.state report:task.snapshot directory:nil]);
}
- (void)axs_cachekeeper_check_lifecycle {
    AxsCacheKeeperPDFTask *task=self.task;if (!task) return;
    if ([task.binding expired:[self axs_cachekeeper_now]]) {[self axs_cachekeeper_invalidate:task];return;}
    if (!task.checking && [@[@"ready",@"finished"] containsObject:task.state]) {
        task.checking=YES;
        dispatch_async(self.work,^{
            BOOL valid=[self axs_cachekeeper_task_gate:task];
            dispatch_async(self.control,^{task.checking=NO;if (!valid) [self axs_cachekeeper_invalidate:task];});
        });
    }
}
- (void)axs_cachekeeper_start_timer {
    if (self.timer) return;
    self.timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,self.control);
    dispatch_source_set_timer(self.timer,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),NSEC_PER_SEC/2,NSEC_PER_SEC/10);
    __weak typeof(self) weak=self;
    dispatch_source_set_event_handler(self.timer,^{[weak axs_cachekeeper_check_lifecycle];});dispatch_resume(self.timer);
}
@end
static void axs_cachekeeper_pdf_server_message(AxsCacheKeeperPDFServiceCoordinator *owner,mach_port_t port) {
    @autoreleasepool {
        AxsCacheKeeperPDFBuffer buffer;NSDictionary *request=nil;audit_token_t client,server;int code=0;
        if (!axs_cachekeeper_pdf_receive(port,NO,&buffer,&request,&client,&code)) return;
        mach_port_t reply=buffer.header.msgh_remote_port;buffer.header.msgh_remote_port=MACH_PORT_NULL;axs_cachekeeper_pdf_destroy(&buffer);
        AxsCacheKeeperChannelFailure failure={0};
        if (!axs_cachekeeper_pdf_self(YES,&server,&failure) || !axs_cachekeeper_channel_authenticate(&client,NO,axs_cachekeeper_channel_now()+2,&failure)) {
            mach_port_deallocate(mach_task_self(),reply);return;
        }
        [owner axs_cachekeeper_accept_authenticated_request:request reply:reply client:client server:server];
    }
}
void axs_cachekeeper_pdf_session_server_start(AxsCacheKeeperPDFRootProvider provider) {
    static dispatch_once_t once;dispatch_once(&once,^{
        static AxsCacheKeeperPDFServiceCoordinator *owner;
        owner=[[AxsCacheKeeperPDFServiceCoordinator alloc] initWithRootProvider:provider];
        dispatch_async(owner.control,^{
            audit_token_t token;AxsCacheKeeperChannelFailure failure={0};
            if (!provider || !axs_cachekeeper_pdf_self(YES,&token,&failure) || !bootstrap_register || !bootstrap_look_up) return;
            mach_port_t bootstrap=MACH_PORT_NULL,port=MACH_PORT_NULL,existing=MACH_PORT_NULL;BOOL ownsSend=NO;
            @try {
                kern_return_t result=task_get_bootstrap_port(mach_task_self(),&bootstrap);
                if (result==KERN_SUCCESS) {result=bootstrap_look_up(bootstrap,axs_cachekeeper_pdf_service,&existing);if (result==KERN_SUCCESS) return;if (result==1102) result=KERN_SUCCESS;}
                if (result==KERN_SUCCESS) result=mach_port_allocate(mach_task_self(),MACH_PORT_RIGHT_RECEIVE,&port);
                if (result==KERN_SUCCESS) {result=mach_port_insert_right(mach_task_self(),port,port,MACH_MSG_TYPE_MAKE_SEND);ownsSend=result==KERN_SUCCESS;}
                mach_port_limits_t limits={.mpl_qlimit=1};
                if (result==KERN_SUCCESS) result=mach_port_set_attributes(mach_task_self(),port,MACH_PORT_LIMITS_INFO,(mach_port_info_t)&limits,MACH_PORT_LIMITS_INFO_COUNT);
                if (result==KERN_SUCCESS) result=bootstrap_register(bootstrap,axs_cachekeeper_pdf_service,port);
                if (result!=KERN_SUCCESS) return;
                result=mach_port_deallocate(mach_task_self(),port);if (result!=KERN_SUCCESS) return;ownsSend=NO;
                dispatch_source_t source=dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV,port,0,owner.control);if (!source) return;
                mach_port_t owned=port;port=MACH_PORT_NULL;owner.source=source;
                dispatch_source_set_event_handler(source,^{axs_cachekeeper_pdf_server_message(owner,owned);});
                dispatch_source_set_cancel_handler(source,^{[owner axs_cachekeeper_invalidate:owner.task];axs_cachekeeper_channel_release_receive(owned,NO);});dispatch_resume(source);
                [owner axs_cachekeeper_start_timer];
            } @finally {
                if (MACH_PORT_VALID(existing)) mach_port_deallocate(mach_task_self(),existing);
                if (MACH_PORT_VALID(port)) axs_cachekeeper_channel_release_receive(port,ownsSend);
                if (MACH_PORT_VALID(bootstrap)) mach_port_deallocate(mach_task_self(),bootstrap);
            }
        });
    });
}

#endif // AXS_CACHEKEEPER_PDF_CLIENT

#if !defined(AXS_CACHEKEEPER_PDF_SERVER)
@interface AxsCacheKeeperPDFSession () {
    atomic_bool _cancelled;
    audit_token_t _client,_server;
    BOOL _bound;
    NSString *_bundle,*_relative,*_session,*_service,*_state;
    uint32_t _generation;
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
    void (^_update)(NSDictionary *);
}
- (NSDictionary *)axs_cachekeeper_exchange:(NSString *)operation candidate:(NSUInteger)candidate;
- (NSDictionary *)axs_cachekeeper_request:(NSString *)operation candidate:(NSUInteger)candidate;
- (NSDictionary *)axs_cachekeeper_accept_authenticated_reply:(NSDictionary *)response request:(NSDictionary *)request client:(audit_token_t)client server:(audit_token_t)peer;
- (void)axs_cachekeeper_deliver:(NSDictionary *)reply;
@end
static __weak AxsCacheKeeperPDFSession *axs_cachekeeper_pdf_active_client;
@implementation AxsCacheKeeperPDFSession
- (instancetype)initWithBundle:(NSString *)bundle relativeDirectory:(NSString *)relative {
    self=[super init];if (self) {
        atomic_init(&_cancelled,false);_bundle=[bundle copy];_relative=[relative copy];_session=NSUUID.UUID.UUIDString;_service=@"";_generation=arc4random_uniform(UINT32_MAX-1)+1;
        _queue=dispatch_queue_create("dev.local.cachekeeper.pdf.client",DISPATCH_QUEUE_SERIAL);
    }return self;
}
- (void)dealloc {if (_timer) dispatch_source_cancel(_timer);}
- (NSDictionary *)axs_cachekeeper_request:(NSString *)operation candidate:(NSUInteger)candidate {
    NSDictionary *request=@{@"operation":operation,@"bundle":_bundle ?: @"",@"relative":_relative ?: @"",@"session":_session,@"generation":@(_generation),
        @"nonce":NSUUID.UUID.UUIDString,@"service":_service,@"candidate":@(candidate)};
    return axs_cachekeeper_pdf_request_valid(request) ? request : nil;
}
- (NSDictionary *)axs_cachekeeper_accept_authenticated_reply:(NSDictionary *)response request:(NSDictionary *)request client:(audit_token_t)client server:(audit_token_t)peer {
    if ((_bound && (memcmp(&_client,&client,sizeof(client)) || memcmp(&_server,&peer,sizeof(peer)))) ||
        !axs_cachekeeper_pdf_reply_matches(response,request,_service))
        return @{@"state":@"unavailable",@"report":axs_cachekeeper_pdf_status(@"unavailable",@"peerIdentity",ESTALE)};
    if (!_bound) {_client=client;_server=peer;_bound=YES;_service=[response[@"service"] copy];}
    return response;
}
- (NSDictionary *)axs_cachekeeper_exchange:(NSString *)operation candidate:(NSUInteger)candidate {
    NSDictionary *request=[self axs_cachekeeper_request:operation candidate:candidate];
    if (!request) return @{@"state":@"unavailable",@"report":axs_cachekeeper_pdf_status(@"unavailable",@"input",EINVAL)};
    AxsCacheKeeperChannelFailure failure={0};audit_token_t client;
    if (!axs_cachekeeper_pdf_self(NO,&client,&failure) || (_bound && memcmp(&_client,&client,sizeof(client))))
        return @{@"state":@"unavailable",@"report":axs_cachekeeper_pdf_status(@"unavailable",@"selfIdentity",failure.code ?: EPERM)};
    mach_port_t bootstrap=MACH_PORT_NULL,service=MACH_PORT_NULL,replyPort=MACH_PORT_NULL;int code=0;
    NSString *stage=@"lookup";
    @try {
        code=task_get_bootstrap_port(mach_task_self(),&bootstrap);
        if (code==KERN_SUCCESS) code=bootstrap_look_up ? bootstrap_look_up(bootstrap,axs_cachekeeper_pdf_service,&service) : ENOSYS;
        if (code!=KERN_SUCCESS) return @{@"state":@"unavailable",@"report":axs_cachekeeper_pdf_status(@"unavailable",stage,code)};
        stage=@"receive";code=mach_port_allocate(mach_task_self(),MACH_PORT_RIGHT_RECEIVE,&replyPort);
        if (code!=KERN_SUCCESS) return @{@"state":@"unavailable",@"report":axs_cachekeeper_pdf_status(@"unavailable",stage,code)};
        AxsCacheKeeperPDFMessage message;
        stage=@"send";
        if (!axs_cachekeeper_pdf_encode(&message,request,NO,service,replyPort) || !axs_cachekeeper_pdf_send(&message,&code))
            return @{@"state":@"unavailable",@"report":axs_cachekeeper_pdf_status(@"unavailable",stage,code ?: EPROTO)};
        AxsCacheKeeperPDFBuffer buffer;NSDictionary *response=nil;audit_token_t peer;
        if (!axs_cachekeeper_pdf_receive(replyPort,YES,&buffer,&response,&peer,&code))
            return @{@"state":@"unavailable",@"report":axs_cachekeeper_pdf_status(@"unavailable",@"receive",code)};
        axs_cachekeeper_pdf_destroy(&buffer);
        audit_token_t current;
        if (!axs_cachekeeper_channel_authenticate(&peer,YES,axs_cachekeeper_channel_now()+2,&failure) ||
            !axs_cachekeeper_pdf_self(NO,&current,&failure) || memcmp(&current,&client,sizeof(client)))
            return @{@"state":@"unavailable",@"report":axs_cachekeeper_pdf_status(@"unavailable",@"peerIdentity",failure.code ?: ESTALE)};
        return [self axs_cachekeeper_accept_authenticated_reply:response request:request client:client server:peer];
    } @finally {
        if (MACH_PORT_VALID(replyPort)) axs_cachekeeper_channel_release_receive(replyPort,NO);
        if (MACH_PORT_VALID(service)) mach_port_deallocate(mach_task_self(),service);
        if (MACH_PORT_VALID(bootstrap)) mach_port_deallocate(mach_task_self(),bootstrap);
    }
}
- (void)axs_cachekeeper_deliver:(NSDictionary *)reply {
    if (atomic_load(&_cancelled)) return;
    _state=reply[@"state"];NSDictionary *snapshot=reply[@"report"] ?: @{};
    if (![@[@"probing",@"ready",@"running",@"finished"] containsObject:_state]) {
        if (_timer) {dispatch_source_cancel(_timer);_timer=nil;}
        if (_bound) [self axs_cachekeeper_exchange:@"cancel" candidate:10];
    }
    dispatch_async(dispatch_get_main_queue(),^{if (!atomic_load(&self->_cancelled) && self->_update) self->_update(snapshot);});
}
- (void)probe:(void (^)(NSDictionary *))update {
    NSAssert(NSThread.isMainThread,@"PDF UI session must be started on main");
    if (axs_cachekeeper_pdf_active_client && axs_cachekeeper_pdf_active_client!=self) {if (update) update(axs_cachekeeper_pdf_status(@"busy",@"busy",EBUSY));return;}
    if (_update || atomic_load(&_cancelled)) return;
    axs_cachekeeper_pdf_active_client=self;_update=[update copy];
    dispatch_async(_queue,^{
        [self axs_cachekeeper_deliver:[self axs_cachekeeper_exchange:@"probe" candidate:10]];
        if (atomic_load(&self->_cancelled) || ![@[@"probing",@"ready"] containsObject:self->_state]) return;
        self->_timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,self->_queue);__weak typeof(self) weak=self;
        dispatch_source_set_timer(self->_timer,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/2),NSEC_PER_SEC,NSEC_PER_SEC/10);
        dispatch_source_set_event_handler(self->_timer,^{AxsCacheKeeperPDFSession *owner=weak;if (owner && !atomic_load(&owner->_cancelled)) [owner axs_cachekeeper_deliver:[owner axs_cachekeeper_exchange:@"poll" candidate:10]];});dispatch_resume(self->_timer);
    });
}
- (void)start {dispatch_async(_queue,^{if (!atomic_load(&self->_cancelled) && [self->_state isEqual:@"ready"]) [self axs_cachekeeper_deliver:[self axs_cachekeeper_exchange:@"start" candidate:10]];});}
- (void)cancel {
    atomic_store(&_cancelled,true);
    dispatch_async(_queue,^{if (self->_timer) {dispatch_source_cancel(self->_timer);self->_timer=nil;}if (self->_bound) [self axs_cachekeeper_exchange:@"cancel" candidate:10];self->_bound=NO;});
}
- (void)resolveCandidate:(NSUInteger)index completion:(void (^)(NSString *,NSDictionary *))completion {
    dispatch_async(_queue,^{
        if (atomic_load(&self->_cancelled) || ![self->_state isEqual:@"finished"]) return;
        NSDictionary *reply=[self axs_cachekeeper_exchange:@"resolve" candidate:index];NSString *path=reply[@"directory"];
        dispatch_async(dispatch_get_main_queue(),^{if (!atomic_load(&self->_cancelled) && completion) completion(path.length ? path : nil,reply[@"report"]);});
    });
}
@end

#endif // AXS_CACHEKEEPER_PDF_SERVER
