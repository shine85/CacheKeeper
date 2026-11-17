"""Run every independent native group, retain logs, then return an aggregate exit code."""
from __future__ import annotations

import argparse
import pathlib
import runpy
import shutil
import subprocess
import sys
import tempfile
import time
import traceback

from native_test_batch import Suite, run_suites, summary_exit_code
import run_native_core

ROOT = pathlib.Path(__file__).resolve().parents[1]
# Wrapper budgets include several compile and test processes. Individual native
# commands retain their <=60 second timeout in their actual test runners.
SCRIPT_GROUPS = (
    ("presentation-red", "run_presentation_red.py", 180),
    ("configuration-red", "run_configuration_red.py", 240),
    ("diagnostics-red", "run_diagnostics_red.py", 180),
    ("network-initialization-red", "run_network_initialization_red.py", 180),
    ("owner-snapshot", "test_owner_snapshot.py", 60),
    ("storage-inventory", "run_storage_inventory_tests.py", 300),
    ("package-version", "package_version_tests.py", 60),
    ("runtime-receipt", "run_runtime_receipt_tests.py", 360),
    ("observation-export", "run_observation_export_tests.py", 180),
    ("operation-history", "run_operation_history_tests.py", 300),
    ("operation-export", "run_operation_export_tests.py", 300),
    ("installation-identity", "run_installation_identity_tests.py", 420),
    ("inspection-traversal", "run_inspection_traversal_tests.py", 180),
    ("image-publication", "run_image_publication_tests.py", 180),
    ("image-legacy-source", "run_image_legacy_source_tests.py", 180),
    ("image-runtime-source", "run_image_runtime_source_tests.py", 240),
    ("inspection-export", "run_inspection_export_tests.py", 180),
    ("scan-diagnostics", "run_scan_diagnostics_tests.py", 180),
    ("scan-task", "run_scan_task_tests.py", 180),
    ("host-evidence", "run_host_evidence_tests.py", 240),
    ("hardlink", "run_hardlink_tests.py", 180),
    ("diagnostic-channel-export-red", "run_diagnostic_channel_export_red.py", 180),
    ("diagnostic-channel-paths-red", "run_diagnostic_channel_paths_red.py", 180),
    ("diagnostic-channel-native-paths", "run_diagnostic_channel_native_paths.py", 180),
)
CORE_GROUPS = (
    ("installation-linkage", run_native_core.installation_linkage, 360),
    ("operation-linkage", run_native_core.operation_linkage, 240),
    ("webkit", run_native_core.webkit, 420),
    ("diagnostic-linkage", run_native_core.diagnostic_linkage, 240),
    ("pdf-linkage", run_native_core.pdf_linkage, 360),
    ("pdf-runtime-classes", run_native_core.pdf_runtime_classes, 540),
    ("pdf-lifecycle", run_native_core.pdf_lifecycle, 660),
    ("cache-control", run_native_core.cache_control, 180),
)


def _timeout_text(value) -> str:
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return str(value)


def _report_timeout(group: str, error: subprocess.TimeoutExpired) -> None:
    captured_stdout = _timeout_text(getattr(error, "stdout", None))
    captured_stderr = _timeout_text(getattr(error, "stderr", None))
    if captured_stdout:
        print(f"NATIVE_TIMEOUT_STDOUT: {captured_stdout}", flush=True)
    if captured_stderr:
        print(f"NATIVE_TIMEOUT_STDERR: {captured_stderr}", file=sys.stderr, flush=True)
    traceback.print_exc()
    print(f"NATIVE_TIMEOUT: {group}: command exceeded {error.timeout}s", flush=True)


def run_group(name: str) -> int:
    compiler = shutil.which("xcrun")
    if name not in {"owner-snapshot", "package-version"} and (sys.platform != "darwin" or not compiler):
        print("UNAVAILABLE: native regression tests require macOS and xcrun; no tests ran.")
        return 2
    for group, script, _ in SCRIPT_GROUPS:
        if group == name:
            # Preserve unittest/script argv semantics while keeping the timeout
            # boundary visible to the parent batch without patching subprocess.
            sys.argv = [str(ROOT / "tests" / script)]
            runpy.run_path(sys.argv[0], run_name="__main__")
            return 0
    for group, function, _ in CORE_GROUPS:
        if group == name:
            with tempfile.TemporaryDirectory(prefix="native-" + name + "-", dir=ROOT / "tmp") as directory:
                function(pathlib.Path(directory), compiler)
            return 0
    raise ValueError("unknown group: " + name)


def main(argv=None) -> int:
    # Windows redirected consoles may use a legacy code page; logs remain UTF-8.
    sys.stdout.reconfigure(errors="replace")
    sys.stderr.reconfigure(errors="replace")
    parser = argparse.ArgumentParser(description=__doc__)
    names = [name for name, _, _ in (*SCRIPT_GROUPS, *CORE_GROUPS)]
    parser.add_argument("--group", choices=names, help="execute one isolated group (used by the batch)")
    parser.add_argument("--output", type=pathlib.Path, default=None, help="directory for suite logs and summary.json")
    args = parser.parse_args(argv)
    (ROOT / "tmp").mkdir(exist_ok=True)
    if args.group:
        try:
            return run_group(args.group)
        except subprocess.TimeoutExpired as error:
            _report_timeout(args.group, error)
            return 124
    output = args.output or ROOT / "tmp" / ("native-results-" + str(time.time_ns()))
    suites = [Suite(name, [sys.executable, "-u", str(pathlib.Path(__file__).resolve()), "--group", name], timeout,
                    environment={"PYTHONIOENCODING": "utf-8"})
              for name, _, timeout in (*SCRIPT_GROUPS, *CORE_GROUPS)]
    summary = run_suites(suites, output, ROOT)
    print("Native suite report: " + str(output / "summary.json"))
    return summary_exit_code(summary)


if __name__ == "__main__":
    raise SystemExit(main())
