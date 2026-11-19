#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define AXS_CACHEKEEPER_RELEASE_DETAIL_CAP 256
#define AXS_CACHEKEEPER_RELEASE_IDENTITY_CAP 2048
#define AXS_CACHEKEEPER_RELEASE_IDENTITY_SLOTS 4096
#define AXS_CACHEKEEPER_RELEASE_VOLUME_CAP 4

typedef enum {
    AxsCacheKeeperReleaseNotRecorded, AxsCacheKeeperReleaseObserved,
    AxsCacheKeeperReleaseUnavailable, AxsCacheKeeperReleaseInvalid
} AxsCacheKeeperReleaseSampleState;
typedef enum { AxsCacheKeeperReleaseOrdinary, AxsCacheKeeperReleaseHardlink } AxsCacheKeeperReleaseKind;
typedef enum { AxsCacheKeeperReleaseUnknown, AxsCacheKeeperReleaseSame, AxsCacheKeeperReleaseDifferent } AxsCacheKeeperReleaseIdentityMatch;
typedef enum { AxsCacheKeeperReleaseLinkUnknown, AxsCacheKeeperReleaseLinkDecremented,
    AxsCacheKeeperReleaseLinkUnchanged, AxsCacheKeeperReleaseLinkOther } AxsCacheKeeperReleaseLinkTransition;

// Raw identities are transient inputs, never fields of a public detail or serialized snapshot.
typedef struct {
    AxsCacheKeeperReleaseSampleState state;
    int error;
    uint64_t device, inode, nlink;
    int64_t size, blocks, birthSeconds, birthNanos;
} AxsCacheKeeperReleaseStat;
typedef struct {
    AxsCacheKeeperReleaseSampleState state;
    int error;
    uint64_t size, blocks, nlink;
} AxsCacheKeeperReleaseMetadata;
typedef struct {
    uint64_t attemptID, rootID, objectID;
    AxsCacheKeeperReleaseKind kind;
    int result, error;
    AxsCacheKeeperReleaseMetadata pre, post;
    AxsCacheKeeperReleaseIdentityMatch identityMatch;
    AxsCacheKeeperReleaseLinkTransition linkTransition;
} AxsCacheKeeperReleaseDetail;
typedef struct {
    AxsCacheKeeperReleaseSampleState state;
    int error;
    uint64_t blockSize, freeBlocks, availableBlocks;
    double uptime;
} AxsCacheKeeperReleaseVolumeSample;
typedef struct {
    AxsCacheKeeperReleaseVolumeSample before, after;
    int closeError;
    bool paired, overflow;
    int64_t freeBytesDelta, availableBytesDelta;
    double elapsedSeconds;
} AxsCacheKeeperReleaseVolume;
typedef struct {
    uint64_t device, inode, objectID, nlink;
    int64_t birthSeconds, birthNanos;
    bool occupied, continuous;
} AxsCacheKeeperReleaseIdentitySlot;
typedef struct {
    uint64_t revision, attempts, succeeded, failed, postMissing;
    uint64_t detailsOmitted, identitiesOmitted, volumesOmitted;
    bool overflow, finished, cancelled;
    size_t detailCount, identityCount, volumeCount;
    AxsCacheKeeperReleaseDetail details[AXS_CACHEKEEPER_RELEASE_DETAIL_CAP];
    AxsCacheKeeperReleaseVolume volumes[AXS_CACHEKEEPER_RELEASE_VOLUME_CAP];
    AxsCacheKeeperReleaseIdentitySlot identities[AXS_CACHEKEEPER_RELEASE_IDENTITY_SLOTS];
} AxsCacheKeeperReleaseEvidence;

#ifdef __cplusplus
extern "C" {
#endif

// Single owning Job/serial queue. No I/O, allocation, clocks, callbacks or deletion decisions.
void axs_cachekeeper_release_init(AxsCacheKeeperReleaseEvidence *evidence);
void axs_cachekeeper_release_record(AxsCacheKeeperReleaseEvidence *evidence, uint64_t rootID,
    AxsCacheKeeperReleaseKind kind, int result, int unlinkError,
    AxsCacheKeeperReleaseStat pre, AxsCacheKeeperReleaseStat post);
// Returns a 1-based anonymous volume ID, or 0 when bounded capacity is exhausted/finished.
size_t axs_cachekeeper_release_begin_volume(AxsCacheKeeperReleaseEvidence *evidence,
    AxsCacheKeeperReleaseVolumeSample before);
void axs_cachekeeper_release_end_volume(AxsCacheKeeperReleaseEvidence *evidence, size_t volumeID,
    AxsCacheKeeperReleaseVolumeSample after, int closeError);
void axs_cachekeeper_release_finish(AxsCacheKeeperReleaseEvidence *evidence, bool cancelled);

#ifdef __cplusplus
}
#endif
