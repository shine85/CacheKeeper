"""Run exact old-source RED and real saved-plist all-app inventory GREEN on macOS."""
import hashlib
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
BASELINE = "9cb488d420e873d24f3677e2758be99fb6f8502c"
HASHES = {
    "AxsCacheKeeperDiagnostics.m": "3809ab0a257fc24efe5a7c49bc97428e0bc8bd7c934852b69fedb724f820696b",
    "AxsCacheKeeperInstallation.m": "6965bee22e5ad583b984305494a7a0a4417259b31c6024560b3c240983022162",
}
EXPECTED_RED = "FAIL: storage inventory: all registrations and configured-only entries survive saved report export"


def normalized_stderr(text: str) -> str:
    # macOS may warn that the Foundation test substitute shares the private
    # LSApplicationWorkspace class name with CoreServices. It is runtime noise;
    # the exact exit code and behavioral assertion remain strict below.
    lines = [line for line in text.splitlines() if "Class LSApplicationWorkspace is implemented in both" not in line]
    return "\n".join(lines).strip()


def run() -> int:
    compiler = shutil.which("xcrun")
    if sys.platform != "darwin" or not compiler:
        print("UNAVAILABLE: all-app storage inventory RED/GREEN requires macOS and xcrun; no tests ran.")
        return 2
    (ROOT / "tmp").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="storage-inventory-", dir=ROOT / "tmp") as temporary:
        output = pathlib.Path(temporary)
        for role in ("red", "green"):
            sources = [ROOT / "tests/storage_inventory_tests.m", ROOT / "AxsCacheKeeperPDFInspection.m",
                       ROOT / "AxsCacheKeeperOperationInfo.m"]
            if role == "red":
                for name, expected in HASHES.items():
                    data = subprocess.check_output(["git", "show", f"{BASELINE}:{name}"], cwd=ROOT, timeout=15)
                    if hashlib.sha256(data).hexdigest() != expected:
                        raise SystemExit("FAIL: all-app inventory old source hash mismatch: " + name)
                    path = output / name
                    path.write_bytes(data)
                    sources.append(path)
            else:
                # Test translation unit imports the production storage .m to instrument only
                # inline policy call boundaries. Never link that same implementation twice.
                sources += [ROOT / name for name in HASHES]
            binary = output / role
            flags = [compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-I" + str(ROOT),
                     "-I" + str(ROOT / "tests/include"), "-framework", "Foundation"]
            if role == "red":
                flags.append("-DAXS_CACHEKEEPER_STORAGE_INVENTORY_RED=1")
            else:
                flags.append("-DAXS_CACHEKEEPER_STORAGE_INVENTORY_TESTING=1")
            # Compilation/link errors and timeout cannot satisfy the expected behavior RED.
            subprocess.run([*flags, *map(str, sources), "-o", str(binary)], check=True, timeout=60)
            fixtures = output / (role + "-fixtures")
            fixtures.mkdir(parents=True, exist_ok=True)
            result = subprocess.run([str(binary), str(fixtures)], capture_output=True,
                                    text=True, encoding="utf-8", timeout=180)
            if role == "red":
                if result.returncode != 1 or normalized_stderr(result.stderr) != EXPECTED_RED:
                    raise SystemExit("FAIL: incorrect all-app inventory behavior RED\n" + result.stdout + result.stderr)
                print("PASS: exact old-source all-app inventory RED:", result.stderr.strip())
            else:
                if result.returncode:
                    raise SystemExit("FAIL: all-app inventory GREEN\n" + result.stdout + result.stderr)
                print(result.stdout, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
