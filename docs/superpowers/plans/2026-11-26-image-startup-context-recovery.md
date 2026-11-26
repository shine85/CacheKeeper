# 图片实例首次配置到达前的恢复修复

目标：修复已安装观察 hook 后、首次异步配置到达前出现的 waiting owner 被永久 invalidated 的启动顺序缺陷；保留严格身份/路径/成员约束。依据新 `packages/采集报告/宿主集中预检.json` SHA256 `daec3d4e07075a52381fc6d1b85234946c618fbc3224b87e689837d54cdba5ea`，当前百度 SDK/安装身份通过但唯一登记实例 invalidated。回执不足以唯一确定真机失效分支，不能把本地复现冒称真机根因已经完全证明。

本文件新增，无旧版本可备份。用户既有诊断驱动整组修复授权适用；本轮不执行设备操作，不重试被拒的私有取证，不把此修复称作完整五 APP 采集工具。

## 不变量

- hook 回调不调用配置 provider 的文件 I/O，不把初始化改为主线程阻塞。
- 首次尚未取得有效配置/安装身份与取得后发生变化是不同状态；只允许前者在完整重验后建立一次基线。
- 构造时捕获的 owner/disk/config/memory/queue/path 保持，不能重新学习改变后的成员；保留 home 与已存在路径祖先身份，不能用 nil context 覆盖。
- 待定状态不设置 disk association、不启用写入限制、不调用清理；原写入继续传递。真实方法/安装/队列/路径变化仍拒绝，不能批量清除 invalidated。
- 主镜像因正常装载变更短时不可用继续等候；真正代码/UUID/helper变化永久拒绝。
- 若目录尚未存在，需要明确首次路径建立语义与重验边界；不得将任意 ENOENT/访问失败吞为可信。
- 首次终态失效原因应保留封闭类型信息，后续刷新不得仅用泛化 invalidated 抹掉来源。不新增地址、用户路径或私人内容输出。

## 任务与验证

1. 在 `tests/image_runtime_source_tests.m` 增加先 `startObserving`、context 未采用时构造 waiting owner、随后真实 worker 刷新的场景。用既有生产 fixture、真实文件和真实方法/队列交互，拒绝复制一个简化状态机来测试。
2. 复用 `tests/run_image_runtime_source_tests.py` 固定216产品源码作为精确 RED，断言旧版永久丢失等待实例；新实现必须同一场景 GREEN。现 Windows 无 Foundation，若无法本地执行，明确记录未运行，并使同提交云端真正运行固定旧源与当前源，不为 baseline 单独推包。
3. 成组修 `AxsCacheKeeperImageCache.m` 的首次基线等待、恢复和首次失败原因保存；只有必要时改当前封闭状态投影/头文件。现有现代/百度固定契约、已登记owner恢复、身份变化反例不得被放宽。
4. 覆盖首次配置暂不可用→有效、未绑定时原写入、完整验证后恢复准入、关闭恢复；反例至少包含owner成员/队列/路径替换、安装已绑定后变化、helper/原IMP变化、等待期间owner释放。必要时增加真实目录缺失后由SDK创建的行为，不能用静态字符串检查替代。
5. 核查 runner预算、固定历史RED接线、原生编排与对象编译。整组独立复核后统一提交（排除用户AGENTS和原未跟踪辅助），跟同SHA六job、真实SDK/UIKit/容量/RootHide、实际deb。未成功验包不要求用户测试。

本轮同步记录五host均216.1/observed、QQ两个firstObserved不同、Gurd新事件11–13全部scopeUnproven、五SDK writer均0、容量复用旧epoch和普通清理新轮次；不将这些变化归为私有适配成功。
