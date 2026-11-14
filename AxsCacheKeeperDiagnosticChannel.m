#import "AxsCacheKeeperDiagnosticChannel.h"
#import "AxsCacheKeeperDiagnosticChannelPrivate.h"
#import <objc/message.h>
#import <TargetConditionals.h>
#import <dispatch/dispatch.h>
#include <arpa/inet.h>
#include <sys/stat.h>
#include <pthread.h>
#include <errno.h>
#include <limits.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#if TARGET_OS_IPHONE && defined(THEOS_PACKAGE_SCHEME_ROOTHIDE)
#include <roothide.h>
#endif

_Static_assert(sizeof(audit_token_t)==32,"Verified iOS 16-17 audit token ABI required");
_Static_assert(sizeof(AxsCacheKeeperChannelMessage)<=AxsCacheKeeperChannelMessageLimit,"HELLO exceeds fixed protocol bound");
static char axs_cachekeeper_channel_service[128]="dev.local.cachekeeper.diagnostic.hello.v1";
static const uint32_t axs_cachekeeper_channel_required_flags=0x00000001|0x04000000|0x20000000;
// XNU16/17 cs_blobs.h: CS_VALID, CS_PLATFORM_BINARY, CS_SIGNED; codesign.h: STATUS=0, IDENTITY=11.
static BOOL axs_cachekeeper_channel_fail(AxsCacheKeeperChannelFailure *failure,AxsCacheKeeperChannelStage stage,
                                       AxsCacheKeeperChannelDomain domain,int32_t code,BOOL unexpected) {
    if (failure) *failure=(AxsCacheKeeperChannelFailure){stage,domain,code,unexpected};return NO;
}
double axs_cachekeeper_channel_now(void) { return NSProcessInfo.processInfo.systemUptime; }
static BOOL axs_cachekeeper_channel_budget(double deadline,AxsCacheKeeperChannelFailure *failure) {
    return axs_cachekeeper_channel_now()<deadline || axs_cachekeeper_channel_fail(failure,AxsCacheKeeperChannelTimeout,AxsCacheKeeperChannelPOSIXError,ETIMEDOUT,NO);
}
static mach_msg_timeout_t axs_cachekeeper_channel_timeout(double deadline) {
    return (mach_msg_timeout_t)MAX(1.0,MIN(2000.0,ceil((deadline-axs_cachekeeper_channel_now())*1000.0)));
}
void axs_cachekeeper_channel_encode(AxsCacheKeeperChannelMessage *message,BOOL reply,const uint8_t nonce[16],
                                    mach_port_t remote,mach_port_t local,AxsCacheKeeperChannelReplyStatus status,AxsCacheKeeperChannelFailure failure) {
    memset(message,0,sizeof(*message));
    message->header.msgh_bits=reply ? MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE,0) : MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND,MACH_MSG_TYPE_MAKE_SEND_ONCE);
    message->header.msgh_size=sizeof(*message);message->header.msgh_remote_port=remote;message->header.msgh_local_port=local;
    message->header.msgh_id=reply ? AxsCacheKeeperChannelReplyID : AxsCacheKeeperChannelHelloID;
    message->version=1;message->kind=reply ? 2 : 1;memcpy(message->nonce,nonce,16);
    message->status=status;message->stage=failure.stage;message->domain=failure.domain;message->code=failure.code;
}
static BOOL axs_cachekeeper_channel_reply_failure(AxsCacheKeeperChannelMessage message) {
    if (message.status==AxsCacheKeeperChannelAccepted) return !message.stage && !message.domain && !message.code;
    if (message.status==AxsCacheKeeperChannelDuplicate)
        return message.stage==AxsCacheKeeperChannelReplay && message.domain==AxsCacheKeeperChannelProtocolError && message.code==1;
    if (message.status==AxsCacheKeeperChannelOccupied)
        return message.stage==AxsCacheKeeperChannelBusy && message.domain==AxsCacheKeeperChannelPOSIXError && message.code==EBUSY;
    if (message.status!=AxsCacheKeeperChannelDenied) return NO;
    switch (message.stage) {
        case AxsCacheKeeperChannelAPI: case AxsCacheKeeperChannelSystemURL: case AxsCacheKeeperChannelStatus:
        case AxsCacheKeeperChannelSigning: case AxsCacheKeeperChannelExecutable: case AxsCacheKeeperChannelFinalStatus:
        case AxsCacheKeeperChannelTimeout: break;
        default:return NO;
    }
    if (message.domain==AxsCacheKeeperChannelProtocolError) return message.code>=1 && message.code<=3;
    if (message.domain!=AxsCacheKeeperChannelPOSIXError) return NO;
    switch (message.code) {
        case EACCES: case EPERM: case ESRCH: case EINVAL: case EIO: case ENOSYS: case ENOMEM:
        case ENOENT: case ENOTSUP: case ERANGE: case ENAMETOOLONG: case EFAULT: case ETIMEDOUT:
        case ENOTDIR: case ELOOP: case EOVERFLOW:return YES;
        default:return NO;
    }
}
BOOL axs_cachekeeper_channel_decode(const void *bytes,size_t capacity,mach_port_t local,BOOL reply,
                                    AxsCacheKeeperChannelDecoded *decoded,AxsCacheKeeperChannelFailure *failure) {
    if (failure) *failure=(AxsCacheKeeperChannelFailure){0};
    if (decoded) memset(decoded,0,sizeof(*decoded));
    if (!bytes || !decoded || capacity<sizeof(AxsCacheKeeperChannelMessage))
        return axs_cachekeeper_channel_fail(failure,AxsCacheKeeperChannelProtocol,AxsCacheKeeperChannelProtocolError,1,YES);
    AxsCacheKeeperChannelMessage message;memcpy(&message,bytes,sizeof(message));
    mach_msg_bits_t expected=reply ? MACH_MSGH_BITS(0,MACH_MSG_TYPE_PORT_SEND_ONCE) : MACH_MSGH_BITS(MACH_MSG_TYPE_PORT_SEND_ONCE,MACH_MSG_TYPE_PORT_SEND);
    if (message.header.msgh_size!=sizeof(message) || message.header.msgh_size>AxsCacheKeeperChannelMessageLimit ||
        message.header.msgh_bits!=expected || message.header.msgh_voucher_port!=MACH_PORT_NULL || message.header.msgh_local_port!=local ||
        message.header.msgh_id!=(reply ? AxsCacheKeeperChannelReplyID : AxsCacheKeeperChannelHelloID) ||
        (reply ? message.header.msgh_remote_port!=MACH_PORT_NULL : !MACH_PORT_VALID(message.header.msgh_remote_port)) ||
        message.version!=1 || message.kind!=(reply ? 2u : 1u) || message.reserved ||
        message.status>(uint32_t)AxsCacheKeeperChannelOccupied || message.stage>(uint32_t)AxsCacheKeeperChannelBusy || message.domain>(uint32_t)AxsCacheKeeperChannelProtocolError)
        return axs_cachekeeper_channel_fail(failure,AxsCacheKeeperChannelProtocol,AxsCacheKeeperChannelProtocolError,2,YES);
    if ((!reply && (message.status || message.stage || message.domain || message.code)) ||
        (reply && !axs_cachekeeper_channel_reply_failure(message)))
        return axs_cachekeeper_channel_fail(failure,AxsCacheKeeperChannelProtocol,AxsCacheKeeperChannelProtocolError,3,YES);
    uint8_t any=0;for (size_t i=0;i<16;i++) any|=message.nonce[i];
    if (!any) return axs_cachekeeper_channel_fail(failure,AxsCacheKeeperChannelProtocol,AxsCacheKeeperChannelProtocolError,4,YES);
    size_t offset=round_msg(message.header.msgh_size);
    if (offset>capacity || capacity-offset<sizeof(mach_msg_audit_trailer_t))
        return axs_cachekeeper_channel_fail(failure,AxsCacheKeeperChannelProtocol,AxsCacheKeeperChannelProtocolError,5,YES);
    mach_msg_audit_trailer_t trailer;memcpy(&trailer,(const uint8_t *)bytes+offset,sizeof(trailer));
    if (trailer.msgh_trailer_type!=MACH_MSG_TRAILER_FORMAT_0 || trailer.msgh_trailer_size!=sizeof(trailer))
        return axs_cachekeeper_channel_fail(failure,AxsCacheKeeperChannelProtocol,AxsCacheKeeperChannelProtocolError,6,YES);
    if (!reply) {
        mach_port_type_t type=0;kern_return_t kr=mach_port_type(mach_task_self(),message.header.msgh_remote_port,&type);
        if (kr!=KERN_SUCCESS || type!=MACH_PORT_TYPE_SEND_ONCE)
            return axs_cachekeeper_channel_fail(failure,AxsCacheKeeperChannelProtocol,AxsCacheKeeperChannelMachError,kr ?: KERN_INVALID_RIGHT,YES);
    }
    decoded->message=message;decoded->token=trailer.msgh_audit;return YES;
}
void axs_cachekeeper_channel_destroy_received(AxsCacheKeeperChannelBuffer *buffer) {
    // The local destination name is not a newly transferred right owned by this message.
    buffer->header.msgh_local_port=MACH_PORT_NULL;
    mach_msg_destroy(&buffer->header);memset(buffer,0,sizeof(*buffer));
}
BOOL axs_cachekeeper_channel_receive_result(mach_msg_return_t mr,mach_port_t port,BOOL reply,double deadline,
                                            AxsCacheKeeperChannelBuffer *buffer,AxsCacheKeeperChannelDecoded *decoded,AxsCacheKeeperChannelFailure *failure) {
    memset(decoded,0,sizeof(*decoded));
    if (mr!=MACH_MSG_SUCCESS) {
        // XNU mach_msg.c copies out the valid header and any delivered body resources on BODY_ERROR.
        if ((mr & ~MACH_MSG_MASK)==MACH_RCV_BODY_ERROR) axs_cachekeeper_channel_destroy_received(buffer);
        return axs_cachekeeper_channel_fail(failure,AxsCacheKeeperChannelReceive,AxsCacheKeeperChannelMachError,mr,NO);
    }
    if (!axs_cachekeeper_channel_decode(buffer,sizeof(*buffer),port,reply,decoded,failure) || !axs_cachekeeper_channel_budget(deadline,failure)) {
        axs_cachekeeper_channel_destroy_received(buffer);return NO;
    }
    return YES;
}
BOOL axs_cachekeeper_channel_receive(mach_port_t port,BOOL reply,double deadline,AxsCacheKeeperChannelBuffer *buffer,
                                     AxsCacheKeeperChannelDecoded *decoded,AxsCacheKeeperChannelFailure *failure) {
    memset(buffer,0,sizeof(*buffer));memset(decoded,0,sizeof(*decoded));
    if (!axs_cachekeeper_channel_budget(deadline,failure)) return NO;
    mach_msg_option_t options=MACH_RCV_MSG|MACH_RCV_TIMEOUT|MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0)|MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT);
    // No MACH_RCV_LARGE: an oversized message is discarded by the kernel, never reallocated or left queued.
    mach_msg_return_t mr=mach_msg(&buffer->header,options,0,sizeof(*buffer),port,axs_cachekeeper_channel_timeout(deadline),MACH_PORT_NULL);
    return axs_cachekeeper_channel_receive_result(mr,port,reply,deadline,buffer,decoded,failure);
}
BOOL axs_cachekeeper_channel_remember(AxsCacheKeeperChannelReplayCache *cache,const AxsCacheKeeperChannelDecoded *decoded,double now,AxsCacheKeeperChannelFailure *failure) {
    AxsCacheKeeperChannelReplayEntry *available=NULL;
    for (NSUInteger i=0;i<AxsCacheKeeperChannelReplaySlots;i++) {
        AxsCacheKeeperChannelReplayEntry *entry=&cache->entries[i];
        if (entry->expires<=now) { if (!available) available=entry;continue; }
        if (!memcmp(&entry->token,&decoded->token,sizeof(entry->token)) && !memcmp(entry->nonce,decoded->message.nonce,16))
            return axs_cachekeeper_channel_fail(failure,AxsCacheKeeperChannelReplay,AxsCacheKeeperChannelProtocolError,1,YES);
    }
    if (!available) return axs_cachekeeper_channel_fail(failure,AxsCacheKeeperChannelBusy,AxsCacheKeeperChannelPOSIXError,EBUSY,NO);
    available->token=decoded->token;memcpy(available->nonce,decoded->message.nonce,16);available->expires=now+2;return YES;
}
BOOL axs_cachekeeper_channel_identity_blob(const uint8_t *blob,size_t capacity,const char *expected) {
    if (!blob || !expected || capacity<9) return NO;
    uint32_t magic,length;memcpy(&magic,blob,4);memcpy(&length,blob+4,4);length=ntohl(length);
    if (magic || length<9 || length>capacity || length!=8+strlen(expected)+1) return NO;
    const uint8_t *end=memchr(blob+8,0,length-8);
    return end==blob+length-1 && !memcmp(blob+8,expected,length-8);
}
// This accessor is restricted to the XNU16/17 layout verified in kern_proc.c and libproc.c.
// Every PID lookup remains bound to the complete, unchanged kernel-provided token.
static pid_t axs_cachekeeper_channel_token_pid(const audit_token_t *token) { return (pid_t)token->val[5]; }
BOOL axs_cachekeeper_channel_self_token(audit_token_t *token,AxsCacheKeeperChannelFailure *failure) {
    memset(token,0,sizeof(*token));mach_msg_type_number_t count=sizeof(*token)/sizeof(natural_t);
    kern_return_t kr=task_info(mach_task_self(),TASK_AUDIT_TOKEN,(task_info_t)token,&count);
    if (kr!=KERN_SUCCESS || count!=sizeof(*token)/sizeof(natural_t) || axs_cachekeeper_channel_token_pid(token)!=getpid())
        return axs_cachekeeper_channel_fail(failure,AxsCacheKeeperChannelSelfToken,AxsCacheKeeperChannelMachError,kr ?: KERN_FAILURE,NO);
    return YES;
}
BOOL axs_cachekeeper_channel_token_path(audit_token_t *token,char buffer[4096],AxsCacheKeeperChannelFailure *failure) {
    if (!proc_pidpath_audittoken) return axs_cachekeeper_channel_fail(failure,AxsCacheKeeperChannelAPI,AxsCacheKeeperChannelPOSIXError,ENOSYS,NO);
    memset(buffer,0xff,4096);errno=0;int length=proc_pidpath_audittoken(token,buffer,4096);int error=errno;
    if (length<=0 || length>=4096) return axs_cachekeeper_channel_fail(failure,AxsCacheKeeperChannelExecutable,AxsCacheKeeperChannelPOSIXError,error ?: EIO,NO);
    if (buffer[length]!=0 || memchr(buffer,0,(size_t)length))
        return axs_cachekeeper_channel_fail(failure,AxsCacheKeeperChannelExecutable,AxsCacheKeeperChannelProtocolError,1,YES);
    return YES;
}
static id axs_cachekeeper_channel_property(id object,NSString *name) {
    SEL selector=NSSelectorFromString(name);return [object respondsToSelector:selector] ? ((id(*)(id,SEL))objc_msgSend)(object,selector) : nil;
}
static NSString *axs_cachekeeper_channel_canonical(NSString *path,AxsCacheKeeperChannelStage stage,AxsCacheKeeperChannelFailure *failure) {
    unichar zero=0;
    if (![path isKindOfClass:NSString.class] || !path.isAbsolutePath || [path rangeOfString:[NSString stringWithCharacters:&zero length:1]].location!=NSNotFound) {
        axs_cachekeeper_channel_fail(failure,stage,AxsCacheKeeperChannelProtocolError,1,YES);return nil;
    }
    char resolved[PATH_MAX];
    if (!realpath(path.fileSystemRepresentation,resolved)) {
        axs_cachekeeper_channel_fail(failure,stage,AxsCacheKeeperChannelPOSIXError,errno,NO);return nil;
    }
    NSString *result=[NSString stringWithUTF8String:resolved];
    if (!result) axs_cachekeeper_channel_fail(failure,stage,AxsCacheKeeperChannelProtocolError,1,YES);
    return result;
}
static NSString *axs_cachekeeper_channel_system_base(NSString *logical,AxsCacheKeeperChannelFailure *failure) {
#if TARGET_OS_IPHONE && defined(THEOS_PACKAGE_SCHEME_ROOTHIDE)
    // Convert only this trusted system anchor once, never a client path or guessed jailbreak prefix.
    logical=rootfs(logical);
#endif
    return axs_cachekeeper_channel_canonical(logical,AxsCacheKeeperChannelSystemURL,failure);
}
static NSString *axs_cachekeeper_channel_system_executable(BOOL springBoard,struct stat *identity,AxsCacheKeeperChannelFailure *failure) {
    NSString *bundle=springBoard ? @"com.apple.springboard" : @"com.apple.Preferences";
    Class proxyClass=NSClassFromString(@"LSApplicationProxy");SEL lookup=NSSelectorFromString(@"applicationProxyForIdentifier:");
    id proxy=[proxyClass respondsToSelector:lookup] ? ((id(*)(id,SEL,id))objc_msgSend)(proxyClass,lookup,bundle) : nil;
    NSURL *url=axs_cachekeeper_channel_property(proxy,@"bundleURL");
    if (![axs_cachekeeper_channel_property(proxy,@"applicationIdentifier") isEqual:bundle] ||
        ![axs_cachekeeper_channel_property(proxy,@"applicationType") isEqual:@"System"] || ![url isKindOfClass:NSURL.class] || !url.isFileURL) {
        axs_cachekeeper_channel_fail(failure,AxsCacheKeeperChannelSystemURL,AxsCacheKeeperChannelProtocolError,1,YES);return nil;
    }
    NSString *root=axs_cachekeeper_channel_canonical(url.path,AxsCacheKeeperChannelSystemURL,failure);if (!root) return nil;
    NSString *base=axs_cachekeeper_channel_system_base(springBoard ? @"/System/Library/CoreServices" : @"/Applications",failure);if (!base) return nil;
    struct stat rootStat;
    if (lstat(root.fileSystemRepresentation,&rootStat)) {
        axs_cachekeeper_channel_fail(failure,AxsCacheKeeperChannelSystemURL,AxsCacheKeeperChannelPOSIXError,errno,NO);return nil;
    }
    if (![root.stringByDeletingLastPathComponent isEqual:base] || ![root.pathExtension isEqual:@"app"] || !S_ISDIR(rootStat.st_mode) || rootStat.st_uid!=0) {
        axs_cachekeeper_channel_fail(failure,AxsCacheKeeperChannelSystemURL,AxsCacheKeeperChannelProtocolError,2,YES);return nil;
    }
    NSBundle *systemBundle=[NSBundle bundleWithPath:root];NSURL *executable=systemBundle.executableURL;
    if (![systemBundle.bundleIdentifier isEqual:bundle] || ![executable isKindOfClass:NSURL.class] || !executable.isFileURL) {
        axs_cachekeeper_channel_fail(failure,AxsCacheKeeperChannelSystemURL,AxsCacheKeeperChannelProtocolError,3,YES);return nil;
    }
    NSString *path=axs_cachekeeper_channel_canonical(executable.path,AxsCacheKeeperChannelSystemURL,failure);if (!path) return nil;
    struct stat raw;
    if (lstat(executable.path.fileSystemRepresentation,&raw) || stat(path.fileSystemRepresentation,identity)) {
        axs_cachekeeper_channel_fail(failure,AxsCacheKeeperChannelSystemURL,AxsCacheKeeperChannelPOSIXError,errno,NO);return nil;
    }
    if (![path.stringByDeletingLastPathComponent isEqual:root] || !S_ISREG(raw.st_mode) || raw.st_uid!=0 || identity->st_dev!=raw.st_dev || identity->st_ino!=raw.st_ino) {
        axs_cachekeeper_channel_fail(failure,AxsCacheKeeperChannelSystemURL,AxsCacheKeeperChannelProtocolError,3,YES);return nil;
    }
    return path;
}
BOOL axs_cachekeeper_channel_authenticate(const audit_token_t *receivedToken,BOOL springBoard,double deadline,AxsCacheKeeperChannelFailure *failure) {
    if (failure) *failure=(AxsCacheKeeperChannelFailure){0};
    if (!receivedToken || !axs_cachekeeper_channel_budget(deadline,failure)) return NO;
    audit_token_t token=*receivedToken;pid_t pid=axs_cachekeeper_channel_token_pid(&token);
    if (pid<=0 || !token.val[7]) return axs_cachekeeper_channel_fail(failure,AxsCacheKeeperChannelStatus,AxsCacheKeeperChannelProtocolError,1,YES);
    if (!csops_audittoken || !proc_pidpath_audittoken) return axs_cachekeeper_channel_fail(failure,AxsCacheKeeperChannelAPI,AxsCacheKeeperChannelPOSIXError,ENOSYS,NO);
    uint32_t initial=0;errno=0;
    if (csops_audittoken(pid,0,&initial,sizeof(initial),&token)) return axs_cachekeeper_channel_fail(failure,AxsCacheKeeperChannelStatus,AxsCacheKeeperChannelPOSIXError,errno ?: EIO,NO);
    if ((initial&axs_cachekeeper_channel_required_flags)!=axs_cachekeeper_channel_required_flags)
        return axs_cachekeeper_channel_fail(failure,AxsCacheKeeperChannelStatus,AxsCacheKeeperChannelProtocolError,2,YES);
    if (!axs_cachekeeper_channel_budget(deadline,failure)) return NO;
    uint8_t identity[512]={0};errno=0;
    if (csops_audittoken(pid,11,identity,sizeof(identity),&token)) return axs_cachekeeper_channel_fail(failure,AxsCacheKeeperChannelSigning,AxsCacheKeeperChannelPOSIXError,errno ?: EIO,NO);
    const char *expected=springBoard ? "com.apple.springboard" : "com.apple.Preferences";
    if (!axs_cachekeeper_channel_identity_blob(identity,sizeof(identity),expected))
        return axs_cachekeeper_channel_fail(failure,AxsCacheKeeperChannelSigning,AxsCacheKeeperChannelProtocolError,1,YES);
    if (!axs_cachekeeper_channel_budget(deadline,failure)) return NO;
    struct stat before;NSString *systemPath=axs_cachekeeper_channel_system_executable(springBoard,&before,failure);if (!systemPath) return NO;
    if (!axs_cachekeeper_channel_budget(deadline,failure)) return NO;
    char executable[4096];if (!axs_cachekeeper_channel_token_path(&token,executable,failure)) return NO;
    NSString *actual=axs_cachekeeper_channel_canonical([NSString stringWithUTF8String:executable],AxsCacheKeeperChannelExecutable,failure);if (!actual) return NO;
    if (![actual isEqual:systemPath]) return axs_cachekeeper_channel_fail(failure,AxsCacheKeeperChannelExecutable,AxsCacheKeeperChannelProtocolError,2,YES);
    if (!axs_cachekeeper_channel_budget(deadline,failure)) return NO;
    struct stat after;
    if (stat(systemPath.fileSystemRepresentation,&after)) return axs_cachekeeper_channel_fail(failure,AxsCacheKeeperChannelExecutable,AxsCacheKeeperChannelPOSIXError,errno,NO);
    if (before.st_dev!=after.st_dev || before.st_ino!=after.st_ino || before.st_size!=after.st_size ||
        before.st_mtimespec.tv_sec!=after.st_mtimespec.tv_sec || before.st_mtimespec.tv_nsec!=after.st_mtimespec.tv_nsec ||
        before.st_ctimespec.tv_sec!=after.st_ctimespec.tv_sec || before.st_ctimespec.tv_nsec!=after.st_ctimespec.tv_nsec)
        return axs_cachekeeper_channel_fail(failure,AxsCacheKeeperChannelExecutable,AxsCacheKeeperChannelProtocolError,3,YES);
    uint32_t final=0;errno=0;
    if (csops_audittoken(pid,0,&final,sizeof(final),&token)) return axs_cachekeeper_channel_fail(failure,AxsCacheKeeperChannelFinalStatus,AxsCacheKeeperChannelPOSIXError,errno ?: EIO,NO);
    if (final!=initial || (final&axs_cachekeeper_channel_required_flags)!=axs_cachekeeper_channel_required_flags)
        return axs_cachekeeper_channel_fail(failure,AxsCacheKeeperChannelFinalStatus,AxsCacheKeeperChannelProtocolError,1,YES);
    return axs_cachekeeper_channel_budget(deadline,failure);
}
static BOOL axs_cachekeeper_channel_self(BOOL springBoard,double deadline,AxsCacheKeeperChannelFailure *failure) {
#if TARGET_OS_IPHONE
    NSInteger major=NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
    if (major<16 || major>17) return axs_cachekeeper_channel_fail(failure,AxsCacheKeeperChannelHost,AxsCacheKeeperChannelPOSIXError,ENOTSUP,NO);
#endif
    NSString *bundle=springBoard ? @"com.apple.springboard" : @"com.apple.Preferences";
    if (![NSBundle.mainBundle.bundleIdentifier isEqual:bundle]) return axs_cachekeeper_channel_fail(failure,AxsCacheKeeperChannelHost,AxsCacheKeeperChannelProtocolError,1,YES);
    audit_token_t token;
    return axs_cachekeeper_channel_self_token(&token,failure) && axs_cachekeeper_channel_authenticate(&token,springBoard,deadline,failure);
}
static NSDictionary *axs_cachekeeper_channel_result(NSString *state,AxsCacheKeeperChannelFailure failure,NSString *selfIdentity,NSString *peerIdentity,NSString *registration) {
    NSArray *stages=@[@"none",@"host",@"selfToken",@"api",@"systemURL",@"status",@"signingIdentity",@"executable",@"finalStatus",@"register",@"lookup",@"send",@"receive",@"protocol",@"replay",@"timeout",@"busy"];
    NSArray *domains=@[@"none",@"mach",@"posix",@"protocol"];
    return @{@"protocolVersion":@1,@"state":state,@"stage":stages[failure.stage],@"errorDomain":domains[failure.domain],@"errorCode":@(failure.code),
        @"errorOrigin":failure.domain ? (failure.peer ? @"peer" : @"local") : @"none",
        @"selfIdentity":selfIdentity,@"peerIdentity":peerIdentity,@"serverRegister":registration};
}
static void axs_cachekeeper_channel_consume_unsent(AxsCacheKeeperChannelMessage *message) {
    // XNU libsyscall's consume_unsent_message: pseudo-copyout does not swap the header ports,
    // and mach_msg_destroy itself omits local_port. COPY/MAKE inputs remain borrowed.
    mach_msg_type_name_t type=MACH_MSGH_BITS_LOCAL(message->header.msgh_bits);
    if (MACH_PORT_VALID(message->header.msgh_local_port) && (type==MACH_MSG_TYPE_MOVE_SEND || type==MACH_MSG_TYPE_MOVE_SEND_ONCE))
        mach_port_deallocate(mach_task_self(),message->header.msgh_local_port);
    message->header.msgh_local_port=MACH_PORT_NULL;
    mach_msg_destroy(&message->header);memset(message,0,sizeof(*message));
}
BOOL axs_cachekeeper_channel_send(AxsCacheKeeperChannelMessage *message,double deadline,AxsCacheKeeperChannelFailure *failure) {
    if (!axs_cachekeeper_channel_budget(deadline,failure)) { axs_cachekeeper_channel_consume_unsent(message);return NO; }
    mach_msg_return_t mr=mach_msg(&message->header,MACH_SEND_MSG|MACH_SEND_TIMEOUT,message->header.msgh_size,0,MACH_PORT_NULL,axs_cachekeeper_channel_timeout(deadline),MACH_PORT_NULL);
    if (mr!=MACH_MSG_SUCCESS) {
        // Match libsyscall recoverable_send_error; other errors may have partially destroyed rights.
        mach_msg_return_t base=mr & ~MACH_MSG_MASK;
        if (base==MACH_SEND_INVALID_DEST || base==MACH_SEND_TIMED_OUT || base==MACH_SEND_INTERRUPTED)
            axs_cachekeeper_channel_consume_unsent(message);
        return axs_cachekeeper_channel_fail(failure,AxsCacheKeeperChannelSend,AxsCacheKeeperChannelMachError,mr,NO);
    }
    return YES;
}
static pthread_mutex_t axs_cachekeeper_channel_client_lock=PTHREAD_MUTEX_INITIALIZER;
NSDictionary *axs_cachekeeper_diagnostic_channel_hello(void) {
    AxsCacheKeeperChannelFailure failure={0};
    if (NSThread.isMainThread) {
        axs_cachekeeper_channel_fail(&failure,AxsCacheKeeperChannelHost,AxsCacheKeeperChannelPOSIXError,EWOULDBLOCK,NO);
        return axs_cachekeeper_channel_result(@"unavailable",failure,@"notObserved",@"notObserved",@"notObserved");
    }
    if (pthread_mutex_trylock(&axs_cachekeeper_channel_client_lock)) {
        axs_cachekeeper_channel_fail(&failure,AxsCacheKeeperChannelBusy,AxsCacheKeeperChannelPOSIXError,EBUSY,NO);
        return axs_cachekeeper_channel_result(@"busy",failure,@"notObserved",@"notObserved",@"notObserved");
    }
    mach_port_t bootstrap=MACH_PORT_NULL,service=MACH_PORT_NULL,replyPort=MACH_PORT_NULL;
    NSString *selfState=@"notObserved";double deadline=axs_cachekeeper_channel_now()+2;
    @try {
        if (!axs_cachekeeper_channel_self(NO,deadline,&failure))
            return axs_cachekeeper_channel_result(@"unavailable",failure,failure.unexpected ? @"unexpected" : @"unavailable",@"notObserved",@"notObserved");
        selfState=@"verified";
        if (!bootstrap_look_up) { axs_cachekeeper_channel_fail(&failure,AxsCacheKeeperChannelAPI,AxsCacheKeeperChannelPOSIXError,ENOSYS,NO);return axs_cachekeeper_channel_result(@"unavailable",failure,selfState,@"notObserved",@"notObserved"); }
        kern_return_t kr=task_get_bootstrap_port(mach_task_self(),&bootstrap);
        if (kr==KERN_SUCCESS) kr=bootstrap_look_up(bootstrap,axs_cachekeeper_channel_service,&service);
        if (kr!=KERN_SUCCESS) { axs_cachekeeper_channel_fail(&failure,AxsCacheKeeperChannelLookup,AxsCacheKeeperChannelMachError,kr,NO);return axs_cachekeeper_channel_result(@"unavailable",failure,selfState,@"notObserved",@"notObserved"); }
        if (!axs_cachekeeper_channel_budget(deadline,&failure)) return axs_cachekeeper_channel_result(@"unavailable",failure,selfState,@"notObserved",@"notObserved");
        kr=mach_port_allocate(mach_task_self(),MACH_PORT_RIGHT_RECEIVE,&replyPort);
        if (kr!=KERN_SUCCESS) { axs_cachekeeper_channel_fail(&failure,AxsCacheKeeperChannelReceive,AxsCacheKeeperChannelMachError,kr,NO);return axs_cachekeeper_channel_result(@"unavailable",failure,selfState,@"notObserved",@"notObserved"); }
        uint8_t nonce[16];arc4random_buf(nonce,sizeof(nonce));
        AxsCacheKeeperChannelMessage request;axs_cachekeeper_channel_encode(&request,NO,nonce,service,replyPort,AxsCacheKeeperChannelRequest,(AxsCacheKeeperChannelFailure){0});
        if (!axs_cachekeeper_channel_send(&request,deadline,&failure)) return axs_cachekeeper_channel_result(@"unavailable",failure,selfState,@"notObserved",@"notObserved");
        AxsCacheKeeperChannelBuffer buffer;AxsCacheKeeperChannelDecoded response;
        if (!axs_cachekeeper_channel_receive(replyPort,YES,deadline,&buffer,&response,&failure)) return axs_cachekeeper_channel_result(@"unavailable",failure,selfState,@"notObserved",@"notObserved");
        axs_cachekeeper_channel_destroy_received(&buffer);
        if (!axs_cachekeeper_channel_authenticate(&response.token,YES,deadline,&failure))
            return axs_cachekeeper_channel_result(@"rejected",failure,selfState,failure.unexpected ? @"unexpected" : @"unavailable",@"notObserved");
        if (memcmp(response.message.nonce,nonce,16)) { axs_cachekeeper_channel_fail(&failure,AxsCacheKeeperChannelProtocol,AxsCacheKeeperChannelProtocolError,7,YES);return axs_cachekeeper_channel_result(@"rejected",failure,selfState,@"verified",@"verified"); }
        if (!axs_cachekeeper_channel_self(NO,deadline,&failure))
            return axs_cachekeeper_channel_result(@"unavailable",failure,failure.unexpected ? @"unexpected" : @"unavailable",@"verified",@"verified");
        if (response.message.status==AxsCacheKeeperChannelAccepted) return axs_cachekeeper_channel_result(@"verified",(AxsCacheKeeperChannelFailure){0},selfState,@"verified",@"verified");
        failure=(AxsCacheKeeperChannelFailure){response.message.stage,response.message.domain,response.message.code,YES,YES};
        return axs_cachekeeper_channel_result(response.message.status==AxsCacheKeeperChannelOccupied ? @"busy" : @"rejected",failure,selfState,@"verified",@"verified");
    } @finally {
        if (MACH_PORT_VALID(replyPort)) mach_port_destroy(mach_task_self(),replyPort);
        if (MACH_PORT_VALID(service)) mach_port_deallocate(mach_task_self(),service);
        if (MACH_PORT_VALID(bootstrap)) mach_port_deallocate(mach_task_self(),bootstrap);
        pthread_mutex_unlock(&axs_cachekeeper_channel_client_lock);
    }
}

