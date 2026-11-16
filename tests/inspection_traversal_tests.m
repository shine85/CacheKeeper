#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dirent.h>
#include <fcntl.h>
#include <stdarg.h>
#include <sys/stat.h>
#include <unistd.h>
#import "../AxsCacheKeeperInspection.h"
#import "../AxsCacheKeeperInspectionStatus.h"

// Compile the actual implementation here. Only syscall race/error boundaries are
// intercepted; fixture enumeration, descriptors, links and header reads are real.
static void (^itBeforeOpen)(const char *);
static void (^itBeforeRead)(void);
static void (^itAfterRead)(void);
static BOOL itFailReads, itShortReads, itFailEnumeration;
static NSUInteger itReads;
static int it_openat(int fd,const char *name,int flags,...) {
    void (^hook)(const char *)=[itBeforeOpen copy];
    if (hook && !(flags&O_DIRECTORY) && !(flags&O_SEARCH)) hook(name);
    if (flags&O_CREAT) {
        va_list args;va_start(args,flags);mode_t mode=(mode_t)va_arg(args,int);va_end(args);
        return openat(fd,name,flags,mode);
    }
    return openat(fd,name,flags);
}
static ssize_t it_pread(int fd,void *buffer,size_t length,off_t offset) {
    itReads++;
    void (^before)(void)=[itBeforeRead copy];if (before) before();
    if (itFailReads) {errno=EIO;return -1;}
    ssize_t count=pread(fd,buffer,itShortReads ? MIN(length,(size_t)1) : length,offset);
    void (^after)(void)=[itAfterRead copy];if (after) after();
    return count;
}
static struct dirent *it_readdir(DIR *stream) {
    if (itFailEnumeration) {errno=EIO;return NULL;}
    return readdir(stream);
}
#define openat it_openat
#define pread it_pread
#define readdir it_readdir
#ifndef AXS_INSPECTION_SOURCE
#define AXS_INSPECTION_SOURCE "../AxsCacheKeeperInspection.m"
#endif
#include AXS_INSPECTION_SOURCE
#undef openat
#undef pread
#undef readdir

// This declaration also lets the old source compile for focused negative runs;
// those runs execute mapping/headers/root-replacement, never cancellation.
@interface AxsCacheKeeperInspection (InspectionTraversalTestDeclaration)
- (void)cancel;
@end

static void itcheck(BOOL value,NSString *message) {
    if (!value) {fprintf(stderr,"FAIL: %s\n",message.UTF8String);exit(1);}
}
static NSString *itdir(NSString *parent,NSString *name) {
    NSString *path=[parent stringByAppendingPathComponent:name];
    itcheck([NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil],@"create inspection fixture directory");
    return path;
}
static NSString *itput(NSString *parent,NSString *name,NSData *contents) {
    NSString *path=[parent stringByAppendingPathComponent:name];
    itcheck([contents writeToFile:path atomically:NO],@"write inspection fixture");return path;
}
static NSData *itdata(void) {return [@"ordinary fixture" dataUsingEncoding:NSUTF8StringEncoding];}
static NSDictionary *itfinish(AxsCacheKeeperInspection *inspection,NSUInteger batch) {
    for (NSUInteger n=0;!inspection.complete && n<20000;n++) [inspection advance:batch];
    itcheck(inspection.complete,@"bounded fixture inspection must finish");return inspection.report;
}
static void itfailure(NSDictionary *report,NSString *stage,NSString *domain,NSInteger code) {
    NSDictionary *expected=@{@"stage":stage,@"errorDomain":domain,@"errorCode":@(code)};
    itcheck([report[@"inspectionReadFailure"] isEqual:expected] &&
        [axs_cachekeeper_inspection_read_failure_projection(expected) isEqual:expected] &&
        ![report[@"coverageComplete"] boolValue],@"failure stage must survive the closed diagnostic projection");
}
static NSUInteger itfds(void) {
    NSUInteger count=0;for (int fd=0;fd<2048;fd++) if (fcntl(fd,F_GETFD)>=0) count++;return count;
}

