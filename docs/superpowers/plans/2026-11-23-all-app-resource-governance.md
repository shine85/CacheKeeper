# 全 APP 资源治理实现计划


## 2026-11-23 21:10 实际主体核验后的方案裁定

**当前方案不能承诺让所有 APP 总占用下降或永不增长。** iOS 的可丢弃缓存约定适用于其缓存用途；用户数据、下载和业务索引需要宿主用途及保持语义。验收改为“已支持的可丢弃缓存实际减少、后续写入按模式受控、关闭恢复、必要数据保持”，并独立列出未取得治理能力的主体，不能用小缓存成功代替整 APP 效果。

百度本机已实测到主占用不在普通图片缓存：netdisk.cachefilelist 约1.575GB，全文检索数据约215MB；image_main.image_filelist约1.384GB（不含其索引），另一个库同名表只有一个空页。image_main照片表有全局单列UNIQUE(fid)，该表总3334320行/deleted1为0的授权只读汇总完整exit0；不存在已证待删垃圾可供deleteGarbageImage处理。该入口候选停止，不继续为零候选补适配，也不调用deleteAll/truncate/VACUUM。主文件+WAL/SHM前后元数据一致，所有本轮隔离目录已核清理。数字不证明全部记录永久必要，只证明当前未发现安全淘汰这部分主体的范围。

实施分两条并行推进：

1. 完成已证通用能力的一整组修复：平台缓存read/pread与依赖语义、准确保留原因、实际writer的模式epoch与尝试/转发/阻止、关闭恢复、导出全链路、旧owner退出registry归属修正。当前21文件候选通过两轮独立源码复核；对象/C核心与编排通过，完整入口55组9PASS/46UNAVAILABLE，须同SHA云端Foundation/UIKit/RootHide打包/验deb完成后才能交付，不能标已真机修复。
2. 主体资源只接真实宿主策略。百度下一唯一有意义方向是FileDiff/ImageDiff同步owner是否已有同步范围、按需索引、保留期限或关闭可选索引的可恢复设置；尚未证明这些设置存在，不能先实现猜测开关。QQ仍需实际Documents缓存owner/同步写并发边界；抖音仍需Support主体owner；Swiftgram优先原生存储页所选媒体清理的合法高层桥接与保留条件。没有合同的主体保持未知/不可自动治理，不能硬改数据库解决容量数字。

四样本以外129个展示APP仍走统一容器发现和平台/SDK能力，不退化为四个bundle硬编码专用产品；新增/升级按能力增量复核。已有全133容量覆盖与历史SDK档案复用，不要求用户重新逐目录采集。

严格独占物理回收依然独立缺口；逻辑字节、dbstat页量、主容器减少和系统自由空间变化分别报告。不把高层完成回调、SQLite空闲页或清理计数当成物理释放证明。

本轮未发布新包、未部署产品、未执行任何APP资源清理。不能为上述诊断/证据补齐单独反复发包；整组真实验证完毕后统一交付，主体未闭合项必须明确列为未完成。


> 面向实施者：沿用当前会话逐任务执行和最终整体复核；检查项使用复选框。用户要求整组完善后统一提交，不按下面任务逐个提交发包。本文是实施计划，不表示新增代码、测试或真机效果已完成。

**目标：** 全部 APP 都有准确能力结论，已开启 APP 的可治理缓存实际减少、新增受控、关闭恢复；已验证契约跨 APP 复用，新增与升级自动增量重验。

**架构：** 复用 Installation、Rules、Job/Sweep、Network、Image、WebKit、Capacity、Receipts。在已有投影补缺少字段，按需增加具体私有事务；文件删除规则只有一处，APP 配置只有现有来源。空间效果、资源保持与真实运行是交付门。

**技术栈：** Theos / Logos、ARC、Foundation / UIKit / WebKit、SDK 16.5、iOS 16–17、RootHide、arm64/arm64e；包身份 `dev.local.cachekeeper`、作者目目。

