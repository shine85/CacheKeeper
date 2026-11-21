"""Exercise production runtime helper gates with explicit synthetic source boundaries.

The independent legacy-source and UIKit suites exercise production fingerprint
primitives and real SDKs respectively.
"""
from pathlib import Path
import hashlib
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
GATE = "    if (legacyBase && !AxsCacheKeeperImageLegacyHelpersMatch(legacyBase)) return NO;"
EXPECTED_RED = "FAIL: image-runtime-source: helper change immediately restores original write"
REFRESH_GATE = "NSString *otherRelative=relativePaths[otherIndex]==NSNull.null ? nil : relativePaths[otherIndex];"
REFRESH_RED = "FAIL: image-runtime-source: 64-owner refresh resolves home at most once plus 64 FD identity probes"
ADMISSION_GATE = "        AxsCacheKeeperImageAdmissionRecord(&_admission,reason);"
ADMISSION_RED = "FAIL: image-runtime-source: early returns retain prior live admission and exact counters"


def run() -> int:
    compiler = shutil.which("xcrun")
    if sys.platform != "darwin" or not compiler:
        print("UNAVAILABLE: image runtime helper regression requires macOS and xcrun; no tests ran.")
        return 2
    # run_native_tests.py owns a 240s wrapper. Compile/test maxima are individually
    # capped by the remaining 225s work budget, leaving room for wrapper reporting.
    deadline = time.monotonic() + 225
    def remaining(maximum):
        seconds = deadline - time.monotonic()
        if seconds <= 0:
            raise SystemExit("FAIL: image-runtime-source aggregate budget exhausted")
        return min(maximum, seconds)
    source = (ROOT / "AxsCacheKeeperImageCache.m").read_text(encoding="utf-8-sig")
    if source.count(GATE) != 1 or source.count(REFRESH_GATE) != 1 or source.count(ADMISSION_GATE) != 1:
        raise SystemExit("FAIL: ambiguous runtime helper gate mutation")
    workspace = ROOT / "tmp/feedback-1792"
    workspace.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="image-runtime-source-", dir=workspace) as directory:
        for role in ("red", "green"):
            folder = Path(directory) / role
            folder.mkdir()
            candidate = source.replace(GATE, "") if role == "red" else source
            if role == "red":
                candidate = candidate.replace(REFRESH_GATE, 'NSString *otherRelative=AxsCacheKeeperImageRelative(context[@"home"],other.path);')
                candidate = candidate.replace(ADMISSION_GATE, "        (void)reason;")
            (folder / "AxsCacheKeeperImageCache.m").write_text(candidate, encoding="utf-8")
            print(f"INFO: image-runtime-source {role} SHA256 {hashlib.sha256(candidate.encode()).hexdigest()}", flush=True)
            binary = folder / "runtime-source-tests"
            subprocess.run([compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format",
                            "-DAXS_CACHEKEEPER_IMAGE_TESTING=1", "-I" + str(folder), "-I" + str(ROOT),
                            "-framework", "Foundation", str(ROOT / "tests/image_runtime_source_tests.m"),
                            str(ROOT / "AxsCacheKeeperCleanupRules.m"),
                            str(ROOT / "AxsCacheKeeperOperationInfo.m"), "-o", str(binary)],
                           cwd=ROOT, check=True, timeout=remaining(60))
            for scenario in ("fingerprint", "fingerprint-shifted", "pinned", "refresh", "sample", "admission"):
                result = subprocess.run([str(binary), scenario], capture_output=True, text=True, encoding="utf-8", timeout=remaining(30))
                if role == "red" and scenario == "admission":
                    if result.returncode != 1 or result.stderr.strip() != ADMISSION_RED or result.stdout.strip():
                        raise SystemExit(f"FAIL: admission RED missed its exact early-return assertion\n{result.stdout}{result.stderr}")
                    print("PASS: admission RED at actual initializer observation", flush=True)
                elif role == "red" and scenario == "refresh":
                    if result.returncode != 1 or result.stderr.strip() != REFRESH_RED or result.stdout.strip():
                        raise SystemExit(f"FAIL: refresh amplification RED missed its exact counting assertion\n{result.stdout}{result.stderr}")
                    print("PASS: refresh amplification RED at actual 64-owner worker", flush=True)
                elif role == "red" and scenario in ("fingerprint", "fingerprint-shifted"):
                    if result.returncode != 1 or result.stderr.strip() != EXPECTED_RED or result.stdout.strip():
                        raise SystemExit(f"FAIL: runtime helper RED did not reach its write assertion\n{result.stdout}{result.stderr}")
                    print("PASS: runtime helper mutation RED at the actual write hook", flush=True)
                else:
                    expected = f"PASS: image-runtime-source fixture {scenario}"
                    if result.returncode != 0 or result.stdout.strip() != expected or result.stderr.strip():
                        raise SystemExit(f"FAIL: image-runtime-source {role}/{scenario} returned {result.returncode}\n{result.stdout}{result.stderr}")
                    print(f"{expected} ({role})", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
