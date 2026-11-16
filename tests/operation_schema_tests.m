#import <Foundation/Foundation.h>
#import "AxsCacheKeeperOperationInfo.h"

static void check(BOOL pass,const char *message) {
    if (!pass) {fprintf(stderr,"FAIL: operation-schema: %s\n",message);exit(1);}
}
static BOOL boolean(id value,BOOL expected) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID() && [value boolValue]==expected;
}
int main(int argc,const char **argv) {
    @autoreleasepool {
        check(argc==2,"one isolated scenario required");
        NSString *scenario=@(argv[1]);
        NSMutableDictionary *history=axs_cachekeeper_operation_history_create(@"image",nil);
        if ([scenario isEqual:@"create"]) {
            check(boolean(axs_cachekeeper_operation_snapshot(history)[@"historyRejected"],NO),"new history rejection flag is a boolean");
        } else if ([scenario isEqual:@"transition"]) {
            NSUInteger event=axs_cachekeeper_operation_begin(history,@"background",1,1,NO);
            NSUInteger action=axs_cachekeeper_operation_action(history,event,1);
            axs_cachekeeper_operation_transition(history,action,@"submitted",NO);
            axs_cachekeeper_operation_timeout(history,action);
            axs_cachekeeper_operation_finish(history,event);
            NSDictionary *raw=axs_cachekeeper_operation_snapshot(history);
            check(boolean(raw[@"processes"][0][@"actions"][0][@"timedOut"],YES),"timeout flag is a boolean");
            check(axs_cachekeeper_operation_history_validate(raw,@"image")!=nil,"timed-out submitted action remains valid");
            axs_cachekeeper_operation_transition(history,action,@"apiCompleted",NO);
            raw=axs_cachekeeper_operation_snapshot(history);
            check(boolean(raw[@"processes"][0][@"actions"][0][@"timedOut"],YES),"late completion retains boolean timeout evidence");
            check([raw[@"processes"][0][@"events"][0][@"state"] isEqual:@"finished"],"last completion settles the closed event");
        } else if ([scenario isEqual:@"restore-rejected"]) {
            axs_cachekeeper_operation_restore(history,@{});
            check(boolean(axs_cachekeeper_operation_snapshot(history)[@"historyRejected"],YES),"restored rejection flag is a boolean");
        } else if ([scenario isEqual:@"restore-truncated"]) {
            NSMutableDictionary *previous=[axs_cachekeeper_operation_snapshot(history) mutableCopy];
            previous[@"historyRejected"]=@NO;previous[@"historyTruncated"]=@YES;
            axs_cachekeeper_operation_restore(history,previous);
            check(boolean(axs_cachekeeper_operation_snapshot(history)[@"historyTruncated"],YES),"restored truncation flag is a boolean");
        } else check(NO,"known scenario required");
        NSDictionary *raw=axs_cachekeeper_operation_snapshot(history);
        check(axs_cachekeeper_operation_history_validate(raw,@"image")!=nil,"production snapshot obeys the closed schema");
        NSData *plist=[NSPropertyListSerialization dataWithPropertyList:raw format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        NSDictionary *loaded=plist ? [NSPropertyListSerialization propertyListWithData:plist options:0 format:NULL error:nil] : nil;
        check(loaded && axs_cachekeeper_operation_history_validate(loaded,@"image")!=nil,"binary plist roundtrip retains schema types");
        NSDictionary *exported=axs_cachekeeper_operation_history_projection(loaded,[NSMutableDictionary new]);
        NSData *json=exported ? [NSJSONSerialization dataWithJSONObject:exported options:0 error:nil] : nil;
        NSDictionary *decoded=json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
        check(decoded && boolean(decoded[@"historyRejected"],[raw[@"historyRejected"] boolValue]) &&
              boolean(decoded[@"historyTruncated"],[raw[@"historyTruncated"] boolValue]),"public JSON preserves boolean fields");
        NSMutableDictionary *invalid=[raw mutableCopy];invalid[@"historyRejected"]=@0;
        check(!axs_cachekeeper_operation_history_validate(invalid,@"image"),"numeric zero cannot masquerade as a boolean");
        printf("PASS: operation-schema %s\n",argv[1]);
    }
    return 0;
}
