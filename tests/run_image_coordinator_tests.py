"""Actual coordinator lifecycle, with UIKit token acquisition as the sole platform boundary."""
from pathlib import Path
import hashlib
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
GATE = "NSUInteger task=_begin ? _begin(^{"
RED = "FAIL: image-coordinator: a stale zero eligible receipt cannot deny preparation time"


def main():
    compiler = shutil.which("xcrun")
    if sys.platform != "darwin" or not compiler:
        print("UNAVAILABLE: image coordinator requires macOS Foundation and xcrun; no behavior ran.")
        return 2
    source = (ROOT / "AxsCacheKeeperImageCoordinator.m").read_text(encoding="utf-8-sig")
    if source.count(GATE) != 1:
        raise RuntimeError("ambiguous stale eligibility control")
    (ROOT / "tmp").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="image-coordinator-", dir=ROOT / "tmp") as directory:
        for role in ("red", "green"):
            folder = Path(directory) / role
            folder.mkdir()
            candidate = source.replace(GATE, 'NSUInteger task=[_cache.receipt[@"eligible"] unsignedIntegerValue] && _begin ? _begin(^{') if role == "red" else source
            path = folder / "AxsCacheKeeperImageCoordinator.m"
            path.write_text(candidate, encoding="utf-8")
            print(f"INFO: image-coordinator {role} SHA256 {hashlib.sha256(candidate.encode()).hexdigest()}", flush=True)
            binary = folder / "coordinator"
            subprocess.run([compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format",
                "-I"+str(ROOT), "-framework", "Foundation", str(path), str(ROOT / "tests/image_coordinator_tests.m"),
                "-o", str(binary)], check=True, timeout=60)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
            if role == "red":
                if result.returncode != 1 or result.stdout.strip() or result.stderr.strip() != RED:
                    raise RuntimeError("incorrect stale eligibility RED\n"+result.stdout+result.stderr)
                print("PASS: old eligibility decision reaches exact delayed-preparation RED", flush=True)
            elif result.returncode or result.stderr.strip() or result.stdout.strip() != "PASS: image-coordinator preparation and lifecycle task ownership":
                raise RuntimeError("coordinator GREEN failed\n"+result.stdout+result.stderr)
            else:
                print(result.stdout, end="", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
