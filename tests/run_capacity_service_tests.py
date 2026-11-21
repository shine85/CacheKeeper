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
    workspace = root / "tmp" / "feedback-1792"
    workspace.mkdir(parents=True, exist_ok=True)
    flags = [compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format",
             "-Werror=implicit-function-declaration", "-I" + str(root), "-I" + str(root / "tests/include"), "-framework", "Foundation"]
    with tempfile.TemporaryDirectory(prefix="capacity-service-", dir=workspace) as directory:
        output = pathlib.Path(directory)
        product = (root / "AxsCacheKeeperCapacityService.m").read_text(encoding="utf-8")
        status = (root / "AxsCacheKeeperCapacityStatus.h").read_text(encoding="utf-8")

        def run(name, source, case, expected=None, protocol=None):
            target = output / (name + "-source")
            (target / "tests").mkdir(parents=True)
            # Each RED gets the same-version real header closure. The copied test
            # imports ../Status.h, so protocol mutations actually reach projection.
            for header in ("AxsCacheKeeperCapacityService.h", "AxsCacheKeeperCapacity.h", "AxsCacheKeeperInstallation.h",
                           "AxsCacheKeeperFileAccess.h", "AxsCacheKeeperPolicy.h", "AxsCacheKeeperResourceLayout.h"):
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
            ("private-layout-owner", 'BOOL swiftGroup=[plan[@"owners"] isEqual:@[@"app.swiftgram.ios"]] && [plan[@"roles"] isEqual:@[@"group"]];',
             'BOOL swiftGroup=NO;', "private-layout", "registered Swiftgram group gets structural profile"),
            ("cursor-closure", 'if (_root) _allCursorsClosed &= _root.openDirectoryCount==0;',
             'if (_root) _allCursorsClosed=NO;', "history",
             "history links consecutive observations with real cursor closure evidence"),
            ("cold-closure", '_record[@"lifecycle"]=@{@"acceptedOperation":@"recovered",@"acceptedAt":AxsCacheKeeperCapacityNow(),@"cursorClosure":@"notObserved"};',
             '_record[@"lifecycle"]=@{@"acceptedOperation":@"recovered",@"acceptedAt":AxsCacheKeeperCapacityNow(),@"cursorClosure":@"observedZero",@"cursorClosedAt":AxsCacheKeeperCapacityNow()};',
             "history-failure", "restart never invents old process descriptor closure"),
            ("terminal-history", '[self axs_cachekeeper_remember:_record saved:YES supersededBy:nil];',
             '/* precise RED: omit successful terminal from next epoch */', "history",
             "saved cancellation remains in next epoch terminal history"),
            ("failed-terminal-history", '[self axs_cachekeeper_remember:_record saved:NO supersededBy:request[@"epoch"]];',
             '[self axs_cachekeeper_remember:_record saved:YES supersededBy:request[@"epoch"]];', "history-failure",
             "superseded failed cancel never claims a saved full result"),
            ("request-fields", "if (![keys isEqual:required]) return nil;", "if (NO && ![keys isEqual:required]) return nil;", "gates",
             "unknown request field cannot access provider or containers"),
            ("alias-identity", "NSMutableDictionary *existing=identities[identity];", "NSMutableDictionary *existing=nil;", "shared",
             "alias/shared root measured once with union owners"),
            ("cancel", 'return !request || ([request[@"operation"] isEqual:@"cancel"] && [request[@"epoch"] isEqual:_record[@"epoch"]]);', 'return NO;', "cancel",
             "cancel closes active measurement before completion"),
            ("alias-replacement", 'if (![expected isEqual:[NSData dataWithBytes:pair length:sizeof(pair)]]) {',
             'if (NO && ![expected isEqual:[NSData dataWithBytes:pair length:sizeof(pair)]]) {', "alias-replace",
             "changed alias cannot attribute old measurement to union owners as complete"),
            ("publication-epoch", 'return !request || [request[@"operation"] isEqual:@"cancel"] || [request[@"epoch"] isEqual:_record[@"epoch"]];',
             'return YES;', "replace",
             "provider-time replacement never publishes old epoch"),
            ("late-cancel", 'return !request || ([request[@"operation"] isEqual:@"cancel"] && [request[@"epoch"] isEqual:_record[@"epoch"]]);',
             'return !request || [request[@"operation"] isEqual:@"cancel"];', "late-cancel", "late cancel A must not terminate active B"),
            ("source-stat-errno", 'sourceFailure=@{@"stage":@"sourceStat",@"reason":@"statFailed",@"errorDomain":@"posix",@"errorCode":@(code)};',
             'sourceFailure=@{@"stage":@"sourceStat",@"reason":@"statFailed",@"errorDomain":@"posix",@"errorCode":@(EACCES)};', "source-errors",
             "missing source preserves actual lstat errno without a synthetic cursor"),
            ("source-cursor-closure", '_cursorObserved |= _root.cursorCreated;', '_cursorObserved=YES;', "source-errors",
             "source failure without cursor never claims observed cursor closure"),
            ("source-alias-cursor", '_root=observed && !_aliasChanged ?', '_root=observed ?', "source-alias",
             "alias mismatch before open has source evidence without opening replacement or cursor errno"),
            ("source-alias-errno", '*failure=@{@"stage":@"aliasRecheck",@"reason":@"statFailed",@"errorDomain":@"posix",@"errorCode":@(code)};',
             '*failure=@{@"stage":@"aliasRecheck",@"reason":@"statFailed",@"errorDomain":@"posix",@"errorCode":@(EACCES)};', "source-alias",
             "alias mismatch before open has source evidence without opening replacement or cursor errno"),
            ("unobserved-root", '[[AxsCacheKeeperCapacityRoot alloc] initWithSourceFailure:observed ? _aliasFailure : plan[@"sourceFailure"]]',
             '[[AxsCacheKeeperCapacityRoot alloc] initWithRoot:plan[@"url"]]', "unobserved",
             "unobserved source root cannot measure a later created directory as complete"),
        )
        for name, before, after, case, failure in mutations:
            if product.count(before) != 1:
                raise RuntimeError("ambiguous service RED anchor: " + name)
            run(name, product.replace(before, after), case, failure)
        protocol_mutations = (
            ("cursor-error-projection", 'out[@"cursorErrors"]=errors;', '/* precise RED: discard real cursor errors */',
             "cursor-errors", "real cursor error survives service schema and saved result"),
            ("cursor-error-counts", 'if (enumerated!=enumeration || statted!=stat) return nil;',
             'if (NO && (enumerated!=enumeration || statted!=stat)) return nil;', "error-schema",
             "contradictory cursor counts and detail fail closed"),
            ("cursor-error-truncation", 'if ((!omitted && !saturated) || (omitted<UINT32_MAX ? omitted<missing || (!saturated && omitted!=missing) : !saturated && missing<UINT32_MAX)) return nil;',
             '/* precise RED: accept contradictory truncated counts */', "error-schema",
             "contradictory cursor counts and detail fail closed"),
            ("complete-cursor-errors", 'if ([value[@"state"] isEqual:@"complete"] && ([errors[@"enumerationErrors"] unsignedLongLongValue] ||',
             'if (NO && [value[@"state"] isEqual:@"complete"] && ([errors[@"enumerationErrors"] unsignedLongLongValue] ||', "error-schema",
             "complete measurement cannot carry cursor errors"),
            ("complete-source-failure", 'if (!failure || [@[@"running",@"complete"] containsObject:value[@"state"]]) return nil;',
             'if (!failure) return nil;', "error-schema", "complete measurement cannot carry source failure"),
            ("node-depth", 'if (depth>axs_cachekeeper_resource_node_depth(layout) || ![node[@"entries"] unsignedLongLongValue]) return nil;',
             'if (! [node[@"entries"] unsignedLongLongValue]) return nil;', "nodes", "anonymous directory depth four is invalid"),
            ("node-sibling-totals", 'if (amount>maximum || sum>maximum-amount) return nil;',
             'if (amount>maximum) return nil;', "nodes", "direct sibling sums cannot exceed parent aggregate"),
            ("node-parent-entry", 'if ([key isEqual:@"entries"]) maximum--;',
             'if (NO && [key isEqual:@"entries"]) maximum--;', "nodes", "directory entries must retain the parent's own entry"),
        )
        for name, before, after, case, failure in protocol_mutations:
            if status.count(before) != 1:
                raise RuntimeError("ambiguous protocol RED anchor: " + name)
            mutation=status.replace(before, after)
            if name=="node-depth":
                # Remove all three depth protections for this one malformed-depth
                # counterexample; category/parent/aggregate checks otherwise remain.
                positioned='BOOL positioned=axs_cachekeeper_resource_node_valid('
                expansion='if (depth>3) {'
                if mutation.count(positioned)!=1 or mutation.count(expansion)!=1:
                    raise RuntimeError('depth protection mutation anchors changed')
                mutation=mutation.replace(positioned,'BOOL positioned=depth>3 || axs_cachekeeper_resource_node_valid(').replace(expansion,'if (NO && depth>3) {')
            run(name, product, case, failure, mutation)
        run("green", product, "all")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
