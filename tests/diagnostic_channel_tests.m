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
#include <sys/stat.h>
#include <limits.h>
#include <stdlib.h>

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

static void axs_cachekeeper_channel_test_production_path_selection(NSString *folder) {
    NSFileManager *fm=NSFileManager.defaultManager;NSError *error=nil;
    for (NSNumber *host in @[@NO,@YES]) {
        BOOL springBoard=host.boolValue;
        NSString *name=springBoard ? @"SpringBoard" : @"Preferences";
        NSString *anchor=springBoard ? @"/System/Library/CoreServices" : @"/Applications";
        NSURL *lsURL=[NSURL fileURLWithPath:[anchor stringByAppendingPathComponent:[name stringByAppendingString:@".app"]]];
        NSString *base=[folder stringByAppendingPathComponent:name];
        NSString *root=[base stringByAppendingPathComponent:[name stringByAppendingString:@".app"]];
        NSString *contents=[root stringByAppendingPathComponent:@"Contents"];
        NSString *executables=[contents stringByAppendingPathComponent:@"MacOS"];
        axs_cachekeeper_channel_test_check([fm createDirectoryAtPath:executables withIntermediateDirectories:YES attributes:nil error:&error],"create a real native bundle fixture for production path entrypoints");
        NSDictionary *info=@{@"CFBundleIdentifier":springBoard ? @"com.apple.springboard" : @"com.apple.Preferences",
            @"CFBundleExecutable":name,@"CFBundlePackageType":@"APPL"};
        NSString *file=[executables stringByAppendingPathComponent:name];
        axs_cachekeeper_channel_test_check([info writeToFile:[contents stringByAppendingPathComponent:@"Info.plist"] atomically:YES] &&
            [fm copyItemAtPath:@"/usr/bin/true" toPath:file error:&error],"use real NSBundle metadata and an actual executable file without loading it");
        AxsCacheKeeperChannelFailure failure={0};audit_token_t nativeToken;char kernelBytes[4096];
        axs_cachekeeper_channel_test_check(axs_cachekeeper_channel_self_token(&nativeToken,&failure) &&
            axs_cachekeeper_channel_token_path(&nativeToken,kernelBytes,&failure),"obtain the fixture runner's real token-bound kernel path without an identity mock");
        NSString *kernelPath=[NSString stringWithUTF8String:kernelBytes];
        NSMutableDictionary<NSString *,NSNumber *> *calls=[NSMutableDictionary new];
        NSDictionary *mapping=@{lsURL.path:root,anchor:base,kernelPath:file};
        NSString *(^map)(NSString *)=^NSString *(NSString *logical) {
            calls[logical]=@([calls[logical] unsignedIntegerValue]+1);
            NSString *mapped=mapping[logical];if (!mapped) errno=ENOENT;return mapped;
        };
        NSString *resolvedRoot=nil,*resolvedBase=nil;
        // These are the exact three semantic entrypoints used by system_executable/authenticate.
        // The test never supplies a RootFilesystem/ResolvedBundle source selection.
        axs_cachekeeper_channel_test_check(axs_cachekeeper_channel_system_roots(springBoard,lsURL,map,&resolvedRoot,&resolvedBase,&failure),"production LS and fixed system-anchor combination resolves through the mapper");
        NSBundle *bundle=[NSBundle bundleWithPath:resolvedRoot];
        axs_cachekeeper_channel_test_check([bundle.bundleIdentifier isEqual:info[@"CFBundleIdentifier"]],"read metadata from the real fixture NSBundle");
        NSString *executable=axs_cachekeeper_channel_bundle_executable(bundle,map,&failure);
        axs_cachekeeper_channel_test_check(executable && calls.count==2 && [calls[lsURL.path] unsignedIntegerValue]==1 &&
            [calls[anchor] unsignedIntegerValue]==1,"production NSBundle entrypoint preserves the mapped namespace with zero extra conversions");
        axs_cachekeeper_channel_test_check(axs_cachekeeper_channel_kernel_matches(executable,kernelPath,map,&failure) && calls.count==3 &&
            [calls[lsURL.path] unsignedIntegerValue]==1 && [calls[anchor] unsignedIntegerValue]==1 && [calls[kernelPath] unsignedIntegerValue]==1,
            "production kernel comparison converts exactly once and agrees with the NSBundle executable");
        char canonicalFile[PATH_MAX],canonicalRoot[PATH_MAX],canonicalBase[PATH_MAX];
        axs_cachekeeper_channel_test_check(realpath(file.fileSystemRepresentation,canonicalFile) && realpath(root.fileSystemRepresentation,canonicalRoot) &&
            realpath(base.fileSystemRepresentation,canonicalBase) && [executable isEqual:[NSString stringWithUTF8String:canonicalFile]] &&
            [resolvedRoot isEqual:[NSString stringWithUTF8String:canonicalRoot]] && [resolvedBase isEqual:[NSString stringWithUTF8String:canonicalBase]],
            "all production path outputs identify the real files rather than merely matching mapper call counts");
        NSString *(^wrongKernel)(NSString *)=^NSString *(NSString *logical) {return [logical isEqual:kernelPath] ? @"/usr/bin/true" : nil;};
        axs_cachekeeper_channel_test_check(!axs_cachekeeper_channel_kernel_matches(executable,kernelPath,wrongKernel,&failure) &&
            failure.pathStage==AxsCacheKeeperChannelPathKernel && failure.domain==AxsCacheKeeperChannelProtocolError && failure.code==2,
            "a real different kernel executable remains rejected after namespace conversion");
    }
}

