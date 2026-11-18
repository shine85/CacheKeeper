"""Run actual Mach-O bytes, Objective-C metadata and privacy fixtures on macOS."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run() -> int:
    compiler = shutil.which("xcrun")
    if sys.platform != "darwin" or not compiler:
        print("UNAVAILABLE: image source observation fixtures require macOS/xcrun; no native tests ran.")
        return 2
    (ROOT / "tmp").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="image-observation-", dir=ROOT / "tmp") as temporary:
        binary = Path(temporary) / "image-observation"
        subprocess.run([compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format",
                        "-I" + str(ROOT), "-framework", "Foundation", str(ROOT / "tests/image_source_observation_tests.m"),
                        "-o", str(binary)], check=True, timeout=60)
        subprocess.run([str(binary)], check=True, timeout=30)
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
