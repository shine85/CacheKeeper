#import "AxsCacheKeeperCollectionSession.h"
#import "AxsCacheKeeperCapacityStatus.h"
#import "AxsCacheKeeperHostEvidence.h"
#import "AxsCacheKeeperImageCollection.h"
#include <errno.h>
#include <CommonCrypto/CommonDigest.h>

static NSArray<NSString *> *axs_cachekeeper_collection_phases(void) {
    return @[@"hostPreflight",@"capacity",@"diagnostics",@"export"];
}

static NSMutableDictionary *axs_cachekeeper_collection_copy(NSDictionary *value) {
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    id copy=data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainers format:NULL error:NULL] : nil;
    return [copy isKindOfClass:NSMutableDictionary.class] ? copy : nil;
}

static NSString *axs_cachekeeper_collection_sha(NSData *data) {
    if (data.length>UINT32_MAX) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
    NSMutableString *value=[NSMutableString new];
    for (NSUInteger i=0;i<sizeof(digest);i++) [value appendFormat:@"%02x",digest[i]];
    return value;
}

static NSDictionary *axs_cachekeeper_collection_host(NSDictionary *value) {
    if (![value isKindOfClass:NSDictionary.class] || ![value[@"roundStartedAt"] isKindOfClass:NSNumber.class] ||
        !isfinite([value[@"roundStartedAt"] doubleValue]) || [value[@"roundStartedAt"] doubleValue]<1 ||
        ![value[@"apps"] isKindOfClass:NSArray.class] || [value[@"apps"] count]>5) return nil;
    NSMutableArray *rows=[NSMutableArray new];NSMutableSet *bundles=[NSMutableSet new];BOOL complete=[value[@"apps"] count]==5;
    for (NSDictionary *row in value[@"apps"]) {
        if (![row isKindOfClass:NSDictionary.class] || !axs_cachekeeper_bundle_id(row[@"bundle"]) || [bundles containsObject:row[@"bundle"]] ||
            ![@[@"observed",@"timedOut",@"cancelled",@"transportError",@"clockChanged",@"invalidResponse"] containsObject:row[@"state"]] ||
            ![@[@"succeeded",@"failed",@"notAttempted"] containsObject:row[@"saveState"]]) return nil;
        [bundles addObject:row[@"bundle"]];
        NSDictionary *receipt=row[@"receipt"] ? axs_cachekeeper_host_observed_projection(row[@"receipt"]) : nil;
        if (row[@"receipt"] && (!receipt || ![receipt[@"state"] isEqual:row[@"state"]])) return nil;
        NSNumber *updated=receipt[@"data"][@"updated"];
        BOOL fresh=updated && [updated doubleValue]>=[value[@"roundStartedAt"] doubleValue] &&
            [updated doubleValue]<=[receipt[@"updated"] doubleValue]+1;
        NSMutableDictionary *entry=[@{@"bundle":row[@"bundle"],@"state":row[@"state"],@"saveState":row[@"saveState"],
            @"transportTrust":@"unauthenticated",@"roundStartedAt":value[@"roundStartedAt"],
            @"observationFreshness":fresh ? @"currentRound" : updated ? @"stale" : @"notObserved"} mutableCopy];
        if (receipt) entry[@"receipt"]=receipt;
        if (updated) entry[@"sourceUpdated"]=updated;
        entry[@"multipleResponders"]=receipt[@"multipleResponders"] ?: @NO;
        if (!fresh || ![row[@"state"] isEqual:@"observed"] || ![row[@"saveState"] isEqual:@"succeeded"] || [entry[@"multipleResponders"] boolValue]) complete=NO;
        [rows addObject:entry];
    }
    return @{@"state":complete ? @"complete" : @"partial",@"roundStartedAt":value[@"roundStartedAt"],@"transportTrust":@"unauthenticated",@"apps":rows};
}

static NSDictionary *axs_cachekeeper_collection_saved_host(NSDictionary *document,NSError **error) {
    if (error) *error=nil;
    NSDictionary *artifact=document[@"hostArtifact"];
    if (!artifact) return nil;
    if (![artifact isKindOfClass:NSDictionary.class]) {if (error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];return nil;}
    NSData *data=[artifact isKindOfClass:NSDictionary.class] && [artifact[@"data"] isKindOfClass:NSData.class] ? artifact[@"data"] : nil;
    NSDictionary *snapshot=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    NSDictionary *closed=axs_cachekeeper_collection_host(snapshot);
    NSMutableDictionary *expected=[closed mutableCopy];expected[@"sourceSHA256"]=artifact[@"sha256"];
    NSDictionary *phase=document[@"phases"][@"hostPreflight"];
    if (!data || ![artifact[@"sessionID"] isEqual:document[@"sessionID"]] || ![artifact[@"sha256"] isEqual:axs_cachekeeper_collection_sha(data)] ||
        ![snapshot isEqual:closed] || ![phase[@"result"] isEqual:expected] || ![phase[@"state"] isEqual:closed[@"state"]]) {
        if (error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];return nil;
    }
    return closed;
}

