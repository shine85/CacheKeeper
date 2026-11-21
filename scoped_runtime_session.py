"""Single authenticated bounded diagnostic/observation session. Secrets stay in RAM."""
import argparse
import base64
import datetime
import gzip
import hashlib
import importlib
import json
import pathlib
import os
import queue
import re
import secrets
import shlex
import socket
import subprocess
import sys
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parent
# Device tooling and private round evidence stay local; the repository schema
# takes precedence over historical copies in the support directory.
BASE = ROOT / 'tmp/feedback-1792'
LEGACY = ROOT / 'tmp/feedback-172'
PROBE_SCRIPT = ROOT / 'scripts/resource_access_probe.js'
sys.path[:0] = [str(ROOT), str(BASE), str(LEGACY)]
from runtime_auth_protocol import protected_command, prompt_authentication
import scoped_runtime_gate as gating
from scoped_runtime_transport import capture, cleanup_script
import resource_runtime_client as client
import scoped_runtime_budget as limits
import resource_identity_inventory as identity_inventory
import resource_app_binding as app_binding
import restricted_runtime_artifacts as restricted

PYTHON = sys.executable
KNOWN_HOSTS = BASE.parent / 'device_known_hosts'
TARGETS = ('com.baidu.netdisk', 'com.tencent.mqq', 'com.ss.iphone.ugc.Aweme', 'app.swiftgram.ios')
SINGLE_APPS = dict(zip(('baidu','qq','douyin','swiftgram'),TARGETS))
PROBE_SCRIPT_SHA = 'e4ce07304fd6741c161541333962ec66ed930ce7aeba65f9eb819990f3dcfb3e'
FAILURE_CODES = frozenset(('foregroundConfirmationDeadline', 'foregroundConfirmationUnavailable', 'foregroundConfirmationRejected',
    'probeSourceChanged', 'assetChanged', 'invalidStageAssetManifest',
    'stageIdentityMissing', 'stageFailedOrFraming', 'streamSize', 'lineSize', 'protocolEncoding',
    'captureFraming', 'partialCapture', 'partialProtocolLine', 'unknownProtocolOutput', 'secretEcho',
    'streamDeadline', 'streamClosed', 'unexpectedProtocolPhase', 'sendDeadline', 'sendFailed',
    'targetObservationUnconfirmed', 'targetObservationIncomplete', 'endBoundary', 'directorySnapshotFrame',
    'directoryModuleUnavailable', 'unsupportedPinnedHostKey', 'invalidPinnedHostKey', 'ambiguousPinnedHostKey',
    'captureMarkerCount', 'invalidCaptureBlock', 'captureSize', 'missingStageCreationIdentity',
    'tokenRequest', 'serverExitUnconfirmed', 'temporaryDirectoryImplementationAndTestsPending',
    'directorySnapshotBounds', 'directorySnapshotEncoding', 'directorySnapshotCount', 'directorySnapshotRole',
    'directoryOwnershipMode', 'directoryParentIdentity', 'directoryPathBinding', 'directoryAliasIdentity',
    'signingChangedDirectoryIdentity', 'directoryParentOrStageChanged', 'signingDirectoryEvidence',
    'signedPayloadOrEntitlements', 'normalExecutionHash', 'diagnosticHash', 'imageClosureChanged',
    'selectionNotGeneric', 'sessionContextChanged', 'sessionDeadline', 'dyldMainPath', 'imageAliasEvidence',
    'dyldLine', 'dyldCount', 'dyldPath', 'roundDeadline'))


class RuntimeBudget:
    def __init__(self, clock=time.monotonic):
        self.clock=clock;self.end=clock()+limits.TOTAL
    def remaining(self): return max(0,self.end-self.clock())
    # DIAG120 + pre-token validation90 + server/END75 + orderly STOP15.
    def can_start(self): return self.remaining()>=limits.WINDOW
    def deadline(self, seconds, reserve=0):
        end=min(self.clock()+seconds,self.end-reserve)
        if end<=self.clock(): raise RuntimeError('roundDeadline')
        return end
    def wait(self, end):
        remaining=min(end,self.end)-self.clock()
        if remaining<=0: raise RuntimeError('roundDeadline')
        return remaining


def directory_module():
    try: return importlib.import_module('scoped_runtime_gate_directories')
    except ImportError: raise RuntimeError('directoryModuleUnavailable') from None


def sha(data):
    return hashlib.sha256(data).hexdigest()


def load_probe():
    source = PROBE_SCRIPT.read_text(encoding='utf-8')
    if sha(source.encode('utf-8')) != PROBE_SCRIPT_SHA:
        raise ValueError('probeSourceChanged')
    return source


def assets(stage):
    normal = restricted.normal()
    diagnostic = restricted.diagnostic(stage)
    agent = (LEGACY / 'frida/frida-agent.dylib').read_bytes()
    entitlements = (LEGACY / 'runtime-tool-entitlements.plist').read_bytes()
    if sha(normal) != restricted.NORMAL_SHA or sha(agent) != gating.AGENT_SHA or sha(entitlements) != gating.ENTITLEMENTS_SHA:
        raise ValueError('assetChanged')
    records, packets = [], []
    for relative, data in (('runtime-assets/frida-server.normal', normal),
                           ('runtime-assets/frida-server.probe', diagnostic),
                           ('usr/lib/frida-1.0/frida-agent.dylib', agent),
                           ('entitlements.plist', entitlements)):
        packet = gzip.compress(data, compresslevel=6, mtime=0)
        records.append(dict(path=relative, sha=sha(data), size=len(data), packetSize=len(packet)))
        packets.append(packet)
    return records, b''.join(packets), agent


