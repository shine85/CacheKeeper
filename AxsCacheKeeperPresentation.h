#pragma once
#import <Foundation/Foundation.h>
#import "AxsCacheKeeperAllocation.h"
#import "AxsCacheKeeperReleaseEvidenceStatus.h"

static inline NSString *axs_cachekeeper_presentation_release_evidence(id value) {
    if (!value) return @"本轮删除证据未记录；物理释放量未测定";
    NSDictionary *evidence=axs_cachekeeper_release_evidence_projection(value,nil);
    if (!evidence) return @"本轮删除证据无效；物理释放量未测定";
    if ([evidence[@"state"] isEqual:@"notRecorded"]) return @"本轮尚无实际删除调用；物理释放量未测定";
    NSString *state=[evidence[@"state"] isEqual:@"recording"] ? @"采集中" : [evidence[@"state"] isEqual:@"cancelled"] ? @"已停止" : @"已结束";
    NSMutableString *text=[NSMutableString stringWithFormat:@"本轮删除证据（%@）：成功 %@ 次，失败 %@ 次；物理释放量未测定",state,evidence[@"succeeded"],evidence[@"failed"]];
    if ([evidence[@"postMissing"] unsignedLongLongValue]) [text appendFormat:@"；%@ 次缺少删除后对象观测",evidence[@"postMissing"]];
    if ([evidence[@"detailsOmitted"] unsignedLongLongValue]) [text appendFormat:@"；%@ 条明细因上限省略",evidence[@"detailsOmitted"]];
    if ([evidence[@"overflow"] boolValue]) [text appendString:@"；观测计数或换算超限"];
    NSUInteger lastLink=0,stillLinked=0,unconfirmed=0;
    for (NSDictionary *detail in evidence[@"details"]) {
        if ([detail[@"result"] intValue]) continue;
        if ([detail[@"identityMatch"] isEqual:@"same"] && [detail[@"linkTransition"] isEqual:@"decremented"])
            {if ([detail[@"post"][@"nlink"] unsignedLongLongValue]) stillLinked++;else lastLink++;}
        else unconfirmed++;
    }
    [text appendFormat:@"\n已记录的成功明细：最后一个链接消失 %lu 次；仍有链接 %lu 次；链接变化未确认 %lu 次。链接消失不等于物理块已经释放。",
        (unsigned long)lastLink,(unsigned long)stillLinked,(unsigned long)unconfirmed];
    NSUInteger observed=0;for (NSDictionary *volume in evidence[@"volumes"]) if ([volume[@"state"] isEqual:@"observed"]) observed++;
    if (observed) [text appendFormat:@"；%lu 个卷有前后空闲空间观测，含其他进程影响，不能归为本次释放",(unsigned long)observed];
    for (NSDictionary *volume in evidence[@"volumes"]) {
        if ([volume[@"state"] isEqual:@"observed"]) {
            [text appendFormat:@"\n卷 %@：空闲空间变化 %+lld B；可用空间变化 %+lld B；观察间隔 %.3f 秒。",
                volume[@"volumeID"],[volume[@"freeBytesDelta"] longLongValue],[volume[@"availableBytesDelta"] longLongValue],[volume[@"elapsedSeconds"] doubleValue]];
        } else [text appendFormat:@"\n卷 %@：%@，空间变化未取得完整观测。",volume[@"volumeID"],
            [volume[@"state"] isEqual:@"recording"] ? @"采集中" : [volume[@"state"] isEqual:@"overflow"] ? @"数值超限" : @"观测不可用"];
        if ([volume[@"closeErrno"] unsignedIntegerValue]) [text appendFormat:@" 观测句柄关闭失败（errno %@）。",volume[@"closeErrno"]];
    }
    return text;
}

