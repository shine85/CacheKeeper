"""Bound one registered app's SDK metadata using the existing static collector.

New local helper: no previous version existed to back up. This module only
prepares scripts and validates receipts; it never queues or connects to a device.
"""
import base64
import hashlib
import importlib.util
from pathlib import Path
import re
import shlex

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'scripts/device_collection_sources'
SOURCE_SHA = '95e5f4d6df4821a09d1089a3eb9cb90143d5832f5e98a3a0621b9a3be102e4c9'
TEMPLATE_SHA = '9f9f7c73862e07c78e4587539534d3554d15d65ed09b2b5c9b9a771660a53a1f'
RAW_LIMIT = 2 * 1024 * 1024
OUTPUT_LIMIT = 4 * 1024 * 1024
SCRIPT_LIMIT = 72 * 1024
IDENTITY_KEYS = {'bundle', 'version', 'build', 'uuid'}


def _source():
    path = SOURCES / 'sdk_receipt.py'
    raw = path.read_bytes()
    if hashlib.sha256(raw).hexdigest() != SOURCE_SHA:
        raise ValueError('sdkCollectorSourceChanged')
    spec = importlib.util.spec_from_file_location('_isolated_sdk_collector', path)
    module = importlib.util.module_from_spec(spec)
    # Compile the checked bytes instead of reopening the path after verification.
    exec(compile(raw, str(path), 'exec'), module.__dict__)
    return module


def _identity(value):
    if (type(value) is not dict or not IDENTITY_KEYS <= set(value) or
            set(value) - IDENTITY_KEYS - {'hasUIKitDependency'}):
        raise ValueError('sdkExpectedIdentity')
    if (type(value['bundle']) is not str or
            not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,254}', value['bundle']) or
            any(type(value[k]) is not str or len(value[k]) > 40 or
                not re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,5}', value[k]) for k in ('version', 'build')) or
            type(value['uuid']) is not str or not re.fullmatch(r'[0-9a-f]{32}', value['uuid'])):
        raise ValueError('sdkExpectedIdentity')
    return {key: value[key] for key in sorted(IDENTITY_KEYS)}


def _replace(text, before, after):
    if text.count(before) != 1:
        raise ValueError('sdkTemplateAnchorChanged')
    return text.replace(before, after, 1)


