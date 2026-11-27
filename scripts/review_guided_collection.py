"""Read-only technical summary of a guided report; never writes or uploads its input."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path

from device_collection_manifest import verify_manifest

TARGETS = {'com.ss.iphone.ugc.Aweme', 'com.tencent.mqq', 'com.baidu.netdisk',
           'com.360buy.jdmobile', 'app.swiftgram.ios', 'com.xiaomi.mihome'}


def summarize(path):
    payload = path.read_bytes()
    report = json.loads(payload)
    guided = report['guidedCollection']
    capacity = report['capacityMeasurement']
    result = {
        'file': path.name, 'bytes': len(payload), 'sha256': hashlib.sha256(payload).hexdigest(),
        'manifest': verify_manifest(report), 'environment': report['environment'],
        'generatedAtUTC': datetime.fromtimestamp(report['generatedAt'], timezone.utc).isoformat(),
        'sessionID': guided['sessionID'], 'sessionState': guided['state'],
        'phases': {key: value['state'] for key, value in guided['phases'].items()},
        'events': [{key: event[key] for key in ('sequence', 'at', 'phase', 'state')} for event in guided['events']],
        'imageStagePresent': 'supportedImageCollection' in report,
        'diagnostics': guided['phases']['diagnostics']['result'],
        'capacity': {key: capacity.get(key) for key in ('state', 'epoch', 'startedAt', 'finishedAt',
                      'completedRoots', 'totalRoots', 'failedRoots', 'summaryBinding', 'freshness')},
        'capacityFailures': [], 'installationGaps': [], 'targets': [],
    }
    for root in capacity.get('roots', []):
        measured = root['measurement']
        if measured['state'] != 'complete':
            result['capacityFailures'].append({
                'id': root['id'], 'roles': root['roles'], 'owners': root['owners'],
                'state': measured['state'], 'cursorErrors': measured.get('cursorErrors')})
    for app in report['apps']:
        if app.get('installationState') != 'verified':
            result['installationGaps'].append({key: app.get(key) for key in
                ('bundle', 'installedMetadataState', 'installationState', 'version', 'build')})
        if app['bundle'] not in TARGETS:
            continue
        image = app['imageDiskCache'].get('data', {})
        runtime = image.get('runtimeInfo', {})
        processes = image.get('operationHistory', {}).get('processes', [])
        current = [p for p in processes if p.get('firstObserved') == runtime.get('firstObserved')]
        cleanup = app['cleanup'].get('data', {})
        positive_rounds = []
        for row in cleanup.get('cleanupHistory', {}).get('rounds', []):
            if row.get('removed', 0) and row.get('context', {}).get('packageVersion') == report['environment']['pluginVersion']:
                positive_rounds.append({key: row.get(key) for key in ('roundID', 'finishedAt', 'removed', 'bytes', 'failed', 'coverageComplete', 'endReason')})
        result['targets'].append({
            'bundle': app['bundle'], 'enabled': app['configuration'].get('enabled'), 'mode': app['configuration'].get('mode'),
            'image': {key: image.get(key) for key in ('state', 'reason', 'eligible', 'pending', 'updated')},
            'runtimeInfo': runtime, 'imageCollectionPresent': 'imageCollection' in image,
            'writerEpochs': [{key: epoch.get(key) for key in ('epoch', 'configuration', 'installation', 'enabled', 'mode', 'identityState')} |
                {'data': {key: epoch['data'][key] for key in ('nonemptyAttempts', 'nonemptyAllowed', 'nonemptyBlocked')}}
                for epoch in image.get('writeObservation', {}).get('epochs', [])],
            'currentSDKActions': [action for process in current for action in process.get('actions', [])],
            'gurd': {key: app['gurdCache'].get('data', {}).get(key) for key in ('state', 'reason', 'updated')},
            'latestCleanup': {key: cleanup.get(key) for key in ('phase', 'coverageComplete', 'endReason', 'failed', 'lastRemoved', 'lastBytes', 'updated')},
            'positiveCleanupRounds': positive_rounds,
        })
    result['allImageAckCount'] = sum('imageCollection' in app['imageDiskCache'].get('data', {}) for app in report['apps'])
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('reports', nargs='+', type=Path)
    args = parser.parse_args()
    print(json.dumps([summarize(path) for path in args.reports], ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
