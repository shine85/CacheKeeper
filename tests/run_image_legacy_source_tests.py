"""Exercise real Mach VM reads and SHA256 using synthetic bytes, never Baidu code."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HEADER = "AxsCacheKeeperImageLegacySource.h"
MUTATIONS = (
    ("digest", 'if (memcmp(digest,window->sha256,sizeof(digest))) return AxsCacheKeeperImageLegacyResult(stage,"digest",method,helper);',
     "if (0) return AxsCacheKeeperImageLegacyComplete();", "byte mutation is refused"),
    ("section", 'if (!AxsCacheKeeperImageLegacyContains(layout->sectionOffset,layout->sectionSize,window->offset,window->length)) return AxsCacheKeeperImageLegacyResult(stage,"section",method,helper);',
     "if (0) return AxsCacheKeeperImageLegacyComplete();", "section crossing is refused"),
    ("slot", 'if (implementations[10]) return AxsCacheKeeperImageLegacyResult("slots","unexpected",11,0);',
     "if (0) return AxsCacheKeeperImageLegacyComplete();", "unexpected eleventh method is refused"),
    ("class-source", "return imageName && mainName && !strcmp(imageName,mainName);",
     "return imageName && mainName;", "foreign class source is refused"),
    ("helper-abi", 'if (memcmp(actualEncoding,encoding,length+1)) return AxsCacheKeeperImageLegacyResult("helperABI","encoding",0,helper);',
     "if (0) return AxsCacheKeeperImageLegacyComplete();", "helper ABI mismatch is refused"),
    ("helper-own", 'if (!own) return AxsCacheKeeperImageLegacyResult("helperOwner","inherited",0,helper);',
     "if (0) return AxsCacheKeeperImageLegacyComplete();", "inherited helper method is refused"),
)


def run() -> int:
    compiler = shutil.which("xcrun")
    if sys.platform != "darwin" or not compiler:
        print("UNAVAILABLE: image legacy source native tests require macOS and xcrun; no tests ran.")
        return 2
    source = (ROOT / HEADER).read_text(encoding="utf-8")
    (ROOT / "tmp").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="image-legacy-source-", dir=ROOT / "tmp") as directory:
        temporary = Path(directory)
        for role, old, new, expected in (*MUTATIONS, ("green", "", "", "")):
            folder = temporary / role
            folder.mkdir()
            if old and source.count(old) != 1:
                raise SystemExit(f"FAIL: {role} mutation does not identify one production gate")
            (folder / HEADER).write_text(source.replace(old, new, 1) if old else source, encoding="utf-8")
            binary = folder / "source-tests"
            subprocess.run([compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra",
                            "-I" + str(folder), "-I" + str(ROOT), "-framework", "Foundation",
                            str(ROOT / "tests/image_legacy_source_tests.m"), "-o", str(binary)],
                           cwd=ROOT, check=True, timeout=60)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
            if old:
                if result.returncode != 1 or result.stdout.strip() or result.stderr.strip() != f"FAIL: image-legacy-source: {expected}":
                    raise SystemExit(f"FAIL: {role} must fail its exact assertion, got {result.returncode}\n{result.stdout}{result.stderr}")
                print(f"PASS: image-legacy-source {role} mutation RED: {expected}")
            elif result.returncode != 0 or result.stderr.strip() or result.stdout.strip() != "PASS: image-legacy-source native memory boundaries and fingerprints":
                raise SystemExit(f"FAIL: native legacy source checks returned {result.returncode}\n{result.stdout}{result.stderr}")
            else:
                print(result.stdout.strip())
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
