#import <Foundation/Foundation.h>
#import "../AxsCacheKeeperPDFInspection.h"
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <errno.h>
#include <string.h>

static void axs_cachekeeper_pdf_test_require(BOOL ok,const char *message) {
    if (!ok) { fprintf(stderr,"FAIL: PDF inspection: %s\n",message);exit(1); }
}
static NSString *axs_cachekeeper_pdf_test_directory(NSString *parent,NSString *relative) {
    NSString *path=[parent stringByAppendingPathComponent:relative];
    axs_cachekeeper_pdf_test_require([NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil],"create dedicated real fixture directory");return path;
}
static void axs_cachekeeper_pdf_test_file(NSString *path,BOOL pdf,NSUInteger size) {
    NSMutableData *data=[NSMutableData dataWithLength:size];
    if (size) memset(data.mutableBytes,'x',size);
    if (pdf && size>=5) memcpy(data.mutableBytes,"%PDF-",5);
    axs_cachekeeper_pdf_test_require([data writeToFile:path options:0 error:nil],"write real fixture file");
}
static int axs_cachekeeper_pdf_test_root(NSString *root) {
    int fd=open(root.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);
    axs_cachekeeper_pdf_test_require(fd>=0,"open real container fixture FD");return fd;
}
static NSDictionary *axs_cachekeeper_pdf_test_finish(AxsCacheKeeperPDFInspection *inspection) {
    for (NSUInteger i=0;i<500 && !inspection.complete;i++) [inspection advance:64];
    axs_cachekeeper_pdf_test_require(inspection.complete,"bounded engine reaches terminal state");return inspection.report;
}
static AxsCacheKeeperPDFInspection *axs_cachekeeper_pdf_test_engine(NSString *root,NSString *relative,AxsCacheKeeperPDFInspectionLimits limits,
                                                                  NSTimeInterval (^clock)(void),void (^boundary)(NSString *),ssize_t (^readBlock)(int,void *,size_t)) {
    int fd=axs_cachekeeper_pdf_test_root(root);
    AxsCacheKeeperPDFInspection *engine=[[AxsCacheKeeperPDFInspection alloc] initWithContainerFD:fd relativeDirectory:relative limits:limits clock:clock beforeRead:boundary read:readBlock];
    close(fd);return engine;
}

