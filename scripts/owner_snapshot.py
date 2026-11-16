"""Developer-only metadata snapshots for a separately proven, authorized SDK owner.

No discovery, file-content reads, cleanup, config changes or device installation.
Capture requires POSIX dir_fd APIs and a private local authorization manifest.
The manifest is an operator input, not proof that a resource is safe to delete.
"""
import argparse
import hashlib
import hmac
import json
import math
import os
import pathlib
import re
import stat
import time

MAX_ENTRIES = 100000
MAX_DEPTH = 64
MAX_SECONDS = 15
HEX = re.compile(r"[0-9a-f]{64}\Z")
ENTRY_KEYS = {"entryID", "objectID", "identity", "bytes", "allocated", "links"}
SNAPSHOT_KEYS = {"schemaVersion", "rootID", "comparisonID", "complete", "started", "finished", "failures",
                 "symlinks", "specialFiles", "entriesVisited", "logicalUniqueBytes", "allocatedStatBytes", "entries"}


def _integer(value):
    return type(value) is int and 0 <= value <= 2**53 - 1


def _validate(value):
    if not isinstance(value, dict) or value.keys() != SNAPSHOT_KEYS or type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1:
        raise ValueError("invalid snapshot schema")
    if type(value["complete"]) is not bool or not value["complete"]:
        raise ValueError("incomplete snapshot")
    for key in ("rootID", "comparisonID"):
        if not isinstance(value[key], str) or not HEX.fullmatch(value[key]):
            raise ValueError("invalid comparison identity")
    for key in ("started", "finished"):
        if type(value[key]) not in (int, float) or not math.isfinite(value[key]) or value[key] < 0:
            raise ValueError("invalid sample time")
    if value["finished"] < value["started"]:
        raise ValueError("reversed sample time")
    for key in ("failures", "symlinks", "specialFiles", "entriesVisited", "logicalUniqueBytes", "allocatedStatBytes"):
        if not _integer(value[key]):
            raise ValueError("invalid counter")
    if value["failures"] or not isinstance(value["entries"], list) or len(value["entries"]) > MAX_ENTRIES or len(value["entries"]) > value["entriesVisited"]:
        raise ValueError("failed or invalid collection")
    entries, objects = {}, {}
    for entry in value["entries"]:
        if not isinstance(entry, dict) or entry.keys() != ENTRY_KEYS:
            raise ValueError("invalid entry schema")
        if any(not isinstance(entry[k], str) or not HEX.fullmatch(entry[k]) for k in ("entryID", "objectID", "identity")):
            raise ValueError("invalid entry identity")
        if any(not _integer(entry[k]) for k in ("bytes", "allocated", "links")) or not entry["links"]:
            raise ValueError("invalid entry measurement")
        if entry["entryID"] in entries:
            raise ValueError("duplicate entry")
        entries[entry["entryID"]] = entry
        signature = (entry["bytes"], entry["allocated"], entry["links"], entry["identity"])
        prior = objects.setdefault(entry["objectID"], signature)
        if prior != signature:
            raise ValueError("object changed within sample")
    if sum(v[0] for v in objects.values()) != value["logicalUniqueBytes"] or sum(v[1] for v in objects.values()) != value["allocatedStatBytes"]:
        raise ValueError("inconsistent unique totals")
    return entries


def compare(before, after):
    left, right = _validate(before), _validate(after)
    if before["rootID"] != after["rootID"] or before["comparisonID"] != after["comparisonID"] or after["started"] < before["finished"]:
        raise ValueError("unrelated or overlapping snapshots")
    removed = [entry for key, entry in left.items() if key not in right]
    remaining_objects = {entry["objectID"] for entry in right.values()}
    removed_objects = {entry["objectID"]: entry for entry in left.values() if entry["objectID"] not in remaining_objects}
    return {"schemaVersion": 1, "state": "compared", "beforeFinished": before["finished"], "afterFinished": after["finished"],
            "removedEntries": len(removed), "addedEntries": len(right.keys() - left.keys()),
            "replacedEntries": sum(left[k]["objectID"] != right[k]["objectID"] for k in left.keys() & right.keys()),
            "changedEntries": sum(left[k]["identity"] != right[k]["identity"] for k in left.keys() & right.keys()),
            "removedObservedLogicalBytes": sum(e["bytes"] for e in removed_objects.values()),
            "allocatedStatDelta": after["allocatedStatBytes"] - before["allocatedStatBytes"],
            "physicalRelease": "notMeasured", "attribution": "requiresOwnerAndOperationEvidence"}


def _identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_nlink, info.st_uid, info.st_gid,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def _token(key, domain, value):
    return hmac.new(key, domain.encode("ascii") + b"\0" + value, hashlib.sha256).hexdigest()


