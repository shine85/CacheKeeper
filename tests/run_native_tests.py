"""在 macOS 编译运行真实 Foundation/POSIX 回归，所有产物放入项目 tmp。"""
import pathlib
import shutil
import subprocess
import sys
import time

root = pathlib.Path(__file__).resolve().parents[1]
compiler = shutil.which("xcrun")
if sys.platform != "darwin" or not compiler:
    print("UNAVAILABLE: native regression tests require macOS and xcrun; no tests ran.")
    raise SystemExit(2)
output = root / "tmp" / ("cache-tests-" + str(time.time_ns()))
output.mkdir(parents=True)
try:
    subprocess.run([compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra",
                    "-I" + str(root / "tests" / "include"), "-framework", "Foundation",
                    str(root / "tests" / "cache_control_tests.m"), str(root / "Baseline.m"),
                    str(root / "Permissions.m"), str(root / "AxsCacheKeeperNetworkCache.m"),
                    str(root / "AxsCacheKeeperDirectories.m"),
                    "-o", str(output / "cache-tests")], check=True, timeout=60)
    subprocess.run([str(output / "cache-tests"), str(output / "fixtures")], check=True, timeout=60)
finally:
    if output.resolve().parent == (root / "tmp").resolve():
        shutil.rmtree(output)
