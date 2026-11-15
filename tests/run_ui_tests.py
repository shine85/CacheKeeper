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

def verify_sdk_revision(expected):
    resolved = output / "CacheKeeperInputTests.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    pins = json.loads(resolved.read_text(encoding="utf-8"))["pins"]
    matches = [pin for pin in pins if pin.get("identity") == "sdwebimage"]
    if len(matches) != 1 or matches[0].get("state", {}).get("revision") != expected:
        raise SystemExit(f"FAIL: SDWebImage build did not resolve required source {expected}")
    print("Verified SDWebImage source:", expected, flush=True)

# Run 116 spent most of the combined deadline compiling; execution gets its own
# unchanged 600-second budget, against exactly the products built above.
subprocess.run(["xcodebuild", "build-for-testing", *build_options], check=True, timeout=600)
verify_sdk_revision("2de3a496eaf6df9a1312862adcfd54acd73c39c0")
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
                    "-only-testing:ImageCacheIntegrationTests",
                    "-resultBundlePath", str(output / "ImageCacheResults.xcresult"),
                    "-parallel-testing-enabled", "NO"], check=True, timeout=420)
    subprocess.run(["xcodebuild", "test-without-building", *build_options,
                    "-skip-testing:WebKitIntegrationTests",
                    "-skip-testing:ImageCacheIntegrationTests",
                    "-resultBundlePath", str(output / "Results.xcresult"),
                    "-parallel-testing-enabled", "NO"], check=True, timeout=900)
    # The adapter admits both verified SDK versions. Rebuild the same behavior tests against
    # the second actual dependency, with an independent result bundle; never relabel 5.21.7.
    spec = (ROOT / "tests/ui/project.yml").read_text(encoding="utf-8-sig")
    current_revision = "2de3a496eaf6df9a1312862adcfd54acd73c39c0"
    legacy_revision = "fb50c1d20f24db5322b2f8f379de3618f75fe08e"
    if spec.count(current_revision) != 1:
        raise SystemExit("FAIL: ambiguous SDWebImage dependency revision")
    compatibility_spec = output / "image-sdk-5.15.5.yml"
    compatibility_spec.write_text(spec.replace(current_revision, legacy_revision), encoding="utf-8")
    subprocess.run(["xcodegen", "generate", "--spec", str(compatibility_spec),
                    "--project", str(output), "--project-root", str(output)], check=True, timeout=60)
    subprocess.run(["xcodebuild", "build-for-testing", *build_options,
                    "-only-testing:ImageCacheIntegrationTests"], check=True, timeout=600)
    verify_sdk_revision(legacy_revision)
    subprocess.run(["xcodebuild", "test-without-building", *build_options,
                    "-only-testing:ImageCacheIntegrationTests",
                    "-resultBundlePath", str(output / "ImageCache515Results.xcresult"),
                    "-parallel-testing-enabled", "NO"], check=True, timeout=420)
finally:
    for result, screenshots in [("WebKitResults.xcresult", "WebKitScreenshots"),
                                ("ImageCacheResults.xcresult", "ImageCacheScreenshots"),
                                ("ImageCache515Results.xcresult", "ImageCache515Screenshots"),
                                ("Results.xcresult", "Screenshots")]:
        if (output / result).exists():
            subprocess.run(["xcrun", "xcresulttool", "export", "attachments",
                            "--path", str(output / result),
                            "--output-path", str(output / screenshots)], check=True, timeout=60)
