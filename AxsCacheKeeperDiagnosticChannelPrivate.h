#pragma once
#import <Foundation/Foundation.h>
#include <mach/mach.h>
#include <mach/message.h>
#include <sys/types.h>
#include <stdint.h>
#include <stddef.h>

// Exact signatures: Apple XNU xnu-8792.61.2 bsd/sys/codesign.h:72,
// libsyscall/wrappers/libproc/libproc.h:103; launchd liblaunch/bootstrap.h:270,325.
// Evidence hashes are recorded in tmp/pdf-ipc-evidence/manifest.json.
// Weak imports preserve an explicit unavailable result when a runtime omits a private API.
extern int csops_audittoken(pid_t, unsigned int, void *, size_t, audit_token_t *) __attribute__((weak_import));
extern int proc_pidpath_audittoken(audit_token_t *, void *, uint32_t) __attribute__((weak_import));
extern kern_return_t bootstrap_register(mach_port_t, char [128], mach_port_t) __attribute__((weak_import));
extern kern_return_t bootstrap_look_up(mach_port_t, const char [128], mach_port_t *) __attribute__((weak_import));

typedef NS_ENUM(uint32_t,AxsCacheKeeperChannelStage) {
    AxsCacheKeeperChannelNone, AxsCacheKeeperChannelHost, AxsCacheKeeperChannelSelfToken,
    AxsCacheKeeperChannelAPI, AxsCacheKeeperChannelSystemURL, AxsCacheKeeperChannelStatus,
    AxsCacheKeeperChannelSigning, AxsCacheKeeperChannelExecutable, AxsCacheKeeperChannelFinalStatus,
    AxsCacheKeeperChannelRegister, AxsCacheKeeperChannelLookup, AxsCacheKeeperChannelSend,
    AxsCacheKeeperChannelReceive, AxsCacheKeeperChannelProtocol, AxsCacheKeeperChannelReplay,
    AxsCacheKeeperChannelTimeout, AxsCacheKeeperChannelBusy
};
typedef NS_ENUM(uint32_t,AxsCacheKeeperChannelDomain) {
    AxsCacheKeeperChannelNoError, AxsCacheKeeperChannelMachError, AxsCacheKeeperChannelPOSIXError,
    AxsCacheKeeperChannelProtocolError
};
typedef struct {
    AxsCacheKeeperChannelStage stage;
    AxsCacheKeeperChannelDomain domain;
    int32_t code;
    BOOL unexpected;
    BOOL peer;
} AxsCacheKeeperChannelFailure;
typedef NS_ENUM(uint32_t,AxsCacheKeeperChannelReplyStatus) {
    AxsCacheKeeperChannelRequest, AxsCacheKeeperChannelAccepted, AxsCacheKeeperChannelDenied,
    AxsCacheKeeperChannelDuplicate, AxsCacheKeeperChannelOccupied
};
typedef struct {
    mach_msg_header_t header;
    uint32_t version, kind;
    uint8_t nonce[16];
    uint32_t status, stage, domain;
    int32_t code;
    uint32_t reserved;
} AxsCacheKeeperChannelMessage;
enum { AxsCacheKeeperChannelMessageLimit=256, AxsCacheKeeperChannelHelloID=0x434B484C,
       AxsCacheKeeperChannelReplyID=0x434B4852, AxsCacheKeeperChannelReplaySlots=64 };
typedef union {
    mach_msg_header_t header;
    uint8_t bytes[AxsCacheKeeperChannelMessageLimit+MAX_TRAILER_SIZE];
} AxsCacheKeeperChannelBuffer;
typedef struct {
    AxsCacheKeeperChannelMessage message;
    audit_token_t token;
} AxsCacheKeeperChannelDecoded;
typedef struct {
    audit_token_t token;
    uint8_t nonce[16];
    double expires;
} AxsCacheKeeperChannelReplayEntry;
typedef struct { AxsCacheKeeperChannelReplayEntry entries[AxsCacheKeeperChannelReplaySlots]; } AxsCacheKeeperChannelReplayCache;

// Internal protocol primitives, also exercised directly by the native boundary regression.
// Decode requires bytes returned by this module's successful Mach receive; payload tokens are never accepted.
double axs_cachekeeper_channel_now(void);
void axs_cachekeeper_channel_encode(AxsCacheKeeperChannelMessage *, BOOL reply, const uint8_t nonce[16],
                                    mach_port_t remote, mach_port_t local, AxsCacheKeeperChannelReplyStatus,
                                    AxsCacheKeeperChannelFailure);
// Consumes the encoded message on success and on recoverable send failure; borrowed COPY/MAKE
// rights remain owned by the caller. Does not infer ownership after an unrecoverable kernel error.
BOOL axs_cachekeeper_channel_send(AxsCacheKeeperChannelMessage *, double deadline, AxsCacheKeeperChannelFailure *);
BOOL axs_cachekeeper_channel_decode(const void *, size_t capacity, mach_port_t local, BOOL reply,
                                    AxsCacheKeeperChannelDecoded *, AxsCacheKeeperChannelFailure *);
BOOL axs_cachekeeper_channel_receive(mach_port_t, BOOL reply, double deadline, AxsCacheKeeperChannelBuffer *,
                                     AxsCacheKeeperChannelDecoded *, AxsCacheKeeperChannelFailure *);
// Interprets the actual receive result and owns any delivered rights; boundary tests inject a
// BODY_ERROR code with real received rights, without claiming to reproduce kernel VM exhaustion.
BOOL axs_cachekeeper_channel_receive_result(mach_msg_return_t, mach_port_t, BOOL reply, double deadline,
                                            AxsCacheKeeperChannelBuffer *, AxsCacheKeeperChannelDecoded *, AxsCacheKeeperChannelFailure *);
// Destroys delivered rights (including complex/OOL messages), but never the destination receive right.
void axs_cachekeeper_channel_destroy_received(AxsCacheKeeperChannelBuffer *);
// Only ports allocated by this module, without a guard. Removes the owned receive right and,
// when true, exactly one still-owned send uref; does not discard unrelated rights sharing a name.
kern_return_t axs_cachekeeper_channel_release_receive(mach_port_t, BOOL ownsSend);
BOOL axs_cachekeeper_channel_remember(AxsCacheKeeperChannelReplayCache *, const AxsCacheKeeperChannelDecoded *,
                                      double now, AxsCacheKeeperChannelFailure *);
BOOL axs_cachekeeper_channel_identity_blob(const uint8_t *, size_t, const char *expected);
BOOL axs_cachekeeper_channel_self_token(audit_token_t *, AxsCacheKeeperChannelFailure *);
BOOL axs_cachekeeper_channel_token_path(audit_token_t *, char buffer[4096], AxsCacheKeeperChannelFailure *);
BOOL axs_cachekeeper_channel_authenticate(const audit_token_t *, BOOL springBoard, double deadline,
                                          AxsCacheKeeperChannelFailure *);
