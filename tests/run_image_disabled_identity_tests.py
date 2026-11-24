"""Fixed released engine RED and actual current hook accounting with disabled Runtime context."""
from pathlib import Path
import hashlib
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BASELINE = "1ba72221c74b7616c11fd7650a7424152ec8f548"
RED = "FAIL: image-runtime-source: disabled real-context empty identity retains its own original-call evidence"


def main():
    compiler = shutil.which("xcrun")
    if sys.platform != "darwin" or not compiler:
        print("UNAVAILABLE: disabled Runtime identity needs macOS Foundation and xcrun; no behavior ran.")
        return 2
    (ROOT / "tmp").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="image-disabled-identity-", dir=ROOT / "tmp") as directory:
        output = Path(directory)
        helper = output / "autorelease.o"
        subprocess.run([compiler, "clang", "-fno-objc-arc", "-c", str(ROOT / "tests/image_runtime_autorelease_fixture.m"), "-o", str(helper)], check=True, timeout=60)
        for role in ("red", "green"):
            folder = output / role
            folder.mkdir()
            name = "AxsCacheKeeperImageCache.m"
            source = subprocess.check_output(["git", "show", f"{BASELINE}:{name}"], cwd=ROOT, timeout=15) if role == "red" else (ROOT / name).read_bytes()
            (folder / name).write_bytes(source)
            print(f"INFO: disabled-identity {role} producer SHA256 {hashlib.sha256(source).hexdigest()}", flush=True)
            binary = folder / "disabled-tests"
            subprocess.run([compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format",
                "-DAXS_CACHEKEEPER_IMAGE_TESTING=1", "-DAXS_CACHEKEEPER_WRITE_OBSERVATION_TESTING=1", "-DAXS_CACHEKEEPER_DISABLED_IDENTITY_TESTING=1",
                "-I"+str(folder), "-I"+str(ROOT / "tests/image_runtime_context_platform"), "-I"+str(ROOT), "-framework", "Foundation", str(ROOT / "tests/image_runtime_source_tests.m"),
                str(ROOT / "tests/image_write_observation_status_tests.m"), str(ROOT / "AxsCacheKeeperCleanupRules.m"),
                str(ROOT / "AxsCacheKeeperOperationInfo.m"), str(ROOT / "AxsCacheKeeperImageCoordinator.m"), str(helper), "-o", str(binary)], check=True, timeout=60)
            result = subprocess.run([str(binary), "write-observation"], capture_output=True, text=True, timeout=60)
            if role == "red":
                if result.returncode != 1 or result.stdout.strip() or result.stderr.strip() != RED:
                    raise RuntimeError("incorrect fixed disabled identity RED\n"+result.stdout+result.stderr)
                print("PASS: fixed 200 engine reaches exact disabled identity RED", flush=True)
            elif result.returncode or result.stderr.strip() or result.stdout.strip() != "PASS: image-runtime-source fixture write-observation":
                raise RuntimeError("disabled identity GREEN failed\n"+result.stdout+result.stderr)
            else:
                print(result.stdout, end="", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
