"""Verify the pre-remediation reporter drops the new local path failure detail."""
import pathlib
import shutil
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
if sys.platform != "darwin" or not shutil.which("xcrun"):
    print("UNAVAILABLE: channel path baseline requires macOS and xcrun; no tests ran.")
    raise SystemExit(2)
baseline = "636c532d354e9c5644841eaae91f9eced7fa1739"
(root / "tmp").mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="channel-path-red-", dir=root / "tmp") as temp:
    target = pathlib.Path(temp)
    for name in ("AxsCacheKeeperDiagnostics.h", "AxsCacheKeeperDiagnostics.m",
                 "AxsCacheKeeperPolicy.h", "AxsCacheKeeperSearchDiagnostics.h"):
        (target / name).write_bytes(subprocess.check_output(
            ["git", "show", f"{baseline}:{name}"], cwd=root, timeout=15))
    (target / "main.m").write_text('''#import <Foundation/Foundation.h>
#import "AxsCacheKeeperDiagnostics.h"
int main(void) { @autoreleasepool {
    NSString *folder=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    AxsCacheKeeperDiagnostics *session=[[AxsCacheKeeperDiagnostics alloc] initWithFolder:folder];
    NSDictionary *status=@{@"protocolVersion":@1,@"state":@"unavailable",@"stage":@"systemURL",
        @"errorDomain":@"posix",@"errorCode":@2,@"errorOrigin":@"local",@"localPathStage":@"bundlePath",
        @"selfIdentity":@"unavailable",@"peerIdentity":@"notObserved",@"serverRegister":@"notObserved"};
    NSDictionary *report=[session reportWithApps:@[] environment:@{@"diagnosticChannel":status}];
    if (![report[@"diagnosticChannel"] isEqual:status]) {
        fprintf(stderr,"FAIL: local path detail lost at diagnostics boundary\\n");return 1;
    }
} return 0; }
''', encoding="utf-8")
    binary = target / "red-test"
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-framework", "Foundation",
                    str(target / "main.m"), str(target / "AxsCacheKeeperDiagnostics.m"),
                    "-o", str(binary)], check=True, timeout=60)
    result = subprocess.run([str(binary)], capture_output=True, text=True, encoding="utf-8", timeout=60)
    expected = "FAIL: local path detail lost at diagnostics boundary"
    if result.returncode != 1 or expected not in result.stderr:
        raise SystemExit(f"Expected channel path projection failure; got {result.returncode}: {result.stderr}")
    print("Verified channel path projection baseline red:", result.stderr.strip())
