# Gurd 范围证明与分片续采实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 `subagent-driven-development`（推荐）或 `executing-plans` 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 只有在固定抖音宿主的真实清理候选范围已证明且前后采样完整时才调用宿主清理；否则以 `scopeUnproven` 或明确 partial 收口，永不提交。

**架构：** 在 Gurd Source 中认证 `com.ss.iphone.ugc.Aweme` 41.2.0/build 412021、现有类/selector/type/实现地址及五个固定代码窗口，并生成绑定同一宿主实际候选规则与根身份的封闭 scope proof。Engine 在串行队列分片持有单一 cursor 与累计下界，只有完整 proof、完整 before 及提交前 lifecycle gate 均有效时才进入 `clearCacheExceptWhitelist:`；该 void 调用仍只记录 submitted，不冒充宿主完成。

**技术栈：** Objective-C/Foundation、POSIX FD-relative 遍历、现有 Theos/RootHide 工程与 macOS Foundation 行为 runner。

**规格：** `docs/superpowers/specs/2026-11-24-diagnostic-evidence-design.md` 第“范围与排除项”“约束与证据边界”“实现方案”“验收条件”节。

## 全局约束

- 宿主固定为 `com.ss.iphone.ugc.Aweme`、版本 `41.2.0`、build `412021`；实现窗口哈希不代表 whole-binary hash。
- 编码生产 proof 前先复核 `docs/superpowers/plans/2026-11-23-gurd-host-cleanup.md`、`docs/2026-11-24-图片生命周期与宿主清理整组修复.md`、`docs/2026-11-23-写入统计与平台清理修复验收.md` 与当前 `AxsCacheKeeperGurdSource.m`：已有固定证据确认 `AwemeCore` UUID `cc3b646814e43c7fa8708f1eb5f4adeb`、`IESGurdKit clearCacheExceptWhitelist:` ABI `v20@0:8B16`、YES 入口的白名单/小程序/游戏容器/锁定通道语义及宿主无完成回调；这些证据不等于已证明完整清理候选谓词。
- 若上述资料和当前固定实现窗口仍不能独立复现完整候选清单及每项保留/清理判定，生产 proof 必须保持 `scopeUnproven`，`host submitCalls==0`；不得用白名单反集、目录名猜测或合成候选 fixture 代替证据。只有新增可复核的宿主谓词证据后，才允许把相应正向 fixture 标成 production-complete。
- `clearCacheExceptWhitelist:` 仅在已证明候选集等于真实清理谓词时可调用；静态白名单子树不等于清理候选集。
- 当前未证明候选清单/完整谓词时，必须输出 `scopeUnproven` 并确保 host submit 调用数为 0。
- cursor 只在当前进程、同一 cursor 生命周期有效；partial 保留已观察条目数、逻辑字节、已分配字节、错误及终止原因。
- submitted 不等于宿主完成；不报告因果删除量或物理可回收量。
- 不执行手机宿主清理；不纳入抖音 ALog 三轮、其他 12 个无回执 APP、D 后数据完好性。

## 审查重点（Review Focus）

- 候选规则证据缺失、未知条目、宿主版本或任一方法/窗口身份变化时，proof 必须不完整且 `submitCalls==0`。
- 白名单、active/inactive 元数据、版本目录、保护排除重叠的正反样本，只有与真实宿主谓词一致的候选集合可 complete；任一不一致必须整体阻断。
- 多个 time slice 后，游标行为 fixture 每个访问文件只计一次且总下界等于该 fixture 的唯一普通文件集合；该 fixture 仅验证续采与累计，不能替代真实宿主候选范围等价 proof。取消/过期/配置撤销/读取错误/进程重启不得继续旧 cursor 或提交。
- after 未完成、重新认证失败或提交前 lifecycle gate 撤销时，不得写 observed/reduced；保留原因和 partial lower bound。
- 持有目录句柄遇目录身份变化、符号链接、关闭失败或数字累计溢出时必须释放资源并保持失败/partial，不能变成零或 complete。

## 文件清单

- 修改：`AxsCacheKeeperGurdSource.h`、`AxsCacheKeeperGurdSource.m` — Source 接口与宿主认证、候选范围解析/proof。
- 修改：`AxsCacheKeeperGurdStatus.h` — 闭合 scope proof、partial 下界及 operation/receipt schema。
- 修改：`AxsCacheKeeperGurdCache.h`、`AxsCacheKeeperGurdCache.m` — 同进程 slice 状态机、提交门、终态持久化。
- 修改：`tests/gurd_cache_tests.m`、`tests/gurd_runtime_tests.m`、`tests/run_gurd_cache_tests.py`、`tests/run_gurd_runtime_tests.py` — 生产 Engine/Source 行为、宿主边界替身和精确反例。
- 修改：`tests/run_native_tests.py`、`.github/workflows/build.yml` — 如新增独立测试组，接入正式 native runner/CI；复用既有组时不改入口。
- 修改：`Makefile` — 仅当实现新增生产编译单元时接入既有 Gurd 文件清单。

