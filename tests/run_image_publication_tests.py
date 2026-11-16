"""Run production hook publication RED/GREEN on an Objective-C runtime fixture.

This deliberately is not an SDWebImage SDK test. The independent UIKit suite
continues to exercise the real pinned SDK revisions.
"""
from pathlib import Path
import hashlib
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BASELINE = "d823af847a17231e245211817e4caa6e3c627993"
EXPECTED_RED = "FAIL: image-publication: unverified publication is refused"
SCENARIOS = ("clean", "getter", "original", "installed")


def run() -> int:
    compiler = shutil.which("xcrun")
    if sys.platform != "darwin" or not compiler:
        print("UNAVAILABLE: image publication runtime RED/GREEN requires macOS and xcrun; no tests ran.")
        return 2
    (ROOT / "tmp").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="image-publication-", dir=ROOT / "tmp") as directory:
        folder = Path(directory)
        for role in ("red", "green"):
            target = folder / role
            target.mkdir()
            for name in ("AxsCacheKeeperImageCache.m", "AxsCacheKeeperImageCache.h", "AxsCacheKeeperImageCacheStatus.h"):
                if role == "red":
                    source = subprocess.check_output(["git", "show", f"{BASELINE}:{name}"], cwd=ROOT, timeout=15)
                else:
                    source = (ROOT / name).read_bytes()
                (target / name).write_bytes(source)
            digest = hashlib.sha256((target / "AxsCacheKeeperImageCache.m").read_bytes()).hexdigest()
            print(f"INFO: image-publication {role} source SHA256 {digest}", flush=True)
            binary = target / "publication-tests"
            subprocess.run([compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra",
                            "-DAXS_CACHEKEEPER_IMAGE_TESTING=1", "-I" + str(target), "-I" + str(ROOT),
                            "-framework", "Foundation", str(ROOT / "tests/image_publication_tests.m"),
                            str(ROOT / "AxsCacheKeeperCleanupRules.m"),
                            str(ROOT / "AxsCacheKeeperOperationInfo.m"), "-o", str(binary)],
                           cwd=ROOT, check=True, timeout=60)
            for scenario in SCENARIOS:
                result = subprocess.run([str(binary), scenario], capture_output=True, text=True,
                                        encoding="utf-8", timeout=30)
                if role == "red" and scenario != "clean":
                    if result.returncode != 1 or result.stderr.strip() != EXPECTED_RED or result.stdout.strip():
                        raise SystemExit(f"FAIL: expected original-source {scenario} assertion; got {result.returncode}\n{result.stdout}{result.stderr}")
                    print(f"PASS: image-publication original source RED {scenario}: {EXPECTED_RED}")
                else:
                    expected = f"PASS: image-publication runtime fixture {scenario}"
                    if result.returncode != 0 or result.stdout.strip() != expected or result.stderr.strip():
                        raise SystemExit(f"FAIL: image-publication {role}/{scenario} returned {result.returncode}\n{result.stdout}{result.stderr}")
                    print(f"{result.stdout.strip()} ({role})")
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
