# SDWebImage 写入限制证据计划

> **面向 AI 代理的工作者：** 必需子技能：使用 `subagent-driven-development`（推荐）或 `executing-plans` 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 让限制设置、状态摘要和导出明确只覆盖已认证的 SDWebImage 磁盘写入路径，且 attempts/blocked 只由真实 writer 观察产生。

**架构：** 沿用 `AxsCacheKeeperImageCache` 的受认证 SDWebImage writer hook、分 epoch 计数和 strict `writeObservation` 投影。收窄 `ScanPage` 广义“网络磁盘缓存/限制缓存”文案，并让诊断导出把 API 清理回执、SDWebImage 实际写入尝试及 blocked/allowed decision 分栏解释；缺失 observation 字段保持 unknown。

**技术栈：** Objective-C、C writer ledger、Foundation strict schema、UIKit/SDWebImage 固定依赖版本集成测试。

**规格：** `docs/superpowers/specs/2026-11-24-diagnostic-evidence-design.md` 第“意图”“范围与排除项”“约束与证据边界”“实现方案”“验收条件”节。

## 全局约束

- 能力只承诺已接入的 SDWebImage 磁盘写入观察与限制；不得暗示通用网络/任意 writer 全面禁止写入。
- `attempts`、`blocked` 必须来自真实 writer hook；缺字段等价 unknown，不能从清理 API 完成数推导。
- 限制写入、清理 API 被调用、实际磁盘落盘是不同证据；API completion 不证明文件删除/写入结果。
- 保持既有安装身份、writer owner/epoch、关闭后恢复原调用及 SDWebImage 版本兼容行为。

## 审查重点（Review Focus）

- 用户只看总开关/模式或旧回执时，文案不得表示所有网络缓存或全局文件写入均被禁止。
- 缺失 observation、旧 schema、损坏字段与零 attempts 必须区分 unknown、旧记录和真实未观察，不把零当作有效限制证据。
- 清理 API `apiCompleted>0` 且 `attempts` 缺失/为零时，不得导出 `blocked>0` 或“已阻止”结论。
- 实际 data 与 extended-data store 在 prevent 模式要记录 attempts/blocked 并保持内存读取；关闭限制后真实 store 恢复 allowed 且落盘。
- 固定 SDWebImage 5.21.7、5.15.5、5.10.4 的多版本 SDK、writer 关闭/重开、owner 失效及 epoch 滚动不能把旧 observation 算进新轮或声称 disk persistence 已验证。

## 文件清单

- 修改：`Prefs/ScanPage.m` — 总开关、模式、SDWebImage 与状态文字边界。
- 修改：`AxsCacheKeeperImageCacheStatus.h`、`AxsCacheKeeperImageWriteObservation.h`、`AxsCacheKeeperImageCache.m` — 仅当需要补齐缺失=unknown 的 schema/真实 writer 观测定义时修改；生产计数不能由 API 状态派生。
- 修改：`AxsCacheKeeperDiagnostics.m`、`AxsCacheKeeperDiagnostics.h` — imageDiskCache 导出与能力摘要的范围和 unknown 语义。
- 修改：`tests/ui/ScanPageTests.m`、`tests/ui/ImageCacheIntegrationTests.m`、`tests/ui/ImageCacheLegacyIntegrationTests.m`、`tests/diagnostics_tests.m`、`tests/run_image_write_observation_tests.py`、`tests/run_native_tests.py` — UI 文案、真实 writer、历史 schema 与诊断导出测试。
- 修改：`tests/ui/project.yml`、`tests/run_ui_tests.py`、`.github/workflows/build.yml` — 仅在新增独立 target 或测试组时更新现有测试接线。

## 接口约定

- 对外可验证的 writer 数据为现有 `writeObservation` schema：每 epoch 的 data/extended attempts、allowed、blocked、overflow、enabled/identity state，以及 `diskPersistence=notMeasured`；计数不从 `writesBlocked` 清理汇总字段反推。
- 缺 `writeObservation` 的兼容回执应表示未记录/unknown，而不是 attempts=0、blocked=0 或已恢复。
- 摘要只可在有效真实 observation 明确支持时使用“观察到 attempts/blocked/allowed”；API completion 单独表述。

### 任务 1：真实 writer 计数与未知投影

**文件：** `AxsCacheKeeperImageWriteObservation.h`、`AxsCacheKeeperImageCacheStatus.h`、必要时 `AxsCacheKeeperImageCache.m`、`tests/image_write_observation_status_tests.m`、`tests/image_write_observation_cases.h`、`tests/run_image_write_observation_tests.py`。

- [ ] **步骤 1：新增真实 writer 与缺失字段回归断言**

在 status 测试增加 `testMissingWriteObservationRemainsUnknown`：旧 schema 1 回执没有 `writeObservation` 时 strict projection 接受兼容输入但不合成 attempts/blocked。增加 `testCacheCompletionCannotCreateWriteEvidence`：只执行清理 API 并设置 `apiCompleted>0` 时没有 `writeObservation` 或 observation state=`unknown`，不能生成 blocked。复用 `image_write_observation_cases.h` 的真实 data/extended writer 样本断言 prevent 下 `attempts=1,blocked=1`、关闭后 `allowed=1,blocked=0` 且存在新的磁盘文件可读，`diskPersistence=notMeasured`；再分别将 5.21.7、5.15.5、5.10.4 实际 integration target 配置到 prevent→disabled 正反例。

