"""Run all UIKit assertions with bounded process groups and durable stage outcomes."""
import argparse
import contextlib
import json
import os
import pathlib
import signal
import stat
import subprocess
import sys
import tarfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
BUDGETS = dict(generate=60, discovery=300, boot=60, bootstatus=420,
               search_red=1200, build=600, codesign=60, suite=420, search=900,
               legacy_red=1320, history_red=1200, export=60, archive=120)
MAX_COMMANDS = 29
RUNNER_BUDGET_SECONDS = 10700
GROUP_GRACE_SECONDS = 2
CURRENT = "2de3a496eaf6df9a1312862adcfd54acd73c39c0"
RESULTS = (("ScanPageTests.xcresult", "ScanPageScreenshots"),
           ("WebKitResults.xcresult", "WebKitScreenshots"),
           ("ImageCacheResults.xcresult", "ImageCacheScreenshots"),
           ("ImageCache515Results.xcresult", "ImageCache515Screenshots"),
           ("ImageCache510Results.xcresult", "ImageCache510Screenshots"),
           ("ImageCache510AbsentResults.xcresult", "ImageCache510AbsentScreenshots"),
           ("Results.xcresult", "Screenshots"))
SUITES = ("WebKit", "SDWebImage 5.21.7", "ScanPage", "Search/XCUI", "SDWebImage 5.15.5",
          "SDWebImage 5.10.4 admission baseline", "SDWebImage 5.10.4", "SDWebImage 5.10.4 absent API", "Cleanup history summary baseline")


def command_budget_seconds():
    # 3 generations/builds, seven test invocations, three RED wrappers, seven exports.
    return (3*BUDGETS['generate'] + BUDGETS['discovery'] + BUDGETS['boot'] + BUDGETS['bootstatus'] +
            BUDGETS['search_red'] + 3*BUDGETS['build'] + BUDGETS['codesign'] +
            6*BUDGETS['suite'] + BUDGETS['search'] + BUDGETS['legacy_red'] + BUDGETS['history_red'] + 7*BUDGETS['export'])


class Cancelled(BaseException):
    def __init__(self, signum):
        self.signum = signum


class GroupCleanupError(RuntimeError):
    pass


@contextlib.contextmanager
def cancellation_signals():
    def stop(signum, frame):
        raise Cancelled(signum)
    previous = {}
    try:
        for signum in (signal.SIGINT, signal.SIGTERM):
            previous[signum] = signal.signal(signum, stop)
        yield
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)


def group_exists(pid):
    try:
        os.killpg(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        try:
            result = subprocess.run(['ps', '-Ao', 'pid=,pgid=,stat=,uid='],
                                    capture_output=True, text=True, timeout=3, check=False)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise GroupCleanupError('cannot inspect owned command process group') from error
        if result.returncode != 0:
            raise GroupCleanupError('cannot inspect owned command process group')
        try:
            members = []
            saw_self = False
            uid = os.geteuid()
            for line in result.stdout.splitlines():
                fields = line.split()
                if len(fields) != 4:
                    raise ValueError('invalid ps process row')
                member_pid, member_group, state, owner = fields
                if not state:
                    raise ValueError('empty process state')
                row_pid, row_group, row_uid = int(member_pid), int(member_group), int(owner)
                if row_pid == os.getpid():
                    if row_uid != uid:
                        raise ValueError('current process owner mismatch')
                    saw_self = True
                if row_group == pid:
                    members.append((row_pid, state, row_uid))
        except ValueError as error:
            raise GroupCleanupError('invalid process listing while checking owned command group') from error
        if not saw_self:
            raise GroupCleanupError('process listing omitted current supervisor')
        if not members:
            return False
        if any(owner != uid for _, _, owner in members):
            raise GroupCleanupError('owned command process group contains another user')
        return any(state[0] not in ('Z', 'X') for _, state, _ in members)


def stop_group(process):
    """Own only this command's session, including grandchildren of RED wrappers."""
    previous = {}
    pending = []
    cleanup_failed = False
    try:
        for signum in (signal.SIGINT, signal.SIGTERM):
            # Finish bounded cleanup, then honor a cancellation arriving during it.
            previous[signum] = signal.signal(signum, lambda value, frame: pending.append(value))
        if os.name != 'posix':
            # Windows only runs local supervisor tests. UIKit remains unavailable there.
            if process.poll() is None:
                subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3, check=False)
                process.kill()
            process.wait(timeout=3)
            return
        if not group_exists(process.pid):
            process.wait(timeout=GROUP_GRACE_SECONDS)
            return
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        deadline = time.monotonic() + GROUP_GRACE_SECONDS
        while time.monotonic() < deadline:
            process.poll()  # Reap the leader before checking the remaining group.
            if not group_exists(process.pid):
                return
            time.sleep(.05)
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=GROUP_GRACE_SECONDS)
        deadline = time.monotonic() + GROUP_GRACE_SECONDS
        while time.monotonic() < deadline:
            if not group_exists(process.pid):
                return
            time.sleep(.05)
        raise GroupCleanupError('owned command process group still present after SIGKILL')
    except BaseException:
        cleanup_failed = True
        raise
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)
        if pending and not cleanup_failed:
            raise Cancelled(pending[0])