**规格：** [全 APP 覆盖分析与最终实施方案](../../2026-11-23-全APP覆盖分析与最终实施方案.md)。最新设备依据 198.1 / iOS16.2；完整 133 项本地台账在 `packages/all-app-governance-2026-11-23/`，不提交用户安装列表。

## 全局约束与实施顺序

已实现成果先保留：1123 整组、百度恢复、统一容器提供器、续扫、真实标准缓存删除与历史、NSURLCache、现有 SDWebImage、WebKit、PDF/搜索、容量分类和旧权限恢复。当前产品基线 `122e1ff`，不重写这些功能。

修订顺序：任务 0 标准缓存主流程 → 任务 2/3 中现有能力的写入与恢复补齐 → 任务 4 宿主已有缓存管理 → 其他实现族扩展。任务 1 能力投影随实际功能接线；任务 5 空间效果贯穿每项，严格物理归因独立；任务 6 整体验收。任务之间可离线研究独立契约，交付仍为整组。未知 Swift/闭源 ABI 是真实阻断，不能承诺仅凭本计划必然解决。

修改已有文件先 BK 时间戳备份；新文件无需备份。临时测试产物只放 tmp，本地证据长期保留 packages。设备补证不重复全机扫描，不要求用户查目录或提供 IPA。关闭 APP 不自动开启，系统条目不扩大注入，风起云涌排除、微信关闭保持。

越狱路径仅用当前 SDK 实际 `jbroot()` / 已核路径 API；应用容器使用系统提供器，资源 token 只在当前观测有效。不开广泛写锁，不放宽 ABI/IMP/owner 检查，不以裸 unlink 替代私有索引事务。

## 审查重点

| 输入或失败条件 | 期望结果 | 对应任务 |
|---|---|---|
| 新版宿主出现，但某能力回执仍是旧版；APP 从未启动 | 分能力保留原时间版本；未知不升级成已验证 | 1、2 |
| 同短版本换 build、实现或容器；排队后排除/关闭 | 旧作业即时失效；停止新动作，必要保留不撤销 | 2、3、4 |
| SDK 同名类/伪版本、并发队列、自建后端、多个 owner | 不根据名字放行；只处理证明兼容且授权的范围 | 3 |
| 文稿/媒体缺恢复来源、共享消费者或索引事务；半完成/映射日志 | 保留原件/索引/未知项，明确拒绝，其他独立能力继续 | 4 |
| 克隆/快照/范围外链接/打开 FD、后台并发、系统显示口径变化 | 逻辑删除与空间趋势分开；无证据不报告独占物理释放 | 5 |

## 任务 0：先修 iOS 标准缓存实际主流程

**已确认问题：** 无关目录名称被 auth/session/token 等子串误拦截；标准缓存被内容预读门阻塞。修改 Rules、Baseline 的内容读取依据；名称策略需先有具体范围用途证据，当前不扩选择/删除范围，Inventory/原因明确未核实。平台用途不要求逐文件永久可重取；明确账户/离线/草稿等必要用途、用户排除和内置 APP 精确保留继续生效。

- [ ] 真实生产路径测试：已有标准范围清理、名称提示维持既有动作边界且不称已确认必要、用户/APP 排除保持；不使用名字单独生成新增删除授权。
- [ ] PlatformCache 决定不依赖 readComplete，Baseline 只在同一 Rules 已明确平台决定时省内容探测；身份、类型、年龄、硬链接和取消门保持，日志/未知/私有内容要求不放宽。不能假填 readComplete=YES。
- [ ] 新平台规则 revision 使旧作业和登记失效；真实目录 Sweep/选择/Inventory/Image 共用语义验证。
- [ ] 复核逐根采样的批内撤销：不得称每次 unlink 已同步检查当前进程；只有取得当前状态的机制才能收窄窗口，性能和旧 FrontBoard 采样回归一起验。
- [ ] 原生 fixed-old 精确 RED、当前 GREEN，现有 cache-control/retention/硬链接/权限/SDK 回归通过；无实际执行环境按 UNAVAILABLE 记录。

