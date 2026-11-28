"""Real Foundation files and production image collection transaction."""
from pathlib import Path
import hashlib
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
    # Prove the new file-backed entry assertion fails on the shipped 220.1 implementation.
    prior=output/'prior-entry';prior.mkdir()
    source=subprocess.run(['git','show','46721186e6e221b3bc7637ee0eae3bcef145cec2:AxsCacheKeeperImageCollection.m'],
                          check=True,capture_output=True,timeout=30).stdout
    assert hashlib.sha256(source).hexdigest()=='dee50cd3757f28f3905e14588fdb12066bf4f383eb437735c787ae1d3d10d9f9'
    (prior/'AxsCacheKeeperImageCollection.m').write_bytes(source)
    prior_binary=output/'prior-entry-tests'
    subprocess.run(flags+['-I'+str(ROOT),str(prior/'AxsCacheKeeperImageCollection.m'),
                          str(ROOT/'AxsCacheKeeperOperationInfo.m'),str(ROOT/'tests/image_collection_tests.m'),
                          '-o',str(prior_binary)],check=True,timeout=60)
    result=subprocess.run([str(prior_binary),str(output/'prior-entry-home')],capture_output=True,text=True,timeout=30)
    assert result.returncode==1 and result.stderr.strip()=='FAIL: image-collection: candidate check and rejection reasons survive reopening before start',result.stderr
    print('PASS: fixed 220.1 missing entry persistence exact RED',hashlib.sha256(source).hexdigest())
    stale_source=subprocess.run(['git','show','6af0c5e7563840daf51bd0d97dee2530af3dc5db:AxsCacheKeeperImageCollection.m'],check=True,capture_output=True,timeout=30).stdout
    assert hashlib.sha256(stale_source).hexdigest()=='31f61e0ec6f86bb5b33cbb5c33c31ab0e2082907b7bedc1e073273d665fefe34'
    (prior/'AxsCacheKeeperImageCollection.m').write_bytes(stale_source)
    subprocess.run(flags+['-I'+str(ROOT),str(prior/'AxsCacheKeeperImageCollection.m'),str(ROOT/'AxsCacheKeeperOperationInfo.m'),
                          str(ROOT/'tests/image_collection_tests.m'),'-o',str(prior_binary)],check=True,timeout=60)
    result=subprocess.run([str(prior_binary),str(output/'prior-stale-home'),'refresh-discovery'],capture_output=True,text=True,timeout=30)
    assert result.returncode==1 and result.stderr.strip()=='FAIL: image-collection: stale known SDK remains selectable for refresh without execution authority',result.stderr
    print('PASS: fixed 221.1 stale candidate exact RED',hashlib.sha256(stale_source).hexdigest())
    sources=[str(ROOT/name) for name in ('AxsCacheKeeperImageCollection.m','AxsCacheKeeperOperationInfo.m','tests/image_collection_tests.m')]
    subprocess.run(flags+sources+['-o',str(binary)],check=True,timeout=60)
    subprocess.run([str(binary),str(output/'green')],check=True,timeout=30)
    subprocess.run([str(binary),str(output/'stale-green'),'refresh-discovery'],check=True,timeout=30)
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
    cleanup_source=(ROOT/'AxsCacheKeeperImageCollection.m').read_text(encoding='utf8')
    anchor='if([cleanup[@"cleanupActions"] unsignedIntegerValue]>0 && [event[@"state"] isEqual:@"notTriggered"])event[@"state"]=@"insufficientEvidence";'
    assert cleanup_source.count(anchor)==1
    (red/'AxsCacheKeeperImageCollection.m').write_text(cleanup_source.replace(anchor,''),encoding='utf8')
    shutil.copyfile(ROOT/'AxsCacheKeeperImageCollection.h',red/'AxsCacheKeeperImageCollection.h')
    subprocess.run(flags+['-I'+str(ROOT),str(red/'AxsCacheKeeperImageCollection.m'),str(ROOT/'AxsCacheKeeperOperationInfo.m'),str(red/'tests/image_collection_tests.m'),'-o',str(red_binary)],check=True,timeout=60)
    result=subprocess.run([str(red_binary),str(output/'cleanup-red-home')],capture_output=True,text=True,timeout=30)
    assert result.returncode==1 and result.stderr.strip()=='FAIL: image-collection: observed cleanup is not labelled untriggered and incomplete coverage stays unproven',result.stderr
    print('PASS: writer-only stage summary reaches exact observed-cleanup RED')
