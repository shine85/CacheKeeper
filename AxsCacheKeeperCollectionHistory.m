#import "AxsCacheKeeperCollectionHistory.h"
#import "AxsCacheKeeperCollectionReturn.h"
#import "AxsCacheKeeperImageCollection.h"
#include <sys/stat.h>
#include <fcntl.h>
#include <dirent.h>
#include <unistd.h>
#include <errno.h>

static const off_t AxsCacheKeeperHistoryMaximumRecordBytes=128*1024*1024;
static BOOL AxsCacheKeeperHistoryError(NSError **error,NSInteger code,NSString *reason) {
    if(error)*error=[NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey:reason}];return NO;
}
static BOOL AxsCacheKeeperHistoryFilename(id value) {
    if(![value isKindOfClass:NSString.class] || ![value isEqual:[value lastPathComponent]] || ![[value pathExtension] isEqual:@"plist"])return NO;
    NSString *stem=[value stringByDeletingPathExtension];NSUUID *uuid=[[NSUUID alloc] initWithUUIDString:stem];
    return uuid && [uuid.UUIDString.lowercaseString isEqual:stem];
}
static BOOL AxsCacheKeeperHistorySameFile(struct stat a,struct stat b) {
    return a.st_dev==b.st_dev && a.st_ino==b.st_ino && a.st_size==b.st_size && a.st_nlink==b.st_nlink &&
        a.st_mtimespec.tv_sec==b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec==b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec==b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec==b.st_ctimespec.tv_nsec;
}
// A pinned directory and O_NOFOLLOW keep filenames from becoming paths outside this session store.
static NSDictionary *AxsCacheKeeperHistoryRead(int directory,NSString *file,BOOL optional,NSError **error) {
    int fd=openat(directory,file.fileSystemRepresentation,O_RDONLY|O_CLOEXEC|O_NOFOLLOW);
    if(fd<0){if(optional && errno==ENOENT)return @{@"revision":@"missing"};AxsCacheKeeperHistoryError(error,errno,@"recordReadFailed");return nil;}
    struct stat before,after;int code=0;
    if(fstat(fd,&before)!=0)code=errno;
    else if(!S_ISREG(before.st_mode) || before.st_nlink!=1)code=EINVAL;
    else if(before.st_size<1 || before.st_size>AxsCacheKeeperHistoryMaximumRecordBytes)code=EFBIG;
    NSMutableData *data=code ? nil : [NSMutableData dataWithLength:(NSUInteger)before.st_size];
    NSUInteger offset=0;
    while(!code && offset<data.length){
        ssize_t count=read(fd,(char *)data.mutableBytes+offset,data.length-offset);
        if(count<0){if(errno==EINTR)continue;code=errno;}
        else if(!count)code=ESTALE;else offset+=(NSUInteger)count;
    }
    if(!code && fstat(fd,&after)!=0)code=errno;
    if(!code && !AxsCacheKeeperHistorySameFile(before,after))code=ESTALE;
    struct stat named;
    if(!code && fstatat(directory,file.fileSystemRepresentation,&named,AT_SYMLINK_NOFOLLOW)!=0)code=errno;
    if(!code && (!S_ISREG(named.st_mode) || !AxsCacheKeeperHistorySameFile(before,named)))code=ESTALE;
    close(fd);
    if(code){AxsCacheKeeperHistoryError(error,code,@"recordReadFailed");return nil;}
    id document=[NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:error];
    if(![document isKindOfClass:NSDictionary.class]){AxsCacheKeeperHistoryError(error,EINVAL,@"recordInvalid");return nil;}
    NSString *revision=[NSString stringWithFormat:@"%llu:%llu:%@",(unsigned long long)before.st_dev,(unsigned long long)before.st_ino,axs_cachekeeper_image_collection_sha(data)];
    return @{@"document":document,@"revision":revision};
}
static BOOL AxsCacheKeeperHistoryMain(NSDictionary *document) {
    if(![document[@"schemaVersion"] isEqual:@1] || !axs_cachekeeper_image_collection_id(document[@"sessionID"]) ||
        ![document[@"createdAt"] isKindOfClass:NSNumber.class] || !isfinite([document[@"createdAt"] doubleValue]) ||
        ![document[@"phases"] isKindOfClass:NSDictionary.class] ||
        ![document[@"events"] isKindOfClass:NSArray.class] || ![document[@"blockedCapabilities"] isKindOfClass:NSArray.class])return NO;
    for(NSString *phase in document[@"phases"]){
        NSDictionary *entry=document[@"phases"][phase];
        if(![@[@"hostPreflight",@"capacity",@"diagnostics",@"export"] containsObject:phase] || ![entry isKindOfClass:NSDictionary.class] ||
            ![@[@"pending",@"running",@"complete",@"partial",@"failed",@"interrupted",@"cancelled",@"blockedByCapability"] containsObject:entry[@"state"]])return NO;
    }
    return YES;
}
static BOOL AxsCacheKeeperHistoryRestored(NSDictionary *image) {
    if(![image isKindOfClass:NSDictionary.class])return NO;
    NSDictionary *lease=image[@"request"],*restoration=image[@"restoration"];
    if(![lease isKindOfClass:NSDictionary.class] || ![restoration isKindOfClass:NSDictionary.class])return NO;
    NSDictionary *receipt=restoration[@"receipt"];
    if(![receipt isKindOfClass:NSDictionary.class])return NO;
    NSDictionary *ack=receipt[@"imageCollection"];if(![ack isKindOfClass:NSDictionary.class])return NO;
    return [image[@"state"] isEqual:@"complete"] && [lease[@"phase"] isEqual:@"restore"] &&
        [restoration[@"state"] isEqual:@"hostConfirmed"] && [ack[@"sessionID"] isEqual:image[@"sessionID"]] &&
        [ack[@"requestID"] isEqual:lease[@"requestID"]] && [ack[@"phase"] isEqual:@"restore"] &&
        [ack[@"disposition"] isEqual:@"restored"] && [receipt[@"pending"] isEqual:@0];
}
static NSString *AxsCacheKeeperHistoryImageReason(NSDictionary *image,NSString *identifier,NSTimeInterval now) {
    if(!image)return nil;
    if(![image[@"schemaVersion"] isEqual:@1] || ![image[@"sessionID"] isEqual:identifier] || ![image[@"events"] isKindOfClass:NSArray.class])return @"invalidImage";
    NSDictionary *lease=image[@"request"];NSString *state=image[@"state"];
    if(lease && (!axs_cachekeeper_image_collection_request(lease) || ![lease[@"sessionID"] isEqual:identifier]))return @"invalidImage";
    if([@[@"idle",@"skipped"] containsObject:state] && !lease)return nil;
    if(AxsCacheKeeperHistoryRestored(image))return nil;
    if([state isEqual:@"restorationUnconfirmed"] && [lease[@"phase"] isEqual:@"restore"] && [lease[@"expiresAt"] doubleValue]<=now)return nil;
    return @"imageNotTerminal";
}
static BOOL AxsCacheKeeperHistoryReturnValid(NSDictionary *value) {
    if(![value[@"schemaVersion"] isEqual:@1])return NO;
    if([value[@"released"] isEqual:@YES])return value.count==2 || (value.count==3 && axs_cachekeeper_image_collection_id(value[@"token"]));
    return value.count==5 && axs_cachekeeper_image_collection_id(value[@"token"]) && axs_cachekeeper_image_collection_id(value[@"sessionID"]) &&
        AxsCacheKeeperHistoryFilename(value[@"file"]) && [@[@"guided",@"host",@"image"] containsObject:value[@"page"]];
}

