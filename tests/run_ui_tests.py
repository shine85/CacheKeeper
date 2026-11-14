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
subprocess.run(["xcrun", "simctl", "bootstatus", device, "-b"], check=True, timeout=180)
subprocess.run(["xcodebuild", "test", "-project", str(output / "CacheKeeperInputTests.xcodeproj"),
                "-scheme", "InputHarness", "-destination", f"platform=iOS Simulator,id={device}",
                "-derivedDataPath", str(output / "DerivedData"), "-resultBundlePath", str(output / "Results.xcresult"),
                "-parallel-testing-enabled", "NO", "CODE_SIGNING_ALLOWED=NO"], check=True, timeout=600)
