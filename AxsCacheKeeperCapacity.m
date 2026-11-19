#import "AxsCacheKeeperCapacity.h"
#import "AxsCacheKeeperCapacityStatus.h"
#import "AxsCacheKeeperScanTask.h"
#include <string.h>

static const NSUInteger AxsCacheKeeperCapacityEntryLimit=2000000;
static const NSUInteger AxsCacheKeeperCapacityDepthLimit=64;
static const NSUInteger AxsCacheKeeperCapacityInodeLimit=262144;
static const NSUInteger AxsCacheKeeperCapacityNodeLimit=4096;
static const NSUInteger AxsCacheKeeperCapacityNodeDepth=3;
static const uint64_t AxsCacheKeeperCapacityMaximum=9007199254740991ULL;

// Byte keys compare the entire identity, not NSNumber/NSArray count hashes.
static NSData *AxsCacheKeeperCapacityInodeKey(const struct stat *info) {
    const uint64_t identity[2]={(uint64_t)info->st_dev,(uint64_t)info->st_ino};
    return [NSData dataWithBytes:identity length:sizeof(identity)];
}
static NSData *AxsCacheKeeperCapacitySample(const struct stat *info) {
    // Canonical fields, not struct padding; a reused/changed inode is not a
    // stable measurement. Reading directory entries does not mutate these fields.
    const uint64_t values[]={info->st_mode,info->st_nlink,info->st_uid,info->st_gid,
        (uint64_t)info->st_rdev,(uint64_t)info->st_size,(uint64_t)info->st_blocks,(uint64_t)info->st_blksize,
        info->st_flags,info->st_gen,(uint64_t)info->st_mtimespec.tv_sec,(uint64_t)info->st_mtimespec.tv_nsec,
        (uint64_t)info->st_ctimespec.tv_sec,(uint64_t)info->st_ctimespec.tv_nsec,
        (uint64_t)info->st_birthtimespec.tv_sec,(uint64_t)info->st_birthtimespec.tv_nsec};
    return [NSData dataWithBytes:values length:sizeof(values)];
}
static NSData *AxsCacheKeeperCapacityNodeKey(NSArray<NSData *> *components,NSUInteger depth) {
    NSMutableData *key=[NSMutableData new];
    for(NSUInteger i=0;i<depth;i++) {
        NSData *part=components[i];uint64_t length=part.length;
        [key appendBytes:&length length:sizeof(length)];[key appendData:part];
    }
    return key;
}
static BOOL AxsCacheKeeperCapacityName(NSData *part,const char *name) {
    NSUInteger length=strlen(name);return part.length==length && !memcmp(part.bytes,name,length);
}
static NSString *AxsCacheKeeperCapacityCategory(NSArray<NSData *> *components) {
    if(components.count==1) {
        if(AxsCacheKeeperCapacityName(components[0],"Documents")) return @"Documents";
        if(AxsCacheKeeperCapacityName(components[0],"Library")) return @"Library";
        if(AxsCacheKeeperCapacityName(components[0],"tmp")) return @"tmp";
    }
    if(components.count==2 && AxsCacheKeeperCapacityName(components[0],"Library")) {
        if(AxsCacheKeeperCapacityName(components[1],"Caches")) return @"Caches";
        if(AxsCacheKeeperCapacityName(components[1],"Application Support")) return @"Application Support";
    }
    return @"unknown";
}
@interface AxsCacheKeeperCapacityRoot ()
- (instancetype)initWithRoot:(NSURL *)root entryLimit:(NSUInteger)entries depthLimit:(NSUInteger)depth
                 inodeLimit:(NSUInteger)inodes nodeLimit:(NSUInteger)nodes;
- (instancetype)initWithRoot:(NSURL *)root entryLimit:(NSUInteger)entries depthLimit:(NSUInteger)depth
                 inodeLimit:(NSUInteger)inodes nodeLimit:(NSUInteger)nodes
      requiresExpectedIdentity:(BOOL)required expectedDevice:(dev_t)device expectedInode:(ino_t)inode;
