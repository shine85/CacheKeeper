#import <Foundation/Foundation.h>
#import "../AxsCacheKeeperPolicy.h"
#import "../AxsCacheKeeperNetworkCache.h"

extern void axs_cachekeeper_run_network_mode_tests(NSString *fixture);
static void ckcheck(BOOL condition, const char *message) {
    if (!condition) {fprintf(stderr,"FAIL: cache mode behavior: %s\n",message);exit(1);}
}
static NSURLRequest *ckrequest(NSString *name) {
    return [NSURLRequest requestWithURL:[NSURL URLWithString:[@"https://cachekeeper-fixture.invalid/" stringByAppendingString:name]]];
}
static NSData *ckpayload(void) {
    NSMutableData *data=[NSMutableData dataWithLength:131072];
    for (NSUInteger i=0;i<data.length;i++) ((unsigned char *)data.mutableBytes)[i]=(unsigned char)((i*73+19)%251);
    return data;
}
static NSURLCache *ckcache(NSString *root,NSString *name,BOOL url) {
    NSString *path=[root stringByAppendingPathComponent:name];
    return url ? [[NSURLCache alloc] initWithMemoryCapacity:0 diskCapacity:8388608 directoryURL:[NSURL fileURLWithPath:path isDirectory:YES]] :
        [[NSURLCache alloc] initWithMemoryCapacity:0 diskCapacity:8388608 diskPath:path];
}
static void ckstore(NSURLCache *cache,NSString *name) {
    NSURLRequest *request=ckrequest(name);
    NSHTTPURLResponse *response=[[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:200 HTTPVersion:@"HTTP/1.1"
        headerFields:@{@"Cache-Control":@"public, max-age=3600",@"Content-Type":@"application/octet-stream"}];
    [cache storeCachedResponse:[[NSCachedURLResponse alloc] initWithResponse:response data:ckpayload() userInfo:nil storagePolicy:NSURLCacheStorageAllowed] forRequest:request];
}
static BOOL ckwait(BOOL (^condition)(void)) {
    NSTimeInterval end=NSProcessInfo.processInfo.systemUptime+3;
    while (!condition() && NSProcessInfo.processInfo.systemUptime<end) [NSThread sleepForTimeInterval:0.02];
    return condition();
}
int main(int argc,const char **argv) {
    @autoreleasepool {
        ckcheck(argc==4,"expected producer/verifier, fixture and initializer");
        NSString *action=[NSString stringWithUTF8String:argv[1]],*root=[NSString stringWithUTF8String:argv[2]];
        BOOL url=!strcmp(argv[3],"url");
        // No HTTP request is sent. These are synthetic cacheable responses in the
        // test process's own Foundation cache directories, not user containers.
        if ([action isEqual:@"produce"]) {
            axs_cachekeeper_run_network_mode_tests(root);
            NSDictionary *clean=@{@"enabled":@YES,@"mode":@"clean",@"urlCache":@YES};
            NSDictionary *limited=@{@"enabled":@YES,@"mode":@"prevent",@"urlCache":@YES};
            NSDictionary *off=@{@"enabled":@NO,@"mode":@"prevent",@"urlCache":@YES};
            ckcheck(axs_cachekeeper_configure_network_cache(axs_cachekeeper_should_prevent(clean)),"configure clean");
            NSURLCache *control=ckcache(root,@"clean",url);ckstore(control,@"clean");
            ckcheck(ckwait(^BOOL{return [[control cachedResponseForRequest:ckrequest(@"clean")].data isEqual:ckpayload()];}),"clean mode real disk response is readable");
            ckcheck(axs_cachekeeper_configure_network_cache(axs_cachekeeper_should_prevent(limited)),"configure limited");
            NSURLCache *blocked=ckcache(root,@"limited",url);ckstore(blocked,@"limited");
            ckcheck([blocked cachedResponseForRequest:ckrequest(@"limited")]==nil,"limited disk-only response must not be retrievable");
            ckcheck(axs_cachekeeper_configure_network_cache(axs_cachekeeper_should_prevent(off)),"configure disabled");
            // Reuse the very same limited object: a fresh disabled object alone
            // cannot detect a lost pending restoration on existing instances.
            ckstore(blocked,@"restored");
            ckcheck(ckwait(^BOOL{return [[blocked cachedResponseForRequest:ckrequest(@"restored")].data isEqual:ckpayload()];}),"same limited cache resumes real disk IO after disable");
            ckcheck(axs_cachekeeper_configure_network_cache(axs_cachekeeper_should_prevent(off)),"repeat disabled");
            ckstore(blocked,@"late");
            ckcheck(ckwait(^BOOL{return [[blocked cachedResponseForRequest:ckrequest(@"late")].data isEqual:ckpayload()];}),"disabled refresh preserves later disk IO");
            // Foundation can defer persistence. Cross-process reads below, not
            // this delay or currentDiskUsage, are the durability oracle.
            [NSThread sleepForTimeInterval:1];
        } else {
            ckcheck([action isEqual:@"verify"],"unknown fixture action");
            NSURLCache *control=ckcache(root,@"clean",url),*restored=ckcache(root,@"limited",url);
            ckcheck(ckwait(^BOOL{return [[control cachedResponseForRequest:ckrequest(@"clean")].data isEqual:ckpayload()];}),"clean mode response survives process exit");
            ckcheck([restored cachedResponseForRequest:ckrequest(@"limited")]==nil,"limited response was not persisted");
            ckcheck(ckwait(^BOOL{return [[restored cachedResponseForRequest:ckrequest(@"restored")].data isEqual:ckpayload()];}),"restored response survives process exit");
            ckcheck(ckwait(^BOOL{return [[restored cachedResponseForRequest:ckrequest(@"late")].data isEqual:ckpayload()];}),"late disabled response survives process exit");
        }
        puts("PASS: real Foundation disk responses across clean, restricted, disabled and process exit");
    }
    return 0;
}
