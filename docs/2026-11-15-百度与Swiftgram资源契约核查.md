# 百度与 Swiftgram 资源契约核查

日期：2026-11-15。本报告接续[核心续修与真机验收](2026-11-14-核心续修与真机验收.md)，记录当前授权 iPhone 的定向技术采证。仅读取安装镜像的未加密代码与元数据，不读取账号、消息或用户文件正文，不调用资源删除接口。

## 已确认的进展与结论

百度转换函数的 67 个外部目标、四个接收类的 173 条方法及模型 7 个字段已完成静态归属。Swift UI 两个字段表已找到实际实例类；已安装 Postbox 镜像也证实两个删除入口的取消与结果回执限制。此前“59 个转换代码缺口、3 个固定 slot、UI owner 未归属”的缺口已经收敛，不能继续当作当前阻塞。

**私有资源自动删除仍未开放。** 当前没有任何候选动作同时具备存活 owner、正确 ABI 与队列、完整保留集合、有效恢复来源、逐项结果、取消及后置一致性验证。静态识别不授予删除权限，也没有产生清理或释放空间的实测结果。

## 证据范围

| 样本 | 已确认身份 |
| --- | --- |
| 百度网盘主程序 | 13.37.5 / build 13.37.5.10；UUID `b2b9d30a-1caf-31b4-82ca-c776e7eb2ba1`；446,666,416 字节 |
| Swiftgram UI | 13.0 / build 319；TelegramUIFramework UUID `3c18e9ea-5c15-31a4-93b0-f3899d79bae6`；120,453,520 字节 |
| Swiftgram Postbox | 同一安装版本；UUID `dc7f4a8f-aa9b-3319-bbc7-5e4e4f264e63`；4,481,696 字节；SHA256 `7602d9b668bef8088e115e72c52bfce17b6ff9f1afe17d1336688d6ec7e4ce01` |

本轮 v1–v13 的逐批验证通过：591 个新原始范围、249,243 字节、223 次重叠字节比较；字节数包含重叠。另有 3 次限定元数据扫描只留下匹配位置和 word count，不计入原始字节 SHA 证明。本轮没有重复验证此前 557 个范围，也没有重做全 APP 盘点。

各批分别检查自己的头部、首末请求与文件身份边界，按真实 load commands 限制段范围并排除加密区。静态证据随安装镜像身份变化失效；磁盘身份稳定不能代替活进程映射与对象生命周期验证。

本地完整报告及权威收据位于 `tmp/capability-gap-20261115/`：`resource-report.md`、`resource-batch-verification-final.json`、`resource-baidu-verified.json`、`resource-class-chain-verified.json`、`resource-baidu-query-dsl-verified.json`、`resource-swift-ui-owner-verified.json`、`resource-postbox-delete-verified.json`。原始技术范围和设备连接资料只保留本地，不进入源码或 deb。

## 百度：查询边界已经明确

转换函数共 252 条指令、130 个外部调用点、67 个不同目标：54 个 selector 目标、3 个短 helper、10 个调用目标对应 6 个真实 lazy imports。真实接收类包括 `TransToCacheFileMetaModel`、`TransFileListDAO`、`TransFileStateFetcher`、`BDPanThumbnailCacheCleaner`；其方法数分别为 28、86、47、12。

两个固定 class slots 对应 `CBModule`、`BDPanDownloadConfig`，协议为 `BDPanCloudFileServiceProtocol`。实际服务链为 `sharedModule → serviceWithProtocol: → getCacheFileMetaWithServerFullPath:`。转换保留下载来源、资源、任务和状态字段；`isQuery` 参数名、URL 字段存在或 setter 可见都不能证明调用无副作用或资源可恢复。

`+[TransFileListDAO hasTransFileWithBlockMD5List:status:fileNameArray:usinDB:]` 的类型编码为 `B48@0:8@16@24@32@40`：status 是对象参数，传入的零值应解释为 **nil**，不是业务状态枚举 0。

实际查询 block 调用 `whereClauseWithBlockMD5List:fileNameArry:statusArry:`，其 DSL 构造已由真实指令、selector、binding 与 helper 核实：

- `isDirectory` 使用 `SQL_EQ(0)`；`transType` 使用 `SQL_NOT_IN([0,4])`，以 `SQL_AND` 合并。
- status 的 `count` 为零时，只跳过可选的 `transStatus SQL_IN` 条件，不跳过前述基本筛选。
- 字符串版方法的 `isdir = 0`、`trans_type <> 0` 与 `trans_type <> 4` 仅作交叉佐证，不属于本次观察到的实际调用链。

因此，status=nil 不代表覆盖全部引用。尚未执行 DSL 或数据库，也没有为类型 0/4 猜测业务名称。该 BOOL 接口没有显式错误 out 参数，目前不能可靠区分“未命中”与数据库失败，更不能把 false 当作删除许可。三个通用构造 helper 的末端和 DSL getter 内部实现未继续展开；这些缺口不改变当前不可接入删除的判断。

