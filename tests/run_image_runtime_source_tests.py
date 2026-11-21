"""Exercise production runtime helper gates with explicit synthetic source boundaries.

The independent legacy-source and UIKit suites exercise production fingerprint
primitives and real SDKs respectively.
"""
from pathlib import Path
import hashlib
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
GATE = "    if (legacyBase && !AxsCacheKeeperImageLegacyHelpersMatch(legacyBase)) return NO;"
EXPECTED_RED = "FAIL: image-runtime-source: helper change immediately restores original write"
REFRESH_GATE = "NSString *otherRelative=relativePaths[otherIndex]==NSNull.null ? nil : relativePaths[otherIndex];"
REFRESH_RED = "FAIL: image-runtime-source: 64-owner refresh resolves home at most once plus 64 FD identity probes"
ADMISSION_GATE = "        AxsCacheKeeperImageAdmissionRecord(&_admission,reason);"
ADMISSION_RED = "FAIL: image-runtime-source: early returns retain prior live admission and exact counters"
MEMBER_GATE = "    id disk=AxsCacheKeeperImageGet(owner,\"diskCache\"),config=AxsCacheKeeperImageGet(owner,\"config\");\n    NSString *reason=AxsCacheKeeperImageStructureReason(owner,disk,config);if (reason) return reason;"
MEMBER_RED = "FAIL: image-runtime-source: released disk member is not misreported as released owner"
OWNER_POOL_GATE = '- (void)axs_cachekeeper_refresh_event:(NSUInteger)event {\n    // End SDK getter temporaries before completion or the next state transition,\n    // including direct refreshes within a still-running worker item.\n    @autoreleasepool {'
OWNER_POOL_RED = "INFO: release live=1 observed=1 released=0 expected=1\nFAIL: image-runtime-source: weak owner release is recorded once without retention"


def verify_case(role, scenario, result):
    red = {
        ("pool-red", "owner-pool"): (OWNER_POOL_RED, "owner pool RED inside actual refresh with deferred SDK getter reference"),
        ("member-red", "admission"): (MEMBER_RED, "stale member RED at actual owner getter and retained old member"),
        ("red", "admission"): (ADMISSION_RED, "admission RED at actual initializer observation"),
        ("red", "refresh"): (REFRESH_RED, "refresh amplification RED at actual 64-owner worker"),
        ("red", "fingerprint"): (EXPECTED_RED, "runtime helper mutation RED at the actual write hook"),
        ("red", "fingerprint-shifted"): (EXPECTED_RED, "runtime helper mutation RED at the actual write hook"),
    }.get((role, scenario))
    if red:
        expected, description = red
        valid = result.returncode == 1 and result.stderr.strip() == expected and not result.stdout.strip()
    else:
        expected = f"PASS: image-runtime-source fixture {scenario}"
        description = f"image-runtime-source fixture {scenario} ({role})"
        valid = result.returncode == 0 and result.stdout.strip() == expected and not result.stderr.strip()
    if not valid:
        raise AssertionError(f"{role}/{scenario} returned {result.returncode}; expected {'exact RED' if red else 'GREEN'}\n{result.stdout}{result.stderr}")
    print(f"PASS: {description}", flush=True)


def run_cases(binary, role, scenarios, remaining):
    failures = []
    for scenario in scenarios:
        try:
            result = subprocess.run([str(binary), scenario], capture_output=True, text=True, encoding="utf-8", timeout=remaining(30))
            verify_case(role, scenario, result)
        except (AssertionError, subprocess.TimeoutExpired) as error:
            # Each scenario has its own process and fresh runtime hooks. A failure
            # must stay fatal to the suite without hiding independent scenarios.
            failures.append(f"{role}/{scenario}")
            print(f"FAIL: image-runtime-source {error}", file=sys.stderr, flush=True)
    return failures


