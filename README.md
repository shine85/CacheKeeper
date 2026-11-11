# CacheKeeper 仓库说明（GitHub 自动编译版）

本目录就是仓库根目录：`Makefile`、`control`、源码都在根下，
`.github/workflows/build.yml` 已按本工程调好（roothide/theos、iPhoneOS 16.5 SDK、
macos-14、Xcode 15.4、ldid/dpkg），与交接说明里的本地编译条件对齐。

## 怎么用

1. 在 GitHub 新建一个 **Private** 仓库（名字随意，如 `cachekeeper`），不要勾选自动生成 README。
2. 把本目录的**全部内容**（包括隐藏的 `.github` 文件夹，别漏）推到仓库的 `main` 分支。
3. 推送会自动触发编译；也可以在仓库的 Actions 页手动点 “Build CacheKeeper (Roothide)” → Run workflow。
4. 编译成功后，在那次运行页面底部 Artifacts 下载 `CacheKeeper-deb`，
   里面是 `dev.local.cachekeeper_0.3.9_iphoneos-arm64e.deb`。
5. 编译失败时，把失败步骤的日志发回给 Muse，按日志改工作流或代码，不要靠猜。

注意：私有仓库 Actions 免费额度按分钟计，macOS 按 10 倍计费，一次编译约几分钟，
日常迭代够用，别开无意义的重复触发。版本号在 `control` 里，升版改那里，不要让 CI 改。
