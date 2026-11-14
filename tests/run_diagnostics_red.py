"""Verify that the installed-app regression detects the old configuration-only report."""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
baseline = "897259fcd3e846662379fbce97896ed8abfd76ff"
(root / "tmp").mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="diagnostics-red-", dir=root / "tmp") as temp:
    target = pathlib.Path(temp)
    (target / "tests").mkdir()
    for name in ("AxsCacheKeeperDiagnostics.h", "AxsCacheKeeperDiagnostics.m"):
        (target / name).write_bytes(subprocess.check_output(
            ["git", "show", f"{baseline}:{name}"], cwd=root, timeout=15))
    for name in ("AxsCacheKeeperPolicy.h", "tests/diagnostics_tests.m"):
        (target / name).write_bytes((root / name).read_bytes())
    (target / "main.m").write_text(
        '#import <Foundation/Foundation.h>\n'
        'extern void axs_cachekeeper_run_diagnostics_tests(NSString *fixture);\n'
        'int main(int argc, char **argv) { @autoreleasepool { '
        'axs_cachekeeper_run_diagnostics_tests([NSString stringWithUTF8String:argv[1]]); } return 0; }\n',
        encoding="utf-8")
    binary = target / "red-test"
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-framework", "Foundation",
                    str(target / "main.m"), str(target / "AxsCacheKeeperDiagnostics.m"),
                    str(target / "tests/diagnostics_tests.m"), "-o", str(binary)],
                   check=True, timeout=60)
    result = subprocess.run([str(binary), str(target / "fixtures")], capture_output=True,
                            text=True, encoding="utf-8", timeout=60)
    expected = "FAIL: diagnostics: 安装配置并集的进度每轮固定为 0 至 5"
    if result.returncode != 1 or expected not in result.stderr:
        raise SystemExit(f"Expected installed-app omission failure; got {result.returncode}: {result.stderr}")
    print("Verified diagnostic baseline red:", result.stderr.strip())
