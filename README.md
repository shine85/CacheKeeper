# CacheKeeper 缓存管家

iOS 16–17 RootHide 插件。列出已安装 APP，由用户逐个开启缓存控制；支持自动、只禁止、只清理模式。

- [下载编译后的测试包](https://github.com/shine85/CacheKeeper/releases)
- [查看自动构建与日志](https://github.com/shine85/CacheKeeper/actions/workflows/build.yml)
- [目录、保护规则与模式说明](docs/缓存控制优化.md)
- [本地编译与交接](交接说明.md)

推送到 `main` / `master` 后，GitHub Actions 自动运行原生回归、编译 RootHide deb 并检查关键文件；通过后创建带 `.deb`、SHA256 校验和、包文件清单的预发布版本。也可在 Actions 页面手动运行工作流。

包版本保留 `control` 的基础版本，追加构建序号与重试序号，避免不同构建重名。构建通过不等于已完成真机验证；下载包默认关闭 APP 功能，需在设置中自行开启。

本地 `BK/`、`tmp/`、`memory/`、构建目录及 `.deb` 不上传到源码仓库。