void axs_cachekeeper_run_pdf_inspection_tests(NSString *fixture) {
    @autoreleasepool {
        NSString *base=axs_cachekeeper_pdf_test_directory(fixture,@"pdf-inspection");
        AxsCacheKeeperPDFInspectionLimits defaults=axs_cachekeeper_pdf_inspection_limits();
        NSString *root=axs_cachekeeper_pdf_test_directory(base,@"formats");
        NSString *chosen=axs_cachekeeper_pdf_test_directory(root,@"Library/Caches");
        axs_cachekeeper_pdf_test_file([chosen stringByAppendingPathComponent:@"no-extension"],YES,6);
        axs_cachekeeper_pdf_test_file([chosen stringByAppendingPathComponent:@"small.pdf"],YES,5);
        NSString *hard=[chosen stringByAppendingPathComponent:@"hard.pdf"];
        axs_cachekeeper_pdf_test_file(hard,YES,15);
        axs_cachekeeper_pdf_test_require(link(hard.fileSystemRepresentation,[chosen stringByAppendingPathComponent:@"hard-copy"].fileSystemRepresentation)==0,"create actual hard link");
        for (NSUInteger i=0;i<9;i++) axs_cachekeeper_pdf_test_file([chosen stringByAppendingPathComponent:[NSString stringWithFormat:@"candidate-%lu",(unsigned long)i]],YES,100+i);
        axs_cachekeeper_pdf_test_file([chosen stringByAppendingPathComponent:@"misleading.pdf"],NO,32768);
        NSString *neighbor=axs_cachekeeper_pdf_test_directory(root,@"Library/Neighbor");
        axs_cachekeeper_pdf_test_file([neighbor stringByAppendingPathComponent:@"unselected.pdf"],YES,20);
        axs_cachekeeper_pdf_test_require(symlink(neighbor.fileSystemRepresentation,[chosen stringByAppendingPathComponent:@"neighbor-link"].fileSystemRepresentation)==0,"create real directory symlink");
        axs_cachekeeper_pdf_test_require(mkfifo([chosen stringByAppendingPathComponent:@"pipe"].fileSystemRepresentation,0600)==0,"create real FIFO");
        NSArray *before=[[NSFileManager.defaultManager subpathsAtPath:root] sortedArrayUsingSelector:@selector(compare:)];
        NSMutableArray *reads=[NSMutableArray new];
        AxsCacheKeeperPDFInspection *engine=axs_cachekeeper_pdf_test_engine(root,@"Library/Caches",defaults,nil,^(NSString *relative){[reads addObject:relative];},nil);
        NSDictionary *report=axs_cachekeeper_pdf_test_finish(engine);
        axs_cachekeeper_pdf_test_require([report[@"inspectionMode"] isEqual:@"pdfLocate"] && [report[@"stopReason"] isEqual:@"finished"] &&
            [report[@"pdfPathCount"] unsignedIntegerValue]==13 && [report[@"pdfCandidates"] count]==10 && [report[@"pdfCandidatesTruncated"] boolValue],"normal, tiny, extensionless and hard-linked PDFs share detection and bounded candidate list");
        axs_cachekeeper_pdf_test_require([report[@"symbolicLinkCount"] unsignedIntegerValue]==1 && [report[@"specialFileCount"] unsignedIntegerValue]==1 &&
            ![report[@"coverageComplete"] boolValue],"symlink and FIFO are skipped and coverage is explicit");
        uint64_t previous=UINT64_MAX;
        for (NSDictionary *row in report[@"pdfCandidates"]) {
            axs_cachekeeper_pdf_test_require([row[@"path"] hasPrefix:@"Library/Caches/"] && ![row[@"path"] hasPrefix:@"/"] &&
                [row[@"bytes"] unsignedLongLongValue]<=previous,"candidate paths stay container-relative and sorted by size");previous=[row[@"bytes"] unsignedLongLongValue];
        }
        for (NSString *relative in reads) axs_cachekeeper_pdf_test_require([relative hasPrefix:@"Library/Caches/"] && ![relative containsString:@"neighbor-link"],"only selected directory is read, without following adjacent-root link");
        NSArray *after=[[NSFileManager.defaultManager subpathsAtPath:root] sortedArrayUsingSelector:@selector(compare:)];
        axs_cachekeeper_pdf_test_require([before isEqual:after],"inspection creates zero report or other files");
        NSData *json=[NSJSONSerialization dataWithJSONObject:report options:0 error:nil];NSString *text=[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
        axs_cachekeeper_pdf_test_require(json && ![text containsString:@"%PDF-"] && ![text containsString:root],"memory report excludes content samples and absolute container path");

        NSString *protectedRoot=axs_cachekeeper_pdf_test_directory(base,@"protected");
        NSString *protected=axs_cachekeeper_pdf_test_directory(protectedRoot,@"Library/Preferences/nested");
        axs_cachekeeper_pdf_test_file([protected stringByAppendingPathComponent:@"secret"],YES,30);
        axs_cachekeeper_pdf_test_require(link([protected stringByAppendingPathComponent:@"secret"].fileSystemRepresentation,[protected stringByAppendingPathComponent:@"secret-twin"].fileSystemRepresentation)==0,"create hard link inside protected parent");
        __block NSUInteger protectedReads=0;
        engine=axs_cachekeeper_pdf_test_engine(protectedRoot,@"Library/Preferences/nested",defaults,nil,^(NSString *path){(void)path;protectedReads++;},nil);
        report=axs_cachekeeper_pdf_test_finish(engine);
        axs_cachekeeper_pdf_test_require(protectedReads==0 && [report[@"protectedCount"] unsignedIntegerValue]>0 && ![report[@"coverageComplete"] boolValue],"selected sensitive parent prefix is checked using the full container-relative path");
        engine=axs_cachekeeper_pdf_test_engine(protectedRoot,@"Library",defaults,nil,^(NSString *path){(void)path;protectedReads++;},nil);
        report=axs_cachekeeper_pdf_test_finish(engine);
        axs_cachekeeper_pdf_test_require(protectedReads==0 && [report[@"protectedCount"] unsignedIntegerValue]>0,"enumerated sensitive subtree is excluded before ordinary or hard-linked content reads");
        for (NSString *relative in @[@"",@"/Library",@"Caches/../Library",@"Caches//a",@"Caches/."]) {
            engine=axs_cachekeeper_pdf_test_engine(protectedRoot,relative,defaults,nil,nil,nil);
            axs_cachekeeper_pdf_test_require(engine.complete && [engine.report[@"stopReason"] isEqual:@"error"] && [engine.report[@"sampleBytes"] unsignedLongLongValue]==0,"invalid relative input cannot open or sample a path");
        }

        NSString *nestedSecret=axs_cachekeeper_pdf_test_directory(protectedRoot,@"Library/Caches/account-session");
        axs_cachekeeper_pdf_test_file([nestedSecret stringByAppendingPathComponent:@"private"],YES,40);
        report=axs_cachekeeper_pdf_test_finish(axs_cachekeeper_pdf_test_engine(protectedRoot,@"Library/Caches",defaults,nil,^(NSString *path){(void)path;protectedReads++;},nil));
        axs_cachekeeper_pdf_test_require(protectedReads==0 && [report[@"protectedCount"] unsignedIntegerValue]>0,"nested account and credential paths are excluded before content reads");
        axs_cachekeeper_pdf_test_require(CFGetTypeID((__bridge CFTypeRef)report[@"complete"])==CFBooleanGetTypeID() &&
            CFGetTypeID((__bridge CFTypeRef)report[@"coverageComplete"])==CFBooleanGetTypeID() &&
            CFGetTypeID((__bridge CFTypeRef)report[@"pdfCandidatesTruncated"])==CFBooleanGetTypeID(),"report booleans retain strict CFBoolean types for unified export");

        NSString *budgetRoot=axs_cachekeeper_pdf_test_directory(base,@"budgets");NSString *budgetDir=axs_cachekeeper_pdf_test_directory(budgetRoot,@"Caches");
        for (NSUInteger i=0;i<100;i++) axs_cachekeeper_pdf_test_file([budgetDir stringByAppendingPathComponent:[NSString stringWithFormat:@"file-%lu",(unsigned long)i]],YES,12);
        engine=axs_cachekeeper_pdf_test_engine(budgetRoot,@"Caches",defaults,nil,nil,nil);[engine advance:NSUIntegerMax];
        axs_cachekeeper_pdf_test_require([engine.report[@"enumeratedCount"] unsignedIntegerValue]==64 && !engine.complete,"one advance is capped at 64 actual entries");[engine cancel];
        AxsCacheKeeperPDFInspectionLimits limits=defaults;limits.entryLimit=2;
        report=axs_cachekeeper_pdf_test_finish(axs_cachekeeper_pdf_test_engine(budgetRoot,@"Caches",limits,nil,nil,nil));
        axs_cachekeeper_pdf_test_require([report[@"stopReason"] isEqual:@"entryLimit"] && [report[@"enumeratedCount"] unsignedIntegerValue]==2 && ![report[@"coverageComplete"] boolValue],"entry budget stops with bounded partial coverage");
        limits=defaults;limits.sampleByteLimit=5;
        report=axs_cachekeeper_pdf_test_finish(axs_cachekeeper_pdf_test_engine(budgetRoot,@"Caches",limits,nil,nil,nil));
        axs_cachekeeper_pdf_test_require([report[@"stopReason"] isEqual:@"byteLimit"] && [report[@"sampleBytes"] unsignedLongLongValue]==5,"actual byte budget caps even the last per-file read");
        __block NSTimeInterval now=0;__block NSUInteger timedReads=0;
        engine=axs_cachekeeper_pdf_test_engine(budgetRoot,@"Caches",defaults,^NSTimeInterval{return now;},^(NSString *path){(void)path;now=6;},^ssize_t(int fd,void *data,size_t count){timedReads++;return pread(fd,data,count,0);});
        report=axs_cachekeeper_pdf_test_finish(engine);
        axs_cachekeeper_pdf_test_require([report[@"stopReason"] isEqual:@"timeLimit"] && timedReads==0 && [report[@"sampleBytes"] unsignedLongLongValue]==0,"monotonic budget checked again immediately before content read");
        limits=(AxsCacheKeeperPDFInspectionLimits){NSUIntegerMax,UINT64_MAX,1000,NSUIntegerMax,NSUIntegerMax};
        engine=axs_cachekeeper_pdf_test_engine(budgetRoot,@"Caches",limits,nil,nil,nil);NSDictionary *effective=engine.report[@"budgets"];
        axs_cachekeeper_pdf_test_require([effective[@"entryLimit"] unsignedIntegerValue]==10000 && [effective[@"sampleByteLimit"] unsignedLongLongValue]==16777216 &&
            [effective[@"seconds"] doubleValue]==5 && [effective[@"depthLimit"] unsignedIntegerValue]==32 && [effective[@"descriptorLimit"] unsignedIntegerValue]==34,"test seams cannot enlarge production budgets");
        [engine cancel];[engine advance:64];report=engine.report;
        axs_cachekeeper_pdf_test_require([report[@"stopReason"] isEqual:@"cancelled"] && [report[@"pdfCandidates"] count]==0 && [report[@"openDescriptorCount"] unsignedIntegerValue]==0,"cancel clears candidates and closes owned directory FDs");

        NSString *raceRoot=axs_cachekeeper_pdf_test_directory(base,@"file-race");NSString *raceDir=axs_cachekeeper_pdf_test_directory(raceRoot,@"Caches");
        NSString *raceFile=[raceDir stringByAppendingPathComponent:@"only"];
        axs_cachekeeper_pdf_test_file(raceFile,YES,16);__block NSUInteger racedReads=0;__block BOOL replaced=NO;
        engine=axs_cachekeeper_pdf_test_engine(raceRoot,@"Caches",defaults,nil,^(NSString *relative){
            (void)relative;if (!replaced) {replaced=YES;axs_cachekeeper_pdf_test_require(rename(raceFile.fileSystemRepresentation,[raceRoot stringByAppendingPathComponent:@"moved-original"].fileSystemRepresentation)==0,"replace real file after open");axs_cachekeeper_pdf_test_file(raceFile,YES,16);}
        },^ssize_t(int fd,void *data,size_t count){racedReads++;return pread(fd,data,count,0);});
        [engine advance:1];report=engine.report;
        axs_cachekeeper_pdf_test_require(racedReads==0 && [report[@"changedCount"] unsignedIntegerValue]>0 && [report[@"pdfPathCount"] unsignedIntegerValue]==0,"replacement after open is caught by parent-entry identity before read");[engine cancel];

        NSString *moveRoot=axs_cachekeeper_pdf_test_directory(base,@"ancestor-race");NSString *moveDir=axs_cachekeeper_pdf_test_directory(moveRoot,@"Caches/sub");
        axs_cachekeeper_pdf_test_file([moveDir stringByAppendingPathComponent:@"only"],YES,16);__block BOOL moved=NO;__block NSUInteger movedReads=0;
        engine=axs_cachekeeper_pdf_test_engine(moveRoot,@"Caches/sub",defaults,nil,^(NSString *relative){
            (void)relative;if (!moved) {moved=YES;axs_cachekeeper_pdf_test_require(rename(moveDir.fileSystemRepresentation,[moveRoot stringByAppendingPathComponent:@"moved-away"].fileSystemRepresentation)==0,"move real held ancestor outside selected path");}
        },^ssize_t(int fd,void *data,size_t count){movedReads++;return pread(fd,data,count,0);});
        report=axs_cachekeeper_pdf_test_finish(engine);
        axs_cachekeeper_pdf_test_require(movedReads==0 && [report[@"changedCount"] unsignedIntegerValue]>0 && [report[@"stopReason"] isEqual:@"error"],"held ancestor FD cannot continue reading after its path edge is removed");

        NSString *postRoot=axs_cachekeeper_pdf_test_directory(base,@"post-read-race");NSString *postDir=axs_cachekeeper_pdf_test_directory(postRoot,@"Caches");
        NSString *postFile=[postDir stringByAppendingPathComponent:@"only"];axs_cachekeeper_pdf_test_file(postFile,YES,16);
        engine=axs_cachekeeper_pdf_test_engine(postRoot,@"Caches",defaults,nil,nil,^ssize_t(int fd,void *data,size_t count){
            ssize_t actual=pread(fd,data,count,0);
            axs_cachekeeper_pdf_test_require(rename(postFile.fileSystemRepresentation,[postRoot stringByAppendingPathComponent:@"old"].fileSystemRepresentation)==0,"replace path after actual sample read");
            axs_cachekeeper_pdf_test_file(postFile,YES,16);return actual;
        });
        [engine advance:1];report=engine.report;
        axs_cachekeeper_pdf_test_require([report[@"sampleBytes"] unsignedLongLongValue]==16 && [report[@"changedCount"] unsignedIntegerValue]>0 && [report[@"pdfPathCount"] unsignedIntegerValue]==0,"post-read path replacement rejects the sampled candidate");[engine cancel];

        NSString *readsRoot=axs_cachekeeper_pdf_test_directory(base,@"read-results");NSString *readsDir=axs_cachekeeper_pdf_test_directory(readsRoot,@"Caches");
        axs_cachekeeper_pdf_test_file([readsDir stringByAppendingPathComponent:@"only"],YES,20);
        report=axs_cachekeeper_pdf_test_finish(axs_cachekeeper_pdf_test_engine(readsRoot,@"Caches",defaults,nil,nil,nil));
        axs_cachekeeper_pdf_test_require([report[@"coverageComplete"] boolValue] && [report[@"pdfPathCount"] unsignedIntegerValue]==1,"stable fully visited selected directory reports complete coverage");
        report=axs_cachekeeper_pdf_test_finish(axs_cachekeeper_pdf_test_engine(readsRoot,@"Caches",defaults,nil,nil,^ssize_t(int fd,void *data,size_t count){return pread(fd,data,MIN(count,(size_t)3),0);}));
        axs_cachekeeper_pdf_test_require([report[@"shortReadCount"] unsignedIntegerValue]==1 && [report[@"sampleBytes"] unsignedLongLongValue]==3 && [report[@"pdfPathCount"] unsignedIntegerValue]==0,"real short pread is counted separately and its prefix is not accepted");
        report=axs_cachekeeper_pdf_test_finish(axs_cachekeeper_pdf_test_engine(readsRoot,@"Caches",defaults,nil,nil,^ssize_t(int fd,void *data,size_t count){(void)fd;(void)data;(void)count;errno=EACCES;return -1;}));
        axs_cachekeeper_pdf_test_require([report[@"readFailureCount"] unsignedIntegerValue]==1 && [report[@"errorCode"] intValue]==EACCES && [report[@"sampleBytes"] unsignedLongLongValue]==0,"injected permission error is preserved without pretending content was read");
        now=0;
        report=axs_cachekeeper_pdf_test_finish(axs_cachekeeper_pdf_test_engine(readsRoot,@"Caches",defaults,^NSTimeInterval{return now;},nil,^ssize_t(int fd,void *data,size_t count){ssize_t actual=pread(fd,data,count,0);now=6;return actual;}));
        axs_cachekeeper_pdf_test_require([report[@"stopReason"] isEqual:@"timeLimit"] && [report[@"sampleBytes"] unsignedLongLongValue]==20 && [report[@"pdfPathCount"] unsignedIntegerValue]==0,"time spent in read is counted and late candidate is not restored");
        __block int activeFD=-1;__block __weak AxsCacheKeeperPDFInspection *weakEngine;
        engine=axs_cachekeeper_pdf_test_engine(readsRoot,@"Caches",defaults,nil,nil,^ssize_t(int fd,void *data,size_t count){activeFD=fd;ssize_t result=pread(fd,data,count,0);[weakEngine cancel];return result;});weakEngine=engine;
        [engine advance:64];report=engine.report;errno=0;
        axs_cachekeeper_pdf_test_require([report[@"stopReason"] isEqual:@"cancelled"] && [report[@"pdfCandidates"] count]==0 && activeFD>=0 && fcntl(activeFD,F_GETFD)==-1 && errno==EBADF,"cancel during read clears late candidates and closes active file FD on return");

        dispatch_semaphore_t entered=dispatch_semaphore_create(0),resume=dispatch_semaphore_create(0),finished=dispatch_semaphore_create(0);
        engine=axs_cachekeeper_pdf_test_engine(readsRoot,@"Caches",defaults,nil,nil,^ssize_t(int fd,void *data,size_t count){
            ssize_t actual=pread(fd,data,count,0);dispatch_semaphore_signal(entered);
            dispatch_semaphore_wait(resume,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC));return actual;
        });
        AxsCacheKeeperPDFInspection *pending=engine;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{[pending advance:64];dispatch_semaphore_signal(finished);});
        axs_cachekeeper_pdf_test_require(dispatch_semaphore_wait(entered,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0,"background engine reached active read boundary");
        [engine requestCancellation];dispatch_semaphore_signal(resume);
        axs_cachekeeper_pdf_test_require(dispatch_semaphore_wait(finished,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0,"control cancellation never waits for held scan lock");
        report=engine.report;
        axs_cachekeeper_pdf_test_require([report[@"stopReason"] isEqual:@"cancelled"] && [report[@"pdfCandidates"] count]==0 && [report[@"openDescriptorCount"] unsignedIntegerValue]==0,"concurrent cancellation discards late read and releases FD chain");

        NSString *deepRoot=axs_cachekeeper_pdf_test_directory(base,@"depth");axs_cachekeeper_pdf_test_directory(deepRoot,@"Caches/one/two");
        limits=defaults;limits.depthLimit=2;
        report=axs_cachekeeper_pdf_test_finish(axs_cachekeeper_pdf_test_engine(deepRoot,@"Caches",limits,nil,nil,nil));
        axs_cachekeeper_pdf_test_require([report[@"depthLimitedCount"] unsignedIntegerValue]>0 && ![report[@"coverageComplete"] boolValue],"depth cap reports unvisited subtree");
        limits=defaults;limits.descriptorLimit=2;
        report=axs_cachekeeper_pdf_test_finish(axs_cachekeeper_pdf_test_engine(readsRoot,@"Caches",limits,nil,nil,nil));
        axs_cachekeeper_pdf_test_require([report[@"fdLimitedCount"] unsignedIntegerValue]>0 && [report[@"sampleBytes"] unsignedLongLongValue]==0 && ![report[@"coverageComplete"] boolValue],"descriptor cap cannot be bypassed by opening a file");
        puts("PASS: PDF FD traversal, real file fixtures, fixed budgets, boundary error/race injection and cancellation (iOS container permissions unverified)");
    }
}
