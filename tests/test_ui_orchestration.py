"""Run the real runner with only unavailable macOS command boundaries replaced.

These checks exercise scheduling, failure propagation, pin gates and attachment
attempts. They do not exercise UIKit, SDWebImage, WebKit or an actual Xcode build.
"""
import contextlib
from datetime import datetime
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import traceback
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "tests/run_ui_tests.py").read_text(encoding="utf-8-sig")
CURRENT = "2de3a496eaf6df9a1312862adcfd54acd73c39c0"
LEGACY = "fb50c1d20f24db5322b2f8f379de3618f75fe08e"
FIXED_SERIAL = "a6b6e44eadf0d39250c10a7cc0e3b91d0bdb0e94"
ALL_SUITES = ["WebKit", "SDK521", "ScanPage", "Search", "SDK515", "SDK510", "SDK510Absent"]
ALL_EXPORTS = ["ScanPage", "WebKit", "SDK521", "SDK515", "SDK510", "SDK510Absent", "Search"]
WITHOUT515_SUITES = [name for name in ALL_SUITES if name != "SDK515"]
WITHOUT515_EXPORTS = [name for name in ALL_EXPORTS if name != "SDK515"]
WITHOUT510_SUITES = [name for name in ALL_SUITES if not name.startswith("SDK510")]
WITHOUT510_EXPORTS = [name for name in ALL_EXPORTS if not name.startswith("SDK510")]
RESULTS = {"WebKitResults.xcresult": "WebKit", "ImageCacheResults.xcresult": "SDK521",
           "ImageCache515Results.xcresult": "SDK515", "ImageCache510Results.xcresult": "SDK510",
           "ImageCache510AbsentResults.xcresult": "SDK510Absent", "Results.xcresult": "Search", "ScanPageTests.xcresult": "ScanPage"}
STAMP = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
FIXTURES = ROOT / "tmp/feedback-1792" / ("runner-fixtures-" + STAMP)