static NSDictionary *axs_cachekeeper_collection_capacity(NSDictionary *document,NSError **error) {
        if (error) *error=nil;
        NSDictionary *artifact=document[@"capacityArtifact"];
        if (!artifact) return nil;
        NSData *data=[artifact isKindOfClass:NSDictionary.class] && [artifact[@"data"] isKindOfClass:NSData.class] ? artifact[@"data"] : nil;
        NSDictionary *snapshot=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        NSDictionary *closed=axs_cachekeeper_capacity_projection(snapshot);
        NSDictionary *result=[document[@"phases"][@"capacity"][@"result"] isKindOfClass:NSDictionary.class] ? document[@"phases"][@"capacity"][@"result"] : nil;
        BOOL valid=data && [artifact[@"sessionID"] isEqual:document[@"sessionID"]] &&
            [artifact[@"sha256"] isEqual:axs_cachekeeper_collection_sha(data)] && [result[@"sourceSHA256"] isEqual:artifact[@"sha256"]] &&
            [snapshot isEqual:closed] && [result[@"serviceState"] isEqual:closed[@"state"]] &&
            [@[@"complete",@"partial",@"cancelled",@"interrupted",@"unavailable"] containsObject:closed[@"state"]];
        for (NSString *key in @[@"epoch",@"finishedAt",@"completedRoots",@"totalRoots",@"failedRoots"])
            if (!result[key] || ![result[key] isEqual:closed[key]]) valid=NO;
        NSString *expectedState=[closed[@"state"] isEqual:@"complete"] ? @"complete" : @"partial";
        if (![result[@"state"] isEqual:expectedState] || ![document[@"phases"][@"capacity"][@"state"] isEqual:expectedState]) valid=NO;
        BOOL matchedStart=NO,matchedTerminal=NO;
        for (NSDictionary *event in document[@"events"]) {
            if (![event[@"phase"] isEqual:@"capacity"]) continue;
            if ([event[@"state"] isEqual:@"started"]) matchedStart=[event[@"result"][@"epoch"] isEqual:closed[@"epoch"]];
            if ([event[@"state"] isEqual:expectedState] && [event[@"result"] isEqual:result]) matchedTerminal=matchedStart;
        }
        if (!matchedTerminal) valid=NO;
        if (!valid) {if (error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];return nil;}
        return closed;
}

