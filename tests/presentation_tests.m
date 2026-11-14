#import <Foundation/Foundation.h>
#import "../AxsCacheKeeperPresentation.h"

static void pcheck(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr,"FAIL: presentation: %s\n",message.UTF8String); exit(1); }
}
void axs_cachekeeper_run_presentation_tests(void) {
    NSDate *old=[NSDate dateWithTimeIntervalSince1970:1794441600];
    NSDate *recent=[old dateByAddingTimeInterval:86400];
    NSDictionary *receipt=@{@"complete":@YES,@"measurementComplete":@YES,@"coverageComplete":@YES,
        @"retainedSubtreeCount":@12,@"removed":@0,@"updated":recent};
    NSString *state=axs_cachekeeper_presentation_round_state(receipt);
    pcheck([state containsString:@"整目录保留"] && ![state containsString:@"发现不完整"] && ![state isEqual:@"完成"],@"本目录完整且保留12子树不能受全APP发现未完成影响或报完成");
    NSString *text=axs_cachekeeper_presentation_receipt(receipt,@{@"coverageComplete":@NO});
    pcheck([text containsString:@"APP 范围发现未完整"] && [text containsString:@"12"] && [text containsString:@"未计入"] && [text containsString:@"总占用"],@"全APP范围另注且保留子树统计不冒充总占用");
    NSString *size=axs_cachekeeper_presentation_snapshot(@{@"bytes":@0,@"complete":@YES},old);
    pcheck([size containsString:@"大小快照（"] && [size containsString:@"0.00 MB"] && [size containsString:@"非实时占用"],@"旧零大小必须有独立快照时间和性质");
    pcheck(![size containsString:@"105.00"] && ![size containsString:@"8.82"],@"不得用清理字节替代目录大小");
    pcheck([axs_cachekeeper_presentation_snapshot(@{},nil) containsString:@"大小待检测"],@"自动发现没有大小即未知");
    pcheck([axs_cachekeeper_presentation_snapshot(@{@"bytes":@1},nil) containsString:@"时间未知"],@"遗留大小快照缺时间应明示");
    pcheck([axs_cachekeeper_presentation_round_state(@{@"complete":@YES,@"measurementComplete":@YES}) containsString:@"覆盖未知"],@"旧回执缺目录coverage不能继承APP值或当完整");
    pcheck([axs_cachekeeper_presentation_round_state(@{@"complete":@YES,@"measurementComplete":@YES,@"coverageComplete":@NO}) containsString:@"本目录未完整覆盖"],@"目录覆盖不完整必须保留提示");
    pcheck([axs_cachekeeper_presentation_round_state(@{@"skipped":@YES}) containsString:@"未重扫"],@"结转不能冒充本轮重新测量");
    NSString *inspection=axs_cachekeeper_presentation_inspection(@{@"complete":@YES,@"coverageComplete":@YES,@"updated":old,@"files":@0,@"bytes":@0});
    pcheck([inspection containsString:@"深度检测记录（"] && [inspection containsString:@"非实时占用"],@"深度检测与清理回执分别注明时间和性质");
    fprintf(stdout,"PASS: presentation contracts\n");
}
