// Standalone executable: includes the sole production coordinator and client implementation.
// Only external identity/time/read/transport boundaries are controlled by these native fixtures.
#import "../AxsCacheKeeperPDFSession.m"
#include <stdio.h>
#include <spawn.h>
#include <sys/wait.h>
extern char **environ;

static void axs_cachekeeper_pdf_lifecycle_require(BOOL value,const char *message) {
    if (!value) {fprintf(stderr,"FAIL: PDF lifecycle: %s\n",message);exit(1);}
}
static dispatch_time_t axs_cachekeeper_pdf_lifecycle_deadline(void) {
    return dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC);
}

// Native test subclass only. It never ships in either product role.
// Real production gate still separately checks Root.validate and atomic cancellation.
@interface AxsCacheKeeperPDFLifecycleFixture : AxsCacheKeeperPDFServiceCoordinator {
@public
    audit_token_t testClient,testServer;
    atomic_uint_fast64_t testNow;
    atomic_bool identityValid,rootValid,holdRead,holdGate;
}
@property(atomic) int rootFD;
@property(atomic) int readingFD;
@property(nonatomic,strong) dispatch_semaphore_t readEntered;
@property(nonatomic,strong) dispatch_semaphore_t readResume;
@property(nonatomic,strong) dispatch_semaphore_t gateEntered;
@property(nonatomic,strong) dispatch_semaphore_t gateResume;
@property(atomic,strong) AxsCacheKeeperPDFInspection *actualEngine;
@end
@implementation AxsCacheKeeperPDFLifecycleFixture
- (NSTimeInterval)axs_cachekeeper_now {return atomic_load(&testNow);}
- (BOOL)axs_cachekeeper_identities_current:(AxsCacheKeeperPDFTask *)task {
    if (atomic_exchange(&holdGate,false)) {
        dispatch_semaphore_signal(self.gateEntered);
        axs_cachekeeper_pdf_lifecycle_require(dispatch_semaphore_wait(self.gateResume,
            axs_cachekeeper_pdf_lifecycle_deadline())==0,"release controlled identity recheck");
    }
    // Already-authenticated coordination fixture, not real signing identity success.
    return atomic_load(&identityValid) && !memcmp(&task->client,&testClient,sizeof(testClient)) &&
           !memcmp(&task->server,&testServer,sizeof(testServer));
}
- (AxsCacheKeeperPDFInspection *)axs_cachekeeper_engine_for_root:(AxsCacheKeeperPDFRoot *)root
                                                       relative:(NSString *)relative {
    __weak typeof(self) weak=self;
    AxsCacheKeeperPDFInspection *engine=[[AxsCacheKeeperPDFInspection alloc]
        initWithContainerFD:root.descriptor relativeDirectory:relative
        limits:axs_cachekeeper_pdf_inspection_limits() clock:^NSTimeInterval{return 0;}
        beforeRead:nil read:^ssize_t(int fd,void *bytes,size_t count){
            // Use actual production reading; only delay returning from the external operation.
            ssize_t result=pread(fd,bytes,count,0);
            AxsCacheKeeperPDFLifecycleFixture *owner=weak;
            owner.readingFD=fd;
            if (atomic_exchange(&owner->holdRead,false)) {
                dispatch_semaphore_signal(owner.readEntered);
                axs_cachekeeper_pdf_lifecycle_require(
                    dispatch_semaphore_wait(owner.readResume,axs_cachekeeper_pdf_lifecycle_deadline())==0,
                    "test must release its actual read boundary");
            }
            return result;
        }];
    self.actualEngine=engine;return engine;
}
@end

static NSMutableDictionary *axs_cachekeeper_pdf_lifecycle_request(NSString *operation,NSString *instance,
                                                                NSString *session,uint32_t generation) {
    return [@{@"operation":operation,@"bundle":@"test.pdf.app",@"relative":@"Library/Caches",
              @"session":session,@"generation":@(generation),@"nonce":NSUUID.UUID.UUIDString,
              @"service":instance,@"candidate":@10} mutableCopy];
}

