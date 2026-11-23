"""Real subprocess checks: fail-fast, swallowed exits, timeout conflation and unsafe dependencies."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import run_image_admission_core_tests
import run_native_tests

ROOT = Path(__file__).resolve().parents[1]


class NativeOrchestrationTests(unittest.TestCase):
    def setUp(self):
        (ROOT / "tmp").mkdir(exist_ok=True)
        self.directory = tempfile.TemporaryDirectory(prefix="native-orchestration-", dir=ROOT / "tmp")
        self.addCleanup(self.directory.cleanup)
        self.work = Path(self.directory.name)

    def run_batch(self, specs):
        driver = self.work / "driver.py"
        driver.write_text(
            "import sys\nfrom pathlib import Path\n"
            f"sys.path.insert(0, {str(ROOT / 'tests')!r})\n"
            "from native_test_batch import Suite, run_suites, summary_exit_code\n"
            f"summary = run_suites([Suite(**s) for s in {specs!r}], Path({str(self.work / 'out')!r}), Path({str(ROOT)!r}))\n"
            "raise SystemExit(summary_exit_code(summary))\n", encoding="utf-8")
        result = subprocess.run([sys.executable, str(driver)], capture_output=True, text=True, timeout=10)
        path = self.work / "out" / "summary.json"
        self.assertTrue(path.exists(), "batch must always write summary: " + result.stderr)
        return result, json.loads(path.read_text(encoding="utf-8"))

    def suite(self, name, code, timeout=3, dependencies=()):
        return {"name": name, "command": [sys.executable, "-c", code],
                "timeout_seconds": timeout, "dependencies": dependencies}

    def test_first_failure_does_not_block_later_group(self):
        result, summary = self.run_batch([
            self.suite("first", "raise SystemExit(7)"),
            self.suite("later", "print('later ran')"),
        ])
        self.assertEqual(result.returncode, 1)
        self.assertEqual([r["status"] for r in summary["suites"]], ["FAIL", "PASS"])
        self.assertIn("later ran", (self.work / "out" / summary["suites"][1]["log"]).read_text())

    def test_timeout_and_unavailable_are_distinct(self):
        result, summary = self.run_batch([
            self.suite("slow", "import time; print('started', flush=True); time.sleep(3)", .25),
            self.suite("missing", "print('UNAVAILABLE: no xcrun'); raise SystemExit(2)"),
        ])
        self.assertEqual(result.returncode, 1)
        self.assertEqual([r["status"] for r in summary["suites"]], ["TIMEOUT", "UNAVAILABLE"])
        self.assertIn("started", (self.work / "out" / summary["suites"][0]["log"]).read_text())

    def test_compile_failure_blocks_its_binary_only(self):
        marker = self.work / "binary-ran"
        result, summary = self.run_batch([
            self.suite("compile", "raise SystemExit(3)"),
            self.suite("binary", f"from pathlib import Path; Path({str(marker)!r}).write_text('bad')", dependencies=("compile",)),
            self.suite("independent", "print('ran')"),
        ])
        self.assertEqual(result.returncode, 1)
        self.assertEqual([r["status"] for r in summary["suites"]], ["FAIL", "SKIPPED_DEPENDENCY", "PASS"])
        self.assertFalse(marker.exists())

    def test_all_success_returns_zero(self):
        result, summary = self.run_batch([self.suite("one", "print('ok')"), self.suite("two", "print('ok')")])
        self.assertEqual(result.returncode, 0)
        self.assertEqual(summary["failed"], [])
        self.assertEqual(summary["status"], "PASS")

    def test_core_compile_failure_never_launches_its_binary(self):
        marker = self.work / "core-binary-ran"
        driver = self.work / "compile-and-run.py"
        driver.write_text(
            "import sys\n"
            f"sys.path.insert(0, {str(ROOT / 'tests')!r})\n"
            "from run_native_core import run_command\n"
            "run_command([sys.executable, '-c', 'raise SystemExit(3)'], check=True)\n"
            f"run_command([sys.executable, '-c', {('from pathlib import Path; Path(' + repr(str(marker)) + ').write_text(\"bad\")')!r}], check=True)\n",
            encoding="utf-8")
        result, summary = self.run_batch([
            {"name": "compile-and-run", "command": [sys.executable, str(driver)], "timeout_seconds": 5},
            self.suite("independent", "print('ran')"),
        ])
        self.assertEqual(result.returncode, 1)
        self.assertEqual([r["status"] for r in summary["suites"]], ["FAIL", "PASS"])
        self.assertFalse(marker.exists())

    def test_nonzero_summary_includes_evidence(self):
        result, summary = self.run_batch([self.suite("bad", "print('evidence'); raise SystemExit(9)")])
        self.assertEqual(result.returncode, 1)
        row = summary["suites"][0]
        self.assertEqual(row["returncode"], 9)
        self.assertEqual(summary["failed"], ["bad"])
        self.assertIn("evidence", (self.work / "out" / row["log"]).read_text())
        self.assertIn("bad: FAIL", result.stdout)

    def test_plain_exit_two_is_failure_not_unavailable(self):
        result, summary = self.run_batch([self.suite("syntax", "raise SystemExit(2)")])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(summary["suites"][0]["status"], "FAIL")

    def test_inner_native_timeout_is_reported_as_timeout(self):
        result, summary = self.run_batch([self.suite("inner", "print('NATIVE_TIMEOUT: fixture: command exceeded 60s'); raise SystemExit(124)")])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(summary["suites"][0]["status"], "TIMEOUT")

    def test_run_group_timeout_preserves_captured_output(self):
        timed_out_script = self.work / "timed-out-focused.py"
        timed_out_script.write_text(
            "import subprocess, sys\n"
            "subprocess.run([sys.executable, '-c', "
            "'import sys, time; print(\\\"captured stdout\\\", flush=True); print(\\\"captured stderr\\\", file=sys.stderr, flush=True); time.sleep(2)'"
            "], capture_output=True, timeout=0.5)\n",
            encoding="utf-8")
        driver = self.work / "run-group-timeout.py"
        driver.write_text(
            "import sys\n"
            f"sys.path.insert(0, {str(ROOT / 'tests')!r})\n"
            "import run_native_tests\n"
            f"run_native_tests.SCRIPT_GROUPS = ((\"owner-snapshot\", {str(timed_out_script)!r}, 60),)\n"
            "raise SystemExit(run_native_tests.main(['--group', 'owner-snapshot']))\n",
            encoding="utf-8")
        result = subprocess.run([sys.executable, str(driver)], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 124)
        self.assertIn("NATIVE_TIMEOUT_STDOUT: captured stdout", result.stdout)
        self.assertIn("NATIVE_TIMEOUT_STDERR: captured stderr", result.stderr)
        self.assertIn("NATIVE_TIMEOUT: owner-snapshot", result.stdout)

    def test_only_unavailable_returns_two(self):
        result, summary = self.run_batch([self.suite("missing", "print('UNAVAILABLE: macOS required'); raise SystemExit(2)")])
        self.assertEqual(result.returncode, 2)
        self.assertEqual(summary["status"], "UNAVAILABLE")

    def test_qq_schema_group_runs_without_macos(self):
        result = subprocess.run(
            [sys.executable, str(ROOT / "tests/run_native_tests.py"), "--group", "qq-resource-schema"],
            capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Ran 9 tests", result.stdout + result.stderr)
        self.assertNotIn("UNAVAILABLE:", result.stdout + result.stderr)

    def test_diagnostic_assets_group_runs_without_device_support(self):
        result = subprocess.run(
            [sys.executable, str(ROOT / "tests/run_native_tests.py"), "--group", "runtime-diagnostic-assets"],
            capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Ran 4 tests", result.stdout + result.stderr)
        self.assertNotIn("UNAVAILABLE:", result.stdout + result.stderr)

    def test_qq_code_group_executes_the_repository_probe(self):
        if not shutil.which("node"):
            self.skipTest("UNAVAILABLE: QQ code-window regression requires Node.js")
        result = subprocess.run(
            [sys.executable, str(ROOT / "tests/run_native_tests.py"), "--group", "qq-resource-code"],
            capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS QQ bounded code windows", result.stdout)

    def test_portable_c_groups_use_the_available_host_compiler(self):
        zig = ROOT / "tmp/release-evidence-toolchain/zig-windows-x86_64-0.13.0/zig.exe"
        environment = os.environ.copy()
        if zig.is_file():
            environment["PATH"] = str(zig.parent) + os.pathsep + environment.get("PATH", "")
        available = any(shutil.which(name, path=environment.get("PATH")) for name in ("clang", "cc", "zig"))
        budgets = {name: budget for name, _, budget in run_native_tests.SCRIPT_GROUPS}
        cases = (("resource-layout", "PASS: resource-layout:"),
                 ("image-effect", "PASS: image effect totals"),
                 ("image-admission-core", "PASS: image admission core green"),
                 ("scaled-representation-geometry", "PASS: fixed scaled representation dimensions"))
        for group, evidence in cases:
            with self.subTest(group=group):
                result = subprocess.run(
                    [sys.executable, str(ROOT / "tests/run_native_tests.py"), "--group", group],
                    capture_output=True, text=True, env=environment, timeout=budgets[group] + 15)
                self.assertNotIn("require macOS and xcrun", result.stdout + result.stderr)
                self.assertEqual(result.returncode, 0 if available else 2, result.stdout + result.stderr)
                self.assertIn(evidence if available else "UNAVAILABLE:", result.stdout + result.stderr)

    def test_portable_wrapper_allows_all_commands_and_summary_overhead(self):
        # A successful compiler/test may consume its whole permitted command
        # budget. The parent must leave time to publish that group's result.
        required = {"resource-layout": 60 + 60,
                    "image-effect": 2 * (60 + 30),
                    "image-source-observation": 60 + 4 * (60 + 30),
                    # C core, MRC helper, fixed-header RED/current GREEN,
                    # then fixed-producer RED/current writer integration.
                    "image-write-observation": (60 + 30) + 60 + (15 + 2 * (60 + 30)) + (15 + 2 * (60 + 60)),
                    "scaled-representation-geometry": 2 * (60 + 30)}
        budgets = {name: budget for name, _, budget in run_native_tests.SCRIPT_GROUPS}
        for name, command_seconds in required.items():
            with self.subTest(group=name):
                self.assertGreaterEqual(budgets[name], command_seconds + 15,
                                        "wrapper can truncate a valid group before its summary")

    def test_admission_uses_path_zig_without_the_local_bundle(self):
        zig = shutil.which("zig")
        local_zig = ROOT / "tmp/release-evidence-toolchain/zig-windows-x86_64-0.13.0/zig.exe"
        if not zig and local_zig.is_file():
            zig = str(local_zig)
        if not zig:
            self.skipTest("UNAVAILABLE: isolated PATH Zig regression requires Zig")
        # Hide the historical bundle and other compilers from discovery only;
        # the selected Zig still compiles and runs the actual production header.
        with patch.object(run_image_admission_core_tests.Path, "is_file", return_value=False), \
                patch.object(run_image_admission_core_tests.shutil, "which",
                             side_effect=lambda name: zig if name == "zig" else None), \
                patch.object(sys, "argv", ["run_image_admission_core_tests.py", "--green-only"]):
            self.assertEqual(run_image_admission_core_tests.run(), 0)


if __name__ == "__main__":
    unittest.main()