def capture(manifest):
    required = {"schemaVersion", "root", "rootDevice", "rootInode", "comparisonKey", "ownerEvidence", "authorized"}
    if not isinstance(manifest, dict) or manifest.keys() != required or type(manifest["schemaVersion"]) is not int or manifest["schemaVersion"] != 1 or manifest["authorized"] is not True:
        raise ValueError("invalid authorization manifest")
    if not isinstance(manifest["ownerEvidence"], str) or not HEX.fullmatch(manifest["ownerEvidence"]):
        raise ValueError("missing independently verified owner evidence")
    if not isinstance(manifest["comparisonKey"], str) or not HEX.fullmatch(manifest["comparisonKey"]):
        raise ValueError("invalid private comparison key")
    if any(not _integer(manifest[k]) for k in ("rootDevice", "rootInode")):
        raise ValueError("invalid expected root identity")
    root = manifest["root"]
    if not isinstance(root, str) or not root.startswith("/") or root == "/" or "\0" in root or any(x in ("", ".", "..") for x in root.split("/")[1:]):
        raise ValueError("invalid authorized root")
    if os.name != "posix" or not hasattr(os, "O_NOFOLLOW") or os.open not in os.supports_dir_fd or os.stat not in os.supports_dir_fd or os.scandir not in os.supports_fd:
        raise RuntimeError("UNAVAILABLE: POSIX descriptor traversal is required")
    key = bytes.fromhex(manifest["comparisonKey"])
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    started, deadline = time.time(), time.monotonic() + MAX_SECONDS
    # Resolve every component with NOFOLLOW; this never discovers an alternate owner.
    fd = os.open("/", flags)
    try:
        for component in os.fsencode(root).split(b"/")[1:]:
            nxt = os.open(component, flags, dir_fd=fd)
            os.close(fd)
            fd = nxt
        baseline = os.fstat(fd)
        if (baseline.st_dev, baseline.st_ino) != (manifest["rootDevice"], manifest["rootInode"]):
            raise ValueError("authorized root identity changed")
        result = {"schemaVersion": 1, "rootID": _token(key, "root", repr((baseline.st_dev, baseline.st_ino)).encode()),
                  "comparisonID": _token(key, "comparison", manifest["ownerEvidence"].encode()),
                  "started": started, "finished": started, "complete": True, "failures": 0, "symlinks": 0,
                  "specialFiles": 0, "entriesVisited": 0, "logicalUniqueBytes": 0, "allocatedStatBytes": 0, "entries": []}
        objects = {}

        def walk(directory, components, original):
            if len(components) > MAX_DEPTH or time.monotonic() > deadline:
                raise ValueError("snapshot budget exceeded")
            with os.scandir(directory) as entries:
                visit(entries, directory, components)
            if _identity(original) != _identity(os.fstat(directory)):
                raise ValueError("directory changed during observation")

        def visit(entries, directory, components):
            # scandir(fd) is incremental; surrogateescape preserves raw POSIX bytes.
            for item in entries:
                if result["entriesVisited"] >= MAX_ENTRIES or time.monotonic() > deadline:
                    raise ValueError("snapshot budget exceeded")
                raw = os.fsencode(item.name)
                if not raw or raw in (b".", b"..") or b"/" in raw or b"\0" in raw:
                    raise ValueError("invalid directory entry")
                result["entriesVisited"] += 1
                before = os.stat(raw, dir_fd=directory, follow_symlinks=False)
                if before.st_dev != baseline.st_dev:
                    raise ValueError("cross-device descendant")
                path = components + [raw]
                if stat.S_ISLNK(before.st_mode):
                    result["symlinks"] += 1
                elif stat.S_ISDIR(before.st_mode):
                    child = os.open(raw, flags, dir_fd=directory)
                    try:
                        if _identity(before) != _identity(os.fstat(child)):
                            raise ValueError("directory changed while opening")
                        walk(child, path, before)
                    finally:
                        os.close(child)
                elif stat.S_ISREG(before.st_mode):
                    identity = _identity(before)
                    object_id = _token(key, "object", repr((before.st_dev, before.st_ino)).encode())
                    signature = (identity, before.st_blocks)
                    if objects.setdefault(object_id, signature) != signature:
                        raise ValueError("hardlink object changed within sample")
                    entry = {"entryID": _token(key, "entry", b"/".join(path)), "objectID": object_id,
                             "identity": _token(key, "identity", repr(identity).encode()), "bytes": before.st_size,
                             "allocated": before.st_blocks * 512, "links": before.st_nlink}
                    result["entries"].append(entry)
                else:
                    result["specialFiles"] += 1
                if _identity(before) != _identity(os.stat(raw, dir_fd=directory, follow_symlinks=False)):
                    raise ValueError("entry changed during observation")

        walk(fd, [], baseline)
        # Re-resolve all ancestors to ensure the pathname still designates the held root.
        current = os.open("/", flags)
        try:
            for component in os.fsencode(root).split(b"/")[1:]:
                nxt = os.open(component, flags, dir_fd=current)
                os.close(current)
                current = nxt
            if _identity(baseline) != _identity(os.fstat(current)):
                raise ValueError("root changed during observation")
        finally:
            os.close(current)
        result["logicalUniqueBytes"] = sum(v[0][6] for v in objects.values())
        result["allocatedStatBytes"] = sum(v[1] * 512 for v in objects.values())
        result["finished"] = time.time()
        _validate(result)
        return result
    finally:
        os.close(fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    collect = sub.add_parser("capture")
    collect.add_argument("manifest", type=pathlib.Path)
    diff = sub.add_parser("compare")
    diff.add_argument("before", type=pathlib.Path)
    diff.add_argument("after", type=pathlib.Path)
    args = parser.parse_args()
    try:
        if args.command == "capture":
            value = capture(json.loads(args.manifest.read_text(encoding="utf-8")))
        else:
            value = compare(json.loads(args.before.read_text(encoding="utf-8")), json.loads(args.after.read_text(encoding="utf-8")))
        print(json.dumps(value, sort_keys=True))
        return 0
    except (ValueError, OSError, RuntimeError) as error:
        # OSError text may include private input paths; only a finite category and errno leave the tool.
        print(json.dumps({"schemaVersion": 1, "state": "unavailable" if isinstance(error, RuntimeError) else "rejected",
                          "errorClass": type(error).__name__, "errno": error.errno if isinstance(error, OSError) else 0}))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
