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
ALL_SUITES = ["WebKit", "SDK521", "Search", "SDK515"]
ALL_EXPORTS = ["WebKit", "SDK521", "SDK515", "Search"]
RESULTS = {"WebKitResults.xcresult": "WebKit", "ImageCacheResults.xcresult": "SDK521",
           "ImageCache515Results.xcresult": "SDK515", "Results.xcresult": "Search"}
STAMP = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
FIXTURES = ROOT / "tmp/diagnostics-144-followup" / ("runner-fixtures-" + STAMP)


def execute(name, failures=None, bad_pin=None, ambiguous_spec=False):
    failures = failures or {}
    fixture = FIXTURES / name
    (fixture / "tests/ui").mkdir(parents=True)
    spec = (ROOT / "tests/ui/project.yml").read_text(encoding="utf-8-sig")
    (fixture / "tests/ui/project.yml").write_text(spec + ("\n# " + CURRENT if ambiguous_spec else ""), encoding="utf-8")
    output = fixture / "tmp/input-ui-tests"
    resolved = output / "CacheKeeperInputTests.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    commands, suites, exports = [], [], []
    stdout, stderr = io.StringIO(), io.StringIO()
    builds = 0

    def fake_run(command, **kwargs):
        nonlocal builds
        command = list(map(str, command))
        timeout = kwargs.get("timeout")
        if len(command) > 1 and command[1].endswith("run_search_editing_red.py"):
            stage, expected_timeout = "searchRed", 900
        elif command[0] == "xcodegen":
            stage = "generate515" if "image-sdk-5.15.5.yml" in command[command.index("--spec") + 1] else "generate521"
            expected_timeout = 60
        elif command[:2] == ["xcodebuild", "build-for-testing"]:
            builds += 1
            stage = "build521" if builds == 1 else "build515"
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
            elif stage in ("SDK521", "SDK515"):
                assert "-only-testing:ImageCacheIntegrationTests" in command
            else:
                assert "-skip-testing:WebKitIntegrationTests" in command
                assert "-skip-testing:ImageCacheIntegrationTests" in command
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
        assert kwargs.get("check") is (stage != "boot"), (stage, kwargs)
        assert not any(key in kwargs for key in ("capture_output", "stdout", "stderr")), kwargs
        commands.append(stage)
        print("SIMULATED external command:", stage, flush=True)
        failure = failures.get(stage)
        if failure == "exit":
            raise subprocess.CalledProcessError(65, command)
        if failure == "timeout":
            raise subprocess.TimeoutExpired(command, timeout)
        if failure == "oserror":
            raise OSError("simulated command launch failure: " + stage)
        if stage in ("build521", "build515"):
            resolved.parent.mkdir(parents=True, exist_ok=True)
            revision = CURRENT if stage == "build521" else LEGACY
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
        return subprocess.CompletedProcess(command, 0)

    exit_code, exception = 0, None
    devices = json.dumps({"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-17-5": [
        {"isAvailable": True, "name": "iPhone Test", "udid": "TEST-DEVICE"}]}})
    with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr), \
            patch.object(sys, "platform", "darwin"), \
            patch.object(subprocess, "run", fake_run), \
            patch.object(subprocess, "check_output", return_value=devices):
        try:
            exec(compile(SOURCE, str(ROOT / "tests/run_ui_tests.py"), "exec"),
                 {"__file__": str(fixture / "tests/run_ui_tests.py"), "__name__": "__main__"})
        except SystemExit as error:
            exit_code = error.code if isinstance(error.code, int) else 1
            if error.code:
                print(error.code, file=sys.stderr)
        except Exception as error:
            exit_code, exception = 1, type(error).__name__
            traceback.print_exc()
    return {"name": name, "exit": exit_code, "exception": exception, "commands": commands,
            "suites": suites, "exports": exports, "stdout": stdout.getvalue(), "stderr": stderr.getvalue()}


