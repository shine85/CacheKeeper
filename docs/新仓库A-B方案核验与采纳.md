# 新仓库 A/B 方案核验与采纳

核验日期：2026-11-12（北京时间）。参考仓库为 `shine85/CacheKeeper`，固定提交为 `fe10eb6448b71a3325669c145a72b22c3540b264`；现有工程以本地 `deef9d9` 为起点，交付仓库继续使用 `shine85/CacheKeeper2`。

## 结论

选择性采纳路径一致性、设备本地时间和原始进程状态诊断。A 案的挂起放行、B 案的未知目录自动删除，以及目录写锁、全清、日志定级删除不原样移植。它们改变了现有的数据保护和用户选择范围，编译成功不能证明这些改变适合真实 APP。

| 新实现 | 核实结果 | 本工程处理 |
|---|---|---|
| A：同实例挂起满 60 秒清理 | `Scanner.m` 将挂起映射为 Stopped；计时依赖 NSDate 和周期采样，不能证明期间一直未执行，也没有证明恢复后数据可重建 | 保留进程清单确认退出的边界；吸收 `state.taskState` 原始值用于诊断，接口缺失明确报告不可读 |
| B：未知目录无数据证据即删 | 有限名称和头部名单漏检不等于可重建；JSON/plist 被直接排除在数据证据之外，旧二进制也可被删 | 未知目录继续只读；不把格式、增长或未命中黑名单转成删除授权 |
| B/日志：文件级稳定性检查 | 预检后新建数据库或兄弟文件变成数据文件时，仍可能删除稳定的关联文件 | 保留完整预检、目录 mtime/ctime 与文件快照复核，变化后停止并等下一轮重新预检 |
| 标准根全清 | 分支和测试明确放行删除 SQLite 与嵌套数据文件 | 不移植；数据库/登录态及关联后代保持保护 |
| 日志定级 | 文件名扩展只能给出名称特征，不能证明业务事件队列或自定义日志可丢弃 | 不以日志定级开放删除，保留只读档案 |
| 默认自动发现和 B 候选发现 | 缺键被解释为开启；B 不依赖已选目录或自动发现开关 | 保留当前缺省值、显式选择和排除语义 |
| 递归目录/文件写锁 | 可能阻断缓存根里的数据库与状态文件写入；失败分支忽略恢复结果却宣称回滚 | 保留旧权限恢复功能，不重新引入 chmod 限写 |
| 放开全部祖先符号链接 | 上游共享 helper 的调用方并非都做了根身份绑定 | 保留逐级 O_NOFOLLOW；仅处理已核验为同一目录的根别名 |

## 实际采纳

1. `AxsCacheKeeperFileAccess.h` 提供同一目录的根别名和枚举路径映射。只替换核验后的根前缀，拒绝根外前缀、点组件与路径穿越；后代路径不做 realpath 或标准化。`Baseline.m` 和只读 `AxsCacheKeeperInspection.m` 用重建的规范 NSString 贯通属性读取、父路径、数据保护、文件快照与删除检查。避免将它再转成 NSURL 后取 `.path`，引入第二次路径形态变化。
2. `AxsCacheKeeperPolicy.h` 统一时间显示为设备本地时区、Gregorian 日期与完整年月日。检测快照、清理检查、目录档案和网络诊断共用此入口；无效时间显示“时间未知”。保存的 NSDate 和文件年龄判断没有改成文本时间。
3. `AxsCacheKeeperProcess.h` 显示原始 `taskState` 或“不可读”。仍有进程记录时保持 Running；不把私有状态数字、挂起或取不到状态解释成已退出。
4. 版本升为 `0.7.2`，沿用现有包标识、偏好域、SDK 16.5、iOS 16–17 与 RootHide。网络容量模块两树一致，没有重复替换它。

`axs-ios-tweaks` 技能源与本地内容已对比：代码、文档与脚本一致，参考仓库缺少本地已有的面板图标；没有“换成新技能后自动升级插件”的事实依据。当前安装入口可读，继续通过项目相对符号链接维护，不覆盖工程。

## 证据与验证边界

- 修复前测试提交 `aa60a94` 已在 [Actions 43143673204](https://github.com/shine85/CacheKeeper2/actions/runs/43143673204) 编译并运行，因“有进程记录时保留原始执行状态”断言失败。该失败来自真实代码行为，没有发布测试包。
- 新增回归覆盖原始状态/不可读状态、设备时区、根别名与越界输入、四级目录与大小批次、数据库关联内容保留、预检后根被链接替换。原有新增数据库、原地变化、取消、失败阶段与 NSURLCache 恢复测试继续保留。
- 时间验证按 [Apple 的 localTimeZone 文档](https://developer.apple.com/documentation/foundation/nstimezone/local) 修正：iOS 11/macOS 10.13 起该属性跟随系统时区，修改进程默认时区不改变它。用注入时区的实际格式器验证上海、洛杉矶与跨日，再用独立 Calendar 结果核对设备入口；不修改机器时区。
- Windows 不能执行 macOS Foundation 原生回归；实际测试、Theos 编译和 deb 文件验收由本次提交对应的 GitHub Actions 完成，以最终成功运行和 Release 为交付证据。
- `errno 22` 的旧截图没有区分路径边界校验与真实 unlinkat 失败。新仓库的说明也没有提供可独立核验的原始真机回执；不能仅凭这些文字断言该设备根因已修复。当前保留失败阶段、errno 与路径样本，需在设备上核对。
- iOS 16.2 抖音、RootHide 私有接口、实际清理收益与 Filza 定位仍需真机验证。本次不把云端测试成功当作设备功能验收。

参考实现：[进程状态](https://github.com/shine85/CacheKeeper/blob/fe10eb6448b71a3325669c145a72b22c3540b264/AxsCacheKeeperProcess.h)、[候选与清理调度](https://github.com/shine85/CacheKeeper/blob/fe10eb6448b71a3325669c145a72b22c3540b264/Scanner.m)、[策略](https://github.com/shine85/CacheKeeper/blob/fe10eb6448b71a3325669c145a72b22c3540b264/AxsCacheKeeperPolicy.h)、[清理预检](https://github.com/shine85/CacheKeeper/blob/fe10eb6448b71a3325669c145a72b22c3540b264/Baseline.m)、[原生测试](https://github.com/shine85/CacheKeeper/blob/fe10eb6448b71a3325669c145a72b22c3540b264/tests/cache_control_tests.m)。本文件为新文件，无旧版本可备份；相关已有文件备份在本次 `BK/` 目录。
