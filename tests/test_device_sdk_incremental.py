"""Actual Bash SDK metadata and the reused strict receipt parser; no device IO.

New test file: no previous version existed to back up. Timeout is a fixture
shim on Git Bash; production process termination is not claimed by these tests.
"""
import base64
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import device_sdk_incremental as sdk

IDENTITY = dict(bundle='com.fixture.sdk', version='1.2', build='3', uuid='11' * 16)


def macho(*, primary=False, encrypted=False, payload_size=16):
    uuid = struct.pack('<II', 27, 24) + bytes.fromhex('11' * 16 if primary else '22' * 16)
    commands = uuid
    payload = bytes((index % 251 for index in range(payload_size)))
    if not primary:
        segment = bytearray(152)
        struct.pack_into('<II16sQQQQIIII', segment, 0, 25, 152, b'__DATA', 0x1000,
                         payload_size, 4096, payload_size, 3, 3, 1, 0)
        struct.pack_into('<16s16sQQIIIIIIII', segment, 72, b'__objc_data', b'__DATA',
                         0x1000, payload_size, 4096, 3, 0, 0, 0, 0, 0, 0)
        commands += segment
        if encrypted:
            commands += struct.pack('<6I', 44, 24, 4096, payload_size, 1, 0)
    header = struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2 if primary else 6,
                         1 if primary else 3 if encrypted else 2, len(commands), 0, 0) + commands
    return header + bytes(4096 - len(header)) + (b'UNRELATED_MAIN_CODE' if primary else payload)


