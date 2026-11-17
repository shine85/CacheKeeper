#import "ScanHostEvidenceBoundary.h"
#import "../../AxsCacheKeeperPolicy.h"
#include <notify.h>

static AxsCacheKeeperScanHostFailure AxsCacheKeeperScanHostFailureStage;
static NSUInteger AxsCacheKeeperScanHostRegisterCalls,AxsCacheKeeperScanHostCancelCalls;
static NSMutableSet *AxsCacheKeeperScanHostTokens;
void axs_cachekeeper_scan_host_fail(AxsCacheKeeperScanHostFailure failure) {
    NSCAssert(AxsCacheKeeperScanHostTokens.count==0,@"Previous actual client tokens must be released first");
    AxsCacheKeeperScanHostFailureStage=failure;AxsCacheKeeperScanHostRegisterCalls=0;AxsCacheKeeperScanHostCancelCalls=0;
    AxsCacheKeeperScanHostTokens=[NSMutableSet new];
}
NSUInteger axs_cachekeeper_scan_host_active_tokens(void) {return AxsCacheKeeperScanHostTokens.count;}
NSUInteger axs_cachekeeper_scan_host_register_calls(void) {return AxsCacheKeeperScanHostRegisterCalls;}
NSUInteger axs_cachekeeper_scan_host_cancel_calls(void) {return AxsCacheKeeperScanHostCancelCalls;}
static uint32_t axs_cachekeeper_scan_host_register(const char *name,int *token) {
    AxsCacheKeeperScanHostRegisterCalls++;
    if ((AxsCacheKeeperScanHostFailureStage==AxsCacheKeeperScanHostFailureFirstRegister && AxsCacheKeeperScanHostRegisterCalls==1) ||
        (AxsCacheKeeperScanHostFailureStage==AxsCacheKeeperScanHostFailureSecondRegister && AxsCacheKeeperScanHostRegisterCalls==2)) return NOTIFY_STATUS_FAILED;
    uint32_t result=notify_register_check(name,token);if (result==NOTIFY_STATUS_OK) [AxsCacheKeeperScanHostTokens addObject:@(*token)];return result;
}
static uint32_t axs_cachekeeper_scan_host_set(int token,uint64_t state) {
    return AxsCacheKeeperScanHostFailureStage==AxsCacheKeeperScanHostFailureSet ? NOTIFY_STATUS_FAILED : notify_set_state(token,state);
}
static uint32_t axs_cachekeeper_scan_host_post(const char *name) {
    return AxsCacheKeeperScanHostFailureStage==AxsCacheKeeperScanHostFailurePost ? NOTIFY_STATUS_FAILED : notify_post(name);
}
static uint32_t axs_cachekeeper_scan_host_cancel(int token) {
    AxsCacheKeeperScanHostCancelCalls++;[AxsCacheKeeperScanHostTokens removeObject:@(token)];return notify_cancel(token);
}

// Compile the actual client against controlled system-call boundaries. Distinct
// test-only names avoid duplicating the harness's unchanged production classes.
#define AXS_CACHEKEEPER_HOST_CLIENT_ONLY 1
#define AxsCacheKeeperHostEvidenceClient AxsCacheKeeperScanHostClient
#define axs_cachekeeper_host_request axs_cachekeeper_scan_host_request
#define axs_cachekeeper_host_request_fresh axs_cachekeeper_scan_host_request_fresh
#define axs_cachekeeper_host_encode axs_cachekeeper_scan_host_encode
#define axs_cachekeeper_host_decode axs_cachekeeper_scan_host_decode
#define axs_cachekeeper_host_projection axs_cachekeeper_scan_host_projection
#define axs_cachekeeper_host_observed_projection axs_cachekeeper_scan_host_observed_projection
#define axs_cachekeeper_network_projection axs_cachekeeper_scan_network_projection
#define axs_cachekeeper_host_version_state axs_cachekeeper_scan_host_version_state
#define axs_cachekeeper_host_name axs_cachekeeper_scan_host_name
#define axs_cachekeeper_host_summary axs_cachekeeper_scan_host_summary
#define notify_register_check axs_cachekeeper_scan_host_register
#define notify_set_state axs_cachekeeper_scan_host_set
#define notify_post axs_cachekeeper_scan_host_post
#define notify_cancel axs_cachekeeper_scan_host_cancel
#import "../../AxsCacheKeeperHostEvidence.m"
