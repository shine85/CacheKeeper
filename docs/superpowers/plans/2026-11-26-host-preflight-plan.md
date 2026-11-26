# 五 APP 宿主预检实现计划

**规格：**`docs/superpowers/specs/2026-11-26-host-preflight-design.md`。

- [ ] 批次层 `AxsCacheKeeperHostPreflight.h/.m`：固定五目标列表唯一入口；复用现有client，start/poll/cancel/retry-save/snapshot。新增Foundation行为用例并接host evidence runner；代理只改该层及其用例。
- [ ] 页面 `Prefs/HostPreflightPage.h/.m`：按钮、状态列表、真实离页取消、后台保留、返回轮询；DiagnosticsPage加入口，Makefile及UI工程/容量独立runner纳入依赖。主流程负责。
- [ ] UIKit测试：借鉴现有实际控制器隔离方式，测试五项、失败、保存、前后台与离页；独立代理只改新测试，主流程接线。
- [ ] 本地可执行检查、旧collection/编排回归、SDK编译检查；独立完整审查。Foundation/UIKit需macOS，同提交CI验证，不把Windows对象编译当行为通过。
- [ ] 整组相关工具与产品变更统一提交推送，跟进同SHA Actions，验deb并给出集中手机步骤；无关AGENTS/SSH/临时产物不提交。若云端失败集中修正并复验。

不得新增取证协议、手机执行脚本、进程附加、权限请求或资源动作。现有HostEvidence不经身份认证的边界与timeout未知语义不变；避免把预检完成等同五APP适配完成。
