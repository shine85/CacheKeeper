"""Compile/run the actual portable evidence core; preserve artifacts and precise RED logs."""
import argparse
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cc", help="C compiler executable; Zig automatically receives cc")
    parser.add_argument("--source", type=pathlib.Path, default=ROOT / "AxsCacheKeeperReleaseEvidence.c")
    parser.add_argument("--expect-red", help="Exact expected FAIL message, without prefix")
    args = parser.parse_args()
    compiler = args.cc or shutil.which("clang") or shutil.which("cc")
    if not compiler:
        print("UNAVAILABLE: a C compiler is required; no tests ran.")
        return 2
    (ROOT / "tmp").mkdir(exist_ok=True)
    output = pathlib.Path(tempfile.mkdtemp(prefix="release-evidence-", dir=ROOT / "tmp"))
    binary = output / ("evidence.exe" if sys.platform == "win32" else "evidence")
    command = [compiler]
    if pathlib.Path(compiler).stem == "zig":
        command += ["cc"]
    command += ["-std=c11", "-Wall", "-Wextra", "-Werror", "-I" + str(ROOT),
                str(args.source), str(ROOT / "tests" / "release_evidence_tests.c"), "-o", str(binary)]
    built = subprocess.run(command, capture_output=True, text=True, timeout=60)
    (output / "build.log").write_text(built.stdout + built.stderr, encoding="utf-8")
    print("Artifacts:", output)
    if built.returncode:
        print(built.stdout + built.stderr)
        return 1
    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=60)
    (output / "run.log").write_text(result.stdout + result.stderr, encoding="utf-8")
    if args.expect_red:
        expected = "FAIL: release-evidence: " + args.expect_red
        if result.returncode != 1 or result.stderr.strip() != expected:
            print("FAIL: negative control did not reach its exact assertion\n" + result.stdout + result.stderr)
            return 1
        print("PASS: exact RED:", args.expect_red)
        return 0
    print(result.stdout + result.stderr, end="")
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
