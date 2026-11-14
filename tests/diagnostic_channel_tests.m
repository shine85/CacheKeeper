#import <Foundation/Foundation.h>
#import "../AxsCacheKeeperDiagnosticChannel.h"
#import "../AxsCacheKeeperDiagnosticChannelPrivate.h"
#import "../AxsCacheKeeperDiagnostics.h"
#include <arpa/inet.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <dispatch/dispatch.h>
#include <mach/notify.h>

static void axs_cachekeeper_channel_test_check(BOOL ok,const char *message) {
    if (!ok) { fprintf(stderr,"FAIL: diagnostic channel: %s\n",message);exit(1); }
}
static mach_port_t axs_cachekeeper_channel_test_port(BOOL send) {
    mach_port_t port=MACH_PORT_NULL;
    axs_cachekeeper_channel_test_check(mach_port_allocate(mach_task_self(),MACH_PORT_RIGHT_RECEIVE,&port)==KERN_SUCCESS,"allocate real receive right");
    if (send) axs_cachekeeper_channel_test_check(mach_port_insert_right(mach_task_self(),port,port,MACH_MSG_TYPE_MAKE_SEND)==KERN_SUCCESS,"insert real send right");
    return port;
}
static void axs_cachekeeper_channel_test_send(mach_msg_header_t *header) {
    axs_cachekeeper_channel_test_check(mach_msg(header,MACH_SEND_MSG|MACH_SEND_TIMEOUT,header->msgh_size,0,MACH_PORT_NULL,50,MACH_PORT_NULL)==MACH_MSG_SUCCESS,"real bounded Mach send");
}
static BOOL axs_cachekeeper_channel_test_has_send(mach_port_t port) {
    mach_port_type_t type=0;
    return mach_port_type(mach_task_self(),port,&type)==KERN_SUCCESS && (type&MACH_PORT_TYPE_SEND);
}
static void axs_cachekeeper_channel_test_release_receive(mach_port_t port,BOOL ownsSend) {
    axs_cachekeeper_channel_test_check(axs_cachekeeper_channel_release_receive(port,ownsSend)==KERN_SUCCESS,"release only the owned receive/send rights with SDK-supported API");
}