// Hand over a real owned send-once right to the same coordination/reply path used by production.
// The lifecycle ingress receives controlled tokens; it is not the audited host entry point.
static mach_port_t axs_cachekeeper_pdf_lifecycle_send(AxsCacheKeeperPDFLifecycleFixture *service,
                                                     NSDictionary *request,audit_token_t client,audit_token_t server) {
    mach_port_t receive=MACH_PORT_NULL,reply=MACH_PORT_NULL;mach_msg_type_name_t acquired=0;
    axs_cachekeeper_pdf_lifecycle_require(
        mach_port_allocate(mach_task_self(),MACH_PORT_RIGHT_RECEIVE,&receive)==KERN_SUCCESS &&
        mach_port_extract_right(mach_task_self(),receive,MACH_MSG_TYPE_MAKE_SEND_ONCE,&reply,&acquired)==KERN_SUCCESS &&
        acquired==MACH_MSG_TYPE_PORT_SEND_ONCE,"allocate real lifecycle reply endpoint");
    dispatch_async(service.control,^{
        [service axs_cachekeeper_accept_authenticated_request:request reply:reply client:client server:server];
    });
    return receive;
}
static NSDictionary *axs_cachekeeper_pdf_lifecycle_receive(mach_port_t receive) {
    AxsCacheKeeperPDFBuffer buffer={0};
    mach_msg_option_t options=MACH_RCV_MSG|MACH_RCV_TIMEOUT|
        MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0)|MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT);
    axs_cachekeeper_pdf_lifecycle_require(
        mach_msg(&buffer.header,options,0,sizeof(buffer),receive,2000,MACH_PORT_NULL)==MACH_MSG_SUCCESS,
        "actual coordination branch must send a reply without waiting for the reading queue");
    NSDictionary *response=nil;audit_token_t peer;
    axs_cachekeeper_pdf_lifecycle_require(
        axs_cachekeeper_pdf_decode(&buffer,sizeof(buffer),receive,YES,&response,&peer) && peer.val[5]==(uint32_t)getpid(),
        "actual reply has a decoded kernel audit trailer, not a fabricated wire message");
    axs_cachekeeper_pdf_destroy(&buffer);
    axs_cachekeeper_channel_release_receive(receive,NO);
    return response;
}
static NSDictionary *axs_cachekeeper_pdf_lifecycle_exchange(AxsCacheKeeperPDFLifecycleFixture *service,NSDictionary *request) {
    return axs_cachekeeper_pdf_lifecycle_receive(axs_cachekeeper_pdf_lifecycle_send(service,request,service->testClient,service->testServer));
}
static void axs_cachekeeper_pdf_lifecycle_fence(AxsCacheKeeperPDFLifecycleFixture *service) {
    // Two rounds include lifecycle checks which enqueue cleanup back onto work.
    for (NSUInteger i=0;i<2;i++) {dispatch_sync(service.work,^{});dispatch_sync(service.control,^{});}
}
static void axs_cachekeeper_pdf_lifecycle_wait_ready(AxsCacheKeeperPDFLifecycleFixture *service,
                                                   NSString *session,uint32_t generation) {
    NSDictionary *probe=axs_cachekeeper_pdf_lifecycle_request(@"probe",@"",session,generation);
    NSDictionary *reply=axs_cachekeeper_pdf_lifecycle_exchange(service,probe);
    axs_cachekeeper_pdf_lifecycle_require([reply[@"state"] isEqual:@"probing"],"fresh probe enters real probing task");
    // Serial queue fences, not fabricated state changes. The real probe publishes on control.
    dispatch_sync(service.work,^{});dispatch_sync(service.control,^{});
    NSDictionary *poll=axs_cachekeeper_pdf_lifecycle_request(@"poll",service.instance,session,generation);
    reply=axs_cachekeeper_pdf_lifecycle_exchange(service,poll);
    axs_cachekeeper_pdf_lifecycle_require([reply[@"state"] isEqual:@"ready"] &&
        [reply[@"report"][@"containerReadable"] boolValue],"actual selected directory probe reaches ready");
    axs_cachekeeper_pdf_lifecycle_require([service.actualEngine.report[@"sampleBytes"] unsignedLongLongValue]==0,
        "probe does not read PDF content before start");
}
static void axs_cachekeeper_pdf_lifecycle_require_closed(int fd,const char *message) {
    errno=0;axs_cachekeeper_pdf_lifecycle_require(fd>=0 && fcntl(fd,F_GETFD)==-1 && errno==EBADF,message);
}

