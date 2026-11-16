// Synthetic Mach-O/data fixture for the production memory reader and fingerprint gates.
// No Baidu instructions, fake SDWebImage, or production source pin are included.
#import <Foundation/Foundation.h>
#include <sys/mman.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#import "AxsCacheKeeperImageLegacySource.h"

// A test-owned byte marker in real executable memory. It is hashed, never executed.
__asm__(".section __TEXT,__text,regular,pure_instructions\n"
        ".p2align 4\n.globl _axs_cachekeeper_legacy_method_bytes\n"
        "_axs_cachekeeper_legacy_method_bytes:\n.byte 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16\n");
extern const unsigned char axs_cachekeeper_legacy_method_bytes[];
@interface AxsCacheKeeperLegacyMethodFixture : NSObject
+ (id)axs_cachekeeper_sample:(id)value;
@end
@implementation AxsCacheKeeperLegacyMethodFixture
+ (id)axs_cachekeeper_sample:(id)value {return value;}
@end
@interface AxsCacheKeeperLegacyInheritedFixture : AxsCacheKeeperLegacyMethodFixture
@end
@implementation AxsCacheKeeperLegacyInheritedFixture
@end

static void axs_cachekeeper_legacy_require(BOOL value,const char *message) {
    if (!value) {fprintf(stderr,"FAIL: image-legacy-source: %s\n",message);exit(1);}
}
static uint8_t *axs_cachekeeper_legacy_mapping;
static size_t axs_cachekeeper_legacy_page;
static struct mach_header_64 *axs_cachekeeper_legacy_header;
static struct segment_command_64 *axs_cachekeeper_legacy_segment;
static struct section_64 *axs_cachekeeper_legacy_section;
static struct uuid_command *axs_cachekeeper_legacy_uuid;
static void axs_cachekeeper_legacy_protect(size_t offset,size_t length,int protection) {
    axs_cachekeeper_legacy_require(mprotect(axs_cachekeeper_legacy_mapping+offset,length,protection)==0,"fixture protection changes");
}
static void axs_cachekeeper_legacy_reset(void) {
    axs_cachekeeper_legacy_protect(0,3*axs_cachekeeper_legacy_page,PROT_READ|PROT_WRITE);
    memset(axs_cachekeeper_legacy_mapping,0,3*axs_cachekeeper_legacy_page);
    axs_cachekeeper_legacy_header=(struct mach_header_64 *)axs_cachekeeper_legacy_mapping;
    *axs_cachekeeper_legacy_header=(struct mach_header_64){.magic=MH_MAGIC_64,.cputype=CPU_TYPE_ARM64,
        .cpusubtype=CPU_SUBTYPE_ARM64_ALL,.filetype=MH_EXECUTE,.ncmds=2,
        .sizeofcmds=sizeof(struct segment_command_64)+sizeof(struct section_64)+sizeof(struct uuid_command)};
    axs_cachekeeper_legacy_segment=(void *)(axs_cachekeeper_legacy_header+1);
    *axs_cachekeeper_legacy_segment=(struct segment_command_64){.cmd=LC_SEGMENT_64,
        .cmdsize=sizeof(struct segment_command_64)+sizeof(struct section_64),.vmaddr=0x100000000,
        .vmsize=3*axs_cachekeeper_legacy_page,.filesize=3*axs_cachekeeper_legacy_page,
        .maxprot=VM_PROT_READ|VM_PROT_EXECUTE,.initprot=VM_PROT_READ|VM_PROT_EXECUTE,.nsects=1};
    memcpy(axs_cachekeeper_legacy_segment->segname,"__TEXT",7);
    axs_cachekeeper_legacy_section=(void *)(axs_cachekeeper_legacy_segment+1);
    *axs_cachekeeper_legacy_section=(struct section_64){.addr=0x100000000+axs_cachekeeper_legacy_page,
        .size=axs_cachekeeper_legacy_page,.offset=(uint32_t)axs_cachekeeper_legacy_page,
        .flags=S_ATTR_PURE_INSTRUCTIONS|S_ATTR_SOME_INSTRUCTIONS};
    memcpy(axs_cachekeeper_legacy_section->sectname,"__text",7);
    memcpy(axs_cachekeeper_legacy_section->segname,"__TEXT",7);
    axs_cachekeeper_legacy_uuid=(void *)(axs_cachekeeper_legacy_section+1);
    *axs_cachekeeper_legacy_uuid=(struct uuid_command){.cmd=LC_UUID,.cmdsize=sizeof(struct uuid_command),
        .uuid={0xb2,0xb9,0xd3,0x0a,0x1c,0xaf,0x31,0xb4,0x82,0xca,0xc7,0x76,0xe7,0xeb,0x2b,0xa1}};
    for (size_t i=0;i<16;i++) axs_cachekeeper_legacy_mapping[axs_cachekeeper_legacy_page+32+i]=(uint8_t)(i+1);
}
static BOOL axs_cachekeeper_legacy_layout(AxsCacheKeeperImageLegacyLayout *layout) {
    axs_cachekeeper_legacy_protect(0,axs_cachekeeper_legacy_page,PROT_READ);
    axs_cachekeeper_legacy_protect(axs_cachekeeper_legacy_page,2*axs_cachekeeper_legacy_page,PROT_READ|PROT_EXEC);
    return AxsCacheKeeperImageLegacyReadLayout(axs_cachekeeper_legacy_mapping,
        (intptr_t)(uintptr_t)axs_cachekeeper_legacy_mapping-(intptr_t)0x100000000,layout);
}
int main(void) {
    @autoreleasepool {
        axs_cachekeeper_legacy_page=(size_t)getpagesize();
        axs_cachekeeper_legacy_mapping=mmap(NULL,3*axs_cachekeeper_legacy_page,PROT_NONE,MAP_PRIVATE|MAP_ANON,-1,0);
        axs_cachekeeper_legacy_require(axs_cachekeeper_legacy_mapping!=MAP_FAILED,"fixture mapping succeeds");
        AxsCacheKeeperImageLegacyLayout layout={0};
        axs_cachekeeper_legacy_reset();
        axs_cachekeeper_legacy_require(axs_cachekeeper_legacy_layout(&layout),"valid loaded layout is read");
        AxsCacheKeeperImageLegacyWindow window={.methodIndex=1,.offset=axs_cachekeeper_legacy_page+32,.length=16,
            .sha256={0x5d,0xfb,0xab,0xee,0xdf,0x31,0x8b,0xf3,0x3c,0x09,0x27,0xc4,0x3d,0x76,0x30,0xf5,
                0x1b,0x82,0xf3,0x51,0x74,0x03,0x01,0x35,0x4f,0xa3,0xd7,0xfc,0x51,0xf0,0x13,0x2e}};
        const void *implementation=axs_cachekeeper_legacy_mapping+window.offset;
        axs_cachekeeper_legacy_require(AxsCacheKeeperImageLegacyWindowMatches(&layout,implementation,&window),"exact loaded data fingerprint matches");
        axs_cachekeeper_legacy_require(!AxsCacheKeeperImageLegacyWindowMatches(&layout,(const uint8_t *)implementation+1,&window),"wrong IMP offset is refused");
        for (size_t i=0;i<window.length;i++) {
            axs_cachekeeper_legacy_protect(axs_cachekeeper_legacy_page,axs_cachekeeper_legacy_page,PROT_READ|PROT_WRITE);
            axs_cachekeeper_legacy_mapping[window.offset+i]^=0x80;
            axs_cachekeeper_legacy_protect(axs_cachekeeper_legacy_page,axs_cachekeeper_legacy_page,PROT_READ|PROT_EXEC);
            axs_cachekeeper_legacy_require(!AxsCacheKeeperImageLegacyWindowMatches(&layout,implementation,&window),"byte mutation is refused");
            axs_cachekeeper_legacy_protect(axs_cachekeeper_legacy_page,axs_cachekeeper_legacy_page,PROT_READ|PROT_WRITE);
            axs_cachekeeper_legacy_mapping[window.offset+i]^=0x80;
            axs_cachekeeper_legacy_protect(axs_cachekeeper_legacy_page,axs_cachekeeper_legacy_page,PROT_READ|PROT_EXEC);
        }
        AxsCacheKeeperImageLegacyLayout clipped=layout;clipped.sectionSize=32;
        axs_cachekeeper_legacy_require(!AxsCacheKeeperImageLegacyWindowMatches(&clipped,implementation,&window),"section crossing is refused");
        clipped.sectionOffset=window.offset;clipped.sectionSize=window.length;
        axs_cachekeeper_legacy_require(AxsCacheKeeperImageLegacyWindowMatches(&clipped,implementation,&window),"exact section endpoints are accepted");
        clipped.sectionSize--;
        axs_cachekeeper_legacy_require(!AxsCacheKeeperImageLegacyWindowMatches(&clipped,implementation,&window),"one byte beyond section is refused");
        AxsCacheKeeperImageLegacyWindow oversized=window;oversized.length=UINT32_MAX;
        axs_cachekeeper_legacy_require(!AxsCacheKeeperImageLegacyWindowMatches(&layout,implementation,&oversized),"oversized capture is refused");
        axs_cachekeeper_legacy_protect(axs_cachekeeper_legacy_page,axs_cachekeeper_legacy_page,PROT_NONE);
        axs_cachekeeper_legacy_require(!AxsCacheKeeperImageLegacyWindowMatches(&layout,implementation,&window),"unreadable code memory is refused without dereference");
        axs_cachekeeper_legacy_protect(axs_cachekeeper_legacy_page,axs_cachekeeper_legacy_page,PROT_READ);
        axs_cachekeeper_legacy_require(!AxsCacheKeeperImageLegacyWindowMatches(&layout,implementation,&window),"non executable code memory is refused");

        const void *methods[25];for (NSUInteger i=0;i<25;i++) methods[i]=implementation;methods[10]=NULL;
        axs_cachekeeper_legacy_require(AxsCacheKeeperImageLegacySlotsPresent(methods),"legacy slot shape accepted");
        methods[10]=implementation;
        axs_cachekeeper_legacy_require(!AxsCacheKeeperImageLegacySlotsPresent(methods),"unexpected eleventh method is refused");
        methods[10]=NULL;
        for (NSUInteger i=0;i<25;i++) if (i!=10) {
            methods[i]=NULL;
            axs_cachekeeper_legacy_require(!AxsCacheKeeperImageLegacySlotsPresent(methods),"every required method is checked");
            methods[i]=implementation;
        }
        axs_cachekeeper_legacy_require(!AxsCacheKeeperImageLegacySourceMatches(axs_cachekeeper_legacy_mapping,methods),"non dyld image is refused");
        axs_cachekeeper_legacy_require(!AxsCacheKeeperImageLegacySourceMatches(_dyld_get_image_header(0),methods),"unmatched real host is refused");
        axs_cachekeeper_legacy_require(!AxsCacheKeeperImageLegacyHelpersMatch(axs_cachekeeper_legacy_mapping),"helper-only gate rejects a non dyld image");
        axs_cachekeeper_legacy_require(!AxsCacheKeeperImageLegacyHelpersMatch(_dyld_get_image_header(0)),"helper-only gate retains exact host identity");

        axs_cachekeeper_legacy_reset();axs_cachekeeper_legacy_header->magic=MH_CIGAM_64;
        axs_cachekeeper_legacy_require(!axs_cachekeeper_legacy_layout(&layout),"wrong magic is refused");
        axs_cachekeeper_legacy_reset();axs_cachekeeper_legacy_header->sizeofcmds=UINT32_MAX;
        axs_cachekeeper_legacy_require(!axs_cachekeeper_legacy_layout(&layout),"oversized load commands are refused");
        axs_cachekeeper_legacy_reset();axs_cachekeeper_legacy_segment->cmdsize=sizeof(struct load_command);
        axs_cachekeeper_legacy_require(!axs_cachekeeper_legacy_layout(&layout),"truncated segment is refused");
        axs_cachekeeper_legacy_reset();axs_cachekeeper_legacy_header->ncmds++;
        axs_cachekeeper_legacy_require(!axs_cachekeeper_legacy_layout(&layout),"missing load command is refused");
        axs_cachekeeper_legacy_reset();axs_cachekeeper_legacy_uuid->uuid[0]^=1;
        axs_cachekeeper_legacy_require(!axs_cachekeeper_legacy_layout(&layout),"wrong UUID is refused");
        axs_cachekeeper_legacy_reset();memcpy(axs_cachekeeper_legacy_uuid+1,axs_cachekeeper_legacy_uuid,sizeof(*axs_cachekeeper_legacy_uuid));
        axs_cachekeeper_legacy_header->ncmds++;axs_cachekeeper_legacy_header->sizeofcmds+=sizeof(*axs_cachekeeper_legacy_uuid);
        axs_cachekeeper_legacy_require(!axs_cachekeeper_legacy_layout(&layout),"duplicate UUID is refused");
        axs_cachekeeper_legacy_reset();axs_cachekeeper_legacy_section->flags=0;
        axs_cachekeeper_legacy_require(!axs_cachekeeper_legacy_layout(&layout),"non instruction section is refused");
        axs_cachekeeper_legacy_reset();axs_cachekeeper_legacy_section->size=UINT64_MAX;
        axs_cachekeeper_legacy_require(!axs_cachekeeper_legacy_layout(&layout),"overflowing section is refused");
        axs_cachekeeper_legacy_reset();axs_cachekeeper_legacy_section->offset++;
        axs_cachekeeper_legacy_require(!axs_cachekeeper_legacy_layout(&layout),"section file and VM disagreement is refused");
        axs_cachekeeper_legacy_reset();axs_cachekeeper_legacy_segment->vmsize=UINT64_MAX;
        axs_cachekeeper_legacy_require(!axs_cachekeeper_legacy_layout(&layout),"overflowing segment is refused");
        axs_cachekeeper_legacy_reset();axs_cachekeeper_legacy_segment->filesize=axs_cachekeeper_legacy_page;
        axs_cachekeeper_legacy_require(!axs_cachekeeper_legacy_layout(&layout),"non file backed section is refused");
        axs_cachekeeper_legacy_reset();axs_cachekeeper_legacy_segment->initprot|=VM_PROT_WRITE;
        axs_cachekeeper_legacy_require(!axs_cachekeeper_legacy_layout(&layout),"writable text segment is refused");
        axs_cachekeeper_legacy_reset();
        struct segment_command_64 *overlap=(void *)(axs_cachekeeper_legacy_uuid+1);
        *overlap=(struct segment_command_64){.cmd=LC_SEGMENT_64,.cmdsize=sizeof(*overlap),
            .vmaddr=0x100000000+axs_cachekeeper_legacy_page,.vmsize=axs_cachekeeper_legacy_page};
        memcpy(overlap->segname,"__OTHER",8);axs_cachekeeper_legacy_header->ncmds++;
        axs_cachekeeper_legacy_header->sizeofcmds+=sizeof(*overlap);
        axs_cachekeeper_legacy_require(!axs_cachekeeper_legacy_layout(&layout),"overlapping loaded segments are refused");
        axs_cachekeeper_legacy_reset();
        axs_cachekeeper_legacy_require(!AxsCacheKeeperImageLegacyReadLayout(axs_cachekeeper_legacy_mapping,0,&layout),"wrong image slide is refused");
        axs_cachekeeper_legacy_protect(0,axs_cachekeeper_legacy_page,PROT_NONE);
        axs_cachekeeper_legacy_require(!AxsCacheKeeperImageLegacyReadLayout(axs_cachekeeper_legacy_mapping,0,&layout),"unreadable header is refused without dereference");
        axs_cachekeeper_legacy_require(!AxsCacheKeeperImageLegacyReadLayout((void *)(UINTPTR_MAX-16),0,&layout),"overflowing header address is refused");
        axs_cachekeeper_legacy_require(munmap(axs_cachekeeper_legacy_mapping,3*axs_cachekeeper_legacy_page)==0,"fixture mapping closes");

        // Exercise the same helper gate against actual Objective-C metadata and known bytes.
        const void *mainImage=_dyld_get_image_header(0);Class fixture=AxsCacheKeeperLegacyMethodFixture.class;
        axs_cachekeeper_legacy_require(AxsCacheKeeperImageLegacyClassFromMainImage(fixture,mainImage),"own class source is accepted");
        axs_cachekeeper_legacy_require(!AxsCacheKeeperImageLegacyClassFromMainImage(NSObject.class,mainImage),"foreign class source is refused");
        axs_cachekeeper_legacy_require(!AxsCacheKeeperImageLegacyClassFromMainImage(object_getClass(fixture),mainImage),"metaclass is not accepted as the source class");
        window.offset=(uintptr_t)axs_cachekeeper_legacy_method_bytes-(uintptr_t)mainImage;
        layout=(AxsCacheKeeperImageLegacyLayout){(uintptr_t)mainImage,window.offset,window.length};
        Method method=class_getClassMethod(fixture,@selector(axs_cachekeeper_sample:));IMP original=method_getImplementation(method);
        method_setImplementation(method,(IMP)axs_cachekeeper_legacy_method_bytes);
        axs_cachekeeper_legacy_require(AxsCacheKeeperImageLegacyMethodMatches(&layout,fixture,"axs_cachekeeper_sample:","@24@0:8@16",&window),"own metaclass method with exact source ABI and bytes is accepted");
        axs_cachekeeper_legacy_require(!AxsCacheKeeperImageLegacyMethodMatches(&layout,fixture,"axs_cachekeeper_sample:","v24@0:8@16",&window),"helper ABI mismatch is refused");
        axs_cachekeeper_legacy_require(!AxsCacheKeeperImageLegacyMethodMatches(&layout,AxsCacheKeeperLegacyInheritedFixture.class,"axs_cachekeeper_sample:","@24@0:8@16",&window),"inherited helper method is refused");
        axs_cachekeeper_legacy_require(!AxsCacheKeeperImageLegacyMethodMatches(&layout,fixture,"missing:","@24@0:8@16",&window),"missing helper method is refused");
        method_setImplementation(method,original);
        for (NSUInteger attempt=0;attempt<2;attempt++)
            axs_cachekeeper_legacy_require(!AxsCacheKeeperImageLegacyMethodMatches(&layout,fixture,"axs_cachekeeper_sample:","@24@0:8@16",&window),"later helper IMP is never relearned");
        method_setImplementation(method,(IMP)axs_cachekeeper_legacy_method_bytes);
        axs_cachekeeper_legacy_require(AxsCacheKeeperImageLegacyMethodMatches(&layout,fixture,"axs_cachekeeper_sample:","@24@0:8@16",&window),"only the verified helper implementation can return");
        method_setImplementation(method,original);
        puts("PASS: image-legacy-source native memory boundaries and fingerprints");
    }
    return 0;
}
