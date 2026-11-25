"""Verify that the installed-app regression detects the old configuration-only report."""
import pathlib
import shutil
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
if sys.platform != "darwin" or not shutil.which("xcrun"):
    print("UNAVAILABLE: diagnostics baseline requires macOS and xcrun; no tests ran.")
    raise SystemExit(2)
baseline = "897259fcd3e846662379fbce97896ed8abfd76ff"
(root / "tmp").mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="diagnostics-red-", dir=root / "tmp") as temp:
    target = pathlib.Path(temp)
    (target / "tests").mkdir()
    for name in ("AxsCacheKeeperDiagnostics.h", "AxsCacheKeeperDiagnostics.m"):
        (target / name).write_bytes(subprocess.check_output(
            ["git", "show", f"{baseline}:{name}"], cwd=root, timeout=15))
    # Stage the project headers beside the historical implementation and test.
    # Quoted relative imports must resolve to one physical copy; otherwise a
    # temp header plus its root counterpart can redefine unguarded helpers.
    for path in root.glob("AxsCacheKeeper*.h"):
        if path.name == "AxsCacheKeeperDiagnostics.h":
            continue
        (target / path.name).write_bytes(path.read_bytes())
    for name in ("diagnostics_tests.m", "gurd_export_fixture.h"):
        (target / "tests" / name).write_bytes((root / "tests" / name).read_bytes())
    (target / "main.m").write_text(
        '#import <Foundation/Foundation.h>\n'
        'extern void axs_cachekeeper_run_diagnostics_tests(NSString *fixture);\n'
        'int main(int argc, char **argv) { @autoreleasepool { '
        'axs_cachekeeper_run_diagnostics_tests([NSString stringWithUTF8String:argv[1]]); } return 0; }\n',
        encoding="utf-8")
    binary = target / "red-test"
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format", "-I" + str(root), "-framework", "Foundation",
                    str(target / "main.m"), str(target / "AxsCacheKeeperDiagnostics.m"),
                    str(target / "tests/diagnostics_tests.m"), str(root / "AxsCacheKeeperInstallation.m"), "-o", str(binary)],
                   check=True, timeout=60)
    result = subprocess.run([str(binary), str(target / "fixtures")], capture_output=True,
                            text=True, encoding="utf-8", timeout=60)
    expected = "FAIL: diagnostics: 安装配置并集的进度每轮固定为 0 至 5"
    if result.returncode != 1 or expected not in result.stderr:
        raise SystemExit(f"Expected installed-app omission failure; got {result.returncode}: {result.stderr}")
    print("Verified diagnostic baseline red:", result.stderr.strip())
