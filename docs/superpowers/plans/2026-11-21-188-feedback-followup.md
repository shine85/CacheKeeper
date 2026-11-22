# 188.1 真机反馈整组续修

目标：依据 2026-11-21 新增八份手机报告，补齐四重点 APP 的安装版本资源契约与三模式证据，并明确全部 APP 的清理边界。


当前执行边界（2026-11-22 23:20）：四 APP 的只读采集已封存。以下历史补采步骤仅保留过程证据，不再执行。当前整组交付范围为清理历史/状态来源、Swiftgram 三类派生占用识别、百度首次 SDK 拒绝诊断，以及关联原生/UIKit 回归入口。四 APP 未证实私有资源保持保护；不以本次交付宣称私有删除与限写全部适配。开发侧本地可执行验证和云端实际 Foundation/UIKit/Theos/deb 完成后，才交付新包；独立 iOS CLI 受加载保护失败限制，原结果保留，临时目录已单独确认清理。

## 已核实事实

- 报告位于本地忽略目录 packages/采集报告，共八份，环境均为 0.7.2-188.1 / iOS 16.2。按 generatedAt 排序，不依文件名推断先后。
- 用户在安装 188.1 后采集，八份原始 JSON 均 environment.pluginVersion=188.1、collection.mode=savedRecords/rescanned=false。三模式配置确实保存，对应字段仍带 179.2 历史回执，不能据此断言当时宿主加载旧包或验证新版限写。后两份 QQ、抖音、Swiftgram 已有 188.1 新回执，百度尚无新记录。
- 新轮和取消历史独立、游标关闭已观察。每轮 Apple Music 一个 Group 根 entryStat/EPERM；一次 Swiftgram Group 枚举 identityChanged，后轮未再记录同错误，不能据此确认根因消除。均须保持不完整标记。
- 清理累计增长但后续空轮覆盖有效删除明细；本轮需要修正证据保留，不能把旧证据移植给新轮。
- 当前已授权逐 APP 只读 SSH，2026-11-22 用户启动 BAT 常驻连接，v2 真机八任务复用通过；16:20 已一次重启加载 v3 内存通道，继续使用同一 VPN 连接；前一夜不可连的限制已结束。密码仅本地隐藏输入，不逐任务重新认证。

## 实现方案与不变量

沿用同一回执写入器和同一清理引擎。在同一原子回执中保留独立最近有效清理及有界轮次历史，当前轮仍如实记录零操作、失败和取消。每条历史绑定自己的 roundID、计数、时间、模式、插件版本及公开安装版本；不导出私有路径或安装指纹，不把累计增长称为物理释放。

四 APP 的私有删除适配只在同一安装构建的 owner、保留引用、重取、执行与恢复契约齐备时实施。全部 APP 的规则依据平台缓存、已验证资源、精确保留和未知资源四类说明，升级撤销不兼容删除权限但保留保护。

## 任务与验收

- [x] 八份报告按真实时间核对配置、报告环境与历史回执来源版本、扫描终态和清理增量。
- [ ] 修复空轮覆盖：当前轮、最近有效清理、最多 16 条终态历史相互独立；同轮幂等、失败重试、取消和重启恢复保持。测试证明有效轮之后的空轮不丢证据、错误跨轮证据拒绝、历史字段严格校验且导出脱敏。
- [ ] 核查四 APP：先 QQ 已准备方法表与固定代码窗口；百度确认当前图片回执更新链路和准入能力；抖音核实 41.2.0 Support/ALog；Swiftgram核实共享原件、派生项、消费者和 writer。每轮保存独立结果和收尾状态。
- [ ] 完成全部 APP 清理规则说明、专属例外及版本/模式状态展示，保留真实未知项。
- [ ] 整组本地可执行验证、独立代码审查后统一提交推送；同提交云端原生/UIKit/Theos及 deb 检查成功后交付。任何仍缺设备契约的项目明确保持开放。

本轮不更换包身份、iOS 16–17、SDK16.5 或 RootHide 打包方式；不强推，不提交用户无关改动、BK/tmp/memory/设备报告。

## 续接进度（2026-11-21 23:15，北京时间）

