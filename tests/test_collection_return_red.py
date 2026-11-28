"""Execute RED preparation against real repository files; replace only unavailable Apple tools."""
from pathlib import Path
import importlib.util
import contextlib
import io
import json
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]


class ReturnRedTests(unittest.TestCase):
    def test_real_source_mutation_project_and_expected_failure(self):
        (ROOT/'tmp').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='return-red-runner-',dir=ROOT/'tmp') as folder:
            root=Path(folder);(root/'tests/ui').mkdir(parents=True);(root/'Prefs').mkdir()
            for source in ('Prefs/Settings.m','tests/ui/project.yml'):
                (root/source).write_bytes((ROOT/source).read_bytes())
            spec=importlib.util.spec_from_file_location('return_red',ROOT/'tests/run_collection_return_red.py')
            runner=importlib.util.module_from_spec(spec);spec.loader.exec_module(runner)
            commands=[]
            def run(command,**options):
                commands.append(command)
                return subprocess.CompletedProcess(command,65 if command[1]=='test-without-building' else 0)
            summary={'failedTests':1,'totalTestCount':1,'testFailures':[{'testIdentifier':'testRecreatedRootAutomaticallyReturnsToOriginalImageWithoutContinue','failureText':'COLLECTION_AUTO_RETURN: original image page must reappear without tapping Continue'}]}
            with patch.object(runner,'__file__',str(root/'tests/run_collection_return_red.py')),patch.object(sys,'argv',['runner','DEVICE']),patch.object(subprocess,'run',side_effect=run),patch.object(subprocess,'check_output',return_value=json.dumps(summary)),contextlib.redirect_stdout(io.StringIO()):
                runner.main()
            self.assertEqual([command[0] for command in commands],['xcodegen','xcodebuild','xcodebuild'])
            output=root/'tmp/collection-return-red'
            mutated=(output/'Settings.m').read_text(encoding='utf8')
            self.assertIn('- (void)axs_cachekeeper_restore_collection {}',mutated)
            self.assertIn('AxsCacheKeeperCollectionHistory.m',(output/'project.yml').read_text(encoding='utf8'))
            self.assertTrue((output/'red-summary.json').is_file());self.assertTrue((output/'source-manifest.json').is_file())


if __name__=='__main__':unittest.main()
