#pragma once
#import "AxsCacheKeeperImageMachOObservation.h"
#import "AxsCacheKeeperImageLegacySource.h"
#import <objc/runtime.h>
#include <mach-o/dyld.h>
#include <dlfcn.h>
#include <stdatomic.h>

typedef struct {NSUInteger ownerIndex;BOOL classMethod;const char *selector;} AxsCacheKeeperImageObservationMethod;
static atomic_ulong axs_cachekeeper_image_observation_generation;
static inline BOOL axs_cachekeeper_image_observation_vm_read(uintptr_t address,void *buffer,size_t length,void *context) {
    (void)context;return AxsCacheKeeperImageLegacyRead(address,buffer,length,VM_PROT_READ);
}
typedef struct {
    const void *bases[40];
    const struct mach_header *dyldHeaders[4096];
    __unsafe_unretained NSMutableArray *modules;
    __unsafe_unretained NSArray *names;
    NSTimeInterval deadline;
    NSUInteger dyldCount,methodCount;
    BOOL partial;
} AxsCacheKeeperImageObservationContext;
static inline BOOL axs_cachekeeper_image_observation_time(AxsCacheKeeperImageObservationContext *context) {
    if (NSProcessInfo.processInfo.systemUptime<context->deadline) return YES;
    context->partial=YES;return NO;
}
static inline NSUInteger axs_cachekeeper_image_observation_module(AxsCacheKeeperImageObservationContext *context,const void *base) {
    if (!base) return 0;
    for (NSUInteger i=0;i<context->modules.count;i++) if (context->bases[i]==base) return i+1;
    if (context->modules.count>=40 || !axs_cachekeeper_image_observation_time(context)) {context->partial=YES;return 0;}
    NSUInteger matches=0,dyldIndex=0;
    for (NSUInteger i=0;i<context->dyldCount;i++) if ((const void *)context->dyldHeaders[i]==base) {matches++;dyldIndex=i;}
    NSDictionary *metadata=AxsCacheKeeperImageMachOObservation((uintptr_t)base,axs_cachekeeper_image_observation_vm_read,NULL);
    if (![@[@"complete",@"missingUUID"] containsObject:metadata[@"state"]]) context->partial=YES;
    NSString *uuid=metadata[@"uuid"];
    NSUInteger index=context->modules.count+1;
    NSMutableDictionary *row=[@{@"index":@(index),@"metadata":metadata,@"dyldMatches":@(matches),
        @"contractUUIDRelation":uuid ? ([uuid isEqual:@"b2b9d30a1caf31b482cac776e7eb2ba1"] ? @"matches" : @"different") : @"notResolved"} mutableCopy];
    if (matches==1) row[@"dyldIndex"]=@(dyldIndex);
    context->bases[index-1]=base;[context->modules addObject:row];return index;
}
static inline NSUInteger axs_cachekeeper_image_observation_imp(AxsCacheKeeperImageObservationContext *context,const void *implementation) {
    Dl_info info={0};
    if (!implementation) return 0;
    if (!axs_cachekeeper_image_observation_time(context)) return 0;
    if (!dladdr(AxsCacheKeeperImageLegacyCodeAddress(implementation),&info) || !info.dli_fbase) {context->partial=YES;return 0;}
    return axs_cachekeeper_image_observation_module(context,info.dli_fbase);
}
// Only the requested selectors enter the table; arbitrary selector names never enter an output.
static inline NSDictionary *axs_cachekeeper_image_observation_table(Class owner,AxsCacheKeeperImageObservationContext *context,
    NSMutableDictionary *tables,const AxsCacheKeeperImageObservationMethod specs[27]) {
    NSValue *key=[NSValue valueWithPointer:(__bridge const void *)owner];id cached=tables[key];
    if (cached) return cached==NSNull.null ? nil : cached;
    if (!axs_cachekeeper_image_observation_time(context)) return nil;
    unsigned count=0;Method *list=class_copyMethodList(owner,&count);
    if (count>4096 || count>32768-context->methodCount || (count && !list)) {
        free(list);context->partial=YES;tables[key]=NSNull.null;return nil;
    }
    context->methodCount+=count;NSMutableDictionary *table=[NSMutableDictionary new];
    for (unsigned i=0;i<count;i++) {
        if (!axs_cachekeeper_image_observation_time(context)) {free(list);tables[key]=NSNull.null;return nil;}
        SEL selector=method_getName(list[i]);
        for (NSUInteger n=0;n<27;n++) if (selector==sel_registerName(specs[n].selector))
            table[[NSValue valueWithPointer:selector]]=[NSValue valueWithPointer:list[i]];
    }
    free(list);tables[key]=[table copy];return tables[key];
}
static inline NSDictionary *AxsCacheKeeperImageRuntimeObservation(Class __unsafe_unretained classes[5],
    const AxsCacheKeeperImageObservationMethod specs[27],const void *originals[4],const void *wrappers[4],BOOL usesSavedOriginal) {
    unsigned long generation=atomic_load(&axs_cachekeeper_image_observation_generation);
    NSMutableArray *modules=[NSMutableArray new],*names=[NSMutableArray new];
    AxsCacheKeeperImageObservationContext context={.modules=modules,.deadline=NSProcessInfo.processInfo.systemUptime+.05};
    uint32_t count=_dyld_image_count();context.dyldCount=MIN(count,(uint32_t)4096);context.partial=count>4096;
    for (NSUInteger i=0;i<context.dyldCount;i++) {
        if (!axs_cachekeeper_image_observation_time(&context)) {context.dyldCount=i;break;}
        context.dyldHeaders[i]=_dyld_get_image_header((uint32_t)i);const char *name=_dyld_get_image_name((uint32_t)i);
        NSString *text=name && strnlen(name,4096)<4096 ? [NSString stringWithUTF8String:name] : nil;
        if (!text || !context.dyldHeaders[i]) context.partial=YES;[names addObject:text ?: NSNull.null];
    }
    context.names=names;BOOL nameViewComplete=context.dyldCount==count;
    for (id name in names) if (name==NSNull.null) nameViewComplete=NO;
    NSUInteger main=axs_cachekeeper_image_observation_module(&context,context.dyldCount ? context.dyldHeaders[0] : NULL);
    NSMutableArray *classRows=[NSMutableArray new],*methodRows=[NSMutableArray new],*originalRows=[NSMutableArray new];
    for (NSUInteger i=0;i<5;i++) {
        Class owner=classes[i];
        if (!axs_cachekeeper_image_observation_time(&context)) {
            [classRows addObject:@{@"index":@(i+1),@"present":@(owner!=Nil),@"nameState":owner ? @"partial" : @"unavailable",@"module":@0}];continue;
        }
        const char *raw=owner ? class_getImageName(owner) : NULL;
        NSString *name=raw && strnlen(raw,4096)<4096 ? [NSString stringWithUTF8String:raw] : nil;
        NSUInteger matches=0,index=0;BOOL nameComplete=nameViewComplete;
        if (name) for (NSUInteger n=0;n<context.dyldCount;n++) {
            if (!axs_cachekeeper_image_observation_time(&context)) {nameComplete=NO;break;}
            if ([names[n] isEqual:name]) {matches++;index=n;}
        }
        NSUInteger module=nameComplete && matches==1 ? axs_cachekeeper_image_observation_module(&context,context.dyldHeaders[index]) : 0;
        NSString *state=!name ? @"unavailable" : !nameComplete ? @"partial" : matches>1 ? @"ambiguous" : matches==1 && module ? @"matched" : context.partial ? @"partial" : @"notRegistered";
        if (owner && ![state isEqual:@"matched"]) context.partial=YES;
        [classRows addObject:@{@"index":@(i+1),@"present":@(owner!=Nil),@"nameState":state,@"module":@(module)}];
    }
    NSMutableDictionary *tables=[NSMutableDictionary new];const void *current[27]={NULL};Method selected[27]={NULL};
    static const NSUInteger originalSlots[4]={0,20,23,24};
    for (NSUInteger i=0;i<27;i++) {
        const AxsCacheKeeperImageObservationMethod *spec=&specs[i];Class owner=spec->ownerIndex<5 ? classes[spec->ownerIndex] : Nil;
        if (owner && spec->classMethod) owner=object_getClass(owner);
        NSString *state=@"missing";Class visited[16]={Nil};NSUInteger depth=0;
        while (owner) {
            if (depth>=16) {state=@"partial";context.partial=YES;break;}
            BOOL repeated=NO;for (NSUInteger n=0;n<depth;n++) if (visited[n]==owner) repeated=YES;
            if (repeated) {state=@"partial";context.partial=YES;break;}visited[depth]=owner;
            NSDictionary *table=axs_cachekeeper_image_observation_table(owner,&context,tables,specs);
            if (!table) {state=@"partial";break;}
            NSValue *method=table[[NSValue valueWithPointer:sel_registerName(spec->selector)]];
            if (method) {
                selected[i]=method.pointerValue;current[i]=(const void *)method_getImplementation(selected[i]);
                state=current[i] ? (depth ? @"inherited" : @"own") : @"partial";if (!current[i]) context.partial=YES;break;
            }
            owner=class_getSuperclass(owner);depth++;
        }
        NSString *wrapper=@"notCompared";
        for (NSUInteger n=0;n<4;n++) if (originalSlots[n]==i && current[i] && wrappers[n])
            wrapper=AxsCacheKeeperImageLegacyCodeAddress(current[i])==AxsCacheKeeperImageLegacyCodeAddress(wrappers[n]) ? @"matches" : @"different";
        [methodRows addObject:@{@"index":@(i+1),@"state":state,@"module":@(axs_cachekeeper_image_observation_imp(&context,current[i])),@"wrapper":wrapper}];
    }
    for (NSUInteger i=0;i<4;i++) {
        const void *actual=current[originalSlots[i]];
        NSString *relation=originals[i] && actual ? (AxsCacheKeeperImageLegacyCodeAddress(originals[i])==AxsCacheKeeperImageLegacyCodeAddress(actual) ? @"same" : @"different") : @"notCompared";
        [originalRows addObject:@{@"index":@(i+1),@"present":@(originals[i]!=NULL),@"module":@(axs_cachekeeper_image_observation_imp(&context,originals[i])),@"currentRelation":relation}];
    }
    NSNumber *candidateValue=usesSavedOriginal ? originalRows[0][@"module"] : methodRows[0][@"module"];
    NSUInteger candidate=[candidateValue unsignedIntegerValue];
    BOOL changed=generation!=atomic_load(&axs_cachekeeper_image_observation_generation) || count!=_dyld_image_count();
    for (NSUInteger i=0;!changed && i<context.dyldCount;i++) {
        if (!axs_cachekeeper_image_observation_time(&context)) break;
        if (_dyld_get_image_header((uint32_t)i)!=context.dyldHeaders[i]) changed=YES;
    }
    for (NSUInteger i=0;!changed && i<27;i++) if (selected[i] && current[i]!=(const void *)method_getImplementation(selected[i])) changed=YES;
    if (changed || !axs_cachekeeper_image_observation_time(&context)) context.partial=YES;
    NSDictionary *value=@{@"schemaVersion":@1,@"state":context.partial ? @"partial" : @"complete",@"dyldState":changed ? @"changed" : context.partial ? @"partial" : @"complete",
        @"observedDyldImages":@(context.dyldCount),@"observedMethods":@(context.methodCount),@"modules":modules,@"classes":classRows,@"methods":methodRows,@"originals":originalRows,
        @"mainModule":@(main),@"candidateModule":@(candidate),@"initializerUsesSavedOriginal":@(usesSavedOriginal),@"mappingBackingIdentity":@"notVerified"};
    return axs_cachekeeper_image_runtime_observation_projection(value);
}
