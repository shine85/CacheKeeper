#import "AxsCacheKeeperInstallation.h"
#include <stdio.h>

// Logos callers use Objective-C++; keep the real implementation in Objective-C.
int main(void) {
    @autoreleasepool {
        NSError *error=nil;
        NSDictionary *snapshot=axs_cachekeeper_installation_snapshot(nil,@"test.installation.linkage",@"1",&error);
        if (snapshot || error.code!=1 || ![error.domain isEqual:@"dev.local.cachekeeper.installation"]) {
            fprintf(stderr,"FAIL: mixed-language snapshot must reject an invalid bundle URL\n");return 1;
        }
        error=nil;
        if (axs_cachekeeper_validate_installation_snapshot(@{},nil,@"1",&error) ||
            error.code!=1 || ![error.domain isEqual:@"dev.local.cachekeeper.installation"]) {
            fprintf(stderr,"FAIL: mixed-language validation must reject a missing installation identity\n");return 1;
        }
        puts("PASS: Objective-C++ installation caller links real Objective-C exports and preserves identity rejection");
    }
    return 0;
}
