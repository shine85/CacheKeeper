"""Retained static receipt validation; provenance is in provenance.json."""
import base64
import hashlib
import re
import struct

TAG = 'CK_ALLAPP_TECH_136_V2'
SDKS = ('SDWebImage YYCache PINCache Kingfisher CocoaLumberjack YYKit Cache DKCache '
        'YYWebImage CITICLog Loggerithm MJFLog VolcBaseLog TTSDKVolcLog '
        'TTSDKLivePullVolcLog glog hitlog vllog xlog').split()
ALOG = {'com.bot.doubao', 'com.phoenix.video', 'com.soda.music',
        'com.ss.iphone.ugc.aweme.lite', 'com.zhiliaoapp.musically'}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def need(condition, message):
    if not condition:
        raise ValueError(message)


def metadata_section(segment, name):
    data = {'__objc_const', '__objc_data', '__objc_classlist', '__objc_catlist', '__objc_protolist',
            '__objc_classrefs', '__objc_selrefs', '__objc_imageinfo'}
    return (segment in {'__DATA', '__DATA_CONST', '__AUTH', '__AUTH_CONST'} and name in data or
            segment == '__TEXT' and (name in {'__objc_classname', '__objc_methname', '__objc_methtype'} or name.startswith('__swift5_')))


def macho_layout(header, file_size):
    need(32 <= len(header) <= 65536, 'invalid header size')
    magic, cpu, subtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from('<8I', header)
    need(magic == 0xFEEDFACF and cpu == 0x100000C and ncmds <= 2048 and len(header) == 32 + sizeofcmds,
         'unsupported or malformed Mach-O header')
    pos, uuid, crypt, ranges, sections, deps = 32, [], [], [], [], []
    text = lambda b: b.split(b'\0', 1)[0].decode('ascii', errors='strict')
    for _ in range(ncmds):
        need(pos + 8 <= len(header), 'truncated load command')
        cmd, size = struct.unpack_from('<II', header, pos)
        need(size >= 8 and size % 4 == 0 and pos + size <= len(header), 'malformed load command')
        if cmd == 27:
            need(size == 24, 'malformed UUID')
            uuid.append(header[pos+8:pos+24].hex())
        elif cmd == 44:
            need(size >= 24, 'malformed encryption command')
            off, length, active = struct.unpack_from('<III', header, pos+8)
            need(off + length <= file_size, 'encryption beyond file')
            if active:
                crypt.append((off, off+length))
        elif cmd == 25:
            need(size >= 72, 'short segment')
            segment = text(header[pos+8:pos+24])
            vm, vmsize, seg_off, seg_len = struct.unpack_from('<QQQQ', header, pos+24)
            count = struct.unpack_from('<I', header, pos+64)[0]
            need(72 + 80*count <= size and seg_off+seg_len <= file_size, 'invalid segment bounds')
            for i in range(count):
                at = pos+72+80*i
                name = text(header[at:at+16]); declared = text(header[at+16:at+32])
                address, length, offset = struct.unpack_from('<QQI', header, at+32)
                flags = struct.unpack_from('<I', header, at+64)[0]
                need(declared == segment, 'section segment mismatch')
                sections.append({'kind': segment+','+name, 'vm': address, 'offset': offset, 'length': length})
                if metadata_section(segment, name):
                    need(flags & 255 not in {1, 12, 18}, 'metadata is zero-fill')
                    need(seg_off <= offset <= offset+length <= seg_off+seg_len, 'metadata outside segment')
                    ranges.append((segment+','+name, offset, length))
        elif cmd in {0x80000034, 0x80000033}:
            need(size >= 16, 'short linkedit')
            off, length = struct.unpack_from('<II', header, pos+8)
            ranges.append(('chained_fixups' if cmd == 0x80000034 else 'exports_trie', off, length))
        elif cmd in {0x22, 0x80000022}:
            need(size >= 48, 'short dyld info')
            for i in range(5):
                off, length = struct.unpack_from('<II', header, pos+8+i*8)
                ranges.append((f'dyld_{i}', off, length))
        elif cmd == 2:
            need(size == 24, 'short symtab')
            off, count, stroff, strlen = struct.unpack_from('<IIII', header, pos+8)
            ranges += [('nlist64', off, count*16), ('strings', stroff, strlen)]
        elif cmd in {12, 24, 0x80000018, 0x8000001f, 0x80000023}:
            need(size >= 24, 'short dylib')
            start = struct.unpack_from('<I', header, pos+8)[0]
            need(24 <= start < size, 'invalid dylib name offset')
            # Install names may contain UTF-8 bundle/framework components.
            name = header[pos+start:pos+size].split(b'\0', 1)[0].decode('utf-8', errors='strict')
            need(not any(ord(c)<32 or ord(c)==127 for c in name), 'non-scalar dylib install name')
            deps.append(name)
        pos += size
    need(pos == len(header) and len(uuid) == 1, 'load command extent or UUID count')
    need(all(0 <= off <= off+length <= file_size for _, off, length in ranges), 'range outside image')
    return {'uuid': uuid[0], 'ranges': ranges, 'encrypted': crypt, 'sections': sections, 'dependencies': deps}