既有删除入口 `deleteLocalFileTempWithCacheFileMeta:` 实际尝试删除 `localFullPath` 和附加 `.tmp`，两个文件删除均忽略错误与返回值，不是只清临时文件。任务删除和全局清理另有更广下游副作用，不能当作有逐项排除与结果验证的默认回收接口。

## Swiftgram：owner 静态归属与删除限制

真实 fixup 页链将两个字段表归属到 `TelegramUI.AccountContextImpl`（实例大小 952，69 字段）和 `StorageUsageScreen.StorageUsageScreen`（实例大小 1176，3 字段）。这补齐了磁盘布局的归属，仍没有进程内存活的 AccountContext→Account/Engine→Resources/Postbox→MediaBox 链。16 字节 UI context 不能直接当单个 NSObject，lazy resources 字段也不能直接按静态 offset 调用。

已安装 Postbox 的 progress 与 withResult 两个 generator 均通过 `SwiftSignalKit.Queue.async` 排队并返回 `EmptyDisposable`：取消订阅不会取消已排队的删除。实际 `_unlink` 的 6 个调用点均在下一条指令覆盖返回值，没有检查成功与失败；进度、completion 和 removedIds 不能当作逐项文件删除成功回执。

固定 13.0 源码另外佐证：在用资源可能被跳过但进度仍推进，removedIds 记录尝试而非已核实成功。clearStorage 的 `.misc` 全局路径还会清整目录并重置索引。后两项属于固定源码证据，不能冒充本机全部分支均已反编译或运行验证。

## 剩余完成条件

### 本轮五个查询入口的增量核查

本轮又完成两批安装镜像只读采证，共 55 段、6004 字节；每批身份、长度与 SHA 校验通过。新增确认 `blockListMd5`、`localPath`、`transId` 字段，补齐两个查询尾段，并观察到 17 个参数 helper 返回。外部资源的空 MD5 列表会跳过可选 IN 条件，不能把它当成必然无匹配。8 个 CFString 正文、部分 selector 及错误/返回语义仍未闭合。

这些是静态证据：没有调用 DAO、读取数据库行或验证删除恢复。运行 owner/队列、完整保留集合和恢复来源仍是独立缺口。新增记录位于本地 `tmp/capability-gap-20261115/resource-next-readonly-baidu-report.md`，两批收据及解析结果保留备查，不进入 deb。前文 v1–v13 的 591 个范围与本轮 55 个范围分别记录，不能把解码指令数当作独立读取范围数。

### 更多 SDK 的产生限制

固定 SDWebImage 5.19.1 接口资料显示：`maxDiskSize=0` 表示不限量，`maxDiskAge=0` 会在过期检查中清缓存，均不能作为禁写开关；`toDisk:NO` 虽跳过该次磁盘缓存，却会改变 completion 时序。现有安装清单仅识别到 18 个嵌入框架候选，未核实每个安装实现、真实实例及可重取/离线保留契约，因此没有启用新的 SDWebImage 控制。

已安装 Swiftgram Postbox 的 `setMaxStoreTimes` 是存量保留和清理策略入口，不能解释为无副作用的通用禁写开关。WebKit 非持久存储会同时改变 Cookies 与站点数据语义，也不作为只限制磁盘缓存的替代。当前产品减少产生的能力仍限于既有 `NSURLCache` 磁盘容量策略。

### 开放动作的必要条件

| 范围 | 开放动作前必须补齐 |
| --- | --- |
| 运行对象与调用 | 活 owner、生命周期、真实 ABI、队列和事务边界；不能按静态偏移强转调用 |
| 保留与共享影响 | 完整资源/副本/索引映射；草稿、上传、未发送、唯一副本、用户排除、跨账号及扩展共享集合 |
| 恢复与结果 | 仍有效的重取来源及权限、逐项成功/失败、取消或补偿、文件和索引后置一致性 |
| 设备验收 | 获准测试范围的三轮回收—重新获取—展示恢复；登录、下载记录及必要数据保持 |

开发侧下一步是设计受限的被动观测，复用统一容器发现和安装变化链，只记录镜像身份、类型、状态、计数和缺口。能力诊断与证据失效接入仍需产品实现和测试；本报告没有新增观测 hook 或诊断状态。安装/启用观测、调用私有接口和删除恢复实验需要对应的具体设备授权，当前只读授权不包含这些动作。

新增或升级 APP 由程序和开发侧做增量核验；不要求用户再扫全机、查目录或准备同版本 IPA。未知资源继续保留，标准缓存的闭合硬链接修复见[认证路径与闭合硬链接续修](2026-11-15-认证路径与闭合硬链接续修.md)，两者不共用删除授权。
