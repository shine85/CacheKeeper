"""Exercise RED acceptance against actual child exits and output streams."""
import pathlib
import subprocess
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from exact_failure_control import require_exact_failure


class ExactFailureControlTests(unittest.TestCase):
    def child(self, stdout='', stderr='', code=1):
        return subprocess.run([sys.executable, '-c',
            'import sys; sys.stdout.write(sys.argv[1]); sys.stderr.write(sys.argv[2]); sys.exit(int(sys.argv[3]))',
            stdout, stderr, str(code)], capture_output=True, text=True, timeout=10)

    def test_allows_diagnostic_logs_with_one_exact_failure(self):
        require_exact_failure(self.child(stderr='file read diagnostic\nFAIL: expected\n'), 'FAIL: expected', 'RED')

    def test_accepts_failure_on_stdout(self):
        require_exact_failure(self.child(stdout='FAIL: expected\n', stderr='diagnostic\n'), 'FAIL: expected', 'RED')

    def test_rejects_duplicate_failure_across_streams(self):
        with self.assertRaises(RuntimeError):
            require_exact_failure(self.child(stdout='FAIL: expected\n', stderr='FAIL: expected\n'), 'FAIL: expected', 'RED')

    def test_rejects_other_failure(self):
        with self.assertRaises(RuntimeError):
            require_exact_failure(self.child(stderr='FAIL: expected\nFAIL: other\n'), 'FAIL: expected', 'RED')

    def test_rejects_wrong_exit_even_with_expected_failure(self):
        for code in (0, 2):
            with self.subTest(code=code), self.assertRaises(RuntimeError):
                require_exact_failure(self.child(stderr='FAIL: expected\n', code=code), 'FAIL: expected', 'RED')

    def test_rejects_missing_or_inexact_failure(self):
        for message in ('diagnostic only\n', 'FAIL: expected suffix\n'):
            with self.subTest(message=message), self.assertRaises(RuntimeError):
                require_exact_failure(self.child(stderr=message), 'FAIL: expected', 'RED')


if __name__ == '__main__':
    unittest.main()
