"""Real Foundation concurrency regression; controlled scheduling never replaces native IO."""
from pathlib import Path
import argparse
import hashlib
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
SCENARIOS = ("setter-reentry", "getter-reentry", "setter-same-instance-reentry", "initial-getter-new-request", "newer-setter", "late-write-after-read", "disable-during-setter", "enable-during-setter", "off-on-during-setter", "setter-exception", "getter-exception", "replay-exception", "queued-replay-exception", "parallel-setters", "existing")
BASELINE_SHA256 = "417fb7827ef3b08be4ede4b52d3e695ccbaf2b76b3d8be3edb85c0a96fffd068"
BASELINE_REF = "2eb4f85046c6634ac3b785904fd3a561ba3bf49d"
TOTAL_BUDGET_SECONDS = 360

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--support-root", type=Path, default=ROOT)
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--red-only", action="store_true")
    args = parser.parse_args()
    if sys.platform != "darwin" or not shutil.which("xcrun"):
        print("UNAVAILABLE: network lock RED/GREEN requires macOS Foundation and xcrun; no native behavior ran.")
        return 2
    output = ROOT / "tmp" / "network-lock-results"
    output.mkdir(parents=True, exist_ok=True)
    deadline = time.monotonic() + TOTAL_BUDGET_SECONDS
    def execute(command, limit, **kwargs):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("network lock RED/GREEN total budget exhausted")
        return subprocess.run(command, timeout=min(limit, remaining), **kwargs)
    def build(source, name):
        binary = output / name
        command = ["xcrun", "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format", "-framework", "Foundation",
                   "-I" + str(ROOT), "-I" + str(args.support_root), "-I" + str(args.support_root / "tests/include"),
                   '-DAXS_CACHEKEEPER_NETWORK_LOCK_SOURCE="' + str(source.resolve()) + '"',
                   "-DAXS_CACHEKEEPER_NETWORK_LOCK_CURRENT=" + ("1" if name.endswith("green") else "0"),
                   str(ROOT / "tests/network_cache_tests.m"), str(ROOT / "tests/network_lock_tests.m"), "-o", str(binary)]
        result = execute(command, 60, capture_output=True, text=True)
        (output / (name + "-build.log")).write_text(result.stdout + result.stderr, encoding="utf-8")
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)
        return binary
    def run(binary, scenario, name):
        folder = output / name
        folder.mkdir(exist_ok=True)
        result = execute([str(binary), scenario, str(folder)], 45, capture_output=True, text=True)
        (output / (name + ".log")).write_text(result.stdout + result.stderr, encoding="utf-8")
        return result
    baseline = args.baseline
    if baseline is None:
        result = execute(["git", "show", BASELINE_REF + ":AxsCacheKeeperNetworkCache.m"], 15,
                         cwd=args.support_root, capture_output=True)
        if result.returncode:
            raise RuntimeError("fixed network baseline unavailable: " + result.stderr.decode(errors="replace"))
        baseline = output / "network-lock-baseline.m"
        baseline.write_bytes(result.stdout)
    if hashlib.sha256(baseline.read_bytes()).hexdigest() != BASELINE_SHA256:
        raise RuntimeError("network lock baseline source digest mismatch")
    binary = build(baseline, "network-lock-red")
    for scenario in SCENARIOS[:2]:
        result = run(binary, scenario, "red-" + scenario)
        expected = "FAIL: network locking: native capacity access must allow another thread to enter a different cache setter"
        failures = [line for line in (result.stdout + result.stderr).splitlines() if line.startswith("FAIL:")]
        if result.returncode != 1 or failures != [expected]:
            raise RuntimeError("incorrect exact network locking RED\n" + result.stdout + result.stderr)
        print("PASS: exact network-lock baseline RED " + scenario)
    if args.red_only:
        return 0
    binary = build(ROOT / "AxsCacheKeeperNetworkCache.m", "network-lock-green")
    for scenario in SCENARIOS:
        result = run(binary, scenario, "green-" + scenario)
        expected = "PASS: network-lock " + scenario
        if scenario == "existing":
            expected = "PASS: NSURLCache real initializer boundary, restoration, latest requests and concurrent toggle"
        if result.returncode or (result.stdout.strip().splitlines()[-1:] != [expected]):
            raise RuntimeError("network lock regression failed\n" + result.stdout + result.stderr)
        print(result.stdout, end="")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
