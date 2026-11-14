"""Prove the old NSURLCache hook passes a nonzero disk budget into Foundation."""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
baseline = "897259fcd3e846662379fbce97896ed8abfd76ff"
(root / "tmp").mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="network-initialization-red-", dir=root / "tmp") as temp:
    target = pathlib.Path(temp)
    (target / "tests").mkdir()
    (target / "AxsCacheKeeperNetworkCache.m").write_bytes(subprocess.check_output(
        ["git", "show", f"{baseline}:AxsCacheKeeperNetworkCache.m"], cwd=root, timeout=15))
    for name in ("AxsCacheKeeperNetworkCache.h", "tests/network_cache_tests.m"):
        (target / name).write_bytes((root / name).read_bytes())
    (target / "main.m").write_text(
        '#import <Foundation/Foundation.h>\n'
        'extern void axs_cachekeeper_run_network_cache_tests(NSString *fixture);\n'
        'int main(int argc, char **argv) { @autoreleasepool { '
        'axs_cachekeeper_run_network_cache_tests([NSString stringWithUTF8String:argv[1]]); } return 0; }\n',
        encoding="utf-8")
    fixture = target / "fixtures"
    fixture.mkdir()
    binary = target / "red-test"
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-framework", "Foundation",
                    "-I" + str(root / "tests/include"), str(target / "main.m"),
                    str(target / "AxsCacheKeeperNetworkCache.m"),
                    str(target / "tests/network_cache_tests.m"), "-o", str(binary)],
                   check=True, timeout=60)
    result = subprocess.run([str(binary), str(fixture)], capture_output=True,
                            text=True, encoding="utf-8", timeout=60)
    expected = "FAIL: network initialization: path 原初始化器 disk 期望 0，实际 8388608"
    if result.returncode != 1 or expected not in result.stderr:
        raise SystemExit(f"Expected initialization budget failure; got {result.returncode}: {result.stderr}")
    print("Verified network initialization baseline red:", result.stderr.strip())
