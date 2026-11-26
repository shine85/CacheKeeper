"""Static task access to an existing authenticated queue, never a new connection.

The task/result checks are retained from qq_persistent_bridge; the existing
transport still owns queue locking, admission, authentication and deadlines.
"""
import importlib.util
from pathlib import Path
import re
import secrets
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
HEX = re.compile(r'[0-9a-f]{32}\Z')
SCRIPT_LIMIT = 72 * 1024


def load_transport(path=None):
    path = Path(path) if path is not None else ROOT / 'scripts/persistent_device_ssh.py'
    path = path.resolve(strict=True)
    if not path.is_file() or path.suffix != '.py':
        raise ValueError('collectionTransportAdapter')
    spec = importlib.util.spec_from_file_location('_collection_authorized_transport', path)
    module = importlib.util.module_from_spec(spec)
    # Resolve the explicitly selected adapter's siblings, not this checkout's
    # unrelated SSH modules. Only loading occurs here; no service is started.
    previous = sys.path[:]
    sys.path.insert(0, str(path.parent))
    try:
        spec.loader.exec_module(module)
    finally:
        sys.path[:] = previous
    if (not isinstance(getattr(module, 'BASE', None), (str, Path)) or
            not all(callable(getattr(module, name, None)) for name in
                    ('read_state', 'queue_lock', 'enqueue_locked', 'read_json'))):
        raise ValueError('collectionTransportInterface')
    return module


def checked_state(transport, expected_session, *, until=None):
    state = transport.read_state(until=until)
    if (type(expected_session) is not str or not HEX.fullmatch(expected_session) or
            state.get('session') != expected_session or state.get('protocolVersion') not in (2, 3) or
            state.get('state') not in ('ready', 'working')):
        raise ValueError('persistentConnectionBinding')
    local = Path(state.get('local', ''))
    if local.parent.resolve() != Path(transport.BASE).resolve() or local.name != expected_session:
        raise ValueError('persistentConnectionPath')
    return state


class QueueTasks:
    def __init__(self, transport, session=None):
        self.transport = transport
        self.session = transport.read_state().get('session') if session is None else session
        checked_state(transport, self.session)
        self.sequence = 0

    def task(self, script, seconds, *, until=None):
        if (type(script) is not str or not script or '\0' in script or '\r' in script or
                len(script.encode('ascii')) > SCRIPT_LIMIT):
            raise ValueError('bridgeScriptBudget')
        if until is not None and (type(until) not in (int, float) or
                                  not time.monotonic() < until <= time.monotonic() + seconds):
            raise ValueError('persistentTaskDeadline')
        persistent = self.transport
        checked_state(persistent, self.session, until=until)
        self.sequence += 1
        ident = 'qq-' + secrets.token_hex(8) + '-' + str(self.sequence)
        with persistent.queue_lock():
            checked_state(persistent, self.session, until=until)
            budget = seconds if until is None else int(until - time.monotonic())
            if budget < 1:
                raise RuntimeError('persistentTaskDeadline')
            path = persistent.enqueue_locked(script, ident, budget)
        if path.parent.parent.name != self.session:
            raise RuntimeError('persistentEnqueueBinding')
        deadline = time.monotonic() + seconds + 15 if until is None else until
        while time.monotonic() < deadline:
            if path.exists():
                value = persistent.read_json(path, until=deadline)
                if time.monotonic() >= deadline:
                    raise RuntimeError('persistentTaskDeadline')
                return self._result(value, ident)
            checked_state(persistent, self.session, until=deadline)
            time.sleep(.1)
        raise RuntimeError('persistentTaskDeadline')

    def _result(self, value, ident):
        if (value.get('id') != ident or value.get('session') != self.session or
                value.get('state') not in ('completed', 'commandFailed') or
                type(value.get('exitCode')) is not int or type(value.get('output')) is not str or
                value.get('lines') != value['output'].splitlines()):
            raise RuntimeError('persistentTaskResultBinding')
        if value['exitCode'] != 0:
            raise RuntimeError('persistentTaskFailed')
        return value['output']
