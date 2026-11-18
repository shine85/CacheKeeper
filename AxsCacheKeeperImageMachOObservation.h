#pragma once
#import "AxsCacheKeeperImageSourceObservation.h"
#include <mach-o/loader.h>
#include <mach/machine.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef BOOL (*AxsCacheKeeperImageObservationRead)(uintptr_t,void *,size_t,void *);
// The reader authenticates its own view (Mach VM or the already validated installation FD).
static inline NSDictionary *AxsCacheKeeperImageMachOObservation(uintptr_t base,AxsCacheKeeperImageObservationRead read,void *context) {
    struct mach_header_64 header;
    if (!read || !read(base,&header,sizeof(header),context)) return @{@"state":@"unreadable"};
    if (header.magic!=MH_MAGIC_64 || header.sizeofcmds>65536 || header.ncmds>header.sizeofcmds/sizeof(struct load_command) ||
        base>UINTPTR_MAX-sizeof(header)-header.sizeofcmds) return @{@"state":@"invalid"};
    size_t length=sizeof(header)+header.sizeofcmds;
    unsigned char *copy=malloc(length),*after=malloc(length);
    if (!copy || !after) {free(copy);free(after);return @{@"state":@"unreadable"};}
    NSString *failure=nil,*uuid=nil;NSUInteger found=0;size_t cursor=sizeof(header);
    if (!read(base,copy,length,context)) failure=@"unreadable";
    else if (memcmp(copy,&header,sizeof(header))) failure=@"changed";
    for (uint32_t i=0;!failure && i<header.ncmds;i++) {
        if (cursor>length || length-cursor<sizeof(struct load_command)) {failure=@"invalid";break;}
        struct load_command command;memcpy(&command,copy+cursor,sizeof(command));
        if (command.cmdsize<sizeof(command) || command.cmdsize%8 || command.cmdsize>length-cursor) {failure=@"invalid";break;}
        if (command.cmd==LC_UUID) {
            if (command.cmdsize!=sizeof(struct uuid_command) || ++found!=1) {failure=@"invalid";break;}
            struct uuid_command receipt;memcpy(&receipt,copy+cursor,sizeof(receipt));NSMutableString *text=[NSMutableString new];
            for (NSUInteger n=0;n<16;n++) [text appendFormat:@"%02x",receipt.uuid[n]];uuid=text;
        }
        cursor+=command.cmdsize;
    }
    if (!failure && cursor!=length) failure=@"invalid";
    if (!failure && !read(base,after,length,context)) failure=@"unreadable";
    if (!failure && memcmp(copy,after,length)) failure=@"changed";
    free(copy);free(after);
    if (failure) return @{@"state":failure};
    NSMutableDictionary *out=[@{@"state":uuid ? @"complete" : @"missingUUID",@"cpuType":@(header.cputype),@"cpuSubtype":@(header.cpusubtype),@"fileType":@(header.filetype)} mutableCopy];
    if (uuid) out[@"uuid"]=uuid;return [out copy];
}
