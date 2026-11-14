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
                 "-derivedDataPath", str(output / "DerivedData"), "CODE_SIGNING_ALLOWED=NO"]
# Run 116 spent most of the combined deadline compiling; execution gets its own
# unchanged 600-second budget, against exactly the products built above.
subprocess.run(["xcodebuild", "build-for-testing", *build_options], check=True, timeout=600)
# Run 127 exceeded the 600-second test budget with zero assertion failures: the keyboard
# input test alone took 268 seconds and the suite was cut off mid-test. Raise only the
# execution budget; no assertion or timeout inside the tests changes.
try:
    subprocess.run(["xcodebuild", "test-without-building", *build_options,
                    "-resultBundlePath", str(output / "Results.xcresult"),
                    "-parallel-testing-enabled", "NO"], check=True, timeout=900)
finally:
    if (output / "Results.xcresult").exists():
        subprocess.run(["xcrun", "xcresulttool", "export", "attachments",
                        "--path", str(output / "Results.xcresult"),
                        "--output-path", str(output / "Screenshots")], check=True, timeout=60)
