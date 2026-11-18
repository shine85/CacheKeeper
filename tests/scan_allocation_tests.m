#import <Foundation/Foundation.h>
#import "../AxsCacheKeeperScanTask.h"
#import "../AxsCacheKeeperRecords.h"
#include <fcntl.h>
#include <unistd.h>

extern NSUInteger axs_cachekeeper_scan_test_inode_hash(dev_t,ino_t);

static void AxsCacheKeeperAllocationCheck(BOOL value,const char *message) {
    if(!value) {fprintf(stderr,"FAIL: scan allocation: %s\n",message);exit(1);}
}
static void AxsCacheKeeperAllocationDirectory(NSString *path) {
    AxsCacheKeeperAllocationCheck([NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil],"fixture directory");
}
static unsigned long long AxsCacheKeeperAllocationBlocks(NSString *path) {
    struct stat info;AxsCacheKeeperAllocationCheck(!lstat(path.fileSystemRepresentation,&info) && info.st_blocks>=0,"real block metadata");
    return (uint64_t)info.st_blocks*512;
}
int main(int argc,const char **argv) { @autoreleasepool {
    AxsCacheKeeperAllocationCheck(argc==2,"unique fixture root");
    NSString *base=[NSString stringWithUTF8String:argv[1]],*home=[base stringByAppendingPathComponent:@"home"];
    NSString *cache=[home stringByAppendingPathComponent:@"Library/Caches"],*temporary=[home stringByAppendingPathComponent:@"tmp"];
    AxsCacheKeeperAllocationDirectory(cache);AxsCacheKeeperAllocationDirectory(temporary);
    NSString *dense=[cache stringByAppendingPathComponent:@"dense"],*sparse=[cache stringByAppendingPathComponent:@"sparse"],*empty=[cache stringByAppendingPathComponent:@"empty"];
    AxsCacheKeeperAllocationCheck([[NSMutableData dataWithLength:8192] writeToFile:dense atomically:YES],"dense file");
    int fd=open(sparse.fileSystemRepresentation,O_CREAT|O_EXCL|O_WRONLY,0600);
    char block[4096]={1};AxsCacheKeeperAllocationCheck(fd>=0 && !ftruncate(fd,8*1024*1024) && pwrite(fd,block,sizeof(block),0)==sizeof(block),"real sparse file");
    close(fd);AxsCacheKeeperAllocationCheck([NSData.data writeToFile:empty atomically:YES],"zero length file");
    NSString *same=[cache stringByAppendingPathComponent:@"same"],*crossRoot=[temporary stringByAppendingPathComponent:@"same"];
    AxsCacheKeeperAllocationCheck(!link(dense.fileSystemRepresentation,same.fileSystemRepresentation) && !link(dense.fileSystemRepresentation,crossRoot.fileSystemRepresentation),"real hard links within and across roots");
    AxsCacheKeeperAllocationCheck(!symlink(base.fileSystemRepresentation,[cache stringByAppendingPathComponent:@"outside"].fileSystemRepresentation),"symlink fixture");
    unsigned long long expected=AxsCacheKeeperAllocationBlocks(dense)+AxsCacheKeeperAllocationBlocks(sparse)+AxsCacheKeeperAllocationBlocks(empty);
    AxsCacheKeeperAllocationCheck(AxsCacheKeeperAllocationBlocks(sparse)<8*1024*1024,"actual sparse allocation differs from logical size");
    AxsCacheKeeperScanCursor *cursor=[[AxsCacheKeeperScanCursor alloc] initWithRoot:[NSURL fileURLWithPath:cache] entryLimit:100 depthLimit:64];
    for(NSUInteger i=0;i<20 && [cursor.state isEqual:@"running"];i++) [cursor advanceEntries:1 seconds:1];
    NSDictionary *observation=cursor.result[@"allocationObservation"];
    AxsCacheKeeperAllocationCheck([cursor.state isEqual:@"complete"] && [observation[@"state"] isEqual:@"complete"] && [observation[@"allocatedBytes"] unsignedLongLongValue]==expected,"small slices observe actual unique regular file blocks");
    AxsCacheKeeperAllocationCheck([observation[@"uniqueFiles"] unsignedIntegerValue]==3 && [observation[@"duplicateFiles"] unsignedIntegerValue]==1,"zero length files counted and symlinks excluded");

    NSString *records=[base stringByAppendingPathComponent:@"records"];AxsCacheKeeperAllocationDirectory(records);
    AxsCacheKeeperScanService *service=[[AxsCacheKeeperScanService alloc] initWithFolder:records resolver:^NSDictionary *(NSString *bundle){(void)bundle;return @{@"home":[NSURL fileURLWithPath:home],@"groups":@{}};} writer:nil];
    AxsCacheKeeperAllocationCheck([@{@"token":@"allocation",@"bundle":@"fixture.allocation"} writeToFile:[records stringByAppendingPathComponent:@"request.plist"] atomically:YES],"real scan request");
    NSUInteger ticks=0;while([service tick] && ++ticks<200) {}
    NSDictionary *scan=[NSDictionary dictionaryWithContentsOfFile:[records stringByAppendingPathComponent:@"scan.plist"]];
    observation=scan[@"allocationObservation"];
    AxsCacheKeeperAllocationCheck(ticks<200 && [scan[@"complete"] boolValue] && [observation[@"allocatedBytes"] unsignedLongLongValue]==expected && [observation[@"duplicateFiles"] unsignedIntegerValue]==2,"task shares inode deduplication across discovered roots");
    unsigned long long contributions=0;for(NSDictionary *row in scan[@"rows"]) contributions+=[row[@"allocationObservation"][@"allocatedBytes"] unsignedLongLongValue];
    AxsCacheKeeperAllocationCheck(contributions==expected && axs_cachekeeper_record_valid(scan,0),"durable row contributions agree with task total and validate");

    cursor=[[AxsCacheKeeperScanCursor alloc] initWithRoot:[NSURL fileURLWithPath:cache] entryLimit:100 depthLimit:64 allocationLimit:2];
    [cursor advanceEntries:100 seconds:1];observation=cursor.result[@"allocationObservation"];
    AxsCacheKeeperAllocationCheck([cursor.state isEqual:@"complete"] && [observation[@"state"] isEqual:@"inodeLimit"] && [observation[@"uniqueFiles"] unsignedIntegerValue]==2 && [observation[@"untrackedFiles"] unsignedIntegerValue]>0,"bounded inode table reports incomplete allocation without failing traversal");
    cursor=[[AxsCacheKeeperScanCursor alloc] initWithRoot:[NSURL fileURLWithPath:cache] entryLimit:100 depthLimit:64];
    [cursor advanceEntries:1 seconds:1];[cursor stopWithState:@"cancelled"];
    AxsCacheKeeperAllocationCheck([cursor.result[@"allocationObservation"][@"state"] isEqual:@"partial"] && cursor.openDirectoryCount==0,"cancelled allocation remains partial and releases descriptors");

    struct stat samples[2]={0};samples[0].st_dev=1;samples[0].st_ino=1;samples[0].st_blocks=-1;
    observation=axs_cachekeeper_scan_allocation_test_stats(samples,1,2);
    AxsCacheKeeperAllocationCheck([observation[@"state"] isEqual:@"invalidMetadata"] && [observation[@"untrackedFiles"] unsignedIntegerValue]==1,"negative blocks are rejected by production accumulator");
    samples[0].st_blocks=INT64_MAX;observation=axs_cachekeeper_scan_allocation_test_stats(samples,1,2);
    AxsCacheKeeperAllocationCheck([observation[@"state"] isEqual:@"invalidMetadata"] && [observation[@"allocatedBytes"] unsignedLongLongValue]==0,"block multiplication overflow cannot become valid allocation");
    samples[0].st_blocks=1;samples[1]=samples[0];samples[1].st_blocks=2;
    observation=axs_cachekeeper_scan_allocation_test_stats(samples,2,2);
    AxsCacheKeeperAllocationCheck([observation[@"state"] isEqual:@"invalidMetadata"] && [observation[@"duplicateFiles"] unsignedIntegerValue]==1,"changed same inode metadata is explicitly invalid");
    // Sequential inodes mirror the large same-device directories seen in full scans.
    NSMutableSet *hashes=[NSMutableSet set];
    for (NSUInteger index=0;index<4096;index++) {
        [hashes addObject:@(axs_cachekeeper_scan_test_inode_hash(7,0x100000000ULL+index))];
    }
    AxsCacheKeeperAllocationCheck(hashes.count>=2048,"same-device sequential inode keys distribute across hash buckets");
    samples[0].st_dev=1;samples[1]=samples[0];samples[1].st_dev=2;
    observation=axs_cachekeeper_scan_allocation_test_stats(samples,2,2);
    AxsCacheKeeperAllocationCheck([observation[@"uniqueFiles"] unsignedIntegerValue]==2,"same inode on distinct devices counts separately");
    NSMutableDictionary *bad=[observation mutableCopy];bad[@"path"]=@"/private/secret";
    AxsCacheKeeperAllocationCheck(!axs_cachekeeper_allocation_projection(bad),"unknown sensitive allocation fields reject closed schema");
    bad=[observation mutableCopy];bad[@"allocatedBytes"]=@YES;
    AxsCacheKeeperAllocationCheck(!axs_cachekeeper_allocation_projection(bad),"boolean cannot impersonate a block count");
    printf("PASS: actual sparse/hardlink/empty metadata, cross-root inode accounting, budget, cancellation and numeric safety (allocated=%llu)\n",expected);return 0;
} }