static NSDictionary *axs_cachekeeper_channel_server_state;
static dispatch_source_t axs_cachekeeper_channel_server_source;
static AxsCacheKeeperChannelReplayCache axs_cachekeeper_channel_server_replay;
static void axs_cachekeeper_channel_server_message(mach_port_t port) {
    @autoreleasepool {
        double deadline=axs_cachekeeper_channel_now()+2;
        AxsCacheKeeperChannelFailure failure={0};AxsCacheKeeperChannelBuffer buffer;AxsCacheKeeperChannelDecoded request;
        if (!axs_cachekeeper_channel_receive(port,NO,MIN(deadline,axs_cachekeeper_channel_now()+0.01),&buffer,&request,&failure)) return;
        mach_port_t reply=buffer.header.msgh_remote_port;buffer.header.msgh_remote_port=MACH_PORT_NULL;axs_cachekeeper_channel_destroy_received(&buffer);
        if (!axs_cachekeeper_channel_self(YES,deadline,&failure)) {
            axs_cachekeeper_channel_server_state=axs_cachekeeper_channel_result(@"unavailable",failure,failure.unexpected ? @"unexpected" : @"unavailable",@"notObserved",@"verified");
            mach_port_deallocate(mach_task_self(),reply);return;
        }
        AxsCacheKeeperChannelReplyStatus status=AxsCacheKeeperChannelAccepted;
        if (!axs_cachekeeper_channel_authenticate(&request.token,NO,deadline,&failure)) status=AxsCacheKeeperChannelDenied;
        else if (!axs_cachekeeper_channel_remember(&axs_cachekeeper_channel_server_replay,&request,axs_cachekeeper_channel_now(),&failure))
            status=failure.stage==AxsCacheKeeperChannelReplay ? AxsCacheKeeperChannelDuplicate : AxsCacheKeeperChannelOccupied;
        AxsCacheKeeperChannelMessage response;axs_cachekeeper_channel_encode(&response,YES,request.message.nonce,reply,MACH_PORT_NULL,status,failure);
        axs_cachekeeper_channel_send(&response,deadline,&failure);
    }
}
static NSDictionary *axs_cachekeeper_channel_register(dispatch_queue_t queue) {
    AxsCacheKeeperChannelFailure failure={0};double deadline=axs_cachekeeper_channel_now()+2;
    if (!axs_cachekeeper_channel_self(YES,deadline,&failure))
        return axs_cachekeeper_channel_result(@"unavailable",failure,failure.unexpected ? @"unexpected" : @"unavailable",@"notObserved",@"notObserved");
    if (!bootstrap_register || !bootstrap_look_up) { axs_cachekeeper_channel_fail(&failure,AxsCacheKeeperChannelAPI,AxsCacheKeeperChannelPOSIXError,ENOSYS,NO);return axs_cachekeeper_channel_result(@"unavailable",failure,@"verified",@"notObserved",@"notObserved"); }
    mach_port_t bootstrap=MACH_PORT_NULL,port=MACH_PORT_NULL,existing=MACH_PORT_NULL;
    @try {
        kern_return_t kr=task_get_bootstrap_port(mach_task_self(),&bootstrap);
        if (kr==KERN_SUCCESS) {
            kr=bootstrap_look_up(bootstrap,axs_cachekeeper_channel_service,&existing);
            if (kr==KERN_SUCCESS) kr=1101; // BOOTSTRAP_NAME_IN_USE: never replace a registered service.
            else if (kr==1102) kr=KERN_SUCCESS; // BOOTSTRAP_UNKNOWN_SERVICE from the verified launchd header.
        }
        if (kr!=KERN_SUCCESS) { axs_cachekeeper_channel_fail(&failure,AxsCacheKeeperChannelRegister,AxsCacheKeeperChannelMachError,kr,NO);return axs_cachekeeper_channel_result(@"unavailable",failure,@"verified",@"notObserved",@"failed"); }
        if (!axs_cachekeeper_channel_budget(deadline,&failure)) return axs_cachekeeper_channel_result(@"unavailable",failure,@"verified",@"notObserved",@"notObserved");
        kr=mach_port_allocate(mach_task_self(),MACH_PORT_RIGHT_RECEIVE,&port);
        if (kr==KERN_SUCCESS) kr=mach_port_insert_right(mach_task_self(),port,port,MACH_MSG_TYPE_MAKE_SEND);
        mach_port_limits_t limits={.mpl_qlimit=1};
        if (kr==KERN_SUCCESS) kr=mach_port_set_attributes(mach_task_self(),port,MACH_PORT_LIMITS_INFO,(mach_port_info_t)&limits,MACH_PORT_LIMITS_INFO_COUNT);
        if (kr==KERN_SUCCESS) kr=bootstrap_register(bootstrap,axs_cachekeeper_channel_service,port);
        if (kr!=KERN_SUCCESS) { axs_cachekeeper_channel_fail(&failure,AxsCacheKeeperChannelRegister,AxsCacheKeeperChannelMachError,kr,NO);return axs_cachekeeper_channel_result(@"unavailable",failure,@"verified",@"notObserved",@"failed"); }
        if (!axs_cachekeeper_channel_budget(deadline,&failure)) return axs_cachekeeper_channel_result(@"unavailable",failure,@"verified",@"notObserved",@"verified");
        dispatch_source_t source=dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV,port,0,queue);
        if (!source) { axs_cachekeeper_channel_fail(&failure,AxsCacheKeeperChannelRegister,AxsCacheKeeperChannelPOSIXError,ENOMEM,NO);return axs_cachekeeper_channel_result(@"unavailable",failure,@"verified",@"notObserved",@"verified"); }
        mach_port_t ownedPort=port;dispatch_source_set_event_handler(source,^{axs_cachekeeper_channel_server_message(ownedPort);});
        dispatch_source_set_cancel_handler(source,^{mach_port_destroy(mach_task_self(),ownedPort);});
        mach_port_deallocate(mach_task_self(),port);port=MACH_PORT_NULL;
        axs_cachekeeper_channel_server_source=source;dispatch_resume(source);
        return axs_cachekeeper_channel_result(@"listening",(AxsCacheKeeperChannelFailure){AxsCacheKeeperChannelRegister,0,0,NO},@"verified",@"notObserved",@"verified");
    } @finally {
        if (MACH_PORT_VALID(existing)) mach_port_deallocate(mach_task_self(),existing);
        if (MACH_PORT_VALID(port)) mach_port_destroy(mach_task_self(),port);
        if (MACH_PORT_VALID(bootstrap)) mach_port_deallocate(mach_task_self(),bootstrap);
    }
}
void axs_cachekeeper_diagnostic_channel_start(void (^completion)(NSDictionary *status)) {
    static dispatch_queue_t queue;static dispatch_once_t once;static BOOL attempted;
    dispatch_once(&once,^{queue=dispatch_queue_create("dev.local.cachekeeper.diagnostic.hello",DISPATCH_QUEUE_SERIAL);});
    dispatch_async(queue,^{ @autoreleasepool {
        if (!attempted) { attempted=YES;axs_cachekeeper_channel_server_state=axs_cachekeeper_channel_register(queue); }
        if (completion) completion(axs_cachekeeper_channel_server_state);
    }});
}