cases = [
    ("initial_red_fail_stop", {"searchRed": "exit"}, None, False, [], [], True, None),
    ("initial_red_timeout_stop", {"searchRed": "timeout"}, None, False, [], [], True, None),
    ("all_pass", {}, None, False, ALL_SUITES, ALL_EXPORTS, False, None),
    ("webkit_fails_continue", {"WebKit": "exit"}, None, False, ALL_SUITES, ALL_EXPORTS, True, "WebKit"),
    ("sdk521_fails_continue", {"SDK521": "exit"}, None, False, ALL_SUITES, ALL_EXPORTS, True, "5.21.7"),
    ("search_timeout_continue", {"Search": "timeout"}, None, False, ALL_SUITES, ALL_EXPORTS, True, "Search"),
    ("sdk515_fails", {"SDK515": "exit"}, None, False, ALL_SUITES, ALL_EXPORTS, True, "5.15.5"),
    ("all_suites_fail", {name: "exit" for name in ALL_SUITES}, None, False, ALL_SUITES, ALL_EXPORTS, True, "5.15.5"),
    ("launch_error_continue", {"WebKit": "oserror"}, None, False, ALL_SUITES, ALL_EXPORTS, True, "WebKit"),
    ("legacy_generation_fails", {"generate515": "exit"}, None, False, ALL_SUITES[:3], ["WebKit", "SDK521", "Search"], True, "5.15.5"),
    ("legacy_build_fails", {"build515": "exit"}, None, False, ALL_SUITES[:3], ["WebKit", "SDK521", "Search"], True, "5.15.5"),
    ("legacy_build_timeout", {"build515": "timeout"}, None, False, ALL_SUITES[:3], ["WebKit", "SDK521", "Search"], True, "5.15.5"),
    ("legacy_pin_wrong", {}, "build515_wrong", False, ALL_SUITES[:3], ["WebKit", "SDK521", "Search"], True, "5.15.5"),
    ("legacy_pin_malformed", {}, "build515_json", False, ALL_SUITES[:3], ["WebKit", "SDK521", "Search"], True, "5.15.5"),
    ("legacy_pin_invalid_shape", {}, "build515_shape", False, ALL_SUITES[:3], ["WebKit", "SDK521", "Search"], True, "5.15.5"),
    ("legacy_pin_mixed_shape", {}, "build515_mixed", False, ALL_SUITES[:3], ["WebKit", "SDK521", "Search"], True, "5.15.5"),
    ("ambiguous_spec", {}, None, True, ALL_SUITES[:3], ["WebKit", "SDK521", "Search"], True, "5.15.5"),
    ("attachment_failure_continue", {"exportWebKit": "exit"}, None, False, ALL_SUITES, ALL_EXPORTS, True, "attachments"),
    ("suite_and_attachment_fail", {"SDK521": "exit", "exportWebKit": "timeout"}, None, False, ALL_SUITES, ALL_EXPORTS, True, "5.21.7"),
    ("initial_build_fail_stop", {"build521": "exit"}, None, False, [], [], True, None),
    ("initial_pin_fail_stop", {}, "build521_wrong", False, [], [], True, None),
    ("initial_sign_fail_stop", {"sign": "exit"}, None, False, [], [], True, None),
]
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
    if summary_label:
        if result["exception"]:
            errors.append("uncaught failure: " + result["exception"])
        summaries = [line for line in result["stderr"].splitlines() if "failed suites/stages:" in line]
        if len(summaries) != 1 or summary_label not in summaries[0]:
            errors.append("missing aggregate failure summary containing " + summary_label)
    if name.startswith("initial_") and any(stage in result["commands"] for stage in ("generate515", "build515")):
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
report_path = Path(sys.argv[1]) if len(sys.argv) > 1 else FIXTURES / "results.json"
report_path.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
print(f"RESULT: {report['passed']}/{report['total']} orchestration scenarios passed; {report_path}")
raise SystemExit(0 if report["passed"] == report["total"] else 1)
