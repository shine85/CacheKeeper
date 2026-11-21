#pragma once
#include <stdbool.h>
#include <stdint.h>
#define AXS_CACHEKEEPER_IMAGE_EXACT_MAX UINT64_C(9007199254740991)
typedef enum {
    AxsCacheKeeperImageSampleComplete, AxsCacheKeeperImageSampleReadError,
    AxsCacheKeeperImageSampleChanged, AxsCacheKeeperImageSampleNonFlat,
    AxsCacheKeeperImageSampleEntryLimit, AxsCacheKeeperImageSampleTimeLimit,
    AxsCacheKeeperImageSampleOverflow, AxsCacheKeeperImageSampleCloseError,
    AxsCacheKeeperImageSamplePathChanged
} AxsCacheKeeperImageSampleState;
typedef struct {AxsCacheKeeperImageSampleState state;uint64_t files,logicalBytes,allocatedBytes;} AxsCacheKeeperImageSample;
typedef enum {AxsCacheKeeperImageEffectUnverified,AxsCacheKeeperImageEffectEmpty,AxsCacheKeeperImageEffectResidual} AxsCacheKeeperImageEffectResult;
static inline bool axs_cachekeeper_image_sample_add(AxsCacheKeeperImageSample *sample,uint64_t logical,uint64_t allocated) {
    if (!sample || sample->state!=AxsCacheKeeperImageSampleComplete) return false;
    if (sample->files>=100000) {sample->state=AxsCacheKeeperImageSampleEntryLimit;return false;}
    if (logical>AXS_CACHEKEEPER_IMAGE_EXACT_MAX || allocated>AXS_CACHEKEEPER_IMAGE_EXACT_MAX ||
        sample->logicalBytes>AXS_CACHEKEEPER_IMAGE_EXACT_MAX-logical || sample->allocatedBytes>AXS_CACHEKEEPER_IMAGE_EXACT_MAX-allocated) {
        sample->state=AxsCacheKeeperImageSampleOverflow;return false;
    }
    sample->files++;sample->logicalBytes+=logical;sample->allocatedBytes+=allocated;return true;
}
static inline AxsCacheKeeperImageEffectResult axs_cachekeeper_image_effect_result(AxsCacheKeeperImageSample before,AxsCacheKeeperImageSample after) {
    if (before.state!=AxsCacheKeeperImageSampleComplete || after.state!=AxsCacheKeeperImageSampleComplete) return AxsCacheKeeperImageEffectUnverified;
    return after.files ? AxsCacheKeeperImageEffectResidual : AxsCacheKeeperImageEffectEmpty;
}
