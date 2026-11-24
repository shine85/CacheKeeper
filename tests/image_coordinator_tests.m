#import <Foundation/Foundation.h>
#import "AxsCacheKeeperImageCoordinator.h"
#include <stdio.h>
#include <stdlib.h>

// UIKit's token/expiration boundary is injected; the production coordinator runs unchanged.
@interface AxsCacheKeeperImageLifecycleFixture : NSObject <AxsCacheKeeperImageLifecycle>
@property(nonatomic,strong) NSDictionary *receipt;
@property(nonatomic,copy) void (^scheduled)(void);
@property(nonatomic) NSUInteger backgrounds,active,expired;
@property(nonatomic) BOOL receivedTime;
@end
@implementation AxsCacheKeeperImageLifecycleFixture
- (void)didEnterBackgroundWithTime:(BOOL)time completion:(void (^)(void))completion {
    self.backgrounds++;self.receivedTime=time;self.scheduled=completion;
}
- (void)didBecomeActive {self.active++;}
- (void)expireBackgroundTime {self.expired++;}
@end
static void require(BOOL value,const char *message) {
    if (!value) {fprintf(stderr,"FAIL: image-coordinator: %s\n",message);exit(1);}
}
int main(int argc,const char **argv) {@autoreleasepool {
    (void)argc;(void)argv;
    AxsCacheKeeperImageLifecycleFixture *cache=[AxsCacheKeeperImageLifecycleFixture new];
    cache.receipt=@{@"eligible":@0,@"pending":@0};
    __block NSUInteger begins=0;NSMutableArray *ended=[NSMutableArray new],*expirations=[NSMutableArray new];
    __block BOOL synchronousExpiration=NO,denyTask=NO,timeAvailable=YES;
    __block void (^reenter)(void);
    AxsCacheKeeperImageCoordinator *coordinator=[[AxsCacheKeeperImageCoordinator alloc] initWithCache:cache
        beginBackground:^NSUInteger(void (^expire)(void)) {NSUInteger token=++begins;[expirations addObject:[expire copy]];if (synchronousExpiration) expire();if (reenter) {void (^callback)(void)=reenter;reenter=nil;callback();}return denyTask ? 0 : token;}
        endBackground:^(NSUInteger token) {[ended addObject:@(token)];}
        backgroundTime:^BOOL(NSUInteger token) {return token!=0 && timeAvailable;}];
    [coordinator didEnterBackground];
    require(begins==1 && cache.receivedTime,"a stale zero eligible receipt cannot deny preparation time");
    [coordinator didEnterBackground];require(begins==1 && cache.backgrounds==1,"duplicate background notification starts one attempt");
    [coordinator receiptDidChange];require(ended.count==0,"intermediate empty refresh cannot end preparation time");
    cache.receipt=@{@"eligible":@1,@"pending":@1};cache.scheduled();
    require(ended.count==0,"scheduled owner keeps its task until completion");
    cache.receipt=@{@"eligible":@1,@"pending":@0};[coordinator receiptDidChange];
    require([ended isEqual:@[@1]],"completed scheduled work ends exactly its task");
    NSUInteger finishedExpired=cache.expired;((void (^)(void))expirations[0])();
    require(cache.expired==finishedExpired,"ended task expiration cannot revoke an already completed request");
    [coordinator didBecomeActive];[coordinator didEnterBackground];
    void (^oldCompletion)(void)=[cache.scheduled copy];
    void (^oldExpiration)(void)=expirations.lastObject;
    [coordinator didBecomeActive];[coordinator didEnterBackground];
    NSUInteger endings=ended.count,expired=cache.expired;
    oldCompletion();oldExpiration();
    require(ended.count==endings && cache.expired==expired,"late old completion and expiration leave a newer task alive");
    [coordinator configurationDidChange];
    require(ended.count==endings+1 && cache.expired==expired+1,"configuration revocation closes current background authorization");
    [coordinator didBecomeActive];synchronousExpiration=YES;[coordinator didEnterBackground];
    require(!cache.receivedTime && [ended.lastObject isEqual:@4],"synchronous expiration returns and ends its token without usable time");
    [coordinator didBecomeActive];synchronousExpiration=NO;denyTask=YES;endings=ended.count;
    [coordinator didEnterBackground];cache.scheduled();
    require(!cache.receivedTime && ended.count==endings,"invalid task never grants time or gets ended");
    [coordinator didBecomeActive];denyTask=NO;timeAvailable=NO;[coordinator didEnterBackground];cache.scheduled();
    require(!cache.receivedTime && [ended.lastObject isEqual:@6],"insufficient platform time never becomes usable preparation time");
    [coordinator didBecomeActive];timeAvailable=YES;__weak AxsCacheKeeperImageCoordinator *weak=coordinator;
    reenter=^{[weak didBecomeActive];[weak didEnterBackground];};
    [coordinator didEnterBackground];
    require(begins==8 && [ended.lastObject isEqual:@7] && cache.receivedTime,"reentrant task acquisition retires only its obsolete returned token");
    NSUInteger before=ended.count;((void (^)(void))expirations[6])();
    require(ended.count==before,"obsolete reentrant expiration cannot end the replacement task");
    cache.scheduled();require([ended.lastObject isEqual:@8],"replacement request owns its independent completion");
    puts("PASS: image-coordinator preparation and lifecycle task ownership");return 0;
}}
