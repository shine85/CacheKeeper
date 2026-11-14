#pragma once
#import <Foundation/Foundation.h>

// HELLO-only transport. No paths, app content, tokens, signing IDs, nonces or hashes in results.
// Both functions return/callback the same immutable whitelist (protocolVersion is always 1):
// state: listening | verified | unavailable | rejected | busy
// stage: none | host | selfToken | api | systemURL | status | signingIdentity | executable |
//        finalStatus | register | lookup | send | receive | protocol | replay | timeout | busy
// errorDomain: none | mach | posix | protocol; errorCode: signed integer
// errorOrigin: none | local | peer (peer only after authenticating the reply's audit token)
// selfIdentity, peerIdentity: notObserved | verified | unexpected | unavailable
// serverRegister: notObserved | verified | failed
// "listening" only describes local registration, not peer or container access verification.
// A client without an authenticated reply leaves serverRegister notObserved.
// Only a reply authenticated with its kernel audit trailer can expose the server's fixed state.

// Call only from the existing SpringBoard host. Schedules background initialization immediately;
// callback (if provided) runs on that private queue, once per invocation. No main-thread I/O.
void axs_cachekeeper_diagnostic_channel_start(void (^completion)(NSDictionary *status));

// Call only on a Preferences background queue. One in-flight call, no retries, shared 2s soft
// deadline including identity and bootstrap operations; individual kernel calls may overrun it.
// A verified HELLO proves only the message channel; it grants no APP/container read capability.
NSDictionary *axs_cachekeeper_diagnostic_channel_hello(void);
