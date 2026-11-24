# Swiftgram 跨轮扫描诊断历史计划

> **面向 AI 代理的工作者：** 必需子技能：使用 `subagent-driven-development`（推荐）或 `executing-plans` 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 让 Swiftgram 最近四轮扫描历史在诊断导出中保留可定位失败阶段、错误域/码、计数与截断的脱敏摘要，并让旧轮次缺失摘要明确保持 unknown。

**目标应用：** Bundle ID 固定为 `app.swiftgram.ios`；测试 fixture、历史样本与导出断言均使用此身份，避免把其他 Telegram 客户端或泛称 Swiftgram 的记录混入目标链路。

**架构：** 复用现有 `scanDiagnostics` 封闭投影与最大 16 项错误上限，将每轮聚合诊断放入 `recentScans` 条目，随 `snapshots.plist` 原子写入。诊断报告递归白名单投影历史摘要，只导出枚举阶段/原因/域、数值码/次数、计数和截断标记；路径、自由错误文本与文件内容不进入摘要，旧历史缺字段时显式投影为 unknown。

**技术栈：** Objective-C/Foundation property list、诊断 JSON 白名单导出、macOS Foundation history/export tests。

**规格：** `docs/superpowers/specs/2026-11-24-diagnostic-evidence-design.md` 第“Swiftgram”范围、“约束与证据边界”“实现方案”“验收条件”部分。

## 全局约束

- 保存每轮 scan failure projection：失败阶段、错误域、错误码、聚合次数及 `errorsTruncated`/`omittedErrorCount`。
- 沿用 `AxsCacheKeeperScanDiagnostics.h` 封闭阶段/域/码和值域及 `AxsCacheKeeperScanErrorLimit=16` 上限。
- 历史摘要不得保存私有绝对路径、NSError 自由文本、URL/账号或文件内容。
- 旧 `recentScans` 条目没有诊断字段时导出 `unknown`；不得回填成功、零错误或当前轮诊断。
- 保持最近 4 条上限和既有 XML/binary plist 迁移、完整度、取消及原子写入行为。
- 新增/多轮测试样本的目标应用身份必须为 `app.swiftgram.ios`，不得只用显示名称 `Swiftgram` 选择或关联历史。

## 审查重点（Review Focus）

- 本轮扫描存在 POSIX/Cocoa 失败时，历史摘要须保留封闭 stage/domain/code/count 与不完整测量状态。
- 多于 16 种错误或聚合数字饱和时，须保留明确截断与 omitted count，不得静默丢失后仍称完整。
- 旧轮次没有字段、字段类型损坏或未知枚举值时，保持 unknown/invalid，不得推导错误为 0。
- 含绝对路径、私有名称和 NSError 文本的输入通过快照及真实 JSON 导出后均不得出现原始 canary。
- 新历史追加不能破坏最近四条容量、既有 rows/home/time 或 current scan record validator。

## 文件清单

- 修改：`AxsCacheKeeperInspection.h` — 最近扫描历史 entry projection 与 4 条裁剪。
- 修改：`AxsCacheKeeperScanTask.m` — 当前本轮 `scanDiagnostics` 和明确 unknown/available 状态写入 recent history entry。
- 修改：`AxsCacheKeeperScanDiagnostics.h` — 仅在现有诊断封闭投影不足时增补版本兼容的历史专用投影；不复制另一套错误 schema。
- 修改：`AxsCacheKeeperDiagnostics.m` — 历史 entry 的 JSON 白名单投影及隐私边界。
- 修改：`tests/scan_history_tests.m`、`tests/cache_control_tests.m`、`tests/scan_diagnostics_tests.m`、`tests/diagnostics_tests.m`、`tests/run_scan_task_tests.py`、`tests/run_scan_diagnostics_tests.py`、`tests/run_native_tests.py` — 跨轮写入、保留、脱敏与导出验证。

## 接口约定

- 新 history entry 字段：`updated`、`home`、`rows`、`scanDiagnosticsState` (`available|unknown`)；状态为 available 时包含严格通过 `axs_cachekeeper_scan_diagnostics_projection` 的 `scanDiagnostics`，unknown 时不含该字段。
- `scanDiagnostics` 只允许现有诊断投影字段与封闭错误数组；历史投影不得另存 error/message/path。
- `recentScans` 保留最后 4 个条目；旧条目 decode 时被投影为 `scanDiagnosticsState=unknown`，无错误码/计数的零值不合成。

### 任务 1：历史 entry 诊断闭合投影

**文件：** `AxsCacheKeeperInspection.h`、`AxsCacheKeeperScanDiagnostics.h`、`tests/cache_control_tests.m`。

- [ ] **步骤 1：新增 history projection 精确断言**

新增 `testRecentScansRetainClosedDiagnosticsAndUnknownLegacyState`：输入含 `stage=enumerate`、`reason=permissionDenied`、`errorDomain=posix`、`errorCode=13`、`count=2`、`errorsTruncated=true`、`omittedErrorCount=3` 的本轮诊断，断言历史第 0 项字段逐值保留且没有 path/message；额外构造超过 `AxsCacheKeeperScanErrorLimit=16` 个封闭错误并验证 `errorsTruncated` 与 omitted count 保留。再输入旧条目无 `scanDiagnostics`、错误类型损坏及未知 stage/domain 的条目，分别断言 `scanDiagnosticsState=unknown|invalid` 且没有 synthetic zero/error/complete。保留现有四条上限断言。

- [ ] **步骤 2：运行 cache-control 原生组确认新增断言失败**

运行：`python tests/run_native_tests.py --group cache-control`

