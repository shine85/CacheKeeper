"""Fixed-production RED and current Rules/Sweep with real Foundation/POSIX files."""
import hashlib
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
BASELINE = "56d4b0f9cf5d4386f6eb411771b43f61ccc23e04"
PRODUCT_FILES = ("AxsCacheKeeperPolicy.h", "AxsCacheKeeperCleanupRules.m", "Baseline.m", "AxsCacheKeeperFileAccess.h")
EXPECTED = {
    "read": "FAIL: platform-cache: platform purpose does not require content readability",
    "pread": "FAIL: platform-cache: standard sweep performs no content pread",
}

def main():
    compiler = shutil.which("xcrun")
    if sys.platform != "darwin" or not compiler:
        print("UNAVAILABLE: platform cache Rules/Sweep RED/GREEN requires macOS Foundation and xcrun; no native tests ran.")
        return 2
    (ROOT / "tmp").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="platform-cache-", dir=ROOT / "tmp") as directory:
        output = pathlib.Path(directory)
        evidence_object = output / "release-evidence.o"
        subprocess.run([compiler, "clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-c",
            str(ROOT / "AxsCacheKeeperReleaseEvidence.c"), "-o", str(evidence_object)], check=True, timeout=60)
        for role in ("red", "green"):
            folder = output / role
            folder.mkdir()
            for name in PRODUCT_FILES:
                data = subprocess.check_output(["git", "show", f"{BASELINE}:{name}"], cwd=ROOT, timeout=15) if role == "red" else (ROOT / name).read_bytes()
                (folder / name).write_bytes(data)
                print(f"INFO: platform-cache {role} {name} SHA256 {hashlib.sha256(data).hexdigest()}", flush=True)
            # FileAccess must share the selected source directory with Policy,
            # otherwise an old Sweep imports both old and current inline headers.
            # Include old policy from the same fixed source tree. Instrument only
            # the POSIX read boundary; wrappers never replace Rules or Sweep.
            wrapper = folder / "sweep-wrapper.m"
            wrapper.write_text('#include <unistd.h>\n'
                'extern ssize_t axs_cachekeeper_platform_test_pread(int,void *,size_t,off_t);\n'
                '#define pread axs_cachekeeper_platform_test_pread\n'
                '#import "Baseline.m"\n#undef pread\n', encoding="utf-8")
            binary = folder / "platform-tests"
            subprocess.run([compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format",
                "-Werror=implicit-function-declaration", "-I" + str(folder), "-I" + str(ROOT),
                "-I" + str(ROOT / "tests/include"), "-framework", "Foundation",
                str(ROOT / "tests/platform_cache_policy_tests.m"), str(ROOT / "tests/app_retention_tests.m"),
                str(wrapper), str(folder / "AxsCacheKeeperCleanupRules.m"),
                str(ROOT / "AxsCacheKeeperCleanupJob.m"),
                str(ROOT / "AxsCacheKeeperDependencySnapshot.m"), str(evidence_object),
                "-o", str(binary)], check=True, timeout=60)
            for scenario in EXPECTED if role == "red" else ("all",):
                result = subprocess.run([str(binary), scenario, str(folder / (scenario + "-fixtures"))],
                    capture_output=True, text=True, encoding="utf-8", timeout=60)
                if role == "red":
                    if result.returncode != 1 or result.stdout.strip() or result.stderr.strip() != EXPECTED[scenario]:
                        raise SystemExit(f"FAIL: platform cache {scenario} did not hit its exact fixed-source assertion\n" + result.stdout + result.stderr)
                    print("PASS: fixed-source platform cache RED:", scenario, result.stderr.strip(), flush=True)
                else:
                    if result.returncode or result.stderr.strip() or "PASS: platform-cache all" not in result.stdout.splitlines():
                        raise SystemExit("FAIL: current platform cache GREEN\n" + result.stdout + result.stderr)
                    print(result.stdout, end="", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
