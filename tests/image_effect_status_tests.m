#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import "AxsCacheKeeperImageEffectStatus.h"
#import "AxsCacheKeeperOperationInfo.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static void ck_effect_check(BOOL value,const char *message) {
    if (!value) {fprintf(stderr,"FAIL: image-effect-status: %s\n",message);exit(1);}
}
static id ck_effect_mutable(id value) {
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    id copy=data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainersAndLeaves format:NULL error:nil] : nil;
    ck_effect_check(copy!=nil,"fixture property list copy succeeds");return copy;
}
static NSDictionary *ck_effect_record(BOOL residual) {
    AxsCacheKeeperImageSample before={.state=AxsCacheKeeperImageSampleComplete};
    AxsCacheKeeperImageSample after={.state=AxsCacheKeeperImageSampleComplete};
    ck_effect_check(axs_cachekeeper_image_sample_add(&before,17,4096),"fixture records first actual accounting contribution");
    ck_effect_check(axs_cachekeeper_image_sample_add(&before,31,4096),"fixture records second actual accounting contribution");
    if (residual) ck_effect_check(axs_cachekeeper_image_sample_add(&after,7,512),"fixture records residual contribution");
    return axs_cachekeeper_image_effect_record(before,after);
}
static NSDictionary *ck_effect_action(NSDictionary *raw,NSUInteger identifier) {
    for (NSDictionary *action in [raw[@"processes"] lastObject][@"actions"])
        if ([action[@"actionID"] unsignedIntegerValue]==identifier) return action;
    return nil;
}
static NSDictionary *ck_effect_event(NSDictionary *raw,NSUInteger identifier) {
    for (NSDictionary *event in [raw[@"processes"] lastObject][@"events"])
        if ([event[@"eventID"] unsignedIntegerValue]==identifier) return event;
    return nil;
}
static NSUInteger ck_effect_begin(NSMutableDictionary *history,NSUInteger *event) {
    *event=axs_cachekeeper_operation_begin(history,@"background",1,1,NO);
    NSUInteger action=axs_cachekeeper_operation_action(history,*event,1);
    ck_effect_check(*event && action,"real history allocates event and action");return action;
}
static NSMutableDictionary *ck_effect_history(NSString *component,NSUInteger *event,NSUInteger *action) {
    NSMutableDictionary *history=axs_cachekeeper_operation_history_create(component,nil);
    *action=ck_effect_begin(history,event);
    axs_cachekeeper_operation_transition(history,*action,@"submitted",NO);
    axs_cachekeeper_operation_finish(history,*event);
    ck_effect_check(axs_cachekeeper_operation_history_validate(axs_cachekeeper_operation_snapshot(history),component)!=nil,
        "submitted fixture is a valid real history");return history;
}
static void ck_effect_projection(void) {
    NSDictionary *empty=ck_effect_record(NO),*residual=ck_effect_record(YES);
    ck_effect_check([empty[@"result"] isEqual:@"empty"] && [residual[@"result"] isEqual:@"residual"],"record distinguishes empty from residual");
    ck_effect_check([axs_cachekeeper_image_effect_projection(empty) isEqual:empty] &&
        [axs_cachekeeper_image_effect_projection(residual) isEqual:residual],"valid effect records roundtrip exactly");
    NSMutableDictionary *bad=ck_effect_mutable(residual);bad[@"result"]=@"empty";
    ck_effect_check(!axs_cachekeeper_image_effect_projection(bad),"wrong result cannot claim empty");
    for (NSString *side in @[@"before",@"after"]) for (NSString *key in @[@"files",@"logicalBytes",@"allocatedBytes"]) {
        for (NSNumber *invalid in @[@YES,@NO,@(-1),@0.5,@9007199254740992ULL,@(NAN),@(INFINITY)]) {
            bad=ck_effect_mutable(residual);bad[side][key]=invalid;
            ck_effect_check(!axs_cachekeeper_image_effect_projection(bad),"boolean fractional negative and unsafe counts are rejected");
        }
    }
    bad=ck_effect_mutable(residual);bad[@"path"]=@"/PRIVATE_EFFECT_CANARY";
    ck_effect_check(!axs_cachekeeper_image_effect_projection(bad),"unknown effect path is rejected");
    bad=ck_effect_mutable(residual);bad[@"after"][@"path"]=@"/PRIVATE_EFFECT_CANARY";
    ck_effect_check(!axs_cachekeeper_image_effect_projection(bad),"unknown sample path is rejected");
    bad=ck_effect_mutable(residual);bad[@"after"][@"files"]=@100001;
    ck_effect_check(!axs_cachekeeper_image_effect_projection(bad),"sample file bound is enforced");
    bad=ck_effect_mutable(residual);bad[@"after"][@"files"]=@0;
    ck_effect_check(!axs_cachekeeper_image_effect_projection(bad),"zero files cannot carry nonzero byte counts");
    bad=ck_effect_mutable(residual);bad[@"physicalRelease"]=@"measured";
    ck_effect_check(!axs_cachekeeper_image_effect_projection(bad),"directory entries never claim physical release");
    bad=ck_effect_mutable(residual);bad[@"scope"]=@"wholeContainer";
    ck_effect_check(!axs_cachekeeper_image_effect_projection(bad),"effect scope stays fixed");
    bad=ck_effect_mutable(residual);bad[@"after"][@"state"]=@"futureState";
    ck_effect_check(!axs_cachekeeper_image_effect_projection(bad),"unknown sample states are rejected");
    ck_effect_check(!axs_cachekeeper_image_effect_projection(nil) && !axs_cachekeeper_image_effect_projection((id)@[]),"missing or non-dictionary effects are rejected");
    for (NSString *side in @[@"before",@"after"]) for (id invalid in @[NSNull.null,@[],@7,@"PRIVATE_EFFECT_CANARY"]) {
        bad=ck_effect_mutable(residual);bad[side]=invalid;
        @try {ck_effect_check(!axs_cachekeeper_image_effect_projection(bad),"non-dictionary samples are rejected");}
        @catch (NSException *exception) {(void)exception;ck_effect_check(NO,"non-dictionary sample must reject without throwing");}
    }
    AxsCacheKeeperImageSample zero={.state=AxsCacheKeeperImageSampleComplete};
    NSDictionary *alreadyEmpty=axs_cachekeeper_image_effect_record(zero,zero);
    ck_effect_check([axs_cachekeeper_image_effect_projection(alreadyEmpty)[@"result"] isEqual:@"empty"],"observed zero remains distinct from missing observations");
    AxsCacheKeeperImageSample maximum={.state=AxsCacheKeeperImageSampleComplete,.files=100000,
        .logicalBytes=AXS_CACHEKEEPER_IMAGE_EXACT_MAX,.allocatedBytes=AXS_CACHEKEEPER_IMAGE_EXACT_MAX};
    ck_effect_check(axs_cachekeeper_image_effect_projection(axs_cachekeeper_image_effect_record(maximum,maximum))!=nil,
        "legal exact integer and entry maxima survive projection");
    AxsCacheKeeperImageSample invalidState={.state=(AxsCacheKeeperImageSampleState)999};
    ck_effect_check(!axs_cachekeeper_image_effect_record(invalidState,zero) && !axs_cachekeeper_image_effect_record(zero,invalidState),
        "invalid native sample state returns nil instead of building a malformed dictionary");
}
static void ck_effect_failures(void) {
    for (NSUInteger state=AxsCacheKeeperImageSampleReadError;state<=AxsCacheKeeperImageSamplePathChanged;state++) {
        for (NSUInteger side=0;side<2;side++) {
            AxsCacheKeeperImageSample before={.state=AxsCacheKeeperImageSampleComplete,.files=1,.logicalBytes=3,.allocatedBytes=512};
            AxsCacheKeeperImageSample after={.state=AxsCacheKeeperImageSampleComplete};
            if (side) after.state=(AxsCacheKeeperImageSampleState)state;else before.state=(AxsCacheKeeperImageSampleState)state;
            NSDictionary *effect=axs_cachekeeper_image_effect_record(before,after);
            ck_effect_check([effect[@"result"] isEqual:@"unverified"] && axs_cachekeeper_image_effect_projection(effect)!=nil,
                "every failed pre or post sample remains unverified");
            NSMutableDictionary *bad=ck_effect_mutable(effect);bad[@"result"]=@"empty";
            ck_effect_check(!axs_cachekeeper_image_effect_projection(bad),"failed samples cannot become verified empty");
            NSUInteger event,action;NSMutableDictionary *history=ck_effect_history(@"image",&event,&action);
            axs_cachekeeper_operation_image_effect(history,action,effect);
            NSDictionary *raw=axs_cachekeeper_operation_snapshot(history),*saved=ck_effect_action(raw,action);
            ck_effect_check([saved[@"state"] isEqual:@"apiCompleted"] && [saved[@"cacheEffect"] isEqual:effect] &&
                axs_cachekeeper_operation_history_validate(raw,@"image")!=nil,"API completion retains unverified effect without claiming cleanup success");
        }
    }
}
static void ck_effect_history_behavior(void) {
    NSUInteger event,action;NSMutableDictionary *history=ck_effect_history(@"image",&event,&action);
    axs_cachekeeper_operation_timeout(history,action);
    NSMutableDictionary *effect=ck_effect_mutable(ck_effect_record(YES));NSDictionary *expected=ck_effect_record(YES);
    axs_cachekeeper_operation_image_effect(history,action,effect);
    NSDictionary *raw=axs_cachekeeper_operation_snapshot(history),*saved=ck_effect_action(raw,action);
    ck_effect_check([saved[@"state"] isEqual:@"apiCompleted"] && [saved[@"cacheEffect"] isEqual:expected],
        "submitted image action atomically completes with its effect");
    ck_effect_check([saved[@"eventID"] unsignedIntegerValue]==event && [saved[@"timedOut"] boolValue] &&
        [saved[@"bytesState"] isEqual:@"notMeasured"] && [ck_effect_event(raw,event)[@"state"] isEqual:@"finished"] &&
        axs_cachekeeper_operation_history_validate(raw,@"image")!=nil,"effect preserves action association timeout and event settlement");
    effect[@"after"][@"files"]=@0;effect[@"path"]=@"/PRIVATE_EFFECT_CANARY";
    ck_effect_check([axs_cachekeeper_operation_snapshot(history) isEqual:raw],"caller mutation cannot change stored effect");
    axs_cachekeeper_operation_image_effect(history,action,ck_effect_record(NO));
    axs_cachekeeper_operation_transition(history,action,@"failed",NO);
    ck_effect_check([axs_cachekeeper_operation_snapshot(history) isEqual:raw],"duplicate and contradictory callbacks cannot overwrite terminal effect");
}
static void ck_effect_invalid(void) {
    NSUInteger event,action;NSMutableDictionary *history=ck_effect_history(@"image",&event,&action);
    NSDictionary *before=axs_cachekeeper_operation_snapshot(history);
    NSMutableDictionary *bad=ck_effect_mutable(ck_effect_record(YES));bad[@"result"]=@"empty";
    axs_cachekeeper_operation_image_effect(history,action,bad);
    ck_effect_check([axs_cachekeeper_operation_snapshot(history) isEqual:before],"invalid effect changes neither action nor history");
    bad=ck_effect_mutable(ck_effect_record(NO));bad[@"path"]=@"/PRIVATE_EFFECT_CANARY";
    axs_cachekeeper_operation_image_effect(history,action,bad);
    axs_cachekeeper_operation_image_effect(history,action,nil);
    axs_cachekeeper_operation_image_effect(history,0,ck_effect_record(NO));
    axs_cachekeeper_operation_image_effect(history,action+99,ck_effect_record(NO));
    ck_effect_check([axs_cachekeeper_operation_snapshot(history) isEqual:before],"unknown paths missing input and unknown actions are no-ops");
    NSMutableDictionary *web=ck_effect_history(@"webkit",&event,&action);before=axs_cachekeeper_operation_snapshot(web);
    axs_cachekeeper_operation_image_effect(web,action,ck_effect_record(NO));
    ck_effect_check([axs_cachekeeper_operation_snapshot(web) isEqual:before],"non-image component rejects image effect");
    for (NSString *state in @[@"queued",@"apiCompleted",@"failed",@"skipped"]) {
        history=axs_cachekeeper_operation_history_create(@"image",nil);action=ck_effect_begin(history,&event);
        if ([state isEqual:@"apiCompleted"]) axs_cachekeeper_operation_transition(history,action,@"submitted",NO);
        if (![state isEqual:@"queued"]) axs_cachekeeper_operation_transition(history,action,state,NO);
        before=axs_cachekeeper_operation_snapshot(history);
        axs_cachekeeper_operation_image_effect(history,action,ck_effect_record(NO));
        ck_effect_check([axs_cachekeeper_operation_snapshot(history) isEqual:before],"queued and terminal actions reject new effect");
    }
}
static void ck_effect_late(void) {
    NSUInteger oldEvent,oldAction;NSMutableDictionary *history=ck_effect_history(@"image",&oldEvent,&oldAction);
    NSUInteger newEvent,newAction=ck_effect_begin(history,&newEvent);
    axs_cachekeeper_operation_transition(history,newAction,@"submitted",NO);axs_cachekeeper_operation_finish(history,newEvent);
    NSDictionary *before=axs_cachekeeper_operation_snapshot(history),*newBefore=ck_effect_action(before,newAction),*newEventBefore=ck_effect_event(before,newEvent);
    axs_cachekeeper_operation_image_effect(history,oldAction,ck_effect_record(YES));
    NSDictionary *after=axs_cachekeeper_operation_snapshot(history);
    ck_effect_check([ck_effect_action(after,oldAction)[@"cacheEffect"] isEqual:ck_effect_record(YES)] &&
        [ck_effect_action(after,newAction) isEqual:newBefore] && [ck_effect_event(after,newEvent) isEqual:newEventBefore],
        "late old action effect cannot complete or contaminate new action");
    axs_cachekeeper_operation_image_effect(history,newAction,ck_effect_record(NO));
    after=axs_cachekeeper_operation_snapshot(history);
    ck_effect_check([ck_effect_action(after,oldAction)[@"cacheEffect"][@"result"] isEqual:@"residual"] &&
        [ck_effect_action(after,newAction)[@"cacheEffect"][@"result"] isEqual:@"empty"] &&
        axs_cachekeeper_operation_history_validate(after,@"image")!=nil,"two actions retain independent valid effects");
    NSMutableDictionary *previous=ck_effect_mutable(after);
    previous[@"processes"][0][@"processID"]=@"11111111-2222-4333-8444-555555555555";
    NSMutableDictionary *restored=axs_cachekeeper_operation_history_create(@"image",previous);
    NSUInteger event,action=ck_effect_begin(restored,&event);
    axs_cachekeeper_operation_transition(restored,action,@"submitted",NO);
    NSDictionary *savedPrevious=axs_cachekeeper_operation_snapshot(restored)[@"processes"][0];
    axs_cachekeeper_operation_image_effect(restored,action,ck_effect_record(NO));
    NSDictionary *raw=axs_cachekeeper_operation_snapshot(restored);
    ck_effect_check([raw[@"processes"] count]==2 && [raw[@"processes"][0] isEqual:savedPrevious] &&
        axs_cachekeeper_operation_history_validate(raw,@"image")!=nil,"current process effect never rewrites saved previous process history");
}
static void ck_effect_raw(void) {
    NSUInteger event,action;NSMutableDictionary *history=ck_effect_history(@"image",&event,&action);
    axs_cachekeeper_operation_transition(history,action,@"apiCompleted",NO);
    NSDictionary *legacy=axs_cachekeeper_operation_snapshot(history);
    ck_effect_check(axs_cachekeeper_operation_history_validate(legacy,@"image")!=nil && !ck_effect_action(legacy,action)[@"cacheEffect"],
        "legacy completion remains valid without invented effect");
    axs_cachekeeper_operation_image_effect(history,action,ck_effect_record(NO));
    ck_effect_check([axs_cachekeeper_operation_snapshot(history) isEqual:legacy],"legacy terminal action is not retroactively populated");
    NSMutableDictionary *withEffect=ck_effect_mutable(legacy);withEffect[@"processes"][0][@"actions"][0][@"cacheEffect"]=ck_effect_record(NO);
    ck_effect_check(axs_cachekeeper_operation_history_validate(withEffect,@"image")!=nil,"raw completed image action accepts optional valid effect");
    NSMutableDictionary *bad=ck_effect_mutable(withEffect);bad[@"component"]=@"webkit";
    ck_effect_check(!axs_cachekeeper_operation_history_validate(bad,@"webkit"),"raw non-image history cannot carry cacheEffect");
    for (NSString *state in @[@"queued",@"submitted",@"failed",@"skipped",@"unknown"]) {
        bad=ck_effect_mutable(withEffect);NSMutableDictionary *row=bad[@"processes"][0][@"actions"][0];row[@"state"]=state;
        NSMutableDictionary *e=bad[@"processes"][0][@"events"][0];e[@"state"]=@"active";
        if ([state isEqual:@"unknown"]) {row[@"reason"]=@"interruptedUnknown";e[@"state"]=@"unknown";e[@"reason"]=@"interruptedUnknown";}
        NSMutableDictionary *control=ck_effect_mutable(bad);[control[@"processes"][0][@"actions"][0] removeObjectForKey:@"cacheEffect"];
        ck_effect_check(axs_cachekeeper_operation_history_validate(control,@"image")!=nil,"raw rejection control is valid without cacheEffect");
        ck_effect_check(!axs_cachekeeper_operation_history_validate(bad,@"image"),"raw effect requires apiCompleted action");
    }
    bad=ck_effect_mutable(withEffect);bad[@"processes"][0][@"actions"][0][@"cacheEffect"][@"after"][@"files"]=@YES;
    ck_effect_check(!axs_cachekeeper_operation_history_validate(bad,@"image"),"raw effect cannot bypass strict sample projection");
    for (id invalid in @[NSNull.null,@"PRIVATE_EFFECT_CANARY",@7,@[]]) {
        bad=ck_effect_mutable(withEffect);bad[@"processes"][0][@"actions"]=[NSMutableArray arrayWithObject:invalid];
        @try {ck_effect_check(!axs_cachekeeper_operation_history_validate(bad,@"image"),"non-dictionary action is rejected");}
        @catch (NSException *exception) {(void)exception;ck_effect_check(NO,"non-dictionary action must reject without throwing");}
        bad=ck_effect_mutable(withEffect);bad[@"processes"][0][@"actions"][0][@"cacheEffect"]=invalid;
        ck_effect_check(!axs_cachekeeper_operation_history_validate(bad,@"image"),"non-dictionary cacheEffect is rejected");
    }
}
static void ck_effect_summary(void) {
    NSUInteger event,action;NSMutableDictionary *history=ck_effect_history(@"image",&event,&action);
    axs_cachekeeper_operation_image_effect(history,action,ck_effect_record(YES));
    NSString *text=axs_cachekeeper_operation_history_summary(axs_cachekeeper_operation_snapshot(history));
    ck_effect_check([text containsString:@"仍有残留"] && [text containsString:@"文件 2→1"] &&
        [text containsString:@"单实例"] && [text containsString:@"不代表独占物理释放"],"summary describes one measured instance without physical attribution");
    NSUInteger legacyEvent,legacyAction=ck_effect_begin(history,&legacyEvent);
    axs_cachekeeper_operation_transition(history,legacyAction,@"submitted",NO);
    axs_cachekeeper_operation_transition(history,legacyAction,@"apiCompleted",NO);axs_cachekeeper_operation_finish(history,legacyEvent);
    text=axs_cachekeeper_operation_history_summary(axs_cachekeeper_operation_snapshot(history));
    ck_effect_check([text containsString:@"未附目录结果核验"] && ![text containsString:@"文件 2→1"] && ![text containsString:@"仍有残留"],
        "latest legacy completion never reuses an older measured effect");
    NSUInteger emptyEvent,emptyAction=ck_effect_begin(history,&emptyEvent);
    axs_cachekeeper_operation_transition(history,emptyAction,@"submitted",NO);axs_cachekeeper_operation_finish(history,emptyEvent);
    axs_cachekeeper_operation_image_effect(history,emptyAction,ck_effect_record(NO));
    text=axs_cachekeeper_operation_history_summary(axs_cachekeeper_operation_snapshot(history));
    ck_effect_check([text containsString:@"后查为空"] && [text containsString:@"文件 2→0"] && ![text containsString:@"文件 4→"],
        "summary selects latest effect without adding repeated samples");
    AxsCacheKeeperImageSample pre={.state=AxsCacheKeeperImageSampleComplete},post={.state=AxsCacheKeeperImageSampleReadError};
    NSUInteger failedEvent,failedAction=ck_effect_begin(history,&failedEvent);
    axs_cachekeeper_operation_transition(history,failedAction,@"submitted",NO);axs_cachekeeper_operation_finish(history,failedEvent);
    axs_cachekeeper_operation_image_effect(history,failedAction,axs_cachekeeper_image_effect_record(pre,post));
    text=axs_cachekeeper_operation_history_summary(axs_cachekeeper_operation_snapshot(history));
    ck_effect_check([text containsString:@"不能认定已清空"] && ![text containsString:@"后查为空"],
        "latest unverified observation cannot inherit an older empty result");
    ck_effect_check([axs_cachekeeper_operation_history_summary(nil) containsString:@"旧版回执未记录操作历史"],
        "missing old history never invents an effect");
}
static void ck_effect_json(NSString *output) {
    NSUInteger event,action;NSMutableDictionary *history=ck_effect_history(@"image",&event,&action);
    axs_cachekeeper_operation_image_effect(history,action,ck_effect_record(YES));
    NSDictionary *raw=axs_cachekeeper_operation_snapshot(history);NSMutableDictionary *aliases=[NSMutableDictionary new];
    NSDictionary *projected=axs_cachekeeper_operation_history_projection(raw,aliases);
    ck_effect_check(projected!=nil,"real operation export accepts recorded effect");
    NSError *error=nil;NSData *data=[NSJSONSerialization dataWithJSONObject:projected options:NSJSONWritingSortedKeys error:&error];
    ck_effect_check(data!=nil && error==nil,"real JSON serialization succeeds");
    NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    ck_effect_check(![text containsString:@"processID"] && ![text containsString:axs_cachekeeper_operation_process()[@"processID"]] &&
        ![text containsString:@"PRIVATE_EFFECT_CANARY"] && ![text containsString:@"path"],"JSON excludes internal identities paths and arbitrary names");
    ck_effect_check([data writeToFile:output options:NSDataWritingAtomic error:&error],"JSON artifact is actually written");
    NSDictionary *decoded=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:output] options:0 error:&error];
    NSDictionary *saved=ck_effect_action(decoded,action);
    ck_effect_check([saved[@"cacheEffect"] isEqual:ck_effect_record(YES)] && [saved[@"eventID"] unsignedIntegerValue]==event &&
        [decoded[@"processes"][0][@"processAlias"] unsignedIntegerValue]>0,"written JSON preserves effect and anonymous action association");
    ck_effect_check([axs_cachekeeper_operation_snapshot(history) isEqual:raw],"JSON export does not mutate raw history");
    ck_effect_check(!axs_cachekeeper_operation_history_validate(decoded,nil),"anonymous export cannot reenter raw history");
    NSMutableDictionary *old=ck_effect_mutable(raw);[old[@"processes"][0][@"actions"][0] removeObjectForKey:@"cacheEffect"];
    NSDictionary *oldExport=axs_cachekeeper_operation_history_projection(old,aliases);
    ck_effect_check(oldExport!=nil && !ck_effect_action(oldExport,action)[@"cacheEffect"],"old exported history stays without cacheEffect");
}
static void ck_effect_atomic(void) {
    NSMutableDictionary *history=axs_cachekeeper_operation_history_create(@"image",nil);
    NSUInteger event=axs_cachekeeper_operation_begin(history,@"background",1,1,NO);NSMutableArray *actions=[NSMutableArray new];
    for (NSUInteger i=0;i<24;i++) {
        NSUInteger action=axs_cachekeeper_operation_action(history,event,i+1);[actions addObject:@(action)];
        axs_cachekeeper_operation_transition(history,action,@"submitted",NO);
    }
    axs_cachekeeper_operation_finish(history,event);
    dispatch_apply(actions.count,dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^(size_t i){@autoreleasepool {
        axs_cachekeeper_operation_image_effect(history,[actions[i] unsignedIntegerValue],ck_effect_record(i%2));
        NSDictionary *raw=axs_cachekeeper_operation_snapshot(history);
        ck_effect_check(axs_cachekeeper_operation_history_validate(raw,@"image")!=nil,"concurrent snapshots always obey raw schema");
        for (NSDictionary *row in [raw[@"processes"] lastObject][@"actions"])
            ck_effect_check([row[@"state"] isEqual:@"apiCompleted"] ? row[@"cacheEffect"]!=nil :
                [row[@"state"] isEqual:@"submitted"] && !row[@"cacheEffect"],"snapshots never see half-applied completion");
    }});
    NSDictionary *raw=axs_cachekeeper_operation_snapshot(history);
    ck_effect_check([ck_effect_event(raw,event)[@"state"] isEqual:@"finished"],"concurrent last completion settles event");
    for (NSNumber *identifier in actions) ck_effect_check(ck_effect_action(raw,identifier.unsignedIntegerValue)[@"cacheEffect"]!=nil,
        "every submitted action receives exactly its own effect");
}
int main(int argc,const char **argv) {@autoreleasepool {
    if (argc!=3) {fprintf(stderr,"SETUP-FAIL: expected case and JSON artifact path\n");return 2;}
    NSString *selection=[NSString stringWithUTF8String:argv[1]],*output=[NSString stringWithUTF8String:argv[2]];
    NSArray *names=@[@"projection",@"failures",@"history",@"invalid",@"late",@"raw",@"json",@"atomic",@"summary"];
    if (![selection isEqual:@"all"] && ![names containsObject:selection]) {fprintf(stderr,"SETUP-FAIL: unknown case\n");return 2;}
    if ([selection isEqual:@"all"] || [selection isEqual:@"projection"]) ck_effect_projection();
    if ([selection isEqual:@"all"] || [selection isEqual:@"failures"]) ck_effect_failures();
    if ([selection isEqual:@"all"] || [selection isEqual:@"history"]) ck_effect_history_behavior();
    if ([selection isEqual:@"all"] || [selection isEqual:@"invalid"]) ck_effect_invalid();
    if ([selection isEqual:@"all"] || [selection isEqual:@"late"]) ck_effect_late();
    if ([selection isEqual:@"all"] || [selection isEqual:@"raw"]) ck_effect_raw();
    if ([selection isEqual:@"all"] || [selection isEqual:@"json"]) ck_effect_json(output);
    if ([selection isEqual:@"all"] || [selection isEqual:@"atomic"]) ck_effect_atomic();
    if ([selection isEqual:@"all"] || [selection isEqual:@"summary"]) ck_effect_summary();
    printf("PASS: image-effect-status %s\n",selection.UTF8String);return 0;
}}
