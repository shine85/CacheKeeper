#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdarg.h>
#include <string.h>
#import "../AxsCacheKeeperInstallation.h"
#import "AxsCacheKeeperPolicy.h"
#if !defined(AXS_CACHEKEEPER_INSTALLATION_IDENTITY_RED)
#import "../AxsCacheKeeperInstallationCheck.h"
#endif

static void identity_check(BOOL value, const char *message) {
    if (!value) { fprintf(stderr,"FAIL: installation-identity: %s\n",message);exit(1); }
}

// The real path, open FD and filesystem mutation remain real. Only the instant between
// syscalls (or one failing syscall) is controlled, so a guessed race is not the fixture.
typedef NS_ENUM(NSUInteger, IdentityMutation) {
    IdentityUnchanged, IdentityDuringOpen, IdentityDuringFDRecheck, IdentityDuringPathRecheck
};
static NSString *identity_path,*identity_role;
static IdentityMutation identity_mutation;
static int identity_fd=-1,identity_fd_error,identity_path_error;
static NSUInteger identity_opens,identity_fstats,identity_pathstats;

static BOOL identity_matches(const char *path) {
    return identity_path.length && path && !strcmp(path,identity_path.fileSystemRepresentation);
}
static BOOL identity_child(const char *name) {
    return ![identity_role isEqual:@"root"] && name &&
        !strcmp(name,identity_path.lastPathComponent.fileSystemRepresentation);
}
static void identity_change_mode(void) {
    struct stat actual;
    identity_check(lstat(identity_path.fileSystemRepresentation,&actual)==0,"mutation reads the real fixture");
    identity_check(chmod(identity_path.fileSystemRepresentation,(actual.st_mode&07777)^S_IXGRP)==0,
        "mutation changes real fixture metadata without replacing the observed object");
}
static int identity_open(const char *path,int flags,...) {
    int fd;
    if (flags&O_CREAT) { va_list args;va_start(args,flags);mode_t mode=(mode_t)va_arg(args,int);va_end(args);fd=open(path,flags,mode); }
    else fd=open(path,flags);
    if ([identity_role isEqual:@"root"] && identity_matches(path) && fd>=0) {
        identity_check((flags&O_NOFOLLOW) && (flags&O_CLOEXEC) && (flags&O_NONBLOCK),"root open retains all safety flags");
        identity_fd=fd;identity_opens++;
        if (identity_mutation==IdentityDuringOpen) identity_change_mode();
    }
    return fd;
}
static int identity_openat(int root,const char *name,int flags,...) {
    int fd;
    if (flags&O_CREAT) { va_list args;va_start(args,flags);mode_t mode=(mode_t)va_arg(args,int);va_end(args);fd=openat(root,name,flags,mode); }
    else fd=openat(root,name,flags);
    if (identity_child(name) && fd>=0) {
        identity_check((flags&O_NOFOLLOW) && (flags&O_CLOEXEC) && (flags&O_NONBLOCK),"child open retains all safety flags");
        identity_fd=fd;identity_opens++;
        if (identity_mutation==IdentityDuringOpen) identity_change_mode();
    }
    return fd;
}
static int identity_fstat(int fd,struct stat *value) {
    if (fd==identity_fd) {
        identity_fstats++;
        NSUInteger recheck=[identity_role isEqual:@"root"] ? 3 : 2;
        if (identity_mutation==IdentityDuringFDRecheck && identity_fstats==recheck) identity_change_mode();
        if (identity_mutation==IdentityDuringOpen && identity_fstats==2 && identity_fd_error) {
            errno=identity_fd_error;return -1;
        }
    }
    return fstat(fd,value);
}
static int identity_lstat(const char *path,struct stat *value) {
    if ([identity_role isEqual:@"root"] && identity_matches(path)) {
        identity_pathstats++;
        if (identity_mutation==IdentityDuringPathRecheck && identity_pathstats==2) identity_change_mode();
        if (identity_mutation==IdentityDuringOpen && identity_pathstats==2 && identity_path_error) {
            errno=identity_path_error;return -1;
        }
    }
    return lstat(path,value);
}
static int identity_fstatat(int root,const char *name,struct stat *value,int flags) {
    if (identity_child(name)) {
        identity_check(flags&AT_SYMLINK_NOFOLLOW,"child path sampling never follows a symlink");
        identity_pathstats++;
        if (identity_mutation==IdentityDuringPathRecheck && identity_pathstats==2) identity_change_mode();
        if (identity_mutation==IdentityDuringOpen && identity_pathstats==2 && identity_path_error) {
            errno=identity_path_error;return -1;
        }
    }
    return fstatat(root,name,value,flags);
}

