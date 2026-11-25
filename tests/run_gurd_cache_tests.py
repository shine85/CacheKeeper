"""Actual Gurd production engine and FD-relative cursor; host/platform boundaries only."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
ROOT=Path(__file__).resolve().parents[1]
def main():
    contract=subprocess.run([sys.executable,str(ROOT/"tests/test_gurd_scope_projection_contract.py")],cwd=ROOT,timeout=30)
    if contract.returncode:return contract.returncode
    cc=shutil.which("xcrun")
    if sys.platform!="darwin" or not cc:
        print("UNAVAILABLE: Gurd Objective-C behavior requires macOS Foundation and xcrun; no behavior ran.")
        return 2
    base=ROOT/"tmp/implementation-201"
    base.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="gurd-tests-",dir=base) as directory:
        folder=Path(directory);fixture=folder/"fixture";fixture.mkdir()
        binary=folder/"gurd-tests"
        subprocess.run([cc,"clang","-fobjc-arc","-fblocks","-Wall","-Wextra","-Werror=format",
            "-Werror=implicit-function-declaration",'-DAXS_CACHEKEEPER_PACKAGE_VERSION="0.0.0-0.0"',"-DAXS_CACHEKEEPER_GURD_TESTING=1","-DAXS_CACHEKEEPER_SCAN_TESTING=1","-I"+str(ROOT),"-I"+str(ROOT/"tests/include"),
            "-framework","Foundation",*[str(ROOT/p) for p in ("AxsCacheKeeperGurdCache.m","AxsCacheKeeperGurdSource.m",
            "AxsCacheKeeperScanTask.m","AxsCacheKeeperDirectories.m","AxsCacheKeeperOperationInfo.m","tests/gurd_cache_tests.m")],"-o",str(binary)],check=True,timeout=60)
        subprocess.run([str(binary),str(fixture)],check=True,timeout=60)
        git=shutil.which("git")
        if not git:raise RuntimeError("fixed 201 symlink RED requires git")
        fixed=subprocess.run([git,"show","b176c581b44812a94c3a901674ddf7e1d7a1be36:AxsCacheKeeperGurdCache.m"],cwd=ROOT,capture_output=True,check=True,timeout=60).stdout
        old=folder/"fixed201-gurd-cache.m";old.write_bytes(fixed)
        isolated=folder/"gurd-symlink-green";isolated_fixture=folder/"symlink-green-fixture";isolated_fixture.mkdir()
        subprocess.run([cc,"clang","-fobjc-arc","-fblocks","-Wall","-Wextra","-Werror=format",
            "-Werror=implicit-function-declaration",'-DAXS_CACHEKEEPER_PACKAGE_VERSION="0.0.0-0.0"',"-DAXS_CACHEKEEPER_GURD_TESTING=1","-DAXS_CACHEKEEPER_SCAN_TESTING=1",
            "-DAXS_CACHEKEEPER_GURD_FIXED201_SYMLINK=1","-I"+str(ROOT),"-I"+str(ROOT/"tests/include"),"-framework","Foundation",
            *[str(ROOT/p) for p in ("AxsCacheKeeperGurdCache.m","AxsCacheKeeperGurdSource.m","AxsCacheKeeperScanTask.m",
                "AxsCacheKeeperDirectories.m","AxsCacheKeeperOperationInfo.m","tests/gurd_cache_tests.m")],"-o",str(isolated)],check=True,timeout=60)
        subprocess.run([str(isolated),str(isolated_fixture)],check=True,timeout=60)
        fixed_binary=folder/"fixed201-gurd-cache-red";fixed_fixture=folder/"fixed201-symlink-red-fixture";fixed_fixture.mkdir()
        subprocess.run([cc,"clang","-fobjc-arc","-fblocks","-Wall","-Wextra","-Werror=format",
            "-Werror=implicit-function-declaration",'-DAXS_CACHEKEEPER_PACKAGE_VERSION="0.0.0-0.0"',"-DAXS_CACHEKEEPER_GURD_TESTING=1","-DAXS_CACHEKEEPER_SCAN_TESTING=1",
            "-DAXS_CACHEKEEPER_GURD_FIXED201_SYMLINK=1",
            "-I"+str(ROOT),"-I"+str(ROOT/"tests/include"),"-framework","Foundation",str(old),
            *[str(ROOT/p) for p in ("AxsCacheKeeperGurdSource.m","AxsCacheKeeperScanTask.m","AxsCacheKeeperDirectories.m","AxsCacheKeeperOperationInfo.m","tests/gurd_cache_tests.m")],"-o",str(fixed_binary)],check=True,timeout=60)
        result=subprocess.run([str(fixed_binary),str(fixed_fixture)],capture_output=True,text=True,timeout=60)
        if result.returncode!=1 or result.stdout.strip() or result.stderr.strip()!="FAIL: gurd: real descendant symlink fails sample and blocks call":
            raise RuntimeError("fixed 201 symlink RED must fail only its exact assertion\n"+result.stdout+result.stderr)
        print("PASS: fixed 201 Gurd symlink reaches exact behavioral RED")
        product=(ROOT/"AxsCacheKeeperGurdCache.m").read_text(encoding="utf-8")
        anchor='if(axs_cachekeeper_paths_overlap(relative,excluded)) return @"excludedOverlap";'
        if product.count(anchor)!=1:raise RuntimeError("ambiguous Gurd exclusion negative control")
        mutation=folder/"gurd-exclusion-red.m"
        mutation.write_text(product.replace(anchor,'if(NO && axs_cachekeeper_paths_overlap(relative,excluded)) return @"excludedOverlap";'),encoding="utf-8")
        red=folder/"gurd-red";red_fixture=folder/"red-fixture";red_fixture.mkdir()
        subprocess.run([cc,"clang","-fobjc-arc","-fblocks","-Wall","-Wextra","-Werror=format",
            "-Werror=implicit-function-declaration",'-DAXS_CACHEKEEPER_PACKAGE_VERSION="0.0.0-0.0"',"-DAXS_CACHEKEEPER_GURD_TESTING=1","-DAXS_CACHEKEEPER_SCAN_TESTING=1",
            "-I"+str(ROOT),"-I"+str(ROOT/"tests/include"),"-framework","Foundation",str(mutation),
            *[str(ROOT/p) for p in ("AxsCacheKeeperGurdSource.m","AxsCacheKeeperScanTask.m","AxsCacheKeeperDirectories.m","AxsCacheKeeperOperationInfo.m","tests/gurd_cache_tests.m")],"-o",str(red)],check=True,timeout=60)
        result=subprocess.run([str(red),str(red_fixture)],capture_output=True,text=True,timeout=60)
        if result.returncode!=1 or result.stdout.strip() or result.stderr.strip()!="FAIL: gurd: overlapping descendant exclusion blocks whole host call":
            raise RuntimeError("Gurd exclusion RED must fail only its exact assertion\n"+result.stdout+result.stderr)
        print("PASS: Gurd exclusion mutation reaches exact behavioral RED")
    return 0
if __name__=="__main__":raise SystemExit(main())