class SDKTests(unittest.TestCase):
    def run_fixture(self, *, encrypted=False, raw_limit=2 * 1024 * 1024,
                    payload_size=16, identity=None, missing_executable=False):
        with tempfile.TemporaryDirectory(prefix='sdk-incremental-', dir=ROOT / 'tmp') as temporary:
            work = Path(temporary)
            app = work / 'Fixture.app'
            framework = app / 'Frameworks/SDWebImage.framework'
            framework.mkdir(parents=True)
            metadata = dict(CFBundleIdentifier=IDENTITY['bundle'], CFBundleShortVersionString='1.2',
                            CFBundleVersion='3', CFBundleExecutable='Main', PrivateKey='DO_NOT_EXPORT')
            if missing_executable:
                metadata.pop('CFBundleExecutable')
            (app / 'Info.plist').write_bytes(plistlib.dumps(metadata, fmt=plistlib.FMT_XML))
            (app / 'Main').write_bytes(macho(primary=True))
            (framework / 'SDWebImage').write_bytes(macho(encrypted=encrypted, payload_size=payload_size))
            (framework / 'Info.plist').write_bytes(plistlib.dumps(
                dict(CFBundleShortVersionString='5.2', CFBundleVersion='1'), fmt=plistlib.FMT_XML))
            utilities = work / 'bin'
            utilities.mkdir()
            programs = {
                'timeout': '#!/bin/bash\n[[ $1 == --kill-after=* ]] && shift\nshift\n"$@"\n',
                'rootfs': '#!/bin/bash\nprintf "%s\\n" "$1"\n',
                'uicache': '#!/bin/bash\n[[ $1 == -i && $2 == com.fixture.sdk ]] || exit 7\nprintf "Path: %s/Fixture.app\\n" "$PWD"\n',
                # Force the existing XML scalar parser; no replacement parser.
                'plutil': '#!/bin/bash\nexit 1\n',
            }
            for name, source in programs.items():
                (utilities / name).write_text(source, encoding='utf-8')
            plan = sdk.prepare(identity or IDENTITY, sdks=['SDWebImage', 'YYCache'], raw_limit=raw_limit)
            (work / 'collect.sh').write_text(plan['script'], encoding='utf-8')
            result = subprocess.run([shutil.which('bash'), '-c',
                                     'chmod +x bin/*; PATH="$PWD/bin:$PATH" bash collect.sh'],
                                    cwd=work, capture_output=True, text=True, timeout=45)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn('DO_NOT_EXPORT', result.stdout)
            self.assertNotIn(str(app), result.stdout)
            return plan, result.stdout, sdk.parse(plan, result.stdout)

    def test_real_bash_metadata_uses_original_parser_and_retains_bytes(self):
        plan, output, result = self.run_fixture()
        self.assertEqual(result['state'], 'completeWithinRequestedSDKMetadata')
        self.assertEqual(result['identityBinding']['state'], 'matched')
        self.assertEqual([row['presence'] for row in result['sdkChecks']], ['present', 'absent'])
        self.assertFalse(result['receipt']['staticAllComplete'])
        self.assertEqual(result['receipt']['membership'], 'singleRequestedRegistration')
        self.assertIn('containerAssociation', result['uncovered'])
        self.assertNotIn('ALOG_', output)
        self.assertNotIn('CONTAINER|', output)
        primary = next(row for row in result['receipt']['images'] if row['sdk'] == 'PRIMARY')
        self.assertEqual(len(primary['ranges'][0]['data']), 56)
        self.assertNotIn(b'UNRELATED_MAIN_CODE', primary['ranges'][0]['data'])
        image = next(row for row in result['receipt']['images'] if row['sdk'] == 'SDWebImage')
        self.assertTrue(all(isinstance(row['data'], bytes) for row in image['ranges']))
        self.assertEqual(image['verification']['uuid'], '22' * 16)
        self.assertFalse(image['verification']['runtimeABIValidated'])
        self.assertLess(len(plan['script'].encode()), 72 * 1024)

    def test_crypt_ranges_are_not_exported_and_remain_explicit_gaps(self):
        _, output, result = self.run_fixture(encrypted=True)
        self.assertEqual(result['state'], 'partial')
        image = next(row for row in result['receipt']['images'] if row['sdk'] == 'SDWebImage')
        self.assertEqual([row['kind'] for row in image['ranges']], ['header'])
        self.assertTrue(any(row['reason'] == 'encrypted' for row in image['verification']['gaps']))
        self.assertIn('RANGE_SKIP|__DATA,__objc_data|4096|16|encrypted', output)

    def test_raw_budget_returns_partial_without_oversize_data(self):
        _, output, result = self.run_fixture(raw_limit=320, payload_size=1024)
        self.assertEqual(result['state'], 'partial')
        self.assertLessEqual(result['rawBytes'], 320)
        self.assertIn('|budget', output)
        self.assertTrue(result['sdkChecks'][0]['gaps'])

    def test_primary_or_version_change_stops_before_sdk_reads(self):
        for key, value in [('uuid', '33' * 16), ('version', '9.9')]:
            with self.subTest(key=key):
                _, output, result = self.run_fixture(identity=dict(IDENTITY, **{key: value}))
                self.assertEqual(result['state'], 'partial')
                self.assertEqual(result['identityBinding']['state'], 'unverifiedOrChanged')
                self.assertNotIn('IMAGE_BEGIN|a0001|SDWebImage', output)

    def test_missing_current_executable_never_uses_history(self):
        plan, output, result = self.run_fixture(missing_executable=True)
        self.assertEqual(result['state'], 'partial')
        self.assertNotIn('baselineCandidate', plan['script'])
        self.assertNotIn('IMAGE_BEGIN|a0001|PRIMARY', output)
        self.assertNotIn('IMAGE_BEGIN|a0001|SDWebImage', output)

    def test_truncated_tampered_or_out_of_scope_receipts_fail(self):
        plan, output, result = self.run_fixture()
        primary = result['receipt']['images'][0]['ranges'][0]
        bad_outputs = [output.rsplit(sdk._source().TAG + '_END', 1)[0],
                       output.replace(primary['sha256'], '0' * 64, 1),
                       output.replace('__DATA,__objc_data', '__TEXT,__cstring'),
                       output.replace('APP_END|identityStable', 'ALOG_BEGIN|a0001\nAPP_END|identityStable'),
                       'UNEXPECTED\n' + output]
        for bad in bad_outputs:
            with self.subTest(case=bad[:40]), self.assertRaises(ValueError):
                sdk.parse(plan, bad)
        with self.assertRaisesRegex(ValueError, 'sdkRawBudget'):
            sdk.parse(dict(plan, rawLimit=64), output)
        with self.assertRaisesRegex(ValueError, 'sdkOutputBudget'):
            sdk.parse(plan, 'x' * (sdk.OUTPUT_LIMIT + 1))

    def test_contradictory_presence_and_unemitted_fat_frames_are_rejected(self):
        plan, output, _ = self.run_fixture()
        for bad in (output.replace('FRAMEWORK_CHECK|SDWebImage|present', 'FRAMEWORK_CHECK|SDWebImage|absent'),
                    output.replace('RANGE_BEGIN|header|', 'RANGE_BEGIN|fat_table|', 1).replace('RANGE_END|header', 'RANGE_END|fat_table', 1)):
            with self.subTest(case=bad[:40]), self.assertRaises(ValueError):
                sdk.parse(plan, bad)

    def test_sources_and_transformation_anchors_are_pinned(self):
        with self.assertRaisesRegex(ValueError, 'sdkTemplateAnchorChanged'):
            sdk._replace('one one', 'one', 'two')
        with patch.object(sdk, 'TEMPLATE_SHA', '0' * 64):
            with self.assertRaisesRegex(ValueError, 'sdkCollectorTemplateChanged'):
                sdk.prepare(IDENTITY)
        for kwargs in (dict(raw_limit=2 * 1024 * 1024 + 1), dict(seconds=121),
                       dict(sdks=['UnknownSDK']), dict(sdks=['SDWebImage', 'SDWebImage'])):
            with self.subTest(kwargs=kwargs), self.assertRaises(ValueError):
                sdk.prepare(IDENTITY, **kwargs)


if __name__ == '__main__':
    unittest.main()