def stage_script(name, records):
    if not gating.STAGE.fullmatch(name):
        raise ValueError('invalidStage')
    expected = ('runtime-assets/frida-server.normal', 'runtime-assets/frida-server.probe',
                'usr/lib/frida-1.0/frida-agent.dylib', 'entitlements.plist')
    if (not isinstance(records, list) or tuple(row.get('path') for row in records) != expected or
            any(not re.fullmatch(r'[a-f0-9]{64}', row.get('sha', '')) or
                type(row.get('size')) is not int or not 0 < row['size'] <= 64*1024*1024 or
                type(row.get('packetSize')) is not int or not 0 < row['packetSize'] <= 80*1024*1024 for row in records)):
        raise ValueError('invalidStageAssetManifest')
    script = '''set -euo pipefail
set +x
set +v
umask 077
name=''' + shlex.quote(name) + '''
system=$(jbroot "/Library/$name"); root=$(rootfs "$system")
[[ $(id -u) == 0 && "$root" == "/Library/$name" && $(jbroot "$root") == "$system" ]]
[[ ! -e "$root" && ! -L "$root" && $(realpath /Library) == /Library && ! -L /Library ]]
mkdir -m 700 "$root"
root_stamp=$(stat -c '%d:%i' "$root")
[[ $root_stamp =~ ^[0-9]+:[0-9]+$ ]]
printf 'CK1792_STAGE_IDENTITY %s\n' "$root_stamp"
mkdir -m 700 "$root/usr" "$root/usr/sbin" "$root/usr/lib" "$root/usr/lib/frida-1.0" "$root/runtime-assets" "$root/runtime-assets/scoped-gate"
'''
    for record in records:
        path = record['path']
        script += ('head -c ' + str(record['packetSize']) + ' | gzip -dc > "$root/' + path + '"\n'
                   'actual=$(sha256sum "$root/' + path + '"); [[ ${actual%% *} == ' + record['sha'] + ' ]]\n'
                   '[[ $(stat -c %s "$root/' + path + '") == ' + str(record['size']) + ' ]]\n')
    directories = directory_module()
    script += 'bash -euo pipefail -c ' + shlex.quote(directories.prepare_script(name)) + '\n'
    script += 'bash -euo pipefail -c ' + shlex.quote(directories.snapshot_script(name, 'BEFORE')) + '\n'
    script += '''for file in frida-server.normal frida-server.probe; do
  ldid -S"$root/entitlements.plist" "$root/runtime-assets/$file"
  chmod 500 "$root/runtime-assets/$file"
done
chmod 400 "$root/usr/lib/frida-1.0/frida-agent.dylib"
cp -- "$root/runtime-assets/frida-server.normal" "$root/usr/sbin/frida-server"
chmod 500 "$root/usr/sbin/frida-server"
'''
    script += 'bash -euo pipefail -c ' + shlex.quote(directories.snapshot_script(name, 'AFTER')) + '\n'
    script += '''
echo CK1792_NORMAL_BEGIN
base64 "$root/runtime-assets/frida-server.normal"
echo
echo CK1792_NORMAL_END
echo CK1792_PROBE_BEGIN
base64 "$root/runtime-assets/frida-server.probe"
echo
echo CK1792_PROBE_END
'''
    return script


def staging_command(name, records):
    # The fixed nonsecret script otherwise exceeds Windows' SSH command-line length.
    encoded=base64.b64encode(gzip.compress(stage_script(name,records).encode('utf-8'),mtime=0)).decode('ascii')
    wrapper=('set +x; set +v; set -o pipefail; '
             'script=$(printf %s '+encoded+' | base64 -d | gzip -dc) || exit 40; '
             'timeout --kill-after=2s 240s bash -c "$script"; rc=$?; unset script; '
             'echo CK1792_STAGE_EXIT=$rc; if [ "$rc" -eq 0 ]; then exec sh -s; fi; exit "$rc"')
    return 'exec bash -c '+shlex.quote(wrapper)