此任务完成也不表示百度 Documents 等占用主体已回收。

## 任务 1：全 APP 能力与证据来源统一投影

**文件职责：**

- 修改 `AxsCacheKeeperStorageInventory.h/.m`：基于同次已读 envelopes 和 registry 生成全部能力，不新增读盘来源。
- 优先扩现有 Status/StorageInventory 投影；只有字段复杂度确需独立文件时才新增 `AxsCacheKeeperCapabilityStatus.h`，它不含配置、hook、授权或 I/O。
- 修改 `AxsCacheKeeperDiagnostics.m`、`Prefs/DiagnosticsPage.m`、`Prefs/ScanPage.m`：展示每个资源能力、版本/时间、缺口与空间效果，不能显示伪“全 APP 已适配”。
- 扩充 `tests/storage_inventory_tests.m`、`tests/runtime_receipt_tests.m` 和现有 UIKit 相关用例。

**明确接口：** 在 StorageInventory 层新增 `NSDictionary *axs_cachekeeper_resource_capabilities(NSDictionary *rawEnvelopes, NSString *panelVersion, NSDictionary *verifiedResourceEvidence)`；现有 `axs_cachekeeper_capabilities` 保留兼容字段并委托共享核。`verifiedResourceEvidence` 来自各生产模块正式输出，缺失就 unknown，不接受 UI 构造授权。投影字段为 `discovery/cleanup/writeRestriction/disableRecovery/dataPreservation/physicalAttribution`；每项保存 `state/sourceVersion/sourceUpdated/reason`，已验证效果必须有相关结果来源。

- [ ] 先扩充真实 plist→生产投影→JSON 测试：未启动、新宿主配旧图片回执、损坏/缺失 envelope、系统条目、3 历史条目、关闭/排除、无根、权限失败、空/非空动作。
- [ ] 断言没有结果不能得到 verified；旧版本原时间不变；发现/方法存在/容量零/API完成均不授删除。全量样本 133 展示 + 163 非展示 + 3 历史逐项有状态且无重复。
- [ ] 实现上述纯投影与页面接线；空间效果显示实际治理范围和未覆盖占用，不把累计删量当总占用净下降。
- [ ] 运行 `python tests/run_storage_inventory_tests.py`、`python tests/run_runtime_receipt_tests.py` 及对应 UIKit 套件；单条原生命令不超过 60 秒，整套沿用已有编排预算。缺 macOS 时记录 UNAVAILABLE，交任务 6 同提交 CI 实跑。

**产出门：** 程序能自动生成每个 APP 的逐能力矩阵；完整安装清单本地保留，公开方案仅汇总。

## 任务 2：增量重验、动作关联和开发侧最小补证

**文件职责：**

- 修改 `AxsCacheKeeperInstallation.m`：复用现有安装身份缓存/容器登记，补实现和资源证据的失效关联。
- 修改 `Scanner.m`、`AxsCacheKeeperCleanupSchedule.m`：沿用现有登记/静默规则，记录实际重查理由；不凭 34 秒间隔改调度。
- 修改 `AxsCacheKeeperImageCache.m` / `AxsCacheKeeperImageCacheRuntime.m`、`AxsCacheKeeperNetworkCache.m`、`AxsCacheKeeperWebKitCoordinator.m`：实际 writer/后台时间/准入恢复来源，有限计数且不改变原调用。
- 修改已有 Status/OperationInfo/Receipts 投影及相应 native 用例；开发侧归并工具新增 `scripts/compile_app_capabilities.py`，只读已有报告与档案，不连接设备、不读取原文、不发配置。

