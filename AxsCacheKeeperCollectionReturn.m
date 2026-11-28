#import "AxsCacheKeeperCollectionReturn.h"
#import "AxsCacheKeeperCollectionSession.h"
#import "AxsCacheKeeperImageCollection.h"

static BOOL AxsReturnError(NSError **error,NSInteger code) {if(error)*error=[NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];return NO;}
static BOOL AxsReturnPage(id page) {return [@[@"guided",@"host",@"image"] containsObject:page];}
static BOOL AxsReturnValid(id value) {
    if (![value isKindOfClass:NSDictionary.class] || ![value[@"schemaVersion"] isEqual:@1]) return NO;
    if ([value[@"released"] isEqual:@YES]) return [value count]==2 || ([value count]==3 && axs_cachekeeper_image_collection_id(value[@"token"]));
    NSString *file=value[@"file"];
    return [value count]==5 && axs_cachekeeper_image_collection_id(value[@"token"]) && axs_cachekeeper_image_collection_id(value[@"sessionID"]) &&
        [file isKindOfClass:NSString.class] && [file isEqual:file.lastPathComponent] && [file.pathExtension isEqual:@"plist"] && AxsReturnPage(value[@"page"]);
}
@interface AxsCacheKeeperCollectionReturn ()
@property(nonatomic,copy) NSString *directory,*path;
@end
@implementation AxsCacheKeeperCollectionReturn
- (instancetype)initWithDirectory:(NSString *)directory {if(!(self=[super init]))return nil;_directory=[directory copy];_path=[directory stringByAppendingPathComponent:@"return-position.plist"];return self;}
- (NSDictionary *)read:(NSError **)error {
    if(error)*error=nil;
    if (![NSFileManager.defaultManager fileExistsAtPath:self.path]) return nil;
    NSDictionary *raw=axs_cachekeeper_capacity_read_plist(self.directory,@"return-position.plist",4096,error);
    if(!raw)return nil;if(!AxsReturnValid(raw)){AxsReturnError(error,EINVAL);return nil;}
    return raw[@"released"] ? nil : raw;
}
- (BOOL)axs_write:(NSDictionary *)value error:(NSError **)error {
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    return data && [data writeToFile:self.path options:NSDataWritingAtomic error:error];
}
- (NSDictionary *)selectSession:(AxsCacheKeeperCollectionSession *)session page:(NSString *)page error:(NSError **)error {
    @synchronized(AxsCacheKeeperCollectionReturn.class) {
        NSError *readError=nil;[self read:&readError];if(readError){if(error)*error=readError;return nil;}
        NSString *path=session.storagePath;
        if(!AxsReturnPage(page) || ![[path stringByDeletingLastPathComponent] isEqual:self.directory] || session.reportProjection[@"phases"][@"export"]){AxsReturnError(error,EINVAL);return nil;}
        NSDictionary *value=@{@"schemaVersion":@1,@"sessionID":session.sessionID,@"file":path.lastPathComponent,@"page":page,
            @"token":[NSUUID.UUID.UUIDString.lowercaseString stringByReplacingOccurrencesOfString:@"-" withString:@""]};
        return [self axs_write:value error:error] ? value : nil;
    }
}
- (NSDictionary *)update:(NSDictionary *)expected page:(NSString *)page error:(NSError **)error {
    @synchronized(AxsCacheKeeperCollectionReturn.class) {
        NSError *failure=nil;NSDictionary *current=[self read:&failure];if(failure){if(error)*error=failure;return nil;}if(![current isEqual:expected]){AxsReturnError(error,ESTALE);return nil;}
        if(!AxsReturnPage(page)){AxsReturnError(error,EINVAL);return nil;}
        NSMutableDictionary *next=[current mutableCopy];next[@"page"]=page;next[@"token"]=[NSUUID.UUID.UUIDString.lowercaseString stringByReplacingOccurrencesOfString:@"-" withString:@""];
        return [self axs_write:next error:error] ? next : nil;
    }
}
- (BOOL)clear:(NSDictionary *)expected error:(NSError **)error {
    @synchronized(AxsCacheKeeperCollectionReturn.class) {
        NSError *failure=nil;NSDictionary *current=[self read:&failure];if(failure){if(error)*error=failure;return NO;}
        if(![current isEqual:expected])return AxsReturnError(error,ESTALE);
        return [self axs_write:@{@"schemaVersion":@1,@"released":@YES,@"token":expected[@"token"]} error:error];
    }
}
- (BOOL)isReleasedIntent:(NSDictionary *)intent {
    NSDictionary *raw=axs_cachekeeper_capacity_read_plist(self.directory,@"return-position.plist",4096,NULL);
    return AxsReturnValid(raw) && [raw[@"released"] isEqual:@YES] && [raw[@"token"] isEqual:intent[@"token"]];
}
- (AxsCacheKeeperCollectionSession *)openSession:(NSDictionary *)intent error:(NSError **)error {
    if(!AxsReturnValid(intent) || intent[@"released"]){AxsReturnError(error,EINVAL);return nil;}
    AxsCacheKeeperCollectionSession *session=[AxsCacheKeeperCollectionSession openSessionAtPath:[self.directory stringByAppendingPathComponent:intent[@"file"]] error:error];
    if(![session.sessionID isEqual:intent[@"sessionID"]] || session.reportProjection[@"phases"][@"export"]){AxsReturnError(error,ESTALE);return nil;}
    if([intent[@"page"] isEqual:@"image"]){
        NSString *folder=[self.directory.lastPathComponent isEqual:@"collectionSessions"] ? self.directory.stringByDeletingLastPathComponent : self.directory;
        NSString *image=[[folder stringByAppendingPathComponent:@"collectionSessions"] stringByAppendingPathComponent:[session.sessionID stringByAppendingString:@".image.plist"]];
        if(![NSFileManager.defaultManager fileExistsAtPath:image]){AxsReturnError(error,ENOENT);return nil;}
    }
    return session;
}
@end
