#include <assert.h>
#include <stdio.h>
#include "AxsCacheKeeperImageWriteObservation.h"
static void observe(AxsCacheKeeperWriteObservation *value,uint64_t epoch,unsigned writer,bool blocked,bool nonempty) {
#if AXS_CACHEKEEPER_WRITE_PAYLOAD_OBSERVATION
    axs_cachekeeper_write_observe_payload(value,epoch,writer,blocked,nonempty);
#else
    (void)nonempty;axs_cachekeeper_write_observe(value,epoch,writer,blocked);
#endif
}
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
    *counts=(AxsCacheKeeperWriteCounts){.attempts=AXS_CACHEKEEPER_WRITE_MAX-1,.allowed=3,.blocked=AXS_CACHEKEEPER_WRITE_MAX-4};
    axs_cachekeeper_write_observe(&value,20,0,false);
    assert(counts->attempts==AXS_CACHEKEEPER_WRITE_MAX && counts->allowed==4 && !counts->overflow);
    axs_cachekeeper_write_observe(&value,20,0,true);
    assert(counts->attempts==AXS_CACHEKEEPER_WRITE_MAX && counts->allowed==4 && counts->blocked==AXS_CACHEKEEPER_WRITE_MAX-4 && counts->overflow);
    value.lastEpoch=AXS_CACHEKEEPER_WRITE_MAX;
    assert(!axs_cachekeeper_write_epoch_begin(&value,21,1,true,1) && value.overflow);
#if AXS_CACHEKEEPER_WRITE_PAYLOAD_OBSERVATION
    AxsCacheKeeperWriteObservation payloads={0};
    uint64_t payloadEpoch=axs_cachekeeper_write_epoch_begin(&payloads,1,1,true,2);
    observe(&payloads,payloadEpoch,0,true,false);observe(&payloads,payloadEpoch,0,true,true);
    observe(&payloads,payloadEpoch,0,false,false);observe(&payloads,payloadEpoch,0,false,true);
    AxsCacheKeeperWriteCounts payload=payloads.epochs[0].writers[0];
    assert(payload.attempts==4 && payload.blocked==2 && payload.allowed==2);
    assert(payload.nonemptyAttempts==2 && payload.nonemptyBlocked==1 && payload.nonemptyAllowed==1);
    observe(&payloads,0,1,false,true);
    assert(payloads.unattributed[1].nonemptyAllowed==1 && payloads.unattributed[0].nonemptyAttempts==0);
    counts=&payloads.epochs[0].writers[0];
    *counts=(AxsCacheKeeperWriteCounts){.attempts=AXS_CACHEKEEPER_WRITE_MAX-1,.allowed=AXS_CACHEKEEPER_WRITE_MAX-1,
        .nonemptyAttempts=AXS_CACHEKEEPER_WRITE_MAX-1,.nonemptyAllowed=AXS_CACHEKEEPER_WRITE_MAX-1};
    observe(&payloads,payloadEpoch,0,true,true);
    assert(counts->nonemptyAttempts==AXS_CACHEKEEPER_WRITE_MAX && counts->nonemptyBlocked==1 && !counts->overflow);
    observe(&payloads,payloadEpoch,0,true,true);
    assert(counts->nonemptyAttempts==AXS_CACHEKEEPER_WRITE_MAX && counts->nonemptyBlocked==1 && counts->overflow);
#else
    AxsCacheKeeperWriteObservation payloads={0};
    observe(&payloads,axs_cachekeeper_write_epoch_begin(&payloads,1,1,true,2),0,true,true);
    fputs("FAIL: image writer nonempty payload decisions are not recorded\n",stderr);return 1;
#endif
    puts("PASS: image writer bounded epochs, nonempty payloads and exact overflow");
}
