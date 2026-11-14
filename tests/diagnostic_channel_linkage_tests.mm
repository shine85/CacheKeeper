#import "../AxsCacheKeeperDiagnosticChannel.h"
#import <dispatch/dispatch.h>
#include <stdio.h>

// A Logos caller is Objective-C++; the production implementation remains Objective-C.
int main(void) {
    @autoreleasepool {
        dispatch_group_t group=dispatch_group_create();
        __block NSDictionary *server=nil,*client=nil;
        dispatch_group_enter(group);
        axs_cachekeeper_diagnostic_channel_start(^(NSDictionary *status) {
            server=status;dispatch_group_leave(group);
        });
        dispatch_group_async(group,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
            client=axs_cachekeeper_diagnostic_channel_hello();
        });
        if (dispatch_group_wait(group,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC))!=0) {
            fprintf(stderr,"FAIL: mixed-language diagnostic channel callbacks timed out\n");return 1;
        }
        for (NSDictionary *status in @[server ?: @{},client ?: @{}]) {
            if (![status[@"state"] isEqual:@"unavailable"] ||
                ![status[@"errorOrigin"] isEqual:@"local"] ||
                ![status[@"serverRegister"] isEqual:@"notObserved"]) {
                fprintf(stderr,"FAIL: mixed-language caller must preserve CLI host rejection\n");return 1;
            }
        }
        puts("PASS: Objective-C++ caller links both real Objective-C channel exports and preserves host rejection");
    }
    return 0;
}
