"""Capacity-only UIKit suite and exact REDs. Windows is UNAVAILABLE.

No image sources/dependencies. Build/setup/timeouts never count as behavior RED.
All generated files remain under tmp/feedback-1792.
"""
import contextlib
from datetime import datetime, timezone
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time


DISCOVERY_TIMEOUT = 300
BOOT_TIMEOUT = 60
BOOTSTATUS_TIMEOUT = 420


def prepare_simulator(output):
    """One bounded cold discovery, then boot/readiness; persist before every command."""
    started = time.monotonic()
    summary = {"state": "preparing", "startedAt": datetime.now(timezone.utc).isoformat(),
               "elapsedSeconds": 0, "budgetSeconds": DISCOVERY_TIMEOUT + BOOT_TIMEOUT + BOOTSTATUS_TIMEOUT,
               "steps": []}

    def save():
        summary["elapsedSeconds"] = time.monotonic() - started
        (output / "prepare-summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")

    def command(stage, args, timeout):
        step_start = time.monotonic()
        row = {"stage": stage, "command": args, "timeoutSeconds": timeout, "state": "running",
               "elapsedSeconds": 0, "returncode": None,
               "stdout": "prepare-" + stage + ".stdout.log", "stderr": "prepare-" + stage + ".stderr.log"}
        summary["steps"].append(row)
        save()
        print(f"Capacity preparation: {stage} started (timeout {timeout}s); artifacts: {output}", flush=True)
        try:
            with (output / row["stdout"]).open("w", encoding="utf-8") as stdout, \
                    (output / row["stderr"]).open("w", encoding="utf-8") as stderr:
                result = subprocess.run(args, stdout=stdout, stderr=stderr, text=True, check=True, timeout=timeout)
            row.update(state="passed", returncode=result.returncode)
        except subprocess.TimeoutExpired as error:
            row.update(state="timeout", error=str(error))
            raise
        except subprocess.CalledProcessError as error:
            row.update(state="failed", returncode=error.returncode, error=str(error))
            raise
        except OSError as error:
            row.update(state="launchError", error=str(error))
            raise
        finally:
            row["elapsedSeconds"] = time.monotonic() - step_start
            save()
            print(f"Capacity preparation: {stage} {row['state']} after {row['elapsedSeconds']:.3f}s", flush=True)
        return (output / row["stdout"]).read_text(encoding="utf-8")

    save()
    try:
        if sys.platform != "darwin" or not shutil.which("xcrun") or not shutil.which("xcodegen"):
            summary.update(state="unavailable", reason="macOS Xcode/xcodegen and iPhone Simulator required")
            return None
        raw = command("discovery", ["xcrun", "simctl", "list", "devices", "available", "-j"], DISCOVERY_TIMEOUT)
        devices = json.loads(raw)
        if not isinstance(devices, dict) or not isinstance(devices.get("devices"), dict):
            raise ValueError("simctl discovery did not return a devices dictionary")
        candidates = []
        for runtime, items in devices["devices"].items():
            if not isinstance(items, list) or any(not isinstance(device, dict) for device in items):
                raise ValueError("simctl discovery returned invalid device entries")
            if ".iOS-" not in runtime:
                continue
            for device in items:
                if device.get("isAvailable") is True and isinstance(device.get("name"), str) and device["name"].startswith("iPhone"):
                    if not isinstance(device.get("udid"), str) or not device["udid"]:
                        raise ValueError("simctl discovery returned an iPhone without a UDID")
                    candidates.append(device)
        if not candidates:
            summary.update(state="unavailable", reason="no installed available iPhone Simulator")
            return None
        device = candidates[0]
        summary["device"] = {key: device.get(key) for key in ("name", "udid", "state")}
        save()
        if device.get("state") != "Booted":
            command("boot", ["xcrun", "simctl", "boot", device["udid"]], BOOT_TIMEOUT)
        command("bootstatus", ["xcrun", "simctl", "bootstatus", device["udid"], "-b"], BOOTSTATUS_TIMEOUT)
        summary["state"] = "ready"
        return device["udid"]
    except (subprocess.SubprocessError, OSError, ValueError) as error:
        summary.update(state="failed", error=str(error))
        raise
    finally:
        save()


