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

ROOT = Path(__file__).resolve().parents[1]
GATE = "    if (legacyBase && !AxsCacheKeeperImageLegacyHelpersMatch(legacyBase)) return NO;"
EXPECTED_RED = "FAIL: image-runtime-source: helper change immediately restores original write"


def run() -> int:
    compiler = shutil.which("xcrun")
    if sys.platform != "darwin" or not compiler:
        print("UNAVAILABLE: image runtime helper regression requires macOS and xcrun; no tests ran.")
        return 2
    source = (ROOT / "AxsCacheKeeperImageCache.m").read_text(encoding="utf-8-sig")
    if source.count(GATE) != 1:
        raise SystemExit("FAIL: ambiguous runtime helper gate mutation")
    (ROOT / "tmp").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="image-runtime-source-", dir=ROOT / "tmp") as directory:
        for role in ("red", "green"):
            folder = Path(directory) / role
            folder.mkdir()
            candidate = source.replace(GATE, "") if role == "red" else source
            (folder / "AxsCacheKeeperImageCache.m").write_text(candidate, encoding="utf-8")
            print(f"INFO: image-runtime-source {role} SHA256 {hashlib.sha256(candidate.encode()).hexdigest()}", flush=True)
            binary = folder / "runtime-source-tests"
            subprocess.run([compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra",
                            "-DAXS_CACHEKEEPER_IMAGE_TESTING=1", "-I" + str(folder), "-I" + str(ROOT),
                            "-framework", "Foundation", str(ROOT / "tests/image_runtime_source_tests.m"),
                            str(ROOT / "AxsCacheKeeperCleanupRules.m"),
                            str(ROOT / "AxsCacheKeeperOperationInfo.m"), "-o", str(binary)],
                           cwd=ROOT, check=True, timeout=60)
            for scenario in ("fingerprint", "pinned"):
                result = subprocess.run([str(binary), scenario], capture_output=True, text=True, encoding="utf-8", timeout=30)
                if role == "red" and scenario == "fingerprint":
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