def run_command(command, *, timeout, check=True, capture_output=False, text=False):
    options = dict(start_new_session=os.name == 'posix')
    if capture_output:
        options.update(stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=text)
    process = subprocess.Popen(command, **options)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except BaseException:
        stop_group(process)
        raise
    # A wrapper may exit after killing only its direct child: its group can still write xcresult.
    stop_group(process)
    result = subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
    if check:
        result.check_returncode()
    return result


def atomic_json(path, value):
    temporary = path.with_name(path.name + '.partial')
    temporary.write_text(json.dumps(value, indent=2), encoding='utf-8')
    # Windows can briefly deny replacing a closed file. Retry the same atomic
    # operation within a fixed budget; permanent denial keeps both receipts.
    for attempt in range(6):
        try:
            os.replace(temporary, path)
            return
        except PermissionError as error:
            if os.name != 'nt' or getattr(error, 'winerror', None) not in (5, 32, 33) or attempt == 5:
                raise
            time.sleep(.01 * (2 ** attempt))


def archive_candidates(root):
    output = root / 'tmp/input-ui-tests'
    candidates = [output / name for pair in RESULTS for name in pair]
    candidates += [output / 'run-summary.json']
    candidates += [root / 'tmp/history-display-red-results']
    for directory in ('search-editing-red', 'image-legacy-red'):
        candidates += [root / 'tmp' / directory / name for name in
                       ('RedResults.xcresult', 'red-summary.json', 'red.log', 'build.log', 'source-manifest.json')]
    return candidates


def archive_worker(root):
    """Only publish a closed archive. Missing/mutating bundles are recorded, never treated as passing tests."""
    destination = root / 'tmp/ui-artifacts'
    destination.mkdir(parents=True, exist_ok=True)
    summary = dict(state='archiving', included=[], unavailable=[], error=None)
    target = destination / 'UIKit-results.tar.gz'
    partial = destination / 'UIKit-results.tar.gz.partial'
    try:
        if target.exists() or partial.exists():
            raise ValueError('archive destination already exists; refusing stale evidence')
        ledger = root / 'tmp/input-ui-tests/run-summary.json'
        run = json.loads(ledger.read_text(encoding='utf-8')) if ledger.is_file() else {}
        settled = (run.get('state') in ('passed', 'failed', 'cancelled') and
                   run.get('processGroupsSettled') is True and
                   not any(row.get('state') == 'running' for row in run.get('stages', [])))
        with tarfile.open(partial, 'x:gz', dereference=False) as archive:
            for path in archive_candidates(root):
                if not path.exists():
                    continue
                if not settled and path != ledger:
                    summary['unavailable'].append(dict(path=str(path.relative_to(root)), reason='processGroupsNotConfirmedSettled'))
                    continue
                if path.is_symlink():
                    raise ValueError('artifact root is a symlink')
                if path.suffix == '.xcresult' and ((path / 'Staging').exists() or not (path / 'Info.plist').is_file()):
                    summary['unavailable'].append(dict(path=str(path.relative_to(root)), reason='xcresultNotFinalized'))
                    continue
                files = [path] if path.is_file() else sorted(path.rglob('*'))
                manifest = []
                for item in files:
                    before = item.lstat()
                    if stat.S_ISLNK(before.st_mode):
                        raise ValueError('artifact contains symlink')
                    if stat.S_ISDIR(before.st_mode):
                        continue
                    if not stat.S_ISREG(before.st_mode):
                        raise ValueError('artifact is not a regular file')
                    with item.open('rb') as stream:
                        opened = os.fstat(stream.fileno())
                        if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns):
                            raise ValueError('artifact changed before read')
                        info = archive.gettarinfo(str(item), arcname=str(item.relative_to(root)))
                        archive.addfile(info, stream)
                    after = item.stat()
                    if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
                        raise ValueError('artifact changed during read')
                    manifest.append(str(item.relative_to(root)))
                if path.is_dir() and files != sorted(path.rglob('*')):
                    raise ValueError('artifact entries changed during archive')
                summary['included'].extend(manifest)
        os.replace(partial, target)
        summary['state'] = 'complete'
        return 0
    except (OSError, ValueError, tarfile.TarError) as error:
        summary.update(state='failed', error=str(error))
        return 1
    finally:
        atomic_json(destination / 'archive-summary.json', summary)


