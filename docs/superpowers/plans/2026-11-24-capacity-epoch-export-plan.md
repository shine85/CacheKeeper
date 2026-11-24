# 全容器容量测量 Epoch 导出门禁计划

> **面向 AI 代理的工作者：** 必需子技能：使用 subagent-driven-development（推荐）或 executing-plans 逐任务实现此计划。步骤使用复选框（- [ ]）语法来跟踪进度。

**目标：** 使诊断 JSON 仅携带最新已结束只读容量测量的结果，并证明该结果是在对应 terminal epoch 完成后重新汇总；任何重测立即使旧报告失效。

**架构：** DiagnosticsPage 将用户启动的新 epoch、服务读取的 terminal record 与汇总报告的绑定纳入同一 generation 状态机；重测已接受时清除旧 reportData 与容量快照。capacityMeasurement JSON 保留 terminal epoch/state/finishedAt 与 summary epoch/time 的封闭版本化投影，导出前同时校验其 epoch 一致和 summary 时间不早于终态。取消未确认、running、读取错误、错 epoch 和局部根失败均保留原状态/错误，不以旧报告或零填充。

**技术栈：** Objective-C/UIKit、Foundation plist/JSON、当前 capacity schema projector、iOS Simulator xcodebuild XCTest。

**规格：** docs/superpowers/specs/2026-11-24-diagnostic-evidence-design.md 第“导出”“约束与证据边界”“实现方案”“验收条件”部分。

## 全局约束

- 重测开始会使旧容量报告失效；导出不自动启动容量扫描，用户仍需显式重测、汇总、导出。
- 仅最新已 terminal 的只读 measurement epoch 可被汇总导出，且汇总必须发生在该 epoch 的 terminal finishedAt 之后。
- 重测未汇总、running、取消未确认、结果不可读/错 epoch 或汇总后又开始测量时，不得导出为最新容量结果。
- 局部根失败保持 partial 和失败明细；不得补零或把部分结果标 complete。
- 容量测量不授予 APP 私有数据清理权；逻辑/分配字节不等于 APFS 可回收物理空间。

## 审查重点（Review Focus）

- 已有报告后启动新测量时，无论何时点击导出，都不得继续使用旧 reportData 或旧容量快照。
- 当前 epoch terminal 完成后，如果从未重新汇总，必须阻止旧 summary/export；新的 summary generation 必须与最新 terminal epoch 相等且时间晚于 finishedAt。
- 新 epoch 期间旧 epoch 的迟到 poll、saved plist、terminalHistory 或异步 collection completion 不能覆盖新 epoch 的 gate。
- cancel request 保存失败、用户放弃等待和停止终态未确认时，测量仍按 running/unknown 表达，不能导出为新 terminal complete。
- 最新 epoch 为 partial/某 root readError 时，导出保留失败根与 cursor error stage/domain/code/count/truncation，失败根 bytes 不得补为 0。

## 文件清单

- 修改：Prefs/DiagnosticsPage.m、Prefs/DiagnosticsPage.h — 重测失效、epoch/generation 竞态、summarize/export 可用状态门。
- 修改：AxsCacheKeeperCapacityStatus.h — terminal measurement 与 summary binding 的严格 JSON projection；字段按可选 schema 版本扩展保持旧报告兼容且不升级为 verified。
- 修改：AxsCacheKeeperDiagnostics.m — capacityMeasurement 写入真实 summary/terminal 绑定字段，拒绝 stale binding。
- 修改：tests/ui/CapacityPageTests.m、tests/run_capacity_page_tests.py — 真实 UIKit 流程和精确拒绝测试。
- 修改：tests/diagnostics_tests.m、tests/run_native_tests.py — closed JSON projection、错 epoch/时序/partial failure native assertions。
- 修改：tests/test_capacity_page_orchestration.py、.github/workflows/build.yml — 仅当新场景要求增加 harness orchestration check/测试入口时接线。

## 接口约定

