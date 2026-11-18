"""Exercise real owned installation files and root FDs, never a device or application."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run() -> int:
    compiler = shutil.which("xcrun")
    if sys.platform != "darwin" or not compiler:
        print("UNAVAILABLE: installation image/root identity fixtures require macOS/xcrun; no native tests ran.")
        return 2
    (ROOT / "tmp").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="image-resource-identity-", dir=ROOT / "tmp") as directory:
        binary = Path(directory) / "identity"
        fixtures = Path(directory) / "fixtures"
        fixtures.mkdir()
        subprocess.run([compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format",
                        "-I" + str(ROOT), "-framework", "Foundation", str(ROOT / "tests/image_resource_identity_tests.m"),
                        "-o", str(binary)], check=True, timeout=60)
        subprocess.run([str(binary), str(fixtures)], check=True, timeout=60)
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