预期：macOS Foundation 环境新增 history projection 断言先失败；Windows 返回 UNAVAILABLE/2 时只记为缺少原生环境。

- [ ] **步骤 3：实现单一封闭 history projection**

在 `AxsCacheKeeperInspection.h` 扩展 `axs_cachekeeper_recent_scans` 或其专用 inline helper，复用 `axs_cachekeeper_scan_diagnostics_projection` 校验可用诊断；对缺失旧字段明确写 `scanDiagnosticsState=unknown`，非法诊断输出 `invalid` 状态，不保存原自由文本/路径。

- [ ] **步骤 4：运行 history projection 与上限测试**

运行：`python tests/run_native_tests.py --group cache-control`

预期：新闭合 projection 断言、`recentScans.count==4`、既有趋势函数基于 complete row 的行为均通过。

### 任务 2：扫描任务持久化本轮诊断

**文件：** `AxsCacheKeeperScanTask.m`、`tests/scan_history_tests.m`、`tests/run_scan_task_tests.py`。

- [ ] **步骤 1：增加真实多轮 history persistence 用例**

新增 `testRecentHistoryRetainsPerRoundFailureProjection`：为 `app.swiftgram.ios` 通过真实 `AxsCacheKeeperScanService` 第一轮产生枚举失败后保存，第二轮成功后读取 `snapshots.plist`，断言该应用的最近历史保留第一轮 `available` 失败 projection 的 stage/domain/code/count/truncation，当前轮诊断与历史分离，且四轮以外旧 entry 被裁掉。再加载该应用无新字段的旧 plist，断言 unknown。

- [ ] **步骤 2：执行 scan-task runner 确认失败**

运行：`python tests/run_scan_task_tests.py`

预期：macOS Foundation 下新增真实保存断言失败；原有 binary history、精确 bytes reuse、取消/写失败回归继续执行。

- [ ] **步骤 3：在 `-snapshot` 生成每轮诊断历史项**

在 `AxsCacheKeeperScanTask -snapshot` 将 `self.old` 的 recent history 规范化后追加 current `updated/home/rows/scanDiagnostics` entry，并写出 `scanDiagnosticsState`。所有字段使用本任务实际聚合的诊断；失败或未知维持 original state。

- [ ] **步骤 4：运行 scan history 全组**

运行：`python tests/run_scan_task_tests.py`

预期：新增跨轮断言、XML→binary history 迁移、外部 bytes mutation、取消与 writer failure 既有断言均通过。

### 任务 3：诊断 JSON 投影与隐私边界

**文件：** `AxsCacheKeeperDiagnostics.m`、`tests/scan_diagnostics_tests.m`、`tests/diagnostics_tests.m`、`tests/run_scan_diagnostics_tests.py`、必要时 `tests/run_native_tests.py`。

- [ ] **步骤 1：新增真实 report export 隐私与 unknown 测试**

新增 `testRecentScanDiagnosticsExportIsBoundedAndRedacted`：最近 history 含有效 scanDiagnostics 和 `private-history-path-canary`/`private-history-error-canary`，真实 `AxsCacheKeeperDiagnostics reportWithApps:environment:` JSON 导出保留阶段、域、码、计数及截断字段，JSON 不含 canary；旧 history 缺字段导出 `scanDiagnosticsState=unknown`，不补 0 或成功状态。

- [ ] **步骤 2：运行 scan diagnostics 导出 runner 确认失败**

运行：`python tests/run_scan_diagnostics_tests.py`

预期：macOS Foundation 下新增真实 JSON 导出断言失败且既有 discovery/measurement/export cases 可运行；非 macOS 的退出 2 不算通过。

- [ ] **步骤 3：将 history entry 接入严格导出白名单**

在 `AxsCacheKeeperDiagnostics.m -axs_cachekeeper_record:` 对 recentScans 使用明确的 entry projector：字段/状态闭合、summary 复用 scan diagnostics projection；绝对路径依现有 redactor 隐藏，错误自由文本不复制进入 history projector。

- [ ] **步骤 4：运行 scan/history/export 相关测试**

运行：`python tests/run_scan_diagnostics_tests.py`、`python tests/run_scan_task_tests.py`、`python tests/run_native_tests.py --group cache-control`。

预期：诊断历史从生产 scan persistence 到真实 JSON export 的 stage/domain/code/count/truncation 一致，旧条目 unknown，所有 canary 字符串缺席，受影响组退出 0。

### 任务 4：全集接线与完整度复核

**文件：** `AxsCacheKeeperScanDiagnostics.h`、`AxsCacheKeeperInspection.h`、`AxsCacheKeeperScanTask.m`、`AxsCacheKeeperDiagnostics.m`、上述测试与 `tests/run_native_tests.py`。

- [ ] **步骤 1：运行计划相关 native groups 与整体 suite**

运行：`python tests/run_native_tests.py --group scan-task`、`python tests/run_native_tests.py --group scan-diagnostics`、`python tests/run_native_tests.py --group cache-control`、`python tests/run_native_tests.py --output tmp/diagnostic-evidence-native`。

预期：受影响三组和完整 suite 在 macOS Foundation 环境退出 0；如主机不支持，报告为 UNAVAILABLE 并由同 SHA macOS CI 验证，不把静态检查算作行为通过。

- [ ] **步骤 2：审阅持久 schema 与隐私 diff**

运行：`git diff --check`；检查测试 canary 只位于 fixtures，生产持久 history/JSON 的 closed projection 不含自由文本/绝对路径，recentScans 上限仍为 4。

预期：diff check 退出 0；旧快照缺字段投影为 unknown，不迁移性伪造。