- capacityMeasurement 的 terminal fields 使用当前 measurement 的 epoch、state、finishedAt；只有 terminal state (complete|partial|cancelled|interrupted|unavailable) 可作为结束记录，running 明确不可作为最新已完成测量。
- 同一导出投影增加闭合 summaryBinding：epoch、summarizedAt、terminalState、terminalFinishedAt、state (current|stale|unknown)。仅当其 epoch/state/finishedAt 与 terminal record 相等且 summarizedAt >= finishedAt 时 state 为 current；旧 schema 缺绑定时 unknown。
- 用户重测成功启动产生新 epoch 时清除绑定和内存报告；诊断汇总完成后才创建新绑定。异步结果回主线程时仍须匹配当前 generation 和 latest epoch。
- partial 导出继续携带 failedRoots 和每个失败 root 的严格 cursorErrors；不在数据层把 missing measurements 转成零。

### 任务 1：terminal 与 summary binding strict projection

**文件：** AxsCacheKeeperCapacityStatus.h、AxsCacheKeeperDiagnostics.m、tests/diagnostics_tests.m。

- [ ] **步骤 1：增加 capacity binding projection 测试**

新增 testCapacitySummaryBindingRequiresLatestTerminalEpochAndTime：完整 terminal epoch A + summaryBinding A 且 summarizedAt>=finishedAt 投影为 current；epoch B mismatch、summarizedAt<finishedAt、terminal state running、错误 finishedAt 类型及缺 binding 的 legacy record 分别拒绝或投影 stale|unknown，不得保持 current。新增 testCapacityPartialFailureProjectionPreservesRootError：partial/failedRoots 与 root readError 的 cursor error stage/domain/code/count/truncation 原值保留，缺失容量不补 0。

- [ ] **步骤 2：运行 diagnostics native 组确认断言失败**

运行：python tests/run_native_tests.py --group cache-control

预期：新增 projector/export assertion 先失败；`cache-control` 是当前 `tests/run_native_tests.py` 已注册 group，macOS Foundation 行为测试必须执行，UNAVAILABLE/2 记为未运行。

- [ ] **步骤 3：增加版本化 summary binding 闭合投影**

在 AxsCacheKeeperCapacityStatus.h 为 capacity export schema 定义 strict projection：验证 epoch UUID、terminal state、有限非负时间、terminal 与 summary binding 一致、summary 时间不早于 terminal。旧 schema 保留既有容量字段，但 binding 缺失时 state=unknown，不回填 current。

- [ ] **步骤 4：将 binding 纳入实际 report 导出**

在 AxsCacheKeeperDiagnostics.m 采集 environment[@"capacityMeasurement"] 时，经 projector 输出 terminal observation 与 summaryBinding；结构不完整或不一致仅导出 stale/unknown，不把容量值标成最新。

- [ ] **步骤 5：运行 strict projection regression**

运行：python tests/run_native_tests.py --group cache-control

预期：A/current positive、错 epoch、旧 summary、running、旧 schema unknown、partial root error 与 JSON serialization 断言通过；cursorErrors 不含 path。

### 任务 2：DiagnosticsPage 重测和汇总 generation gate

**文件：** Prefs/DiagnosticsPage.m、Prefs/DiagnosticsPage.h、tests/ui/CapacityPageTests.m、tests/run_capacity_page_tests.py。

- [ ] **步骤 1：增加真实 UIKit 时序门测试**

新增 testNewMeasurementInvalidatesPreviousReportImmediately：先完成并汇总 epoch A，再启动 epoch B；断言启动 B 时 reportData=nil、capacity snapshot/binding=nil，旧导出不可用。新增 testSummaryAfterTerminalIsRequiredForEpochBExport：B terminal complete 但未重新汇总时禁止导出；随后收集后绑定 epoch B 且 summarizedAt>=finishedAt 才允许。新增 testStaleCollectionCannotRestorePriorEpochAfterRemeasure：阻塞 collection queue 返回旧 A，启动/确认 B 后放行 A，assert A completion 不得设置 B 页的 reportData/binding。新增 testRunningAndUnconfirmedCancelNeverBecomeCurrentSummary 覆盖 running、停止请求失败和未确认终态。