def check_image(row):
    ranges = row['ranges']
    need(not any(r['kind'] == 'fat_table' for r in ranges), 'fat table outside incremental SDK scope')
    headers = [r for r in ranges if r['kind'] == 'header']
    need(len(headers) <= 1, 'duplicate header')
    if not headers:
        need(row['state'] not in {'identityStable', 'headerOnlyStable'}, 'claimed stable without header')
        return {'status': 'unavailable', 'gaps': [row['state']]}
    before = row.get('before', [])
    need(len(before) == 6 and before[3].isdigit(), 'missing image identity')
    need(headers[0]['offset'] == 0, 'header not at zero')
    layout = macho_layout(headers[0]['data'], int(before[3]))
    if row.get('uuid') is None and row['state'] == 'layoutRejected':
        need(len(ranges) == 1, 'rejected layout exported non-header bytes')
        return {'status': 'partial', 'gaps': ['deviceLayoutRejected'], 'uuid': layout['uuid'], 'runtimeABIValidated': False}
    need(row.get('uuid') == layout['uuid'], 'UUID does not match retained header')
    allowed = layout['ranges']
    seen = []
    for part in ranges:
        off, length = part['offset'], len(part['data'])
        if part['kind'] == 'header':
            continue
        need(any(k == part['kind'] and start <= off and off+length <= start+n for k, start, n in allowed),
             'range not permitted by retained header')
        need(not any(off < end and off+length > start for start, end in layout['encrypted']), 'encrypted range was exported')
        need(not any(k == part['kind'] and off < end and off+length > start for k, start, end in seen), 'duplicate/overlapping range')
        seen.append((part['kind'], off, off+length))
    need(sum(len(r['data']) for r in ranges) <= 16777216, 'per-image budget exceeded')
    gaps = []
    if row['sdk'] != 'PRIMARY':
        for kind, off, length in allowed:
            cursor = off
            for _, start, end in sorted((s for s in seen if s[0] == kind), key=lambda s: s[1]):
                if start > cursor:
                    break
                cursor = max(cursor, end)
            if cursor < off+length:
                gaps.append({'kind': kind, 'offset': cursor, 'length': off+length-cursor,
                             'reason': 'encrypted' if any(cursor < e and off+length > s for s, e in layout['encrypted']) else 'uncollected'})
    version_info = {'status': 'notApplicablePrimary'}
    version_complete = True
    if row['sdk'] != 'PRIMARY':
        version_rows = [r for r in row['records'] if r[0] == 'FRAMEWORK_VERSION']
        need(len(version_rows) <= 1 and all(len(r) == 5 for r in version_rows), 'duplicate/malformed FRAMEWORK_VERSION')
        version_info = {'status': 'recordMissing', 'fields': {}}
        version_complete = False
        if version_rows:
            version_info['status'] = 'available'
            version = version_rows[0]
            for name, code, encoded in [('version', version[1], version[2]), ('build', version[3], version[4])]:
                need(code.isdigit() and 0 <= int(code) <= 255, 'invalid framework plist exit code')
                raw = base64.b64decode(encoded, validate=True)
                need(len(raw) <= 4096, 'oversize framework version')
                value = raw.decode('utf-8', errors='strict')
                need(not any(ord(c) < 32 or ord(c) == 127 for c in value), 'non-scalar framework version')
                state = 'available' if code == '0' and value else ('emptyValue' if code == '0' else 'fieldOrPlistReadUnavailable')
                version_info['fields'][name] = {'status': state, 'exitCode': int(code), 'value': value or None}
                if state != 'available':
                    version_info['status'] = 'partial'
            version_complete = version_info['status'] == 'available'
    stable = row['state'] in {'identityStable', 'headerOnlyStable'} and before == row.get('after')
    return {'status': 'completeWithinDeclaredStaticScope' if stable and not gaps and not row['issues'] and version_complete else 'partial',
            'identityStable': stable, 'uuid': layout['uuid'], 'dependencies': layout['dependencies'],
            'sections': layout['sections'], 'gaps': gaps, 'issues': row['issues'],
            'frameworkVersion': version_info,
            'runtimeABIValidated': False}


