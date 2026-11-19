"""Real macOS Foundation response IO; not iOS CFNetwork/Substrate/physical-release proof.

Fixed interface comparison (not an implementation substituted into these tests):
https://github.com/swiftlang/swift-corelibs-foundation/blob/59e6789524d8593320076e27e39b3852bacf20ca/Sources/FoundationNetworking/URLCache.swift#L487-L512
WebKit's independent network cache explicitly bypasses NSURLCache:
https://github.com/WebKit/WebKit/blob/7a88d3bffee3b701a9288ceda2b5e6b4381ddc02/Source/WebKit/NetworkProcess/cocoa/NetworkSessionCocoa.mm#L1205-L1206
Only synthetic cache responses are used; no device or network content is read.
"""
import pathlib
import shutil
import subprocess
import sys
import tempfile


def main():
    compiler = shutil.which("xcrun")
    if sys.platform != "darwin" or not compiler:
        print("UNAVAILABLE: cache mode real IO requires macOS Foundation and xcrun; no native RED/GREEN ran.")
        return 2
    root = pathlib.Path(__file__).resolve().parents[1]
    (root / "tmp").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="cache-mode-", dir=root / "tmp") as directory:
        output = pathlib.Path(directory)
        flags = [compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format",
                 "-Werror=implicit-function-declaration", "-I" + str(root / "tests/include"), "-I" + str(root), "-framework", "Foundation"]

        def build(product, name):
            binary = output / name
            subprocess.run([*flags, str(product), str(root / "tests/network_cache_tests.m"),
                            str(root / "tests/cache_mode_behavior_tests.m"), "-o", str(binary)], check=True, timeout=60)
            return binary

        def run(binary, action, fixture, kind):
            result = subprocess.run([str(binary), action, str(fixture), kind], capture_output=True, text=True, timeout=60)
            print(result.stdout, end="")
            print(result.stderr, end="", file=sys.stderr)
            return result

        source = root / "AxsCacheKeeperNetworkCache.m"
        mutations = (
            ("memory-loss", "id result=axs_cachekeeper_original_init_path(object,selector,memory,frame.forwarded,path);",
             "id result=axs_cachekeeper_original_init_path(object,selector,(frame.forwarded==disk ? memory : 0),frame.forwarded,path);",
             "FAIL: network initialization: limited initializer still stores a real memory response"),
            ("lost-restore", "NSUInteger desired=prevent ? 0 : state.desired;", "NSUInteger desired=0;",
             "FAIL: cache mode behavior: same limited cache resumes real disk IO after disable"),
        )
        product = source.read_text(encoding="utf-8-sig")
        for name, before, after, expected in mutations:
            if product.count(before) != 1:
                raise RuntimeError("ambiguous behavior RED anchor: " + name)
            mutated = output / (name + ".m")
            mutated.write_text(product.replace(before, after), encoding="utf-8")
            red_binary = build(mutated, name)
            fixture = output / (name + "-fixtures")
            fixture.mkdir()
            red = run(red_binary, "produce", fixture, "path")
            failures = [line for line in (red.stdout + red.stderr).splitlines() if line.startswith("FAIL:")]
            if red.returncode != 1 or failures != [expected]:
                raise RuntimeError(f"RED {name} must hit only its named real IO assertion; exit={red.returncode}, failures={failures}")
            print("Verified precise real IO RED:", name)
        binary = build(source, "green")
        for kind in ("path", "url"):
            fixture = output / kind
            fixture.mkdir()
            run(binary, "produce", fixture, kind).check_returncode()
            run(binary, "verify", fixture, kind).check_returncode()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
