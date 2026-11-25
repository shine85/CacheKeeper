"""Real Foundation schema migration plus a fixed pre-migration behavioral RED."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BASELINE = "deb1c97563fe272bb63b24bd84989f1c9fdfeb6f"


def main():
    compiler = shutil.which("xcrun")
    if sys.platform != "darwin" or not compiler:
        print("UNAVAILABLE: Gurd status migration requires macOS Foundation and xcrun; no behavior or RED ran.")
        return 2
    git = shutil.which("git")
    if not git:
        raise RuntimeError("fixed Gurd status migration RED requires git")
    base = ROOT / "tmp"
    base.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="gurd-status-", dir=base) as temporary:
        folder = Path(temporary)
        flags = [compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format",
                 "-Werror=implicit-function-declaration", "-I" + str(ROOT), "-framework", "Foundation"]
        source = str(ROOT / "tests/gurd_status_tests.m")
        binary = folder / "gurd-status-tests"
        subprocess.run(flags + [source, "-o", str(binary)], check=True, timeout=60)
        fixture = folder / "fixture"
        fixture.mkdir()
        subprocess.run([str(binary), str(fixture)], check=True, timeout=60)
        old_header = folder / "fixed211-gurd-status.h"
        old_header.write_bytes(subprocess.run(
            [git, "show", f"{BASELINE}:AxsCacheKeeperGurdStatus.h"], cwd=ROOT,
            capture_output=True, check=True, timeout=60).stdout)
        red_binary = folder / "fixed211-gurd-status-red"
        subprocess.run(flags + ["-DAXS_CACHEKEEPER_GURD_MIGRATION_RED=1",
            '-DAXS_CACHEKEEPER_GURD_STATUS_HEADER="' + old_header.as_posix() + '"',
            source, "-o", str(red_binary)], check=True, timeout=60)
        result = subprocess.run([str(red_binary)], capture_output=True, text=True, timeout=60)
        expected = "FAIL: gurd-status: schema1 historical records migrate without losing scope provenance"
        if result.returncode != 1 or result.stdout.strip() or result.stderr.strip() != expected:
            raise RuntimeError("fixed 211 schema migration RED must fail only its exact assertion\n" + result.stdout + result.stderr)
        print("PASS: fixed 211 Gurd schema migration reaches exact behavioral RED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
