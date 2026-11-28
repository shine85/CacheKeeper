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
    output=Path(folder)
    flags=['xcrun','clang','-fobjc-arc','-fblocks','-Wall','-Wextra','-Werror=format','-framework','Foundation','-I'+str(ROOT/'tests/include')]
    production=[str(ROOT/(name+'.m')) for name in ('AxsCacheKeeperCollectionSession','AxsCacheKeeperCollectionReturn','AxsCacheKeeperCollectionHistory',
        'AxsCacheKeeperImageCollection','AxsCacheKeeperOperationInfo','AxsCacheKeeperInstallation','AxsCacheKeeperHostEvidence',
        'AxsCacheKeeperCapacityService','AxsCacheKeeperCapacity','AxsCacheKeeperScanTask','AxsCacheKeeperDirectories')]
    for fixture,destination,budget in [('collection_session_tests',output,15),('collection_return_tests',output/'return',15),('collection_history_tests',output/'history',30)]:
        binary=output/fixture
        subprocess.run(flags+production+[str(ROOT/'tests'/(fixture+'.m')),'-o',str(binary)],check=True,timeout=60)
        subprocess.run([str(binary),str(destination)],check=True,timeout=budget)
        if fixture=='collection_session_tests':
            subprocess.run([sys.executable,str(ROOT/'scripts/device_collection_manifest.py'),str(output/'native-capacity-report.json')],check=True,timeout=15)
