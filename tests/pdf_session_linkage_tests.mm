#import <Foundation/Foundation.h>
#import "../AxsCacheKeeperPDFSession.h"
#include <stdio.h>
int main(void) {
    @autoreleasepool {
        // Real Objective-C++ caller, as in Desktop.xm. nil never opens/registers a service.
        axs_cachekeeper_pdf_session_server_start(nil);
        puts("PASS: PDF service Objective-C++ caller links to Objective-C implementation");
    }
    return 0;
}
