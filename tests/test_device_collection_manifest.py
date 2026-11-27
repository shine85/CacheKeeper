"""Verify the exact embedded source bytes, not a reconstructed JSON encoding."""
import base64
import copy
import hashlib
import json
import unittest

from scripts.device_collection_manifest import verify_manifest


def fixture():
    session = 'a' * 32
    source = {'state': 'partial', 'epoch': 'epoch-a', 'finishedAt': 42,
              'completedRoots': 1, 'totalRoots': 2, 'failedRoots': 1,
              'roots': [{'id': 1, 'measurement': {'logicalBytes': 64}}]}
    raw = json.dumps(source, indent=1).encode()
    sha = hashlib.sha256(raw).hexdigest()
    result = {k: source[k] for k in ('epoch', 'finishedAt', 'completedRoots', 'totalRoots', 'failedRoots')}
    result.update(state='partial', serviceState='partial', sourceSHA256=sha)
    return {'guidedCollection': {'sessionID': session, 'phases': {'capacity': {'state': 'partial', 'result': result}}},
            'capacityMeasurement': source,
            'sourceManifest': {'schemaVersion': 1, 'sessionID': session, 'encoding': 'base64',
                               'integrityScope': 'listedSourceBytesOnly', 'authenticity': 'notAuthenticated',
                               'files': [{'name': 'capacity.json', 'phase': 'capacity', 'length': len(raw), 'sha256': sha}]},
            'sourceObjects': {'capacity.json': base64.b64encode(raw).decode()}}


class ManifestTests(unittest.TestCase):
    def test_exact_noncanonical_bytes_pass(self):
        self.assertEqual(verify_manifest(fixture())['sources'], 1)

    def test_byte_tampering_fails(self):
        report = fixture()
        report['sourceObjects']['capacity.json'] = base64.b64encode(b'{}').decode()
        with self.assertRaisesRegex(ValueError, 'sourceLength|sourceSHA'):
            verify_manifest(report)

    def test_different_report_tree_cannot_borrow_source_hash(self):
        report = fixture()
        report['capacityMeasurement'] = copy.deepcopy(report['capacityMeasurement'])
        report['capacityMeasurement']['roots'][0]['measurement']['logicalBytes'] = 256
        with self.assertRaisesRegex(ValueError, 'capacityProjection'):
            verify_manifest(report)

    def test_different_session_is_rejected(self):
        report = fixture(); report['sourceManifest']['sessionID'] = 'b' * 32
        with self.assertRaisesRegex(ValueError, 'sessionBinding'):
            verify_manifest(report)

    def test_manifest_cannot_omit_embedded_object(self):
        report = fixture(); report['sourceManifest']['files'] = []
        with self.assertRaisesRegex(ValueError, 'sourceSet'):
            verify_manifest(report)

    def test_phase_binding_tampering_is_rejected(self):
        report = fixture(); report['guidedCollection']['phases']['capacity']['result']['epoch'] = 'other'
        with self.assertRaisesRegex(ValueError, 'capacityPhase'):
            verify_manifest(report)

    def test_host_receipt_is_bound_to_the_same_phase(self):
        report=fixture(); source={'state':'partial','roundStartedAt':1,'transportTrust':'unauthenticated',
            'apps':[{'bundle':'test.app','receipt':{'state':'observed','transportTrust':'unauthenticated','data':{'updated':2}}}]}
        raw=json.dumps(source).encode(); sha=hashlib.sha256(raw).hexdigest()
        report['sourceObjects']['hostPreflight.json']=base64.b64encode(raw).decode()
        report['sourceManifest']['files'].append({'name':'hostPreflight.json','phase':'hostPreflight','length':len(raw),'sha256':sha})
        report['guidedCollection']['phases']['hostPreflight']={'state':'partial','result':dict(source,sourceSHA256=sha)}
        self.assertEqual(verify_manifest(report)['sources'],2)
        report['guidedCollection']['phases']['hostPreflight']['result']['roundStartedAt']=3
        with self.assertRaisesRegex(ValueError,'hostPhase'): verify_manifest(report)


if __name__ == '__main__': unittest.main()
