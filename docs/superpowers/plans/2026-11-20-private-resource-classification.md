# 私有资源分类接入正式计量

目标：把已采证据支持的结构识别接入产品，减少反复SSH。四APP契约整组仍继续；此项不冒充已完成私有删除能力。

依据：179.2真实全容器计量已有保护文稿总量；11月19日Swiftgram完整匿名树显示共享根/未知/未知/postbox/{db,media}与共享根/未知/logs；11月20日修正探针实际捕获10次postbox/media访问，3次同UUIDPostbox ManagedFile→Darwin.open。固定Swiftgram源码ba54d9823d413f9816e5eee2724da77d5079f4cf的MediaBox.swift解释cache/short-cache结构，但结构与方法存在不授予删除许可。

选择：现有CapacityRoot增加只读布局profile、选择性五层节点；不另建容器枚举器、不把私有路径加入CleanupRules、不全机提高节点深度。类别仅结构标签，不能称引用/恢复已证。未知名继续原始字节匹配和匿名化。默认及旧记录保持三层；仅db/media深四层及media/cache深五层，未知分片汇入已有祖先，避免新增大量节点。

文件：新增AxsCacheKeeperResourceLayout.h作为无I/O的共享分类内核（结构枚举和合法父子深度）；CapacityRoot使用它分类，Service仅从本轮已校验owner/group关联选择profile，Status验证类别位置/profile/owner边界；DiagnosticsPage明确展示结构分类与未授权。纯C行为测试在Windows运行；真实FS/服务/schema用例纳入现有macOS runner，目标iOS对象编译单独报告。

- [x] C分类行为先精确RED后GREEN；未知字节、错误profile、层级错位和前缀同名均覆盖。生产仅对目录调用分类器。
- [x] 正式计量/服务/投影接线；默认三层，Swiftgram唯一owner/group的db/media到四层、cache到五层，未知分片不增加深层节点。节点上限和父子不重复相加保持。
- [x] 真实FS/服务/投影用例及集中报告展示已写；旧格式保留，结构不授删除。macOS执行仍待环境。
- [ ] 完整运行验收：本地C/11源ARM64对象编译/10编排回归通过；独立代理恢复后只读审查无确定P1/P2。macOS真实FS/服务与UIKit执行、RootHide整包仍待，Windows无Foundation。
- [x] 记录修复、剩余契约及验证条件。见docs/2026-11-20-私有结构分类与空间变化开发.md。本组完整前不提交推送；未触碰被安全审查阻断的CI进程组修复。

关联展示修复：现有ReleaseEvidence已记录每卷变化但页面仅显示“有观测”。Presentation现在显示带正负号的空闲/可用字节差、间隔、成功明细最后链接/仍有链接/未确认计数；不跨卷相加、不称独占释放。新增release receipt与UIKit文案用例，负数/零/缺失分别验证；尚待macOS/UIKit执行。

15:17验证：Windows实际C分类及原ReleaseEvidence核心PASS、10编排测试PASS；`product-final-ios-1795158965069002300`11源ARM64 iOS对象编译全0；非Theos链接/打包/手机证明。中间通用编译脚本GBK解码失败已用二进制捕获重新实编，不吞编译输出；第一次capacity测试对象编译漏测试宏，正确启用后通过。未推送。