class Stream:
    """Bounded complete-line framing. Unknown output is rejected before it reaches disk."""
    def __init__(self, process, output):
        self.process, self.output, self.lines = process, output, queue.Queue(maxsize=512)
        self.done, self.error = False, None
        self.secrets, self.lock = [], threading.Lock()
        self.thread = threading.Thread(target=self._reader, daemon=True)
        self.thread.start()

    def protect(self, data):
        if isinstance(data, str): data = data.encode()
        with self.lock:
            self.secrets.extend(part for part in data.splitlines() if part)

    def _reader(self):
        total, pending, capture_label = 0, b'', None
        try:
            with self.output.open('xb') as sink:
                while True:
                    reader = getattr(self.process.stdout, 'read1', self.process.stdout.read)
                    data = reader(65536)
                    if not data:
                        if pending: raise RuntimeError('partialProtocolLine')
                        break
                    total += len(data)
                    if total > 100 * 1024 * 1024: raise RuntimeError('streamSize')
                    pending += data
                    while b'\n' in pending:
                        line, pending = pending.split(b'\n', 1)
                        if len(line) > 6*1024*1024: raise RuntimeError('lineSize')
                        with self.lock:
                            if any(secret in line for secret in self.secrets): raise RuntimeError('secretEcho')
                        if b'\r' in line or b'\0' in line: raise RuntimeError('protocolEncoding')
                        text = line.decode('ascii', errors='strict')
                        is_marker = text.startswith(('CK172_', 'CK1792_', 'SG_'))
                        if capture_label:
                            if text == 'CK1792_' + capture_label + '_END': capture_label = None
                            elif not re.fullmatch(r'[A-Za-z0-9+/=]*', text): raise RuntimeError('captureFraming')
                        elif text in ('CK1792_NORMAL_BEGIN', 'CK1792_PROBE_BEGIN'):
                            capture_label = text[len('CK1792_'):-len('_BEGIN')]
                        elif not is_marker:
                            raise RuntimeError('unknownProtocolOutput')
                        sink.write(line + b'\n'); sink.flush()
                        if is_marker: self.lines.put_nowait(text)
                    if len(pending) > 6*1024*1024: raise RuntimeError('lineSize')
                if capture_label: raise RuntimeError('partialCapture')
        except BaseException as error:
            self.error = type(error).__name__ if not isinstance(error, RuntimeError) else str(error)
        finally:
            self.done = True
            try: self.lines.put_nowait(None)
            except queue.Full: pass

    def next(self, timeout):
        if self.error: raise RuntimeError(self.error)
        if timeout <= 0: raise RuntimeError('streamDeadline')
        try: value = self.lines.get(timeout=timeout)
        except queue.Empty: raise RuntimeError('streamDeadline') from None
        if self.error: raise RuntimeError(self.error)
        if value is None: raise RuntimeError('streamClosed')
        return value

    def wait_exact(self, marker, seconds):
        if self.next(seconds) != marker: raise RuntimeError('unexpectedProtocolPhase')

    def send(self, data, seconds=15, secret=False):
        if isinstance(data, str): data = data.encode()
        if secret: self.protect(data)
        finished, failures = threading.Event(), []
        def writer():
            try:
                self.process.stdin.write(data); self.process.stdin.flush()
            except (OSError, ValueError): failures.append(True)
            finally: finished.set()
        threading.Thread(target=writer, daemon=True).start()
        if not finished.wait(seconds):
            # End the owned transport before a late writer can feed another protocol phase.
            self.process.terminate()
            raise RuntimeError('sendDeadline')
        if failures: raise RuntimeError('sendFailed')


def receive_stage(stream, seconds):
    deadline = time.monotonic() + seconds
    def line(): return stream.next(deadline - time.monotonic())
    identity = line()
    match = re.fullmatch(r'CK1792_STAGE_IDENTITY ([0-9]+:[0-9]+)', identity)
    if not match: raise RuntimeError('stageIdentityMissing')
    snapshots = []
    for phase in ('BEFORE', 'AFTER'):
        frame = line()
        prefix = 'CK1792_DIRECTORIES_' + phase + ' '
        if not frame.startswith(prefix) or len(frame) > 1024 * 1024: raise RuntimeError('directorySnapshotFrame')
        encoded = frame[len(prefix):].encode('ascii')
        data = base64.b64decode(encoded, validate=True)
        if not data or base64.b64encode(data) != encoded: raise RuntimeError('directorySnapshotFrame')
        snapshots.append(data)
    for marker in ('CK1792_NORMAL_BEGIN', 'CK1792_NORMAL_END', 'CK1792_PROBE_BEGIN', 'CK1792_PROBE_END', 'CK1792_STAGE_EXIT=0'):
        if line() != marker: raise RuntimeError('stageFailedOrFraming')
    directory_module().verify_snapshots(*snapshots)
    return match[1], snapshots[0], snapshots[1]


def checked_target(rows, bundle, binding=None, *, allow_incomplete=False):
    if (not isinstance(rows, list) or len(rows) != 1 or not isinstance(rows[0], dict) or
            rows[0].get('bundle') != bundle or rows[0].get('cleanup') != 'completed' or
            rows[0].get('cleanupFailures') != []):
        raise RuntimeError('targetObservationUnconfirmed')
    identity = ({'identityBefore': client.validate_identity_diagnostics(rows[0]['identityBefore'])}
                if 'identityBefore' in rows[0] else {})
    if rows[0].get('state') == 'notRunningOrAmbiguous':
        return [dict(bundle=bundle, state='notRunningOrAmbiguous', cleanup='completed', cleanupFailures=[], **identity)]
    if rows[0].get('state') != 'received': raise RuntimeError('targetObservationUnconfirmed')
    evidence = client.validate(rows[0].get('evidence'), bundle, binding['uuid'] if binding else None)
    if evidence['cleanup'] != dict(state='detached',failures=0):raise RuntimeError('targetObservationUnconfirmed')
    if evidence['image'] is None:raise RuntimeError('targetObservationUnconfirmed')
    if not allow_incomplete and evidence['state'] not in ('observed', 'notTriggered'): raise RuntimeError('targetObservationIncomplete')
    return [dict(bundle=bundle, state='received', cleanup='completed', cleanupFailures=[], evidence=evidence, **identity)]