## 实施前宿主证据核对

- 先将现有 AwemeCore UUID、方法 ABI、白名单入口与保留语义、固定实现窗口逐项对照当前 `AxsCacheKeeperGurdSource.m`，并记录证据来源及其适用版本；不得将窗口哈希写成整二进制哈希。
- 再核对宿主遍历实际使用的资源元数据来源、候选选择条件、全部跳过/保护分支与调用顺序，确认能否在本机只读实现中重建同一候选集合。现有材料未闭合的任一项都意味着无生产 complete proof。
- 实施分支：若完整谓词可复现，测试真实谓词投影与宿主正反样本逐项一致；若不可复现，落地并持久化 `scopeUnproven`，测试候选证据缺失、未知候选、固定身份变化时 proof 不完整且提交数为 0。不得为了让正向测试通过而臆造宿主候选规则。

## 接口约定

- Source 为 scope proof 提供闭合投影：固定宿主身份、候选来源/谓词版本、根身份、候选计数/摘要、排除记录及 `complete|scopeUnproven|identityMismatch` 状态；不把路径、账号或文件内容写入 receipt。
- Engine 的采样 slice 返回内部 cursor 状态与下界；未结束 slice 保持 cursor，不重新开根或归零累计量。对外样本只允许 `complete|partial|scopeUnproven|cancelled|readError|identityChanged|entryLimit|depthLimit|timeLimit|invalidMetadata|linkEncountered` 等闭合状态。
- submit authorization 继续紧邻 host IMP 调用，并要求 scope proof complete 与 before complete；after complete 后才生成 reduced/unchanged/increased observation。

### 任务 1：宿主候选范围证明与关闭门

**文件：** `AxsCacheKeeperGurdSource.h`、`AxsCacheKeeperGurdSource.m`、`AxsCacheKeeperGurdStatus.h`、`tests/gurd_cache_tests.m`、`tests/run_gurd_cache_tests.py`。

- [ ] **步骤 1：编写范围 proof 行为测试**

在 `tests/gurd_cache_tests.m` 增加 `testScopeProofRequiresAuthenticatedCompleteCandidateSet`、`testUnprovenHostPredicateKeepsScopeBlockedForWhitelistAndMetadata`、`testUnknownCandidateOrHostWindowDriftBlocksSubmission`。断言：候选来源未闭合、未知条目、bundle/version/build、type/IMP/任一实现窗口改变时，`scopeProof.state==scopeUnproven` 或 identity mismatch 且 fake host `submitCalls==0`；现有证据尚不能证明生产谓词，因此第二个用例只验证保留/候选元数据投影和持续阻断，不得断言 production-complete。只有未来取得可复核的完整宿主谓词证据后，才加入真实候选正反样本及正向 complete proof；本轮不声称或测试 production-complete。不得以静态白名单子树或反集生成 complete proof。

- [ ] **步骤 2：运行指定 Gurd runner 确认测试可达**

运行：`python tests/run_gurd_cache_tests.py`

预期：macOS/xcrun Foundation 环境中新增测试先以单一精确 `FAIL: gurd: ...` 失败；其他现有检查正常。Windows 的 `UNAVAILABLE`/退出码 2 不算通过。

- [ ] **步骤 3：实现 Source scope proof 与闭合状态投影**

在 `AxsCacheKeeperGurdSource` 增加只读候选范围证明接口，并在 `AxsCacheKeeperGurdStatus.h` 验证其固定宿主身份、来源/规则、根身份、完整性、排除项及计数/摘要字段。仅当源码/接口证据确实复现宿主执行谓词时返回 complete；否则持久返回 `scopeUnproven`，禁止将用户选目录或静态保留白名单当作清理范围。

- [ ] **步骤 4：将 proof 与提交授权绑定**

在 `AxsCacheKeeperGurdCache.m -axs_cachekeeper_prepare:` 和 `AxsCacheKeeperGurdSource -submitBinding:context:authorization:reason:` 中，使 proof complete、before complete、同一 binding 和立即复核的 lifecycle gate 成为提交必要条件；proof 失败记录阻断 receipt 且不触发 source submit。

- [ ] **步骤 5：运行范围 proof 回归**

运行：`python tests/run_gurd_cache_tests.py`

