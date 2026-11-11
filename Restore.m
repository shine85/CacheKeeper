#import <Foundation/Foundation.h>
extern void CKPermissions(NSURL *, BOOL);
int main(void) { @autoreleasepool { CKPermissions(nil,NO); } return 0; }
