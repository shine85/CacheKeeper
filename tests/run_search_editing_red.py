"""Require the pre-fix search geometry to fail the new UIKit regression, in isolation."""
import json
import pathlib
import subprocess
import sys


def main():
    if sys.platform != "darwin":
        raise SystemExit("UNAVAILABLE: search editing baseline requires macOS Simulator")
    root = pathlib.Path(__file__).resolve().parents[1]
    output = root / "tmp/search-editing-red"
    output.mkdir(parents=True, exist_ok=True)
    source = (root / "Prefs/SearchInput.m").read_text(encoding="utf-8")
    start = source.index("- (void)axs_cachekeeper_set_editing:(BOOL)editing {")
    end = source.index("- (void)textFieldDidBeginEditing:", start)
    source = source[:start] + """- (void)axs_cachekeeper_set_editing:(BOOL)editing {
    self.axs_cachekeeper_cancel_button.hidden=!editing;
}
""" + source[end:]
    for header in ("SearchInput.h", "SearchDiagnostics.h"):
        source = source.replace(f'#import "{header}"', f'#import "../../Prefs/{header}"')
    (output / "SearchInputRed.m").write_text(source, encoding="utf-8")
    spec = (root / "tests/ui/project.yml").read_text(encoding="utf-8-sig")
    original = "../../Prefs/SearchInput.m"
    if spec.count(original) != 1:
        raise ValueError("Ambiguous search input source in UIKit project")
    spec = spec.replace(original, "../../tmp/search-editing-red/SearchInputRed.m")
    (output / "project.yml").write_text(spec, encoding="utf-8")
    subprocess.run(["xcodegen", "generate", "--spec", str(output / "project.yml"),
                    "--project", str(output), "--project-root", str(output)], check=True, timeout=60)
    method = "testEditingVisibilityPublishesSettledControlGeometryBeforeParentLayout"
    options = ["-project", str(output / "CacheKeeperInputTests.xcodeproj"), "-scheme", "InputHarness",
               "-destination", f"platform=iOS Simulator,id={sys.argv[1]}",
               "-derivedDataPath", str(output / "DerivedData"),
               "-only-testing:SearchProbeTests/AxsCacheKeeperSearchProbeTests/" + method,
               "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-"]
    # Preserve compile failures even when no xcresult can be created.
    with (output / "build.log").open("w", encoding="utf-8") as log:
        subprocess.run(["xcodebuild", "build-for-testing", *options], stdout=log, stderr=subprocess.STDOUT,
                       check=True, timeout=600)
    result = output / "RedResults.xcresult"
    # Xcode collects diagnostics after an expected failure; #152 finished the test
    # in 10 seconds but exceeded 180 seconds while finalizing its result bundle.
    with (output / "red.log").open("w", encoding="utf-8") as log:
        process = subprocess.run(["xcodebuild", "test-without-building", *options,
                                  "-resultBundlePath", str(result), "-parallel-testing-enabled", "NO"],
                                 stdout=log, stderr=subprocess.STDOUT, timeout=420)
    summary = json.loads(subprocess.check_output(
        ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result), "--format", "json"],
        text=True, timeout=60))
    (output / "red-summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    failures = summary.get("testFailures", [])
    if (process.returncode != 65 or summary.get("failedTests") != 1 or
            summary.get("totalTestCount") != 1 or not failures or
            any(method not in str(failure) or "SEARCH_EDITING_GEOMETRY" not in failure.get("failureText", "")
                for failure in failures)):
        raise RuntimeError("Search baseline did not fail solely on the expected geometry assertions; inspect red.log/xcresult")
    print("PASS: old search visibility behavior fails the synchronous geometry regression", flush=True)


if __name__ == "__main__":
    main()