- (void)axs_cachekeeper_observe:(const struct stat *)info components:(NSArray<NSData *> *)components;
@end
@implementation AxsCacheKeeperCapacityRoot {
    AxsCacheKeeperScanCursor *_cursor;
    NSMutableDictionary<NSData *,NSData *> *_inodes;
    NSMutableDictionary<NSData *,NSNumber *> *_nodeIDs;
    NSMutableArray<NSMutableDictionary *> *_nodes;
    NSString *_failure;
    NSDictionary *_sourceFailure;
    uint64_t _logical,_allocated;
    NSUInteger _entries,_duplicates,_entryLimit,_depthLimit,_inodeLimit,_nodeLimit;
    BOOL _requiresExpectedIdentity;
    dev_t _expectedDevice;
    ino_t _expectedInode;
}
- (instancetype)initWithRoot:(NSURL *)root {
    return [self initWithRoot:root entryLimit:AxsCacheKeeperCapacityEntryLimit depthLimit:AxsCacheKeeperCapacityDepthLimit
        inodeLimit:AxsCacheKeeperCapacityInodeLimit nodeLimit:AxsCacheKeeperCapacityNodeLimit];
}
- (instancetype)initWithSourceFailure:(NSDictionary *)failure {
    NSDictionary *closed=axs_cachekeeper_capacity_source_failure(failure);
    if (!closed) return nil;
    if ((self=[self initWithRoot:nil])) {
        _sourceFailure=closed;_failure=[closed[@"reason"] isEqual:@"identityChanged"] ? @"identityChanged" : @"readError";
    }
    return self;
}
- (instancetype)initWithRoot:(NSURL *)root entryLimit:(NSUInteger)entries depthLimit:(NSUInteger)depth
                 inodeLimit:(NSUInteger)inodes nodeLimit:(NSUInteger)nodes {
    return [self initWithRoot:root entryLimit:entries depthLimit:depth inodeLimit:inodes nodeLimit:nodes
        requiresExpectedIdentity:NO expectedDevice:0 expectedInode:0];
}
- (instancetype)initWithRoot:(NSURL *)root expectedDevice:(dev_t)device expectedInode:(ino_t)inode {
    return [self initWithRoot:root entryLimit:AxsCacheKeeperCapacityEntryLimit depthLimit:AxsCacheKeeperCapacityDepthLimit
        inodeLimit:AxsCacheKeeperCapacityInodeLimit nodeLimit:AxsCacheKeeperCapacityNodeLimit
        requiresExpectedIdentity:YES expectedDevice:device expectedInode:inode];
}
- (instancetype)initWithRoot:(NSURL *)root entryLimit:(NSUInteger)entries depthLimit:(NSUInteger)depth
                 inodeLimit:(NSUInteger)inodes nodeLimit:(NSUInteger)nodes
      requiresExpectedIdentity:(BOOL)required expectedDevice:(dev_t)device expectedInode:(ino_t)inode {
    if(!(self=[super init])) return nil;
    _requiresExpectedIdentity=required;_expectedDevice=device;_expectedInode=inode;
    _entryLimit=MIN(MAX(entries,(NSUInteger)1),AxsCacheKeeperCapacityEntryLimit);
    _depthLimit=MIN(MAX(depth,(NSUInteger)1),AxsCacheKeeperCapacityDepthLimit);
    _inodeLimit=MIN(MAX(inodes,(NSUInteger)1),AxsCacheKeeperCapacityInodeLimit);
    _nodeLimit=MIN(MAX(nodes,(NSUInteger)1),AxsCacheKeeperCapacityNodeLimit);
    _inodes=[NSMutableDictionary new];_nodeIDs=[NSMutableDictionary new];_nodes=[NSMutableArray new];
    // Invalid input did not execute lstat; thread-local errno is not evidence.
    if (!root.isFileURL) {
        _failure=@"readError";_sourceFailure=@{@"stage":@"inputValidation",@"reason":@"invalidRoot",@"errorDomain":@"none"};return self;
    }
    __weak AxsCacheKeeperCapacityRoot *weakSelf=self;
    // Root counts as an entry here, but the legacy cursor counts descendants.
    _cursor=[[AxsCacheKeeperScanCursor alloc] initWithRoot:root entryLimit:_entryLimit-1 depthLimit:_depthLimit
        metadataObserver:^(const struct stat *info,NSArray<NSData *> *components) {
            AxsCacheKeeperCapacityRoot *owner=weakSelf;
            if(!owner) return;
            [owner axs_cachekeeper_observe:info components:components];
            if(owner->_failure) [owner->_cursor stopWithState:owner->_failure];
        }];
    // The root observer runs before _cursor is assigned; close its FD here on
    // rejection, before any caller can advance or publish a root observation.
    if(_failure) [_cursor stopWithState:_failure];
    return self;
}
- (void)axs_cachekeeper_observe:(const struct stat *)info components:(NSArray<NSData *> *)components {
    if(_failure) return;
    if(!components.count && _requiresExpectedIdentity &&
        (info->st_dev!=_expectedDevice || info->st_ino!=_expectedInode)) {_failure=@"identityChanged";return;}
    if(_entries>=_entryLimit) {_failure=@"entryLimit";return;}
    if(info->st_size<0 || info->st_blocks<0 || (uint64_t)info->st_blocks>AxsCacheKeeperCapacityMaximum/512) {_failure=@"invalidMetadata";return;}
    NSData *key=AxsCacheKeeperCapacityInodeKey(info),*sample=AxsCacheKeeperCapacitySample(info),*old=_inodes[key];
    BOOL duplicate=old!=nil;
    if(duplicate && ![old isEqual:sample]) { _failure=@"invalidMetadata";return; }
    if(!duplicate && _inodes.count>=_inodeLimit) {_failure=@"inodeLimit";return;}
    uint64_t logical=S_ISREG(info->st_mode) ? (uint64_t)info->st_size : 0;
    uint64_t allocated=duplicate ? 0 : (uint64_t)info->st_blocks*512;
    if(logical>AxsCacheKeeperCapacityMaximum || _logical>AxsCacheKeeperCapacityMaximum-logical || _allocated>AxsCacheKeeperCapacityMaximum-allocated) {_failure=@"invalidMetadata";return;}
    BOOL directory=S_ISDIR(info->st_mode);
    if(directory && components.count<=AxsCacheKeeperCapacityNodeDepth) {
        if(_nodes.count>=_nodeLimit) { _failure=@"nodeLimit";return; }
        NSData *nodeKey=AxsCacheKeeperCapacityNodeKey(components,components.count);
        NSNumber *parent=components.count ? _nodeIDs[AxsCacheKeeperCapacityNodeKey(components,components.count-1)] : @0;
        if(!parent || _nodeIDs[nodeKey]) {_failure=@"invalidMetadata";return;}
        NSNumber *identifier=@(_nodes.count+1);
        _nodeIDs[nodeKey]=identifier;
        [_nodes addObject:[@{@"id":identifier,@"parent":parent,@"category":AxsCacheKeeperCapacityCategory(components),
            @"logicalBytes":@0,@"allocatedBytes":@0,@"entries":@0} mutableCopy]];
    }
    NSUInteger depth=MIN(directory ? components.count : (components.count ? components.count-1 : 0),AxsCacheKeeperCapacityNodeDepth);
    for(NSUInteger i=0;i<=depth;i++) {
        NSNumber *identifier=_nodeIDs[AxsCacheKeeperCapacityNodeKey(components,i)];
        if(!identifier) {_failure=@"invalidMetadata";return;}
        NSMutableDictionary *node=_nodes[identifier.unsignedIntegerValue-1];
        node[@"logicalBytes"]=@([node[@"logicalBytes"] unsignedLongLongValue]+logical);
        node[@"allocatedBytes"]=@([node[@"allocatedBytes"] unsignedLongLongValue]+allocated);
        node[@"entries"]=@([node[@"entries"] unsignedIntegerValue]+1);
    }
    if(!duplicate) _inodes[key]=sample;else _duplicates++;
    _entries++;_logical+=logical;_allocated+=allocated;
}
- (void)advanceEntries:(NSUInteger)entries seconds:(NSTimeInterval)seconds {
    if(![self.state isEqual:@"running"]) return;
    [_cursor advanceEntries:MIN(entries,(NSUInteger)512) seconds:MIN(MAX(seconds,0),.05)];
    if(_failure) [_cursor stopWithState:_failure];
}
- (void)stopWithState:(NSString *)state {
    if(![self.state isEqual:@"running"]) return;
    BOOL accepted=[@[@"cancelled",@"interrupted",@"readError",@"identityChanged",@"entryLimit",@"depthLimit",@"timeLimit",@"inodeLimit",@"invalidMetadata",@"nodeLimit"] containsObject:state ?: @""];
    // Only actual traversal can declare success, never an external stop request.
    [_cursor stopWithState:accepted ? state : @"readError"];
}
- (NSString *)state {return _failure ?: _cursor.state;}
- (NSUInteger)openDirectoryCount {return _cursor.openDirectoryCount;}
- (BOOL)cursorCreated {return _cursor!=nil;}
- (NSDictionary *)result {
    NSMutableArray *nodes=[NSMutableArray arrayWithCapacity:_nodes.count];
    for(NSDictionary *node in _nodes) [nodes addObject:[node copy]];
    NSMutableDictionary *out=[@{@"schemaVersion":@1,@"state":self.state,@"logicalBytes":@(_logical),@"allocatedBytes":@(_allocated),
        @"entries":@(_entries),@"uniqueInodes":@(_inodes.count),@"duplicateInodes":@(_duplicates),@"nodes":[nodes copy],
        @"entryLimit":@(_entryLimit),@"depthLimit":@(_depthLimit),@"inodeLimit":@(_inodeLimit),@"nodeLimit":@(_nodeLimit),
        @"deletionAuthorization":@"notGranted",@"physicalUniqueBytes":@"notMeasured",@"reclaimableBytes":@"notMeasured"} mutableCopy];
    if (_cursor) out[@"cursorErrors"]=axs_cachekeeper_capacity_cursor_errors(_cursor.result[@"scanDiagnostics"]);
    if (_sourceFailure) out[@"sourceFailure"]=_sourceFailure;
    return [out copy];
}
@end