- 清理历史整组源码已实现并独立终审：共用原相对路径语法；pending/落盘首个终态冻结；终态计数增长入队前拒绝，避免阻塞后续合法轮。真实 job 退役回归与两个精确反例已接入。最新 3 个 ARM64 对象编译退出 0；Foundation 行为在本机不可执行，不能勾选整项通过。上一成功 CI 的该测试组用时 8.726 秒，新 300 秒组预算保留，按下一实际日志核验。
- 百度旧通用拦截错误误分类已从 wrongSignature 修正为 interceptionFailed，并有生产函数精确反例通过。最新固定 64 字节代码入口双读一致、身份/非加密范围通过，SSH 0/完整收尾；本地工具 5 项协议测试通过。保存/恢复 LR 的入口形态已解码，具体拦截原因与引用/重取契约仍未闭环。
- 抖音 ALog 元数据轮已经完成：211 项，70 ready 候选、14 prepare、84 unknown、43 other，身份稳定、未截断，SSH 0/完整收尾。不得重复补采或沿用旧“尚未运行”记录；41.2.0 删除规则仍未开放。
- QQ 有限补证模块基于真实 25 方法/22 窗，新增独立 168 字节前后双读、最多两个合法 GOT 槽；旧窗身份校验实读 11,152 字节另计。14 项本地测试通过，模拟 Frida 依赖运行不等于真机 ABI 通过。正在复用既有单 APP 认证、服务器、预算与收尾接入，不重做全量观察。
- 新增诊断测试后，完整 Python discover 揭示编排仍断言 3 项而实际 4 项；已修正为 4，完整复跑 66 项：59 通过、7 项因 Windows 不支持 POSIX 跳过，用时 38.489 秒。原生入口首轮未提供 Zig 路径为 6 PASS / 45 UNAVAILABLE；补入现有 Zig 后完整复跑为 9 PASS / 42 UNAVAILABLE / 0 FAIL，51 组。尚无本轮提交/推送、Theos 链接、新 deb 或四 APP 三模式真机闭环。

## 续接核对（2026-11-21 23:30，北京时间）

- 当前工作树基线 d341c68，保留整组未提交修复和用户无关文件。原会话确认目标仍包括四 APP 安装版本契约、三模式实际效果与全部 APP 清理规则。
- 百度同 UUID 的较早回执曾 queryCoverage=installed / objcObserved=0，最新拦截失败不能证明此入口永久不可 hook。下一补证须核运行 IMP 与文件窗、固定 BL helper，以及 Frida 实际失败阶段；不跳过入口、不强制 hook。
- QQ 新 transport 保留根控制器认证、服务器、预算与收尾；正常前台确认，不自动设置 split_view_confirmed。有限 probe complete 与整个资源契约 partial 分别报告；尚未开启本次 SSH。
- ALog 现有 211 项清单仅证明旧命名候选范围，缺成熟时间、内容分类、自然写入/轮转、全部 writer 退出与稳定清单；41.2.0/412021 继续保留。将来契约须绑定构建与安装身份，不能仅增加版本字符串。
- Swiftgram setter 参数搬运已离线核实，但活 owner、具体生成器、原件/派生关联、消费者和索引未闭合。合成缩略图测试通过不能替代安装 Swift ABI 或共享媒体删除授权。

## QQ 首次有限补证与开发环境（2026-11-21 23:48，北京时间）

- QQ 工具通过独立终审及本地 11 项 transport、14 项 probe、5 项实际 adapter 模型测试。合法 rejected/changed 回执保留在 targetAttempts；未验证基线仍拒绝入 accepted targets，原 finalizer 不变。
- 233638-949549 真机轮已完成收尾：顶层 failed，SSH 0、cleanupConfirmed/ownedProcessGone/portClosed 均 true，remoteStageMayRemain=false。合法探针回执 rejected/binding，baselineBytes=0、metadataBytes=17,624；新增固定窗与 GOT 均 0。本轮没有获得同步写入语义，不将失败改为完成。
- 读预算将失配收窄到首个方法的类型元数据读前后，当前证据尚不足区分具体原因；先增加封闭阶段诊断并本地验证，不放宽身份/ABI/内存门、不盲目重采。
- 百度官方 Frida 17.27.0 Windows devkit 摘要核验通过；ARM64 重定位夹具编译前端通过 MS 扩展，链接缺 Windows SDK 导入库与 MSVC 静态 CRT。未执行 ARM64 relocation/interceptor/allocator，不据源码推导声称复现成功；WSL 未安装，不修改全局环境。

## 续修检查点（2026-11-22 00:30，北京时间）

