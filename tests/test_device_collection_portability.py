"""Run a clean copy without ignored history or an implicit device connection."""
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))


class PortabilityTests(unittest.TestCase):
    def checkout(self, directory):
        root = Path(directory) / 'checkout'
        (root / 'scripts').mkdir(parents=True)
        (root / 'tests').mkdir()
        (root / 'tmp').mkdir()
        for name in ('collect_device.py', 'device_collection_batch.py',
                     'device_sdk_incremental.py', 'device_collection_transport.py'):
            source = ROOT / 'scripts' / name
            if source.exists():
                shutil.copy2(source, root / 'scripts' / name)
        source = ROOT / 'scripts/device_collection_sources'
        if source.exists():
            shutil.copytree(source, root / 'scripts/device_collection_sources',
                            ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
        shutil.copy2(ROOT / 'tests/test_device_collection_batch.py', root / 'tests')
        return root

    def run_python(self, root, *arguments):
        return subprocess.run([sys.executable, '-I', '-B', '-X', 'utf8', *arguments],
                              cwd=root, capture_output=True, text=True, encoding='utf-8', timeout=35)

    def test_clean_checkout_runs_actual_bash_entire_static_controller(self):
        with tempfile.TemporaryDirectory(prefix='collection-portable-', dir=ROOT / 'tmp') as directory:
            root = self.checkout(directory)
            result = self.run_python(root, '-c',
                "import sys,unittest;sys.path.insert(0,'tests');"
                "from test_device_collection_batch import BatchTests;"
                "suite=unittest.TestSuite([BatchTests('test_full_controller_runs_real_bash_membership_and_collector')]);"
                "result=unittest.TextTestRunner(verbosity=2).run(suite);raise SystemExit(not result.wasSuccessful())")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_cli_help_and_missing_adapter_never_create_queue(self):
        with tempfile.TemporaryDirectory(prefix='collection-portable-', dir=ROOT / 'tmp') as directory:
            root = self.checkout(directory)
            help_result = self.run_python(root, 'scripts/collect_device.py', '--help')
            self.assertEqual(help_result.returncode, 0, help_result.stderr)
            result = self.run_python(root, 'scripts/collect_device.py')
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn('collectionTransportUnavailable', result.stderr)
            self.assertEqual(list((root / 'tmp').iterdir()), [])
            self.assertFalse((root / 'packages').exists())

    def test_clean_checkout_cli_uses_real_bash_adapter_and_keeps_sdk_objects(self):
        with tempfile.TemporaryDirectory(prefix='collection-portable-', dir=ROOT / 'tmp') as directory:
            root = self.checkout(directory)
            transport = Path(directory) / 'authorized-adapter'
            app = transport / 'Fixture.app'
            app.mkdir(parents=True)
            (app / 'Info.plist').write_bytes(b'fixture')
            header = (struct.pack('<8I', 0xfeedfacf, 0x100000c, 2, 2, 1, 24, 0, 0) +
                      struct.pack('<II', 27, 24) + bytes.fromhex('11' * 16))
            (app / 'Main').write_bytes(header + b'PRIVATE_BODY_MUST_NOT_RETURN')
            utilities = transport / 'bin'
            utilities.mkdir()
            for name, source in {
                'timeout': '#!/bin/bash\n[[ $1 == --kill-after=* ]] && shift\nshift\n"$@"\n',
                'rootfs': '#!/bin/bash\nprintf "%s\\n" "$1"\n',
                'uicache': '''#!/bin/bash
if [[ $1 == -l ]]; then printf 'b.good : %s/Fixture.app\\n' "$PWD"; else printf 'Path: %s/Fixture.app\\n' "$PWD"; fi
''',
                'plutil': '''#!/bin/bash
if [[ $1 == -help ]]; then echo '-extract'; exit 0; fi
case "$2" in CFBundleIdentifier) echo b.good;; CFBundleShortVersionString) echo 1.2;; CFBundleVersion) echo 3;; CFBundleExecutable) echo Main;; *) exit 8;; esac
''',
            }.items():
                (utilities / name).write_text(source, encoding='utf-8')
            (transport / 'adapter.py').write_text('''from contextlib import nullcontext
from pathlib import Path
import json,shutil,subprocess
ROOT=Path(__file__).resolve().parent
BASE=ROOT/'session'
def read_state(*,until=None):
    return dict(session='a'*32,protocolVersion=3,state='ready',local=str(BASE/('a'*32)))
def queue_lock():return nullcontext()
def enqueue_locked(script,ident,seconds):
    (ROOT/'current.sh').write_text(script,encoding='utf-8')
    result=subprocess.run([shutil.which('bash'),'-c','chmod +x bin/*; PATH="$PWD/bin:$PATH" bash current.sh'],cwd=ROOT,capture_output=True,text=True,timeout=25)
    path=BASE/('a'*32)/'results'/(ident+'.json')
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(json.dumps(dict(id=ident,session='a'*32,state='completed' if result.returncode==0 else 'commandFailed',exitCode=result.returncode,output=result.stdout,lines=result.stdout.splitlines())))
    return path
def read_json(path,*,until=None):return json.loads(path.read_text())
''', encoding='utf-8')
            result = self.run_python(root, 'scripts/collect_device.py', '--transport-adapter', str(transport / 'adapter.py'))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            summary = json.loads(result.stdout)
            self.assertEqual(summary['state'], 'declaredStaticScopeComplete')
            report_path = root / summary['report']
            report = json.loads(report_path.read_text(encoding='utf-8'))
            self.assertEqual(report['summary']['collected'], 1)
            self.assertEqual(report['apps'][0]['identity']['uuid'], '11' * 16)
            self.assertFalse(report['runtimeExecuted'])
            receipt_path = report_path.parent / report['apps'][0]['sdkEvidence']['receipt']
            receipt = json.loads(receipt_path.read_text(encoding='utf-8'))
            retained = receipt['images'][0]['ranges'][0]
            self.assertEqual((receipt_path.parent / retained['file']).read_bytes(), header)
            self.assertEqual(len(list((transport / 'session').rglob('*.json'))), 4)

    def test_explicit_adapter_keeps_its_session_and_persists_failed_batch(self):
        with tempfile.TemporaryDirectory(prefix='collection-portable-', dir=ROOT / 'tmp') as directory:
            root = self.checkout(directory)
            transport = Path(directory) / 'authorized-adapter'
            transport.mkdir()
            (transport / 'fixture_config.py').write_text("SESSION='a'*32\n", encoding='utf-8')
            (transport / 'adapter.py').write_text('''from contextlib import nullcontext
from pathlib import Path
import json
from fixture_config import SESSION
BASE=Path(__file__).resolve().parent/'session'
def read_state(*,until=None):
    return dict(session=SESSION,protocolVersion=3,state='ready',local=str(BASE/SESSION))
def queue_lock():return nullcontext()
def enqueue_locked(script,ident,seconds):
    result=BASE/SESSION/'results'/(ident+'.json')
    result.parent.mkdir(parents=True,exist_ok=True)
    result.write_text(json.dumps(dict(id=ident,session=SESSION,state='commandFailed',exitCode=7,output='',lines=[])))
    return result
def read_json(path,*,until=None):return json.loads(path.read_text())
''', encoding='utf-8')
            result = self.run_python(root, 'scripts/collect_device.py', '--transport-adapter', str(transport / 'adapter.py'))
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            summary = json.loads(result.stdout)
            self.assertEqual(summary['state'], 'enumerationFailed')
            report = json.loads((root / summary['report']).read_text(encoding='utf-8'))
            self.assertEqual(report['session'], 'a' * 32)
            self.assertFalse(report['runtimeExecuted'])
            self.assertEqual(len(list((transport / 'session').rglob('*.json'))), 1)
            self.assertEqual(list((root / 'tmp').iterdir()), [])

    def test_default_adapter_reads_existing_local_session_without_starting_service(self):
        with tempfile.TemporaryDirectory(prefix='collection-portable-', dir=ROOT / 'tmp') as directory:
            root = self.checkout(directory)
            adapter = root / 'scripts/persistent_device_ssh.py'
            adapter.write_text('''from contextlib import nullcontext
from pathlib import Path
BASE=Path(__file__).resolve().parents[1]/'tmp/persistent-ssh'
def read_state(*,until=None):
    return dict(session='b'*32,protocolVersion=3,state='ready',local=str(BASE/('b'*32)))
def queue_lock():return nullcontext()
def enqueue_locked(*args):raise RuntimeError('fixtureQueueUnavailable')
def read_json(*args,**kwargs):raise AssertionError('result not submitted')
def serve(*args):raise AssertionError('must not start SSH')
''', encoding='utf-8')
            result = self.run_python(root, 'scripts/collect_device.py')
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            summary = json.loads(result.stdout)
            self.assertEqual(summary['state'], 'enumerationFailed')
            report = json.loads((root / summary['report']).read_text(encoding='utf-8'))
            self.assertEqual(report['session'], 'b' * 32)
            self.assertEqual(list((root / 'tmp').iterdir()), [])

    def test_queue_rejects_foreign_session_directory_and_forged_results(self):
        from contextlib import nullcontext
        from types import SimpleNamespace
        from device_collection_transport import QueueTasks

        with tempfile.TemporaryDirectory(prefix='collection-portable-', dir=ROOT / 'tmp') as directory:
            base = Path(directory)
            state = dict(session='a' * 32, protocolVersion=3, state='ready',
                         local=str(base / ('a' * 32)))
            transport = SimpleNamespace(BASE=base, read_state=lambda **kwargs: dict(state),
                                        queue_lock=nullcontext)
            tasks = QueueTasks(transport)
            state['local'] = str(base / 'foreign' / ('a' * 32))
            with self.assertRaisesRegex(ValueError, 'persistentConnectionPath'):
                tasks.task('echo fixture', 10)
            state['local'] = str(base / ('a' * 32))
            state['session'] = 'b' * 32
            with self.assertRaisesRegex(ValueError, 'persistentConnectionBinding'):
                tasks.task('echo fixture', 10)
            state['session'] = 'a' * 32

            def enqueue(script, ident, seconds):
                path = base / ('a' * 32) / 'results' / (ident + '.json')
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(json.dumps(dict(id=ident, session='b' * 32,
                    state='completed', exitCode=0, output='fixture\n', lines=['fixture'])))
                return path

            transport.enqueue_locked = enqueue
            transport.read_json = lambda path, **kwargs: json.loads(path.read_text())
            with self.assertRaisesRegex(RuntimeError, 'persistentTaskResultBinding'):
                tasks.task('echo fixture', 10)


if __name__ == '__main__':
    unittest.main()
