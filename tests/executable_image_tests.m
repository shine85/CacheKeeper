#import <Foundation/Foundation.h>
#include <mach-o/dyld.h>
#include <stdlib.h>
static NSUInteger ckpaths,ckheaders,cknames;
static BOOL ckcountChanged;
static char *ckrealpath(const char *path,char *out) {ckpaths++;return realpath(path,out);}
static uint32_t ckimagecount(void) {return _dyld_image_count()+(ckcountChanged ? 1 : 0);}
static const struct mach_header *ckimageheader(uint32_t index) {ckheaders++;return _dyld_get_image_header(index);}
static const char *ckimagename(uint32_t index) {cknames++;return _dyld_get_image_name(index);}
#define realpath ckrealpath
#define _dyld_image_count ckimagecount
#define _dyld_get_image_header ckimageheader
#define _dyld_get_image_name ckimagename
#import "AxsCacheKeeperImageLegacySource.h"
#undef realpath
#undef _dyld_image_count
#undef _dyld_get_image_header
#undef _dyld_get_image_name
#include <stdio.h>

static void ckcheck(BOOL value,const char *message) {
    if (!value) {fprintf(stderr,"FAIL: executable-image: %s\n",message);exit(1);}
}
int main(void) {@autoreleasepool {
    __block struct mach_header_64 wrapper={.magic=MH_MAGIC_64,.filetype=MH_DYLIB};
    __block struct mach_header_64 executable={.magic=MH_MAGIC_64,.filetype=MH_EXECUTE};
    __block BOOL changed=NO;__block NSUInteger reads=0;
    AxsCacheKeeperExecutableImageRow (^row)(uint32_t)=^AxsCacheKeeperExecutableImageRow(uint32_t index) {
        if (changed && ++reads>2) return (AxsCacheKeeperExecutableImageRow){0};
        return index==0 ? (AxsCacheKeeperExecutableImageRow){(const void *)&wrapper,"/fixture/wrapper",0} :
            (AxsCacheKeeperExecutableImageRow){(const void *)&executable,"/fixture/App",4096};
    };
    AxsCacheKeeperExecutableImage selected={0};
    ckcheck(AxsCacheKeeperExecutableImageSelect(2,"/fixture/App",row,&selected) && selected.header==&executable &&
        selected.index==1 && selected.slide==4096,"wrapper before executable selects the bundle executable and its own slide");
    ckcheck(!AxsCacheKeeperExecutableImageSelect(2,"/fixture/wrapper",row,&selected),"a matching dylib path is never the executable");
    ckcheck(!AxsCacheKeeperExecutableImageSelect(2,"/fixture/Other",row,&selected),"a foreign bundle path does not select the only executable");
    ckcheck(!AxsCacheKeeperExecutableImageSelect(4097,"/fixture/App",row,&selected),"an unbounded loader table is refused");
    ckcheck(!AxsCacheKeeperExecutableImageSelect(2,NULL,row,&selected),"missing bundle executable never falls back to loader order");
    AxsCacheKeeperExecutableImageRow (^duplicate)(uint32_t)=^AxsCacheKeeperExecutableImageRow(uint32_t index) {
        (void)index;return (AxsCacheKeeperExecutableImageRow){(const void *)&executable,"/fixture/App",0};
    };
    ckcheck(!AxsCacheKeeperExecutableImageSelect(2,"/fixture/App",duplicate,&selected),"ambiguous executable registration is refused");
    changed=YES;reads=0;
    ckcheck(!AxsCacheKeeperExecutableImageSelect(2,"/fixture/App",row,&selected) && !selected.header,"changed loader view clears the selected result");
    ckcheck(!AxsCacheKeeperImageExecutable().header && !ckpaths && !ckheaders && !cknames,
        "cold identity lookup performs no discovery");
    AxsCacheKeeperImageRefreshExecutable();
    AxsCacheKeeperExecutableImage actual=AxsCacheKeeperImageExecutable();
    ckcheck(actual.header && actual.header!=(const void *)(uintptr_t)1,"production resolver selects this process executable");
    ckcheck(AxsCacheKeeperImageLegacyClassFromMainImage(NSClassFromString(@"AxsCacheKeeperExecutableCanary"),actual.header),
        "the selected executable authenticates its actual class image");
    ckpaths=ckheaders=cknames=0;
    ckcheck(AxsCacheKeeperImageExecutable().header==actual.header && ckpaths==0 && ckheaders==2 && cknames==2,
        "hot identity lookup checks only its fixed loader row without filesystem lookup");
    atomic_fetch_add(&axs_cachekeeper_image_observation_generation,1);
    ckpaths=ckheaders=cknames=0;
    ckcheck(!AxsCacheKeeperImageExecutable().header && !AxsCacheKeeperImageExecutable().header,
        "generation change revokes cached identity until explicit discovery refresh");
    ckcheck(!ckpaths && !ckheaders && !cknames,"stale identity lookup performs no path resolution or table enumeration");
    AxsCacheKeeperImageRefreshExecutable();
    ckcheck(AxsCacheKeeperImageExecutable().header==actual.header,"explicit discovery refresh restores executable identity");
    ckcountChanged=YES;ckpaths=ckheaders=cknames=0;
    ckcheck(!AxsCacheKeeperImageExecutable().header && !ckpaths && !ckheaders && !cknames,
        "loader count change revokes identity without discovery");
    ckcountChanged=NO;
    printf("PASS: bundle executable selection and loader boundaries\n");
}return 0;}
@interface AxsCacheKeeperExecutableCanary : NSObject
@end
@implementation AxsCacheKeeperExecutableCanary
@end
