# Swiftgram 具体缩略图：窄范围 ABI 补证

2026-11-22。文档最初阶段只读本地已采安装字节与固定上游源码，未 SSH 或修改产品规则；后续真机窄采、工具修复和产品分类改动见文末续接记录。全程未读取用户资源正文，未调用未经验证的 Swift 或资源操作。新文件最初无旧版本可备份。

## 本次确定的结果

| 问题 | 实际证据与结论 |
|---|---|
| MediaBox 的 Swift 相对 vtable 是否引用 fetchCachedResourceRepresentation getter/setter | 同 UUID Postbox descriptor 在 0x34fe54，flags=0x80000050；核非泛型、版本0、无韧性父类、无非平凡初始化后，44字节固定头后是 vtable header 0x34fe80。offset=30 words、size=1。唯一 method descriptor 0x34fe88 为 Init，relative displacement=-2942500，指向公开 allocating init 0x81868；静态 metadata slot 0x3cf030 的真实 format6 chained pointer 也指向该 init。getter 0x81478/setter 0x814b0 没有本类 vtable 项。关闭本类 vtable 路线，不能扩大为未使用或不可观测。 |
| 是否需要再次全镜像找 CachedScaledImageRepresentation 名称 | 不需要。持久技术档案已保存 TelegramUIFramework 的 __objc_classname，范围0x5464300、524889B、SHA256 2e0dba20525622a76b96ec511a300a624f280e6f3e652fe043519e738b40e267。唯一完整名称 _TtC14MediaResources31CachedScaledImageRepresentation 在相对488352、模块VM0x54db6a0，54B含NUL。已核档案映射、SHA、load commands和UUID3c18e9ea5c1531a493b0f3899d79bae6。保存名称尚不证明运行时类已登记、Swift descriptor、协议一致性或生成器绑定。 |
| 现有合成代码是否需要重写 | 不需要。tests/ScaledRepresentationGeometry.h、tests/ScaledRepresentationRebuild.h 和 tests/ui/ScaledRepresentationRebuildTests.m 已存在，接入原 ImageCacheIntegrationTests。合成C维度测试历史通过，UIKit真实执行/像素断言仍缺运行环境。当前代码没有具体宿主资格门，不将 tests 接入 CleanupRules。 |

Postbox 实际文件4481696B，SHA2567602d9b668bef8088e115e72c52bfce17b6ff9f1afe17d1336688d6ec7e4ce01，UUIDdc7f4a8faa9b3319bbc75e4e4f264e63。所有地址为该镜像模块相对VM，不能跨版本直接使用。

## 可执行复验与边界

新增本地只读验证器 tmp/feedback-188-20261121-210029/swiftgram_vtable_evidence.py。实际 Python3.12.14执行exit0，输出 swiftgram-vtable-evidence-20261122.json；核验1项vtable、getter/setter0项引用和已保存具体名称。7项真实变异拒绝通过：泛型、描述符新版本、韧性父类、singleton初始化、表预算超限、超metadata正边界、异步方法编码。变异只作用内存副本，不覆盖输入。

PowerShell复验命令（不带--output时仅stdout，无写入）：

~~~powershell
& 'C:/Users/Shine/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe' 'tmp/feedback-188-20261121-210029/swiftgram_vtable_evidence.py'
~~~

验证器只执行既有 inspect_postbox_metadata.py 的读取前半，固定边界后写文件部分不执行；原静态完整覆盖结果不重跑。ABI参考从 Swift swift-5.10.1-RELEASE解析到commit0cbf541194159e0576548a0f2b9bf41bf16ef631，重新读固定commit确认与tag字节相等，SHA保存在同目录 swiftgram-vtable-abi-20261122/manifest.json。参考版本不是已安装编译器版本证明。

固定源码布局依据：