def check_app(app, images):
    issues = []
    records = app['records']
    def one(kind, length):
        rows = [r for r in records if r[0] == kind]
        need(len(rows) <= 1 and all(len(r) == length for r in rows), 'duplicate/malformed ' + kind)
        if not rows:
            issues.append(kind + 'Missing')
            return None
        return rows[0]
    version = one('APP_VERSION', 5)
    if version:
        for code, encoded in ((version[1], version[2]), (version[3], version[4])):
            need(code.isdigit(), 'invalid plist exit code')
            raw = base64.b64decode(encoded, validate=True)
            need(len(raw) <= 4096, 'oversize version')
            if code != '0' or not raw:
                issues.append('versionUnavailable')
    one('INSTALLATION', 2)
    container_end = one('CONTAINERS_END', 3)
    containers = [r for r in records if r[0] == 'CONTAINER']
    if container_end:
        need(container_end[2].isdigit() and int(container_end[2]) == len(containers) <= 128, 'container count mismatch')
        if container_end[1] != 'complete':
            issues.append('containerMetadataIncomplete')
    for row in containers:
        need(row[1] in {'home', 'container', 'group', 'plugin'} and re.fullmatch('[0-9a-f]{64}', row[2]), 'invalid container identity')
        if row[3] != 'statAvailable':
            issues.append('containerStatUnavailable')
        else:
            need(len(row) == 10, 'container stat framing')
    checks = [r for r in records if r[0] == 'FRAMEWORK_CHECK']
    need(all(len(r) == 3 and r[1] in SDKS and r[2] in {'present', 'absent', 'symlink', 'inaccessible'} for r in checks), 'framework check malformed')
    need(len({r[1] for r in checks}) == len(checks), 'duplicate framework check')
    if len(checks) != len(SDKS):
        issues.append('frameworkPresenceIncomplete')
    local = [i for i in images if i['app'] == app['bundle']]
    if not any(i['sdk'] == 'PRIMARY' and i['verification']['status'] == 'completeWithinDeclaredStaticScope' for i in local):
        issues.append('primaryHeaderUnavailable')
    for row in checks:
        if row[2] == 'present' and not any(i['sdk'] == row[1] and i['verification']['status'] == 'completeWithinDeclaredStaticScope' for i in local):
            issues.append(row[1] + ':metadataIncomplete')
        elif row[2] in {'symlink', 'inaccessible'}:
            issues.append(row[1] + ':' + row[2])
    if app['bundle'] in ALOG and app.get('alog', {}).get('state') != 'complete':
        issues.append('alogMetadataIncomplete')
    if app['state'] != 'identityStable':
        issues.append('bundleIdentityUnavailableOrChanged')
    return {'status': 'completeWithinDeclaredStaticScope' if not issues else 'partial', 'issues': sorted(set(issues)),
            'runtimeObserved': False, 'safeResourceContractEstablished': False}


