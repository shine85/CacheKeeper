#include "AxsCacheKeeperReleaseEvidence.h"
#include <limits.h>
#include <math.h>
#include <string.h>

static void axs_cachekeeper_release_increment(AxsCacheKeeperReleaseEvidence *e, uint64_t *value) {
    if (*value==UINT64_MAX) e->overflow=true;
    else ++*value;
}
static AxsCacheKeeperReleaseStat axs_cachekeeper_release_valid_stat(AxsCacheKeeperReleaseStat s) {
    if (s.state==AxsCacheKeeperReleaseObserved && (s.size<0 || s.blocks<0)) s.state=AxsCacheKeeperReleaseInvalid;
    if (s.state!=AxsCacheKeeperReleaseUnavailable) s.error=0;
    return s;
}
static AxsCacheKeeperReleaseMetadata axs_cachekeeper_release_metadata(AxsCacheKeeperReleaseStat s) {
    AxsCacheKeeperReleaseMetadata m={0};m.state=s.state;m.error=s.error;
    if (s.state==AxsCacheKeeperReleaseObserved) {m.size=(uint64_t)s.size;m.blocks=(uint64_t)s.blocks;m.nlink=s.nlink;}
    return m;
}
static bool axs_cachekeeper_release_same(AxsCacheKeeperReleaseStat a,AxsCacheKeeperReleaseStat b) {
    return a.device==b.device && a.inode==b.inode && a.birthSeconds==b.birthSeconds && a.birthNanos==b.birthNanos;
}
static uint64_t axs_cachekeeper_release_object(AxsCacheKeeperReleaseEvidence *e,AxsCacheKeeperReleaseStat pre,AxsCacheKeeperReleaseStat post) {
    if (pre.state!=AxsCacheKeeperReleaseObserved) return 0;
    uint64_t hash=pre.inode^(pre.device*UINT64_C(0x9e3779b97f4a7c15));
    hash^=hash>>33;hash*=UINT64_C(0xff51afd7ed558ccd);hash^=hash>>33;
    for (size_t probe=0;probe<AXS_CACHEKEEPER_RELEASE_IDENTITY_SLOTS;probe++) {
        AxsCacheKeeperReleaseIdentitySlot *slot=&e->identities[(hash+probe)%AXS_CACHEKEEPER_RELEASE_IDENTITY_SLOTS];
        if (slot->occupied && (slot->device!=pre.device || slot->inode!=pre.inode ||
            slot->birthSeconds!=pre.birthSeconds || slot->birthNanos!=pre.birthNanos)) continue;
        if (!slot->occupied || !slot->continuous || slot->nlink!=pre.nlink) {
            if (e->identityCount==AXS_CACHEKEEPER_RELEASE_IDENTITY_CAP) return 0;
            slot->occupied=true;slot->device=pre.device;slot->inode=pre.inode;
            slot->birthSeconds=pre.birthSeconds;slot->birthNanos=pre.birthNanos;
            slot->objectID=++e->identityCount;
        }
        slot->continuous=post.state==AxsCacheKeeperReleaseObserved && axs_cachekeeper_release_same(pre,post) && post.nlink>0;
        slot->nlink=slot->continuous ? post.nlink : 0;
        return slot->objectID;
    }
    return 0;
}
void axs_cachekeeper_release_init(AxsCacheKeeperReleaseEvidence *e) { memset(e,0,sizeof(*e)); }
void axs_cachekeeper_release_record(AxsCacheKeeperReleaseEvidence *e,uint64_t rootID,AxsCacheKeeperReleaseKind kind,
    int result,int unlinkError,AxsCacheKeeperReleaseStat pre,AxsCacheKeeperReleaseStat post) {
    if (e->finished) return;
    pre=axs_cachekeeper_release_valid_stat(pre);post=axs_cachekeeper_release_valid_stat(post);
    axs_cachekeeper_release_increment(e,&e->attempts);
    axs_cachekeeper_release_increment(e,result==0 ? &e->succeeded : &e->failed);
    if (post.state!=AxsCacheKeeperReleaseObserved) axs_cachekeeper_release_increment(e,&e->postMissing);
    uint64_t objectID=axs_cachekeeper_release_object(e,pre,post);
    if (!objectID) axs_cachekeeper_release_increment(e,&e->identitiesOmitted);
    if (e->detailCount<AXS_CACHEKEEPER_RELEASE_DETAIL_CAP) {
        AxsCacheKeeperReleaseDetail *d=&e->details[e->detailCount++];
        d->attemptID=e->attempts;d->rootID=rootID;d->objectID=objectID;d->kind=kind;
        d->result=result;d->error=result==0 ? 0 : unlinkError;
        d->pre=axs_cachekeeper_release_metadata(pre);d->post=axs_cachekeeper_release_metadata(post);
        if (pre.state==AxsCacheKeeperReleaseObserved && post.state==AxsCacheKeeperReleaseObserved) {
            bool same=axs_cachekeeper_release_same(pre,post);
            d->identityMatch=same ? AxsCacheKeeperReleaseSame : AxsCacheKeeperReleaseDifferent;
            if (same) d->linkTransition=pre.nlink>0 && post.nlink==pre.nlink-1 ? AxsCacheKeeperReleaseLinkDecremented :
                pre.nlink==post.nlink ? AxsCacheKeeperReleaseLinkUnchanged : AxsCacheKeeperReleaseLinkOther;
        }
    } else axs_cachekeeper_release_increment(e,&e->detailsOmitted);
    axs_cachekeeper_release_increment(e,&e->revision);
}
static AxsCacheKeeperReleaseVolumeSample axs_cachekeeper_release_valid_volume(AxsCacheKeeperReleaseVolumeSample s) {
    if (s.state==AxsCacheKeeperReleaseObserved && (!s.blockSize || !isfinite(s.uptime) || s.uptime<0))
        s.state=AxsCacheKeeperReleaseInvalid;
    if (s.state!=AxsCacheKeeperReleaseUnavailable) s.error=0;
    return s;
}
size_t axs_cachekeeper_release_begin_volume(AxsCacheKeeperReleaseEvidence *e,AxsCacheKeeperReleaseVolumeSample before) {
    if (e->finished) return 0;
    if (e->volumeCount==AXS_CACHEKEEPER_RELEASE_VOLUME_CAP) {
        axs_cachekeeper_release_increment(e,&e->volumesOmitted);axs_cachekeeper_release_increment(e,&e->revision);return 0;
    }
    e->volumes[e->volumeCount++].before=axs_cachekeeper_release_valid_volume(before);
    axs_cachekeeper_release_increment(e,&e->revision);return e->volumeCount;
}
static bool axs_cachekeeper_release_delta(uint64_t before,uint64_t after,uint64_t unit,int64_t *delta) {
    if (before>UINT64_MAX/unit || after>UINT64_MAX/unit) return false;
    before*=unit;after*=unit;
    uint64_t magnitude=after>=before ? after-before : before-after;
    if (after>=before) {if (magnitude>INT64_MAX) return false;*delta=(int64_t)magnitude;}
    else {if (magnitude>UINT64_C(1)<<63) return false;*delta=magnitude==(UINT64_C(1)<<63) ? INT64_MIN : -(int64_t)magnitude;}
    return true;
}
void axs_cachekeeper_release_end_volume(AxsCacheKeeperReleaseEvidence *e,size_t volumeID,
    AxsCacheKeeperReleaseVolumeSample after,int closeError) {
    if (e->finished || !volumeID || volumeID>e->volumeCount) return;
    AxsCacheKeeperReleaseVolume *v=&e->volumes[volumeID-1];
    if (v->after.state!=AxsCacheKeeperReleaseNotRecorded) return;
    v->after=axs_cachekeeper_release_valid_volume(after);v->closeError=closeError;
    if (v->before.state==AxsCacheKeeperReleaseObserved && v->after.state==AxsCacheKeeperReleaseObserved &&
        v->before.blockSize==v->after.blockSize && v->after.uptime>=v->before.uptime) {
        v->paired=axs_cachekeeper_release_delta(v->before.freeBlocks,v->after.freeBlocks,v->before.blockSize,&v->freeBytesDelta) &&
            axs_cachekeeper_release_delta(v->before.availableBlocks,v->after.availableBlocks,v->before.blockSize,&v->availableBytesDelta);
        v->overflow=!v->paired;
        if (v->overflow) e->overflow=true;
        else v->elapsedSeconds=v->after.uptime-v->before.uptime;
    }
    axs_cachekeeper_release_increment(e,&e->revision);
}
void axs_cachekeeper_release_finish(AxsCacheKeeperReleaseEvidence *e,bool cancelled) {
    if (e->finished) return;
    e->finished=true;e->cancelled=cancelled;axs_cachekeeper_release_increment(e,&e->revision);
}
