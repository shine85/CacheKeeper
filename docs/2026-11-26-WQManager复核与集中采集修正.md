# WQManager 复核与集中采集修正

复核固定上游提交 `42d65b4142fdf8884f04c6623575b2d944589c86`（main 查询时返回，提交时间 2026-11-18）。仅阅读源码，没有运行上游工程、安装 APP 或连接手机。本文新增，无旧版可备份；不复制上游实现。

## 结论

WQManager 对容器枚举、分阶段测量、按占用定位和操作状态展示有参考价值，但它没有这五个 APP 的私有缓存目录规则。标准相对目录有共性，不代表整个私有路径、资源用途和删除条件跨版本不变，更不代表“大文件=缓存”。

- [SafetyPolicy:12–14、78](https://github.com/hseons/WQManager/blob/42d65b4142fdf8884f04c6623575b2d944589c86/WQManager/WQManager/WQMSafetyPolicy.m#L12)：缓存清理白名单精确限于 `Library/Caches` 与 `tmp`。
- [CacheService:224–225](https://github.com/hseons/WQManager/blob/42d65b4142fdf8884f04c6623575b2d944589c86/WQManager/WQManager/WQMCacheService.m#L224)：实际也只扫描这两个目标；没有 Gurd、QQ Documents、百度主体下载/同步或 Swiftgram 共享媒体的专用策略。
- [CacheService:102](https://github.com/hseons/WQManager/blob/42d65b4142fdf8884f04c6623575b2d944589c86/WQManager/WQManager/WQMCacheService.m#L102) 和 [CacheSafety:57](https://github.com/hseons/WQManager/blob/42d65b4142fdf8884f04c6623575b2d944589c86/WQManager/WQManager/WQCacheSafety.h#L57)：路径归属、容器 dev/inode/Bundle ID、目标身份复核值得参考；CacheKeeper 已有 cursor/FD 身份和严格资源边界，不再另造访问层。
- [AppScanner:155–190](https://github.com/hseons/WQManager/blob/42d65b4142fdf8884f04c6623575b2d944589c86/WQManager/WQManager/WQMAppScanner.m#L155)：聊天库、视频、下载等路径是 DEBUG 模拟器稀疏文件夹具；[CacheService:159](https://github.com/hseons/WQManager/blob/42d65b4142fdf8884f04c6623575b2d944589c86/WQManager/WQManager/WQMCacheService.m#L159) 的 APP 容量也是 UI fixture，不能当真实设备证据。
- [CacheService.h:35](https://github.com/hseons/WQManager/blob/42d65b4142fdf8884f04c6623575b2d944589c86/WQManager/WQManager/WQMCacheService.h#L35)：清理接口没有持续 writer 限制。源码中的访问准备和恢复机制不是禁止缓存方案，本项目不移植其访问技术。

## 本机已有证据能直接排除的方向

源为 `packages/采集报告/综合.json`，SHA256 `816ad8fc4b8e63639c944723dd237eb8d41bc2d5250ba81742070cea04b075fa`，报告于 2026-11-26 00:22:43 +08 生成，插件 214.1。以下全部取同一 `capacityMeasurement`，不混用旧 scan rows；全批 partial 的唯一错误另有记录，这些选定根自身 complete。测量窗口非原子，数值是逻辑大小，不是可回收或独占物理字节。

| APP | 主容器逻辑字节 | 主容器重点 | 主容器 `Caches+tmp` 逻辑字节 | 结论 |
|---|---:|---|---:|---|
| QQ | 1,613,586,347 | Documents 1,607,124,689 | 0 | 标准缓存清理不覆盖主体占用 |
| 百度网盘 | 8,746,457,926 | Documents 8,721,170,944 | 564,592 | 必须区分下载、未同步资源和可重建缓存 |
| 京东 | 285,345,274 | Documents 271,134,342 | 5,415,225 | 只适配图片缓存可能覆盖不到主体 |
| 抖音 | 766,056,395 | Library/Application Support 459,722,720 | 1,273,587 | 该分类仍不能直接等同 Gurd 候选集 |
| Swiftgram | 141,415,678 | 共享容器另有 1,961,930,804 | 103,669 | 主容器两个标准目录不能代表共享媒体资源 |

root id 依次为 QQ 48、百度 90、京东 73、抖音 239、Swiftgram 主 104/共享 1098；分类节点只输出标准语义，不导出私人目录或文件名。QQ/百度/京东大头已在现有报告，不需要为了找到这些一级分类再重扫全机。更细资源用途仍须宿主契约，不能据此删除 Documents 或共享容器。

## 借鉴与不照搬

1. **按大占用确定补证优先级。**复用 `AxsCacheKeeperCapacity.m` 的节点和 `AxsCacheKeeperStorageInventory.m` 队列，把“大头→已知类别→缺失用途”统一汇总。上游 [FileCatalog:26–55](https://github.com/hseons/WQManager/blob/42d65b4142fdf8884f04c6623575b2d944589c86/WQManager/WQManager/WQMFileCatalog.m#L26) 的有界排名只代表已访问部分，不当全局完整排名。
2. **完整性和新鲜度随结果一起走。**上游 [AppScanner:391](https://github.com/hseons/WQManager/blob/42d65b4142fdf8884f04c6623575b2d944589c86/WQManager/WQManager/WQMAppScanner.m#L391) 的首轮轻扫/后轮慢扫可参考；不复制无限预算或把缓存 partial 重放成 Known 的路径（[SpaceLens:511](https://github.com/hseons/WQManager/blob/42d65b4142fdf8884f04c6623575b2d944589c86/WQManager/WQManager/WQMSpaceLensViewController.m#L511)）。CacheKeeper 已有断点，不重建第二扫描器。
3. **阶段结束与证据有效分开。**参考 [BackupQueue:35](https://github.com/hseons/WQManager/blob/42d65b4142fdf8884f04c6623575b2d944589c86/WQManager/WQManager/WQMBackupQueue.m#L35) 的 interrupted 记录，继续复用本项目 fresh/historical 与 SHA 父链。导出生成时间不能证明各组件刚运行。
4. **不移植释放量口径。**上游缓存清理路径的 [`freed`](https://github.com/hseons/WQManager/blob/42d65b4142fdf8884f04c6623575b2d944589c86/WQManager/WQManager/WQAccess.m#L2413) 为成功 unlink 项的逻辑大小累计，不能等同独占物理释放；CacheKeeper 保持 physicalUniqueBytes/reclaimableBytes 未测，不用总容量差冒充效果。

仓库声明 GPL-3.0-or-later，当前仅参考设计且不复制代码。若后续要复制实现，需另行核对并保留原许可、来源和修改声明。

## 为一次集中采集改正工具

新增离线诊断输入接到现有 `--prepare-session`，同一包关联静态身份、保存容量与组件回执：

- 五 APP 各自主/共享/扩展根、Documents/Library/Caches/tmp/Application Support 已知类别；partial、缺根、未知均明确保留。
- 各组件 producer 版本、实际保存时间及与前报告比较；`unchanged` 与 `changed` 仅表示证据变化，不直接给“本轮新鲜/有效”盖章。
- 静态版本/build 与诊断不符时标失配；未输出镜像身份的诊断不能视为 SDK 身份验证。
- 仅固定字段与匿名节点，未复制私人路径、会话、消息、文件内容或原始二进制。

## 手机会话的就绪条件与当前阻塞

现有 `runtime_image_evidence.js:137` 只采镜像/少量方法归属，不采五 APP 的活 owner、真实资源范围、队列和写入结果；`device_collection_batch.py` 中 adapter 名称不等于执行器。因此不能要求用户打开五个 APP 后就宣称能采齐。

下一次集中会话开始前，每个必需字段都必须有实际实现与本地失败/成功输出验证；先保存同版本基线，再要求本轮新的组件 event/epoch，末尾自动核对覆盖和新旧。如果缺的是工具能力，在开发侧修，不反复让用户操作。效果验收需同一会话内有匹配的前后阶段；一次部署不等于一次快照能够证明恢复或全部 writer。

2026-11-26 再查原始任务终态：两段子任务分别在 02:21:09Z、02:21:12Z 被终止，错误为 `Potentially unintended activity` / `misalignment_policy_violation`，未指明具体触发命令。因此此前将其概括成“全部运行时操作都被禁止”过于宽泛；该错误也不构成改走另一通道继续被拒任务的许可。当前工具没有提供该拦截的复核或恢复入口。被拒任务不重试，完整手机执行器与五 APP 真实适配仍未完成，不能承诺 2026-11-26 下午已具备完整采集能力，也不应让用户为尚不可用的执行器提前重连 SSH。

再次核对现有能力：`AxsCacheKeeperDiagnosticChannel.h` 限定 Preferences/SpringBoard HELLO；`AxsCacheKeeperHostEvidence.h` 是既有、未经身份认证的有限技术自报告；`Cleaner.m` 的 network probe 会刷新缓存配置，不能当成纯观察。总诊断只汇总保存记录，没有五 APP 统一会话驱动协议。不能把这些入口拼接并宣称替代完整取证已经可用。

同份214.1报告的 `hostAutomatic` 也显示 QQ/京东/Swiftgram producer=211.1、百度=202.1、抖音=214.1；各项保存时自报配置可读、上次发布成功，但这些不是当前进程的实时状态。`hostObserved` 五项均缺失。由此确定下一次会话必须首先证明本轮加载版本、配置读取与保存链路；不能把旧producer直接归为未注入、共享权限失败或SDK不支持。

完整采集工具的开发验收顺序：

1. **本轮宿主与保存链路。**对各目标获得本轮请求对应的新回执，核对安装身份、实际加载插件版本、配置代次与发布结果。旧记录、未响应、失败均分开；失败留在该阶段定位，不让用户重复后续动作。
2. **占用到用途的对应关系。**复用现有容量基线，针对QQ/百度/京东Documents、Swiftgram共享资源、抖音Support内相应资源建立技术归属；不重复全机静态SDK清单，不读取用户内容，不用目录名授予删除权。
3. **各APP契约证据。**每个缺失项必须对应真实实现和输出，不以adapter名称或pending队列代替。Gurd需一致候选/保留规则/相关writer保护；其余需资源owner、必要数据保留、队列与清理完成语义。
4. **同会话多阶段结果。**正常负载、非空写入、清理前后与关闭恢复分别有观测；未触发不能记成功。没有已证可删范围时不执行清理，前后完整观察和保留项验证不能用传输成功替代。
5. **结束前自动核验。**按目标逐项判定足以进入修复、缺证据或明确失败；断线仅续未完成项，同一包回收，保留每阶段来源。只有五APP必需模块实现并通过开发侧验证，才约用户集中手机操作。

这五项是完整工具的待实现/待验证条件，不是本轮已完成能力；本轮未新增采集协议、响应器、手机执行器或设备任务。

## 已落地工具与验证

`scripts/device_collection_diagnostics.py` 已接现有入口，完成上文离线分析。它区分完整组件内容变化与 `timestampComparedToBaseline`，实际五 APP 的 scan 时间均为 unchanged；百度图片回执 producer 为 202.1、京东为 211.1。缺根/partial/notMeasured 保留，旧 cleanup 安装版本不匹配标 mismatch；不要求为了生成包而先重跑 APP。

开发侧实际跑诊断9+session10+CLI5+resume9共33项全部通过，独立诊断/CLI14项通过；只读对照原报告数值与固定源码引用通过。未运行 WQManager 工程或真机清理测试。新版包为 `packages/采集报告/集中准备/20261126-五APP占用与回执分析-v2.zip`，5,642 字节，SHA256 `1283cff54542e3925d4deda59310c0fb91b4f51e0dced29fb03d7ce906a60874`；旧v1为本轮中间产物，后续使用v2。

上游原始源码ZIP及来源摘要留在 `packages/research/wqm-42d65b4142fd/`，未执行也未纳入产品构建。源ZIP 2,833,211B/SHA256 `407688748a47ce6336f80f20c269b30a23c0965f72c5437c718c45e989b5e175`。本轮没有提交推送、新编包或手机操作；本地工具完成不能替代五 APP 适配完成。
