#import <Foundation/Foundation.h>
#import "../AxsCacheKeeperPDFSessionPrivate.h"
#import "../AxsCacheKeeperDiagnostics.h"
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

static void axs_cachekeeper_pdf_session_require(BOOL condition,const char *message) {
    if (!condition) {fprintf(stderr,"FAIL: PDF session: %s\n",message);exit(1);}
}
static NSMutableDictionary *axs_cachekeeper_pdf_session_request(NSString *service) {
    return [@{@"operation":service.length ? @"poll" : @"probe",@"bundle":@"test.pdf.app",@"relative":@"Library/Caches",@"session":@"10000000-0000-0000-0000-000000000001",@"generation":@7,
        @"nonce":NSUUID.UUID.UUIDString,@"service":service,@"candidate":@10} mutableCopy];
}
static AxsCacheKeeperPDFBuffer axs_cachekeeper_pdf_session_receive_test(mach_port_t port) {
    AxsCacheKeeperPDFBuffer buffer={0};
    mach_msg_return_t result=mach_msg(&buffer.header,MACH_RCV_MSG|MACH_RCV_TIMEOUT|MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0)|MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT),0,sizeof(buffer),port,500,MACH_PORT_NULL);
    axs_cachekeeper_pdf_session_require(result==MACH_MSG_SUCCESS,"receive actual Mach message and kernel audit trailer");return buffer;
}
void axs_cachekeeper_run_pdf_session_tests(NSString *fixture) {
    @autoreleasepool {
        NSString *service=NSUUID.UUID.UUIDString;
        NSMutableDictionary *probe=axs_cachekeeper_pdf_session_request(@"");
        axs_cachekeeper_pdf_session_require(axs_cachekeeper_pdf_request_valid(probe),"single bundle and single relative directory request accepted");
        for (NSDictionary *change in @[@{@"roots":@[@"/tmp"]},@{@"budget":@1000000},@{@"relative":@"/tmp"},@{@"relative":@"Caches/../secret"},@{@"relative":@"Group/other/cache"},@{@"relative":@"Library/Caches/account-secret"},@{@"generation":@YES},@{@"candidate":@0},@{@"operation":@"delete"}]) {
            NSMutableDictionary *bad=[probe mutableCopy];[bad addEntriesFromDictionary:change];
            axs_cachekeeper_pdf_session_require(!axs_cachekeeper_pdf_request_valid(bad),"reject roots, budget override, traversal, sensitive scope and extra operations");
        }
        audit_token_t client={{1,2,3,4,5,6,7,8}},server={{9,10,11,12,13,14,15,16}};
        AxsCacheKeeperPDFBinding *binding=[[AxsCacheKeeperPDFBinding alloc] initWithService:service client:client server:server request:probe now:10];
        NSMutableDictionary *poll=axs_cachekeeper_pdf_session_request(service);
        axs_cachekeeper_pdf_session_require([binding accept:poll client:client server:server now:11],"bind full audit identities, service, generation and session");
        axs_cachekeeper_pdf_session_require(![binding accept:poll client:client server:server now:12],"duplicate nonce rejected");
        for (NSString *key in @[@"service",@"session",@"generation",@"bundle",@"relative"]) {
            NSMutableDictionary *bad=axs_cachekeeper_pdf_session_request(service);bad[key]=[key isEqual:@"generation"] ? @8 : ([key isEqual:@"bundle"] ? @"test.other.app" : ([key isEqual:@"relative"] ? @"tmp" : NSUUID.UUID.UUIDString));
            axs_cachekeeper_pdf_session_require(![binding accept:bad client:client server:server now:12],"stale service, generation, bundle and directory cannot enter a bound session");
        }
        audit_token_t changed=client;changed.val[7]++;
        axs_cachekeeper_pdf_session_require(![binding accept:axs_cachekeeper_pdf_session_request(service) client:changed server:server now:12],"same PID with new process incarnation is rejected");
        changed=server;changed.val[0]++;
        axs_cachekeeper_pdf_session_require(![binding accept:axs_cachekeeper_pdf_session_request(service) client:client server:changed now:12],"every server audit word is bound");
        axs_cachekeeper_pdf_session_require([binding expired:21] && ![binding accept:axs_cachekeeper_pdf_session_request(service) client:client server:server now:22],"lease expiry cannot be renewed by a late request");
        [binding invalidate];axs_cachekeeper_pdf_session_require(![binding accept:axs_cachekeeper_pdf_session_request(service) client:client server:server now:13],"cancelled binding cannot be restored");

        mach_port_t port=MACH_PORT_NULL,replyPort=MACH_PORT_NULL;
        axs_cachekeeper_pdf_session_require(mach_port_allocate(mach_task_self(),MACH_PORT_RIGHT_RECEIVE,&port)==KERN_SUCCESS &&
            mach_port_insert_right(mach_task_self(),port,port,MACH_MSG_TYPE_MAKE_SEND)==KERN_SUCCESS &&
            mach_port_allocate(mach_task_self(),MACH_PORT_RIGHT_RECEIVE,&replyPort)==KERN_SUCCESS,"allocate real protocol endpoints");
        AxsCacheKeeperPDFMessage message;
        axs_cachekeeper_pdf_session_require(axs_cachekeeper_pdf_encode(&message,probe,NO,port,replyPort),"encode production request");
        axs_cachekeeper_pdf_session_require(mach_msg(&message.header,MACH_SEND_MSG|MACH_SEND_TIMEOUT,message.header.msgh_size,0,MACH_PORT_NULL,500,MACH_PORT_NULL)==MACH_MSG_SUCCESS,"send actual request");
        AxsCacheKeeperPDFBuffer received=axs_cachekeeper_pdf_session_receive_test(port);NSDictionary *decoded=nil;audit_token_t actual;
        axs_cachekeeper_pdf_session_require(axs_cachekeeper_pdf_decode(&received,sizeof(received),port,NO,&decoded,&actual) && [decoded isEqual:probe] && actual.val[5]==(uint32_t)getpid(),"production decoder uses kernel-provided sender identity");
        AxsCacheKeeperPDFMessage *wire=(void *)&received;
        uint32_t savedVersion=wire->version;wire->version=2;axs_cachekeeper_pdf_session_require(!axs_cachekeeper_pdf_decode(&received,sizeof(received),port,NO,&decoded,&actual),"reject unknown wire version");wire->version=savedVersion;
        uint32_t savedLength=wire->length;wire->length=AxsCacheKeeperPDFRequestLimit+1;axs_cachekeeper_pdf_session_require(!axs_cachekeeper_pdf_decode(&received,sizeof(received),port,NO,&decoded,&actual),"reject over-budget wire payload");wire->length=savedLength;
        axs_cachekeeper_pdf_session_require(!axs_cachekeeper_pdf_decode(&received,wire->header.msgh_size,port,NO,&decoded,&actual),"reject missing or truncated audit trailer");
        axs_cachekeeper_pdf_destroy(&received);
        struct {mach_msg_header_t header;mach_msg_body_t body;} complex={0};
        complex.header=(mach_msg_header_t){.msgh_bits=MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND,MACH_MSG_TYPE_MAKE_SEND_ONCE)|MACH_MSGH_BITS_COMPLEX,.msgh_size=sizeof(complex),.msgh_remote_port=port,.msgh_local_port=replyPort,.msgh_id=AxsCacheKeeperPDFRequestID};
        axs_cachekeeper_pdf_session_require(mach_msg(&complex.header,MACH_SEND_MSG|MACH_SEND_TIMEOUT,sizeof(complex),0,MACH_PORT_NULL,500,MACH_PORT_NULL)==MACH_MSG_SUCCESS,"deliver actual complex message");
        received=axs_cachekeeper_pdf_session_receive_test(port);mach_port_t deliveredReply=received.header.msgh_remote_port;
        axs_cachekeeper_pdf_session_require(!axs_cachekeeper_pdf_decode(&received,sizeof(received),port,NO,&decoded,&actual),"complex message rejected before parsing");axs_cachekeeper_pdf_destroy(&received);
        mach_port_type_t type=0;axs_cachekeeper_pdf_session_require(mach_port_type(mach_task_self(),deliveredReply,&type)!=KERN_SUCCESS,"rejected delivered send-once right released");
        axs_cachekeeper_channel_release_receive(replyPort,NO);axs_cachekeeper_channel_release_receive(port,YES);

        NSDictionary *status=@{@"state":@"ready",@"stage":@"directoryOpen",@"errorCode":@0,@"containerReadable":@YES};
        NSMutableDictionary *response=[@{@"operation":probe[@"operation"],@"nonce":probe[@"nonce"],@"session":probe[@"session"],@"generation":probe[@"generation"],@"service":service,@"state":@"ready",@"report":status,@"directory":@""} mutableCopy];
        axs_cachekeeper_pdf_session_require(axs_cachekeeper_pdf_reply_matches(response,probe,@""),"first authenticated reply binds service instance");
        response[@"nonce"]=NSUUID.UUID.UUIDString;axs_cachekeeper_pdf_session_require(!axs_cachekeeper_pdf_reply_matches(response,probe,service),"late reply with wrong nonce cannot restore current request");response[@"nonce"]=probe[@"nonce"];
        axs_cachekeeper_pdf_session_require(!axs_cachekeeper_pdf_reply_matches(response,probe,NSUUID.UUID.UUIDString),"new service cannot satisfy an old session");
        response[@"report"]=@{@"state":@"ready",@"stage":@"directoryOpen",@"errorCode":@0,@"containerReadable":@1};axs_cachekeeper_pdf_session_require(!axs_cachekeeper_pdf_reply_matches(response,probe,service),"numeric truth is not proof of readable container");

        NSString *root=[fixture stringByAppendingPathComponent:@"pdf-session"],*directory=[root stringByAppendingPathComponent:@"Library/Caches/private-person"];
        axs_cachekeeper_pdf_session_require([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil],"create real session fixture");
        NSString *path=[directory stringByAppendingPathComponent:@"confidential-title.pdf"];
        axs_cachekeeper_pdf_session_require([[@"%PDF-test document" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:NO],"write actual PDF fixture");
        NSArray *before=[NSFileManager.defaultManager subpathsAtPath:root];int fd=open(root.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);
        AxsCacheKeeperPDFInspection *engine=[[AxsCacheKeeperPDFInspection alloc] initWithContainerFD:fd relativeDirectory:@"Library/Caches"];
        while (!engine.complete) [engine advance:64];
        NSMutableDictionary *snapshot=[engine.report mutableCopy];snapshot[@"state"]=@"finished";snapshot[@"stage"]=@"none";snapshot[@"containerReadable"]=@YES;
        snapshot[@"bundle"]=@"test.pdf.app";snapshot[@"path"]=@"Library/Caches/private-person";snapshot[@"audit"]=@"must-not-export";snapshot[@"sample"]=@"%PDF-test document";
        AxsCacheKeeperDiagnostics *diagnostics=[[AxsCacheKeeperDiagnostics alloc] initWithFolder:[root stringByAppendingPathComponent:@"missing-records"]];
        NSDictionary *report=[diagnostics reportWithApps:@[] environment:@{@"pdfLocate":snapshot}];
        NSData *json=[NSJSONSerialization dataWithJSONObject:report options:0 error:nil];NSString *text=[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
        axs_cachekeeper_pdf_session_require([report[@"pdfLocate"][@"state"] isEqual:@"finished"] && [report[@"pdfLocate"][@"pdfCandidates"] count]==1 &&
            ![text containsString:@"confidential-title"] && ![text containsString:@"private-person"] && ![text containsString:@"must-not-export"] && ![text containsString:@"%PDF-"] && ![text containsString:root],"same diagnostics report redacts candidate, scope, body and identity before JSON");
        axs_cachekeeper_pdf_session_require([report[@"pdfLocate"][@"pdfCandidates"][0][@"path"] hasPrefix:[report[@"pdfLocate"][@"path"] stringByAppendingString:@"/"]],"scope and candidate share one alias map in the same report");
        NSString *relative=@"Library/Caches/private-person/confidential-title.pdf";int error=0;
        axs_cachekeeper_pdf_session_require([engine revalidateCandidate:relative containerFD:fd error:&error],"only retained current candidate passes Filza gate");
        axs_cachekeeper_pdf_session_require(![engine revalidateCandidate:@"Library/Neighbor" containerFD:fd error:&error],"arbitrary non-candidate path rejected");
        axs_cachekeeper_pdf_session_require([before isEqual:[NSFileManager.defaultManager subpathsAtPath:root]],"engine and full report pipeline create zero files");
        NSString *replaced=[path stringByAppendingString:@".old"];axs_cachekeeper_pdf_session_require(rename(path.fileSystemRepresentation,replaced.fileSystemRepresentation)==0,"replace actual candidate");
        [@"%PDF-new document" writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
        axs_cachekeeper_pdf_session_require(![engine revalidateCandidate:relative containerFD:fd error:&error],"replaced candidate rejected before Filza delivery");
        [engine cancel];close(fd);

        __block NSDictionary *clientResult=nil,*busyResult=nil;
        AxsCacheKeeperPDFSession *first=[[AxsCacheKeeperPDFSession alloc] initWithBundle:@"test.pdf.app" relativeDirectory:@"Library/Caches"];
        AxsCacheKeeperPDFSession *second=[[AxsCacheKeeperPDFSession alloc] initWithBundle:@"test.pdf.app" relativeDirectory:@"tmp"];
        [first probe:^(NSDictionary *value){clientResult=value;}];[second probe:^(NSDictionary *value){busyResult=value;}];
        NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:3];while (!clientResult && deadline.timeIntervalSinceNow>0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        axs_cachekeeper_pdf_session_require([busyResult[@"state"] isEqual:@"busy"],"public client entry allows one active session");
        axs_cachekeeper_pdf_session_require([clientResult[@"state"] isEqual:@"unavailable"] && [clientResult[@"stage"] isEqual:@"selfIdentity"] && ![clientResult[@"containerReadable"] boolValue],"actual non-Preferences host cannot probe or claim container permission");
        [first cancel];[second cancel];
        puts("PASS: PDF strict Mach schema, kernel trailer boundaries, session identity/lease/replay, public host refusal and unified in-memory privacy (real iOS hosts unverified)");
    }
}