static void axs_cachekeeper_channel_test_system_paths(void) {
    AxsCacheKeeperChannelFailure failure={0};
    NSURL *url=[NSURL fileURLWithPath:@"/Applications/Preferences.app"];
    axs_cachekeeper_channel_test_check(axs_cachekeeper_channel_validate_system_record(NO,@"com.apple.Preferences",@"System",url,&failure),"known Preferences LS identity and category satisfy metadata boundary only");
    axs_cachekeeper_channel_test_check(axs_cachekeeper_channel_validate_system_record(YES,@"com.apple.springboard",@"Hidden",url,&failure) &&
        axs_cachekeeper_channel_validate_system_record(YES,@"com.apple.springboard",@"System",url,&failure),"only exact SpringBoard also accepts the observed Hidden category");
    for (id type in @[@"User",@"Unknown",@"hidden",NSNull.null]) {
        axs_cachekeeper_channel_test_check(!axs_cachekeeper_channel_validate_system_record(YES,@"com.apple.springboard",type,url,&failure) &&
            failure.pathStage==AxsCacheKeeperChannelPathLSRecord,"unknown or user category stays rejected");
    }
    axs_cachekeeper_channel_test_check(!axs_cachekeeper_channel_validate_system_record(NO,@"com.apple.Preferences",@"Hidden",url,&failure) &&
        !axs_cachekeeper_channel_validate_system_record(YES,@"com.example.springboard",@"Hidden",url,&failure) &&
        !axs_cachekeeper_channel_validate_system_record(YES,@"com.apple.springboard",@"Hidden",[NSURL URLWithString:@"https://example.invalid"],&failure),"Hidden cannot elevate another bundle or non-file URL");

    NSString *folder=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"cachekeeper-channel-path-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSFileManager *fm=NSFileManager.defaultManager;NSError *error=nil;
    axs_cachekeeper_channel_test_check([fm createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:&error],"create bounded path fixture");
    @try {
        axs_cachekeeper_channel_test_production_path_selection(folder);
        NSString *file=[folder stringByAppendingPathComponent:@"program"],*loop=[folder stringByAppendingPathComponent:@"loop"];
        axs_cachekeeper_channel_test_check([@"fixture" writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:&error] &&
            symlink("loop",loop.fileSystemRepresentation)==0,"create real file and self-loop path fixtures");
        __block NSUInteger conversions=0;
        NSString *(^map)(NSString *)=^NSString *(NSString *logical) {
            conversions++;return [logical isEqual:@"/Applications/Preferences.app/Preferences"] ? file : nil;
        };
        NSString *resolved=axs_cachekeeper_channel_resolve_path(@"/Applications/Preferences.app/Preferences",AxsCacheKeeperChannelRootFilesystemPath,
            AxsCacheKeeperChannelPathBundle,map,&failure);
        axs_cachekeeper_channel_test_check(resolved && conversions==1,"system namespace input is converted once before realpath");
        NSString *again=axs_cachekeeper_channel_resolve_path(resolved,AxsCacheKeeperChannelResolvedBundlePath,
            AxsCacheKeeperChannelPathFile,map,&failure);
        axs_cachekeeper_channel_test_check([again isEqual:resolved] && conversions==1,"NSBundle path already in host namespace never receives a second conversion");
        NSString *(^identity)(NSString *)=^NSString *(NSString *path) {return path;};
        NSString *missing=[folder stringByAppendingPathComponent:@"missing"];
        for (NSArray *sample in @[@[missing,@(ENOENT)],@[[file stringByAppendingPathComponent:@"child"],@(ENOTDIR)],@[loop,@(ELOOP)]]) {
            axs_cachekeeper_channel_test_check(!axs_cachekeeper_channel_resolve_path(sample[0],AxsCacheKeeperChannelRootFilesystemPath,
                AxsCacheKeeperChannelPathKernel,identity,&failure) && failure.code==[sample[1] intValue] &&
                failure.domain==AxsCacheKeeperChannelPOSIXError && failure.pathStage==AxsCacheKeeperChannelPathKernel &&
                failure.stage==AxsCacheKeeperChannelExecutable,"real realpath failure preserves exact errno and local path step");
        }
        // RootHide may return an input copy after a mapping error; returning a path is not success.
        NSString *(^failedMap)(NSString *)=^NSString *(NSString *path) {errno=EACCES;return path;};
        axs_cachekeeper_channel_test_check(!axs_cachekeeper_channel_resolve_path(file,AxsCacheKeeperChannelRootFilesystemPath,
            AxsCacheKeeperChannelPathBundle,failedMap,&failure) && failure.code==EACCES,"mapping error is preserved even when the SDK returns an input path");
        unichar embedded[]={ '/', 'x', 0, 'y' };
        for (id invalid in @[@"relative",[NSString stringWithCharacters:embedded length:4],NSNull.null]) {
            axs_cachekeeper_channel_test_check(!axs_cachekeeper_channel_resolve_path(invalid,AxsCacheKeeperChannelRootFilesystemPath,
                AxsCacheKeeperChannelPathBundle,map,&failure) && conversions==1,"invalid input is rejected before invoking RootHide");
        }
        axs_cachekeeper_channel_test_check(!axs_cachekeeper_channel_resolve_path(file,(AxsCacheKeeperChannelPathSource)99,
            AxsCacheKeeperChannelPathBundle,map,&failure),"unknown namespace source cannot skip conversion");
        // The native suite runs on macOS. A real root-owned system app isolates the parent-anchor
        // check from owner rejection; satisfying this file boundary is not host authentication.
        NSString *systemRoot=axs_cachekeeper_channel_resolve_path(@"/System/Library/CoreServices/Finder.app",AxsCacheKeeperChannelResolvedBundlePath,
            AxsCacheKeeperChannelPathBundle,nil,&failure);
        axs_cachekeeper_channel_test_check(systemRoot && axs_cachekeeper_channel_validate_bundle_root(systemRoot,systemRoot.stringByDeletingLastPathComponent,&failure) &&
            !axs_cachekeeper_channel_validate_bundle_root(systemRoot,folder,&failure),"even a real root-owned system bundle is rejected outside the expected anchor");
        NSString *outside=[folder stringByAppendingPathComponent:@"outside.app"];
        axs_cachekeeper_channel_test_check([fm createDirectoryAtPath:outside withIntermediateDirectories:NO attributes:nil error:&error],"create real bundle-shaped directory outside trusted anchor");
        axs_cachekeeper_channel_test_check(!axs_cachekeeper_channel_validate_bundle_root(outside,[folder stringByAppendingPathComponent:@"Applications"],&failure) &&
            failure.stage==AxsCacheKeeperChannelSystemURL && failure.pathStage==AxsCacheKeeperChannelPathAnchor && failure.code==2,"real directory outside system anchor stays rejected");
        NSDictionary *local=axs_cachekeeper_channel_result(@"unavailable",failure,@"unavailable",@"notObserved",@"notObserved");
        axs_cachekeeper_channel_test_check([local[@"localPathStage"] isEqual:@"systemAnchor"] && [local[@"errorOrigin"] isEqual:@"local"] &&
            [local[@"peerIdentity"] isEqual:@"notObserved"],"path failure exposes only the local fixed step");
        failure.peer=YES;
        NSDictionary *remote=axs_cachekeeper_channel_result(@"rejected",failure,@"verified",@"verified",@"verified");
        axs_cachekeeper_channel_test_check([remote[@"localPathStage"] isEqual:@"none"],"HELLO v1 remote failure never inherits local detail");
        uint8_t nonce[16]={1};AxsCacheKeeperChannelMessage message;
        axs_cachekeeper_channel_encode(&message,YES,nonce,MACH_PORT_NULL,MACH_PORT_NULL,AxsCacheKeeperChannelDenied,failure);
        axs_cachekeeper_channel_test_check(message.version==1 && message.reserved==0 && sizeof(message)==68 &&
            message.stage==AxsCacheKeeperChannelSystemURL && message.code==2,"local path step does not change HELLO v1 wire size or reserved bytes");
        failure.pathStage=(AxsCacheKeeperChannelPathStage)99;
        axs_cachekeeper_channel_test_check([axs_cachekeeper_channel_result(@"rejected",failure,@"verified",@"verified",@"verified")[@"state"] isEqual:@"invalid"],
            "unknown internal path step is rejected before fixed-name array lookup");
    } @finally {
        axs_cachekeeper_channel_test_check([fm removeItemAtPath:folder error:&error],"remove only the path fixtures created by this test");
    }
}

void axs_cachekeeper_run_diagnostic_channel_tests(void) {
    @autoreleasepool {
        axs_cachekeeper_channel_test_system_paths();
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