def run() -> int:
    compiler = shutil.which("xcrun")
    if sys.platform != "darwin" or not compiler:
        print("UNAVAILABLE: image runtime helper regression requires macOS and xcrun; no tests ran.")
        return 2
    # run_native_tests.py owns a 240s wrapper. Compile/test maxima are individually
    # capped by the remaining 225s work budget, leaving room for wrapper reporting.
    deadline = time.monotonic() + 225
    def remaining(maximum):
        seconds = deadline - time.monotonic()
        if seconds <= 0:
            raise SystemExit("FAIL: image-runtime-source aggregate budget exhausted")
        return min(maximum, seconds)
    source = (ROOT / "AxsCacheKeeperImageCache.m").read_text(encoding="utf-8-sig")
    if any(source.count(gate) != 1 for gate in (GATE, REFRESH_GATE, ADMISSION_GATE, MEMBER_GATE, OWNER_POOL_GATE)):
        raise SystemExit("FAIL: ambiguous runtime helper gate mutation")
    workspace = ROOT / "tmp/feedback-1792"
    workspace.mkdir(parents=True, exist_ok=True)
    failures = []
    with tempfile.TemporaryDirectory(prefix="image-runtime-source-", dir=workspace) as directory:
        helper = Path(directory) / "autorelease-fixture.o"
        subprocess.run([compiler, "clang", "-fno-objc-arc", "-Wall", "-Wextra", "-Werror=format",
                        "-c", str(ROOT / "tests/image_runtime_autorelease_fixture.m"), "-o", str(helper)],
                       cwd=ROOT, check=True, timeout=remaining(60))
        for role in ("pool-red", "member-red", "red", "green"):
            folder = Path(directory) / role
            folder.mkdir()
            candidate = source.replace(GATE, "") if role == "red" else source
            if role == "pool-red":
                candidate = candidate.replace(OWNER_POOL_GATE, '- (void)axs_cachekeeper_refresh_event:(NSUInteger)event {\n    {')
            if role == "member-red":
                candidate = candidate.replace(MEMBER_GATE, '    id disk=binding.disk,config=binding.config;\n    NSString *reason=AxsCacheKeeperImageStructureReason(owner,disk,config);if (reason) return reason;')
            if role == "red":
                candidate = candidate.replace(REFRESH_GATE, 'NSString *otherRelative=AxsCacheKeeperImageRelative(context[@"home"],other.path);')
                candidate = candidate.replace(ADMISSION_GATE, "        (void)reason;")
            (folder / "AxsCacheKeeperImageCache.m").write_text(candidate, encoding="utf-8")
            print(f"INFO: image-runtime-source {role} SHA256 {hashlib.sha256(candidate.encode()).hexdigest()}", flush=True)
            binary = folder / "runtime-source-tests"
            try:
                subprocess.run([compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format",
                            "-DAXS_CACHEKEEPER_IMAGE_TESTING=1", "-I" + str(folder), "-I" + str(ROOT),
                            "-framework", "Foundation", str(ROOT / "tests/image_runtime_source_tests.m"),
                            str(ROOT / "AxsCacheKeeperCleanupRules.m"),
                            str(ROOT / "AxsCacheKeeperOperationInfo.m"), str(helper), "-o", str(binary)],
                           cwd=ROOT, check=True, timeout=remaining(60))
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
                failures.append(f"{role}/compile")
                print(f"FAIL: image-runtime-source {role} compile: {error}", file=sys.stderr, flush=True)
                continue
            scenarios = ("owner-pool",) if role == "pool-red" else ("admission",) if role == "member-red" else ("fingerprint", "fingerprint-shifted", "pinned", "refresh", "sample", "admission") + (("owner-pool",) if role == "green" else ())
            failures.extend(run_cases(binary, role, scenarios, remaining))
    if failures:
        print("FAIL: image-runtime-source cases: " + ", ".join(failures), file=sys.stderr, flush=True)
    return int(bool(failures))


if __name__ == "__main__":
    raise SystemExit(run())