- [MetadataValues.h:1545](https://github.com/swiftlang/swift/blob/0cbf541194159e0576548a0f2b9bf41bf16ef631/include/swift/ABI/MetadataValues.h#L1545)：context kind/generic/version/kindSpecificFlags；1624起为类vtable、韧性父类及metadata初始化位；334起为method flags。
- [Metadata.h:3946](https://github.com/swiftlang/swift/blob/0cbf541194159e0576548a0f2b9bf41bf16ef631/include/swift/ABI/Metadata.h#L3946)：类descriptor尾随项次序和固定头；578起为method descriptor，605起为vtable header。
- [TargetLayout.h](https://github.com/swiftlang/swift/blob/0cbf541194159e0576548a0f2b9bf41bf16ef631/include/swift/ABI/TargetLayout.h)：External CompactFunctionPointer是int32相对值。本解析只接受测得的同步项，并用真实静态metadata slot交叉核验。

## 后续一个 Swiftgram 窗口应补什么

由主线复用现有已授权运行时会话集中执行，不启动新代理/SSH，不重复全机、全镜像或heap扫描。分阶段服从同一窗口总截止；未命中如实结束，不能反复重启应用求命中。

1. **先取最小已知类登记事实。** 在已运行的 app.swiftgram.ios 内通过已有可调用 C runtime API objc_lookUpClass 查询上述唯一技术名称；不构造对象、不发 selector、不调用 Swift getter。仅使用 class_getName/class_getImageName核技术名和所属已加载镜像，并将路径投影成现有UUID/模块代号，禁止序列化应用路径。返回类指针只留RAM，报告仅匿名类代号、登记状态、镜像UUID、模块相对地址。登记不存在与探针失败分开；不为取得结果调用objc_getClass或类初始化/构造入口。
2. **登记已核后再补具体元数据和代码。** 优先核匹配类descriptor/metadata公开导出是否存在；符号名只作查找请求，返回地址、UUID、段映射和真实字节才是证据。只取已定位的descriptor固定头与由真实flags确定的必要尾随项，以及size/mode/uniqueId/protocol-conformance有关的精确函数范围。缺导出时使用真实Swift类metadata布局和已验证地址点定位descriptor，先核Swift type-metadata身份和映射，未知layout或认证指针解析失败即停止；不得拷贝旧实例字段偏移。目标是MediaResources具体类及TelegramUI分派/private generator，不是再次取Postbox通用导出。代码边界必须由本镜像LC_FUNCTION_STARTS/符号确认，不用固定96B窗口冒充完整函数。
3. **Swift ABI验证必须先于业务观测。** 使用固定宿主源码/真实模块接口构建Swift桥接测试接点，检查CachedScaledImageRepresentation声明的EngineRawCachedMediaResourceRepresentation与Postbox CachedMediaResourceRepresentation之间的真实协议重导出/一致性、existential与witness、闭包、Signal、ARC和队列。现有源码报告指出该缺口，本轮没有凭名称补造typealias。可先在专用合成对象验证调用与所有权，使用已有UIKit harness。不得用NativeFunction/手写C函数指针调用Swift，也不得借vtable地址强转或解引用运行closure context。
4. **一个自然请求的匿名关联。** 仅在桥接已验证后，从宿主正常给出的同一MediaBox/resource/representation建立RAM内关联：实例匿名代号、资源匿名代号、具体type/aspectFit/general、真实整数size、complete与稳定原件、pathExtension=nil、表示匿名对象和生成结果。原resource ID、路径和String不出报告；128×128仍只是开发测试值，不能填成设备观察值。若先只捕获setter，自然进入x20/x0/x1之寄存器必须经本镜像指令与工具真实保留规则复核；只保存匿名owner/代码镜像偏移/不透明context代号，不调用closure，不把setter命中当具体类型和原件关联完成。
5. **消费者/别名是独立门。** 从同队列提交边界和所有消费者取得原件保持、派生表示生成/读写/交付生命周期、路径别名/跨扩展状态；空cachedRepresentationContexts、FD窗口无命中或Signal completion均不能证明无消费者。若此门未知则保留候选，不删。最窄测试先让专用合成资源保留原表示，生成/解码替代文件并覆盖取消/无complete/编码失败/写回失败；还需要文件实际结果、cacheStorageBox协调和原件保持，不使用现有removeOtherCachedResources充作事务。

## 固定实现入口与尚余完成条件

具体算法沿用[CachedResourceRepresentations.swift:36](https://github.com/Swiftgram/Telegram-iOS/blob/ba54d9823d413f9816e5eee2724da77d5079f4cf/submodules/MediaResources/Sources/CachedResourceRepresentations.swift#L36)、[FetchCachedRepresentations.swift:51](https://github.com/Swiftgram/Telegram-iOS/blob/ba54d9823d413f9816e5eee2724da77d5079f4cf/submodules/TelegramUI/Sources/FetchCachedRepresentations.swift#L51)、[private generator:334](https://github.com/Swiftgram/Telegram-iOS/blob/ba54d9823d413f9816e5eee2724da77d5079f4cf/submodules/TelegramUI/Sources/FetchCachedRepresentations.swift#L334)。本轮重新读相同commit、按已存Git树blob核两个文件，不保存重复源码。

普通资源与表示接点为同commit MediaBox.swift:526、997，写回/alias/索引为1001–1164；setter为175–183；Account.swift:1729–1734的注册closure可能.never()。必须保留有限截止，completion不证明落盘有效。

本次只关闭MediaBox本类vtable缺口并找到可直接复用的具体名称，尚无可确证的产品故障根因，因此未改生产hook/清理逻辑。既定缩略图方案仍缺：UIKit实际执行、具体安装类型/分派/生成器/ABI绑定、活owner与原件/表示匿名关联、消费者和alias协调、有限且逐项可核验的替代重建事务。最终产品仍缺在真实资源上闭合恢复/关闭/三轮数据保持与iOS16/17验收；本证据不授予任何用户资源删除许可。


## 2026-11-22 20:30 续证：源码别名与已运行类

固定 commit 的 TelegramEngine/Utils/EnginePostboxCoding.swift:40、44、45 已按 Git blob 22c3243c685b516c3d61812a976c197c8642c097 核对：EngineRawMediaResource、EngineRawCachedMediaResourceRepresentation、EngineCachedMediaRepresentationKeepDuration 分别是 Postbox 的直接 typealias；SHA256 4931da0a878d956693489ad2b689fa7e466704ddb4d4c9a0025a3e554e90af6f。本项关闭源码层协议重导出未知；不证明安装版 witness/调用 ABI。

Swiftgram201945 真机轮已实附加157ms、worker4156ms、内层cleanupcompleted、外层cleanup/port/owner/control均true、SSH仍ready。具体类lookUp非空，但旧探针将 class_getName 与原始 _TtC 名称直接比较，rejected/className；不是类缺失。Apple objc4-876/runtime/objc-runtime-new.mm:6268 实现 class_getName 返回 demangledName，6189起有 Swift 解码；参考SHA a873567b2bbb4fadcb0ad17655c737169d69a21f2a650aec7726e9d6bd57fc92。

新探针仍只用固定原始技术名lookUp，只接纳同一具体类的原始或精确 MediaResources.CachedScaledImageRepresentation 名称；所有主模块/类模块UUID、双遍类指针和2秒/32768B门保留。actual adapter真实大加载表与解码名反例先RED(rejected/className)后GREEN10PASS，错具体type继续拒绝；尚未取得修正后设备模块登记结果。


## 2026-11-22 20:55 续修结果

- Swiftgram 固定源码的普通 cache、short-cache、animation-cache 已集中接入结构分类、扫描第五层、保存合法性及容量界面；扫描使用共享 node_valid，避免再维护独立分类集合。只接受独占登记 Swiftgram group、准确 postbox/media 位置；数据库同名/其他 APP/未知分片保持原规则，无删除授权。新增真实夹具、投影错误父级及 UI 标签测试。
- 真实 C 反例 RESOURCE_RED_EXIT0（命中精确缺失分类），GREEN退出0；首次本机 Zig60秒超时留存，不当RED。完整 Python105项32.069秒，98PASS/7平台skip；Swiftgram真实spawn/收尾15PASS2.821秒，实际Node adapter11PASS。ARM64 iOS16 SDK16.5对象：Capacity、Service、DiagnosticsPage、service tests退出0；capacity tests首次漏testing宏编译失败，正确宏重编exit0；UIKit缺XCTest，Foundation/UIKit行为UNAVAILABLE，未称整包编译。diff --check退出0。
- Swiftgram203025窄采合法failed/deadline、metadata697，内层cleanupcompleted，外层owner/port/control均确认、SSHready；类名修正后的登记仍未真机证实。确定逐字ASCII read每次range检查的高开销：actual adapter20ms操作反例先deadlineRED，改映射边界内≤32B分块后11GREEN；2秒/32768B、双遍UUID/类、ASCII/NUL等门保持。新probeSHA2a20bdcf3422bcc477d6daf88b26a37e6f1955d5fb23e32d735dbb08cd62e509，workerSHA4a2755593cccfa6e30337bf28683bdb954cb6bb5a5515b72993df331800d4e54。不宣称这就是手机所有超时根因。
- 205205新worker ready1110ms；上传期间常驻SSH退出255/streamClosed，尚未运行手机probe，原failed/root cleanup未确认不改写；用户恢复新v3连接，真实ACK通过，正在单独验证原固定桥身份与收尾。四APP业务契约、三模式清理/限写/关闭恢复/必要数据、Foundation/UIKit/Theos/deb尚未整组闭合。无提交推送或产品部署。


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
