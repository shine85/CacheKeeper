#import "AxsCacheKeeperDiagnostics.h"
#import "AxsCacheKeeperPolicy.h"

static NSDictionary *AxsCacheKeeperDiagnosticRead(NSString *folder,NSString *name) {
    NSError *error=nil;
    NSData *data=[NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:name] options:0 error:&error];
    if (!data) return @{@"state":([error.domain isEqual:NSCocoaErrorDomain] && error.code==NSFileReadNoSuchFileError) ? @"missing" : @"unreadable",@"errorCode":@(error.code)};
    id value=[NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:&error];
    if (![value isKindOfClass:NSDictionary.class]) return @{@"state":@"invalid",@"errorCode":@(error.code)};
    return @{@"state":@"available",@"data":value};
}
static NSDictionary *AxsCacheKeeperDiagnosticInspection(NSString *folder,NSString *bundle,NSString *path) {
    if (!axs_cachekeeper_bundle_id(bundle) || !axs_cachekeeper_relative_path(path)) return nil;
    id reports=AxsCacheKeeperDiagnosticRead(folder,[NSString stringWithFormat:@"Status/%@.inspection.plist",bundle])[@"data"][@"reports"];
    if (![reports isKindOfClass:NSDictionary.class]) return nil;
    id report=reports[path];return [report isKindOfClass:NSDictionary.class] ? report : nil;
}
static BOOL AxsCacheKeeperDiagnosticBooleansValid(NSDictionary *record,NSArray *keys) {
    for (NSString *key in keys) if (record[key] && ![record[key] isKindOfClass:NSNumber.class]) return NO;
    return YES;
}

