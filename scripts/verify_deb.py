"""检查真实 deb 的身份及关键文件，并生成可下载的校验信息。"""
import hashlib
import pathlib
import subprocess
import sys
import tarfile
import tempfile

folder = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else 'packages')
packages = sorted(folder.glob('*.deb'))
if len(packages) != 1:
    raise SystemExit(f'Expected one RootHide deb, found {len(packages)}')
package = packages[0]


def field(name):
    return subprocess.check_output(['dpkg-deb', '-f', str(package), name], text=True).strip()


if field('Package') != 'dev.local.cachekeeper' or field('Architecture') != 'iphoneos-arm64e':
    raise SystemExit('Unexpected package identity or architecture')
tmp = pathlib.Path('tmp')
tmp.mkdir(exist_ok=True)
with tempfile.TemporaryFile(dir=tmp) as archive:
    subprocess.run(['dpkg-deb', '--fsys-tarfile', str(package)], stdout=archive, check=True, timeout=60)
    archive.seek(0)
    with tarfile.open(fileobj=archive) as tar:
        names = [item.name.removeprefix('./') for item in tar]

required = [
    'Library/MobileSubstrate/DynamicLibraries/CacheKeeper.dylib',
    'Library/MobileSubstrate/DynamicLibraries/CacheKeeper.plist',
    'Library/PreferenceBundles/CacheKeeperPrefs.bundle/CacheKeeperPrefs',
    'Library/PreferenceBundles/CacheKeeperPrefs.bundle/Info.plist',
    'Library/PreferenceLoader/Preferences/CacheKeeper.plist',
    'Library/libSandy/CacheKeeperAccess.plist',
    'usr/bin/ckrestore',
]
for suffix in required:
    if not any(name == suffix or name.endswith('/' + suffix) for name in names):
        raise SystemExit(f'Missing package file: {suffix}')
for name in names:
    if any(part in {'BK', 'tmp', 'memory', '.git'} for part in pathlib.PurePosixPath(name).parts):
        raise SystemExit(f'Local-only files leaked into package: {name}')

checksum = hashlib.sha256(package.read_bytes()).hexdigest()
(folder / 'SHA256SUMS').write_text(f'{checksum}  {package.name}\n', encoding='utf-8')
control = subprocess.check_output(['dpkg-deb', '-I', str(package)], text=True)
listing = subprocess.check_output(['dpkg-deb', '-c', str(package)], text=True)
(folder / 'package-contents.txt').write_text(control + '\n' + listing, encoding='utf-8')
print(f'PASS: {package.name}; identity, architecture, {len(required)} required files, local artifact exclusion')
