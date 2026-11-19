"""Exercise the real capacity runner; replace only unavailable macOS commands.

No UIKit behavior is executed here. Fixtures/logs are kept below repository tmp.
"""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("capacity_page_runner", ROOT / "tests/run_capacity_page_tests.py")
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)
(ROOT / "tmp").mkdir(exist_ok=True)
FIXTURES = Path(tempfile.mkdtemp(prefix="capacity-orchestration-", dir=ROOT / "tmp"))
METHODS = {
    "stale-running": ("testBackgroundReplacesCachedRunningWithSameEpochSavedTerminal",
                      "D1 stopped page exports saved terminal instead of cached running"),
    "false-stop": ("testFalseStopReturnWithoutNSErrorCannotClaimSaved",
                   "D1 BOOL false cannot become saved when NSError is nil"),
}


def execute(scenario):
    fixture = Path(tempfile.mkdtemp(prefix=scenario.replace(":", "-") + "-", dir=FIXTURES))
    (fixture / "Prefs").mkdir(parents=True)
    (fixture / "Prefs/DiagnosticsPage.m").write_text(
        (ROOT / "Prefs/DiagnosticsPage.m").read_text(encoding="utf-8-sig"), encoding="utf-8")
    commands, outputs_at_discovery, running_snapshots = [], [], []
    elapsed = [0.0]

    def emit(stream, text):
        if hasattr(stream, "write"):
            stream.write(text)
            stream.flush()

    def run(command, **kwargs):
        command = list(map(str, command))
        timeout = kwargs.get("timeout")
        if command[:3] == ["xcrun", "simctl", "list"]:
            stage = "discovery"
        elif command[:3] == ["xcrun", "simctl", "boot"]:
            stage = "boot"
        elif command[:3] == ["xcrun", "simctl", "bootstatus"]:
            stage = "bootstatus"
        elif command[0] == "xcodegen":
            stage = Path(command[command.index("--project") + 1]).name + ":generate"
        elif command[0] == "xcodebuild":
            stage = Path(command[command.index("-project") + 1]).parent.name + ":" + (
                "build" if command[1] == "build-for-testing" else "test")
        elif command[:2] == ["xcrun", "xcresulttool"]:
            stage = Path(command[command.index("--path") + 1]).parent.name + ":summary"
        else:
            raise AssertionError("Unexpected command: " + repr(command))
        commands.append((stage, timeout))
        if stage == "discovery":
            outputs_at_discovery.extend((fixture / "tmp/feedback-1792").glob("capacity-page-*"))
        if stage in ("discovery", "boot", "bootstatus"):
            for output in outputs_at_discovery:
                summary_file = output / "prepare-summary.json"
                if summary_file.exists():
                    running_snapshots.append(json.loads(summary_file.read_text()))
        if scenario == stage + "-timeout":
            elapsed[0] += timeout
            emit(kwargs.get("stdout"), "partial stdout before timeout\n")
            emit(kwargs.get("stderr"), "partial stderr before timeout\n")
            raise subprocess.TimeoutExpired(command, timeout)
        if scenario == stage + "-launch":
            raise OSError("fixture command launch failure")
        returncode = 7 if scenario == stage + "-exit" else 0
        stdout = ""
        if stage == "discovery":
            elapsed[0] += 125
            if timeout is not None and timeout < 125:
                raise subprocess.TimeoutExpired(command, timeout)
            devices = [{"isAvailable": True, "name": "iPhone Fixture", "udid": "FIXTURE-ID",
                        "state": "Booted" if scenario == "already-booted" else "Shutdown"}]
            if scenario == "no-device":
                devices = []
            stdout = json.dumps({"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-17-5": devices}})
            if scenario == "discovery-json":
                stdout = "{invalid"
            if scenario == "discovery-shape":
                stdout = '{"devices": []}'
        else:
            elapsed[0] += 0.5
        if stage.endswith(":test"):
            variant = stage.split(":")[0]
            returncode = 0 if variant == "green" else 65
            if scenario == "red-false-green" and variant == "stale-running":
                returncode = 0
            if scenario == "red-crash" and variant == "stale-running":
                returncode = -9
            if scenario == "green-failure" and variant == "green":
                returncode = 65
        if stage.endswith(":summary"):
            variant = stage.split(":")[0]
            if variant == "green":
                summary = {"failedTests": 0, "passedTests": 13, "totalTestCount": 13}
            else:
                method, message = METHODS[variant]
                summary = {"failedTests": 1, "passedTests": 0, "totalTestCount": 1,
                           "testFailures": [{"testIdentifier": method, "failureText": message}]}
                if scenario == "red-wrong-assertion":
                    summary["testFailures"][0]["failureText"] = "unrelated assertion"
                if scenario == "red-extra-failure":
                    summary["failedTests"] = 2
                    summary["totalTestCount"] = 2
            stdout = json.dumps(summary)
        emit(kwargs.get("stdout"), stdout)
        emit(kwargs.get("stderr"), "fixture stderr for " + stage + "\n")
        if returncode and kwargs.get("check"):
            raise subprocess.CalledProcessError(returncode, command, stdout)
        return subprocess.CompletedProcess(command, returncode, stdout, "fixture stderr")

    console = io.StringIO()
    error = None
    with patch.object(RUNNER, "__file__", str(fixture / "tests/run_capacity_page_tests.py")), \
            patch.object(sys, "platform", "win32" if scenario == "unsupported-host" else "darwin"), \
            patch.object(RUNNER.shutil, "which", return_value=None if scenario == "missing-tools" else "available"), \
            patch.object(subprocess, "run", side_effect=run), \
            patch("time.monotonic", side_effect=lambda: elapsed[0]), \
            contextlib.redirect_stdout(console), contextlib.redirect_stderr(console):
        try:
            code = RUNNER.main()
        except Exception as exc:
            code, error = 1, str(exc)
    (fixture / "console.log").write_text(console.getvalue() + (error or ""), encoding="utf-8")
    output = next((path for path in (fixture / "tmp/feedback-1792").glob("capacity-page-*") if path.is_dir()), None)
    summary = json.loads((output / "prepare-summary.json").read_text()) if output and (output / "prepare-summary.json").exists() else None
    return {"code": code, "commands": commands, "output": output, "prepare": summary,
            "early": outputs_at_discovery, "running": running_snapshots, "console": console.getvalue()}


