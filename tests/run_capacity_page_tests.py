"""Capacity-only UIKit suite and exact REDs. Windows is UNAVAILABLE.

No image sources/dependencies. Build/setup/timeouts never count as behavior RED.
All generated files remain under tmp/feedback-1792.
"""
import contextlib
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile


def main():
    if sys.platform != "darwin" or not shutil.which("xcrun") or not shutil.which("xcodegen"):
        print("UNAVAILABLE: capacity page requires macOS Xcode/xcodegen and iPhone Simulator; no UIKit RED/GREEN ran.")
        return 2
    root = pathlib.Path(__file__).resolve().parents[1]
    workspace = root / "tmp" / "feedback-1792"
    workspace.mkdir(parents=True, exist_ok=True)
    devices = json.loads(subprocess.check_output(
        ["xcrun", "simctl", "list", "devices", "available", "-j"], text=True, timeout=60))
    candidates = [d for runtime, items in devices["devices"].items() if ".iOS-" in runtime
                  for d in items if d.get("isAvailable") and d["name"].startswith("iPhone")]
    if not candidates:
        print("UNAVAILABLE: no installed iPhone Simulator; no UIKit RED/GREEN ran.")
        return 2
    device = candidates[0]["udid"]
    subprocess.run(["xcrun", "simctl", "boot", device], check=False, timeout=60)
    subprocess.run(["xcrun", "simctl", "bootstatus", device, "-b"], check=True, timeout=420)
    source = (root / "Prefs/DiagnosticsPage.m").read_text(encoding="utf-8")
    variants = [
        ("stale-running", 'NSDictionary *capacity=frozen ? snapshot : wanted ? ([saved[@"epoch"] isEqual:wanted] ? saved : snapshot) : saved;',
         'NSDictionary *capacity=snapshot ?: saved;',
         "testBackgroundReplacesCachedRunningWithSameEpochSavedTerminal",
         "D1 stopped page exports saved terminal instead of cached running"),
        ("false-stop", '@"requestWrite":saved ? @"saved" : @"failed"',
         '@"requestWrite":error ? @"failed" : @"saved"',
         "testFalseStopReturnWithoutNSErrorCannotClaimSaved",
         "D1 BOOL false cannot become saved when NSError is nil"),
    ]
    # Preserve the actual projects, build logs and xcresults even on setup failure.
    # CI uploads this one isolated directory; a failed build is never a RED.
    with contextlib.nullcontext(tempfile.mkdtemp(prefix="capacity-page-", dir=workspace)) as directory:
        output = pathlib.Path(directory)
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
        modules = ["Diagnostics", "InjectionConditions", "StorageInventory", "HostEvidence", "OperationInfo",
                   "AppList", "Installation", "DiagnosticChannel", "PDFSession", "PDFInspection"]

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
                        "CapacityHost": {"type": "application", "platform": "iOS", "sources": [str(host), str(copied)] +
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
