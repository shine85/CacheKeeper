"""Local report publication retained from the existing queue implementation."""
import json
import secrets
import time


def atomic(path, value):
    temp = path.with_name(path.name + '.' + secrets.token_hex(8) + '.pending')
    with temp.open('x', encoding='utf-8') as handle:
        json.dump(value, handle, indent=2)
    # Windows readers can briefly deny replacing an otherwise complete report.
    deadline = time.monotonic() + .5
    while True:
        try:
            temp.replace(path)
            return
        except PermissionError:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise
            time.sleep(min(.02, remaining))
            if time.monotonic() >= deadline:
                raise