def execute(name, failures=None, bad_pin=None, ambiguous_spec=False):
    failures = failures or {}
    fixture = FIXTURES / name
    (fixture / "tests/ui").mkdir(parents=True)
    spec = (ROOT / "tests/ui/project.yml").read_text(encoding="utf-8-sig")
    extra = "\n# ImageCacheIntegrationTests" if ambiguous_spec == "target" else ("\n# " + CURRENT if ambiguous_spec else "")
    (fixture / "tests/ui/project.yml").write_text(spec + extra, encoding="utf-8")
    output = fixture / "tmp/input-ui-tests"
    resolved = output / "CacheKeeperInputTests.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    commands, suites, exports = [], [], []
    stdout, stderr = io.StringIO(), io.StringIO()
    configured_sdk = "521"

    def fake_run(command, **kwargs):
        nonlocal configured_sdk
        command = list(map(str, command))
        timeout = kwargs.get("timeout")
        if len(command) > 1 and command[1].endswith("run_search_editing_red.py"):
            stage, expected_timeout = "searchRed", 1200
        elif len(command) > 1 and command[1].endswith("run_image_legacy_red.py"):
            stage, expected_timeout = "imageLegacyRed", 1320
        elif command[:3] == ["xcrun", "simctl", "list"]:
            stage, expected_timeout = "discovery", 300
        elif command[0] == "xcodegen":
            spec_name = Path(command[command.index("--spec") + 1]).name
            configured_sdk = {"project.yml": "521", "image-sdk-5.15.5.yml": "515",
                              "image-sdk-5.10.4.yml": "510"}[spec_name]
            if configured_sdk == "510":
                variant = Path(command[command.index("--spec") + 1]).read_text(encoding="utf-8")
                assert variant.count(FIXED_SERIAL) == 1 and CURRENT not in variant and LEGACY not in variant
                assert "ImageCacheIntegrationTests" not in variant
                assert variant.count("ImageCacheLegacyIntegrationTests") == 3
            stage = "generate" + configured_sdk
            expected_timeout = 60
        elif command[:2] == ["xcodebuild", "build-for-testing"]:
            stage = "build" + configured_sdk
            expected_timeout = 600
        elif command[:2] == ["xcodebuild", "test-without-building"]:
            result = Path(command[command.index("-resultBundlePath") + 1])
            stage = RESULTS[result.name]
            result.mkdir(parents=True)
            suites.append(stage)
            expected_timeout = 900 if stage == "Search" else 420
            assert command[-2:] == ["-parallel-testing-enabled", "NO"]
            if stage == "WebKit":
                assert "-only-testing:WebKitIntegrationTests" in command
            elif stage == "ScanPage":
                assert "-only-testing:ScanPageTests" in command
            elif stage in ("SDK521", "SDK515"):
                assert "-only-testing:ImageCacheIntegrationTests" in command
            elif stage in ("SDK510", "SDK510Absent"):
                test_class = "ImageCacheLegacyAbsentAPITests" if stage == "SDK510Absent" else "ImageCacheLegacyIntegrationTests"
                assert "-only-testing:ImageCacheLegacyIntegrationTests/" + test_class in command
            else:
                assert "-skip-testing:WebKitIntegrationTests" in command
                assert "-skip-testing:ImageCacheIntegrationTests" in command
                assert "-skip-testing:ScanPageTests" in command
        elif command[:4] == ["xcrun", "xcresulttool", "export", "attachments"]:
            name = RESULTS[Path(command[command.index("--path") + 1]).name]
            exports.append(name)
            stage, expected_timeout = "export" + name, 60
        elif command[0] == "codesign":
            stage, expected_timeout = "sign", 60
        elif command[:3] == ["xcrun", "simctl", "boot"]:
            stage, expected_timeout = "boot", 60
        elif command[:3] == ["xcrun", "simctl", "bootstatus"]:
            stage, expected_timeout = "bootstatus", 420
        else:
            raise AssertionError("Unexpected command: " + repr(command))
        assert timeout == expected_timeout, (stage, timeout, expected_timeout)
        assert kwargs.get("check", True) is (stage != "boot"), (stage, kwargs)
        assert not any(key in kwargs for key in ("stdout", "stderr")), kwargs
        assert bool(kwargs.get("capture_output")) == (stage == "discovery")
        commands.append(stage)
        print("SIMULATED external command:", stage, flush=True)
        failure = failures.get(stage)
        if failure == "exit":
            raise subprocess.CalledProcessError(65, command)
        if failure == "timeout":
            raise subprocess.TimeoutExpired(command, timeout)
        if failure == "oserror":
            raise OSError("simulated command launch failure: " + stage)
        if stage in ("build521", "build515", "build510"):
            resolved.parent.mkdir(parents=True, exist_ok=True)
            revision = {"build521": CURRENT, "build515": LEGACY, "build510": FIXED_SERIAL}[stage]
            if bad_pin == stage + "_wrong":
                revision = "0" * 40
            content = json.dumps({"version": 2, "pins": [{"identity": "sdwebimage", "kind": "remoteSourceControl",
                                "location": "https://github.com/SDWebImage/SDWebImage.git",
                                "state": {"revision": revision}}]})
            if bad_pin == stage + "_json":
                content = "{"
            if bad_pin == stage + "_shape":
                content = '{"pins": ["invalid"]}'
            if bad_pin == stage + "_mixed":
                package = json.loads(content)
                package["pins"].append("invalid")
                content = json.dumps(package)
            resolved.write_text(content, encoding="utf-8")
        return subprocess.CompletedProcess(command, 0, devices if stage == "discovery" else None)

    exit_code, exception = 0, None
    devices = json.dumps({"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-17-5": [
        {"isAvailable": True, "name": "iPhone Test", "udid": "TEST-DEVICE"}]}})
    with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr), \
            patch.object(sys, "platform", "darwin"):
        try:
            namespace = {"__file__": str(fixture / "tests/run_ui_tests.py"), "__name__": "ui_runner_fixture"}
            exec(compile(SOURCE, str(ROOT / "tests/run_ui_tests.py"), "exec"), namespace)
            namespace["run_command"] = fake_run
            exit_code = namespace["main"]([])
        except SystemExit as error:
            exit_code = error.code if isinstance(error.code, int) else 1
            if error.code:
                print(error.code, file=sys.stderr)
        except Exception as error:
            exit_code, exception = 1, type(error).__name__
            traceback.print_exc()
    return {"name": name, "exit": exit_code, "exception": exception, "commands": commands,
            "suites": suites, "exports": exports, "summary": json.loads((output / "run-summary.json").read_text()) if (output / "run-summary.json").exists() else None, "stdout": stdout.getvalue(), "stderr": stderr.getvalue()}


