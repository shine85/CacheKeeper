#pragma once
#import <Foundation/Foundation.h>

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
static inline NSString *axs_cachekeeper_presentation_snapshot(NSDictionary *row, id updated) {
    if (!row[@"bytes"]) return @"大小待检测（自动发现尚无大小快照）";
    return [NSString stringWithFormat:@"大小快照（%@）：%.2f MB%@；非实时占用",
        axs_cachekeeper_presentation_time(updated),[row[@"bytes"] doubleValue]/1048576.0,
        [row[@"complete"] boolValue] ? @"" : @"（未统计完整）"];
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
    return text;
}
static inline NSString *axs_cachekeeper_presentation_inspection(NSDictionary *report) {
    NSString *state=[report[@"cancelled"] boolValue] ? @"已停止（部分结果）" :
        ![report[@"complete"] boolValue] ? @"正在分批读取" :
        [report[@"coverageComplete"] boolValue] ? @"枚举完成" : @"结束但未完整读取";
    return [NSString stringWithFormat:@"深度检测记录（%@）：%@\n读取 %@ 个普通文件，%.2f MB（读取期间观察，非实时占用）",
        axs_cachekeeper_presentation_time(report[@"updated"]),state,report[@"files"] ?: @0,[report[@"bytes"] doubleValue]/1048576.0];
}