// 白名单投影：自由文本与未知字段永不原样进入分享文件。
@interface AxsCacheKeeperDiagnosticRedactor : NSObject
@property(nonatomic,strong) NSMutableDictionary *aliases;
@property(nonatomic,strong) NSSet *technicalNames;
- (NSString *)axs_cachekeeper_path:(NSString *)path;
- (NSDictionary *)axs_cachekeeper_record:(NSDictionary *)record;
@end
@implementation AxsCacheKeeperDiagnosticRedactor
- (instancetype)init {
    self=[super init];if (!self) return nil;
    _aliases=[NSMutableDictionary new];
    _technicalNames=[NSSet setWithArray:@[@"Library",@"Caches",@"Cache",@"cache",@"tmp",@"Documents",@"Downloads",@"Inbox",@"Preferences",@"Cookies",@"Keychains",@"Application Support",@"HTTPStorages",@"SplashBoard",@"Saved Application State",@"Logs",@"WebKit",@"NetworkCache",@"Version 16",@"Blobs",@"Records",@"Resource",@"WebsiteData",@"SystemData",@"com.apple.WebKit.GPU",@"com.apple.WebKit.WebContent",@"com.apple.WebKit.Networking",@"com.apple.nsurlsessiond",@"com.baidu.netdisk",@"group.app.swiftgram.ios",@"telegram-data",@"postbox",@"db",@"db_sqlite",@"db_sqlite-wal",@"db_sqlite-shm",@"Cache.db",@"Cache.db-wal",@"Cache.db-shm",@"media",@"storage",@"cache-storage",@"animation-cache",@"accounts-metadata",@"Group",@"Group:group.app.swiftgram.ios",@"容器",@"安装包",@"本目录"]];
    return self;
}
- (NSString *)axs_cachekeeper_alias:(NSString *)value {
    if (!self.aliases[value]) self.aliases[value]=[NSString stringWithFormat:@"<匿名%lu>",(unsigned long)self.aliases.count+1];
    return self.aliases[value];
}
- (NSString *)axs_cachekeeper_path:(NSString *)path {
    if (![path isKindOfClass:NSString.class]) return @"<无效路径>";
    if ([path hasPrefix:@"/"]) return @"<绝对路径已隐藏>";
    NSMutableArray *parts=[NSMutableArray new];
    NSSet *extensions=[NSSet setWithArray:@[@"pdf",@"db",@"sqlite",@"plist",@"json",@"log",@"js",@"html",@"mp4",@"mov",@"jpg",@"png",@"zip",@"tmp"]];
    for (NSString *component in [path componentsSeparatedByString:@"/"]) {
        if ([self.technicalNames containsObject:component]) { [parts addObject:component];continue; }
        if ([component hasPrefix:@"Group:"]) {
            NSString *identifier=[component substringFromIndex:6];
            [parts addObject:[@"Group:" stringByAppendingString:[self.technicalNames containsObject:identifier] ? identifier : [self axs_cachekeeper_alias:identifier]]];continue;
        }
        NSString *prefix=@"";
        for (NSString *candidate in @[@"account-",@"telegram-cloud-document-",@"telegram-cloud-photo-size-",@"telegram-peer-photo-size-"])
            if ([component hasPrefix:candidate]) {prefix=candidate;break;}
        NSString *extension=component.pathExtension.lowercaseString;
        NSString *suffix=[component hasSuffix:@"_partial"] ? @"_partial" : ([extensions containsObject:extension] ? [@"." stringByAppendingString:extension] : @"");
        NSString *identity=suffix.length ? [component substringToIndex:component.length-suffix.length] : component;
        [parts addObject:[NSString stringWithFormat:@"%@%@%@",prefix,[self axs_cachekeeper_alias:identity],suffix]];
    }
    return [parts componentsJoinedByString:@"/"];
}
- (NSDictionary *)axs_cachekeeper_record:(NSDictionary *)record {
    if (![record isKindOfClass:NSDictionary.class]) return @{@"invalidRecord":@YES};
    NSMutableDictionary *out=[NSMutableDictionary new];
    NSArray *numbers=@[@"bytes",@"files",@"count",@"nlink",@"removed",@"failed",@"failures",@"changed",@"recent",@"remaining",@"remainingBytes",@"deferred",@"deferredBytes",@"unresolved",@"unresolvedBytes",@"protected",@"protectedBytes",@"retainedSubtreeCount",@"lastRemoved",@"lastBytes",@"endReason",@"links",@"hardLinks",@"symlinks",@"hidden",@"twinBytes",@"twinFailures",@"twinScanned",@"result",@"errorCode",@"complete",@"coverageComplete",@"measurementComplete",@"cancelled",@"checking",@"skipped",@"manageable",@"twinCoverageComplete",@"twinScanTruncated",@"twinDisplayTruncated",@"linkFilesTruncated",@"enabled",@"autoDiscover",@"urlCache",@"prevent",@"applied",@"total",@"completed",@"remainingCount"];
    NSMutableArray *invalid=[NSMutableArray new];
    for (NSString *key in numbers) if (record[key] && ![record[key] isKindOfClass:NSNumber.class]) [invalid addObject:key];
    for (NSString *key in @[@"updated",@"started"]) if (record[key] && ![record[key] isKindOfClass:NSDate.class]) [invalid addObject:key];
    for (NSString *key in @[@"directories",@"reports",@"types",@"ages",@"data"]) if (record[key] && ![record[key] isKindOfClass:NSDictionary.class]) [invalid addObject:key];
    for (NSString *key in @[@"effectivePaths",@"discoveredPaths",@"excludedPaths",@"logPaths",@"rows",@"previousRows",@"recentScans",@"largest",@"largestHardLinks",@"linkTwins",@"retainedSubtrees",@"tasks"]) if (record[key] && ![record[key] isKindOfClass:NSArray.class]) [invalid addObject:key];
    if (invalid.count) {out[@"invalidRecord"]=@YES;out[@"invalidFields"]=invalid;}
    for (NSString *key in numbers) if ([record[key] isKindOfClass:NSNumber.class]) out[key]=record[key];
    for (NSString *key in @[@"updated",@"started"]) if ([record[key] isKindOfClass:NSDate.class]) out[key]=@([record[key] timeIntervalSince1970]);
    for (NSString *key in @[@"path",@"source",@"twin"]) if (record[key]) out[key]=[self axs_cachekeeper_path:record[key]];
    if (axs_cachekeeper_bundle_id(record[@"bundle"])) out[@"bundle"]=record[@"bundle"];
    NSSet *values=[NSSet setWithArray:@[@"auto",@"clean",@"prevent",@"waiting",@"running",@"complete",@"error",@"paused",@"cache",@"log",@"data",@"mixed",@"unknown",@"scan",@"inspection",@"pending",@"submitted",@"finished",@"partial",@"stopped",@"notStarted",@"timeout",@"conflict",@"available",@"missing",@"unreadable",@"invalid",@"空文件",@"SQLite 数据库",@"二进制 plist",@"媒体文件头",@"归档或压缩文件",@"JSON 数据",@"文本头特征（用途未定）",@"未知二进制",@"数据或登录态名称特征"]];
    for (NSString *key in @[@"state",@"phase",@"mode",@"kind",@"purgeClassification",@"type",@"outcome"])
        if ([record[key] isKindOfClass:NSString.class]) out[key]=[values containsObject:record[key]] ? record[key] : @"unknown";
    for (NSString *key in @[@"error",@"message",@"reason",@"evidence",@"purgeEvidence",@"unresolvedEvidence"]) {
        NSString *text=record[key];if (![text isKindOfClass:NSString.class] || !text.length) continue;
        // 仅导出原因类别；NSError 原文可能带完整路径、URL 和账号，不拼接原文。
        NSMutableArray *categories=[NSMutableArray new];
        for (NSString *word in @[@"保留",@"挂起",@"进程",@"依赖",@"读取",@"写入",@"失败",@"未知",@"近期",@"恢复",@"权限",@"规则",@"未遍历",@"取消",@"超时"])
            if ([text containsString:word]) [categories addObject:word];
        out[[key stringByAppendingString:@"Present"]]=@YES;
        out[[key stringByAppendingString:@"Categories"]]=categories;
    }
    for (NSString *key in @[@"effectivePaths",@"discoveredPaths",@"excludedPaths",@"logPaths"]) if ([record[key] isKindOfClass:NSArray.class]) {
        NSMutableArray *paths=[NSMutableArray new];for (id path in record[key]) [paths addObject:[self axs_cachekeeper_path:path]];out[key]=paths;
    }
    for (NSString *key in @[@"rows",@"previousRows",@"recentScans",@"largest",@"largestHardLinks",@"linkTwins",@"retainedSubtrees",@"tasks"]) if ([record[key] isKindOfClass:NSArray.class]) {
        NSMutableArray *items=[NSMutableArray new];for (id item in record[key]) [items addObject:[self axs_cachekeeper_record:item]];out[key]=items;
    }
    for (NSString *key in @[@"directories",@"reports"]) if ([record[key] isKindOfClass:NSDictionary.class]) {
        NSMutableArray *items=[NSMutableArray new];
        for (NSString *path in [record[key] allKeys]) {
            NSMutableDictionary *item=[[self axs_cachekeeper_record:record[key][path]] mutableCopy];item[@"path"]=[self axs_cachekeeper_path:path];[items addObject:item];
        }
        out[key]=items;
    }
    for (NSString *key in @[@"types",@"ages"]) if ([record[key] isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *groups=[NSMutableDictionary new];
        for (NSString *name in record[key]) {
            BOOL known=[values containsObject:name] || [@[@"不足 60 秒",@"60 秒至 1 天",@"1 至 30 天",@"30 天以上"] containsObject:name];
            id value=record[key][name];groups[known ? name : [self axs_cachekeeper_alias:name]]=[value isKindOfClass:NSNumber.class] ? value : [self axs_cachekeeper_record:value];
        }out[key]=groups;
    }
    if ([record[@"data"] isKindOfClass:NSDictionary.class]) out[@"data"]=[self axs_cachekeeper_record:record[@"data"]];
    return out;
}
@end

@interface AxsCacheKeeperDiagnostics ()
@property(nonatomic,copy) NSString *folder;
@property(nonatomic,strong) NSArray<NSString *> *bundles;
@property(nonatomic) BOOL running;
@property(nonatomic,copy) NSString *status;
@property(nonatomic,copy) NSString *configurationError;
@property(nonatomic,strong) NSMutableArray<NSMutableDictionary *> *tasks;
@property(nonatomic) NSUInteger index;
@property(nonatomic) NSTimeInterval lastProgress;
@property(nonatomic,strong) NSDate *lastUpdated;
@property(nonatomic,strong) NSDate *started;
@end
@implementation AxsCacheKeeperDiagnostics
- (instancetype)initWithFolder:(NSString *)folder {
    self=[super init];if (!self) return nil;
    _folder=[folder copy];_tasks=[NSMutableArray new];
    NSMutableSet *bundles=[NSMutableSet new];
    for (NSString *file in @[@"appEnabled.plist",@"directories.plist"]) {
        NSDictionary *read=AxsCacheKeeperDiagnosticRead(folder,file);
        if (![@[@"available",@"missing"] containsObject:read[@"state"]]) _configurationError=@"配置记录无法读取，先导出现有记录查看读取状态。";
        for (id bundle in [read[@"data"] allKeys]) if (axs_cachekeeper_bundle_id(bundle)) [bundles addObject:bundle];
    }
    _bundles=[bundles.allObjects sortedArrayUsingSelector:@selector(compare:)];
    _status=[NSString stringWithFormat:@"已配置 %lu 个 APP；可直接导出现有记录，或开始串行补采。",(unsigned long)_bundles.count];
    return self;
}
- (BOOL)axs_cachekeeper_inspection_busy {
    NSDictionary *request=AxsCacheKeeperDiagnosticRead(self.folder,@"inspectionRequest.plist")[@"data"];
    if (!AxsCacheKeeperDiagnosticBooleansValid(request,@[@"cancel"])) return YES;
    if (![request[@"token"] isKindOfClass:NSString.class] || [request[@"cancel"] boolValue]) return NO;
    if (!axs_cachekeeper_bundle_id(request[@"bundle"]) || !axs_cachekeeper_relative_path(request[@"path"])) return YES;
    NSDictionary *report=AxsCacheKeeperDiagnosticInspection(self.folder,request[@"bundle"],request[@"path"]);
    if (!AxsCacheKeeperDiagnosticBooleansValid(report,@[@"complete",@"cancelled"])) return YES;
    return !([report[@"token"] isEqual:request[@"token"]] && ([report[@"complete"] boolValue] || [report[@"cancelled"] boolValue]));
}
- (NSString *)startAt:(NSTimeInterval)now {
    if (self.running) return @"正在采集。";
    if (self.configurationError) return self.configurationError;
    if (!self.bundles.count) return @"没有已配置 APP。";
    NSDictionary *batchRead=AxsCacheKeeperDiagnosticRead(self.folder,@"batch.plist");
    id remaining=batchRead[@"data"][@"remaining"];
    if (![@[@"missing",@"available"] containsObject:batchRead[@"state"]] || (remaining && ![remaining isKindOfClass:NSArray.class]))
        return @"批量检测记录损坏或不可读，请先导出现有记录。";
    if ([NSFileManager.defaultManager fileExistsAtPath:[self.folder stringByAppendingPathComponent:@"request.plist"]] ||
        [remaining count] || [self axs_cachekeeper_inspection_busy])
        return @"已有目录或深度检测请求，请等待结束或在原页面停止后再开始；仍可导出现有记录。";
    self.tasks=[NSMutableArray new];self.index=0;self.lastProgress=now;self.started=NSDate.date;self.lastUpdated=nil;
    for (NSString *bundle in self.bundles) [self.tasks addObject:[@{@"kind":@"scan",@"bundle":bundle,@"outcome":@"pending"} mutableCopy]];
    self.running=YES;self.status=@"正在准备目录检测…";return nil;
}
- (BOOL)axs_cachekeeper_write:(NSDictionary *)request name:(NSString *)name {
    NSError *error=nil;
    BOOL saved=[request writeToURL:[NSURL fileURLWithPath:[self.folder stringByAppendingPathComponent:name]] error:&error];
    if (!saved) {self.status=[NSString stringWithFormat:@"请求写入失败（代码 %ld）；可导出已有记录。",(long)error.code];self.running=NO;}
    return saved;
}
- (void)advanceAt:(NSTimeInterval)now {
    if (!self.running) return;
    if (self.index>=self.tasks.count) {self.running=NO;self.status=@"本次补采队列已结束；请导出报告，失败与覆盖不完整项会如实保留。";return;}
    NSMutableDictionary *task=self.tasks[self.index];BOOL deep=[task[@"kind"] isEqual:@"inspection"];
    NSString *file=deep ? @"inspectionRequest.plist" : @"request.plist";
    if ([task[@"outcome"] isEqual:@"pending"]) {
        BOOL occupied=deep ? [self axs_cachekeeper_inspection_busy] : [NSFileManager.defaultManager fileExistsAtPath:[self.folder stringByAppendingPathComponent:file]];
        if (occupied) {task[@"outcome"]=@"conflict";self.running=NO;self.status=@"检测接口被其他请求占用；已停止，可导出部分记录。";return;}
        task[@"token"]=NSUUID.UUID.UUIDString;
        NSMutableDictionary *request=[@{@"bundle":task[@"bundle"],@"token":task[@"token"],@"diagnostic":@YES} mutableCopy];
        if (deep) request[@"path"]=task[@"path"];
        if (![self axs_cachekeeper_write:request name:file]) {task[@"outcome"]=@"error";return;}
        task[@"outcome"]=@"submitted";self.lastProgress=now;self.lastUpdated=nil;
        self.status=[NSString stringWithFormat:@"%lu/%lu · %@ · %@%@",(unsigned long)self.index+1,(unsigned long)self.tasks.count,task[@"bundle"],deep ? @"深度检测 " : @"检测目录",deep ? task[@"path"] : @""];
        return;
    }
    NSDictionary *record=deep ? AxsCacheKeeperDiagnosticInspection(self.folder,task[@"bundle"],task[@"path"]) : AxsCacheKeeperDiagnosticRead(self.folder,@"scan.plist")[@"data"];
    BOOL matches=[record[@"token"] isEqual:task[@"token"]] && [record[@"bundle"] isEqual:task[@"bundle"]];
    if (matches && (!AxsCacheKeeperDiagnosticBooleansValid(record,@[@"complete",@"cancelled",@"coverageComplete"]) ||
        (record[@"error"] && ![record[@"error"] isKindOfClass:NSString.class]) ||
        (!deep && record[@"rows"] && ![record[@"rows"] isKindOfClass:NSArray.class]))) {
        [self stop];task[@"outcome"]=@"invalid";self.status=@"检测回执字段损坏，已停止；请导出记录。";return;
    }
    if (matches && [record[@"updated"] isKindOfClass:NSDate.class] && ![record[@"updated"] isEqual:self.lastUpdated]) {self.lastUpdated=record[@"updated"];self.lastProgress=now;}
    if (matches && (!deep || [record[@"complete"] boolValue] || [record[@"cancelled"] boolValue])) {
        BOOL issue=([record[@"error"] isKindOfClass:NSString.class] && [record[@"error"] length]) || [record[@"cancelled"] boolValue];
        task[@"outcome"]=(issue || (deep && ![record[@"coverageComplete"] boolValue])) ? @"partial" : @"finished";
        if ([record[@"error"] isKindOfClass:NSString.class]) task[@"error"]=record[@"error"];
        if (!deep && [record[@"rows"] isKindOfClass:NSArray.class]) {
            NSMutableSet *seen=[NSMutableSet new];NSUInteger offset=1;
            for (id row in record[@"rows"]) {
                if (![row isKindOfClass:NSDictionary.class]) continue;
                NSString *path=row[@"path"];if (!axs_cachekeeper_relative_path(path) || [seen containsObject:path]) continue;
                [seen addObject:path];[self.tasks insertObject:[@{@"kind":@"inspection",@"bundle":task[@"bundle"],@"path":path,@"outcome":@"pending"} mutableCopy] atIndex:self.index+offset++];
            }
        }
        self.index++;return;
    }
    // 无进度而非总时长：巨大目录只要每秒仍有回执就继续，不截断正常分批读取。
    if (now-self.lastProgress>120) { [self stop];task[@"outcome"]=@"timeout";self.status=@"检测回执超时，已停止补采；可导出部分记录。"; }
}
- (void)stop {
    if (!self.running) return;
    self.running=NO;self.status=@"已停止补采；现有与部分记录仍可导出。";
    if (self.index>=self.tasks.count) return;
    NSMutableDictionary *task=self.tasks[self.index];
    if ([task[@"kind"] isEqual:@"inspection"] && task[@"token"]) {
        NSMutableDictionary *request=[AxsCacheKeeperDiagnosticRead(self.folder,@"inspectionRequest.plist")[@"data"] mutableCopy];
        if ([request[@"token"] isEqual:task[@"token"]]) {request[@"cancel"]=@YES;[self axs_cachekeeper_write:request name:@"inspectionRequest.plist"];}
    }
    task[@"outcome"]=@"stopped";
}
- (NSDictionary *)reportWithApps:(NSArray<NSDictionary *> *)apps environment:(NSDictionary *)environment {
    AxsCacheKeeperDiagnosticRedactor *redactor=[AxsCacheKeeperDiagnosticRedactor new];
    NSDictionary *states=AxsCacheKeeperDiagnosticRead(self.folder,@"appEnabled.plist");
    NSDictionary *directories=AxsCacheKeeperDiagnosticRead(self.folder,@"directories.plist");
    NSDictionary *snapshots=AxsCacheKeeperDiagnosticRead(self.folder,@"snapshots.plist");
    NSMutableArray *exported=[NSMutableArray new];
    for (NSString *bundle in self.bundles) {
        NSMutableDictionary *app=[@{@"bundle":bundle} mutableCopy];
        for (NSDictionary *installed in apps) if ([installed isKindOfClass:NSDictionary.class] && [installed[@"id"] isEqual:bundle]) {
            app[@"installedMetadataAvailable"]=@YES;
            for (NSString *key in @[@"name",@"version"]) if ([installed[key] isKindOfClass:NSString.class]) app[key]=installed[key];break;
        }
        app[@"configurationState"]=states[@"state"];app[@"selectionState"]=directories[@"state"];
        id state=states[@"data"][bundle];
        app[@"configurationPresent"]=@(state!=nil);
        if (!state || [state isKindOfClass:NSNumber.class]) app[@"configuration"]=@{@"enabled":@(axs_cachekeeper_app_enabled(state))};
        else app[@"configuration"]=[redactor axs_cachekeeper_record:state];
        NSArray *paths=directories[@"data"][bundle];if ([paths isKindOfClass:NSArray.class]) app[@"selection"]=[redactor axs_cachekeeper_record:@{@"effectivePaths":paths}];
        NSDictionary *scan=snapshots[@"data"][bundle];
        app[@"scan"]=[redactor axs_cachekeeper_record:scan ? @{@"state":@"available",@"data":scan} : @{@"state":[snapshots[@"state"] isEqual:@"available"] ? @"missing" : snapshots[@"state"]}];
        for (NSArray *source in @[@[@"cleanup",@"auto"],@[@"inspection",@"inspection"],@[@"network",@"network"],@[@"probe",@"probe"]])
            app[source[0]]=[redactor axs_cachekeeper_record:AxsCacheKeeperDiagnosticRead(self.folder,[NSString stringWithFormat:@"Status/%@.%@.plist",bundle,source[1]])];
        [exported addObject:app];
    }
    NSMutableDictionary *env=[NSMutableDictionary new];
    for (NSString *key in @[@"os",@"architecture",@"pluginVersion"]) if ([environment[key] isKindOfClass:NSString.class]) env[key]=environment[key];
    NSMutableDictionary *collection=[@{@"tasks":self.tasks,@"phase":self.started ? (self.running ? @"running" : @"stopped") : @"notStarted"} mutableCopy];
    if (self.started) collection[@"started"]=self.started;
    if (self.started && self.index>=self.tasks.count) collection[@"phase"]=@"complete";
    NSMutableDictionary *batch=[AxsCacheKeeperDiagnosticRead(self.folder,@"batch.plist") mutableCopy];
    if (batch[@"data"]) {
        NSMutableDictionary *data=[batch[@"data"] mutableCopy];
        if ([data[@"remaining"] isKindOfClass:NSArray.class]) {data[@"remainingCount"]=@([data[@"remaining"] count]);[data removeObjectForKey:@"remaining"];}
        else if (data[@"remaining"]) batch[@"state"]=@"invalid";
        batch[@"data"]=data;
    }
    return @{@"schemaVersion":@1,@"generatedAt":@(NSDate.date.timeIntervalSince1970),@"environment":env,@"apps":exported,
        @"sourceStates":@{@"configuration":states[@"state"],@"selection":directories[@"state"],@"snapshots":snapshots[@"state"]},
        @"batch":[redactor axs_cachekeeper_record:batch],
        @"collection":[redactor axs_cachekeeper_record:collection],
        @"notes":@[@"数据来自插件保存的记录；时间戳不同，不是原子快照。直接导出可能包含历史或缺失记录。",@"补采结束不等于清理完成；覆盖、失败、取消、截断标志与每项时间分别判断。",@"字节是逻辑记录值；硬链接孪生大小不等于实际释放空间。",@"未知路径组件和账号已匿名化；自由文本只导出原因类别，不含文件内容或原始日志。"]};
}
@end