预期：新增 proof 正反例和既有真实符号链接/重叠排除用例通过；mutation/固定版本 RED 仍命中指定断言；测试假 host 调用数在所有不完整 proof 反例中为 0。

### 任务 2：同进程 cursor 分片续采与 partial 下界

**文件：** `AxsCacheKeeperGurdCache.m`、`AxsCacheKeeperGurdStatus.h`、`tests/gurd_cache_tests.m`、`tests/gurd_runtime_tests.m`、`tests/run_gurd_cache_tests.py`、`tests/run_gurd_runtime_tests.py`。

- [ ] **步骤 1：增加分片累计与失败路径测试**

在 `tests/gurd_cache_tests.m` 增加 `testSampleContinuesSameCursorAcrossTimeSlicesWithoutDuplicateCounts`、`testPartialLowerBoundSurvivesCancellationAndIdentityLoss`、`testIncompleteAfterSampleNeverClaimsObservationComplete`，并补齐 FD-relative 游标的 close-failure 与 checked-add 溢出故障注入用例。断言：强制每片仅前进固定少量 entries 后，多片累计 files/logicalBytes/allocatedBytes 与 fixture 唯一普通文件集合一致且重复目录项计数为 0；取消/过期/权限或 identity 变化/异常/entry-depth 限制/close failure/累计溢出保留实测下界、错误码和 terminal reason，释放所有可释放 FD，submitCalls 为 0；after partial 时 operation 仍非 observed，decrease 计数为 0。若现有 cursor API 无法注入 close failure/overflow，在生产实现中保留显式失败分支并新增最小测试 seam，不以不相关集成用例替代。

- [ ] **步骤 2：运行 Gurd 行为测试确认失败**

运行：`python tests/run_gurd_cache_tests.py`

预期：新增分片断言以精确失败暴露；现有 Foundation 测试不能被跳过。退出码 2/UNAVAILABLE 不算通过。

- [ ] **步骤 3：实现同 cursor 跨 slice 状态机**

在 Gurd Run 内保存 cursor、proof、累计下界与 terminal reason；每次队列 slice 在相同 cursor 调用 `advanceEntries:seconds:`，未完成时排下一次 slice。遵循当前串行 queue 与公平性、可取消边界；所有终态先关闭 cursor/FD。cursor 不持久化到重启恢复。

- [ ] **步骤 4：将 partial 写入闭合 Gurd receipt**

在 `AxsCacheKeeperGurdStatus.h` 与 `AxsCacheKeeperGurdCache.m` 为 partial 明示 lower bound 与终止原因，校验完整状态与累计结果一致。任何 scope proof、before 或 after incomplete 都不得生成 measured decrease；submitted 只表示调用已进入/返回的既定范围，不表示完成。

- [ ] **步骤 5：运行 Engine 与 Runtime 生命周期回归**

运行：`python tests/run_gurd_cache_tests.py` 和 `python tests/run_gurd_runtime_tests.py`

预期：所有现有及新增 scenario PASS；进程中断恢复只留下不可续接的 partial/unknown 记录；foreground/config/install/background expiration 失效后无 cursor/FD 泄漏且不提交；close failure/overflow 不会输出零计数或 complete。

### 任务 3：合并验证与宿主范围证据门

**文件：** `AxsCacheKeeperGurdSource.m`、`AxsCacheKeeperGurdStatus.h`、`tests/gurd_cache_tests.m`、`tests/gurd_runtime_tests.m`、必要时 `tests/run_native_tests.py`、`.github/workflows/build.yml`、`Makefile`。

- [ ] **步骤 1：执行 Gurd 独立全集**

运行：`python tests/run_gurd_cache_tests.py` 和 `python tests/run_gurd_runtime_tests.py`。

预期：两个 macOS/Foundation runner 均退出 0，报告每个新增 scope proof/cursor/lifecycle 行为均 PASS；任何 `scopeUnproven` fixture 的 source call 为 0。

- [ ] **步骤 2：执行完整 native suite**

运行：`python tests/run_native_tests.py --output tmp/diagnostic-evidence-native`

预期：汇总中本计划受影响 Gurd/scan 相关组为 PASS，suite exit 0；如当前主机返回 UNAVAILABLE，记录为未验证并由同一变更的 macOS CI 补齐，不能标为通过。

- [ ] **步骤 3：审阅差异与构建接线**

运行：`git diff --check`；核对 `Makefile`、native runner、`.github/workflows/build.yml` 只接入实际新增文件/测试组，确认不改 package identity、SDK 16.5、iOS 16–17、RootHide 元数据及固定宿主认证值。

预期：空白检查退出 0，所有新增生产单元进入 Theos 和对应行为 runner，测试替身不替代 Source/Engine 实际逻辑。