def target_attempt(rows,bundle,binding):
    """Persist failure stage before strict acceptance; native error strings remain excluded."""
    if not isinstance(rows,list) or len(rows)!=1 or not isinstance(rows[0],dict):return dict(state='invalidClientReport')
    row=rows[0]
    states={'failed','received','notRunningOrAmbiguous','processChanged','probeFailed','schemaRejected',
            'probeDeadline','workerDeadline','workerExited','cancelled','toolVersionMismatch','bindingMissing','installationChanged','targetMemoryScopeUnproven','foregroundNotConfirmed'}
    result=dict(bundle=bundle,state=row.get('state') if row.get('state') in states else 'invalidClientState',
                cleanup=row.get('cleanup') if row.get('cleanup') in ('completed','failed','notConfirmed','notStarted') else 'invalidCleanup')
    error=row.get('errorType')
    if isinstance(error,str) and re.fullmatch('[A-Za-z]{1,64}',error):result['errorType']=error
    if row.get('phase') in ('binding','connect','identityBefore','foregroundCheck','attach','identityAfterAttach','scriptCreate','scriptLoad','observation','identityAfterObservation','complete'):
        result['phase']=row['phase']
    elapsed=row.get('elapsedMilliseconds')
    if type(elapsed) is int and 0<=elapsed<=600000:result['elapsedMilliseconds']=elapsed
    elapsed=row.get('attachElapsedMilliseconds')
    if type(elapsed) is int and 0<=elapsed<=600000:result['attachElapsedMilliseconds']=elapsed
    if row.get('transportErrorCode') in client.TRANSPORT_CODES:result['transportErrorCode']=row['transportErrorCode']
    if row.get('identityAfterAttachFailure') in client.FAILURE_IDENTITY_STATES:
        result['identityAfterAttachFailure']=row['identityAfterAttachFailure']
    if row.get('foregroundBeforeAttach') in client.FOREGROUND_STATES:
        result['foregroundBeforeAttach']=row['foregroundBeforeAttach']
    if row.get('foregroundConditionSource') in ('userConfirmedApiUnavailable','userConfirmedSplitView') and bundle in TARGETS:
        result['foregroundConditionSource']=row['foregroundConditionSource']
    if 'identityBefore' in row:result['identityBefore']=client.validate_identity_diagnostics(row['identityBefore'])
    if row.get('state')=='received':result['evidence']=client.validate(row.get('evidence'),bundle,binding['uuid'])
    return result


def atomic_ledger(path, result):
    temporary = path.with_name(path.name + '.' + secrets.token_hex(6) + '.tmp')
    with temporary.open('x', encoding='utf-8') as handle: json.dump(result, handle, indent=2)
    # Windows readers can briefly deny replacement; retain both files on persistent failure.
    for attempt in range(5):
        try:
            os.replace(temporary, path)
            return
        except PermissionError as error:
            if os.name != 'nt' or getattr(error,'winerror',None) not in (5,32) or attempt == 4:
                raise
            time.sleep(.1)


def confirm_foreground(bundle, *, reader=None, seconds=limits.INTERACTION-5):
    names=dict(zip(TARGETS,('百度网盘','QQ','抖音','Swiftgram')))
    if bundle not in names: raise ValueError('invalidTargets')
    print('请在手机打开 '+names[bundle]+' 并保持前台亮屏；准备好后在此窗口按 Enter。',flush=True)
    answer=queue.Queue(maxsize=1)
    def read():
        try:answer.put(('ok',(reader or input)()))
        except Exception:answer.put(('failed',None))
    threading.Thread(target=read,daemon=True).start()
    try:status,value=answer.get(timeout=seconds)
    except queue.Empty:raise RuntimeError('foregroundConfirmationDeadline') from None
    if status!='ok':raise RuntimeError('foregroundConfirmationUnavailable')
    if value!='':raise RuntimeError('foregroundConfirmationRejected')
    return True


def outer_script(gate, identity):
    cleanup = cleanup_script(gate.stage, tuple(gating.WORK_FILES), identity=identity)
    temporary_cleanup = directory_module().cleanup_script(gate.stage)
    # The parent no longer interprets stdin. Dispatcher owns fixed phase/token framing.
    return '''set +e
set +x
set +v
export LC_ALL=C
root=$(rootfs "$(jbroot "/Library/''' + gate.stage + '''")")
[[ "$root" == "/Library/''' + gate.stage + '''" && -d "$root" && ! -L "$root" && $(stat -c '%d:%i' "$root") == ''' + shlex.quote(identity) + ''' ]] || exit 52
[[ -d "$root/runtime-assets" && ! -L "$root/runtime-assets" && $(realpath "$root/runtime-assets") == "$root/runtime-assets" ]] || exit 52
assets_stamp=$(stat -c '%d:%i' "$root/runtime-assets") || exit 52
timeout --kill-after=5s ''' + str(limits.TOTAL) + '''s bash -c ''' + shlex.quote(gate.remote_script()) + '''
rc=$?
echo CK1792_DISPATCH_EXIT=$rc
probe=$(timeout --kill-after=1s 2s bash -c 'exec 3<>/dev/tcp/127.0.0.1/27042' 2>&1)
code=$?
if [[ $code != 1 || "$probe" != *"Connection refused"* ]]; then echo CK1792_PORT_UNCONFIRMED; exit 51; fi
echo CK1792_FINAL_PORT_CLOSED
root=$(rootfs "$(jbroot "/Library/''' + gate.stage + '''")")
[[ "$root" == "/Library/''' + gate.stage + '''" && -d "$root" && ! -L "$root" && $(realpath "$root") == "$root" && $(stat -c '%d:%i' "$root") == ''' + shlex.quote(identity) + ''' ]] || exit 52
[[ -d "$root/runtime-assets" && ! -L "$root/runtime-assets" && $(realpath "$root/runtime-assets") == "$root/runtime-assets" && $(stat -c '%d:%i' "$root/runtime-assets") == "$assets_stamp" ]] || exit 52
pidfile="$root/runtime-assets/owned-child.pid"
if [[ -e "$pidfile" || -L "$pidfile" ]]; then
  [[ -f "$pidfile" && ! -L "$pidfile" && $(stat -c %s "$pidfile") -le 24 ]] || exit 52
  pid=$(cat "$pidfile")
  [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]] || exit 52
  [[ $(type -t kill) == builtin ]] || exit 52
  builtin kill -0 "$$" || exit 52
  pid_output=$(builtin kill -0 "$pid" 2>&1)
  pid_code=$?
  [[ $pid_code == 1 && $pid_output == *"No such process"* ]] || exit 52
fi
echo CK1792_FINAL_PROCESS_GONE
timeout --kill-after=2s 90s bash -euo pipefail -c ''' + shlex.quote(temporary_cleanup) + '''
temporary_cleanup=$?
echo CK1792_TEMPORARY_CLEANUP_EXIT=$temporary_cleanup
[[ $temporary_cleanup == 0 ]] || exit 54
timeout --kill-after=2s 90s bash -c ''' + shlex.quote(cleanup) + '''
cleanup=$?
echo CK1792_CLEANUP_EXIT=$cleanup
[[ $cleanup == 0 ]] || exit 53
exit "$rc"
'''


