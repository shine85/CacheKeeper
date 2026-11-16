#import "AxsCacheKeeperOperationInfo.h"
#import <Foundation/Foundation.h>
extern NSDictionary *axs_cachekeeper_test_peer_process(void);
static void check(BOOL pass,const char *message) { if (!pass) {fprintf(stderr,"FAIL: operation-history: %s\n",message);exit(1);} }
static NSDictionary *snapshot(NSMutableDictionary *history) {return axs_cachekeeper_operation_snapshot(history);}
int main(int argc,const char **argv) {
 @autoreleasepool {
    NSString *path=argc>1 ? @(argv[1]) : nil;
    check(path!=nil,"temporary receipt path provided");
    NSMutableDictionary *history=axs_cachekeeper_operation_history_create(@"image",nil);
    check([axs_cachekeeper_operation_process() isEqual:axs_cachekeeper_test_peer_process()],"two translation units share the process marker");
    if (argc>2) {
        NSDictionary *old=[NSDictionary dictionaryWithContentsOfFile:path];
        history=axs_cachekeeper_operation_history_create(@"image",old);
        NSDictionary *raw=snapshot(history);NSArray *processes=raw[@"processes"];
        check(processes.count==2,"restart preserves exactly previous and current instances");
        check(![processes[0][@"processID"] isEqual:processes[1][@"processID"]],"child process gets distinct marker");
        check([processes[0][@"actions"][0][@"state"] isEqual:@"unknown"],"restart does not invent completion for pending API");
        check(axs_cachekeeper_operation_history_validate(raw,@"image")!=nil,"restart output obeys schema");
        check([raw writeToFile:path atomically:YES],"restart history persists");return 0;
    }
    NSUInteger event=axs_cachekeeper_operation_begin(history,@"background",1,1,YES);
    axs_cachekeeper_operation_refresh(history,event,@"applied");
    NSUInteger action=axs_cachekeeper_operation_action(history,event,1);
    axs_cachekeeper_operation_transition(history,action,@"submitted",NO);
    axs_cachekeeper_operation_finish(history,event);
    NSDictionary *raw=snapshot(history);
    check([raw writeToFile:path atomically:YES],"pending actual plist persists");
    NSTask *child=[NSTask new];child.executableURL=[NSURL fileURLWithPath:@(argv[0])];child.arguments=@[path,@"restart"];
    NSError *error=nil;check([child launchAndReturnError:&error],"restart child launches");[child waitUntilExit];check(child.terminationStatus==0,"restart child checks pass");
    NSDictionary *restarted=[NSDictionary dictionaryWithContentsOfFile:path];
    check([restarted[@"processes"] count]==2,"parent reads actual child plist");
    axs_cachekeeper_operation_transition(history,action,@"submitted",YES);
    check([snapshot(history)[@"processes"][0][@"actions"][0][@"state"] isEqual:@"submitted"],"timeout is nonterminal");
    axs_cachekeeper_operation_transition(history,action,@"apiCompleted",NO);
    axs_cachekeeper_operation_transition(history,action,@"failed",NO);
    check([snapshot(history)[@"processes"][0][@"actions"][0][@"state"] isEqual:@"apiCompleted"],"terminal action ignores duplicate or contradictory callback");
    for (NSUInteger round=0;round<100;round++) {
        NSUInteger e=axs_cachekeeper_operation_begin(history,@"background",2,1,NO);
        for (NSUInteger owner=1;owner<=3;owner++) {NSUInteger a=axs_cachekeeper_operation_action(history,e,owner);axs_cachekeeper_operation_transition(history,a,@"skipped",NO);}
        axs_cachekeeper_operation_finish(history,e);
    }
    raw=snapshot(history);check(axs_cachekeeper_operation_history_validate(raw,@"image")!=nil,"truncated cumulative history remains valid");
    check([raw[@"historyTruncated"] boolValue] && [raw[@"processes"][0][@"events"] count]<=32 && [raw[@"processes"][0][@"actions"] count]<=64,"terminal history bounded across owners");
    NSMutableDictionary *aliases=[NSMutableDictionary new];
    NSDictionary *exported=axs_cachekeeper_operation_history_projection(raw,aliases);
    NSMutableDictionary *web=axs_cachekeeper_operation_history_create(@"webkit",nil);
    NSDictionary *other=axs_cachekeeper_operation_history_projection(snapshot(web),aliases);
    check([exported[@"processes"][0][@"processAlias"] isEqual:other[@"processes"][0][@"processAlias"]],"same export aliases across components");
    NSData *json=[NSJSONSerialization dataWithJSONObject:@[exported,other] options:0 error:&error];
    NSString *text=[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    check(json && ![text containsString:axs_cachekeeper_operation_process()[@"processID"]] && ![text containsString:@"processID"],"JSON contains no internal nonce");
    check([json writeToFile:[path stringByAppendingString:@".json"] atomically:YES],"actual exported JSON persists");
    NSMutableDictionary *bad=[raw mutableCopy];bad[@"private-canary"]=@"/private/path-canary";
    check(!axs_cachekeeper_operation_history_validate(bad,nil),"unknown private fields rejected");
    check([snapshot(axs_cachekeeper_operation_history_create(@"image",bad))[@"historyRejected"] boolValue],"invalid persisted history reports rejection");
    check(!axs_cachekeeper_operation_history_validate(exported,nil),"export aliases cannot reenter raw schema");
    NSMutableDictionary *merging=axs_cachekeeper_operation_history_create(@"image",nil);
    NSUInteger live=axs_cachekeeper_operation_begin(merging,@"configuration",3,2,YES);
    axs_cachekeeper_operation_restore(merging,restarted);
    NSDictionary *merged=snapshot(merging);
    check([merged[@"processes"] count]==2 && [[[merged[@"processes"] lastObject][@"events"] lastObject][@"eventID"] unsignedIntegerValue]==live,
          "asynchronous old load retains events already scheduled in current process");
    axs_cachekeeper_operation_refresh(merging,live,@"applied");axs_cachekeeper_operation_finish(merging,live);
    check(axs_cachekeeper_operation_history_validate(snapshot(merging),@"image")!=nil,"async merged current and previous states validate");
    NSMutableDictionary *pending=nil;BOOL writable=YES;
    check(!axs_cachekeeper_operation_save(raw,[path stringByAppendingPathComponent:@"missing/receipt.plist"],YES,&pending,&writable) && pending && !writable,"write failure retains cumulative pending receipt");
    NSUInteger newer=axs_cachekeeper_operation_begin(history,@"foreground",3,1,NO);axs_cachekeeper_operation_finish(history,newer);raw=snapshot(history);
    check(axs_cachekeeper_operation_save(raw,path,YES,&pending,&writable) && !pending && writable,"retry writes latest history atomically");
    check([[NSDictionary dictionaryWithContentsOfFile:path] isEqual:raw],"saved retry roundtrips exactly");
    puts("PASS: operation-history plist/JSON, process restart, bounds, rejection and write retry");
 }
 return 0;
}
