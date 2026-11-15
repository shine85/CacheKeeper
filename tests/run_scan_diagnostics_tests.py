"""Run real directory discovery and diagnostic-export regressions in separate processes."""
import argparse
import pathlib
import shutil
import subprocess
import sys
import tempfile


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expect-red", action="store_true", help="Require both named behavioral failures on the unfixed product")
    args = parser.parse_args()
    compiler = shutil.which("xcrun")
    if sys.platform != "darwin" or not compiler:
        print("UNAVAILABLE: scan diagnostics tests require macOS and xcrun; no tests ran.")
        return 2

    root = pathlib.Path(__file__).resolve().parents[1]
    (root / "tmp").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="scan-diagnostics-tests-", dir=root / "tmp") as temporary:
        output = pathlib.Path(temporary)
        binary = output / "scan-diagnostics-tests"
        sources = [
            root / "tests" / "scan_diagnostics_tests.m",
            root / "AxsCacheKeeperDirectories.m",
            root / "AxsCacheKeeperDiagnostics.m",
            root / "AxsCacheKeeperInstallation.m",
            root / "AxsCacheKeeperPDFInspection.m",
        ]
        # Link current production implementations. A compiler/linker failure is never a passing RED.
        subprocess.run(
            [compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra",
             "-I" + str(root / "tests" / "include"), "-framework", "Foundation",
             *map(str, sources), "-o", str(binary)],
            check=True, timeout=60,
        )
        cases = {
            "missing-home": "FAIL: scan diagnostics: missing primary container must return ENOENT",
            "export": "FAIL: scan diagnostics: valid scanDiagnostics must survive real report export",
        }
        failed = False
        for mode, expected in cases.items():
            result = subprocess.run(
                [str(binary), mode, str(output / (mode + "-fixture"))],
                capture_output=True, text=True, encoding="utf-8", timeout=60,
            )
            if result.stdout:
                print(result.stdout, end="")
            if result.stderr:
                print(result.stderr, end="", file=sys.stderr)
            if args.expect_red:
                valid = result.returncode == 1 and result.stderr.strip() == expected
                if valid:
                    print("Verified scan diagnostics RED:", mode)
                else:
                    print(f"FAIL: expected named {mode} behavioral failure; exit={result.returncode}", file=sys.stderr)
            else:
                valid = result.returncode == 0
                if not valid:
                    print(f"FAIL: {mode} regression exited {result.returncode}", file=sys.stderr)
            failed |= not valid
        return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
