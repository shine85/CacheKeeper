"""Require the released adapter to reject the actual pinned 5.10.4 SDK."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
BASELINE = "d823af847a17231e245211817e4caa6e3c627993"
REVISION = "a6b6e44eadf0d39250c10a7cc0e3b91d0bdb0e94"
METHOD = "testFixedSerialContractAdmitsRealOwnerWithoutQueueAttributesAPI"


def main():
    if sys.platform != "darwin":
        raise SystemExit("UNAVAILABLE: legacy image SDK baseline requires macOS Simulator; no tests ran")
    output = ROOT / "tmp/image-legacy-red"
    baseline = output / "baseline"
    baseline.mkdir(parents=True, exist_ok=True)
    manifest = {"baseline": BASELINE, "sdkRevision": REVISION, "files": {}}
    for name in ("AxsCacheKeeperImageCache.m", "AxsCacheKeeperImageCache.h",
                 "AxsCacheKeeperImageCacheStatus.h", "AxsCacheKeeperCleanupRules.h", "AxsCacheKeeperPolicy.h"):
        source = subprocess.check_output(["git", "show", f"{BASELINE}:{name}"], cwd=ROOT, timeout=15)
        (baseline / name).write_bytes(source)
        manifest["files"][name] = hashlib.sha256(source).hexdigest()
    (output / "source-manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    spec = (ROOT / "tests/ui/project.yml").read_text(encoding="utf-8-sig")
    replacements = [
        ("2de3a496eaf6df9a1312862adcfd54acd73c39c0", REVISION, 1),
        ("ImageCacheIntegrationTests", "ImageCacheLegacyIntegrationTests", 3),
        ("../../AxsCacheKeeperImageCache.m", "baseline/AxsCacheKeeperImageCache.m", 1),
        ("      - path: ../../AxsCacheKeeperImageCacheRuntime.m\n", "", 1),
        ("AXS_CACHEKEEPER_IMAGE_TESTING=1", "AXS_CACHEKEEPER_IMAGE_TESTING=1 AXS_CACHEKEEPER_IMAGE_LEGACY_RED=1", 1),
    ]
    for before, after, count in replacements:
        if spec.count(before) != count:
            raise ValueError("Ambiguous legacy baseline project replacement: " + before)
        spec = spec.replace(before, after)
    (output / "project.yml").write_text(spec, encoding="utf-8")
    subprocess.run(["xcodegen", "generate", "--spec", str(output / "project.yml"),
                    "--project", str(output), "--project-root", str(output)], check=True, timeout=60)
    options = ["-project", str(output / "CacheKeeperInputTests.xcodeproj"), "-scheme", "InputHarness",
               "-destination", f"platform=iOS Simulator,id={sys.argv[1]}",
               "-derivedDataPath", str(output / "DerivedData"),
               "-only-testing:ImageCacheLegacyIntegrationTests/ImageCacheLegacyIntegrationTests/" + METHOD,
               "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-"]
    subprocess.run(["xcodebuild", "build-for-testing", *options], check=True, timeout=600)
    resolved = output / "CacheKeeperInputTests.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    package = json.loads(resolved.read_text(encoding="utf-8"))
    pins = package.get("pins") if isinstance(package, dict) else None
    if not isinstance(pins, list) or any(not isinstance(pin, dict) for pin in pins):
        raise ValueError("Legacy baseline Package.resolved has invalid pins")
    matches = [pin for pin in pins if pin.get("identity") == "sdwebimage"]
    if len(matches) != 1 or not isinstance(matches[0].get("state"), dict) or matches[0]["state"].get("revision") != REVISION:
        raise ValueError("Legacy baseline did not build the exact 5.10.4 source")
    result = output / "RedResults.xcresult"
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
            any(METHOD not in str(failure) or "legacy fixed-serial SDK admission" not in failure.get("failureText", "")
                for failure in failures)):
        raise RuntimeError("Released adapter did not fail solely on legacy SDK admission; inspect red.log/xcresult")
    print("PASS: released adapter rejects real SDWebImage 5.10.4 at the expected admission assertion", flush=True)


if __name__ == "__main__":
    main()
