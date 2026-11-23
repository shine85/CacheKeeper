#import "AxsCacheKeeperOperationInfo.h"
#import "AxsCacheKeeperImageCacheStatus.h"
#import "AxsCacheKeeperWebKitStatus.h"
#import "AxsCacheKeeperImageEffectStatus.h"
#import <dispatch/dispatch.h>
#include <math.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <errno.h>

NSDictionary *axs_cachekeeper_operation_process(void) {
    static NSDictionary *process;static dispatch_once_t once;
    dispatch_once(&once,^{process=@{@"processID":NSUUID.UUID.UUIDString,@"firstObserved":@(NSDate.date.timeIntervalSince1970)};});
    return process;
}
static BOOL AxsCacheKeeperOperationKeys(NSDictionary *value,NSArray *keys) {
    return [value isKindOfClass:NSDictionary.class] && value.count==keys.count && [[NSSet setWithArray:value.allKeys] isEqual:[NSSet setWithArray:keys]];
}
static BOOL AxsCacheKeeperOperationBoolean(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID();
}
static BOOL AxsCacheKeeperOperationNumber(id value,BOOL integral) {
    if (![value isKindOfClass:NSNumber.class] || AxsCacheKeeperOperationBoolean(value)) return NO;
    double n=[value doubleValue];return isfinite(n) && n>=0 && n<=9007199254740991.0 && (!integral || floor(n)==n);
}
static BOOL AxsCacheKeeperOperationTerminal(NSString *state) {return [@[@"apiCompleted",@"skipped",@"failed",@"unknown"] containsObject:state];}
static BOOL AxsCacheKeeperOperationReason(id reason) {
    return [@[@"none",@"appDisabled",@"configurationInvalid",@"installationUnverified",@"installationChanged",@"unsupportedSDK",
        @"unsupportedInstance",@"observationLimit",@"scopeNotAuthorized",@"scopeUnverified",@"pathChanged",@"overlappingOwners",@"ownerChanged",
        @"authorizationChanged",@"foregroundAgain",@"noBackgroundTime",@"deadlineExceeded",@"inFlight",@"reportWriteFailed",
        @"notAuthorized",@"configurationUnreadable",@"exclusionUnrepresentable",@"processUnverified",@"storeUnavailable",@"unsupported",
        @"interruptedUnknown",@"superseded"] containsObject:reason];
}
static id AxsCacheKeeperOperationCopy(id value,BOOL mutable) {
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    return data ? [NSPropertyListSerialization propertyListWithData:data options:mutable ? NSPropertyListMutableContainersAndLeaves : NSPropertyListImmutable format:NULL error:nil] : nil;
}
NSDictionary *axs_cachekeeper_operation_history_validate(id value,NSString *component) {
    if (!AxsCacheKeeperOperationKeys(value,@[@"schemaVersion",@"component",@"historyTruncated",@"historyRejected",@"processes"]) ||
        !AxsCacheKeeperOperationNumber(value[@"schemaVersion"],YES) || [value[@"schemaVersion"] integerValue]!=1 ||
        ![@[@"image",@"webkit"] containsObject:value[@"component"]] || (component && ![component isEqual:value[@"component"]]) ||
        !AxsCacheKeeperOperationBoolean(value[@"historyTruncated"]) || !AxsCacheKeeperOperationBoolean(value[@"historyRejected"]) ||
        ![value[@"processes"] isKindOfClass:NSArray.class] || ![value[@"processes"] count] || [value[@"processes"] count]>2) return nil;
    NSMutableSet *processIDs=[NSMutableSet new];NSUInteger terminalEvents=0,terminalActions=0,activeEvents=0,activeActions=0;
    NSArray *processes=value[@"processes"];
    for (NSDictionary *process in processes) {
        if (!AxsCacheKeeperOperationKeys(process,@[@"processID",@"firstObserved",@"events",@"actions"]) ||
            ![process[@"processID"] isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:process[@"processID"]] ||
            [processIDs containsObject:process[@"processID"]] || !AxsCacheKeeperOperationNumber(process[@"firstObserved"],NO) ||
            ![process[@"events"] isKindOfClass:NSArray.class] || ![process[@"actions"] isKindOfClass:NSArray.class] ||
            [process[@"events"] count]>4096 || [process[@"actions"] count]>4096) return nil;
        [processIDs addObject:process[@"processID"]];
        NSMutableDictionary *events=[NSMutableDictionary new];NSMutableSet *actions=[NSMutableSet new];NSUInteger previousEvent=0,previousAction=0;
        for (NSDictionary *event in process[@"events"]) {
            if (!AxsCacheKeeperOperationKeys(event,@[@"eventID",@"configurationGeneration",@"installationGeneration",@"trigger",@"refresh",@"state",@"reason",@"started",@"updated"]) || !AxsCacheKeeperOperationReason(event[@"reason"])) return nil;
            for (NSString *key in @[@"eventID",@"configurationGeneration",@"installationGeneration"]) if (!AxsCacheKeeperOperationNumber(event[key],YES)) return nil;
            NSUInteger number=[event[@"eventID"] unsignedIntegerValue];
            if (!number || number<=previousEvent || ![@[@"configuration",@"foreground",@"background",@"imageLoad"] containsObject:event[@"trigger"]] ||
                ![@[@"notRequested",@"requested",@"applied",@"obsolete"] containsObject:event[@"refresh"]] || ![@[@"active",@"finished",@"unknown"] containsObject:event[@"state"]] ||
                !AxsCacheKeeperOperationNumber(event[@"started"],NO) || !AxsCacheKeeperOperationNumber(event[@"updated"],NO) ||
                [event[@"updated"] doubleValue]<[event[@"started"] doubleValue] || [event[@"started"] doubleValue]<[process[@"firstObserved"] doubleValue]) return nil;
            BOOL active=[event[@"state"] isEqual:@"active"];
            if ([event[@"refresh"] isEqual:@"requested"] && !active) return nil;
            if (process!=processes.lastObject && active) return nil;
            if (active) activeEvents++;else terminalEvents++;
            events[event[@"eventID"]]=event;previousEvent=number;
        }
        for (NSDictionary *action in process[@"actions"]) {
            if (![action isKindOfClass:NSDictionary.class]) return nil;
            NSArray *actionKeys=@[@"actionID",@"eventID",@"ownerID",@"state",@"reason",@"timedOut",@"started",@"updated",@"bytesState"];
            if (action[@"cacheEffect"]) {
                if (![value[@"component"] isEqual:@"image"] || ![action[@"state"] isEqual:@"apiCompleted"] ||
                    !axs_cachekeeper_image_effect_projection(action[@"cacheEffect"])) return nil;
                actionKeys=[actionKeys arrayByAddingObject:@"cacheEffect"];
            }
            if (!AxsCacheKeeperOperationKeys(action,actionKeys) || !AxsCacheKeeperOperationReason(action[@"reason"])) return nil;
            for (NSString *key in @[@"actionID",@"eventID",@"ownerID"]) if (!AxsCacheKeeperOperationNumber(action[key],YES) || ![action[key] unsignedIntegerValue]) return nil;
            NSDictionary *event=events[action[@"eventID"]];NSUInteger number=[action[@"actionID"] unsignedIntegerValue];
            if (!event || number<=previousAction || [actions containsObject:action[@"actionID"]] ||
                ![@[@"queued",@"submitted",@"apiCompleted",@"skipped",@"failed",@"unknown"] containsObject:action[@"state"]] ||
                !AxsCacheKeeperOperationBoolean(action[@"timedOut"]) || ![action[@"bytesState"] isEqual:@"notMeasured"] ||
                !AxsCacheKeeperOperationNumber(action[@"started"],NO) || !AxsCacheKeeperOperationNumber(action[@"updated"],NO) ||
                [action[@"updated"] doubleValue]<[action[@"started"] doubleValue] || [action[@"started"] doubleValue]<[event[@"started"] doubleValue] ||
                [action[@"updated"] doubleValue]>[event[@"updated"] doubleValue]) return nil;
            BOOL terminal=AxsCacheKeeperOperationTerminal(action[@"state"]);
            if (!terminal && (![event[@"state"] isEqual:@"active"] || process!=processes.lastObject)) return nil;
            if ([action[@"state"] isEqual:@"unknown"] && ![event[@"state"] isEqual:@"unknown"]) return nil;
            if ([action[@"state"] isEqual:@"unknown"] && ![action[@"reason"] isEqual:@"interruptedUnknown"]) return nil;
            if ([action[@"state"] isEqual:@"apiCompleted"] && ![action[@"reason"] isEqual:@"none"]) return nil;
            if ([event[@"state"] isEqual:@"unknown"] && !terminal) return nil;
            if (terminal) terminalActions++;else activeActions++;
            [actions addObject:action[@"actionID"]];previousAction=number;
        }
    }
    // Active actions belong to the existing engine queue/flight. Do not fabricate a new queue limit.
    if (terminalEvents>32 || terminalActions>64 || activeEvents>activeActions+1) return nil;
    return AxsCacheKeeperOperationCopy(value,NO);
}
NSDictionary *axs_cachekeeper_operation_history_projection(id value,NSMutableDictionary *aliases) {
    NSDictionary *valid=axs_cachekeeper_operation_history_validate(value,nil);if (!valid || !aliases) return nil;
    NSMutableDictionary *result=AxsCacheKeeperOperationCopy(valid,YES);
    for (NSMutableDictionary *process in result[@"processes"]) {
        NSString *identity=process[@"processID"];NSNumber *alias=aliases[identity];
        if (!alias) {alias=@(aliases.count+1);aliases[identity]=alias;}
        [process removeObjectForKey:@"processID"];process[@"processAlias"]=alias;
    }
    return AxsCacheKeeperOperationCopy(result,NO);
}
NSString *axs_cachekeeper_operation_history_summary(id value) {
    if (!value) return @"旧版回执未记录操作历史";
    NSDictionary *valid=axs_cachekeeper_operation_history_validate(value,nil);if (!valid) return @"操作历史字段无效";
    NSUInteger completed=0,pending=0,unknown=0;NSDictionary *latestEffect=nil;double latestTime=-1;
    for (NSDictionary *process in valid[@"processes"]) for (NSDictionary *action in process[@"actions"]) {
        if ([action[@"state"] isEqual:@"apiCompleted"]) completed++;
        else if ([action[@"state"] isEqual:@"unknown"]) unknown++;
        else if (!AxsCacheKeeperOperationTerminal(action[@"state"])) pending++;
        if ([action[@"state"] isEqual:@"apiCompleted"] && [action[@"updated"] doubleValue]>=latestTime) {latestEffect=action[@"cacheEffect"];latestTime=[action[@"updated"] doubleValue];}
    }
    NSString *summary=[NSString stringWithFormat:@"保留 %lu 个进程实例：API 完成 %lu，未确认 %lu，结果未知 %lu；释放空间未测量%@%@；保存记录不确认进程当前是否运行",
        (unsigned long)[valid[@"processes"] count],(unsigned long)completed,(unsigned long)pending,(unsigned long)unknown,
        [valid[@"historyTruncated"] boolValue] ? @"；较早历史已截断" : @"",[valid[@"historyRejected"] boolValue] ? @"；旧历史校验被拒绝" : @""];
    if (latestEffect) {
        NSDictionary *before=latestEffect[@"before"],*after=latestEffect[@"after"];
        if ([latestEffect[@"result"] isEqual:@"unverified"])
            summary=[summary stringByAppendingFormat:@"\n最近一次已记录的单实例清理：目录结果未能完整核验（前 %@，后 %@），不能认定已清空",axs_cachekeeper_image_sample_message(before[@"state"]),axs_cachekeeper_image_sample_message(after[@"state"])];
        else summary=[summary stringByAppendingFormat:@"\n最近一次已记录的单实例清理：%@；文件 %@→%@，逻辑字节 %@→%@，已分配字节 %@→%@。按目录项计数，非原子采样，不代表独占物理释放",
            [latestEffect[@"result"] isEqual:@"empty"] ? @"后查为空" : @"仍有残留",before[@"files"],after[@"files"],
            before[@"logicalBytes"],after[@"logicalBytes"],before[@"allocatedBytes"],after[@"allocatedBytes"]];
    } else if ([valid[@"component"] isEqual:@"image"] && completed) summary=[summary stringByAppendingString:@"；已有 API 完成记录未附目录结果核验"];
    return summary;
}
static NSMutableDictionary *AxsCacheKeeperOperationCurrent(NSMutableDictionary *history) {return [history[@"raw"][@"processes"] lastObject];}
static NSMutableDictionary *AxsCacheKeeperOperationEvent(NSMutableDictionary *history,NSUInteger identifier) {
    for (NSMutableDictionary *event in AxsCacheKeeperOperationCurrent(history)[@"events"]) if ([event[@"eventID"] unsignedIntegerValue]==identifier) return event;
    return nil;
}
static void AxsCacheKeeperOperationTrim(NSMutableDictionary *history) {
    NSMutableDictionary *raw=history[@"raw"];NSUInteger events=0,actions=0;
    for (NSDictionary *process in raw[@"processes"]) {
        for (NSDictionary *event in process[@"events"]) if (![event[@"state"] isEqual:@"active"]) events++;
        for (NSDictionary *action in process[@"actions"]) if (AxsCacheKeeperOperationTerminal(action[@"state"])) actions++;
    }
    for (NSMutableDictionary *process in raw[@"processes"]) {
        NSMutableArray *list=process[@"actions"];
        for (NSDictionary *action in [list copy]) if (actions>64 && AxsCacheKeeperOperationTerminal(action[@"state"])) {[list removeObject:action];actions--;raw[@"historyTruncated"]=@YES;}
        NSMutableArray *eventList=process[@"events"];
        for (NSDictionary *event in [eventList copy]) if (events>32 && ![event[@"state"] isEqual:@"active"]) {
            [eventList removeObject:event];events--;raw[@"historyTruncated"]=@YES;
            for (NSDictionary *action in [list copy]) if ([action[@"eventID"] isEqual:event[@"eventID"]]) {[list removeObject:action];actions--;}
        }
    }
}
NSMutableDictionary *axs_cachekeeper_operation_history_create(NSString *component,id previous) {
    NSDictionary *valid=previous ? axs_cachekeeper_operation_history_validate(previous,component) : nil;
    // Logical expressions have type int in Objective-C; the persisted schema requires CFBoolean.
    NSMutableDictionary *raw=[@{@"schemaVersion":@1,@"component":component,@"historyTruncated":@NO,@"historyRejected":@((BOOL)(previous && !valid)),@"processes":[NSMutableArray new]} mutableCopy];
    NSDictionary *identity=axs_cachekeeper_operation_process();NSMutableArray *processes=raw[@"processes"];
    if (valid) {
        raw[@"historyTruncated"]=valid[@"historyTruncated"];raw[@"historyRejected"]=valid[@"historyRejected"];
        // Only the last previous instance survives; no history participates in authorization.
        NSMutableDictionary *old=AxsCacheKeeperOperationCopy([valid[@"processes"] lastObject],YES);
        if (![old[@"processID"] isEqual:identity[@"processID"]]) {
            if ([valid[@"processes"] count]>1) raw[@"historyTruncated"]=@YES;
            for (NSMutableDictionary *event in old[@"events"]) if ([event[@"state"] isEqual:@"active"]) {
                event[@"state"]=@"unknown";event[@"reason"]=@"interruptedUnknown";if ([event[@"refresh"] isEqual:@"requested"]) event[@"refresh"]=@"obsolete";
            }
            for (NSMutableDictionary *action in old[@"actions"]) if (!AxsCacheKeeperOperationTerminal(action[@"state"])) {action[@"state"]=@"unknown";action[@"reason"]=@"interruptedUnknown";}
            [processes addObject:old];
        } else [processes addObject:old];
    }
    if (![[processes lastObject][@"processID"] isEqual:identity[@"processID"]]) {
        NSMutableDictionary *current=[identity mutableCopy];current[@"events"]=[NSMutableArray new];current[@"actions"]=[NSMutableArray new];[processes addObject:current];
    }
    NSMutableDictionary *history=[@{@"raw":raw,@"closed":[NSMutableSet new],@"nextEvent":@0,@"nextAction":@0} mutableCopy];
    for (NSDictionary *event in AxsCacheKeeperOperationCurrent(history)[@"events"]) history[@"nextEvent"]=event[@"eventID"];
    for (NSDictionary *action in AxsCacheKeeperOperationCurrent(history)[@"actions"]) history[@"nextAction"]=action[@"actionID"];
    AxsCacheKeeperOperationTrim(history);return history;
}
void axs_cachekeeper_operation_restore(NSMutableDictionary *history,id previous) {
    @synchronized(history) {
        if (!previous) return;
        NSMutableDictionary *restored=axs_cachekeeper_operation_history_create(history[@"raw"][@"component"],previous);
        NSMutableDictionary *raw=history[@"raw"],*loaded=restored[@"raw"];
        raw[@"historyRejected"]=@((BOOL)([raw[@"historyRejected"] boolValue] || [loaded[@"historyRejected"] boolValue]));
        raw[@"historyTruncated"]=@((BOOL)([raw[@"historyTruncated"] boolValue] || [loaded[@"historyTruncated"] boolValue]));
        NSMutableArray *processes=raw[@"processes"];
        if ([loaded[@"processes"] count]==2 && processes.count==1) [processes insertObject:loaded[@"processes"][0] atIndex:0];
        else if ([loaded[@"processes"] count]==1 && [loaded[@"processes"][0][@"events"] count]) {
            // A second copy of the same component cannot safely reassign already-issued IDs.
            raw[@"historyRejected"]=@YES;
        }
        AxsCacheKeeperOperationTrim(history);
    }
}
id axs_cachekeeper_operation_load(NSString *path,NSString *component) {
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_CLOEXEC|O_NOFOLLOW);
    if (fd<0) return errno==ENOENT ? nil : @{};
    struct stat st={0};const off_t limit=256*1024;
    if (fstat(fd,&st) || !S_ISREG(st.st_mode) || st.st_size<=0 || st.st_size>limit) {close(fd);return @{};}
    NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)st.st_size];size_t offset=0;
    while (offset<data.length) {
        ssize_t count=read(fd,(char *)data.mutableBytes+offset,data.length-offset);
        if (count<0 && errno==EINTR) continue;
        if (count<=0) {close(fd);return @{};}offset+=(size_t)count;
    }
    char extra;ssize_t tail;do {tail=read(fd,&extra,1);} while (tail<0 && errno==EINTR);
    close(fd);if (tail!=0) return @{};
    id record=[NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:nil];
    NSDictionary *valid=[component isEqual:@"image"] ? axs_cachekeeper_image_cache_raw_projection(record) : axs_cachekeeper_webkit_raw_projection(record);
    if (!valid) return @{};
    // Legacy receipts remain readable without inventing historical actions.
    return valid[@"operationHistory"];
}
NSDictionary *axs_cachekeeper_operation_snapshot(NSMutableDictionary *history) {
    @synchronized(history) {return AxsCacheKeeperOperationCopy(history[@"raw"],NO);}
}
NSUInteger axs_cachekeeper_operation_begin_with_policy(NSMutableDictionary *history,NSString *trigger,NSUInteger configuration,NSUInteger installation,BOOL refreshing,BOOL supersedeActive) {
    @synchronized(history) {
        // A newer trigger makes an unfinished refresh obsolete; submitted actions remain active.
        for (NSMutableDictionary *event in supersedeActive ? [AxsCacheKeeperOperationCurrent(history)[@"events"] copy] : @[]) {
            if (![event[@"state"] isEqual:@"active"]) continue;
            if ([event[@"refresh"] isEqual:@"requested"]) {event[@"refresh"]=@"obsolete";event[@"reason"]=@"superseded";}
            axs_cachekeeper_operation_finish(history,[event[@"eventID"] unsignedIntegerValue]);
        }
        NSUInteger identifier=[history[@"nextEvent"] unsignedIntegerValue]+1;history[@"nextEvent"]=@(identifier);
        NSNumber *now=@(NSDate.date.timeIntervalSince1970);
        [AxsCacheKeeperOperationCurrent(history)[@"events"] addObject:[@{@"eventID":@(identifier),@"configurationGeneration":@(configuration),@"installationGeneration":@(installation),
            @"trigger":trigger,@"refresh":refreshing ? @"requested" : @"notRequested",@"state":@"active",@"reason":@"none",@"started":now,@"updated":now} mutableCopy]];
        AxsCacheKeeperOperationTrim(history);return identifier;
    }
}
NSUInteger axs_cachekeeper_operation_begin(NSMutableDictionary *history,NSString *trigger,NSUInteger configuration,NSUInteger installation,BOOL refreshing) {
    return axs_cachekeeper_operation_begin_with_policy(history,trigger,configuration,installation,refreshing,YES);
}
void axs_cachekeeper_operation_refresh(NSMutableDictionary *history,NSUInteger identifier,NSString *state) {
    @synchronized(history) {
        NSMutableDictionary *event=AxsCacheKeeperOperationEvent(history,identifier);
        if (![event[@"refresh"] isEqual:@"requested"] || ![@[@"applied",@"obsolete"] containsObject:state]) return;
        event[@"refresh"]=state;if ([state isEqual:@"obsolete"]) event[@"reason"]=@"superseded";
        event[@"updated"]=@(MAX([event[@"updated"] doubleValue],NSDate.date.timeIntervalSince1970));
    }
}
void axs_cachekeeper_operation_request(NSMutableDictionary *history,NSUInteger identifier) {
    @synchronized(history) {
        NSMutableDictionary *event=AxsCacheKeeperOperationEvent(history,identifier);
        if (!event || ![event[@"refresh"] isEqual:@"notRequested"]) return;
        event[@"refresh"]=@"requested";event[@"state"]=@"active";
        [history[@"closed"] removeObject:@(identifier)];
    }
}
NSUInteger axs_cachekeeper_operation_action(NSMutableDictionary *history,NSUInteger identifier,NSUInteger owner) {
    @synchronized(history) {
        NSMutableDictionary *event=AxsCacheKeeperOperationEvent(history,identifier);if (!event || ![event[@"state"] isEqual:@"active"] || !owner) return 0;
        NSUInteger action=[history[@"nextAction"] unsignedIntegerValue]+1;history[@"nextAction"]=@(action);
        NSNumber *now=@(MAX([event[@"updated"] doubleValue],NSDate.date.timeIntervalSince1970));event[@"updated"]=now;
        [AxsCacheKeeperOperationCurrent(history)[@"actions"] addObject:[@{@"actionID":@(action),@"eventID":@(identifier),@"ownerID":@(owner),@"state":@"queued",@"reason":@"none",@"timedOut":@NO,@"started":now,@"updated":now,@"bytesState":@"notMeasured"} mutableCopy]];
        return action;
    }
}
static void AxsCacheKeeperOperationSettle(NSMutableDictionary *history,NSUInteger identifier) {
    NSMutableDictionary *event=AxsCacheKeeperOperationEvent(history,identifier);
    if (![history[@"closed"] containsObject:@(identifier)] || [event[@"refresh"] isEqual:@"requested"]) return;
    for (NSDictionary *action in AxsCacheKeeperOperationCurrent(history)[@"actions"]) if ([action[@"eventID"] unsignedIntegerValue]==identifier && !AxsCacheKeeperOperationTerminal(action[@"state"])) return;
    if (event) event[@"state"]=@"finished";[history[@"closed"] removeObject:@(identifier)];
}
void axs_cachekeeper_operation_transition(NSMutableDictionary *history,NSUInteger identifier,NSString *state,BOOL timedOut) {
    axs_cachekeeper_operation_transition_reason(history,identifier,state,@"none",timedOut);
}
void axs_cachekeeper_operation_transition_reason(NSMutableDictionary *history,NSUInteger identifier,NSString *state,NSString *reason,BOOL timedOut) {
    @synchronized(history) {
        if (!AxsCacheKeeperOperationReason(reason)) return;
        for (NSMutableDictionary *action in AxsCacheKeeperOperationCurrent(history)[@"actions"]) {
            if ([action[@"actionID"] unsignedIntegerValue]!=identifier || AxsCacheKeeperOperationTerminal(action[@"state"])) continue;
            NSString *old=action[@"state"];
            BOOL allowed=([old isEqual:@"queued"] && [@[@"queued",@"submitted",@"skipped",@"failed"] containsObject:state]) ||
                ([old isEqual:@"submitted"] && [@[@"submitted",@"apiCompleted",@"failed"] containsObject:state]);
            if (!allowed) return;
            action[@"state"]=state;action[@"reason"]=reason;action[@"timedOut"]=@((BOOL)([action[@"timedOut"] boolValue] || timedOut));
            NSMutableDictionary *event=AxsCacheKeeperOperationEvent(history,[action[@"eventID"] unsignedIntegerValue]);
            if (![reason isEqual:@"none"] && ![event[@"refresh"] isEqual:@"obsolete"]) event[@"reason"]=reason;
            NSNumber *now=@(MAX([event[@"updated"] doubleValue],NSDate.date.timeIntervalSince1970));action[@"updated"]=now;event[@"updated"]=now;
            AxsCacheKeeperOperationSettle(history,[action[@"eventID"] unsignedIntegerValue]);break;
        }
        AxsCacheKeeperOperationTrim(history);
    }
}
void axs_cachekeeper_operation_image_effect(NSMutableDictionary *history,NSUInteger identifier,NSDictionary *effect) {
    NSDictionary *valid=axs_cachekeeper_image_effect_projection(effect);if (!valid) return;
    @synchronized(history) {
        if (![history[@"raw"][@"component"] isEqual:@"image"]) return;
        for (NSMutableDictionary *action in AxsCacheKeeperOperationCurrent(history)[@"actions"]) {
            if ([action[@"actionID"] unsignedIntegerValue]!=identifier) continue;
            if (![action[@"state"] isEqual:@"submitted"] || action[@"cacheEffect"]) return;
            action[@"cacheEffect"]=valid;
            axs_cachekeeper_operation_transition_reason(history,identifier,@"apiCompleted",@"none",NO);return;
        }
    }
}
void axs_cachekeeper_operation_event_reason(NSMutableDictionary *history,NSUInteger identifier,NSString *reason) {
    @synchronized(history) {
        NSMutableDictionary *event=AxsCacheKeeperOperationEvent(history,identifier);
        if (event && AxsCacheKeeperOperationReason(reason) && ![event[@"state"] isEqual:@"unknown"] && ![event[@"refresh"] isEqual:@"obsolete"]) event[@"reason"]=reason;
    }
}
void axs_cachekeeper_operation_finish(NSMutableDictionary *history,NSUInteger identifier) {
    @synchronized(history) {[history[@"closed"] addObject:@(identifier)];AxsCacheKeeperOperationSettle(history,identifier);AxsCacheKeeperOperationTrim(history);}
}
void axs_cachekeeper_operation_timeout(NSMutableDictionary *history,NSUInteger identifier) {
    @synchronized(history) {
        for (NSDictionary *action in AxsCacheKeeperOperationCurrent(history)[@"actions"])
            if ([action[@"actionID"] unsignedIntegerValue]==identifier && !AxsCacheKeeperOperationTerminal(action[@"state"])) {
                axs_cachekeeper_operation_transition_reason(history,identifier,action[@"state"],@"inFlight",YES);return;
            }
    }
}
BOOL axs_cachekeeper_operation_save(NSDictionary *record,NSString *path,BOOL access,NSMutableDictionary *__strong *pending,BOOL *writable) {
    if (record) *pending=[record mutableCopy];
    if (!*pending) return *writable;
    NSError *error=nil;NSData *data=[NSPropertyListSerialization dataWithPropertyList:*pending format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    *writable=access && data && [data writeToFile:path options:NSDataWritingAtomic error:&error];
    if (*writable) *pending=nil;
    else NSLog(@"[CacheKeeper] 操作回执保存失败，保留累计历史等待重试（code=%ld）",(long)error.code);
    return *writable;
}
