#pragma once
#import <Foundation/Foundation.h>
// Foundation runner boundary only. No UIKit lifecycle behavior is claimed here.
typedef NSUInteger UIBackgroundTaskIdentifier;
typedef NS_ENUM(NSInteger,UIApplicationState) {UIApplicationStateActive,UIApplicationStateInactive,UIApplicationStateBackground};
extern const UIBackgroundTaskIdentifier UIBackgroundTaskInvalid;
extern NSString * const UIApplicationDidBecomeActiveNotification;
extern NSString * const UIApplicationDidEnterBackgroundNotification;
@interface UIApplication : NSObject
+ (instancetype)sharedApplication;
@property(nonatomic,readonly) NSTimeInterval backgroundTimeRemaining;
@property(nonatomic,readonly) UIApplicationState applicationState;
- (UIBackgroundTaskIdentifier)beginBackgroundTaskWithName:(NSString *)name expirationHandler:(void (^)(void))expiration;
- (void)endBackgroundTask:(UIBackgroundTaskIdentifier)task;
@end
