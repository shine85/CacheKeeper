#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdarg.h>
#include <string.h>
#include <dlfcn.h>
#include <stdlib.h>
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
    IdentityUnchanged, IdentityDuringOpen, IdentityDuringFDRecheck, IdentityDuringPathRecheck, IdentityBetweenRootSamples, IdentityStableTimeProjection, IdentityStablePathTimeProjection, IdentityRootSecondFailure
};
static NSString *identity_path,*identity_role;
static IdentityMutation identity_mutation;
static int identity_fd=-1,identity_fd_error,identity_path_error;
static NSUInteger identity_opens,identity_fstats,identity_pathstats;
// Deterministic view changes are applied to real POSIX samples, never to a fake snapshot provider.
static BOOL identity_field_mutation,identity_field_fd;
static NSUInteger identity_field_index,identity_field_sample;
static void identity_project_field(struct stat *value,BOOL fd,NSUInteger sample) {
    if (!identity_field_mutation || fd!=identity_field_fd || sample!=identity_field_sample) return;
    switch (identity_field_index) {
        case 0: value->st_dev^=1;break;case 1: value->st_ino^=1;break;
        case 2: value->st_mode^=S_IXGRP;break;case 3: value->st_nlink^=1;break;
        case 4: value->st_uid^=1;break;case 5: value->st_gid^=1;break;case 6: value->st_size^=1;break;
        case 7: value->st_mtimespec.tv_sec^=1;break;case 8: value->st_mtimespec.tv_nsec^=1;break;
        case 9: value->st_ctimespec.tv_sec^=1;break;case 10: value->st_ctimespec.tv_nsec^=1;break;
    }
}
static NSUInteger identity_fdpaths,identity_realpaths;
static int identity_fdpath_error,identity_input_resolve_error,identity_fd_resolve_error;
static BOOL identity_fdpath_invalid;
static BOOL identity_bound_calls,identity_rebind_calls;
static NSUInteger identity_call_captures,identity_bound_paths,identity_bound_opens,identity_bound_fds;
static NSUInteger identity_observed_bound_paths,identity_observed_bound_opens,identity_observed_bound_fds;

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
        if (identity_mutation==IdentityBetweenRootSamples && identity_fstats==2) identity_change_mode();
        if (identity_mutation==IdentityDuringFDRecheck && identity_fstats==recheck) identity_change_mode();
        if ((identity_mutation==IdentityDuringOpen || identity_mutation==IdentityRootSecondFailure) && identity_fstats==2 && identity_fd_error) {
            errno=identity_fd_error;return -1;
        }
    }
    int result=fstat(fd,value);
    if (!result && fd==identity_fd && identity_mutation==IdentityStableTimeProjection) {
        value->st_mtimespec.tv_sec++;value->st_mtimespec.tv_nsec^=1;
        value->st_ctimespec.tv_sec++;value->st_ctimespec.tv_nsec^=1;
    }
    if (!result && fd==identity_fd) identity_project_field(value,YES,identity_fstats);
    return result;
}
static void identity_project_path_time(struct stat *value) {
    if (identity_mutation!=IdentityStablePathTimeProjection) return;
    value->st_mtimespec.tv_sec++;value->st_mtimespec.tv_nsec^=1;
    value->st_ctimespec.tv_sec++;value->st_ctimespec.tv_nsec^=1;
}
static int identity_lstat(const char *path,struct stat *value) {
    if ([identity_role isEqual:@"root"] && identity_matches(path)) {
        identity_pathstats++;
        if (identity_mutation==IdentityDuringPathRecheck && identity_pathstats==2) identity_change_mode();
        if (identity_mutation==IdentityDuringOpen && identity_pathstats==2 && identity_path_error) {
            errno=identity_path_error;return -1;
        }
    }
    int result=lstat(path,value);
    if (!result && [identity_role isEqual:@"root"] && identity_matches(path)) { identity_project_path_time(value);identity_project_field(value,NO,identity_pathstats); }
    return result;
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
    int result=fstatat(root,name,value,flags);
    if (!result && identity_child(name)) { identity_project_path_time(value);identity_project_field(value,NO,identity_pathstats); }
    return result;
}
#if !defined(AXS_CACHEKEEPER_INSTALLATION_IDENTITY_RED)
static int identity_bound_lstat(const char *path,struct stat *value) {
    identity_bound_paths++;return identity_lstat(path,value);
}
static int identity_bound_fstatat(int root,const char *path,struct stat *value,int flags) {
    identity_bound_paths++;return identity_fstatat(root,path,value,flags);
}
static int identity_bound_open(const char *path,int flags,...) {
    identity_bound_opens++;return identity_open(path,flags);
}
static int identity_bound_openat(int root,const char *path,int flags,...) {
    identity_bound_opens++;return identity_openat(root,path,flags);
}
static int identity_bound_fstat(int fd,struct stat *value) {
    identity_bound_fds++;return identity_fstat(fd,value);
}
static int identity_observed_dladdr(const void *call,Dl_info *info) {
    if (call==(const void *)identity_bound_lstat || call==(const void *)identity_bound_fstatat) identity_observed_bound_paths++;
    if (call==(const void *)identity_bound_open || call==(const void *)identity_bound_openat) identity_observed_bound_opens++;
    if (call==(const void *)identity_bound_fstat) identity_observed_bound_fds++;
    return dladdr(call,info);
}
static int identity_fcntl(int fd,int command,...) {
    va_list args;va_start(args,command);void *buffer=va_arg(args,void *);va_end(args);
    identity_check(command==F_GETPATH && fd==identity_fd,"observation uses only the existing rejected FD");
    identity_fdpaths++;
    if (identity_fdpath_error) {errno=identity_fdpath_error;return -1;}
    if (identity_fdpath_invalid) {memset(buffer,'x',PATH_MAX);return 0;}
    return fcntl(fd,command,buffer);
}
static char *identity_realpath(const char *path,char *buffer) {
    identity_realpaths++;
    int number=identity_realpaths==1 ? identity_input_resolve_error : identity_fd_resolve_error;
    if (number) {errno=number;return NULL;}
    return realpath(path,buffer);
}
#define fcntl identity_fcntl
#define realpath identity_realpath
#define dladdr identity_observed_dladdr
#define AXS_CACHEKEEPER_INSTALLATION_CALL_BINDING_TESTING 1
#endif

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
#undef fcntl
#undef realpath
#undef dladdr

