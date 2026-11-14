#import <Foundation/Foundation.h>
#import "../AxsCacheKeeperDiagnostics.h"
#include <math.h>

static void axs_cachekeeper_search_check(BOOL condition,NSString *message) {
    if (!condition) {fprintf(stderr,"FAIL: search diagnostics: %s\n",message.UTF8String);exit(1);}
}
static NSMutableDictionary *axs_cachekeeper_search_fixture(void) {
    NSDictionary *rect=@{@"valid":@YES,@"x":@0,@"y":@0,@"width":@100,@"height":@44};
    NSDictionary *node=@{@"bounds":rect,@"windowRect":rect,@"hidden":@NO,@"alpha":@1,
        @"interaction":@YES,@"clips":@NO,@"centerInsideBounds":@YES};
    NSDictionary *event=@{@"event":@"rootHit",@"elapsedMs":@12,@"observedHit":@"field",@"centerHit":@"field",
        @"firstResponder":@NO,@"fieldEnabled":@YES,@"fieldCanBecomeFirstResponder":@YES,@"presented":@NO,@"windowAttached":@YES,@"windowKey":@YES,
        @"windowHidden":@NO,@"windowInteraction":@YES,@"windowAlpha":@1,@"scene":@"foregroundActive",
        @"field":node,@"input":node,@"root":node,@"table":node,
        @"ancestors":@[@{@"role":@"search",@"view":node}],@"ancestorsTruncated":@NO};
    return [@{@"schemaVersion":@1,@"probeRevision":@1,@"state":@"frozen",@"truncated":@NO,@"events":@[event]} mutableCopy];
}
void axs_cachekeeper_run_search_diagnostics_tests(void) {
    NSString *folder=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    AxsCacheKeeperDiagnostics *session=[[AxsCacheKeeperDiagnostics alloc] initWithFolder:folder];
    NSMutableDictionary *fixture=axs_cachekeeper_search_fixture();
    NSDictionary *(^project)(id)=^NSDictionary *(id value) {
        return [session reportWithApps:@[] environment:value ? @{@"searchUI":value} : @{}][@"searchUI"];
    };
    // Missing export wiring or a top-level-only copy breaks these real report assertions.
    NSDictionary *result=project(fixture);
    axs_cachekeeper_search_check([result isEqual:fixture],@"冻结的搜索快照必须进入同一份诊断 JSON");
    axs_cachekeeper_search_check([project(nil) isEqual:@{@"state":@"notObserved"}],@"旧入口未提供快照不能冒充已观察");
    NSMutableDictionary *event=[fixture[@"events"][0] mutableCopy];
    NSMutableDictionary *node=[event[@"field"] mutableCopy];
    NSMutableDictionary *rect=[node[@"bounds"] mutableCopy];
    rect[@"private"]=@"private-sentinel";node[@"bounds"]=rect;node[@"private"]=@"private-sentinel";
    event[@"field"]=node;event[@"private"]=@"private-sentinel";
    fixture[@"events"]=@[event];fixture[@"private"]=@"private-sentinel";
    result=project(fixture);
    axs_cachekeeper_search_check([result isEqual:axs_cachekeeper_search_fixture()],@"每层未知字段均被白名单投影移除");
    rect[@"x"]=@42;node[@"alpha"]=@0;
    axs_cachekeeper_search_check([result[@"events"][0][@"field"][@"bounds"][@"x"] isEqual:@0],@"导出不能保留嵌套可变来源引用");
    for (id bad in @[NSNull.null,@[],@"private-sentinel",@42])
        axs_cachekeeper_search_check([project(bad)[@"state"] isEqual:@"invalid"],@"坏快照形状应拒绝");
    for (NSString *key in @[@"schemaVersion",@"probeRevision",@"state",@"truncated",@"events"]) {
        NSMutableDictionary *bad=axs_cachekeeper_search_fixture();[bad removeObjectForKey:key];
        axs_cachekeeper_search_check([project(bad)[@"state"] isEqual:@"invalid"],@"缺少必需顶层字段应拒绝");
    }
    NSDictionary *badEvents=@{@"elapsedMs":@[@YES,@(-1),@3600001,@(NAN),@(INFINITY),@0.5],
        @"centerHit":@[@"private-sentinel",@1],@"observedHit":@[@"private-sentinel"],
        @"event":@[@"private-sentinel"],@"firstResponder":@[@1,@"true"],
        @"windowAlpha":@[@YES,@(-0.1),@1.1,@(NAN)],@"scene":@[@"private-sentinel"]};
    for (NSString *key in badEvents) for (id value in badEvents[key]) {
        NSMutableDictionary *bad=axs_cachekeeper_search_fixture();NSMutableDictionary *item=[bad[@"events"][0] mutableCopy];
        item[key]=value;bad[@"events"]=@[item];
        axs_cachekeeper_search_check([project(bad)[@"state"] isEqual:@"invalid"],@"坏事件枚举、布尔或无界数值应拒绝");
    }
    for (NSString *key in [axs_cachekeeper_search_fixture()[@"events"][0] allKeys]) {
        NSMutableDictionary *bad=axs_cachekeeper_search_fixture();NSMutableDictionary *item=[bad[@"events"][0] mutableCopy];
        [item removeObjectForKey:key];bad[@"events"]=@[item];
        axs_cachekeeper_search_check([project(bad)[@"state"] isEqual:@"invalid"],@"缺少必需事件字段应拒绝");
    }
    for (id value in @[@YES,@(NAN),@(INFINITY),@1000001,@(-1000001),@"private-sentinel"]) {
        NSMutableDictionary *bad=axs_cachekeeper_search_fixture();NSMutableDictionary *item=[bad[@"events"][0] mutableCopy];
        NSMutableDictionary *view=[item[@"field"] mutableCopy];NSMutableDictionary *bounds=[view[@"bounds"] mutableCopy];
        bounds[@"x"]=value;view[@"bounds"]=bounds;item[@"field"]=view;bad[@"events"]=@[item];
        axs_cachekeeper_search_check([project(bad)[@"state"] isEqual:@"invalid"],@"嵌套矩形必须校验有限数值");
    }
    for (NSNumber *ancestorCase in @[@NO,@YES]) {
        BOOL ancestors=ancestorCase.boolValue;
        NSMutableDictionary *bad=axs_cachekeeper_search_fixture();NSMutableDictionary *item=[bad[@"events"][0] mutableCopy];
        NSMutableArray *many=[NSMutableArray new];NSUInteger count=ancestors ? 7 : 17;
        for (NSUInteger i=0;i<count;i++) [many addObject:ancestors ? item[@"ancestors"][0] : item];
        if (ancestors) {item[@"ancestors"]=many;bad[@"events"]=@[item];} else bad[@"events"]=many;
        axs_cachekeeper_search_check([project(bad)[@"state"] isEqual:@"invalid"],@"事件与祖先超过硬上限应拒绝");
    }
    for (id ancestor in @[NSNull.null,@{@"role":@"private-sentinel",@"view":node},@{@"role":@"other",@"view":@{}}]) {
        NSMutableDictionary *bad=axs_cachekeeper_search_fixture();NSMutableDictionary *item=[bad[@"events"][0] mutableCopy];
        item[@"ancestors"]=@[ancestor];bad[@"events"]=@[item];
        axs_cachekeeper_search_check([project(bad)[@"state"] isEqual:@"invalid"],@"祖先形状、枚举及深层视图同样拒绝坏输入");
    }
    NSData *json=[NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    axs_cachekeeper_search_check(json && ![[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] containsString:@"private-sentinel"],@"同一报告序列化不含私有输入");
    axs_cachekeeper_search_check(![NSFileManager.defaultManager fileExistsAtPath:folder],@"取证导出投影不自动落盘");
    puts("PASS: bounded search diagnostics export");
}