- 八原始 JSON 再核 SHA 与来源全部一致，environment=188.1、savedRecords/rescanned=false；公开诊断和本地 136 APP 清单统一改为已保存回执来源版本。旧字段不否定用户安装 188.1，百度未更新原因仍未知。规则说明已完成，模式展示和实际适配验收继续开放。
- 新确定问题已集中修正：目录详情在状态 updated 改变后，保留同 roundID 终态的原结束时间；状态时间、该轮配置、取消/失败/覆盖和删除证据分别展示。截断历史仅可复用同 ID 独立有效轮，无效 envelope 或不匹配 ID 不借用其他轮时间。固定日期回归、真实 writeStatus 回归、仅替换时间来源的精确 RED 已接入；独立终审无确定 P1/P2。
- 最新 Python discover66：59 PASS/7 POSIX skip，53.607s。完整原生51组：9 PASS/42 UNAVAILABLE/0 FAIL（tmp/resume-20261122-native-final）；Foundation、时间 GREEN/RED 与 Theos 未运行。9源对象通过；Scanner 首次缺版本宏失败，修本地 helper 从 control 单一入口读取包版本后重编退出0，共10源对象成功，不修改 Makefile 身份。
- 百度新工具仅 tmp，entry/helper 各64B双读、物理≤256B、metadata+fixed≤262144B、1500ms操作间期限。主线最终复跑 Node12、runtime transport9(6.534s)、静态helper窗口2+session3均PASS；11资产manifest SHA全匹配。原root controller/finalizer保持；固定probe complete仍partialSubset，不称业务契约完成。
- ALog两遍成熟度工具已准备，主线独立10项PASS；只给匿名元数据候选与保留原因，不证明writer关闭/内容可删/物理释放。QQ当前封闭诊断已本地21+11项PASS，首设备拒绝未被模型改写；下一轮只获取具体阶段。
- Swiftgram同UUID保存镜像新增可复用完整静态coverage：3,281,068解码+8明确跳过=3,281,076B，零直接b/bl、零已解析本地chain pointer指向getter0x81478/setter0x814b0。静态metadata/descriptor保持原值，不据此猜Swift vtable/活owner/可调用ABI；原件与消费者契约仍缺。

### 明天设备阶段顺序与完成条件

1. QQ仅取首失败方法具体phase/code；先区别类型元数据调用、ASCII读取与range检查，再针对证据处理；不因模型复现放宽检查。
2. 百度只取既定入口/helper运行绑定与独立磁盘helper，将同UUID字节/SHA比较和当前图片回执更新分开记录；不强制hook或跳入口。
3. 抖音仅补既有211项ALog的成熟/变化/保留明细；Support/YY路径与owner仍单独核实，不能用ALog结果抵消Support缺口或仅增加版本放行删除。
4. Swiftgram从已保存Postbox/具体生成器绑定继续最窄技术核验；未关联活owner、原件、消费者/别名及索引前不删除共享媒体。各APP以真实行为验证三模式清存量、限制写盘、关闭恢复和必要数据保持。

今晚不启动SSH/认证；2026-11-22周日白天使用既有VPN目标。设备前置资料已准备，用户无需再找目录或准备安装包。四APP整组完成及开发侧复核后统一普通提交推送；同SHA云端Foundation/UIKit/Theos、deb检查全部成功，再提供一次集中真机步骤。当前无本轮提交、新包或完整产品验收。


## 2026-11-22 13:53 — QQ 采集期限与收尾复核

- 用户恢复SSH，周日VPN；旧“今晚不连接”只描述前一夜限制，本轮已恢复单APP只读核验。
- QQ 134021-842852跨过自有输出缓冲读取，真实rejected/deadline停在methodLookup/index21；baseline5504、metadata37952、新窗和GOT仍0。根终态SSH0、cleanupConfirmed/ownedProcessGone/portClosed=true、remoteStageMayRemain=false；窗口级证据未接纳，不改写为成功。
- 仅tmp探针将原1500ms采集预算统一为8000ms，保留worker20秒及读取字节限。独立审查发现末次绑定迟到仍可complete；161ms×50=8050ms精确反例先RED，调用返回后检查deadline后GREEN。当前probe SHA f59e26dd47dadc9148c986006513e7db6f6c7c0b0e520070fa3a92fbe20a41a6，Node24/24、QQ+百度transport20/20新鲜PASS；native C调用不能由JS抢占，仍由外层期限收尾。
- 完整Python discover第三轮66项：59PASS/7平台skip，28.907s；前两轮时间失败、隔离通过均保留，不用重试成功抹去先前失败。百度先前transport因活动SSH占用27043在目标执行前OSError，端口释放后9/9通过。
- QQ新8秒真机轮135205-855565已打开可见认证窗口，尚待用户认证和QQ前台确认；未取得新窗，不称QQ资源契约或三模式完成。无本轮提交推送或新包。


