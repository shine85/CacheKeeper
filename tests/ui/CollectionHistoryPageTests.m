#import <XCTest/XCTest.h>
#import "../../Prefs/CollectionHistoryPage.h"
#import "../../AxsCacheKeeperCollectionSession.h"
@interface AxsCollectionHistoryTests : XCTestCase
@property(nonatomic,copy) NSString *directory;
@property(nonatomic,strong) UIWindow *window,*prior;
@end
@implementation AxsCollectionHistoryTests
- (void)setUp {
    [super setUp];self.continueAfterFailure=NO;
    self.directory=[[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] stringByAppendingPathComponent:@"collectionSessions"];[NSFileManager.defaultManager createDirectoryAtPath:self.directory withIntermediateDirectories:YES attributes:nil error:NULL];
    self.prior=UIApplication.sharedApplication.keyWindow;self.window=self.prior.windowScene ? [[UIWindow alloc] initWithWindowScene:self.prior.windowScene] : [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
}
- (void)tearDown {self.window.hidden=YES;self.window.rootViewController=nil;[self.prior makeKeyAndVisible];[NSFileManager.defaultManager removeItemAtPath:self.directory error:NULL];[super tearDown];}
- (void)testSelectionAndNewAreExplicitAndUseOriginalSession {
    AxsCacheKeeperCollectionSession *session=[AxsCacheKeeperCollectionSession createNewSessionInDirectory:self.directory error:NULL];__block NSString *selected=nil;__block NSUInteger creates=0;
    AxsCacheKeeperCollectionHistoryPage *page=[[AxsCacheKeeperCollectionHistoryPage alloc] initWithDirectory:self.directory selection:^(AxsCacheKeeperCollectionSession *opened){selected=opened.sessionID;} create:^{creates++;}];
    UINavigationController *navigation=[[UINavigationController alloc] initWithRootViewController:[UIViewController new]];[navigation pushViewController:page animated:NO];self.window.rootViewController=navigation;[self.window makeKeyAndVisible];[page loadViewIfNeeded];
    NSPredicate *loaded=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *bindings){(void)object;(void)bindings;return [page.tableView numberOfRowsInSection:0]==1;}];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[[[XCTNSPredicateExpectation alloc] initWithPredicate:loaded object:page]] timeout:3],XCTWaiterResultCompleted);
    XCTAssertEqual([page.tableView numberOfRowsInSection:0],1);XCTAssertNil(selected);XCTAssertEqual(creates,0u);
    [page tableView:page.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
    NSPredicate *opened=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *bindings){(void)object;(void)bindings;return selected!=nil;}];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[[[XCTNSPredicateExpectation alloc] initWithPredicate:opened object:page]] timeout:3],XCTWaiterResultCompleted);
    XCTAssertEqualObjects(selected,session.sessionID);XCTAssertEqual(creates,0u);
    [navigation pushViewController:page animated:NO];[UIApplication.sharedApplication sendAction:page.navigationItem.rightBarButtonItem.action to:page.navigationItem.rightBarButtonItem.target from:page.navigationItem.rightBarButtonItem forEvent:nil];XCTAssertEqual(creates,1u);
}
@end
