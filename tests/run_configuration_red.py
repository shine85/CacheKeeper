"""Prove the old execution/editing boundary admits malformed exclusions, then verify the fix."""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
baseline = "7de043c3ed89e607997add67e6e68d16fe72dd0d"
with tempfile.TemporaryDirectory(prefix="configuration-red-", dir=root / "tmp") as temp:
    target = pathlib.Path(temp)
    source = target / "main.m"
    source.write_text('''#import "AxsCacheKeeperPolicy.h"
#include <stdio.h>
int main(int argc, char **argv) {
    @autoreleasepool {
        NSDictionary *bad=@{@"enabled":@YES,@"excludedPaths":@"Library/Caches/keep"};
        if (axs_cachekeeper_app_enabled(bad)) { fprintf(stderr,"FAIL: malformed exclusions enable cleanup\\n");return 1; }
        NSString *path=[NSString stringWithUTF8String:argv[1]];
        if (![@{@"test.app":bad} writeToFile:path atomically:YES]) return 2;
        if (axs_cachekeeper_edit_configuration(path)) { fprintf(stderr,"FAIL: malformed exclusions permit editing\\n");return 1; }
    }
    return 0;
}
''', encoding="utf-8")
    for label in ("red", "green"):
        header = (subprocess.check_output(["git", "show", f"{baseline}:AxsCacheKeeperPolicy.h"], cwd=root, timeout=15)
                  if label == "red" else (root / "AxsCacheKeeperPolicy.h").read_bytes())
        (target / "AxsCacheKeeperPolicy.h").write_bytes(header)
        binary = target / label
        subprocess.run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-framework", "Foundation", str(source),
                        "-o", str(binary)], check=True, timeout=60)
        result = subprocess.run([str(binary), str(target / "appEnabled.plist")], capture_output=True, text=True, timeout=15)
        if label == "red":
            if result.returncode != 1 or "FAIL: malformed exclusions" not in result.stderr:
                raise SystemExit(f"Expected behavioral red; got {result.returncode}: {result.stderr}")
        elif result.returncode != 0:
            raise SystemExit(f"Repaired boundary failed: {result.returncode}: {result.stderr}")
        print(f"Verified configuration {label}:", result.stderr.strip() or "rejected malformed configuration")