static BOOL axs_cachekeeper_collection_valid(NSDictionary *value) {
    if (![value isKindOfClass:NSDictionary.class] || ![value[@"schemaVersion"] isEqual:@1] ||
        ![value[@"sessionID"] isKindOfClass:NSString.class] || [value[@"sessionID"] length]!=32 ||
        [value[@"sessionID"] rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location!=NSNotFound ||
        ![value[@"createdAt"] isKindOfClass:NSNumber.class] ||
        ![value[@"phases"] isKindOfClass:NSDictionary.class] || ![value[@"events"] isKindOfClass:NSArray.class] ||
        ![value[@"blockedCapabilities"] isKindOfClass:NSArray.class]) return NO;
    for (NSString *key in value[@"phases"]) {
        id entry=value[@"phases"][key];
        if (![axs_cachekeeper_collection_phases() containsObject:key] || ![entry isKindOfClass:NSDictionary.class] ||
            ![entry[@"state"] isKindOfClass:NSString.class] ||
            ![@[@"pending",@"running",@"complete",@"partial",@"failed",@"interrupted",@"cancelled",@"blockedByCapability"] containsObject:entry[@"state"]]) return NO;
    }
    for (id event in value[@"events"])
        if (![event isKindOfClass:NSDictionary.class] || ![event[@"phase"] isKindOfClass:NSString.class] ||
            ![event[@"state"] isKindOfClass:NSString.class] || ![event[@"result"] isKindOfClass:NSDictionary.class]) return NO;
    for (id capability in value[@"blockedCapabilities"])
        if (![capability isKindOfClass:NSDictionary.class] || ![capability[@"bundle"] isKindOfClass:NSString.class] ||
            ![capability[@"capability"] isKindOfClass:NSString.class]) return NO;
    return YES;
}

static BOOL axs_cachekeeper_collection_session_complete(NSDictionary *projection) {
    if (![projection isKindOfClass:NSDictionary.class] || [projection[@"executionAvailable"] boolValue] ||
        [projection[@"state"] isEqual:@"blocked"] || [projection[@"blockedCapabilities"] count] ||
        ![projection[@"phases"] isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *phases=projection[@"phases"];
    for (NSString *phase in axs_cachekeeper_collection_phases()) {
        if (![phases[phase][@"state"] isEqual:@"complete"]) return NO;
        if ([phase isEqual:@"hostPreflight"]) {
            NSDictionary *result=phases[phase][@"result"];
            NSNumber *roundStartedAt=result[@"roundStartedAt"];
            NSArray *apps=[result[@"apps"] isKindOfClass:NSArray.class] ? result[@"apps"] : nil;
            if (![roundStartedAt isKindOfClass:NSNumber.class] || ![result[@"transportTrust"] isEqual:@"unauthenticated"] || !apps.count) return NO;
            for (NSDictionary *app in apps) {
                if (![app isKindOfClass:NSDictionary.class]) return NO;
                NSNumber *sourceUpdated=app[@"sourceUpdated"];
                if (![app isKindOfClass:NSDictionary.class] || ![app[@"state"] isEqual:@"observed"] || ![app[@"saveState"] isEqual:@"succeeded"] ||
                    ![app[@"transportTrust"] isEqual:@"unauthenticated"] || ![app[@"observationFreshness"] isEqual:@"currentRound"] ||
                    [app[@"multipleResponders"] boolValue] || ![sourceUpdated isKindOfClass:NSNumber.class] || [sourceUpdated doubleValue]<[roundStartedAt doubleValue]) return NO;
            }
        }
    }
    return YES;
}

@interface AxsCacheKeeperCollectionSession ()
@property(nonatomic,copy) NSString *axs_cachekeeper_path;
@property(nonatomic,strong) NSMutableDictionary *axs_cachekeeper_document;
- (instancetype)initWithPath:(NSString *)path axs_cachekeeper_allowCreation:(BOOL)allowCreation error:(NSError **)error;
- (BOOL)axs_cachekeeper_beginPhase:(NSString *)phase metadata:(NSDictionary *)metadata error:(NSError **)error;
@end

@implementation AxsCacheKeeperCollectionSession
+ (NSArray<NSDictionary *> *)resumableSessionsInDirectory:(NSString *)directory error:(NSError **)error {
    if (error) *error=nil;
    if (![directory isKindOfClass:NSString.class] || !directory.length) {
        if (error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];
        return nil;
    }
    BOOL isDirectory=NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:directory isDirectory:&isDirectory]) return @[];
    if (!isDirectory) {
        if (error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:ENOTDIR userInfo:nil];
        return nil;
    }
    NSError *enumerationError=nil;
    NSArray<NSString *> *names=[NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:&enumerationError];
    if (!names) { if (error) *error=enumerationError; return nil; }
    NSMutableArray<NSDictionary *> *sessions=[NSMutableArray new];
    for (NSString *name in names) {
      @autoreleasepool {
        if (![name.pathExtension isEqualToString:@"plist"]) continue;
        NSString *path=[directory stringByAppendingPathComponent:name];
        NSDictionary *attributes=[NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL];
        if (![attributes[NSFileType] isEqual:NSFileTypeRegular]) continue;
        NSData *data=[NSData dataWithContentsOfFile:path options:0 error:NULL];
        NSDictionary *document=data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL] : nil;
        if (!axs_cachekeeper_collection_valid(document)) continue;
        if (document[@"hostArtifact"] && !axs_cachekeeper_collection_saved_host(document,NULL)) continue;
        if (document[@"capacityArtifact"] && !axs_cachekeeper_collection_capacity(document,NULL)) continue;
        NSDictionary *phases=document[@"phases"];
        NSString *nextPhase=nil;
        BOOL failedWithoutResume=NO;
        for (NSString *phase in axs_cachekeeper_collection_phases()) {
            NSString *state=phases[phase][@"state"];
            if (!state || [@[@"pending",@"running",@"interrupted",@"cancelled"] containsObject:state]) { nextPhase=phase; break; }
            if ([state isEqual:@"failed"] || [state isEqual:@"blockedByCapability"]) { failedWithoutResume=YES; break; }
        }
        if ([document[@"reportArtifact"] isKindOfClass:NSDictionary.class]) {
            if (![self openSessionAtPath:path error:NULL]) continue;
            nextPhase=@"export";failedWithoutResume=NO;
        }
        if (!nextPhase || failedWithoutResume) continue;
        [sessions addObject:@{ @"path":path,@"sessionID":document[@"sessionID"],
            @"createdAt":document[@"createdAt"] ?: @0,@"nextPhase":nextPhase,@"phases":phases }];
      }
    }
    [sessions sortUsingComparator:^NSComparisonResult(NSDictionary *left,NSDictionary *right) {
        return [right[@"createdAt"] compare:left[@"createdAt"]];
    }];
    return [sessions copy];
}
+ (instancetype)openSessionAtPath:(NSString *)path error:(NSError **)error {
    if (![path isKindOfClass:NSString.class] || !path.length) {
        if (error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];return nil;
    }
    NSDictionary *attributes=[NSFileManager.defaultManager attributesOfItemAtPath:path error:error];
    if (!attributes) return nil;
    if (![attributes[NSFileType] isEqual:NSFileTypeRegular]) {
        if (error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];return nil;
    }
    return [[self alloc] initWithPath:path axs_cachekeeper_allowCreation:NO error:error];
}
+ (instancetype)createNewSessionInDirectory:(NSString *)directory error:(NSError **)error {
    if (![directory isKindOfClass:NSString.class] || !directory.length) {
        if (error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];return nil;
    }
    NSString *path=[[directory stringByAppendingPathComponent:NSUUID.UUID.UUIDString.lowercaseString] stringByAppendingPathExtension:@"plist"];
    if ([NSFileManager.defaultManager fileExistsAtPath:path]) {
        if (error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:EEXIST userInfo:nil];return nil;
    }
    return [[self alloc] initWithPath:path error:error];
}
- (instancetype)initWithPath:(NSString *)path error:(NSError **)error {
    return [self initWithPath:path axs_cachekeeper_allowCreation:YES error:error];
}
- (instancetype)initWithPath:(NSString *)path axs_cachekeeper_allowCreation:(BOOL)allowCreation error:(NSError **)error {
    if (error) *error=nil;
    if (![path isKindOfClass:NSString.class] || !path.length) {
        if (error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];return nil;
    }
    if (!(self=[super init])) return nil;
    _axs_cachekeeper_path=[path copy];
    BOOL fileExists=[NSFileManager.defaultManager fileExistsAtPath:path];
    NSData *data=[NSData dataWithContentsOfFile:path options:0 error:error];
    if (data) {
        id value=[NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainers format:NULL error:error];
        if (!axs_cachekeeper_collection_valid(value)) {
            if (error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];return nil;
        }
        _axs_cachekeeper_document=[value mutableCopy];
        if (_axs_cachekeeper_document[@"hostArtifact"] && !axs_cachekeeper_collection_saved_host(_axs_cachekeeper_document,error)) return nil;
        if (_axs_cachekeeper_document[@"capacityArtifact"] && ![self savedCapacitySnapshot:error]) return nil;
        if (_axs_cachekeeper_document[@"reportArtifact"]) {
            if (![self savedReportData:error]) return nil;
            return self;
        }
        BOOL recovered=NO;
        for (NSString *phase in axs_cachekeeper_collection_phases()) {
            NSMutableDictionary *entry=_axs_cachekeeper_document[@"phases"][phase];
            if ([entry[@"state"] isEqual:@"running"] || [entry[@"state"] isEqual:@"pending"]) {
                entry[@"state"]=@"interrupted";
                [self axs_cachekeeper_event:phase state:@"interrupted" result:@{}];
                recovered=YES;
            }
        }
        if (recovered && ![self axs_cachekeeper_save:error]) return nil;
    } else {
        if (fileExists || !allowCreation) return nil;
        NSError *directoryError=nil;
        if (![NSFileManager.defaultManager createDirectoryAtPath:[path stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:&directoryError]) {
            if (error) *error=directoryError;return nil;
        }
        NSString *uuid=NSUUID.UUID.UUIDString.lowercaseString;
        NSString *sessionID=[[uuid componentsSeparatedByString:@"-"] componentsJoinedByString:@""];
        _axs_cachekeeper_document=axs_cachekeeper_collection_copy(@{ @"schemaVersion":@1,@"sessionID":sessionID,
            @"createdAt":@((uint64_t)NSDate.date.timeIntervalSince1970),@"phases":@{},@"events":@[],@"blockedCapabilities":@[] });
        if (![self axs_cachekeeper_save:error]) return nil;
    }
    if (error) *error=nil;
    return self;
}
- (NSString *)sessionID { @synchronized(self) {return self.axs_cachekeeper_document[@"sessionID"];} }
- (void)axs_cachekeeper_event:(NSString *)phase state:(NSString *)state result:(NSDictionary *)result {
    NSMutableArray *events=self.axs_cachekeeper_document[@"events"];
    [events addObject:@{@"sequence":@(events.count+1),@"phase":phase,@"state":state,
        @"at":@((uint64_t)NSDate.date.timeIntervalSince1970),@"result":result ?: @{}}];
}
- (BOOL)axs_cachekeeper_save:(NSError **)error {
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:self.axs_cachekeeper_document
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    return data && [data writeToFile:self.axs_cachekeeper_path options:NSDataWritingAtomic error:error];
}
- (BOOL)beginPhase:(NSString *)phase error:(NSError **)error {
    return [self axs_cachekeeper_beginPhase:phase metadata:@{} error:error];
}
- (BOOL)beginCapacityWithEpoch:(NSString *)epoch error:(NSError **)error {
    if (!axs_cachekeeper_capacity_epoch(epoch)) {
        if (error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];return NO;
    }
    return [self axs_cachekeeper_beginPhase:@"capacity" metadata:@{@"epoch":epoch} error:error];
}
- (BOOL)axs_cachekeeper_beginPhase:(NSString *)phase metadata:(NSDictionary *)metadata error:(NSError **)error {
    @synchronized(self) {
        if (error) *error=nil;
        NSUInteger index=[axs_cachekeeper_collection_phases() indexOfObject:phase];
        if (index==NSNotFound) {if (error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];return NO;}
        NSMutableDictionary *phases=self.axs_cachekeeper_document[@"phases"];
        for (NSUInteger i=0;i<index;i++) if (![@[@"complete",@"partial",@"failed",@"blockedByCapability"] containsObject:phases[axs_cachekeeper_collection_phases()[i]][@"state"]]) {
            if (error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:EBUSY userInfo:nil];return NO;
        }
        NSString *state=phases[phase][@"state"];
        if (state && ![state isEqual:@"pending"]) {
            if (error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:EALREADY userInfo:nil];return NO;
        }
        NSMutableDictionary *previous=axs_cachekeeper_collection_copy(self.axs_cachekeeper_document);
        id oldEntry=phases[phase];
        NSMutableDictionary *entry=[oldEntry isKindOfClass:NSDictionary.class] ? [oldEntry mutableCopy] : [NSMutableDictionary new];
        entry[@"state"]=@"running";
        if (metadata.count) entry[@"request"]=metadata;
        phases[phase]=entry;
        [self axs_cachekeeper_event:phase state:@"started" result:metadata];
        if ([self axs_cachekeeper_save:error]) return YES;
        self.axs_cachekeeper_document=previous;return NO;
    }
}
- (BOOL)prepareRetryForPhase:(NSString *)phase error:(NSError **)error {
    @synchronized(self) {
        if (error) *error=nil;
        if (![axs_cachekeeper_collection_phases() containsObject:phase]) {
            if (error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];return NO;
        }
        NSMutableDictionary *phases=self.axs_cachekeeper_document[@"phases"];
        if (![@[@"interrupted",@"cancelled"] containsObject:phases[phase][@"state"]]) {
            if (error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:EALREADY userInfo:nil];return NO;
        }
        for (NSString *later in axs_cachekeeper_collection_phases()) {
            if ([later isEqual:phase]) continue;
            NSUInteger phaseIndex=[axs_cachekeeper_collection_phases() indexOfObject:phase];
            NSUInteger laterIndex=[axs_cachekeeper_collection_phases() indexOfObject:later];
            if (laterIndex>phaseIndex && ([phases[later][@"state"] isEqual:@"complete"] || [phases[later][@"state"] isEqual:@"partial"])) {
                if (error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:EBUSY userInfo:nil];return NO;
            }
        }
        NSMutableDictionary *previous=axs_cachekeeper_collection_copy(self.axs_cachekeeper_document);
        phases[phase]=[@{@"state":@"pending",@"retryAfterInterruption":@YES} mutableCopy];
        [self axs_cachekeeper_event:phase state:@"retryScheduled" result:@{}];
        if ([self axs_cachekeeper_save:error]) return YES;
        self.axs_cachekeeper_document=previous;return NO;
    }
}
- (BOOL)finishCapacityWithSnapshot:(NSDictionary *)snapshot error:(NSError **)error {
    @synchronized(self) {
        if (error) *error=nil;
        NSDictionary *phase=self.axs_cachekeeper_document[@"phases"][@"capacity"];
        NSDictionary *closed=axs_cachekeeper_capacity_projection(snapshot);
        if (![phase[@"state"] isEqual:@"running"] ||
            ![@[@"complete",@"partial",@"cancelled",@"interrupted",@"unavailable"] containsObject:closed[@"state"]] ||
            ![phase[@"request"][@"epoch"] isEqual:closed[@"epoch"]] || self.axs_cachekeeper_document[@"capacityArtifact"]) {
            if (error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];return NO;
        }
        NSMutableDictionary *bound=[closed mutableCopy];
        NSDictionary *binding=@{@"epoch":closed[@"epoch"],@"terminalState":closed[@"state"],@"terminalFinishedAt":closed[@"finishedAt"],
            @"summarizedAt":@((uint64_t)NSDate.date.timeIntervalSince1970)};
        bound[@"summaryBinding"]=axs_cachekeeper_capacity_summary_binding(binding,closed);
        closed=axs_cachekeeper_capacity_projection(bound);
        NSData *data=[NSJSONSerialization dataWithJSONObject:closed options:NSJSONWritingSortedKeys error:error];
        if (!data) return NO;
        NSString *sha=axs_cachekeeper_collection_sha(data);
        if (!sha) {if (error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:EFBIG userInfo:nil];return NO;}
        NSMutableDictionary *previous=axs_cachekeeper_collection_copy(self.axs_cachekeeper_document);
        NSString *state=[closed[@"state"] isEqual:@"complete"] ? @"complete" : @"partial";
        NSDictionary *result=@{@"state":state,@"serviceState":closed[@"state"],@"epoch":closed[@"epoch"],@"finishedAt":closed[@"finishedAt"],
            @"completedRoots":closed[@"completedRoots"],@"totalRoots":closed[@"totalRoots"],@"failedRoots":closed[@"failedRoots"],@"sourceSHA256":sha};
        self.axs_cachekeeper_document[@"capacityArtifact"]=@{@"sessionID":self.sessionID,@"data":data,@"sha256":sha};
        self.axs_cachekeeper_document[@"phases"][@"capacity"]=[@{@"state":state,@"result":result} mutableCopy];
        [self axs_cachekeeper_event:@"capacity" state:state result:result];
        if ([self axs_cachekeeper_save:error]) return YES;
        self.axs_cachekeeper_document=previous;return NO;
    }
}
- (NSDictionary *)savedCapacitySnapshot:(NSError **)error {
    @synchronized(self) {return axs_cachekeeper_collection_capacity(self.axs_cachekeeper_document,error);}
}
- (BOOL)finishPhase:(NSString *)phase result:(NSDictionary *)result error:(NSError **)error {
    @synchronized(self) {
        if (error) *error=nil;
        if (![axs_cachekeeper_collection_phases() containsObject:phase] || [phase isEqual:@"export"] ||
            ![self.axs_cachekeeper_document[@"phases"][phase][@"state"] isEqual:@"running"] ||
            ![result isKindOfClass:NSDictionary.class] ||
            ![result[@"state"] isKindOfClass:NSString.class] ||
            ![@[@"complete",@"partial",@"failed",@"interrupted",@"cancelled",@"blockedByCapability"] containsObject:result[@"state"]]) {
            if (error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];return NO;
        }
        NSDictionary *capacityRequest=self.axs_cachekeeper_document[@"phases"][@"capacity"][@"request"];
        if ([phase isEqual:@"capacity"] && capacityRequest[@"epoch"] &&
            (![capacityRequest[@"epoch"] isEqual:result[@"epoch"]] ||
             [@[@"complete",@"partial"] containsObject:result[@"state"]])) {
            if (error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];return NO;
        }
        if ([phase isEqual:@"capacity"] && !([result[@"state"] isEqual:@"interrupted"] &&
            [result[@"terminalSource"] isEqual:@"clientLifecycle"] && [result[@"epoch"] isKindOfClass:NSString.class] &&
            [result[@"epoch"] length] && [result[@"observedAt"] isKindOfClass:NSNumber.class])) {
            NSString *state=result[@"state"];
            if (![@[@"complete",@"partial",@"failed",@"interrupted",@"cancelled"] containsObject:state] ||
                ![result[@"epoch"] isKindOfClass:NSString.class] || ![result[@"epoch"] length] ||
                ![result[@"finishedAt"] isKindOfClass:NSNumber.class] ||
                ![result[@"completedRoots"] isKindOfClass:NSNumber.class] ||
                ![result[@"totalRoots"] isKindOfClass:NSNumber.class] ||
                ![result[@"failedRoots"] isKindOfClass:NSNumber.class] ||
                [result[@"completedRoots"] unsignedIntegerValue]>[result[@"totalRoots"] unsignedIntegerValue] ||
                ([state isEqual:@"complete"] && ([result[@"completedRoots"] unsignedIntegerValue]!=[result[@"totalRoots"] unsignedIntegerValue] || [result[@"failedRoots"] unsignedIntegerValue]!=0))) {
                if (error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];return NO;
            }
        }
        NSDictionary *hostArtifact=nil;
        if ([phase isEqual:@"hostPreflight"] && [@[@"complete",@"partial"] containsObject:result[@"state"]] && result[@"apps"]) {
            NSDictionary *closed=axs_cachekeeper_collection_host(result);
            if (!closed) {if (error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];return NO;}
            NSData *data=[NSJSONSerialization dataWithJSONObject:closed options:NSJSONWritingSortedKeys error:error];
            if (!data) return NO;
            NSString *sha=axs_cachekeeper_collection_sha(data);
            hostArtifact=@{@"sessionID":self.sessionID,@"data":data,@"sha256":sha};
            NSMutableDictionary *bound=[closed mutableCopy];bound[@"sourceSHA256"]=sha;result=bound;
        }
        NSDictionary *frozen=axs_cachekeeper_collection_copy(result);
        if (!frozen) {if (error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];return NO;}
        NSMutableDictionary *previous=axs_cachekeeper_collection_copy(self.axs_cachekeeper_document);
        if (hostArtifact) self.axs_cachekeeper_document[@"hostArtifact"]=hostArtifact;
        NSString *state=frozen[@"state"];
        self.axs_cachekeeper_document[@"phases"][phase]=[@{@"state":state,@"result":frozen} mutableCopy];
        [self axs_cachekeeper_event:phase state:state result:frozen];
        if ([self axs_cachekeeper_save:error]) return YES;
        self.axs_cachekeeper_document=previous;return NO;
    }
}
- (NSData *)saveReport:(NSDictionary *)report diagnosticsResult:(NSDictionary *)diagnosticsResult error:(NSError **)error {
    @synchronized(self) {
        if (error) *error=nil;
        if (![report isKindOfClass:NSDictionary.class] || ![NSJSONSerialization isValidJSONObject:report] ||
            ![diagnosticsResult isKindOfClass:NSDictionary.class] ||
            ![@[@"complete",@"partial"] containsObject:diagnosticsResult[@"state"]] ||
            ![self.axs_cachekeeper_document[@"phases"][@"diagnostics"][@"state"] isEqual:@"running"] ||
            self.axs_cachekeeper_document[@"phases"][@"export"]) {
            if (error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];return nil;
        }
        NSMutableDictionary *previous=axs_cachekeeper_collection_copy(self.axs_cachekeeper_document);
        NSMutableDictionary *finalReport=[report mutableCopy];
        NSString *imagePath=[[self.axs_cachekeeper_path stringByDeletingLastPathComponent] stringByAppendingPathComponent:[self.sessionID stringByAppendingString:@".image.plist"]];
        if ([NSFileManager.defaultManager fileExistsAtPath:imagePath]) {
            NSString *folder=[[self.axs_cachekeeper_path stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
            AxsCacheKeeperImageCollectionSession *image=[[AxsCacheKeeperImageCollectionSession alloc] initWithFolder:folder sessionID:self.sessionID error:error];
            if (!image) return nil;
            if (![image.reportProjection[@"state"] isEqual:@"idle"]) {
                NSError *pollError=nil;if (![image poll:&pollError]) {if (error) *error=pollError;return nil;}
            }
            if (![@[@"complete",@"idle",@"restorationUnconfirmed"] containsObject:image.reportProjection[@"state"]]) {
                if (error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:EBUSY userInfo:nil];return nil;
            }
            finalReport[@"supportedImageCollection"]=image.reportProjection;
        }
        NSMutableDictionary *frozen=axs_cachekeeper_collection_copy(diagnosticsResult);
        if (!frozen) {if (error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];return nil;}
        NSError *capacityError=nil;
        NSDictionary *capacity=[self savedCapacitySnapshot:&capacityError];
        if (capacityError) {if (error) *error=capacityError;return nil;}
        if (capacity) finalReport[@"capacityMeasurement"]=capacity;
        else {
            // Another session may have replaced the global result while this session was closed.
            // Retain this session's terminal summary, never attribute the other result to it.
            finalReport[@"capacityMeasurement"]=@{@"schemaVersion":@1,@"state":@"notMeasured"};
            NSMutableArray *missing=[frozen[@"missingSources"] isKindOfClass:NSArray.class] ? [frozen[@"missingSources"] mutableCopy] : [NSMutableArray new];
            if (![missing containsObject:@"capacitySessionEvidence"]) [missing addObject:@"capacitySessionEvidence"];
            frozen[@"state"]=@"partial";frozen[@"missingSources"]=missing;frozen[@"capacityEvidenceState"]=@"unavailable";
        }
        NSError *hostError=nil;
        (void)axs_cachekeeper_collection_saved_host(self.axs_cachekeeper_document,&hostError);
        if (hostError) {if (error) *error=hostError;return nil;}
        NSMutableArray *files=[NSMutableArray new];NSMutableDictionary *sources=[NSMutableDictionary new];
        for (NSString *phase in @[@"hostPreflight",@"capacity"]) {
            NSString *key=[phase isEqual:@"capacity"] ? @"capacityArtifact" : @"hostArtifact";
            NSDictionary *artifact=self.axs_cachekeeper_document[key];
            if (!artifact) continue;
            NSData *bytes=artifact[@"data"];NSString *name=[phase stringByAppendingString:@".json"];
            sources[name]=[bytes base64EncodedStringWithOptions:0];
            [files addObject:@{@"name":name,@"phase":phase,@"length":@(bytes.length),@"sha256":artifact[@"sha256"]}];
        }
        finalReport[@"sourceManifest"]=@{@"schemaVersion":@1,@"sessionID":self.sessionID,@"encoding":@"base64",
            @"integrityScope":@"listedSourceBytesOnly",@"authenticity":@"notAuthenticated",@"files":files};
        finalReport[@"sourceObjects"]=sources;
        self.axs_cachekeeper_document[@"phases"][@"diagnostics"]=[@{@"state":frozen[@"state"],@"result":frozen} mutableCopy];
        [self axs_cachekeeper_event:@"diagnostics" state:frozen[@"state"] result:frozen];
        [self axs_cachekeeper_event:@"export" state:@"started" result:@{}];
        NSDictionary *result=@{@"state":@"complete",@"format":@"redactedJSON"};
        self.axs_cachekeeper_document[@"phases"][@"export"]=[@{@"state":@"complete",@"result":result} mutableCopy];
        [self axs_cachekeeper_event:@"export" state:@"complete" result:result];
        finalReport[@"guidedCollection"]=self.reportProjection;
        NSData *data=[NSJSONSerialization dataWithJSONObject:finalReport options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:error];
        NSString *sha=data ? axs_cachekeeper_collection_sha(data) : nil;
        if (sha) {
            // Bytes and terminal state share one atomic file replacement; the hash stays outside its own payload.
            self.axs_cachekeeper_document[@"reportArtifact"]=@{@"data":data,@"sha256":sha};
            if ([self axs_cachekeeper_save:error]) return data;
        }
        self.axs_cachekeeper_document=previous;
        if (error && !*error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];
        return nil;
    }
}
- (NSData *)savedReportData:(NSError **)error {
    @synchronized(self) {
        if (error) *error=nil;
        NSDictionary *artifact=self.axs_cachekeeper_document[@"reportArtifact"];
        if (!artifact) return nil;
        NSData *data=[artifact isKindOfClass:NSDictionary.class] && [artifact[@"data"] isKindOfClass:NSData.class] ? artifact[@"data"] : nil;
        NSDictionary *report=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        if (!data || ![artifact[@"sha256"] isEqual:axs_cachekeeper_collection_sha(data)] ||
            ![report isKindOfClass:NSDictionary.class] || ![report[@"guidedCollection"] isEqual:self.reportProjection] ||
            ![self.axs_cachekeeper_document[@"phases"][@"export"][@"state"] isEqual:@"complete"]) {
            if (error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];return nil;
        }
        return [data copy];
    }
}
- (BOOL)blockCapability:(NSString *)bundle capability:(NSString *)capability error:(NSError **)error {
    @synchronized(self) {
        if (error) *error=nil;
        if (![bundle isKindOfClass:NSString.class] || !bundle.length || ![capability isKindOfClass:NSString.class] || !capability.length) {
            if (error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];return NO;
        }
        NSDictionary *entry=@{@"bundle":bundle,@"capability":capability,@"state":@"blockedByCapability"};
        NSMutableArray *blocked=self.axs_cachekeeper_document[@"blockedCapabilities"];
        if ([blocked containsObject:entry]) return YES;
        if (self.axs_cachekeeper_document[@"reportArtifact"]) {
            if (error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:EALREADY userInfo:nil];return NO;
        }
        NSMutableDictionary *previous=axs_cachekeeper_collection_copy(self.axs_cachekeeper_document);
        [blocked addObject:entry];
        [self axs_cachekeeper_event:@"capabilityGate" state:@"blockedByCapability" result:entry];
        if ([self axs_cachekeeper_save:error]) return YES;
        self.axs_cachekeeper_document=previous;return NO;
    }
}
- (NSDictionary *)reportProjection {
    @synchronized(self) {
        BOOL blocked=[self.axs_cachekeeper_document[@"blockedCapabilities"] count]>0;
        for (NSString *phase in axs_cachekeeper_collection_phases())
            if ([@[@"running",@"failed",@"interrupted",@"cancelled"] containsObject:self.axs_cachekeeper_document[@"phases"][phase][@"state"]]) blocked=YES;
        BOOL complete=axs_cachekeeper_collection_session_complete(@{@"executionAvailable":@NO,@"state":blocked ? @"blocked" : @"incomplete",
            @"phases":self.axs_cachekeeper_document[@"phases"],@"blockedCapabilities":self.axs_cachekeeper_document[@"blockedCapabilities"]});
        return [axs_cachekeeper_collection_copy(@{ @"schemaVersion":@1,@"sessionID":self.sessionID,@"state":blocked ? @"blocked" : complete ? @"complete" : @"incomplete",
            @"executionAvailable":@NO,@"phases":[self.axs_cachekeeper_document[@"phases"] copy],
            @"events":[self.axs_cachekeeper_document[@"events"] copy],
            @"blockedCapabilities":[self.axs_cachekeeper_document[@"blockedCapabilities"] copy] }) copy];
    }
}
@end