@interface AxsCacheKeeperCollectionHistory ()
@property(nonatomic,copy) NSString *directory;
@end
@implementation AxsCacheKeeperCollectionHistory
- (instancetype)initWithDirectory:(NSString *)directory {if(!(self=[super init]))return nil;_directory=[directory copy];return self;}
- (int)axs_cachekeeper_openDirectory:(NSError **)error {
    if(!self.directory.isAbsolutePath || [self.directory.pathComponents containsObject:@".."] || ![self.directory.lastPathComponent isEqual:@"collectionSessions"]){AxsCacheKeeperHistoryError(error,EINVAL,@"invalidDirectory");return -1;}
    int directory=open(self.directory.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);
    if(directory<0)AxsCacheKeeperHistoryError(error,errno,@"directoryUnavailable");return directory;
}
- (NSDictionary *)axs_cachekeeper_record:(NSString *)file directory:(int)directory error:(NSError **)error {
    NSDictionary *main=AxsCacheKeeperHistoryRead(directory,file,NO,error),*document=main[@"document"];
    if(!main)return nil;
    if(!AxsCacheKeeperHistoryMain(document)){AxsCacheKeeperHistoryError(error,EINVAL,@"unknownRecord");return nil;}
    NSString *identifier=document[@"sessionID"],*imageFile=[identifier stringByAppendingString:@".image.plist"];
    NSError *imageError=nil;NSDictionary *image=AxsCacheKeeperHistoryRead(directory,imageFile,YES,&imageError);
    NSString *reason=imageError ? @"imageUnavailable" : AxsCacheKeeperHistoryImageReason(image[@"document"],identifier,NSDate.date.timeIntervalSince1970);
    NSString *state=@"idle";
    for(NSString *phase in @[@"hostPreflight",@"capacity",@"diagnostics",@"export"]){
        NSString *current=document[@"phases"][phase][@"state"];if(current)state=current;
        if([@[@"running",@"pending"] containsObject:current])reason=@"phaseActive";
    }
    NSError *positionError=nil;NSDictionary *position=AxsCacheKeeperHistoryRead(directory,@"return-position.plist",YES,&positionError)[@"document"];
    if(positionError || (position && !AxsCacheKeeperHistoryReturnValid(position)))reason=@"returnUnavailable";
    else if([position[@"sessionID"] isEqual:identifier] || [position[@"file"] isEqual:file])reason=@"activeReturn";
    int parent=openat(directory,"..",O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);
    NSError *requestError=nil;NSDictionary *shared=parent<0 ? nil : AxsCacheKeeperHistoryRead(parent,@"imageCollectionRequest.plist",YES,&requestError)[@"document"];
    if(parent>=0)close(parent);
    if(parent<0 || requestError || (shared && !axs_cachekeeper_image_collection_request(shared)))reason=@"requestUnavailable";
    else if([shared[@"sessionID"] isEqual:identifier] && [shared[@"expiresAt"] doubleValue]>NSDate.date.timeIntervalSince1970 &&
        !(AxsCacheKeeperHistoryRestored(image[@"document"]) && [shared[@"phase"] isEqual:@"restore"] && [shared[@"requestID"] isEqual:image[@"document"][@"request"][@"requestID"]]))reason=@"imageLeaseActive";
    NSDictionary *revision=@{@"main":main[@"revision"],@"image":image[@"revision"] ?: @"unavailable"};
    return @{@"file":file,@"sessionID":identifier,@"createdAt":document[@"createdAt"],@"state":state,
        @"deletable":@(!reason),@"reason":reason ?: @"none",@"revision":revision,@"imagePresent":@(image[@"document"]!=nil)};
}
- (NSArray<NSDictionary *> *)records:(NSError **)error {
    if(error)*error=nil;int directory=[self axs_cachekeeper_openDirectory:error];
    if(directory<0){if(error && (*error).code==ENOENT){*error=nil;return @[];}return nil;}
    int enumeration=dup(directory);DIR *stream=enumeration<0 ? NULL : fdopendir(enumeration);
    if(!stream){int code=errno;if(enumeration>=0)close(enumeration);close(directory);AxsCacheKeeperHistoryError(error,code,@"directoryUnavailable");return nil;}
    NSMutableArray *rows=[NSMutableArray new];struct dirent *entry;int enumerationError=0;
    while(YES)@autoreleasepool {
        errno=0;entry=readdir(stream);if(!entry){enumerationError=errno;break;}
        NSString *file=[NSString stringWithUTF8String:entry->d_name];if(!AxsCacheKeeperHistoryFilename(file))continue;
        struct stat info;if(fstatat(directory,entry->d_name,&info,AT_SYMLINK_NOFOLLOW)!=0 || !S_ISREG(info.st_mode) || info.st_nlink!=1)continue;
        NSDictionary *record=[self axs_cachekeeper_record:file directory:directory error:NULL];if(record)[rows addObject:record];
    }
    closedir(stream);close(directory);
    if(enumerationError){AxsCacheKeeperHistoryError(error,enumerationError,@"directoryReadFailed");return nil;}
    NSCountedSet *identifiers=[NSCountedSet new];for(NSDictionary *record in rows)[identifiers addObject:record[@"sessionID"]];
    for(NSUInteger index=0;index<rows.count;index++)if([identifiers countForObject:rows[index][@"sessionID"]]>1){
        NSMutableDictionary *record=[rows[index] mutableCopy];record[@"deletable"]=@NO;record[@"reason"]=@"duplicateSession";rows[index]=record;
    }
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [b[@"createdAt"] compare:a[@"createdAt"]];}];return rows;
}
- (NSDictionary *)axs_cachekeeper_result:(NSString *)state reason:(NSString *)reason removed:(NSArray *)removed remaining:(NSArray *)remaining code:(NSInteger)code error:(NSError **)error {
    NSDictionary *result=@{@"state":state,@"reason":reason,@"removedFiles":removed,@"remainingFiles":remaining};
    if(error)*error=code ? [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey:reason,@"deletionResult":result}] : nil;
    return result;
}
- (NSDictionary *)deleteRecord:(NSDictionary *)expected confirmed:(BOOL)confirmed error:(NSError **)error {
    if(error)*error=nil;
    if(!confirmed)return [self axs_cachekeeper_result:@"rejected" reason:@"notConfirmed" removed:@[] remaining:@[] code:ECANCELED error:error];
    if(![expected isKindOfClass:NSDictionary.class] || !AxsCacheKeeperHistoryFilename(expected[@"file"]) ||
        !axs_cachekeeper_image_collection_id(expected[@"sessionID"]) || ![expected[@"revision"] isKindOfClass:NSDictionary.class])
        return [self axs_cachekeeper_result:@"rejected" reason:@"invalidRecord" removed:@[] remaining:@[] code:EINVAL error:error];
    // Match the UI return/image writers' locks; a new in-process authorization cannot race deletion.
    @synchronized(AxsCacheKeeperCollectionReturn.class){@synchronized(AxsCacheKeeperImageCollectionSession.class){@synchronized(AxsCacheKeeperCollectionHistory.class){
        NSError *failure=nil;int directory=[self axs_cachekeeper_openDirectory:&failure];
        NSDictionary *current=directory<0 ? nil : [self axs_cachekeeper_record:expected[@"file"] directory:directory error:&failure];
        NSMutableArray *files=[NSMutableArray arrayWithObject:expected[@"file"]];
        if([current[@"imagePresent"] boolValue])[files insertObject:[expected[@"sessionID"] stringByAppendingString:@".image.plist"] atIndex:0];
        NSString *reason=nil;NSInteger code=0;
        if(!current){reason=@"recordUnavailable";code=failure.code ?: ENOENT;}
        else if(![current[@"sessionID"] isEqual:expected[@"sessionID"]] || ![current[@"revision"] isEqual:expected[@"revision"]]){reason=@"recordChanged";code=ESTALE;}
        else if(![current[@"deletable"] boolValue]){reason=current[@"reason"];code=EBUSY;}
        if(!code){
            NSArray *rows=[self records:&failure];NSUInteger matches=0;
            for(NSDictionary *record in rows)if([record[@"sessionID"] isEqual:current[@"sessionID"]])matches++;
            if(!rows || matches!=1){reason=rows ? @"duplicateSession" : @"directoryReadFailed";code=failure.code ?: EBUSY;}
        }
        if(code){if(directory>=0)close(directory);return [self axs_cachekeeper_result:@"rejected" reason:reason removed:@[] remaining:files code:code error:error];}
        NSMutableArray *removed=[NSMutableArray new],*remaining=[files mutableCopy];
        for(NSString *file in files){
            NSDictionary *fresh=AxsCacheKeeperHistoryRead(directory,file,NO,&failure);
            NSString *key=[file isEqual:expected[@"file"]] ? @"main" : @"image";
            if(!fresh || ![fresh[@"revision"] isEqual:current[@"revision"][key]]){code=failure.code ?: ESTALE;reason=@"recordChanged";break;}
            if(unlinkat(directory,file.fileSystemRepresentation,0)!=0){code=errno;reason=@"removeFailed";break;}
            [removed addObject:file];[remaining removeObject:file];
        }
        close(directory);
        return [self axs_cachekeeper_result:code ? (removed.count ? @"partial" : @"rejected") : @"deleted" reason:reason ?: @"none" removed:removed remaining:remaining code:code error:error];
    }}}
}
@end
