"""The diagnostics RED runner reports missing Apple tooling as unavailable."""
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
RUNNER = ROOT / "tests" / "run_diagnostics_red.py"


class DiagnosticsRedEnvironmentTests(unittest.TestCase):
    def test_missing_xcrun_exits_unavailable_before_git_or_build(self):
        (ROOT / "tmp").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="empty-path-", dir=ROOT / "tmp") as empty_path:
            env = os.environ.copy()
            env["PATH"] = empty_path
            result = subprocess.run(
                [sys.executable, str(RUNNER)],
                cwd=ROOT,
                env=env,
                capture_output=True,
                text=True,
                encoding="utf-8",
                timeout=20,
            )

        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(
            result.stdout,
            "UNAVAILABLE: diagnostics baseline requires macOS and xcrun; no tests ran.\n",
        )
        self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    unittest.main()
