#include "../AxsCacheKeeperReleaseEvidence.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

static AxsCacheKeeperReleaseEvidence e;
static void check(bool ok, const char *message) {
    if (!ok) { fprintf(stderr,"FAIL: release-evidence: %s\n",message); exit(1); }
}
static AxsCacheKeeperReleaseStat st(uint64_t inode, uint64_t links) {
    AxsCacheKeeperReleaseStat s={0};s.state=AxsCacheKeeperReleaseObserved;
    s.device=9;s.inode=inode;s.nlink=links;s.size=17;s.blocks=8;s.birthSeconds=123;
    return s;
}
static AxsCacheKeeperReleaseVolumeSample volume(uint64_t freeBlocks, uint64_t available) {
    AxsCacheKeeperReleaseVolumeSample v={AxsCacheKeeperReleaseObserved,0,4096,freeBlocks,available,10};return v;
}
int main(void) {
    axs_cachekeeper_release_init(&e);
    axs_cachekeeper_release_record(&e,1,AxsCacheKeeperReleaseOrdinary,0,13,st(42,1),st(42,0));
    check(e.attempts==1 && e.succeeded==1 && e.failed==0 && e.details[0].error==0,
        "successful syscall is recorded without stale errno");
    check(e.details[0].identityMatch==AxsCacheKeeperReleaseSame && e.details[0].linkTransition==AxsCacheKeeperReleaseLinkDecremented && e.details[0].post.blocks==8,
        "observed unlink preserves allocated blocks without claiming release");
    axs_cachekeeper_release_record(&e,2,AxsCacheKeeperReleaseHardlink,0,0,st(43,2),st(43,1));
    axs_cachekeeper_release_record(&e,3,AxsCacheKeeperReleaseHardlink,0,0,st(43,1),st(43,0));
    check(e.details[1].objectID==e.details[2].objectID && e.details[1].objectID!=e.details[0].objectID,
        "closed aliases share an anonymous object within their observed continuity");
    axs_cachekeeper_release_record(&e,1,AxsCacheKeeperReleaseOrdinary,0,0,st(42,1),st(42,0));
    check(e.details[3].objectID!=e.details[0].objectID,"reused identity after zero links gets a new object generation");
    AxsCacheKeeperReleaseStat missing={0};missing.state=AxsCacheKeeperReleaseUnavailable;missing.error=9;
    axs_cachekeeper_release_record(&e,1,AxsCacheKeeperReleaseOrdinary,-1,13,st(50,1),missing);
    check(e.failed==1 && e.postMissing==1 && e.details[4].error==13 && e.details[4].post.error==9,
        "unlink failure and post-stat failure keep separate real errno");
    AxsCacheKeeperReleaseStat invalid=st(51,1);invalid.blocks=-1;invalid.error=13;
    axs_cachekeeper_release_record(&e,1,AxsCacheKeeperReleaseOrdinary,0,0,invalid,invalid);
    check(e.details[5].pre.state==AxsCacheKeeperReleaseInvalid && !e.details[5].pre.error && !e.details[5].objectID && e.postMissing==2,
        "negative metadata is invalid without manufactured errno or identity");
    axs_cachekeeper_release_record(&e,1,AxsCacheKeeperReleaseOrdinary,0,0,st(52,1),st(53,0));
    check(e.details[6].identityMatch==AxsCacheKeeperReleaseDifferent && e.details[6].linkTransition==AxsCacheKeeperReleaseLinkUnknown,
        "different post identity cannot prove a link decrement");
    uint64_t rev=e.revision;axs_cachekeeper_release_finish(&e,true);
    axs_cachekeeper_release_record(&e,1,AxsCacheKeeperReleaseOrdinary,0,0,st(60,1),st(60,0));
    axs_cachekeeper_release_finish(&e,false);
    check(e.attempts==7 && e.finished && e.cancelled && e.revision==rev+1,"terminal evidence freezes and retains cancellation");
    axs_cachekeeper_release_init(&e);
    for (size_t i=0;i<2050;i++) axs_cachekeeper_release_record(&e,1,AxsCacheKeeperReleaseOrdinary,0,0,st(100+i,1),st(100+i,0));
    check(e.detailCount==256 && e.attempts==2050 && e.detailsOmitted==1794 && e.identityCount==2048 && e.identitiesOmitted==2,
        "bounded detail and identity tables close against every actual attempt");
    e.attempts=UINT64_MAX;e.succeeded=UINT64_MAX;e.detailsOmitted=UINT64_MAX;e.revision=UINT64_MAX;
    axs_cachekeeper_release_record(&e,1,AxsCacheKeeperReleaseOrdinary,0,0,st(9000,1),st(9000,0));
    check(e.attempts==UINT64_MAX && e.succeeded==UINT64_MAX && e.detailsOmitted==UINT64_MAX && e.revision==UINT64_MAX && e.overflow,
        "counters saturate without wrapping complete evidence");
    axs_cachekeeper_release_init(&e);
    size_t id=axs_cachekeeper_release_begin_volume(&e,volume(100,80));
    AxsCacheKeeperReleaseVolumeSample after=volume(98,81);after.uptime=13;
    axs_cachekeeper_release_end_volume(&e,id,after,0);
    check(e.volumes[0].paired && e.volumes[0].freeBytesDelta==-8192 && e.volumes[0].availableBytesDelta==4096 && e.volumes[0].elapsedSeconds==3,
        "volume observation retains signed independent deltas");
    id=axs_cachekeeper_release_begin_volume(&e,volume(100,80));after=volume(100,80);after.uptime=11;
    axs_cachekeeper_release_end_volume(&e,id,after,0);
    check(e.volumes[1].paired && !e.volumes[1].freeBytesDelta,"zero volume delta remains a valid observation");
    id=axs_cachekeeper_release_begin_volume(&e,volume(UINT64_MAX,80));
    axs_cachekeeper_release_end_volume(&e,id,after,0);
    check(e.volumes[2].overflow && !e.volumes[2].paired && e.overflow,"volume arithmetic overflow is explicit and not measured zero");
    id=axs_cachekeeper_release_begin_volume(&e,volume(100,80));after.state=AxsCacheKeeperReleaseUnavailable;after.error=5;
    axs_cachekeeper_release_end_volume(&e,id,after,4);
    check(!e.volumes[3].paired && e.volumes[3].after.error==5 && e.volumes[3].closeError==4,
        "volume sample and close failure remain independent");
    check(!axs_cachekeeper_release_begin_volume(&e,volume(1,1)) && e.volumesOmitted==1 && e.volumeCount==4,
        "volume capacity is bounded and omitted requests are explicit");
    puts("PASS: release-evidence core behavior");return 0;
}
