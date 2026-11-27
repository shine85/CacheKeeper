"""Compile and run the durable on-device collection session state machine."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT=Path(__file__).resolve().parents[1]
if sys.platform!='darwin' or not shutil.which('xcrun'):
    print('UNAVAILABLE: collection session Foundation tests require macOS and xcrun; no native tests ran.')
    raise SystemExit(2)
(ROOT/'tmp').mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='collection-session-',dir=ROOT/'tmp') as folder:
    output=Path(folder);binary=output/'collection-session-tests'
    subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-Wall','-Wextra','-Werror=format','-framework','Foundation',
                    '-I'+str(ROOT/'tests/include'),str(ROOT/'AxsCacheKeeperCollectionSession.m'),str(ROOT/'tests/collection_session_tests.m'),
                    *[str(ROOT/(name+'.m')) for name in ('AxsCacheKeeperImageCollection','AxsCacheKeeperOperationInfo','AxsCacheKeeperInstallation','AxsCacheKeeperHostEvidence','AxsCacheKeeperCapacityService','AxsCacheKeeperCapacity','AxsCacheKeeperScanTask','AxsCacheKeeperDirectories')],'-o',str(binary)],
                   check=True,timeout=60)
    subprocess.run([str(binary),str(output)],check=True,timeout=15)
    subprocess.run([sys.executable,str(ROOT/'scripts/device_collection_manifest.py'),str(output/'native-capacity-report.json')],check=True,timeout=15)