def prepare(identity, *, sdks=None, raw_limit=RAW_LIMIT, seconds=120):
    """Return a script/plan for tasks.task(plan['script'], plan['seconds'])."""
    identity = _identity(identity)
    base = _source()
    selected = list(base.SDKS) if sdks is None else list(sdks) if type(sdks) in (list, tuple) else []
    if (not selected or len(selected) != len(set(selected)) or
            any(type(name) is not str or name not in base.SDKS for name in selected)):
        raise ValueError('sdkNames')
    if (type(raw_limit) is not int or not 64 <= raw_limit <= RAW_LIMIT or
            type(seconds) is not int or not 30 <= seconds <= 120):
        raise ValueError('sdkBudget')
    raw = (SOURCES / 'device-batch-template.sh').read_bytes()
    if hashlib.sha256(raw).hexdigest() != TEMPLATE_SHA:
        raise ValueError('sdkCollectorTemplateChanged')
    script = raw.decode('utf-8')
    script = _replace(script, 'timeout 1800 bash -s', 'timeout --kill-after=2s ' + str(seconds - 2) + 's bash -s')
    script = _replace(script, 'set -o pipefail\n', 'set +x; set +v; umask 077\nset -o pipefail\n')
    script = _replace(script, 'CKB_TOTAL_LIMIT=134217728', 'CKB_TOTAL_LIMIT=' + str(raw_limit))
    script = _replace(script, 'CKB_IMAGE_LIMIT=16777216', 'CKB_IMAGE_LIMIT=' + str(raw_limit))
    script = _replace(script, "CKB_SDKS='@@SDK_NAMES@@'", "CKB_SDKS='" + ' '.join(selected) + "'")
    script = _replace(script, '-lt 1680', '-lt ' + str(seconds - 20))
    # Keep the reviewed byte reader/layout/image code intact. The container and
    # ALog readers are outside this interface's scope and are absent from output.
    baseline = script[script.index('ckb_baseline() {'):script.index('# Read only the named range')]
    script = _replace(script, baseline, '')
    readers = script[script.index('ckb_containers() {'):script.index('ckb_members=$(timeout 20 uicache -l')]
    script = _replace(script, readers, '')
    membership = script[script.index('ckb_members=$(timeout 20 uicache -l'):script.index("while IFS='|' read -r CKB_BUNDLE ckb_source; do")]
    registration = '''ckb_registration=$(timeout 8 uicache -i ''' + shlex.quote(identity['bundle']) + ''' 2>/dev/null)
[ $? -eq 0 ] || { printf 'FATAL|membershipUnavailable\\n'; exit 40; }
ckb_source=$(printf '%s\\n' "$ckb_registration" | awk '/^Path: / {n++;s=substr($0,7)} END{if(n==1 && s ~ /^\\/.*\\.app$/ && s !~ /[[:cntrl:]|]/)print s;else exit 41}')
[ $? -eq 0 ] && [ -n "$ckb_source" ] || { printf 'FATAL|membershipMalformed\\n'; exit 41; }
ckb_valid_members=$(printf '%s|%s\\n' ''' + shlex.quote(identity['bundle']) + ''' "$ckb_source")
'''
    script = _replace(script, membership, registration)
    script = _replace(script, '    ckb_baseline "$CKB_BUNDLE"\n', '')
    script = _replace(script, 'CFBundleShortVersionString|CFBundleVersion|CFBundleExecutable)',
                      'CFBundleIdentifier|CFBundleShortVersionString|CFBundleVersion|CFBundleExecutable)')
    script = _replace(script, '    ckb_app_before=$(ckb_identity "$ckb_app")\n', '''    ckb_app_before=$(ckb_identity "$ckb_app")
    [[ -f "$ckb_app/Info.plist" && ! -L "$ckb_app/Info.plist" ]] || { printf 'APP_END|metadataUnavailable\\n'; continue; }
    ckb_meta_before=$(timeout 3 sha256sum "$ckb_app/Info.plist") || { printf 'APP_END|metadataUnavailable\\n'; continue; }
    ckb_identifier=$(ckb_plist_key "$ckb_app/Info.plist" CFBundleIdentifier)
    [[ $? == 0 && $ckb_identifier == "$CKB_BUNDLE" ]] || { printf 'APP_END|registrationIdentityMismatch\\n'; continue; }
''')
    comparison = script[script.index('    ckb_state=versionUnavailable'):script.index('    ckb_exec=$(ckb_plist_key')]
    script = _replace(script, comparison, '''    printf 'INSTALLATION|currentRegistration\\n'
    printf 'CONTAINERS_END|notCollected|0\\n'
    [[ $ckb_vcode == 0 && $ckb_bcode == 0 && $ckb_version == ''' + shlex.quote(identity['version']) +
                      ' && $ckb_build == ' + shlex.quote(identity['build']) + ''' ]] || { printf 'APP_END|installationIdentityChanged\\n'; continue; }
    CKB_PRIMARY_UUID=''
''')
    script = _replace(script, '    elif [ -n "$CKB_OLD_EXEC" ]; then ckb_exec=$CKB_OLD_EXEC; ckb_esource=baselineCandidate\n', '')
    script = _replace(script,
                      'if [ "$ckb_before" = "$ckb_after" ]; then printf \'IMAGE_END|headerOnlyStable\\n\';',
                      'if [ "$ckb_before" = "$ckb_after" ]; then CKB_PRIMARY_UUID=$ckb_uuid; printf \'IMAGE_END|headerOnlyStable\\n\';')
    script = _replace(script, '    for ckb_sdk in $CKB_SDKS; do\n',
                      '    [[ $CKB_PRIMARY_UUID == ' + shlex.quote(identity['uuid']) +
                      ''' ]] || { printf 'APP_END|primaryIdentityChangedOrUnavailable\\n'; continue; }
    for ckb_sdk in $CKB_SDKS; do
''')
    script = _replace(script, '    if [ "$CKB_ALOG" = 1 ]; then ckb_alog; fi\n', '')
    script = _replace(script, '    if [ -n "$ckb_app_before" ] && [ "$ckb_app_before" = "$ckb_app_after" ]; then',
                      '    if [ -n "$ckb_app_before" ] && [ "$ckb_app_before" = "$ckb_app_after" ] && [ "$(timeout 3 sha256sum "$ckb_app/Info.plist")" = "$ckb_meta_before" ]; then')
    if ('@@' in script or 'baselineCandidate' in script or 'ckb_alog' in script or
            len(script.encode('ascii')) >= SCRIPT_LIMIT or len(shlex.quote(script).encode('ascii')) >= SCRIPT_LIMIT):
        raise ValueError('sdkScriptBoundary')
    return dict(schemaVersion=1, kind='cachekeeper.sdkIncrementalPlan', identity=identity,
                sdks=selected, rawLimit=raw_limit, seconds=seconds, script=script,
                sourceSHA256=SOURCE_SHA, templateSHA256=TEMPLATE_SHA)


