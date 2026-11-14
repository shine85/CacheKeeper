#pragma once
#import <Foundation/Foundation.h>
#include <math.h>

// Shared, content-free snapshot contract. No UIKit objects or arbitrary strings cross this boundary.
enum { AxsCacheKeeperSearchEventLimit=16, AxsCacheKeeperSearchAncestorLimit=6 };
typedef NS_ENUM(NSUInteger,AxsCacheKeeperSearchEvent) {
    AxsCacheKeeperSearchEventLoaded, AxsCacheKeeperSearchEventWillAppear, AxsCacheKeeperSearchEventDidAppear,
    AxsCacheKeeperSearchEventWillDisappear, AxsCacheKeeperSearchEventDiagnostics, AxsCacheKeeperSearchEventRootHit,
    AxsCacheKeeperSearchEventShouldBegin, AxsCacheKeeperSearchEventDidBegin, AxsCacheKeeperSearchEventDidEnd,
    AxsCacheKeeperSearchEventFocus, AxsCacheKeeperSearchEventFocusNoWindow, AxsCacheKeeperSearchEventFocusDisabled,
    AxsCacheKeeperSearchEventFocusHidden, AxsCacheKeeperSearchEventFocusAccepted, AxsCacheKeeperSearchEventFocusRejected,
    AxsCacheKeeperSearchEventDismiss
};
static inline NSArray<NSString *> *axs_cachekeeper_search_event_names(void) {
    return @[@"loaded",@"willAppear",@"didAppear",@"willDisappear",@"diagnostics",@"rootHit",@"shouldBegin",
        @"didBegin",@"didEnd",@"focus",@"focusNoWindow",@"focusDisabled",@"focusHidden",@"focusAccepted",@"focusRejected",@"dismiss"];
}
static inline BOOL axs_cachekeeper_search_bool(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID();
}
static inline BOOL axs_cachekeeper_search_number(id value,double minimum,double maximum,BOOL integer) {
    if (![value isKindOfClass:NSNumber.class] || axs_cachekeeper_search_bool(value)) return NO;
    double number=[value doubleValue];
    return isfinite(number) && number>=minimum && number<=maximum && (!integer || trunc(number)==number);
}
static inline NSDictionary *axs_cachekeeper_search_rect_projection(id value) {
    if (![value isKindOfClass:NSDictionary.class] || !axs_cachekeeper_search_bool(value[@"valid"])) return nil;
    NSMutableDictionary *out=[NSMutableDictionary new];out[@"valid"]=@([value[@"valid"] boolValue]);
    for (NSString *key in @[@"x",@"y",@"width",@"height"]) {
        BOOL position=[key isEqual:@"x"] || [key isEqual:@"y"];
        if (!axs_cachekeeper_search_number(value[key],position ? -1000000 : 0,1000000,NO)) return nil;
        out[key]=@([value[key] doubleValue]);
    }
    return [out copy];
}
static inline NSDictionary *axs_cachekeeper_search_view_projection(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    NSMutableDictionary *out=[NSMutableDictionary new];
    for (NSString *key in @[@"bounds",@"windowRect"]) {
        NSDictionary *rect=axs_cachekeeper_search_rect_projection(value[key]);if (!rect) return nil;out[key]=rect;
    }
    for (NSString *key in @[@"hidden",@"interaction",@"clips",@"centerInsideBounds"]) {
        if (!axs_cachekeeper_search_bool(value[key])) return nil;out[key]=@([value[key] boolValue]);
    }
    if (!axs_cachekeeper_search_number(value[@"alpha"],0,1,NO)) return nil;
    out[@"alpha"]=@([value[@"alpha"] doubleValue]);return [out copy];
}
static inline NSDictionary *axs_cachekeeper_search_diagnostics_projection(id value) {
    if (!value) return @{@"state":@"notObserved"};
    NSDictionary *invalid=@{@"state":@"invalid"};
    if (![value isKindOfClass:NSDictionary.class] ||
        !axs_cachekeeper_search_number(value[@"schemaVersion"],1,1,YES) ||
        !axs_cachekeeper_search_number(value[@"probeRevision"],1,1,YES) ||
        ![value[@"state"] isKindOfClass:NSString.class] || ![@[@"recording",@"frozen"] containsObject:value[@"state"]] ||
        !axs_cachekeeper_search_bool(value[@"truncated"]) ||
        ![value[@"events"] isKindOfClass:NSArray.class] || [value[@"events"] count]>AxsCacheKeeperSearchEventLimit) return invalid;
    NSArray *roles=@[@"field",@"search",@"table",@"other",@"none"];
    NSMutableArray *events=[NSMutableArray new];
    for (id event in value[@"events"]) {
        if (![event isKindOfClass:NSDictionary.class]) return invalid;
        NSMutableDictionary *out=[NSMutableDictionary new];
        NSDictionary *enums=@{@"event":axs_cachekeeper_search_event_names(),@"centerHit":roles,
            @"observedHit":@[@"field",@"search",@"table",@"other",@"none",@"notObserved"],
            @"scene":@[@"unattached",@"foregroundActive",@"foregroundInactive",@"background",@"unknown"]};
        for (NSString *key in enums) {
            if (![event[key] isKindOfClass:NSString.class] || ![enums[key] containsObject:event[key]]) return invalid;
            out[key]=[event[key] copy];
        }
        if (!axs_cachekeeper_search_number(event[@"elapsedMs"],0,3600000,YES) ||
            !axs_cachekeeper_search_number(event[@"windowAlpha"],0,1,NO)) return invalid;
        out[@"elapsedMs"]=@([event[@"elapsedMs"] unsignedIntegerValue]);out[@"windowAlpha"]=@([event[@"windowAlpha"] doubleValue]);
        for (NSString *key in @[@"firstResponder",@"fieldEnabled",@"fieldCanBecomeFirstResponder",@"presented",@"windowAttached",@"windowKey",@"windowHidden",@"windowInteraction",@"ancestorsTruncated"]) {
            if (!axs_cachekeeper_search_bool(event[key])) return invalid;out[key]=@([event[key] boolValue]);
        }
        for (NSString *key in @[@"field",@"input",@"root",@"table"]) {
            NSDictionary *node=axs_cachekeeper_search_view_projection(event[key]);if (!node) return invalid;out[key]=node;
        }
        if (![event[@"ancestors"] isKindOfClass:NSArray.class] || [event[@"ancestors"] count]>AxsCacheKeeperSearchAncestorLimit) return invalid;
        NSMutableArray *ancestors=[NSMutableArray new];
        for (id ancestor in event[@"ancestors"]) {
            if (![ancestor isKindOfClass:NSDictionary.class] || ![ancestor[@"role"] isKindOfClass:NSString.class] ||
                ![@[@"search",@"root",@"table",@"window",@"other"] containsObject:ancestor[@"role"]]) return invalid;
            NSDictionary *node=axs_cachekeeper_search_view_projection(ancestor[@"view"]);if (!node) return invalid;
            [ancestors addObject:@{@"role":[ancestor[@"role"] copy],@"view":node}];
        }
        out[@"ancestors"]=[ancestors copy];[events addObject:[out copy]];
    }
    return @{@"schemaVersion":@1,@"probeRevision":@1,@"state":[value[@"state"] copy],
        @"truncated":@([value[@"truncated"] boolValue]),@"events":[events copy]};
}
