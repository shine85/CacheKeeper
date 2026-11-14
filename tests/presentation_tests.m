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
    fprintf(stdout,"PASS: presentation contracts\n");
}