def parse(plan, output):
    """Return summary plus the original receipt; ranges retain verified data bytes.

    Missing END, malformed framing, wrong identity or range budgets never become
    complete. Consumers must keep this technical receipt local and preserve bytes
    with their original hashes when writing objects for the existing supplements.
    """
    expected = _identity(plan['identity'])
    base = _source()
    if (plan.get('schemaVersion') != 1 or plan.get('kind') != 'cachekeeper.sdkIncrementalPlan' or
            plan.get('sourceSHA256') != SOURCE_SHA or plan.get('templateSHA256') != TEMPLATE_SHA or
            type(plan.get('rawLimit')) is not int or not 64 <= plan['rawLimit'] <= RAW_LIMIT or
            type(plan.get('sdks')) is not list or not plan['sdks'] or
            any(type(name) is not str or name not in base.SDKS for name in plan['sdks']) or
            len(set(plan['sdks'])) != len(plan['sdks'])):
        raise ValueError('sdkPlanBinding')
    if type(output) is not str or len(output.encode('utf-8')) > OUTPUT_LIMIT:
        raise ValueError('sdkOutputBudget')
    lines = output.splitlines()
    if (not lines or lines[0] != base.TAG + '_BEGIN' or
            not lines[-1].startswith(base.TAG + '_END|') or
            any(line.startswith('ALOG_') or line.startswith('CONTAINER|') or line.startswith('RANGE_BEGIN|fat_table|') for line in lines)):
        raise ValueError('sdkReceiptScope')
    # Isolated module parameters describe only the requested SDK metadata scope;
    # the original parser/check_image implementations and crypto exclusions stay.
    base.SDKS = list(plan['sdks'])
    base.ALOG = set()
    receipt = base.parse_text(output, {'apps': [{'bundle': expected['bundle']}]})
    if len(receipt['apps']) != 1 or receipt['apps'][0]['bundle'] != expected['bundle']:
        raise ValueError('sdkReceiptAppBinding')
    if receipt['rawBytes'] > plan['rawLimit']:
        raise ValueError('sdkRawBudget')
    app = receipt['apps'][0]
    versions = [row for row in app['records'] if row[0] == 'APP_VERSION']
    observed = {}
    if versions and versions[0][1] == versions[0][3] == '0':
        observed = {key: base64.b64decode(versions[0][position], validate=True).decode('utf-8')
                    for key, position in (('version', 2), ('build', 4))}
    primary = next((row for row in receipt['images'] if row['sdk'] == 'PRIMARY'), None)
    if primary:
        observed['uuid'] = primary['verification'].get('uuid')
    matched = (app['state'] == 'identityStable' and primary is not None and
               primary['verification']['status'] == 'completeWithinDeclaredStaticScope' and
               all(observed.get(key) == expected[key] for key in ('version', 'build', 'uuid')))
    if not matched and any(row['sdk'] != 'PRIMARY' for row in receipt['images']):
        # An installation changed after collection can retain partial technical
        # evidence, but cannot be presented as matching the caller's identity.
        if app['state'] == 'identityStable':
            raise ValueError('sdkExpectedIdentityMismatch')
    checks = {row[1]: row[2] for row in app['records'] if row[0] == 'FRAMEWORK_CHECK'}
    sdk_checks = []
    for name in plan['sdks']:
        presence = checks.get(name, 'notObserved')
        image = next((row for row in receipt['images'] if row['sdk'] == name), None)
        if (image is not None) != (presence == 'present'):
            raise ValueError('sdkPresenceImageMismatch')
        verification = image['verification'] if image else {}
        state = ('absent' if presence == 'absent' else verification.get('status', 'unavailable'))
        sdk_checks.append(dict(sdk=name, presence=presence, state=state,
                               gaps=verification.get('gaps', []), runtimeABIValidated=False))
    complete = matched and all(row['state'] in ('absent', 'completeWithinDeclaredStaticScope') for row in sdk_checks)
    receipt['membership'] = 'singleRequestedRegistration'
    receipt['staticAllComplete'] = False  # Containers/runtime and other SDKs remain outside this receipt.
    return dict(schemaVersion=1, kind='cachekeeper.sdkIncrementalReceipt', bundle=expected['bundle'],
                state='completeWithinRequestedSDKMetadata' if complete else 'partial',
                identityBinding=dict(state='matched' if matched else 'unverifiedOrChanged', expected=expected, observed=observed),
                rawBytes=receipt['rawBytes'], sdkChecks=sdk_checks,
                uncovered=['containerAssociation', 'ALogExcluded', 'unlistedOrStaticallyLinkedSDKs',
                           'SDKInstructionBodies', 'runtimeOwnerAndABI', 'resourceContract'], receipt=receipt)
