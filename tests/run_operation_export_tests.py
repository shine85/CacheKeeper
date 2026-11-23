"""Real saved records prove shared report aliases, with an exact old-source RED."""
from pathlib import Path
import hashlib
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BASELINE = "9cb488d420e873d24f3677e2758be99fb6f8502c"
EXPECTED_RED = "FAIL: operation export: distinct process instances remain distinct across the report"


def run() -> int:
    compiler = shutil.which("xcrun")
    if sys.platform != "darwin" or not compiler:
        print("UNAVAILABLE: operation export RED/GREEN requires macOS and xcrun; no tests ran.")
        return 2
    baseline = subprocess.check_output(["git", "show", f"{BASELINE}:AxsCacheKeeperDiagnostics.m"], cwd=ROOT, timeout=15)
    if hashlib.sha256(baseline).hexdigest() != "3809ab0a257fc24efe5a7c49bc97428e0bc8bd7c934852b69fedb724f820696b":
        raise SystemExit("FAIL: operation export baseline source hash differs")
    (ROOT / "tmp").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="operation-export-", dir=ROOT / "tmp") as directory:
        output = Path(directory)
        old = output / "diagnostics-old.m"
        old.write_bytes(baseline)
        # Current diagnostics with the pre-1123 inventory isolates saved liveness
        # from the independent historical alias regression below.
        old_inventory = output / "inventory-193.m"
        old_inventory.write_bytes(subprocess.check_output(["git", "show", "2f19b98b500c51043e561544fafab25938f42719:AxsCacheKeeperStorageInventory.m"], cwd=ROOT, timeout=15))
        for role, inventory in (("pending-red", old_inventory),):
            binary = output / role
            sources = [ROOT / "tests/operation_export_tests.m", ROOT / "AxsCacheKeeperDiagnostics.m", ROOT / "AxsCacheKeeperOperationInfo.m",
                       ROOT / "AxsCacheKeeperInstallation.m", ROOT / "AxsCacheKeeperPDFInspection.m", inventory,
                       ROOT / "AxsCacheKeeperHostEvidence.m", ROOT / "AxsCacheKeeperInjectionConditions.m"]
            subprocess.run([compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format", "-I" + str(ROOT),
                            "-I" + str(ROOT / "tests/include"), "-framework", "Foundation", *map(str, sources), "-o", str(binary)], check=True, timeout=60)
            result = subprocess.run([str(binary), str(output / (role + "-fixture")), "pending"], capture_output=True, text=True, encoding="utf-8", timeout=60)
            if role == "pending-red":
                if result.returncode != 1 or result.stderr.strip() != "FAIL: operation export: saved pending receipt is not evidence of a live process":
                    raise SystemExit("FAIL: incorrect saved liveness RED\n" + result.stdout + result.stderr)
                print("PASS: 193 inventory reproduces exact saved liveness RED")
        for role, source in (("red", old), ("green", ROOT / "AxsCacheKeeperDiagnostics.m")):
            binary = output / role
            sources = [ROOT / "tests/operation_export_tests.m", source, ROOT / "AxsCacheKeeperOperationInfo.m",
                       ROOT / "AxsCacheKeeperInstallation.m", ROOT / "AxsCacheKeeperPDFInspection.m"]
            if role == "green":
                sources.append(ROOT / "AxsCacheKeeperStorageInventory.m")
                sources.append(ROOT / "AxsCacheKeeperHostEvidence.m")
                sources.append(ROOT / "AxsCacheKeeperInjectionConditions.m")
            subprocess.run([compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format", "-I" + str(ROOT),
                            "-I" + str(ROOT / "tests/include"), "-framework", "Foundation",
                            *map(str, sources), "-o", str(binary)], check=True, timeout=60)
            result = subprocess.run([str(binary), str(output / (role + "-fixture"))], capture_output=True,
                                    text=True, encoding="utf-8", timeout=60)
            if role == "red":
                if result.returncode != 1 or result.stderr.strip() != EXPECTED_RED:
                    raise SystemExit("FAIL: incorrect operation export behavior RED\n" + result.stdout + result.stderr)
                print("PASS: original source loses shared report aliases at the exact assertion")
            else:
                if result.returncode:
                    raise SystemExit("FAIL: operation export GREEN\n" + result.stdout + result.stderr)
                print(result.stdout, end="")
                result = subprocess.run([str(binary), str(output / "pending-green-fixture"), "pending"], capture_output=True, text=True, encoding="utf-8", timeout=60)
                if result.returncode:
                    raise SystemExit("FAIL: pending export GREEN\n" + result.stdout + result.stderr)
                print(result.stdout, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