class CapacityOrchestrationTests(unittest.TestCase):
    def test_cold_discovery_can_complete_after_125_seconds(self):
        result = execute("cold-success")
        self.assertEqual(result["code"], 0, "cold discovery must allow the observed 125-second startup")
        self.assertEqual(len(result["early"]), 1, "artifact directory must exist before discovery starts")
        self.assertEqual(result["prepare"]["state"], "ready")
        self.assertEqual(result["prepare"]["steps"][0]["elapsedSeconds"], 125)
        self.assertEqual([item["steps"][-1]["stage"] for item in result["running"]], ["discovery", "boot", "bootstatus"])
        self.assertTrue(all(item["steps"][-1]["state"] == "running" for item in result["running"]))
        self.assertEqual(result["commands"], [("discovery", 300), ("boot", 60), ("bootstatus", 420)] +
                         [(name + ":" + stage, budget) for name in ["stale-running", "false-stop", "green"]
                          for stage, budget in [("generate", 60), ("build", 600), ("test", 420), ("summary", 60)]])

    def test_preparation_failures_keep_evidence_and_never_start_tests(self):
        for stage in ["discovery", "boot", "bootstatus"]:
            for failure in ["timeout", "exit", "launch"]:
                with self.subTest(stage=stage, failure=failure):
                    result = execute(stage + "-" + failure)
                    self.assertEqual(result["code"], 1)
                    self.assertEqual(len(result["early"]), 1)
                    self.assertIsNotNone(result["prepare"], "failure must retain a prepare summary")
                    self.assertEqual(result["prepare"]["state"], "failed")
                    row = result["prepare"]["steps"][-1]
                    self.assertEqual(row["stage"], stage)
                    self.assertEqual(row["state"], {"timeout": "timeout", "exit": "failed", "launch": "launchError"}[failure])
                    self.assertGreaterEqual(row["elapsedSeconds"], 0)
                    self.assertEqual([name for name, _ in result["commands"]].count(stage), 1)
                    self.assertFalse(any(":" in name for name, _ in result["commands"]))
                    self.assertNotIn("Verified precise", result["console"])
                    if failure == "timeout":
                        self.assertIn("partial stdout", (result["output"] / row["stdout"]).read_text())
                        self.assertIn("partial stderr", (result["output"] / row["stderr"]).read_text())

    def test_invalid_discovery_and_no_device_are_explicit(self):
        for scenario, code, state in [("discovery-json", 1, "failed"), ("discovery-shape", 1, "failed"),
                                      ("no-device", 2, "unavailable")]:
            with self.subTest(scenario=scenario):
                result = execute(scenario)
                self.assertEqual(result["code"], code)
                self.assertIsNotNone(result["prepare"])
                self.assertEqual(result["prepare"]["state"], state)
                self.assertEqual(len(result["commands"]), 1)

    def test_already_booted_device_still_checks_readiness(self):
        result = execute("already-booted")
        self.assertEqual(result["code"], 0)
        self.assertNotIn("boot", dict(result["commands"]))
        self.assertIn(("bootstatus", 420), result["commands"])

    def test_unavailable_environment_retains_reason_without_commands(self):
        for scenario in ["unsupported-host", "missing-tools"]:
            with self.subTest(scenario=scenario):
                result = execute(scenario)
                self.assertEqual(result["code"], 2)
                self.assertEqual(result["prepare"]["state"], "unavailable")
                self.assertIn("required", result["prepare"]["reason"])
                self.assertEqual(result["commands"], [])

    def test_real_child_timeout_and_exit_preserve_streams(self):
        # Real OS subprocesses exercise file-backed partial logs/timeout cleanup; these are not simctl.
        real_run = subprocess.run
        for mode in ["timeout", "exit"]:
            with self.subTest(mode=mode):
                output = FIXTURES / ("real-child-" + mode)
                output.mkdir()

                def child(args, **kwargs):
                    kwargs["timeout"] = 0.5 if mode == "timeout" else 10
                    tail = "import time; time.sleep(5)" if mode == "timeout" else "sys.exit(7)"
                    script = "import sys; print('child stdout', flush=True); print('child stderr', file=sys.stderr, flush=True); " + tail
                    return real_run([sys.executable, "-u", "-c", script], **kwargs)

                with patch.object(sys, "platform", "darwin"), patch.object(RUNNER.shutil, "which", return_value="available"), \
                        patch.object(subprocess, "run", side_effect=child), contextlib.redirect_stdout(io.StringIO()):
                    with self.assertRaises(subprocess.SubprocessError):
                        RUNNER.prepare_simulator(output)
                summary = json.loads((output / "prepare-summary.json").read_text())
                self.assertEqual(summary["state"], "failed")
                self.assertEqual(len(summary["steps"]), 1)
                row = summary["steps"][0]
                self.assertEqual(row["state"], "timeout" if mode == "timeout" else "failed")
                self.assertGreater(row["elapsedSeconds"], 0)
                self.assertIn("child stdout", (output / row["stdout"]).read_text())
                self.assertIn("child stderr", (output / row["stderr"]).read_text())

    def test_nonbehavior_failures_cannot_be_accepted_as_red(self):
        for scenario in ["stale-running:generate-exit", "stale-running:build-timeout", "stale-running:test-timeout",
                         "stale-running:summary-exit", "red-false-green", "red-crash", "red-wrong-assertion",
                         "red-extra-failure", "green-failure"]:
            with self.subTest(scenario=scenario):
                result = execute(scenario)
                self.assertEqual(result["code"], 1)
                self.assertEqual(result["prepare"]["state"], "ready")
                if scenario != "green-failure":
                    self.assertNotIn("Verified precise", result["console"])

    def test_workflow_budget_and_failure_artifact_coverage(self):
        # Parse the bounded job block without adding a PyYAML dependency to CI.
        import re
        workflow = (ROOT / ".github/workflows/build.yml").read_text(encoding="utf-8-sig")
        job = re.split(r"\n  [a-z][a-z0-9-]*:\n", workflow.split("\n  capacity-page:\n", 1)[1], maxsplit=1)[0]
        job_budget = int(re.search(r"^    timeout-minutes: (\d+)$", job, re.M)[1]) * 60
        step_budgets = [int(n) * 60 for n in re.findall(r"^        timeout-minutes: (\d+)$", job, re.M)]
        self.assertEqual(len(step_budgets), 4)
        self.assertGreaterEqual(step_budgets[2], 300 + 60 + 420 + 3 * (60 + 600 + 420 + 60) + 120)
        self.assertGreaterEqual(job_budget, sum(step_budgets) + 60)
        self.assertIn("needs: native", job)
        self.assertIn("if: always()", job)
        self.assertIn("test_capacity_page_orchestration.py", job)
        # Match real prepare artifacts against the exact configured upload glob list.
        result = execute("bootstatus-timeout")
        self.assertEqual(result["prepare"]["state"], "failed")
        patterns = [line.strip() for line in job.splitlines() if line.strip().startswith("tmp/")]
        for file in result["output"].glob("prepare*"):
            relative = file.relative_to(result["output"].parents[2])
            self.assertTrue(any(relative.match(pattern) for pattern in patterns), str(relative))
        self.assertIn("needs: [build, capacity-page]", workflow)


if __name__ == "__main__":
    print("Orchestration fixtures:", FIXTURES, flush=True)
    unittest.main(verbosity=2)
