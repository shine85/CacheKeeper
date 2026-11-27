"""离线入口在无真实传输模块的干净目录运行；新文件无旧版可备份。"""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
BUNDLES = ('com.ss.iphone.ugc.Aweme', 'com.tencent.mqq', 'com.baidu.netdisk',
           'com.360buy.jdmobile', 'app.swiftgram.ios')


class SessionCLITests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='focused-session-cli-', dir=ROOT/'tmp')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        scripts = self.root/'scripts'
        scripts.mkdir()
        for name in ('collect_device.py', 'device_collection_batch.py',
                     'device_sdk_incremental.py', 'device_collection_session.py',
                     'device_collection_diagnostics.py',
                     'device_collection_phase_report.py'):
            source = ROOT/'scripts'/name
            if source.exists():
                shutil.copy2(source, scripts/name)
        source_dir = scripts/'device_collection_sources'
        source_dir.mkdir()
        for name in ('report_io.py', 'sdk_receipt.py'):
            shutil.copy2(ROOT/'scripts/device_collection_sources'/name, source_dir/name)
        # 若离线分支错误进入传输，实际导入这个模块会落下标记并失败。
        (scripts/'device_collection_transport.py').write_text(
            "from pathlib import Path\n"
            "Path(__file__).with_name('TRANSPORT_IMPORTED').write_text('bad', encoding='utf-8')\n"
            "raise AssertionError('offline command imported device transport')\n", encoding='utf-8')
        run = self.root/'20261126T000000Z-12345678'
        run.mkdir()
        self.report = run/'collection.json'
        rows = [dict(bundle=b, staticState='failed', runtimeState='notAttempted',
                     sdkEvidence=dict(state='notAttemptedMissingIdentity')) for b in BUNDLES]
        data = dict(schemaVersion=1, runID=run.name, state='partial',
                    scope='allCurrentRegisteredApplicationMetadata', membershipCount=5, apps=rows,
                    sdkCollectionRequested=True, runtimeExecuted=False, appLaunchExecuted=False,
                    resourceDeletionExecuted=False, summary=dict(collected=0, failed=5,
                        attemptedOutcomeUnknown=0, notAttemptedConnection=0, notAttemptedBudget=0))
        self.report.write_text(json.dumps(data), encoding='utf-8')
        self.output = self.root/'五APP准备.zip'

    def run_cli(self, *args):
        result = subprocess.run([sys.executable, '-X', 'utf8', '-B',
                                 str(self.root/'scripts/collect_device.py'), *map(str, args)],
                                cwd=self.root, text=True, encoding='utf-8', capture_output=True, timeout=20)
        self.assertFalse((self.root/'scripts/TRANSPORT_IMPORTED').exists(), result.stderr)
        return result

    def test_prepare_creates_explicit_offline_package_without_transport(self):
        result = self.run_cli('--prepare-session', self.report, '--output', self.output)
        self.assertEqual(result.returncode, 0, result.stderr)
        summary = json.loads(result.stdout)
        self.assertEqual(summary['state'], 'offlinePreparationComplete')
        self.assertFalse(summary['executionAvailable'])
        self.assertEqual(summary['sha256'], hashlib.sha256(self.output.read_bytes()).hexdigest())
        with zipfile.ZipFile(self.output) as archive:
            self.assertEqual(set(archive.namelist()), {'session.json', 'manifest.json', 'README.md'})
            self.assertNotIn('TRANSPORT_IMPORTED', archive.read('README.md').decode('utf-8'))

    def test_bad_input_never_creates_package_or_imports_transport(self):
        self.report.write_text('{broken', encoding='utf-8')
        result = self.run_cli('--prepare-session', self.report, '--output', self.output)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stderr)['state'], 'sessionPreparationFailed')
        self.assertFalse(self.output.exists())

    def test_prepare_rejects_remote_options_and_missing_output_before_work(self):
        for args in (
            ('--prepare-session', self.report),
            ('--output', self.output),
            ('--prepare-session', self.report, '--output', self.output, '--resume', self.report),
            ('--prepare-session', self.report, '--output', self.output, '--transport-adapter', 'unused.py'),
            ('--diagnostics', 'unused.json'),
            ('--prepare-session', self.report, '--output', self.output, '--baseline-diagnostics', 'unused.json'),
        ):
            with self.subTest(args=args):
                result = self.run_cli(*args)
                self.assertEqual(result.returncode, 2)
                self.assertFalse(self.output.exists())

    def test_diagnostics_are_embedded_without_copying_private_fields_or_loading_transport(self):
        diagnostic = self.root/'diagnostic.json'
        baseline = self.root/'baseline.json'
        data = dict(schemaVersion=1, generatedAt=1234,
                    environment=dict(pluginVersion='0.7.2-215.1'), apps=[],
                    privateField='SECRET_DIAGNOSTIC_CANARY')
        diagnostic.write_text(json.dumps(data), encoding='utf-8')
        baseline.write_text(json.dumps(data), encoding='utf-8')
        result = self.run_cli('--prepare-session', self.report, '--output', self.output,
                              '--diagnostics', diagnostic, '--baseline-diagnostics', baseline)
        self.assertEqual(result.returncode, 0, result.stderr)
        with zipfile.ZipFile(self.output) as archive:
            session = json.loads(archive.read('session.json'))
            analysis = session['diagnostics']
            self.assertEqual(analysis['sourceSHA256'], hashlib.sha256(diagnostic.read_bytes()).hexdigest())
            self.assertEqual(analysis['baselineSHA256'], hashlib.sha256(baseline.read_bytes()).hexdigest())
            self.assertEqual(len(analysis['apps']), 5)
            self.assertFalse(session['executionAvailable'])
            self.assertEqual(session['capabilityGate']['state'],'blocked')
            self.assertFalse(session['capabilityGate']['executionAvailable'])
            self.assertNotIn('SECRET_DIAGNOSTIC_CANARY', archive.read('session.json').decode('utf-8'))

    def test_phase_reports_are_embedded_and_missing_app_capabilities_are_blocked(self):
        base=ROOT/'tests/fixtures/collection-phases'
        manifest=json.loads((base/'manifest.json').read_text(encoding='utf-8'))
        reports=[(stage,base/item['file'],item['sha256']) for stage,item in manifest.items()]
        result=self.run_cli('--prepare-session',self.report,'--output',self.output,
                            *[arg for stage,path,pin in reports for arg in ('--phase-report',f'{stage}={path}={pin}')])
        self.assertEqual(result.returncode,0,result.stderr)
        with zipfile.ZipFile(self.output) as archive:
            session=json.loads(archive.read('session.json'))
            self.assertEqual(len(session['phaseReports']['apps']),5)
            self.assertEqual(session['capabilityGate']['state'],'blocked')
            self.assertFalse(session['capabilityGate']['executionAvailable'])
            for app in session['capabilityGate']['apps']:
                self.assertEqual(app['overall'],'blockedByCapability')
                self.assertTrue(app['blockedCapabilities'])
                self.assertTrue(all(item['state']=='blockedByCapability' for item in app['blockedCapabilities']))
            baidu=next(row for row in session['phaseReports']['apps'] if row['bundle']=='com.baidu.netdisk')
            self.assertEqual(baidu['stages']['prevent']['writer']['nonempty'],dict(attempts=30,blocked=29,allowed=1))
            self.assertEqual(baidu['stages']['disabled']['outcome'],'insufficientEvidence')
            douyin=next(row for row in session['phaseReports']['apps'] if row['bundle']=='com.ss.iphone.ugc.Aweme')
            self.assertTrue(all(op['submission']=='notSubmitted' for op in douyin['stages']['prevent']['gurd']['operations']))

    def test_duplicate_or_bad_phase_source_aborts_report_creation(self):
        base=ROOT/'tests/fixtures/collection-phases';source=base/'prevent.json'
        duplicate=self.run_cli('--prepare-session',self.report,'--output',self.output,
                                '--phase-report',f'prevent={source}','--phase-report',f'prevent={source}')
        self.assertEqual(duplicate.returncode,2);self.assertFalse(self.output.exists())
    def test_existing_output_is_preserved(self):
        self.output.write_bytes(b'previous-report')
        result = self.run_cli('--prepare-session', self.report, '--output', self.output)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stderr)['state'], 'sessionPreparationFailed')
        self.assertEqual(self.output.read_bytes(), b'previous-report')


if __name__ == '__main__':
    unittest.main()
