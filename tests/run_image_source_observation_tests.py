"""Run actual Mach-O bytes, Objective-C metadata and privacy fixtures on macOS."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run() -> int:
    compiler = shutil.which("xcrun")
    if sys.platform != "darwin" or not compiler:
        print("UNAVAILABLE: image source observation fixtures require macOS/xcrun; no native tests ran.")
        return 2
    (ROOT / "tmp").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="image-observation-", dir=ROOT / "tmp") as temporary:
        folder = Path(temporary)
        binary = folder / "image-observation"
        flags = [compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format",
                 "-I" + str(ROOT), "-framework", "Foundation"]
        subprocess.run([*flags, str(ROOT / "tests/image_source_observation_tests.m"), "-o", str(binary)],
                       check=True, timeout=60)
        subprocess.run([str(binary)], check=True, timeout=30)
        # Recreate the observed integer-boxing regression without relaxing the schema.
        product = (ROOT / "AxsCacheKeeperImageRuntimeSource.h").read_text(encoding="utf-8-sig")
        test = (ROOT / "tests/image_source_observation_tests.m").read_text(encoding="utf-8-sig")
        for name in ("AxsCacheKeeperImageRuntimeSource.h", "AxsCacheKeeperInstallationImageObservation.h"):
            test = test.replace('"../' + name + '"', '"' + name + '"')
        fixture = folder / "runtime-source-tests.m"
        fixture.write_text(test, encoding="utf-8")
        for name, before, after, count in (
            ("class-boolean", 'owner ? @YES : @NO', '@(owner!=Nil)', 2),
            ("original-boolean", 'originals[i] ? @YES : @NO', '@(originals[i]!=NULL)', 1),
        ):
            if product.count(before) != count:
                raise RuntimeError("Ambiguous image observation mutation: " + name)
            (folder / "AxsCacheKeeperImageRuntimeSource.h").write_text(product.replace(before, after), encoding="utf-8")
            executable = folder / name
            subprocess.run([*flags, "-I" + str(folder), str(fixture), "-o", str(executable)], check=True, timeout=60)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=30)
            failures = [line for line in (result.stdout + result.stderr).splitlines() if line.startswith("FAIL:")]
            if result.returncode != 1 or failures != ["FAIL: image source observation: production runtime schema is closed"]:
                raise RuntimeError("Image observation mutation did not hit its schema assertion: " + name + "\n" + result.stdout + result.stderr)
            print("PASS: image runtime integer-boxing RED: " + name, flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
