"""Actual RED runner file handling; only unavailable Xcode commands are replaced."""
import importlib.util
import json
import pathlib
import shutil
import subprocess
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]


class CleanupSummaryDiagnosticsTests(unittest.TestCase):
    def execute(self, failure=None, accepted=True):
        spec = importlib.util.spec_from_file_location('cleanup_summary_diagnostics', ROOT / 'tests/run_cleanup_summary_red.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory(prefix='summary-diagnostics-test-', dir=ROOT / 'tmp') as temp:
            root = pathlib.Path(temp)
            for name in ('Prefs/ScanPage.m', 'tests/ui/ScanPageTests.m', 'tests/ui/project.yml'):
                target = root / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / name, target)
            artifact = root / 'tmp/history-display-red-results'
            artifact.mkdir(parents=True)
            (artifact / 'summary.json').write_text('{"priorRun": true}', encoding='utf-8')
            module.__file__ = str(root / 'tests/run_cleanup_summary_red.py')
            module.sys = types.SimpleNamespace(platform='darwin', argv=['runner', 'test-simulator'])

            def run(command, **kwargs):
                phase = 'generate' if command[0] == 'xcodegen' else ('build' if command[1] == 'build-for-testing' else 'test')
                if kwargs.get('stdout') is not None:
                    kwargs['stdout'].write('actual-file-diagnostic:' + phase + '\n')
                if phase == failure:
                    if phase == 'build':
                        raise subprocess.CalledProcessError(66, command)
                    raise subprocess.TimeoutExpired(command, kwargs['timeout'])
                return subprocess.CompletedProcess(command, 65 if phase == 'test' else 0)

            def summary(command, **kwargs):
                if failure == 'summary':
                    raise subprocess.TimeoutExpired(command, kwargs['timeout'])
                return json.dumps({'failedTests': 2, 'totalTestCount': 2, 'testFailures': [
                    {'testName': method, 'failureText': 'HISTORY_CONFIGURATION:' if accepted else 'unrelated failure'}
                    for method in ('testDisabledAppKeepsHistoricalSummaryAndActionStatus',
                                   'testEnabledAppWithoutDirectoriesKeepsHistoricalSummaryAndActionStatus')]})

            with patch.object(module.subprocess, 'run', side_effect=run), \
                    patch.object(module.subprocess, 'check_output', side_effect=summary):
                if failure:
                    error = subprocess.CalledProcessError if failure == 'build' else subprocess.TimeoutExpired
                    with self.assertRaises(error):
                        module.main()
                elif not accepted:
                    with self.assertRaisesRegex(RuntimeError, 'did not fail solely'):
                        module.main()
                else:
                    self.assertEqual(module.main(), 0)
            rounds = [path for path in artifact.iterdir() if path.is_dir()]
            self.assertEqual(len(rounds), 1, 'this round must retain diagnostics before temporary build cleanup')
            report = json.loads((rounds[0] / 'status.json').read_text(encoding='utf-8'))
            self.assertEqual(report['state'], 'passed' if not failure and accepted else 'failed')
            expected_logs = ['generate.log'] + ([] if failure == 'generate' else ['build.log'])
            if failure not in ('generate', 'build'):
                expected_logs.append('red.log')
            for name in expected_logs:
                self.assertIn('actual-file-diagnostic:', (rounds[0] / name).read_text(encoding='utf-8'))
            self.assertEqual(json.loads((artifact / 'summary.json').read_text()), {'priorRun': True})
            self.assertEqual((rounds[0] / 'summary.json').exists(), failure not in ('generate', 'build', 'test', 'summary'))

    def test_generation_timeout_keeps_closed_log(self): self.execute('generate')
    def test_build_failure_keeps_closed_log(self): self.execute('build')
    def test_test_timeout_keeps_closed_logs(self): self.execute('test')
    def test_summary_timeout_keeps_closed_logs(self): self.execute('summary')
    def test_unrelated_test_failure_remains_failed(self): self.execute(accepted=False)
    def test_exact_negative_control_preserves_this_round(self): self.execute()


if __name__ == '__main__':
    unittest.main()
