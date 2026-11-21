#include "ScaledRepresentationGeometry.h"
#include <stdio.h>
#include <stdlib.h>
static void check(bool v,const char *m){if(!v){fprintf(stderr,"FAIL: scaled-representation: %s\n",m);exit(1);}}
int main(void){
    AxsCacheKeeperTestSize result;
    check(axs_cachekeeper_test_scaled_geometry((AxsCacheKeeperTestSize){400,300},(AxsCacheKeeperTestSize){128,128},&result)&&result.width==128&&result.height==96,"fixed aspect fit produces 128 by 96");
    check(axs_cachekeeper_test_scaled_geometry((AxsCacheKeeperTestSize){32,16},(AxsCacheKeeperTestSize){128,128},&result)&&result.width==32&&result.height==16,"small original is never enlarged");
    check(axs_cachekeeper_test_scaled_geometry((AxsCacheKeeperTestSize){501,1001},(AxsCacheKeeperTestSize){128,128},&result)&&result.width==64&&result.height==128,"two-stage floor follows fixed source");
    check(!axs_cachekeeper_test_scaled_geometry((AxsCacheKeeperTestSize){3,1000},(AxsCacheKeeperTestSize){128,128},&result)&&result.width==0&&result.height==0,"zero-axis result cannot silently become one pixel");
    double invalid[]={0,-1,NAN,INFINITY,0.5,4097};
    for(unsigned i=0;i<sizeof(invalid)/sizeof(invalid[0]);i++) check(!axs_cachekeeper_test_scaled_geometry((AxsCacheKeeperTestSize){400,300},(AxsCacheKeeperTestSize){invalid[i],128},&result),"invalid or oversized target rejected");
    check(!axs_cachekeeper_test_scaled_geometry((AxsCacheKeeperTestSize){9000,9000},(AxsCacheKeeperTestSize){128,128},&result),"decode pixel budget is bounded");
    check(!axs_cachekeeper_test_scaled_geometry((AxsCacheKeeperTestSize){12.5,16},(AxsCacheKeeperTestSize){128,128},&result),"fractional source pixel dimensions rejected");
    check(!axs_cachekeeper_test_scaled_geometry((AxsCacheKeeperTestSize){400,300},(AxsCacheKeeperTestSize){128,128},NULL),"missing output refused");
    puts("PASS: fixed scaled representation dimensions and safe synthetic bounds");return 0;
}
