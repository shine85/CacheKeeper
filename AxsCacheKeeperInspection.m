#import "AxsCacheKeeperInspection.h"
#import "AxsCacheKeeperPolicy.h"
#import "AxsCacheKeeperFileAccess.h"

@interface AxsCacheKeeperInspection ()
@property(nonatomic,copy) NSString *root;
@property(nonatomic,copy) NSArray<NSString *> *rootAliases;
@property(nonatomic,strong) NSDirectoryEnumerator *entries;
@property(nonatomic,readwrite) BOOL complete;
@property(nonatomic) NSUInteger files;
@property(nonatomic) NSUInteger failures;
@property(nonatomic) NSUInteger links;
@property(nonatomic) NSUInteger hidden;
@property(nonatomic) NSUInteger changed;
@property(nonatomic) NSUInteger markers;
@property(nonatomic) unsigned long long bytes;
@property(nonatomic,strong) NSMutableDictionary *types;
@property(nonatomic,strong) NSMutableDictionary *ages;
@property(nonatomic,strong) NSMutableArray *largest;
@property(nonatomic,copy) NSString *error;
@property(nonatomic,strong) NSDate *started;
// 硬链接孪生定位：主枚举只记身份（设备+inode），枚举完成后分批扫搜索根找孪生。
@property(nonatomic,copy) NSArray<NSDictionary *> *searchRoots;
@property(nonatomic,strong) NSMutableArray *linkFiles;
@property(nonatomic,strong) NSMutableDictionary *linkIndex;
@property(nonatomic) NSUInteger hardLinks;
@property(nonatomic) NSUInteger symlinks;
@property(nonatomic) BOOL linkFilesTruncated;
@property(nonatomic) BOOL twinPhase;
@property(nonatomic) NSUInteger searchIndex;
@property(nonatomic,strong) NSDictionary *searchCurrent;
@property(nonatomic,strong) NSDirectoryEnumerator *searchEntries;
@property(nonatomic,strong) NSMutableArray *twinEntries;
@property(nonatomic,strong) NSMutableSet *twinnedKeys;
@property(nonatomic) unsigned long long twinBytes;
@property(nonatomic) NSUInteger twinScanned;
@property(nonatomic) BOOL twinTruncated;
@property(nonatomic) BOOL twinDisplayTruncated;
@property(nonatomic) NSUInteger twinSkipped;
@end

static NSString *axs_cachekeeper_inode_key(dev_t device, ino_t inode) {
    return [NSString stringWithFormat:@"%llu:%llu",(unsigned long long)device,(unsigned long long)inode];
}

static NSString *axs_cachekeeper_header_kind(const unsigned char *data, NSUInteger length, off_t size) {
    if (!size) return @"空文件";
    if (length>=15 && !memcmp(data,"SQLite format 3",15)) return @"SQLite 数据库";
    if (length>=6 && !memcmp(data,"bplist",6)) return @"二进制 plist";
    if (axs_cachekeeper_media_signature(data,length)) return @"媒体文件头";
    if ((length>=4 && !memcmp(data,"PK\003\004",4)) || (length>=2 && data[0]==0x1f && data[1]==0x8b) ||
        (length>=6 && !memcmp(data,"7z\xbc\xaf\x27\x1c",6)) || (length>=4 && !memcmp(data,"Rar!",4)) ||
        (length>=3 && !memcmp(data,"BZh",3)) || (length>=6 && !memcmp(data,"\xfd" "7zXZ\0",6))) return @"归档或压缩文件";
    NSData *sample=[NSData dataWithBytes:data length:length];
    if (size==(off_t)length && [NSJSONSerialization JSONObjectWithData:sample options:NSJSONReadingFragmentsAllowed error:nil]) return @"JSON 数据";
    NSString *text=[[NSString alloc] initWithData:sample encoding:NSUTF8StringEncoding];
    if (text.length && !memchr(data,0,length)) return @"文本头特征（用途未定）";
    return @"未知二进制";
}