void axs_cachekeeper_run_diagnostic_channel_tests(void) {
    @autoreleasepool {
        mach_port_type_t releasedType=0;
        mach_port_t receiveOnly=axs_cachekeeper_channel_test_port(NO);
        axs_cachekeeper_channel_test_release_receive(receiveOnly,NO);
        axs_cachekeeper_channel_test_check(mach_port_type(mach_task_self(),receiveOnly,&releasedType)==KERN_INVALID_NAME,"receive-only teardown leaves no name or dead-name ref");
        mach_port_t receiveAndSend=axs_cachekeeper_channel_test_port(YES);
        axs_cachekeeper_channel_test_release_receive(receiveAndSend,YES);
        axs_cachekeeper_channel_test_check(mach_port_type(mach_task_self(),receiveAndSend,&releasedType)==KERN_INVALID_NAME,"failed registration teardown consumes receive plus exactly its own send ref");
        mach_port_t handedToSource=axs_cachekeeper_channel_test_port(YES);
        axs_cachekeeper_channel_test_check(mach_port_deallocate(mach_task_self(),handedToSource)==KERN_SUCCESS &&
            mach_port_type(mach_task_self(),handedToSource,&releasedType)==KERN_SUCCESS && releasedType==MACH_PORT_TYPE_RECEIVE,"successful registration drops its local send ref before source owns receive");
        axs_cachekeeper_channel_test_release_receive(handedToSource,NO);
        mach_port_t sharedName=axs_cachekeeper_channel_test_port(YES);
        axs_cachekeeper_channel_test_check(mach_port_mod_refs(mach_task_self(),sharedName,MACH_PORT_RIGHT_SEND,1)==KERN_SUCCESS,"hold an additional independently owned send reference");
        axs_cachekeeper_channel_test_release_receive(sharedName,YES);
        mach_port_urefs_t remainingDeadRefs=0;
        axs_cachekeeper_channel_test_check(mach_port_get_refs(mach_task_self(),sharedName,MACH_PORT_RIGHT_DEAD_NAME,&remainingDeadRefs)==KERN_SUCCESS && remainingDeadRefs==1,
            "teardown preserves the other owner's reference as one dead-name ref");
        axs_cachekeeper_channel_test_check(mach_port_deallocate(mach_task_self(),sharedName)==KERN_SUCCESS &&
            mach_port_type(mach_task_self(),sharedName,&releasedType)==KERN_INVALID_NAME,"other owner releases its own final reference separately");
        __block NSDictionary *publicStatus;
        dispatch_group_t group=dispatch_group_create();
        dispatch_group_async(group,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
            publicStatus=axs_cachekeeper_diagnostic_channel_hello();
        });
        axs_cachekeeper_channel_test_check(dispatch_group_wait(group,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC))==0,"real public HELLO finishes on background queue");
        axs_cachekeeper_channel_test_check([publicStatus[@"state"] isEqual:@"unavailable"] && [publicStatus[@"errorOrigin"] isEqual:@"local"] &&
            [publicStatus[@"serverRegister"] isEqual:@"notObserved"],"real CLI host rejection reports local origin without claiming remote registration");
        // An absent configuration root requires no fixture writes or host identity mocks.
        NSString *missing=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"cachekeeper-channel-absent-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        AxsCacheKeeperDiagnostics *diagnostics=[[AxsCacheKeeperDiagnostics alloc] initWithFolder:missing];
        NSDictionary *report=[diagnostics reportWithApps:@[] environment:@{@"diagnosticChannel":publicStatus}];
        axs_cachekeeper_channel_test_check([report[@"diagnosticChannel"] isEqual:publicStatus],"public HELLO status survives the real diagnostics whitelist unchanged");
        mach_port_t server=axs_cachekeeper_channel_test_port(YES),client=axs_cachekeeper_channel_test_port(NO);
        uint8_t nonce[16];memset(nonce,0x5a,sizeof(nonce));
        AxsCacheKeeperChannelMessage request;
        axs_cachekeeper_channel_encode(&request,NO,nonce,server,client,AxsCacheKeeperChannelRequest,(AxsCacheKeeperChannelFailure){0});
        axs_cachekeeper_channel_test_send(&request.header);
        AxsCacheKeeperChannelBuffer received;AxsCacheKeeperChannelDecoded decoded;AxsCacheKeeperChannelFailure failure={0};
        axs_cachekeeper_channel_test_check(axs_cachekeeper_channel_receive(server,NO,axs_cachekeeper_channel_now()+0.1,&received,&decoded,&failure),"decode real kernel-delivered HELLO and audit trailer");
        audit_token_t selfToken;
        axs_cachekeeper_channel_test_check(axs_cachekeeper_channel_self_token(&selfToken,&failure) && memcmp(&decoded.token,&selfToken,sizeof(selfToken))==0,"sender identity equals kernel self token, not inline bytes");
        axs_cachekeeper_channel_test_check(memcmp(decoded.message.nonce,nonce,sizeof(nonce))==0,"request ID roundtrip");

        // Mutate a copy of actual kernel output; the original retains sole ownership of delivered rights.
        AxsCacheKeeperChannelBuffer broken=received;
        ((AxsCacheKeeperChannelMessage *)&broken)->header.msgh_size++;
        axs_cachekeeper_channel_test_check(!axs_cachekeeper_channel_decode(&broken,sizeof(broken),server,NO,&decoded,&failure),"reject extra inline identity fields");
        broken=received;((AxsCacheKeeperChannelMessage *)&broken)->status=AxsCacheKeeperChannelAccepted;
        axs_cachekeeper_channel_test_check(!axs_cachekeeper_channel_decode(&broken,sizeof(broken),server,NO,&decoded,&failure),"request cannot self-assert authentication");
        broken=received;((AxsCacheKeeperChannelMessage *)&broken)->reserved=1;
        axs_cachekeeper_channel_test_check(!axs_cachekeeper_channel_decode(&broken,sizeof(broken),server,NO,&decoded,&failure),"reject unknown payload fields");
        broken=received;((AxsCacheKeeperChannelMessage *)&broken)->header.msgh_id++;
        axs_cachekeeper_channel_test_check(!axs_cachekeeper_channel_decode(&broken,sizeof(broken),server,NO,&decoded,&failure),"reject wrong Mach message ID");
        size_t trailerOffset=round_msg(received.header.msgh_size);
        axs_cachekeeper_channel_test_check(!axs_cachekeeper_channel_decode(&received,trailerOffset+sizeof(mach_msg_audit_trailer_t)-1,server,NO,&decoded,&failure),"reject truncated audit trailer");
        broken=received;((mach_msg_audit_trailer_t *)(broken.bytes+trailerOffset))->msgh_trailer_type=99;
        axs_cachekeeper_channel_test_check(!axs_cachekeeper_channel_decode(&broken,sizeof(broken),server,NO,&decoded,&failure),"reject wrong trailer format");
        axs_cachekeeper_channel_test_check(axs_cachekeeper_channel_decode(&received,sizeof(received),server,NO,&decoded,&failure),"valid original still decodes");

        AxsCacheKeeperChannelReplayCache replay={0};
        axs_cachekeeper_channel_test_check(axs_cachekeeper_channel_remember(&replay,&decoded,100,&failure) &&
            !axs_cachekeeper_channel_remember(&replay,&decoded,100.01,&failure) && failure.stage==AxsCacheKeeperChannelReplay,"duplicate ID from same real audit identity rejected");
        axs_cachekeeper_channel_test_check(axs_cachekeeper_channel_remember(&replay,&decoded,103,&failure),"bounded replay lease expires");
        for (NSUInteger i=1;i<AxsCacheKeeperChannelReplaySlots;i++) {
            AxsCacheKeeperChannelDecoded other=decoded;other.message.nonce[0]=(uint8_t)i;
            axs_cachekeeper_channel_test_check(axs_cachekeeper_channel_remember(&replay,&other,103,&failure),"bounded replay slots accept unique IDs");
        }
        AxsCacheKeeperChannelDecoded overflow=decoded;overflow.message.nonce[0]=0xff;
        axs_cachekeeper_channel_test_check(!axs_cachekeeper_channel_remember(&replay,&overflow,103,&failure) && failure.stage==AxsCacheKeeperChannelBusy,"full replay cache refuses instead of evicting active IDs");

        AxsCacheKeeperChannelMessage response;
        axs_cachekeeper_channel_encode(&response,YES,nonce,received.header.msgh_remote_port,MACH_PORT_NULL,AxsCacheKeeperChannelAccepted,(AxsCacheKeeperChannelFailure){0});
        received.header.msgh_remote_port=MACH_PORT_NULL;
        axs_cachekeeper_channel_destroy_received(&received);
        axs_cachekeeper_channel_test_send(&response.header);
        axs_cachekeeper_channel_test_check(axs_cachekeeper_channel_receive(client,YES,axs_cachekeeper_channel_now()+0.1,&received,&decoded,&failure) &&
            memcmp(decoded.message.nonce,nonce,16)==0 && memcmp(&decoded.token,&selfToken,sizeof(selfToken))==0,"real send-once reply carries kernel identity");
        broken=received;((AxsCacheKeeperChannelMessage *)&broken)->status=AxsCacheKeeperChannelDenied;
        ((AxsCacheKeeperChannelMessage *)&broken)->stage=AxsCacheKeeperChannelStatus;
        ((AxsCacheKeeperChannelMessage *)&broken)->domain=AxsCacheKeeperChannelPOSIXError;
        ((AxsCacheKeeperChannelMessage *)&broken)->code=INT32_MAX;
        axs_cachekeeper_channel_test_check(!axs_cachekeeper_channel_decode(&broken,sizeof(broken),client,YES,&decoded,&failure),"reply rejects arbitrary peer error numbers outside fixed system set");
        const int pathErrors[]={ELOOP,ENOTDIR};
        for (NSUInteger i=0;i<sizeof(pathErrors)/sizeof(pathErrors[0]);i++) {
            // Only mutate the fixed reply fields in real kernel output; no identity success is simulated.
            broken=received;AxsCacheKeeperChannelMessage *pathReply=(AxsCacheKeeperChannelMessage *)&broken;
            pathReply->status=AxsCacheKeeperChannelDenied;pathReply->stage=AxsCacheKeeperChannelSystemURL;
            pathReply->domain=AxsCacheKeeperChannelPOSIXError;pathReply->code=pathErrors[i];
            axs_cachekeeper_channel_test_check(axs_cachekeeper_channel_decode(&broken,sizeof(broken),client,YES,&decoded,&failure) &&
                decoded.message.stage==AxsCacheKeeperChannelSystemURL && decoded.message.domain==AxsCacheKeeperChannelPOSIXError && decoded.message.code==pathErrors[i],
                "fixed path errno reply preserves systemURL stage and original ELOOP or ENOTDIR code");
        }
        axs_cachekeeper_channel_destroy_received(&received);

        // Fill a real queue. A failed COPY_SEND / MAKE_SEND_ONCE send pseudo-copies rights back;
        // the production helper must release both without consuming the borrowed receive right.
        mach_port_t blockedServer=axs_cachekeeper_channel_test_port(YES),blockedClient=axs_cachekeeper_channel_test_port(NO);
        mach_port_limits_t limits={.mpl_qlimit=1};
        axs_cachekeeper_channel_test_check(mach_port_set_attributes(mach_task_self(),blockedServer,MACH_PORT_LIMITS_INFO,(mach_port_info_t)&limits,MACH_PORT_LIMITS_INFO_COUNT)==KERN_SUCCESS,"set real queue limit");
        axs_cachekeeper_channel_encode(&request,NO,nonce,blockedServer,blockedClient,AxsCacheKeeperChannelRequest,(AxsCacheKeeperChannelFailure){0});
        axs_cachekeeper_channel_test_send(&request.header);
        mach_port_urefs_t refsBefore=0,refsAfter=0;
        axs_cachekeeper_channel_test_check(mach_port_get_refs(mach_task_self(),blockedServer,MACH_PORT_RIGHT_SEND,&refsBefore)==KERN_SUCCESS,"read initial destination send refs");
        axs_cachekeeper_channel_encode(&request,NO,nonce,blockedServer,blockedClient,AxsCacheKeeperChannelRequest,(AxsCacheKeeperChannelFailure){0});
        axs_cachekeeper_channel_test_check(!axs_cachekeeper_channel_send(&request,axs_cachekeeper_channel_now()+0.02,&failure) &&
            (failure.code & ~MACH_MSG_MASK)==MACH_SEND_TIMED_OUT,"real full queue causes production send timeout");
        axs_cachekeeper_channel_test_check(mach_port_get_refs(mach_task_self(),blockedServer,MACH_PORT_RIGHT_SEND,&refsAfter)==KERN_SUCCESS && refsBefore==refsAfter &&
            request.header.msgh_remote_port==MACH_PORT_NULL && request.header.msgh_local_port==MACH_PORT_NULL,"failed send releases pseudo-copyout rights and preserves caller send ref");
        memset(&received,0,sizeof(received));
        axs_cachekeeper_channel_test_check(mach_msg(&received.header,MACH_RCV_MSG|MACH_RCV_TIMEOUT,0,sizeof(received),blockedClient,50,MACH_PORT_NULL)==MACH_MSG_SUCCESS &&
            received.header.msgh_id==MACH_NOTIFY_SEND_ONCE,"unused pseudo-copyout send-once right is destroyed and its kernel notification received");
        axs_cachekeeper_channel_destroy_received(&received);
        mach_port_status_t portStatus={0};mach_msg_type_number_t statusCount=MACH_PORT_RECEIVE_STATUS_COUNT;
        axs_cachekeeper_channel_test_check(mach_port_get_attributes(mach_task_self(),blockedClient,MACH_PORT_RECEIVE_STATUS,(mach_port_info_t)&portStatus,&statusCount)==KERN_SUCCESS &&
            portStatus.mps_sorights==1,"send timeout leaves exactly the queued request's send-once right");
        axs_cachekeeper_channel_test_check(axs_cachekeeper_channel_receive(blockedServer,NO,axs_cachekeeper_channel_now()+0.1,&received,&decoded,&failure),"receive original queued message after failed send cleanup");
        axs_cachekeeper_channel_destroy_received(&received);
        axs_cachekeeper_channel_test_release_receive(blockedServer,YES);axs_cachekeeper_channel_test_release_receive(blockedClient,NO);

        axs_cachekeeper_channel_encode(&request,NO,nonce,server,client,AxsCacheKeeperChannelRequest,(AxsCacheKeeperChannelFailure){0});
        axs_cachekeeper_channel_test_send(&request.header);memset(&received,0,sizeof(received));
        axs_cachekeeper_channel_test_check(mach_msg(&received.header,MACH_RCV_MSG|MACH_RCV_TIMEOUT,0,sizeof(received),server,50,MACH_PORT_NULL)==MACH_MSG_SUCCESS &&
            !axs_cachekeeper_channel_decode(&received,sizeof(received),server,NO,&decoded,&failure),"real receive without requesting audit trailer cannot authenticate");
        axs_cachekeeper_channel_destroy_received(&received);

        // A same-UID CLI process never authenticates as either platform host; no successful identity mock.
        axs_cachekeeper_channel_test_check(csops_audittoken && proc_pidpath_audittoken,"required native audit APIs must actually exist");
        char path[4096];
        axs_cachekeeper_channel_test_check(axs_cachekeeper_channel_token_path(&selfToken,path,&failure) && path[0]=='/',"real token-bound executable query");
        axs_cachekeeper_channel_test_check(!axs_cachekeeper_channel_authenticate(&selfToken,YES,axs_cachekeeper_channel_now()+1,&failure) &&
            !axs_cachekeeper_channel_authenticate(&selfToken,NO,axs_cachekeeper_channel_now()+1,&failure),"real wrong-process token rejected for both expected hosts");
        audit_token_t stale=selfToken;stale.val[7]^=0x40000000;
        uint32_t flags=0;errno=0;
        axs_cachekeeper_channel_test_check(csops_audittoken(getpid(),0,&flags,sizeof(flags),&stale)!=0 && errno==ESRCH,"real csops rejects stale process version");
        axs_cachekeeper_channel_test_check(!axs_cachekeeper_channel_token_path(&stale,path,&failure),"real pidpath rejects stale process version");

        uint8_t blob[512]={0};const char *identity="com.apple.Preferences";
        uint32_t length=(uint32_t)(8+strlen(identity)+1),network=htonl(length);memcpy(blob+4,&network,4);memcpy(blob+8,identity,strlen(identity)+1);
        axs_cachekeeper_channel_test_check(axs_cachekeeper_channel_identity_blob(blob,sizeof(blob),identity),"parse real CS_OPS_IDENTITY blob layout");
        axs_cachekeeper_channel_test_check(!axs_cachekeeper_channel_identity_blob(blob,8,identity) && !axs_cachekeeper_channel_identity_blob(blob,sizeof(blob),"com.apple.springboard"),"reject truncated and wrong signing identifier blobs");
        blob[length-1]='X';axs_cachekeeper_channel_test_check(!axs_cachekeeper_channel_identity_blob(blob,sizeof(blob),identity),"reject missing terminating NUL");

        // Wrong reply-right disposition is destroyed without consuming the receiving port.
        axs_cachekeeper_channel_encode(&request,NO,nonce,server,client,AxsCacheKeeperChannelRequest,(AxsCacheKeeperChannelFailure){0});
        request.header.msgh_bits=MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND,MACH_MSG_TYPE_MAKE_SEND);
        axs_cachekeeper_channel_test_send(&request.header);
        axs_cachekeeper_channel_test_check(!axs_cachekeeper_channel_receive(server,NO,axs_cachekeeper_channel_now()+0.1,&received,&decoded,&failure) &&
            !axs_cachekeeper_channel_test_has_send(client),"reject and release transferred ordinary reply send right");

        mach_port_t descriptorPort=axs_cachekeeper_channel_test_port(NO);
        struct { mach_msg_header_t header;mach_msg_body_t body;mach_msg_port_descriptor_t port; } complex={0};
        complex.header.msgh_bits=MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND,MACH_MSG_TYPE_MAKE_SEND_ONCE)|MACH_MSGH_BITS_COMPLEX;
        complex.header.msgh_size=sizeof(complex);complex.header.msgh_remote_port=server;complex.header.msgh_local_port=client;complex.header.msgh_id=AxsCacheKeeperChannelHelloID;
        complex.body.msgh_descriptor_count=1;complex.port.name=descriptorPort;complex.port.disposition=MACH_MSG_TYPE_MAKE_SEND;complex.port.type=MACH_MSG_PORT_DESCRIPTOR;
        axs_cachekeeper_channel_test_send(&complex.header);
        axs_cachekeeper_channel_test_check(!axs_cachekeeper_channel_receive(server,NO,axs_cachekeeper_channel_now()+0.1,&received,&decoded,&failure) &&
            !axs_cachekeeper_channel_test_has_send(descriptorPort),"complex message rejection releases descriptor rights");

        // Inject only the return code at the production result boundary. Header and descriptor
        // rights were actually delivered by Mach; this does not simulate kernel VM exhaustion.
        complex.header.msgh_bits=MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND,MACH_MSG_TYPE_MAKE_SEND_ONCE)|MACH_MSGH_BITS_COMPLEX;
        complex.header.msgh_remote_port=server;complex.header.msgh_local_port=client;
        complex.port.name=descriptorPort;complex.port.disposition=MACH_MSG_TYPE_MAKE_SEND;
        axs_cachekeeper_channel_test_send(&complex.header);memset(&received,0,sizeof(received));
        axs_cachekeeper_channel_test_check(mach_msg(&received.header,MACH_RCV_MSG|MACH_RCV_TIMEOUT,0,sizeof(received),server,50,MACH_PORT_NULL)==MACH_MSG_SUCCESS &&
            axs_cachekeeper_channel_test_has_send(descriptorPort),"real descriptor right exists before BODY_ERROR boundary injection");
        mach_msg_return_t bodyError=MACH_RCV_BODY_ERROR|MACH_MSG_VM_SPACE;
        axs_cachekeeper_channel_test_check(!axs_cachekeeper_channel_receive_result(bodyError,server,NO,axs_cachekeeper_channel_now()+0.1,&received,&decoded,&failure) &&
            failure.code==bodyError && failure.stage==AxsCacheKeeperChannelReceive && !axs_cachekeeper_channel_test_has_send(descriptorPort),
            "BODY_ERROR resource bits preserve original error and release actually delivered descriptor rights");
        mach_port_type_t destinationType=0;
        axs_cachekeeper_channel_test_check(mach_port_type(mach_task_self(),server,&destinationType)==KERN_SUCCESS && (destinationType&MACH_PORT_TYPE_RECEIVE),
            "BODY_ERROR cleanup preserves destination receive right");
        axs_cachekeeper_channel_test_release_receive(descriptorPort,NO);

        struct { mach_msg_header_t header;uint8_t payload[1024]; } oversized={0};
        oversized.header.msgh_bits=MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND,0);oversized.header.msgh_size=sizeof(oversized);oversized.header.msgh_remote_port=server;
        axs_cachekeeper_channel_test_send(&oversized.header);
        axs_cachekeeper_channel_test_check(!axs_cachekeeper_channel_receive(server,NO,axs_cachekeeper_channel_now()+0.1,&received,&decoded,&failure) && failure.code==MACH_RCV_TOO_LARGE,"oversized message discarded without allocation");
        double begin=axs_cachekeeper_channel_now();
        axs_cachekeeper_channel_test_check(!axs_cachekeeper_channel_receive(server,NO,begin+0.02,&received,&decoded,&failure) && failure.code==MACH_RCV_TIMED_OUT &&
            axs_cachekeeper_channel_now()-begin<0.5,"oversized request did not remain queued; actual short receive timeout");
        axs_cachekeeper_channel_test_check(!axs_cachekeeper_channel_receive(server,NO,axs_cachekeeper_channel_now()-1,&received,&decoded,&failure) && failure.stage==AxsCacheKeeperChannelTimeout,"expired shared deadline does not restart");
        axs_cachekeeper_channel_test_release_receive(server,YES);axs_cachekeeper_channel_test_release_receive(client,NO);
        puts("PASS: real Mach HELLO codec, audit token binding, rights cleanup, stale/wrong-process rejection and bounded timeouts (iOS hosts unverified)");
    }
}
