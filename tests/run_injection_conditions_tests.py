"""Run real Foundation projection/file tests and exact behavioral mutation RED checks."""
from __future__ import annotations
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]


def main():
    if sys.platform != "darwin" or not shutil.which("xcrun"):
        print("UNAVAILABLE: injection conditions require macOS Foundation/xcrun; no native tests ran.")
        return 2
    (ROOT / "tmp").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="injection-conditions-", dir=ROOT / "tmp") as directory:
        out = pathlib.Path(directory)
        source = ROOT / "AxsCacheKeeperInjectionConditions.m"
        flags = ["xcrun", "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format",
                 "-I" + str(ROOT), "-I" + str(out / "include"), "-I" + str(ROOT / "tests/include"), "-framework", "Foundation"]
        (out / "include").mkdir()
        (out / "include/roothide.h").write_text(
            "#import <Foundation/Foundation.h>\nextern NSString *axs_cachekeeper_test_injection_path(NSString *);\n"
            "#define jbroot(path) axs_cachekeeper_test_injection_path(path)\n", encoding="utf-8")
        dependencies = [ROOT / name for name in ("AxsCacheKeeperDiagnostics.m", "AxsCacheKeeperHostEvidence.m",
            "AxsCacheKeeperStorageInventory.m", "AxsCacheKeeperOperationInfo.m", "AxsCacheKeeperInstallation.m",
            "AxsCacheKeeperPDFInspection.m")]
        def compile_run(product, binary, mode, fixture):
            subprocess.run([*flags, str(ROOT / "tests/injection_conditions_tests.m"), str(product), *map(str, dependencies),
                            "-o", str(binary)], check=True, timeout=60)
            return subprocess.run([str(binary), mode, str(fixture)], text=True, capture_output=True, timeout=60)
        binary = out / "green"
        result = compile_run(source, binary, "projection", out / "projection")
        print(result.stdout, end="")
        if result.returncode:
            raise RuntimeError(result.stderr)
        result = subprocess.run([str(binary), "files", str(out / "files")], text=True, capture_output=True, timeout=60)
        print(result.stdout, end="")
        if result.returncode:
            raise RuntimeError(result.stderr)
        result = subprocess.run([str(binary), "export", str(out / "export")], text=True, capture_output=True, timeout=60)
        print(result.stdout, end="")
        if result.returncode:
            raise RuntimeError(result.stderr)
        original = source.read_text(encoding="utf-8")
        mutations = [
            ('if (allowed && ![allowed containsObject:@"CacheKeeper"])',
             'if (allowed.count && ![allowed containsObject:@"CacheKeeper"])',
             "valid empty allow list must deny CacheKeeper"),
            ('BOOL overwrite=[app[@"overwriteGlobalTweakConfiguration"] boolValue];',
             'BOOL overwrite=NO;',
             "global overwrite works even when custom configuration is off"),
        ]
        for index, (needle, replacement, failure) in enumerate(mutations):
            if original.count(needle) != 1:
                raise RuntimeError("ambiguous mutation boundary: " + needle)
            mutant = out / ("mutation-" + str(index) + ".m")
            mutant.write_text(original.replace(needle, replacement), encoding="utf-8")
            result = compile_run(mutant, out / ("red-" + str(index)), "projection", out / ("red-fixture-" + str(index)))
            expected = "FAIL: injection conditions: " + failure
            if result.returncode != 1 or result.stderr.strip() != expected:
                raise RuntimeError("mutation did not reach exact assertion: " + result.stdout + result.stderr)
            print("PASS: exact behavioral mutation RED: " + failure)
        diagnostic_source = ROOT / "AxsCacheKeeperDiagnostics.m"
        diagnostic_original = diagnostic_source.read_text(encoding="utf-8")
        needle = 'app[@"savedInjectionConditions"]=axs_cachekeeper_injection_conditions_projection(injectionConditions,bundle);'
        if diagnostic_original.count(needle) != 1:
            raise RuntimeError("ambiguous diagnostic export mutation boundary")
        diagnostic_mutant = out / "diagnostic-mutated.m"
        diagnostic_mutant.write_text(diagnostic_original.replace(needle, '(void)injectionConditions;'), encoding="utf-8")
        dependencies[0] = diagnostic_mutant
        result = compile_run(source, out / "export-red", "export", out / "export-red-fixture")
        expected = "FAIL: injection conditions: real export contains saved allow-list exclusion"
        if result.returncode != 1 or result.stderr.strip() != expected:
            raise RuntimeError("missing export did not reach exact behavioral assertion: " + result.stdout + result.stderr)
        print("PASS: exact behavioral export-omission RED")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
