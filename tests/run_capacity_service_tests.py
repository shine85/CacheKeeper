"""Production capacity service against real FS; Windows is explicitly unavailable.

Only provider metadata and actual writer failure are injected. RED copies must
compile and hit exactly the named behavioral assertion, never fail to link/run.
"""
import pathlib
import shutil
import subprocess
import sys
import tempfile


def main():
    compiler = shutil.which("xcrun")
    if sys.platform != "darwin" or not compiler:
        print("UNAVAILABLE: capacity service requires macOS Foundation and xcrun; no native RED/GREEN ran.")
        return 2
    root = pathlib.Path(__file__).resolve().parents[1]
    (root / "tmp").mkdir(exist_ok=True)
    flags = [compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format",
             "-Werror=implicit-function-declaration", "-I" + str(root), "-I" + str(root / "tests/include"), "-framework", "Foundation"]
    with tempfile.TemporaryDirectory(prefix="capacity-service-", dir=root / "tmp") as directory:
        output = pathlib.Path(directory)
        product = (root / "AxsCacheKeeperCapacityService.m").read_text(encoding="utf-8")
        status = (root / "AxsCacheKeeperCapacityStatus.h").read_text(encoding="utf-8")

        def run(name, source, case, expected=None, protocol=None):
            target = output / (name + "-source")
            (target / "tests").mkdir(parents=True)
            # Each RED gets the same-version real header closure. The copied test
            # imports ../Status.h, so protocol mutations actually reach projection.
            for header in ("AxsCacheKeeperCapacityService.h", "AxsCacheKeeperCapacity.h", "AxsCacheKeeperInstallation.h",
                           "AxsCacheKeeperFileAccess.h", "AxsCacheKeeperPolicy.h"):
                shutil.copyfile(root / header, target / header)
            (target / "AxsCacheKeeperCapacityStatus.h").write_text(status if protocol is None else protocol, encoding="utf-8")
            shutil.copyfile(root / "tests/capacity_service_tests.m", target / "tests/capacity_service_tests.m")
            path = target / "AxsCacheKeeperCapacityService.m"
            path.write_text(source, encoding="utf-8")
            binary = output / name
            fixture = output / (name + "-fixture")
            fixture.mkdir()
            subprocess.run([*flags, "-I" + str(target), str(path), str(target / "tests/capacity_service_tests.m"),
                            *[str(root / (module + ".m")) for module in ("AxsCacheKeeperCapacity", "AxsCacheKeeperScanTask", "AxsCacheKeeperDirectories", "AxsCacheKeeperInstallation")],
                            "-o", str(binary)], check=True, timeout=60)
            result = subprocess.run([str(binary), str(fixture), case], capture_output=True, text=True, timeout=60)
            print(result.stdout, end="", flush=True)
            print(result.stderr, end="", file=sys.stderr, flush=True)
            if expected is None:
                result.check_returncode()
            else:
                failures = [line for line in (result.stdout + result.stderr).splitlines() if line.startswith("FAIL:")]
                if result.returncode != 1 or failures != ["FAIL: capacity service: " + expected]:
                    raise RuntimeError(f"RED {name} did not hit its exact assertion: {result.returncode}, {failures}")
                print("Verified precise service behavior RED:", name)

        mutations = (
            ("request-fields", "if (![keys isEqual:required]) return nil;", "if (NO && ![keys isEqual:required]) return nil;", "gates",
             "unknown request field cannot access provider or containers"),
            ("alias-identity", "NSMutableDictionary *existing=identities[identity];", "NSMutableDictionary *existing=nil;", "shared",
             "alias/shared root measured once with union owners"),
            ("cancel", 'return !request || ([request[@"operation"] isEqual:@"cancel"] && [request[@"epoch"] isEqual:_record[@"epoch"]]);', 'return NO;', "cancel",
             "cancel closes active measurement before completion"),
            ("alias-replacement", 'if (![expected isEqual:[NSData dataWithBytes:pair length:sizeof(pair)]]) return NO;',
             'if (NO && ![expected isEqual:[NSData dataWithBytes:pair length:sizeof(pair)]]) return NO;', "alias-replace",
             "changed alias cannot attribute old measurement to union owners as complete"),
            ("publication-epoch", 'return !request || [request[@"operation"] isEqual:@"cancel"] || [request[@"epoch"] isEqual:_record[@"epoch"]];',
             'return YES;', "replace",
             "provider-time replacement never publishes old epoch"),
            ("late-cancel", 'return !request || ([request[@"operation"] isEqual:@"cancel"] && [request[@"epoch"] isEqual:_record[@"epoch"]]);',
             'return !request || [request[@"operation"] isEqual:@"cancel"];', "late-cancel", "late cancel A must not terminate active B"),
            ("unobserved-root", '[[AxsCacheKeeperCapacityRoot alloc] initWithRoot:nil]', '[[AxsCacheKeeperCapacityRoot alloc] initWithRoot:plan[@"url"]]', "unobserved",
             "unobserved source root cannot measure a later created directory as complete"),
        )
        for name, before, after, case, failure in mutations:
            if product.count(before) != 1:
                raise RuntimeError("ambiguous service RED anchor: " + name)
            run(name, product.replace(before, after), case, failure)
        protocol_mutations = (
            ("node-depth", 'if (depth>3 || ![node[@"entries"] unsignedLongLongValue]) return nil;',
             'if (! [node[@"entries"] unsignedLongLongValue]) return nil;', "anonymous directory depth four is invalid"),
            ("node-sibling-totals", 'if (amount>maximum || sum>maximum-amount) return nil;',
             'if (amount>maximum) return nil;', "direct sibling sums cannot exceed parent aggregate"),
            ("node-parent-entry", 'if ([key isEqual:@"entries"]) maximum--;',
             'if (NO && [key isEqual:@"entries"]) maximum--;', "directory entries must retain the parent's own entry"),
        )
        for name, before, after, failure in protocol_mutations:
            if status.count(before) != 1:
                raise RuntimeError("ambiguous protocol RED anchor: " + name)
            run(name, product, "nodes", failure, status.replace(before, after))
        run("green", product, "all")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
