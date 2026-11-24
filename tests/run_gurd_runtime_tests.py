"""Real Gurd Runtime integration; only platform/loaded-host ABI boundaries differ.

Each child has a hard timeout <=60 seconds. Total runner budget is 780 seconds;
the orchestrator should allow 810 seconds including Python startup and cleanup.
UNAVAILABLE/exit 2 means no Foundation behavior or mutation result ran.
"""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
TOTAL_BUDGET_SECONDS = 780
SCENARIOS = (
    "enabled", "disabled", "malformed", "build-mismatch", "version-mismatch",
    "restore", "restore-invalid", "restore-ordering", "startup-background", "report-failure", "invalid-task", "sync-expire", "foreground-task", "strict",
)
PRODUCTION = (
    "AxsCacheKeeperGurdCache.m", "AxsCacheKeeperScanTask.m",
    "AxsCacheKeeperDirectories.m", "AxsCacheKeeperOperationInfo.m",
)


def host_boundary_source():
    """Keep all production Source methods/root binding; replace one host ABI probe."""
    source = (ROOT / "AxsCacheKeeperGurdSource.m").read_text(encoding="utf-8")
    anchor = "static NSString *axs_cachekeeper_gurd_identity(NSDictionary *context,IMP originals[4]) {"
    if source.count(anchor) != 1:
        raise RuntimeError("ambiguous Gurd loaded-host boundary")
    start = source.index(anchor)
    marker = "\n@implementation AxsCacheKeeperGurdSource"
    if source.count(marker) != 1:
        raise RuntimeError("ambiguous Gurd production Source methods")
    end = source.index(marker, start)
    function = source[start:end]
    if not function.rstrip().endswith("}"):
        raise RuntimeError("unexpected Gurd host boundary shape")
    bridge = (
        "extern NSString *axs_cachekeeper_gurd_runtime_fixture_host_identity(NSDictionary *,IMP [4]);\n"
        + anchor
        + "\n return axs_cachekeeper_gurd_runtime_fixture_host_identity(context,originals);\n}\n"
    )
    return source[:start] + bridge + source[end:]


