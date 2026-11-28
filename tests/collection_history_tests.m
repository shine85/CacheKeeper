#import <Foundation/Foundation.h>
#import "../AxsCacheKeeperCollectionHistory.h"
#import "../AxsCacheKeeperCollectionSession.h"
#import "../AxsCacheKeeperCollectionReturn.h"
#import "../AxsCacheKeeperImageCollection.h"
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>

static void check(BOOL value,const char *message) {if(!value){fprintf(stderr,"FAIL: collection-history: %s\n",message);exit(1);}}
static void save(id value,NSString *path) {
    NSError *error=nil;NSData *data=[NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    check(data && [data writeToFile:path options:NSDataWritingAtomic error:&error],"fixture writes actual binary plist");
}
static NSDictionary *row(AxsCacheKeeperCollectionHistory *history,NSString *identifier) {
    NSError *error=nil;NSArray *rows=[history records:&error];check(rows && !error,"history enumerates without changing sessions");
    for(NSDictionary *record in rows)if([record[@"sessionID"] isEqual:identifier])return record;return nil;
}
static AxsCacheKeeperCollectionSession *session(NSString *directory) {
    NSError *error=nil;AxsCacheKeeperCollectionSession *value=[AxsCacheKeeperCollectionSession createNewSessionInDirectory:directory error:&error];
    check(value && !error,"create production session");return value;
}
static NSString *imagePath(NSString *directory,NSString *identifier) {return [directory stringByAppendingPathComponent:[identifier stringByAppendingString:@".image.plist"]];}
static NSDictionary *request(NSString *identifier,NSString *phase,NSTimeInterval expires) {
    return @{@"schemaVersion":@1,@"sessionID":identifier,@"requestID":@"11111111111111111111111111111111",@"bundle":@"com.baidu.netdisk",
        @"phase":phase,@"step":[phase isEqual:@"restore"] ? @4 : @1,@"issuedAt":@(expires-300),@"expiresAt":@(expires),
        @"baselineSHA256":[@"" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0],@"processFirstObserved":@1};
}
static NSDictionary *imageDocument(NSString *identifier,NSString *state,NSDictionary *lease) {
    NSMutableDictionary *value=[@{@"schemaVersion":@1,@"sessionID":identifier,@"state":state,@"events":@[]} mutableCopy];
    if(lease)value[@"request"]=lease;
    if([state isEqual:@"complete"])value[@"restoration"]=@{@"state":@"hostConfirmed",@"receipt":@{@"pending":@0,@"imageCollection":@{
        @"sessionID":identifier,@"requestID":lease[@"requestID"],@"phase":@"restore",@"disposition":@"restored"}}};
    return value;
}
int main(int argc,const char **argv) {@autoreleasepool {
    check(argc==2,"isolated directory argument");NSString *base=[NSString stringWithUTF8String:argv[1]],*directory=[base stringByAppendingPathComponent:@"collectionSessions"];
    check([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL],"isolated test directory");
    AxsCacheKeeperCollectionHistory *history=[[AxsCacheKeeperCollectionHistory alloc] initWithDirectory:directory];NSError *error=nil;
    AxsCacheKeeperCollectionSession *a=session(directory),*other=session(directory);
    NSString *image=imagePath(directory,a.sessionID);save(imageDocument(a.sessionID,@"skipped",nil),image);
    NSString *external=[base stringByAppendingPathComponent:@"external-report.json"];check([[@"saved external report" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:external atomically:YES],"external exported copy fixture");
    NSString *unknown=[directory stringByAppendingPathComponent:@"do-not-delete.plist"];save(@{@"unrelated":@YES},unknown);
    NSDictionary *selected=row(history,a.sessionID);check([selected[@"deletable"] boolValue],"inactive session pair can be selected");
    NSDictionary *cancelled=[history deleteRecord:selected confirmed:NO error:&error];
    check([cancelled[@"state"] isEqual:@"rejected"] && error.code==ECANCELED && [NSFileManager.defaultManager fileExistsAtPath:a.storagePath] && [NSFileManager.defaultManager fileExistsAtPath:image],"cancel confirmation preserves both records");
    NSDictionary *deleted=[history deleteRecord:selected confirmed:YES error:&error];
    check([deleted[@"state"] isEqual:@"deleted"] && !error && [deleted[@"removedFiles"] count]==2 && ![NSFileManager.defaultManager fileExistsAtPath:a.storagePath] && ![NSFileManager.defaultManager fileExistsAtPath:image],"confirmed deletion removes only the selected pair");
    check(row(history,a.sessionID)==nil && row(history,other.sessionID)!=nil,"list refresh removes only deleted session");
    check([NSFileManager.defaultManager fileExistsAtPath:external] && [NSFileManager.defaultManager fileExistsAtPath:unknown],"external export and unknown file remain");

    AxsCacheKeeperCollectionSession *running=session(directory);check([running beginPhase:@"hostPreflight" error:&error],"active host fixture");
    NSData *runningBytes=[NSData dataWithContentsOfFile:running.storagePath];NSDictionary *active=row(history,running.sessionID);
    check(![active[@"deletable"] boolValue] && [[NSData dataWithContentsOfFile:running.storagePath] isEqual:runningBytes],"listing never recovers active phase into deletable interruption");
    check([[history deleteRecord:active confirmed:YES error:&error][@"state"] isEqual:@"rejected"] && error.code==EBUSY,"running phase rejected at delete time");
    AxsCacheKeeperCollectionSession *capacity=session(directory);check([capacity beginCapacityWithEpoch:NSUUID.UUID.UUIDString error:&error],"running capacity fixture");
    check(![row(history,capacity.sessionID)[@"deletable"] boolValue],"capacity request is protected without opening or interrupting its session");
    AxsCacheKeeperCollectionReturn *position=[[AxsCacheKeeperCollectionReturn alloc] initWithDirectory:directory];
    NSDictionary *intent=[position selectSession:other page:@"guided" error:&error];check(intent!=nil,"active navigation fixture");
    check(![row(history,other.sessionID)[@"deletable"] boolValue],"active return position protects otherwise idle session");
    check([position clear:intent error:&error],"explicit exit clears matching position");
    check([row(history,other.sessionID)[@"deletable"] boolValue],"explicitly exited idle session is removable");

    AxsCacheKeeperCollectionSession *changed=session(directory);NSDictionary *stale=row(history,changed.sessionID);
    check([changed blockCapability:@"com.test" capability:@"fixture" error:&error],"session changes after confirmation row");
    check([[history deleteRecord:stale confirmed:YES error:&error][@"state"] isEqual:@"rejected"] && error.code==ESTALE && [NSFileManager.defaultManager fileExistsAtPath:changed.storagePath],"stale confirmation cannot remove changed document");
    NSMutableDictionary *traversal=[stale mutableCopy];traversal[@"file"]=@"../external-report.json";
    check([[history deleteRecord:traversal confirmed:YES error:&error][@"state"] isEqual:@"rejected"] && [NSFileManager.defaultManager fileExistsAtPath:external],"caller cannot supply a traversal filename");

    AxsCacheKeeperCollectionSession *leased=session(directory);NSString *leasedImage=imagePath(directory,leased.sessionID);NSTimeInterval now=NSDate.date.timeIntervalSince1970;
    save(imageDocument(leased.sessionID,@"awaitingHost",request(leased.sessionID,@"prevent",now+300)),leasedImage);
    check(![row(history,leased.sessionID)[@"deletable"] boolValue],"active image lease blocks deletion");
    save(imageDocument(leased.sessionID,@"awaitingHost",request(leased.sessionID,@"restore",now+300)),leasedImage);
    check(![row(history,leased.sessionID)[@"deletable"] boolValue],"restore request is not restoration confirmation");
    NSMutableDictionary *malformed=[imageDocument(leased.sessionID,@"complete",request(leased.sessionID,@"restore",now+300)) mutableCopy];malformed[@"restoration"]=@"invalid";save(malformed,leasedImage);
    check(![row(history,leased.sessionID)[@"deletable"] boolValue],"malformed nested restoration rejects without crashing");
    save(imageDocument(leased.sessionID,@"restorationUnconfirmed",request(leased.sessionID,@"restore",now-1)),leasedImage);
    check([row(history,leased.sessionID)[@"deletable"] boolValue],"expired explicit restoration-unconfirmed terminal is removable");
    NSString *shared=[base stringByAppendingPathComponent:@"imageCollectionRequest.plist"];
    save(request(leased.sessionID,@"prevent",now+300),shared);
    check(![row(history,leased.sessionID)[@"deletable"] boolValue],"newer shared active lease protects old terminal document");
    check(unlink(shared.fileSystemRepresentation)==0,"remove isolated shared-request fixture");
    save(imageDocument(leased.sessionID,@"complete",request(leased.sessionID,@"restore",now+300)),leasedImage);
    check([row(history,leased.sessionID)[@"deletable"] boolValue],"host-confirmed restoration is terminal before restore request expiry");
    NSDictionary *beforeMissing=row(history,leased.sessionID);check(unlink(leasedImage.fileSystemRepresentation)==0,"remove isolated image fixture");
    check([[history deleteRecord:beforeMissing confirmed:YES error:&error][@"state"] isEqual:@"rejected"] && error.code==ESTALE && [NSFileManager.defaultManager fileExistsAtPath:leased.storagePath],"missing confirmed companion rejects before changing main file");
    AxsCacheKeeperCollectionSession *missing=session(directory);NSString *orphan=imagePath(directory,missing.sessionID);save(imageDocument(missing.sessionID,@"skipped",nil),orphan);
    NSDictionary *missingRow=row(history,missing.sessionID);check(unlink(missing.storagePath.fileSystemRepresentation)==0,"remove isolated primary fixture");
    check([[history deleteRecord:missingRow confirmed:YES error:&error][@"state"] isEqual:@"rejected"] && error.code==ENOENT && [NSFileManager.defaultManager fileExistsAtPath:orphan],"missing primary never authorizes deleting remaining companion");

    AxsCacheKeeperCollectionSession *linked=session(directory);NSString *linkedImage=imagePath(directory,linked.sessionID);
    check(symlink(external.fileSystemRepresentation,linkedImage.fileSystemRepresentation)==0,"external symlink fixture");
    check(![row(history,linked.sessionID)[@"deletable"] boolValue],"symlink image companion cannot be selected");
    check([[history deleteRecord:row(history,linked.sessionID) confirmed:YES error:&error][@"state"] isEqual:@"rejected"] && [NSFileManager.defaultManager fileExistsAtPath:external],"symlink deletion cannot reach exported file");
    NSString *fake=[directory stringByAppendingPathComponent:[NSUUID.UUID.UUIDString.lowercaseString stringByAppendingPathExtension:@"plist"]];
    check(symlink(other.storagePath.fileSystemRepresentation,fake.fileSystemRepresentation)==0,"main symlink fixture");
    NSArray *rows=[history records:&error];for(NSDictionary *entry in rows)check(![entry[@"file"] isEqual:fake.lastPathComponent],"main symlinks never appear as own sessions");

    AxsCacheKeeperCollectionSession *duplicate=session(directory);NSString *duplicateImage=imagePath(directory,duplicate.sessionID);save(imageDocument(duplicate.sessionID,@"skipped",nil),duplicateImage);
    NSDictionary *unique=row(history,duplicate.sessionID);NSString *copy=[directory stringByAppendingPathComponent:[NSUUID.UUID.UUIDString.lowercaseString stringByAppendingPathExtension:@"plist"]];
    check([[NSData dataWithContentsOfFile:duplicate.storagePath] writeToFile:copy atomically:YES],"duplicate identity fixture");
    check(![row(history,duplicate.sessionID)[@"deletable"] boolValue],"two primary records cannot share a deletable image identity");
    check([[history deleteRecord:unique confirmed:YES error:&error][@"state"] isEqual:@"rejected"] && [NSFileManager.defaultManager fileExistsAtPath:duplicateImage],"duplicate introduced after confirmation keeps shared image");
    NSString *aliasParent=[base stringByAppendingPathComponent:@"alias"];check([NSFileManager.defaultManager createDirectoryAtPath:aliasParent withIntermediateDirectories:NO attributes:nil error:NULL],"directory alias fixture parent");
    NSString *alias=[aliasParent stringByAppendingPathComponent:@"collectionSessions"];check(symlink(directory.fileSystemRepresentation,alias.fileSystemRepresentation)==0,"directory symlink fixture");
    AxsCacheKeeperCollectionHistory *aliased=[[AxsCacheKeeperCollectionHistory alloc] initWithDirectory:alias];check([aliased records:&error]==nil && error,"store directory symlink refuses traversal");

    AxsCacheKeeperCollectionSession *partial=session(directory);NSString *partialImage=imagePath(directory,partial.sessionID);save(imageDocument(partial.sessionID,@"skipped",nil),partialImage);
    check(chflags(partial.storagePath.fileSystemRepresentation,UF_IMMUTABLE)==0,"make actual selected main unlink fail");
    NSDictionary *result=[history deleteRecord:row(history,partial.sessionID) confirmed:YES error:&error];
    BOOL partialMainExists=[NSFileManager.defaultManager fileExistsAtPath:partial.storagePath],partialImageExists=[NSFileManager.defaultManager fileExistsAtPath:partialImage];
    check(chflags(partial.storagePath.fileSystemRepresentation,0)==0,"release isolated immutable fixture before checking outcome");
    check([result[@"state"] isEqual:@"partial"] && error && [result[@"removedFiles"] isEqual:@[partialImage.lastPathComponent]] && [result[@"remainingFiles"] isEqual:@[partial.storagePath.lastPathComponent]],"real second-file failure reports partial deletion precisely");
    check(partialMainExists && !partialImageExists,"partial result agrees with actual filesystem");
    check([[history deleteRecord:row(history,partial.sessionID) confirmed:YES error:&error][@"state"] isEqual:@"deleted"] && !error,"remaining primary can be explicitly retried after partial failure");
    check([NSFileManager.defaultManager fileExistsAtPath:other.storagePath],"other session survives all cases");
    printf("PASS: collection history confirmed pair deletion, active lease refusal, exact revisions, symlink isolation and real partial failure\n");
}return 0;}
