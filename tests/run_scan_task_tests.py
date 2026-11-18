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
    (root / "tmp").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="scan-task-", dir=root / "tmp") as directory:
        flags = [compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format",
                        "-DAXS_CACHEKEEPER_SCAN_TESTING=1",
                        "-Werror=implicit-function-declaration", "-I" + str(root / "tests/include"),
                        "-framework", "Foundation"]
        for name in ("scan_task", "scan_history"):
            binary = pathlib.Path(directory) / (name + "-tests")
            fixture = pathlib.Path(directory) / name
            fixture.mkdir()
            sources = [f"tests/{name}_tests.m", "AxsCacheKeeperScanTask.m", "AxsCacheKeeperDirectories.m"]
            subprocess.run([*flags, *[str(root / source) for source in sources], "-o", str(binary)], check=True, timeout=60)
            subprocess.run([str(binary), str(fixture)], check=True, timeout=60)
        # Compile isolated single-regression variants; a compiler failure or crash
        # must never count as the expected behavioral RED.
        product = (root / "AxsCacheKeeperScanTask.m").read_text(encoding="utf-8")
        variants = (
            ("xml", "format:NSPropertyListBinaryFormat_v1_0", "format:NSPropertyListXMLFormat_v1_0",
             "history writes compact binary plist"),
            ("decode", "if(data && [data isEqualToData:_historyBytes])", "if(NO && data && [data isEqualToData:_historyBytes])",
             "unchanged saved history decoded once"),
            ("cancel", 'else if([current[@"cancel"] boolValue] || [task.state isEqual:@"cancelled"])',
             'else if(NO && ([current[@"cancel"] boolValue] || [task.state isEqual:@"cancelled"]))',
             "mid-advance cancellation never counts as completion"),
        )
        for name, old, new, message in variants:
            if product.count(old) != 1:
                raise RuntimeError(f"RED mutation anchor changed: {name}")
            source = pathlib.Path(directory) / (name + ".m")
            source.write_text(product.replace(old, new), encoding="utf-8")
            binary = pathlib.Path(directory) / (name + "-red")
            fixture = pathlib.Path(directory) / (name + "-fixture")
            fixture.mkdir()
            subprocess.run([*flags, "-I" + str(root), str(root / "tests/scan_history_tests.m"),
                            str(source), str(root / "AxsCacheKeeperDirectories.m"), "-o", str(binary)],
                           check=True, timeout=60)
            result = subprocess.run([str(binary), str(fixture)], capture_output=True, text=True, timeout=60)
            print(result.stdout, end="")
            print(result.stderr, end="", file=sys.stderr)
            expected = "FAIL: scan history: " + message
            failures = [line for line in result.stderr.splitlines() if line.startswith("FAIL:")]
            if result.returncode != 1 or failures != [expected]:
                raise RuntimeError(f"RED {name} must fail only its named assertion; exit={result.returncode}")
            print(f"Verified scan history RED: {name}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