@interface AxsCacheKeeperUnexpectedEnumerator : NSDirectoryEnumerator
@property(nonatomic) BOOL sent;
@end
@implementation AxsCacheKeeperUnexpectedEnumerator
- (id)nextObject {if (_sent) return nil;_sent=YES;return [NSURL fileURLWithPath:@"/cachekeeper-unregistered-enumerator-shape/payload"];}
- (NSUInteger)level {return 1;}
- (void)skipDescendants {}
@end
static IMP itOriginalEnumerator;
static NSDirectoryEnumerator *itUnexpectedEnumerator(id self,SEL selector,NSURL *url,NSArray *keys,
    NSDirectoryEnumerationOptions options,BOOL (^handler)(NSURL *,NSError *)) {
    (void)self;(void)selector;(void)url;(void)keys;(void)options;(void)handler;
    return [AxsCacheKeeperUnexpectedEnumerator new];
}
static void itmapping(NSString *fixture) {
    // Negative control: the old absolute-path adapter reports a boundary failure
    // for this Foundation result. The new FD traversal must read only the real,
    // authorized fixture regardless of that unused adapter's path spelling.
    NSString *root=itdir(fixture,@"mapping");itput(root,@"payload",itdata());
    Method method=class_getInstanceMethod(NSFileManager.class,@selector(enumeratorAtURL:includingPropertiesForKeys:options:errorHandler:));
    itOriginalEnumerator=method_setImplementation(method,(IMP)itUnexpectedEnumerator);
    NSDictionary *report=nil;
    @try {report=itfinish([[AxsCacheKeeperInspection alloc] initWithRoot:root],1);}
    @finally {method_setImplementation(method,itOriginalEnumerator);}
    itcheck([report[@"files"] isEqual:@1] && [report[@"failures"] isEqual:@0] && [report[@"coverageComplete"] boolValue],
        @"verified FD inspection must not depend on Foundation absolute path aliases");
}
static void itheaders(NSString *fixture) {
    NSString *root=itdir(fixture,@"headers");
    const unsigned char valid[16]="SQLite format 3";
    unsigned char invalid[16];memcpy(invalid,valid,16);invalid[15]='X';
    itput(root,@"valid.bin",[NSData dataWithBytes:valid length:16]);
    itput(root,@"invalid.bin",[NSData dataWithBytes:invalid length:16]);
    itput(root,@"truncated.bin",[NSData dataWithBytes:valid length:15]);
    NSDictionary *report=itfinish([[AxsCacheKeeperInspection alloc] initWithRoot:root],1);
    itcheck([report[@"files"] isEqual:@3] && [report[@"types"][@"SQLite 数据库"][@"count"] isEqual:@1],
        @"SQLite signature requires all 16 bytes including the terminal NUL");
}
static void itrootreplacement(NSString *fixture) {
    NSString *root=itdir(fixture,@"root-replacement");itput(root,@"old",itdata());
    AxsCacheKeeperInspection *inspection=[[AxsCacheKeeperInspection alloc] initWithRoot:root];
    itcheck(rename(root.fileSystemRepresentation,[[fixture stringByAppendingPathComponent:@"root-saved"] fileSystemRepresentation])==0,@"replace opened inspection root");
    itdir(fixture,@"root-replacement");itput(root,@"replacement",itdata());itReads=0;
    NSDictionary *report=itfinish(inspection,1);
    itcheck([report[@"files"] isEqual:@0] && [report[@"changed"] unsignedIntegerValue]>0 && itReads==0,
        @"replaced root must stop before reading either namespace");
    itfailure(report,@"rootRecheck",@"identity",0);
}
static void itancestorreplacement(NSString *fixture) {
    NSString *root=itdir(fixture,@"ancestor-replacement"),*parent=itdir(root,@"parent");itput(parent,@"payload",itdata());
    NSString *outside=itdir(fixture,@"ancestor-outside");NSString *canary=itput(outside,@"payload",itdata());
    AxsCacheKeeperInspection *inspection=[[AxsCacheKeeperInspection alloc] initWithRoot:root];[inspection advance:1];
    itcheck(rename(parent.fileSystemRepresentation,[[root stringByAppendingPathComponent:@"saved"] fileSystemRepresentation])==0 &&
        symlink(outside.fileSystemRepresentation,parent.fileSystemRepresentation)==0,@"replace opened ancestor with outside symlink");
    itReads=0;NSDictionary *report=itfinish(inspection,1);
    itcheck([report[@"files"] isEqual:@0] && [report[@"changed"] unsignedIntegerValue]>0 && itReads==0 &&
        [[NSData dataWithContentsOfFile:canary] isEqual:itdata()],@"ancestor replacement cannot read outside content");
    itfailure(report,@"ancestorRecheck",@"identity",0);
}
static void itfileopenreplacement(NSString *fixture) {
    NSString *root=itdir(fixture,@"file-open-replacement"),*path=itput(root,@"payload",itdata());
    NSString *outside=itput(fixture,@"outside-file",itdata());
    itBeforeOpen=^(const char *name) {
        if (strcmp(name,"payload")) return;
        itBeforeOpen=nil;
        itcheck(rename(path.fileSystemRepresentation,[[root stringByAppendingPathComponent:@"saved"] fileSystemRepresentation])==0 &&
            symlink(outside.fileSystemRepresentation,path.fileSystemRepresentation)==0,@"swap leaf before openat");
    };
    itReads=0;NSDictionary *report=itfinish([[AxsCacheKeeperInspection alloc] initWithRoot:root],1);itBeforeOpen=nil;
    itcheck([report[@"files"] isEqual:@0] && [report[@"failures"] unsignedIntegerValue]>0 && itReads==0,
        @"NOFOLLOW must reject a leaf swapped to a symlink before open");
    itcheck([[NSData dataWithContentsOfFile:outside] isEqual:itdata()],@"leaf swap preserves outside file");
}
static void itfilereadreplacement(NSString *fixture) {
    NSString *root=itdir(fixture,@"file-read-replacement"),*path=itput(root,@"payload",itdata());
    itAfterRead=^{
        itAfterRead=nil;
        itcheck(rename(path.fileSystemRepresentation,[[root stringByAppendingPathComponent:@"saved"] fileSystemRepresentation])==0,@"replace file after pread");
        itput(root,@"payload",itdata());
    };
    NSDictionary *report=itfinish([[AxsCacheKeeperInspection alloc] initWithRoot:root],1);itAfterRead=nil;
    itcheck([report[@"files"] isEqual:@0] && [report[@"changed"] unsignedIntegerValue]>0,
        @"file pathname replacement after reading invalidates the result");
    itfailure(report,@"fileRecheck",@"identity",0);
}
static void ithiddenlinks(NSString *fixture) {
    NSString *root=itdir(fixture,@"hidden-links");itput(root,@"visible",itdata());
    NSString *documents=itdir(root,@"Documents"),*downloads=itdir(root,@"Downloads");
    itput(documents,@"private",itdata());itput(downloads,@"private",itdata());
    NSString *hard=itput(root,@"hard-a",itdata());
    itcheck(link(hard.fileSystemRepresentation,[[root stringByAppendingPathComponent:@"hard-b"] fileSystemRepresentation])==0,@"create read-only hardlink fixture");
    NSString *outside=itdir(fixture,@"hidden-outside");itput(outside,@"private",itdata());
    itcheck(symlink(outside.fileSystemRepresentation,[[root stringByAppendingPathComponent:@"external-link"] fileSystemRepresentation])==0 &&
        symlink(root.fileSystemRepresentation,[[root stringByAppendingPathComponent:@"loop"] fileSystemRepresentation])==0,@"create descendant link fixtures");
    itReads=0;NSDictionary *report=itfinish([[AxsCacheKeeperInspection alloc] initWithRoot:root searchRoots:@[]],1);
    itcheck([report[@"files"] isEqual:@1] && [report[@"hidden"] isEqual:@2] && [report[@"hardLinks"] isEqual:@2] &&
        [report[@"symlinks"] isEqual:@2] && itReads==1,@"hidden descendants and hardlinks never reach header reads");
}
static void ittwins(NSString *fixture) {
    NSString *source=itdir(fixture,@"twins-source"),*other=itdir(fixture,@"twins-other"),*nested=itdir(other,@"nested");
    NSString *path=itput(source,@"resource",itdata());
    itcheck(link(path.fileSystemRepresentation,[[nested stringByAppendingPathComponent:@"twin"] fileSystemRepresentation])==0,@"create nested twin");
    NSString *alias=[fixture stringByAppendingPathComponent:@"twins-alias"];
    itcheck(symlink(fixture.fileSystemRepresentation,alias.fileSystemRepresentation)==0,@"create ancestor alias for twin search");
    NSArray *roots=@[@{@"path":[source stringByAppendingString:@"/"],@"label":@"self"},
        @{@"path":[alias stringByAppendingPathComponent:@"twins-other"],@"label":@"other"}];
    itReads=0;NSDictionary *report=itfinish([[AxsCacheKeeperInspection alloc] initWithRoot:source searchRoots:roots],1);
    itcheck([report[@"files"] isEqual:@0] && [report[@"linkTwins"] count]==1 &&
        [report[@"linkTwins"][0][@"twin"] isEqual:@"other/nested/twin"] && [report[@"twinCoverageComplete"] boolValue] && itReads==0,
        @"twin walker preserves full relative paths and excludes the same directory entry");
    AxsCacheKeeperInspection *limited=[[AxsCacheKeeperInspection alloc] initWithRoot:source searchRoots:roots searchLimit:1 stat:nil];
    NSDictionary *limitedReport=itfinish(limited,1);
    itcheck([limitedReport[@"twinScanned"] isEqual:@1] && [limitedReport[@"twinScanTruncated"] boolValue] &&
        ![limitedReport[@"twinCoverageComplete"] boolValue],@"twin entry budget remains exact");
    NSString *protectedRoot=itdir(fixture,@"twins-protected"),*documents=itdir(protectedRoot,@"Documents");
    itcheck(link(path.fileSystemRepresentation,[[documents stringByAppendingPathComponent:@"private-twin"] fileSystemRepresentation])==0,
        @"create protected twin fixture");
    report=itfinish([[AxsCacheKeeperInspection alloc] initWithRoot:source searchRoots:@[@{@"path":protectedRoot,@"label":@"protected"}]],1);
    itcheck([report[@"coverageComplete"] boolValue] && [report[@"twinHidden"] isEqual:@1] &&
        [report[@"twinFailures"] isEqual:@0] && ![report[@"twinCoverageComplete"] boolValue] &&
        [report[@"linkTwins"] count]==0 && itReads==0,@"protected twin descendants stay unread and cannot claim complete coverage");
}
static void ittwinreplacement(NSString *fixture) {
    NSString *source=itdir(fixture,@"twin-replacement-source"),*search=itdir(fixture,@"twin-replacement-search");
    NSString *path=itput(source,@"resource",itdata());
    itcheck(link(path.fileSystemRepresentation,[[search stringByAppendingPathComponent:@"twin"] fileSystemRepresentation])==0,
        @"create twin root replacement fixture");
    AxsCacheKeeperInspection *inspection=[[AxsCacheKeeperInspection alloc] initWithRoot:source searchRoots:@[@{@"path":search,@"label":@"search"}]];
    [inspection advance:1];[inspection advance:1];
    itcheck(!inspection.complete && [inspection.report[@"hardLinks"] isEqual:@1] && [inspection.report[@"twinScanned"] isEqual:@0],
        @"real primary traversal opens the twin root before replacement");
    itcheck(rename(search.fileSystemRepresentation,[[fixture stringByAppendingPathComponent:@"twin-replacement-saved"] fileSystemRepresentation])==0,
        @"rename opened twin root");
    itdir(fixture,@"twin-replacement-search");itput(search,@"replacement",itdata());itReads=0;
    NSDictionary *report=itfinish(inspection,1);
    NSDictionary *expected=@{@"stage":@"rootRecheck",@"errorDomain":@"identity",@"errorCode":@0};
    itcheck([report[@"coverageComplete"] boolValue] && [report[@"twinFailures"] isEqual:@1] &&
        ![report[@"twinCoverageComplete"] boolValue] && [report[@"linkTwins"] count]==0 && itReads==0 &&
        [report[@"inspectionReadFailure"] isEqual:expected] && [axs_cachekeeper_inspection_read_failure_projection(expected) isEqual:expected],
        @"twin root replacement invalidates only twin coverage and cannot read either namespace");

    source=itdir(fixture,@"twin-ancestor-source");search=itdir(fixture,@"twin-ancestor-search");
    NSString *nested=itdir(search,@"nested"),*outside=itdir(fixture,@"twin-ancestor-outside");
    path=itput(source,@"resource",itdata());NSString *canary=itput(outside,@"canary",itdata());
    itcheck(link(path.fileSystemRepresentation,[[nested stringByAppendingPathComponent:@"twin"] fileSystemRepresentation])==0,
        @"create twin ancestor replacement fixture");
    inspection=[[AxsCacheKeeperInspection alloc] initWithRoot:source searchRoots:@[@{@"path":search,@"label":@"search"}]];
    [inspection advance:1];[inspection advance:1];[inspection advance:1];
    itcheck(!inspection.complete && [inspection.report[@"twinScanned"] isEqual:@1],@"open twin ancestor before replacement");
    itcheck(rename(nested.fileSystemRepresentation,[[search stringByAppendingPathComponent:@"saved"] fileSystemRepresentation])==0 &&
        symlink(outside.fileSystemRepresentation,nested.fileSystemRepresentation)==0,@"replace twin ancestor with external symlink");
    itReads=0;report=itfinish(inspection,1);
    expected=@{@"stage":@"ancestorRecheck",@"errorDomain":@"identity",@"errorCode":@0};
    itcheck([report[@"coverageComplete"] boolValue] && [report[@"twinFailures"] isEqual:@1] &&
        ![report[@"twinCoverageComplete"] boolValue] && [report[@"linkTwins"] count]==0 && itReads==0 &&
        [report[@"inspectionReadFailure"] isEqual:expected] && [[NSData dataWithContentsOfFile:canary] isEqual:itdata()],
        @"twin ancestor replacement stops before outside traversal while preserving primary coverage");
}
static void itsourcechanges(NSString *fixture) {
    // Missing source revalidation must fail these assertions: the root directory
    // itself stays unchanged while a completed descendant source becomes stale.
    for (NSString *change in @[@"leaf",@"ancestor",@"contents",@"missing"]) {
        NSString *scope=itdir(fixture,[@"source-" stringByAppendingString:change]);
        NSString *source=itdir(scope,@"source"),*branch=itdir(source,@"branch"),*parent=itdir(branch,@"parent");
        NSString *search=itdir(scope,@"search"),*path=itput(parent,@"resource",itdata());
        NSString *twinParent=[change isEqual:@"missing"] ? itdir(scope,@"unsearched") : search;
        NSString *twin=[twinParent stringByAppendingPathComponent:@"twin"];
        itcheck(link(path.fileSystemRepresentation,twin.fileSystemRepresentation)==0,@"create nested source hardlink");
        struct stat originalSource;itcheck(lstat(path.fileSystemRepresentation,&originalSource)==0,@"record source inode before mutation");
        NSUInteger beforeDescriptors=itfds();
        AxsCacheKeeperInspection *inspection=[[AxsCacheKeeperInspection alloc] initWithRoot:source searchRoots:@[@{@"path":search,@"label":@"search"}]];
        for (NSUInteger n=0;n<4;n++) [inspection advance:1];
        itcheck(!inspection.complete && [inspection.report[@"hardLinks"] isEqual:@1] && [inspection.report[@"twinScanned"] isEqual:@0],
            @"complete real nested primary traversal before changing its source");
        struct stat before,after;itcheck(lstat(source.fileSystemRepresentation,&before)==0,@"record unchanged root identity");
        NSData *replacement=[@"replacement source contents" dataUsingEncoding:NSUTF8StringEncoding];
        if ([change isEqual:@"ancestor"]) {
            NSString *outside=itdir(scope,@"outside");itput(outside,@"resource",replacement);
            itcheck(rename(parent.fileSystemRepresentation,[[branch stringByAppendingPathComponent:@"saved"] fileSystemRepresentation])==0 &&
                symlink(outside.fileSystemRepresentation,parent.fileSystemRepresentation)==0,@"replace completed source ancestor with a symlink");
        } else if ([change isEqual:@"contents"]) {
            int fd=open(path.fileSystemRepresentation,O_WRONLY|O_TRUNC|O_CLOEXEC);
            itcheck(fd>=0,@"open source for in-place fixture mutation");
            ssize_t count=write(fd,replacement.bytes,replacement.length);int result=close(fd);
            itcheck(count==(ssize_t)replacement.length && result==0,@"change source contents without replacing its inode");
            struct stat modified;itcheck(lstat(path.fileSystemRepresentation,&modified)==0 &&
                modified.st_dev==originalSource.st_dev && modified.st_ino==originalSource.st_ino && modified.st_size!=originalSource.st_size,
                @"in-place source mutation preserves its inode and changes its length");
        } else {
            itcheck(rename(path.fileSystemRepresentation,[[parent stringByAppendingPathComponent:@"saved"] fileSystemRepresentation])==0,
                @"move source without changing root membership");
            if ([change isEqual:@"leaf"]) itput(parent,@"resource",replacement);
        }
        itcheck(lstat(source.fileSystemRepresentation,&after)==0 && before.st_dev==after.st_dev && before.st_ino==after.st_ino &&
            before.st_size==after.st_size && before.st_nlink==after.st_nlink &&
            before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec &&
            before.st_ctimespec.tv_sec==after.st_ctimespec.tv_sec && before.st_ctimespec.tv_nsec==after.st_ctimespec.tv_nsec,
            @"source mutation must leave the held root metadata unchanged");
        itReads=0;NSDictionary *report=itfinish(inspection,1);
        itcheck(![report[@"coverageComplete"] boolValue] && ![report[@"twinCoverageComplete"] boolValue] &&
            [report[@"linkTwins"] count]==0 && itReads==0,
            @"stale nested hardlink sources must invalidate coverage before publishing twins");
        itcheck(itfds()==beforeDescriptors,@"failed source revalidation releases all descriptors before the inspection is deallocated");
        if ([change isEqual:@"leaf"] || [change isEqual:@"contents"])
            itfailure(report,@"fileRecheck",@"identity",0);
        else if ([change isEqual:@"ancestor"]) itfailure(report,@"ancestorRecheck",@"identity",0);
        else itfailure(report,@"fileRecheck",@"posix",ENOENT);
    }
}
static void itreaderrors(NSString *fixture) {
    NSString *root=itdir(fixture,@"read-errors");itput(root,@"payload",itdata());
    itFailReads=YES;NSDictionary *report=itfinish([[AxsCacheKeeperInspection alloc] initWithRoot:root],1);itFailReads=NO;
    itfailure(report,@"readHeader",@"posix",EIO);
    itShortReads=YES;report=itfinish([[AxsCacheKeeperInspection alloc] initWithRoot:root],1);itShortReads=NO;
    itfailure(report,@"shortRead",@"read",0);
    itFailEnumeration=YES;report=itfinish([[AxsCacheKeeperInspection alloc] initWithRoot:root],1);itFailEnumeration=NO;
    itfailure(report,@"enumerate",@"posix",EIO);
}
static void itlimits(NSString *fixture) {
    NSString *root=itdir(fixture,@"depth-limit"),*deep=root;
    for (NSUInteger n=0;n<80;n++) deep=itdir(deep,@"d");itput(deep,@"payload",itdata());
    NSDictionary *report=itfinish([[AxsCacheKeeperInspection alloc] initWithRoot:root],1);
    itcheck([report[@"files"] isEqual:@0],@"depth-limited content is not silently read");itfailure(report,@"depthLimit",@"limit",0);
    root=itdir(fixture,@"error-limit");
    for (NSUInteger n=0;n<100;n++) itput(root,[NSString stringWithFormat:@"file-%lu",(unsigned long)n],itdata());
    itReads=0;itFailReads=YES;report=itfinish([[AxsCacheKeeperInspection alloc] initWithRoot:root],256);itFailReads=NO;
    itcheck([report[@"failures"] isEqual:@64] && itReads==64 && [report[@"files"] isEqual:@0],
        @"the 65th failing header read must never start");itfailure(report,@"readHeader",@"posix",EIO);
}
static void itcancellation(NSString *fixture) {
    NSString *root=itdir(fixture,@"cancel");itput(itdir(root,@"parent"),@"payload",itdata());
    NSUInteger before=itfds();
    for (NSUInteger n=0;n<25;n++) { @autoreleasepool {
        AxsCacheKeeperInspection *inspection=[[AxsCacheKeeperInspection alloc] initWithRoot:root];[inspection advance:1];
        itcheck(itfds()>before,@"active primary traversal holds real descriptors");
        [inspection cancel];itcheck(itfds()==before,@"cancel releases primary descriptors while the inspection is still alive");
        NSUInteger reads=itReads;[inspection advance:256];NSDictionary *report=inspection.report;
        itcheck(inspection.complete && [report[@"cancelled"] boolValue] && ![report[@"coverageComplete"] boolValue] &&
            itReads==reads,@"cancel closes traversal and prevents subsequent reads");
    } }
    itcheck(itfds()<=before,@"cancelled and deallocated inspections release every descriptor");
}
static void ittwincancellation(NSString *fixture) {
    NSString *source=itdir(fixture,@"twin-cancel-source"),*search=itdir(fixture,@"twin-cancel-search");
    NSString *nested=itdir(search,@"nested"),*path=itput(source,@"resource",itdata());
    itcheck(link(path.fileSystemRepresentation,[[nested stringByAppendingPathComponent:@"twin"] fileSystemRepresentation])==0,
        @"create twin cancellation fixture");
    NSUInteger before=itfds();
    for (NSUInteger n=0;n<25;n++) { @autoreleasepool {
        AxsCacheKeeperInspection *inspection=[[AxsCacheKeeperInspection alloc] initWithRoot:source searchRoots:@[@{@"path":search,@"label":@"search"}]];
        [inspection advance:1];[inspection advance:1];[inspection advance:1];
        itcheck(!inspection.complete && [inspection.report[@"twinScanned"] isEqual:@1],@"open nested twin traversal before cancel");
        itcheck(itfds()>before,@"active twin traversal holds real descriptors");
        NSUInteger reads=itReads;[inspection cancel];
        itcheck(itfds()==before,@"cancel releases twin and primary descriptors while the inspection is still alive");
        [inspection advance:256];NSDictionary *report=inspection.report;
        itcheck(inspection.complete && [report[@"cancelled"] boolValue] && ![report[@"coverageComplete"] boolValue] &&
            ![report[@"twinCoverageComplete"] boolValue] && [report[@"twinScanned"] isEqual:@1] && itReads==reads,
            @"cancelled twin traversal stops and closes both primary and search descriptors");
    } }
    itcheck(itfds()<=before,@"cancelled twin traversals release every descriptor");
}
int main(int argc,const char *argv[]) { @autoreleasepool {
    itcheck(argc>=2,@"fixture directory argument required");NSString *fixture=[NSString stringWithUTF8String:argv[1]];
    itcheck(![NSFileManager.defaultManager fileExistsAtPath:fixture],@"fixture directory must be fresh");itdir(fixture,@"");
    NSString *selection=argc>2 ? [NSString stringWithUTF8String:argv[2]] : @"all";
    NSArray *names=@[@"mapping",@"headers",@"root-replacement",@"ancestor-replacement",@"file-open-replacement",@"file-read-replacement",@"hidden-links",@"twins",@"twin-replacement",@"source-changes",@"read-errors",@"limits",@"cancel",@"twin-cancel"];
    void (*cases[])(NSString *)={itmapping,itheaders,itrootreplacement,itancestorreplacement,itfileopenreplacement,itfilereadreplacement,ithiddenlinks,ittwins,ittwinreplacement,itsourcechanges,itreaderrors,itlimits,itcancellation,ittwincancellation};
    itcheck([selection isEqual:@"all"] || [names containsObject:selection],@"unknown inspection test selection");
    for (NSUInteger n=0;n<names.count;n++) if ([selection isEqual:@"all"] || [selection isEqual:names[n]]) {
        cases[n](fixture);printf("PASS: inspection %s\n",[names[n] UTF8String]);
    }
    return 0;
} }
