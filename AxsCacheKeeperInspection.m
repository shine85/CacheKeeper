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
@end

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
    self=[super init];if (!self) return nil;
    _root=[root copy];_types=[NSMutableDictionary new];_ages=[NSMutableDictionary new];_largest=[NSMutableArray new];_started=NSDate.date;
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
            NSURL *enumerated=[self.entries nextObject];
            if (!enumerated) { self.complete=YES;break; }
            NSString *entry=axs_cachekeeper_enumerated_path(enumerated.path,self.root,self.rootAliases);
            if (!entry) { self.failures++;self.error=@"枚举路径不属于已核验目录，已停止读取";self.complete=YES;break; }
            NSString *relative=[entry substringFromIndex:self.root.length+1];
            struct stat info;
            if (lstat(entry.fileSystemRepresentation,&info)) { self.failures++;self.error=[NSString stringWithFormat:@"无法读取文件属性：errno %d",errno];continue; }
            if (S_ISLNK(info.st_mode) || (S_ISREG(info.st_mode) && info.st_nlink!=1)) { self.links++;continue; }
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
- (NSDictionary *)report {
    BOOL covered=self.complete && !self.failures && !self.changed;
    NSString *evidence=@"用途仍未确认；请结合文件类型与实际功能继续核查";
    if (self.markers || self.types[@"SQLite 数据库"] || self.types[@"二进制 plist"] || self.types[@"JSON 数据"])
        evidence=@"检出数据格式或数据名称特征；不代表整个目录都是必需数据，也不能直接清空";
    else if (covered && self.files && [self.types[@"媒体文件头"][@"count"] unsignedIntegerValue]==self.files && !self.hidden && !self.links)
        evidence=@"已读取的文件全部具有媒体头特征；媒体也可能是下载或用户内容，未证明可删";
    return @{@"complete":@(self.complete),@"coverageComplete":@(covered),@"files":@(self.files),@"bytes":@(self.bytes),
        @"failures":@(self.failures),@"changed":@(self.changed),@"links":@(self.links),@"hidden":@(self.hidden),
        @"types":[self.types copy],@"ages":[self.ages copy],@"largest":[self.largest copy],@"evidence":evidence,
        @"error":self.error ?: @"",@"started":self.started,@"updated":NSDate.date};
}
@end