- [ ] **步骤 2：运行现有 writer runner 验证失败**

运行：`python tests/run_image_write_observation_tests.py`

预期：macOS/xcrun Foundation runner 的新增精确断言先失败；固定 producer RED 仍只触发命名失败；Windows 可运行 `python tests/run_image_write_observation_tests.py --core-only`，但不能据此宣称 Foundation 投影通过。

- [ ] **步骤 3：补齐生产 observation 投影与摘要语义**

在 `AxsCacheKeeperImageCacheStatus.h` / `AxsCacheKeeperImageWriteObservation.h` 仅修改确实缺少的闭合 schema 表达：旧 receipt 缺字段保留 absent/unknown，只有 writer hook 更新 epoch counts；`AxsCacheKeeperImageCache.m` 的 API completed/skipped/queued 计数不得写入 writer ledger。

- [ ] **步骤 4：运行 writer status/full suite**

运行：`python tests/run_image_write_observation_tests.py`。

预期：真实 producer、strict Foundation XML/binary plist/JSON roundtrip、固定版本 RED、旧 schema 与 missing/unknown 断言全部通过；attempts 与 allowed+blocked 数量守恒，溢出明确；三版真实 integration 均证明 prevent 有新写入尝试且 disabled 后文件确实恢复落盘。

### 任务 2：限制能力文案与诊断导出归因

**文件：** `Prefs/ScanPage.m`、`AxsCacheKeeperImageCacheStatus.h`、`AxsCacheKeeperDiagnostics.m`、`tests/ui/ScanPageTests.m`、`tests/diagnostics_tests.m`、`tests/ui/ImageCacheIntegrationTests.m`。

- [ ] **步骤 1：编写文案和导出行为测试**

在 `ScanPageTests` 增加 `testRestrictionCopyNamesOnlySDWebImageAndNSURLCache`：主区模式说明分清标准 NSURLCache 独立开关与 SDWebImage 已适配磁盘写入，不出现全局禁止任意磁盘写入承诺；图片缓存区说明明确未知 writer 不覆盖。于 `diagnostics_tests.m` 增加 `testImageAPICompletionIsNotWriterObservation` 和 `testImageWriteObservationExportPreservesUnknownAndScope`：API completed 不生成 attempts/blocked；实际合法 writer 记录只出现在 `imageDiskCache` 且保留 SDK 名称/字段；缺失 observation 不填零；JSON 不含路径、原始错误文本或文件内容。

- [ ] **步骤 2：运行相关 native/UI suite 确认缺口**

运行：`python tests/run_native_tests.py --group cache-control`、`python tests/run_ui_tests.py`。

预期：新增能触发精确断言失败；UI runner 需要 macOS/Xcode 和 iOS Simulator，UNAVAILABLE 不算通过。

- [ ] **步骤 3：修改范围文案与投影调用链**

在 `Prefs/ScanPage.m` 收窄一键开启、模式与图片状态文案，分别命名 NSURLCache 和已适配 SDWebImage 磁盘写入，不改变底层策略配置。检查 `AxsCacheKeeperDiagnostics.m` 的 imageDiskCache 与 `AxsCacheKeeperImageCacheStatus.h` message projection：API completed 和 writerObservation 分开表示；无 writerObservation 时保持 notRecorded/unknown。

- [ ] **步骤 4：运行真实写入和摘要/导出回归**

运行：`python tests/run_native_tests.py --group cache-control`、`python tests/run_image_write_observation_tests.py`、`python tests/run_ui_tests.py`。

预期：native JSON/export assertions、UIKit 文案及实际 SDWebImage prevent→disabled 恢复断言均通过；每个版本都需证明 prevent 时 attempts>0 并 blocked>0，同时仍可内存读取；关闭后 allowed>0 且读取到新落盘文件。测试覆盖固定 SDWebImage 5.21.7 与项目既有 5.15.5/5.10.4 integration targets；报告 `diskPersistence=notMeasured`。

### 任务 3：writer 版本和整体构建接线

**文件：** `tests/ui/ImageCacheIntegrationTests.m`、`tests/ui/ImageCacheLegacyIntegrationTests.m`、`tests/run_ui_tests.py`、`tests/run_native_tests.py`、`.github/workflows/build.yml`、`Makefile`（仅新增生产文件时）。

- [ ] **步骤 1：执行全 writer 集成回归**

运行：`python tests/run_image_write_observation_tests.py`、`python tests/run_ui_tests.py`、`python tests/run_native_tests.py --output tmp/diagnostic-evidence-native`。

预期：macOS Foundation producer/schema 与三版 SDWebImage/UIKit behavior 均 PASS，完整 native summary 对 cache-control、image-write-observation 及相关 diagnostics 组为 PASS；若本机无 Apple 工具链，明确报告 UNAVAILABLE，后续交同 SHA CI。

- [ ] **步骤 2：检查 diff 和构建身份**

运行：`git diff --check`；核对新增生产文件是否进入 `Makefile`；核对 `.github/workflows/build.yml` 测试接线仍使用项目 SDK 16.5、RootHide 双架构、iOS 16–17 目标，不更改包身份或配置域。

预期：检查退出 0；没有把测试 target / 诊断写入路径扩成全局策略，也没有把非实际 writer 记录为 verified。
