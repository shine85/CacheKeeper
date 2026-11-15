"""Exercise real taps/keyboard in an installed iPhone Simulator, never a physical device."""
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
if sys.platform != "darwin":
    raise SystemExit("UNAVAILABLE: UIKit tests require macOS Simulator; no UI tests ran")
output = ROOT / "tmp" / "input-ui-tests"
output.mkdir(parents=True, exist_ok=True)
subprocess.run(["xcodegen", "generate", "--spec", str(ROOT / "tests/ui/project.yml"),
                "--project", str(output), "--project-root", str(output)], check=True, timeout=60)
devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"], text=True))
candidates = [d for runtime, items in devices["devices"].items() if ".iOS-" in runtime
              for d in items if d.get("isAvailable") and d["name"].startswith("iPhone")]
if not candidates:
    raise SystemExit("UNAVAILABLE: no installed iPhone Simulator runtime")
device = candidates[0]["udid"]
print("UIKit destination:", candidates[0]["name"], device, flush=True)
subprocess.run(["xcrun", "simctl", "boot", device], check=False, timeout=60)
# Hosted simulator migration exceeded the old 180-second startup budget in run 115.
# Keep startup bounded separately; the actual test deadline and assertions stay unchanged.
subprocess.run(["xcrun", "simctl", "bootstatus", device, "-b"], check=True, timeout=420)
build_options = ["-project", str(output / "CacheKeeperInputTests.xcodeproj"),
                 "-scheme", "InputHarness", "-destination", f"platform=iOS Simulator,id={device}",
                 "-derivedDataPath", str(output / "DerivedData"),
                 "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-"]
# Run 116 spent most of the combined deadline compiling; execution gets its own
# unchanged 600-second budget, against exactly the products built above.
subprocess.run(["xcodebuild", "build-for-testing", *build_options], check=True, timeout=600)
# WebKit's simulator services require an identifiable host. Ad-hoc signing needs no account.
subprocess.run(["codesign", "--verify", "--deep", "--strict",
                str(output / "DerivedData/Build/Products/Debug-iphonesimulator/InputHarness.app")],
               check=True, timeout=60)
# Run 127 exceeded the 600-second test budget with zero assertion failures: the keyboard
# input test alone took 268 seconds and the suite was cut off mid-test. Raise only the
# execution budget; no assertion or timeout inside the tests changes.
try:
    # The real WebKit session runs in a fresh host, isolated from the forty-view capacity probe.
    # Fail here before spending time on XCUI, while retaining every check on successful builds.
    subprocess.run(["xcodebuild", "test-without-building", *build_options,
                    "-only-testing:WebKitIntegrationTests",
                    "-resultBundlePath", str(output / "WebKitResults.xcresult"),
                    "-parallel-testing-enabled", "NO"], check=True, timeout=420)
    subprocess.run(["xcodebuild", "test-without-building", *build_options,
                    "-skip-testing:WebKitIntegrationTests",
                    "-resultBundlePath", str(output / "Results.xcresult"),
                    "-parallel-testing-enabled", "NO"], check=True, timeout=900)
finally:
    for result, screenshots in [("WebKitResults.xcresult", "WebKitScreenshots"),
                                ("Results.xcresult", "Screenshots")]:
        if (output / result).exists():
            subprocess.run(["xcrun", "xcresulttool", "export", "attachments",
                            "--path", str(output / result),
                            "--output-path", str(output / screenshots)], check=True, timeout=60)
