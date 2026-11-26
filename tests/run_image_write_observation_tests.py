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
STATUS_BASELINE = "2b450ec6a2a584bee2e46ffdc6bdeddce3132924"
EXPECTED = "FAIL: image-runtime-source: actual nonnil writers publish separate attempted and blocked evidence"
STATUS_RED = "FAIL: image-write-status: producer truncation is a Foundation boolean at zero and after eviction"
PAYLOAD_BASELINE = "5cab9ce8115b6e6f73c33de6e5e339f66c157833"
PAYLOAD_RED = "FAIL: image-runtime-source: actual hooks distinguish empty and nonempty payload decisions"
SOURCE_HASHES = {
    BASELINE: "4a2ea7001e780da0483816eca0c17b5381f4045c2410f8172c024147fcdb96db",
    PAYLOAD_BASELINE: "578ba43325601b6a9c2af4b3d3d4b97661cbc88e3a09c9fd041648bd65e986e7",
    STATUS_BASELINE: "4c0d52e9da4f6a029bdefde98ff8da2dcd21fe5e88ece8264130030608e94605",
}


def fixed_source(revision, name):
    source = subprocess.check_output(["git", "show", f"{revision}:{name}"], cwd=ROOT, timeout=15)
    if hashlib.sha256(source).hexdigest() != SOURCE_HASHES[revision]:
        raise RuntimeError("write observation baseline source hash mismatch")
    return source


def core(compiler, output):
    binary = output / ("writer-core.exe" if sys.platform == "win32" else "writer-core")
    command = [compiler, "clang"] if Path(compiler).stem == "xcrun" else [compiler, "cc"] if Path(compiler).stem == "zig" else [compiler]
    subprocess.run([*command, "-std=c11", "-Wall", "-Wextra", "-Werror", "-I"+str(ROOT),
        str(ROOT / "tests/image_write_observation_core_tests.c"), "-o", str(binary)], check=True, timeout=60)
    subprocess.run([str(binary)], check=True, timeout=30)


def status_cases(compiler, output):
    for role in ("status-red", "status-green"):
        folder = output / role
        folder.mkdir()
        name = "AxsCacheKeeperImageWriteObservation.h"
        source = fixed_source(STATUS_BASELINE, name) if role == "status-red" else (ROOT / name).read_bytes()
        (folder / name).write_bytes(source)
        # Keep the including header beside the chosen producer; otherwise its
        # quoted import silently selects the current root header in the RED.
        (folder / "AxsCacheKeeperImageCacheStatus.h").write_bytes((ROOT / "AxsCacheKeeperImageCacheStatus.h").read_bytes())
        print(f"INFO: write-observation {role} header SHA256 {hashlib.sha256(source).hexdigest()}", flush=True)
        binary = folder / "status-tests"
        subprocess.run([compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format", "-Werror=implicit-function-declaration",
            "-DAXS_CACHEKEEPER_WRITE_STATUS_STANDALONE=1", "-I"+str(folder), "-I"+str(ROOT), "-framework", "Foundation",
            str(ROOT / "tests/image_write_observation_status_tests.m"), str(ROOT / "AxsCacheKeeperOperationInfo.m"),
            "-o", str(binary)], check=True, timeout=60)
        result = subprocess.run([str(binary)], capture_output=True, text=True, encoding="utf-8", timeout=30)
        if role == "status-red":
            if result.returncode != 1 or result.stdout.strip() or result.stderr.strip() != STATUS_RED:
                raise RuntimeError("incorrect fixed producer boolean RED\n"+result.stdout+result.stderr)
            print("PASS: fixed 199 producer reaches exact Foundation boolean RED", flush=True)
        elif result.returncode or result.stderr.strip() or result.stdout.strip() != "PASS: image-write-status producer and strict Foundation roundtrip":
            raise RuntimeError("write observation status GREEN failed\n"+result.stdout+result.stderr)
        else:
            print(result.stdout, end="", flush=True)


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
        status_cases(compiler, output)
        helper = output / "autorelease.o"
        subprocess.run([compiler, "clang", "-fno-objc-arc", "-c", str(ROOT / "tests/image_runtime_autorelease_fixture.m"), "-o", str(helper)], check=True, timeout=60)
        for role in ("red", "payload-red", "payload-green", "green"):
            folder = output / role
            folder.mkdir()
            baseline = BASELINE if role == "red" else PAYLOAD_BASELINE if role == "payload-red" else None
            source = fixed_source(baseline, "AxsCacheKeeperImageCache.m") if baseline else (ROOT / "AxsCacheKeeperImageCache.m").read_bytes()
            (folder / "AxsCacheKeeperImageCache.m").write_bytes(source)
            print(f"INFO: write-observation {role} producer SHA256 {hashlib.sha256(source).hexdigest()}", flush=True)
            binary = folder / "writer-tests"
            subprocess.run([compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format", "-Werror=implicit-function-declaration",
                "-DAXS_CACHEKEEPER_IMAGE_TESTING=1", "-DAXS_CACHEKEEPER_WRITE_OBSERVATION_TESTING=1",
                *(["-DAXS_CACHEKEEPER_WRITE_OBSERVATION_OLD=1"] if role == "red" else []),
                *(["-DAXS_CACHEKEEPER_WRITE_PAYLOAD_TESTING=1"] if role.startswith("payload-") else []),
                "-I"+str(folder), "-I"+str(ROOT), "-framework", "Foundation",
                str(ROOT / "tests/image_runtime_source_tests.m"), str(ROOT / "AxsCacheKeeperCleanupRules.m"),
                str(ROOT / "tests/image_write_observation_status_tests.m"),
                str(ROOT / "AxsCacheKeeperOperationInfo.m"), str(helper), "-o", str(binary)], check=True, timeout=60)
            result = subprocess.run([str(binary), "write-observation"], capture_output=True, text=True, encoding="utf-8", timeout=60)
            if role in ("red", "payload-red"):
                expected = EXPECTED if role == "red" else PAYLOAD_RED
                if result.returncode != 1 or result.stdout.strip() or result.stderr.strip() != expected:
                    raise RuntimeError("incorrect write observation RED\n"+result.stdout+result.stderr)
                print("PASS: fixed producer reaches exact writer evidence RED: " + expected, flush=True)
            elif result.returncode or result.stderr.strip() or result.stdout.strip() != "PASS: image-runtime-source fixture write-observation":
                raise RuntimeError("write observation GREEN failed\n"+result.stdout+result.stderr)
            else:
                print(result.stdout, end="", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
