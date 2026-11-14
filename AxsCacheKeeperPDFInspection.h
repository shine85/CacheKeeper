#pragma once
#import <Foundation/Foundation.h>
#include <sys/types.h>
#include <stdint.h>

typedef struct {
    NSUInteger entryLimit;
    uint64_t sampleByteLimit;
    NSTimeInterval seconds;
    NSUInteger depthLimit;
    NSUInteger descriptorLimit;
} AxsCacheKeeperPDFInspectionLimits;

// Production ceilings: 10000 entries, 16 MiB actually read, 5 monotonic seconds,
// 32 relative components, 34 owned descriptors, 64 entries per advance, 4096 bytes per file.
AxsCacheKeeperPDFInspectionLimits axs_cachekeeper_pdf_inspection_limits(void);
// Single typed report schema shared by the wire boundary and the unified redactor.
// Drops unknown fields; returns nil for invalid known fields. Paths here are still private.
NSDictionary *axs_cachekeeper_pdf_report_fields(id report);

// HELLO/container discovery and installation validation belong to the caller. This class accepts
// an already verified directory FD, duplicates it, and never opens an absolute path or expands roots.
// Use on a background serial queue. cancel is thread-safe and marks cancellation immediately;
// descriptor release waits for any active syscall, whose latency is not a hard real-time guarantee.
@interface AxsCacheKeeperPDFInspection : NSObject
@property(nonatomic,readonly) BOOL complete;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)initWithContainerFD:(int)containerFD relativeDirectory:(NSString *)relative;
// Trusted native regression seams, never an IPC request schema. Every supplied limit is clamped
// to the production ceiling. nil clock/read use real monotonic time/pread; beforeRead runs after
// opening the file but before a second path-edge check and any content read.
- (instancetype)initWithContainerFD:(int)containerFD relativeDirectory:(NSString *)relative
                             limits:(AxsCacheKeeperPDFInspectionLimits)limits
                              clock:(NSTimeInterval (^)(void))clock
                         beforeRead:(void (^)(NSString *containerRelativePath))beforeRead
                               read:(ssize_t (^)(int descriptor,void *buffer,size_t count))read;
- (void)advance:(NSUInteger)limit;
// Nonblocking signal for a separate receive/control queue. advance closes resources at its next checkpoint.
- (void)requestCancellation;
- (void)cancel;
// Only an already retained candidate may be reopened, after the caller revalidates installation.
// Compares the original file identity without reading content; never accepts arbitrary paths.
- (BOOL)revalidateCandidate:(NSString *)path containerFD:(int)containerFD error:(int *)code;
// In-memory snapshot only; no report files. Candidate paths remain container-relative for the
// later unified redactor. A candidate identifies only a stable %PDF- prefix, not deletion authority.
- (NSDictionary *)report;
@end
