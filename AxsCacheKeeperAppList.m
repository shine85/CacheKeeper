#import "AxsCacheKeeperAppList.h"
#import "AxsCacheKeeperPolicy.h"
#include <errno.h>
#include <math.h>
#include <sys/stat.h>

static BOOL axs_cachekeeper_source_strings(id value, BOOL (*predicate)(NSString *)) {
    if (![value isKindOfClass:NSArray.class]) return NO;
    for (id item in value) if (![item isKindOfClass:NSString.class] || (predicate && !predicate(item))) return NO;
    return YES;
}
static BOOL axs_cachekeeper_source_counter(id value) {
    return [value isKindOfClass:NSNumber.class] && isfinite([value doubleValue]) && [value doubleValue]>=0;
}
static BOOL axs_cachekeeper_source_schema(id value, NSString *name) {
    if ([name isEqual:@"favorites.plist"]) return axs_cachekeeper_source_strings(value,NULL);
    if (![value isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *dictionary=value;
    if ([name isEqual:@"batch.plist"]) {
        if (dictionary[@"remaining"] && !axs_cachekeeper_source_strings(dictionary[@"remaining"],axs_cachekeeper_bundle_id)) return NO;
        for (NSString *field in @[@"total",@"completed"])
            if (dictionary[field] && !axs_cachekeeper_source_counter(dictionary[field])) return NO;
        return YES;
    }
    if ([name hasPrefix:@"Status/"] && [name hasSuffix:@".auto.plist"]) {
        for (NSString *field in @[@"removed",@"bytes",@"failed",@"lastBytes",@"confirmedRemoved",@"confirmedBytes",@"lastRemoved"])
            if (dictionary[field] && !axs_cachekeeper_source_counter(dictionary[field])) return NO;
        if (dictionary[@"updated"] && ![dictionary[@"updated"] isKindOfClass:NSDate.class]) return NO;
        if (dictionary[@"message"] && ![dictionary[@"message"] isKindOfClass:NSString.class]) return NO;
        return YES;
    }
    if ([name isEqual:@"appEnabled.plist"]) {
        for (id state in dictionary.allValues) {
            if ([state isKindOfClass:NSNumber.class]) continue;
            if (![state isKindOfClass:NSDictionary.class]) return NO;
            for (NSString *field in @[@"enabled",@"urlCache",@"autoDiscover",@"restrict"])
                if (state[field] && ![state[field] isKindOfClass:NSNumber.class]) return NO;
            if (state[@"mode"] && ![@[@"auto",@"prevent",@"clean"] containsObject:state[@"mode"]]) return NO;
            for (NSString *field in @[@"logPaths",@"excludedPaths"])
                if (state[field] && !axs_cachekeeper_source_strings(state[field],axs_cachekeeper_relative_path)) return NO;
        }
        return YES;
    }
    if ([name isEqual:@"directories.plist"]) {
        for (id paths in dictionary.allValues) if (!axs_cachekeeper_source_strings(paths,axs_cachekeeper_relative_path)) return NO;
        return YES;
    }
    if ([name isEqual:@"snapshots.plist"]) {
        for (id record in dictionary.allValues) {
            if (![record isKindOfClass:NSDictionary.class]) return NO;
            if (record[@"rows"] && ![record[@"rows"] isKindOfClass:NSArray.class]) return NO;
        }
        return YES;
    }
    return NO;
}

@interface AxsCacheKeeperAppListSource : NSObject
@property(nonatomic,copy) NSString *folder;
@property(nonatomic,copy) AxsCacheKeeperApplicationsProvider applicationsProvider;
@property(nonatomic,strong) NSMutableDictionary *stamps;
@property(nonatomic,strong) NSMutableDictionary *values;
@property(nonatomic,copy) NSArray *apps;
@property(nonatomic,copy) NSString *appsError;
@property(nonatomic) BOOL appsLoaded;
@property(nonatomic,strong) NSDictionary *lastPayload;
@property(nonatomic,strong) NSDictionary *lastSnapshot;
@property(nonatomic) NSUInteger revision;
- (NSDictionary *)axs_cachekeeper_snapshot:(BOOL)refreshApplications;
@end

@implementation AxsCacheKeeperAppListSource
- (instancetype)init {
    if (!(self=[super init])) return nil;
    _stamps=[NSMutableDictionary new];_values=[NSMutableDictionary new];_apps=@[];
    return self;
}
- (id)axs_cachekeeper_read:(NSString *)name array:(BOOL)array errors:(NSMutableDictionary *)errors {
    NSString *path=[self.folder stringByAppendingPathComponent:name];
    id empty=array ? @[] : @{};
    struct stat info;
    if (stat(path.fileSystemRepresentation,&info)) {
        if (errno==ENOENT) {
            self.stamps[name]=@[@"missing"];self.values[name]=empty;
            return empty;
        }
        errors[name]=[NSString stringWithFormat:@"无法读取来源（errno %d）",errno];
        return self.values[name] ?: empty;
    }
    if (!S_ISREG(info.st_mode)) {
        errors[name]=@"来源不是普通文件";
        return self.values[name] ?: empty;
    }
    NSArray *stamp=@[@(info.st_dev),@(info.st_ino),@(info.st_size),
        @(info.st_mtimespec.tv_sec),@(info.st_mtimespec.tv_nsec),@(info.st_ctimespec.tv_sec),@(info.st_ctimespec.tv_nsec)];
    if ([stamp isEqual:self.stamps[name]]) return self.values[name] ?: empty;
    NSError *error=nil;
    id value=[AxsCacheKeeperAppList axs_cachekeeper_read_source_at_path:path name:name error:&error];
    if (error) {
        errors[name]=[NSString stringWithFormat:@"来源读取或字段校验失败（%ld）",(long)error.code];
        return self.values[name] ?: empty;
    }
    if (!value) {
        self.stamps[name]=@[@"missing"];self.values[name]=empty;
        return empty;
    }
    self.stamps[name]=stamp;self.values[name]=value;
    return value;
}
- (NSDictionary *)axs_cachekeeper_snapshot:(BOOL)refreshApplications {
    NSMutableDictionary *errors=[NSMutableDictionary new];
    NSDictionary *states=[self axs_cachekeeper_read:@"appEnabled.plist" array:NO errors:errors];
    NSDictionary *directories=[self axs_cachekeeper_read:@"directories.plist" array:NO errors:errors];
    NSArray *favorites=[self axs_cachekeeper_read:@"favorites.plist" array:YES errors:errors];
    NSDictionary *history=[self axs_cachekeeper_read:@"snapshots.plist" array:NO errors:errors];
    NSDictionary *batch=[self axs_cachekeeper_read:@"batch.plist" array:NO errors:errors];
    if (refreshApplications || !self.appsLoaded) {
        NSError *error=nil;
        NSArray *apps=self.applicationsProvider(&error);
        BOOL valid=[apps isKindOfClass:NSArray.class];
        if (valid) for (id app in apps) {
            if (![app isKindOfClass:NSDictionary.class] || !axs_cachekeeper_bundle_id(app[@"id"]) ||
                ![app[@"name"] isKindOfClass:NSString.class] || ![app[@"pinyin"] isKindOfClass:NSString.class]) { valid=NO;break; }
        }
        if (valid && !error) { self.apps=[apps copy];self.appsLoaded=YES;self.appsError=nil; }
        else self.appsError=error ? [NSString stringWithFormat:@"系统应用列表读取失败（%ld）",(long)error.code] : @"系统应用列表不可用";
    }
    if (self.appsError) errors[@"applications"]=self.appsError;
    NSMutableDictionary *statuses=[NSMutableDictionary new];
    NSMutableSet *statusFiles=[NSMutableSet new];
    for (NSString *bundle in states) {
        if (!axs_cachekeeper_bundle_id(bundle) || !axs_cachekeeper_app_enabled(states[bundle])) continue;
        NSString *name=[NSString stringWithFormat:@"Status/%@.auto.plist",bundle];
        [statusFiles addObject:name];
        NSDictionary *status=[self axs_cachekeeper_read:name array:NO errors:errors];
        // Missing/unreadable-without-history is not a successful zero-byte cleanup receipt.
        if (self.values[name] && ![self.stamps[name] isEqual:@[@"missing"]]) statuses[bundle]=status;
    }
    for (NSString *name in self.values.allKeys) if ([name hasPrefix:@"Status/"] && ![statusFiles containsObject:name]) {
        [self.values removeObjectForKey:name];[self.stamps removeObjectForKey:name];
    }
    NSDictionary *payload=@{@"apps":self.apps,@"states":states,@"directories":directories,@"favorites":favorites,
        @"history":history,@"batch":batch,@"statuses":[statuses copy],@"errors":[errors copy]};
    // Content comparison belongs to the reader queue too; the UI only compares a revision.
    if ([payload isEqual:self.lastPayload]) return self.lastSnapshot;
    self.lastPayload=payload;
    NSMutableDictionary *snapshot=[payload mutableCopy];snapshot[@"revision"]=@(++self.revision);
    self.lastSnapshot=[snapshot copy];
    return self.lastSnapshot;
}
@end

@interface AxsCacheKeeperAppList ()
@property(nonatomic,strong) dispatch_queue_t queue;
@property(nonatomic,copy) AxsCacheKeeperAppListProvider provider;
@property(nonatomic,copy) AxsCacheKeeperAppListCompletion completion;
@property(nonatomic) BOOL loading;
@property(nonatomic) BOOL pending;
@property(nonatomic) BOOL pendingApplications;
@property(nonatomic) NSUInteger generation;
@end

@implementation AxsCacheKeeperAppList
+ (id)axs_cachekeeper_read_source_at_path:(NSString *)path name:(NSString *)name error:(NSError **)error {
    if (error) *error=nil;
    struct stat info;
    if (stat(path.fileSystemRepresentation,&info)) {
        int failure=errno;
        if (failure!=ENOENT && error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:failure userInfo:nil];
        return nil;
    }
    if (!S_ISREG(info.st_mode)) {
        if (error) *error=[NSError errorWithDomain:@"dev.local.cachekeeper.app-list" code:2 userInfo:@{NSLocalizedDescriptionKey:@"来源不是普通文件"}];
        return nil;
    }
    NSError *readError=nil;
    NSData *data=[NSData dataWithContentsOfFile:path options:0 error:&readError];
    id value=data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:&readError] : nil;
    if (!value || !axs_cachekeeper_source_schema(value,name)) {
        if (error) *error=readError ?: [NSError errorWithDomain:@"dev.local.cachekeeper.app-list" code:3 userInfo:@{NSLocalizedDescriptionKey:@"来源字段格式无效"}];
        return nil;
    }
    return value;
}
- (instancetype)initWithProvider:(AxsCacheKeeperAppListProvider)provider completion:(AxsCacheKeeperAppListCompletion)completion {
    if (!(self=[super init])) return nil;
    NSParameterAssert(provider);NSParameterAssert(completion);
    _provider=[provider copy];_completion=[completion copy];
    _queue=dispatch_queue_create("dev.local.cachekeeper.app-list",DISPATCH_QUEUE_SERIAL);
    return self;
}
- (instancetype)initWithFolder:(NSString *)folder applicationsProvider:(AxsCacheKeeperApplicationsProvider)provider completion:(AxsCacheKeeperAppListCompletion)completion {
    AxsCacheKeeperAppListSource *source=[AxsCacheKeeperAppListSource new];
    source.folder=folder;source.applicationsProvider=provider;
    return [self initWithProvider:^NSDictionary *(BOOL refreshApplications) {
        return [source axs_cachekeeper_snapshot:refreshApplications];
    } completion:completion];
}
- (void)requestRefreshApplications:(BOOL)refreshApplications {
    NSAssert(NSThread.isMainThread,@"List requests must be made on the main thread");
    if (self.loading) { self.pending=YES;self.pendingApplications|=refreshApplications;return; }
    self.loading=YES;
    NSUInteger generation=self.generation;
    dispatch_async(self.queue,^{
        @autoreleasepool {
            NSDictionary *snapshot=self.provider(refreshApplications);
            dispatch_async(dispatch_get_main_queue(),^{
                self.loading=NO;
                if (generation==self.generation && snapshot) self.completion(snapshot);
                if (self.pending) {
                    BOOL refresh=self.pendingApplications;self.pending=NO;self.pendingApplications=NO;
                    [self requestRefreshApplications:refresh];
                }
            });
        }
    });
}
- (void)invalidate {
    NSAssert(NSThread.isMainThread,@"List invalidation must be made on the main thread");
    self.generation++;self.pending=NO;self.pendingApplications=NO;
}
+ (NSArray<NSDictionary *> *)sectionsForApps:(NSArray<NSDictionary *> *)apps states:(NSDictionary *)states favorites:(NSSet<NSString *> *)favorites tab:(NSInteger)tab query:(NSString *)query {
    query=query ?: @"";
    NSMutableArray *matches=[NSMutableArray new];
    for (NSDictionary *app in apps) {
        NSString *name=app[@"name"], *bundle=app[@"id"], *pinyin=app[@"pinyin"] ?: name;
        NSString *compact=[pinyin stringByReplacingOccurrencesOfString:@" " withString:@""];
        if (query.length && ![name localizedCaseInsensitiveContainsString:query] &&
            ![bundle localizedCaseInsensitiveContainsString:query] && ![pinyin localizedCaseInsensitiveContainsString:query] &&
            ![compact localizedCaseInsensitiveContainsString:query]) continue;
        if (tab==0 && !axs_cachekeeper_app_enabled(states[bundle])) continue;
        if (tab==1 && ![app[@"source"] isEqual:@"user"]) continue;
        if (tab==2 && ![app[@"source"] isEqual:@"troll"]) continue;
        if (tab==3 && ![favorites containsObject:bundle]) continue;
        [matches addObject:app];
    }
    [matches sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b) {
        NSComparisonResult result=[a[@"pinyin"] localizedStandardCompare:b[@"pinyin"]];
        return result==NSOrderedSame ? [a[@"id"] compare:b[@"id"]] : result;
    }];
    NSMutableDictionary *byLetter=[NSMutableDictionary new];
    for (NSDictionary *app in matches) {
        NSString *pinyin=app[@"pinyin"];
        NSString *letter=pinyin.length ? [[pinyin substringToIndex:1] uppercaseString] : @"#";
        unichar character=[letter characterAtIndex:0];
        if (character<'A' || character>'Z') letter=@"#";
        NSMutableArray *group=byLetter[letter];
        if (!group) { group=[NSMutableArray new];byLetter[letter]=group; }
        [group addObject:app];
    }
    NSArray *letters=[byLetter.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a,NSString *b) {
        if ([a isEqual:b]) return NSOrderedSame;
        if ([a isEqual:@"#"]) return NSOrderedDescending;
        if ([b isEqual:@"#"]) return NSOrderedAscending;
        return [a compare:b];
    }];
    NSMutableArray *sections=[NSMutableArray new];
    for (NSString *letter in letters) [sections addObject:@{@"title":letter,@"apps":[byLetter[letter] copy]}];
    return [sections copy];
}
@end
