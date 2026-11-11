#import <Foundation/Foundation.h>
// 0.4.3：原经 CKPermissions(nil, NO) 中转（该函数写死了单个 App 的路径，已删）；
// 直接调 CKSetPaths(nil, NO) 即还原 permissions.plist 中的全部记录，行为不变。
extern void CKSetPaths(NSArray *, BOOL);
int main(void) { @autoreleasepool { CKSetPaths(nil, NO); } return 0; }
