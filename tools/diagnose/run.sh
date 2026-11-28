#!/bin/sh
# RootHide bootstrap shell paths are translated by the official jbroot tool.
set -eu
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
for tool in jbroot rootfs ln chmod mkdir stat; do
    command -v "$tool" >/dev/null 2>&1 || { printf '缺少 RootHide 已有工具：%s；未开始采集。\n' "$tool" >&2; exit 20; }
done
root=$(jbroot /)
case "$root" in /*) ;; *) printf 'RootHide 根路径无效；未开始采集。\n' >&2; exit 21;; esac
library=$(rootfs "${root%/}/usr/lib/libroothide.dylib")
[ -r "$library" ] || { printf '当前 RootHide 的 libroothide 不可读；未开始采集。\n' >&2; exit 22; }
if [ -e "$directory/.jbroot" ] || [ -L "$directory/.jbroot" ]; then
    [ -L "$directory/.jbroot" ] || { printf '已有 .jbroot 不是链接；请解压新工具目录。\n' >&2; exit 23; }
else
    # Bootstrap ln uses vroot_symlink and translates this logical / exactly once.
    # Passing the already converted jbroot path here would prepend it twice.
    ln -s / "$directory/.jbroot"
fi
expected=$(stat -L -c '%d:%i' -- "$library")
actual=$(stat -L -c '%d:%i' -- "$directory/.jbroot/usr/lib/libroothide.dylib")
[ "$actual" = "$expected" ] || { printf '工具装载库不属于当前 RootHide；未开始采集。\n' >&2; exit 23; }
[ -f "$directory/ckdiagnose" ] && [ ! -L "$directory/ckdiagnose" ] || { printf '签名工具文件缺失；未开始采集。\n' >&2; exit 24; }
chmod u+x "$directory/ckdiagnose"
mkdir -p "$directory/reports"
output=$(jbroot "$directory/reports")
exec "$directory/ckdiagnose" --background --output "$output" --duration 90
