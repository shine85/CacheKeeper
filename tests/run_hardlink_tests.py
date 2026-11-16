"""Run real Foundation/POSIX hard-link behavior and isolated negative controls on macOS."""
import pathlib
import shutil
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
compiler = shutil.which("xcrun")
if sys.platform != "darwin" or not compiler:
    print("UNAVAILABLE: hard-link regression tests require macOS and xcrun; no tests ran.")
    raise SystemExit(2)

(root / "tmp").mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="hardlink-tests-", dir=root / "tmp") as directory:
    output = pathlib.Path(directory)
    main = output / "main.m"
    main.write_text('''#import <Foundation/Foundation.h>
void axs_cachekeeper_run_hardlink_tests(NSString *fixture);
int main(int argc, const char **argv) { @autoreleasepool {
    if (argc!=2) return 2;
    axs_cachekeeper_run_hardlink_tests([NSString stringWithUTF8String:argv[1]]);
} return 0; }
''', encoding="utf-8")
    baseline_source = (root / "Baseline.m").read_text(encoding="utf-8-sig")
    job_source = (root / "AxsCacheKeeperCleanupJob.m").read_text(encoding="utf-8-sig")
    cases = [
        ("current", baseline_source, job_source, None),
    ]
    controls = [
        ("no-closure", "job", "self.hardLinkGroups=[AxsCacheKeeperSweep closedHardLinkGroupsForSweeps:self.sweeps];",
         "self.hardLinkGroups=@[];", "closed group is reclaimed once across roots and overlapping observations"),
        ("no-batch-gate", "job", "nextGateRemoval=self.removed+MAX((NSUInteger)1,perRootLimit);", "nextGateRemoval=NSUIntegerMax;",
         "gate closes before first unlink or at the existing per-root batch boundary"),
        ("deferred-underflow", "baseline", "representative.sweep.changedBytes=changedBytesBefore;",
         "representative.sweep.changedBytes-=[representative.snapshot[6] unsignedLongLongValue];",
         "external inode or parent changes retain exact deferred bytes after an owned unlink"),
        ("oversized-group-stops-job", "job",
         "[group retainForBudget];self.hardLinkBudgetLimited=YES;self.hardLinkCursor++;return;",
         "[self finishWithReason:AxsCacheKeeperCleanupEndReasonLimitReached];return;",
         "oversized closed group remains pending without starving an independent ordinary file"),
    ]
    for name, target, before, after, expected in controls:
        source = job_source if target == "job" else baseline_source
        if source.count(before) != 1:
            raise SystemExit("FAIL: ambiguous hard-link negative control: " + name)
        changed = source.replace(before, after)
        cases.append((name, changed if target == "baseline" else baseline_source,
                      changed if target == "job" else job_source, expected))
    for name, baseline, job, expected in cases:
        baseline_path = output / (name + "-baseline.m")
        baseline_path.write_text(baseline, encoding="utf-8")
        job_path = output / (name + "-job.m")
        job_path.write_text(job, encoding="utf-8")
        binary = output / name
        subprocess.run([compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format",
                        "-I" + str(root), "-I" + str(root / "tests" / "include"),
                        "-framework", "Foundation", str(main), str(root / "tests" / "hardlink_tests.m"),
                        str(baseline_path), str(job_path), str(root / "AxsCacheKeeperCleanupRules.m"),
                        str(root / "AxsCacheKeeperDependencySnapshot.m"), "-o", str(binary)],
                       check=True, timeout=60)
        result = subprocess.run([str(binary), str(output / (name + "-fixtures"))],
                                capture_output=True, text=True, encoding="utf-8", timeout=60)
        if expected is None:
            if result.returncode:
                raise SystemExit(result.stdout + result.stderr)
            print(result.stderr.strip())
        elif result.returncode != 1 or "FAIL: hardlink: " + expected not in result.stderr:
            raise SystemExit("FAIL: hard-link control did not reach its behavioral assertion: " + name +
                             "\n" + result.stdout + result.stderr)
        else:
            print("PASS: hard-link negative control caught: " + name)
