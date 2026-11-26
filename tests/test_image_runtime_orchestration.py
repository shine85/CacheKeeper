"""Keep independent image runtime evidence visible while preserving failure gates."""
import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("image_runtime_runner", ROOT / "tests/run_image_runtime_source_tests.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class ImageRuntimeOrchestrationTests(unittest.TestCase):
    def test_startup_red_rejects_a_green_or_unrelated_failure(self):
        with contextlib.redirect_stdout(io.StringIO()):
            runner.verify_case("startup-red", "startup", subprocess.CompletedProcess([], 1, "", runner.STARTUP_RED))
        for result in (subprocess.CompletedProcess([], 0, "PASS: image-runtime-source fixture startup", ""),
                       subprocess.CompletedProcess([], 1, "", "unrelated failure"),
                       subprocess.CompletedProcess([], 2, "", runner.STARTUP_RED)):
            with self.assertRaises(AssertionError):
                runner.verify_case("startup-red", "startup", result)

    def test_red_requires_exact_failure_and_cannot_accept_green(self):
        with contextlib.redirect_stdout(io.StringIO()):
            runner.verify_case("pool-red", "owner-pool", subprocess.CompletedProcess([], 1, "", runner.OWNER_POOL_RED))
        for result in (subprocess.CompletedProcess([], 0, "PASS: image-runtime-source fixture owner-pool", ""),
                       subprocess.CompletedProcess([], 1, "", "unrelated failure"),
                       subprocess.CompletedProcess([], 1, "unexpected output", runner.OWNER_POOL_RED)):
            with self.assertRaises(AssertionError):
                runner.verify_case("pool-red", "owner-pool", result)

    def test_failed_process_does_not_hide_next_independent_process(self):
        (ROOT / "tmp").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="image-runtime-orchestration-", dir=ROOT / "tmp") as folder:
            failed, passed = Path(folder) / "failed.py", Path(folder) / "passed.py"
            marker = Path(folder) / "executed"
            failed.write_text("raise SystemExit(3)\n", encoding="utf8")
            passed.write_text(f"from pathlib import Path\nPath({str(marker)!r}).write_text('yes')\n"
                              f"print({'PASS: image-runtime-source fixture ' + str(passed)!r})\n", encoding="utf8")
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                failures = runner.run_cases(sys.executable, "green", (str(failed), str(passed)), lambda _: 10)
            self.assertEqual(failures, ["green/" + str(failed)])
            self.assertEqual(marker.read_text(), "yes")

    def test_timed_out_process_does_not_hide_next_independent_process(self):
        (ROOT / "tmp").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="image-runtime-timeout-", dir=ROOT / "tmp") as folder:
            hung, passed = Path(folder) / "hung.py", Path(folder) / "passed.py"
            hung.write_text("import time; time.sleep(10)\n", encoding="utf8")
            passed.write_text(f"print({'PASS: image-runtime-source fixture ' + str(passed)!r})\n", encoding="utf8")
            budgets = iter((0.5, 10))
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                failures = runner.run_cases(sys.executable, "green", (str(hung), str(passed)), lambda _: next(budgets))
            self.assertEqual(failures, ["green/" + str(hung)])


if __name__ == "__main__":
    unittest.main()