**证据接口：** 各 owner 输出 `verificationContext={installationGeneration,configurationGeneration,contractID,contractRevision,operationID}`，公开 ID 为观测范围匿名值。Image writer 分 `nonemptyAttempts/allowed/blocked`，分别记录 main data 与 extended data；Network 区分容量策略应用和可归因文件写入效果。WebKit 记录同 token 的准备、提交、过期和剩余时间区间。Registration 记录命中、原测量时间与固定枚举重查原因。证据历史不成为下次授权来源。

- [ ] 对实际生产源码补负控：同版本换 build、root 替换、成员变化、旧异步回调、配置关闭、后台无时间、计数边界/溢出、provider 失败/重启。旧轮不能覆盖新轮；未变项不反复解析或制造清理终态。
- [ ] 先运行旧行为反例确认它在指定断言失败，再实现最小补证/关联；健康图片分支保持不读 provider、不学习新 IMP/queue/path。
- [ ] 定義编译工具输入为报告路径+可选历史索引；输出 count/来源/差异/缺口，不输出数据内容/账户/原路径。校验 133 项台账与 registry 的集合一致，SDK 缺动态候选不等于不存在静态链接实现。
- [ ] 对当前 18 个已开启 APP 自动归并；13 个缺本版本回执按未启动、未触发、保存失败、来源拒绝分别核。不能用批量强开 APP 或清库“制造证据”。
- [ ] 离线无法回答时才建立最小设备任务：一个安装差异、一个待证假设、一组字段、明确失败退出。复用授权连接和已采镜像；失败留阻断，不反复 attach/整包上传。
- [ ] 运行 `python tests/run_installation_identity_tests.py`、`python tests/run_host_evidence_tests.py`、`python tests/run_cleanup_observation_tests.py`、`python tests/run_image_main_view_tests.py`、WebKit/Network 现有相关组。新编译工具补真实输入校验测试；其输出不是手机行为测试。

**产出门：** 新装/升级/实现变化/重启真实撤销与重验通过；报告能自行还原新阶段，不再依赖用户回忆切换顺序。

## 任务 3：跨 APP SDK 实现契约复用与覆盖扩展

**文件职责：**

- 修改 `AxsCacheKeeperImageCache.m`、`AxsCacheKeeperImageCacheRuntime.m` 和相关 Discovery/Source/Status：现有 modern 与 fixed legacy 接口继续运行。
- 优先沿用已存在 modern/fixed-legacy 等契约结构；出现第二个实际复用方后才抽独立实现描述，不预建 `AxsCacheKeeperSDKContract` 通用框架。
- 新增 `AxsCacheKeeperYYCacheAction.h/.m`、`AxsCacheKeeperPINCacheAction.h/.m`：仅当真实 owner 契约已证明时接入；Swift 适配独立桥接文件，合法 ABI 未证前不写动作代码。
- 扩充 `tests/ui/ImageCacheIntegrationTests.m`、对应实际 SDK 集成目标与 `tests/run_ui_tests.py` 的来源校验；增加真正支持族的 native/runtime 用例。

**契约接口：** 在具体 owner 模块中描述 `contractID/revision/implementationFamily/capabilities` 并核实现、ABI、owner、后端、队列、路径、授权；复用现有入口，独立类的需求未出现前不创建抽象层。能力声明来自实测实现族，不能用 SDK 名称或数字版本推导。通过后交已有 owner 引擎执行，不向 Scanner 广泛授路径删除。

