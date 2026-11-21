#pragma once
#import <Foundation/Foundation.h>
#ifdef __cplusplus
extern "C" {
#endif
// Internal association only. firstObserved is not the OS process start time.
NSDictionary *axs_cachekeeper_operation_process(void);
NSDictionary *axs_cachekeeper_operation_history_validate(id value, NSString *component);
NSDictionary *axs_cachekeeper_operation_history_projection(id value, NSMutableDictionary *aliases);
NSString *axs_cachekeeper_operation_history_summary(id value);
// Mutable state is private to one component; helpers synchronize it across SDK callbacks.
NSMutableDictionary *axs_cachekeeper_operation_history_create(NSString *component, id previous);
void axs_cachekeeper_operation_restore(NSMutableDictionary *history, id previous);
// Bounded local read on the caller's background queue. Missing old receipt returns nil;
// unreadable/malformed/oversized content returns an invalid sentinel for explicit rejection.
id axs_cachekeeper_operation_load(NSString *path, NSString *component);
NSDictionary *axs_cachekeeper_operation_snapshot(NSMutableDictionary *history);
NSUInteger axs_cachekeeper_operation_begin(NSMutableDictionary *history, NSString *trigger, NSUInteger configuration, NSUInteger installation, BOOL refreshing);
NSUInteger axs_cachekeeper_operation_begin_with_policy(NSMutableDictionary *history, NSString *trigger, NSUInteger configuration, NSUInteger installation, BOOL refreshing, BOOL supersedeActive);
void axs_cachekeeper_operation_refresh(NSMutableDictionary *history, NSUInteger event, NSString *state);
void axs_cachekeeper_operation_request(NSMutableDictionary *history, NSUInteger event);
void axs_cachekeeper_operation_timeout(NSMutableDictionary *history, NSUInteger action);
NSUInteger axs_cachekeeper_operation_action(NSMutableDictionary *history, NSUInteger event, NSUInteger owner);
void axs_cachekeeper_operation_transition(NSMutableDictionary *history, NSUInteger action, NSString *state, BOOL timedOut);
void axs_cachekeeper_operation_transition_reason(NSMutableDictionary *history, NSUInteger action, NSString *state, NSString *reason, BOOL timedOut);
// Finishes one submitted image action with same-action directory observations.
void axs_cachekeeper_operation_image_effect(NSMutableDictionary *history, NSUInteger action, NSDictionary *effect);
void axs_cachekeeper_operation_event_reason(NSMutableDictionary *history, NSUInteger event, NSString *reason);
void axs_cachekeeper_operation_finish(NSMutableDictionary *history, NSUInteger event);
// Caller owns a serial component save path. Failure retains the newest cumulative record.
BOOL axs_cachekeeper_operation_save(NSDictionary *record, NSString *path, BOOL access, NSMutableDictionary *__strong *pending, BOOL *writable);
#ifdef __cplusplus
}
#endif
