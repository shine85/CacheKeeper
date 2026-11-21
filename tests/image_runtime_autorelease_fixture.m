#import <Foundation/Foundation.h>

#if __has_feature(objc_arc)
#error This fixture must be compiled separately without ARC.
#endif

// Return void across the ARC boundary: the caller must not claim the pending
// autorelease as an unused Objective-C return value and release it immediately.
void axs_cachekeeper_runtime_enqueue_autorelease(id owner) {
    [[owner retain] autorelease];
}
