"""Check embedded redacted source integrity; SHA does not authenticate the sender."""
import argparse
import base64
import binascii
import hashlib
import json
from pathlib import Path
import re


def _need(condition, reason):
    if not condition:
        raise ValueError(reason)


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        _need(key not in result, 'duplicateJSONKey')
        result[key] = value
    return result


def _invalid_constant(_):
    raise ValueError('invalidJSONConstant')


def verify_manifest(report):
    _need(type(report) is dict, 'reportShape')
    manifest = report.get('sourceManifest')
    session = report.get('guidedCollection')
    objects = report.get('sourceObjects')
    _need(type(manifest) is dict and type(session) is dict and type(objects) is dict, 'manifestShape')
    _need(manifest.get('schemaVersion') == 1 and manifest.get('encoding') == 'base64'
          and manifest.get('integrityScope') == 'listedSourceBytesOnly'
          and manifest.get('authenticity') == 'notAuthenticated', 'manifestContract')
    identifier = manifest.get('sessionID')
    _need(type(identifier) is str and re.fullmatch('[0-9a-f]{32}', identifier)
          and identifier == session.get('sessionID'), 'sessionBinding')
    files = manifest.get('files')
    phases = session.get('phases')
    _need(type(files) is list and len(files) <= 2 and type(phases) is dict, 'sourceList')
    seen = set()
    for item in files:
        _need(type(item) is dict, 'sourceEntry')
        phase = item.get('phase'); name = item.get('name')
        _need(phase in ('capacity', 'hostPreflight') and name == phase + '.json'
              and name not in seen and type(objects.get(name)) is str, 'sourceName')
        seen.add(name)
        try:
            raw = base64.b64decode(objects[name], validate=True)
        except (ValueError, binascii.Error) as error:
            raise ValueError('sourceBase64') from error
        _need(type(item.get('length')) is int and len(raw) == item['length'], 'sourceLength')
        _need(hashlib.sha256(raw).hexdigest() == item.get('sha256'), 'sourceSHA')
        source = json.loads(raw.decode('utf-8'), object_pairs_hook=_pairs, parse_constant=_invalid_constant)
        entry = phases.get(phase)
        _need(type(source) is dict and type(entry) is dict and type(entry.get('result')) is dict, 'phaseShape')
        result = entry['result']
        _need(result.get('sourceSHA256') == item['sha256'], 'phaseSourceSHA')
        if phase == 'capacity':
            _need(source == report.get('capacityMeasurement'), 'capacityProjection')
            _need(all(source.get(key) == result.get(key) for key in
                      ('epoch', 'finishedAt', 'completedRoots', 'totalRoots', 'failedRoots'))
                  and source.get('state') == result.get('serviceState'), 'capacityPhase')
            expected = 'complete' if source['state'] == 'complete' else 'partial'
            _need(entry.get('state') == expected and result.get('state') == expected, 'capacityPhase')
        else:
            expected = dict(source, sourceSHA256=item['sha256'])
            _need(expected == result and entry.get('state') == source.get('state'), 'hostPhase')
            _need(source.get('transportTrust') == 'unauthenticated', 'hostTrust')
    _need(seen == set(objects), 'sourceSet')
    for phase in ('capacity', 'hostPreflight'):
        entry = phases.get(phase, {})
        result = entry.get('result', {}) if type(entry) is dict else {}
        if type(result) is dict and 'sourceSHA256' in result:
            _need(phase + '.json' in seen, 'sourceSet')
    return {'state': 'verified', 'sources': len(seen), 'sessionID': identifier,
            'integrityScope': 'listedSourceBytesOnly', 'authenticity': 'notAuthenticated'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report', type=Path)
    args = parser.parse_args()
    report = json.loads(args.report.read_text(encoding='utf-8'), object_pairs_hook=_pairs,
                        parse_constant=_invalid_constant)
    print(json.dumps(verify_manifest(report), ensure_ascii=False))


if __name__ == '__main__': main()
