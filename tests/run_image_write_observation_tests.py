"""Production writer hooks: exact fixed-producer RED and current epoch accounting."""
import hashlib
import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BASELINE = "56d4b0f9cf5d4386f6eb411771b43f61ccc23e04"
EXPECTED = "FAIL: image-runtime-source: actual nonnil writers publish separate attempted and blocked evidence"


def core(compiler, output):
    binary = output / ("writer-core.exe" if sys.platform == "win32" else "writer-core")
    command = [compiler, "clang"] if Path(compiler).stem == "xcrun" else [compiler, "cc"] if Path(compiler).stem == "zig" else [compiler]
    subprocess.run([*command, "-std=c11", "-Wall", "-Wextra", "-Werror", "-I"+str(ROOT),
        str(ROOT / "tests/image_write_observation_core_tests.c"), "-o", str(binary)], check=True, timeout=60)
    subprocess.run([str(binary)], check=True, timeout=30)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--core-only", action="store_true")
    parser.add_argument("--cc")
    args = parser.parse_args()
    compiler = shutil.which("xcrun")
    if args.core_only:
        compiler = args.cc or shutil.which("clang") or shutil.which("cc")
        if not compiler:
            print("UNAVAILABLE: writer core requires a C compiler.")
            return 2
        (ROOT / "tmp").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="image-write-core-", dir=ROOT / "tmp") as temporary:
            core(compiler, Path(temporary))
        return 0
    if sys.platform != "darwin" or not compiler:
        print("UNAVAILABLE: image write observation needs macOS Foundation and xcrun; no behavior ran.")
        return 2
    (ROOT / "tmp").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="image-write-observation-", dir=ROOT / "tmp") as temporary:
        output = Path(temporary)
        core(compiler, output)
        helper = output / "autorelease.o"
        subprocess.run([compiler, "clang", "-fno-objc-arc", "-c", str(ROOT / "tests/image_runtime_autorelease_fixture.m"), "-o", str(helper)], check=True, timeout=60)
        for role in ("red", "green"):
            folder = output / role
            folder.mkdir()
            source = subprocess.check_output(["git", "show", f"{BASELINE}:AxsCacheKeeperImageCache.m"], cwd=ROOT, timeout=15) if role == "red" else (ROOT / "AxsCacheKeeperImageCache.m").read_bytes()
            (folder / "AxsCacheKeeperImageCache.m").write_bytes(source)
            print(f"INFO: write-observation {role} producer SHA256 {hashlib.sha256(source).hexdigest()}", flush=True)
            binary = folder / "writer-tests"
            subprocess.run([compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format", "-Werror=implicit-function-declaration",
                "-DAXS_CACHEKEEPER_IMAGE_TESTING=1", "-DAXS_CACHEKEEPER_WRITE_OBSERVATION_TESTING=1",
                *(["-DAXS_CACHEKEEPER_WRITE_OBSERVATION_OLD=1"] if role == "red" else []),
                "-I"+str(folder), "-I"+str(ROOT), "-framework", "Foundation",
                str(ROOT / "tests/image_runtime_source_tests.m"), str(ROOT / "AxsCacheKeeperCleanupRules.m"),
                str(ROOT / "AxsCacheKeeperOperationInfo.m"), str(helper), "-o", str(binary)], check=True, timeout=60)
            result = subprocess.run([str(binary), "write-observation"], capture_output=True, text=True, encoding="utf-8", timeout=60)
            if role == "red":
                if result.returncode != 1 or result.stdout.strip() or result.stderr.strip() != EXPECTED:
                    raise RuntimeError("incorrect write observation RED\n"+result.stdout+result.stderr)
                print("PASS: fixed producer reaches exact missing writer evidence RED", flush=True)
            elif result.returncode or result.stderr.strip() or result.stdout.strip() != "PASS: image-runtime-source fixture write-observation":
                raise RuntimeError("write observation GREEN failed\n"+result.stdout+result.stderr)
            else:
                print(result.stdout, end="", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
