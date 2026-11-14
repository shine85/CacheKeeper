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
static NSMutableSet<NSString *> *AxsCacheKeeperDiagnosticConfiguredBundles(NSDictionary *states,NSDictionary *directories) {
    NSMutableSet *bundles=[NSMutableSet new];
    for (NSDictionary *read in @[states,directories])
        for (id bundle in [read[@"data"] allKeys]) if (axs_cachekeeper_bundle_id(bundle)) [bundles addObject:bundle];
    return bundles;
}
static NSDictionary *AxsCacheKeeperDiagnosticChannelProjection(id value) {
    if (!value) return @{@"state":@"notObserved"};
    if (![value isKindOfClass:NSDictionary.class]) return @{@"state":@"invalid"};
    NSDictionary *allowed=@{
        @"state":@[@"listening",@"verified",@"unavailable",@"rejected",@"busy"],
        @"stage":@[@"none",@"host",@"selfToken",@"api",@"systemURL",@"status",@"signingIdentity",@"executable",@"finalStatus",@"register",@"lookup",@"send",@"receive",@"protocol",@"replay",@"timeout",@"busy"],
        @"errorDomain":@[@"none",@"mach",@"posix",@"protocol"],
        @"errorOrigin":@[@"none",@"local",@"peer"],
        @"selfIdentity":@[@"notObserved",@"verified",@"unexpected",@"unavailable"],
        @"peerIdentity":@[@"notObserved",@"verified",@"unexpected",@"unavailable"],
        @"serverRegister":@[@"notObserved",@"verified",@"failed"]};
    NSMutableDictionary *out=[NSMutableDictionary new];
    for (NSString *key in allowed) {
        if (![value[key] isKindOfClass:NSString.class] || ![allowed[key] containsObject:value[key]])
            return @{@"state":@"invalid"};
        out[key]=[value[key] copy];
    }
    for (NSString *key in @[@"protocolVersion",@"errorCode"]) {
        id number=value[key];
        if (![number isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)number)==CFBooleanGetTypeID())
            return @{@"state":@"invalid"};
        double numeric=[number doubleValue];
        if (!isfinite(numeric) || numeric!=trunc(numeric) || numeric<INT32_MIN || numeric>INT32_MAX ||
            ([key isEqual:@"protocolVersion"] && numeric!=1)) return @{@"state":@"invalid"};
        out[key]=@((int32_t)numeric);
    }
    return [out copy];
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
    NSArray *numbers=@[@"appRuleWaitingForExit",@"bytes",@"files",@"count",@"nlink",@"removed",@"failed",@"failures",@"changed",@"recent",@"remaining",@"remainingBytes",@"deferred",@"deferredBytes",@"unresolved",@"unresolvedBytes",@"protected",@"protectedBytes",@"retainedSubtreeCount",@"lastRemoved",@"lastBytes",@"endReason",@"links",@"hardLinks",@"symlinks",@"hidden",@"twinBytes",@"twinFailures",@"twinScanned",@"result",@"errorCode",@"complete",@"coverageComplete",@"measurementComplete",@"cancelled",@"checking",@"skipped",@"manageable",@"twinCoverageComplete",@"twinScanTruncated",@"twinDisplayTruncated",@"linkFilesTruncated",@"enabled",@"autoDiscover",@"urlCache",@"prevent",@"applied",@"total",@"completed",@"remainingCount"];
    NSMutableArray *invalid=[NSMutableArray new];
    for (NSString *key in @[@"appRuleID",@"state",@"phase",@"mode",@"kind",@"purgeClassification",@"type",@"outcome",@"path",@"source",@"twin"])
        if (record[key] && ![record[key] isKindOfClass:NSString.class]) [invalid addObject:key];
    for (NSString *key in numbers) if (record[key] && ![record[key] isKindOfClass:NSNumber.class]) [invalid addObject:key];
    for (NSString *key in @[@"updated",@"started"]) if (record[key] && ![record[key] isKindOfClass:NSDate.class]) [invalid addObject:key];
    for (NSString *key in @[@"directories",@"reports",@"types",@"ages",@"data"]) if (record[key] && ![record[key] isKindOfClass:NSDictionary.class]) [invalid addObject:key];
    for (NSString *key in @[@"effectivePaths",@"discoveredPaths",@"excludedPaths",@"logPaths",@"rows",@"previousRows",@"recentScans",@"largest",@"largestHardLinks",@"linkTwins",@"retainedSubtrees",@"tasks"]) if (record[key] && ![record[key] isKindOfClass:NSArray.class]) [invalid addObject:key];
    for (NSString *key in @[@"effectivePaths",@"discoveredPaths",@"excludedPaths",@"logPaths"]) if ([record[key] isKindOfClass:NSArray.class])
        for (id path in record[key]) if (![path isKindOfClass:NSString.class]) {[invalid addObject:key];break;}
    if (invalid.count) {out[@"invalidRecord"]=@YES;out[@"invalidFields"]=invalid;}
    for (NSString *key in numbers) if ([record[key] isKindOfClass:NSNumber.class]) out[key]=record[key];
    for (NSString *key in @[@"updated",@"started"]) if ([record[key] isKindOfClass:NSDate.class]) out[key]=@([record[key] timeIntervalSince1970]);
    for (NSString *key in @[@"path",@"source",@"twin"]) if (record[key]) out[key]=[self axs_cachekeeper_path:record[key]];
    if (axs_cachekeeper_bundle_id(record[@"bundle"])) out[@"bundle"]=record[@"bundle"];
    NSSet *values=[NSSet setWithArray:@[@"douyin-alog",@"auto",@"clean",@"prevent",@"waiting",@"running",@"complete",@"error",@"paused",@"cache",@"log",@"data",@"mixed",@"unknown",@"scan",@"inspection",@"pending",@"submitted",@"finished",@"partial",@"stopped",@"notStarted",@"timeout",@"conflict",@"available",@"missing",@"unreadable",@"invalid",@"空文件",@"SQLite 数据库",@"二进制 plist",@"媒体文件头",@"归档或压缩文件",@"JSON 数据",@"文本头特征（用途未定）",@"未知二进制",@"数据或登录态名称特征"]];
    for (NSString *key in @[@"appRuleID",@"state",@"phase",@"mode",@"kind",@"purgeClassification",@"type",@"outcome"])
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
@property(nonatomic,copy) NSArray<NSString *> *bundles;
@end
@implementation AxsCacheKeeperDiagnostics
- (instancetype)initWithFolder:(NSString *)folder {
    self=[super init];if (!self) return nil;
    _folder=[folder copy];
    NSMutableSet *bundles=AxsCacheKeeperDiagnosticConfiguredBundles(AxsCacheKeeperDiagnosticRead(folder,@"appEnabled.plist"),AxsCacheKeeperDiagnosticRead(folder,@"directories.plist"));
    _bundles=[bundles.allObjects sortedArrayUsingSelector:@selector(compare:)];
    return self;
}
- (NSDictionary *)reportWithApps:(NSArray<NSDictionary *> *)apps environment:(NSDictionary *)environment {
    return [self reportWithApps:apps environment:environment progress:nil];
}
- (NSDictionary *)reportWithApps:(NSArray<NSDictionary *> *)apps environment:(NSDictionary *)environment progress:(void (^)(NSUInteger completed,NSUInteger total))progress {
    NSDate *started=NSDate.date;
    AxsCacheKeeperDiagnosticRedactor *redactor=[AxsCacheKeeperDiagnosticRedactor new];
    NSDictionary *states=AxsCacheKeeperDiagnosticRead(self.folder,@"appEnabled.plist");
    NSDictionary *directories=AxsCacheKeeperDiagnosticRead(self.folder,@"directories.plist");
    NSDictionary *snapshots=AxsCacheKeeperDiagnosticRead(self.folder,@"snapshots.plist");
    NSMutableSet *bundleSet=AxsCacheKeeperDiagnosticConfiguredBundles(states,directories);
    NSMutableDictionary *installedMetadata=[NSMutableDictionary new];
    BOOL installedSnapshotAvailable=[apps isKindOfClass:NSArray.class];
    if (installedSnapshotAvailable) for (id installed in [apps copy]) {
        if (![installed isKindOfClass:NSDictionary.class] || !axs_cachekeeper_bundle_id(installed[@"id"])) {
            installedSnapshotAvailable=NO;continue;
        }
        NSString *bundle=[installed[@"id"] copy];
        [bundleSet addObject:bundle];
        if (installedMetadata[bundle]) continue;
        NSMutableDictionary *metadata=[NSMutableDictionary new];
        for (NSString *key in @[@"name",@"version",@"build"])
            if ([installed[key] isKindOfClass:NSString.class]) metadata[key]=[installed[key] copy];
        if ([@[@"verified",@"versionUnknown",@"unavailable"] containsObject:installed[@"installationState"] ?: NSNull.null])
            metadata[@"installationState"]=installed[@"installationState"];
        installedMetadata[bundle]=metadata;
    }
    // 本轮集合在首次进度回调前固定；之后的配置变更由下一轮读取。
    NSArray *bundles=[bundleSet.allObjects sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray *exported=[NSMutableArray new];
    if (progress) progress(0,bundles.count);
    for (NSString *bundle in bundles) {
        NSMutableDictionary *app=[@{@"bundle":bundle} mutableCopy];
        NSDictionary *installed=installedMetadata[bundle];
        app[@"installedMetadataAvailable"]=@(installed!=nil);
        app[@"installedMetadataState"]=installed ? @"available" : (installedSnapshotAvailable ? @"notInSnapshot" : @"unavailable");
        if (installed) [app addEntriesFromDictionary:installed];
        app[@"configurationState"]=states[@"state"];app[@"selectionState"]=directories[@"state"];
        id state=states[@"data"][bundle];
        app[@"configurationPresent"]=@(state!=nil);
        if ([states[@"state"] isEqual:@"available"] && !state) app[@"configurationState"]=@"missing";
        if (!state || [state isKindOfClass:NSNumber.class]) app[@"configuration"]=@{@"enabled":@(axs_cachekeeper_app_enabled(state))};
        else app[@"configuration"]=[redactor axs_cachekeeper_record:state];
        if ([app[@"configuration"][@"invalidRecord"] boolValue]) app[@"configurationState"]=@"invalid";
        id paths=directories[@"data"][bundle];
        app[@"selectionPresent"]=@(paths!=nil);
        if (paths) {
            app[@"selection"]=[redactor axs_cachekeeper_record:@{@"effectivePaths":paths}];
            if ([app[@"selection"][@"invalidRecord"] boolValue]) app[@"selectionState"]=@"invalid";
        } else if ([directories[@"state"] isEqual:@"available"]) app[@"selectionState"]=@"missing";
        NSDictionary *scan=snapshots[@"data"][bundle];
        app[@"scan"]=[redactor axs_cachekeeper_record:scan ? @{@"state":@"available",@"data":scan} : @{@"state":[snapshots[@"state"] isEqual:@"available"] ? @"missing" : snapshots[@"state"]}];
        for (NSArray *source in @[@[@"cleanup",@"auto"],@[@"inspection",@"inspection"],@[@"network",@"network"],@[@"probe",@"probe"]])
            app[source[0]]=[redactor axs_cachekeeper_record:AxsCacheKeeperDiagnosticRead(self.folder,[NSString stringWithFormat:@"Status/%@.%@.plist",bundle,source[1]])];
        [exported addObject:app];
        if (progress) progress(exported.count,bundles.count);
    }
    NSMutableDictionary *env=[NSMutableDictionary new];
    for (NSString *key in @[@"os",@"architecture",@"pluginVersion"]) if ([environment[key] isKindOfClass:NSString.class]) env[key]=environment[key];
    NSMutableDictionary *batch=[AxsCacheKeeperDiagnosticRead(self.folder,@"batch.plist") mutableCopy];
    if (batch[@"data"]) {
        NSMutableDictionary *data=[batch[@"data"] mutableCopy];
        if ([data[@"remaining"] isKindOfClass:NSArray.class]) {data[@"remainingCount"]=@([data[@"remaining"] count]);[data removeObjectForKey:@"remaining"];}
        else if (data[@"remaining"]) batch[@"state"]=@"invalid";
        batch[@"data"]=data;
    }
    NSTimeInterval finished=NSDate.date.timeIntervalSince1970;
    // 汇总结束不代表新扫描完成；输入记录各自的原始时间戳保持不变。
    NSDictionary *collection=@{@"mode":@"savedRecords",@"phase":@"complete",@"total":@(bundles.count),
        @"completed":@(exported.count),@"started":@(started.timeIntervalSince1970),@"finished":@(finished),@"rescanned":@NO};
    return @{@"schemaVersion":@2,@"generatedAt":@(finished),@"environment":env,@"apps":exported,
        @"diagnosticChannel":AxsCacheKeeperDiagnosticChannelProjection(environment[@"diagnosticChannel"]),
        @"sourceStates":@{@"configuration":states[@"state"],@"selection":directories[@"state"],@"snapshots":snapshots[@"state"],@"installedApplications":installedSnapshotAvailable ? @"available" : @"unavailable"},
        @"batch":[redactor axs_cachekeeper_record:batch],
        @"collection":collection,
        @"notes":@[@"按传入安装快照与当前配置的并集汇总已有记录；缺配置 APP 保持禁用。notInSnapshot 只表示传入快照缺条目，不确认卸载；安装来源缺失或含坏身份条目时标记 unavailable。",@"只汇总插件已保存记录，不重新扫描 APP；历史、缺失与损坏状态保留。各记录时间不同，不是原子快照。",@"汇总完成不等于清理完成或深度检测完成；覆盖、失败、取消、截断与原始时间分别判断。",@"诊断通道只核验本轮握手；verified 不表示取得 APP 容器访问或清理能力，notObserved 表示未观察到，invalid 表示状态记录损坏。",@"字节是逻辑记录值；硬链接孪生大小不等于实际释放空间。",@"未知路径组件和账号已匿名化；自由文本只导出原因类别，不含文件内容或原始日志。"]};
}
@end
