#include <assert.h>
#include <stdio.h>
#include "AxsCacheKeeperImageWriteObservation.h"
int main(void) {
    AxsCacheKeeperWriteObservation value={0};
    uint64_t first=axs_cachekeeper_write_epoch_begin(&value,1,1,true,0);
    axs_cachekeeper_write_observe(&value,first,0,true);axs_cachekeeper_write_observe(&value,first,1,true);
    assert(value.epochs[0].writers[0].attempts==1 && value.epochs[0].writers[1].blocked==1);
    uint64_t next=axs_cachekeeper_write_epoch_begin(&value,2,1,false,2);
    axs_cachekeeper_write_observe(&value,first,0,true);axs_cachekeeper_write_observe(&value,next,0,false);
    assert(value.epochs[0].writers[0].blocked==2 && value.epochs[1].writers[0].allowed==1);
    assert(axs_cachekeeper_write_epoch_begin(&value,2,1,false,2)==next && value.count==2);
    for (uint64_t i=3;i<=20;i++) axs_cachekeeper_write_epoch_begin(&value,i,1,true,1);
    assert(value.count==16 && value.droppedEpochs==4 && value.lastEpoch==20 && value.epochs[0].identifier==5);
    axs_cachekeeper_write_observe(&value,first,1,false);assert(value.unattributed[1].allowed==1);
    AxsCacheKeeperWriteCounts *counts=&value.epochs[15].writers[0];
    *counts=(AxsCacheKeeperWriteCounts){AXS_CACHEKEEPER_WRITE_MAX-1,3,AXS_CACHEKEEPER_WRITE_MAX-4,false};
    axs_cachekeeper_write_observe(&value,20,0,false);
    assert(counts->attempts==AXS_CACHEKEEPER_WRITE_MAX && counts->allowed==4 && !counts->overflow);
    axs_cachekeeper_write_observe(&value,20,0,true);
    assert(counts->attempts==AXS_CACHEKEEPER_WRITE_MAX && counts->allowed==4 && counts->blocked==AXS_CACHEKEEPER_WRITE_MAX-4 && counts->overflow);
    value.lastEpoch=AXS_CACHEKEEPER_WRITE_MAX;
    assert(!axs_cachekeeper_write_epoch_begin(&value,21,1,true,1) && value.overflow);
    puts("PASS: image writer bounded epochs and exact overflow");
}
