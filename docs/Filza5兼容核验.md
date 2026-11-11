# Filza 5 目录跳转兼容核验

2026-11-11，根据用户提供的 TIGI 官方源 `https://tigisoftware.com/cydia/` 核对。

## 实际证据

- Packages 条目：`com.tigisoftware.filza64bit`，版本 `5.0.1-3`，RootHide 架构 `iphoneos-arm64e`。
- 官方包：`com.tigisoftware.filza64bit_5.0.1-3_iphoneos-arm64e.deb`，SHA256 `51ada1bb3c5c3358c69fd062e428211486344ccbbfb3c4860e9f3036c78744d9`；下载后校验一致。
- 包内 `Applications/Filza.app/Info.plist`：Bundle ID 为 `com.tigisoftware.Filza`，版本 `5.0.1`，没有 `CFBundleURLTypes`。因此旧 `filza://` URL 不能依靠已注册 scheme 分派。
- Info.plist 声明 `public.item` 等文档类型；二进制仍有文件 URL 与 `application:openURL:options:`、`scene:openURLContexts:` 处理入口。此为静态证据，不等于已观察到目录定位成功。
- 包里的 `/usr/libexec/filza/Filza` 并非简单目录启动器，其 main 接收 root/命令等参数并进入 shell 执行链，未用于本项目。

REA 识别本地 Mach-O 成功，但本机没有可用深度分析提供者。包清单和 plist 由 Python 静态解析；小型辅助二进制由临时 Capstone 查看指令，未安装或执行 Filza。

## 当前实现

运行时从 LaunchServices 查找 `com.tigisoftware.Filza` 并读取该安装实例的 Info.plist：有 `filza` scheme 时沿用原 URL；无 scheme 时用 `file://` URL，通过 `_LSOpenConfiguration.frontBoardOptions` 的 `FBSOpenApplicationOptionKeyPayloadURL` 向该 Bundle ID 投递。

接口依据：[iOS 17 LSApplicationWorkspace 声明](https://github.com/MTACS/iOS-17-Runtime-Headers/blob/d1d960dfaa4107765dd7fcf891e4967c0930d5fd/Frameworks/CoreServices.framework/LSApplicationWorkspace.h)、[LiveContainer 实际调用](https://github.com/LiveContainer/LiveContainer/blob/9d6ea09b05afa2c8fc537c372795a294db631311/ShareExtension/main.m)。使用 `openApplicationWithBundleIdentifier:usingConfiguration:completionHandler:`，回调为 BOOL 和 NSError；运行时检查接口及常量，缺失时明确失败。

不修改 Filza 的注册、安装文件或系统权限，不调用其 shell 工具。失败区分注册不可读、接口不可用、系统拒绝及超时，并由用户选择复制路径。成功只报告“已发送目录打开请求”；是否定位到该目录，仍需 iOS 16/17 RootHide + Filza 5 真机验证。
