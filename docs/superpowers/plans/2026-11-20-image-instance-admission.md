# 图片实例准入原因实现计划

目标：在原来源、ABI、owner、范围及恢复门不变的前提下，区分没有初始化返回、返回后未登记、已登记但实例检查失败、已释放。只增加可核验诊断，不扩大百度或未来版本支持。

范围：ImageCache.m / ImageCacheStatus.h 及对应测试。Diagnostics 已使用同一投影，OperationInfo 保留原授权原因，不复制诊断事实。用户已批准直接实施；不派代理、不改 memory、CI、用户文件，不提交或连接设备。

## 数据与不变量

- schema 1 可选 `instanceAdmission`；旧记录不补值。其 schemaVersion=1，initializerReturns/registered/unregistered/released 为有界累计计数，overflow 为真正布尔值。
- initializerReturns 只表示原 initializer 已返回并到达观察器，包含 nil；不冒称未返回或抛异常的调用已完成。registered 仅指登记到有限 registry，并非取得删除或限制授权。
- unregisteredReasons 是固定早退枚举的非零计数；liveReasons 是当前存活 owner 最近实际实例检查的固定原因分布。notChecked 明确表示被前序门短路，none 不替代 scope/source 授权。
- 累计采用 2^53-1 饱和，合计也按相同饱和语义闭合：returns=registered+unregistered；unregistered=sum(reasons)；registered=released+observed；sum(liveReasons)=observed。overflow 不能由普通精确计数伪造。
- 每个弱 owner 只记一次释放；清理 registry 之前结算。发布在 registry 锁下取同一快照，只读取缓存诊断与弱引用；不执行 SDK getter、扫描或 FS I/O。早退累计不能覆盖已登记 owner 的状态。
- 不输出路径、键、对象描述/地址、原始类名、动态异常字符串。当前实例最多 64；所有原因键来自封闭枚举。

## 实施与验证

- [x] 先 BK 备份；C 累计/饱和/矛盾测试初始精确失败，正式实现 GREEN，四个隔离变异均命中精确断言。
- [x] Status.h 内共用 C 计数与严格 Foundation 投影，旧字段可选；已写布尔/未知键/私密值/闭合和旧记录用例。
- [x] 观察器完整早退计数、实例原因缓存、owner 释放一次结算，保持原授权和发布 getter 边界。
- [x] ObjC fixture 覆盖 nil、成员缺失、配置/队列失配、恢复、释放/新 owner、排队中释放、并发与上限；SDK 用例追加固定原因及释放断言。
- [x] 执行可用 C RED/GREEN、runner 语法/精确锚点及 UNAVAILABLE/2 检查、ARM64 对象编译，保存 diff 与证据。
- [ ] macOS Foundation/UIKit 行为运行：当前没有 xcrun，未执行；不以对象编译或 C 测试替代。两个独立 runner 已由主线接入 tests/run_native_tests.py，各180秒外层预算；10项编排测试通过，CI工作流未改。

验收：拒绝原因可区分且不扩大 eligible/restricted/submitted；诊断总数闭合；旧 receipt/operationHistory 仍可读；发布无新增业务 getter；真实百度活实例准入和清理效果继续等待正式产品环境验证。