## 2026-11-22 14:02 — QQ 8秒真机复测已收尾
- QQ 135205-855565、9.3.86/9.3.86.617同UUID，target收到合法partial/read；25方法与22旧窗双遍稳定，baseline11152/sourceVerified=true，metadata81952，worker总5703ms，没有deadline。原1.5秒过短阻塞已跨过，不能称整个QQ契约完成。
- 新三helper104B与两stub32B双读稳定并用Capstone5.0.6完整解码136B；四引用槽首读失败，尚缺具体range/module/read错误诊断，不猜根因。两个stub实际为直接B跳往0xfc67310/0xfc661ec，与预设ADRP/LDR/BR不同，GOT读取0保持unknown；不能把候选symbol当已解析导入。
- 根末态partialSubset、SSH0、cleanupConfirmed/ownedProcessGone/portClosed全true、remoteStageMayRemain=false；accepted fixed evidence不代表产品owner/删除/限写/关闭恢复契约。脱敏summary与解码在tmp/resume-20261122-ssh/qq-deadline-device-summary.json及qq-followup-decoded.json。
- 开发侧真实完整Python59PASS/7skip；Node24PASS、QQ+百度transport20PASS、百度静态helper+ALog15PASS。无新产品包、无提交推送。下一设备阶段百度，QQ缺口先离线分析并集中制定补证。


## 2026-11-22 14:10 — 百度运行入口/helper核验已收尾
- 140150-425327：13.37.5/13.37.5.10同UUID，固定probe complete/none；TransFileListDAO自有class method、B48@0:8@16@24@32@40、IMP0x825d200前后一致，raw与canonical相同；entry旧SHA匹配，helper64B双读SHA6d14821a618b44ba94eaf267fb50d720dc6a09eaac123eeb773aae46dd278a3a稳定。metadata42416、固定实读256、worker2094ms。这里没有Interceptor安装或业务调用，不证明旧拦截问题已修复。
- Capstone5.0.6两窗128B完整解码：entry用x1保存LR，BL helper，后恢复LR；helper开栈保存寄存器后ret。原签名误分类已纠正，实际绑定确认与磁盘对照/Frida relocation原因/当前188.1图片回执更新分开验收。
- 根partialSubset、SSH0、cleanupConfirmed/ownedProcessGone/portClosed=true、remoteStageMayRemain=false。resourceContract notGranted；脱敏runtime summary及解码在tmp/resume-20261122-ssh。下一仅读磁盘同helper64B双遍；无新产品提交/包。

## 2026-11-22 14:27 — 认证与开发侧异常如实留证
- 百度helper协议独立复核7/7 PASS；实际导入legacy tmp/feedback-1792 Stream类，与根Stream类源码一致。141523轮认证前SSH255退出；141809轮sudo拒绝、authenticated=false、SSH1/streamComplete=true，未读代码/上传/attach。已按用户要求重开新的可见认证窗口，结果待。先sudo隐藏输入、再SSH认证，两阶段不得混为网络超时；不保存凭据。
- 新鲜ALog成熟度10项复测6PASS/4ERROR(221.321s)，4项实际Bash/awk子进程8秒或30秒TimeoutExpired；完整协议/拒绝/匿名/闭合schema六项通过。同期PowerShell/tasklist/node启动亦间歇挂起，原因未证，不增期限掩盖；较早10PASS不能覆盖本轮失败。当前不将工具或手机适配称完成。
- QQ segment/branch子任务完成本地31Node+11Python；真实LC text-only模型四槽先RED模块门拒绝后GREEN，新增两固定B目标各16B双读/总200logical400physical及封闭诊断。仅tmp、source eb51f317.../schema a6d0bc0...；独立审查与新真机仍待。未提交推送、无新包，四APP资源与三模式闭环仍开放。

## 2026-11-22 14:29 — 百度磁盘/helper对照已验证
- 142605-706773认证成功，verified、SSH0/streamComplete=true；同13.37.5/13.37.5.10及UUID，helper0x706aa18各64B双读(物理128)与运行轮140150的完整hex/SHA一致，SHA6d14821a618b44ba94eaf267fb50d720dc6a09eaac123eeb773aae46dd278a3a。元数据/头SHA/安装stamp设备复核稳定，没有上传/attach/手机文件写入。脱敏比较tmp/resume-20261122-ssh/baidu-helper-static-runtime-comparison.json。
- helper磁盘与运行字节不一致候选已排除；本次没有Interceptor安装或业务调用，旧拦截失败、当前188.1图片回执更新、资源/重取/三模式闭环仍开放。协议帧修后真机通过不等于产品适配完成。无新包/提交/推送。