- [ ] 对 61 个历史候选先逐项重验当前安装关系并给兼容/失配/待重验/阻断；18 个动态 SDWebImage 先处理现有兼容五样本，再处理明确差异版本和伪版本。
- [ ] 固定上游提交与本地目标语义表：初始化、全部写分支、内存保持、队列、清理回调、取消、关闭恢复。现有上游：SDWebImage `2de3a496...` / `fb50c1d...`、QQ 旧接口 `b734f289...`、YYCache `0aac6e84...`；完整哈希和路径见规格关联的研究记录。新 PIN/日志/Swift 实现必须再取得固定源码，不凭本计划臆造 API。
- [ ] 将每个允许实现用真实 SDK 编成独立测试目标：先写入文件，清后确减；同等非空写尝试受限；只清理与关闭后重新落盘；内存可读；多 owner/自定义后端/并发队列/排除/身份变化/迟回调准确拒绝。旧断言真实失败后再实现兼容。
- [ ] QQ 同步支路和异步支路均证明完成/队列/资源关联才准入；两者有一支未知就保持该能力拒绝，不套百度四类现代契约。
- [ ] YY/PIN 只操作已证明缓存 owner，事务型数据库走 SDK 本身操作。Swift SDK 只允许来源可核的桥接；单有导出符号不能调用。
- [ ] 首批已开启 APP 与兼容历史样本采用同一引擎；新 APP 不新增名字白名单。新版补证要核实际写尝试和目标磁盘变化，不把 API 命中算效果。

**产出门：** 一个契约在多个 APP 复用，支持清存量与限写的每项均有真实 SDK 和宿主效果；能力缺口独立记录，不为准确拒绝算作功能完成。

## 任务 4：全部大占用私有资源、日志与必要保持

**文件职责：**

- 扩充 `AxsCacheKeeperCleanupRules.h/.m`：保留统一用途决定，允许规则依赖与严格实现适用条件；不扩大通用标准目录授权。
- 新增 `AxsCacheKeeperBaiduAction.h/.m`：下载管理器本地副本事务；`AxsCacheKeeperQQResourceAction.h/.m`：独立文稿资源 owner；`AxsCacheKeeperSwiftgramAction.h/.m`：已证合法桥接的有限媒体事务。没有真实 ABI/保留集合时不实现调用。
- 按需新增 `AxsCacheKeeperLogContract.h/.m`：writer/轮转契约核验，实际规则仍注册到 CleanupRules。
- 修改 `Cleaner.m`、`Scanner.m`、现有 OperationInfo/Receipts/Diagnostics 接入；扩充 `tests/alog_version_tests.m`、`tests/cache_mode_behavior_tests.m` 与真实文件/事务用例。
- `AxsCacheKeeperResourceLayout.h` / Capacity 仅扩已有证据支持的分类；结构分类不授删除。

**共用动作接口：** 私有动作对象使用 `-initWithContextProvider:observer:`、`-requestCleanup`、`-refreshWithCompletion:`、`-expireBackgroundTime`；请求与回调绑定同 installation/configuration/contract/owner/operation 代际。具体宿主 selector/Swift bridge 只能从实际证据填写，本计划不创造宿主接口。返回区分 queued、submitted、apiCompleted、effectVerified、cancelledBeforeSubmission、interruptedUnknown、failed；已提交不可取消动作不得报已取消。

