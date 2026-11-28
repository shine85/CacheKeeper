"""Build a deterministic standalone ZIP from one already signed Theos executable."""
from pathlib import Path
import argparse
import hashlib
import json
import plistlib
import re
import subprocess
import tempfile
import zipfile

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--binary',required=True,type=Path)
    parser.add_argument('--output',required=True,type=Path)
    parser.add_argument('--version',required=True)
    parser.add_argument('--source',required=True)
    args=parser.parse_args()
    source=Path(__file__).resolve().parent
    binary=args.binary.resolve(strict=True)
    if not binary.is_file() or args.output.exists():raise ValueError('binaryUnavailableOrOutputExists')
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.+_-]{0,63}',args.version) or not re.fullmatch(r'[0-9a-f]{40}',args.source):raise ValueError('releaseIdentity')
    archs=subprocess.check_output(['lipo','-archs',str(binary)],text=True,timeout=15).split()
    if set(archs)!={'arm64','arm64e'}:raise ValueError('requiredArchitectures')
    required='@loader_path/.jbroot/usr/lib/libroothide.dylib'
    expected=plistlib.loads((source/'entitlements.plist').read_bytes())
    temporary=source.parents[1]/'tmp';temporary.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='diagnose-package-',dir=temporary) as folder:
        for arch in archs:
            thin=Path(folder)/arch
            subprocess.run(['lipo',str(binary),'-thin',arch,'-output',str(thin)],check=True,timeout=15)
            payload=thin.read_bytes()
            if args.version.encode('ascii')+b'\0' not in payload or args.source.encode('ascii')+b'\0' not in payload:raise ValueError('binaryReleaseIdentity:'+arch)
            load=subprocess.check_output(['otool','-L',str(thin)],text=True,timeout=15)
            if required not in load:raise ValueError('roothideLoaderPath:'+arch)
            for line in load.splitlines():
                if not line.startswith('\t'):continue
                dependency=line.strip().split(' (',1)[0]
                if dependency!=required and not dependency.startswith(('/usr/lib/','/System/Library/')):raise ValueError('unexpectedRuntimeDependency:'+arch)
            entitlements=plistlib.loads(subprocess.check_output(['ldid','-e',str(thin)],timeout=15))
            if entitlements!=expected:raise ValueError('entitlementsMismatch:'+arch)
    members={'ckdiagnose':binary.read_bytes(),'run.sh':(source/'run.sh').read_bytes(),'README.md':(source/'README.md').read_bytes()}
    if b'\r' in members['run.sh'] or not members['run.sh'].startswith(b'#!/bin/sh\n'):raise ValueError('launcherMustUseLF')
    manifest={'schemaVersion':1,'toolVersion':args.version,'sourceRevision':args.source,'architectures':archs,'loaderDependency':required,'deviceExecutionVerified':False,
        'files':{name:{'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()} for name,data in members.items()}}
    members['manifest.json']=json.dumps(manifest,ensure_ascii=False,indent=2).encode('utf8')
    args.output.parent.mkdir(parents=True,exist_ok=True)
    with zipfile.ZipFile(args.output,'x',compression=zipfile.ZIP_DEFLATED) as archive:
        for name,data in members.items():
            entry=zipfile.ZipInfo('CacheKeeper-Diagnostics/'+name,date_time=(2026,1,1,0,0,0))
            entry.create_system=3;entry.external_attr=((0o100755 if name in ('ckdiagnose','run.sh') else 0o100644)<<16)
            entry.compress_type=zipfile.ZIP_DEFLATED;archive.writestr(entry,data)
    with zipfile.ZipFile(args.output) as archive:
        for name,data in members.items():
            if archive.read('CacheKeeper-Diagnostics/'+name)!=data:raise ValueError('archiveMismatch')
    print(json.dumps({'state':'verifiedArchive','bytes':args.output.stat().st_size,'sha256':hashlib.sha256(args.output.read_bytes()).hexdigest(),'deviceExecutionVerified':False}))
    return 0

if __name__=='__main__':raise SystemExit(main())
