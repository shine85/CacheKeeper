"""The historical reporter must fail the real channel-status export assertion."""
import pathlib
import shutil
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
if sys.platform != "darwin" or not shutil.which("xcrun"):
    print("UNAVAILABLE: channel export baseline requires macOS and xcrun; no tests ran.")
    raise SystemExit(2)
baseline = "9690efc8fb4c993b94f6a8354a2d42b2778c43b8"
(root / "tmp").mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="channel-export-red-", dir=root / "tmp") as temp:
    target = pathlib.Path(temp)
    (target / "tests").mkdir()
    for name in ("AxsCacheKeeperDiagnostics.h", "AxsCacheKeeperDiagnostics.m", "AxsCacheKeeperPolicy.h"):
        (target / name).write_bytes(subprocess.check_output(
            ["git", "show", f"{baseline}:{name}"], cwd=root, timeout=15))
    name = "tests/diagnostic_channel_export_tests.m"
    (target / name).write_bytes((root / name).read_bytes())
    (target / "main.m").write_text(
        '#import <Foundation/Foundation.h>\n'
        'extern void axs_cachekeeper_run_diagnostic_channel_export_tests(void);\n'
        'int main(void) { @autoreleasepool { axs_cachekeeper_run_diagnostic_channel_export_tests(); } return 0; }\n',
        encoding="utf-8")
    binary = target / "red-test"
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-framework", "Foundation",
                    str(target / "main.m"), str(target / "AxsCacheKeeperDiagnostics.m"),
                    str(target / name), "-o", str(binary)], check=True, timeout=60)
    result = subprocess.run([str(binary)], capture_output=True, text=True, encoding="utf-8", timeout=60)
    expected = "FAIL: diagnostic channel export: 握手状态必须进入内存诊断报告"
    if result.returncode != 1 or expected not in result.stderr:
        raise SystemExit(f"Expected channel export failure; got {result.returncode}: {result.stderr}")
    print("Verified channel export baseline red:", result.stderr.strip())
