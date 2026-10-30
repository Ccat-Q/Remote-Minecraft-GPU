# Geometry 后端 / Zink GL 3.2 Core 功能差异矩阵

更新：2026-10-30。候选：UTM MoltenVK
`2974cbbbd42593eeeaf993d954702f74ae09a239`，独立 Probe，**设备报告 PENDING**。
App/Actions/IPA 来源见[实验记录](moltenvk-geometry-probe.md)，不引用 MobileGlues 的局部
PASS 作为该 Vulkan 候选的执行证据。

## 判定规则与文档版本

对照 [Mesa 官方 Zink 要求](https://docs.mesa3d.org/drivers/zink.html)，读取日期 2026-10-30，
范围包含 GL2.1→3.0→3.1→3.2 全部继承项。该页面为滚动文档，**尚未选定/编译 iOS Mesa
commit**，故这是本日要求清单，不是对任意 Mesa 版本都成立的适配保证。官方还提供
`VP_ZINK_requirements.json` 与 `zink_check_requirements`；将来选定 Mesa 后必须固定该版本
profile 并逐项重新对照，不能只冻结这一张人工表。GitLab 固定 revision 原文此次获取失败，
不把未核实的镜像 SHA 写成已审计官方依赖。

状态只使用以下五种：

- `PASS_DEVICE_EXECUTED`：该设备、该候选、该功能有真实执行/输出证据。
- `PASS_DECLARED_ONLY`：收到实际 API/feature/format/limit 查询证明，但未执行；不满足执行门槛。
- `BLOCKED`：具体前置条件、实现或一致性问题阻塞；备注说明是源码还是设备证据。
- `UNSUPPORTED`：有明确不支持依据；不能把未测试直接写成此状态。
- `NOT_TESTED`：尚无足够设备证据。源码声明 true 也不自动提升为设备查询通过。

当前 **没有任何该候选的 `PASS_DEVICE_EXECUTED` 或 `PASS_DECLARED_ONLY`**。
下表“源码”均指固定 fork 的审计，不冒充设备报告。

## 继承要求清单

扩展名称省略统一前缀 `VK_`；成员保留 Vulkan 原名。扩展提升到 core 时仍须检查对应
feature 和语义，不能仅因 API 版本高就认定全部符合。源码扩展表为 `Layers/MVKExtensions.def`，
feature/limit 实现为 `GPUObjects/MVKDevice.mm`。

| GL 门槛 | Vulkan 要求 | 状态 | 当前证据 / 尚需验证 |
| --- | --- | --- | --- |
| 2.1 | API ≥1.0 | NOT_TESTED | IPA 查询 loader/physical API，待设备。 |
| 2.1 | logicOp | BLOCKED | 源码取决于 `useMetalPrivateAPI`；本实验不启用私人 API。待设备确认，不以配置强开解决。 |
| 2.1 | fillModeNonSolid | NOT_TESTED | 源码声明；线框执行未覆盖。 |
| 2.1 | alphaToOne | NOT_TESTED | 源码声明；多重采样语义未覆盖。 |
| 2.1 | shaderClipDistance | NOT_TESTED | 源码声明；裁剪 shader 未覆盖。 |
| 2.1 | independentBlend | NOT_TESTED | 源码声明；多附件不同混合未覆盖。 |
| 2.1 | KHR_maintenance1 | NOT_TESTED | 待扩展/core 查询与相关执行。 |
| 2.1 | KHR_maintenance5 | NOT_TESTED | 源码扩展表存在；未执行。 |
| 2.1 | KHR_create_renderpass2 | NOT_TESTED | Probe 使用基础 render pass，不代表 renderpass2 通过。 |
| 2.1 | KHR_imageless_framebuffer | NOT_TESTED | 记录 core1.2 feature；Probe 非 imageless。 |
| 2.1 | KHR_timeline_semaphore | NOT_TESTED | 记录声明；基础 fence 不证明 timeline。 |
| 2.1 | KHR_dynamic_rendering | NOT_TESTED | 记录声明；Probe 未用动态渲染。 |
| 2.1 | EXT_robustness2 或 KHR_robustness2 + nullDescriptor | NOT_TESTED | 源码存在；Probe 查询 EXT feature（若可用），不执行 null descriptor。 |
| 2.1 | EXT_custom_border_color + customBorderColorWithoutFormat | BLOCKED | 固定源码扩展表未见该扩展；待设备枚举确认。无应用端豁免。 |
| 2.1 | EXT_provoking_vertex | NOT_TESTED | 记录声明；顶点 provoking 语义未覆盖。 |
| 2.1 | EXT_line_rasterization / rectangularLines | NOT_TESTED | 查询 feature；一条普通线不是全部模式执行。 |
| 2.1 | 同扩展 / bresenhamLines | NOT_TESTED | 查询 feature；未执行。 |
| 2.1 | 同扩展 / smoothLines | NOT_TESTED | 查询 feature；未执行。 |
| 2.1 | 同扩展 / stippledRectangularLines | NOT_TESTED | 查询 feature；未执行。 |
| 2.1 | 同扩展 / stippledBresenhamLines | NOT_TESTED | 查询 feature；未执行。 |
| 2.1 | 同扩展 / stippledSmoothLines | NOT_TESTED | 查询 feature；未执行。 |
| 2.1 | KHR_swapchain_mutable_format | NOT_TESTED | Probe 离屏不使用 swapchain。 |
| 2.1 | EXT_border_color_swizzle | BLOCKED | 固定源码扩展表未见；待设备枚举。 |
| 2.1 | KHR_descriptor_update_template | NOT_TESTED | 普通 descriptor 更新不等于 template。 |
| 2.1 / DRI | KHR_external_memory | NOT_TESTED | 官方限定 DRI 路径；iOS Host EGL 路径未选择，不直接套用 Linux FD 方案。 |
| 2.1 | EXT_scalar_block_layout 或 core1.2 + scalarBlockLayout | NOT_TESTED | 查询声明；非标准标量布局 shader 未执行。 |
| 3.0 | EXT_transform_feedback | NOT_TESTED | 源码存在；X1 单列且有 GS limit 前置门槛。 |
| 3.0 | EXT_conditional_rendering | BLOCKED | 固定源码扩展表未见；待设备确认。 |
| 3.0 | D32_SFLOAT / depth-stencil attachment | NOT_TESTED | 记录格式位；尚未创建该深度附件绘制。 |
| 3.0 | D32_SFLOAT_S8_UINT / depth-stencil attachment | NOT_TESTED | 记录格式位；未执行。 |
| 3.0 | D32_SFLOAT_S8_UINT / sampled image | NOT_TESTED | 记录格式位；未执行。 |
| 3.0 | B10G11R11_UFLOAT_PACK32 / color attachment | NOT_TESTED | 记录格式位；未执行。 |
| 3.1 | maxPerStageDescriptorSamplers ≥16 | NOT_TESTED | 全 limits 导出；不以单 sampler 用例替代限制验收。 |
| 3.1 | maxPerStageDescriptorUniformBuffers ≥13 | NOT_TESTED | 同上；单 UBO 不能证明 13 个。 |
| 3.2 | depthClamp | NOT_TESTED | 源码声明 true；Probe 不执行深度 clamp。 |
| 3.2 | geometryShader | BLOCKED | 有 Metal mesh 实现，但五项 Geometry limits 源码为零；待设备确认。 |
| 3.2 | shaderTessellationAndGeometryPointSize | NOT_TESTED | 查询 core feature；G2 point 输出受此门槛约束。 |
| 3.2 | EXT_depth_clip_enable | BLOCKED | 源码表只有 `EXT_depth_clip_control`，不是同一扩展，不能替代。 |

## 实际语义、资源与限制补充门槛

这些是目标兼容路径还需要的工程验收，不把它们全部称为官方 Zink 文档的额外硬性条目。
Geometry 限制属于 Vulkan 实现需真实报告并满足所用 shader 的约束，详见
[Vulkan limits](https://docs.vulkan.org/refpages/latest/refpages/source/VkPhysicalDeviceLimits.html)。

| 项目 | 状态 | Probe 覆盖 / 缺口 |
| --- | --- | --- |
| VS/FS shader 翻译与实际执行 | NOT_TESTED | C0 两色、全图及 fence；仅实际报告到达后改变状态。 |
| GS shader→SPIR-V→MSL→GPU | BLOCKED | nine real GS SPIR-V fixtures；零 limits 时 pipeline/draw NOT_RUN。 |
| maxGeometryShaderInvocations | BLOCKED | 源码为 0；G3 需要 2。 |
| maxGeometryInputComponents | BLOCKED | 源码为 0；需 input varying。 |
| maxGeometryOutputComponents | BLOCKED | 源码为 0；按含 builtin/varying 的实际输出检查。 |
| maxGeometryOutputVertices | BLOCKED | 源码为 0；本代表用例最多声明 8。 |
| maxGeometryTotalOutputComponents | BLOCKED | 源码为 0；不能只看顶点数。 |
| GS triangles/lines/points、strip、插值/ID/invocation | NOT_TESTED | 每例独立日志；前置 BLOCKED 不成为 skip-PASS。 |
| GS + transform feedback | NOT_TESTED | X1 独立三角形捕获、允许规范内循环顶点旋转、字节 counter 与像素；多 streams/counter resume/非 GS 基线未覆盖。 |
| GS + indirect / indexed indirect | UNSUPPORTED | 固定源码两路径明确 return；实际图像测试仍受限额门槛阻塞，无设备 PASS。 |
| R8I/RGBA32F TBO on Vulkan/Zink | NOT_TESTED | MobileGlues TBO PASS 不可搬用；当前 Probe 不测试 TBO。 |
| 纹理尺寸/数组/mip/压缩/采样/缓冲格式 | NOT_TESTED | 全 core limits + 四格式位，非逐格式执行。 |
| RGBA8 FBO/render pass/transfer | NOT_TESTED | C0 与实际执行 GS 用例可提供小尺寸证据；不是所有 FBO/renderpass 语义。 |
| Buffer alignment/range/映射/可见性 | NOT_TESTED | 全 core limits、memory heaps/types；实际 host-visible 内存 flush/invalidate，非所有映射模式。 |
| Fence / 资源复用与释放 | NOT_TESTED | 逐提交有界 fence 后才读/改/释放；不是跨队列/并行在途取消或 timeline。 |
| Vulkan validation | NOT_TESTED | 未打包 Khronos validation layer；缺失时明确报告不可用，driver debug-utils 不等价。 |
| Metal texture / IOSurface 零 CPU 复制 | NOT_TESTED | 本地诊断 readback 不涉及正式显示；需未来独立互操作验证。 |
| Zink iOS 编译、GL/EGL Host API、GL3.2 实际语义 | NOT_TESTED | 本轮没有构建 Zink，也未批准整合。 |
| VirGL context/share/resource ID/fence 对接 | NOT_TESTED | 见[集成成本分析](geometry-backend-integration.md)。 |
| Ubuntu Minecraft 1.21.1 + NeoForge/Mods | NOT_TESTED | 本轮不运行游戏，不改 JVM、guest 或协议。 |

## 当前技术判断

即使将来 Geometry 基础输出通过，仍至少有 border-color、conditional rendering、depth-clip
等源码层差距，且普通公开 Metal 路径的 logicOp 声明需要核实。故 **Geometry PASS 不是 Zink
GL3.2 GO**。当前选型只能保持条件性候选，不能承诺完整 Minecraft 或任意大型 Modpack。
尚无目标工作负载的 API trace；indirect 是否影响某个具体 Mod 不可猜测，须以原始负载证据
分析，不能修改 Minecraft 或悄悄替换 trace 来绕过缺失。