## 2026-11-22 16:48 当前验证进度

常驻 SSH 已一次加载 v3，实际任务继续复用同连接。ALog 登记误拒绝已按完整原始行多重集合修复；新门 11 个真实 Bash 合成边界通过，随后当前抖音 41.2.0 两次各 230 项元数据遍历完整、身份稳定、各阶段退出 0。87 项仅满足元数据候选，143 项保留；未观察所有 writer 退出，不授予新版删除权限。

QQ 首 v3 上传在约 263 KB shell 参数启动时返回 126，尚未绑定、确认前台或附加应用；小参数对照通过，后续 gzip EOF 是输入关闭后的结果。该轮失败证据保留，已单独核验无 runtime 启动、owner/端口关闭、固定身份和已知条目后精确清除本轮部分上传及桥目录。正在集中处理上传块大小、阶段/偏移门和唯一登记命令接入，不能把合成桥测试算实际 QQ 完成。

产品清理历史、证据时间及模式来源修改仍为本地未提交实现；四 APP 实际清理、限制写盘、关闭恢复和必要数据保持、macOS Foundation/UIKit、RootHide Theos 与 deb 验证仍待整组闭环。未新增提交、推送或测试包。


## 2026-11-22 18:59 — 常驻路径修复与最新两 APP 证据

- 主机真实 sys.path 上轮15600项/12唯一，tmp QueueTasks 的每次 checked_state/task/batch反复insert；已移为模块初始化幂等注册，根 persistent_device_ssh import亦幂等。旧 QueueTasks 实例仍保留旧函数，必须重新创建并保留RAM回调；当前同session真实ACK前后12→12。无设备worker真collect返回562ms，不能将路径增长当所有主机卡顿唯一根因。
- 路径实际RED三项→GREEN三项；根真实模块重复exec的精确mutation RED1FAIL→GREEN1PASS，state/JSON/Queue与真实路径轮询16/16PASS1.481s；QQ桥定向39PASS4.289s，两个本机Bash/owner项未含。证据tmp/feedback-188-20261121-210029/qq-host-startup-20261122；当前服务仍旧Stream，不为新类打断认证。
- QQ183503-747640同9.3.86/9.3.86.617及UUID，完整41MiB上传/49.8MiB回读后 worker received19719ms、attach359ms；25方法22旧窗双遍11152B、11新增窗200/400B全stable，三selector已resolved。classref槽稳定但unknown，两B岛stable仍无GOT/import绑定；fixed partial/metadata不是资源契约。顶层partialSubset/CLI2，cleanup/owner/port/control均confirmed，remoteStageMayRemain=false、persistentSSHClosedByProbe=false。用户确认前台，API unavailable仅userConfirmedApiUnavailable。
- 百度已保存188.1关系只读42字段真机2352B/13078ms/EXIT0，身份和stamp stable：runtime schema2/complete，wrapper1/21/24/25 own且matches，四original present主模块1且与current不同。raw完整schema未验证/非live；早期 initializerReturns1、registered0、sdkMethodsChanged1，只说明observe门拒绝，不唯一确定helper、安装、raw IMP或时序。Windows write_text CRLF原拒绝保留，用RAM原LF write_bytes重存后严格parser接纳。
- 同一SSH v3仍ready。下一集中最窄QQ终跳与class拒绝阶段；百度用单次门结构化拒绝保留，不猜PAC或忽略swizzle；Swiftgram既有具体名称与窄方案复用，ALog已采不重复。清理历史本地实现及四APP资源/三模式、关闭恢复、必要数据保持、Foundation/UIKit、Theos/deb尚未整组闭合；无本轮提交推送/新包。


## 2026-11-22 19:35 — 状态发布共享冲突与失败轮恢复