// A compact link to the last record, never a claim that cleanup is live or the app is empty.
static inline NSString *axs_cachekeeper_presentation_app_record(NSDictionary *report) {
    if (![report isKindOfClass:NSDictionary.class] || !report.count) return @"尚无清理记录";
    NSString *phase=[report[@"phase"] isKindOfClass:NSString.class] ? report[@"phase"] : nil;
    if ([report[@"failed"] unsignedIntegerValue] || [phase isEqual:@"error"]) return @"上次记录：有失败 · 查看详情";
    if ([phase isEqual:@"waiting"]) return @"上次记录：等待处理";
    if ([phase isEqual:@"cleaning"]) return @"上次记录：清理中";
    if ([phase isEqual:@"complete"] && [report[@"coverageComplete"] isKindOfClass:NSNumber.class] &&
        ![report[@"coverageComplete"] boolValue]) return @"上次记录：覆盖未完整";
    return @"清理记录 · 查看详情";
}

// Display-only contracts. Directory coverage never inherits app discovery coverage;
// cleanup byte counters never substitute for a directory size snapshot.
static inline NSString *axs_cachekeeper_presentation_time(id updated) {
    if (![updated isKindOfClass:NSDate.class]) return @"时间未知";
    NSDateFormatter *formatter=[NSDateFormatter new];
    formatter.locale=[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat=@"yyyy-MM-dd HH:mm:ss";
    formatter.timeZone=NSTimeZone.localTimeZone;
    return [formatter stringFromDate:updated];
}
static inline NSUInteger axs_cachekeeper_presentation_deferred(NSDictionary *receipt) {
    return receipt[@"deferred"] ? [receipt[@"deferred"] unsignedIntegerValue] :
        [receipt[@"recent"] unsignedIntegerValue]+[receipt[@"changed"] unsignedIntegerValue];
}
static inline NSString *axs_cachekeeper_presentation_round_state(NSDictionary *receipt) {
    if ([receipt[@"skipped"] boolValue]) return @"本轮未重扫（残留为上轮登记）";
    if ([receipt[@"cancelled"] boolValue]) return @"已中止";
    if (![receipt[@"complete"] boolValue]) return @"尚未完成";
    if (![receipt[@"measurementComplete"] boolValue]) return @"测量未完成，残留数量与大小未知";
    if ([receipt[@"failed"] unsignedIntegerValue]) return [NSString stringWithFormat:@"失败（%@ 项）",receipt[@"failed"]];
    if (!receipt[@"coverageComplete"]) return @"本目录覆盖未知（旧回执缺少覆盖记录）";
    if (![receipt[@"coverageComplete"] boolValue]) return @"本目录未完整覆盖";
    if ([receipt[@"unresolved"] unsignedIntegerValue]) return @"待识别";
    if (axs_cachekeeper_presentation_deferred(receipt)) return @"等待延期文件";
    if ([receipt[@"remaining"] unsignedIntegerValue]) return [NSString stringWithFormat:@"部分完成（待处理 %@ 项）",receipt[@"remaining"]];
    if ([receipt[@"retainedSubtreeCount"] unsignedIntegerValue]) return @"已检查（有整目录保留范围）";
    if ([receipt[@"protected"] unsignedIntegerValue]) return @"已检查（有受保护文件保留）";
    return @"本轮处理结束（不代表目录为空）";
}
static inline NSString *axs_cachekeeper_presentation_allocation(id value) {
    NSDictionary *allocation=axs_cachekeeper_allocation_projection(value);
    if (!allocation) return @"文件已分配量未知（记录无效）";
    if ([allocation[@"state"] isEqual:@"invalidMetadata"]) return @"文件元数据发生变化，已分配量未知";
    NSString *coverage=[allocation[@"state"] isEqual:@"complete"] ? @"" :
        ([allocation[@"state"] isEqual:@"inodeLimit"] ? @"（去重达到上限，未完整计量）" : @"（部分读取）");
    return [NSString stringWithFormat:@"文件已分配快照：%.2f MB%@；本次检测去重后的目录贡献，共享引用与可回收空间未核实",
        [allocation[@"allocatedBytes"] doubleValue]/1048576.0,coverage];
}
static inline NSString *axs_cachekeeper_presentation_snapshot(NSDictionary *row, id updated) {
    if (!row[@"bytes"]) return @"大小待检测（自动发现尚无大小快照）";
    NSString *logical=[NSString stringWithFormat:@"大小快照（%@）：%.2f MB%@；非实时占用",
        axs_cachekeeper_presentation_time(updated),[row[@"bytes"] doubleValue]/1048576.0,
        [row[@"complete"] boolValue] ? @"" : @"（未统计完整）"];
    return row[@"allocationObservation"] ? [logical stringByAppendingFormat:@"\n%@",axs_cachekeeper_presentation_allocation(row[@"allocationObservation"])] : logical;
}
static inline NSString *axs_cachekeeper_presentation_receipt(NSDictionary *receipt, NSDictionary *appReport) {
    NSMutableString *text=[NSMutableString stringWithFormat:@"清理记录（%@）：%@\n清理分类统计，非目录总占用；字节为逻辑长度，非实测释放空间。",
        axs_cachekeeper_presentation_time(receipt[@"updated"]),axs_cachekeeper_presentation_round_state(receipt)];
    BOOL skipped=[receipt[@"skipped"] boolValue];
    if (!skipped && receipt[@"removed"]) {
        [text appendFormat:@"\n已删除 %@ 项",receipt[@"removed"]];
        if (receipt[@"bytes"]) [text appendFormat:@" · %.2f MB",[receipt[@"bytes"] doubleValue]/1048576.0];
    }
    if ([receipt[@"measurementComplete"] boolValue] || skipped) {
        if (!skipped && receipt[@"protected"]) [text appendFormat:@"\n受保护文件 %@ 项",receipt[@"protected"]];
        for (NSString *key in @[@"remaining",@"deferred",@"unresolved"]) {
            NSUInteger count=[key isEqual:@"deferred"] ? axs_cachekeeper_presentation_deferred(receipt) : [receipt[key] unsignedIntegerValue];
            if (!count) continue;
            NSString *label=[key isEqual:@"remaining"] ? @"待处理" : [key isEqual:@"deferred"] ? @"延期" : @"待识别";
            [text appendFormat:@"\n%@%@: %lu 项",skipped ? @"上轮登记" : @"",label,(unsigned long)count];
            id bytes=receipt[[key stringByAppendingString:@"Bytes"]];
            if (bytes) [text appendFormat:@" · %.2f MB",[bytes doubleValue]/1048576.0];
        }
    }
    if ([receipt[@"failed"] unsignedIntegerValue]) [text appendFormat:@"\n失败 %@ 项",receipt[@"failed"]];
    NSUInteger retained=[receipt[@"retainedSubtreeCount"] unsignedIntegerValue];
    if (retained) [text appendFormat:@"\n整目录保留 %lu 处，内部未遍历，其文件数量和大小未计入清理文件统计；不能据此认定目录为空。",(unsigned long)retained];
    if (appReport[@"coverageComplete"] && ![appReport[@"coverageComplete"] boolValue])
        [text appendFormat:@"\nAPP 汇总覆盖未完整（APP 回执时间：%@）；本目录状态按本目录回执判断。",axs_cachekeeper_presentation_time(appReport[@"updated"])];
    if ([receipt[@"error"] length]) [text appendFormat:@"\n%@",receipt[@"error"]];
    if (appReport[@"confirmedRoundID"] || appReport[@"releaseEvidence"])
        [text appendFormat:@"\nAPP 本轮全部清理范围（APP 回执时间：%@；非本目录统计）\n%@",
            axs_cachekeeper_presentation_time(appReport[@"updated"]),axs_cachekeeper_presentation_release_evidence(appReport[@"releaseEvidence"])];
    return text;
}
static inline NSString *axs_cachekeeper_presentation_inspection(NSDictionary *report) {
    NSString *state=[report[@"cancelled"] boolValue] ? @"已停止（部分结果）" :
        ![report[@"complete"] boolValue] ? @"正在分批读取" :
        [report[@"coverageComplete"] boolValue] ? @"枚举完成" : @"结束但未完整读取";
    return [NSString stringWithFormat:@"深度检测记录（%@）：%@\n读取 %@ 个普通文件，%.2f MB（读取期间观察，非实时占用）",
        axs_cachekeeper_presentation_time(report[@"updated"]),state,report[@"files"] ?: @0,[report[@"bytes"] doubleValue]/1048576.0];
}
