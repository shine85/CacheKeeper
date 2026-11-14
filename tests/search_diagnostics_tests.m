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
static id axs_cachekeeper_search_mutable(id value) {
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *out=[NSMutableDictionary new];
        for (id key in value) out[key]=axs_cachekeeper_search_mutable(value[key]);
        return out;
    }
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *out=[NSMutableArray new];
        for (id item in value) [out addObject:axs_cachekeeper_search_mutable(item)];
        return out;
    }
    return [value copy];
}
static NSMutableDictionary *axs_cachekeeper_search_route_fixture(void) {
    NSMutableDictionary *fixture=axs_cachekeeper_search_fixture();
    NSMutableDictionary *event=[fixture[@"events"][0] mutableCopy];
    NSDictionary *node=event[@"field"];
    event[@"event"]=@"sampled";
    event[@"hitRoute"]=@{@"rootCenterHit":@"field",
        @"windowHit":@{@"role":@"navigationContainer",@"kind":@"view",@"view":node},
        @"hitAncestors":@[@{@"role":@"navigationContainer",@"kind":@"view",@"view":node},
            @{@"role":@"window",@"kind":@"window",@"view":node}],
        @"hitAncestorsTruncated":@NO,@"navigationBar":node,
        @"windowHitInsideRoot":@NO,@"windowHitInsideNavigationBar":@NO,@"sameHit":@NO};
    fixture[@"probeRevision"]=@2;fixture[@"events"]=@[event];
    return axs_cachekeeper_search_mutable(fixture);
}
static void axs_cachekeeper_search_add_private(id value) {
    if ([value isKindOfClass:NSMutableDictionary.class]) {
        for (id key in [value allKeys]) axs_cachekeeper_search_add_private(value[key]);
        value[@"private"]=@"private-sentinel";
    } else if ([value isKindOfClass:NSArray.class]) {
        for (id item in value) axs_cachekeeper_search_add_private(item);
    }
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
    // Revision 1-only production rejects this complete route; this is the new behavior's red baseline.
    NSMutableDictionary *routeFixture=axs_cachekeeper_search_route_fixture();
    NSDictionary *routeResult=project(routeFixture);
    axs_cachekeeper_search_check([routeResult isEqual:routeFixture],@"revision 2 命中链必须完整进入同一份诊断 JSON");
    axs_cachekeeper_search_add_private(routeFixture);
    axs_cachekeeper_search_check([project(routeFixture) isEqual:routeResult],@"命中描述符及导航栏每层未知字段均被移除");
    routeFixture[@"events"][0][@"hitRoute"][@"windowHit"][@"view"][@"bounds"][@"x"]=@42;
    [routeFixture[@"events"][0][@"hitRoute"][@"hitAncestors"] removeLastObject];
    axs_cachekeeper_search_check([routeResult isEqual:axs_cachekeeper_search_route_fixture()],@"命中链导出与可变来源完全隔离");
    for (id revision in @[@0,@3,@1.5,@YES,@"2"]) {
        NSMutableDictionary *bad=axs_cachekeeper_search_route_fixture();bad[@"probeRevision"]=revision;
        axs_cachekeeper_search_check([project(bad)[@"state"] isEqual:@"invalid"],@"未知及错误类型 revision 应拒绝");
    }
    NSMutableDictionary *legacySample=axs_cachekeeper_search_route_fixture();legacySample[@"probeRevision"]=@1;
    axs_cachekeeper_search_check([project(legacySample)[@"state"] isEqual:@"invalid"],@"revision 1 不扩展 sampled 事件枚举");
    NSMutableDictionary *missingRoute=axs_cachekeeper_search_route_fixture();
    [missingRoute[@"events"][0] removeObjectForKey:@"hitRoute"];
    axs_cachekeeper_search_check([project(missingRoute)[@"state"] isEqual:@"invalid"],@"revision 2 必须包含命中链");
    for (NSString *key in [axs_cachekeeper_search_route_fixture()[@"events"][0][@"hitRoute"] allKeys]) {
        NSMutableDictionary *bad=axs_cachekeeper_search_route_fixture();
        [bad[@"events"][0][@"hitRoute"] removeObjectForKey:key];
        axs_cachekeeper_search_check([project(bad)[@"state"] isEqual:@"invalid"],@"命中链不可缺少任一字段");
    }
    NSDictionary *badRouteValues=@{@"rootCenterHit":@[@"root",@"navigationContainer",@1],
        @"windowHit":@[NSNull.null,@[]],@"navigationBar":@[NSNull.null,@{}],@"hitAncestors":@[NSNull.null,@{}],
        @"hitAncestorsTruncated":@[@0,@1,@"false"],@"windowHitInsideRoot":@[@0,@1],
        @"windowHitInsideNavigationBar":@[@0,@1],@"sameHit":@[@0,@1]};
    for (NSString *key in badRouteValues) for (id value in badRouteValues[key]) {
        NSMutableDictionary *bad=axs_cachekeeper_search_route_fixture();bad[@"events"][0][@"hitRoute"][key]=value;
        axs_cachekeeper_search_check([project(bad)[@"state"] isEqual:@"invalid"],@"命中链布尔、枚举和形状须严格拒收");
    }
    for (NSNumber *ancestorCase in @[@NO,@YES]) {
        for (NSString *key in @[@"role",@"kind",@"view"]) {
            NSMutableDictionary *bad=axs_cachekeeper_search_route_fixture();
            NSMutableDictionary *route=bad[@"events"][0][@"hitRoute"];
            NSMutableDictionary *descriptor=ancestorCase.boolValue ? route[@"hitAncestors"][0] : route[@"windowHit"];
            [descriptor removeObjectForKey:key];
            axs_cachekeeper_search_check([project(bad)[@"state"] isEqual:@"invalid"],@"每个命中描述符都须有 role/kind/view");
        }
        NSDictionary *badDescriptor=@{@"role":@[@"private-sentinel",@1],@"kind":@[@"UIView",@"private-sentinel",@1],@"view":@[@{},NSNull.null]};
        for (NSString *key in badDescriptor) for (id value in badDescriptor[key]) {
            NSMutableDictionary *bad=axs_cachekeeper_search_route_fixture();NSMutableDictionary *route=bad[@"events"][0][@"hitRoute"];
            NSMutableDictionary *descriptor=ancestorCase.boolValue ? route[@"hitAncestors"][0] : route[@"windowHit"];
            descriptor[key]=value;
            axs_cachekeeper_search_check([project(bad)[@"state"] isEqual:@"invalid"],@"命中对象和祖先均不能暴露任意类名或坏视图");
        }
    }
    for (NSString *key in @[@"windowHit",@"hitAncestors",@"navigationBar"]) {
        for (id number in @[@YES,@(NAN),@(INFINITY),@1000001,@(-1000001)]) {
            NSMutableDictionary *bad=axs_cachekeeper_search_route_fixture();NSMutableDictionary *route=bad[@"events"][0][@"hitRoute"];
            NSMutableDictionary *view=[key isEqual:@"navigationBar"] ? route[key] : [key isEqual:@"windowHit"] ? route[key][@"view"] : route[key][0][@"view"];
            view[@"windowRect"][@"x"]=number;
            axs_cachekeeper_search_check([project(bad)[@"state"] isEqual:@"invalid"],@"命中链每层矩形遵守相同有限数值边界");
        }
    }
    NSMutableDictionary *deepRoute=axs_cachekeeper_search_route_fixture();
    NSMutableArray *hitAncestors=deepRoute[@"events"][0][@"hitRoute"][@"hitAncestors"];
    while (hitAncestors.count<6) [hitAncestors addObject:hitAncestors[0]];
    axs_cachekeeper_search_check([project(deepRoute)[@"state"] isEqual:@"frozen"],@"六层命中祖先可导出");
    [hitAncestors addObject:hitAncestors[0]];
    axs_cachekeeper_search_check([project(deepRoute)[@"state"] isEqual:@"invalid"],@"七层命中祖先应拒绝");
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
    NSData *json=[NSJSONSerialization dataWithJSONObject:@[result,routeResult] options:0 error:nil];
    axs_cachekeeper_search_check(json && ![[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] containsString:@"private-sentinel"],@"同一报告序列化不含私有输入");
    axs_cachekeeper_search_check(![NSFileManager.defaultManager fileExistsAtPath:folder],@"取证导出投影不自动落盘");
    puts("PASS: bounded search diagnostics export");
}
