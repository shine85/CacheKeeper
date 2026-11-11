"""打包时从 control 同步偏好包版本；源码 plist 的占位符不是版本事实源。"""
import pathlib
import plistlib
import re
import sys

root = pathlib.Path(__file__).resolve().parents[1]
version = re.search(r'^Version: (\S+)$', (root / 'control').read_text(encoding='utf-8'), re.M).group(1)
base, _, build = version.partition('-')
targets = list(pathlib.Path(sys.argv[1]).rglob('CacheKeeperPrefs.bundle/Info.plist'))
if len(targets) != 1:
    raise SystemExit(f'Expected one staged preference Info.plist, found {len(targets)}')
path = targets[0]
info = plistlib.loads(path.read_bytes())
info['CFBundleShortVersionString'] = base
info['CFBundleVersion'] = build or base
info['CacheKeeperPackageVersion'] = version
path.write_bytes(plistlib.dumps(info, sort_keys=False))
print(f'Preference bundle version: {version}')
