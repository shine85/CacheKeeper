#pragma once
#import <Foundation/Foundation.h>

// Shared configuration grammar; filenames may contain colons or newlines on iOS.
static inline BOOL axs_cachekeeper_relative_path(NSString *path) {
    if (![path isKindOfClass:NSString.class] || !path.length || [path hasPrefix:@"/"]) return NO;
    for (NSString *part in [path componentsSeparatedByString:@"/"]) {
        if (!part.length || [part isEqual:@"."] || [part isEqual:@".."] || [part containsString:@"\\"]) return NO;
    }
    return YES;
}