cases = [
    ("initial_red_fail_stop", {"searchRed": "exit"}, None, False, [], [], True, None),
    ("initial_red_timeout_stop", {"searchRed": "timeout"}, None, False, [], [], True, None),
    ("all_pass", {}, None, False, ALL_SUITES, ALL_EXPORTS, False, None),
    ("webkit_fails_continue", {"WebKit": "exit"}, None, False, ALL_SUITES, ALL_EXPORTS, True, "WebKit"),
    ("sdk521_fails_continue", {"SDK521": "exit"}, None, False, ALL_SUITES, ALL_EXPORTS, True, "5.21.7"),
    ("scanpage_failure_continue", {"ScanPage": "exit"}, None, False, ALL_SUITES, ALL_EXPORTS, True, "ScanPage"),
    ("scanpage_attachment_failure_continue", {"exportScanPage": "exit"}, None, False, ALL_SUITES, ALL_EXPORTS, True, "attachments"),
    ("search_timeout_continue", {"Search": "timeout"}, None, False, ALL_SUITES, ALL_EXPORTS, True, "Search"),
    ("sdk515_fails", {"SDK515": "exit"}, None, False, ALL_SUITES, ALL_EXPORTS, True, "5.15.5"),
    ("all_suites_fail", {name: "exit" for name in ALL_SUITES}, None, False, ALL_SUITES, ALL_EXPORTS, True, "5.15.5"),
    ("launch_error_continue", {"WebKit": "oserror"}, None, False, ALL_SUITES, ALL_EXPORTS, True, "WebKit"),
    ("legacy_generation_fails", {"generate515": "exit"}, None, False, WITHOUT515_SUITES, WITHOUT515_EXPORTS, True, "5.15.5"),
    ("legacy_build_fails", {"build515": "exit"}, None, False, WITHOUT515_SUITES, WITHOUT515_EXPORTS, True, "5.15.5"),
    ("legacy_build_timeout", {"build515": "timeout"}, None, False, WITHOUT515_SUITES, WITHOUT515_EXPORTS, True, "5.15.5"),
    ("legacy_pin_wrong", {}, "build515_wrong", False, WITHOUT515_SUITES, WITHOUT515_EXPORTS, True, "5.15.5"),
    ("legacy_pin_malformed", {}, "build515_json", False, WITHOUT515_SUITES, WITHOUT515_EXPORTS, True, "5.15.5"),
    ("legacy_pin_invalid_shape", {}, "build515_shape", False, WITHOUT515_SUITES, WITHOUT515_EXPORTS, True, "5.15.5"),
    ("legacy_pin_mixed_shape", {}, "build515_mixed", False, WITHOUT515_SUITES, WITHOUT515_EXPORTS, True, "5.15.5"),
    ("ambiguous_spec", {}, None, True, ALL_SUITES[:4], ["ScanPage", "WebKit", "SDK521", "Search"], True, "5.15.5"),
    ("attachment_failure_continue", {"exportWebKit": "exit"}, None, False, ALL_SUITES, ALL_EXPORTS, True, "attachments"),
    ("suite_and_attachment_fail", {"SDK521": "exit", "exportWebKit": "timeout"}, None, False, ALL_SUITES, ALL_EXPORTS, True, "5.21.7"),
    ("fixed_generation_fails", {"generate510": "exit"}, None, False, WITHOUT510_SUITES, WITHOUT510_EXPORTS, True, "5.10.4"),
    ("fixed_baseline_failure_collects_green", {"imageLegacyRed": "exit"}, None, False, ALL_SUITES, ALL_EXPORTS, True, "5.10.4 admission baseline"),
    ("fixed_baseline_timeout_collects_green", {"imageLegacyRed": "timeout"}, None, False, ALL_SUITES, ALL_EXPORTS, True, "5.10.4 admission baseline"),
    ("ambiguous_fixed_target", {}, None, "target", WITHOUT510_SUITES, WITHOUT510_EXPORTS, True, "5.10.4"),
    ("fixed_build_fails", {"build510": "exit"}, None, False, WITHOUT510_SUITES, WITHOUT510_EXPORTS, True, "5.10.4"),
    ("fixed_build_timeout", {"build510": "timeout"}, None, False, WITHOUT510_SUITES, WITHOUT510_EXPORTS, True, "5.10.4"),
    ("fixed_pin_wrong", {}, "build510_wrong", False, WITHOUT510_SUITES, WITHOUT510_EXPORTS, True, "5.10.4"),
    ("fixed_pin_malformed", {}, "build510_json", False, WITHOUT510_SUITES, WITHOUT510_EXPORTS, True, "5.10.4"),
    ("fixed_pin_invalid_shape", {}, "build510_shape", False, WITHOUT510_SUITES, WITHOUT510_EXPORTS, True, "5.10.4"),
    ("fixed_pin_mixed_shape", {}, "build510_mixed", False, WITHOUT510_SUITES, WITHOUT510_EXPORTS, True, "5.10.4"),
    ("fixed_suite_fails_continue", {"SDK510": "exit"}, None, False, ALL_SUITES, ALL_EXPORTS, True, "5.10.4"),
    ("fixed_absent_suite_fails", {"SDK510Absent": "exit"}, None, False, ALL_SUITES, ALL_EXPORTS, True, "5.10.4"),
    ("fixed_attachment_fails_continue", {"exportSDK510": "exit"}, None, False, ALL_SUITES, ALL_EXPORTS, True, "attachments"),
    ("initial_build_fail_stop", {"build521": "exit"}, None, False, [], [], True, None),
    ("initial_pin_fail_stop", {}, "build521_wrong", False, [], [], True, None),
    ("initial_sign_fail_stop", {"sign": "exit"}, None, False, [], [], True, None),
    ("discovery_timeout_stop", {"discovery": "timeout"}, None, False, [], [], True, None),
    ("discovery_exit_stop", {"discovery": "exit"}, None, False, [], [], True, None),
    ("bootstatus_timeout_stop", {"bootstatus": "timeout"}, None, False, [], [], True, None),
]
def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    results = []
    for name, failures, bad_pin, ambiguous, want_suites, want_exports, want_failure, summary_label in cases:
        result = execute(name, failures, bad_pin, ambiguous)
        errors = []
        if result["suites"] != want_suites:
            errors.append(f"suite schedule: expected {want_suites}, got {result['suites']}")
        if result["exports"] != want_exports:
            errors.append(f"attachment schedule: expected {want_exports}, got {result['exports']}")
        if (result["exit"] != 0) != want_failure:
            errors.append(f"exit: expected failure={want_failure}, got {result['exit']}")
        ledger = result['summary']
        if not ledger or ledger['state'] != ('failed' if want_failure else 'passed'):
            errors.append('durable summary disagrees with actual exit')
        if ledger and any(row['state'] == 'running' for row in ledger['stages']):
            errors.append('finished command remains running in durable ledger')
        if name.startswith('discovery_') and 'boot' in result['commands']:
            errors.append('failed discovery must not boot a simulator')
        if summary_label:
            if result["exception"]:
                errors.append("uncaught failure: " + result["exception"])
            summaries = [line for line in result["stderr"].splitlines() if "failed suites/stages:" in line]
            if len(summaries) != 1 or summary_label not in summaries[0]:
                errors.append("missing aggregate failure summary containing " + summary_label)
        if name.startswith("initial_") and any(stage in result["commands"] for stage in ("generate515", "build515", "generate510", "build510")):
            errors.append("initial build/sign/pin failure must stop before compatibility generation")
        if name in ("legacy_generation_fails", "ambiguous_spec") and "build515" in result["commands"]:
            errors.append("failed compatibility preparation must not build")
        result["assertion_errors"] = errors
        result["passed"] = not errors
        results.append(result)
        print(("PASS" if not errors else "FAIL") + ": " + name)
        for error in errors:
            print("  " + error)
    report = {"scope": "Python orchestration only; external macOS commands simulated; no SDK/UIKit behavior executed",
              "source_sha256": hashlib.sha256((ROOT / "tests/run_ui_tests.py").read_bytes()).hexdigest(),
              "total": len(results), "passed": sum(result["passed"] for result in results), "results": results}
    report_path = Path(argv[0]) if argv else FIXTURES / "results.json"
    report_path.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"RESULT: {report['passed']}/{report['total']} orchestration scenarios passed; {report_path}")
    return 0 if report["passed"] == report["total"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
