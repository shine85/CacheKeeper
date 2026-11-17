"""Compile production readonly callback; run real files/export and distinct Darwin notify peers."""
from __future__ import annotations
import contextlib
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]


def ready(process, log, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        text = log.read_text(encoding="utf-8") if log.exists() else ""
        if "READY\n" in text:
            return
        if process.poll() is not None:
            raise RuntimeError("notify peer exited before READY: " + text)
        time.sleep(.02)
    raise TimeoutError("notify peer readiness exceeded five seconds")


def run():
    if sys.platform != "darwin" or not shutil.which("xcrun"):
        print("UNAVAILABLE: host evidence requires macOS Foundation/Darwin notify; no native tests ran.")
        return 2
    (ROOT / "tmp").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="host-evidence-", dir=ROOT / "tmp") as directory:
        out = pathlib.Path(directory)
        wrapper = out / "host-production.m"
        declarations = ('#import <Foundation/Foundation.h>\n#include <notify.h>\n'
                        '#import "' + (ROOT / "AxsCacheKeeperPolicy.h").as_posix() + '"\n'
                        'extern NSDictionary *axs_cachekeeper_test_host_read(NSString *, NSError **);\n'
                        'extern uint32_t axs_cachekeeper_test_host_register(const char *, int *);\n'
                        'extern uint32_t axs_cachekeeper_test_host_get(int, uint64_t *);\n'
                        'extern uint32_t axs_cachekeeper_test_host_cancel(int);\n'
                        'extern void axs_cachekeeper_test_forbidden_effect(void);\n'
                        '#define axs_cachekeeper_read_input axs_cachekeeper_test_host_read\n'
                        '#define notify_register_check axs_cachekeeper_test_host_register\n'
                        '#define notify_get_state axs_cachekeeper_test_host_get\n'
                        '#define notify_cancel axs_cachekeeper_test_host_cancel\n')
        wrapper.write_text(declarations + '#import "' + (ROOT / "AxsCacheKeeperHostEvidence.m").as_posix() + '"\n', encoding="utf-8")
        sources = [ROOT / x for x in ["tests/host_evidence_tests.m", "AxsCacheKeeperDiagnostics.m",
                   "AxsCacheKeeperStorageInventory.m", "AxsCacheKeeperOperationInfo.m", "AxsCacheKeeperInstallation.m", "AxsCacheKeeperPDFInspection.m"]]
        flags = ["xcrun", "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format", "-I" + str(ROOT),
                 "-I" + str(ROOT / "tests/include"), "-framework", "Foundation"]
        for role, definition, present, absent in [
            ("server", "AXS_CACHEKEEPER_HOST_SERVER_ONLY=1", "Server", "Client"),
            ("client", "AXS_CACHEKEEPER_HOST_CLIENT_ONLY=1", "Client", "Server")]:
            object_file = out / (role + ".o")
            subprocess.run([*flags, "-D" + definition, "-c", str(ROOT / "AxsCacheKeeperHostEvidence.m"),
                            "-o", str(object_file)], check=True, timeout=60)
            symbols = subprocess.check_output(["xcrun", "nm", "-gj", str(object_file)], text=True, timeout=60)
            if "_OBJC_CLASS_$_AxsCacheKeeperHostEvidence" + present not in symbols or "_OBJC_CLASS_$_AxsCacheKeeperHostEvidence" + absent in symbols:
                raise RuntimeError("host role leaks or omits Objective-C class: " + role)
        print("PASS: actual production server/client role objects avoid duplicate runtime classes")
        binary = out / "host-tests"
        subprocess.run([*flags, *map(str, sources), str(wrapper), "-o", str(binary)], check=True, timeout=60)
        for mode in ("missingPhysical", "protocol", "files", "export", "timeout", "adversarial", "serverFailures"):
            subprocess.run([str(binary), mode, str(out / mode), "dev.local.hosttest." + uuid.uuid4().hex], check=True, timeout=60)
        # Mutate only the temporary production callback, then require its actual side-effect assertion.
        mutation = out / "host-mutated.m"
        source = (ROOT / "AxsCacheKeeperHostEvidence.m").read_text(encoding="utf-8")
        target = "- (void)axs_cachekeeper_answer {"
        if source.count(target) != 1:
            raise RuntimeError("ambiguous readonly mutation boundary")
        mutation.write_text(source.replace(target, target + "\n    axs_cachekeeper_test_forbidden_effect();"), encoding="utf-8")
        wrapper.write_text(declarations + '#import "' + mutation.as_posix() + '"\n', encoding="utf-8")
        red = out / "host-red"
        subprocess.run([*flags, *map(str, sources), str(wrapper), "-o", str(red)], check=True, timeout=60)
        result = subprocess.run([str(red), "files", str(out / "red"), "dev.local.hostred." + uuid.uuid4().hex], text=True, capture_output=True, timeout=60)
        expected = "FAIL: host evidence: readonly callback never executes policy authorization or cache side effects"
        if result.returncode != 1 or result.stderr.strip() != expected:
            raise RuntimeError("readonly callback mutation missed exact assertion: " + result.stdout + result.stderr)
        print("PASS: readonly production side-effect mutation reaches exact behavior RED")
        # Reproduce R1 by accepting an absent notify name's default state 0. The
        # actual client must reach the missing-frame assertion, never a link failure.
        marker_guard = "if ((uint32_t)(physical>>32)!=axs_cachekeeper_host_frame_marker(i)) return nil;"
        if source.count(marker_guard) != 1:
            raise RuntimeError("ambiguous physical marker mutation boundary")
        marker_mutation = out / "host-missing-marker.m"
        marker_mutation.write_text(source.replace(marker_guard,
            "if (physical && (uint32_t)(physical>>32)!=axs_cachekeeper_host_frame_marker(i)) return nil;"), encoding="utf-8")
        wrapper.write_text(declarations + '#import "' + marker_mutation.as_posix() + '"\n', encoding="utf-8")
        marker_red = out / "host-marker-red"
        subprocess.run([*flags, *map(str, sources), str(wrapper), "-o", str(marker_red)], check=True, timeout=60)
        result = subprocess.run([str(marker_red), "missingPhysical", str(out / "marker-red"),
                                 "dev.local.markered." + uuid.uuid4().hex], text=True, capture_output=True, timeout=60)
        expected = "FAIL: host evidence: every physical frame must have actually been published"
        if result.returncode != 1 or result.stderr.strip() != expected:
            raise RuntimeError("missing marker mutation missed exact assertion: " + result.stdout + result.stderr)
        print("PASS: missing-zero-frame production mutation reaches exact real-notify behavior RED")
        # Each peer is a fresh executable, never forked from a live Objective-C runtime.
        for index, (server_mode, client_mode, client_first) in enumerate([
            ("server", "client", False), ("server", "client", True),
            ("serverNoAttempt", "clientNoAttempt", True), ("serverNoGate", "clientNoGate", False)]):
            bundle = "dev.local.hostpeer." + uuid.uuid4().hex
            folder = out / ("denied" + str(index))
            first_mode, second_mode = (client_mode, server_mode) if client_first else (server_mode, client_mode)
            log = out / (str(index) + ".log")
            with log.open("w", encoding="utf-8") as stdout:
                peer = subprocess.Popen([str(binary), first_mode, str(folder), bundle], stdout=stdout, stderr=subprocess.STDOUT, text=True)
                try:
                    ready(peer, log)
                    subprocess.run([str(binary), second_mode, str(folder), bundle], check=True, timeout=60)
                    peer.wait(timeout=10)
                    if peer.returncode:
                        raise RuntimeError("notify peer failed: " + log.read_text(encoding="utf-8"))
                finally:
                    if peer.poll() is None:
                        peer.terminate()
                        peer.wait(timeout=5)
            print(log.read_text(encoding="utf-8"), end="")
        bundle = "dev.local.hostmulti." + uuid.uuid4().hex
        folder = out / "multi-denied"
        with contextlib.ExitStack() as stack:
            peers = []
            for index, mode in enumerate(("server", "serverDifferent")):
                log = out / ("multi-" + str(index) + ".log")
                output = stack.enter_context(log.open("w", encoding="utf-8"))
                peer = subprocess.Popen([str(binary), mode, str(folder), bundle], stdout=output, stderr=subprocess.STDOUT, text=True)
                peers.append((peer, log))
            try:
                for peer, log in peers:
                    ready(peer, log)
                subprocess.run([str(binary), "clientMulti", str(folder), bundle], check=True, timeout=60)
                for peer, log in peers:
                    peer.wait(timeout=10)
                    if peer.returncode:
                        raise RuntimeError("multiple-host peer failed: " + log.read_text(encoding="utf-8"))
            finally:
                for peer, _ in peers:
                    if peer.poll() is None:
                        peer.terminate()
                        peer.wait(timeout=5)
        print("PASS: two independent host processes publish coherent immutable response frames")
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
