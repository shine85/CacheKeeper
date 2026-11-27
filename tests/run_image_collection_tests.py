"""Real Foundation files and production image collection transaction."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT=Path(__file__).resolve().parents[1]
if sys.platform!='darwin' or not shutil.which('xcrun'):
    print('UNAVAILABLE: image collection transaction requires macOS Foundation; no behavior ran.')
    raise SystemExit(2)
(ROOT/'tmp').mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='image-collection-',dir=ROOT/'tmp') as folder:
    output=Path(folder); binary=output/'tests'
    flags=['xcrun','clang','-fobjc-arc','-fblocks','-Wall','-Wextra','-Werror=format','-Werror=implicit-function-declaration',
           '-I'+str(ROOT/'tests/include'),'-framework','Foundation']
    sources=[str(ROOT/name) for name in ('AxsCacheKeeperImageCollection.m','AxsCacheKeeperOperationInfo.m','tests/image_collection_tests.m')]
    subprocess.run(flags+sources+['-o',str(binary)],check=True,timeout=60)
    subprocess.run([str(binary),str(output/'green')],check=True,timeout=30)
    # Exact semantic RED changes the production overlay, with the same file/receipt path.
    red=output/'red';(red/'tests').mkdir(parents=True)
    for name in ('AxsCacheKeeperImageCollection.m','AxsCacheKeeperImageCollection.h'):
        shutil.copyfile(ROOT/name,red/name)
    # The copied status header and transaction must share the same mutated inline contract.
    shutil.copyfile(ROOT/'AxsCacheKeeperImageCacheStatus.h',red/'AxsCacheKeeperImageCacheStatus.h')
    source=(red/'AxsCacheKeeperImageCollection.h').read_text()
    anchor='context[@"appState"]=effective;'
    assert source.count(anchor)==1
    (red/'AxsCacheKeeperImageCollection.h').write_text(source.replace(anchor,'context[@"appState"]=base[@"appState"];'))
    shutil.copyfile(ROOT/'tests/image_collection_tests.m',red/'tests/image_collection_tests.m')
    red_binary=output/'red-tests'
    subprocess.run(flags+['-I'+str(ROOT),str(red/'AxsCacheKeeperImageCollection.m'),str(ROOT/'AxsCacheKeeperOperationInfo.m'),str(red/'tests/image_collection_tests.m'),'-o',str(red_binary)],check=True,timeout=60)
    result=subprocess.run([str(red_binary),str(output/'red-home')],capture_output=True,text=True,timeout=30)
    assert result.returncode==1 and result.stderr.strip()=='FAIL: image-collection: image-only lease changes effective mode',result.stderr
    print('PASS: exact prior-no-overlay behavior RED')
