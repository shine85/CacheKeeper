"""Real saved receipt to production Diagnostics to JSON observation regression."""
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
if sys.platform != "darwin" or not shutil.which("xcrun"):
    print("UNAVAILABLE: observation export tests require macOS and xcrun; no tests ran.")
    raise SystemExit(2)

(ROOT / "tmp").mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="observation-export-", dir=ROOT / "tmp") as directory:
    output = pathlib.Path(directory)
    binary = output / "observation-export"
    sources = ["tests/observation_export_tests.m", "AxsCacheKeeperDiagnostics.m",
               "AxsCacheKeeperStorageInventory.m", "AxsCacheKeeperOperationInfo.m",
               "AxsCacheKeeperInstallation.m", "AxsCacheKeeperPDFInspection.m"]
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format", "-I" + str(ROOT),
                    "-I" + str(ROOT / "tests/include"), "-framework", "Foundation",
                    *[str(ROOT / source) for source in sources], "-o", str(binary)], check=True, timeout=60)
    subprocess.run([str(binary), str(output / "fixture")], check=True, timeout=60)
