#pragma once
#import <Foundation/Foundation.h>

// In-memory, single-directory diagnostic session. No persistent request or report files.
// All callbacks run on the main queue. probe never enumerates; start requires a verified probe.
@interface AxsCacheKeeperPDFSession : NSObject
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)initWithBundle:(NSString *)bundle relativeDirectory:(NSString *)relative;
- (void)probe:(void (^)(NSDictionary *snapshot))update;
- (void)start;
- (void)cancel;
- (void)resolveCandidate:(NSUInteger)index completion:(void (^)(NSString *directory, NSDictionary *status))completion;
@end

// The server owns the supplied FD. The validator rechecks the current system installation and
// root identity on its private work queue; it must never use caller-supplied absolute paths.
@interface AxsCacheKeeperPDFRoot : NSObject
@property(nonatomic,readonly) int descriptor;
@property(nonatomic,copy,readonly) NSString *path;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)initWithDescriptor:(int)descriptor path:(NSString *)path validator:(BOOL (^)(void))validator;
- (BOOL)validate;
@end
typedef AxsCacheKeeperPDFRoot *(^AxsCacheKeeperPDFRootProvider)(NSString *bundle, NSString **stage, int *code);

#ifdef __cplusplus
extern "C" {
#endif
// Called by SpringBoard initialization; no main-thread authentication or filesystem work.
void axs_cachekeeper_pdf_session_server_start(AxsCacheKeeperPDFRootProvider provider);
AxsCacheKeeperPDFRoot *axs_cachekeeper_pdf_resolve_root(NSString *bundle, NSString **stage, int *code);
#ifdef __cplusplus
}
#endif
