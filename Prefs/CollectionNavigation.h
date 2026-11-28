#pragma once
#import <UIKit/UIKit.h>
#import "../AxsCacheKeeperCollectionReturn.h"
#import "../AxsCacheKeeperCollectionSession.h"

// One page owns one revision. Detaching a controller is not evidence of a user Back action.
@interface AxsCacheKeeperCollectionNavigation : NSObject
- (instancetype)initWithSession:(AxsCacheKeeperCollectionSession *)session intent:(NSDictionary *)intent;
@property(nonatomic,readonly,strong) AxsCacheKeeperCollectionReturn *store;
@property(nonatomic,readonly,copy) NSDictionary *intent;
@property(nonatomic,copy) dispatch_block_t returnToParent;
- (BOOL)selectPage:(NSString *)page error:(NSError **)error;
- (void)attachTo:(UIViewController *)owner exit:(dispatch_block_t)exit;
- (BOOL)clear;
@end

BOOL axs_cachekeeper_collection_visible_root(UIViewController *owner);
