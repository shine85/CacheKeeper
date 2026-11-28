# CI 构建与核验

独立目标不加入插件 deb；在现有 RootHide Theos、SDK 16.5 环境完成插件构建后，使用同一 `THEOS`：

```sh
make -C tools/diagnose clean
make -C tools/diagnose all CK_DIAGNOSE_VERSION="$PACKAGE_VERSION" CK_DIAGNOSE_SOURCE="$GITHUB_SHA"
python3 tools/diagnose/package.py --binary tools/diagnose/.theos/obj/ckdiagnose --output "packages/CacheKeeper-Diagnostics-$PACKAGE_VERSION.zip" --version "$PACKAGE_VERSION" --source "$GITHUB_SHA"
```

`PACKAGE_VERSION` 沿主 CI 现有已生成完整版本号。`FINALPACKAGE=1`、非调试构建的 Theos 合并且签名目标为 `.theos/obj/ckdiagnose`；如果当前 Theos 产物路径不同，CI 必须查明确切单个目标后传入，不能跳过验包或随意取第一个文件。

`package.py` 真实执行 `lipo -archs`，分别拆出 arm64/arm64e 后各自执行 `otool -L`、`ldid -e`，要求两架构均含唯一 RootHide 动态库依赖 `@loader_path/.jbroot/usr/lib/libroothide.dylib`、其他依赖仅系统库/框架，以及四项准确 entitlement。只看静态符号或把旧包换名不能通过。

ZIP 固定四项：`CacheKeeper-Diagnostics/ckdiagnose`、`run.sh`、`README.md`、`manifest.json`。manifest 含 SHA256/大小、架构和装载依赖；不包含设备已有报告/用户资料/旧 runtime 工具。ZIP 创建后回读逐字节核对；它不声明手机执行已验证。

原生测试：

```sh
python3 tests/run_standalone_diagnostics_tests.py
python3 tests/test_standalone_launcher.py
```

第一条需要 macOS/xcrun，真实文件/容量服务、拒链接/超大/损坏、时间预算关闭 cursor、系统注册拒绝、JSON 写失败，以及实际 exec 后台进程和 ready 握手。Windows 必须返回 UNAVAILABLE，不能当 PASS。

RootHide shell 使用 libvroot，`ln -s / .jbroot` 的 `/` 会由 `vroot_symlink` 转为当前原生越狱根；不可把已转换的 `jbroot /` 输出再传入 `ln`。启动入口随后用 `stat -L` 核库的设备号/inode与官方 `rootfs(jbroot(...))` 目标一致才运行。相同源码参考：roothide/Developer `roothide.md`、`interface.md`、`vroot.md`；roothide/libroothide `vroot.c` 的 `VROOT_API_NAME(symlink)`。这解决工具目录依赖映射，仍须单独记录手机实际运行。

`stat -c` 为当前 RootHide bootstrap 的 GNU 形式：此前成功设备批采的 `ckb_identity` 使用 `stat -c '%d|%i|%f|%s|%Y|%Z'` 并有 completed/exit 0 回执，不只检查命令是否存在。当前运行仍需 `stat -L -c` 返回成功；不支持参数时脚本失败退出，不打印 started，也不安装替代工具。
