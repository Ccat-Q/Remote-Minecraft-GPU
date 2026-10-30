# MobileGL Geometry 定向源码比较

日期：2026-10-30。只读源码审计，不是第二完整后端实现或设备验收。
固定 [MobileGL commit 08124c99f12ab2283cc15e4dc64ea972ecbd49c1](https://github.com/MobileGL-Dev/MobileGL/tree/08124c99f12ab2283cc15e4dc64ea972ecbd49c1)，
复用此前记录的 snapshot，未切换 main。该审计未编译 MobileGL、未生成其 IPA、未运行其
CI/设备测试；不能给它补写本项目的 Actions 成功链接。

## 结论

**存在值得后续单独验证的 DirectVulkan 实现，不应把 MobileGL 简化为“只有字符串”或
“只有 GLES 透传”。但它依然要求底层 Vulkan 接受真实 Geometry stage；没有发现可绕过
本次 UTM Geometry limits/indirect 缺口的独立 GS→Compute 通用实现。**

| 问题 | 固定源码事实 | 判断 |
| --- | --- | --- |
| 真正 Geometry stage？ | `DirectVulkan/Renderer/ProgramFactory.cpp` 将 Geometry 映射为 `VK_SHADER_STAGE_GEOMETRY_BIT`，stage/module 进入 `PipelineFactory.cpp` 的 `vkCreateGraphicsPipelines`。 | 有真实 Vulkan GS 路径；正确性依赖具体 Vulkan provider 与执行证据。 |
| 只是 GLES 透传？ | `DirectGLES/Managers.cpp` 编译翻译后 ESSL、调用 GLES shader 创建/编译；几何相关扩展按底层支持配置。 | DirectGLES 仍受当前 ANGLE Metal 不接受 GS 的限制。不能仅换 frontend 解决。 |
| Vulkan backend？ | `CMakeLists.txt` 编译 DirectVulkan renderer、pipeline/program/buffer/texture managers；`VulkanRenderer.cpp` 查询并启用实际 `geometryShader`。 | 确有另一种 GL→Vulkan 兼容候选，不是 Zink 的别名。 |
| GS→Compute 等价实现？ | 阅读 shader/program/pipeline 和 draw 路径，Geometry 作为 Vulkan GS 提交；未见当底层 GS 不可用时改写为完整等价 compute 的分支。 | 本 snapshot 没有证实可独立补齐 MoltenVK GS 的通用替代方案。不是宣称所有未来代码都不可能有。 |
| iOS 构建输入？ | `MOBILEGL_IOS`、`MOBILEGL_VULKAN_LIBRARY` 和 Apple framework 链接选项存在。 | 只是接口；不等于这个组合已在本设备构建/运行成功。 |
| Metal provider/surface？ | 有 `vkCreateMetalSurfaceEXT`/CAMetalLayer 分支；Apple internal pbuffer helper 查找 `NSWindow`。 | UIKit iOS 没有 NSWindow。离屏/context 初始化需选择并验证 UIKit/无 WSI 路径，不能把 macOS helper 当 iOS 现成可用。 |
| 声明与执行一致？ | frontend getter 中还有固定 Geometry 限制；动态后端 feature、point-size refusal 等路径另存在。 | 查询值必须与实际 provider 逐项比对；不把固定 frontend 值作为能力证据。 |
| 测试证据？ | `MG_IntegrationTest/Scenarios/GeometryDrawModeScenario.cpp` 创建真实 context/program，验证 topology/API 错误、捕获路径；还有不支持时 skip。 | 是测试源码，不是 iPhone/A19 执行报告；skip 不能算 PASS。 |
| Indirect/反馈组合？ | Vulkan renderer 有 indirect calls、GS/XFB 路径与 barrier；仍提交到底层 Vulkan。 | UTM pin 的 GS indirect return 不会因上层调用存在而消失。 |

源码锚点（均为上述 commit）：

- [构建输入](https://github.com/MobileGL-Dev/MobileGL/blob/08124c99f12ab2283cc15e4dc64ea972ecbd49c1/CMakeLists.txt)
- [Vulkan renderer / 逻辑设备与 Metal surface](https://github.com/MobileGL-Dev/MobileGL/blob/08124c99f12ab2283cc15e4dc64ea972ecbd49c1/MobileGL/MG_Backend/DirectVulkan/Renderer/VulkanRenderer.cpp)
- [ProgramFactory](https://github.com/MobileGL-Dev/MobileGL/blob/08124c99f12ab2283cc15e4dc64ea972ecbd49c1/MobileGL/MG_Backend/DirectVulkan/Renderer/ProgramFactory.cpp)
- [PipelineFactory](https://github.com/MobileGL-Dev/MobileGL/blob/08124c99f12ab2283cc15e4dc64ea972ecbd49c1/MobileGL/MG_Backend/DirectVulkan/Renderer/PipelineFactory.cpp)
- [真实 context 测试源码](https://github.com/MobileGL-Dev/MobileGL/blob/08124c99f12ab2283cc15e4dc64ea972ecbd49c1/MobileGL/MG_IntegrationTest/Scenarios/GeometryDrawModeScenario.cpp)

## 有条件的最小后续实验（未批准实施）

仅在底层合法 Geometry 真机输出通过、且用户批准下一 GL 兼容实验后考虑：新 bundle，
固定本 snapshot 与完整 LGPL-3.0-only 对应源码，关闭 DirectGLES 选择 DirectVulkan，
先解决显式 provider 与 UIKit/离屏 surface/context，再测试桌面 GLSL150 VS/GS/FS、
TBO、共享/同步和实际像素。先不连接 VirGL/QUIC，也不换正式 EGL。

成本比当前纯 Vulkan Probe 高：需新前端及 shader 依赖构建、provider 绑定、EGL context
拥有权、离屏输出和资源生命周期验证。比从零开发 GL frontend 少，但不能可靠承诺工期。
在底层 GS limits/indirect 缺口解决前编译整套 MobileGL 不会增加关键证据，因此本轮不启动。

关键文件 SHA256（便于以后复核 snapshot，而不是改写上游）：

| 文件 | SHA256 |
| --- | --- |
| CMakeLists.txt | `ae50d79284be958b23c7052bf8285c651ed614af6320d09ffb3162b5105f4d47` |
| VulkanRenderer.cpp | `37fab51a223a35563866a63ee84db63fe9c2540e70ab71a4314f3e57d36cd92a` |
| ProgramFactory.cpp | `8cf890a484b2183c3a5287a681b284c012a210bd847e371298e511af16a492a5` |
| PipelineFactory.cpp | `28fcfb76d4dc55676d5064b5ec4d6c6815eb0bf0a33795933be1ded0ee0bce8e` |
