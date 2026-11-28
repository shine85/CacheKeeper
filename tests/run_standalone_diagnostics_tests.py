"""Actual Foundation/POSIX collector and detached CLI; never claims device execution."""
from pathlib import Path
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--project-root',type=Path)
    args=parser.parse_args()
    source=Path(__file__).resolve().parents[1]
    root=(args.project_root or source).resolve()
    if sys.platform!='darwin' or not shutil.which('xcrun'):
        print('UNAVAILABLE: standalone behavior requires macOS Foundation and xcrun; no behavior ran.')
        return 2
    subprocess.run([sys.executable,str(source/'tests/test_standalone_launcher.py')],check=True,timeout=30)
    (root/'tmp').mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='standalone-',dir=root/'tmp') as workspace:
        output=Path(workspace)
        flags=['xcrun','clang','-fobjc-arc','-fblocks','-Wall','-Wextra','-Werror=format','-Werror=implicit-function-declaration',
            '-DAXS_CACHEKEEPER_HOST_CLIENT_ONLY=1','-DAXS_CACHEKEEPER_HOST_SERVER_ONLY=1',
            '-I'+str(root),'-I'+str(root/'tests/include'),'-I'+str(source/'tools/diagnose'),'-framework','Foundation']
        dependencies=[source/'tools/diagnose/AxsCacheKeeperStandaloneDiagnostics.m']+[root/name for name in (
            'AxsCacheKeeperCapacityService.m','AxsCacheKeeperCapacity.m','AxsCacheKeeperScanTask.m','AxsCacheKeeperDirectories.m',
            'AxsCacheKeeperInstallation.m','AxsCacheKeeperHostEvidence.m','AxsCacheKeeperOperationInfo.m')]
        fixture=output/'fixture';fixture.mkdir()
        old=subprocess.run(['git','show','d05e5ef4383e0d729795a292031ca8782f1ac917:tools/diagnose/AxsCacheKeeperStandaloneDiagnostics.m'],cwd=root,capture_output=True,check=True,timeout=15).stdout
        import hashlib,re
        assert hashlib.sha256(old).hexdigest()=='8e3ca1d4df52342d0ddd5d8145cfbfec9619efa89bd724ad93cada4e1a78731b'
        baseline=output/'StandaloneBeforeAggregate.m';baseline.write_bytes(old)
        red_sources=[baseline]+dependencies[1:]
        red=output/'aggregate-red'
        subprocess.run(flags+[str(source/'tests/standalone_diagnostics_tests.m')]+list(map(str,red_sources))+['-o',str(red)],check=True,timeout=60)
        red_home=output/'aggregate-red-home';red_home.mkdir()
        result=subprocess.run([str(red),str(red_home)],capture_output=True,text=True,timeout=30)
        assert result.returncode==1 and result.stdout.strip()=='' and re.findall(r'^FAIL:.*$',result.stderr,re.MULTILINE)==['FAIL: standalone: invalid saved record makes aggregate partial'],result.stdout+result.stderr
        print('PASS: fixed 232.1 invalid saved record aggregation RED')
        test_source=(source/'tests/standalone_diagnostics_tests.m').read_text(encoding='utf-8')
        assertion='    axs_cachekeeper_standalone_require([read[@"state"] isEqual:@"partial"],"invalid saved record makes aggregate partial");'
        assert test_source.count(assertion)==1
        fault_fixture=output/'fault-aggregate-fixture.m';fault_fixture.write_text(test_source.replace(assertion,''),encoding='utf-8')
        fault_red=output/'fault-aggregate-red'
        subprocess.run(flags+[str(fault_fixture)]+list(map(str,red_sources))+['-o',str(fault_red)],check=True,timeout=60)
        fault_home=output/'fault-aggregate-red-home';fault_home.mkdir()
        result=subprocess.run([str(fault_red),str(fault_home)],capture_output=True,text=True,timeout=30)
        assert result.returncode==1 and result.stdout.strip()=='' and re.findall(r'^FAIL:.*$',result.stderr,re.MULTILINE)==['FAIL: standalone: fault source read error makes aggregate partial'],result.stdout+result.stderr
        print('PASS: fixed 232.1 failed fault source aggregation RED')
        fault_assertion='    axs_cachekeeper_standalone_require([mixed[@"state"] isEqual:@"partial"] && [mixed[@"sources"][1][@"state"] isEqual:@"readError"],"fault source read error makes aggregate partial");'
        assert test_source.count(fault_assertion)==1
        eof_fixture=output/'fault-eof-fixture.m';eof_fixture.write_text(test_source.replace(assertion,'').replace(fault_assertion,''),encoding='utf-8')
        eof_red=output/'fault-eof-red'
        subprocess.run(flags+[str(eof_fixture)]+list(map(str,red_sources))+['-o',str(eof_red)],check=True,timeout=60)
        eof_home=output/'fault-eof-red-home';eof_home.mkdir()
        result=subprocess.run([str(eof_red),str(eof_home)],capture_output=True,text=True,timeout=30)
        assert result.returncode==1 and result.stdout.strip()=='' and re.findall(r'^FAIL:.*$',result.stderr,re.MULTILINE)==['FAIL: standalone: directory EOF preserves earlier metadata lookup error'],result.stdout+result.stderr
        print('PASS: fixed 232.1 metadata error lost at EOF RED')


        tests=output/'tests'
        subprocess.run(flags+[str(source/'tests/standalone_diagnostics_tests.m')]+list(map(str,dependencies))+['-o',str(tests)],check=True,timeout=60)
        subprocess.run([str(tests),str(fixture)],check=True,timeout=60)
        cli=output/'ckdiagnose'
        subprocess.run(flags+[str(source/'tools/diagnose/main.m')]+list(map(str,dependencies))+['-o',str(cli)],check=True,timeout=60)
        reports=output/'reports';reports.mkdir()
        began=time.monotonic()
        launched=subprocess.run([str(cli),'--background','--duration','2','--output',str(reports)],text=True,capture_output=True,timeout=15)
        assert launched.returncode==0,launched.stderr
        ready=json.loads(launched.stdout)
        assert ready['state']=='started' and time.monotonic()-began<10
        report=Path(ready['report']);assert report.is_file()
        data=json.loads(report.read_text())
        assert data['state']=='running','ready handshake must precede terminal status'
        deadline=time.monotonic()+20
        while data['state']=='running' and time.monotonic()<deadline:
            time.sleep(.1);data=json.loads(report.read_text())
        assert data['state'] in ('complete','partial'),data
        assert len(data['processWindow']['samples'])>=2
        assert data['safety']['processMemoryRead'] is False
        blocked=output/'not-directory';blocked.write_text('canary')
        failed=subprocess.run([str(cli),'--background','--duration','1','--output',str(blocked)],text=True,capture_output=True,timeout=15)
        assert failed.returncode!=0 and 'started' not in failed.stdout
        assert blocked.read_text()=='canary'
        print('PASS: detached worker survives launcher exit; failed output never acknowledges ready')
    return 0

if __name__=='__main__':raise SystemExit(main())
