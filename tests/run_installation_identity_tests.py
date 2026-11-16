"""Run the exact released source RED, then current real Foundation/POSIX identity tests."""
import hashlib
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
BASELINE = "004b6c004ea14cb698c593deecb18df1543aae1f"
BASELINE_SOURCE_SHA256 = "11643125cb77c57df6ff02ed9c50d4a7103890389d3640f6c1849547eb88b0bc"
EXPECTED_RED = "FAIL: installation-identity: open mismatch exposes nonzero field differences"


def run() -> int:
    compiler = shutil.which("xcrun")
    if sys.platform != "darwin" or not compiler:
        print("UNAVAILABLE: installation identity RED/GREEN requires macOS and xcrun; no tests ran.")
        return 2
    (ROOT / "tmp").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="installation-identity-", dir=ROOT / "tmp") as temporary:
        folder = pathlib.Path(temporary)
        for role in ("red", "green"):
            target = folder / role
            (target / "tests").mkdir(parents=True)
            names = ["AxsCacheKeeperInstallation.m", "AxsCacheKeeperInstallation.h", "AxsCacheKeeperInstallationDetail.h"]
            if role == "green":
                names.append("AxsCacheKeeperInstallationCheck.h")
            for name in names:
                if role == "red":
                    source = subprocess.check_output(["git", "show", f"{BASELINE}:{name}"], cwd=ROOT, timeout=15)
                else:
                    source = (ROOT / name).read_bytes()
                (target / name).write_bytes(source)
            if role == "red":
                source = (target / "AxsCacheKeeperInstallation.m").read_text(encoding="utf-8-sig")
                actual = hashlib.sha256(source.encode("utf-8")).hexdigest()
                if actual != BASELINE_SOURCE_SHA256:
                    raise SystemExit("FAIL: original installation baseline source hash does not match the reviewed release")
            test = target / "tests" / "installation_identity_tests.m"
            test.write_bytes((ROOT / "tests" / "installation_identity_tests.m").read_bytes())
            binary = target / "identity-tests"
            flags = [compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-I" + str(ROOT), "-framework", "Foundation"]
            if role == "red":
                flags.append("-DAXS_CACHEKEEPER_INSTALLATION_IDENTITY_RED=1")
            subprocess.run([*flags, str(test), "-o", str(binary)], check=True, timeout=60)
            result = subprocess.run([str(binary), str(target / "fixtures")], capture_output=True, text=True,
                                    encoding="utf-8", timeout=60)
            if role == "red":
                if result.returncode != 1 or result.stderr.count("FAIL:") != 1 or EXPECTED_RED not in result.stderr:
                    raise SystemExit(f"FAIL: expected original-source identity assertion; got {result.returncode}\n{result.stdout}{result.stderr}")
                print("PASS: exact installation source baseline RED:", result.stderr.strip())
            else:
                if result.returncode != 0:
                    raise SystemExit(f"FAIL: installation identity GREEN returned {result.returncode}\n{result.stdout}{result.stderr}")
                if "PASS: installation identity actual refusal, bounded resample and strict schema" not in result.stdout:
                    raise SystemExit("FAIL: installation identity GREEN did not complete its full test set")
                print(result.stdout.strip())
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