def host_key_binding():
    # Pin one explicit Ed25519 key and force that host-key algorithm in OpenSSH.
    entries = []
    for line in KNOWN_HOSTS.read_text(encoding='utf-8').splitlines():
        parts = line.split()
        if len(parts) >= 3 and '[127.0.0.1]:22222' in parts[0].split(','):
            if parts[1] != 'ssh-ed25519': raise ValueError('unsupportedPinnedHostKey')
            blob = base64.b64decode(parts[2], validate=True)
            if (len(blob) != 51 or blob[:4] != b'\x00\x00\x00\x0b' or blob[4:15] != b'ssh-ed25519' or
                    blob[15:19] != b'\x00\x00\x00\x20' or base64.b64encode(blob).decode() != parts[2]):
                raise ValueError('invalidPinnedHostKey')
            entries.append(blob)
    if len(entries) != 1: raise ValueError('ambiguousPinnedHostKey')
    return sha(entries[0])


def finalize_result(result, process, stream, dispatcher_started):
    result['sshExit'] = process.returncode if process else None
    result['portClosed'] = result['ownedProcessGone'] = result['cleanupConfirmed'] = False
    cleanup_tail = [b'CK1792_TEMP_DIRECTORIES_REMOVED', b'CK1792_TEMPORARY_CLEANUP_EXIT=0',
                    b'CK1792_DIRECTORY_REMOVED', b'CK1792_CLEANUP_EXIT=0']
    dispatch_ok = False
    if stream and stream.done and not stream.error and stream.output.exists():
        lines = stream.output.read_bytes().splitlines()
        cleanup_unique = all(lines.count(marker)==1 for marker in cleanup_tail)
        if dispatcher_started:
            dispatch = [i for i,line in enumerate(lines) if line.startswith(b'CK1792_DISPATCH_EXIT=')]
            if len(dispatch)==1:
                index=dispatch[0]
                code=re.fullmatch(rb'CK1792_DISPATCH_EXIT=([0-9]+)',lines[index])
                expected=[b'CK1792_FINAL_PORT_CLOSED',b'CK1792_FINAL_PROCESS_GONE']+cleanup_tail
                tail_ok=bool(code) and lines[index+1:]==expected
                # Cleanup is independent evidence: a diagnostic failure/STOP19 cannot erase it.
                result['cleanupConfirmed']=tail_ok and cleanup_unique
                result['portClosed']=tail_ok
                result['ownedProcessGone']=tail_ok
                stopped=('SG_STOPPED '+result.get('sessionID','')).encode()
                dispatch_ok=(tail_ok and code[1]==b'0' and process.returncode==0 and lines.count(stopped)==1 and
                             index>0 and lines[index-1]==stopped)
        else:
            result['cleanupConfirmed']=cleanup_unique and lines[-4:]==cleanup_tail
    if stream and stream.error: result['streamFailure']=stream.error
    result['remoteStageMayRemain']=(bool(result.get('privilegedReady')) and not result['cleanupConfirmed']) or bool(result.get('recovery',{}).get('remoteStageMayRemain'))
    if result['state']=='windowsComplete':
        skipped=sum(row.get('state')=='notAttemptedBudget' for row in result['targets'])
        if result.get('mode') == 'identityInventory':
            valid=(dispatch_ok and result['cleanupConfirmed'] and len(result['windows'])==1 and
                   result.get('identityInventory',{}).get('state')=='inspected' and len(result['targets'])==len(TARGETS))
            result['state']='identityInspected' if valid else 'failed'
        elif result.get('mode') == 'foregroundBaiduComparison':
            valid=(dispatch_ok and result['cleanupConfirmed'] and len(result['windows'])==1 and
                   len(result['targets'])==1 and result['targets'][0].get('bundle')==TARGETS[0] and
                   result['targets'][0].get('state')=='received')
            result['state']='observedSubset' if valid else 'failed'
        elif result.get('mode') in ('foregroundRemainingApps','foregroundDouyinOnly','foregroundSingleApp'):
            if result['mode']=='foregroundSingleApp':
                selected=result.get('selectedBundle');expected=[selected] if selected in TARGETS else []
            else:expected=[TARGETS[2]] if result['mode']=='foregroundDouyinOnly' else list(TARGETS[1:])
            valid=(dispatch_ok and result['cleanupConfirmed'] and
                   bool(expected) and
                   [r.get('bundle') for r in result['targets']]==expected and
                   [r.get('bundle') for r in result['windows']]==expected and
                   all(r.get('state') in ('received','notRunningOrAmbiguous') for r in result['targets']))
            complete=all(r.get('state')=='received' and r.get('evidence',{}).get('state') in ('observed','notTriggered')
                         for r in result['targets'])
            result['state']=('observedSubset' if complete else 'partialSubset') if valid else 'failed'
        elif (dispatch_ok and result['cleanupConfirmed'] and len(result['targets'])==len(TARGETS) and
                len(result['windows'])+skipped==len(TARGETS)):
            result['state']='partial' if any(row['state']!='received' for row in result['targets']) else 'observed'
        else: result.update(state='failed',failureType='FinalizationUnconfirmed',failureCode='finalizationUnconfirmed')


