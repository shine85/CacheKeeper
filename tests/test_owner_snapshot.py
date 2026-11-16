"""Metadata-only owner snapshots: compare evidence without overstating release."""
import importlib.util
import errno
import pathlib
import os
import tempfile
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("owner_snapshot", ROOT / "scripts/owner_snapshot.py")


class ComparisonTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = importlib.util.module_from_spec(SPEC)
        SPEC.loader.exec_module(cls.module)

    def snapshot(self, entries=(), **changes):
        value = {"schemaVersion": 1, "rootID": "a" * 64, "comparisonID": "b" * 64,
                 "complete": True, "started": 100, "finished": 101, "failures": 0,
                 "symlinks": 0, "specialFiles": 0, "entriesVisited": len(entries),
                 "logicalUniqueBytes": sum(e["bytes"] for e in entries),
                 "allocatedStatBytes": sum(e["allocated"] for e in entries),
                 "entries": list(entries)}
        value.update(changes)
        return value

    def entry(self, token="1", inode="2", size=7):
        return {"entryID": token * 64, "objectID": inode * 64, "identity": "3" * 64,
                "bytes": size, "allocated": 4096, "links": 1}

    def test_empty_after_is_observed_removal_without_physical_claim(self):
        result = self.module.compare(self.snapshot([self.entry()]), self.snapshot(started=103, finished=104))
        self.assertEqual(result["removedEntries"], 1)
        self.assertEqual(result["removedObservedLogicalBytes"], 7)
        self.assertEqual(result["physicalRelease"], "notMeasured")
        self.assertEqual(result["attribution"], "requiresOwnerAndOperationEvidence")

    def test_same_name_new_object_is_replacement(self):
        result = self.module.compare(self.snapshot([self.entry()]), self.snapshot([self.entry(inode="4")], started=103, finished=104))
        self.assertEqual(result["replacedEntries"], 1)
        self.assertEqual(result["removedEntries"], 0)
        self.assertEqual(result["removedObservedLogicalBytes"], 7)

    def test_partial_mismatch_overlap_and_bad_numbers_fail_closed(self):
        good = self.snapshot()
        for changes in [{"complete": False}, {"rootID": "c" * 64}, {"comparisonID": "d" * 64},
                        {"started": 100.5}, {"failures": True}, {"privatePath": "/private/canary"}]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.module.compare(good, self.snapshot(**({"started": 103, "finished": 104} | changes)))

    def test_links_are_counted_once_in_observed_removal(self):
        first = self.entry()
        second = self.entry(token="5")
        first["links"] = second["links"] = 2
        before = self.snapshot([first, second], logicalUniqueBytes=7, allocatedStatBytes=4096)
        result = self.module.compare(before, self.snapshot(started=103, finished=104))
        self.assertEqual(result["removedEntries"], 2)
        self.assertEqual(result["removedObservedLogicalBytes"], 7)

    def test_rename_or_remaining_hardlink_does_not_count_disappeared_object(self):
        first, alias = self.entry(), self.entry(token="5")
        first["links"] = alias["links"] = 2
        before = self.snapshot([first, alias], logicalUniqueBytes=7, allocatedStatBytes=4096)
        after = self.snapshot([alias], started=103, finished=104)
        self.assertEqual(self.module.compare(before, after)["removedObservedLogicalBytes"], 0)
        renamed = self.snapshot([self.entry(token="6")], started=103, finished=104)
        self.assertEqual(self.module.compare(self.snapshot([self.entry()]), renamed)["removedObservedLogicalBytes"], 0)

    def test_duplicate_entries_and_inconsistent_objects_rejected(self):
        first = self.entry()
        for entries in [[first, first], [first, self.entry(token="5", size=8)]]:
            with self.subTest(entries=entries), self.assertRaises(ValueError):
                self.module.compare(self.snapshot(entries), self.snapshot(started=103, finished=104))

    def test_failed_collection_and_fake_empty_are_not_success(self):
        for changes in [{"failures": 1}, {"entriesVisited": 0, "entries": [self.entry()]},
                        {"logicalUniqueBytes": 9}, {"allocatedStatBytes": -1}]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.module.compare(self.snapshot(**changes), self.snapshot(started=103, finished=104))


@unittest.skipUnless(os.name == "posix", "UNAVAILABLE: real descriptor filesystem tests require POSIX")
class CaptureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = importlib.util.module_from_spec(SPEC)
        SPEC.loader.exec_module(cls.module)

    def setUp(self):
        (ROOT / "tmp").mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="owner-snapshot-test-", dir=ROOT / "tmp")
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name).resolve()
        info = self.root.stat()
        self.manifest = {"schemaVersion": 1, "root": str(self.root), "rootDevice": info.st_dev, "rootInode": info.st_ino,
                         "comparisonKey": "e" * 64, "ownerEvidence": "f" * 64, "authorized": True}

    def test_real_files_hardlinks_raw_names_and_zero_content_reads(self):
        (self.root / "private-file-canary").write_bytes(b"private-content-canary")
        os.link(self.root / "private-file-canary", self.root / "twin")
        raw_name_created = False
        try:
            fd = os.open(os.fsencode(self.root) + b"/opaque-\xff", os.O_CREAT | os.O_WRONLY, 0o600)
        except OSError as error:
            if error.errno not in (errno.EINVAL, errno.EILSEQ, errno.ENAMETOOLONG):
                raise
            print(f"UNSUPPORTED: filesystem rejected non-UTF8 filename fixture (errno={error.errno}); other real capture checks continue")
        else:
            os.close(fd)
            raw_name_created = True
        os.symlink(self.root / "private-file-canary", self.root / "link")
        with patch.object(self.module.os, "read", side_effect=AssertionError("content read forbidden")):
            result = self.module.capture(self.manifest)
        self.assertEqual(len(result["entries"]), 2 + int(raw_name_created))
        self.assertEqual(result["logicalUniqueBytes"], len(b"private-content-canary"))
        self.assertEqual(result["symlinks"], 1)
        self.assertNotIn("private", str(result))
        self.assertNotIn(str(self.root), str(result))
        self.assertEqual(self.module.compare(result, self.module.capture(self.manifest))["removedEntries"], 0)

    def test_no_follow_or_identity_fallback(self):
        (self.root / "actual").mkdir()
        os.symlink(self.root / "actual", self.root / "alias")
        bad = self.manifest | {"root": str(self.root / "alias")}
        with self.assertRaises(OSError):
            self.module.capture(bad)
        with self.assertRaises(ValueError):
            self.module.capture(self.manifest | {"rootInode": self.manifest["rootInode"] + 1})

    def test_budget_failure_never_returns_partial_success(self):
        (self.root / "one").write_bytes(b"1")
        with patch.object(self.module, "MAX_ENTRIES", 0), self.assertRaises(ValueError):
            self.module.capture(self.manifest)

    def test_actual_remove_rebuild_and_unrelated_root_rejected(self):
        target = self.root / "payload"
        target.write_bytes(b"12345")
        before = self.module.capture(self.manifest)
        target.unlink()
        after = self.module.capture(self.manifest)
        self.assertEqual(self.module.compare(before, after)["removedObservedLogicalBytes"], 5)
        target.write_bytes(b"rebuilt")
        rebuilt = self.module.capture(self.manifest)
        self.assertEqual(self.module.compare(after, rebuilt)["addedEntries"], 1)


if __name__ == "__main__":
    unittest.main()
