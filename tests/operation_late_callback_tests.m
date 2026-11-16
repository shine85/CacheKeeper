#import <Foundation/Foundation.h>
#import "AxsCacheKeeperWebKitCache.h"

// The external asynchronous system API is controlled; the real coordinator and status are exercised.
@interface AxsCacheKeeperOperationTestStore : NSObject <AxsCacheKeeperWebKitStore>
@property(nonatomic,copy) void (^reply)(void);
@end
@implementation AxsCacheKeeperOperationTestStore
- (BOOL)isPersistent { return YES; }
- (void)removeDataOfTypes:(NSSet *)types modifiedSince:(NSDate *)date completionHandler:(void (^)(void))completion {
    (void)types;(void)date;self.reply=completion;
}
@end
static void check(BOOL pass,const char *message) {
    if (!pass) {fprintf(stderr,"FAIL: operation-history: %s\n",message);exit(1);}
}
int main(void) {
    @autoreleasepool {
        NSMutableDictionary *context=[@{@"readable":@YES,@"valid":@YES,@"enabled":@YES,@"requested":@YES,
            @"excludedPaths":@[],@"installation":@"private-install-canary",@"process":@"private-process-canary",@"reportWritable":@YES} mutableCopy];
        AxsCacheKeeperWebKitCache *engine=[[AxsCacheKeeperWebKitCache alloc] initWithPreparation:nil clock:nil scheduler:^(NSTimeInterval delay,void (^block)(void)){(void)delay;(void)block;} observer:nil];
        [engine updateContext:context];
        AxsCacheKeeperOperationTestStore *store=[AxsCacheKeeperOperationTestStore new];[engine observeStore:store];
        [engine didBecomeActive];[engine didEnterBackgroundWithTime:YES];
        check(store.reply!=nil,"initial request reaches asynchronous boundary");
        context[@"requested"]=@NO;[engine updateContext:context];
        store.reply();store.reply();
        check([engine.receipt[@"state"] isEqual:@"disabled"],"late callback does not replace disabled current state");
        check([engine.receipt[@"completed"] unsignedIntegerValue]==1,"duplicate completion is ignored");
        NSDictionary *oldAction=engine.receipt[@"operationHistory"][@"processes"][0][@"actions"][0];
        check([oldAction[@"state"] isEqual:@"apiCompleted"],"late completion remains attached to original action");
        context[@"requested"]=@YES;[engine updateContext:context];
        for (NSUInteger round=0;round<3;round++) {
            [engine didBecomeActive];[engine didEnterBackgroundWithTime:YES];store.reply();
            check([engine.receipt[@"state"] isEqual:@"completed"],"three foreground background rounds complete independently");
        }
        [engine didBecomeActive];[engine didEnterBackgroundWithTime:YES];
        [engine didBecomeActive];store.reply();
        check(![engine.receipt[@"state"] isEqual:@"completed"],"old callback cannot replace new foreground state");
        check(axs_cachekeeper_webkit_raw_projection(engine.receipt)!=nil,"real engine history validates");
        NSArray *actions=engine.receipt[@"operationHistory"][@"processes"][0][@"actions"];
        check(actions.count==5,"each lifecycle action retained exactly once");
        __block void (^preparation)(NSDictionary *,BOOL)=nil;
        AxsCacheKeeperWebKitCache *queued=[[AxsCacheKeeperWebKitCache alloc] initWithPreparation:^(void (^reply)(NSDictionary *,BOOL)){preparation=reply;} clock:nil scheduler:^(NSTimeInterval delay,void (^block)(void)){(void)delay;(void)block;} observer:nil];
        [queued updateContext:context];
        AxsCacheKeeperOperationTestStore *second=[AxsCacheKeeperOperationTestStore new];
        [queued observeStore:store];[queued observeStore:second];
        [queued didBecomeActive];[queued didEnterBackgroundWithTime:YES];
        NSArray *queuedActions=queued.receipt[@"operationHistory"][@"processes"][0][@"actions"];
        check(queuedActions.count==2 && ![queuedActions[0][@"ownerID"] isEqual:queuedActions[1][@"ownerID"]],"multiple owners have distinct child actions");
        context[@"excludedPaths"]=@[@"Library/kept"];preparation(context,YES);
        for (NSDictionary *action in queued.receipt[@"operationHistory"][@"processes"][0][@"actions"])
            check([action[@"state"] isEqual:@"skipped"],"exclusion after queue records each unsubmitted child as skipped");
        check([queued.receipt[@"submitted"] unsignedIntegerValue]==0,"exclusion before submission retains original gate");
        NSUInteger requested=[queued beginOperationRefreshWithTrigger:@"foreground"];
        [queued suspendForConfiguration];[queued completeOperationRefresh:requested applied:NO];
        NSArray *events=queued.receipt[@"operationHistory"][@"processes"][0][@"events"];
        BOOL obsolete=NO;for (NSDictionary *event in events) if ([event[@"eventID"] unsignedIntegerValue]==requested) obsolete=[event[@"refresh"] isEqual:@"obsolete"];
        check(obsolete,"late refresh result remains obsolete on original event");
        puts("PASS: operation-history late callback preserves current authorization");
    }
    return 0;
}
