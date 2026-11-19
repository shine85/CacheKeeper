"""Run saved receipt/schema behavior and exact evidence-loss controls on macOS."""
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT=pathlib.Path(__file__).resolve().parents[1]
compiler=shutil.which('xcrun')
if sys.platform!='darwin' or not compiler:
    print('UNAVAILABLE: release receipt behavior requires macOS and xcrun; no tests ran.')
    raise SystemExit(2)
source=(ROOT/'AxsCacheKeeperReceipts.m').read_text(encoding='utf-8-sig')
controls=[('current',source,None)]
for name,before,after,expected in [
    ('drop-evidence','if (snapshot[@"releaseEvidence"]) report[@"releaseEvidence"]=snapshot[@"releaseEvidence"];','',
     'terminal evidence survives deduplication without double counting'),
    ('lose-on-status','if (previous[@"releaseEvidence"]) report[@"releaseEvidence"]=previous[@"releaseEvidence"];','',
     'status update preserves evidence'),
    ('dedup-evidence','((!previous[@"releaseEvidence"] && !snapshot[@"releaseEvidence"]) || [previous[@"releaseEvidence"] isEqual:snapshot[@"releaseEvidence"]])','YES',
     'terminal evidence survives deduplication without double counting'),
]:
    if source.count(before)!=1: raise SystemExit('Ambiguous release receipt control: '+name)
    controls.append((name,source.replace(before,after),expected))
(ROOT/'tmp').mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='release-receipts-',dir=ROOT/'tmp') as temp:
    output=pathlib.Path(temp)
    for name,code,expected in controls:
        copied=output/(name+'.m');copied.write_text(code,encoding='utf-8')
        executable=output/name
        subprocess.run([compiler,'clang','-fobjc-arc','-fblocks','-Wall','-Wextra','-Werror=format',
            '-Werror=implicit-function-declaration','-I'+str(ROOT),'-framework','Foundation',
            str(copied),str(ROOT/'tests/release_receipt_tests.m'),'-o',str(executable)],check=True,timeout=60)
        result=subprocess.run([str(executable),str(output/(name+'-fixtures'))],capture_output=True,text=True,timeout=60)
        print(result.stdout,end='');print(result.stderr,end='',file=sys.stderr)
        if expected:
            if result.returncode!=1 or 'FAIL: release receipt: '+expected not in result.stderr:
                raise SystemExit('Control did not reach expected behavior: '+name)
            print('PASS: release receipt exact control '+name)
        elif result.returncode: raise SystemExit(result.returncode)
