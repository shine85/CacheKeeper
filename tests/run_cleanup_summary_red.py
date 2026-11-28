"""Run the old summary overwrite against the actual ScanPage UIKit regressions."""
import json
import pathlib
import re
import subprocess
import sys
import tempfile


def main():
    if sys.platform != "darwin":
        print("UNAVAILABLE: cleanup summary RED requires macOS Simulator; no tests ran.", file=sys.stderr)
        return 2
    if len(sys.argv) != 2:
        raise SystemExit("Usage: run_cleanup_summary_red.py SIMULATOR_UDID")
    root = pathlib.Path(__file__).resolve().parents[1]
    (root / "tmp").mkdir(exist_ok=True)
    evidence = root / "tmp/history-display-red-results"
    evidence.mkdir(exist_ok=True)
    artifact = pathlib.Path(tempfile.mkdtemp(prefix="run-", dir=evidence))
    status = {"state": "running"}
    try:
        # Keep relative imports at the same depth as tests/ui and Prefs' root imports.
        with tempfile.TemporaryDirectory(prefix="cleanup-summary-red-", dir=root / "tmp") as temp:
            output = pathlib.Path(temp)
            source = (root / "Prefs/ScanPage.m").read_text(encoding="utf-8-sig")
            anchor = '        cell.detailTextLabel.attributedText = summaryStyled;\n'
            if source.count(anchor) != 1:
                raise ValueError("Ambiguous actual ScanPage summary control")
            old_overwrite = '''        if (!toggle.on) cell.detailTextLabel.text=@"未开启；打开总开关、单项开启或一键开启后才生效";
            else if (!axs_cachekeeper_selected_paths(selected,states,self.bundle).count && !axs_cachekeeper_auto_discover(states[self.bundle])) cell.detailTextLabel.text=@"总开关已开启；未选择文件清理目录，网络缓存按独立选项执行";
            if (self.actionStatus.length) cell.detailTextLabel.text=[self.actionStatus stringByAppendingFormat:@"\\n%@",cell.detailTextLabel.text];
    '''
            source = source.replace(anchor, anchor + old_overwrite)
            source = re.sub(r'^#import "\.\./([^"\n]+)"', r'#import "../../\1"', source, flags=re.M)
            for header in ("InspectionPage.h",):
                source = source.replace(f'#import "{header}"', f'#import "../../Prefs/{header}"')
            (output / "ScanPageRed.m").write_text(source, encoding="utf-8")
            test = (root / "tests/ui/ScanPageTests.m").read_text(encoding="utf-8-sig")
            if test.count('#import "../../Prefs/ScanPage.m"') != 1:
                raise ValueError("Ambiguous actual ScanPage test import")
            test = test.replace('#import "../../Prefs/ScanPage.m"', '#import "ScanPageRed.m"')
            (output / "ScanPageTestsRed.m").write_text(test, encoding="utf-8")
            spec = (root / "tests/ui/project.yml").read_text(encoding="utf-8-sig")
            original = "../../tests/ui/ScanPageTests.m"
            if spec.count(original) != 1:
                raise ValueError("Ambiguous ScanPage test source in UIKit project")
            replacement = "../../" + (output / "ScanPageTestsRed.m").relative_to(root).as_posix()
            (output / "project.yml").write_text(spec.replace(original, replacement), encoding="utf-8")
            with (artifact / "generate.log").open("w", encoding="utf-8") as log:
                subprocess.run(["xcodegen", "generate", "--spec", str(output / "project.yml"),
                                "--project", str(output), "--project-root", str(output)],
                               stdout=log, stderr=subprocess.STDOUT, check=True, timeout=60)
            methods = ("testDisabledAppKeepsHistoricalSummaryAndActionStatus",
                       "testEnabledAppWithoutDirectoriesKeepsHistoricalSummaryAndActionStatus")
            options = ["-project", str(output / "CacheKeeperInputTests.xcodeproj"), "-scheme", "InputHarness",
                       "-destination", f"platform=iOS Simulator,id={sys.argv[1]}", "-derivedDataPath", str(output / "DerivedData"),
                       "-skipPackageUpdates", "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-"]
            options += ["-only-testing:ScanPageTests/AxsCacheKeeperScanPageTests/" + method for method in methods]
            with (artifact / "build.log").open("w", encoding="utf-8") as log:
                subprocess.run(["xcodebuild", "build-for-testing", *options], stdout=log, stderr=subprocess.STDOUT,
                               check=True, timeout=600)
            result = output / "RedResults.xcresult"
            with (artifact / "red.log").open("w", encoding="utf-8") as log:
                process = subprocess.run(["xcodebuild", "test-without-building", *options,
                                          "-resultBundlePath", str(result), "-parallel-testing-enabled", "NO"],
                                         stdout=log, stderr=subprocess.STDOUT, timeout=420)
            summary = json.loads(subprocess.check_output(
                ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result), "--format", "json"],
                text=True, timeout=60))
            failures = summary.get("testFailures", [])
            accepted = (process.returncode == 65 and summary.get("failedTests") == 2 and
                        summary.get("totalTestCount") == 2 and failures and
                        all(any(method in str(failure) for method in methods) and
                            "HISTORY_CONFIGURATION:" in failure.get("failureText", "") for failure in failures))
            (artifact / "summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
            if not accepted:
                raise RuntimeError("Summary RED did not fail solely on both historical configuration assertions")
            print("PASS: old current-configuration overwrite fails both actual ScanPage regressions", flush=True)
        status["state"] = "passed"
    except BaseException as error:
        status.update(state="failed", errorType=type(error).__name__)
        raise
    finally:
        (artifact / "status.json").write_text(json.dumps(status, indent=2), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
