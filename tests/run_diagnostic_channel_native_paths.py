"""Run real native path entrypoints and prove the exact old mapper baseline fails."""
import pathlib
import shutil
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
compiler = shutil.which("xcrun")
if sys.platform != "darwin" or not compiler:
    print("UNAVAILABLE: native channel path regression requires macOS and xcrun; no tests ran.")
    raise SystemExit(2)

baseline = "725e4d527a5f831e642c5752006ee20067954c25"
files = ("AxsCacheKeeperDiagnosticChannel.h", "AxsCacheKeeperDiagnosticChannelPrivate.h",
         "AxsCacheKeeperDiagnosticChannel.m")
test_source = r'''#import <Foundation/Foundation.h>
#import "AxsCacheKeeperDiagnosticChannelPrivate.h"
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

int main(int argc,char **argv) { @autoreleasepool {
    if (argc!=3) return 2;
    NSString *mode=[NSString stringWithUTF8String:argv[1]];
    NSString *fixture=[NSString stringWithUTF8String:argv[2]];
    NSFileManager *fm=NSFileManager.defaultManager;NSError *error=nil;
    if (![fm createDirectoryAtPath:fixture withIntermediateDirectories:YES attributes:nil error:&error]) return 2;
    BOOL kernel=[mode isEqual:@"kernel"],springBoard=[mode isEqual:@"springboard-anchor"];
    BOOL bundle=[mode isEqual:@"bundle"];
    NSString *anchor=springBoard ? @"/System/Library/CoreServices" : @"/Applications";
    char canonicalRoot[PATH_MAX],canonicalAnchor[PATH_MAX],kernelBytes[4096],canonicalKernel[PATH_MAX];
    if (!realpath(fixture.fileSystemRepresentation,canonicalRoot) || !realpath(anchor.fileSystemRepresentation,canonicalAnchor)) return 2;
    AxsCacheKeeperChannelFailure failure={0};
    NSString *kernelPath=nil,*expectedKernel=nil;
    if (kernel) {
        audit_token_t token;
        if (!axs_cachekeeper_channel_self_token(&token,&failure) ||
            !axs_cachekeeper_channel_token_path(&token,kernelBytes,&failure) || !realpath(kernelBytes,canonicalKernel)) return 2;
        kernelPath=[NSString stringWithUTF8String:kernelBytes];
        expectedKernel=[NSString stringWithUTF8String:canonicalKernel];
    }
    __block NSUInteger denied=0;
#ifdef AXS_CACHEKEEPER_NATIVE_PATH_BASELINE
    // This is a boundary tripwire, not a RootHide implementation or a successful path substitute.
    // Untargeted native observations stay byte-for-byte unchanged so each old branch is exercised.
    NSString *blockedInput=kernel ? kernelPath : (bundle ? fixture : anchor);
    NSString *(^mapper)(NSString *)=^NSString *(NSString *path) {
        if ([path isEqual:blockedInput]) {denied++;errno=ENOTSUP;return nil;}
        return path;
    };
#endif
    BOOL ok=NO;NSString *resolvedRoot=nil,*resolvedBase=nil;
    if (kernel) {
#ifdef AXS_CACHEKEEPER_NATIVE_PATH_BASELINE
        ok=axs_cachekeeper_channel_kernel_matches(expectedKernel,kernelPath,mapper,&failure);
#else
        ok=axs_cachekeeper_channel_kernel_matches(expectedKernel,kernelPath,&failure);
#endif
    } else {
        NSURL *url=[NSURL fileURLWithPath:fixture];
#ifdef AXS_CACHEKEEPER_NATIVE_PATH_BASELINE
        ok=axs_cachekeeper_channel_system_roots(springBoard,url,mapper,&resolvedRoot,&resolvedBase,&failure);
#else
        ok=axs_cachekeeper_channel_system_roots(springBoard,url,&resolvedRoot,&resolvedBase,&failure);
#endif
        ok=ok && [resolvedRoot isEqual:[NSString stringWithUTF8String:canonicalRoot]] &&
                 [resolvedBase isEqual:[NSString stringWithUTF8String:canonicalAnchor]];
    }
    AxsCacheKeeperChannelPathStage expectedStage=kernel ? AxsCacheKeeperChannelPathKernel :
        (bundle ? AxsCacheKeeperChannelPathBundle : AxsCacheKeeperChannelPathAnchor);
    if (!ok && denied==1 && failure.domain==AxsCacheKeeperChannelPOSIXError && failure.code==ENOTSUP && failure.pathStage==expectedStage) {
        fprintf(stderr,"FAIL: native-rootfs source reached bootstrap mapper: %s\n",argv[1]);return 1;
    }
    if (!ok || denied || failure.domain) {
        fprintf(stderr,"FAIL: native path result invalid: %s\n",argv[1]);return 2;
    }
    // The successful native path boundary must not authorize a temporary system-looking directory.
    if (!kernel && (axs_cachekeeper_channel_validate_bundle_root(resolvedRoot,resolvedBase,&failure) ||
                    failure.pathStage!=AxsCacheKeeperChannelPathAnchor)) return 2;
    if (kernel && (axs_cachekeeper_channel_kernel_matches(fixture,kernelPath,
#ifdef AXS_CACHEKEEPER_NATIVE_PATH_BASELINE
                    mapper,
#endif
                    &failure) || failure.pathStage!=AxsCacheKeeperChannelPathKernel)) return 2;
    printf("PASS: native channel path: %s\n",argv[1]);
} return 0; }
'''

(root / "tmp").mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="channel-native-paths-", dir=root / "tmp") as temp:
    output = pathlib.Path(temp)
    for legacy in (True, False):
        target = output / ("baseline" if legacy else "current")
        target.mkdir()
        for name in files:
            contents = subprocess.check_output(["git", "show", f"{baseline}:{name}"], cwd=root, timeout=15) if legacy else (root / name).read_bytes()
            (target / name).write_bytes(contents)
        (target / "main.m").write_text(test_source, encoding="utf-8")
        binary = target / "native-paths"
        flags = ["-DAXS_CACHEKEEPER_NATIVE_PATH_BASELINE=1"] if legacy else []
        subprocess.run([compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format",
                        "-I" + str(root / "tests" / "include"), "-framework", "Foundation", *flags,
                        str(target / "main.m"), str(target / "AxsCacheKeeperDiagnosticChannel.m"),
                        "-o", str(binary)], check=True, timeout=60)
        for mode in ("bundle", "preferences-anchor", "springboard-anchor", "kernel"):
            result = subprocess.run([str(binary), mode, str(target / ("fixture-" + mode + ".app"))],
                                    capture_output=True, text=True, timeout=60)
            if legacy:
                expected = "FAIL: native-rootfs source reached bootstrap mapper: " + mode
                if result.returncode != 1 or result.stderr.strip() != expected:
                    raise SystemExit(f"FAIL: old native path baseline missed {mode}: {result.returncode}\n{result.stdout}{result.stderr}")
                print("Verified native path baseline red:", mode)
            else:
                expected = "PASS: native channel path: " + mode
                if result.returncode != 0 or result.stdout.strip() != expected:
                    raise SystemExit(f"FAIL: current native path regression: {mode}: {result.returncode}\n{result.stdout}{result.stderr}")
                print(result.stdout.strip())
