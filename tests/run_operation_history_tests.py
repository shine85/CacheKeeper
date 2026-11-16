"""Real Foundation/WebKit history and pinned behavioral regression; no device access."""
import pathlib
import shutil
import subprocess
import sys
import time

root = pathlib.Path(__file__).resolve().parents[1]
compiler = shutil.which("xcrun")
if sys.platform != "darwin" or not compiler:
    print("UNAVAILABLE: operation history tests require macOS and xcrun; no tests ran.")
    raise SystemExit(2)
out = root / "tmp" / ("operation-history-" + str(time.time_ns()))
out.mkdir(parents=True)
flags = [compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format", "-I" + str(root),
         "-framework", "Foundation", "-framework", "WebKit"]
pinned = out / "pinned154.m"
pinned.write_bytes(subprocess.run(["git", "show", "9cb488d420e873d24f3677e2758be99fb6f8502c:AxsCacheKeeperWebKitCache.m"],
                                 check=True, capture_output=True, timeout=30).stdout)
for label, source in (("pinned154", pinned), ("current", root / "AxsCacheKeeperWebKitCache.m")):
    exe = out / label
    subprocess.run([*flags, str(source), str(root / "AxsCacheKeeperOperationInfo.m"),
                    str(root / "tests/operation_late_callback_tests.m"), "-o", str(exe)], check=True, timeout=60)
    result = subprocess.run([str(exe)], capture_output=True, text=True, timeout=30)
    if label == "pinned154":
        expected = "FAIL: operation-history: late callback does not replace disabled current state"
        if result.returncode != 1 or result.stderr.strip() != expected:
            raise SystemExit("FAIL: pinned154 did not hit exact behavioral RED\n" + result.stdout + result.stderr)
        print("PASS: pinned154 reproduces exact late callback state regression")
    else:
        print(result.stdout, end="")
        if result.returncode:
            raise SystemExit(result.stderr or result.returncode)
history = out / "history"
subprocess.run([*flags, str(root / "AxsCacheKeeperOperationInfo.m"),
                str(root / "tests/operation_marker_peer.m"), str(root / "tests/operation_history_tests.m"),
                "-o", str(history)], check=True, timeout=60)
subprocess.run([str(history), str(out / "roundtrip.plist")], check=True, timeout=30)
