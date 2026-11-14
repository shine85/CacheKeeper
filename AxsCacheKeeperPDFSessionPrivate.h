#pragma once
#import "AxsCacheKeeperPDFSession.h"
#import "AxsCacheKeeperDiagnosticChannelPrivate.h"
#import "AxsCacheKeeperPDFInspection.h"

enum { AxsCacheKeeperPDFWireLimit=65536, AxsCacheKeeperPDFRequestLimit=8192,
       AxsCacheKeeperPDFRequestID=0x434B5031, AxsCacheKeeperPDFReplyID=0x434B5032 };
typedef struct {
    mach_msg_header_t header;
    uint32_t version, length;
    uint8_t payload[AxsCacheKeeperPDFWireLimit];
} AxsCacheKeeperPDFMessage;
typedef union {
    mach_msg_header_t header;
    uint8_t bytes[sizeof(AxsCacheKeeperPDFMessage)+MAX_TRAILER_SIZE];
} AxsCacheKeeperPDFBuffer;

BOOL axs_cachekeeper_pdf_request_valid(id request);
BOOL axs_cachekeeper_pdf_reply_matches(NSDictionary *reply, NSDictionary *request, NSString *service);
BOOL axs_cachekeeper_pdf_decode(const void *bytes,size_t capacity,mach_port_t port,BOOL reply,
                                NSDictionary **payload,audit_token_t *token);
BOOL axs_cachekeeper_pdf_encode(AxsCacheKeeperPDFMessage *,NSDictionary *,BOOL reply,mach_port_t remote,mach_port_t local);
void axs_cachekeeper_pdf_destroy(AxsCacheKeeperPDFBuffer *);

// Pure identity/session gate used by the real server after successful kernel authentication.
// Tests may exercise this gate but cannot replace production authenticate() or server registration.
@interface AxsCacheKeeperPDFBinding : NSObject
@property(nonatomic,copy,readonly) NSString *service;
- (instancetype)initWithService:(NSString *)service client:(audit_token_t)client server:(audit_token_t)server request:(NSDictionary *)request now:(double)now;
- (BOOL)accept:(NSDictionary *)request client:(audit_token_t)client server:(audit_token_t)server now:(double)now;
- (BOOL)expired:(double)now;
- (void)invalidate;
@end
