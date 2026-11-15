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
@end
@implementation AxsCacheKeeperWebKitTestStore
- (BOOL)isPersistent { return self.persistent; }
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
int main(void) {
    @autoreleasepool {
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
        deadlineNow+=40;
        wcheck(deadlines.count==0 && e.calls+f.calls==0,@"slow preflight has no submission deadline");
        void (^ready)(NSDictionary *,BOOL)=deferredReply;deferredReply=nil;ready(context,YES);
        wcheck(deadlines.count==1 && [delays[0] doubleValue]==15 && e.calls+f.calls==1,@"deadline starts at actual first submission after delayed preflight");
        AxsCacheKeeperWebKitTestStore *scheduledFirst=e.calls ? e : f,*scheduledSecond=e.calls ? f : e;
        void (^oldDeadline)(void)=deadlines[0];
        deadlineNow+=4;
        void (^scheduledFirstDone)(void)=scheduledFirst.completion;scheduledFirst.completion=nil;scheduledFirstDone();
        wcheck(deadlines.count==1 && deferredReply!=nil,@"second preflight does not inherit first submission timer");
        deadlineNow+=20;oldDeadline();
        wcheck(![scheduled.receipt[@"timedOut"] boolValue],@"completed flight timer cannot time out delayed second preflight");
        ready=deferredReply;deferredReply=nil;ready(context,YES);
        wcheck(deadlines.count==2 && [delays[1] doubleValue]==15 && e.calls+f.calls==2,@"second actual submission owns its own deadline");
        deadlineNow+=14;oldDeadline();
        wcheck(![scheduled.receipt[@"timedOut"] boolValue],@"old timer cannot time out a newer flight");
        void (^secondDeadline)(void)=deadlines[1];
        secondDeadline();
        wcheck(deadlines.count==3 && [delays[2] doubleValue]==1 && ![scheduled.receipt[@"timedOut"] boolValue],@"early deadline reschedules the exact remaining interval");
        deadlineNow+=1;((void (^)(void))deadlines[2])();
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