#define open identity_open
#define openat identity_openat
#define fstat identity_fstat
#define lstat identity_lstat
#define fstatat identity_fstatat
#import "../AxsCacheKeeperInstallation.m"
#undef open
#undef openat
#undef fstat
#undef lstat
#undef fstatat

static NSString *identity_bundle(NSString *fixture) {
    NSString *root=[[fixture stringByAppendingPathComponent:NSUUID.UUID.UUIDString] stringByAppendingPathComponent:@"Fixture.app"];
    identity_check([NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil],"create temporary bundle");
    NSDictionary *info=@{@"CFBundleIdentifier":@"test.identity",@"CFBundleExecutable":@"Main",
        @"CFBundleVersion":@"1",@"CFBundleShortVersionString":@"1.0"};
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:info format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    identity_check([data writeToFile:[root stringByAppendingPathComponent:@"Info.plist"] atomically:YES] &&
        [[@"real executable fixture" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:[root stringByAppendingPathComponent:@"Main"] atomically:YES],"write real installation metadata and executable fixture");
    return root;
}
static void identity_reset(NSString *root,NSString *role,IdentityMutation mutation) {
    identity_role=role;identity_path=[role isEqual:@"root"] ? root : [root stringByAppendingPathComponent:[role isEqual:@"info"] ? @"Info.plist" : @"Main"];
    identity_fd=-1;identity_opens=0;identity_fstats=0;identity_pathstats=0;
    identity_fd_error=0;identity_path_error=0;identity_mutation=mutation;
}
static NSDictionary *identity_failure(NSError *error,NSString *role,NSString *operation,NSString *comparison) {
    NSDictionary *detail=error.userInfo[@"detail"],*identity=detail[@"identity"];
    identity_check([error.domain isEqual:@"dev.local.cachekeeper.installation"] &&
        error.code==([operation isEqual:@"openIdentity"] ? ([role isEqual:@"root"] ? 2 : 3) : 6),"identity diagnostics preserve failure domain and code");
    identity_check([detail[@"target"] isEqual:role] && [detail[@"operation"] isEqual:operation] && [detail[@"errno"] isEqual:@0],"identity rejection does not borrow stale syscall errno");
    identity_check([identity[@"differenceMask"] unsignedIntegerValue]>0,"open mismatch exposes nonzero field differences");
    identity_check([identity[@"schemaVersion"] isEqual:@1] && [identity[@"comparison"] isEqual:comparison],"identity comparison relationship is explicit");
    identity_check([axs_cachekeeper_installation_detail_projection(detail) isEqual:detail],"producer details survive the shared strict projection");
    return identity;
}
static void identity_open_case(NSString *fixture,NSString *role,int fdError,int pathError,BOOL diagnostic) {
    NSString *root=identity_bundle(fixture);identity_reset(root,role,IdentityDuringOpen);
    identity_fd_error=fdError;identity_path_error=pathError;
    NSError *error=nil;errno=EPERM;
    NSDictionary *snapshot=axs_cachekeeper_installation_snapshot([NSURL fileURLWithPath:root],@"test.identity",@"1.0",diagnostic ? &error : NULL);
    identity_check(!snapshot,"a real mutation at open can never gain a valid installation snapshot");
    if (diagnostic) {
        NSDictionary *identity=identity_failure(error,role,@"openIdentity",@"pathToFD");
        identity_check(([identity[@"differenceMask"] unsignedIntegerValue]&4)!=0,"real chmod is reported as the mode difference bit");
        NSDictionary *repeat=identity[@"resample"];
        identity_check([repeat[@"fdErrno"] isEqual:@(fdError)] && [repeat[@"pathErrno"] isEqual:@(pathError)],"bounded resample retains independent immediate syscall errors");
        identity_check(fdError ? !repeat[@"fdDifferenceMask"] : [repeat[@"fdDifferenceMask"] isEqual:@0],"failed FD sample is not fabricated and stable FD sample is zero");
        identity_check(pathError ? !repeat[@"pathDifferenceMask"] : ([repeat[@"pathDifferenceMask"] unsignedIntegerValue]&4)!=0,"path comparison refers to the original pre-open sample");
        identity_check(fdError || pathError ? !repeat[@"pathFDDifferenceMask"] : [repeat[@"pathFDDifferenceMask"] isEqual:@0],"converged resample cannot overturn the original mismatch");
    }
    identity_check(identity_opens==1 && identity_fstats==(diagnostic ? 2 : 1) && identity_pathstats==(diagnostic ? 2 : 1),"failure resamples once per endpoint and never reopens or loops");
    errno=0;identity_check(fcntl(identity_fd,F_GETFD)==-1 && errno==EBADF,"rejected open closes the real observed descriptor");
}
static void identity_recheck_cases(NSString *fixture) {
    for (NSString *role in @[@"root",@"info",@"main"]) {
        for (NSNumber *mode in @[@(IdentityDuringFDRecheck),@(IdentityDuringPathRecheck)]) {
            NSString *root=identity_bundle(fixture);identity_reset(root,role,mode.unsignedIntegerValue);
            NSError *error=nil;
            identity_check(!axs_cachekeeper_installation_snapshot([NSURL fileURLWithPath:root],@"test.identity",@"1.0",&error),"read-time metadata mutation still rejects the snapshot");
            NSDictionary *identity=identity_failure(error,role,@"recheckIdentity",mode.unsignedIntegerValue==IdentityDuringFDRecheck ? @"referenceToFD" : @"fdToPath");
            identity_check(([identity[@"differenceMask"] unsignedIntegerValue]&4)!=0 && !identity[@"resample"],"recheck uses its existing evidence without additional diagnostic IO");
            identity_check(identity_opens==1 && identity_fstats==([role isEqual:@"root"] ? 3 : 2) && identity_pathstats==2,"recheck does not grow a retry loop");
        }
    }
}
static void identity_field_cases(NSString *fixture) {
    NSString *root=identity_bundle(fixture);identity_reset(root,@"root",IdentityUnchanged);
    NSURL *url=[NSURL fileURLWithPath:root];NSError *error=nil;
    NSDictionary *snapshot=axs_cachekeeper_installation_snapshot(url,@"test.identity",@"1.0",&error);
    identity_check(snapshot && !error && axs_cachekeeper_validate_installation_snapshot(snapshot,url,@"1.0",NULL),"unchanged real installation still verifies");
    for (NSString *role in @[@"root",@"info",@"main"]) {
        NSString *key=[@"_" stringByAppendingString:role];
        for (NSUInteger index=0;index<11;index++) {
            NSMutableDictionary *changed=[snapshot mutableCopy];NSMutableArray *reference=[snapshot[key] mutableCopy];
            reference[index]=@([reference[index] unsignedLongLongValue]^1ULL);changed[key]=reference;
            identity_check(!axs_cachekeeper_validate_installation_snapshot(changed,url,@"1.0",&error),"every bound identity field still rejects a changed snapshot");
            NSDictionary *identity=identity_failure(error,role,@"snapshotIdentity",@"snapshotToFD");
            identity_check([identity[@"differenceMask"] unsignedIntegerValue]==(1U<<index),"each bound stat field retains its exact diagnostic bit");
        }
    }
    NSMutableDictionary *changed=[snapshot mutableCopy];NSMutableArray *reference=[snapshot[@"_info"] mutableCopy];
    for (NSNumber *index in @[@0,@2,@10]) reference[index.unsignedIntegerValue]=@([reference[index.unsignedIntegerValue] unsignedLongLongValue]^1ULL);
    changed[@"_info"]=reference;
    identity_check(!axs_cachekeeper_validate_installation_snapshot(changed,url,@"1.0",&error),"multiple simultaneous differences remain a rejection");
    identity_check([identity_failure(error,@"info",@"snapshotIdentity",@"snapshotToFD")[@"differenceMask"] isEqual:@1029],"multiple differing fields are combined without loss");
    for (id bad in @[@[],@[@1],@"private-shape",NSNull.null]) {
        changed=[snapshot mutableCopy];changed[@"_root"]=bad;
        identity_check(!axs_cachekeeper_validate_installation_snapshot(changed,url,@"1.0",&error),"invalid private vectors fail closed without indexing outside their shape");
        identity_check(!error.userInfo[@"detail"][@"identity"],"invalid vectors do not fabricate measured field evidence");
    }
    for (id bad in @[NSNull.null,@NO,@"0"]) {
        changed=[snapshot mutableCopy];reference=[snapshot[@"_root"] mutableCopy];reference[4]=bad;changed[@"_root"]=reference;
        identity_check(!axs_cachekeeper_validate_installation_snapshot(changed,url,@"1.0",&error) && !error.userInfo[@"detail"][@"identity"],
            "invalid private vector elements never become measured fields or an accepted snapshot");
    }
    struct stat actual;identity_check(lstat(root.fileSystemRepresentation,&actual)==0,"read atime exclusion fixture");
    struct stat accessed=actual;accessed.st_atimespec.tv_sec++;
    identity_check([axs_cachekeeper_installation_stat(actual) isEqual:axs_cachekeeper_installation_stat(accessed)],"atime is not an installation identity field");
}

#if !defined(AXS_CACHEKEEPER_INSTALLATION_IDENTITY_RED)
static void identity_schema_cases(void) {
    NSDictionary *legacy=@{@"target":@"root",@"operation":@"openIdentity",@"errno":@0};
    NSDictionary *identity=@{@"schemaVersion":@1,@"comparison":@"pathToFD",@"differenceMask":@4,
        @"resample":@{@"fdErrno":@0,@"pathErrno":@0,@"fdDifferenceMask":@0,@"pathDifferenceMask":@4,@"pathFDDifferenceMask":@0}};
    NSMutableDictionary *valid=[legacy mutableCopy];valid[@"identity"]=identity;
    identity_check([axs_cachekeeper_installation_detail_projection(legacy) isEqual:legacy] &&
        [axs_cachekeeper_installation_detail_projection(valid) isEqual:valid],"legacy and extended details share one strict contract");
    for (NSNumber *mask in @[@1,@2047]) {
        NSMutableDictionary *detail=[legacy mutableCopy];detail[@"identity"]=@{@"schemaVersion":@1,@"comparison":@"pathToFD",@"differenceMask":mask};
        identity_check(axs_cachekeeper_installation_detail_projection(detail)!=nil,"valid lowest and full masks remain representable without a resample");
    }
    for (NSString *field in @[@"schemaVersion",@"differenceMask"]) {
        for (id bad in @[@YES,@(-1),@0,@1.5,@2048,@(NAN),@(INFINITY),@"1",NSNull.null]) {
            NSMutableDictionary *detail=[valid mutableCopy],*sample=[identity mutableCopy];sample[field]=bad;detail[@"identity"]=sample;
            identity_check(!axs_cachekeeper_installation_detail_projection(detail),"bad identity numeric values cannot cross the export boundary");
        }
    }
    for (NSDictionary *change in @[@{@"comparison":@"fdToPath"},@{@"comparison":@"unknown"},@{@"value":@1},@{@"resample":@{}},@{@"resample":NSNull.null}]) {
        NSMutableDictionary *detail=[valid mutableCopy],*sample=[identity mutableCopy];[sample addEntriesFromDictionary:change];detail[@"identity"]=sample;
        identity_check(!axs_cachekeeper_installation_detail_projection(detail),"unknown fields, illegal relationship and malformed resample are rejected");
    }
    for (NSDictionary *change in @[@{@"fdErrno":@YES},@{@"pathErrno":@(-1)},@{@"fdDifferenceMask":@YES},@{@"pathDifferenceMask":@2048},
        @{@"pathFDDifferenceMask":@(-1)},@{@"fdErrno":@(EIO)},@{@"pathErrno":@(ENOENT)},@{@"rawStat":@[]},@{@"path":@"private"}]) {
        NSMutableDictionary *detail=[valid mutableCopy],*sample=[identity mutableCopy],*repeat=[identity[@"resample"] mutableCopy];
        [repeat addEntriesFromDictionary:change];sample[@"resample"]=repeat;detail[@"identity"]=sample;
        identity_check(!axs_cachekeeper_installation_detail_projection(detail),"failed syscall evidence cannot carry fabricated values or private extra keys");
    }
    for (NSString *key in @[@"fdDifferenceMask",@"pathDifferenceMask",@"pathFDDifferenceMask"]) {
        NSMutableDictionary *detail=[valid mutableCopy],*sample=[identity mutableCopy],*repeat=[identity[@"resample"] mutableCopy];
        [repeat removeObjectForKey:key];sample[@"resample"]=repeat;detail[@"identity"]=sample;
        identity_check(!axs_cachekeeper_installation_detail_projection(detail),"successful samples require each corresponding comparison");
    }
    for (NSDictionary *change in @[@{@"operation":@"open",@"errno":@(EACCES)},@{@"target":@"snapshot",@"operation":@"path"},@{@"operation":@"snapshotIdentity"}]) {
        NSMutableDictionary *detail=[valid mutableCopy];[detail addEntriesFromDictionary:change];
        identity_check(!axs_cachekeeper_installation_detail_projection(detail),"identity evidence is allowed only for its actual rejection stage");
    }
    NSMutableDictionary *sample=[identity mutableCopy],*repeat=[identity[@"resample"] mutableCopy];sample[@"resample"]=repeat;valid[@"identity"]=sample;
    NSDictionary *projected=axs_cachekeeper_installation_detail_projection(valid);
    repeat[@"fdDifferenceMask"]=@1024;sample[@"differenceMask"]=@64;
    identity_check([projected[@"identity"] isEqual:identity],"projection owns immutable diagnostic values");
    NSError *error=[NSError errorWithDomain:@"dev.local.cachekeeper.installation" code:2 userInfo:@{@"detail":projected}];
    NSDictionary *check=axs_cachekeeper_installation_check_result(YES,nil,error);
    identity_check([check isEqual:@{@"state":@"failed",@"errorCode":@2,@"detail":projected}] &&
        [axs_cachekeeper_installation_check_projection(check) isEqual:check],"shared check preserves only validated failure detail");
    identity_check([axs_cachekeeper_installation_check_result(NO,nil,error) isEqual:@{@"state":@"notRequested",@"errorCode":@0}],"not requested is distinct from an attempted failure");
    for (NSString *state in @[@"verified",@"versionUnknown"]) {
        identity_check([axs_cachekeeper_installation_check_result(YES,@{@"installationState":state},nil) isEqual:@{@"state":state,@"errorCode":@0}],"known snapshot states survive shared result construction");
    }
    identity_check([axs_cachekeeper_installation_check_result(YES,nil,nil) isEqual:@{@"state":@"failed",@"errorCode":@0}],"missing error is not fabricated success");
    identity_check([axs_cachekeeper_installation_check_result(YES,@{@"installationState":@"verified"},error)[@"state"] isEqual:@"invalid"],"contradictory success and error cannot become verified");
    identity_check([axs_cachekeeper_installation_check_result(YES,@{},nil)[@"state"] isEqual:@"invalid"],"malformed snapshot is not silently version unknown");
    error=[NSError errorWithDomain:@"dev.local.cachekeeper.installation" code:2 userInfo:@{@"detail":@{@"private":@"value"}}];
    identity_check([axs_cachekeeper_installation_check_result(YES,nil,error)[@"state"] isEqual:@"invalid"],"malformed present error detail is visible as invalid");
    for (NSDictionary *invalid in @[@{@"state":@"verified",@"errorCode":@0,@"detail":projected},@{@"state":@"failed",@"errorCode":@YES},
        @{@"state":@"failed",@"errorCode":@8},@{@"state":@"unknown",@"errorCode":@0},@{@"state":@"failed",@"errorCode":@2,@"path":@"private"}])
        identity_check(!axs_cachekeeper_installation_check_projection(invalid),"invalid shared check objects are rejected");
}
#endif

int main(int argc,const char *argv[]) {
    @autoreleasepool {
        identity_check(argc==2,"fixture parent argument is required");NSString *fixture=[NSString stringWithUTF8String:argv[1]];
        identity_open_case(fixture,@"root",0,0,YES);
#if !defined(AXS_CACHEKEEPER_INSTALLATION_IDENTITY_RED)
        for (NSString *role in @[@"root",@"info",@"main"]) {
            if (![role isEqual:@"root"]) identity_open_case(fixture,role,0,0,YES);
            for (NSArray *errors in @[@[@(EIO),@0],@[@0,@(ENOENT)],@[@(EIO),@(ENOENT)]])
                identity_open_case(fixture,role,[errors[0] intValue],[errors[1] intValue],YES);
            identity_open_case(fixture,role,0,0,NO);
        }
        identity_recheck_cases(fixture);identity_field_cases(fixture);identity_schema_cases();
#endif
        fprintf(stdout,"PASS: installation identity actual refusal, bounded resample and strict schema\n");
    }
    return 0;
}
