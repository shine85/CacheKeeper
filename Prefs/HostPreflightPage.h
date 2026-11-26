#pragma once
#import <UIKit/UIKit.h>

// Batches the existing technical self-report; it does not change host policy.
@interface AxsCacheKeeperHostPreflightPage : UIViewController
- (instancetype)initWithStatusDirectory:(NSString *)directory panelVersion:(NSString *)version;
@end
