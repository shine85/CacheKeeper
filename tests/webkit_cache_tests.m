#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#import "../AxsCacheKeeperWebKitCache.h"

static void wcheck(BOOL value, NSString *message) {
    if (!value) { fprintf(stderr,"FAIL: webkit-cache: %s\n",message.UTF8String);exit(1); }
}
@interface AxsCacheKeeperWebKitTestStore : NSObject <AxsCacheKeeperWebKitStore>
@property(nonatomic) BOOL persistent;
@property(nonatomic) NSUInteger calls;
@property(nonatomic,copy) void (^completion)(void);
@property(nonatomic,copy) NSSet *types;
@property(nonatomic,strong) NSDate *date;
@property(nonatomic,copy) void (^onPersistentRead)(void);
@end
@implementation AxsCacheKeeperWebKitTestStore
- (BOOL)isPersistent { if (self.onPersistentRead) self.onPersistentRead();return self.persistent; }
- (void)removeDataOfTypes:(NSSet *)types modifiedSince:(NSDate *)date completionHandler:(void (^)(void))completion {
    self.calls++;self.types=types;self.date=date;self.completion=completion;
}
@end
static NSMutableDictionary *wcontext(void) {
    return [@{@"readable":@YES,@"valid":@YES,@"enabled":@YES,@"requested":@YES,
        @"excludedPaths":@[],@"installation":@"install-a",@"process":@"process-a",@"reportWritable":@YES} mutableCopy];
}
static AxsCacheKeeperWebKitTestStore *wstore(BOOL persistent) {
    AxsCacheKeeperWebKitTestStore *store=[AxsCacheKeeperWebKitTestStore new];store.persistent=persistent;return store;
}
static void winitial_configuration_wait(void) {
    __block NSTimeInterval now=100;
    NSMutableArray *replies=[NSMutableArray new],*deadlines=[NSMutableArray new];
    AxsCacheKeeperWebKitCache *engine=[[AxsCacheKeeperWebKitCache alloc] initWithPreparation:^(void (^reply)(NSDictionary *,BOOL)) {
        [replies addObject:[reply copy]];
    } clock:^{return now;} scheduler:^(NSTimeInterval delay,void (^deadline)(void)) {
        (void)delay;[deadlines addObject:[deadline copy]];
    } observer:^(NSDictionary *receipt) {wcheck(axs_cachekeeper_webkit_projection(receipt)!=nil,@"initial preparation receipt obeys the closed schema");}];
    NSDictionary *context=wcontext();AxsCacheKeeperWebKitTestStore *store=wstore(YES);
    [engine updateContext:context];[engine observeStore:store];[engine didBecomeActive];
    [engine suspendForConfiguration];[engine beginBackgroundPreparation];
    wcheck(deadlines.count==1 && engine.hasPendingWork,@"initial configuration wait owns the first preparation deadline");
    now+=10;((void (^)(void))deadlines[0])();[engine updateContext:context];
    wcheck(!engine.backgroundPreparationAllowed && store.calls==0 && !engine.hasPendingWork &&
        [engine.receipt[@"reason"] isEqual:@"deadlineExceeded"],@"initial wait expiry rejects late validation without API submission");
    [engine didBecomeActive];[engine suspendForConfiguration];[engine beginBackgroundPreparation];
    now+=9;[engine updateContext:context];wcheck(engine.backgroundPreparationAllowed,@"current validation before initial deadline may prepare");
    [engine didEnterBackgroundWithTime:YES];
    now+=1;((void (^)(NSDictionary *,BOOL))replies.lastObject)(context,YES);
    wcheck(store.calls==0 && [engine.receipt[@"reason"] isEqual:@"deadlineExceeded"],@"first owner inherits the initial configuration wait start");
    [engine didBecomeActive];[engine suspendForConfiguration];[engine beginBackgroundPreparation];
    now+=10;[engine updateContext:context];
    wcheck(!engine.backgroundPreparationAllowed && store.calls==0 && !engine.hasPendingWork,
        @"late initial validation is rejected before a delayed timer is delivered");
    [engine didBecomeActive];[engine suspendForConfiguration];[engine beginBackgroundPreparation];
    void (^oldDeadline)(void)=deadlines.lastObject;
    [engine suspendForConfigurationWithAuthorization:NO];now+=10;oldDeadline();
    wcheck(!engine.hasPendingWork && [engine.receipt[@"reason"] isEqual:@"notAuthorized"],@"revocation invalidates the initial configuration timer");
}
static void wpreparation_lifecycle(void) {
    // Removing preparation expiry or preserving queued after cancellation must fail here.
    __block NSTimeInterval now=100;
    NSMutableDictionary *context=wcontext();
    NSMutableArray *replies=[NSMutableArray new],*deadlines=[NSMutableArray new];
    AxsCacheKeeperWebKitCache *engine=[[AxsCacheKeeperWebKitCache alloc] initWithPreparation:^(void (^reply)(NSDictionary *,BOOL)) {
        [replies addObject:[reply copy]];
    } clock:^{return now;} scheduler:^(NSTimeInterval delay,void (^deadline)(void)) {
        (void)delay;[deadlines addObject:[deadline copy]];
    } observer:^(NSDictionary *receipt) {wcheck(axs_cachekeeper_webkit_projection(receipt)!=nil,@"preparation lifecycle receipt is valid");}];
    AxsCacheKeeperWebKitTestStore *store=wstore(YES);
    [engine updateContext:context];[engine observeStore:store];[engine didBecomeActive];[engine didEnterBackgroundWithTime:YES];
    wcheck(replies.count==1 && deadlines.count==1,@"preparation owns a deadline before API submission");
    now+=6;[engine suspendForConfiguration];[engine updateContext:context];
    wcheck(replies.count==2 && deadlines.count==1,@"equal refresh resumes preparation without resetting its deadline");
    ((void (^)(NSDictionary *,BOOL))replies[0])(context,YES);
    wcheck(store.calls==0,@"superseded preparation reply cannot submit");
    now+=4;((void (^)(void))deadlines[0])();
    wcheck([engine.receipt[@"reason"] isEqual:@"deadlineExceeded"] && ![engine.receipt[@"state"] isEqual:@"queued"] && store.calls==0,@"ten-second preparation expiry settles without a submitted call");
    ((void (^)(NSDictionary *,BOOL))replies[1])(context,YES);
    wcheck(store.calls==0,@"reply after preparation expiry cannot submit");
    [engine didBecomeActive];[engine didEnterBackgroundWithTime:YES];
    ((void (^)(void))deadlines[0])();
    wcheck([engine.receipt[@"state"] isEqual:@"queued"],@"old preparation deadline cannot cancel a new round");
    [engine didBecomeActive];
    wcheck([engine.receipt[@"reason"] isEqual:@"foregroundAgain"] && ![engine.receipt[@"state"] isEqual:@"queued"],@"foreground cancellation settles top-level queued state");
    [engine updateContext:context];[engine didEnterBackgroundWithTime:YES];
    void (^current)(NSDictionary *,BOOL)=replies.lastObject;current(context,YES);current(context,YES);
    wcheck(store.calls==1 && [engine.receipt[@"pending"] boolValue],@"next valid round recovers and duplicate preparation submits once");
    [engine expireBackgroundTime];store.completion();
    wcheck([engine.receipt[@"completed"] integerValue]==1 && [engine.receipt[@"reason"] isEqual:@"noBackgroundTime"],@"late API callback preserves current expired scheduling state");
}
static void wrefresh_gates(void) {
    // Unconditionally cancelling equal refreshes or accepting changed authorization breaks these cases.
    NSArray *changes=@[@{},@{@"requested":@NO},@{@"excludedPaths":@[@"kept"]},@{@"installation":@"new-install"},@{@"process":@"new-process"}];
    for (NSDictionary *change in changes) {
        NSMutableDictionary *context=wcontext();NSMutableArray *replies=[NSMutableArray new];
        AxsCacheKeeperWebKitCache *engine=[[AxsCacheKeeperWebKitCache alloc] initWithPreparation:^(void (^reply)(NSDictionary *,BOOL)) {
            [replies addObject:[reply copy]];
        } clock:^{return 100.0;} scheduler:^(NSTimeInterval delay,void (^deadline)(void)) {(void)delay;(void)deadline;}
        observer:^(NSDictionary *receipt) {wcheck(axs_cachekeeper_webkit_projection(receipt)!=nil,@"refresh gate receipt is valid");}];
        AxsCacheKeeperWebKitTestStore *store=wstore(YES);[engine updateContext:context];[engine observeStore:store];
        [engine didBecomeActive];[engine didEnterBackgroundWithTime:YES];[engine suspendForConfiguration];
        [context addEntriesFromDictionary:change];[engine updateContext:context];
        ((void (^)(NSDictionary *,BOOL))replies[0])(wcontext(),YES);
        wcheck(store.calls==0,@"old preparation cannot bypass a configuration refresh");
        if (!change.count) {
            wcheck(replies.count==2,@"equal authorization is prepared again in the same background attempt");
            ((void (^)(NSDictionary *,BOOL))replies[1])(context,YES);
            wcheck(store.calls==1,@"equal configuration refresh resumes exactly one API submission");
        } else wcheck(replies.count==1 && ![engine.receipt[@"state"] isEqual:@"queued"],@"changed authorization, exclusions and identity cancel instead of resuming");
    }
}
static void wsubmission_boundary(void) {
    // A store getter can re-enter the host; final task validation cannot use only an old reply.
    for (NSNumber *gate in @[@0,@1]) {
        NSMutableDictionary *context=wcontext();__block void (^reply)(NSDictionary *,BOOL)=nil;
        AxsCacheKeeperWebKitCache *engine=[[AxsCacheKeeperWebKitCache alloc] initWithPreparation:^(void (^value)(NSDictionary *,BOOL)) {reply=[value copy];}
            clock:^{return 100.0;} scheduler:^(NSTimeInterval delay,void (^deadline)(void)) {(void)delay;(void)deadline;}
            observer:^(NSDictionary *receipt) {wcheck(axs_cachekeeper_webkit_projection(receipt)!=nil,@"submission boundary receipt is valid");}];
        AxsCacheKeeperWebKitTestStore *store=wstore(YES);[engine updateContext:context];[engine observeStore:store];
        [engine didBecomeActive];[engine didEnterBackgroundWithTime:YES];
        __weak AxsCacheKeeperWebKitCache *weakEngine=engine;
        if (!gate.integerValue) [engine setBackgroundTimeValidation:^BOOL {return NO;}];
        else store.onPersistentRead=^{[weakEngine didBecomeActive];};
        reply(context,YES);
        wcheck(store.calls==0 && ![engine.receipt[@"state"] isEqual:@"queued"],@"latest task validation and getter reentry prohibit actual submission");
        store.onPersistentRead=nil;
    }
}
static void wlate_callback_states(void) {
    NSArray *reasons=@[@"foregroundAgain",@"notAuthorized",@"noBackgroundTime",@"authorizationChanged",@"inFlight"];
    for (NSUInteger scenario=0;scenario<reasons.count;scenario++) {
        NSMutableDictionary *context=wcontext();
        AxsCacheKeeperWebKitCache *engine=[[AxsCacheKeeperWebKitCache alloc] initWithPreparation:^(void (^reply)(NSDictionary *,BOOL)) {reply(context,YES);}
            clock:^{return 100.0;} scheduler:^(NSTimeInterval delay,void (^deadline)(void)) {(void)delay;(void)deadline;}
            observer:^(NSDictionary *receipt) {wcheck(axs_cachekeeper_webkit_projection(receipt)!=nil,@"production receipt obeys closed schema");}];
        AxsCacheKeeperWebKitTestStore *store=wstore(YES);[engine updateContext:context];[engine observeStore:store];
        [engine didBecomeActive];[engine didEnterBackgroundWithTime:YES];
        if (scenario==0) [engine didBecomeActive];
        if (scenario==1) {context[@"requested"]=@NO;[engine updateContext:context];}
        if (scenario==2) [engine expireBackgroundTime];
        if (scenario==3) {[engine suspendForConfigurationWithAuthorization:NO];[engine suspendForConfiguration];[engine updateContext:context];}
        if (scenario==4) {[engine didBecomeActive];[engine didEnterBackgroundWithTime:YES];}
        wcheck([engine.receipt[@"pending"] boolValue] && store.calls==1,@"lifecycle or authorization changes cannot release the original flight");
        store.completion();store.completion();
        wcheck([engine.receipt[@"completed"] integerValue]==1 && ![engine.receipt[@"pending"] boolValue] &&
            [engine.receipt[@"reason"] isEqual:reasons[scenario]] && ![engine.receipt[@"state"] isEqual:@"completed"],@"old API completion preserves the current scheduling rejection");
        NSArray *actions=[engine.receipt[@"operationHistory"][@"processes"] lastObject][@"actions"];
        wcheck([actions[0][@"state"] isEqual:@"apiCompleted"],@"late API completion belongs to its original action");
    }
}
static void wflight_before_configuration(void) {
    __block NSTimeInterval now=100;NSMutableDictionary *context=wcontext();
    NSMutableArray *replies=[NSMutableArray new],*deadlines=[NSMutableArray new];
    AxsCacheKeeperWebKitCache *engine=[[AxsCacheKeeperWebKitCache alloc] initWithPreparation:^(void (^reply)(NSDictionary *,BOOL)) {[replies addObject:[reply copy]];}
        clock:^{return now;} scheduler:^(NSTimeInterval delay,void (^deadline)(void)) {(void)delay;[deadlines addObject:[deadline copy]];}
        observer:^(NSDictionary *receipt) {wcheck(axs_cachekeeper_webkit_projection(receipt)!=nil,@"multi-store paused configuration receipt is valid");}];
    AxsCacheKeeperWebKitTestStore *a=wstore(YES),*b=wstore(YES);[engine updateContext:context];[engine observeStore:a];[engine observeStore:b];
    for (NSUInteger round=0;round<2;round++) {
        NSUInteger before=replies.count;
        [engine didBecomeActive];[engine didEnterBackgroundWithTime:YES];
        ((void (^)(NSDictionary *,BOOL))replies[before])(context,YES);
        AxsCacheKeeperWebKitTestStore *first=a.calls>b.calls ? a : b,*second=first==a ? b : a;
        [engine suspendForConfiguration];first.completion();
        wcheck([engine.receipt[@"state"] isEqual:@"queued"] && [engine.receipt[@"completed"] integerValue]==1 && ![engine.receipt[@"pending"] boolValue],@"flight completing before equal configuration preserves the next queued owner");
        NSUInteger timerCount=deadlines.count;now+=7;[engine updateContext:context];
        wcheck(replies.count==before+2 && deadlines.count==timerCount,@"paused second-owner preparation resumes with its original deadline");
        now+=1;((void (^)(NSDictionary *,BOOL))replies.lastObject)(context,YES);second.completion();
        wcheck([engine.receipt[@"completed"] integerValue]==2 && !engine.hasPendingWork,@"two multi-store rounds complete after paused configuration recovery");
    }
}
int main(void) {
    @autoreleasepool {
        wpreparation_lifecycle();
        wrefresh_gates();
        wsubmission_boundary();
        wlate_callback_states();
        wflight_before_configuration();
        winitial_configuration_wait();
        __block NSMutableDictionary *context=wcontext();__block NSTimeInterval now=100;
        __block void (^pendingPreparation)(NSDictionary *,BOOL)=nil;
        __block BOOL deferPreparation=NO;
        AxsCacheKeeperWebKitCache *engine=[[AxsCacheKeeperWebKitCache alloc] initWithPreparation:^(void (^reply)(NSDictionary *,BOOL)) {
            if (deferPreparation) pendingPreparation=[reply copy]; else reply(context,YES);
        } clock:^{return now;} observer:^(NSDictionary *receipt) {
            wcheck(axs_cachekeeper_webkit_projection(receipt)!=nil,@"production receipt obeys closed schema");
        }];
        [engine updateContext:context];
        AxsCacheKeeperWebKitTestStore *a=wstore(YES),*b=wstore(YES),*privateStore=wstore(NO);
        [engine observeStore:a];[engine observeStore:a];[engine observeStore:privateStore];
        wcheck([engine.receipt[@"persistentStores"] integerValue]==1 && [engine.receipt[@"nonPersistentStores"] integerValue]==1,@"store identity deduplicated");
        [engine didBecomeActive];[engine didEnterBackgroundWithTime:YES];
        wcheck(a.calls==1 && privateStore.calls==0,@"one persistent store is actually invoked");
        wcheck([a.types isEqual:[NSSet setWithObject:WKWebsiteDataTypeDiskCache]] && [a.date isEqual:NSDate.distantPast],@"only DiskCache reaches public removal boundary");
        [engine didEnterBackgroundWithTime:YES];
        now+=16;[engine checkTimeout];[engine didBecomeActive];[engine didEnterBackgroundWithTime:YES];
        wcheck(a.calls==1 && [engine.receipt[@"pending"] integerValue]==1 && [engine.receipt[@"timedOut"] boolValue],@"timeout retains in-flight across new lifecycle");
        context[@"requested"]=@NO;[engine updateContext:context];context[@"requested"]=@YES;[engine updateContext:context];
        [engine didBecomeActive];[engine didEnterBackgroundWithTime:YES];
        wcheck(a.calls==1,@"off/on cannot bypass in-flight");
        void (^late)(void)=a.completion;a.completion=nil;late();late();
        wcheck([engine.receipt[@"completed"] integerValue]==1 && ![engine.receipt[@"pending"] boolValue],@"late completion matches original once");

        context[@"excludedPaths"]=@[@"Unrelated/kept"];[engine updateContext:context];
        [engine didBecomeActive];[engine didEnterBackgroundWithTime:YES];
        wcheck(a.calls==1 && [engine.receipt[@"reason"] isEqual:@"exclusionUnrepresentable"],@"any exclusion blocks broad API");
        context[@"excludedPaths"]=@[];[engine updateContext:context];
        deferPreparation=YES;[engine didBecomeActive];[engine didEnterBackgroundWithTime:YES];
        wcheck(pendingPreparation!=nil,@"preflight is asynchronous and observable");
        context[@"excludedPaths"]=@[@"Library/WebKit"];pendingPreparation(context,YES);pendingPreparation=nil;
        wcheck(a.calls==1,@"new exclusion during preflight blocks submission");

        context=wcontext();[engine updateContext:context];[engine observeStore:b];
        [engine didBecomeActive];[engine didEnterBackgroundWithTime:YES];
        context[@"installation"]=@"install-b";pendingPreparation(context,YES);pendingPreparation=nil;
        wcheck(a.calls==1 && b.calls==0 && [engine.receipt[@"persistentStores"] integerValue]==0,@"installation generation change invalidates observations");
        [engine observeStore:b];[engine didBecomeActive];[engine didEnterBackgroundWithTime:YES];
        [engine expireBackgroundTime];pendingPreparation(context,YES);pendingPreparation=nil;
        wcheck(b.calls==0,@"expired background budget blocks late preflight");

        deferPreparation=NO;[engine didBecomeActive];[engine didEnterBackgroundWithTime:YES];
        wcheck(b.calls==1,@"new observed generation can submit");
        context[@"process"]=@"process-b";[engine updateContext:context];
        void (^old)(void)=b.completion;b.completion=nil;old();
        wcheck([engine.receipt[@"completed"] integerValue]==1,@"old completion remains in original batch after generation invalidation");
        [engine didBecomeActive];[engine didEnterBackgroundWithTime:YES];
        wcheck(b.calls==1,@"new process token requires new observation");

        NSMutableDictionary *bad=[engine.receipt mutableCopy];bad[@"url"]=@"https://private.invalid/account";
        wcheck(!axs_cachekeeper_webkit_projection(bad),@"unknown private report fields are rejected");
        bad=[engine.receipt mutableCopy];bad[@"pending"]=@2;
        wcheck(!axs_cachekeeper_webkit_projection(bad),@"invalid in-flight count is rejected");
        bad=[engine.receipt mutableCopy];bad[@"state"]=@"completed";bad[@"reason"]=@"none";
        bad[@"submitted"]=@2;bad[@"completed"]=@1;bad[@"pending"]=@0;
        wcheck(!axs_cachekeeper_webkit_projection(bad),@"submitted calls cannot disappear without completion or pending state");
        context=wcontext();context[@"requested"]=@"YES";[engine updateContext:context];[engine observeStore:a];
        [engine didBecomeActive];[engine didEnterBackgroundWithTime:YES];
        wcheck(a.calls==1,@"malformed authorization never submits");

        context=wcontext();
        AxsCacheKeeperWebKitCache *serial=[[AxsCacheKeeperWebKitCache alloc] initWithPreparation:^(void (^reply)(NSDictionary *,BOOL)) {reply(context,YES);}
            clock:^{return now;} observer:nil];
        [serial updateContext:context];
        AxsCacheKeeperWebKitTestStore *c=wstore(YES),*d=wstore(YES);
        [serial observeStore:c];[serial observeStore:d];[serial didBecomeActive];[serial didEnterBackgroundWithTime:YES];
        wcheck(c.calls+d.calls==1,@"different stores serialize in one process");
        AxsCacheKeeperWebKitTestStore *first=c.calls ? c : d,*second=c.calls ? d : c;
        void (^firstDone)(void)=first.completion;first.completion=nil;firstDone();
        wcheck(c.calls+d.calls==2 && [serial.receipt[@"pending"] boolValue],@"next store starts only after first completion");
        firstDone();
        wcheck([serial.receipt[@"completed"] integerValue]==1 && [serial.receipt[@"pending"] boolValue],@"duplicate first callback cannot release second store");
        void (^secondDone)(void)=second.completion;second.completion=nil;secondDone();
        wcheck([serial.receipt[@"completed"] integerValue]==2 && ![serial.receipt[@"pending"] boolValue],@"both serialized callbacks recorded without fake bytes");

        __block NSTimeInterval deadlineNow=1000;
        __block void (^deferredReply)(NSDictionary *,BOOL)=nil;
        NSMutableArray *deadlines=[NSMutableArray new],*delays=[NSMutableArray new];
        AxsCacheKeeperWebKitCache *scheduled=[[AxsCacheKeeperWebKitCache alloc] initWithPreparation:^(void (^reply)(NSDictionary *,BOOL)) {
            deferredReply=[reply copy];
        } clock:^{return deadlineNow;} scheduler:^(NSTimeInterval delay,void (^deadline)(void)) {
            [delays addObject:@(delay)];[deadlines addObject:[deadline copy]];
        } observer:^(NSDictionary *receipt) {
            wcheck(axs_cachekeeper_webkit_projection(receipt)!=nil,@"scheduled receipt obeys closed schema");
        }];
        AxsCacheKeeperWebKitTestStore *e=wstore(YES),*f=wstore(YES);
        [scheduled updateContext:context];[scheduled observeStore:e];[scheduled observeStore:f];
        [scheduled didBecomeActive];[scheduled didEnterBackgroundWithTime:YES];
        deadlineNow+=6;
        wcheck(deadlines.count==1 && e.calls+f.calls==0,@"preflight has its own deadline without an API flight");
        void (^ready)(NSDictionary *,BOOL)=deferredReply;deferredReply=nil;ready(context,YES);
        wcheck(deadlines.count==2 && [delays[1] doubleValue]==15 && e.calls+f.calls==1,@"flight deadline starts at actual first submission after delayed preflight");
        AxsCacheKeeperWebKitTestStore *scheduledFirst=e.calls ? e : f,*scheduledSecond=e.calls ? f : e;
        void (^oldPreparationDeadline)(void)=deadlines[0];oldPreparationDeadline();
        wcheck([scheduled.receipt[@"pending"] boolValue],@"completed preparation timer cannot cancel its submitted flight");
        void (^oldDeadline)(void)=deadlines[1];
        deadlineNow+=4;
        void (^scheduledFirstDone)(void)=scheduledFirst.completion;scheduledFirst.completion=nil;scheduledFirstDone();
        wcheck(deadlines.count==3 && deferredReply!=nil,@"second preflight has its own preparation timer");
        deadlineNow+=6;oldDeadline();
        wcheck(![scheduled.receipt[@"timedOut"] boolValue],@"completed flight timer cannot time out delayed second preflight");
        ready=deferredReply;deferredReply=nil;ready(context,YES);
        wcheck(deadlines.count==4 && [delays[3] doubleValue]==15 && e.calls+f.calls==2,@"second actual submission owns its own deadline");
        deadlineNow+=14;oldDeadline();
        wcheck(![scheduled.receipt[@"timedOut"] boolValue],@"old timer cannot time out a newer flight");
        void (^secondDeadline)(void)=deadlines[3];
        secondDeadline();
        wcheck(deadlines.count==5 && [delays[4] doubleValue]==1 && ![scheduled.receipt[@"timedOut"] boolValue],@"early deadline reschedules the exact remaining interval");
        deadlineNow+=1;((void (^)(void))deadlines[4])();
        wcheck([scheduled.receipt[@"timedOut"] boolValue] && [scheduled.receipt[@"pending"] boolValue],@"second flight times out fifteen seconds after its own submission");
        void (^scheduledSecondDone)(void)=scheduledSecond.completion;scheduledSecond.completion=nil;scheduledSecondDone();
        [scheduled didBecomeActive];[scheduled didEnterBackgroundWithTime:YES];
        ready=deferredReply;deferredReply=nil;ready(context,YES);
        wcheck(![scheduled.receipt[@"timedOut"] boolValue] && [scheduled.receipt[@"pending"] boolValue],@"later submission resets timed-out state");
        secondDeadline();
        wcheck(![scheduled.receipt[@"timedOut"] boolValue],@"late prior-round deadline cannot mark the new round timed out");
        context=wcontext();context[@"installation"]=@"";
        NSDictionary *check=@{@"state":@"failed",@"errorCode":@6};
        context[@"installationCheck"]=check;
        AxsCacheKeeperWebKitCache *identityEngine=[[AxsCacheKeeperWebKitCache alloc] initWithPreparation:nil clock:nil observer:nil];
        [identityEngine updateContext:context];
        wcheck([identityEngine.receipt[@"installationCheck"] isEqual:check],@"installation failure detail survives the production receipt");
        wcheck([identityEngine.receipt[@"reason"] isEqual:@"installationUnverified"],@"diagnostic details cannot bypass installation verification");
        wcheck([axs_cachekeeper_webkit_message(identityEngine.receipt) containsString:@"安装版本或身份已变化"],@"installation failure has an actionable bounded message");
        NSDictionary *detail=@{@"target":@"main",@"operation":@"open",@"errno":@13};
        context[@"installationCheck"]=@{@"state":@"failed",@"errorCode":@3,@"detail":detail};
        [identityEngine updateContext:context];
        wcheck([identityEngine.receipt[@"installationCheck"][@"detail"] isEqual:detail] &&
            [axs_cachekeeper_webkit_message(identityEngine.receipt) containsString:@"主程序 / open，errno=13"],
            @"bounded installation stage and errno survive production receipt and presentation");
        NSMutableDictionary *invalid=[identityEngine.receipt mutableCopy];
        invalid[@"installationCheck"]=@{@"state":@"verified",@"errorCode":@0,@"detail":detail};
        wcheck(!axs_cachekeeper_webkit_projection(invalid),@"verified installation cannot carry failure details");
        invalid[@"installationCheck"]=@{@"state":@"failed",@"errorCode":@3,@"detail":@{@"target":@"main",@"operation":@"open",@"errno":@YES}};
        wcheck(!axs_cachekeeper_webkit_projection(invalid),@"boolean errno cannot masquerade as syscall evidence");
        invalid[@"installationCheck"]=@{@"state":@"failed",@"errorCode":@YES};
        wcheck(!axs_cachekeeper_webkit_projection(invalid),@"installation error boolean is not a numeric code");
        invalid[@"installationCheck"]=@{@"state":@"failed",@"errorCode":@6,@"path":@"private-path-must-not-export"};
        wcheck(!axs_cachekeeper_webkit_projection(invalid),@"installation diagnostics reject arbitrary data");
        [invalid removeObjectForKey:@"installationCheck"];
        wcheck(axs_cachekeeper_webkit_projection(invalid)!=nil,@"older receipts without installation details stay readable");
        puts("PASS: WebKit DiskCache action gates, generations, exclusion, single-flight and late completion");
    }
    return 0;
}