@implementation AxsCacheKeeperInspection
- (instancetype)initWithRoot:(NSString *)root {
    return [self initWithRoot:root searchRoots:@[@{@"path":root ?: @"",@"label":@"本目录"}]];
}
- (instancetype)initWithRoot:(NSString *)root searchRoots:(NSArray<NSDictionary *> *)searchRoots {
    self=[super init];if (!self) return nil;
    _root=[root copy];_types=[NSMutableDictionary new];_ages=[NSMutableDictionary new];_largest=[NSMutableArray new];_started=NSDate.date;
    _searchRoots=[searchRoots count] ? [searchRoots copy] : @[@{@"path":root ?: @"",@"label":@"本目录"}];
    _linkFiles=[NSMutableArray new];_twinEntries=[NSMutableArray new];_twinnedKeys=[NSMutableSet new];
    int fd=axs_cachekeeper_open_directory(root);
    if (fd<0) { _complete=YES;_failures=1;_error=[NSString stringWithFormat:@"目录无法读取：errno %d",errno];return self; }
    close(fd);
    _rootAliases=axs_cachekeeper_directory_aliases(root);
    __weak typeof(self) weak=self;
    _entries=[NSFileManager.defaultManager enumeratorAtURL:[NSURL fileURLWithPath:root] includingPropertiesForKeys:nil options:0 errorHandler:^BOOL(NSURL *url,NSError *error) {
        weak.failures++;weak.error=[NSString stringWithFormat:@"%@（%@/%ld）",error.localizedDescription,error.domain,(long)error.code];return YES;
    }];
    if (!_entries) { _complete=YES;_failures=1;_error=@"无法创建目录枚举器"; }
    return self;
}
- (void)advance:(NSUInteger)limit {
    for (NSUInteger index=0;index<limit && !self.complete;index++) {
        @autoreleasepool {
            if (self.twinPhase) { [self axs_cachekeeper_advance_twin];continue; }
            NSURL *enumerated=[self.entries nextObject];
            if (!enumerated) {
                if (self.linkFiles.count && self.searchRoots.count) { [self axs_cachekeeper_begin_twin];continue; }
                self.complete=YES;break;
            }
            NSString *entry=axs_cachekeeper_enumerated_path(enumerated.path,self.root,self.rootAliases);
            if (!entry) { self.failures++;self.error=@"枚举路径不属于已核验目录，已停止读取";self.complete=YES;break; }
            NSString *relative=[entry substringFromIndex:self.root.length+1];
            struct stat info;
            if (lstat(entry.fileSystemRepresentation,&info)) { self.failures++;self.error=[NSString stringWithFormat:@"无法读取文件属性：errno %d",errno];continue; }
            if (S_ISLNK(info.st_mode)) { self.links++;self.symlinks++;continue; }
            if (S_ISREG(info.st_mode) && info.st_nlink!=1) {
                self.links++;self.hardLinks++;
                if (self.linkFiles.count<100) [self.linkFiles addObject:@{@"path":relative,@"device":@(info.st_dev),@"inode":@(info.st_ino),@"nlink":@(info.st_nlink),@"bytes":@(info.st_size)}];
                else self.linkFilesTruncated=YES;
                continue;
            }
            if (axs_cachekeeper_hidden_directory(relative)) { self.hidden++;if (S_ISDIR(info.st_mode)) [self.entries skipDescendants];continue; }
            if (S_ISDIR(info.st_mode)) {
                if (axs_cachekeeper_data_marker(entry.lastPathComponent)) self.markers++;
                continue;
            }
            if (!S_ISREG(info.st_mode)) continue;
            int parent=axs_cachekeeper_open_directory(entry.stringByDeletingLastPathComponent);
            int fd=parent>=0 ? openat(parent,entry.lastPathComponent.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_NONBLOCK) : -1;
            struct stat opened={0},after={0};unsigned char sample[4096];ssize_t count=-1;
            if (fd>=0 && !fstat(fd,&opened) && S_ISREG(opened.st_mode) && opened.st_nlink==1 && opened.st_ino==info.st_ino && opened.st_dev==info.st_dev)
                count=pread(fd,sample,sizeof(sample),0);
            int failure=errno;
            BOOL stable=fd>=0 && !fstat(fd,&after) && opened.st_size==after.st_size &&
                opened.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec && opened.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec &&
                opened.st_ctimespec.tv_sec==after.st_ctimespec.tv_sec && opened.st_ctimespec.tv_nsec==after.st_ctimespec.tv_nsec;
            if (fd>=0) close(fd);if (parent>=0) close(parent);
            if (count<0) { self.failures++;self.error=[NSString stringWithFormat:@"文件头读取失败：errno %d",failure];continue; }
            if (count!=MIN(opened.st_size,(off_t)sizeof(sample))) { self.failures++;self.error=@"文件头未完整读取；请重检";continue; }
            if (!stable) { self.changed++;continue; }
            NSString *kind=axs_cachekeeper_header_kind(sample,(NSUInteger)count,opened.st_size);
            if (axs_cachekeeper_data_marker(entry.lastPathComponent)) { self.markers++;kind=@"数据或登录态名称特征"; }
            NSDictionary *old=self.types[kind];
            self.types[kind]=@{@"count":@([old[@"count"] unsignedIntegerValue]+1),@"bytes":@([old[@"bytes"] unsignedLongLongValue]+opened.st_size)};
            self.files++;self.bytes+=opened.st_size;
            NSTimeInterval age=[self.started timeIntervalSince1970]-MAX(opened.st_mtimespec.tv_sec,MAX(opened.st_ctimespec.tv_sec,opened.st_birthtimespec.tv_sec));
            NSString *bucket=age<60 ? @"不足 60 秒" : age<86400 ? @"60 秒至 1 天" : age<30*86400 ? @"1 至 30 天" : @"30 天以上";
            self.ages[bucket]=@([self.ages[bucket] unsignedIntegerValue]+1);
            [self.largest addObject:@{@"path":relative,@"bytes":@(opened.st_size),@"type":kind}];
            [self.largest sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b) { return [b[@"bytes"] compare:a[@"bytes"]]; }];
            if (self.largest.count>10) [self.largest removeLastObject];
        }
    }
}
- (void)axs_cachekeeper_begin_twin {
    self.twinPhase=YES;
    self.linkIndex=[NSMutableDictionary new];
    for (NSDictionary *record in self.linkFiles) {
        NSString *key=axs_cachekeeper_inode_key([record[@"device"] unsignedLongLongValue],[record[@"inode"] unsignedLongLongValue]);
        NSMutableArray *records=self.linkIndex[key];
        if (!records) { records=[NSMutableArray new];self.linkIndex[key]=records; }
        [records addObject:record];
    }
    self.searchIndex=0;
    [self axs_cachekeeper_open_search_root];
    if (!self.searchEntries) self.complete=YES;
}
- (void)axs_cachekeeper_open_search_root {
    self.searchEntries=nil;self.searchCurrent=nil;
    while (self.searchIndex<self.searchRoots.count) {
        NSDictionary *candidate=self.searchRoots[self.searchIndex];
        self.searchIndex++;
        NSString *path=candidate[@"path"];
        if (![path isKindOfClass:NSString.class] || !path.length) { self.twinSkipped++;continue; }
        // 先预校验目录可读（任务 7）：enumeratorAtURL 对缺失路径是否返回 nil 未定，
        // 不预校验会让不可读搜索根静默漏计失败；open_directory 失败即计入孪生失败。
        int fd=axs_cachekeeper_open_directory(path);
        if (fd<0) { self.twinSkipped++;continue; }
        close(fd);
        __weak typeof(self) weak=self;
        NSDirectoryEnumerator *entries=[NSFileManager.defaultManager enumeratorAtURL:[NSURL fileURLWithPath:path] includingPropertiesForKeys:nil options:0 errorHandler:^BOOL(NSURL *url,NSError *error) { (void)error;weak.twinSkipped++;return YES; }];
        if (entries) { self.searchEntries=entries;self.searchCurrent=candidate;return; }
        self.twinSkipped++;
    }
}
- (void)axs_cachekeeper_advance_twin {
    if (self.twinScanned>=100000) { self.twinTruncated=YES;self.complete=YES;return; }
    NSURL *enumerated=[self.searchEntries nextObject];
    if (!enumerated) { [self axs_cachekeeper_open_search_root];if (!self.searchEntries) self.complete=YES;return; }
    self.twinScanned++;
    struct stat info;
    // 孪生搜索的 lstat 失败计入孪生失败（任务 7）：静默跳过会让 0 匹配看起来像"已确认无孪生"。
    if (lstat(enumerated.path.fileSystemRepresentation,&info)) { self.twinSkipped++;return; }
    if (!S_ISREG(info.st_mode) || info.st_nlink==1) return;
    NSString *key=axs_cachekeeper_inode_key(info.st_dev,info.st_ino);
    NSArray *sources=self.linkIndex[key];
    if (!sources.count) return;
    for (NSDictionary *source in sources) {
        NSString *sourceFull=[self.root stringByAppendingPathComponent:source[@"path"]];
        NSString *twinResolved=[NSURL fileURLWithPath:enumerated.path].URLByResolvingSymlinksInPath.path;
        NSString *sourceResolved=[NSURL fileURLWithPath:sourceFull].URLByResolvingSymlinksInPath.path;
        if ([twinResolved isEqual:sourceResolved]) continue;
        NSUInteger existing=0;
        for (NSDictionary *twin in self.twinEntries) if ([twin[@"source"] isEqual:source[@"path"]]) existing++;
        // 展示截断（任务 7）：每源 3 条或总 50 条上限丢掉的孪生须标记，不能静默少报。
        if (existing>=3 || self.twinEntries.count>=50) { self.twinDisplayTruncated=YES;continue; }
        NSString *base=self.searchCurrent[@"path"];
        NSString *label=self.searchCurrent[@"label"] ?: @"";
        NSString *shown=[enumerated.path hasPrefix:[base stringByAppendingString:@"/"]] ?
            [NSString stringWithFormat:@"%@/%@",label,[enumerated.path substringFromIndex:base.length+1]] :
            [NSString stringWithFormat:@"%@/%@",label,enumerated.path.lastPathComponent];
        [self.twinEntries addObject:@{@"source":source[@"path"],@"twin":shown,@"bytes":source[@"bytes"]}];
        // 关联大小按 (设备, inode) 去重（任务 7）：同一 inode 的多个源路径只计一次，
        // 否则同目录双链接会把同一份数据算两遍。twinBytes 是逻辑关联大小，非实测释放空间。
        if (![self.twinnedKeys containsObject:key]) { [self.twinnedKeys addObject:key];self.twinBytes+=[source[@"bytes"] unsignedLongLongValue]; }
    }
}
- (NSDictionary *)report {
    BOOL covered=self.complete && !self.failures && !self.changed;
    // 孪生搜索完整性与主扫描分开报告（任务 7）：主扫描未完成时孪生源清单本身不完整，
    // 不能声称孪生已覆盖；无硬链接时孪生阶段不启动，各项计数为 0，完整性自然成立。
    BOOL twinCovered=self.complete && !self.twinSkipped && !self.twinTruncated && !self.linkFilesTruncated && !self.twinDisplayTruncated;
    NSString *evidence=@"用途仍未确认；请结合文件类型与实际功能继续核查";
    if (self.markers || self.types[@"SQLite 数据库"] || self.types[@"二进制 plist"] || self.types[@"JSON 数据"])
        evidence=@"检出数据格式或数据名称特征；不代表整个目录都是必需数据，也不能直接清空";
    else if (covered && self.files && [self.types[@"媒体文件头"][@"count"] unsignedIntegerValue]==self.files && !self.hidden && !self.links)
        evidence=@"已读取的文件全部具有媒体头特征；媒体也可能是下载或用户内容，未证明可删";
    return @{@"complete":@(self.complete),@"coverageComplete":@(covered),@"files":@(self.files),@"bytes":@(self.bytes),
        @"failures":@(self.failures),@"changed":@(self.changed),@"links":@(self.links),@"hidden":@(self.hidden),
        @"hardLinks":@(self.hardLinks),@"symlinks":@(self.symlinks),@"linkTwins":[self.twinEntries copy],@"twinBytes":@(self.twinBytes),
        @"twinCoverageComplete":@(twinCovered),@"twinFailures":@(self.twinSkipped),
        @"twinScanTruncated":@(self.twinTruncated),@"twinDisplayTruncated":@(self.twinDisplayTruncated),@"linkFilesTruncated":@(self.linkFilesTruncated),@"twinScanned":@(self.twinScanned),
        @"types":[self.types copy],@"ages":[self.ages copy],@"largest":[self.largest copy],@"evidence":evidence,
        @"error":self.error ?: @"",@"started":self.started,@"updated":NSDate.date};
}
@end
