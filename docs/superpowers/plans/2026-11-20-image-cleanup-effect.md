# 图片清理结果核验

目标：落实既定“实际清理与同次效果”要求。SDK removeAllData 忽略删除和重建错误，API 返回只能说明调用结束。复用原 SDK 队列和受授权平面目录检查，在同一 action 保存前后元数据；不增加删除范围。

实现：新增无 I/O 的 ImageEffect 内核处理计数、溢出与结果分类；ImageEffectStatus 严格投影。ImageCache 原预检顺便采前值，API 返回后重新认证目录祖先与 SDK owner，再采后值。每次最多十万条、0.25秒，符号链接/子目录/错误/目录变化/关闭失败明确失败，不能变成零。目录重建允许最后一层变化，祖先必须保持。字节为目录项逻辑/已分配量，硬链接不去重，非原子采样，绝不称物理释放。

OperationInfo 仅 image 的 apiCompleted action 可附 cacheEffect，旧记录不补造。沿原有 actionID/eventID/processID 保存和脱敏导出，不建立第二账本。页面显示空目录、仍有残留、不可核验及前后字节，不从 API 完成数推断清理效果。

验证：C真实行为（空目录、残留、增长、零、缺测、溢出、硬链接计数）；运行器精确负对照；ObjC真实文件和同一action归属/跨轮/旧记录/未知字段；实际SDK三版目录重建、只清理/限制/关闭保持测试。当前Windows只能执行C与Python并编iOS对象，macOS/UIKit明确待执行，不能冒充设备已通过。

- [x] 内核和严格schema及反例；C精确残留反例与GREEN实际通过，ObjC七反例已写但未运行。
- [x] 原队列采样、operation action与展示接线；祖先/owner/采样后路径身份复核、失败不称空。
- [x] 当前可执行验证：C分类/效果/ReleaseEvidence、10编排回归通过；生产及测试iOS对象编译通过；独立复核无确定阻塞。
- [ ] macOS真实FS/history及三版SDK/UIKit运行：Windows无xcrun；44组全入口2组PASS/42组UNAVAILABLE，非全部通过。
- [ ] 整组通过后统一发布；CI182原安全拒绝仍单列阻塞，不绕过。

来源：SDWebImage 5.10.4及5.21.7固定版本 SDDiskCache.m 的 removeAllData；它们是行为参考，百度安装版本仍依赖既有精确镜像契约，不能由上游版本代替。

固定源码已实际HTTPS读取并SHA256核验：5.10.4 commit `a6b6e44eadf0d39250c10a7cc0e3b91d0bdb0e94`，5.21.7 commit `2de3a496eaf6df9a1312862adcfd54acd73c39c0`；记录见本地image-effect-pinned-source-20261120.json。
