#import "AxsCacheKeeperGurdRuntime.h"
#import "AxsCacheKeeperGurdCache.h"
#import "AxsCacheKeeperInstallation.h"
#import "AxsCacheKeeperPolicy.h"
#import "AxsCacheKeeperOperationInfo.h"
#import <UIKit/UIKit.h>
#include <roothide.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdatomic.h>

static AxsCacheKeeperGurdCache *axs_cachekeeper_gurd_engine;
static NSObject *axs_cachekeeper_gurd_context_lock;
static _Atomic(BOOL) axs_cachekeeper_gurd_access;
static BOOL axs_cachekeeper_gurd_report_writable=YES;
static NSDictionary *axs_cachekeeper_gurd_installation;
static NSDictionary *axs_cachekeeper_gurd_policy_snapshot;
static NSMutableDictionary *axs_cachekeeper_gurd_pending_report;
static NSUInteger axs_cachekeeper_gurd_configuration;
static NSUInteger axs_cachekeeper_gurd_notified_configuration;
static dispatch_queue_t axs_cachekeeper_gurd_report_queue;

static NSString *AxsCacheKeeperGurdFolder(void) {
    return jbroot(@"/var/mobile/Library/CacheKeeper");
}
static NSString *AxsCacheKeeperGurdReportPath(void) {
    return [[AxsCacheKeeperGurdFolder() stringByAppendingPathComponent:@"Status"]
        stringByAppendingPathComponent:[NSBundle.mainBundle.bundleIdentifier stringByAppendingString:@".gurd.plist"]];
}
static id AxsCacheKeeperGurdLoadReport(NSString *path) {
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK);
    if(fd<0) return errno==ENOENT ? nil : @{};
    struct stat before={0},after={0};
    if(fstat(fd,&before) || !S_ISREG(before.st_mode) || before.st_size<=0 || before.st_size>256*1024) {close(fd);return @{};}
    NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)before.st_size];size_t offset=0;
    while(offset<data.length) {
        ssize_t count=read(fd,(char *)data.mutableBytes+offset,data.length-offset);
        if(count<0 && errno==EINTR) continue;
        if(count<=0) {close(fd);return @{};}offset+=(size_t)count;
    }
    char extra;ssize_t tail;do {tail=read(fd,&extra,1);} while(tail<0 && errno==EINTR);
    BOOL stable=tail==0 && !fstat(fd,&after) && before.st_dev==after.st_dev && before.st_ino==after.st_ino &&
        before.st_size==after.st_size && before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec &&
        before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec && before.st_ctimespec.tv_sec==after.st_ctimespec.tv_sec && before.st_ctimespec.tv_nsec==after.st_ctimespec.tv_nsec;
    if(close(fd)) stable=NO;
    return stable ? ([NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:nil] ?: @{}) : @{};
}
static void AxsCacheKeeperGurdFlushReport(void) {
    axs_cachekeeper_operation_save(nil,AxsCacheKeeperGurdReportPath(),axs_cachekeeper_gurd_access,
        &axs_cachekeeper_gurd_pending_report,&axs_cachekeeper_gurd_report_writable);
}
static NSDictionary *AxsCacheKeeperGurdContext(void) {
    @synchronized(axs_cachekeeper_gurd_context_lock) {
        AxsCacheKeeperGurdFlushReport();
        NSError *stateError=nil,*selectionError=nil;
        NSString *folder=AxsCacheKeeperGurdFolder(),*bundle=NSBundle.mainBundle.bundleIdentifier;
        NSDictionary *states=axs_cachekeeper_read_input([folder stringByAppendingPathComponent:@"appEnabled.plist"],&stateError);
        NSDictionary *selected=axs_cachekeeper_read_input([folder stringByAppendingPathComponent:@"directories.plist"],&selectionError);
        id state=states[bundle] ?: @NO;
        BOOL valid=axs_cachekeeper_gurd_access && !stateError && !selectionError && axs_cachekeeper_state_valid(state);
        NSString *version=[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
        NSString *build=[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"],*installation=@"";
        if (valid && axs_cachekeeper_app_enabled(state)) {
            NSError *error=nil;
            if (!axs_cachekeeper_gurd_installation || !axs_cachekeeper_validate_installation_snapshot_with_context(
                axs_cachekeeper_gurd_installation,NSBundle.mainBundle.bundleURL,version,AxsCacheKeeperInstallationContextHostMainBundle,&error)) {
                error=nil;axs_cachekeeper_gurd_installation=axs_cachekeeper_installation_snapshot_with_context(
                    NSBundle.mainBundle.bundleURL,bundle,version,AxsCacheKeeperInstallationContextHostMainBundle,&error);
            }
            // Bundle metadata and the independently parsed installation view must agree.
            if ([axs_cachekeeper_gurd_installation[@"installationState"] isEqual:@"verified"] &&
                [axs_cachekeeper_gurd_installation[@"version"] isEqual:version] &&
                [axs_cachekeeper_gurd_installation[@"build"] isEqual:build])
                installation=axs_cachekeeper_gurd_installation[@"fingerprint"] ?: @"";
        }
        NSDictionary *policy=@{@"valid":@(valid),@"appState":state,@"selected":selected[bundle] ?: @[],
            @"home":NSHomeDirectory(),@"bundle":bundle ?: @"",@"version":version ?: @"",@"build":build ?: @"",
            @"installation":installation};
        if (![axs_cachekeeper_gurd_policy_snapshot isEqual:policy]) {
            axs_cachekeeper_gurd_policy_snapshot=policy;
            if (axs_cachekeeper_gurd_configuration<9007199254740991ULL) axs_cachekeeper_gurd_configuration++;
            else axs_cachekeeper_gurd_report_writable=NO;
        }
        NSMutableDictionary *context=[policy mutableCopy];context[@"configuration"]=@(axs_cachekeeper_gurd_configuration);
        context[@"reportWritable"]=@(axs_cachekeeper_gurd_report_writable);return [context copy];
    }
}
void axs_cachekeeper_configure_gurd_cache(BOOL containerEligible,BOOL configurationAccess) {
    // This contract belongs to the verified current Aweme host, not arbitrary SDK users.
    if (!containerEligible || ![NSBundle.mainBundle.bundleIdentifier isEqual:@"com.ss.iphone.ugc.Aweme"]) return;
    static dispatch_once_t once;
    dispatch_once(&once,^{
        axs_cachekeeper_gurd_context_lock=[NSObject new];axs_cachekeeper_gurd_access=configurationAccess;
        axs_cachekeeper_gurd_report_queue=dispatch_queue_create("dev.local.cachekeeper.gurd.report",DISPATCH_QUEUE_SERIAL);
        axs_cachekeeper_gurd_engine=[[AxsCacheKeeperGurdCache alloc] initWithContextProvider:^NSDictionary *{
            return AxsCacheKeeperGurdContext();
        } source:[AxsCacheKeeperGurdSource new] beginTask:^NSUInteger(void (^expiration)(void)) {
            UIApplication *app=UIApplication.sharedApplication;
            if (app.applicationState!=UIApplicationStateBackground) return 0;
            UIBackgroundTaskIdentifier task=[app beginBackgroundTaskWithName:@"CacheKeeper.GurdCache" expirationHandler:expiration];
            if (task==UIBackgroundTaskInvalid) return 0;
            if (app.applicationState!=UIApplicationStateBackground || app.backgroundTimeRemaining<=1) {
                [app endBackgroundTask:task];return 0;
            }
            return (NSUInteger)task+1;
        } endTask:^(NSUInteger token) {
            if (token) [UIApplication.sharedApplication endBackgroundTask:(UIBackgroundTaskIdentifier)(token-1)];
        } observer:^(NSDictionary *receipt) {
            dispatch_async(axs_cachekeeper_gurd_report_queue,^{@synchronized(axs_cachekeeper_gurd_context_lock) {
                NSDictionary *valid=axs_cachekeeper_gurd_receipt_projection(receipt);
                if (!valid) {
                    axs_cachekeeper_gurd_report_writable=NO;
                    NSLog(@"[CacheKeeper] 宿主缓存回执字段无效，停止新增动作");return;
                }
                axs_cachekeeper_operation_save(valid,AxsCacheKeeperGurdReportPath(),axs_cachekeeper_gurd_access,
                    &axs_cachekeeper_gurd_pending_report,&axs_cachekeeper_gurd_report_writable);
            }});
        }];
        // Load saved state before lifecycle observers can enqueue an action. Disk
        // access and installation sampling stay off UIKit's notification thread.
        dispatch_async(axs_cachekeeper_gurd_report_queue,^{
            NSString *path=AxsCacheKeeperGurdReportPath();
            id saved=AxsCacheKeeperGurdLoadReport(path);
            [axs_cachekeeper_gurd_engine restoreReceipt:saved completion:^{
            NSNotificationCenter *center=NSNotificationCenter.defaultCenter;
            [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                (void)note;[axs_cachekeeper_gurd_engine didBecomeActive];
            }];
            [center addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                (void)note;[axs_cachekeeper_gurd_engine didEnterBackground];
            }];
            // A background notification may have arrived while history was read.
            // Catch up from UIKit state; the engine deduplicates a callback already received.
            if(UIApplication.sharedApplication.applicationState==UIApplicationStateBackground)
                [axs_cachekeeper_gurd_engine didEnterBackground];
            }];
        });
    });
    // UIKit must never wait for provider disk/installation IO under its lock.
    BOOL previous=atomic_exchange(&axs_cachekeeper_gurd_access,configurationAccess);
    if(previous!=configurationAccess) {
        if(NSThread.isMainThread) [axs_cachekeeper_gurd_engine refresh];
        else dispatch_async(dispatch_get_main_queue(),^{[axs_cachekeeper_gurd_engine refresh];});
    }
    // Diagnostic probes share this entry point. Only a changed policy snapshot
    // may create a new event; repeated reads must not retry submitted host work.
    dispatch_async(axs_cachekeeper_gurd_report_queue,^{
        NSDictionary *context=AxsCacheKeeperGurdContext();
        NSUInteger current=[context[@"configuration"] unsignedIntegerValue];
        if (current!=axs_cachekeeper_gurd_notified_configuration) {
            BOOL initial=axs_cachekeeper_gurd_notified_configuration==0;
            axs_cachekeeper_gurd_notified_configuration=current;
            if (!initial) dispatch_async(dispatch_get_main_queue(),^{[axs_cachekeeper_gurd_engine refreshForConfiguration:current];});
        }
    });
}
