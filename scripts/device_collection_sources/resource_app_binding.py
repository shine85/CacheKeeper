"""Same-connection registered executable headers, never application data."""
import base64
import re
import struct
import shlex

TARGETS=('com.baidu.netdisk','com.tencent.mqq','com.ss.iphone.ugc.Aweme','app.swiftgram.ios')


def selected_targets(targets):
    if not isinstance(targets,(tuple,list)) or not targets or any(type(b) is not str or b not in TARGETS for b in targets) or len(set(targets))!=len(targets):
        raise ValueError('invalidBindingTargets')
    return tuple(targets)


def script(targets=TARGETS):
    selected=selected_targets(targets)
    template=r'''set -euo pipefail
set +x
set +v
export LC_ALL=C
for target in __CK_BINDING_TARGETS__; do
  index=${target%%:*}
  bundle=${target#*:}
  registration=$(timeout 8 uicache -i "$bundle")
  app_path=$(printf '%s\n' "$registration" | awk '/^Path: / {sub(/^Path: /, ""); print}')
  [[ $app_path == /*.app && $app_path != *$'\n'* && $app_path != *'/../'* && $app_path != *'/./'* ]]
  app=$(rootfs "$app_path")
  [[ $app == /* && -d $app && ! -L $app ]]
  canonical=$(realpath "$app")
  metadata="$canonical/Info.plist"
  [[ -f $metadata && ! -L $metadata ]]
  meta_before=$(sha256sum "$metadata")
  identifier=$(timeout 5 plutil -key CFBundleIdentifier "$metadata")
  version=$(timeout 5 plutil -key CFBundleShortVersionString "$metadata")
  build=$(timeout 5 plutil -key CFBundleVersion "$metadata")
  executable=$(timeout 5 plutil -key CFBundleExecutable "$metadata")
  [[ $identifier == "$bundle" && $version =~ ^[0-9]+(\.[0-9]+){0,5}$ && $build =~ ^[0-9]+(\.[0-9]+){0,5}$ ]]
  [[ $executable =~ ^[A-Za-z0-9_.-]+$ && $executable != . && $executable != .. ]]
  binary="$canonical/$executable"
  [[ -f $binary && ! -L $binary && $(realpath "$binary") == "$binary" ]]
  before=$(stat -c '%d:%i:%s:%Y:%Z' "$binary")
  header=$(head -c 65536 "$binary" | base64 | tr -d '\r\n')
  [[ $(stat -c '%d:%i:%s:%Y:%Z' "$binary") == "$before" && $(sha256sum "$metadata") == "$meta_before" ]]
  printf 'CK1792_APP_BINDING %s %s %s %s %s\n' "$index" "$bundle" "$version" "$build" "$header"
done
echo CK1792_APP_BINDINGS_DONE
'''
    return template.replace('__CK_BINDING_TARGETS__',' '.join(shlex.quote(str(TARGETS.index(b))+':'+b) for b in selected))


def parse(line,index):
    parts=line.split(' ')
    if len(parts)!=6 or parts[:3]!=['CK1792_APP_BINDING',str(index),TARGETS[index]]:raise ValueError('appBindingFrame')
    _,_,bundle,version,build,encoded=parts
    if any(not re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,5}',v) or len(v)>40 for v in (version,build)):raise ValueError('appBindingVersion')
    raw=base64.b64decode(encoded,validate=True)
    if not 32<=len(raw)<=65536 or base64.b64encode(raw).decode()!=encoded:raise ValueError('appBindingBounds')
    magic,cpu,subtype,kind,count,size,flags,reserved=struct.unpack_from('<8I',raw)
    if magic!=0xfeedfacf or cpu!=0x100000c or kind!=2 or count>2048 or size>len(raw)-32:raise ValueError('appBindingMachO')
    cursor=32;uuid=None;has_uikit=False
    for _ in range(count):
        if cursor+8>32+size:raise ValueError('appBindingCommands')
        command,length=struct.unpack_from('<II',raw,cursor)
        if length<8 or length%8 or cursor+length>32+size:raise ValueError('appBindingCommands')
        if command==0x1b:
            if length!=24 or uuid is not None:raise ValueError('appBindingUUID')
            uuid=raw[cursor+8:cursor+24].hex()
        if command in (12,0x80000018,0x8000001f):
            if length<24:raise ValueError('appDependencyBounds')
            offset=struct.unpack_from('<I',raw,cursor+8)[0]
            if not 24<=offset<length:raise ValueError('appDependencyBounds')
            name=raw[cursor+offset:cursor+length]
            if b'\0' not in name:raise ValueError('appDependencyBounds')
            if name.split(b'\0',1)[0]==b'/System/Library/Frameworks/UIKit.framework/UIKit':has_uikit=True
        cursor+=length
    if cursor!=32+size or uuid is None:raise ValueError('appBindingUUID')
    # Reading registered metadata grants no private ABI access; the probe pins that query itself.
    return dict(bundle=bundle,version=version,build=build,uuid=uuid,hasUIKitDependency=has_uikit)


def collect(stream,targets=TARGETS):
    selected=selected_targets(targets)
    command=('timeout --kill-after=2s 120s bash -c '+shlex.quote(script(selected))+
             '; rc=$?; echo CK1792_BINDING_EXIT=$rc; exec sh -s\n')
    stream.send(command)
    rows={}
    for bundle in selected:
        rows[bundle]=parse(stream.next(125),TARGETS.index(bundle))
    stream.wait_exact('CK1792_APP_BINDINGS_DONE',5)
    stream.wait_exact('CK1792_BINDING_EXIT=0',5)
    return rows