def active_targets(*,identity_only,foreground_baidu,foreground_remaining,douyin_only=False,single_app=None):
    if single_app is not None:
        if type(single_app) is not str or single_app not in SINGLE_APPS:raise ValueError('invalidSingleApp')
        if identity_only or foreground_baidu or not foreground_remaining or douyin_only:raise ValueError('incompatibleModes')
        return (SINGLE_APPS[single_app],)
    if douyin_only and (not foreground_remaining or identity_only or foreground_baidu):raise ValueError('incompatibleModes')
    return TARGETS[2:3] if douyin_only else TARGETS[1:] if foreground_remaining else TARGETS[:1] if identity_only or foreground_baidu else TARGETS


def main(*, test_fixture_only=False, host='192.168.99.152', identity_only=False, foreground_baidu=False, user_foreground_confirmed=False, foreground_remaining=False, split_view_confirmed=False,douyin_only=False,recover_round=None,single_app=None):
    if host not in ('192.168.250.6', '192.168.99.152'):
        raise ValueError('unapprovedHost')
    if identity_only and foreground_baidu: raise ValueError('incompatibleModes')
    if user_foreground_confirmed and not foreground_baidu: raise ValueError('incompatibleModes')
    if foreground_remaining and (identity_only or foreground_baidu or user_foreground_confirmed):raise ValueError('incompatibleModes')
    if split_view_confirmed and not foreground_remaining:raise ValueError('incompatibleModes')
    selected_targets=active_targets(identity_only=identity_only,foreground_baidu=foreground_baidu,foreground_remaining=foreground_remaining,douyin_only=douyin_only,single_app=single_app)
    if not test_fixture_only and (identity_only or len(selected_targets)!=1):raise ValueError('singleAppRequired')
    recovery_prefix=''
    if recover_round is not None:
        from recover_scoped_stage import recovery_command
        recovery_prefix=recovery_command(recover_round)
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    name = 'CacheKeeperScopedRuntime-' + stamp
    local = BASE / ('scoped-device-' + stamp); local.mkdir()
    status_path = BASE / 'scoped-session-state.json'
    result = dict(state='preflight', local=str(local), stage=name, testFixtureOnly=bool(test_fixture_only),
                  executionContext='localProtocolTest' if test_fixture_only else 'deviceSession',
                  targets=[], windows=[], normalServerStarted=False, cleanupConfirmed=False,
                  resourceContract='notGranted', physicalRelease='notMeasured', ownerCoverage='notProven', privilegedReady=False,
                  sshHost=host)
    if identity_only:result['mode']='identityInventory'
    if foreground_baidu:result['mode']='foregroundBaiduComparison'
    if user_foreground_confirmed:result['foregroundUserConfirmed']=True
    if foreground_remaining:result['mode']='foregroundRemainingApps'
    if douyin_only:result['mode']='foregroundDouyinOnly'
    if single_app is not None:result.update(mode='foregroundSingleApp',selectedBundle=selected_targets[0])
    if split_view_confirmed:result['visibilityCondition']='userConfirmedSplitView'
    if recover_round is not None:result['recovery']={'round':recover_round,'state':'notStarted','cleanupConfirmed':False,'remoteStageMayRemain':True}
    def save():
        atomic_ledger(local / 'result.json', result)
        atomic_ledger(status_path, result)
    save()
    process = stream = gate = watchdog = None
    stage_ready = dispatcher_started = False
    token = auth = packet = None
    stage_identity = None
    try:
        if not identity_only and client.ATTACH_BLOCKER:
            result.update(state='blocked',failureType='RuntimeBlocked',failureCode=client.ATTACH_BLOCKER)
            return 2
        blocker = getattr(gating, 'RUNTIME_BLOCKER', None)
        if blocker:
            result.update(state='blocked', failureType='RuntimeBlocked', failureCode=str(blocker) if str(blocker) in FAILURE_CODES else 'runtimeBlocked')
            return 2
        source = load_probe()
        with socket.socket() as sock: sock.bind(('127.0.0.1', 27043))
        host_key_sha = host_key_binding()
        records, packet, agent = assets(name)
        sentinel = 'CK172_AUTH_SEPARATOR_' + secrets.token_hex(16)
        remote = recovery_prefix+staging_command(name, records)
        args = ['ssh', '-T', '-p', '22', '-L', '127.0.0.1:27043:127.0.0.1:27042',
                '-o', 'ExitOnForwardFailure=yes', '-o', 'HostKeyAlias=[127.0.0.1]:22222',
                '-o', 'HostKeyAlgorithms=ssh-ed25519', '-o', 'UpdateHostKeys=no', '-o', 'VerifyHostKeyDNS=no',
                '-o', 'KexAlgorithms=curve25519-sha256', '-o', 'StrictHostKeyChecking=yes',
                '-o', 'UserKnownHostsFile=' + str(KNOWN_HOSTS), '-o', 'ConnectTimeout=15',
                '-o', 'ServerAliveInterval=10', '-o', 'ServerAliveCountMax=3',
                'mobile@' + host, protected_command(remote, sentinel)]
        result['state'] = 'waitingForAuthentication'; save()
        auth = prompt_authentication(sentinel)
        # OpenSSH owns the native console's hidden authentication prompt. Its stderr
        # is not the remote stdout protocol and is never written to a capture file.
        process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        def expired():
            try:
                if process.poll() is None: process.terminate()
            except OSError: pass
        watchdog = threading.Timer(limits.WATCHDOG, expired);watchdog.daemon = True;watchdog.start()
        stream = Stream(process, local / 'output.private')
        stream.protect(auth.split(b'\n', 1)[0])
        stream.send(auth); auth = None
        stream.wait_exact('CK172_PRIVILEGED_READY ' + sentinel, 180)
        result['privilegedReady']=True;save()
        if recover_round is not None:
            result['recovery']['state']='running';result['state']='recoveringPreviousStage';save()
            stream.wait_exact('CK1792_RECOVERY_COMPLETE',215)
            result['recovery'].update(state='confirmed',cleanupConfirmed=True,remoteStageMayRemain=False);save()
        result.update(state='uploading', privilegedReady=True); save()
        stream.send(packet, 150); packet = None
        stage_identity, directories_before, directories_after = receive_stage(stream, 250)
        stage_ready = True
        raw = stream.output.read_bytes()
        normal = capture(raw, 'NORMAL', 24 * 1024 * 1024)
        diagnostic = capture(raw, 'PROBE', 24 * 1024 * 1024)
        bindings=None
        if not identity_only:
            result['state']='bindingInstalledApps';save()
            bindings=app_binding.collect(stream,selected_targets)
            result['appBindings']=bindings;save()
        budget = RuntimeBudget()
        gate = gating.GateSession(connection=process, host_key_sha256=host_key_sha,
                                  stage=name, normal=normal, diagnostic=diagnostic, agent=agent,
                                  directories_before=directories_before, directories_after=directories_after,
                                  artifact_profile=restricted.PROFILE)
        (local / 'normal-signed').write_bytes(normal)
        (local / 'probe-signed').write_bytes(diagnostic)
        result.update(state='verifiedStartingDispatcher', sessionID=gate.session_id, normalSHA=gate.normal_sha, probeSHA=gate.probe_sha)
        save()
        command = 'exec bash -c ' + shlex.quote(outer_script(gate, stage_identity)) + '\n'
        # Once any byte of the dispatcher command is sent, never send a fallback shell command.
        dispatcher_started = True
        stream.send(command)
        stream.wait_exact('SG_DISPATCHER_READY ' + gate.session_id, budget.wait(budget.deadline(limits.READY,reserve=limits.WINDOW)))
        for index,bundle in enumerate(selected_targets):
            if not budget.can_start():
                result['budgetLimited']=True
                result['targets'].extend(dict(bundle=b,state='notAttemptedBudget',cleanup='notStarted') for b in selected_targets[index:])
                save();break
            confirmed_this_target=user_foreground_confirmed
            if foreground_remaining and not split_view_confirmed:
                result.update(state='waitingForForegroundConfirmation',currentBundle=bundle);save()
                confirmed_this_target=confirm_foreground(bundle)
                result.setdefault('foregroundConfirmations',[]).append(dict(bundle=bundle,source='consoleEnter'));save()
            challenge = gate.begin(process)
            result.update(state='diagnosing', currentBundle=bundle); save()
            diagnostic_started = time.monotonic()
            stream.send(gate.diagnostic_command(challenge, process))
            transcript, deadline = [], budget.deadline(limits.DIAGNOSTIC,reserve=limits.PRELAUNCH+limits.SERVER_END+limits.STOP)
            for _ in gating.FRAME_ORDER:
                transcript.append(stream.next(budget.wait(deadline)))
                result['diagnosticProgress'] = dict(receivedFrames=len(transcript),
                    elapsedMilliseconds=round((time.monotonic()-diagnostic_started)*1000), verified=False)
                save()
            text = '\n'.join(transcript) + '\n'
            permit = gate.verify_diagnostic(challenge, text, process)
            result['diagnosticProgress']['verified'] = True
            save()
            (local / ('window-' + str(challenge.index) + '-diagnostic.private')).write_text(text, encoding='utf-8')
            stream.send(gate.consume(permit, process))
            request = stream.next(budget.wait(budget.deadline(limits.PRELAUNCH,reserve=limits.SERVER_END+limits.STOP)))
            token = secrets.token_hex(24)
            token_bytes = gate.token_packet(permit, request, token, process)
            stream.send(token_bytes, secret=True);token_bytes = None
            pid = gate.accept_launch(stream.next(15), process)
            launched_at=time.monotonic()
            result.update(state='observing', currentBundle=bundle, normalServerStarted=True,
                          runtimeProfile=gate.artifact_profile);save()
            print('Inspecting four registered app/process associations.' if identity_only else
                  'Observing ' + bundle + ' for 20 seconds; open it normally if needed.', flush=True)
            time.sleep(1)
            if identity_only:
                inventory=identity_inventory.collect(token)
                result['identityInventory']=inventory;save()
                rows=inventory.get('targets',[])
            else:
                rows = client.collect([bundle], token, source, seconds=20, bindings=bindings,
                                      runtime_profile=gate.artifact_profile, require_foreground=foreground_baidu or foreground_remaining,
                                      user_foreground_confirmed=confirmed_this_target,user_visible_confirmed=split_view_confirmed)
                result.setdefault('targetAttempts',[]).append(target_attempt(rows,bundle,bindings[bundle]));save()
            token = None
            # Gate owns exact SERVER_EXIT -> PID_GONE <pid> -> PORT_CLOSED acceptance.
            ending, deadline = [], budget.deadline(70,reserve=limits.STOP)
            supervision=gating.parse_supervision(stream.next(budget.wait(deadline)),gate.session_id,challenge.nonce)
            for _ in range(3): ending.append(stream.next(budget.wait(deadline)))
            end_fields=dict(bundle=bundle,elapsedMilliseconds=round((time.monotonic()-launched_at)*1000),supervision=supervision)
            exit_match=re.fullmatch(r'SG_SERVER_EXIT '+gate.session_id+' '+challenge.nonce+r' ([0-9]{1,3})',ending[0])
            if exit_match:end_fields['serverExit']=int(exit_match[1])
            end_fields['ownedPIDGone']=ending[1]==f'SG_PID_GONE {gate.session_id} {challenge.nonce} {pid}'
            end_fields['portClosed']=ending[2]==f'SG_PORT_CLOSED {gate.session_id} {challenge.nonce}'
            result.setdefault('serverAttempts',[]).append(end_fields);save()
            if supervision['supervisorOutputUnknown']:raise RuntimeError('supervisorOutputUnknown')
            if ending[-1] != f'SG_PORT_CLOSED {gate.session_id} {challenge.nonce}': raise RuntimeError('endBoundary')
            end = gate.accept_end('\n'.join(ending) + '\n', process)
            result['windows'].append(dict(bundle=bundle, pid=pid, **end));save()
            if identity_only:
                if inventory.get('state')!='inspected' or inventory.get('cleanup')!='completed':
                    raise RuntimeError('targetObservationUnconfirmed')
                result['targets'].extend(rows)
            else:
                result['targets'].extend(checked_target(rows, bundle, bindings[bundle],allow_incomplete=foreground_remaining))
            save()
        stream.send('STOP\n')
        stream.wait_exact('SG_STOPPED ' + gate.session_id, budget.wait(budget.deadline(limits.STOP)))
        result['state'] = 'windowsComplete';save()
    except BaseException as error:
        result.update(state='failed', failureType=type(error).__name__)
        result['failureCode'] = str(error) if str(error) in FAILURE_CODES else 'unclassifiedFailure'
        print('Session stopped: ' + type(error).__name__, flush=True)
        try:
            if stage_ready and not dispatcher_started and stream is not None and process.poll() is None:
                cleanup = cleanup_script(name, tuple(gating.WORK_FILES), identity=stage_identity)
                temporary_cleanup = directory_module().cleanup_script(name)
                command = ('timeout --kill-after=2s 90s bash -euo pipefail -c ' + shlex.quote(temporary_cleanup) +
                           '; rc=$?; echo CK1792_TEMPORARY_CLEANUP_EXIT=$rc; [ "$rc" -eq 0 ] || exit "$rc"; ' +
                           'timeout --kill-after=2s 90s bash -c ' + shlex.quote(cleanup) + '; rc=$?; echo CK1792_CLEANUP_EXIT=$rc; exit "$rc"')
                stream.send('exec bash -c ' + shlex.quote(command) + '\n')
            elif dispatcher_started and stream is not None and process.poll() is None:
                stream.send('STOP\n')
        except (OSError, ValueError, RuntimeError): result['stopRequestFailed'] = True
    finally:
        auth = token = packet = None
        def save_finalization():
            try:
                save()
            except OSError as error:
                # Persistence failure is reported, but must not skip transport cleanup.
                result['ledgerWriteFailure'] = type(error).__name__
                print('Ledger write failed; owned transport finalization continues.',flush=True)
        try:
            if process is not None:
                try: process.stdin.close()
                except (OSError, ValueError): pass
                try:
                    finalization_seconds = limits.FINALIZATION if dispatcher_started or stage_ready else 40
                    deadline = time.monotonic() + finalization_seconds
                    while process.poll() is None:
                        remaining = deadline - time.monotonic()
                        if remaining <= 0: raise subprocess.TimeoutExpired('ownedSSH', finalization_seconds)
                        try: process.wait(timeout=min(10, remaining))
                        except subprocess.TimeoutExpired:
                            result['finalization'] = 'waitingForOwnedTransport'
                            save_finalization()
                            print('Waiting for owned transport to exit; bounded finalization continues.', flush=True)
                except subprocess.TimeoutExpired:
                    process.terminate()
                    try: process.wait(timeout=5)
                    except subprocess.TimeoutExpired: process.kill();process.wait(timeout=5)
                if stream is not None: stream.thread.join(timeout=5)
        except BaseException as error:
            result.update(state='failed', finalizationFailure=type(error).__name__)
        finally:
            if watchdog is not None: watchdog.cancel()
            finalize_result(result, process, stream, dispatcher_started)
            if result.get('ledgerWriteFailure'):
                result.update(state='failed',failureType='LedgerWriteFailure',failureCode='ledgerWriteFailure')
            save_finalization()
            if result.get('ledgerWriteFailure'):
                result.update(state='failed',failureType='LedgerWriteFailure',failureCode='ledgerWriteFailure')
                # The round report may be writable even when the shared status is not.
                try:atomic_ledger(local / 'result.json',result)
                except OSError:print('Final failed round report could not be saved.',flush=True)
            print(json.dumps({key: result.get(key) for key in ('state', 'testFixtureOnly', 'cleanupConfirmed', 'portClosed', 'ownedProcessGone', 'failureType','ledgerWriteFailure')}), flush=True)
    return 0 if result['state'] in ('observed','identityInspected','observedSubset') else 2 if result['state'] in ('partial','partialSubset') else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', choices=('192.168.250.6', '192.168.99.152'), default='192.168.99.152')
    parser.add_argument('--identity-only',action='store_true')
    parser.add_argument('--foreground-baidu',action='store_true')
    parser.add_argument('--user-foreground-confirmed',action='store_true')
    parser.add_argument('--foreground-remaining',action='store_true')
    parser.add_argument('--split-view-confirmed',action='store_true')
    parser.add_argument('--douyin-only',action='store_true')
    parser.add_argument('--single-app',choices=tuple(SINGLE_APPS))
    parser.add_argument('--recover-round')
    args=parser.parse_args()
    raise SystemExit(main(host=args.host,identity_only=args.identity_only,foreground_baidu=args.foreground_baidu,
                         user_foreground_confirmed=args.user_foreground_confirmed,foreground_remaining=args.foreground_remaining,
                         split_view_confirmed=args.split_view_confirmed,douyin_only=args.douyin_only,recover_round=args.recover_round,single_app=args.single_app))
