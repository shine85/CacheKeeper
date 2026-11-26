"""Run the batch with existing real Darwin notify peers and Foundation files."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT=Path(__file__).resolve().parents[1]


def run():
    if sys.platform!='darwin' or not shutil.which('xcrun'):
        print('UNAVAILABLE: host preflight requires macOS Foundation/Darwin notify; no native tests ran.')
        return 2
    (ROOT/'tmp').mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='host-preflight-',dir=ROOT/'tmp') as temporary:
        output=Path(temporary);wrapper=output/'host-production.m'
        wrapper.write_text('#import <Foundation/Foundation.h>\n#include <notify.h>\n'
            'extern uint32_t axs_cachekeeper_preflight_test_register(const char *,int *);\n'
            '#define notify_register_check axs_cachekeeper_preflight_test_register\n'
            '#import "'+(ROOT/'AxsCacheKeeperHostEvidence.m').as_posix()+'"\n',encoding='utf-8')
        binary=output/'preflight-tests'
        command=['xcrun','clang','-fobjc-arc','-fblocks','-Wall','-Wextra','-Werror=format','-I'+str(ROOT),
                 '-I'+str(ROOT/'tests/include'),'-framework','Foundation',str(ROOT/'tests/host_preflight_tests.m'),
                 str(ROOT/'AxsCacheKeeperHostPreflight.m'),str(wrapper),'-o',str(binary)]
        subprocess.run(command,check=True,timeout=60)
        for mode in ('observed','timeoutCancel','saveRetry','beginFailure'):
            subprocess.run([str(binary),mode,str(output/mode)],check=True,timeout=15)
        source=(ROOT/'AxsCacheKeeperHostPreflight.m').read_text(encoding='utf-8')
        marker='            [client axs_cachekeeper_cancel];\n            [self axs_cachekeeper_accept:'
        if source.count(marker)!=1:raise RuntimeError('ambiguous batch cancellation mutation')
        mutated=output/'preflight-cancel-red.m'
        mutated.write_text(source.replace(marker,'            [self axs_cachekeeper_accept:',1),encoding='utf-8')
        red=output/'preflight-red';red_command=command.copy()
        red_command[red_command.index(str(ROOT/'AxsCacheKeeperHostPreflight.m'))]=str(mutated)
        red_command[-1]=str(red);subprocess.run(red_command,check=True,timeout=60)
        result=subprocess.run([str(red),'timeoutCancel',str(output/'cancel-red')],capture_output=True,text=True,timeout=15)
        expected='FAIL: host preflight: every real client releases notify tokens'
        if result.returncode!=1 or result.stderr.strip()!=expected:
            raise RuntimeError('cancel mutation missed exact behavior RED: '+result.stdout+result.stderr)
        print('PASS: missing cancellation mutation reaches real token-release assertion')
    return 0


if __name__=='__main__':raise SystemExit(run())