class UIRun:
    def __init__(self, root):
        self.root, self.output = root, root / 'tmp/input-ui-tests'
        self.output.mkdir(parents=True, exist_ok=True)
        self.started = time.monotonic()
        self.failures = []
        self.summary = dict(state='running', processGroupsSettled=True, budgetSeconds=RUNNER_BUDGET_SECONDS, commandBudgetSeconds=command_budget_seconds(),
                            stages=[], suites={name: 'notRun' for name in SUITES})
        self.save()

    def save(self):
        self.summary['elapsedSeconds'] = time.monotonic() - self.started
        self.summary['failedStages'] = self.failures[:]
        atomic_json(self.output / 'run-summary.json', self.summary)

    def command(self, name, args, timeout, **kwargs):
        remaining = RUNNER_BUDGET_SECONDS - (time.monotonic() - self.started)
        if remaining < timeout + 4:
            raise GroupCleanupError('runner budget exhausted before ' + name)
        row = dict(stage=name, timeoutSeconds=timeout, state='running', returncode=None)
        self.summary['stages'].append(row)
        self.summary['processGroupsSettled'] = False
        self.save()
        print(f'UIKit step: {name} (budget {timeout}s)', flush=True)
        started = time.monotonic()
        try:
            result = run_command(args, timeout=timeout, **kwargs)
            self.summary['processGroupsSettled'] = True
            row.update(state='passed' if result.returncode == 0 else 'nonzero', returncode=result.returncode)
            return result
        except Cancelled as error:
            self.summary['processGroupsSettled'] = True
            row.update(state='cancelled', signal=error.signum)
            if name in self.summary['suites']:
                self.summary['suites'][name] = 'cancelled'
            raise
        except subprocess.TimeoutExpired:
            self.summary['processGroupsSettled'] = True
            row['state'] = 'timeout'
            raise
        except subprocess.CalledProcessError as error:
            self.summary['processGroupsSettled'] = True
            row.update(state='failed', returncode=error.returncode)
            raise
        except (OSError, GroupCleanupError) as error:
            row.update(state='infrastructureFailure', error=str(error))
            raise
        finally:
            row['elapsedSeconds'] = time.monotonic() - started
            self.save()

    def fail(self, name, error):
        self.failures.append(name)
        print(f'FAIL: {name}: {error}', file=sys.stderr, flush=True)
        self.save()

    def step(self, name, command, timeout):
        try:
            self.command(name, command, timeout)
            if name in self.summary['suites']:
                self.summary['suites'][name] = 'passed'
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError) as error:
            self.fail(name, error)
            if name in self.summary['suites']:
                self.summary['suites'][name] = 'timeout' if isinstance(error, subprocess.TimeoutExpired) else 'failed'
        self.save()

    def verify_sdk_revision(self, expected):
        resolved = self.output / 'CacheKeeperInputTests.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
        package = json.loads(resolved.read_text(encoding='utf-8'))
        pins = package.get('pins') if isinstance(package, dict) else None
        if not isinstance(pins, list) or any(not isinstance(pin, dict) for pin in pins):
            raise ValueError('SDWebImage Package.resolved has invalid pins')
        matches = [pin for pin in pins if pin.get('identity') == 'sdwebimage']
        state = matches[0].get('state') if len(matches) == 1 else None
        if not isinstance(state, dict) or state.get('revision') != expected:
            raise ValueError(f'SDWebImage build did not resolve required source {expected}')
        print('Verified SDWebImage source:', expected, flush=True)

    def sdk_variant(self, version, revision, target, cases):
        stage = f'SDWebImage {version} preparation'
        try:
            spec = (self.root / 'tests/ui/project.yml').read_text(encoding='utf-8-sig')
            if spec.count(CURRENT) != 1:
                raise ValueError('ambiguous SDWebImage dependency revision')
            spec = spec.replace(CURRENT, revision)
            if target != 'ImageCacheIntegrationTests':
                if spec.count('ImageCacheIntegrationTests') != 3:
                    raise ValueError('ambiguous image integration target')
                spec = spec.replace('ImageCacheIntegrationTests', target)
            compatibility = self.output / f'image-sdk-{version}.yml'
            compatibility.write_text(spec, encoding='utf-8')
            stage = f'SDWebImage {version} generation'
            self.command(stage, ['xcodegen', 'generate', '--spec', str(compatibility), '--project', str(self.output),
                                 '--project-root', str(self.output)], BUDGETS['generate'])
            stage = f'SDWebImage {version} build'
            self.command(stage, ['xcodebuild', 'build-for-testing', *self.build_options, '-only-testing:' + target], BUDGETS['build'])
            stage = f'SDWebImage {version} revision'
            self.verify_sdk_revision(revision)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError, ValueError) as error:
            self.fail(stage, error)
            return
        for label, selection, result in cases:
            self.step(label, ['xcodebuild', 'test-without-building', *self.build_options, '-only-testing:' + selection,
                             '-resultBundlePath', str(self.output / result), '-parallel-testing-enabled', 'NO'], BUDGETS['suite'])

    def execute(self):
        shared_ready = False
        try:
            self.command('generation', ['xcodegen', 'generate', '--spec', str(self.root / 'tests/ui/project.yml'),
                                       '--project', str(self.output), '--project-root', str(self.output)], BUDGETS['generate'])
            devices = json.loads(self.command('discovery', ['xcrun', 'simctl', 'list', 'devices', 'available', '-j'],
                                             BUDGETS['discovery'], capture_output=True, text=True).stdout)
            candidates = [d for runtime, items in devices['devices'].items() if '.iOS-' in runtime
                          for d in items if d.get('isAvailable') and d['name'].startswith('iPhone')]
            if not candidates:
                raise RuntimeError('UNAVAILABLE: no installed iPhone Simulator runtime')
            device = candidates[0]['udid']
            print('UIKit destination:', candidates[0]['name'], device, flush=True)
            self.command('boot', ['xcrun', 'simctl', 'boot', device], BUDGETS['boot'], check=False)
            self.command('bootstatus', ['xcrun', 'simctl', 'bootstatus', device, '-b'], BUDGETS['bootstatus'])
            self.build_options = ['-project', str(self.output / 'CacheKeeperInputTests.xcodeproj'), '-scheme', 'InputHarness',
                                  '-destination', f'platform=iOS Simulator,id={device}', '-derivedDataPath', str(self.output / 'DerivedData'),
                                  'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_IDENTITY=-']
            self.command('search editing baseline', [sys.executable, str(self.root / 'tests/run_search_editing_red.py'), device], BUDGETS['search_red'])
            self.command('current build', ['xcodebuild', 'build-for-testing', *self.build_options], BUDGETS['build'])
            self.verify_sdk_revision(CURRENT)
            self.command('codesign', ['codesign', '--verify', '--deep', '--strict',
                                     str(self.output / 'DerivedData/Build/Products/Debug-iphonesimulator/InputHarness.app')], BUDGETS['codesign'])
            shared_ready = True
            for name, target, result in (('WebKit', 'WebKitIntegrationTests', 'WebKitResults.xcresult'),
                                         ('SDWebImage 5.21.7', 'ImageCacheIntegrationTests', 'ImageCacheResults.xcresult'),
                                         ('ScanPage', 'ScanPageTests', 'ScanPageTests.xcresult')):
                self.step(name, ['xcodebuild', 'test-without-building', *self.build_options, '-only-testing:' + target,
                                 '-resultBundlePath', str(self.output / result), '-parallel-testing-enabled', 'NO'], BUDGETS['suite'])
            self.step('Cleanup history summary baseline', [sys.executable, str(self.root / 'tests/run_cleanup_summary_red.py'), device], BUDGETS['history_red'])
            self.step('Search/XCUI', ['xcodebuild', 'test-without-building', *self.build_options,
                      '-skip-testing:WebKitIntegrationTests', '-skip-testing:ImageCacheIntegrationTests', '-skip-testing:ScanPageTests',
                      '-resultBundlePath', str(self.output / 'Results.xcresult'), '-parallel-testing-enabled', 'NO'], BUDGETS['search'])
            self.sdk_variant('5.15.5', 'fb50c1d20f24db5322b2f8f379de3618f75fe08e', 'ImageCacheIntegrationTests',
                             [('SDWebImage 5.15.5', 'ImageCacheIntegrationTests', 'ImageCache515Results.xcresult')])
            self.step('SDWebImage 5.10.4 admission baseline', [sys.executable, str(self.root / 'tests/run_image_legacy_red.py'), device], BUDGETS['legacy_red'])
            self.sdk_variant('5.10.4', 'a6b6e44eadf0d39250c10a7cc0e3b91d0bdb0e94', 'ImageCacheLegacyIntegrationTests',
                             [('SDWebImage 5.10.4', 'ImageCacheLegacyIntegrationTests/ImageCacheLegacyIntegrationTests', 'ImageCache510Results.xcresult'),
                              ('SDWebImage 5.10.4 absent API', 'ImageCacheLegacyIntegrationTests/ImageCacheLegacyAbsentAPITests', 'ImageCache510AbsentResults.xcresult')])
        except Cancelled as error:
            self.summary.update(state='cancelled', signal=error.signum)
            return 128 + error.signum
        except (subprocess.SubprocessError, OSError, ValueError, RuntimeError) as error:
            self.fail('preparation/lifecycle', error)
            self.summary['state'] = 'failed'
            shared_ready = False
        finally:
            # External cancellation must finish inside the runner's signal grace; no new Xcode work.
            try:
                if shared_ready and self.summary['state'] != 'cancelled':
                    for result, screenshots in RESULTS:
                        if (self.output / result).exists():
                            self.step(f'attachments {result}', ['xcrun', 'xcresulttool', 'export', 'attachments',
                                      '--path', str(self.output / result), '--output-path', str(self.output / screenshots)], BUDGETS['export'])
            except Cancelled as error:
                self.summary.update(state='cancelled', signal=error.signum)
            except GroupCleanupError as error:
                self.fail('attachment lifecycle', error)
            self.save()
        if self.summary['state'] == 'cancelled':
            return 128 + self.summary['signal']
        self.summary['state'] = 'failed' if self.failures else 'passed'
        self.save()
        if self.failures:
            print('FAIL: UIKit failed suites/stages: ' + ', '.join(self.failures), file=sys.stderr, flush=True)
            return 1
        return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive-only', action='store_true')
    parser.add_argument('--archive-worker', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if args.archive_worker:
        return archive_worker(ROOT)
    if args.archive_only:
        with cancellation_signals():
            try:
                run_command([sys.executable, str(pathlib.Path(__file__).resolve()), '--archive-worker'], timeout=BUDGETS['archive'])
                return 0
            except Cancelled as error:
                return 128 + error.signum
            except (subprocess.SubprocessError, OSError, RuntimeError) as error:
                print('FAIL: UIKit artifact archive:', error, file=sys.stderr)
                return 1
    if sys.platform != 'darwin':
        print('UNAVAILABLE: UIKit tests require macOS Simulator; no UI tests ran', file=sys.stderr)
        return 2
    with cancellation_signals():
        return UIRun(ROOT).execute()


if __name__ == '__main__':
    raise SystemExit(main())
