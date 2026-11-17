"""Run saved inspection receipt export against fixed old source and current code."""
import hashlib
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
if sys.platform != "darwin" or not shutil.which("xcrun"):
    print("UNAVAILABLE: inspection export tests require macOS and xcrun; no tests ran.")
    raise SystemExit(2)

baseline = subprocess.check_output(["git", "show", "9cb488d420e873d24f3677e2758be99fb6f8502c:AxsCacheKeeperDiagnostics.m"], cwd=ROOT, timeout=60)
if hashlib.sha256(baseline).hexdigest() != "3809ab0a257fc24efe5a7c49bc97428e0bc8bd7c934852b69fedb724f820696b":
    raise SystemExit("FAIL: inspection export baseline source hash differs")
(ROOT / "tmp").mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="inspection-export-", dir=ROOT / "tmp") as directory:
    output = pathlib.Path(directory)
    old = output / "diagnostics-old.m"
    old.write_bytes(baseline)
    print("Pinned inspection export RED SHA256:", hashlib.sha256(baseline).hexdigest())
    for name, source in [("old", old), ("current", ROOT / "AxsCacheKeeperDiagnostics.m")]:
        binary = output / name
        subprocess.run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format", "-I" + str(ROOT),
                        "-I" + str(ROOT / "tests/include"), "-framework", "Foundation",
                        str(ROOT / "tests/inspection_export_tests.m"), str(source),
                        str(ROOT / "AxsCacheKeeperOperationInfo.m"),
                        *([str(ROOT / "AxsCacheKeeperStorageInventory.m"), str(ROOT / "AxsCacheKeeperHostEvidence.m")] if name == "current" else []),
                        str(ROOT / "AxsCacheKeeperInstallation.m"), str(ROOT / "AxsCacheKeeperPDFInspection.m"),
                        "-o", str(binary)], check=True, timeout=60)
        result = subprocess.run([str(binary), str(output / (name + "-fixture"))], capture_output=True, text=True, timeout=60)
        if name == "old":
            if result.returncode != 1 or result.stderr.strip() != "FAIL: inspection export: main and twin failures remain separate":
                raise SystemExit("FAIL: incorrect inspection export RED\n" + result.stdout + result.stderr)
            print("PASS: fixed old source reached the expected export assertion")
        else:
            print(result.stdout, end="")
            if result.returncode:
                raise SystemExit(result.stderr or "FAIL: current inspection export")
