#import <Foundation/Foundation.h>
#import "../AxsCacheKeeperAppList.h"

static void alcheck(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr,"FAIL: app list: %s\n",message.UTF8String);exit(1); }
}
static void alwait(BOOL (^done)(void), NSString *message) {
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:3];
    while (!done() && deadline.timeIntervalSinceNow>0)
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    alcheck(done(),message);
}
static void alwrite(NSString *folder, NSString *name, id value) {
    alcheck([value writeToFile:[folder stringByAppendingPathComponent:name] atomically:YES],@"写入列表夹具");
}
static NSArray *alids(NSArray *sections) {
    NSMutableArray *ids=[NSMutableArray new];
    for (NSDictionary *section in sections) for (NSDictionary *app in section[@"apps"]) [ids addObject:app[@"id"]];
    return ids;
}

void axs_cachekeeper_run_app_list_tests(NSString *fixture) {
    Class cls=NSClassFromString(@"AxsCacheKeeperAppList");
    alcheck(cls!=Nil,@"必须提供异步列表来源，不能在输入回调同步枚举和读配置");
    alcheck(NSThread.isMainThread,@"测试从主线程驱动 UI 调度契约");
    NSArray *apps=@[@{@"id":@"test.baidu",@"name":@"百度",@"pinyin":@"bai du",@"source":@"user"},
        @{@"id":@"test.swiftgram",@"name":@"Swiftgram",@"pinyin":@"Swiftgram",@"source":@"troll"}];
    NSDictionary *states=@{@"test.baidu":@{@"enabled":@YES},@"test.swiftgram":@{@"enabled":@NO}};
    NSSet *favorites=[NSSet setWithObject:@"test.swiftgram"];
    alcheck([alids([cls sectionsForApps:apps states:states favorites:favorites tab:1 query:@"百度"]) isEqual:@[@"test.baidu"]],@"中文搜索只在当前分类过滤");
    alcheck([alids([cls sectionsForApps:apps states:states favorites:favorites tab:1 query:@"BAI"]) isEqual:@[@"test.baidu"]],@"拼音搜索忽略大小写");
    alcheck([alids([cls sectionsForApps:apps states:states favorites:favorites tab:3 query:@"test.swift"]) isEqual:@[@"test.swiftgram"]],@"收藏分类允许按包名过滤");
    alcheck([alids([cls sectionsForApps:apps states:states favorites:favorites tab:0 query:@""]) isEqual:@[@"test.baidu"]],@"清空搜索恢复开启项");

    // Hold the source open while pumping the main run loop: user input must still execute.
    dispatch_semaphore_t release=dispatch_semaphore_create(0);
    __block NSUInteger delivered=0;
    __block BOOL providerOnMain=YES, completionOnMain=NO, heartbeat=NO;
    AxsCacheKeeperAppList *slow=[[cls alloc] initWithProvider:^NSDictionary *(BOOL refreshApps) {
        (void)refreshApps;providerOnMain=NSThread.isMainThread;
        dispatch_semaphore_wait(release,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC));
        return @{@"apps":apps};
    } completion:^(NSDictionary *snapshot) { (void)snapshot;completionOnMain=NSThread.isMainThread;delivered++; }];
    [slow requestRefreshApplications:YES];
    dispatch_async(dispatch_get_main_queue(),^{ heartbeat=YES; });
    alwait(^BOOL {return heartbeat;},@"慢来源不能阻塞主线程输入心跳");
    alcheck(delivered==0,@"来源未释放前不能伪造完成");
    for (NSUInteger i=0;i<25;i++) [cls sectionsForApps:apps states:states favorites:favorites tab:i%4 query:i%2?@"ba":@""];
    dispatch_semaphore_signal(release);
    alwait(^BOOL {return delivered==1;},@"慢来源应完成一次交付");
    alcheck(!providerOnMain && completionOnMain,@"来源在后台，界面快照在主线程交付");

    // Frequent polling must coalesce, not create parallel readers or starve all publications.
    dispatch_semaphore_t firstRelease=dispatch_semaphore_create(0);
    __block NSUInteger calls=0, coalescedDeliveries=0;
    __block NSMutableArray *refreshFlags=[NSMutableArray new];
    AxsCacheKeeperAppList *coalesced=[[cls alloc] initWithProvider:^NSDictionary *(BOOL refreshApps) {
        calls++;[refreshFlags addObject:@(refreshApps)];
        if (calls==1) dispatch_semaphore_wait(firstRelease,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC));
        return @{@"call":@(calls)};
    } completion:^(NSDictionary *snapshot) { (void)snapshot;coalescedDeliveries++; }];
    [coalesced requestRefreshApplications:NO];
    for (NSUInteger i=0;i<30;i++) [coalesced requestRefreshApplications:i==4];
    dispatch_semaphore_signal(firstRelease);
    alwait(^BOOL {return coalescedDeliveries==2;},@"重复轮询合并，但在途结果仍须发布");
    alcheck(calls==2 && [refreshFlags isEqual:@[@NO,@YES]],@"仅一个在途和一个合并请求，保留应用重读需求");

    // Leaving the page or saving a switch invalidates results that were read before that event.
    dispatch_semaphore_t obsoleteRelease=dispatch_semaphore_create(0);
    __block NSUInteger obsoleteCalls=0;
    __block BOOL obsoleteStarted=NO;
    __block NSMutableArray *versions=[NSMutableArray new];
    AxsCacheKeeperAppList *generation=[[cls alloc] initWithProvider:^NSDictionary *(BOOL refreshApps) {
        (void)refreshApps;NSUInteger version=++obsoleteCalls;
        if (version==1) {
            dispatch_async(dispatch_get_main_queue(),^{ obsoleteStarted=YES; });
            dispatch_semaphore_wait(obsoleteRelease,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC));
        }
        return @{@"version":@(version)};
    } completion:^(NSDictionary *snapshot) { [versions addObject:snapshot[@"version"]]; }];
    [generation requestRefreshApplications:YES];
    alwait(^BOOL {return obsoleteStarted;},@"确认旧读取已在途再模拟离页或保存");
    [generation invalidate];
    [generation requestRefreshApplications:YES];
    dispatch_semaphore_signal(obsoleteRelease);
    alwait(^BOOL {return versions.count==1;},@"离页返回后新的来源请求可完成");
    alcheck([versions isEqual:@[@2]],@"旧代际不得覆盖返回后或写配置后的状态");

    NSString *folder=[fixture stringByAppendingPathComponent:@"app-list"];
    alcheck([NSFileManager.defaultManager createDirectoryAtPath:[folder stringByAppendingPathComponent:@"Status"] withIntermediateDirectories:YES attributes:nil error:nil],@"创建列表快照目录");
    alwrite(folder,@"appEnabled.plist",states);
    alwrite(folder,@"directories.plist",@{@"test.baidu":@[@"Library/Caches"]});
    alwrite(folder,@"favorites.plist",@[@"test.swiftgram"]);
    alwrite(folder,@"snapshots.plist",@{@"test.baidu":@{@"bytes":@10}});
    alwrite(folder,@"batch.plist",@{@"remaining":@[],@"total":@2,@"completed":@2});
    alwrite(folder,@"Status/test.baidu.auto.plist",@{@"removed":@7});
    __block NSUInteger appReads=0, snapshots=0;
    __block BOOL failApps=NO;
    __block NSDictionary *latest=nil;
    AxsCacheKeeperAppList *source=[[cls alloc] initWithFolder:folder applicationsProvider:^NSArray *(NSError **error) {
        alcheck(!NSThread.isMainThread,@"真实文件来源与系统应用读取必须在后台");appReads++;
        if (failApps) { if (error) *error=[NSError errorWithDomain:@"fixture" code:1 userInfo:nil];return nil; }
        return apps;
    } completion:^(NSDictionary *snapshot) { latest=snapshot;snapshots++; }];
    [source requestRefreshApplications:YES];
    alwait(^BOOL {return snapshots==1;},@"载入完整列表来源");
    alcheck([latest[@"states"] isEqual:states] && [latest[@"statuses"][@"test.baidu"][@"removed"] isEqual:@7],@"配置和启用项回执一起进入内存快照");
    alcheck([latest[@"apps"] isEqual:apps] && ![latest[@"errors"] count],@"有效来源保留应用列表且无错误");
    for (NSUInteger i=0;i<30;i++) [cls sectionsForApps:latest[@"apps"] states:latest[@"states"] favorites:favorites tab:i%4 query:@"b"];
    alcheck(appReads==1,@"输入与分类切换不发起来源调用");
    alwrite(folder,@"Status/test.baidu.auto.plist",@{@"removed":@11});
    [source requestRefreshApplications:NO];
    alwait(^BOOL {return snapshots==2;},@"仅回执变化仍刷新");
    alcheck(appReads==1 && [latest[@"statuses"][@"test.baidu"][@"removed"] isEqual:@11],@"常规轮询不重枚举安装应用，也不漏掉回执变化");
    alcheck([@"broken plist" writeToFile:[folder stringByAppendingPathComponent:@"appEnabled.plist"] atomically:YES encoding:NSUTF8StringEncoding error:nil],@"破坏来源夹具");
    failApps=YES;
    [source requestRefreshApplications:YES];
    alwait(^BOOL {return snapshots==3;},@"来源失败仍完成并报告");
    alcheck([latest[@"states"] isEqual:states] && [latest[@"apps"] isEqual:apps],@"读取失败不以空配置覆盖最后有效快照");
    alcheck(latest[@"errors"][@"appEnabled.plist"] && latest[@"errors"][@"applications"],@"配置和系统应用失败必须显式记录");
    failApps=NO;alwrite(folder,@"appEnabled.plist",@{});
    [source requestRefreshApplications:YES];
    alwait(^BOOL {return snapshots==4;},@"失败后可恢复刷新");
    alcheck(![latest[@"states"] count] && ![latest[@"statuses"] count] && ![latest[@"errors"] count],@"有效空配置替换旧值，清除过期回执与错误");
    [slow invalidate];[coalesced invalidate];[generation invalidate];[source invalidate];
}
