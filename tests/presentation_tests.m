#import <Foundation/Foundation.h>
#import "../AxsCacheKeeperPresentation.h"

static void pcheck(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr,"FAIL: presentation: %s\n",message.UTF8String); exit(1); }
}
void axs_cachekeeper_run_presentation_tests(void) {
    pcheck([axs_cachekeeper_presentation_app_record(nil) isEqual:@"尚无清理记录"],@"没有回执不显示成功");
    pcheck([axs_cachekeeper_presentation_app_record(@{@"phase":@"complete",@"failed":@2}) containsString:@"有失败"],@"失败优先于阶段");
    pcheck([axs_cachekeeper_presentation_app_record(@{@"phase":@"waiting"}) containsString:@"等待处理"],@"等待记录不能当正在清理");
    pcheck([axs_cachekeeper_presentation_app_record(@{@"phase":@"cleaning"}) containsString:@"清理中"],@"仅表达回执记录的阶段");
    pcheck([axs_cachekeeper_presentation_app_record(@{@"phase":@"complete",@"coverageComplete":@NO}) containsString:@"覆盖未完整"],@"结束阶段不掩盖覆盖缺口");
    pcheck([axs_cachekeeper_presentation_app_record(@{@"phase":@"complete",@"coverageComplete":@YES,@"bytes":@999}) isEqual:@"清理记录 · 查看详情"],@"紧凑行不把结束或计数字节当清空和实际释放");
    pcheck([axs_cachekeeper_presentation_app_record(@{@"phase":@42,@"coverageComplete":@[]}) isEqual:@"清理记录 · 查看详情"],@"旧记录的未知阶段不强转或臆测");
    NSDate *old=[NSDate dateWithTimeIntervalSince1970:1794441600];
    NSDate *recent=[old dateByAddingTimeInterval:86400];
    NSDictionary *oldRuntime=@{@"schemaVersion":@1,@"packageVersion":@"0.7.2-179.2",@"firstObserved":@1794441500};
    NSString *oldObservation=axs_cachekeeper_presentation_saved_runtime(@{@"runtimeInfo":oldRuntime,@"updated":old},@"0.7.2-188.1");
    pcheck([oldObservation containsString:@"179.2"] && [oldObservation containsString:@"旧版记录"] &&
        [oldObservation containsString:@"不能验证当前模式"] && [oldObservation containsString:axs_cachekeeper_presentation_time(old)],@"旧宿主结果必须带版本时间且不能验证当前模式");
    NSMutableDictionary *currentRuntime=[oldRuntime mutableCopy];currentRuntime[@"packageVersion"]=@"0.7.2-188.1";
    NSString *currentObservation=axs_cachekeeper_presentation_saved_runtime(@{@"runtimeInfo":currentRuntime,@"updated":recent},@"0.7.2-188.1");
    pcheck([currentObservation containsString:@"188.1"] && [currentObservation containsString:@"同版历史记录"] &&
        [currentObservation containsString:@"当前模式效果仍需核验"],@"同版本不能单独证明同一配置阶段已生效");
    pcheck([axs_cachekeeper_presentation_saved_runtime(@{@"updated":old},@"0.7.2-188.1") containsString:@"来源版本未记录"],@"旧格式不伪造运行版本");
    pcheck([axs_cachekeeper_presentation_saved_runtime(@{@"runtimeInfo":@{@"schemaVersion":@1}},@"0.7.2-188.1") containsString:@"来源版本无效"],@"损坏来源不能当无记录或当前版本");
    pcheck([axs_cachekeeper_presentation_saved_runtime(@{@"runtimeInfo":currentRuntime},nil) containsString:@"面板版本未知"],@"缺面板版本不能判定当前版本");
    NSDictionary *receipt=@{@"complete":@YES,@"measurementComplete":@YES,@"coverageComplete":@YES,
        @"retainedSubtreeCount":@12,@"removed":@0,@"updated":recent};
    NSString *state=axs_cachekeeper_presentation_round_state(receipt);
    pcheck([state containsString:@"整目录保留"] && ![state containsString:@"发现不完整"] && ![state isEqual:@"完成"],@"本目录完整且保留12子树不能受全APP汇总覆盖未完整影响或报完成");
    NSString *text=axs_cachekeeper_presentation_receipt(receipt,@{@"coverageComplete":@NO});
    pcheck([text containsString:@"APP 汇总覆盖未完整"] && [text containsString:@"12"] && [text containsString:@"未计入"] && [text containsString:@"总占用"],@"全APP汇总覆盖另注且保留子树统计不冒充总占用");
    NSString *size=axs_cachekeeper_presentation_snapshot(@{@"bytes":@0,@"complete":@YES},old);
    pcheck([size containsString:@"大小快照（"] && [size containsString:@"0.00 MB"] && [size containsString:@"非实时占用"],@"旧零大小必须有独立快照时间和性质");
    pcheck(![size containsString:@"105.00"] && ![size containsString:@"8.82"],@"不得用清理字节替代目录大小");
    pcheck([axs_cachekeeper_presentation_snapshot(@{},nil) containsString:@"大小待检测"],@"自动发现没有大小即未知");
    pcheck([axs_cachekeeper_presentation_snapshot(@{@"bytes":@1},nil) containsString:@"时间未知"],@"遗留大小快照缺时间应明示");
    pcheck([axs_cachekeeper_presentation_round_state(@{@"complete":@YES,@"measurementComplete":@YES}) containsString:@"覆盖未知"],@"旧回执缺目录coverage不能继承APP值或当完整");
    pcheck([axs_cachekeeper_presentation_round_state(@{@"complete":@YES,@"measurementComplete":@YES,@"coverageComplete":@NO}) containsString:@"本目录未完整覆盖"],@"目录覆盖不完整必须保留提示");
    pcheck([axs_cachekeeper_presentation_round_state(@{@"skipped":@YES}) containsString:@"未重扫"],@"结转不能冒充本轮重新测量");
    pcheck([axs_cachekeeper_presentation_round_state(@{@"cancelled":@YES}) isEqual:@"已中止"],@"中止优先于完成和覆盖");
    pcheck([axs_cachekeeper_presentation_round_state(@{@"complete":@YES,@"measurementComplete":@YES,@"coverageComplete":@YES,@"failed":@1}) containsString:@"失败"],@"失败不能被目录完整标志覆盖");
    NSString *unmeasured=axs_cachekeeper_presentation_receipt(@{@"complete":@YES,@"measurementComplete":@NO,@"remaining":@0},@{});
    pcheck([unmeasured containsString:@"残留数量与大小未知"] && ![unmeasured containsString:@"待处理: 0"],@"未测完不能把缺失残留当零");
    pcheck([size containsString:axs_cachekeeper_presentation_time(old)] && ![size containsString:axs_cachekeeper_presentation_time(recent)],@"目录大小保留自身快照时间");
    pcheck([text containsString:axs_cachekeeper_presentation_time(recent)] && ![text containsString:axs_cachekeeper_presentation_time(old)],@"清理记录保留独立回执时间");
    NSDictionary *alog=@{@"complete":@YES,@"measurementComplete":@YES,@"coverageComplete":@YES,@"removed":@1,@"bytes":@(105*1048576),@"unresolved":@2,@"unresolvedBytes":@(9250406),@"updated":recent};
    NSString *alogText=axs_cachekeeper_presentation_receipt(alog,@{});
    NSString *alogSize=axs_cachekeeper_presentation_snapshot(@{@"bytes":@(18863882),@"complete":@YES},old);
    pcheck([alogText containsString:@"105.00 MB"] && [alogText containsString:@"8.82 MB"] && [alogText containsString:@"非目录总占用"] && [alogSize containsString:@"17.99 MB"],@"旧大小与新清理/待识别字节各自标注，互不替代");
    NSString *inspection=axs_cachekeeper_presentation_inspection(@{@"complete":@YES,@"coverageComplete":@YES,@"updated":old,@"files":@0,@"bytes":@0});
    pcheck([inspection containsString:@"深度检测记录（"] && [inspection containsString:@"非实时占用"],@"深度检测与清理回执分别注明时间和性质");
    NSDictionary *allocation=@{@"schemaVersion":@1,@"scope":@"taskUniqueRegularFileInodeFirstObservation",@"state":@"complete",
        @"allocatedBytes":@(4*1048576),@"uniqueFiles":@2,@"duplicateFiles":@1,@"untrackedFiles":@0,@"inodeBudget":@65536};
    NSString *allocationText=axs_cachekeeper_presentation_snapshot(@{@"bytes":@(8*1048576),@"complete":@YES,@"allocationObservation":allocation},old);
    pcheck([allocationText containsString:@"8.00 MB"] && [allocationText containsString:@"4.00 MB"] && [allocationText containsString:@"可回收空间未核实"],@"逻辑与去重分配量分别显示，不冒充释放量");
    NSMutableDictionary *limited=[allocation mutableCopy];limited[@"state"]=@"inodeLimit";limited[@"untrackedFiles"]=@1;
    pcheck([axs_cachekeeper_presentation_allocation(limited) containsString:@"未完整计量"],@"分配量预算不足不能显示完整");
    limited[@"state"]=@"invalidMetadata";
    pcheck([axs_cachekeeper_presentation_allocation(limited) containsString:@"已分配量未知"] && ![axs_cachekeeper_presentation_allocation(limited) containsString:@"4.00"],@"变化元数据不能显示已核验容量");
    limited[@"allocatedBytes"]=@YES;
    pcheck([axs_cachekeeper_presentation_allocation(limited) containsString:@"记录无效"],@"无效分配记录不冒充零值");
    pcheck(![size containsString:@"已分配"],@"旧快照缺分配量不伪造测量");
    NSDictionary *context=axs_cachekeeper_cleanup_context(@"clean",YES,YES,NO,YES,@"0.7.2-188.1",@"1.0",@"110",@"platform-cache:2",@[],@[],@[]);
    NSDictionary *round=@{@"roundID":@"saved-round",@"finishedAt":old,@"removed":@1,@"bytes":@12,@"failed":@1,
        @"endReason":@4,@"coverageComplete":@NO,@"context":context,@"releaseEvidence":@{@"state":@"notRecorded"}};
    NSDictionary *history=@{@"schemaVersion":@1,@"state":@"recorded",@"capacity":@16,@"truncatedCount":@0,@"rounds":@[round]};
    NSMutableDictionary *status=[@{@"updated":recent,@"confirmedRoundID":@"saved-round",@"cleanupContext":context,
        @"cleanupHistory":history,@"lastEffectiveCleanup":round,@"releaseEvidence":@{@"state":@"notRecorded"}} mutableCopy];
    NSString *savedDetail=axs_cachekeeper_presentation_receipt(receipt,status);
    pcheck([savedDetail containsString:[NSString stringWithFormat:@"该轮结束时间：%@",axs_cachekeeper_presentation_time(old)]] &&
        [savedDetail containsString:[NSString stringWithFormat:@"状态记录时间：%@",axs_cachekeeper_presentation_time(recent)]] &&
        [savedDetail containsString:@"该回执配置：只清理"] && [savedDetail containsString:@"插件 0.7.2-188.1"] &&
        [savedDetail containsString:@"该轮已中止"] && [savedDetail containsString:@"该轮失败 1 项"] &&
        [savedDetail containsString:@"该轮覆盖未完整"] && ![savedDetail containsString:@"APP 本轮全部清理范围"],
        @"status-only updates cannot relabel historical cleanup time or configuration");
    NSString *legacyDetail=axs_cachekeeper_presentation_receipt(receipt,@{@"updated":recent,@"confirmedRoundID":@"legacy",@"releaseEvidence":@{@"state":@"notRecorded"}});
    pcheck([legacyDetail containsString:@"该轮结束时间未记录或未确认"] && [legacyDetail containsString:@"该回执配置未记录"],@"legacy receipt cannot invent a round time or mode");
    status[@"confirmedRoundID"]=@"running-round";
    NSString *runningDetail=axs_cachekeeper_presentation_receipt(receipt,status);
    pcheck([runningDetail containsString:@"该轮结束时间未记录或未确认"] &&
        ![runningDetail containsString:@"该轮结束时间："],@"unmatched running round cannot borrow preceding effective time");
    status[@"cleanupHistory"]=@{@"state":@"invalid"};
    NSString *invalidDetail=axs_cachekeeper_presentation_receipt(receipt,status);
    pcheck([invalidDetail containsString:@"清理历史无效"] && ![invalidDetail containsString:@"该回执配置："],@"invalid history cannot supply trusted round context");
    NSDictionary *emptyRound=@{@"roundID":@"empty-round",@"finishedAt":recent,@"removed":@0,@"bytes":@0,@"failed":@0,
        @"endReason":@1,@"coverageComplete":@YES,@"context":context,@"releaseEvidence":@{@"state":@"notRecorded"}};
    NSMutableArray *retainedRounds=[NSMutableArray new];
    for (NSUInteger i=0;i<16;i++) {
        NSMutableDictionary *copy=[emptyRound mutableCopy];copy[@"roundID"]=[NSString stringWithFormat:@"empty-%lu",(unsigned long)i];
        [retainedRounds addObject:copy];
    }
    status[@"confirmedRoundID"]=@"saved-round";
    status[@"cleanupHistory"]=@{@"schemaVersion":@1,@"state":@"recorded",@"capacity":@16,@"truncatedCount":@1,@"rounds":retainedRounds};
    NSString *truncatedDetail=axs_cachekeeper_presentation_receipt(receipt,status);
    pcheck([truncatedDetail containsString:[NSString stringWithFormat:@"该轮结束时间：%@",axs_cachekeeper_presentation_time(old)]],
        @"same confirmed effective round retains time outside truncated history");
    status[@"confirmedRoundID"]=@"other-unretained";
    pcheck([axs_cachekeeper_presentation_receipt(receipt,status) containsString:@"该轮结束时间未记录或未确认"],
        @"truncated unrelated round cannot substitute last retained time");
    status[@"confirmedRoundID"]=@"saved-round";
    status[@"cleanupHistory"]=history;
    NSMutableDictionary *badRound=[round mutableCopy];badRound[@"releaseEvidence"]=@{@"state":@"recording"};
    status[@"lastEffectiveCleanup"]=badRound;
    pcheck([axs_cachekeeper_presentation_receipt(receipt,status) containsString:@"清理历史无效"],@"invalid effective evidence cannot be trusted independently");
    fprintf(stdout,"PASS: presentation contracts\n");
}
