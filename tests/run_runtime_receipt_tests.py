"""Exercise receipt privacy and runtime provenance on real Foundation, including the old headers."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
compiler = shutil.which("xcrun")
if sys.platform != "darwin" or not compiler:
    print("UNAVAILABLE: runtime receipt tests require macOS and xcrun; no tests ran.")
    raise SystemExit(2)

(root / "tmp").mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="runtime-receipts-", dir=root / "tmp") as directory:
    output = Path(directory)
    baseline = output / "baseline"
    baseline.mkdir()
    for name in ("AxsCacheKeeperImageCacheStatus.h", "AxsCacheKeeperWebKitStatus.h", "AxsCacheKeeperInstallationDetail.h"):
        old = subprocess.run(["git", "show", "d823af8:" + name], cwd=root, capture_output=True, check=True, timeout=60)
        (baseline / name).write_bytes(old.stdout)
    for name, headers in (("baseline", baseline), ("fixed", root)):
        executable = output / name / "receipt-test" if name == "baseline" else output / "receipt-test"
        subprocess.run([compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format", "-framework", "Foundation",
                        *( ["-DAXS_CACHEKEEPER_RECEIPT_BASELINE=1"] if name == "baseline" else []),
                        "-I" + str(headers), str(root / "tests/runtime_receipt_tests.m"),
                        str(root / "AxsCacheKeeperOperationInfo.m"), "-o", str(executable)],
                       check=True, timeout=60)
        result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=60)
        if name == "baseline":
            if result.returncode != 1 or result.stderr.strip() != "FAIL: current runtime build survives image receipt":
                raise SystemExit("FAIL: old headers did not reproduce the exact runtime-evidence loss\n" + result.stdout + result.stderr)
            print("PASS: original headers reproduce missing runtime evidence")
        else:
            print(result.stdout, end="")
            if result.returncode:
                raise SystemExit(result.stderr or result.returncode)