def main():
    root = pathlib.Path(__file__).resolve().parents[1]
    workspace = root / "tmp" / "feedback-1792"
    workspace.mkdir(parents=True, exist_ok=True)
    output = pathlib.Path(tempfile.mkdtemp(prefix="capacity-page-", dir=workspace))
    print("Capacity page artifacts:", output, flush=True)
    try:
        device = prepare_simulator(output)
    except (subprocess.SubprocessError, OSError, ValueError) as error:
        print("FAIL: capacity page preparation; no UIKit RED/GREEN ran:", error, flush=True)
        return 1
    if device is None:
        print("UNAVAILABLE: capacity page preparation; see prepare-summary.json; no UIKit RED/GREEN ran.")
        return 2
    source = (root / "Prefs/DiagnosticsPage.m").read_text(encoding="utf-8")
    variants = [
        ("stale-running", 'NSDictionary *capacity=saved;',
         'NSDictionary *capacity=snapshot ?: saved;',
         "testBackgroundReplacesCachedRunningWithSameEpochSavedTerminal",
         "D1 stopped page exports saved terminal instead of cached running"),
        ("false-stop", '@"requestWrite":saved ? @"saved" : @"failed"',
         '@"requestWrite":error ? @"failed" : @"saved"',
         "testFalseStopReturnWithoutNSErrorCannotClaimSaved",
         "D1 BOOL false cannot become saved when NSError is nil"),
        ("old-report-export", 'self.exportButton.enabled=self.reportData && exportable && !self.collecting && !self.sharing && !self.axs_cachekeeper_capacityEpoch;',
         'self.exportButton.enabled=self.reportData && !self.collecting && !self.sharing && !self.axs_cachekeeper_capacityEpoch;',
         "testExportRequiresCurrentTerminalSummaryBinding",
         "旧容量绑定不能作为最新结果导出"),
        ("export-latest-terminal", 'if (!latestMatches) {',
         'if (NO && !latestMatches) {',
         "testExportActionRevalidatesLatestSavedCapacityBeforeSharing",
         "CAPACITY_EXPORT_LATEST: changed saved result must not reach sharing"),
    ]
    # Preserve the actual projects, build logs and xcresults even on setup failure.
    # CI uploads this one isolated directory; a failed build is never a RED.
    with contextlib.nullcontext():
        host = output / "Host.m"
        host.write_text('''#import <UIKit/UIKit.h>
#import "Preferences/PSViewController.h"
@implementation PSViewController
@end
@interface AxsCacheKeeperCapacityHost : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation AxsCacheKeeperCapacityHost
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)app;(void)options;self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController=[UIViewController new];[self.window makeKeyAndVisible];return YES;
}
@end
int main(int argc,char **argv) { @autoreleasepool {return UIApplicationMain(argc,argv,nil,NSStringFromClass(AxsCacheKeeperCapacityHost.class));} }
''', encoding="utf-8")
        modules = ["Diagnostics", "InjectionConditions", "StorageInventory", "HostEvidence", "HostPreflight", "OperationInfo",
                   "AppList", "Installation", "DiagnosticChannel", "PDFSession", "PDFInspection", "CollectionSession", "ImageCollection"]

        def run(name, product, method=None, expected=None):
            stage = output / name
            stage.mkdir()
            lines = []
            for line in product.splitlines():
                if line.startswith('#import "'):
                    relative = line.split('"')[1]
                    line = '#import ' + json.dumps(str((root / "Prefs" / relative).resolve()))
                lines.append(line)
            copied = stage / "DiagnosticsPage.m"
            copied.write_text("\n".join(lines) + "\n", encoding="utf-8")
            headers = f'{root / "tests/ui/include"} {root / "tests/include"}'
            settings = {"HEADER_SEARCH_PATHS": headers, "GCC_PREPROCESSOR_DEFINITIONS": "$(inherited) AXS_CACHEKEEPER_PDF_CLIENT=1"}
            spec = {"name": "CapacityPage", "options": {"bundleIdPrefix": "dev.local.cachekeeper.capacity", "deploymentTarget": {"iOS": "16.0"}},
                    "settings": {"base": {"CLANG_ENABLE_OBJC_ARC": True, "GENERATE_INFOPLIST_FILE": True, "CODE_SIGN_IDENTITY": "-"}},
                    "targets": {
                        "CapacityHost": {"type": "application", "platform": "iOS", "sources": [str(host), str(copied), str(root / "Prefs/HostPreflightPage.m"), str(root / "Prefs/ImageCollectionPage.m")] +
                                         [str(root / ("AxsCacheKeeper" + module + ".m")) for module in modules], "settings": {"base": settings}},
                        "CapacityPageTests": {"type": "bundle.unit-test", "platform": "iOS", "sources": [str(root / "tests/ui/CapacityPageTests.m")],
                                              "dependencies": [{"target": "CapacityHost"}], "settings": {"base": settings}}},
                    "schemes": {"CapacityHost": {"build": {"targets": {"CapacityHost": "all"}}, "test": {"targets": ["CapacityPageTests"]}}}}
            project = stage / "project.json"
            project.write_text(json.dumps(spec), encoding="utf-8")
            subprocess.run(["xcodegen", "generate", "--spec", str(project), "--project", str(stage)], check=True, timeout=60)
            options = ["-project", str(stage / "CapacityPage.xcodeproj"), "-scheme", "CapacityHost",
                       "-destination", f"platform=iOS Simulator,id={device}", "-derivedDataPath", str(stage / "DerivedData"),
                       "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-"]
            if method:
                options += ["-only-testing:CapacityPageTests/AxsCacheKeeperCapacityPageTests/" + method]
            with (stage / "build.log").open("w", encoding="utf-8") as log:
                subprocess.run(["xcodebuild", "build-for-testing", *options], check=True,
                               stdout=log, stderr=subprocess.STDOUT, timeout=600)
            result = stage / "Results.xcresult"
            with (stage / "test.log").open("w", encoding="utf-8") as log:
                process = subprocess.run(["xcodebuild", "test-without-building", *options, "-resultBundlePath", str(result),
                                          "-parallel-testing-enabled", "NO"], stdout=log, stderr=subprocess.STDOUT, timeout=420)
            summary = json.loads(subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result), "--format", "json"], text=True, timeout=60))
            (workspace / ("capacity-page-" + name + "-summary.json")).write_text(json.dumps(summary, indent=2), encoding="utf-8")
            shutil.copyfile(stage / "test.log", workspace / ("capacity-page-" + name + ".log"))
            if expected is None:
                if process.returncode or summary.get("failedTests") or not summary.get("passedTests"):
                    raise RuntimeError("capacity page GREEN did not pass actual UIKit behaviors")
            else:
                failures = summary.get("testFailures", [])
                if (process.returncode != 65 or summary.get("failedTests") != 1 or summary.get("totalTestCount") != 1 or
                        len(failures) != 1 or method not in str(failures[0]) or expected not in failures[0].get("failureText", "")):
                    raise RuntimeError("capacity page RED did not fail solely on exact assertion: " + name)
                print("Verified precise UIKit behavior RED:", name, flush=True)

        for name, before, after, method, expected in variants:
            if source.count(before) != 1:
                raise RuntimeError("ambiguous capacity page RED anchor: " + name)
            run(name, source.replace(before, after), method, expected)
        run("green", source)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
