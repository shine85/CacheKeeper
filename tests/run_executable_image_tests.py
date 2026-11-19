"""Exercise the real reader, bundle executable selection and loader-table guards."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run() -> int:
    compiler = shutil.which("xcrun")
    if sys.platform != "darwin" or not compiler:
        print("UNAVAILABLE: executable image tests require macOS/xcrun; no native tests ran.")
        return 2
    (ROOT / "tmp").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="executable-image-", dir=ROOT / "tmp") as directory:
        folder = Path(directory)
        source = (ROOT / "AxsCacheKeeperImageLegacySource.h").read_text(encoding="utf-8-sig")
        old = "AxsCacheKeeperExecutableImageRow value=row(index);"
        assert source.count(old) == 1, "ambiguous loader-order regression"
        stale = "generation!=atomic_load(&axs_cachekeeper_image_observation_generation)"
        assert source.count(stale) == 3, "ambiguous generation revocation regression"
        for role in ("red", "stale", "green"):
            target = folder / role
            target.mkdir()
            product = source.replace(old, "AxsCacheKeeperExecutableImageRow value=row(0);") if role == "red" else source.replace(stale, "NO") if role == "stale" else source
            (target / "AxsCacheKeeperImageLegacySource.h").write_text(product, encoding="utf-8")
            binary = target / "executable-image"
            subprocess.run([compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format",
                            "-I" + str(target), "-I" + str(ROOT), "-framework", "Foundation",
                            str(ROOT / "tests/executable_image_tests.m"), "-o", str(binary)], check=True, timeout=60)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
            if role != "green":
                assertion = "wrapper before executable selects the bundle executable and its own slide" if role == "red" else "generation change revokes cached identity until explicit discovery refresh"
                expected = "FAIL: executable-image: " + assertion
                if result.returncode != 1 or result.stderr.strip() != expected or result.stdout.strip():
                    raise RuntimeError("loader-order RED missed its assertion: " + result.stdout + result.stderr)
                print("PASS: executable selection RED: " + role)
            elif result.returncode or result.stderr.strip() or result.stdout.strip() != "PASS: bundle executable selection and loader boundaries":
                raise RuntimeError("executable image GREEN failed: " + result.stdout + result.stderr)
            else:
                print(result.stdout.strip())
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
