# UTM MoltenVK Geometry 独立实验

日期：2026-10-30。状态：**首版独立 IPA 已构建并核验；真机报告 PENDING**。

## 首版交付收据

| 交付项 | 版本 / 来源 / 验收状态 |
| --- | --- |
| Probe 源码与 Workflow | `28ba404bc4a25f804e77d9bb436276609fae7967`，分支 `experiment/moltenvk-geometry-probe`。 |
| Actions 构建、shader 与 oracle 检查 | [41006655218](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/41006655218)，成功。共享 CPU oracle 经 ASan/UBSan；9 个 Geometry entry-point SPIR-V 编译/验证成功。不是 GPU 执行。 |
| 既有项目回归 CI | [41006655172](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/41006655172)，成功；未修改正式 renderer/传输。 |
| 可自签 IPA | [artifact 12954819861](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/41006655218/artifacts/12954819861)，`MoltenVKGeometryProbe-unsigned.ipa`。CI 打包与本地 hash/结构核验通过，安装/运行 PENDING。 |
| 日志、provenance、shader 与完整对应源码 | [artifact 12955921561](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/41006655218/artifacts/12955921561)，含 `MoltenVK-complete-source.tar.gz`；7934 个归档条目，含 UTM SPIRV-Cross 与全部固定依赖源码/许可证，不是 patch-only。 |
| Vulkan Feature/Limit 设备报告 | PENDING；安装后 App 生成 `features.json`，包含完整 core features/limits、相关 extension features、扩展列表、格式位和 memory/queue 信息。未查询的扩展 feature 仍 NOT_TESTED。 |
| Geometry G1–G5 / XFB / Indirect 实际执行与图像 | PENDING；真实 GS stage 和逐用例 Oracle 已实现，不把编译成功写成设备 PASS。零 Geometry limits 时严格 BLOCKED/NOT_RUN。 |
| MobileGL 定向比较 | [固定 `08124c99` 的源码比较](mobilegl-geometry-comparison.md)，在 `e785654b50f18b27141f609bb3e9467fac876e64` 记录。源码审计完成，未构建/执行；对应实验 Actions 是上述 Probe，不是 MobileGL CI。 |
| Zink 继承门槛矩阵 | [完整清单与当前缺口](geometry-backend-feature-matrix.md)，构建源码 `28ba404` 中已包含；设备功能状态未提升。尚未固定/编译 iOS Mesa。 |
| GL/VirGL 集成与 Go/No-Go | [成本与决策](geometry-backend-integration.md)，在 `e785654` 记录；立即迁移 NO-GO，独立实验设备判断 PENDING。 |

下载后本地只做制品读取/完整性检查，未进行编译：包内与 diagnostics 的 provenance
逐字节相同；只嵌入 MoltenVK 一个 framework；App 和 framework 都是 ARM64、Mach-O
`LC_BUILD_VERSION platform=2`（iPhoneOS），SDK 18.5，App 最低 iOS17、framework 最低 iOS15。
实际打包不含 EGL/GLESv2/MobileGlues/VirGL/epoxy。App 的 PNG 诊断依赖 CoreGraphics。
framework 保留上游系统 IOKit install-name；未私自重写，实际 dyld 可用性仍待安装验证。

```text
IPA SHA256:
0a7d231085d3c51f3f828aec0f97d467163f1ecf01f3f1da93d73895c7b207b1
unsigned MoltenVK.framework/MoltenVK SHA256:
abc4c7cf817103e3ad1a20ae99ee7dcbeba7c31374ff35e69d3dae789a40ae46
complete source archive SHA256:
f014767b58a7f9afa85ccc249eb542597d6ef8253679abee9bc6b2521d47b496
```

工具链：Xcode16.4（16F6）/iPhoneOS SDK18.5/Apple clang17；shader 工具 glslang16.6.0、
SPIRV-Tools2026.4，输出目标 Vulkan1.1/SPIR-V1.3。完整工具版本及依赖 revision 随 manifest。
上游代码没有修改（`adaptations=[]`）；所有哈希为外部重签前，签名可能改变字节。
Actions 制品保留 90 天，请同时保存 IPA、manifest 和源码，不只保存 IPA。

构建历史保留：[首轮 41005899522](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/41005899522)
完成固定依赖/framework/shader 编译及源码归档后，App 因缺少 CoreGraphics 链接失败；
[41006342595](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/41006342595)
复现该错误。`28ba404` 补齐链接并通过；成功轮复用已验证的同一固定候选缓存，
没有重建或替换正式 ANGLE。失败日志保留，不改写为成功。