- QQ191958上传/签名回读完整，尚未执行Frida；常驻352d服务在129任务后PermissionError退出、SSH0，唯一state.pending内容ready/lastTask129且所有已执行结果完成，定位原子state替换边界。真实Win32 reader不允许delete共享重现transient拒绝，RED1FAIL→固定0.5s同完整文件replace重试GREEN2PASS，永久冲突仍失败、旧状态不丢；state/JSON/Queue/import16PASS1.089s。已有BK后改scripts/persistent_device_ssh.py与tests。
- bridge原poll只看remote code，失去共享SSH仍等待完整210s并STOP无效；新poll验证现有capability，断线立即明确RuntimeError、不造remoteExit。RED1FAIL→GREEN2PASS；定向41PASS2.355s，两本机Bash/owner项未含。原roundfailed保留finalizationFailureKeyboardInterrupt，未改成功。
- 用户自行重开215619服务已直接复用，ACK0；旧owner64277gone、done37，远端tail含PORT_CLOSED/PROCESS_GONE/临时目录及stage清理四帧；按原dev:ino/固定5entry移除control，独立recovery-confirmed，原result不改。新连接ready，继续一次最窄QQ终跳；不再询问密码/QQ前台。
- 新QQ工具manifest8SHA全匹配，实际NodeCLI46PASS0FAIL72168ms（主机启动等待），两vm验证有realm不一致失败，仅列工具执行问题，不当生产回归。Swiftgram真实pinned worker边界成功接纳先RED1FAIL→GREEN3PASS0.121s，identityChange/cleanupFail拒绝；metadata探针尚未真机，源配置完整接入仍需检查。四APP业务契约、实际三模式/关闭恢复、Foundation/UIKit/Theos/deb未闭合，无提交推送。


## 2026-11-22 续接 — QQ 有限终跳实采与 Swiftgram 适配

- QQ193528因为上下文恢复未及时给已有前台确认而failed/foregroundConfirmationDeadline；未执行探针，完整收尾cleanup/port/owner/control均true、ownedRuntimeExit0，SSH仍ready。194249直接复用215619同连接且已有QQ确认，实采partialSubset完整收尾。25方法22旧窗双遍11152B稳定/sourceVerified，新增232logical/464physical稳定，metadata110240；两终跳精确命中但unsupportedStub，不追跳、GOT0；classCause diagnosticUnavailable及第二遍notAttempted，不猜本机metadata根因，不开放业务契约。worker7750ms、attach281ms。
- 百度12文件SHA与最终manifest全部一致；最终6对象1795347418454482200真实exit0。完整diff --check退出0，仅CRLF提示。该组是首次拒绝可诊断性，旧188.1根因仍未唯一确定；Foundation/UIKit行为与Theos/deb尚未验证。
- Swiftgram实际saved TelegramUI加载命令15280B（SHA49247b...），旧8192上限可确定拒绝。新actual FridaIO adapter用真实命令表先RED(metadata)后GREEN8PASS，只读取每条8B头及UUID16B，逐条长度/8对齐/唯一UUID/映像边界保持，最大遍历1MiB/4096命令且总metadata32768不变。重复UUID/坏长度/错UUID/映射不可读/迟到/类变化均拒绝。probeSHA b77117646be47bc8cb578d85ba7a2dbb550a9230bfa95951b79c7fcd0316672e；Python9PASS0.516s、Node12PASS。仅tmp工具未部署产品；已要求一次Swiftgram前台切换，上传复用同SSH。
- 四APP业务资源契约、三模式实际清理/限写/关闭恢复、必要数据保持仍未闭合；无本轮提交/推送/新包。


## 2026-11-22 20:03 — Swiftgram 首轮未返回及 QQ BOOL 字段

- Swiftgram195239同215619连接，用户已一次确认前台；上传/诊断14帧110485ms验证通过，workerDeadline无Frida回执、内层cleanup未确认，顶层failed/targetObservationUnconfirmed，serverExit124、外层ownedRuntimeExit0和cleanup/port/owner/control均true。原result不改，不能说注册不存在或设备适配成功；先验证本机spawn入口，不盲扩时限或重复认证。
- QQ194249的diagnosticUnavailable存在确定工具类型问题：Frida17.27.0固定gumffi.c bool→ffi_type_schar，gumquickcore.c sint8→JS_NewInt32，旧metaFlagTrue直接存数字导致严格boolean schema拒绝。实际adapter新增numericMetaFlag精确RED(expected resolved/actual diagnosticUnavailable)，只将metaFlagTrue显式!!后GREEN；真实Node CLI完整47PASS/0FAIL/38601.794ms，新sourceSHA3b705d26de732b10fe34a6b97d7dbdafb73efabcc789d2e6e9ed89b44fe2e08c。修正字段不放宽slot/identity/预算门，尚无新手机cause，不追未知终跳。固定参考bindings/gumjs/gumffi.c SHAeb9ae877cf5f8c1a4c8963b65d838987451fad6d47e234d0ea4d2aa9e16de454；local Frida验证首用系统Python缺模块失败，不列ABI通过。
- 本轮完整根persistent测试23项641.817s：18PASS/1FAIL/4ERROR，5个Bash执行项streamDeadline；Win32 atomic/状态/JSON/queue项通过。该失败保留，不能列整体通过；本机shell/node启动有长延迟，后续根因区分后再验，不用加期限掩盖。Swiftgram最新Python9PASS0.580s（正确Frida所在Python），Node模型12与actual adapter8PASS。


