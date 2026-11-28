#import <XCTest/XCTest.h>
#import "Preferences/PSViewController.h"
#import "../../AxsCacheKeeperCollectionReturn.h"
#import "../../AxsCacheKeeperCollectionSession.h"
#import "../../AxsCacheKeeperImageCollection.h"
#import "../../AxsCacheKeeperOperationInfo.h"
#import "../../Prefs/CollectionNavigation.h"
#import "../../Prefs/DiagnosticsPage.h"
#import "../../Prefs/ImageCollectionPage.h"

@interface CKSettings : PSViewController
- (NSString *)axs_cachekeeper_collection_directory;
@end
@interface AxsCollectionReturnRoot : CKSettings
@property(nonatomic,copy) NSString *directory;
@end
@implementation AxsCollectionReturnRoot
- (NSString *)axs_cachekeeper_collection_directory {return self.directory;}
@end
@interface AxsCollectionReturnTests : XCTestCase
@property(nonatomic,copy) NSString *folder,*directory;
@property(nonatomic,strong) UIWindow *window;
@property(nonatomic,strong) UIWindow *priorWindow;
@end
@implementation AxsCollectionReturnTests
- (void)setUp {
    [super setUp];self.continueAfterFailure=NO;self.folder=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];self.directory=[self.folder stringByAppendingPathComponent:@"collectionSessions"];
    [NSFileManager.defaultManager createDirectoryAtPath:self.directory withIntermediateDirectories:YES attributes:nil error:NULL];
    self.priorWindow=UIApplication.sharedApplication.keyWindow;
    self.window=self.priorWindow.windowScene ? [[UIWindow alloc] initWithWindowScene:self.priorWindow.windowScene] : [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
}
- (void)tearDown {
    self.window.hidden=YES;self.window.rootViewController=nil;self.window=nil;[self.priorWindow makeKeyAndVisible];
    [NSFileManager.defaultManager removeItemAtPath:self.folder error:NULL];[super tearDown];
}
- (UINavigationController *)root {
    AxsCollectionReturnRoot *root=[AxsCollectionReturnRoot new];root.directory=self.directory;
    UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:root];self.window.rootViewController=nav;[self.window makeKeyAndVisible];return nav;
}
- (void)waitForImage:(UINavigationController *)navigation {
    NSPredicate *shown=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *bindings){(void)object;(void)bindings;return [navigation.topViewController isKindOfClass:AxsCacheKeeperImageCollectionPage.class];}];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[[[XCTNSPredicateExpectation alloc] initWithPredicate:shown object:navigation]] timeout:3],XCTWaiterResultCompleted,@"COLLECTION_AUTO_RETURN: original image page must reappear without tapping Continue");
}
- (AxsCacheKeeperCollectionSession *)imageSession {
    NSError *error=nil;AxsCacheKeeperCollectionSession *session=[AxsCacheKeeperCollectionSession createNewSessionInDirectory:self.directory error:&error];
    XCTAssertNotNil(session);XCTAssertNil(error);
    XCTAssertTrue([session beginPhase:@"hostPreflight" error:&error]);XCTAssertTrue([session finishPhase:@"hostPreflight" result:@{@"state":@"partial"} error:&error]);
    XCTAssertTrue([session beginPhase:@"capacity" error:&error]);XCTAssertTrue(([session finishPhase:@"capacity" result:@{@"state":@"partial",@"epoch":@"fixture",@"finishedAt":@2,@"completedRoots":@0,@"totalRoots":@0,@"failedRoots":@0} error:&error]));
    XCTAssertNotNil([session imageCollectionSession:&error]);
    AxsCacheKeeperCollectionReturn *store=[[AxsCacheKeeperCollectionReturn alloc] initWithDirectory:self.directory];
    XCTAssertNotNil([store selectSession:session page:@"image" error:&error]);return session;
}
- (void)testRecreatedRootAutomaticallyReturnsToOriginalImageWithoutContinue {
    AxsCacheKeeperCollectionSession *session=[self imageSession];UINavigationController *nav=[self root];[self waitForImage:nav];
    AxsCacheKeeperImageCollectionPage *page=(id)nav.topViewController;
    XCTAssertEqualObjects([[page valueForKey:@"session"] reportProjection][@"sessionID"],session.sessionID);
    XCTAssertEqual(nav.viewControllers.count,3u);
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationWillResignActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidEnterBackgroundNotification object:nil];
    self.window.rootViewController=nil;nav=nil;page=nil;
    nav=[self root];[NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];[self waitForImage:nav];
    XCTAssertEqualObjects([[(AxsCacheKeeperImageCollectionPage *)nav.topViewController valueForKey:@"session"] reportProjection][@"sessionID"],session.sessionID);
    for(NSUInteger i=0;i<3;i++)[NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];
    XCTAssertEqual(nav.viewControllers.count,3u,@"foreground notifications cannot duplicate restored pages");
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[self.folder stringByAppendingPathComponent:@"imageCollectionRequest.plist"]]);
}
- (void)testExistingNavigationKeepsSameImageAndExplicitBackStopsAutomaticReturn {
    [self imageSession];UINavigationController *nav=[self root];[self waitForImage:nav];UIViewController *page=nav.topViewController;
    UIGestureRecognizer *gesture=nav.interactivePopGestureRecognizer;id delegate=gesture.delegate;
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];XCTAssertEqual(nav.topViewController,page);
    XCTAssertEqual(gesture.delegate,delegate,@"collection never replaces the host gesture delegate");
    UIAction *back=page.navigationItem.backAction;XCTAssertNotNil(back);
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];[button addAction:back forControlEvents:UIControlEventTouchUpInside];[button sendActionsForControlEvents:UIControlEventTouchUpInside];
    AxsCacheKeeperCollectionReturn *store=[[AxsCacheKeeperCollectionReturn alloc] initWithDirectory:self.directory];XCTAssertEqualObjects([store read:NULL][@"page"],@"guided");
    UIViewController *parent=nav.viewControllers[1];[parent viewDidAppear:NO];
    UIButton *parentBack=[UIButton buttonWithType:UIButtonTypeSystem];[parentBack addAction:parent.navigationItem.backAction forControlEvents:UIControlEventTouchUpInside];[parentBack sendActionsForControlEvents:UIControlEventTouchUpInside];
    XCTAssertNil([store read:NULL]);[NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];
}
- (void)testAnotherVisiblePageIsNeverReplacedByPendingCollection {
    UINavigationController *nav=[self root];UIViewController *other=[UIViewController new];[nav pushViewController:other animated:NO];[self imageSession];
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];
    XCTAssertEqual(nav.topViewController,other);XCTAssertEqual(nav.viewControllers.count,2u);
}
- (void)testNestedHostRestoresOnlyItsVisibleNavigationBranch {
    [self imageSession];AxsCollectionReturnRoot *root=[AxsCollectionReturnRoot new];root.directory=self.directory;
    UINavigationController *inner=[[UINavigationController alloc] initWithRootViewController:root];
    UIViewController *wrapper=[UIViewController new];[wrapper addChildViewController:inner];inner.view.frame=UIScreen.mainScreen.bounds;[wrapper.view addSubview:inner.view];[inner didMoveToParentViewController:wrapper];
    UINavigationController *outer=[[UINavigationController alloc] initWithRootViewController:wrapper];self.window.rootViewController=outer;[self.window makeKeyAndVisible];
    [self waitForImage:inner];XCTAssertEqual(outer.topViewController,wrapper);XCTAssertEqual(inner.viewControllers.count,3u);
}
- (void)testMalformedIntentDoesNotLoopOrCreateCollection {
    NSString *path=[self.directory stringByAppendingPathComponent:@"return-position.plist"];
    XCTAssertTrue(([@{@"bad":@YES} writeToFile:path atomically:YES]));
    UINavigationController *nav=[self root];for(NSUInteger i=0;i<3;i++)[NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];
    XCTAssertEqual(nav.viewControllers.count,1u);XCTAssertEqual([NSFileManager.defaultManager contentsOfDirectoryAtPath:self.directory error:NULL].count,1u);
}
- (void)testStalePageCannotReviveItsSessionAfterAnotherSessionExits {
    AxsCacheKeeperCollectionSession *a=[self imageSession];AxsCacheKeeperCollectionReturn *store=[[AxsCacheKeeperCollectionReturn alloc] initWithDirectory:self.directory];
    AxsCacheKeeperCollectionNavigation *old=[[AxsCacheKeeperCollectionNavigation alloc] initWithSession:a intent:[store read:NULL]];__block NSUInteger transfers=0;old.returnToParent=^{transfers++;};
    UIViewController *page=[UIViewController new];UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:[UIViewController new]];[nav pushViewController:page animated:NO];[old attachTo:page exit:^{}];
    AxsCacheKeeperCollectionSession *b=[AxsCacheKeeperCollectionSession createNewSessionInDirectory:self.directory error:NULL];NSDictionary *newer=[store selectSession:b page:@"guided" error:NULL];
    XCTAssertTrue([old clear]);XCTAssertTrue([store clear:newer error:NULL]);
    UIButton *back=[UIButton buttonWithType:UIButtonTypeSystem];[back addAction:page.navigationItem.backAction forControlEvents:UIControlEventTouchUpInside];[back sendActionsForControlEvents:UIControlEventTouchUpInside];
    XCTAssertEqual(transfers,0u);XCTAssertNil([store read:NULL]);
}
- (void)testSkippingImageThenReturningKeepsGuideRestorable {
    AxsCacheKeeperCollectionSession *session=[self imageSession];UINavigationController *nav=[self root];[self waitForImage:nav];
    UIViewController *image=nav.topViewController;[(UIButton *)[image valueForKey:@"skipButton"] sendActionsForControlEvents:UIControlEventTouchUpInside];
    AxsCacheKeeperCollectionReturn *store=[[AxsCacheKeeperCollectionReturn alloc] initWithDirectory:self.directory];XCTAssertNil([store read:NULL]);
    UIButton *back=[UIButton buttonWithType:UIButtonTypeSystem];[back addAction:image.navigationItem.backAction forControlEvents:UIControlEventTouchUpInside];[back sendActionsForControlEvents:UIControlEventTouchUpInside];
    XCTAssertEqualObjects([store read:NULL][@"page"],@"guided");XCTAssertEqualObjects([store read:NULL][@"sessionID"],session.sessionID);
    self.window.rootViewController=nil;nav=[self root];
    NSPredicate *shown=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *bindings){(void)object;(void)bindings;return [nav.topViewController isKindOfClass:AxsCacheKeeperDiagnosticsPage.class];}];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[[[XCTNSPredicateExpectation alloc] initWithPredicate:shown object:nav]] timeout:3],XCTWaiterResultCompleted);
}
- (void)testCapacityRootRecreationKeepsOriginalEpochWithoutNewRequest {
    NSError *error=nil;AxsCacheKeeperCollectionSession *session=[AxsCacheKeeperCollectionSession createNewSessionInDirectory:self.directory error:&error];
    XCTAssertTrue([session beginPhase:@"hostPreflight" error:&error]);XCTAssertTrue([session finishPhase:@"hostPreflight" result:@{@"state":@"partial"} error:&error]);
    NSString *epoch=NSUUID.UUID.UUIDString;XCTAssertTrue([session beginCapacityWithEpoch:epoch error:&error]);
    NSString *requestPath=[self.folder stringByAppendingPathComponent:@"capacityRequest.plist"];
    XCTAssertTrue(axs_cachekeeper_capacity_write_request(requestPath,epoch,NO,&error));NSData *bytes=[NSData dataWithContentsOfFile:requestPath];
    AxsCacheKeeperCollectionReturn *store=[[AxsCacheKeeperCollectionReturn alloc] initWithDirectory:self.directory];XCTAssertNotNil([store selectSession:session page:@"guided" error:&error]);
    UINavigationController *nav=[self root];
    NSPredicate *shown=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *bindings){(void)object;(void)bindings;return [nav.topViewController isKindOfClass:AxsCacheKeeperDiagnosticsPage.class];}];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[[[XCTNSPredicateExpectation alloc] initWithPredicate:shown object:nav]] timeout:3],XCTWaiterResultCompleted);
    XCTAssertEqualObjects([nav.topViewController valueForKey:@"axs_cachekeeper_capacityEpoch"],epoch);XCTAssertEqualObjects([NSData dataWithContentsOfFile:requestPath],bytes);
}
- (void)testBackgroundDetachmentDoesNotPublishRestoreRequest {
    AxsCacheKeeperCollectionSession *session=[self imageSession];AxsCacheKeeperImageCollectionSession *image=[session imageCollectionSession:NULL];
    NSString *states=[self.folder stringByAppendingPathComponent:@"appEnabled.plist"],*status=[self.folder stringByAppendingPathComponent:@"Status"];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtPath:status withIntermediateDirectories:YES attributes:nil error:NULL]);
    XCTAssertTrue(([@{AxsCacheKeeperImageCollectionBundle:@YES} writeToFile:states atomically:YES]));
    XCTAssertTrue([@{} writeToFile:[self.folder stringByAppendingPathComponent:@"directories.plist"] atomically:YES]);
    NSDictionary *receipt=@{@"schemaVersion":@1,@"sdk":@"SDWebImage",@"state":@"ready",@"reason":@"none",@"observed":@1,@"eligible":@1,@"restricted":@0,@"writesBlocked":@0,@"queued":@0,@"submitted":@0,@"apiCompleted":@0,@"skipped":@0,@"pending":@0,@"updated":NSDate.date,@"bytesState":@"notMeasured",@"runtimeInfo":@{@"schemaVersion":@1,@"packageVersion":@"0.7.2-224.1",@"firstObserved":@1}};
    NSMutableDictionary *pending=nil;BOOL writable=NO;XCTAssertTrue(axs_cachekeeper_operation_save(receipt,[status stringByAppendingPathComponent:[AxsCacheKeeperImageCollectionBundle stringByAppendingString:@".imagecache.plist"]],YES,&pending,&writable));
    XCTAssertTrue([image start:NULL]);NSString *request=[self.folder stringByAppendingPathComponent:@"imageCollectionRequest.plist"];NSData *original=[NSData dataWithContentsOfFile:request];
    UINavigationController *nav=[self root];[self waitForImage:nav];
    [nav popToRootViewControllerAnimated:NO];
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:request],original,@"unknown host detach is not an explicit user cancel");
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];[self waitForImage:nav];
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:request],original,@"automatic reattachment never republishes or renews lease");
    NSString *imagePath=[self.directory stringByAppendingPathComponent:[session.sessionID stringByAppendingString:@".image.plist"]];
    NSMutableDictionary *document=[[NSDictionary dictionaryWithContentsOfFile:imagePath] mutableCopy];
    NSTimeInterval now=NSDate.date.timeIntervalSince1970;
    NSMutableDictionary *expired=[document[@"request"] mutableCopy];expired[@"issuedAt"]=@(now-301);expired[@"expiresAt"]=@(now-1);document[@"request"]=expired;
    NSData *saved=[NSPropertyListSerialization dataWithPropertyList:document format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];XCTAssertTrue([saved writeToFile:imagePath atomically:YES]);
    self.window.rootViewController=nil;nav=[self root];[self waitForImage:nav];
    XCTAssertEqualObjects([[nav.topViewController valueForKey:@"session"] reportProjection][@"state"],@"interrupted",@"expired original lease is shown without renewal");
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:request],original);
}
@end