def parse_text(text, manifest, allow_membership_partial=False):
    lines = text.splitlines()
    starts = [i for i, l in enumerate(lines) if l == TAG+'_BEGIN']
    ends = [i for i, l in enumerate(lines) if l.startswith(TAG+'_END|')]
    need(len(starts) == len(ends) == 1 and starts[0] < ends[0], 'batch begin/end absent or duplicated')
    apps, images, app, image, block, alog = [], [], None, None, None, None
    total = 0
    membership_partial = False
    for line in lines[starts[0]+1:ends[0]]:
        parts = line.split('|'); record = parts[0]
        if block is not None and record != 'RANGE_END':
            need(re.fullmatch(r'[A-Za-z0-9+/=]+', line) is not None, 'invalid base64 framing')
            block['encoded'].append(line)
            block['encodedChars'] += len(line)
            need(block['encodedChars'] <= 1398200, 'oversize encoded range')
            continue
        if record == 'APP_BEGIN':
            need(app is None and image is None and alog is None and len(parts) == 4, 'nested/malformed APP')
            bundle = base64.b64decode(parts[2], validate=True).decode('utf-8')
            need(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', bundle), 'invalid app bundle')
            need(re.fullmatch(r'a[0-9]{4}', parts[1]) and re.fullmatch(r'[0-9a-f]{64}', parts[3]), 'invalid app alias/path hash')
            need(not any(a['bundle'] == bundle or a['alias'] == parts[1] for a in apps), 'duplicate APP')
            app = {'alias': parts[1], 'bundle': bundle, 'pathHash': parts[3], 'records': [], 'images': []}
            apps.append(app)
        elif record == 'APP_END':
            need(app is not None and image is None and alog is None and len(parts) == 2, 'APP_END framing')
            app['state'] = parts[1]; app = None
        elif record == 'IMAGE_BEGIN':
            need(app is not None and image is None and alog is None and len(parts) == 3 and parts[1] == app['alias'], 'IMAGE framing')
            need(parts[2] in SDKS + ['PRIMARY'] and parts[2] not in app['images'], 'unknown/duplicate SDK')
            image = {'app': app['bundle'], 'alias': app['alias'], 'sdk': parts[2], 'ranges': [], 'issues': [], 'records': []}
            images.append(image); app['images'].append(parts[2])
        elif record == 'IMAGE_END':
            need(image is not None and len(parts) == 2, 'IMAGE_END framing')
            image['state'] = parts[1]; image = None
        elif record == 'RANGE_BEGIN':
            need(image is not None and len(parts) == 5, 'RANGE framing')
            off, length = int(parts[2]), int(parts[3])
            need(off >= 0 and 0 < length <= 1048576 and re.fullmatch(r'[0-9a-f]{64}', parts[4]), 'RANGE bounds/digest')
            block = {'kind': parts[1], 'offset': off, 'length': length, 'sha256': parts[4], 'encoded': [], 'encodedChars': 0}
        elif record == 'RANGE_END':
            need(block is not None and len(parts) == 2 and parts[1] == block['kind'], 'RANGE_END mismatch')
            raw = base64.b64decode(''.join(block.pop('encoded')), validate=True)
            block.pop('encodedChars')
            need(len(raw) == block['length'] and digest(raw) == block['sha256'], 'range byte length or SHA mismatch')
            block['data'] = raw; image['ranges'].append(block); total += len(raw); block = None
            need(total <= 134217728, 'batch byte budget exceeded')
        elif record in {'IDENTITY_BEFORE', 'IDENTITY_AFTER'}:
            need(image is not None and len(parts) == 7, 'image identity framing')
            key = 'before' if record.endswith('BEFORE') else 'after'
            need(key not in image, 'duplicate image identity'); image[key] = parts[1:]
        elif record == 'UUID':
            need(image is not None and len(parts) == 2 and 'uuid' not in image, 'UUID framing')
            image['uuid'] = parts[1]
        elif record == 'HEADER_SHA256':
            need(image is not None and len(parts) == 2 and 'headerSHA256' not in image and re.fullmatch('[0-9a-f]{64}',parts[1]), 'header SHA framing')
            image['headerSHA256'] = parts[1]
        elif record in {'RANGE_SKIP', 'RANGE_FAIL', 'RANGE_REMAINDER'}:
            need(image is not None and len(parts) == 5, 'range issue framing')
            image['issues'].append(parts)
        elif record == 'ALOG_BEGIN':
            need(app is not None and app['bundle'] in ALOG and image is None and alog is None and len(parts) == 2 and parts[1] == app['alias'], 'ALog framing')
            need('alog' not in app, 'duplicate ALog'); alog = {'records': []}; app['alog'] = alog
        elif record == 'ALOG_END':
            need(alog is not None and len(parts) == 4, 'ALog end framing')
            alog.update(state=parts[1], entries=int(parts[2]), samples=int(parts[3]))
            need(0 <= alog['entries'] <= 256 and 0 <= alog['samples'] <= 64, 'ALog budget exceeded')
            if alog['state'] == 'complete':
                need(['ALOG_ENUMERATION', '0'] in alog['records'], 'ALog complete without successful find')
                before = [r[1:] for r in alog['records'] if r[0] == 'ALOG_IDENTITY_BEFORE']
                after = [r[1:] for r in alog['records'] if r[0] == 'ALOG_IDENTITY_AFTER']
                need(len(before) == len(after) == 1 and before == after, 'ALog complete without stable root')
            alog = None
        elif record.startswith('ALOG_'):
            need(alog is not None and record in {'ALOG_ITEM', 'ALOG_SHAPE', 'ALOG_ENUMERATION', 'ALOG_IDENTITY_BEFORE', 'ALOG_IDENTITY_AFTER'}, 'unknown ALog record')
            alog['records'].append(parts)
        elif record == 'TOOLS':
            need(app is None and len(parts) == 3 and parts[1] == 'plutil', 'tools framing')
        elif record == 'MEMBERSHIP_TRUNCATED':
            need(allow_membership_partial, 'device reported MEMBERSHIP_TRUNCATED; explicit partial mode required')
            need(app is image is block is alog is None and len(parts)==1 and not membership_partial, 'membership truncation framing')
            membership_partial = True
        elif record == 'FATAL':
            raise ValueError('device reported ' + record)
        elif record in {'APP_VERSION', 'INSTALLATION', 'FRAMEWORK_CHECK', 'CONTAINER', 'CONTAINERS_END', 'CONTAINERS_FIELD_STATE', 'EXECUTABLE_SOURCE', 'PRIMARY_UNAVAILABLE', 'FRAMEWORK_VERSION',
                        'PLIST_TYPE', 'PLIST_IDENTITY_BEFORE', 'PLIST_IDENTITY_AFTER', 'PLIST_MAGIC8', 'TECH_FIELD', 'EXECUTABLE_TYPE', 'EXECUTABLE_LINK_TARGET'}:
            need(app is not None, 'app record outside app')
            if record == 'FRAMEWORK_VERSION':
                need(image is not None, 'framework version outside image'); image['records'].append(parts)
            else:
                need(image is None and alog is None, 'app record inside subrecord'); app['records'].append(parts)
        else:
            raise ValueError('unknown record type: ' + record)
    need(app is image is block is alog is None, 'unclosed record')
    end = lines[ends[0]].split('|')
    need(len(end) == 4 and [int(x) for x in end[1:]] == [len(apps), len(images), total], 'batch end counts mismatch')
    need(0 < len(apps) <= 512 and sum(i['sdk'] != 'PRIMARY' for i in images) <= 96, 'empty/oversize membership')
    for image in images:
        image['verification'] = check_image(image)
    for app in apps:
        app['verification'] = check_app(app, images)
    observed = {a['bundle'] for a in apps}
    old = {a['bundle']: a for a in manifest['apps']}
    coverage = []
    for bundle in sorted(set(old) | observed):
        row = next((a for a in apps if a['bundle'] == bundle), None)
        coverage.append({'bundle': bundle, 'registration': 'present' if row else 'notObserved' if membership_partial else 'absentInCurrentRegistration',
                         'baselineEvidence': 'available' if bundle in old else 'newRegistration',
                         'staticStatus': row['verification']['status'] if row else 'notObserved' if membership_partial else 'notInstalled',
                         'runtimeStatus': 'notObserved', 'deletionAuthorizedByThisBatch': False})
    return {'schemaVersion': 2, 'kind': 'cachekeeper.staticGapReceipt', 'batchTag': TAG,
            'transport': 'completeAndByteVerified', 'rawBytes': total, 'apps': apps,
            'membership': 'partialDueToDeviceBudget' if membership_partial else 'completeCurrentRegistration',
            'images': images, 'coverage': coverage,
            'staticAllComplete': not membership_partial and all(a['verification']['status'] == 'completeWithinDeclaredStaticScope' for a in apps)}
