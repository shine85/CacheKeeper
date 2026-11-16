#pragma once
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach/vm_region.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <objc/runtime.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif

// Only com.baidu.netdisk 13.37.5 (13.37.5.10), main UUID below, has this contract.
// These are captured instruction windows, not asserted whole-function boundaries.
// Provenance: baidu-legacy-method-fingerprints-v1.json; 24 windows, 4,436 bytes.
typedef struct {
    uint32_t methodIndex;
    uint64_t offset;
    uint32_t length;
    unsigned char sha256[CC_SHA256_DIGEST_LENGTH];
} AxsCacheKeeperImageLegacyWindow;
static const AxsCacheKeeperImageLegacyWindow AxsCacheKeeperImageLegacyWindows[24]={
    {1,0xb8c5544,660,{0xd8,0x33,0x32,0xcc,0x15,0xec,0x9b,0xf4,0xa6,0xfd,0xeb,0x5b,0xca,0xf9,0xd9,0x6a,0x76,0x4c,0xa4,0x4d,0xfe,0x6a,0x6b,0xf8,0xed,0x59,0x15,0x74,0xdb,0x63,0xb0,0xdc}},
    {2,0xb8c8624,8,{0xbd,0x23,0x7e,0x5d,0x99,0xf6,0x46,0x27,0x70,0x94,0x6d,0xd6,0x4c,0x9d,0x52,0x73,0x57,0x7f,0x92,0xae,0xb7,0x81,0x54,0xba,0x48,0x5f,0xef,0x49,0xe0,0xd7,0x38,0x51}},
    {3,0xb8c8638,12,{0x41,0x60,0x9c,0xe6,0xef,0xd7,0xaf,0x4c,0x37,0x25,0x4d,0xc6,0xf5,0x2a,0x8e,0x3c,0x16,0x7e,0xd5,0xac,0xd7,0x03,0x05,0x77,0xfc,0xca,0xa0,0xd1,0xb9,0x17,0x3e,0xce}},
    {4,0xb8c85fc,12,{0xa3,0xb7,0xd1,0xd7,0x77,0x40,0x4e,0x1c,0x47,0x90,0x5e,0x91,0xe9,0xcc,0x27,0x65,0xf3,0x99,0x56,0xb6,0x8a,0x6c,0xc6,0x3e,0xd5,0xea,0x08,0xc1,0xed,0x0b,0xcf,0xbe}},
    {5,0xb8c8660,8,{0x6b,0x81,0x93,0x24,0xb4,0xa3,0xbc,0x2d,0x39,0x0c,0x83,0xc7,0xfe,0x02,0xea,0x41,0xa1,0xf5,0x7a,0xe5,0xd4,0xf2,0xa9,0xb0,0xc9,0x25,0x63,0x41,0xa5,0xb8,0xd3,0x7f}},
    {6,0xb8c8610,8,{0xdf,0xb5,0x56,0xa4,0x13,0xc8,0xbd,0xa5,0x33,0x29,0x42,0xd0,0x20,0x2e,0x8d,0x5f,0x1e,0x52,0xf4,0x51,0x58,0xae,0xc3,0x67,0x62,0x94,0xcf,0x11,0xad,0x59,0x09,0xcb}},
    {7,0xb8c27d4,12,{0x53,0xb8,0xca,0x4a,0x5e,0x73,0xda,0xc3,0x11,0xee,0x16,0x7a,0x7c,0x2c,0xe8,0x85,0xb1,0xb2,0xf4,0x66,0xc6,0xb9,0xb4,0x90,0xb7,0x1a,0xe4,0xed,0xf1,0x96,0xea,0x5e}},
    {8,0xb8c27cc,8,{0x19,0x64,0x7f,0x57,0xf4,0x8e,0x23,0xc8,0x73,0x0e,0xcf,0xc8,0x5b,0xdc,0xe8,0x0b,0xf6,0x7c,0xe4,0xea,0xe5,0x6e,0x82,0xf9,0x76,0x61,0x43,0x2f,0xa2,0x01,0x80,0x25}},
    {9,0xb8c27e8,8,{0xbd,0x23,0x7e,0x5d,0x99,0xf6,0x46,0x27,0x70,0x94,0x6d,0xd6,0x4c,0x9d,0x52,0x73,0x57,0x7f,0x92,0xae,0xb7,0x81,0x54,0xba,0x48,0x5f,0xef,0x49,0xe0,0xd7,0x38,0x51}},
    {10,0xb8c9020,8,{0x62,0xc6,0x4b,0xd5,0x85,0xdb,0x7a,0x91,0x91,0x78,0x43,0x36,0x2b,0xb7,0x5a,0xa8,0xdd,0x20,0xb0,0x02,0xbc,0xe4,0x87,0x48,0x91,0xb0,0xb3,0xec,0x8f,0xd2,0x42,0xb9}},
    {12,0xb8c9044,8,{0xd5,0x98,0x43,0x6b,0xff,0x3a,0x9d,0xd6,0xf3,0x86,0xd5,0x2e,0x9d,0x19,0x6b,0x4b,0x62,0x2d,0x92,0x0d,0x9d,0xf2,0xd4,0xb3,0x74,0x77,0x3c,0xdd,0xd2,0xc4,0xc4,0xb8}},
    {13,0xb8c9034,8,{0x98,0x9b,0xb1,0xa0,0x41,0xc9,0x3e,0x09,0xfa,0x29,0x54,0x01,0x4e,0xab,0xa1,0xa4,0x6b,0x19,0x12,0x86,0x64,0xc6,0xbb,0xb2,0x10,0x69,0x4e,0x09,0x89,0xf0,0x95,0x32}},
    {14,0xb8c8d10,608,{0xc9,0xdb,0x28,0xf3,0x3c,0xa9,0xfd,0xbc,0x6f,0xfa,0x4f,0x7c,0xf7,0xaa,0xae,0x9a,0xef,0xf7,0x1c,0x1d,0xb2,0x2e,0x59,0x17,0x00,0x52,0x2e,0xb3,0x94,0xd8,0xd8,0xbd}},
    {15,0xb8c8bfc,116,{0xe7,0x69,0xb7,0x1d,0xcb,0x7b,0x51,0xc2,0x37,0x3e,0x10,0x27,0x0f,0xea,0x6f,0x7e,0x0a,0xe7,0x14,0x2f,0xc8,0xf9,0x45,0xf1,0x80,0x4a,0x45,0x48,0x10,0xa7,0xd9,0xee}},
    {16,0xb8d54b8,16,{0x46,0x0c,0x87,0x50,0x4d,0x2c,0xe5,0x4c,0x46,0xf2,0xdd,0x93,0xf7,0xe9,0x76,0x48,0x3e,0x18,0xa2,0x7a,0x77,0xf7,0xd7,0xdd,0x66,0x68,0xc9,0x3b,0x7a,0x0a,0x6c,0xce}},
    {17,0xb8d4b3c,144,{0xb5,0xcf,0xb3,0x37,0xce,0xeb,0x66,0x21,0x3d,0xfe,0x4e,0x06,0x84,0x8b,0x26,0x19,0xc6,0x0f,0x25,0xec,0x7c,0xf8,0x88,0x84,0xfc,0x63,0x51,0x2f,0x5c,0xfc,0x91,0x80}},
    {18,0xb8d4bcc,460,{0xf4,0xd8,0x56,0xf3,0x9d,0xe9,0x12,0xc9,0xda,0xf1,0xd3,0xba,0x9f,0x04,0x73,0xb0,0xec,0xcd,0x60,0x28,0x09,0x12,0xdf,0xe5,0x5e,0xe7,0x0e,0xed,0xb9,0xa3,0xab,0xca}},
    {19,0xb8c0c14,180,{0x43,0x69,0x28,0xc5,0x14,0x5b,0x51,0x5c,0xba,0x35,0xa9,0x65,0xa5,0x49,0xcb,0x7a,0xcf,0x19,0xe5,0x53,0xd1,0xa1,0x74,0x59,0x6f,0x65,0x6c,0x8d,0x9e,0x3d,0x00,0x61}},
    {20,0xb8c0cc8,240,{0x9e,0xaa,0x49,0xeb,0xee,0xcc,0xc6,0x95,0x0e,0x68,0x23,0x7f,0xe4,0xe5,0x37,0xf2,0x82,0xab,0x35,0xdf,0xc7,0x3e,0x0f,0x03,0xd5,0x28,0x6a,0x65,0xb3,0x09,0x33,0x0b}},
    {21,0xb8c13d0,236,{0x42,0xd5,0xe7,0xba,0xdd,0xc5,0x30,0x26,0x67,0xb9,0xfb,0xb0,0x0c,0x3a,0x21,0xdf,0xb5,0x23,0x72,0xdf,0xb8,0x6e,0x97,0x1c,0x3d,0x46,0x3e,0x3c,0xcf,0xb1,0x8d,0x60}},
    {22,0xb8c1dbc,136,{0xdf,0xfd,0x3a,0xc6,0x45,0x5b,0x16,0x89,0x13,0xd7,0x9f,0x7f,0xd2,0x9e,0x50,0x97,0x0d,0xfd,0x46,0xb4,0xdd,0xc3,0x9b,0x19,0x63,0xdf,0x6a,0x75,0xbc,0x00,0xdd,0x81}},
    {23,0xb8c214c,764,{0x5c,0xc8,0x8b,0xa2,0xb0,0x4b,0x32,0x48,0x0c,0x07,0xda,0x0e,0x87,0xd3,0x33,0x84,0xa1,0x2c,0xed,0xbe,0x1e,0x1d,0xb5,0x55,0xdd,0xba,0x39,0xd3,0x69,0x70,0x1b,0xa6}},
    {24,0xb8c0fe8,592,{0x08,0xb3,0x10,0x21,0x43,0x3a,0x9b,0xce,0x9c,0xd9,0x15,0x54,0x88,0x0d,0x00,0xd6,0x20,0x83,0x75,0x15,0x6a,0x6d,0x2b,0xff,0x5b,0x7e,0x3c,0x9e,0x2c,0x77,0x70,0x82}},
    {25,0xb8c12a8,184,{0xdb,0xd1,0x6c,0x65,0x2e,0x4d,0x63,0x35,0x6b,0xf3,0x81,0xf8,0x27,0x83,0x48,0x3b,0xcf,0xb8,0x36,0x8d,0xab,0xb9,0x9c,0xf2,0x5a,0xed,0x6b,0xa0,0x74,0xa4,0xc8,0xb4}},
};
typedef struct {
    uintptr_t base;
    uint64_t sectionOffset;
    uint64_t sectionSize;
} AxsCacheKeeperImageLegacyLayout;

