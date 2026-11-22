"""Real subprocess lifetime and stable UI artifact boundaries; no UIKit on Windows."""
import importlib.util
import json
import os
import pathlib
import re
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT=pathlib.Path(__file__).resolve().parents[1]
SPEC=importlib.util.spec_from_file_location('ui_runner_lifecycle',ROOT/'tests/run_ui_tests.py')

class UILifecycleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module=importlib.util.module_from_spec(SPEC)
        try: SPEC.loader.exec_module(cls.module)
        except SystemExit: cls.module=None

    def test_runner_import_has_no_platform_side_effect(self):
        self.assertIsNotNone(self.module,'runner must be importable without starting UIKit or exiting')

    def test_orchestration_suite_is_safe_to_import_by_unittest_discovery(self):
        path = ROOT / 'tests/test_ui_orchestration.py'
        spec = importlib.util.spec_from_file_location('ui_orchestration_discovery', path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertTrue(callable(module.execute))

    def test_discovery_and_nested_red_have_complete_budgets(self):
        if self.module is None:self.fail('bounded command plan not implemented')
        self.assertGreaterEqual(self.module.BUDGETS['discovery'],300)
        self.assertGreater(self.module.BUDGETS['legacy_red'],5*15+60+600+420+60)
        self.assertGreater(self.module.BUDGETS['history_red'],60+600+420+60)
        self.assertGreaterEqual(self.module.RUNNER_BUDGET_SECONDS,self.module.command_budget_seconds()+self.module.MAX_COMMANDS*6)
        workflow=(ROOT/'.github/workflows/build.yml').read_text(encoding='utf-8-sig')
        uikit=workflow.split('  uikit:\n',1)[1].split('  build:\n',1)[0]
        self.assertIn('timeout-minutes: 210',uikit)
        self.assertIn('timeout-minutes: 180',uikit)
        self.assertLess(self.module.RUNNER_BUDGET_SECONDS,180*60)
        self.assertLessEqual(3+8+2+180+3+5,210)
        self.assertIn('needs: [native, uikit]',workflow)
        upload=uikit.split('uses: actions/upload-artifact@v4',1)[1]
        self.assertNotIn('.xcresult',upload)
        self.assertIn('UIKit-results.tar.gz',upload)

    def test_atomic_ledger_retries_only_known_windows_replace_errors(self):
        root=self.fixture();path=root/'summary.json';path.write_text('{"old":true}')
        original=self.module.os.replace
        for code in (5,32,33):
            calls=[]
            def replace(source,destination):
                calls.append((source,destination))
                if len(calls)==1:
                    error=PermissionError('temporary replace denial');error.winerror=code;raise error
                return original(source,destination)
            with self.subTest(code=code),patch.object(self.module.os,'name','nt'), \
                    patch.object(self.module.os,'replace',side_effect=replace), \
                    patch.object(self.module.time,'sleep') as pause:
                self.module.atomic_json(path,{'new':code})
                self.assertEqual(len(calls),2);self.assertEqual(pause.call_count,1)
                self.assertEqual(json.loads(path.read_text()),{'new':code})

    def test_atomic_ledger_persistent_denial_keeps_previous_and_pending_data(self):
        root=self.fixture();path=root/'summary.json';path.write_text('{"old":true}')
        error=PermissionError('persistent replace denial');error.winerror=5
        with patch.object(self.module.os,'name','nt'), \
                patch.object(self.module.os,'replace',side_effect=error) as replace, \
                patch.object(self.module.time,'sleep') as pause:
            with self.assertRaises(PermissionError):self.module.atomic_json(path,{'new':True})
        self.assertEqual(replace.call_count,6);self.assertEqual(pause.call_count,5)
        self.assertLessEqual(sum(call.args[0] for call in pause.call_args_list),.32)
        self.assertEqual(json.loads(path.read_text()),{'old':True})
        self.assertEqual(json.loads(path.with_name(path.name+'.partial').read_text()),{'new':True})

    def test_atomic_ledger_unknown_or_posix_denial_is_not_retried(self):
        root=self.fixture();path=root/'summary.json'
        for platform,code in (('nt',1314),('posix',5)):
            error=PermissionError('denied');error.winerror=code
            with self.subTest(platform=platform),patch.object(self.module.os,'name',platform), \
                    patch.object(self.module.os,'replace',side_effect=error) as replace, \
                    patch.object(self.module.time,'sleep') as pause:
                with self.assertRaises(PermissionError):self.module.atomic_json(path,{})
                self.assertEqual(replace.call_count,1);pause.assert_not_called()

    def test_real_command_success_failure_and_timeout(self):
        if self.module is None:self.fail('process supervisor not implemented')
        runner=self.module
        result=runner.run_command([sys.executable,'-c','print("actual-child")'],capture_output=True,text=True,timeout=3)
        self.assertEqual(result.stdout.strip(),'actual-child')
        with self.assertRaises(subprocess.CalledProcessError):
            runner.run_command([sys.executable,'-c','raise SystemExit(7)'],timeout=3)
        started=time.monotonic()
        with self.assertRaises(subprocess.TimeoutExpired):
            runner.run_command([sys.executable,'-c','import time;time.sleep(30)'],timeout=.15)
        self.assertLess(time.monotonic()-started,6)

    def test_permission_denied_group_probe_checks_real_ps_contract(self):
        group=31415
        ps=subprocess.CompletedProcess(['ps'],0,f'  {group} {group} S 501\n  {os.getpid()} 100 S 501\n','')
        with patch.object(os,'killpg',create=True,side_effect=PermissionError(1,'Operation not permitted')), \
                patch.object(os,'geteuid',create=True,return_value=501), \
                patch.object(subprocess,'run',return_value=ps) as listing:
            self.assertTrue(self.module.group_exists(group))
        self.assertEqual(listing.call_args.args[0],['ps','-Ao','pid=,pgid=,stat=,uid='])
        self.assertEqual(listing.call_args.kwargs,dict(capture_output=True,text=True,timeout=3,check=False))

    def test_permission_denied_group_probe_confirms_absent_group_is_not_running(self):
        group=31415
        ps=subprocess.CompletedProcess(['ps'],0,f'  {os.getpid()} 100 S 501\n','')
        with patch.object(os,'killpg',create=True,side_effect=PermissionError(1,'Operation not permitted')), \
                patch.object(os,'geteuid',create=True,return_value=501), \
                patch.object(subprocess,'run',return_value=ps):
            self.assertFalse(self.module.group_exists(group))

    def test_permission_denied_group_probe_ignores_zombie_members(self):
        ps=subprocess.CompletedProcess(['ps'],0,f'  901 31415 Z 501\n  {os.getpid()} 100 S 501\n','')
        with patch.object(os,'killpg',create=True,side_effect=PermissionError(1,'Operation not permitted')), \
                patch.object(os,'geteuid',create=True,return_value=501), \
                patch.object(subprocess,'run',return_value=ps):
            self.assertFalse(self.module.group_exists(31415))

    def test_permission_denied_group_probe_fails_closed_when_ps_fails(self):
        ps=subprocess.CompletedProcess(['ps'],1,'','process listing denied')
        with patch.object(os,'killpg',create=True,side_effect=PermissionError(1,'Operation not permitted')), \
                patch.object(subprocess,'run',return_value=ps):
            with self.assertRaises(self.module.GroupCleanupError):self.module.group_exists(31415)

    def test_permission_denied_group_probe_fails_closed_when_ps_times_out(self):
        with patch.object(os,'killpg',create=True,side_effect=PermissionError(1,'Operation not permitted')), \
                patch.object(subprocess,'run',side_effect=subprocess.TimeoutExpired('ps',3)):
            with self.assertRaises(self.module.GroupCleanupError):self.module.group_exists(31415)

    def test_permission_denied_group_probe_fails_closed_when_ps_cannot_start(self):
        with patch.object(os,'killpg',create=True,side_effect=PermissionError(1,'Operation not permitted')), \
                patch.object(subprocess,'run',side_effect=OSError('ps not found')):
            with self.assertRaises(self.module.GroupCleanupError):self.module.group_exists(31415)

    def test_permission_denied_group_probe_fails_closed_on_empty_ps_output(self):
        ps=subprocess.CompletedProcess(['ps'],0,'','')
        with patch.object(os,'killpg',create=True,side_effect=PermissionError(1,'Operation not permitted')), \
                patch.object(os,'getpid',return_value=700), \
                patch.object(os,'geteuid',create=True,return_value=501), \
                patch.object(subprocess,'run',return_value=ps):
            with self.assertRaises(self.module.GroupCleanupError):self.module.group_exists(31415)

    def test_permission_denied_group_probe_fails_closed_when_ps_omits_self(self):
        ps=subprocess.CompletedProcess(['ps'],0,'  901 100 S 501\n','')
        with patch.object(os,'killpg',create=True,side_effect=PermissionError(1,'Operation not permitted')), \
                patch.object(os,'getpid',return_value=700), \
                patch.object(os,'geteuid',create=True,return_value=501), \
                patch.object(subprocess,'run',return_value=ps):
            with self.assertRaises(self.module.GroupCleanupError):self.module.group_exists(31415)

    def test_permission_denied_group_probe_fails_closed_on_unknown_ps_output(self):
        ps=subprocess.CompletedProcess(['ps'],0,'not a process row\n','')
        with patch.object(os,'killpg',create=True,side_effect=PermissionError(1,'Operation not permitted')), \
                patch.object(os,'geteuid',create=True,return_value=501), \
                patch.object(subprocess,'run',return_value=ps):
            with self.assertRaises(self.module.GroupCleanupError):self.module.group_exists(31415)

    def test_permission_denied_group_probe_fails_closed_on_foreign_owner(self):
        ps=subprocess.CompletedProcess(['ps'],0,'  901 31415 S 502\n','')
        with patch.object(os,'killpg',create=True,side_effect=PermissionError(1,'Operation not permitted')), \
                patch.object(os,'geteuid',create=True,return_value=501), \
                patch.object(subprocess,'run',return_value=ps):
            with self.assertRaises(self.module.GroupCleanupError):self.module.group_exists(31415)

    def test_windows_reports_uikit_unavailable(self):
        if sys.platform=='darwin':self.skipTest('Windows-only availability check')
        result=subprocess.run([sys.executable,str(ROOT/'tests/run_ui_tests.py')],capture_output=True,text=True,timeout=5)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('UNAVAILABLE',result.stdout+result.stderr)

    def fixture(self):
        base=ROOT/'tmp/feedback-1792';base.mkdir(parents=True,exist_ok=True)
        return pathlib.Path(tempfile.mkdtemp(prefix='ui-lifecycle-',dir=base))

    def test_archiving_excludes_unfinished_result_and_preserves_failure(self):
        root=self.fixture();output=root/'tmp/input-ui-tests';output.mkdir(parents=True)
        self.module.atomic_json(output/'run-summary.json',dict(state='failed',processGroupsSettled=True,stages=[]))
        complete=output/'WebKitResults.xcresult';complete.mkdir();(complete/'Info.plist').write_bytes(b'plist')
        (complete/'data').write_bytes(b'evidence')
        incomplete=root/'tmp/image-legacy-red/RedResults.xcresult';(incomplete/'Staging').mkdir(parents=True)
        (incomplete.parent/'red.log').write_bytes(b'not a completed RED')
        (incomplete.parent/'build.log').write_bytes(b'legacy compile failure')
        search=root/'tmp/search-editing-red';search.mkdir(parents=True)
        (search/'build.log').write_bytes(b'search compile failure')
        self.assertEqual(self.module.archive_worker(root),0)
        with tarfile.open(root/'tmp/ui-artifacts/UIKit-results.tar.gz') as result:
            names=result.getnames()
            self.assertIn('tmp/input-ui-tests/WebKitResults.xcresult/data',names)
            self.assertEqual(result.extractfile('tmp/image-legacy-red/build.log').read(),b'legacy compile failure')
            self.assertEqual(result.extractfile('tmp/search-editing-red/build.log').read(),b'search compile failure')
            self.assertNotIn('tmp/image-legacy-red/RedResults.xcresult/Staging',names)
            self.assertEqual(json.load(result.extractfile('tmp/input-ui-tests/run-summary.json'))['state'],'failed')
        summary=json.loads((root/'tmp/ui-artifacts/archive-summary.json').read_text())
        self.assertEqual(summary['unavailable'][0]['reason'],'xcresultNotFinalized')

    def test_archive_never_publishes_partial_or_unsettled_group_data(self):
        root=self.fixture();output=root/'tmp/input-ui-tests';output.mkdir(parents=True)
        self.module.atomic_json(output/'run-summary.json',dict(state='running',stages=[dict(state='running')]))
        result=output/'Results.xcresult';result.mkdir();(result/'Info.plist').write_bytes(b'plist')
        self.assertEqual(self.module.archive_worker(root),0)
        with tarfile.open(root/'tmp/ui-artifacts/UIKit-results.tar.gz') as archive:
            self.assertEqual(archive.getnames(),['tmp/input-ui-tests/run-summary.json'])
        root=self.fixture();output=root/'tmp/input-ui-tests';output.mkdir(parents=True)
        self.module.atomic_json(output/'run-summary.json',dict(state='failed',processGroupsSettled=True,stages=[]))
        with patch.object(tarfile.TarFile,'addfile',side_effect=OSError('disappearing Staging')):
            self.assertEqual(self.module.archive_worker(root),1)
        self.assertFalse((root/'tmp/ui-artifacts/UIKit-results.tar.gz').exists())
        self.assertEqual(json.loads((root/'tmp/ui-artifacts/archive-summary.json').read_text())['state'],'failed')

    def test_cancel_marks_active_stage_and_skips_exports(self):
        root=self.fixture();run=self.module.UIRun(root)
        def cancelled(*args,**kwargs):raise self.module.Cancelled(signal.SIGTERM)
        with patch.object(self.module,'run_command',side_effect=cancelled):
            self.assertEqual(run.execute(),128+signal.SIGTERM)
        value=json.loads((run.output/'run-summary.json').read_text())
        self.assertEqual(value['state'],'cancelled')
        self.assertEqual(value['stages'][0]['state'],'cancelled')
        self.assertEqual(len(value['stages']),1)
        self.assertTrue(all(state=='notRun' for state in value['suites'].values()))

    @unittest.skipUnless(os.name=='posix','UNAVAILABLE: real POSIX process groups require macOS/Linux')
    def test_timeout_and_wrapper_exit_reap_real_descendant_group(self):
        root=self.fixture()
        for exit_early in (False,True):
            pidfile=root/('child-'+str(exit_early))
            child='import time;time.sleep(60)'
            parent=('import subprocess,sys,pathlib,time; p=subprocess.Popen([sys.executable,"-c",'+repr(child)+']);'
                    'pathlib.Path('+repr(str(pidfile))+').write_text(str(p.pid));'+('raise SystemExit(7)' if exit_early else 'p.wait()'))
            expected=subprocess.CalledProcessError if exit_early else subprocess.TimeoutExpired
            with self.assertRaises(expected):self.module.run_command([sys.executable,'-c',parent],timeout=1)
            pid=int(pidfile.read_text())
            with self.assertRaises(ProcessLookupError):os.kill(pid,0)

    @unittest.skipUnless(os.name=='posix','UNAVAILABLE: real POSIX process groups require macOS/Linux')
    def test_permission_denied_group_probe_still_reaps_real_descendant(self):
        root=self.fixture();pidfile=root/'child-eprem'
        child='import time;time.sleep(60)'
        parent=('import subprocess,sys,pathlib,os; p=subprocess.Popen([sys.executable,"-c",'+repr(child)+']);'
                'pathlib.Path('+repr(str(pidfile))+').write_text(str(os.getpid())+" "+str(p.pid));p.wait()')
        original_group,original_process=os.killpg,os.kill
        def deny_group_signal(pgid,signum):
            if signum==0:raise PermissionError(1,'Operation not permitted')
            return original_group(pgid,signum)
        try:
            with patch.object(os,'killpg',side_effect=deny_group_signal), \
                    patch.object(os,'kill',side_effect=original_process):
                with self.assertRaises(subprocess.TimeoutExpired):
                    self.module.run_command([sys.executable,'-c',parent],timeout=1)
            group,child_pid=map(int,pidfile.read_text().split())
            with self.assertRaises(ProcessLookupError):os.kill(child_pid,0)
        finally:
            try:original_group(int(pidfile.read_text().split()[0]),signal.SIGKILL)
            except (FileNotFoundError,ProcessLookupError):pass

    @unittest.skipUnless(os.name=='posix','UNAVAILABLE: real POSIX cancellation requires macOS/Linux')
    def test_sigterm_interrupts_owned_command_and_reaps_child(self):
        root=self.fixture();pidfile=root/'child.pid'
        code=('import importlib.util,pathlib,sys;'
              's=importlib.util.spec_from_file_location("runner",'+repr(str(ROOT/'tests/run_ui_tests.py'))+');'
              'm=importlib.util.module_from_spec(s);s.loader.exec_module(m)\n'
              'try:\n with m.cancellation_signals():\n  m.run_command([sys.executable,"-c",'
              +repr('import os,pathlib,time;pathlib.Path('+repr(str(pidfile))+').write_text(str(os.getpid()));time.sleep(60)')+
              '],timeout=50)\nexcept m.Cancelled:raise SystemExit(143)\n')
        parent=subprocess.Popen([sys.executable,'-c',code])
        try:
            deadline=time.monotonic()+5
            while not pidfile.exists() and time.monotonic()<deadline:time.sleep(.02)
            self.assertTrue(pidfile.exists())
            parent.send_signal(signal.SIGTERM)
            self.assertEqual(parent.wait(timeout=7),143)
            with self.assertRaises(ProcessLookupError):os.kill(int(pidfile.read_text()),0)
        finally:
            if parent.poll() is None:parent.kill();parent.wait(timeout=3)

if __name__=='__main__':unittest.main(verbosity=2)
