"""Real Foundation/POSIX stable observation regression against fixed 193.1 source."""
import pathlib, shutil, subprocess, sys, tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]

def main():
    compiler=shutil.which('xcrun')
    if sys.platform!='darwin' or not compiler:
        print('UNAVAILABLE: cleanup observation requires macOS/xcrun; no behavior tests ran.')
        return 2
    (ROOT/'tmp').mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='cleanup-observation-',dir=ROOT/'tmp') as temp:
        out=pathlib.Path(temp)
        old=out/'schedule-193.m'
        old.write_bytes(subprocess.check_output(['git','show','2f19b98b500c51043e561544fafab25938f42719:AxsCacheKeeperCleanupSchedule.m'],cwd=ROOT,timeout=15))
        evidence=out/'evidence.o'
        subprocess.run([compiler,'clang','-std=c11','-Wall','-Wextra','-Werror','-c',str(ROOT/'AxsCacheKeeperReleaseEvidence.c'),'-o',str(evidence)],check=True,timeout=60)
        for role,schedule in (('red',old),('green',ROOT/'AxsCacheKeeperCleanupSchedule.m')):
            binary=out/role
            sources=[ROOT/'tests/cleanup_observation_tests.m',schedule,ROOT/'Baseline.m',ROOT/'AxsCacheKeeperCleanupJob.m',ROOT/'AxsCacheKeeperCleanupRules.m',ROOT/'AxsCacheKeeperDependencySnapshot.m',ROOT/'AxsCacheKeeperReceipts.m',evidence]
            subprocess.run([compiler,'clang','-fobjc-arc','-fblocks','-Wall','-Wextra','-Werror=format','-Werror=implicit-function-declaration','-I'+str(ROOT),'-I'+str(ROOT/'tests/include'),'-framework','Foundation',*map(str,sources),'-o',str(binary)],check=True,timeout=60)
            result=subprocess.run([str(binary),str(out/(role+'-fixture'))],capture_output=True,text=True,timeout=30)
            if role=='red':
                if result.returncode!=1 or result.stderr.strip()!='FAIL: cleanup observation: stable cache observation prevents repeated empty rounds':
                    raise SystemExit('FAIL: incorrect cleanup observation RED\n'+result.stdout+result.stderr)
                print('PASS: 193.1 reproduces exact repeated-empty-observation RED')
            elif result.returncode:
                raise SystemExit('FAIL: cleanup observation GREEN\n'+result.stdout+result.stderr)
            else: print(result.stdout,end='')
    return 0

if __name__=='__main__': raise SystemExit(main())
