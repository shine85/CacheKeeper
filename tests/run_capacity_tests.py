"""Compile the real production cursor/capacity against real macOS filesystem fixtures.

REDs are isolated behavioral regressions. Compiler errors, signals, timeouts and
unrelated assertions never qualify as a verified RED. Windows is UNAVAILABLE.
"""
from __future__ import annotations

import pathlib
import shutil
import subprocess
import sys
import tempfile


def main() -> int:
    compiler = shutil.which("xcrun")
    if sys.platform != "darwin" or not compiler:
        print("UNAVAILABLE: capacity tests require macOS and xcrun; no tests ran.")
        return 2
    root = pathlib.Path(__file__).resolve().parents[1]
    (root / "tmp").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="capacity-", dir=root / "tmp") as directory:
        temporary = pathlib.Path(directory)
        flags = [compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra",
                 "-Werror=format", "-Werror=implicit-function-declaration",
                 "-DAXS_CACHEKEEPER_CAPACITY_TESTING=1", "-I" + str(root),
                 "-I" + str(root / "tests/include"), "-framework", "Foundation"]
        cursor = (root / "AxsCacheKeeperScanTask.m").read_text(encoding="utf-8")
        capacity = (root / "AxsCacheKeeperCapacity.m").read_text(encoding="utf-8")

        def run(name: str, cursor_source: str, capacity_source: str, case: str,
                failure: str | None = None) -> None:
            source_cursor = temporary / (name + "-cursor.m")
            source_capacity = temporary / (name + "-capacity.m")
            source_cursor.write_text(cursor_source, encoding="utf-8")
            source_capacity.write_text(capacity_source, encoding="utf-8")
            binary = temporary / name
            fixture = temporary / (name + "-fixture")
            fixture.mkdir()
            subprocess.run([*flags, str(root / "tests/capacity_tests.m"),
                            str(source_cursor), str(source_capacity),
                            str(root / "AxsCacheKeeperDirectories.m"), "-o", str(binary)],
                           check=True, timeout=60)
            result = subprocess.run([str(binary), str(fixture), case],
                                    capture_output=True, text=True, timeout=60)
            print(result.stdout, end="", flush=True)
            print(result.stderr, end="", file=sys.stderr, flush=True)
            failures = [line for line in result.stderr.splitlines() if line.startswith("FAIL:")]
            if failure is None:
                if result.returncode != 0 or failures:
                    raise RuntimeError(f"capacity GREEN failed: exit={result.returncode}")
            elif result.returncode != 1 or failures != ["FAIL: capacity: " + failure]:
                raise RuntimeError(f"capacity RED {name} must fail only its named assertion; exit={result.returncode}")
            else:
                print(f"Verified capacity RED: {name}", flush=True)

        # Run RED before GREEN on the same commit. Replace one precise branch;
        # these anchors locate a mutation, they are NOT source-text assertions.
        variants = (
            ("expected-opened-root", "capacity", "if(!components.count && _requiresExpectedIdentity &&",
             "if(NO && !components.count && _requiresExpectedIdentity &&", "expected-identity",
             "opened root expected identity rejects ABA before any metadata accumulation"),
            ("root-observation", "cursor", "if(_metadataObserver) _metadataObserver(&opened,@[]);",
             "if(NO && _metadataObserver) _metadataObserver(&opened,@[]);", "empty",
             "empty root is observed once and has real directory allocation"),
            ("all-types", "cursor", "components=[frame.observerComponents arrayByAddingObject:name];_metadataObserver(&info,components);",
             "components=[frame.observerComponents arrayByAddingObject:name];if(S_ISREG(info.st_mode)) _metadataObserver(&info,components);", "observer",
             "observer receives root and every raw-byte entry without following links"),
            ("legacy-table", "cursor", "allocation:observer ? nil : [[AxsCacheKeeperScanAllocation alloc] initWithLimit:65536] metadataObserver:observer];",
             "allocation:[[AxsCacheKeeperScanAllocation alloc] initWithLimit:65536] metadataObserver:observer];", "observer",
             "observer mode retains no unrelated legacy inode observations"),
            ("block-unit", "capacity", "uint64_t allocated=duplicate ? 0 : (uint64_t)info->st_blocks*512;",
             "uint64_t allocated=duplicate ? 0 : (uint64_t)info->st_blocks*256;", "totals",
             "all-entry allocation includes root directories and links once"),
            ("deduplication", "capacity", "uint64_t allocated=duplicate ? 0 : (uint64_t)info->st_blocks*512;",
             "uint64_t allocated=(uint64_t)info->st_blocks*512;", "totals",
             "all-entry allocation includes root directories and links once"),
            ("metadata-change", "capacity", 'if(duplicate && ![old isEqual:sample]) { _failure=@"invalidMetadata";return; }',
             'if(NO && duplicate && ![old isEqual:sample]) { _failure=@"invalidMetadata";return; }', "metadata",
             "changed same inode metadata cannot finish successfully"),
            ("node-budget", "capacity", 'if(_nodes.count>=_nodeLimit) { _failure=@"nodeLimit";return; }',
             'if(NO && _nodes.count>=_nodeLimit) { _failure=@"nodeLimit";return; }', "budgets",
             "node budget exhaustion cannot silently truncate a complete hierarchy"),
            ("inode-budget", "capacity", 'if(!duplicate && _inodes.count>=_inodeLimit) {_failure=@"inodeLimit";return;}',
             'if(NO && !duplicate && _inodes.count>=_inodeLimit) {_failure=@"inodeLimit";return;}', "budgets",
             "inode budget exhaustion remains an incomplete measurement"),
            ("empty-stack-root", "cursor", 'if(lstat(_root.fileSystemRepresentation,&current) || !AxsCacheKeeperScanUnchanged(&_identity,&current)) return NO;',
             'if(_stack.count && (lstat(_root.fileSystemRepresentation,&current) || !AxsCacheKeeperScanUnchanged(&_identity,&current))) return NO;', "identity",
             "empty-stack final validation still checks the root pathname"),
            ("cancel", "capacity", '[_cursor stopWithState:accepted ? state : @"readError"];',
             'if(NO) [_cursor stopWithState:accepted ? state : @"readError"];', "cancellation",
             "cancelled measurement cannot advance or become complete"),
        )
        for name, target, old, new, case, failure in variants:
            product = cursor if target == "cursor" else capacity
            if product.count(old) != 1:
                raise RuntimeError(f"RED mutation anchor changed: {name}")
            mutation = product.replace(old, new)
            run(name, mutation if target == "cursor" else cursor,
                mutation if target == "capacity" else capacity, case, failure)
        run("green", cursor, capacity, "all")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
