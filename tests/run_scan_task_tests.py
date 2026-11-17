"""Real filesystem continuation, cancellation, identity, fairness and persistence tests."""
import pathlib
import shutil
import subprocess
import sys
import tempfile


def main():
    compiler = shutil.which("xcrun")
    if sys.platform != "darwin" or not compiler:
        print("UNAVAILABLE: scan task tests require macOS and xcrun; no tests ran.")
        return 2
    root = pathlib.Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="scan-task-", dir=root / "tmp") as directory:
        binary = pathlib.Path(directory) / "scan-task-tests"
        sources = ["tests/scan_task_tests.m", "AxsCacheKeeperScanTask.m", "AxsCacheKeeperDirectories.m"]
        subprocess.run([compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format",
                        "-DAXS_CACHEKEEPER_SCAN_TESTING=1",
                        "-Werror=implicit-function-declaration", "-I" + str(root / "tests/include"),
                        "-framework", "Foundation", *[str(root / source) for source in sources],
                        "-o", str(binary)], check=True, timeout=60)
        subprocess.run([str(binary), directory], check=True, timeout=60)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
