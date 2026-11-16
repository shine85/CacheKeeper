"""Run real FD/name fixtures with pinned old RED and current GREEN in one checkout."""
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
name_baseline_commit = "9cb488d420e873d24f3677e2758be99fb6f8502c"
name_baseline_sha256 = "f82cda7be4e19f1b1bbd7f8663b067fe49bd5c37d66b9d186930a64fc2e490d1"
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
    flags = [compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format",
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

    name_baseline = subprocess.run(
        ["git", "show", name_baseline_commit + ":AxsCacheKeeperInspection.m"],
        cwd=root, capture_output=True, check=True, timeout=60,
    ).stdout.replace(b"\r\n", b"\n")
    if hashlib.sha256(name_baseline).hexdigest() != name_baseline_sha256:
        raise SystemExit("FAIL: pinned raw-name baseline source hash does not match")
    name_path = output / "AxsCacheKeeperInspection-name-baseline.m"
    name_path.write_bytes(name_baseline)
    name_binary = output / "inspection-name-baseline"
    subprocess.run([*flags, '-DAXS_INSPECTION_SOURCE="' + name_path.as_posix() + '"',
                    str(fixture_source), "-o", str(name_binary)], check=True, timeout=60)
    print("Pinned raw-name RED: " + name_baseline_commit + " SHA256 " + name_baseline_sha256, flush=True)
    for selection, expected in [
        ("raw-conversion", "legal byte names remain traversable when display conversion fails"),
        ("raw-sources", "same-display byte components retain distinct source and twin identities"),
        ("raw-protected", "raw protected components remain unread when presentation decoding fails"),
        ("raw-invalid", "invalid dirent handling consumes one bounded step without swallowing siblings"),
        ("raw-cancel", "one invalid raw record leaves traversal cancellable"),
    ]:
        result = subprocess.run([str(name_binary), str(output / ("name-old-" + selection)), selection],
                                capture_output=True, text=True, encoding="utf-8", timeout=60)
        failures = [line for line in result.stderr.splitlines() if line.startswith("FAIL:")]
        if result.returncode != 1 or failures != ["FAIL: " + expected]:
            raise SystemExit("FAIL: raw-name baseline did not reach expected assertion: " +
                             selection + "\n" + result.stdout + result.stderr)
        print("PASS: pinned raw-name baseline reached expected failure: " + selection, flush=True)

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
        ("unicode-policy", "encoding:NSUTF8StringEncoding];\n    return decoded ?: @\"opaque-component\";",
         "encoding:NSASCIIStringEncoding];\n    return decoded ?: @\"opaque-component\";", [
             ("raw-unicode-markers", "valid Unicode marker semantics survive unavailable display conversion"),
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
