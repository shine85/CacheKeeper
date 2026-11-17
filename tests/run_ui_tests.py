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
    package = json.loads(resolved.read_text(encoding="utf-8"))
    pins = package.get("pins") if isinstance(package, dict) else None
    if not isinstance(pins, list) or any(not isinstance(pin, dict) for pin in pins):
        raise ValueError("SDWebImage Package.resolved has invalid pins")
    matches = [pin for pin in pins if pin.get("identity") == "sdwebimage"]
    state = matches[0].get("state") if len(matches) == 1 else None
    if not isinstance(state, dict) or state.get("revision") != expected:
        raise ValueError(f"SDWebImage build did not resolve required source {expected}")
    print("Verified SDWebImage source:", expected, flush=True)

subprocess.run([sys.executable, str(ROOT / "tests/run_search_editing_red.py"), device], check=True, timeout=1200)

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
failures = []

def record_failure(name, error):
    failures.append(name)
    print(f"FAIL: {name}: {error}", file=sys.stderr, flush=True)

def run_step(name, command, timeout):
    print("UIKit step:", name, flush=True)
    try:
        subprocess.run(command, check=True, timeout=timeout)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError) as error:
        record_failure(name, error)


def run_sdk_variant(version, revision, target, cases):
    stage = f"SDWebImage {version} preparation"
    try:
        spec = (ROOT / "tests/ui/project.yml").read_text(encoding="utf-8-sig")
        current_revision = "2de3a496eaf6df9a1312862adcfd54acd73c39c0"
        if spec.count(current_revision) != 1:
            raise ValueError("ambiguous SDWebImage dependency revision")
        spec = spec.replace(current_revision, revision)
        if target != "ImageCacheIntegrationTests":
            # Replace the target, its one source file and the scheme entry together.
            if spec.count("ImageCacheIntegrationTests") != 3:
                raise ValueError("ambiguous image integration target")
            spec = spec.replace("ImageCacheIntegrationTests", target)
        compatibility_spec = output / f"image-sdk-{version}.yml"
        compatibility_spec.write_text(spec, encoding="utf-8")
        stage = f"SDWebImage {version} generation"
        subprocess.run(["xcodegen", "generate", "--spec", str(compatibility_spec),
                        "--project", str(output), "--project-root", str(output)], check=True, timeout=60)
        stage = f"SDWebImage {version} build"
        subprocess.run(["xcodebuild", "build-for-testing", *build_options,
                        "-only-testing:" + target], check=True, timeout=600)
        stage = f"SDWebImage {version} revision"
        verify_sdk_revision(revision)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError, ValueError) as error:
        record_failure(stage, error)
        return
    for label, selection, result in cases:
        run_step(label, ["xcodebuild", "test-without-building", *build_options,
                         "-only-testing:" + selection, "-resultBundlePath", str(output / result),
                         "-parallel-testing-enabled", "NO"], timeout=420)


try:
    # The real WebKit session runs in a fresh host, isolated from the forty-view capacity probe.
    # Once the shared build is verified, independent suites all run before failure is reported.
    run_step("WebKit", ["xcodebuild", "test-without-building", *build_options,
                         "-only-testing:WebKitIntegrationTests",
                         "-resultBundlePath", str(output / "WebKitResults.xcresult"),
                         "-parallel-testing-enabled", "NO"], timeout=420)
    run_step("SDWebImage 5.21.7", ["xcodebuild", "test-without-building", *build_options,
                                 "-only-testing:ImageCacheIntegrationTests",
                                 "-resultBundlePath", str(output / "ImageCacheResults.xcresult"),
                                 "-parallel-testing-enabled", "NO"], timeout=420)
    run_step("ScanPage", ["xcodebuild", "test-without-building", *build_options,
                          "-only-testing:ScanPageTests", "-resultBundlePath", str(output / "ScanPageTests.xcresult"),
                          "-parallel-testing-enabled", "NO"], timeout=420)
    run_step("Search/XCUI", ["xcodebuild", "test-without-building", *build_options,
                             "-skip-testing:WebKitIntegrationTests",
                             "-skip-testing:ImageCacheIntegrationTests",
                             "-skip-testing:ScanPageTests",
                             "-resultBundlePath", str(output / "Results.xcresult"),
                             "-parallel-testing-enabled", "NO"], timeout=900)
    run_sdk_variant("5.15.5", "fb50c1d20f24db5322b2f8f379de3618f75fe08e", "ImageCacheIntegrationTests",
                    [("SDWebImage 5.15.5", "ImageCacheIntegrationTests", "ImageCache515Results.xcresult")])
    # The old SDK has a different API. Its own source and target are built against its exact
    # revision. The irreversible added-method test gets a separate test process.
    run_step("SDWebImage 5.10.4 admission baseline",
             [sys.executable, str(ROOT / "tests/run_image_legacy_red.py"), device], timeout=1200)
    run_sdk_variant("5.10.4", "a6b6e44eadf0d39250c10a7cc0e3b91d0bdb0e94", "ImageCacheLegacyIntegrationTests",
                    [("SDWebImage 5.10.4", "ImageCacheLegacyIntegrationTests/ImageCacheLegacyIntegrationTests",
                      "ImageCache510Results.xcresult"),
                     ("SDWebImage 5.10.4 absent API", "ImageCacheLegacyIntegrationTests/ImageCacheLegacyAbsentAPITests",
                      "ImageCache510AbsentResults.xcresult")])
finally:
    for result, screenshots in [("ScanPageTests.xcresult", "ScanPageScreenshots"),
                                ("WebKitResults.xcresult", "WebKitScreenshots"),
                                ("ImageCacheResults.xcresult", "ImageCacheScreenshots"),
                                ("ImageCache515Results.xcresult", "ImageCache515Screenshots"),
                                ("ImageCache510Results.xcresult", "ImageCache510Screenshots"),
                                ("ImageCache510AbsentResults.xcresult", "ImageCache510AbsentScreenshots"),
                                ("Results.xcresult", "Screenshots")]:
        if (output / result).exists():
            run_step(f"attachments {result}", ["xcrun", "xcresulttool", "export", "attachments",
                                              "--path", str(output / result),
                                              "--output-path", str(output / screenshots)], timeout=60)

if failures:
    print("FAIL: UIKit failed suites/stages: " + ", ".join(failures), file=sys.stderr, flush=True)
    raise SystemExit(1)