- [ ] **步骤 2：运行 UIKit runner 确认测试失败**

运行：python tests/run_capacity_page_tests.py

预期：macOS Xcode/xcodegen/iOS Simulator 上至少新增场景以唯一预期断言失败；当前 Windows 不可执行时 runner 输出 UNAVAILABLE/2，不能算通过。

- [ ] **步骤 3：实现 UI epoch invalidation 和 collection freshness gate**

在 Prefs/DiagnosticsPage.m 的 axs_cachekeeper_capacity_action 新 epoch 成功保存后，先递增 generation 并清除旧 report/snapshot/summary binding；在 axs_cachekeeper_collect 捕获 collection generation 与 capacity epoch，在异步结束主线程重新比较两者，过期完成不得发布 reportData。仅 terminal result 同 epoch 后开始的 summary 可盖章绑定；点击导出前要求无 active capacity epoch 且 report summaryBinding=current。

- [ ] **步骤 4：保留取消及 partial root 原始状态**

更新 axs_cachekeeper_capacity_export:saved:stop:，对 running、unconfirmed stop、其他 epoch saved result 和 terminalHistory 不生成 current binding；对 partial terminal 保留 failedRoots/cursorErrors 并创建仅标识该 partial epoch 的 binding，UI 不称其全根 complete。

- [ ] **步骤 5：运行所有 CapacityPage XCTest**

运行：python tests/run_capacity_page_tests.py

预期：新增 epoch invalidation、summary-after-terminal、迟到异步 collection、running/unconfirmed cancel 场景及现有 stop/restore/navigation/strict projection 全部通过；xcresult 失败数为 0。

### 任务 3：完整采集→投影→导出链路复核

**文件：** Prefs/DiagnosticsPage.m、AxsCacheKeeperCapacityStatus.h、AxsCacheKeeperDiagnostics.m、上述 UI/native tests、runner/CI 接线。

- [ ] **步骤 1：增加最终 JSON 真链路用例**

新增 testCapacitySummaryBindingSurvivesActualJSONExport：建立 latest terminal A 与之后 summary，执行 AxsCacheKeeperDiagnostics reportWithApps:environment: 并 JSON serialize，断言 epoch/state/finishedAt/summarizedAt 与 A 完全一致且 binding current；然后模拟最新 epoch B 开始但未汇总，断言旧 A report 已清空或被标 stale，且不得以 A 容量冒充 B。

- [ ] **步骤 2：运行 UIKit、native 与编排测试**

运行：python tests/run_capacity_page_tests.py、python tests/run_native_tests.py --group cache-control、python tests/test_capacity_page_orchestration.py。

预期：iOS Simulator UI 场景、Foundation JSON projection 与 orchestration safety 均退出 0；工具链缺失导致的 UNAVAILABLE 必须交由同一提交 macOS CI 补跑。

- [ ] **步骤 3：运行完整 native suite 与提交前静态门**

运行：python tests/run_native_tests.py --output tmp/diagnostic-evidence-native 和 git diff --check。

预期：capacity、cache-control/diagnostics 相关组全部 PASS，完整 runner exit 0，diff check exit 0；没有系统容量置零、自动重测或清理授权副作用。

- [ ] **步骤 4：审阅闭合门与兼容性**

检查 capacityMeasurement.summaryBinding 对缺失、损坏、terminal history-only、cancelled/unavailable、错 epoch、回调竞态和 partial root error 的结果；确认旧 report 缺 binding 时只显示 unknown/stale，既有 clientStop 记录不被伪装成服务终态。

预期：每个失败状态都有独立结果并匹配对应测试；summary binding 不被容量 measurement service 写入或当成只读测量本身的事实。