static inline BOOL AxsCacheKeeperImageLegacyContains(uint64_t start,uint64_t size,uint64_t address,uint64_t length) {
    return address>=start && address-start<=size && length<=size-(address-start);
}
static inline BOOL AxsCacheKeeperImageLegacyRead(uintptr_t address,void *destination,size_t length,vm_prot_t required) {
    if (!address || !destination || !length || length>UINTPTR_MAX-address) return NO;
    vm_address_t cursor=address,end=address+length;
    while (cursor<end) {
        vm_address_t region=cursor;vm_size_t size=0;
        vm_region_basic_info_data_64_t info={0};mach_msg_type_number_t count=VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object=MACH_PORT_NULL;
        kern_return_t result=vm_region_64(mach_task_self(),&region,&size,VM_REGION_BASIC_INFO_64,(vm_region_info_t)&info,&count,&object);
        if (object!=MACH_PORT_NULL) mach_port_deallocate(mach_task_self(),object);
        if (result!=KERN_SUCCESS || count!=VM_REGION_BASIC_INFO_COUNT_64 || !size || region>cursor ||
            size>UINT64_MAX-region || cursor>=region+size || (info.protection&required)!=required ||
            ((required&VM_PROT_EXECUTE) && (info.protection&VM_PROT_WRITE))) return NO;
        cursor=MIN(end,region+size);
    }
    vm_size_t copied=0;
    return vm_read_overwrite(mach_task_self(),address,length,(vm_address_t)destination,&copied)==KERN_SUCCESS && copied==length;
}
static inline BOOL AxsCacheKeeperImageLegacyName(const char name[16],const char *expected) {
    size_t length=strlen(expected);
    return length<16 && !memcmp(name,expected,length) && name[length]=='\0';
}
static inline BOOL AxsCacheKeeperImageLegacyReadLayout(const void *base,intptr_t slide,AxsCacheKeeperImageLegacyLayout *layout) {
    if (!base || !layout) return NO;
    struct mach_header_64 header;
    if (!AxsCacheKeeperImageLegacyRead((uintptr_t)base,&header,sizeof(header),VM_PROT_READ) ||
        header.magic!=MH_MAGIC_64 || header.cputype!=CPU_TYPE_ARM64 || header.cpusubtype!=CPU_SUBTYPE_ARM64_ALL ||
        header.filetype!=MH_EXECUTE || header.reserved || !header.ncmds || header.sizeofcmds>65536 ||
        header.ncmds>header.sizeofcmds/sizeof(struct load_command)) return NO;
    size_t length=sizeof(header)+header.sizeofcmds;
    uint8_t *copy=malloc(length);if (!copy) return NO;
    BOOL valid=AxsCacheKeeperImageLegacyRead((uintptr_t)base,copy,length,VM_PROT_READ) && !memcmp(copy,&header,sizeof(header));
    struct segment_command_64 text={0};struct section_64 section={0};
    struct {uint64_t address,size;} segments[64];NSUInteger segmentCount=0,textCount=0,sectionCount=0,uuidCount=0;
    static const unsigned char uuid[16]={0xb2,0xb9,0xd3,0x0a,0x1c,0xaf,0x31,0xb4,0x82,0xca,0xc7,0x76,0xe7,0xeb,0x2b,0xa1};
    size_t cursor=sizeof(header);
    for (uint32_t index=0;valid && index<header.ncmds;index++) {
        if (length-cursor<sizeof(struct load_command)) {valid=NO;break;}
        const struct load_command *command=(const void *)(copy+cursor);
        if (command->cmdsize<sizeof(*command) || command->cmdsize%8 || command->cmdsize>length-cursor) {valid=NO;break;}
        if (command->cmd==LC_UUID) {
            if (++uuidCount!=1 || command->cmdsize!=sizeof(struct uuid_command) ||
                memcmp(((const struct uuid_command *)command)->uuid,uuid,sizeof(uuid))) {valid=NO;break;}
        } else if (command->cmd==LC_SEGMENT_64) {
            if (command->cmdsize<sizeof(struct segment_command_64) || segmentCount==64) {valid=NO;break;}
            const struct segment_command_64 *segment=(const void *)command;
            if (segment->nsects!=(command->cmdsize-sizeof(*segment))/sizeof(struct section_64) ||
                command->cmdsize!=sizeof(*segment)+(uint64_t)segment->nsects*sizeof(struct section_64) ||
                segment->vmsize>UINT64_MAX-segment->vmaddr || segment->filesize>UINT64_MAX-segment->fileoff ||
                segment->filesize>segment->vmsize) {valid=NO;break;}
            for (NSUInteger previous=0;previous<segmentCount;previous++)
                if (segment->vmsize && segments[previous].size && segment->vmaddr<segments[previous].address+segments[previous].size &&
                    segments[previous].address<segment->vmaddr+segment->vmsize) {valid=NO;break;}
            if (!valid) break;
            segments[segmentCount].address=segment->vmaddr;segments[segmentCount++].size=segment->vmsize;
            BOOL isText=AxsCacheKeeperImageLegacyName(segment->segname,"__TEXT");
            if (isText) {
                if (++textCount!=1 || segment->fileoff || segment->vmaddr!=0x100000000 ||
                    segment->filesize<length || (segment->initprot&(VM_PROT_READ|VM_PROT_EXECUTE))!=(VM_PROT_READ|VM_PROT_EXECUTE) ||
                    (segment->maxprot&(VM_PROT_READ|VM_PROT_EXECUTE))!=(VM_PROT_READ|VM_PROT_EXECUTE) ||
                    ((segment->initprot|segment->maxprot)&VM_PROT_WRITE)) {valid=NO;break;}
                text=*segment;
            }
            const struct section_64 *sections=(const void *)(segment+1);
            for (uint32_t part=0;valid && part<segment->nsects;part++) {
                const struct section_64 *candidate=&sections[part];
                if (!AxsCacheKeeperImageLegacyName(candidate->sectname,"__text")) continue;
                if (++sectionCount!=1 || !isText || !AxsCacheKeeperImageLegacyName(candidate->segname,"__TEXT") ||
                    !candidate->size || (candidate->flags&SECTION_TYPE)!=S_REGULAR ||
                    (candidate->flags&(S_ATTR_PURE_INSTRUCTIONS|S_ATTR_SOME_INSTRUCTIONS))!=(S_ATTR_PURE_INSTRUCTIONS|S_ATTR_SOME_INSTRUCTIONS) ||
                    !AxsCacheKeeperImageLegacyContains(segment->vmaddr,segment->vmsize,candidate->addr,candidate->size) ||
                    !AxsCacheKeeperImageLegacyContains(segment->fileoff,segment->filesize,candidate->offset,candidate->size) ||
                    candidate->addr-segment->vmaddr!=(uint64_t)candidate->offset-segment->fileoff) {valid=NO;break;}
                section=*candidate;
            }
        }
        cursor+=command->cmdsize;
    }
    valid=valid && cursor==length && textCount==1 && sectionCount==1 && uuidCount==1;
    if (valid) {
        uint64_t address=text.vmaddr;
        if (slide>=0) {
            if ((uint64_t)slide>UINTPTR_MAX-address) valid=NO;else address+=(uint64_t)slide;
        } else {
            uint64_t magnitude=(uint64_t)(-(slide+1))+1;
            if (magnitude>address) valid=NO;else address-=magnitude;
        }
        if (valid && (address!=(uintptr_t)base || text.vmsize>UINTPTR_MAX-address)) valid=NO;
        if (valid) *layout=(AxsCacheKeeperImageLegacyLayout){(uintptr_t)base,section.addr-text.vmaddr,section.size};
    }
    free(copy);return valid;
}
static inline BOOL AxsCacheKeeperImageLegacyWindowMatches(const AxsCacheKeeperImageLegacyLayout *layout,const void *implementation,const AxsCacheKeeperImageLegacyWindow *window) {
    if (!layout || !implementation || !window || !window->length || window->length>4096 || window->offset>UINTPTR_MAX-layout->base) return NO;
#if __has_feature(ptrauth_calls)
    implementation=ptrauth_strip(implementation,ptrauth_key_function_pointer);
#endif
    if ((uintptr_t)implementation!=layout->base+window->offset) return NO;
    if (!AxsCacheKeeperImageLegacyContains(layout->sectionOffset,layout->sectionSize,window->offset,window->length)) return NO;
    unsigned char bytes[4096],digest[CC_SHA256_DIGEST_LENGTH];
    if (!AxsCacheKeeperImageLegacyRead((uintptr_t)implementation,bytes,window->length,VM_PROT_READ|VM_PROT_EXECUTE) ||
        !CC_SHA256(bytes,(CC_LONG)window->length,digest)) return NO;
    if (memcmp(digest,window->sha256,sizeof(digest))) return NO;
    return YES;
}
static inline BOOL AxsCacheKeeperImageLegacySlotsPresent(const void *implementations[25]) {
    if (!implementations || implementations[10]) return NO;
    for (NSUInteger index=0;index<25;index++) if (index!=10 && !implementations[index]) return NO;
    return YES;
}
static inline BOOL AxsCacheKeeperImageLegacyClassFromMainImage(Class owner,const void *base) {
    if (!owner || class_isMetaClass(owner) || !base || base!=(const void *)_dyld_get_image_header(0)) return NO;
    const char *imageName=class_getImageName(owner),*mainName=_dyld_get_image_name(0);
    return imageName && mainName && !strcmp(imageName,mainName);
}
static inline BOOL AxsCacheKeeperImageLegacyMethodMatches(const AxsCacheKeeperImageLegacyLayout *layout,Class owner,const char *selector,const char *encoding,const AxsCacheKeeperImageLegacyWindow *window) {
    if (!layout || !selector || !encoding || !window || !AxsCacheKeeperImageLegacyClassFromMainImage(owner,(const void *)layout->base)) return NO;
    Class meta=object_getClass(owner);if (!meta || !class_isMetaClass(meta)) return NO;
    SEL name=sel_registerName(selector);Method method=class_getClassMethod(owner,name);if (!method) return NO;
    unsigned int count=0;Method *methods=class_copyMethodList(meta,&count);BOOL own=NO;
    for (unsigned int index=0;methods && index<count;index++) if (methods[index]==method) {own=YES;break;}
    free(methods);
    if (!own) return NO;
    size_t length=strlen(encoding);unsigned char actualEncoding[128];
    if (!length || length>=sizeof(actualEncoding) ||
        !AxsCacheKeeperImageLegacyRead((uintptr_t)method_getTypeEncoding(method),actualEncoding,length+1,VM_PROT_READ)) return NO;
    if (memcmp(actualEncoding,encoding,length+1)) return NO;
    IMP implementation=method_getImplementation(method);
    if (!AxsCacheKeeperImageLegacyWindowMatches(layout,(const void *)implementation,window)) return NO;
    return class_getClassMethod(owner,name)==method && method_getImplementation(method)==implementation;
}
static inline BOOL AxsCacheKeeperImageLegacyReadMainLayout(const void *base,AxsCacheKeeperImageLegacyLayout *layout) {
    if (!base || base!=(const void *)_dyld_get_image_header(0)) return NO;
    NSBundle *bundle=NSBundle.mainBundle;
    if (![bundle.bundleIdentifier isEqual:@"com.baidu.netdisk"] ||
        ![bundle.infoDictionary[@"CFBundleShortVersionString"] isEqual:@"13.37.5"] ||
        ![bundle.infoDictionary[@"CFBundleVersion"] isEqual:@"13.37.5.10"]) return NO;
    return AxsCacheKeeperImageLegacyReadLayout(base,_dyld_get_image_vmaddr_slide(0),layout);
}
static inline BOOL AxsCacheKeeperImageLegacyHelpersForLayout(const AxsCacheKeeperImageLegacyLayout *layout) {
    // Provenance: docs/2026-11-16-baidu-image-contract.json. The 548-byte remove
    // window excludes the separately starting code after its observed return/error path.
    static const struct {
        const char *selector;
        const char *encoding;
        AxsCacheKeeperImageLegacyWindow window;
    } helpers[]={
        {"setExtendedAttribute:value:atPath:traverseLink:overwrite:error:","B56@0:8@16@24@32B40B44^@48",
            {0,0xb8c3640,804,{0x72,0xa2,0xc4,0xac,0xac,0x45,0x64,0x54,0x75,0x0c,0x4e,0x76,0x11,0x81,0xff,0x10,0xdd,0x3b,0x0a,0x12,0x82,0xe9,0x09,0x4e,0x13,0xdf,0x04,0x2c,0xa8,0xc8,0xa3,0x62}}},
        {"removeExtendedAttribute:atPath:traverseLink:error:","B44@0:8@16@24B32^@36",
            {0,0xb8c3964,548,{0x6b,0xb0,0x89,0xd1,0x92,0x81,0xa7,0x8c,0x01,0x1a,0xd4,0x6d,0xc8,0xd9,0xe7,0x0f,0x72,0x30,0x2b,0x5e,0xe1,0xc0,0x30,0xda,0xd2,0x4c,0x08,0x3d,0x3c,0x0a,0x12,0xc8}}},
    };
    Class owner=NSClassFromString(@"SDFileAttributeHelper");
    for (NSUInteger index=0;index<sizeof(helpers)/sizeof(helpers[0]);index++)
        if (!AxsCacheKeeperImageLegacyMethodMatches(layout,owner,helpers[index].selector,helpers[index].encoding,&helpers[index].window)) return NO;
    return YES;
}
// Recheck the two live helpers without rescanning the 24 saved SDK method windows.
// Main-image identity/layout, own metaclass methods, exact ABI and fixed code remain mandatory.
static inline BOOL AxsCacheKeeperImageLegacyHelpersMatch(const void *base) {
    AxsCacheKeeperImageLegacyLayout layout;
    return AxsCacheKeeperImageLegacyReadMainLayout(base,&layout) && AxsCacheKeeperImageLegacyHelpersForLayout(&layout);
}
// Pass the four saved SDK originals after hook publication, never our wrapper IMPs.
// Callers still enforce the 24 SDK methods' class ownership and all method ABIs.
static inline BOOL AxsCacheKeeperImageLegacySourceMatches(const void *base,const void *implementations[25]) {
    if (!AxsCacheKeeperImageLegacySlotsPresent(implementations)) return NO;
    AxsCacheKeeperImageLegacyLayout layout;
    if (!AxsCacheKeeperImageLegacyReadMainLayout(base,&layout)) return NO;
    for (NSUInteger index=0;index<24;index++) {
        const AxsCacheKeeperImageLegacyWindow *window=&AxsCacheKeeperImageLegacyWindows[index];
        if (!AxsCacheKeeperImageLegacyWindowMatches(&layout,implementations[window->methodIndex-1],window)) return NO;
    }
    return AxsCacheKeeperImageLegacyHelpersForLayout(&layout);
}
