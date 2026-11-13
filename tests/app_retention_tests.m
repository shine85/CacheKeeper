#import <Foundation/Foundation.h>
#import "../AxsCacheKeeperCleanupRules.h"
#import "../AxsCacheKeeperSweep.h"

static void archeck(BOOL condition,NSString *message) {
    if (!condition) { fprintf(stderr,"FAIL: app retention: %s\n",message.UTF8String);exit(1); }
}
static void arput(NSString *path) {
    archeck([NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil],@"创建夹具目录");
    archeck([@"local offline payload" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil],@"写入夹具内容");
}
static void arfinish(AxsCacheKeeperSweep *sweep) {
    for (NSUInteger i=0;i<1000 && !sweep.complete;i++) [sweep advance:8 shouldContinue:^BOOL{return YES;}];
    archeck(sweep.complete,@"有界夹具清理结束");
}
void axs_cachekeeper_run_app_retention_tests(NSString *fixture) {
    NSArray *cases=@[
        @{@"bundle":@"com.zhiliaoapp.musically",@"paths":@[@"offline-mode",@"com.studio.album.importToEdit"]},
        @{@"bundle":@"com.strava.stravaride",@"paths":@[@"offline",@"mapdownloads"]},
        @{@"bundle":@"com.google.Maps",@"paths":@[@"OfflineData"]}];
    NSDictionary *evidence=@{@"readComplete":@YES,@"hasEvidence":@NO,@"hasMediaSignature":@NO};
    [AxsCacheKeeperCleanupRules removeAllRulesForTesting];
    NSTimeInterval future=NSDate.date.timeIntervalSince1970+600;
    NSUInteger index=0;
    for (NSDictionary *item in cases) {
        NSString *bundle=item[@"bundle"];
        NSString *home=[fixture stringByAppendingPathComponent:[NSString stringWithFormat:@"app-retention-%lu",(unsigned long)index++]];
        NSString *root=[home stringByAppendingPathComponent:@"Library/Caches"];
        for (NSString *part in item[@"paths"]) {
            NSString *relative=[NSString stringWithFormat:@"Library/Caches/%@/payload",part];
            AxsCacheKeeperCleanupDecision *decision=[AxsCacheKeeperCleanupRules decisionForBundle:bundle version:@"future-version" relativePath:relative state:@{} evidence:evidence];
            archeck(decision.disposition==AxsCacheKeeperCleanupKeep && decision.basis==AxsCacheKeeperCleanupBasisAppRule,@"已知离线/草稿范围必须有独立APP保留规则，升级也不撤销保护");
            arput([home stringByAppendingPathComponent:relative]);
        }
        NSString *ordinary=[root stringByAppendingPathComponent:@"ordinary-cache"];arput(ordinary);
        AxsCacheKeeperSweep *sweep=[[AxsCacheKeeperSweep alloc] initWithRoot:root bundle:bundle version:@"future-version" containerPath:home state:@{} clock:^NSTimeInterval{return future;}];arfinish(sweep);
        archeck(sweep.removed==1 && ![NSFileManager.defaultManager fileExistsAtPath:ordinary],@"保留范围不连坐同级普通缓存");
        for (NSString *part in item[@"paths"]) archeck([NSFileManager.defaultManager fileExistsAtPath:[[root stringByAppendingPathComponent:part] stringByAppendingPathComponent:@"payload"]],@"实际清理后离线/草稿文件保持完整");
    }
    for (NSString *bundle in @[@"com.example.other",@"com.ss.iphone.ugc.Aweme",@"com.zhiliaoapp.musically.other"])
        archeck([AxsCacheKeeperCleanupRules decisionForBundle:bundle version:@"1" relativePath:@"Library/Caches/com.studio.album.importToEdit/a" state:@{} evidence:evidence].disposition==AxsCacheKeeperCleanupDelete,@"TikTok规则不按相似包名套国内抖音或其他APP");
    archeck([AxsCacheKeeperCleanupRules decisionForBundle:@"com.zhiliaoapp.musically" version:@"1" relativePath:@"Library/Caches/com.studio.album.importToEdit-backup/a" state:@{} evidence:evidence].disposition==AxsCacheKeeperCleanupDelete,@"保留按完整路径成分匹配");
    NSString *spotify=[fixture stringByAppendingPathComponent:@"spotify-retention"];
    NSString *download=[spotify stringByAppendingPathComponent:@"Library/Caches/opaque-resource"];arput(download);
    NSString *temp=[spotify stringByAppendingPathComponent:@"tmp/ordinary-cache"];arput(temp);
    for (NSString *relative in @[@"Library/Caches",@"tmp"]) {
        AxsCacheKeeperSweep *sweep=[[AxsCacheKeeperSweep alloc] initWithRoot:[spotify stringByAppendingPathComponent:relative] bundle:@"com.spotify.client" version:nil containerPath:spotify state:@{} clock:^NSTimeInterval{return future;}];arfinish(sweep);
        archeck(sweep.removed==([relative isEqual:@"tmp"] ? 1 : 0),@"Spotify只保留可能存离线歌曲的缓存根，独立临时缓存继续处理");
    }
    archeck([NSFileManager.defaultManager fileExistsAtPath:download] && ![NSFileManager.defaultManager fileExistsAtPath:temp],@"Spotify离线对照与独立范围真实文件结果");
    puts("PASS: exact app retention, offline/draft preservation, independent cache deletion and upgrade retention");
}
