"""Real Foundation projection/history tests with precise behavioral RED controls.

The aggregate work budget is 165 seconds; each compiler/test command is at most
60 seconds and capped by the remaining budget. Windows or absent xcrun
returns UNAVAILABLE/2; cross compilation is not native behavior verification.
Artifacts and logs stay in a unique local tmp directory for failure inspection.
"""
from __future__ import annotations

import hashlib
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
WORK_SECONDS = 165


def changed(source: str, before: str, after: str, label: str) -> str:
    if source.count(before) != 1:
        raise RuntimeError("ambiguous image-effect-status RED anchor: " + label)
    return source.replace(before, after)


def remaining(deadline: float) -> float:
    seconds = deadline - time.monotonic()
    if seconds <= 0:
        raise RuntimeError("image-effect-status aggregate 165-second budget exhausted; never a RED")
    return min(60.0, seconds)


def command(args: list[str], folder: pathlib.Path, name: str, deadline: float) -> subprocess.CompletedProcess:
    timeout = remaining(deadline)
    try:
        result = subprocess.run(args, cwd=ROOT, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        (folder / (name + ".stdout.log")).write_bytes(error.stdout or b"")
        (folder / (name + ".stderr.log")).write_bytes(error.stderr or b"")
        raise RuntimeError("image-effect-status " + name + " exceeded its remaining command budget; never a RED") from error
    (folder / (name + ".stdout.log")).write_bytes(result.stdout)
    (folder / (name + ".stderr.log")).write_bytes(result.stderr)
    return result


def main() -> int:
    deadline = time.monotonic() + WORK_SECONDS
    compiler = shutil.which("xcrun")
    if sys.platform != "darwin" or not compiler:
        print("UNAVAILABLE: image effect status/history tests require macOS and xcrun; no tests ran.")
        return 2
    (ROOT / "tmp").mkdir(exist_ok=True)
    output = pathlib.Path(tempfile.mkdtemp(prefix="image-effect-status-", dir=ROOT / "tmp"))
    print("Artifacts:", output, flush=True)
    status = (ROOT / "AxsCacheKeeperImageEffectStatus.h").read_text(encoding="utf-8-sig")
    operation = (ROOT / "AxsCacheKeeperOperationInfo.m").read_text(encoding="utf-8-sig")
    test = (ROOT / "tests/image_effect_status_tests.m").read_text(encoding="utf-8-sig")
    kernel = (ROOT / "AxsCacheKeeperImageEffect.h").read_text(encoding="utf-8-sig")
    operation_header = (ROOT / "AxsCacheKeeperOperationInfo.h").read_text(encoding="utf-8-sig")
    # Mutations are compiled in isolated directories; production is never changed.
    controls = [
        ("wrong-result", "projection", "wrong result cannot claim empty",
         changed(status, "return [record isEqual:value] ? record : nil;", "return record;", "wrong-result"), operation),
        ("boolean-counts", "projection", "boolean fractional negative and unsafe counts are rejected",
         changed(status, " || CFGetTypeID((__bridge CFTypeRef)n)==CFBooleanGetTypeID()", "", "boolean-counts"), operation),
        ("drop-effect", "history", "submitted image action atomically completes with its effect", status,
         changed(operation, 'action[@"cacheEffect"]=valid;', '(void)valid;', "drop-effect")),
        ("component", "invalid", "non-image component rejects image effect", status,
         changed(operation, 'if (![history[@"raw"][@"component"] isEqual:@"image"]) return;', '', "component")),
        ("queued", "invalid", "queued and terminal actions reject new effect", status,
         changed(operation, 'if (![action[@"state"] isEqual:@"submitted"] || action[@"cacheEffect"]) return;',
                 'if ((! [action[@"state"] isEqual:@"submitted"] && ![action[@"state"] isEqual:@"queued"]) || action[@"cacheEffect"]) return;', "queued")),
        ("action-association", "late", "late old action effect cannot complete or contaminate new action", status,
         changed(operation, 'if ([action[@"actionID"] unsignedIntegerValue]!=identifier) continue;',
                 'if ([action[@"actionID"] unsignedIntegerValue]!=[history[@"nextAction"] unsignedIntegerValue]) continue;', "action-association")),
        ("raw-component", "raw", "raw non-image history cannot carry cacheEffect", status,
         changed(operation, 'if (![value[@"component"] isEqual:@"image"] || ![action[@"state"] isEqual:@"apiCompleted"] ||',
                 'if (![action[@"state"] isEqual:@"apiCompleted"] ||', "raw-component")),
        ("green", "all", None, status, operation),
    ]
    for label, case, expected, schema_source, operation_source in controls:
        remaining(deadline)
        folder = output / label
        folder.mkdir()
        # Both translation units import the same copied schema/kernel closure.
        for name, contents in (("AxsCacheKeeperImageEffectStatus.h", schema_source),
                               ("AxsCacheKeeperImageEffect.h", kernel),
                               ("AxsCacheKeeperOperationInfo.h", operation_header),
                               ("AxsCacheKeeperOperationInfo.m", operation_source),
                               ("image_effect_status_tests.m", test)):
            (folder / name).write_text(contents, encoding="utf-8")
        (folder / "source-hashes.json").write_text(json.dumps({name: hashlib.sha256((folder / name).read_bytes()).hexdigest()
            for name in ("AxsCacheKeeperImageEffectStatus.h", "AxsCacheKeeperImageEffect.h", "AxsCacheKeeperOperationInfo.h",
                         "AxsCacheKeeperOperationInfo.m", "image_effect_status_tests.m")}, indent=2), encoding="utf-8")
        executable = folder / "image-effect-status"
        built = command([compiler, "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror=format",
                         "-Werror=implicit-function-declaration", "-I" + str(folder), "-I" + str(ROOT),
                         "-framework", "Foundation", str(folder / "AxsCacheKeeperOperationInfo.m"),
                         str(folder / "image_effect_status_tests.m"), "-o", str(executable)], folder, "build", deadline)
        if built.returncode:
            raise RuntimeError("image-effect-status build failed; never a RED: " + label + "\n" + built.stderr.decode(errors="replace"))
        executed = command([str(executable), case, str(folder / "effect-export.json")], folder, "run", deadline)
        if expected:
            message = ("FAIL: image-effect-status: " + expected).encode()
            if executed.returncode != 1 or executed.stdout.strip() or executed.stderr.strip() != message:
                raise RuntimeError("precise image-effect-status RED not reached: " + label + "\n" +
                                   (executed.stdout + executed.stderr).decode(errors="replace"))
            print("PASS: image-effect-status precise RED " + label, flush=True)
        else:
            if executed.returncode != 0 or executed.stderr.strip() or executed.stdout.strip() != b"PASS: image-effect-status all":
                raise RuntimeError("image-effect-status GREEN failed\n" + (executed.stdout + executed.stderr).decode(errors="replace"))
            exported = json.loads((folder / "effect-export.json").read_text(encoding="utf-8"))
            action = exported["processes"][-1]["actions"][0]
            if action["cacheEffect"]["result"] != "residual" or "processID" in exported["processes"][-1]:
                raise RuntimeError("JSON artifact did not retain anonymous effect")
            print("PASS: image-effect-status all (real Foundation history and JSON)", flush=True)
    remaining(deadline)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print("FAIL:", error, file=sys.stderr)
        raise SystemExit(1)