#if !defined(AXS_CACHEKEEPER_INSTALLATION_IDENTITY_RED)
AxsCacheKeeperInstallationCalls axs_cachekeeper_installation_test_calls(BOOL root,AxsCacheKeeperInstallationCalls imports) {
    (void)root;
    if (!identity_bound_calls) return imports;
    identity_call_captures++;
    if (identity_rebind_calls && identity_call_captures>1) return imports;
    return (AxsCacheKeeperInstallationCalls){.rootPath=identity_bound_lstat,.childPath=identity_bound_fstatat,
        .rootOpen=identity_bound_open,.childOpen=identity_bound_openat,.fdCall=identity_bound_fstat};
}
#endif

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
    identity_field_mutation=NO;identity_field_fd=NO;identity_field_index=0;identity_field_sample=0;
    identity_fd=-1;identity_opens=0;identity_fstats=0;identity_pathstats=0;
    identity_fd_error=0;identity_path_error=0;identity_mutation=mutation;
    identity_fdpaths=0;identity_realpaths=0;identity_fdpath_error=0;identity_input_resolve_error=0;identity_fd_resolve_error=0;
    identity_fdpath_invalid=NO;
    identity_bound_calls=NO;identity_rebind_calls=NO;identity_call_captures=0;
    identity_bound_paths=0;identity_bound_opens=0;identity_bound_fds=0;
    identity_observed_bound_paths=0;identity_observed_bound_opens=0;identity_observed_bound_fds=0;
}
static NSDictionary *identity_failure(NSError *error,NSString *role,NSString *operation,NSString *comparison) {
    NSDictionary *detail=error.userInfo[@"detail"],*identity=detail[@"identity"];
    identity_check([error.domain isEqual:@"dev.local.cachekeeper.installation"] &&
        error.code==([operation isEqual:@"openIdentity"] ? ([role isEqual:@"root"] ? 2 : 3) : 6),"identity diagnostics preserve failure domain and code");
    identity_check([detail[@"target"] isEqual:role] && [detail[@"operation"] isEqual:operation] && [detail[@"errno"] isEqual:@0],"identity rejection does not borrow stale syscall errno");
    identity_check([identity[@"differenceMask"] unsignedIntegerValue]>0,"open mismatch exposes nonzero field differences");
    identity_check(([identity[@"schemaVersion"] isEqual:@1] || [identity[@"schemaVersion"] isEqual:@2]) && [identity[@"comparison"] isEqual:comparison],"identity comparison relationship is explicit");
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
#if !defined(AXS_CACHEKEEPER_INSTALLATION_IDENTITY_RED)
        NSDictionary *view=identity[@"viewObservation"];
        identity_check([identity[@"schemaVersion"] isEqual:@2] && [view[@"context"] isEqual:@"unspecified"] &&
            [view[@"fdPathErrno"] isEqual:@0] && [view[@"inputResolveErrno"] isEqual:@0] && [view[@"fdResolveErrno"] isEqual:@0],
            "new observation has explicit context and independent successful resolution states");
        identity_check(identity_fdpaths==1 && identity_realpaths==2,"diagnostic adds one FD path and two name resolutions only");
#endif
    }
    identity_check(identity_opens==1 && identity_fstats==(diagnostic ? 2 : 1) && identity_pathstats==(diagnostic ? 2 : 1),"failure resamples once per endpoint and never reopens or loops");
    errno=0;identity_check(fcntl(identity_fd,F_GETFD)==-1 && errno==EBADF,"rejected open closes the real observed descriptor");
}
#if !defined(AXS_CACHEKEEPER_INSTALLATION_IDENTITY_RED)
static void identity_callable_binding_cases(NSString *fixture) {
    for (NSString *role in @[@"root",@"info",@"main"]) for (NSUInteger rebound=0;rebound<([role isEqual:@"root"] ? 2U : 1U);rebound++) {
        NSString *root=identity_bundle(fixture);identity_reset(root,role,IdentityDuringOpen);
        identity_bound_calls=YES;identity_rebind_calls=rebound!=0;
        NSError *error=nil;
        identity_check(!axs_cachekeeper_installation_snapshot_with_context([NSURL fileURLWithPath:root],@"test.identity",@"1.0",AxsCacheKeeperInstallationContextTestInjected,&error),
            "bound callable mismatch remains an actual installation refusal");
        NSDictionary *view=identity_failure(error,role,@"openIdentity",@"pathToFD")[@"viewObservation"];
        if ([role isEqual:@"root"]) {
            identity_check(identity_bound_paths==2 && identity_bound_opens==1 && identity_bound_fds==2,
                "initial root path/open/FD and one resample execute only the captured typed callable set");
            identity_check(identity_observed_bound_paths==(rebound ? 1 : 2) && identity_observed_bound_opens==(rebound ? 1 : 2) && identity_observed_bound_fds==(rebound ? 1 : 2),
                "owner observation resolves the executed callable and distinguishes later import rebinding");
            identity_check([view[@"callOwnersStable"] boolValue]==!rebound,
                "callable set rebinding is explicit while original sample and resample retain their pinned calls");
        } else if (!rebound) {
            BOOL main=[role isEqual:@"main"];
            identity_check(identity_bound_paths==(main ? 4U : 3U) && identity_bound_opens==(main ? 3U : 2U) && identity_bound_fds==(main ? 5U : 4U),
                "root second sample and child initial/resample use their correctly typed captured entrypoints");
            identity_check(identity_observed_bound_paths==2 && identity_observed_bound_opens==2 && identity_observed_bound_fds==2 && [view[@"callOwnersStable"] boolValue],
                "child failure observation belongs to the callable used by its path/open/FD samples");
        }
        identity_check(identity_opens==1 && identity_fstats==2 && identity_pathstats==2 && identity_fdpaths==1 && identity_realpaths==2,
            "typed binding does not grow failure IO, reopen, or descriptor lifetime budgets");
    }
}
static void identity_view_failure_cases(NSString *fixture) {
    for (NSUInteger endpoint=0;endpoint<4;endpoint++) {
        NSString *root=identity_bundle(fixture);identity_reset(root,@"root",IdentityStableTimeProjection);
        if (!endpoint) identity_fdpath_error=EIO;
        else if (endpoint==1) identity_input_resolve_error=ENOENT;
        else if (endpoint==2) identity_fd_resolve_error=EACCES;
        else identity_fdpath_invalid=YES;
        NSError *error=nil;
        identity_check(!axs_cachekeeper_installation_snapshot_with_context([NSURL fileURLWithPath:root],@"test.identity",@"1.0",AxsCacheKeeperInstallationContextTestInjected,&error),
            "observation failure cannot override the original identity refusal");
        NSDictionary *identity=identity_failure(error,@"root",@"openIdentity",@"pathToFD"),*view=identity[@"viewObservation"];
        identity_check([identity[@"differenceMask"] isEqual:@1920] && [view[@"context"] isEqual:@"testInjected"] && !view[@"resolvedInputEqualsResolvedFDPath"],
            "original 1920 and explicit caller survive failed relationship observation");
        if (!endpoint) identity_check([view[@"fdPathState"] isEqual:@"failed"] && [view[@"fdPathErrno"] isEqual:@(EIO)] &&
            [view[@"fdResolveState"] isEqual:@"notAttempted"] && !view[@"inputEqualsFDPath"] && identity_realpaths==1,"failed F_GETPATH forbids fabricated FD name or extra resolution");
        else if (endpoint==3) identity_check([view[@"fdPathState"] isEqual:@"invalidResult"] && [view[@"fdPathErrno"] isEqual:@0] &&
            [view[@"fdResolveState"] isEqual:@"notAttempted"] && !view[@"inputEqualsFDPath"] && identity_realpaths==1,
            "malformed successful FD path result is explicit without fabricated errno or unsafe string access");
        else identity_check(identity_realpaths==2 && [view[endpoint==1 ? @"inputResolveErrno" : @"fdResolveErrno"] isEqual:@(endpoint==1 ? ENOENT : EACCES)],
            "two realpath calls retain each endpoint's immediate errno without retries");
        identity_check(identity_opens==1 && identity_fstats==2 && identity_pathstats==2 && identity_fdpaths==1,"failed observation stays within the original resample budget");
    }
}
#endif
static void identity_recheck_cases(NSString *fixture) {
    for (NSString *role in @[@"root",@"info",@"main"]) {
        for (NSNumber *mode in @[@(IdentityDuringFDRecheck),@(IdentityDuringPathRecheck)]) {
            NSString *root=identity_bundle(fixture);identity_reset(root,role,mode.unsignedIntegerValue);
            NSError *error=nil;
            identity_check(!axs_cachekeeper_installation_snapshot([NSURL fileURLWithPath:root],@"test.identity",@"1.0",&error),"read-time metadata mutation still rejects the snapshot");
            NSDictionary *identity=identity_failure(error,role,@"recheckIdentity",mode.unsignedIntegerValue==IdentityDuringFDRecheck ? @"referenceToFD" : @"referenceToPath");
            identity_check(([identity[@"differenceMask"] unsignedIntegerValue]&4)!=0 && !identity[@"resample"],"recheck uses its existing evidence without additional diagnostic IO");
            identity_check(identity_opens==1 && identity_fstats==([role isEqual:@"root"] ? 3 : 2) && identity_pathstats==2,"recheck does not grow a retry loop");
        }
    }
}
static void identity_earliest_root_case(NSString *fixture) {
    NSString *root=identity_bundle(fixture);identity_reset(root,@"root",IdentityBetweenRootSamples);
    NSError *error=nil;
    NSDictionary *snapshot=axs_cachekeeper_installation_snapshot([NSURL fileURLWithPath:root],@"test.identity",@"1.0",&error);
    identity_check(!snapshot,"pinned154.1 earliest verified root FD survives true chmod before second fstat");
    NSDictionary *identity=identity_failure(error,@"root",@"recheckIdentity",@"referenceToFD");
    identity_check(([identity[@"differenceMask"] unsignedIntegerValue]&4)!=0 && identity_fstats==2,
        "earliest root comparison refuses at second sample without reading children or resetting baseline");
    errno=0;identity_check(fcntl(identity_fd,F_GETFD)==-1 && errno==EBADF,"earliest root failure closes held FD");
}
#if !defined(AXS_CACHEKEEPER_INSTALLATION_IDENTITY_RED)
static void identity_second_root_failure_case(NSString *fixture) {
    NSString *root=identity_bundle(fixture);identity_reset(root,@"root",IdentityUnchanged);
    NSURL *url=[NSURL fileURLWithPath:root];NSError *error=nil;
    NSDictionary *snapshot=axs_cachekeeper_installation_snapshot(url,@"test.identity",@"1.0",&error);
    identity_check(snapshot!=nil,"second root failure fixture establishes a real unchanged snapshot");
    for (NSUInteger validation=0;validation<2;validation++) {
        identity_reset(root,@"root",IdentityRootSecondFailure);identity_fd_error=EIO;
        BOOL accepted=validation ? axs_cachekeeper_validate_installation_snapshot(snapshot,url,@"1.0",&error) :
            axs_cachekeeper_installation_snapshot(url,@"test.identity",@"1.0",&error)!=nil;
        identity_check(!accepted && error.code==2 && [error.userInfo[@"detail"] isEqual:@{@"target":@"root",@"operation":@"snapshotStat",@"errno":@(EIO)}],
            "both entrypoints preserve the original second fstat snapshotStat errno contract");
        identity_check(identity_fstats==2 && identity_pathstats==1 && !identity_fdpaths && !identity_realpaths,
            "second fstat syscall failure does not invoke identity resample or path observation");
        errno=0;identity_check(fcntl(identity_fd,F_GETFD)==-1 && errno==EBADF,"second root syscall failure closes existing FD");
    }
    identity_reset(root,@"root",IdentityBetweenRootSamples);
    identity_check(!axs_cachekeeper_validate_installation_snapshot(snapshot,url,@"1.0",&error),"validate retains the earliest root FD sample too");
    identity_failure(error,@"root",@"recheckIdentity",@"referenceToFD");
}
#endif
static void identity_stable_projection_case(NSString *fixture) {
    for (NSString *role in @[@"root",@"info",@"main"]) {
        NSString *root=identity_bundle(fixture);identity_reset(root,role,IdentityStableTimeProjection);
        NSError *error=nil;NSURL *url=[NSURL fileURLWithPath:root];
        NSDictionary *snapshot=axs_cachekeeper_installation_snapshot(url,@"test.identity",@"1.0",&error);
        identity_check(snapshot!=nil && !error,"stable 1920 dual-view projection accepts independently stable installation");
        NSString *key=[@"_" stringByAppendingString:role],*pathKey=[key stringByAppendingString:@"Path"];
        NSUInteger mask=0;
        for (NSUInteger index=0;index<11;index++) if (![snapshot[key][index] isEqual:snapshot[pathKey][index]]) mask|=1U<<index;
        identity_check(mask==1920,
            "snapshot retains all eleven fields of both independently sampled views");
        identity_reset(root,role,IdentityStableTimeProjection);
        identity_check(axs_cachekeeper_validate_installation_snapshot(snapshot,url,@"1.0",&error),"stable dual-view snapshot verifies again without resetting either baseline");
        identity_reset(root,role,IdentityUnchanged);
        identity_check(!axs_cachekeeper_validate_installation_snapshot(snapshot,url,@"1.0",&error),"later disappearance of FD time projection invalidates the snapshot");
        identity_reset(root,role,IdentityUnchanged);
        NSDictionary *plain=axs_cachekeeper_installation_snapshot(url,@"test.identity",@"1.0",NULL);
        identity_check(plain && ![plain[@"fingerprint"] isEqual:snapshot[@"fingerprint"]],"fingerprint binds FD view time fields");
        identity_reset(root,role,IdentityStablePathTimeProjection);
        NSDictionary *pathProjected=axs_cachekeeper_installation_snapshot(url,@"test.identity",@"1.0",&error);
        identity_check(pathProjected && !error && [plain[key] isEqual:pathProjected[key]] &&
            ![plain[@"fingerprint"] isEqual:pathProjected[@"fingerprint"]],"fingerprint independently binds path time fields with unchanged FD view");
        identity_reset(root,role,IdentityStablePathTimeProjection);
        identity_check(axs_cachekeeper_validate_installation_snapshot(pathProjected,url,@"1.0",&error),"stable path-only time projection also verifies across snapshots");
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
    for (NSString *role in @[@"root",@"info",@"main"]) {
        NSString *key=[NSString stringWithFormat:@"_%@Path",role];
        for (NSUInteger index=0;index<11;index++) {
            changed=[snapshot mutableCopy];reference=[snapshot[key] mutableCopy];
            reference[index]=@([reference[index] unsignedLongLongValue]^1ULL);changed[key]=reference;
            identity_check(!axs_cachekeeper_validate_installation_snapshot(changed,url,@"1.0",&error),"every bound path-view field rejects a changed snapshot");
            identity_check([identity_failure(error,role,@"snapshotIdentity",@"snapshotToPath")[@"differenceMask"] unsignedIntegerValue]==(1U<<index),
                "path snapshot difference has its precise non-sensitive field mask");
        }
        for (id bad in @[@[],@[@1],@"private-shape",NSNull.null]) {
            changed=[snapshot mutableCopy];changed[key]=bad;
            identity_check(!axs_cachekeeper_validate_installation_snapshot(changed,url,@"1.0",&error) && !error.userInfo[@"detail"][@"identity"],
                "corrupt path identity rejects without fabricated measured values");
        }
        for (id bad in @[NSNull.null,@NO,@"0"]) {
            changed=[snapshot mutableCopy];reference=[snapshot[key] mutableCopy];reference[4]=bad;changed[key]=reference;
            identity_check(!axs_cachekeeper_validate_installation_snapshot(changed,url,@"1.0",&error) && !error.userInfo[@"detail"][@"identity"],
                "corrupt path identity elements reject without measured-value evidence");
        }
        changed=[snapshot mutableCopy];[changed removeObjectForKey:key];
        identity_check(!axs_cachekeeper_validate_installation_snapshot(changed,url,@"1.0",&error),"missing one path view rejects the snapshot");
    }
    changed=[snapshot mutableCopy];[changed removeObjectForKey:@"_identitySchema"];
    for (NSString *key in @[@"_rootPath",@"_infoPath",@"_mainPath"]) [changed removeObjectForKey:key];
    identity_check(!axs_cachekeeper_validate_installation_snapshot(changed,url,@"1.0",&error) && [error.userInfo[@"detail"][@"operation"] isEqual:@"shape"],
        "legacy single-view snapshot is rejected instead of inventing missing baselines");
    struct stat actual;identity_check(lstat(root.fileSystemRepresentation,&actual)==0,"read atime exclusion fixture");
    struct stat accessed=actual;accessed.st_atimespec.tv_sec++;
    identity_check([axs_cachekeeper_installation_stat(actual) isEqual:axs_cachekeeper_installation_stat(accessed)],"atime is not an installation identity field");
}

#if !defined(AXS_CACHEKEEPER_INSTALLATION_IDENTITY_RED)
static void identity_view_field_matrix(NSString *fixture) {
    for (NSString *role in @[@"root",@"info",@"main"]) {
        NSString *root=identity_bundle(fixture);NSURL *url=[NSURL fileURLWithPath:root];
        identity_reset(root,role,IdentityUnchanged);
        NSDictionary *snapshot=axs_cachekeeper_installation_snapshot(url,@"test.identity",@"1.0",NULL);
        identity_check(snapshot!=nil,"view matrix begins with a real stable installation");
        for (NSUInteger entry=0;entry<2;entry++) for (NSUInteger fd=0;fd<2;fd++) {
            NSUInteger samples=fd && [role isEqual:@"root"] ? 3 : 2;
            for (NSUInteger sample=1;sample<=samples;sample++) for (NSUInteger field=0;field<11;field++) {
                identity_reset(root,role,IdentityUnchanged);
                identity_field_mutation=YES;identity_field_fd=fd;identity_field_index=field;identity_field_sample=sample;
                NSError *error=nil;
                BOOL accepted=entry ? axs_cachekeeper_validate_installation_snapshot(snapshot,url,@"1.0",&error) :
                    axs_cachekeeper_installation_snapshot(url,@"test.identity",@"1.0",&error)!=nil;
                identity_check(!accepted,"every field in either view at every sampled stage rejects drift in both entrypoints");
                identity_check(axs_cachekeeper_installation_detail_projection(error.userInfo[@"detail"])!=nil,
                    "all view drift failures retain only fixed projection fields");
            }
        }
    }
}
#endif

#if !defined(AXS_CACHEKEEPER_INSTALLATION_IDENTITY_RED)
static void identity_schema_cases(void) {
    NSDictionary *legacy=@{@"target":@"root",@"operation":@"openIdentity",@"errno":@0};
    NSDictionary *identity=@{@"schemaVersion":@1,@"comparison":@"pathToFD",@"differenceMask":@4,
        @"resample":@{@"fdErrno":@0,@"pathErrno":@0,@"fdDifferenceMask":@0,@"pathDifferenceMask":@4,@"pathFDDifferenceMask":@0}};
    NSMutableDictionary *valid=[legacy mutableCopy];valid[@"identity"]=identity;
    identity_check([axs_cachekeeper_installation_detail_projection(legacy) isEqual:legacy] &&
        [axs_cachekeeper_installation_detail_projection(valid) isEqual:valid],"legacy and extended details share one strict contract");
    NSDictionary *view=@{@"schemaVersion":@1,@"context":@"hostMainBundle",@"pathAPI":@"lstat",@"openAPI":@"openSearchNoFollow",@"fdAPI":@"fstat",
        @"pathCallOwner":@"libSystem",@"openCallOwner":@"libRootHide",@"fdCallOwner":@"other",
        @"pathCallResolved":@YES,@"openCallResolved":@YES,@"fdCallResolved":@YES,@"callOwnersStable":@YES,
        @"fdPathState":@"success",@"fdPathErrno":@0,@"inputResolveState":@"success",@"inputResolveErrno":@0,
        @"fdResolveState":@"success",@"fdResolveErrno":@0,@"inputEqualsFDPath":@NO,@"resolvedInputEqualsResolvedFDPath":@YES,@"sameObjectNonTimeFields":@NO};
    NSMutableDictionary *modern=[identity mutableCopy];modern[@"schemaVersion"]=@2;modern[@"viewObservation"]=view;
    NSMutableDictionary *modernDetail=[legacy mutableCopy];modernDetail[@"identity"]=modern;
    identity_check([axs_cachekeeper_installation_detail_projection(modernDetail) isEqual:modernDetail],"closed new identity/view schema remains independent of name equality");
    for (NSDictionary *change in @[@{@"context":@"guessed"},@{@"pathCallOwner":@"unresolved"},@{@"fdCallResolved":@1},
        @{@"callOwnersStable":@1},@{@"fdPathState":@"failed",@"fdPathErrno":@(EIO)},@{@"inputResolveState":@"failed",@"inputResolveErrno":@(ENOENT)},
        @{@"fdPathErrno":@(EIO)},@{@"fdResolveState":@"notAttempted"},@{@"sameObjectNonTimeFields":@YES},@{@"rawPath":@"private"}]) {
        NSMutableDictionary *bad=[view mutableCopy];[bad addEntriesFromDictionary:change];modern[@"viewObservation"]=bad;
        identity_check(!axs_cachekeeper_installation_detail_projection(modernDetail),"contradictory call/name/error evidence and private keys never cross new identity projection");
    }
    modern[@"viewObservation"]=view;
    NSDictionary *immutable=axs_cachekeeper_installation_detail_projection(modernDetail);
    NSMutableDictionary *mutableView=[view mutableCopy];modern[@"viewObservation"]=mutableView;
    immutable=axs_cachekeeper_installation_detail_projection(modernDetail);mutableView[@"fdPathErrno"]=@(EIO);
    identity_check([immutable[@"identity"][@"viewObservation"] isEqual:view],"projection owns nested immutable observation values");
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
        #if defined(AXS_CACHEKEEPER_INSTALLATION_EARLIEST_RED)
        identity_earliest_root_case(fixture);return 0;
#endif
#if defined(AXS_CACHEKEEPER_INSTALLATION_DUAL_VIEW_RED)
        identity_stable_projection_case(fixture);return 0;
#endif
        identity_open_case(fixture,@"root",0,0,YES);
#if !defined(AXS_CACHEKEEPER_INSTALLATION_IDENTITY_RED)
        for (NSString *role in @[@"root",@"info",@"main"]) {
            if (![role isEqual:@"root"]) identity_open_case(fixture,role,0,0,YES);
            for (NSArray *errors in @[@[@(EIO),@0],@[@0,@(ENOENT)],@[@(EIO),@(ENOENT)]])
                identity_open_case(fixture,role,[errors[0] intValue],[errors[1] intValue],YES);
            identity_open_case(fixture,role,0,0,NO);
        }
        identity_earliest_root_case(fixture);identity_second_root_failure_case(fixture);identity_stable_projection_case(fixture);identity_view_failure_cases(fixture);identity_callable_binding_cases(fixture);
        identity_recheck_cases(fixture);identity_field_cases(fixture);identity_view_field_matrix(fixture);identity_schema_cases();
#endif
        fprintf(stdout,"PASS: installation identity actual refusal, bounded resample and strict schema\n");
    }
    return 0;
}
