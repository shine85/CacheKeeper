"""Execute the production C accounting on the local host; no Foundation claim."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]

def run():
    zig = ROOT / "tmp/release-evidence-toolchain/zig-windows-x86_64-0.13.0/zig.exe"
    compiler_path = str(zig) if zig.is_file() else (shutil.which("cc") or shutil.which("clang") or shutil.which("zig"))
    if not compiler_path:
        print("UNAVAILABLE: image admission C compiler missing; no tests ran.")
        return 2
    compiler = [compiler_path] + (["cc"] if Path(compiler_path).stem == "zig" else [])
    directory = Path(tempfile.mkdtemp(prefix="image-admission-core-", dir=ROOT / "tmp"))
    deadline = time.monotonic() + 165
    def call(command, maximum, folder, name):
        remaining=deadline-time.monotonic()
        if remaining<=0:
            raise RuntimeError("image admission core aggregate budget exhausted; never RED")
        result = subprocess.run(command, capture_output=True, timeout=min(maximum, remaining))
        (folder / name).write_bytes(result.stdout + result.stderr)
        print((result.stdout + result.stderr).decode(errors="replace"), end="", flush=True)
        return result
    source=(ROOT/"AxsCacheKeeperImageCacheStatus.h").read_text(encoding="utf-8-sig")
    controls=[
        ("returns", "    AxsCacheKeeperImageAdmissionIncrement(&ledger->initializerReturns,&ledger->overflow);", "",
         "early returns do not erase registered owners"),
        ("release", "    AxsCacheKeeperImageAdmissionIncrement(&ledger->released,&ledger->overflow);", "    (void)ledger;",
         "released owner remains counted"),
        ("closure", "        ledger->unregistered==total && ", "        ", "inconsistent reasons rejected"),
        ("overflow", "*overflow=true;", "(void)overflow;", "saturated cumulative totals still close"),
        ("green",None,None,None)] if "--green-only" not in sys.argv else [("green",None,None,None)]
    for label,before,after,expected in controls:
        folder=directory/label;folder.mkdir()
        candidate=source
        if before:
            if source.count(before)!=1:
                raise RuntimeError("ambiguous admission core mutation: "+label)
            candidate=source.replace(before,after)
        (folder/"AxsCacheKeeperImageCacheStatus.h").write_text(candidate,encoding="utf-8")
        binary=folder/("admission.exe" if sys.platform=="win32" else "admission")
        compiled=call(compiler+["-std=c11","-Wall","-Wextra","-Werror","-I"+str(folder),
                                str(ROOT/"tests/image_admission_core_tests.c"),"-o",str(binary)],60,folder,"compile.log")
        if compiled.returncode:
            raise RuntimeError("image admission core compile failed; never RED")
        result=call([str(binary)],10,folder,"run.log")
        if expected:
            if result.returncode!=1 or result.stdout.strip() or result.stderr.strip()!=("FAIL: image-admission: "+expected).encode():
                raise RuntimeError("precise admission core RED missed: "+label)
        elif result.returncode:
            return result.returncode
        print("PASS: image admission core "+label,flush=True)
    print(f"Artifacts: {directory}")
    return 0

if __name__ == "__main__":
    raise SystemExit(run())
