"""Independent Foundation/POSIX compile groups; subprocess commands retain their original bounds."""
import pathlib
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[1]


def run_command(command, *, check=False, capture_output=False, text=False, timeout=60):
    # Always retain diagnostics, including successful compiler warnings and expected RED output.
    print("COMMAND: " + repr(command), flush=True)
    result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    if result.stdout:
        print(result.stdout, end="", flush=True)
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr, flush=True)
    if check:
        result.check_returncode()
    return result


def installation_linkage(output, compiler):
    # Catch the Logos/Objective-C boundary before the expensive UIKit and Theos stages.
    installation_object = output / "installation.o"
    installation_flags = [compiler, "clang++", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format", "-Werror=implicit-function-declaration"]
    installation_caller = root / "tests" / "installation_linkage_tests.mm"
    run_command([compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format", "-Werror=implicit-function-declaration",
                    "-I" + str(root / "tests" / "include"), "-c",
                    str(root / "AxsCacheKeeperInstallation.m"), "-o", str(installation_object)],
                   check=True, timeout=60)
    # Recreate the missing-linkage header in tmp. Both translation units must compile;
    # only the link may fail, and it must identify all four real runtime dependencies.
    installation_header = (root / "AxsCacheKeeperInstallation.h").read_text(encoding="utf-8-sig")
    for guard in ('#ifdef __cplusplus\nextern "C" {\n#endif\n', '#ifdef __cplusplus\n}\n#endif\n'):
        if installation_header.count(guard) != 1:
            raise SystemExit("FAIL: ambiguous installation linkage mutation target")
        installation_header = installation_header.replace(guard, "")
    installation_baseline = output / "installation-baseline"
    installation_baseline.mkdir()
    (installation_baseline / "AxsCacheKeeperInstallation.h").write_text(installation_header, encoding="utf-8")
    baseline_object = installation_baseline / "caller.o"
    run_command([*installation_flags, "-I" + str(installation_baseline), "-I" + str(root), "-c",
                    str(installation_caller), "-o", str(baseline_object)], check=True, timeout=60)
    baseline = run_command([*installation_flags, "-framework", "Foundation", str(baseline_object),
                               str(installation_object), "-o", str(installation_baseline / "linkage")],
                              capture_output=True, text=True, timeout=60)
    expected_symbols = ("axs_cachekeeper_installation_snapshot(", "axs_cachekeeper_validate_installation_snapshot(",
                        "axs_cachekeeper_installation_snapshot_with_context(", "axs_cachekeeper_validate_installation_snapshot_with_context(")
    if baseline.returncode == 0 or "Undefined symbols" not in baseline.stderr or not all(
            symbol in baseline.stderr for symbol in expected_symbols):
        raise SystemExit("FAIL: missing C linkage did not reproduce the expected linker failure\n" +
                         baseline.stdout + baseline.stderr)
    print("PASS: installation missing-C-linkage baseline fails at all four expected exports")
    installation_linkage = output / "installation-linkage"
    run_command([*installation_flags, "-I" + str(root), "-framework", "Foundation",
                    str(installation_caller), str(installation_object), "-o", str(installation_linkage)],
                   check=True, timeout=60)
    run_command([str(installation_linkage)], check=True, timeout=60)


def operation_linkage(output, compiler):
    operation_object = output / "operation-info.o"
    operation_linkage = output / "operation-linkage"
    run_command([compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format", "-Werror=implicit-function-declaration", "-c",
                    str(root / "AxsCacheKeeperOperationInfo.m"), "-o", str(operation_object)],
                   check=True, timeout=60)
    run_command([compiler, "clang++", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format", "-Werror=implicit-function-declaration", "-I" + str(root),
                    "-framework", "Foundation", str(root / "tests/operation_linkage_tests.mm"),
                    str(operation_object), "-o", str(operation_linkage)], check=True, timeout=60)
    run_command([str(operation_linkage)], check=True, timeout=60)


def webkit(output, compiler):
    webkit_tests = output / "webkit-cache-tests"
    run_command([compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format", "-Werror=implicit-function-declaration",
                    "-framework", "Foundation", "-framework", "WebKit",
                    str(root / "AxsCacheKeeperWebKitCache.m"),
                    str(root / "AxsCacheKeeperOperationInfo.m"),
                    str(root / "tests" / "webkit_cache_tests.m"), "-o", str(webkit_tests)],
                   check=True, timeout=60)
    run_command([str(webkit_tests)], check=True, timeout=60)
    webkit_source = (root / "AxsCacheKeeperWebKitCache.m").read_text(encoding="utf-8-sig")
    webkit_mutations = [
        ("initial-configuration-deadline", [("[self axs_cachekeeper_schedule_initial_preparation:++_initialPreparationID after:10];", "++_initialPreparationID;")],
         "initial configuration wait owns the first preparation deadline"),
        ("preparation-deadline", [("[self axs_cachekeeper_schedule_preparation:attempt after:MAX(0,10-(now-_preparationStarted))];", "(void)attempt;")],
         "preparation owns a deadline before API submission"),
        ("equal-refresh", [("if (_preparing && wasPending) [self axs_cachekeeper_read_preparation];", "if (NO) [self axs_cachekeeper_read_preparation];")],
         "equal refresh resumes preparation without resetting its deadline"),
        ("foreground-state", [("_reason=@\"foregroundAgain\";\n    if (!_flight) _state=@\"blocked\";", "if (_flight) _reason=@\"foregroundAgain\";")],
         "foreground cancellation settles top-level queued state"),
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
        run_command([compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format", "-Werror=implicit-function-declaration", "-I" + str(root),
                        "-framework", "Foundation", "-framework", "WebKit", str(source),
                        str(root / "AxsCacheKeeperOperationInfo.m"),
                        str(root / "tests" / "webkit_cache_tests.m"), "-o", str(executable)],
                       check=True, timeout=60)
        result = run_command([str(executable)], capture_output=True, text=True, timeout=60)
        failures = [line for line in (result.stdout + result.stderr).splitlines() if line.startswith("FAIL:")]
        if result.returncode != 1 or failures != ["FAIL: webkit-cache: " + expected]:
            raise SystemExit("FAIL: WebKit mutation did not hit its behavioral assertion: " + name + "\n" + result.stdout + result.stderr)
        print("PASS: WebKit behavior mutation caught: " + name)


def diagnostic_linkage(output, compiler):
    # Keep the implementation in Objective-C and the caller in Objective-C++, as in Logos.
    # Run this before UIKit so missing C linkage fails in the native stage.
    channel_object = output / "diagnostic-channel.o"
    channel_linkage = output / "diagnostic-channel-linkage"
    run_command([compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format", "-Werror=implicit-function-declaration",
                    "-I" + str(root / "tests" / "include"), "-c",
                    str(root / "AxsCacheKeeperDiagnosticChannel.m"), "-o", str(channel_object)],
                   check=True, timeout=60)
    run_command([compiler, "clang++", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format", "-Werror=implicit-function-declaration",
                    "-framework", "Foundation", str(root / "tests" / "diagnostic_channel_linkage_tests.mm"),
                    str(channel_object), "-o", str(channel_linkage)], check=True, timeout=60)
    run_command([str(channel_linkage)], check=True, timeout=60)


def pdf_linkage(output, compiler):
    channel_object = output / "diagnostic-channel.o"
    channel_linkage = output / "diagnostic-channel-linkage"
    run_command([compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format", "-Werror=implicit-function-declaration",
                    "-I" + str(root / "tests" / "include"), "-c",
                    str(root / "AxsCacheKeeperDiagnosticChannel.m"), "-o", str(channel_object)],
                   check=True, timeout=60)
    pdf_objects = []
    for name in ("AxsCacheKeeperPDFInspection", "AxsCacheKeeperPDFSession"):
        object_path = output / (name + ".o")
        run_command([compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format", "-Werror=implicit-function-declaration",
                        "-I" + str(root / "tests" / "include"), "-c", str(root / (name + ".m")),
                        "-o", str(object_path)], check=True, timeout=60)
        pdf_objects.append(str(object_path))
    pdf_linkage = output / "pdf-session-linkage"
    run_command([compiler, "clang++", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format", "-Werror=implicit-function-declaration",
                    "-framework", "Foundation", str(root / "tests" / "pdf_session_linkage_tests.mm"),
                    str(channel_object), *pdf_objects, "-o", str(pdf_linkage)], check=True, timeout=60)
    run_command([str(pdf_linkage)], check=True, timeout=60)


def pdf_runtime_classes(output, compiler):
    # Both binaries can be loaded into Preferences by the existing UIKit filter. Their Objective-C
    # class definitions must remain disjoint; shared C helpers do not register runtime classes.
    role_classes = {}
    for role in ("CLIENT", "SERVER"):
        classes = set()
        for name in ("AxsCacheKeeperPDFInspection", "AxsCacheKeeperPDFSession"):
            object_path = output / (name + "-" + role + ".o")
            run_command([compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format", "-Werror=implicit-function-declaration",
                            "-DAXS_CACHEKEEPER_PDF_" + role + "=1", "-I" + str(root / "tests" / "include"),
                            "-c", str(root / (name + ".m")), "-o", str(object_path)], check=True, timeout=60)
            symbols = run_command([compiler, "nm", "-gU", str(object_path)], check=True, text=True, timeout=60).stdout
            classes.update(line.split()[-1] for line in symbols.splitlines() if "_OBJC_CLASS_$_AxsCacheKeeperPDF" in line)
        role_classes[role] = classes
    if role_classes["CLIENT"] & role_classes["SERVER"] or not all(role_classes.values()):
        raise SystemExit("FAIL: PDF client/server Objective-C runtime class definitions overlap or are missing")
    print("PASS: PDF client/server runtime classes are disjoint")


def pdf_lifecycle(output, compiler):
    channel_object = output / "diagnostic-channel.o"
    channel_linkage = output / "diagnostic-channel-linkage"
    run_command([compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format", "-Werror=implicit-function-declaration",
                    "-I" + str(root / "tests" / "include"), "-c",
                    str(root / "AxsCacheKeeperDiagnosticChannel.m"), "-o", str(channel_object)],
                   check=True, timeout=60)
    inspection_object = output / "AxsCacheKeeperPDFInspection.o"
    run_command([compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format", "-Werror=implicit-function-declaration",
                 "-I" + str(root / "tests" / "include"), "-c",
                 str(root / "AxsCacheKeeperPDFInspection.m"), "-o", str(inspection_object)],
                check=True, timeout=60)
    # Import the one production implementation into the standalone test translation unit.
    # Do not link PDFSession.o again: fixtures subclass only external dependency boundaries.
    lifecycle = output / "pdf-lifecycle"
    lifecycle_flags = [compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format", "-Werror=implicit-function-declaration",
                       "-I" + str(root / "tests" / "include"), "-I" + str(root),
                       "-framework", "Foundation"]
    lifecycle_objects = [str(channel_object), str(inspection_object)]
    run_command([*lifecycle_flags, str(root / "tests" / "pdf_lifecycle_tests.m"),
                    *lifecycle_objects, "-o", str(lifecycle)], check=True, timeout=60)
    run_command([str(lifecycle), str(output / "pdf-lifecycle-fixtures")], check=True, timeout=60)
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
        run_command([*lifecycle_flags, str(mutated_test), *lifecycle_objects, "-o", str(executable)],
                       check=True, timeout=60)
        result = run_command([str(executable), str(output / ("fixtures-" + name)), name],
                                capture_output=True, text=True, timeout=60)
        if result.returncode == 0 or expected not in result.stderr:
            raise SystemExit("FAIL: PDF mutation did not hit its behavioral assertion: " + name +
                             "\n" + result.stdout + result.stderr)
        print("PASS: PDF lifecycle mutation caught: " + name)


def cache_control(output, compiler):
    evidence_object = output / "release-evidence.o"
    run_command([compiler, "clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-c",
                 str(root / "AxsCacheKeeperReleaseEvidence.c"), "-o", str(evidence_object)], check=True, timeout=60)
    run_command([compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format", "-Werror=implicit-function-declaration",
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
                    str(evidence_object),
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
                    str(root / "AxsCacheKeeperInjectionConditions.m"),
                    str(root / "AxsCacheKeeperStorageInventory.m"),
                    str(root / "AxsCacheKeeperHostEvidence.m"),
                    str(root / "AxsCacheKeeperOperationInfo.m"),
                    str(root / "AxsCacheKeeperAppList.m"),
                    str(root / "AxsCacheKeeperInstallation.m"),
                    str(root / "AxsCacheKeeperDiagnosticChannel.m"),
                    "-o", str(output / "cache-tests")], check=True, timeout=60)
    run_command([str(output / "cache-tests"), str(output / "fixtures")], check=True, timeout=60)
