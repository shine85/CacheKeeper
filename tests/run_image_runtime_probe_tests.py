"""Actual image Runtime/engine/coordinator and established synthetic host ABI fixture."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import re
ROOT=Path(__file__).resolve().parents[1]
TOTAL_BUDGET_SECONDS=360

def main():
    compiler=shutil.which("xcrun")
    if sys.platform!="darwin" or not compiler:
        print("UNAVAILABLE: image Runtime probe behavior needs macOS Foundation and xcrun; no behavior ran.")
        return 2
    end=time.monotonic()+TOTAL_BUDGET_SECONDS
    def run(args,limit=60,**kwargs):
        left=end-time.monotonic()
        if left<=0:raise TimeoutError("image Runtime probe total budget exhausted")
        return subprocess.run(args,timeout=min(limit,left),**kwargs)
    parent=ROOT/"tmp/implementation-201";parent.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="image-probes-",dir=parent) as temporary:
        folder=Path(temporary);helper=folder/"autorelease.o"
        run([compiler,"clang","-fno-objc-arc","-c",str(ROOT/"tests/image_runtime_autorelease_fixture.m"),"-o",str(helper)],check=True)
        flags=[compiler,"clang","-fobjc-arc","-fblocks","-Wall","-Wextra","-Werror=format","-Werror=implicit-function-declaration","-DAXS_CACHEKEEPER_IMAGE_TESTING=1",'-DAXS_CACHEKEEPER_PACKAGE_VERSION="0.0.0-0.0"',"-I"+str(ROOT/"tests/image_runtime_context_platform"),"-I"+str(ROOT),"-I"+str(ROOT/"tests"),"-framework","Foundation"]
        sources=[str(ROOT/p) for p in ("tests/image_runtime_probe_tests.m","AxsCacheKeeperCleanupRules.m","AxsCacheKeeperOperationInfo.m","AxsCacheKeeperImageCoordinator.m","AxsCacheKeeperImageCollection.m")]+[str(helper)]
        binary=folder/"image-probes";run(flags+sources+["-o",str(binary)],check=True)
        for scenario in ("same","changed","access","installation","delayed","rapid","late-provider","collection","preparation"):
            home=folder/scenario;home.mkdir();result=run([str(binary),scenario,str(home)],20,capture_output=True,text=True)
            if result.returncode or result.stdout.strip()!=f"PASS: image-runtime-probe {scenario}":raise RuntimeError(result.stdout+result.stderr)
            print(result.stdout,end="")
        runtime=(ROOT/"AxsCacheKeeperImageCacheRuntime.m").read_text(encoding="utf-8")
        anchors=("if (policy<=axs_cachekeeper_image_notified_policy) return;","if (axs_cachekeeper_image_background && applied) return;")
        for anchor in anchors:
            if runtime.count(anchor)!=1:raise RuntimeError("ambiguous image repeated-probe RED boundary")
            runtime=runtime.replace(anchor,anchor.replace("if (","if (NO && ",1))
        red_source=folder/"ImageRuntime-probe-red.m";red_source.write_text(runtime,encoding="utf-8")
        red=folder/"image-probes-red"
        run(flags+['-DAXS_CACHEKEEPER_PROBE_RUNTIME_INCLUDE="'+str(red_source)+'"']+sources+["-o",str(red)],check=True)
        home=folder/"same-red";home.mkdir();result=run([str(red),"same",str(home)],20,capture_output=True,text=True)
        expected="FAIL: image-runtime-source: identical Runtime probe preserves in-flight generation event and UIKit task"
        if result.returncode!=1 or result.stdout.strip() or re.findall(r"^FAIL:.*$",result.stderr,re.MULTILINE)!=[expected]:raise RuntimeError("incorrect image probe behavioral RED\n"+result.stdout+result.stderr)
        print("PASS: image-runtime-probe exact repeated-probe RED")
    return 0
if __name__=="__main__":raise SystemExit(main())
