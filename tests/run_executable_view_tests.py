"""Run production executable lookup with bounded C loader fixtures; no ObjC runtime claim."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
ROOT=Path(__file__).resolve().parents[1]

def run():
    source=(Path(sys.argv[1]) if len(sys.argv)>1 else ROOT/'AxsCacheKeeperImageLegacySource.h').read_text(encoding='utf-8-sig')
    first=source.index('static inline BOOL AxsCacheKeeperExecutableImageSelect(')
    last=source.index('// Call only from discovery/diagnostic work,')
    product=source[first:last].replace('static NSString *axs_cachekeeper_executable_loader_name;', 'static const char *axs_cachekeeper_executable_loader_name;')
    product=product.replace('NSString *name=axs_cachekeeper_executable_loader_name;', 'const char *name=axs_cachekeeper_executable_loader_name;').replace('name.fileSystemRepresentation','name')
    if 'axs_cachekeeper_executable_authenticated_header' not in product:
        product += '\nstatic const void *axs_cachekeeper_executable_authenticated_header;\n'
    if 'AxsCacheKeeperImageLegacyMainViewUnavailable' not in product:
        product += '\nstatic bool AxsCacheKeeperImageLegacyMainViewUnavailable(const void *base) {(void)base;return false;}\n'
    # String storage and locks are boundary stubs; selection, row validation, count,
    # generation checks and return paths remain the production function text.
    fixture=r'''
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <stdatomic.h>
#define BOOL bool
#define YES true
#define NO false
#define VM_PROT_READ 1
#define MH_MAGIC_64 0xfeedfacf
#define MH_EXECUTE 2
#define OS_UNFAIR_LOCK_INIT 0
typedef int os_unfair_lock;
void os_unfair_lock_lock(os_unfair_lock *lock) {(void)lock;}
void os_unfair_lock_unlock(os_unfair_lock *lock) {(void)lock;}
void *_NSConcreteStackBlock[32];
struct mach_header_64 {uint32_t magic,filetype;};
typedef struct {const void *header;const char *name;intptr_t slide;} AxsCacheKeeperExecutableImageRow;
typedef struct {const void *header;intptr_t slide;uint32_t index;} AxsCacheKeeperExecutableImage;
static atomic_ulong axs_cachekeeper_image_observation_generation;
static struct mach_header_64 executable={MH_MAGIC_64,MH_EXECUTE};
static struct mach_header_64 foreign={MH_MAGIC_64,MH_EXECUTE};
static uint32_t loaderCount=2,headers,names;
static bool changedRow,changedSlide,changedName,changedDuringRead;
static uint32_t _dyld_image_count(void) {return loaderCount;}
static const void *_dyld_get_image_header(uint32_t index) {(void)index;headers++;if(changedDuringRead)atomic_fetch_add(&axs_cachekeeper_image_observation_generation,1);return changedRow?&foreign:&executable;}
static const char *_dyld_get_image_name(uint32_t index) {(void)index;names++;return changedName?"/fixture/Other":"/fixture/App";}
static intptr_t _dyld_get_image_vmaddr_slide(uint32_t index) {(void)index;return changedSlide?8192:4096;}
static bool AxsCacheKeeperImageLegacyRead(uintptr_t source,void *target,size_t length,int protection) {(void)protection;if(!source)return false;memcpy(target,(const void *)source,length);return true;}
'''
    tests=r'''
static void check(bool value,const char *message) {if(!value){fprintf(stderr,"FAIL: executable-view: %s\n",message);exit(1);}}
static void refresh(void) {axs_cachekeeper_executable_cached=(AxsCacheKeeperExecutableImage){&executable,4096,1};axs_cachekeeper_executable_authenticated_header=&executable;axs_cachekeeper_executable_loader_name="/fixture/App";axs_cachekeeper_executable_count=loaderCount;axs_cachekeeper_executable_generation=atomic_load(&axs_cachekeeper_image_observation_generation);}
int main(void) {
    check(!AxsCacheKeeperImageExecutable().header,"cold view is absent");refresh();
    check(AxsCacheKeeperImageExecutable().header==&executable,"stable view authenticates fixed row");
    check(!AxsCacheKeeperImageLegacyMainViewUnavailable(&executable),"stable authenticated executable is not a waiting view");
    atomic_fetch_add(&axs_cachekeeper_image_observation_generation,1);headers=names=0;
    check(!AxsCacheKeeperImageExecutable().header&&!headers&&!names,"generation change returns NULL before synchronous admission can inspect its methods");
    check(AxsCacheKeeperImageLegacyMainViewUnavailable(&executable)&&!AxsCacheKeeperImageLegacyMainViewUnavailable(&foreign),"only known revoked executable is classified as waiting");
    axs_cachekeeper_executable_cached=(AxsCacheKeeperExecutableImage){0};
    check(AxsCacheKeeperImageLegacyMainViewUnavailable(&executable),"in-progress discovery retains only prior identity classification");
    refresh();check(AxsCacheKeeperImageExecutable().header==&executable,"explicit stable refresh restores identity");
    loaderCount++;headers=names=0;check(!AxsCacheKeeperImageExecutable().header&&!headers&&!names,"count change returns NULL without scanning in the hook");refresh();
    changedRow=true;check(!AxsCacheKeeperImageExecutable().header,"foreign main row refuses identity");changedRow=false;
    changedSlide=true;check(!AxsCacheKeeperImageExecutable().header,"changed slide refuses identity");changedSlide=false;
    changedName=true;check(!AxsCacheKeeperImageExecutable().header,"changed loader path refuses identity");changedName=false;
    changedDuringRead=true;check(!AxsCacheKeeperImageExecutable().header,"mid-read generation change revokes identity");
    puts("PASS: production executable count/generation and fixed-row rejection");return 0;
}
'''
    folder=Path(tempfile.mkdtemp(prefix='executable-view-',dir=ROOT/'tmp'))
    (folder/'view.c').write_text(fixture+product+tests,encoding='utf8')
    zig=ROOT/'tmp/release-evidence-toolchain/zig-windows-x86_64-0.13.0/zig.exe'
    compiler=[str(zig),'cc'] if zig.is_file() else ([shutil.which('clang')] if shutil.which('clang') else None)
    if not compiler:
        print('UNAVAILABLE: portable production executable view compiler missing; no tests ran.')
        return 2
    binary=folder/('view.exe' if sys.platform=='win32' else 'view')
    compiled=subprocess.run(compiler+['-std=c11','-fblocks','-Wall','-Wextra','-Werror',str(folder/'view.c'),'-o',str(binary)],capture_output=True,timeout=60)
    (folder/'compile.log').write_bytes(compiled.stdout+compiled.stderr)
    if compiled.returncode:
        print((compiled.stdout+compiled.stderr).decode(errors='replace'));return compiled.returncode
    result=subprocess.run([str(binary)],capture_output=True,timeout=10)
    (folder/'run.log').write_bytes(result.stdout+result.stderr)
    print((result.stdout+result.stderr).decode(errors='replace'),end='')
    print('Artifacts: '+str(folder))
    return result.returncode
if __name__=='__main__':raise SystemExit(run())
