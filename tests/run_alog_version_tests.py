"""Run production ALog rule decisions and an exact fallback regression control."""
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
BEGIN = '    // ALog version boundary: reserve known scope before generic fallback.\n'
END = '    // End ALog version boundary.\n'


def main():
    compiler = shutil.which('xcrun')
    if sys.platform != 'darwin' or not compiler:
        print('UNAVAILABLE: ALog rule behavior requires macOS Foundation and xcrun; no tests ran.')
        return 2
    (ROOT / 'tmp').mkdir(exist_ok=True)
    output = pathlib.Path(tempfile.mkdtemp(prefix='alog-version-', dir=ROOT / 'tmp'))
    source = (ROOT / 'AxsCacheKeeperCleanupRules.m').read_text(encoding='utf-8-sig')
    if source.count(BEGIN) != 1 or source.count(END) != 1 or source.index(BEGIN) >= source.index(END):
        print('FAIL: missing or ambiguous ALog negative-control boundary')
        return 1
    start, end = source.index(BEGIN), source.index(END) + len(END)
    controls = [('red', source[:start] + source[end:]), ('green', source)]
    deadline = time.monotonic() + 150
    def budget(maximum):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError('ALog runner total deadline')
        return min(maximum, remaining)
    rows = []
    for label, contents in controls:
        folder = output / label
        folder.mkdir()
        implementation = folder / 'AxsCacheKeeperCleanupRules.m'
        implementation.write_text(contents, encoding='utf-8')
        executable = folder / 'alog-version'
        built = subprocess.run([compiler, 'clang', '-fobjc-arc', '-fblocks', '-Wall', '-Wextra',
                                '-Werror=format', '-Werror=implicit-function-declaration', '-I' + str(ROOT),
                                str(implementation), str(ROOT / 'tests/alog_version_tests.m'),
                                '-framework', 'Foundation', '-o', str(executable)], capture_output=True, timeout=budget(60))
        (folder / 'compile.log').write_bytes(built.stdout + built.stderr)
        if built.returncode:
            print(built.stderr.decode(errors='replace'))
            return built.returncode
        run = subprocess.run([str(executable)], capture_output=True, timeout=budget(15))
        (folder / 'run.log').write_bytes(run.stdout + run.stderr)
        rows.append({'control': label, 'exit': run.returncode})
        (output / 'summary.json').write_text(json.dumps(rows, indent=2), encoding='utf-8')
        if label == 'red':
            expected = b'FAIL: alog-version: unsupported version cannot fall through to user log'
            if run.returncode != 1 or run.stdout or run.stderr.strip() != expected:
                print('FAIL: negative control did not reach the exact fallback regression')
                return 1
            print('PASS: exact ALog generic-fallback regression control')
        elif run.returncode:
            print(run.stderr.decode(errors='replace'))
            return run.returncode
        else:
            print(run.stdout.decode(), end='')
    print('Artifacts:', output)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
