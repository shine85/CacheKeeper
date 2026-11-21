"""Check local diagnostic assets without importing or starting the SSH controller."""
import ast
import hashlib
import pathlib
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]


class RuntimeDiagnosticAssetTests(unittest.TestCase):
    def namespace(self):
        source = ROOT / 'scoped_runtime_session.py'
        tree = ast.parse(source.read_text(encoding='utf-8'))
        values = {'__file__': str(source), 'pathlib': pathlib, 'sys': __import__('sys')}
        names = {'ROOT', 'BASE', 'LEGACY', 'PROBE_SCRIPT', 'PROBE_SCRIPT_SHA'}
        for node in tree.body:
            if isinstance(node, ast.Assign) and all(isinstance(t, ast.Name) and t.id in names for t in node.targets):
                exec(compile(ast.Module(body=[node], type_ignores=[]), str(source), 'exec'), values)
        return values

    def test_probe_path_and_pin_bind_the_repository_source(self):
        values = self.namespace()
        self.assertEqual(values.get('PROBE_SCRIPT'), ROOT / 'scripts/resource_access_probe.js')
        source = (ROOT / 'scripts/resource_access_probe.js').read_text(encoding='utf-8')
        self.assertEqual(hashlib.sha256(source.encode('utf-8')).hexdigest(), values['PROBE_SCRIPT_SHA'])

    def test_private_work_and_legacy_dependencies_stay_under_tmp(self):
        values = self.namespace()
        self.assertEqual(values['BASE'], ROOT / 'tmp/feedback-1792')
        self.assertEqual(values['LEGACY'], ROOT / 'tmp/feedback-172')

    def test_source_loader_rejects_changed_probe_before_use(self):
        tree=ast.parse((ROOT/'scoped_runtime_session.py').read_text(encoding='utf-8'))
        functions=[node for node in tree.body if isinstance(node,ast.FunctionDef) and node.name in ('sha','load_probe')]
        values=self.namespace();values['hashlib']=hashlib
        exec(compile(ast.Module(body=functions,type_ignores=[]),'<diagnostic-source-loader>','exec'),values)
        self.assertTrue(callable(values.get('load_probe')),'the controller must expose its checked source loader')
        source=values['load_probe']()
        self.assertIn('function collectQQImageCode()',source)
        with patch.object(pathlib.Path,'read_text',return_value=source+'\n// changed'):
            with self.assertRaisesRegex(ValueError,'probeSourceChanged'):
                values['load_probe']()


if __name__ == '__main__':
    unittest.main()
