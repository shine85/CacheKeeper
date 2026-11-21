#import <Foundation/Foundation.h>
#import "AxsCacheKeeperCleanupRules.h"

static void check(BOOL value,const char *message) {
    if(!value){fprintf(stderr,"FAIL: alog-version: %s\n",message);exit(1);}
}
int main(void) {@autoreleasepool {
    [AxsCacheKeeperCleanupRules removeAllRulesForTesting];
    NSString *bundle=@"com.ss.iphone.ugc.Aweme";
    NSDictionary *state=@{@"processExited":@YES,@"logPaths":@[@"Library/alog",@"Library/alog-other"]};
    NSDictionary *evidence=@{@"readComplete":@YES,@"hasEvidence":@NO,@"hasMediaSignature":@NO};
    AxsCacheKeeperCleanupDecision *(^decide)(NSString *,NSString *,NSDictionary *,NSDictionary *)=
        ^(NSString *version,NSString *path,NSDictionary *s,NSDictionary *e) {
            return [AxsCacheKeeperCleanupRules decisionForBundle:bundle version:version relativePath:path state:s evidence:e];
        };
    NSArray *paths=@[@"Library/alog/ready/app.log",@"Library/alog/default/prepare/app.log",@"Library/alog/Unknown/app.log"];
    for(NSString *version in @[@"41.2.0",@"41.1.1",@"",@"41.1.0.1"]) {
        for(NSString *path in paths) {
            AxsCacheKeeperCleanupDecision *decision=decide(version,path,state,evidence);
            check(decision.disposition==AxsCacheKeeperCleanupUnresolved,"unsupported version cannot fall through to user log");
            check([decision.ruleID isEqual:@"douyin-alog"] && [decision.scopeRelativePath isEqual:@"Library/alog"],"reserved scope keeps its diagnostic rule identity");
        }
    }
    check(decide(nil,paths[0],state,evidence).disposition==AxsCacheKeeperCleanupUnresolved,"missing version keeps reserved scope");
    NSString *ready=@"Library/alog/ready/BDALog_20261111_193314.alog.iOS.1128";
    check(decide(@"41.1.0",ready,state,evidence).disposition==AxsCacheKeeperCleanupDelete,"supported exact ready log remains eligible");
    check(decide(@"41.1.0",paths[0],state,evidence).disposition==AxsCacheKeeperCleanupUnresolved,"supported version still rejects unknown log name");
    check(decide(@"41.1.0",ready,@{@"processExited":@NO,@"logPaths":@[@"Library/alog"]},evidence).disposition==AxsCacheKeeperCleanupUnresolved,"suspension cannot bypass exit condition");
    check(decide(@"41.2.0",paths[0],state,@{@"readComplete":@NO}).disposition==AxsCacheKeeperCleanupDefer,"read failure remains deferred");
    check(decide(@"41.2.0",paths[0],@{@"excludedPaths":@[@"Library/alog"],@"logPaths":@[@"Library/alog"]},evidence).disposition==AxsCacheKeeperCleanupKeep,"user exclusion keeps precedence");
    check(decide(@"41.2.0",@"Library/alog-other/app.log",state,evidence).basis==AxsCacheKeeperCleanupBasisUserLog,"component neighbor keeps independent log rule");
    check([AxsCacheKeeperCleanupRules decisionForBundle:@"com.example.other" version:@"41.2.0" relativePath:paths[0] state:state evidence:evidence].basis==AxsCacheKeeperCleanupBasisUserLog,"reserved scope is bundle specific");
    AxsCacheKeeperAppRule *later=[[NSClassFromString(@"AxsCacheKeeperALogRule") alloc] initWithRuleID:@"test-later-alog" revision:@"1" appVersion:@"41.2.0" cleanablePaths:@[@"Library/alog"] retentionPaths:@[] dependencyPaths:@[]];
    check(later!=nil,"test uses actual ALog subclass");
    [AxsCacheKeeperCleanupRules registerRule:later forBundle:bundle];
    AxsCacheKeeperCleanupDecision *decision=decide(@"41.2.0",ready,state,evidence);
    check(decision.disposition==AxsCacheKeeperCleanupDelete && [decision.ruleID isEqual:@"test-later-alog"],"older version does not shadow later matching rule");
    [AxsCacheKeeperCleanupRules removeAllRulesForTesting];
    check([[AxsCacheKeeperCleanupRules rulesVersion] containsString:@"douyin-alog:3"],"revision invalidates jobs created before fallback fix");
    puts("PASS: ALog version precedence and scoped fallback");return 0;
}}
