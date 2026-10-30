# Geometry 候选与现有 VirGL 集成成本

日期：2026-10-30。技术选型分析，**不是集成批准**。当前纯 Vulkan 设备结果 PENDING，
没有编译/运行 Zink iOS，也没有可工作的替换 Host GL provider。正式 A3.2 保持不变。

## 缺失环节必须有实体

```text
Ubuntu virpipe → VirGL/vtest → QUIC → iPhone virglrenderer
                                         ↓ Host GL/EGL API
                          候选 GL frontend + context/screen/资源桥
                              （Zink + iOS Mesa/EGL？或 MobileGL？）
                                         ↓ Vulkan
                                  UTM MoltenVK → Metal
```

上图中问号尚未实现。MoltenVK 提供 Vulkan，不提供 virglrenderer 现有 GL/EGL 接口；
Gallium Zink 也不是复制一个 dylib 就能替换 GLESv2.framework 的 drop-in provider。

## 两种有范围的后续候选

| 方案 | 可复用部分 | 复杂度/风险与成本 | 当前建议 |
| --- | --- | --- | --- |
| Mesa Zink + 经验证的 iOS GL/EGL frontend | Mesa 的桌面 GL/Gallium 语义与 Zink 翻译；保留 virglrenderer/vtest/QUIC | 需固定 Mesa、满足完整继承 Vulkan 要求、实现/选择 iOS screen/loader/WSI/EGL 路径；依赖与长期维护面较大。 | 先依据功能矩阵排除硬缺口，未满足前不开始完整编译/集成。 |
| MobileGL DirectVulkan frontend | 已有 GL/EGL 状态与 Vulkan backend，源码存在 GS stage | 不是完整一致性保证；UIKit/pbuffer、provider、shader/GL 限制、共享和 IOSurface 仍需验证。维护面不同而非更低风险已证实。 | 源码路径值得保留，底层通过后需批准独立 GL Probe；本轮不实现。 |

不考虑直接把当前 virglrenderer 接到 Vulkan，也不把 Venus 当本轮迁移目标。

## 逐项集成门槛

| 领域 | 真实需要的实现/实验 | 当前状态与对 A3.2 的影响 |
| --- | --- | --- |
| iOS Zink 可构建/运行 | 固定 Mesa SHA 与工具链，iOS ARM64 shader compiler、Vulkan loader/device、Gallium screen/context，验证桌面 GL3.2。 | NOT_TESTED。当前 Zink 官方要求不被固定 MoltenVK 的声明完整满足。不能声称 iOS 已有可用 Zink。 |
| Host GL/EGL API | virglrenderer 用到的 desktop GL / GLES / EGL config、context、FBO、纹理及扩展语义必须由真实 frontend 提供。 | NOT_TESTED。不能把 Vulkan handle 填入 EGLContext。 |
| libepoxy dispatch | 明确每个 GL/EGL 入口归属、proc resolver、desktop/ES 版本分支，必要时独立构建/适配 dispatch。 | 只可在未来隔离实验做，不改正式 epoxy/provider。不能使用 RTLD_DEFAULT 混入系统 OpenGLES。 |
| context ownership | frontend context→Gallium/Vulkan device/queue 的拥有权、TLS、共享、make-current/线程迁移和销毁顺序。 | NOT_TESTED。MobileGlues B1.1 结果不能复用到新 provider。 |
| VirGL resource ID | 仍由 virglrenderer 维护 guest ID 与 host texture；新 host storage、重定义、UNREF/名称复用及 framebuffer 完成语义需验证。 | 传输 ID/协议保持，不允许跨 API 把 GL texture GLuint 当成 VkImage。 |
| sharing / synchronization | Host GL fence 与 Vulkan queue completion、MoltenVK/Metal completion 之间需可证明排序；多 context/device 的共享不能只靠句柄相等。 | NOT_TESTED。独立 Probe 的串行 VkFence 不覆盖此桥。 |
| texture→IOSurface | 查询 Metal/external-memory 能力，证明 VkImage 对应 MTLTexture 或可 GPU copy 到 IOSurface-backed destination；格式/布局/使用权限/生命周期均匹配。 | NOT_TESTED。`VK_EXT_external_memory_metal` 等源码存在不等于双向零复制可用。不得用 readback 代替正常显示。 |
| 是否增加 GPU copy | 若不能直接互操作，则需要 Vulkan/Metal 之间额外 GPU copy 和有界 staging/ownership；先实测，不假设零成本。 | copy 数、带宽、完成 Fence 与 slot 退休都可能变化。CPU framebuffer 串流不是退路。 |
| 两槽/backpressure | 现有 slot admission、两槽占满背压、snapshot 不被后续写覆盖、GPU完成后退休、最后一帧保持需在新资源桥重验。 | 不改当前通过版本；未来新候选需独立 A3.2 回归，不能从 Probe PASS 继承。 |
| 缓存/依赖升级 | MoltenVK shader converter fork、Mesa/Zink profile、GL frontend、epoxy版本组成固定矩阵；编译缓存按 recipe/toolchain 分离。 | 补丁与上游行为差异长期需要回归；新运行时不得污染 accepted ANGLE 缓存。 |
| 平台与许可证 | Vulkan/Metal 支持的公开接口、shader 编译器与第三方许可证、完整修改后 LGPL 源码交付。 | 本 Probe 保留原始对应源码；未来 frontend 适配另有对应义务。 |

Vulkan API 与执行区别及 Zink 门槛依据：[Vulkan stage 有效使用要求](https://docs.vulkan.org/refpages/latest/refpages/source/VkPipelineShaderStageCreateInfo.html)、
[Mesa 官方 Zink 要求](https://docs.mesa3d.org/drivers/zink.html)。本表其他内容是对当前工程接口
的集成推理，不冒充已经完成的 iOS port 或设备测试。

## 决策

- 现有 A3.2：保持已验收状态，A3.3 可独立推进，不依赖 MoltenVK。此轮未修改 A3.3。
- 立即替换正式 Host GL backend：**NO-GO**，缺少合法 GS/完整 Vulkan 要求和 GL/EGL/资源桥实证。
- 继续底层独立实验：**PENDING / 条件性候选**；先交 IPA、拿真实报告。
- 若仅基础 GS 通过而 indirect/XFB 不完整：应记录 **CONDITIONAL**，不能宣称 GL3.2 或 Modpack
  通过。GL3.2 的 XFB 及 Zink 继承要求可能直接阻塞；indirect 超出部分 GL3.2 基本调用范围，
  但不能据此假设 Minecraft/未来 Mod 不使用它，需真实目标 trace 和独立 GL frontend 验证。
- 若设备确认零限额：报告 BLOCKED，保留此 pin 与测试；下一步只能是有依据且受控的
  源码修复或比较候选，不能自动更换架构、修改能力字符串或省略 stage。

在当前证据下无法给出可信迁移工期、FPS 或“大型 Modpack 必然可运行”的承诺。
