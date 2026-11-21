#pragma once
#include <stdbool.h>
#include <math.h>
// Test reference for fixed Swiftgram fitted(aspectFit); no product deletion gate.
typedef struct {double width,height;} AxsCacheKeeperTestSize;
static inline bool axs_cachekeeper_test_scaled_geometry(AxsCacheKeeperTestSize original,AxsCacheKeeperTestSize bound,AxsCacheKeeperTestSize *out) {
    if(!out)return false;*out=(AxsCacheKeeperTestSize){0};
    if(!isfinite(original.width)||!isfinite(original.height)||original.width<=0||original.height<=0||
       floor(original.width)!=original.width||floor(original.height)!=original.height||
       original.width>16384||original.height>16384||original.width*original.height>16000000||
       !isfinite(bound.width)||!isfinite(bound.height)||bound.width<=0||bound.height<=0||
       bound.width>4096||bound.height>4096||floor(bound.width)!=bound.width||floor(bound.height)!=bound.height)return false;
    double w=original.width,h=original.height;
    if(w>bound.width){h=floor(h*bound.width/fmax(w,1));w=bound.width;}
    if(h>bound.height){w=floor(w*bound.height/fmax(h,1));h=bound.height;}
    if(w<=0||h<=0)return false;
    *out=(AxsCacheKeeperTestSize){w,h};return true;
}