def main():
    compiler = shutil.which("xcrun")
    if sys.platform != "darwin" or not compiler:
        print("UNAVAILABLE: Gurd Runtime integration requires macOS Foundation and xcrun; no behavior or RED ran.")
        return 2
    deadline = time.monotonic() + TOTAL_BUDGET_SECONDS

    def run(arguments, limit, **kwargs):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("Gurd Runtime total 780-second budget exhausted")
        return subprocess.run(arguments, timeout=min(limit, remaining), **kwargs)

    parent = ROOT / "tmp/implementation-201"
    parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="gurd-runtime-", dir=parent) as temporary:
        directory = Path(temporary)
        source = directory / "gurd-source-host-boundary.m"
        source.write_text(host_boundary_source(), encoding="utf-8")
        flags = [
            compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra",
            "-Werror=format", "-Werror=implicit-function-declaration",
            '-DAXS_CACHEKEEPER_PACKAGE_VERSION="0.0.0-0.0"',
            "-I" + str(ROOT / "tests/gurd_runtime_platform"),
            "-I" + str(ROOT), "-I" + str(ROOT / "tests"),
            "-framework", "Foundation",
        ]

        def compile_binary(name, runtime=None, cache=None):
            binary = directory / name
            extra = ['-DAXS_CACHEKEEPER_GURD_RUNTIME_INCLUDE="' + str(runtime) + '"'] if runtime else []
            products = [str(cache) if cache and path == "AxsCacheKeeperGurdCache.m" else str(ROOT / path) for path in PRODUCTION]
            run(flags + extra + [str(source)] + products
                + [str(ROOT / "tests/gurd_runtime_tests.m"), "-o", str(binary)], 60, check=True)
            return binary

        binary = compile_binary("gurd-runtime-tests")
        for scenario in SCENARIOS:
            fixture = directory / scenario
            fixture.mkdir()
            result = run([str(binary), scenario, str(fixture)], 20, capture_output=True, text=True)
            expected = f"PASS: gurd-runtime {scenario}"
            if result.returncode != 0 or result.stdout.strip() != expected:
                raise RuntimeError(f"Gurd Runtime scenario {scenario} failed ({result.returncode})\n{result.stdout}{result.stderr}")
            print(expected)

        baseline = "b176c581b44812a94c3a901674ddf7e1d7a1be36"
        git = shutil.which("git")
        if not git:
            raise RuntimeError("fixed 201 restore RED requires git")
        old_products = {}
        for name in ("AxsCacheKeeperGurdRuntime.m", "AxsCacheKeeperGurdCache.m"):
            product = run([git, "show", f"{baseline}:{name}"], 60, cwd=ROOT, capture_output=True, check=True).stdout
            path = directory / ("fixed201-" + name)
            path.write_bytes(product)
            old_products[name] = path
        red = compile_binary("fixed201-restore-ordering-red", runtime=old_products["AxsCacheKeeperGurdRuntime.m"], cache=old_products["AxsCacheKeeperGurdCache.m"])
        fixture = directory / "fixed201-restore-ordering-red-fixture"
        fixture.mkdir()
        result = run([str(red), "restore-ordering", str(fixture)], 20, capture_output=True, text=True)
        expected = "FAIL: gurd-runtime: pending restore cannot register lifecycle or acquire a task"
        failures = re.findall(r"^FAIL:.*$", result.stderr, re.MULTILINE)
        if result.returncode != 1 or result.stdout.strip() or failures != [expected]:
            raise RuntimeError(f"fixed 201 startup RED missed its exact assertion\n{result.stdout}{result.stderr}")
        print("PASS: fixed 201 Gurd restore ordering reaches exact behavioral RED")

        runtime = (ROOT / "AxsCacheKeeperGurdRuntime.m").read_text(encoding="utf-8")
        mutations = (
            ("disabled", "if (valid && axs_cachekeeper_app_enabled(state)) {", "if (valid) {",
             "FAIL: gurd-runtime: invalid or disabled inputs never request identity"),
            ("build-mismatch", '[axs_cachekeeper_gurd_installation[@"build"] isEqual:build]', "YES",
             "FAIL: gurd-runtime: metadata mismatch never authorizes installation fingerprint"),
        )
        for scenario, anchor, replacement, expected in mutations:
            if runtime.count(anchor) != 1:
                raise RuntimeError(f"ambiguous Runtime mutation anchor: {scenario}")
            mutated = directory / f"runtime-{scenario}-red.m"
            mutated.write_text(runtime.replace(anchor, replacement), encoding="utf-8")
            red = compile_binary(f"runtime-{scenario}-red", mutated)
            fixture = directory / f"{scenario}-red"
            fixture.mkdir()
            result = run([str(red), scenario, str(fixture)], 20, capture_output=True, text=True)
            # NSLog save errors may exist on stderr; the assertion is the only FAIL.
            failures = re.findall(r"^FAIL:.*$", result.stderr, re.MULTILINE)
            if result.returncode != 1 or result.stdout.strip() or failures != [expected]:
                raise RuntimeError(f"Runtime {scenario} RED did not reach its exact assertion\n{result.stdout}{result.stderr}")
            print(f"PASS: gurd-runtime {scenario} exact behavioral RED")
        cache = (ROOT / "AxsCacheKeeperGurdCache.m").read_text(encoding="utf-8")
        anchor = 'self->_lastUpdated=validated[@"updated"];self->_runtimeInfo=validated[@"runtimeInfo"];'
        if cache.count(anchor) != 1:
            raise RuntimeError("ambiguous Gurd restore evidence mutation")
        mutated = directory / "gurd-restore-producer-red.m"
        mutated.write_text(cache.replace(anchor, 'self->_lastUpdated=NSDate.date;self->_runtimeInfo=axs_cachekeeper_runtime_info();'), encoding="utf-8")
        red = compile_binary("gurd-restore-producer-red", cache=mutated)
        fixture = directory / "restore-red"
        fixture.mkdir()
        result = run([str(red), "restore", str(fixture)], 20, capture_output=True, text=True)
        expected = "FAIL: gurd-runtime: startup restore retains saved producer and evidence timestamp"
        failures = re.findall(r"^FAIL:.*$", result.stderr, re.MULTILINE)
        if result.returncode != 1 or result.stdout.strip() or failures != [expected]:
            raise RuntimeError(f"Runtime restore RED did not reach its exact assertion\n{result.stdout}{result.stderr}")
        print("PASS: gurd-runtime restore exact behavioral RED")
    print("PASS: real Gurd Runtime integration and three exact mutation controls")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (subprocess.SubprocessError, RuntimeError, TimeoutError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
