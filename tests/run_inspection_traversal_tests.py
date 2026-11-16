"""Run real FD inspection fixtures after the pinned old implementation fails them."""
import hashlib
import pathlib
import shutil
import subprocess
import sys
import tempfile


root = pathlib.Path(__file__).resolve().parents[1]
compiler = shutil.which("xcrun")
if sys.platform != "darwin" or not compiler:
    print("UNAVAILABLE: inspection traversal tests require macOS and xcrun; no tests ran.")
    raise SystemExit(2)

baseline_commit = "d823af847a17231e245211817e4caa6e3c627993"
baseline_sha256 = "25ae565367409a780a3b8f2618c2bd20e13f6d1a55d2427a708886baaadc7890"
baseline = subprocess.run(
    ["git", "show", baseline_commit + ":AxsCacheKeeperInspection.m"],
    cwd=root, capture_output=True, check=True, timeout=60,
).stdout.replace(b"\r\n", b"\n")
if hashlib.sha256(baseline).hexdigest() != baseline_sha256:
    raise SystemExit("FAIL: pinned inspection baseline source hash does not match")

(root / "tmp").mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="inspection-tests-", dir=root / "tmp") as directory:
    output = pathlib.Path(directory)
    baseline_path = output / "AxsCacheKeeperInspection-baseline.m"
    baseline_path.write_bytes(baseline)
    fixture_source = root / "tests" / "inspection_traversal_tests.m"
    flags = [compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra",
             "-I" + str(root), "-I" + str(root / "tests" / "include"),
             "-framework", "Foundation"]
    old_binary = output / "inspection-baseline"
    # The test includes exactly one real implementation. Never link a second .m;
    # compiler diagnostics remain visible and a compile failure is not a red test.
    subprocess.run([*flags, '-DAXS_INSPECTION_SOURCE="' + baseline_path.as_posix() + '"',
                    str(fixture_source), "-o", str(old_binary)], check=True, timeout=60)
    negative_cases = [
        ("mapping", "verified FD inspection must not depend on Foundation absolute path aliases"),
        ("headers", "SQLite signature requires all 16 bytes including the terminal NUL"),
        ("root-replacement", "replaced root must stop before reading either namespace"),
    ]
    for selection, expected in negative_cases:
        result = subprocess.run([str(old_binary), str(output / ("old-" + selection)), selection],
                                capture_output=True, text=True, encoding="utf-8", timeout=60)
        failures = [line for line in result.stderr.splitlines() if line.startswith("FAIL:")]
        if result.returncode != 1 or failures != ["FAIL: " + expected]:
            raise SystemExit("FAIL: old inspection did not reach its expected assertion: " +
                             selection + "\n" + result.stdout + result.stderr)
        print("PASS: old inspection reached the expected failure: " + selection, flush=True)

    source = (root / "AxsCacheKeeperInspection.m").read_text(encoding="utf-8-sig")
    mutations = [
        ("source-recheck", "if (![self.walker validateSource:source])", "if (NO)", [
            ("source-changes", "stale nested hardlink sources must invalidate coverage before publishing twins"),
        ]),
        ("cancel-close", "- (void)cancel {self.cancelled=YES;[self axs_cachekeeper_finish];}",
         "- (void)cancel {self.cancelled=YES;self.complete=YES;}", [
             ("cancel", "cancel releases primary descriptors while the inspection is still alive"),
             ("twin-cancel", "cancel releases twin and primary descriptors while the inspection is still alive"),
         ]),
    ]
    for name, before, after, cases in mutations:
        if source.count(before) != 1:
            raise SystemExit("FAIL: ambiguous inspection mutation target: " + name)
        mutated_path = output / ("AxsCacheKeeperInspection-" + name + ".m")
        mutated_path.write_text(source.replace(before, after), encoding="utf-8")
        mutated_binary = output / ("inspection-" + name)
        subprocess.run([*flags, '-DAXS_INSPECTION_SOURCE="' + mutated_path.as_posix() + '"',
                        str(fixture_source), "-o", str(mutated_binary)], check=True, timeout=60)
        for selection, expected in cases:
            result = subprocess.run([str(mutated_binary), str(output / (name + "-" + selection)), selection],
                                    capture_output=True, text=True, encoding="utf-8", timeout=60)
            failures = [line for line in result.stderr.splitlines() if line.startswith("FAIL:")]
            if result.returncode != 1 or failures != ["FAIL: " + expected]:
                raise SystemExit("FAIL: inspection mutation did not reach its expected assertion: " +
                                 name + "/" + selection + "\n" + result.stdout + result.stderr)
            print("PASS: inspection mutation reached the expected failure: " + name + "/" + selection, flush=True)

    current_binary = output / "inspection-current"
    subprocess.run([*flags, str(fixture_source), "-o", str(current_binary)],
                   check=True, timeout=60)
    subprocess.run([str(current_binary), str(output / "current-fixtures"), "all"],
                   check=True, timeout=60)
