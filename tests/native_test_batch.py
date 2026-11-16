"""Independent subprocess orchestration for native regression groups.

Each suite gets its own log and result. A failed suite never stops unrelated suites;
dependent suites are skipped when an upstream compile/setup suite is not green.
"""
from __future__ import annotations

import dataclasses
import json
import os
import subprocess
import time
import signal
from pathlib import Path
from typing import Iterable, Sequence


@dataclasses.dataclass(frozen=True)
class Suite:
    name: str
    command: Sequence[str]
    timeout_seconds: float = 60.0
    dependencies: Sequence[str] = ()
    environment: dict[str, str] | None = None


def _unavailable(result: subprocess.CompletedProcess[str]) -> bool:
    if result.returncode != 2:
        return False
    text = (result.stdout or "") + "\n" + (result.stderr or "")
    return any(line.lstrip().startswith("UNAVAILABLE:") for line in text.splitlines())


def _as_text(value) -> str:
    return value.decode("utf-8", errors="replace") if isinstance(value, bytes) else (value or "")


def _write_log(output: Path, name: str, stdout: str, stderr: str) -> str:
    stdout, stderr = _as_text(stdout), _as_text(stderr)
    log_name = name + ".log"
    (output / log_name).write_text(
        (stdout or "") + (("\n" + stderr) if stderr else ""), encoding="utf-8", errors="replace"
    )
    return log_name


def _run_process(command, cwd, env, timeout):
    # A suite wrapper may have a compiler/test child. Kill that entire isolated
    # process group on deadline so it cannot continue writing after the result.
    with subprocess.Popen(command, cwd=cwd, env=env, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True, encoding="utf-8", errors="replace",
                          start_new_session=(os.name != "nt")) as process:
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            if os.name == "nt":
                subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
                if process.poll() is None:
                    process.kill()
            else:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            stdout, stderr = process.communicate()
            raise subprocess.TimeoutExpired(command, timeout, output=stdout, stderr=stderr)
        return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)


def run_suites(suites: Iterable[Suite], output: Path, cwd: Path) -> dict:
    output.mkdir(parents=True, exist_ok=True)
    rows = []
    by_name = {}
    for suite in suites:
        unmet = [dep for dep in suite.dependencies if by_name.get(dep, {}).get("status") != "PASS"]
        started = time.monotonic()
        if unmet:
            row = {
                "name": suite.name, "status": "SKIPPED_DEPENDENCY", "returncode": None,
                "duration_seconds": 0.0, "dependencies": list(suite.dependencies),
                "blocked_by": unmet, "log": None,
            }
            print(f"{suite.name}: SKIPPED_DEPENDENCY ({', '.join(unmet)})")
            rows.append(row)
            by_name[suite.name] = row
            continue
        command = [str(part) for part in suite.command]
        env = None
        if suite.environment is not None:
            env = os.environ.copy()
            env.update(suite.environment)
        try:
            result = _run_process(command, cwd, env, float(suite.timeout_seconds))
            internal_timeout = result.returncode == 124 and any(
                line.startswith("NATIVE_TIMEOUT:") for line in result.stdout.splitlines())
            status = ("TIMEOUT" if internal_timeout else "UNAVAILABLE" if _unavailable(result)
                      else "PASS" if result.returncode == 0 else "FAIL")
            returncode = result.returncode
            stdout, stderr = result.stdout, result.stderr
        except subprocess.TimeoutExpired as error:
            status, returncode = "TIMEOUT", None
            stdout = error.stdout or ""
            stderr = error.stderr or ""
        except OSError as error:
            status, returncode = "FAIL", None
            stdout, stderr = "", f"{type(error).__name__}: {error}"
        duration = time.monotonic() - started
        log_name = _write_log(output, suite.name, stdout, stderr)
        row = {
            "name": suite.name, "status": status, "returncode": returncode,
            "duration_seconds": round(duration, 3), "timeout_seconds": suite.timeout_seconds,
            "dependencies": list(suite.dependencies), "blocked_by": [], "log": log_name,
        }
        detail = f" ({returncode})" if returncode is not None else ""
        print(f"{suite.name}: {status}{detail}", flush=True)
        if stdout:
            print(_as_text(stdout), end="" if _as_text(stdout).endswith("\n") else "\n", flush=True)
        if stderr:
            print(_as_text(stderr), end="" if _as_text(stderr).endswith("\n") else "\n", flush=True)
        rows.append(row)
        by_name[suite.name] = row
    failed = [row["name"] for row in rows if row["status"] in {"FAIL", "TIMEOUT", "SKIPPED_DEPENDENCY"}]
    unavailable = [row["name"] for row in rows if row["status"] == "UNAVAILABLE"]
    summary = {
        "status": "FAIL" if failed else ("UNAVAILABLE" if unavailable else "PASS"),
        "suites": rows, "failed": failed, "unavailable": unavailable,
    }
    (output / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("native summary: " + summary["status"])
    for row in rows:
        if row["status"] in {"FAIL", "TIMEOUT", "UNAVAILABLE", "SKIPPED_DEPENDENCY"}:
            print(f"  {row['name']}: {row['status']} log={row['log']}")
    return summary


def summary_exit_code(summary: dict) -> int:
    if summary["failed"]:
        return 1
    return 2 if summary["status"] == "UNAVAILABLE" else 0

