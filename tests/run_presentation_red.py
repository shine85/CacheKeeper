"""Re-run the frozen missing-presentation contract, asserting a genuine behavioral failure."""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
baseline = "7de043c3ed89e607997add67e6e68d16fe72dd0d"
with tempfile.TemporaryDirectory(prefix="presentation-red-", dir=root / "tmp") as temp:
    target = pathlib.Path(temp)
    (target / "tests").mkdir()
    for name in ("AxsCacheKeeperPresentation.h", "tests/presentation_tests.m"):
        data = subprocess.check_output(["git", "show", f"{baseline}:{name}"], cwd=root, timeout=15)
        (target / name).write_bytes(data)
    (target / "main.m").write_text(
        '#import <Foundation/Foundation.h>\nextern void axs_cachekeeper_run_presentation_tests(void);\n'
        'int main(void) { @autoreleasepool { axs_cachekeeper_run_presentation_tests(); } return 0; }\n')
    binary = target / "red-test"
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-framework", "Foundation",
                    str(target / "main.m"), str(target / "tests/presentation_tests.m"),
                    "-o", str(binary)], check=True, timeout=60)
    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15)
    if result.returncode != 1 or "FAIL: presentation:" not in result.stderr:
        raise SystemExit(f"Expected frozen presentation failure; got {result.returncode}: {result.stderr}")
    print("Verified frozen red:", result.stderr.strip())
