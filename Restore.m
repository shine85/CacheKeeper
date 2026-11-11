#import <Foundation/Foundation.h>
extern NSDictionary *CKPermissions(NSURL *, BOOL);
int main(void) {
    @autoreleasepool {
        NSDictionary *result=CKPermissions(nil,NO);
        if ([result[@"failed"] unsignedIntegerValue]) {
            fprintf(stderr,"CacheKeeper: %s; permission journal retained, fix access and retry removal.\n",[result[@"error"] UTF8String]);
            return 1;
        }
    }
    return 0;
}
