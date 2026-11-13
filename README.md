# CacheKeeper 缓存管家

iOS 16–17 RootHide 插件。列出已安装 APP，由用户逐个开启缓存控制；支持自动、限制缓存并清理、只清理模式，三种模式共用同一清理引擎。

- [下载编译后的测试包](https://github.com/shine85/CacheKeeper/releases)
- [查看自动构建与日志](https://github.com/shine85/CacheKeeper/actions/workflows/build.yml)
- [持续空间回收目标与十项修复方案](docs/superpowers/plans/2026-11-12-cachekeeper-audit-fixes.md)
- [本地导入核对与验证限制](docs/2026-11-13-本地导入核对.md)
- [全天修复审查](docs/2026-11-12-全天修复审查.md) / [晚间整改复核](docs/2026-11-12-晚间整改复核.md)
- [目录与策略的历史演变](docs/缓存控制优化.md)
- [本地编译与交接](交接说明.md)

2026-11-13 复核：本地 49 个产品源码、测试及构建文件已与新远端 `9988040` 一致；该提交的 #82 原生测试编译失败，尚无通过的原生回归或 Theos 编译结果。文件同步不代表可以发布，详见导入核对报告。

推送到 `main` / `master` 后，GitHub Actions 自动运行原生回归、编译 RootHide deb 并检查关键文件；通过后创建带 `.deb`、SHA256 校验和、包文件清单的预发布版本。也可在 Actions 页面手动运行工作流。

包版本保留 `control` 的基础版本，追加构建序号与重试序号，避免不同构建重名。构建通过不等于已完成真机验证；下载包默认关闭 APP 功能，需在设置中自行开启。

本地 `BK/`、`tmp/`、`memory/`、构建目录及 `.deb` 不上传到源码仓库。

产品源码、审查报告、修复方案、完整 `axs-ios-tweaks/` 技能源、图标及必要资料统一在本仓库维护；`.agents/skills/axs-ios-tweaks` 使用相对符号链接指向技能源。克隆后应保留该链接，无需另建技能副本。