- [ ] 仅对私有混合资源事务建立必要的资源、消费者/别名、原件、索引、重取来源及保留矩阵；优先复用宿主已有保留策略与事务，避免插件重造全部内部知识。标准缓存不适用此门。
- [ ] 百度占用主体：先解析已采 BDPanCacheManageService 的缓存范围和高层清理子操作，验证其与容量子树关系；不能先把约 6.92 GB 全部当可删缓存或下载。只有明确属于用户下载时，另做选择性的“移除本地副本”操作，保留下载记录、云端对象、上传中/唯一副本和排除，不能裸删 Documents。
- [ ] QQ 图片与文稿分开：原件/聊天/附件/草稿/离线保存/恢复索引必须保留；图片不能授权 Documents 全树。
- [ ] 抖音41.2 的日志与约 0.51 GB 未知子树分开；ready/prepare/模块名、所有 writer/映射关闭、成熟、重开新日志、升级失配均真实回归。不只增加版本字符串；Support 由 owner 子契约治理。
- [ ] Swiftgram：优先核宿主 StorageUsageScreen 调用的 engine.resources.clearStorage、已有缓存容量与保留时长，确认合法桥接、账户 owner、作用范围和原配置恢复。该入口会删除所选本地完整媒体，首批排除全局 misc、携带必要本地项排除；宿主先更缓存索引后做文件移除，需完成后重计量，不能伪称跨步骤原子成功。合成缩略图/逐表示手工重建退出主线，只有确需新增派生重建时才独立研究。
- [ ] 将同族能力扩到汽水音乐、TikTok、抖音极速版、淘宝、红果短剧、移动云盘、小红书等已开启 APP；美团、轻悦时光、全能签+、喜马拉雅、输入法/豆包/地图等关闭 APP 列用途与可复用候选，不执行资源删除。
- [ ] 每项实际文件/事务测试覆盖失败、半完成、队列交错、关闭/排除、资源与安装变化、取消、保留唯一副本、共享 owner 和迟回调；三轮恢复证明可用，数据库/原件不变。运行 `python tests/run_alog_version_tests.py`、`python tests/run_cache_mode_behavior_tests.py` 及新增事务入口，纳入 native 总入口。

**产出门：** 已要求的百度/QQ/抖音/Swiftgram 私有能力真正实现并保持数据；其他资源按同一全量队列推进，明确阻断不冒称完成。

## 任务 5：实际空间效果与独占物理归因可行性

**文件职责：**

- 修改 `AxsCacheKeeperImageEffect.h`、`AxsCacheKeeperReleaseEvidence.c/.h`、Receipts、Capacity 与展示：沿用现有逻辑移除/最后链接/卷观测，增加同范围分阶段关联。
- 新增 `AxsCacheKeeperResourceEffect.h/.m`：owner 已授权范围的 before/produced/after/reused/disabledRestored 观察，来源不齐明确失败。
- `AxsCacheKeeperPhysicalEvidence.h/.m` 仅在合法系统接口被证明能取得共享块/快照/持有关系后创建；无接口不得做假实现。
- 扩充 `tests/release_evidence_tests.c`、`tests/release_receipt_tests.m`、`tests/test_owner_snapshot.py` 及资源效果/文件系统实际用例。

**效果接口：** `AxsCacheKeeperResourceEffect` 以当前匿名 operationID 和阶段输入，输出逻辑/已分配/实际新增/实际移除的观测及完整性；只比较同安装、同 owner 范围、完整且无身份变化的数据。不将尺寸差直接命名独占物理回收。

- [ ] 对用户 17:20 截图反馈建受控窗口：使用前→产生后→清后→再使用→关闭恢复，同时核 APP 总占用更新时间。目标缓存清后实际下降；同负载非空写尝试下新增受控；关闭实际写盘恢复。
- [ ] APP 总量分二进制、必要数据、已治理、待识别与共享；父子/跨根重叠不相加，旧快照不当实时量。不能以总量减少证明所有必要数据无损，也不能用必要数据增长回避未受控缓存。
- [ ] 开发侧调查 iOS16–17/RootHide 的合法物理观测接口；若无法证明 APFS 克隆/快照/范围外持有，就输出明确 unsupported/notMeasured 和缺哪个可用接口，关闭无收益的重复测量任务，严格物理目标仍列未完成。
- [ ] 实测普通文件、外部硬链接、克隆/快照、FD 持有、延迟回收、并发写入、观察中替换/权限失败；无环境的分支明确未执行。禁止清快照或扩大权限以制造效果。
- [ ] 运行 `python tests/run_release_evidence_tests.py`、`python tests/run_release_receipt_tests.py`、`python tests/test_owner_snapshot.py`；目标文件系统验收另列，不用 Windows 文件系统代替 APFS。

**产出门：** 每次清理有目标范围真实减少，限写有非空实际尝试且新增受控；逻辑空间与严格物理归因分开。用户 APP 总占用增长有可核原因和未覆盖资源方案。