// Mutation target: removing draining from the production busy guard must fail before readResume.
// Removing immediate atomic cancellation or FD cleanup must also fail an explicit assertion.
static AxsCacheKeeperPDFLifecycleFixture *axs_cachekeeper_pdf_lifecycle_service(NSString *root) {
    __block __weak AxsCacheKeeperPDFLifecycleFixture *weak;
    AxsCacheKeeperPDFLifecycleFixture *service=[[AxsCacheKeeperPDFLifecycleFixture alloc]
        initWithRootProvider:^AxsCacheKeeperPDFRoot *(NSString *bundle,NSString **stage,int *code){
            axs_cachekeeper_pdf_lifecycle_require([bundle isEqual:@"test.pdf.app"],"one fixed test bundle only");
            int fd=open(root.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
            if (fd<0) {if (stage) *stage=@"containerOpen";if (code) *code=errno;return nil;}
            weak.rootFD=fd;
            return [[AxsCacheKeeperPDFRoot alloc] initWithDescriptor:fd path:root validator:^BOOL{
                AxsCacheKeeperPDFLifecycleFixture *owner=weak;return owner && atomic_load(&owner->rootValid);
            }];
        }];
    weak=service;service.rootFD=-1;service.readingFD=-1;
    service.readEntered=dispatch_semaphore_create(0);service.readResume=dispatch_semaphore_create(0);
    service.gateEntered=dispatch_semaphore_create(0);service.gateResume=dispatch_semaphore_create(0);
    atomic_init(&service->testNow,100);atomic_init(&service->identityValid,true);atomic_init(&service->rootValid,true);
    atomic_init(&service->holdRead,false);atomic_init(&service->holdGate,false);
    service->testClient=(audit_token_t){{1,2,3,4,5,(uint32_t)getpid(),7,8}};
    service->testServer=(audit_token_t){{9,10,11,12,13,(uint32_t)getpid(),15,16}};
    return service;
}
static void axs_cachekeeper_pdf_lifecycle_cancel_draining(NSString *root) {
    AxsCacheKeeperPDFLifecycleFixture *service=axs_cachekeeper_pdf_lifecycle_service(root);
    NSString *session=NSUUID.UUID.UUIDString;
    axs_cachekeeper_pdf_lifecycle_wait_ready(service,session,7);
    atomic_store(&service->holdRead,true);
    NSDictionary *reply=axs_cachekeeper_pdf_lifecycle_exchange(service,
        axs_cachekeeper_pdf_lifecycle_request(@"start",service.instance,session,7));
    axs_cachekeeper_pdf_lifecycle_require([reply[@"state"] isEqual:@"running"],"ready start enters actual read task");
    axs_cachekeeper_pdf_lifecycle_require(
        dispatch_semaphore_wait(service.readEntered,axs_cachekeeper_pdf_lifecycle_deadline())==0,
        "real PDFInspection reaches the held content read");
    int rootFD=service.rootFD,readingFD=service.readingFD;
    AxsCacheKeeperPDFInspection *engine=service.actualEngine;
    axs_cachekeeper_pdf_lifecycle_require(fcntl(readingFD,F_GETFD)>=0,"read FD stays owned while callback is held");
    reply=axs_cachekeeper_pdf_lifecycle_exchange(service,
        axs_cachekeeper_pdf_lifecycle_request(@"cancel",service.instance,session,7));
    axs_cachekeeper_pdf_lifecycle_require([reply[@"state"] isEqual:@"cancelled"],
        "cancel reply returns while the actual read callback is still held");
    __block AxsCacheKeeperPDFTask *oldTask;
    dispatch_sync(service.control,^{
        oldTask=service.draining;
        axs_cachekeeper_pdf_lifecycle_require(!service.task && service.draining &&
            atomic_load(&service.draining->cancelled),"cancel immediately marks old task and preserves draining");
    });
    NSString *nextSession=NSUUID.UUID.UUIDString;
    reply=axs_cachekeeper_pdf_lifecycle_exchange(service,
        axs_cachekeeper_pdf_lifecycle_request(@"probe",@"",nextSession,8));
    axs_cachekeeper_pdf_lifecycle_require([reply[@"state"] isEqual:@"busy"],
        "second probe during draining must return busy before read returns");
    // Do not inspect engine.report here: it would take the real scan lock we deliberately hold.
    dispatch_semaphore_signal(service.readResume);
    dispatch_sync(service.work,^{});dispatch_sync(service.control,^{});
    axs_cachekeeper_pdf_lifecycle_require_closed(readingFD,"returned read releases actual file FD");
    axs_cachekeeper_pdf_lifecycle_require_closed(rootFD,"cancel cleanup releases provider's actual root FD");
    axs_cachekeeper_pdf_lifecycle_require([engine.report[@"pdfCandidates"] count]==0 &&
        [engine.report[@"openDescriptorCount"] unsignedIntegerValue]==0,
        "late read cannot retain candidates or descriptor chain");
    dispatch_sync(service.control,^{axs_cachekeeper_pdf_lifecycle_require(!service.task && !service.draining,
        "draining clears only after actual cleanup");});
    axs_cachekeeper_pdf_lifecycle_wait_ready(service,nextSession,8);
    NSDictionary *oldSnapshot=oldTask.snapshot;
    [service axs_cachekeeper_publish:oldTask state:@"finished" snapshot:@{@"state":@"finished"}];
    dispatch_sync(service.control,^{
        axs_cachekeeper_pdf_lifecycle_require([oldTask.snapshot isEqual:oldSnapshot] &&
            [service.task.state isEqual:@"ready"],"late publish must not change retired or replacement task");
    });
    for (NSString *operation in @[@"poll",@"resolve"]) {
        NSMutableDictionary *stale=axs_cachekeeper_pdf_lifecycle_request(operation,service.instance,session,7);
        if ([operation isEqual:@"resolve"]) stale[@"candidate"]=@0;
        NSDictionary *rejected=axs_cachekeeper_pdf_lifecycle_exchange(service,stale);
        axs_cachekeeper_pdf_lifecycle_require([rejected[@"state"] isEqual:@"expired"] && ![rejected[@"directory"] length],
            "old generation cannot poll or resolve replacement task");
    }
    int readyFD=service.rootFD;
    reply=axs_cachekeeper_pdf_lifecycle_exchange(service,
        axs_cachekeeper_pdf_lifecycle_request(@"cancel",service.instance,nextSession,8));
    axs_cachekeeper_pdf_lifecycle_require([reply[@"state"] isEqual:@"cancelled"],"release final ready task");
    dispatch_sync(service.work,^{});dispatch_sync(service.control,^{});
    axs_cachekeeper_pdf_lifecycle_require_closed(readyFD,"ready-only cancel releases root without starting a scan");
}

static NSDictionary *axs_cachekeeper_pdf_lifecycle_finish(AxsCacheKeeperPDFLifecycleFixture *service,NSString *session) {
    axs_cachekeeper_pdf_lifecycle_wait_ready(service,session,7);
    axs_cachekeeper_pdf_lifecycle_exchange(service,axs_cachekeeper_pdf_lifecycle_request(@"start",service.instance,session,7));
    axs_cachekeeper_pdf_lifecycle_fence(service);
    NSDictionary *reply=axs_cachekeeper_pdf_lifecycle_exchange(service,axs_cachekeeper_pdf_lifecycle_request(@"poll",service.instance,session,7));
    axs_cachekeeper_pdf_lifecycle_require([reply[@"state"] isEqual:@"finished"] &&
        [reply[@"report"][@"pdfCandidates"] count]==1,"actual work queue finishes and retains one real PDF");
    return reply;
}
static void axs_cachekeeper_pdf_lifecycle_stop(AxsCacheKeeperPDFLifecycleFixture *service) {
    dispatch_sync(service.control,^{if (service.timer) {dispatch_source_cancel(service.timer);service.timer=nil;}
        [service axs_cachekeeper_invalidate:service.task];});
    axs_cachekeeper_pdf_lifecycle_fence(service);
}
static void axs_cachekeeper_pdf_lifecycle_expired(AxsCacheKeeperPDFLifecycleFixture *service,NSString *session) {
    for (NSString *operation in @[@"poll",@"resolve"]) {
        NSMutableDictionary *request=axs_cachekeeper_pdf_lifecycle_request(operation,service.instance,session,7);
        if ([operation isEqual:@"resolve"]) request[@"candidate"]=@0;
        NSDictionary *reply=axs_cachekeeper_pdf_lifecycle_exchange(service,request);
        axs_cachekeeper_pdf_lifecycle_require([reply[@"state"] isEqual:@"expired"] && ![reply[@"directory"] length],
            "old poll/resolve cannot renew invalidated session or return a directory");
    }
}
static void axs_cachekeeper_pdf_lifecycle_wait(BOOL (^done)(void),const char *message) {
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:3];
    while (!done() && deadline.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    axs_cachekeeper_pdf_lifecycle_require(done(),message);
}
// Mutation targets: disconnecting the actual timer/PROC handler or omitting periodic identity/root checks.
static void axs_cachekeeper_pdf_lifecycle_invalidation(NSString *root) {
    for (NSUInteger mode=0;mode<5;mode++) {
        AxsCacheKeeperPDFLifecycleFixture *service=axs_cachekeeper_pdf_lifecycle_service(root);
        NSString *session=NSUUID.UUID.UUIDString;pid_t child=0;int input[2]={-1,-1};
        if (mode==4) {
            axs_cachekeeper_pdf_lifecycle_require(pipe(input)==0,"create child lifetime pipe");
            posix_spawn_file_actions_t actions;posix_spawn_file_actions_init(&actions);
            posix_spawn_file_actions_adddup2(&actions,input[0],STDIN_FILENO);
            posix_spawn_file_actions_addclose(&actions,input[0]);posix_spawn_file_actions_addclose(&actions,input[1]);
            char *args[]={"/bin/cat",NULL};
            int result=posix_spawn(&child,"/bin/cat",&actions,NULL,args,environ);
            posix_spawn_file_actions_destroy(&actions);close(input[0]);
            axs_cachekeeper_pdf_lifecycle_require(result==0,"spawn real blocked child for process-exit event");
            service->testClient.val[5]=(uint32_t)child;
        }
        if (mode==0) axs_cachekeeper_pdf_lifecycle_wait_ready(service,session,7);
        else axs_cachekeeper_pdf_lifecycle_finish(service,session);
        AxsCacheKeeperPDFInspection *engine=service.actualEngine;int rootFD=service.rootFD;
        if (mode==0 || mode==1) atomic_store(&service->testNow,111);
        if (mode==2) atomic_store(&service->identityValid,false);
        if (mode==3) atomic_store(&service->rootValid,false);
        if (mode==4) {
            dispatch_semaphore_t registered=dispatch_semaphore_create(0);
            dispatch_sync(service.control,^{
                axs_cachekeeper_pdf_lifecycle_require(service.task.exitSource!=nil,"real process exit source exists");
                // Installing a registration handler after resume still observes completed registration.
                dispatch_source_set_registration_handler(service.task.exitSource,^{dispatch_semaphore_signal(registered);});
            });
            axs_cachekeeper_pdf_lifecycle_require(dispatch_semaphore_wait(registered,axs_cachekeeper_pdf_lifecycle_deadline())==0,
                "process exit source is registered before child exits");
            close(input[1]);
        } else if (mode==1) {
            dispatch_sync(service.control,^{[service axs_cachekeeper_start_timer];
                dispatch_source_set_timer(service.timer,DISPATCH_TIME_NOW,NSEC_PER_MSEC,NSEC_PER_MSEC);});
        } else dispatch_sync(service.control,^{[service axs_cachekeeper_check_lifecycle];});
        axs_cachekeeper_pdf_lifecycle_wait(^BOOL{
            __block BOOL cleared=NO;dispatch_sync(service.control,^{cleared=!service.task && !service.draining;});return cleared;
        },"real lifecycle event clears active and draining task");
        if (child) {int status=0;axs_cachekeeper_pdf_lifecycle_require(waitpid(child,&status,0)==child && WIFEXITED(status),"reap exited test peer");}
        axs_cachekeeper_pdf_lifecycle_require_closed(rootFD,"lifecycle invalidation closes root FD");
        axs_cachekeeper_pdf_lifecycle_require([engine.report[@"pdfCandidates"] count]==0 &&
            [engine.report[@"openDescriptorCount"] unsignedIntegerValue]==0,"invalidation clears actual retained candidates/FDs");
        axs_cachekeeper_pdf_lifecycle_expired(service,session);axs_cachekeeper_pdf_lifecycle_stop(service);
    }
}
// Mutation targets: removed binding guards, pre/post work gate or final resolve task/lease guard.
static void axs_cachekeeper_pdf_lifecycle_resolve(NSString *root) {
    for (NSUInteger mode=0;mode<7;mode++) {
        AxsCacheKeeperPDFLifecycleFixture *service=axs_cachekeeper_pdf_lifecycle_service(root);
        NSString *session=NSUUID.UUID.UUIDString;axs_cachekeeper_pdf_lifecycle_finish(service,session);
        NSMutableDictionary *request=axs_cachekeeper_pdf_lifecycle_request(@"resolve",service.instance,session,7);request[@"candidate"]=@0;
        if (mode==1) atomic_store(&service->rootValid,false);
        if (mode==2) atomic_store(&service->identityValid,false);
        if (mode==3) {
            NSString *path=[root stringByAppendingPathComponent:@"Library/Caches/candidate.pdf"];
            axs_cachekeeper_pdf_lifecycle_require([[ @"%PDF-replaced different inode" dataUsingEncoding:NSUTF8StringEncoding]
                writeToFile:path atomically:YES],"replace candidate inode before production resolve");
        }
        if (mode==4) request[@"candidate"]=@9;
        NSDictionary *reply;
        if (mode>=5) {
            // Hold external identity recheck while the real resolve is in flight.
            atomic_store(&service->holdGate,true);
            mach_port_t receive=axs_cachekeeper_pdf_lifecycle_send(service,request,service->testClient,service->testServer);
            axs_cachekeeper_pdf_lifecycle_require(dispatch_semaphore_wait(service.gateEntered,axs_cachekeeper_pdf_lifecycle_deadline())==0,"resolve reached real work gate");
            if (mode==5) axs_cachekeeper_pdf_lifecycle_exchange(service,axs_cachekeeper_pdf_lifecycle_request(@"cancel",service.instance,session,7));
            else atomic_store(&service->testNow,111);
            dispatch_semaphore_signal(service.gateResume);reply=axs_cachekeeper_pdf_lifecycle_receive(receive);
        } else reply=axs_cachekeeper_pdf_lifecycle_exchange(service,request);
        axs_cachekeeper_pdf_lifecycle_require(mode==0 ? ([reply[@"state"] isEqual:@"finished"] &&
            [reply[@"directory"] isEqual:[root stringByAppendingPathComponent:@"Library/Caches"]]) :
            ([reply[@"state"] isEqual:@"expired"] && ![reply[@"directory"] length]),
            "resolve only returns a currently retained, revalidated candidate before cancellation/expiry");
        axs_cachekeeper_pdf_lifecycle_stop(service);
    }
    AxsCacheKeeperPDFLifecycleFixture *service=axs_cachekeeper_pdf_lifecycle_service(root);
    NSString *session=NSUUID.UUID.UUIDString;axs_cachekeeper_pdf_lifecycle_wait_ready(service,session,7);
    for (NSString *field in @[@"service",@"session",@"generation",@"bundle",@"relative"]) {
        NSMutableDictionary *request=axs_cachekeeper_pdf_lifecycle_request(@"poll",service.instance,session,7);
        request[field]=[field isEqual:@"generation"] ? @8 : ([field isEqual:@"bundle"] ? @"test.other.app" : ([field isEqual:@"relative"] ? @"tmp" : NSUUID.UUID.UUIDString));
        NSDictionary *reply=axs_cachekeeper_pdf_lifecycle_exchange(service,request);
        axs_cachekeeper_pdf_lifecycle_require([reply[@"state"] isEqual:@"expired"],"actual coordinator rejects stale request binding fields");
    }
    for (NSUInteger word=0;word<8;word++) for (NSUInteger peer=0;peer<2;peer++) {
        audit_token_t client=service->testClient,server=service->testServer;if (peer) server.val[word]++;else client.val[word]++;
        NSDictionary *reply=axs_cachekeeper_pdf_lifecycle_receive(axs_cachekeeper_pdf_lifecycle_send(service,
            axs_cachekeeper_pdf_lifecycle_request(@"poll",service.instance,session,7),client,server));
        axs_cachekeeper_pdf_lifecycle_require([reply[@"state"] isEqual:@"expired"],"all words of both actual coordinator bindings are enforced");
    }
    NSMutableDictionary *replay=axs_cachekeeper_pdf_lifecycle_request(@"poll",service.instance,session,7);
    axs_cachekeeper_pdf_lifecycle_exchange(service,replay);
    axs_cachekeeper_pdf_lifecycle_require([axs_cachekeeper_pdf_lifecycle_exchange(service,replay)[@"state"] isEqual:@"expired"],"actual coordinator rejects replayed nonce");
    atomic_store(&service->rootValid,false);
    axs_cachekeeper_pdf_lifecycle_exchange(service,axs_cachekeeper_pdf_lifecycle_request(@"start",service.instance,session,7));
    axs_cachekeeper_pdf_lifecycle_fence(service);
    NSDictionary *reply=axs_cachekeeper_pdf_lifecycle_exchange(service,axs_cachekeeper_pdf_lifecycle_request(@"poll",service.instance,session,7));
    axs_cachekeeper_pdf_lifecycle_require([reply[@"state"] isEqual:@"unavailable"] && [service.actualEngine.report[@"sampleBytes"] unsignedLongLongValue]==0,
        "changed root at start is rejected before content is read");
    axs_cachekeeper_pdf_lifecycle_stop(service);
}

static void axs_cachekeeper_pdf_lifecycle_recheck_after_read(NSString *root) {
    for (NSUInteger mode=0;mode<2;mode++) {
        AxsCacheKeeperPDFLifecycleFixture *service=axs_cachekeeper_pdf_lifecycle_service(root);
        NSString *session=NSUUID.UUID.UUIDString;axs_cachekeeper_pdf_lifecycle_wait_ready(service,session,7);
        atomic_store(&service->holdRead,true);
        axs_cachekeeper_pdf_lifecycle_exchange(service,axs_cachekeeper_pdf_lifecycle_request(@"start",service.instance,session,7));
        axs_cachekeeper_pdf_lifecycle_require(dispatch_semaphore_wait(service.readEntered,axs_cachekeeper_pdf_lifecycle_deadline())==0,
            "actual scan reached read before identity/install changes");
        int rootFD=service.rootFD,readingFD=service.readingFD;AxsCacheKeeperPDFInspection *engine=service.actualEngine;
        if (mode) atomic_store(&service->rootValid,false);else atomic_store(&service->identityValid,false);
        dispatch_semaphore_signal(service.readResume);axs_cachekeeper_pdf_lifecycle_fence(service);
        NSDictionary *reply=axs_cachekeeper_pdf_lifecycle_exchange(service,axs_cachekeeper_pdf_lifecycle_request(@"poll",service.instance,session,7));
        axs_cachekeeper_pdf_lifecycle_require([reply[@"state"] isEqual:@"unavailable"] && [engine.report[@"pdfCandidates"] count]==0,
            "post-read identity/root failure discards real candidates before publish");
        axs_cachekeeper_pdf_lifecycle_require_closed(rootFD,"post-read invalidation closes root");
        axs_cachekeeper_pdf_lifecycle_require_closed(readingFD,"post-read invalidation closes read descriptor");
        axs_cachekeeper_pdf_lifecycle_stop(service);
    }
}

// Test-only access to queue fences. No reset/state transition is introduced into the product.
@interface AxsCacheKeeperPDFSession (AxsCacheKeeperPDFLifecycleTests)
- (void)axs_cachekeeper_test_fence;
- (void)axs_cachekeeper_test_poll_now;
- (BOOL)axs_cachekeeper_test_has_timer;
- (NSString *)axs_cachekeeper_test_service;
@end
@implementation AxsCacheKeeperPDFSession (AxsCacheKeeperPDFLifecycleTests)
- (void)axs_cachekeeper_test_fence {dispatch_sync(_queue,^{});}
- (void)axs_cachekeeper_test_poll_now {dispatch_sync(_queue,^{
    if (self->_timer) dispatch_source_set_timer(self->_timer,DISPATCH_TIME_NOW,NSEC_PER_SEC,NSEC_PER_MSEC);
});}
- (BOOL)axs_cachekeeper_test_has_timer {__block BOOL value;dispatch_sync(_queue,^{value=self->_timer!=nil;});return value;}
- (NSString *)axs_cachekeeper_test_service {__block NSString *value;dispatch_sync(_queue,^{value=self->_service;});return value;}
@end
@interface AxsCacheKeeperPDFLifecycleClient : AxsCacheKeeperPDFSession {
@public
    audit_token_t testClient,testServer;
}
@property(nonatomic,copy) NSString *instance;
@property(atomic,copy) NSString *heldOperation;
@property(atomic,copy) NSString *fault;
@property(atomic) NSUInteger pollCount;
@property(nonatomic,strong) dispatch_semaphore_t entered;
@property(nonatomic,strong) dispatch_semaphore_t resume;
@end
@implementation AxsCacheKeeperPDFLifecycleClient
- (instancetype)initWithBundle:(NSString *)bundle relativeDirectory:(NSString *)relative {
    self=[super initWithBundle:bundle relativeDirectory:relative];if (self) {
        _instance=NSUUID.UUID.UUIDString;_entered=dispatch_semaphore_create(0);_resume=dispatch_semaphore_create(0);
        testClient=(audit_token_t){{1,2,3,4,5,(uint32_t)getpid(),7,8}};
        testServer=(audit_token_t){{9,10,11,12,13,(uint32_t)getpid(),15,16}};
    }return self;
}
- (NSDictionary *)axs_cachekeeper_exchange:(NSString *)operation candidate:(NSUInteger)candidate {
    NSDictionary *request=[self axs_cachekeeper_request:operation candidate:candidate];
    axs_cachekeeper_pdf_lifecycle_require(request!=nil,"client fixture uses production validated request construction");
    if ([operation isEqual:@"poll"]) self.pollCount++;
    NSString *state=[operation isEqual:@"probe"] ? @"ready" : ([operation isEqual:@"cancel"] ? @"cancelled" : @"finished");
    NSMutableDictionary *response=[@{@"operation":operation,@"nonce":request[@"nonce"],@"session":request[@"session"],
        @"generation":request[@"generation"],@"service":self.instance,@"state":state,
        @"report":@{@"state":state,@"stage":@"none",@"errorCode":@0,@"containerReadable":@YES},
        @"directory":[operation isEqual:@"resolve"] ? @"/test/selected/directory" : @""} mutableCopy];
    audit_token_t client=testClient,server=testServer;NSString *fault=self.fault;
    if (![operation isEqual:@"cancel"]) {
        if ([fault isEqual:@"lookup"] || [fault isEqual:@"receive"])
            return @{@"state":@"unavailable",@"report":axs_cachekeeper_pdf_status(@"unavailable",fault,ETIMEDOUT)};
        if ([fault hasPrefix:@"client:"]) client.val[[[fault componentsSeparatedByString:@":"] lastObject].intValue]++;
        else if ([fault hasPrefix:@"server:"]) server.val[[[fault componentsSeparatedByString:@":"] lastObject].intValue]++;
        else if (fault.length) response[fault]=[fault isEqual:@"generation"] ? @999 :
            ([fault isEqual:@"operation"] ? @"resolve" : NSUUID.UUID.UUIDString);
    }
    NSDictionary *accepted=[self axs_cachekeeper_accept_authenticated_reply:response request:request client:client server:server];
    if ([self.heldOperation isEqual:operation]) {
        self.heldOperation=nil;dispatch_semaphore_signal(self.entered);
        axs_cachekeeper_pdf_lifecycle_require(dispatch_semaphore_wait(self.resume,axs_cachekeeper_pdf_lifecycle_deadline())==0,
            "release held authenticated client transport response");
    }
    return accepted;
}
@end
static AxsCacheKeeperPDFLifecycleClient *axs_cachekeeper_pdf_lifecycle_client(void) {
    return [[AxsCacheKeeperPDFLifecycleClient alloc] initWithBundle:@"test.pdf.app" relativeDirectory:@"Library/Caches"];
}
static void axs_cachekeeper_pdf_lifecycle_flush_main(void) {
    __block BOOL done=NO;dispatch_async(dispatch_get_main_queue(),^{done=YES;});
    axs_cachekeeper_pdf_lifecycle_wait(^BOOL{return done;},"flush real client main-queue delivery");
}
// Mutation target: removing the second cancellation check on the real main-queue delivery.
static void axs_cachekeeper_pdf_lifecycle_client_main(void) {
    @autoreleasepool {
        AxsCacheKeeperPDFLifecycleClient *client=axs_cachekeeper_pdf_lifecycle_client();__block NSUInteger updates=0;
        [client probe:^(NSDictionary *report){(void)report;updates++;}];
        [client axs_cachekeeper_test_fence]; // deliver has queued its callback; main has not run it yet.
        [client cancel];[client axs_cachekeeper_test_fence];axs_cachekeeper_pdf_lifecycle_flush_main();
        axs_cachekeeper_pdf_lifecycle_require(updates==0,"cancelled client suppresses already queued main update");
        axs_cachekeeper_pdf_lifecycle_require(![client axs_cachekeeper_test_has_timer],"cancel removes production poll timer");
    }
}
static void axs_cachekeeper_pdf_lifecycle_client_late(void) {
    for (NSUInteger mode=0;mode<3;mode++) @autoreleasepool {
        AxsCacheKeeperPDFLifecycleClient *client=axs_cachekeeper_pdf_lifecycle_client();
        __block NSUInteger updates=0,completions=0;__block NSString *state;
        [client probe:^(NSDictionary *report){updates++;state=report[@"state"];}];
        axs_cachekeeper_pdf_lifecycle_wait(^BOOL{return [state isEqual:@"ready"];},"public client receives actual ready delivery");
        [client start];axs_cachekeeper_pdf_lifecycle_wait(^BOOL{return [state isEqual:@"finished"];},"public client start reaches finished");
        NSUInteger before=updates;
        if (mode==0) {client.heldOperation=@"poll";[client axs_cachekeeper_test_poll_now];}
        else {
            if (mode==1) client.heldOperation=@"resolve";
            [client resolveCandidate:0 completion:^(NSString *path,NSDictionary *report){(void)path;(void)report;completions++;}];
        }
        if (mode<2) axs_cachekeeper_pdf_lifecycle_require(dispatch_semaphore_wait(client.entered,axs_cachekeeper_pdf_lifecycle_deadline())==0,
            "real client serial exchange holds late poll/resolve reply");
        else [client axs_cachekeeper_test_fence];
        [client cancel];if (mode<2) dispatch_semaphore_signal(client.resume);
        [client axs_cachekeeper_test_fence];axs_cachekeeper_pdf_lifecycle_flush_main();
        axs_cachekeeper_pdf_lifecycle_require(updates==before && completions==0,
            "cancelled real client suppresses late poll and candidate completion");
        axs_cachekeeper_pdf_lifecycle_require(![client axs_cachekeeper_test_has_timer],"late reply does not recreate poll timer");
    }
}
// Mutation targets: dropping full token/service/request checks or failing to stop polling on an error.
static void axs_cachekeeper_pdf_lifecycle_client_binding(void) {
    NSMutableArray *faults=[NSMutableArray arrayWithArray:@[@"service",@"session",@"generation",@"nonce",@"operation",@"lookup",@"receive"]];
    for (NSUInteger word=0;word<8;word++) { [faults addObject:[NSString stringWithFormat:@"client:%lu",(unsigned long)word]];
        [faults addObject:[NSString stringWithFormat:@"server:%lu",(unsigned long)word]]; }
    for (NSString *fault in faults) @autoreleasepool {
        AxsCacheKeeperPDFLifecycleClient *client=axs_cachekeeper_pdf_lifecycle_client();__block NSDictionary *last;
        [client probe:^(NSDictionary *report){last=report;}];
        axs_cachekeeper_pdf_lifecycle_wait(^BOOL{return [last[@"state"] isEqual:@"ready"];},"bind client through public probe");
        NSString *bound=[client axs_cachekeeper_test_service];client.fault=fault;[client axs_cachekeeper_test_poll_now];
        axs_cachekeeper_pdf_lifecycle_wait(^BOOL{return [last[@"state"] isEqual:@"unavailable"];},"old service/token/request reply fails public client delivery");
        axs_cachekeeper_pdf_lifecycle_require([last[@"stage"] isEqual:([@[@"lookup",@"receive"] containsObject:fault] ? fault : @"peerIdentity")] &&
            [[client axs_cachekeeper_test_service] isEqual:bound] && ![client axs_cachekeeper_test_has_timer],
            "failure preserves original binding and stops production polling");
        __block NSUInteger completions=0;[client start];[client resolveCandidate:0 completion:^(NSString *path,NSDictionary *report){(void)path;(void)report;completions++;}];
        [client axs_cachekeeper_test_fence];axs_cachekeeper_pdf_lifecycle_flush_main();
        axs_cachekeeper_pdf_lifecycle_require(completions==0,"failed session cannot restart or deliver old candidate");
        [client cancel];[client axs_cachekeeper_test_fence];
    }
}
static void axs_cachekeeper_pdf_lifecycle_failed_send(void) {
    mach_port_t receive=MACH_PORT_NULL,reply=MACH_PORT_NULL;mach_msg_type_name_t acquired=0;
    axs_cachekeeper_pdf_lifecycle_require(mach_port_allocate(mach_task_self(),MACH_PORT_RIGHT_RECEIVE,&receive)==KERN_SUCCESS &&
        mach_port_extract_right(mach_task_self(),receive,MACH_MSG_TYPE_MAKE_SEND_ONCE,&reply,&acquired)==KERN_SUCCESS,
        "allocate real failed-send reply right");
    axs_cachekeeper_channel_release_receive(receive,NO);
    AxsCacheKeeperPDFMessage message;int code=0;
    axs_cachekeeper_pdf_lifecycle_require(axs_cachekeeper_pdf_encode(&message,@{@"reply":@YES},YES,reply,MACH_PORT_NULL) &&
        !axs_cachekeeper_pdf_send(&message,&code) && (code & ~MACH_MSG_MASK)==MACH_SEND_INVALID_DEST,
        "actual send fails when reply endpoint has exited");
    mach_port_type_t type=0;
    axs_cachekeeper_pdf_lifecycle_require(mach_port_type(mach_task_self(),reply,&type)!=KERN_SUCCESS,
        "failed real send releases owned send-once/dead-name right");
}

// The enclosing runner owns and cleans this fixture path.
int main(int argc,char **argv) {
    @autoreleasepool {
        axs_cachekeeper_pdf_lifecycle_require(argc>=2,"runner supplies a project tmp fixture directory");
        NSString *root=[NSString stringWithUTF8String:argv[1]];
        NSString *directory=[root stringByAppendingPathComponent:@"Library/Caches"];
        axs_cachekeeper_pdf_lifecycle_require([NSFileManager.defaultManager createDirectoryAtPath:directory
            withIntermediateDirectories:YES attributes:nil error:nil],"create real lifecycle fixture");
        axs_cachekeeper_pdf_lifecycle_require([[@"%PDF-actual lifecycle fixture" dataUsingEncoding:NSUTF8StringEncoding]
            writeToFile:[directory stringByAppendingPathComponent:@"candidate.pdf"] atomically:NO],"write one real PDF fixture");
        if (argc==3) {
            if (!strcmp(argv[2],"client-main")) axs_cachekeeper_pdf_lifecycle_client_main();
            else axs_cachekeeper_pdf_lifecycle_cancel_draining(root);
            return 0;
        }
        axs_cachekeeper_pdf_lifecycle_cancel_draining(root);
        axs_cachekeeper_pdf_lifecycle_invalidation(root);
        axs_cachekeeper_pdf_lifecycle_resolve(root);
        axs_cachekeeper_pdf_lifecycle_recheck_after_read(root);
        axs_cachekeeper_pdf_lifecycle_client_main();
        axs_cachekeeper_pdf_lifecycle_client_late();
        axs_cachekeeper_pdf_lifecycle_client_binding();
        axs_cachekeeper_pdf_lifecycle_failed_send();
        puts("PASS: actual post-auth PDF lifecycle, client late delivery, Mach replies and FD cleanup (real iOS host authentication unverified)");
    }
    return 0;
}
