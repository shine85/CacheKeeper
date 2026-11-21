#include "AxsCacheKeeperImageEffect.h"
#include <stdio.h>
#include <stdlib.h>
static void check(bool value,const char *message) {if(!value){fprintf(stderr,"FAIL: image-effect: %s\n",message);exit(1);}}
int main(void) {
    AxsCacheKeeperImageSample before={0},after={0};
    check(axs_cachekeeper_image_sample_add(&before,4096,8192),"first file added");
    check(axs_cachekeeper_image_sample_add(&before,3,4096),"second file added");
    check(before.files==2 && before.logicalBytes==4099 && before.allocatedBytes==12288,"directory entry byte totals");
    check(axs_cachekeeper_image_effect_result(before,after)==AxsCacheKeeperImageEffectEmpty,"empty postcheck is recognized");
    check(axs_cachekeeper_image_sample_add(&after,17,4096),"residual added");
    check(axs_cachekeeper_image_effect_result(before,after)==AxsCacheKeeperImageEffectResidual,"API return cannot hide residual files");
    after.state=AxsCacheKeeperImageSampleReadError;
    check(axs_cachekeeper_image_effect_result(before,after)==AxsCacheKeeperImageEffectUnverified,"failed postcheck is not empty");
    after=(AxsCacheKeeperImageSample){0};before.state=AxsCacheKeeperImageSampleChanged;
    check(axs_cachekeeper_image_effect_result(before,after)==AxsCacheKeeperImageEffectUnverified,"changed precheck prevents comparison");
    before=(AxsCacheKeeperImageSample){.logicalBytes=AXS_CACHEKEEPER_IMAGE_EXACT_MAX};
    check(!axs_cachekeeper_image_sample_add(&before,1,512) && before.state==AxsCacheKeeperImageSampleOverflow && before.files==0 && before.allocatedBytes==0,"overflow preserves previous totals and rejects file atomically");
    before=(AxsCacheKeeperImageSample){.files=100000};
    check(!axs_cachekeeper_image_sample_add(&before,0,0) && before.state==AxsCacheKeeperImageSampleEntryLimit,"entry bound enforced");
    before=(AxsCacheKeeperImageSample){0};
    check(axs_cachekeeper_image_sample_add(&before,5,512) && axs_cachekeeper_image_sample_add(&before,5,512) && before.allocatedBytes==1024,"counts directory entries without inventing hardlink uniqueness");
    puts("PASS: image effect totals, residuals, failed observations and bounds");return 0;
}