设备步骤：[安装、运行、分享报告](../ios/Experiments/MoltenVKGeometryProbe/README.md#iphone-steps)。
下一次验收需要用户回传完整报告与所有 actual/expected 图像；在此之前不填设备 GO。

## 范围与基线

MobileGlues 成果固化提交：`6ffef4f`。两项 TBO 代表用例真机 PASS 的运行代码仍是
`b234149c917661e499c156b3107c7cd90370181e`；Geometry、完整 B1.2、B1.3 及 guest
GL3.2 未通过。[三轮记录与真实构建链接](current-status-2026-10-29.md)保留不改。
完整修改后 LGPL 对应源码仍在原 Actions 制品中；未回写历史报告或 manifest。
A3.2 `6dd8b04c049da999b9dbd91e4c341f4a8b6d5e31` 和正式 ANGLE/VirGL/QUIC/PRESENT
均不修改。新分支：`experiment/moltenvk-geometry-probe`。

独立 Vulkan Probe 与立即集成 Zink 相比，能把底层 Geometry 执行与 GL/EGL、
context、资源互操作问题分开，影响范围与排错成本较低；因此先交付独立 IPA。
没有批准替换正式 provider、改 Mesa winsys、迁移 Venus 或开启第二完整 MobileGL 后端。

## 固定源码审计：不是只有 feature bit

依赖固定为 [utmapp/MoltenVK@2974cbb](https://github.com/utmapp/MoltenVK/tree/2974cbbbd42593eeeaf993d954702f74ae09a239)。

| 路径 | 源码事实 | 验收影响 |
| --- | --- | --- |
| `GPUObjects/MVKDevice.mm` | `geometryShader=true`；五项 `maxGeometry*` 限制均为 0。`geometryStreams` 声明旁保留 FIXME。 | 声明自相矛盾；必须记录设备返回值，不能修改限制绕过测试。 |
| `GPUObjects/MVKPipeline.mm` | Geometry pipeline 创建 `MTLMeshRenderPipelineDescriptor`；VS 变为 objectFunction，GS 变为 meshFunction，连接 FS。 | 存在独立 GPU 实现路径，不是把 GS 类型透传 GLES。不能因此宣称正确。 |
| 同文件 `addGeometryShaderToPipeline` | SPIR-V execution model Geometry，经配置 `for_mesh_pipeline` 进入 UTM SPIRV-Cross；输入拓扑有显式分支及不支持日志。 | 需真实编译和逐拓扑执行；不是通用 GS 语义证明。 |
| `Commands/MVKCmdDraw.mm` | 直接绘制计算 primitive/thread 数并调用 Metal `drawMeshThreadgroups`；firstVertex/firstInstance 有限制日志。 | 本版先用零 firstVertex/firstInstance；其他值 NOT_TESTED。 |
| 同文件 indirect 两条路径 | Geometry pipeline 分支记录错误并 return，无绘制。 | 单列 BLOCKED/UNSUPPORTED；不能用普通直接绘制替代并记 PASS。 |
| Shader converter | 读取 `needs_xfb_buffer` 并配置 XFB 隐式资源。 | 存在 XFB 代码不等于 Geometry+XFB 实际成功；需捕获记录 oracle。 |

上述文件固定 SHA256 在准备脚本中硬校验，候选源码不做适配修改。
2026-10-30 查看远端 `geometry-shaders@b5680e33d7dca891667adea0b4c35ffe905d1a66`，虽有 vertex stride/format 等定向修复，
仍有相同零 Geometry limits；没有切换依赖。后续任何修复应另记 commit/patch、
实现依据及新验收，不允许给未知能力填入好看的常数。

[UTM v5.0.2](https://github.com/utmapp/UTM/releases/tag/v5.0.2)（tag commit
`762233efc35f3aa859bf08eb5bc0bdc4ced828e1`）的依赖脚本使用 `fetchDependencies --ios`
及 iOS packaging scheme。本实验复用这些上游步骤，不运行整套 UTM/QEMU/Mesa 构建。
其发布说明也明确记录 Geometry indirect draw 的缺失，不能据其 Vulkan/DXVK 宣传
推断 Zink Linux 桌面或本项目 guest 已可用。

## 构建、测试与制品

- [源码与设备步骤](../ios/Experiments/MoltenVKGeometryProbe/README.md)。
- [独立 Workflow](../.github/workflows/build-ios-geometry-probe.yml)。
- [准备与 provenance](../tools/ci/prepare_moltenvk_geometry_probe.py)：依赖 SHA、关键源码
  哈希、未适配声明、shader 工具版本与 source/SPIR-V 哈希、框架哈希、Actions URL。
- [Zink 矩阵](geometry-backend-feature-matrix.md)、[MobileGL 源码比较](mobilegl-geometry-comparison.md)、
  [GL/VirGL 集成成本](geometry-backend-integration.md)是后续选型门槛，不是已实现集成。
- 完整对应源码和许可证随 diagnostics 制品归档；framework 缓存隔离且固定工具链/pin。
- 每个实际执行用例：32×32 全图 oracle、实际/期望 PNG、匹配与 mismatch、原始 RGBA、
  Pipeline/VkResult、fence、driver debug-utils 日志。构建成功不填设备 PASS。
- 无 Khronos validation layer 时明确 NOT_AVAILABLE/NOT_TESTED；零 driver 错误不等于
  已完成 Vulkan validation。持久化部分报告用于设备崩溃诊断。
- XFB Oracle 遵循 [Vulkan primitive capture 规则](https://docs.vulkan.org/spec/latest/chapters/vertexpostproc.html#vertexpostproc-transform-feedback)：
  strip 拆成独立三角形，四个三角形捕获十二个顶点；未启用 provoking-preservation 时允许
  单个三角形内循环旋转，但不允许反转 winding、跨 primitive 乱序、数量错误或越界写。

## 本版决策门槛

设备报告：**PENDING**。继续研究的 GO：合法 Geometry pipeline + 正确实际输出 + 所需
features/limits 真实证据 + 无能力伪造 + 有合理 GL/VirGL 集成路径；不是迁移批准。

如果设备确认 Geometry limits 为 0，本固定候选在严格门槛下 **BLOCKED**：不提交超出
声明限制的 Vulkan 程序，G1–G5/XFB/indirect 未执行不能 PASS。是否批准一个具备实证的
有限源码修复，应在收到报告后单独决定；本版不以无依据的 limits 修改修补声明。
当前无条件采用此 fork/Zink 的提案为 **NO-GO**；底层实际实验的设备判断仍 PENDING，
不能把“尚未执行”写成实际 GPU 输出失败或硬件不支持。
