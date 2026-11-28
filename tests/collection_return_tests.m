#import <Foundation/Foundation.h>
#import "../AxsCacheKeeperCollectionSession.h"
#import "../AxsCacheKeeperCollectionReturn.h"
static void check(BOOL value,const char *message) {if(!value){fprintf(stderr,"FAIL: collection-return: %s\n",message);exit(1);}}
int main(int argc,const char **argv) {@autoreleasepool {
    check(argc==2,"isolated directory");NSString *directory=[NSString stringWithUTF8String:argv[1]];NSError *error=nil;
    AxsCacheKeeperCollectionSession *a=[AxsCacheKeeperCollectionSession createNewSessionInDirectory:directory error:&error];
    AxsCacheKeeperCollectionSession *b=[AxsCacheKeeperCollectionSession createNewSessionInDirectory:directory error:&error];
    AxsCacheKeeperCollectionReturn *store=[[AxsCacheKeeperCollectionReturn alloc] initWithDirectory:directory];
    NSDictionary *first=[store selectSession:a page:@"guided" error:&error];check(first && !error,"explicit entry persists original session");
    AxsCacheKeeperCollectionReturn *reopened=[[AxsCacheKeeperCollectionReturn alloc] initWithDirectory:directory];
    check([[reopened read:&error] isEqual:first],"recreated owner reads same durable intent");
    NSDictionary *image=[reopened update:first page:@"image" error:&error];check(image && ![image[@"token"] isEqual:first[@"token"]],"page change replaces revision");
    check(![store clear:first error:&error] && error.code==ESTALE,"old page cannot clear new route");
    check(![store openSession:image error:&error] && error.code==ENOENT,"missing image session is not invented by restoration");
    check([a imageCollectionSession:&error]!=nil,"explicit image entry creates its own durable session");
    check([[store openSession:image error:&error].sessionID isEqual:a.sessionID],"relative basename binds original session");
    NSDictionary *second=[store selectSession:b page:@"host" error:&error];check(second!=nil,"explicit second session replaces route");
    check(![reopened clear:image error:&error] && error.code==ESTALE,"late old session callback cannot clear chosen new session");
    check([reopened clear:second error:&error] && ![store read:&error] && !error,"clear persists released state without deleting session files");
    check([store isReleasedIntent:second] && ![store isReleasedIntent:image],"another session release never returns ownership to stale intent");
    NSDictionary *raw=@{@"schemaVersion":@1,@"token":@"bad",@"sessionID":a.sessionID,@"file":@"../outside.plist",@"page":@"image"};
    NSString *path=[directory stringByAppendingPathComponent:@"return-position.plist"];
    check([raw writeToFile:path atomically:YES],"write malformed route fixture");
    check(![store read:&error] && error.code==EINVAL,"bad route cannot escape or pick another session");
    check(![store selectSession:a page:@"image" error:&error] && error.code==EINVAL,"invalid existing record is not silently overwritten");
    printf("PASS: collection return durable identity, token isolation and invalid input\n");
}return 0;}