## Swiftgram 开源接入与启动修复（2026-11-22 续接）

沿用用户提供的 Swiftgram/Telegram-iOS 和固定 commit ba54d9823d413f9816e5eee2724da77d5079f4cf，具体 scaled-image/aspectFit/general 分派、完整原件、生成器、表示路径和索引语义以已保存源码报告为准。继续既定方案，不重做全机盘点。

- [ ] 本机预启动 worker，在任何手机运行窗口前核 ready；token 仅在 ready 后通过 RAM pipe 发送，启动失败不得启动手机 runtime。单次请求、封闭 phase/elapsed、总截止及取消清理均需真实 spawn 边界测试。
- [ ] 直接复用常驻 SSH 和已有 Swiftgram 前台确认作一次窄注册核验，记录最后阶段与独立收尾，不将类登记视为业务契约。
- [ ] 具体资源资格判定与生成/写回/索引/关闭恢复分别验证；未知 owner、原件、消费者或别名保留。现有 removeOtherCachedResources 不满足操作结果及索引协调，不能作为可靠删除接口。


## Swiftgram 派生目录分类整组修复（2026-11-22 续接）

固定 Swiftgram commit ba54d9823d413f9816e5eee2724da77d5079f4cf，Postbox MediaBox.swift blob e28a2d0f1b2467dc7dc1758bae0f396a8d24c9ae、SHA256 67fec306a9828dca4015bc20ee9bfa26eeb0b19efa5506fa34df5924ec24e27b，187–188/202–207/264–306 行确认 cache、short-cache 与 animation-cache 为媒体根内并列目录。现有分类仅识别 cache，另两项容量计入媒体祖先但缺独立展示。

沿用已授权占用识别修复：以同一结构分类器扩展两个封闭标签，扫描借用同一节点合法性接口决定第五层；保存投影和界面消费标签。仍只针对独占登记 Swiftgram group、准确 postbox/media/目录位置。其他 APP/共同 owner、相似名称、数据库内同名目录、未知媒体分片不扩展。逻辑容量与分配容量沿用原统计，父子节点不可相加；不授予删除。

验收：真实 C 分类器先精确 RED 后 GREEN；真实文件夹具覆盖普通/短期/动画三者各自计数和祖先总量、投影错误父级/旧 profile/共同 owner 拒绝、界面三个标签。Windows 可执行分类行为与 ARM64 对象编译分别报告；Foundation/UIKit 和真实三模式继续开放。Swiftgram 最新窄登记轮 failed/deadline 必须保留，先验证字符串读取操作开销，仍守 2 秒/32768 字节及双遍 UUID/类门，不以分类或登记替代资源契约。


## 2026-11-22 续接：集中采集收尾边界

- QQ/百度/抖音已有只读证据复用，不重复全机盘点或未知终跳。Swiftgram 212909轮在附加APP前，normal --version退出0后文件SHA改变，严格dispatcher拒绝；内外cleanup、owner、port、control均确认，shared SSH保留。
- 单独版本检查复现同一变化：长度18405344不变，仅40字节，arm64e __text section.segname尾八字节cookie与官方jbroot当前环境标记相符，另32字节位于签名；完整code hash核验尚待，不放宽gate或接受任意执行后SHA。证据tmp/feedback-188-20261121-210029/runtime-version-{diff,cookie-evidence,mutation-result}.json。
- 205946轮桥和stage消失根因未唯一确定；用户无清理或环境重载。小桥和215秒canary存活，STOP后精确清理；fs_usage监测440秒退出124无输出，不能归因，监测已收尾。
- 保存实际Frida IO adapter15PASS与宽读/跨映射mutation拒绝；probe、worker未改。完整原生51组9PASS/42UNAVAILABLE/0FAIL，Foundation/UIKit无实际行为环境。常驻真实Git Bash完整旧轮18PASS/2FAIL/3ERROR，新60秒有界轮timeout，最小嵌套pipeline退出137仍未修复；不冒充整体通过。
- 下一步先离线验证环境cookie与相应签名页哈希，再修复最小准备流程，一次窄采Swiftgram；随后转整组产品实现与真实行为验收。无本轮提交推送、产品部署、Theos新包。


