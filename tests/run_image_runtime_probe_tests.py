"""Actual image Runtime/engine/coordinator and established synthetic host ABI fixture."""
from pathlib import Path
import hashlib
import shutil
import subprocess
import sys
import tempfile
import time
import re
ROOT=Path(__file__).resolve().parents[1]
TOTAL_BUDGET_SECONDS=360
RECEIPT_BASELINE="2eb4f85046c6634ac3b785904fd3a561ba3bf49d"
RECEIPT_SOURCE_SHA256="a2e4f7941f1cbd8e33110f6135510eb869b26faef3a80fced4353efbed443e75"

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
        sources=[str(ROOT/p) for p in ("tests/image_runtime_probe_tests.m","AxsCacheKeeperCleanupRules.m","AxsCacheKeeperOperationInfo.m","AxsCacheKeeperImageCoordinator.m")]+[str(helper)]
        baseline=folder/"receipt-baseline";baseline.mkdir()
        old=run(["git","show",RECEIPT_BASELINE+":AxsCacheKeeperImageCache.m"],15,cwd=ROOT,capture_output=True,check=True).stdout
        if hashlib.sha256(old).hexdigest()!=RECEIPT_SOURCE_SHA256:raise RuntimeError("unexpected receipt IO baseline source")
        (baseline/"AxsCacheKeeperImageCache.m").write_bytes(old)
        receipt_red=folder/"receipt-io-red"
        run(flags[:2]+["-I"+str(baseline)]+flags[2:]+sources+["-o",str(receipt_red)],check=True)
        home=folder/"receipt-io-red-home";home.mkdir()
        result=run([str(receipt_red),"receipt-io",str(home)],20,capture_output=True,text=True)
        expected="FAIL: image-runtime-source: foreground and receipt access never wait for receipt IO"
        if result.returncode!=1 or result.stdout.strip() or re.findall(r"^FAIL:.*$",result.stderr,re.MULTILINE)!=[expected]:raise RuntimeError("incorrect receipt IO baseline RED\n"+result.stdout+result.stderr)
        print("PASS: image-runtime-probe fixed 228.1 receipt IO foreground blocking RED")
        coordinator=(ROOT/"AxsCacheKeeperImageCoordinator.m").read_text(encoding="utf-8")
        published='_publishedReceipt && ![_publishedReceipt[@"pending"] unsignedIntegerValue]'
        if coordinator.count(published)!=1:raise RuntimeError("ambiguous completed publication decision boundary")
        future=coordinator.replace(published,'_cache.receipt && ![_cache.receipt[@"pending"] unsignedIntegerValue]')
        terminal_source=folder/"ImageCoordinator-terminal-red.m";terminal_source.write_text(future,encoding="utf-8")
        terminal_sources=[str(terminal_source) if Path(source).name=="AxsCacheKeeperImageCoordinator.m" else source for source in sources]
        terminal_red=folder/"image-terminal-red";run(flags+terminal_sources+["-o",str(terminal_red)],check=True)
        home=folder/"receipt-terminal-red-home";home.mkdir()
        result=run([str(terminal_red),"receipt-terminal",str(home)],20,capture_output=True,text=True)
        expected="FAIL: image-runtime-source: background task survives older notices until terminal receipt publication finishes"
        if result.returncode!=1 or result.stdout.strip() or re.findall(r"^FAIL:.*$",result.stderr,re.MULTILINE)!=[expected]:raise RuntimeError("incorrect terminal publication RED\n"+result.stdout+result.stderr)
        print("PASS: image-runtime-probe exact unfinished terminal publication RED")
        binary=folder/"image-probes";run(flags+sources+["-o",str(binary)],check=True)
        for scenario in ("receipt-io","receipt-order","receipt-terminal","same","changed","access","installation","delayed","rapid","late-provider","legacy-request","initial-background"):
            home=folder/scenario;home.mkdir();result=run([str(binary),scenario,str(home)],20,capture_output=True,text=True)
            if result.returncode or result.stdout.strip()!=f"PASS: image-runtime-probe {scenario}":raise RuntimeError(result.stdout+result.stderr)
            print(result.stdout,end="")
        old_runtime=run(["git","show","060d27747bda3c540217a6ec86ea5534d4a8409d:AxsCacheKeeperImageCacheRuntime.m"],15,cwd=ROOT,capture_output=True,check=True).stdout
        if hashlib.sha256(old_runtime).hexdigest()!='ad26b8957570d07e468c87f2132b9699a4f8d5585bcb5d008fecd269df84d2ec':raise RuntimeError("unexpected legacy overlay baseline")
        old_header=run(["git","show","060d27747bda3c540217a6ec86ea5534d4a8409d:AxsCacheKeeperImageCollection.h"],15,cwd=ROOT,capture_output=True,check=True).stdout
        legacy_source=folder/"LegacyRuntime.m";legacy_source.write_bytes(old_runtime)
        (folder/"AxsCacheKeeperImageCollection.h").write_bytes(old_header)
        legacy=folder/"legacy-request-red"
        run(flags+['-DAXS_CACHEKEEPER_PROBE_RUNTIME_INCLUDE="'+str(legacy_source)+'"']+sources+["-o",str(legacy)],check=True)
        home=folder/"legacy-request-red-home";home.mkdir();result=run([str(legacy),"legacy-request",str(home)],20,capture_output=True,text=True)
        expected="FAIL: image-runtime-source: legacy collection request never overrides ordinary user policy"
        if result.returncode!=1 or result.stdout.strip() or re.findall(r"^FAIL:.*$",result.stderr,re.MULTILINE)!=[expected]:raise RuntimeError("incorrect legacy overlay RED\n"+result.stdout+result.stderr)
        print("PASS: image-runtime-probe fixed 230.1 legacy overlay RED")
        home=folder/"initial-background-red-home";home.mkdir();result=run([str(legacy),"initial-background",str(home)],20,capture_output=True,text=True)
        expected="FAIL: image-runtime-source: initial background state triggers ordinary cleanup without another notification"
        if result.returncode!=1 or result.stdout.strip() or re.findall(r"^FAIL:.*$",result.stderr,re.MULTILINE)!=[expected]:raise RuntimeError("incorrect initial background RED\n"+result.stdout+result.stderr)
        print("PASS: image-runtime-probe fixed 230.1 missed initial background RED")
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
