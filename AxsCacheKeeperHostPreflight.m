#import "AxsCacheKeeperHostPreflight.h"
#import "AxsCacheKeeperHostEvidence.h"
#include <errno.h>

NSArray<NSDictionary *> *axs_cachekeeper_host_preflight_targets(void) {
    static NSArray *targets;static dispatch_once_t once;
    dispatch_once(&once,^{targets=@[@{@"bundle":@"com.ss.iphone.ugc.Aweme",@"name":@"抖音"},
        @{@"bundle":@"com.tencent.mqq",@"name":@"QQ"},@{@"bundle":@"com.baidu.netdisk",@"name":@"百度网盘"},
        @{@"bundle":@"com.360buy.jdmobile",@"name":@"京东"},@{@"bundle":@"app.swiftgram.ios",@"name":@"Swiftgram"}];});
    return targets;
}

@interface AxsCacheKeeperHostPreflight ()
@property(nonatomic,copy) NSString *axs_cachekeeper_directory,*axs_cachekeeper_panelVersion;
@property(nonatomic,strong) NSMutableArray<AxsCacheKeeperHostEvidenceClient *> *axs_cachekeeper_clients;
@property(nonatomic,strong) NSMutableArray<NSMutableDictionary *> *axs_cachekeeper_rows;
@end

@implementation AxsCacheKeeperHostPreflight
- (instancetype)initWithStatusDirectory:(NSString *)directory panelVersion:(NSString *)version {
    if (!(self=[super init]) || ![directory isKindOfClass:NSString.class] || !directory.length ||
        ![version isKindOfClass:NSString.class]) return nil;
    _axs_cachekeeper_directory=[directory copy];_axs_cachekeeper_panelVersion=[version copy];
    _axs_cachekeeper_clients=[NSMutableArray new];[self axs_cachekeeper_reset];return self;
}
- (void)axs_cachekeeper_reset {
    self.axs_cachekeeper_rows=[NSMutableArray new];
    for (NSDictionary *target in axs_cachekeeper_host_preflight_targets()) {
        NSMutableDictionary *row=[target mutableCopy];
        [row addEntriesFromDictionary:@{@"state":@"idle",@"summary":@"尚未开始宿主预检",@"saveState":@"notAttempted",@"saveErrorCode":@0}];
        [self.axs_cachekeeper_rows addObject:row];
    }
}
- (BOOL)running {
    @synchronized(self) {
        for (NSDictionary *row in self.axs_cachekeeper_rows) if ([row[@"state"] isEqual:@"pending"]) return YES;
        return NO;
    }
}
- (void)axs_cachekeeper_save:(NSMutableDictionary *)row {
    NSDictionary *result=row[@"result"];if (!result) return;
    NSError *error=nil;BOOL directory=NO;
    BOOL exists=[NSFileManager.defaultManager fileExistsAtPath:self.axs_cachekeeper_directory isDirectory:&directory];
    BOOL saved=NO;
    if (!exists || !directory) error=[NSError errorWithDomain:NSPOSIXErrorDomain code:exists ? ENOTDIR : ENOENT userInfo:nil];
    else {
        NSData *data=[NSPropertyListSerialization dataWithPropertyList:result format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
        NSString *path=[self.axs_cachekeeper_directory stringByAppendingPathComponent:[row[@"bundle"] stringByAppendingString:@".hostObserved.plist"]];
        if (data) saved=[data writeToFile:path options:NSDataWritingAtomic error:&error];
    }
    row[@"saveState"]=saved ? @"succeeded" : @"failed";row[@"saveErrorCode"]=@(saved ? 0 : (error.code ?: EIO));
}
- (void)axs_cachekeeper_accept:(NSDictionary *)result row:(NSMutableDictionary *)row {
    if (![row[@"state"] isEqual:@"pending"] || [result[@"state"] isEqual:@"pending"]) return;
    NSDictionary *projected=axs_cachekeeper_host_observed_projection(result);
    if (!projected) projected=axs_cachekeeper_host_observed_projection(@{@"source":@"panelObserved",@"state":@"invalidResponse",@"updated":@(NSDate.date.timeIntervalSince1970),@"transportTrust":@"unauthenticated"});
    row[@"result"]=projected;row[@"state"]=projected[@"state"];
    row[@"summary"]=axs_cachekeeper_host_summary(@{@"state":@"available",@"data":projected},self.axs_cachekeeper_panelVersion);
    [self axs_cachekeeper_save:row];
}
- (BOOL)startWithTimeout:(NSTimeInterval)timeout {
    @synchronized(self) {
        if (self.running) return NO;
        [self cancel];[self.axs_cachekeeper_clients removeAllObjects];[self axs_cachekeeper_reset];
        for (NSMutableDictionary *row in self.axs_cachekeeper_rows) {
            AxsCacheKeeperHostEvidenceClient *client=[[AxsCacheKeeperHostEvidenceClient alloc] initWithBundle:row[@"bundle"]];
            [self.axs_cachekeeper_clients addObject:client];row[@"state"]=@"pending";row[@"summary"]=@"等待本轮宿主自报告；请在时限内打开 APP";
            if (![client axs_cachekeeper_beginWithTimeout:timeout]) [self axs_cachekeeper_accept:[client axs_cachekeeper_poll] row:row];
        }
        return YES;
    }
}
- (void)poll {
    @synchronized(self) {
        [self.axs_cachekeeper_clients enumerateObjectsUsingBlock:^(AxsCacheKeeperHostEvidenceClient *client,NSUInteger index,BOOL *stop) {
            (void)stop;NSMutableDictionary *row=self.axs_cachekeeper_rows[index];
            if ([row[@"state"] isEqual:@"pending"]) [self axs_cachekeeper_accept:[client axs_cachekeeper_poll] row:row];
        }];
    }
}
- (void)cancel {
    @synchronized(self) {
        [self.axs_cachekeeper_clients enumerateObjectsUsingBlock:^(AxsCacheKeeperHostEvidenceClient *client,NSUInteger index,BOOL *stop) {
            (void)stop;
            [client axs_cachekeeper_cancel];
            [self axs_cachekeeper_accept:[client axs_cachekeeper_poll] row:self.axs_cachekeeper_rows[index]];
        }];
    }
}
- (void)retrySaving {
    @synchronized(self) {for (NSMutableDictionary *row in self.axs_cachekeeper_rows) if ([row[@"saveState"] isEqual:@"failed"]) [self axs_cachekeeper_save:row];}
}
- (NSDictionary *)snapshot {
    @synchronized(self) {
        NSMutableArray *rows=[NSMutableArray new];NSUInteger completed=0;
        for (NSDictionary *row in self.axs_cachekeeper_rows) {
            if (![@[@"idle",@"pending"] containsObject:row[@"state"]]) completed++;
            [rows addObject:[row copy]];
        }
        return @{@"running":@(self.running),@"completed":@(completed),@"total":@(rows.count),@"rows":[rows copy]};
    }
}
- (void)dealloc {for (AxsCacheKeeperHostEvidenceClient *client in _axs_cachekeeper_clients) [client axs_cachekeeper_cancel];}
@end
