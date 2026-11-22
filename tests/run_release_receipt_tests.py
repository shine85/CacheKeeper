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
    ('drop-history','[report addEntriesFromDictionary:history];','',
     'empty round preserves preceding effective cleanup and its own evidence'),
    ('drop-history-on-status','if (previous[key]) report[key]=previous[key];','',
     'status writer preserves effective and bounded terminal history'),
    ('reopen-terminal','if (oldTerminal) {','if (oldTerminal && !sameRound) {',
     'retirement cannot replace an already persisted terminal boundary'),
    ('rewrite-pending-terminal','if (pending[@"round"]) {','if (NO && pending[@"round"]) {',
     'pending retirement preserves first terminal failures reason and coverage'),
]:
    if source.count(before)!=1: raise SystemExit('Ambiguous release receipt control: '+name)
    controls.append((name,source.replace(before,after),expected))
(ROOT/'tmp').mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='release-receipts-',dir=ROOT/'tmp') as temp:
    output=pathlib.Path(temp)
    # Exact display-only counterexample: same receipt and volume samples, but
    # hide signed values. No subprocess lifecycle or CI control is changed.
    display=(ROOT/'AxsCacheKeeperPresentation.h').read_text(encoding='utf-8')
    anchor='if ([volume[@"state"] isEqual:@"observed"]) {'
    if display.count(anchor)!=1:raise SystemExit('Ambiguous volume display control')
    display_root=output/'display-red';(display_root/'tests').mkdir(parents=True)
    for header in ('AxsCacheKeeperReceipts.h','AxsCacheKeeperReleaseEvidenceStatus.h','AxsCacheKeeperAllocation.h',
                   'AxsCacheKeeperCleanupHistory.h','AxsCacheKeeperPolicy.h','AxsCacheKeeperRelativePath.h'):
        shutil.copyfile(ROOT/header,display_root/header)
    (display_root/'AxsCacheKeeperPresentation.h').write_text(display.replace(anchor,'if (NO && [volume[@"state"] isEqual:@"observed"]) {'),encoding='utf-8')
    shutil.copyfile(ROOT/'tests/release_receipt_tests.m',display_root/'tests/release_receipt_tests.m')
    executable=display_root/'display-red'
    subprocess.run([compiler,'clang','-fobjc-arc','-fblocks','-Wall','-Wextra','-Werror=format',
        '-Werror=implicit-function-declaration','-I'+str(ROOT),'-framework','Foundation',
        str(ROOT/'AxsCacheKeeperReceipts.m'),str(display_root/'tests/release_receipt_tests.m'),'-o',str(executable)],check=True,timeout=60)
    negative=subprocess.run([str(executable),str(display_root/'fixtures')],capture_output=True,text=True,timeout=60)
    expected='FAIL: release receipt: actual signed volume changes and time are visible without attribution'
    if negative.returncode!=1 or negative.stderr.strip()!=expected:raise SystemExit('Volume display RED did not reach exact assertion: '+negative.stderr)
    print('PASS: release receipt exact volume display control')
    time_anchor='axs_cachekeeper_presentation_time(round[@"finishedAt"])'
    if display.count(time_anchor)!=1:raise SystemExit('Ambiguous cleanup round time control')
    # Run the actual presentation function with fixed distinct round/status dates.
    # Replacing only the date source must reproduce status refresh relabelling old evidence.
    for label,header in (('time-current',display),('time-red',display.replace(time_anchor,'axs_cachekeeper_presentation_time(report[@"updated"])'))):
        time_root=output/label;(time_root/'tests').mkdir(parents=True)
        (time_root/'AxsCacheKeeperPresentation.h').write_text(header,encoding='utf-8')
        shutil.copyfile(ROOT/'tests/presentation_tests.m',time_root/'tests/presentation_tests.m')
        main=time_root/'main.m'
        main.write_text('#import <Foundation/Foundation.h>\nvoid axs_cachekeeper_run_presentation_tests(void);\nint main(void) {@autoreleasepool {axs_cachekeeper_run_presentation_tests();} return 0;}\n',encoding='utf-8')
        binary=time_root/label
        subprocess.run([compiler,'clang','-fobjc-arc','-fblocks','-Wall','-Wextra','-Werror=format',
            '-Werror=implicit-function-declaration','-I'+str(ROOT),'-framework','Foundation',
            str(main),str(time_root/'tests/presentation_tests.m'),'-o',str(binary)],check=True,timeout=60)
        result=subprocess.run([str(binary)],capture_output=True,text=True,timeout=60)
        if label=='time-red':
            if result.returncode!=1 or result.stderr.strip()!='FAIL: presentation: status-only updates cannot relabel historical cleanup time or configuration':
                raise SystemExit('Round time RED did not reach exact assertion: '+result.stderr)
        elif result.returncode:raise SystemExit('Current round time display failed: '+result.stderr)
        print('PASS: cleanup historical time '+label)
    # Reproduce the old summary with frozen failure/cancel/coverage suffixes hidden.
    # The real status writer first clears current failed to zero; each history line
    # must still expose its distinct, persisted terminal facts.
    policy=(ROOT/'AxsCacheKeeperPolicy.h').read_text(encoding='utf-8')
    frozen_suffixes='''    if ([round[@"endReason"] unsignedIntegerValue]==4) [text appendString:@"；该轮已中止"];
    if ([round[@"failed"] unsignedIntegerValue]) [text appendFormat:@"；该轮失败 %@ 项",round[@"failed"]];
    if (![round[@"coverageComplete"] boolValue]) [text appendString:@"；该轮覆盖未完整"];
'''
    if policy.count(frozen_suffixes)!=1:raise SystemExit('Ambiguous frozen round failure control')
    policy_root=output/'history-failure-red';(policy_root/'tests').mkdir(parents=True)
    for header in ('AxsCacheKeeperReceipts.h','AxsCacheKeeperReleaseEvidenceStatus.h','AxsCacheKeeperAllocation.h',
                   'AxsCacheKeeperCleanupHistory.h','AxsCacheKeeperRelativePath.h','AxsCacheKeeperPresentation.h'):
        shutil.copyfile(ROOT/header,policy_root/header)
    (policy_root/'AxsCacheKeeperPolicy.h').write_text(policy.replace(frozen_suffixes,''),encoding='utf-8')
    shutil.copyfile(ROOT/'tests/release_receipt_tests.m',policy_root/'tests/release_receipt_tests.m')
    binary=policy_root/'history-failure-red'
    subprocess.run([compiler,'clang','-fobjc-arc','-fblocks','-Wall','-Wextra','-Werror=format',
        '-Werror=implicit-function-declaration','-I'+str(ROOT),'-framework','Foundation',
        str(ROOT/'AxsCacheKeeperReceipts.m'),str(policy_root/'tests/release_receipt_tests.m'),'-o',str(binary)],check=True,timeout=60)
    result=subprocess.run([str(binary),str(policy_root/'fixtures')],capture_output=True,text=True,timeout=60)
    expected='FAIL: release receipt: policy summary preserves each frozen failure cancellation and coverage after status-only update'
    if result.returncode!=1 or result.stderr.strip()!=expected:
        raise SystemExit('Frozen round failure RED did not reach exact assertion: '+result.stderr)
    print('PASS: release receipt exact frozen round failure display control')
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