## 任务 6：整体回归、同提交构建和集中真机验收

**范围：** `tests/run_native_tests.py`、`tests/ui/project.yml`、`tests/run_ui_tests.py`、`tests/run_capacity_page_tests.py`、`.github/workflows/build.yml`、`Makefile`、`scripts/verify_deb.py`、`scripts/generate_release_notes.py`。仅为接入真实新增目标修改，不套用模板改变身份/SDK/RootHide。

- [ ] 检查所有模块共用同配置、规则/范围代际和回执 schema；没有第二事实源、隐藏 fallback、未来源校验的第三方测试二进制或过度注入。
- [ ] 本地适用的真实 C/文件/Python/对象编译先运行，结果分 PASS/FAIL/UNAVAILABLE；新功能必须有真实行为测试，不用静态替身冒充。测试单命令≤60秒，既有编排组预算分别管理。
- [ ] 整体跑 `python tests/run_native_tests.py --output tmp/all-app-native`、`python tests/run_ui_tests.py`、`python tests/run_capacity_page_tests.py`；Windows 缺执行环境保留 UNAVAILABLE，同提交 macOS CI 完成所有真实业务组/SDK/UIKit。新增组必须纳入正式 runner。
- [ ] 对新 APP 无名单发现、升级/同版本换 build/重启、关闭/排除、权限拒绝、取消、迟回调、多 owner/共享、保存失败、未知资源、搜索/PDF/历史和性能执行回归。
- [ ] 检查 diff、忽略项、BK 备份、内存记录、用户无关文件；整组统一正常提交推送。沿用既有授权，不强推、不重置、不提交 AGENTS/SSH 等无关用户修改。
- [ ] 跟进同 SHA 全部 Actions 到完成：原生、真实 SDK/UIKit、容量页、SDK16.5 RootHide arm64/arm64e Theos；失败修完整关联问题后复验，不让用户装失败包。
- [ ] 下载仅一个最终成功 deb 至 `tmp/all-app-release`，运行 `python scripts/verify_deb.py tmp/all-app-release`；核标签/源码/资产 digest、元数据、作者目目、过滤器、脚本、依赖和排除测试/BK/tmp/memory/私有档案。
- [ ] `scripts/generate_release_notes.py` 按上一可达发布标签的真实提交生成完整版本中文日志，与 Release/CHANGELOG 附件一致。只提供成功 Release/deb 下载。
- [ ] 用户集中步骤：安装成功包→保留配置→18 个已开启 APP 正常使用→每个可限写契约选代表资源执行只清理/限制/自动/关闭→正常重开验证业务→一次导出统一 JSON；有异常附 APP/动作。开发侧做来源、空间和恢复判定，不要求用户逐个查目录或制造竞态。
- [ ] 真机 iOS16、iOS17 的安装/注入/保持/卸载恢复独立验收；当前只有 iOS16.2，不补假 iOS17 完成。卸载在用户安排的独立步骤执行，保留配置和旧权限恢复证据。

**交付门：** 新功能、真实测试、整体审查、同 SHA 编译、验 deb 全闭合才交包。最终报告固定说明本次修复/实际空间效果、原方案剩余、最终能力缺口；未实现/未触发/拒绝/确认失败不能混用。

## 自检与当前状态

- [x] 最新 198.1 原始报告、全 133 项/296 登记/1132 根和 61 历史 SDK 样本核对，保存本地逐项台账。
- [x] 其他已开启 13 个缺新版宿主来源、汽水音乐真实删除、百度大文稿范围、空间增长反馈纳入规格与实施任务。
- [x] 各任务明确现有/新增文件、单一事实来源、输入/输出、真实行为验收与阻断；不把现有功能重新列待实现。
- [ ] 执行任务 0–6（按上方修订次序）。**已开始任务 0 的产品实现；新包空间效果尚未完成，不能按文档完成判产品完成。**
