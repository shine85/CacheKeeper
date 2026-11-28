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