字段复核更正：0x8a00c8 是 __text section 的 segname 尾8字节（section+24），不是 addr（section+32）。addr保持0x100004000；原件和运行后准确结构存 runtime-version-cookie-field-correction.json。运行后SHA-256全部页有效，arm64e SHA-1第0页无效，因此该执行后文件不准入。新工具只在签名前按官方jbrand绑定这个字段，两slice全部代码页和special entitlement hashes另行核验，原source/gate/dispatcher/cleanup保持。


## 2026-11-22 22:08 — 运行环境绑定实际跨过

仅本地tmp工具新增签名前官方jbrand绑定；原restricted源码哈希、backend签名payload校验、全部gate/dispatcher/window/cleanup继续使用，另查两架构SHA-1与SHA-256全部code pages和special entitlement hashes。7项实际保存二进制/Gate回归exit0，去绑定精确mutation1FAIL（expected RED），原执行后40B变化样本仍因SHA-1第0页失败被拒绝。

220133真机同3ba1连接已经收到14诊断帧且verified=true（108875ms），normal/probe均退出0且前后SHA严格相等；尚未等到目标最终回执，不提前称采集完成。normal d57ff1dd6075afdcacdd7e136aee93a8eeab38905b54e6dbb56626830cde8f81；probe 188f694e3fa2e3a28b38f5196ce8ba93745eaaabcf86bcb35caf814e2b68b1d4。

独立Windows MSYS复核仍FAIL：真实Link/PersistentStream两任务exit137/output空10.531秒，独立外部程序pipeline亦停滞；简单nested/timeout/builtin均快速完成，未定位唯一底层根因。未改手机已工作的共享协议，不增期限、不改测试期望。证据tmp/persistent-bash-fix-1795355349371/findings.md，测试自有进程已收尾。


## 2026-11-22 22:15 — 设备采集集中封存，转整组修复验证

QQ/百度/抖音复用已采证据。Swiftgram220133已在同3ba1连接跨过14诊断帧/工具哈希；attach25016ms callTimeout、sameIdentity，未运行probe。server137/dispatcher35、unknownProtocolOutput保持failed。独立恢复核验stage absent、owner gone、端口关闭及五清理帧后，桥按原stamp/已知五条目精确清除，SSH ACK成功，不重采。

仅tmp工具新增签名前官方jbrand绑定与全部code/special hashes；7PASS、精确noop mutation1FAIL。__text section.segname尾8字节cookie，addr不变。另修失败读线程退出后不读done的徒等：3GREEN/2原行为RED，同SSH自有canaryunknownProtocolOutput且EXIT7/精确cleanup。较宽bridge46项45PASS/1真实MSYS FIFO timeout，独立MSYS停滞未唯一归因，不宣称整体通过。

新增docs/2026-11-22-188.1-设备采集收尾.md，按四APP列事实、保留与剩余验收。清理历史/显示/分类/百度拒绝诊断已本地实现，Foundation/UIKit真实行为、四APP三模式/关闭恢复/必要数据、Theos/deb仍待；不重新调查已采全机/固定窗，不把未知放行。无提交推送部署或新包。


## 2026-11-22 22:58 — 转产品回归，历史显示测试接入 CI

- 四 APP 采集封存，不重传 Frida/attach/追未知终跳；未知资源继续保护。七个 ARM64 iOS16 SDK16.5 测试二进制本地链接 exit0，仅构建，不称手机行为通过；SDK路径文本链接用真实目标tbd本地alias，不改SDK。
- 历史摘要精确反例接入唯一 UIKit step/suite ledger；失败和超时继续独立套件并使整组失败。定向调度 RED2FAIL→42/42PASS，lifecycle24项21PASS/3平台skip。新命令预算10700<180分钟，job210分钟。
- 复核确认原摘要runner在build/test/summary失败时丢日志；改每轮独立持久run目录直接写generate/build/red，finally状态且异常重抛，归档仍要求组终态和processGroupsSettled。实际文件I/O6例RED6FAIL→GREEN6PASS，未运行Xcode/UIKit。
- 独立Foundation runner只receipt/time六项，不访问APP/status；创建回帧失败改owner+原dev:ino恢复并finally精确收尾，空entries跳过。两失败路径RED2FAIL→GREEN2PASS。网络sharedURLCache隔离另准备，尚未执行。
- 原3ba1状态ready已失效，本地PID退出。用户一次重开后新3db867同VPN连接真实ACK通过；已启动独立Foundation测试，当前结果待，不把started当passed。无本轮提交推送/产品部署/新包。
