#import "AxsCacheKeeperGurdCache.h"
#import "AxsCacheKeeperPolicy.h"
#import "AxsCacheKeeperScanTask.h"
#import "AxsCacheKeeperRuntimeBuild.h"
#include <stdatomic.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
static NSDictionary *axs_cachekeeper_gurd_no_sample(void) {
 return @{@"state":@"notRecorded",@"files":@0,@"logicalBytes":@0,@"allocatedBytes":@0,@"entries":@0,@"errorCode":@0};
}
// Verify each ordinary file through the same held root FD. Metadata reads do not
// consume file bodies, and a file swapped for a link or changed during observation fails.
static BOOL axs_cachekeeper_gurd_file_metadata(const struct stat *left,const struct stat *right) {
 return S_ISREG(right->st_mode) && left->st_dev==right->st_dev && left->st_ino==right->st_ino && left->st_mode==right->st_mode &&
 left->st_nlink==right->st_nlink && left->st_size==right->st_size && left->st_blocks==right->st_blocks &&
 left->st_mtimespec.tv_sec==right->st_mtimespec.tv_sec && left->st_mtimespec.tv_nsec==right->st_mtimespec.tv_nsec &&
 left->st_ctimespec.tv_sec==right->st_ctimespec.tv_sec && left->st_ctimespec.tv_nsec==right->st_ctimespec.tv_nsec;
}
static NSString *axs_cachekeeper_gurd_verify_file(int root,const struct stat *observed,NSArray<NSData *> *components,int *errorCode) {
 int parent=dup(root);if(parent<0) {*errorCode=errno;return @"readError";}
 for(NSUInteger i=0;i+1<components.count;i++) {
  NSMutableData *name=[components[i] mutableCopy];const char zero=0;[name appendBytes:&zero length:1];
  int next=openat(parent,name.bytes,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);int code=next<0 ? errno : 0;
  if(close(parent) && !code) code=errno;parent=next;
  if(code) {if(parent>=0) close(parent);*errorCode=code;return @"readError";}
 }
 NSMutableData *name=[components.lastObject mutableCopy];const char zero=0;[name appendBytes:&zero length:1];
 int file=openat(parent,name.bytes,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);struct stat held,path;
 int code=file<0 ? errno : 0;NSString *failure=code ? @"readError" : nil;
 if(!failure && (fstat(file,&held) || fstatat(parent,name.bytes,&path,AT_SYMLINK_NOFOLLOW))) {code=errno;failure=@"readError";}
 if(!failure && (!axs_cachekeeper_gurd_file_metadata(observed,&held) || !axs_cachekeeper_gurd_file_metadata(&held,&path))) {failure=@"identityChanged";code=ESTALE;}
 if(file>=0 && close(file) && !failure) {code=errno;failure=@"readError";}
 if(close(parent) && !failure) {code=errno;failure=@"readError";}*errorCode=code;return failure;
}
@interface AxsCacheKeeperGurdRun : NSObject
@property(nonatomic) NSUInteger generation,token;
@property(nonatomic,strong) NSDictionary *context,*binding;
@property(nonatomic,strong) NSMutableDictionary *operation;
@property(nonatomic,strong) NSDictionary *scopeProof;
@property(nonatomic,strong) AxsCacheKeeperScanCursor *cursor;
@property(nonatomic,strong) NSMutableDictionary *sampleInodes;
@property(nonatomic) uint64_t sampleLogicalBytes,sampleAllocatedBytes,sampleFiles,sampleEntries;
@property(nonatomic) int sampleRootFD,sampleErrorCode;
@property(nonatomic) NSTimeInterval sampleDeadline;
@property(nonatomic,copy) NSString *sampleFailure,*samplePhase;
@property(nonatomic) BOOL finished,entered;
@property(nonatomic) BOOL expired;
@end
@implementation AxsCacheKeeperGurdRun
@end
@implementation AxsCacheKeeperGurdCache {
 AxsCacheKeeperGurdContextProvider _provider;
 id<AxsCacheKeeperGurdHostSource> _source;
 NSUInteger (^_begin)(void (^expiration)(void));
 void (^_end)(NSUInteger token);
 void (^_observer)(NSDictionary *receipt);
 dispatch_queue_t _queue;
 NSObject *_commitLock;
 _Atomic(unsigned long) _generation;
 _Atomic(BOOL) _background;
 _Atomic(unsigned long) _startedConfiguration;
 _Atomic(unsigned long) _event;
 BOOL _eventStarted;
 NSUInteger _sampleEntryLimit;
 NSUInteger _sampleSliceEntries;
 uint64_t _sampleCounterLimit;
 NSTimeInterval _sampleSeconds;
 NSMutableArray *_operations;
 NSString *_state,*_reason;
 NSDate *_lastUpdated;
 NSDictionary *_runtimeInfo;
 AxsCacheKeeperGurdRun *_run;
 AxsCacheKeeperGurdRun *_platformRun;
}
- (instancetype)initWithContextProvider:(AxsCacheKeeperGurdContextProvider)provider source:(id<AxsCacheKeeperGurdHostSource>)source
 beginTask:(NSUInteger (^)(void (^expiration)(void)))begin endTask:(void (^)(NSUInteger task))end observer:(void (^)(NSDictionary *))observer {
 if(!(self=[super init])) return nil;
 _provider=[provider copy];_source=source ?: [AxsCacheKeeperGurdSource new];_begin=[begin copy];_end=[end copy];_observer=[observer copy];
 _queue=dispatch_queue_create("dev.local.cachekeeper.gurd",DISPATCH_QUEUE_SERIAL);dispatch_queue_set_specific(_queue,(__bridge const void *)self,(__bridge void *)self,NULL);_operations=[NSMutableArray new];_state=@"idle";_reason=@"none";_sampleEntryLimit=200000;_sampleSliceEntries=128;_sampleSeconds=4;_sampleCounterLimit=9007199254740991ULL;_lastUpdated=NSDate.date;
 _commitLock=[NSObject new];_runtimeInfo=axs_cachekeeper_runtime_info();atomic_init(&_generation,1);atomic_init(&_background,NO);atomic_init(&_startedConfiguration,NSUIntegerMax);atomic_init(&_event,0);return self;
}
- (NSDictionary *)axs_cachekeeper_snapshot {
 return @{@"schemaVersion":@1,@"updated":_lastUpdated,@"runtimeInfo":_runtimeInfo,@"family":@"gurd",@"contract":@"aweme412021WhitelistV1",@"state":_state,@"reason":_reason,
 @"restriction":@"unsupported",@"background":@(atomic_load(&_background)),@"operations":[_operations copy]};
}
- (NSDictionary *)receipt {if(dispatch_get_specific((__bridge const void *)self)) return [self axs_cachekeeper_snapshot];__block NSDictionary *result;dispatch_sync(_queue,^{result=[self axs_cachekeeper_snapshot];});return result;}
- (void)axs_cachekeeper_publish {
 _lastUpdated=NSDate.date;_runtimeInfo=axs_cachekeeper_runtime_info();NSDictionary *snapshot=[self axs_cachekeeper_snapshot];if(_observer) dispatch_async(dispatch_get_main_queue(),^{self->_observer(snapshot);});
}
- (void)axs_cachekeeper_record:(AxsCacheKeeperGurdRun *)run {
 NSUInteger index=[_operations indexOfObjectPassingTest:^BOOL(NSDictionary *operation,NSUInteger i,BOOL *stop) {(void)i;(void)stop;return [operation[@"event"] isEqual:run.operation[@"event"]];}];
 if(index==NSNotFound) [_operations addObject:[run.operation copy]];else _operations[index]=[run.operation copy];
 [_operations sortUsingComparator:^NSComparisonResult(NSDictionary *left,NSDictionary *right) {return [left[@"event"] compare:right[@"event"]];}];
 if(_operations.count>16) [_operations removeObjectAtIndex:0];[self axs_cachekeeper_publish];
}
- (NSString *)axs_cachekeeper_basic_reason:(NSDictionary *)context {
 if(![context isKindOfClass:NSDictionary.class] || !axs_cachekeeper_gurd_bool(context[@"valid"]) || ![context[@"valid"] boolValue] ||
 !axs_cachekeeper_state_valid(context[@"appState"]) || !axs_cachekeeper_input_strings(context[@"selected"],axs_cachekeeper_relative_path) ||
 !axs_cachekeeper_gurd_integer(context[@"configuration"],9007199254740991ULL)) return @"configurationInvalid";
 if(!axs_cachekeeper_app_enabled(context[@"appState"])) return @"appDisabled";
 if(![context[@"installation"] isKindOfClass:NSString.class] || ![context[@"installation"] length] || ![context[@"home"] isKindOfClass:NSString.class] || ![context[@"home"] isAbsolutePath]) return @"installationUnverified";
 if(!axs_cachekeeper_gurd_bool(context[@"reportWritable"]) || ![context[@"reportWritable"] boolValue]) return @"reportWriteFailed";
 return nil;
}
- (NSString *)axs_cachekeeper_gate:(AxsCacheKeeperGurdRun *)run {
 if(run.generation!=atomic_load(&_generation) || !atomic_load(&_background)) return @"revoked";
 NSDictionary *current=_provider ? _provider() : nil;NSString *reason=[self axs_cachekeeper_basic_reason:current];if(reason) return reason;
 if(![run.context[@"installation"] isEqual:current[@"installation"]] || ![run.context[@"home"] isEqual:current[@"home"]]) return @"installationChanged";
 for(NSString *key in @[@"configuration",@"appState",@"selected",@"bundle",@"version",@"build"])
  if(![run.context[key] isEqual:current[key]]) return @"configurationChanged";
 if(!run.binding) return !axs_cachekeeper_auto_discover(current[@"appState"]) && ![current[@"selected"] count] ? @"scopeNotAuthorized" : nil;
 NSString *relative=run.binding[@"relative"];
 if(!axs_cachekeeper_relative_path(relative)) return @"scopeInvalid";
 for(NSString *excluded in axs_cachekeeper_exclusions(current[@"appState"])) if(axs_cachekeeper_paths_overlap(relative,excluded)) return @"excludedOverlap";
 BOOL selected=NO;for(NSString *root in current[@"selected"]) if([root isEqual:relative]) selected=YES;
 if(!axs_cachekeeper_auto_discover(current[@"appState"]) && !selected) return @"scopeNotAuthorized";
 @try {reason=[_source validateBinding:run.binding context:current];} @catch(NSException *exception) {(void)exception;return @"sourceException";}
 if(reason) return reason;
 return run.generation!=atomic_load(&_generation) || !atomic_load(&_background) ? @"revoked" : nil;
}
- (void)axs_cachekeeper_finish:(AxsCacheKeeperGurdRun *)run reason:(NSString *)reason {
 if(run.finished) return;run.finished=YES;
 NSString *samplePhase=run.samplePhase;
 NSString *sampleState=reason ? @"cancelled" : (run.sampleFailure ?: run.cursor.state);
 [self axs_cachekeeper_sample_close:run];
 if(samplePhase && run.operation) {
  NSDictionary *partial=[self axs_cachekeeper_sample_snapshot:run state:run.sampleFailure ?: sampleState ?: @"cancelled"];
  run.operation[[samplePhase isEqual:@"before"] ? @"before" : @"after"]=partial;run.sampleInodes=nil;run.samplePhase=nil;
 }
 BOOL submitted=[run.operation[@"submission"] isEqual:@"submitted"] || run.entered;
 if(reason) {
  run.operation[@"reason"]=reason;
  run.operation[@"phase"]=submitted ? @"interruptedAfterSubmission" : [@[@"revoked",@"foreground",@"expired",@"configurationChanged",@"installationChanged"] containsObject:reason] ? @"cancelled" : @"skipped";
  if(submitted) {run.operation[@"observation"]=@"partial";run.operation[@"logicalDecrease"]=@0;run.operation[@"allocatedDecrease"]=@0;}
 }
 if(_run==run || (!_run && run.generation==atomic_load(&_generation))) {
  _state=reason ? (submitted ? @"interrupted" : [reason isEqual:@"appDisabled"] ? @"disabled" : @"blocked") : @"observed";_reason=reason ?: @"none";
 }
 [self axs_cachekeeper_record:run];if(_run==run) _run=nil;
 [self axs_cachekeeper_end_platform_run:run];
}
- (void)axs_cachekeeper_end_platform_run:(AxsCacheKeeperGurdRun *)run {
 NSUInteger token;@synchronized(run) {token=run.token;run.token=0;}
 if(token && _end) {
  if(NSThread.isMainThread) _end(token);else dispatch_async(dispatch_get_main_queue(),^{self->_end(token);});
 }
}
- (NSDictionary *)axs_cachekeeper_sample_snapshot:(AxsCacheKeeperGurdRun *)run state:(NSString *)state {
 return @{@"state":state ?: @"readError",@"files":@(run.sampleFiles),@"logicalBytes":@(run.sampleLogicalBytes),
  @"allocatedBytes":@(run.sampleAllocatedBytes),@"entries":@(run.sampleEntries),@"errorCode":@(MIN(MAX(run.sampleErrorCode,0),255))};
}
- (void)axs_cachekeeper_sample_close:(AxsCacheKeeperGurdRun *)run {
 if(run.cursor) {int closeCode=0;if([run.cursor closeWithErrorCode:&closeCode]) {run.sampleFailure=@"closeError";run.sampleErrorCode=closeCode;}run.cursor=nil;}
 if(run.sampleRootFD>=0) {if(close(run.sampleRootFD)) {run.sampleFailure=@"closeError";run.sampleErrorCode=errno;}run.sampleRootFD=-1;}
}
- (void)axs_cachekeeper_sample_finish:(AxsCacheKeeperGurdRun *)run {
 NSString *phase=run.samplePhase;
 if(!run.sampleFailure) {
  NSString *rootReason=axs_cachekeeper_gurd_binding_reason(run.binding,run.context[@"home"],run.context[@"installation"]);
  if(rootReason) {run.sampleFailure=[rootReason isEqual:@"rootUnavailable"] ? @"readError" : @"identityChanged";run.sampleErrorCode=[run.sampleFailure isEqual:@"readError"] ? errno : ESTALE;}
 }
 NSString *state=run.sampleFailure ?: run.cursor.state ?: @"readError";
 if([state isEqual:@"readError"] && [run.cursor.result[@"scanDiagnostics"][@"errors"].firstObject[@"stage"] isEqual:@"closeDirectory"]) state=@"closeError";
 [self axs_cachekeeper_sample_close:run];
 if(run.sampleFailure) state=run.sampleFailure;
 NSDictionary *sample=[self axs_cachekeeper_sample_snapshot:run state:run.sampleFailure ?: state];
 run.sampleInodes=nil;run.samplePhase=nil;
 if([phase isEqual:@"before"]) {
  run.operation[@"before"]=sample;
  NSString *reason=[self axs_cachekeeper_gate:run];if(!reason && ![sample[@"state"] isEqual:@"complete"]) reason=@"beforeSampleFailed";
  if(reason) {[self axs_cachekeeper_finish:run reason:reason];return;}
  BOOL returned=NO;
  @try {returned=[_source submitBinding:run.binding context:run.context authorization:^BOOL {
   if([self axs_cachekeeper_gate:run]) return NO;
   @synchronized(self->_commitLock) {
    if(run.generation!=atomic_load(&self->_generation) || !atomic_load(&self->_background)) return NO;
    run.entered=YES;run.operation[@"submission"]=@"enteredUnknown";return YES;
   }
  } reason:&reason];} @catch(NSException *exception) {(void)exception;reason=@"hostException";}
  if(!returned) {[self axs_cachekeeper_finish:run reason:reason ?: @"revoked"];return;}
  run.operation[@"submission"]=@"submitted";run.operation[@"phase"]=@"submitted";run.operation[@"observation"]=@"pending";_state=@"submitted";[self axs_cachekeeper_record:run];
  reason=[self axs_cachekeeper_gate:run];if(reason) {[self axs_cachekeeper_finish:run reason:reason];return;}
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),_queue,^{[self axs_cachekeeper_start_sample:run phase:@"after"];});return;
 }
 run.operation[@"after"]=sample;
 NSString *reason=[self axs_cachekeeper_gate:run];if(!reason && ![sample[@"state"] isEqual:@"complete"]) reason=@"afterSampleFailed";
 if(reason) {[self axs_cachekeeper_finish:run reason:reason];return;}
 NSDictionary *before=run.operation[@"before"];uint64_t b=[before[@"logicalBytes"] unsignedLongLongValue],a=[sample[@"logicalBytes"] unsignedLongLongValue];
 uint64_t ba=[before[@"allocatedBytes"] unsignedLongLongValue],aa=[sample[@"allocatedBytes"] unsignedLongLongValue];
 run.operation[@"observation"]=(a<b || aa<ba) ? @"reduced" : (a>b || aa>ba) ? @"increased" : @"unchanged";
 run.operation[@"logicalDecrease"]=@(b>a ? b-a : 0);run.operation[@"allocatedDecrease"]=@(ba>aa ? ba-aa : 0);run.operation[@"phase"]=@"observed";
 [self axs_cachekeeper_finish:run reason:nil];
}
- (void)axs_cachekeeper_start_sample:(AxsCacheKeeperGurdRun *)run phase:(NSString *)phase {
 if(run.finished) return;NSString *reason=[self axs_cachekeeper_gate:run];if(reason) {[self axs_cachekeeper_finish:run reason:reason];return;}
 run.samplePhase=[phase copy];run.sampleFailure=nil;run.sampleErrorCode=0;run.sampleLogicalBytes=0;run.sampleAllocatedBytes=0;run.sampleFiles=0;run.sampleEntries=0;run.sampleInodes=[NSMutableDictionary new];
 run.sampleDeadline=NSProcessInfo.processInfo.systemUptime+_sampleSeconds;
 int rootFD=axs_cachekeeper_gurd_open_root(run.binding);if(rootFD<0) {int code=errno;run.sampleFailure=code==ESTALE ? @"identityChanged" : @"readError";run.sampleErrorCode=code;run.cursor=nil;run.sampleRootFD=-1;[self axs_cachekeeper_sample_finish:run];return;}
 run.sampleRootFD=rootFD;
 NSArray *leaf=[run.binding[@"identity"] lastObject];
 __block __weak AxsCacheKeeperScanCursor *weakCursor=nil;
 AxsCacheKeeperScanCursor *cursor=[[AxsCacheKeeperScanCursor alloc] initWithRootFD:rootFD path:[NSURL fileURLWithPath:run.binding[@"root"]] entryLimit:_sampleEntryLimit depthLimit:64
 metadataObserver:^(const struct stat *info,NSArray<NSData *> *components) {
  run.sampleEntries++;
  if(!components.count && (info->st_dev!=[leaf[0] longLongValue] || info->st_ino!=[leaf[1] unsignedLongLongValue])) run.sampleFailure=@"identityChanged";
  if(S_ISLNK(info->st_mode)) run.sampleFailure=@"linkEncountered";
  else if(!S_ISDIR(info->st_mode) && !S_ISREG(info->st_mode)) run.sampleFailure=@"invalidMetadata";
  if(!run.sampleFailure && S_ISREG(info->st_mode)) run.sampleFailure=axs_cachekeeper_gurd_verify_file(run.sampleRootFD,info,components,&run.sampleErrorCode);
  if(!run.sampleFailure && S_ISREG(info->st_mode)) {
   const uint64_t identity[]={(uint64_t)info->st_dev,(uint64_t)info->st_ino};NSData *key=[NSData dataWithBytes:identity length:sizeof(identity)];
   NSArray *value=@[@(info->st_size),@(info->st_blocks),@(info->st_nlink),@(info->st_mtimespec.tv_sec),@(info->st_mtimespec.tv_nsec),@(info->st_ctimespec.tv_sec),@(info->st_ctimespec.tv_nsec)];
   NSArray *old=run.sampleInodes[key];uint64_t size=info->st_size<0 ? 0 : (uint64_t)info->st_size;
   uint64_t blocks=info->st_blocks<0 ? 0 : (uint64_t)info->st_blocks;
   BOOL overflow=info->st_size<0 || info->st_blocks<0 || blocks>UINT64_MAX/512 || blocks>self->_sampleCounterLimit/512 ||
    run.sampleLogicalBytes>self->_sampleCounterLimit || size>self->_sampleCounterLimit-run.sampleLogicalBytes ||
    run.sampleAllocatedBytes>self->_sampleCounterLimit || (!old && blocks*512>self->_sampleCounterLimit-run.sampleAllocatedBytes);
   if(overflow) {run.sampleFailure=@"invalidMetadata";run.sampleErrorCode=EOVERFLOW;}
   else if(old && ![old isEqual:value]) {run.sampleFailure=@"invalidMetadata";run.sampleErrorCode=ESTALE;}
   else if(!old && run.sampleInodes.count>=65536) run.sampleFailure=@"inodeLimit";
   else {run.sampleLogicalBytes+=size;run.sampleFiles++;if(!old) {run.sampleInodes[key]=value;run.sampleAllocatedBytes+=blocks*512;}}
  }
  if(run.sampleFailure && weakCursor) [weakCursor stopWithState:run.sampleFailure];
 }];
 weakCursor=cursor;run.cursor=cursor;if(run.sampleFailure) [cursor stopWithState:run.sampleFailure];
 run.operation[@"phase"]=[phase isEqual:@"before"] ? @"samplingBefore" : @"submitted";[self axs_cachekeeper_record:run];
 [self axs_cachekeeper_sample_slice:run];
}
- (void)axs_cachekeeper_sample_slice:(AxsCacheKeeperGurdRun *)run {
 if(run.finished) return;NSString *reason=[self axs_cachekeeper_gate:run];
 if(reason) {if(run.cursor && [run.cursor.state isEqual:@"running"]) [run.cursor stopWithState:@"cancelled"];[self axs_cachekeeper_finish:run reason:reason];return;}
 if([run.cursor.state isEqual:@"running"] && _sampleSeconds>0 && NSProcessInfo.processInfo.systemUptime>=run.sampleDeadline)
  [run.cursor stopWithState:@"timeLimit"];
 if([run.cursor.state isEqual:@"running"] && _sampleSeconds==0) [run.cursor stopWithState:@"timeLimit"];
 if([run.cursor.state isEqual:@"running"]) [run.cursor advanceEntries:_sampleSliceEntries seconds:.025];
 if([run.cursor.state isEqual:@"running"] && _sampleSeconds>0 && NSProcessInfo.processInfo.systemUptime<run.sampleDeadline) {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_MSEC),_queue,^{[self axs_cachekeeper_sample_slice:run];});return;
 }
 if([run.cursor.state isEqual:@"running"]) [run.cursor stopWithState:@"timeLimit"];
 if([run.cursor.state isEqual:@"readError"]) {
  NSArray *errors=run.cursor.result[@"scanDiagnostics"][@"errors"];NSDictionary *error=errors.firstObject;
  if(!run.sampleErrorCode) run.sampleErrorCode=[error[@"errorCode"] intValue];
  if(!run.sampleFailure) run.sampleFailure=[error[@"stage"] isEqual:@"closeDirectory"] ? @"closeError" : @"readError";
 }
 [self axs_cachekeeper_sample_finish:run];
}
- (NSDictionary *)axs_cachekeeper_production_scope_for_binding:(NSDictionary *)binding {
 NSDictionary *sourceProof=binding[@"scopeProof"];
#if defined(AXS_CACHEKEEPER_GURD_TESTING)
 if(axs_cachekeeper_gurd_scope_proof_projection(sourceProof) && [sourceProof[@"state"] isEqual:@"complete"] &&
    [sourceProof[@"candidateSource"] isEqual:@"testFixture"]) return [sourceProof copy];
#endif
 // This producer authenticates the fixed entry point, but the host clean/retain
 // predicate is still unproven. Discard any caller-supplied positive claim.
 if(![sourceProof isKindOfClass:NSDictionary.class] || ![sourceProof[@"state"] isEqual:@"scopeUnproven"])
  return axs_cachekeeper_gurd_scope_unproven_default();
 if(!axs_cachekeeper_gurd_scope_proof_projection(sourceProof)) return axs_cachekeeper_gurd_scope_unproven_default();
 return [sourceProof copy];
}
- (void)axs_cachekeeper_prepare:(AxsCacheKeeperGurdRun *)run {
 _run=run;_state=@"running";_reason=@"none";[self axs_cachekeeper_record:run];
 NSString *reason=[self axs_cachekeeper_gate:run];if(reason) {[self axs_cachekeeper_finish:run reason:reason];return;}
 @try {run.binding=[_source prepareWithContext:run.context reason:&reason];} @catch(NSException *exception) {(void)exception;reason=@"sourceException";}
 if(!reason && !run.binding) reason=@"sourceUnavailable";
 if(!reason) {run.scopeProof=[self axs_cachekeeper_production_scope_for_binding:run.binding];run.operation[@"scopeProof"]=run.scopeProof;
  if(![run.scopeProof[@"state"] isEqual:@"complete"]) reason=@"scopeUnproven";}
 if(!reason) reason=[self axs_cachekeeper_gate:run];if(reason) {[self axs_cachekeeper_finish:run reason:reason];return;}
 [self axs_cachekeeper_start_sample:run phase:@"before"];
}
- (void)didEnterBackground {
 NSAssert(NSThread.isMainThread,@"Gurd lifecycle is main-thread confined");
 atomic_store(&_background,YES);if(_eventStarted) return;_eventStarted=YES;
 NSUInteger generation=atomic_load(&_generation);
 NSUInteger event=atomic_fetch_add(&_event,1)+1;
 AxsCacheKeeperGurdRun *run=[AxsCacheKeeperGurdRun new];run.generation=generation;run.sampleRootFD=-1;
 @synchronized(_commitLock) {_platformRun=run;}
 __weak AxsCacheKeeperGurdCache *weakSelf=self;
 // Acquire platform time before any provider IO or source preparation. A synchronous
 // expiration advances the generation and cannot be overwritten by its returned token.
 NSUInteger token=_begin ? _begin(^{
  @synchronized(run) {run.expired=YES;}
  [weakSelf axs_cachekeeper_expire_generation:generation];[weakSelf axs_cachekeeper_end_platform_run:run];
 }) : 0;
 BOOL expired;@synchronized(run) {run.token=token;expired=run.expired;}
 if(expired || generation!=atomic_load(&_generation) || !atomic_load(&_background)) [self axs_cachekeeper_end_platform_run:run];
 dispatch_async(_queue,^{
  BOOL usable=token && generation==atomic_load(&self->_generation) && atomic_load(&self->_background);
  NSDictionary *context=usable && self->_provider ? self->_provider() : nil;run.context=context;
  if(usable && generation==atomic_load(&self->_generation) && atomic_load(&self->_background)) atomic_store(&self->_startedConfiguration,axs_cachekeeper_gurd_integer(context[@"configuration"],9007199254740991ULL) ? [context[@"configuration"] unsignedIntegerValue] : NSUIntegerMax);
  run.operation=[@{@"event":@(event),@"runtimeInfo":axs_cachekeeper_runtime_info(),@"configuration":axs_cachekeeper_gurd_integer(context[@"configuration"],9007199254740991ULL) ? context[@"configuration"] : @0,
   @"phase":@"preparing",@"reason":@"none",@"submission":@"notSubmitted",@"hostCompletion":@"notProvided",@"observation":@"notObserved",@"scopeProof":axs_cachekeeper_gurd_scope_unproven_default(),@"before":axs_cachekeeper_gurd_no_sample(),
   @"after":axs_cachekeeper_gurd_no_sample(),@"logicalDecrease":@0,@"allocatedDecrease":@0,@"physicalUniqueReclaimed":@"notMeasured"} mutableCopy];
  NSString *reason=usable ? [self axs_cachekeeper_basic_reason:context] : @"noBackgroundTime";
  if(reason) [self axs_cachekeeper_finish:run reason:reason];else [self axs_cachekeeper_prepare:run];
 });
}
- (void)axs_cachekeeper_revoke:(NSString *)reason {
 unsigned long revoked;AxsCacheKeeperGurdRun *platform;@synchronized(_commitLock) {revoked=atomic_fetch_add(&_generation,1);platform=_platformRun;}
 if(platform && platform.generation<=revoked) [self axs_cachekeeper_end_platform_run:platform];
 dispatch_async(_queue,^{if(self->_run && self->_run.generation<=revoked) [self axs_cachekeeper_finish:self->_run reason:reason];else if(!self->_run) {self->_state=@"idle";self->_reason=reason;[self axs_cachekeeper_publish];}});
}
- (void)didBecomeActive {
 NSAssert(NSThread.isMainThread,@"Gurd lifecycle is main-thread confined");@synchronized(_commitLock) {atomic_store(&_background,NO);atomic_store(&_startedConfiguration,NSUIntegerMax);_eventStarted=NO;[self axs_cachekeeper_revoke:@"foreground"];}
}
- (void)refreshForConfiguration:(NSUInteger)configuration {
 NSAssert(NSThread.isMainThread,@"Gurd lifecycle is main-thread confined");
 NSUInteger generation=atomic_load(&_generation);
 // An immediate access revocation may already have queued a successor whose
 // provider will adopt this policy. Evaluate after that preparation, without
 // making UIKit wait for provider IO or cancelling the successor twice.
 dispatch_async(_queue,^{
  if(generation!=atomic_load(&self->_generation)) return;
  unsigned long started=atomic_load(&self->_startedConfiguration);
  if(started!=NSUIntegerMax && configuration<=started) return;
  dispatch_async(dispatch_get_main_queue(),^{
   if(generation!=atomic_load(&self->_generation)) return;
   unsigned long current=atomic_load(&self->_startedConfiguration);
   if(current!=NSUIntegerMax && configuration<=current) return;
   [self refresh];
  });
 });
}
- (void)refresh {
 NSAssert(NSThread.isMainThread,@"Gurd lifecycle is main-thread confined");BOOL background=atomic_load(&_background);_eventStarted=NO;[self axs_cachekeeper_revoke:@"configurationChanged"];if(background) [self didEnterBackground];
}
- (void)axs_cachekeeper_expire_generation:(NSUInteger)generation {
 @synchronized(_commitLock) {unsigned long expected=generation;
 if(!atomic_compare_exchange_strong(&_generation,&expected,generation+1)) return;}
 dispatch_async(_queue,^{if(self->_run && self->_run.generation==generation) [self axs_cachekeeper_finish:self->_run reason:@"expired"];});
}
- (void)expireBackgroundTime {
 AxsCacheKeeperGurdRun *run;@synchronized(_commitLock) {run=_platformRun;}
 if(!run) return;@synchronized(run) {run.expired=YES;}
 [self axs_cachekeeper_expire_generation:run.generation];[self axs_cachekeeper_end_platform_run:run];
}
- (void)restoreReceipt:(id)receipt {
 [self restoreReceipt:receipt completion:nil];
}
- (void)restoreReceipt:(id)receipt completion:(void (^)(void))completion {
 dispatch_async(_queue,^{
  [self axs_cachekeeper_restore_receipt:receipt];
  if(completion) dispatch_async(dispatch_get_main_queue(),completion);
 });
}
- (void)axs_cachekeeper_restore_receipt:(id)receipt {
  if(!receipt) return;
  NSDictionary *validated=axs_cachekeeper_gurd_receipt_projection(receipt);id history=validated[@"operations"];
  if(self->_run || self->_operations.count || !validated || ![history isKindOfClass:NSArray.class] || [history count]>16) {self->_reason=@"historyRejected";[self axs_cachekeeper_publish];return;}
  NSMutableArray *closed=[NSMutableArray new];NSUInteger previous=0;
  for(id value in history) {
   NSDictionary *operation=axs_cachekeeper_gurd_operation_projection(value);
   if(!operation || [operation[@"event"] unsignedIntegerValue]<=previous) {self->_reason=@"historyRejected";[self axs_cachekeeper_publish];return;}
   previous=[operation[@"event"] unsignedIntegerValue];NSMutableDictionary *restored=[operation mutableCopy];
   if([@[@"preparing",@"samplingBefore",@"submitted"] containsObject:restored[@"phase"]]) {
    BOOL submitted=[@[@"submitted",@"enteredUnknown"] containsObject:restored[@"submission"]];
    restored[@"phase"]=submitted ? @"interruptedAfterSubmission" : @"cancelled";restored[@"reason"]=@"historyInterrupted";restored[@"observation"]=submitted ? @"partial" : @"notObserved";
   }
   [closed addObject:[restored copy]];atomic_store(&self->_event,MAX(atomic_load(&self->_event),[restored[@"event"] unsignedIntegerValue]));
  }
  self->_operations=closed;self->_lastUpdated=validated[@"updated"];self->_runtimeInfo=validated[@"runtimeInfo"];NSDictionary *snapshot=[self axs_cachekeeper_snapshot];if(self->_observer) dispatch_async(dispatch_get_main_queue(),^{self->_observer(snapshot);});
}
#if defined(AXS_CACHEKEEPER_GURD_TESTING)
- (void)axs_cachekeeper_setSampleEntryLimit:(NSUInteger)entries seconds:(NSTimeInterval)seconds {
 dispatch_sync(_queue,^{self->_sampleEntryLimit=MIN(entries,(NSUInteger)200000);self->_sampleSeconds=MIN(MAX(seconds,0),4);});
}
- (void)axs_cachekeeper_setSampleSliceEntries:(NSUInteger)entries {
 dispatch_sync(_queue,^{self->_sampleSliceEntries=MAX((NSUInteger)1,MIN(entries,(NSUInteger)512));});
}
- (void)axs_cachekeeper_setSampleCounterLimit:(uint64_t)limit {
 dispatch_sync(_queue,^{self->_sampleCounterLimit=MIN(limit,9007199254740991ULL);});
}
#endif

@end
