"""在 macOS 编译运行真实 Foundation/POSIX 回归，所有产物放入项目 tmp。"""
import pathlib
import shutil
import subprocess
import sys
import time

root = pathlib.Path(__file__).resolve().parents[1]
compiler = shutil.which("xcrun")
if sys.platform != "darwin" or not compiler:
    print("UNAVAILABLE: native regression tests require macOS and xcrun; no tests ran.")
    raise SystemExit(2)
output = root / "tmp" / ("cache-tests-" + str(time.time_ns()))
output.mkdir(parents=True)
try:
    # Catch the Logos/Objective-C boundary before the expensive UIKit and Theos stages.
    installation_object = output / "installation.o"
    installation_flags = [compiler, "clang++", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra"]
    installation_caller = root / "tests" / "installation_linkage_tests.mm"
    subprocess.run([compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra",
                    "-I" + str(root / "tests" / "include"), "-c",
                    str(root / "AxsCacheKeeperInstallation.m"), "-o", str(installation_object)],
                   check=True, timeout=60)
    # Recreate the missing-linkage header in tmp. Both translation units must compile;
    # only the link may fail, and it must identify the two real runtime dependencies.
    installation_header = (root / "AxsCacheKeeperInstallation.h").read_text(encoding="utf-8-sig")
    for guard in ('#ifdef __cplusplus\nextern "C" {\n#endif\n', '#ifdef __cplusplus\n}\n#endif\n'):
        if installation_header.count(guard) != 1:
            raise SystemExit("FAIL: ambiguous installation linkage mutation target")
        installation_header = installation_header.replace(guard, "")
    installation_baseline = output / "installation-baseline"
    installation_baseline.mkdir()
    (installation_baseline / "AxsCacheKeeperInstallation.h").write_text(installation_header, encoding="utf-8")
    (installation_baseline / "AxsCacheKeeperInstallationDetail.h").write_bytes(
        (root / "AxsCacheKeeperInstallationDetail.h").read_bytes())
    baseline_object = installation_baseline / "caller.o"
    subprocess.run([*installation_flags, "-I" + str(installation_baseline), "-c",
                    str(installation_caller), "-o", str(baseline_object)], check=True, timeout=60)
    baseline = subprocess.run([*installation_flags, "-framework", "Foundation", str(baseline_object),
                               str(installation_object), "-o", str(installation_baseline / "linkage")],
                              capture_output=True, text=True, timeout=60)
    expected_symbols = ("axs_cachekeeper_installation_snapshot(", "axs_cachekeeper_validate_installation_snapshot(")
    if baseline.returncode == 0 or "Undefined symbols" not in baseline.stderr or not all(
            symbol in baseline.stderr for symbol in expected_symbols):
        raise SystemExit("FAIL: missing C linkage did not reproduce the expected linker failure\n" +
                         baseline.stdout + baseline.stderr)
    print("PASS: installation missing-C-linkage baseline fails at both expected exports")
    installation_linkage = output / "installation-linkage"
    subprocess.run([*installation_flags, "-I" + str(root), "-framework", "Foundation",
                    str(installation_caller), str(installation_object), "-o", str(installation_linkage)],
                   check=True, timeout=60)
    subprocess.run([str(installation_linkage)], check=True, timeout=60)
    webkit_tests = output / "webkit-cache-tests"
    subprocess.run([compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra",
                    "-framework", "Foundation", "-framework", "WebKit",
                    str(root / "AxsCacheKeeperWebKitCache.m"),
                    str(root / "tests" / "webkit_cache_tests.m"), "-o", str(webkit_tests)],
                   check=True, timeout=60)
    subprocess.run([str(webkit_tests)], check=True, timeout=60)
    webkit_source = (root / "AxsCacheKeeperWebKitCache.m").read_text(encoding="utf-8-sig")
    webkit_mutations = [
        ("exclusion", [("if ([context[@\"excludedPaths\"] count]) return @\"exclusionUnrepresentable\";", "")],
         "any exclusion blocks broad API"),
        ("in-flight", [("if (_flight) { _reason=@\"inFlight\";", "if (NO) { _reason=@\"inFlight\";"),
                        ("if (_flight || _preparing ||", "if (_preparing ||"),
                        ("if (reason || self->_flight) return;", "if (reason) return;")],
         "production receipt obeys closed schema"),
    ]
    for name, replacements, expected in webkit_mutations:
        mutated = webkit_source
        for before, after in replacements:
            if mutated.count(before) != 1:
                raise SystemExit("FAIL: ambiguous WebKit mutation target: " + name)
            mutated = mutated.replace(before, after)
        source = output / ("webkit-" + name + ".m")
        source.write_text(mutated, encoding="utf-8")
        executable = output / ("webkit-" + name)
        subprocess.run([compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-I" + str(root),
                        "-framework", "Foundation", "-framework", "WebKit", str(source),
                        str(root / "tests" / "webkit_cache_tests.m"), "-o", str(executable)],
                       check=True, timeout=60)
        result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=60)
        if result.returncode == 0 or expected not in result.stderr:
            raise SystemExit("FAIL: WebKit mutation did not hit its behavioral assertion: " + name + "\n" + result.stdout + result.stderr)
        print("PASS: WebKit behavior mutation caught: " + name)
    subprocess.run([sys.executable, str(root / "tests" / "run_scan_diagnostics_tests.py")],
                   check=True, timeout=60)
    subprocess.run([sys.executable, str(root / "tests" / "run_hardlink_tests.py")],
                   check=True, timeout=60)
    subprocess.run([sys.executable, str(root / "tests" / "run_diagnostic_channel_export_red.py")],
                   check=True, timeout=60)
    subprocess.run([sys.executable, str(root / "tests" / "run_diagnostic_channel_paths_red.py")],
                   check=True, timeout=60)
    subprocess.run([sys.executable, str(root / "tests" / "run_diagnostic_channel_native_paths.py")],
                   check=True, timeout=60)
    # Keep the implementation in Objective-C and the caller in Objective-C++, as in Logos.
    # Run this before UIKit so missing C linkage fails in the native stage.
    channel_object = output / "diagnostic-channel.o"
    channel_linkage = output / "diagnostic-channel-linkage"
    subprocess.run([compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra",
                    "-I" + str(root / "tests" / "include"), "-c",
                    str(root / "AxsCacheKeeperDiagnosticChannel.m"), "-o", str(channel_object)],
                   check=True, timeout=60)
    subprocess.run([compiler, "clang++", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra",
                    "-framework", "Foundation", str(root / "tests" / "diagnostic_channel_linkage_tests.mm"),
                    str(channel_object), "-o", str(channel_linkage)], check=True, timeout=60)
    subprocess.run([str(channel_linkage)], check=True, timeout=60)
    pdf_objects = []
    for name in ("AxsCacheKeeperPDFInspection", "AxsCacheKeeperPDFSession"):
        object_path = output / (name + ".o")
        subprocess.run([compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra",
                        "-I" + str(root / "tests" / "include"), "-c", str(root / (name + ".m")),
                        "-o", str(object_path)], check=True, timeout=60)
        pdf_objects.append(str(object_path))
    pdf_linkage = output / "pdf-session-linkage"
    subprocess.run([compiler, "clang++", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra",
                    "-framework", "Foundation", str(root / "tests" / "pdf_session_linkage_tests.mm"),
                    str(channel_object), *pdf_objects, "-o", str(pdf_linkage)], check=True, timeout=60)
    subprocess.run([str(pdf_linkage)], check=True, timeout=60)
    # Both binaries can be loaded into Preferences by the existing UIKit filter. Their Objective-C
    # class definitions must remain disjoint; shared C helpers do not register runtime classes.
    role_classes = {}
    for role in ("CLIENT", "SERVER"):
        classes = set()
        for name in ("AxsCacheKeeperPDFInspection", "AxsCacheKeeperPDFSession"):
            object_path = output / (name + "-" + role + ".o")
            subprocess.run([compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra",
                            "-DAXS_CACHEKEEPER_PDF_" + role + "=1", "-I" + str(root / "tests" / "include"),
                            "-c", str(root / (name + ".m")), "-o", str(object_path)], check=True, timeout=60)
            symbols = subprocess.check_output([compiler, "nm", "-gU", str(object_path)], text=True, timeout=60)
            classes.update(line.split()[-1] for line in symbols.splitlines() if "_OBJC_CLASS_$_AxsCacheKeeperPDF" in line)
        role_classes[role] = classes
    if role_classes["CLIENT"] & role_classes["SERVER"] or not all(role_classes.values()):
        raise SystemExit("FAIL: PDF client/server Objective-C runtime class definitions overlap or are missing")
    print("PASS: PDF client/server runtime classes are disjoint")
    # Import the one production implementation into the standalone test translation unit.
    # Do not link PDFSession.o again: fixtures subclass only external dependency boundaries.
    lifecycle = output / "pdf-lifecycle"
    lifecycle_flags = [compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra",
                       "-I" + str(root / "tests" / "include"), "-I" + str(root),
                       "-framework", "Foundation"]
    lifecycle_objects = [str(channel_object), pdf_objects[0]]
    subprocess.run([*lifecycle_flags, str(root / "tests" / "pdf_lifecycle_tests.m"),
                    *lifecycle_objects, "-o", str(lifecycle)], check=True, timeout=60)
    subprocess.run([str(lifecycle), str(output / "pdf-lifecycle-fixtures")], check=True, timeout=60)
    # Each mutation must compile and fail the specific behavioral assertion, never just fail
    # compilation or time out. Only isolated tmp copies change; the product stays untouched.
    session_source = (root / "AxsCacheKeeperPDFSession.m").read_text(encoding="utf-8-sig")
    lifecycle_source = (root / "tests" / "pdf_lifecycle_tests.m").read_text(encoding="utf-8-sig")
    mutations = [
        ("draining", "if (task || self.draining)", "if (task)",
         "second probe during draining must return busy before read returns"),
        ("publish", "if (self.task!=task || atomic_load(&task->cancelled)) return;\n"
         "        if ([task.binding expired:[self axs_cachekeeper_now]]) {[self axs_cachekeeper_invalidate:task];return;}", "",
         "late publish must not change retired or replacement task"),
        ("client-main", "if (!atomic_load(&self->_cancelled) && self->_update)", "if (self->_update)",
         "cancelled client suppresses already queued main update"),
    ]
    for name, before, after, expected in mutations:
        if session_source.count(before) != 1:
            raise SystemExit("FAIL: ambiguous PDF lifecycle mutation target: " + name)
        mutated_session = output / ("pdf-session-" + name + ".m")
        mutated_session.write_text(session_source.replace(before, after), encoding="utf-8")
        mutated_test = output / ("pdf-lifecycle-" + name + ".m")
        mutated_test.write_text(lifecycle_source.replace('#import "../AxsCacheKeeperPDFSession.m"',
                                '#import "' + mutated_session.as_posix() + '"'), encoding="utf-8")
        executable = output / ("pdf-lifecycle-" + name)
        subprocess.run([*lifecycle_flags, str(mutated_test), *lifecycle_objects, "-o", str(executable)],
                       check=True, timeout=60)
        result = subprocess.run([str(executable), str(output / ("fixtures-" + name)), name],
                                capture_output=True, text=True, timeout=60)
        if result.returncode == 0 or expected not in result.stderr:
            raise SystemExit("FAIL: PDF mutation did not hit its behavioral assertion: " + name +
                             "\n" + result.stdout + result.stderr)
        print("PASS: PDF lifecycle mutation caught: " + name)
    subprocess.run([compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra",
                    "-DAXS_CACHEKEEPER_INSTALLATION_TESTING=1",
                    "-I" + str(root / "tests" / "include"), "-framework", "Foundation",
                    str(root / "tests" / "cache_control_tests.m"), str(root / "Baseline.m"),
                    str(root / "Permissions.m"), str(root / "AxsCacheKeeperNetworkCache.m"),
                    str(root / "AxsCacheKeeperDirectories.m"),
                    str(root / "AxsCacheKeeperInspection.m"),
                    str(root / "AxsCacheKeeperPDFInspection.m"),
                    str(root / "AxsCacheKeeperPDFSession.m"),
                    str(root / "tests" / "pdf_inspection_tests.m"),
                    str(root / "tests" / "pdf_session_tests.m"),
                    str(root / "AxsCacheKeeperProcessObservation.m"),
                    str(root / "AxsCacheKeeperCleanupJob.m"),
                    str(root / "AxsCacheKeeperCleanupRules.m"),
                    str(root / "AxsCacheKeeperReceipts.m"),
                    str(root / "AxsCacheKeeperCleanupSchedule.m"),
                    str(root / "AxsCacheKeeperDependencySnapshot.m"),
                    str(root / "tests" / "plan_repair_tests.m"),
                    str(root / "tests" / "hardlink_tests.m"),
                    str(root / "tests" / "review_followup_tests.m"),
                    str(root / "tests" / "diagnostics_tests.m"),
                    str(root / "tests" / "search_diagnostics_tests.m"),
                    str(root / "tests" / "app_list_tests.m"),
                    str(root / "tests" / "app_retention_tests.m"),
                    str(root / "tests" / "installation_tests.m"),
                    str(root / "tests" / "network_cache_tests.m"),
                    str(root / "tests" / "diagnostic_channel_tests.m"),
                    str(root / "tests" / "diagnostic_channel_export_tests.m"),
                    str(root / "tests" / "presentation_tests.m"),
                    str(root / "AxsCacheKeeperDiagnostics.m"),
                    str(root / "AxsCacheKeeperAppList.m"),
                    str(root / "AxsCacheKeeperInstallation.m"),
                    str(root / "AxsCacheKeeperDiagnosticChannel.m"),
                    "-o", str(output / "cache-tests")], check=True, timeout=60)
    subprocess.run([str(output / "cache-tests"), str(output / "fixtures")], check=True, timeout=60)
finally:
    if output.resolve().parent == (root / "tmp").resolve():
        shutil.rmtree(output)
