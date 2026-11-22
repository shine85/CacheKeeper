"""Strict Foundation projection with isolated exact REDs; no CI orchestration."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
ADMISSION_CHECK = '    if (value[@"instanceAdmission"] && !axs_cachekeeper_image_admission_projection(value[@"instanceAdmission"],(NSUInteger)observed)) return nil;\n'
REJECTION_CHECK = '''    NSDictionary *rejection=value[@"sdkMethodsRejectionObservation"],*admission=value[@"instanceAdmission"];
    if ([rejection[@"state"] isEqual:@"recorded"] &&
        (!admission || [rejection[@"initializerOrdinal"] unsignedLongLongValue]>[admission[@"initializerReturns"] unsignedLongLongValue] ||
         ![admission[@"unregisteredReasons"][@"sdkMethodsChanged"] unsignedLongLongValue])) return nil;
'''
CONTROLS = (
    ("boolean", " || CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()", "",
     "boolean fractional negative unsafe and nonnumeric counts rejected"),
    ("closure", "liveTotal==live && AxsCacheKeeperImageAdmissionValid(&ledger,live)", "liveTotal==live",
     "contradictory lifecycle counts rejected"),
    ("rejection-order", ADMISSION_CHECK + REJECTION_CHECK, REJECTION_CHECK + ADMISSION_CHECK,
     "recorded rejection validates admission before reading cumulative reason data"),
)

def run():
    compiler = shutil.which("xcrun")
    if sys.platform != "darwin" or not compiler:
        print("UNAVAILABLE: image admission Foundation projection requires macOS/xcrun; no native tests ran.")
        return 2
    directory = Path(tempfile.mkdtemp(prefix="image-admission-status-", dir=ROOT / "tmp"))
    deadline = time.monotonic() + 165
    print(f"Artifacts: {directory}", flush=True)
    def call(args, folder, label, maximum):
        remaining = deadline-time.monotonic()
        if remaining <= 0:
            raise RuntimeError("admission status aggregate budget exhausted; never RED")
        try:
            result = subprocess.run(args, cwd=ROOT, capture_output=True, timeout=min(maximum, remaining))
        except subprocess.TimeoutExpired as error:
            (folder/(label+".stdout.log")).write_bytes(error.stdout or b"")
            (folder/(label+".stderr.log")).write_bytes(error.stderr or b"")
            raise
        (folder/(label+".stdout.log")).write_bytes(result.stdout)
        (folder/(label+".stderr.log")).write_bytes(result.stderr)
        return result
    source = (ROOT/"AxsCacheKeeperImageCacheStatus.h").read_text(encoding="utf-8-sig")
    controls = list(CONTROLS) + [("green", None, None, None)]
    for name, before, after, expected in controls:
        folder=directory/name;folder.mkdir()
        candidate=source
        if before:
            if source.count(before)!=1:
                raise RuntimeError("ambiguous admission status mutation: "+name)
            candidate=source.replace(before,after)
        (folder/"AxsCacheKeeperImageCacheStatus.h").write_text(candidate,encoding="utf-8")
        shutil.copyfile(ROOT/"tests/image_admission_status_tests.m",folder/"test.m")
        binary=folder/"status"
        built=call([compiler,"clang","-fobjc-arc","-fblocks","-Wall","-Wextra","-Werror=format",
                    "-I"+str(folder),"-I"+str(ROOT),"-framework","Foundation",str(folder/"test.m"),
                    str(ROOT/"AxsCacheKeeperOperationInfo.m"),"-o",str(binary)],folder,"compile",60)
        if built.returncode:
            raise RuntimeError("admission status compile failed; never RED: "+built.stderr.decode(errors="replace"))
        result=call([str(binary)],folder,"run",15)
        if expected:
            if result.returncode!=1 or result.stdout.strip() or result.stderr.strip()!=("FAIL: image-admission-status: "+expected).encode():
                raise RuntimeError("precise admission status RED missed: "+name+"\n"+(result.stdout+result.stderr).decode(errors="replace"))
        elif result.returncode or result.stderr.strip() or result.stdout.strip()!=b"PASS: image-admission-status closed projection, privacy, legacy and wording":
            raise RuntimeError("admission status GREEN failed: "+(result.stdout+result.stderr).decode(errors="replace"))
        print("PASS: image admission status "+name,flush=True)
    return 0

if __name__ == "__main__":
    raise SystemExit(run())
