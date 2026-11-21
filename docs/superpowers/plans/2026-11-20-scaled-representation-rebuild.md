# 具体缩略图的合成重建验证

沿用用户已批准的四APP保留/重取任务，先把Swiftgram general CachedScaledImageRepresentation/aspectFit的具体重建条件做成可执行验证；不接入CleanupRules，不对用户媒体或私有Swift对象执行操作。

固定源码ba54d9823d413f9816e5eee2724da77d5079f4cf：UIKitUtils.fitted先限宽再限高，两步floor，不放大；GenerateImage scale1，正尺寸才进入min1；FetchCachedRepresentations JPEG0.5。精确引用和限制见本地swiftgram-concrete-representation-20261120.md。镜像方向行为有上游特例，初始实现仅接受up的合成图片，不能声称全部orientation等效。

实现独立开发侧harness：纯C尺寸校验/拟合内核与实际运行测试；UIKit测试使用程序生成的简单PNG作为原件，在内存生成JPEG并重新解码核尺寸，原件不修改。拒绝缺原件/未complete/损坏/非静态/非up/非法或过大尺寸/取消/超过预算。不接受用户路径，不网络、不删除、不写宿主索引。将测试接已有ImageCacheIntegrationTests目标（包含新测试源），不改被拒的进程收尾runner。

- [x] 纯C先失败后通过，验证两次floor/不放大/极端比例/非有限及界限；精确不放大负对照及GREEN实际通过。
- [x] 合成UIKit helper、失败保留/最后发布取消/简单像素区域断言已写，接入已有ImageCacheIntegrationTests target；helper iOS对象实编0。
- [x] 独立复核发现发布前缺最终取消检查，已补；10原生编排测试通过、diff检查通过。
- [ ] UIKit真实执行与像素断言；Windows不具备该运行环境，当前不是实际重建成功证明。
- [ ] 安装私有ABI、活owner/资源/原件/别名与使用者绑定仍未闭合，harness不授删除。

输入像素与字节预算是开发侧合成样本约束；阶段截止/取消只在检查点生效，不能中断正在执行的系统解码或编码，不声称硬时间/峰值内存上限。当前限静态Up图片，不称与宿主全部颜色空间/方向逐像素等价。
