# RemoteGPU 可行性与源码审计

日期：2026-10-12。仓库基线：`816bf85bde34accc6bbc9a3cfe1757c6bb21df43`。

这是审计交付物，不是新的架构决定。未修改应用、依赖、既有 `/docs`、DNS 或部署；未本地编译、启动 Minecraft 或触发 Actions。上游公开源码只下载到临时目录进行阅读。

## 1. 结论与决策边界

**用户目标没有被否定，但当前锁定的 VirGL → ANGLE Metal 版本组合不满足现代 Minecraft 的能力门槛。现在不能按原计划直接推进到 Minecraft 或承诺第一版完成日期。**

应区分三个问题：

1. 远程 Ubuntu 运行完整 Java 客户端，而手机执行 GPU 渲染：架构上没有发现必须改成视频串流、重写 Minecraft 或把 JVM 搬到手机的理由；完整可用性尚未证明。
2. 当前依赖不变、只完善 QUIC/PRESENT：不能解决现已观察到的 GLSL 130 阻塞。传输正确不等于图形接口充分。
3. Minecraft 1.21.1 + 数百个 Mod：比 Vanilla 门槛高得多，不能从三角形、GL 版本字符串或 JVM 正常运行推导兼容性。

推荐下一步是**有退出条件的渲染能力选型实验**，不是大规模补齐 ANGLE，也不是直接全面迁移 Venus。先找到真机上满足所需功能的本地 renderer，再接入远程传输。现有协议、Linux winsys hook、原生 decoder 和 Actions 缓存仍有复用价值。

## 2. 审计方法与证据等级

使用 Exa 从 Mesa/VirGL、ANGLE、UTM、备选兼容层/Vulkan、Minecraft/Mod 五个方向检索了 70 个候选结果条目（14 次检索，含重复结果）。筛除二手转载，重点对照项目自身文档、实际源码和用户提供的真机证据。检索返回的介绍或功能声明不视为运行验收。

- **已观察事实**：用户提供的 iPhone 报告和截图；本机硬件/内存只读检查。
- **源码事实**：锁定 commit 的分支、上限、功能映射以及当前仓库代码。
- **推理**：这些机制对目标的影响；未运行复现的代码风险明确标记。
- **未验证**：手机端 Ubuntu guest context、远程 VirGL 绘制、连续呈现、Minecraft 和 Mod 性能。

锁定版本：Mesa `590bf21d918c86908d96d1f4590ecd25b9657171`；UTM `9d00a54833184628c696bcbfafbf344cea566e59`；UTM virglrenderer `482f9d8b8c2d2288efa10a027116216909d2c226`；UTM WebKit/ANGLE `ed78ab6e1a37f4f11583a0bd038f22ec91f3ff10`。

另查 UTM 锁定配置中的 MoltenVK fork `2974cbbbd42593eeeaf993d954702f74ae09a239`。**这个 fork 不在 RemoteGPU 当前 renderer sysroot 中**：我们的构建显式禁用 Venus/Neptune，也排除了 Vulkan 依赖。Khronos MoltenVK 和部分其他项目的 `main/dev` 仅作审计当日候选参考，不是经过验收的新依赖。

来源：[UTM 锁定依赖配置](https://github.com/utmapp/UTM/blob/9d00a54833184628c696bcbfafbf344cea566e59/patches/sources)、仓库 `ios/DEPENDENCIES.md` 和 `tools/ci/prepare_utm_renderer.py`。

## 3. 目前究竟证明了什么

| 项目 | 审计状态 | 不能据此推导的内容 |
| --- | --- | --- |
| Linux Mesa virpipe 经 QUIC 到 Linux renderer | 仓库记录有 Actions 渲染/协议验收 | 不等于 Apple GPU 验收；Linux gate 使用软件 renderer |
| Mesa display hook 不做正常显示 TRANSFER_GET | Linux gate 有对应证据 | 不等于 iPhone 已接管 PRESENT |
| iPhone ANGLE Metal → IOSurface → Metal 显示 | 用户截图确认橙色三角形，方向已修正 | 是手机本地 GLES demo，不是 Ubuntu 下发的 VirGL draw |
| iPhone native vtest context + capsets | 用户报告 PASS | CREATE_RENDERER/GET_CAPS 成功不代表 shader、draw 和呈现成功 |
| Host GLES 3.0 / GLSL ES 3.00 | 用户日志确认 | Host GLES 和 guest desktop GL 不是同一个 API |
| GLES 3.1、3.2 请求 | 用户日志显示 EGL 0x3004 拒绝 | 不能用版本覆盖替代真实实现 |
| Guest GLSL feature level | capsets 1/2 均报告 130 | 未通过计划中的 GLSL 150 门槛 |
| iPhone QUIC capability endpoint | 已实现、Actions 构建通过 | 没有本次提供的端到端真机网络运行证据 |
| 远程显示 / Minecraft / 输入 / 音频 | 未完成对应验收 | 不能称为可玩的第一版 |

截图上的 `632 ms` 没有明确的稳态帧时间定义，不能换算成 FPS 或作为 GPU 性能结论。当前三角形路径有同步等待，是一次性诊断而非持续渲染基准。

## 4. 当前图形路线的根因

### 4.1 GLES 上限不是 Context 参数写错

锁定 ANGLE Metal 的 `mtl_common.h` 定义最大支持版本为 GLES 3.0；`DisplayMtl::getMaxSupportedESVersion()` 使用此值。它的 `getMaxSupportedDesktopVersion()` 返回无效值，因此不能通过切换 EGL API 把这套后端变成桌面 OpenGL。

真机请求 3.1/3.2 被拒，与源码一致。再重复同一测试、修改 Java 参数或重建同一套依赖，没有依据认为能改变结果。ANGLE 当前官方支持表也只将 Metal 的 GLES 3.0 标为完整支持；不能将 Vulkan backend 的 GLES 3.2 支持套用到 Metal backend。

来源：[锁定 ANGLE Metal 上限](https://github.com/utmapp/WebKit/blob/ed78ab6e1a37f4f11583a0bd038f22ec91f3ff10/Source/ThirdParty/ANGLE/src/libANGLE/renderer/metal/mtl_common.h)、[DisplayMtl 实现](https://github.com/utmapp/WebKit/blob/ed78ab6e1a37f4f11583a0bd038f22ec91f3ff10/Source/ThirdParty/ANGLE/src/libANGLE/renderer/metal/DisplayMtl.mm)、[ANGLE 官方支持表](https://chromium.googlesource.com/angle/angle/+/main/README.md)。

### 4.2 VirGL 能力映射是决定性阻塞，但不是唯一待查功能

锁定 renderer 的 `vrend_fill_caps_glsl_version()` 在 GLES 3.0 分支报告 guest GLSL 130。Apple 桌面 GL 的特殊处理要求桌面 context，不适用于此处的 GLES context。

锁定 Mesa 的 `version.c::compute_version()` 要求 GL 3.2 的 GLSL 至少为 150，且继承 GL 3.0/3.1 的条件，并检查 depth clamp、base-vertex、fragment-coordinate conventions、provoking vertex、sync、multisample 等能力。因此 130 已足够使当前组合不能通过；即便改变这个数值，其余语义也不能凭空出现。

还应特别注意：GLES 3.1 与桌面 GL 3.2 不存在简单一一对应。实际扩展、限制和翻译实现比版本数字更重要。geometry shader、texture buffer 等桌面功能需要分别评估，不能仅据一个版本阈值声称完整兼容。

来源：[VirGL 锁定 renderer](https://github.com/utmapp/virglrenderer/blob/482f9d8b8c2d2288efa10a027116216909d2c226/src/vrend/vrend_renderer.c)、[Mesa 锁定 version.c](https://gitlab.freedesktop.org/mesa/mesa/-/blob/590bf21d918c86908d96d1f4590ecd25b9657171/src/mesa/main/version.c)、[Mesa 锁定 VirGL screen](https://gitlab.freedesktop.org/mesa/mesa/-/blob/590bf21d918c86908d96d1f4590ecd25b9657171/src/gallium/drivers/virgl/virgl_screen.c)。

### 4.3 不应把所有检查项都列成已确认缺失

- Depth clamp：锁定 ANGLE Metal 已有条件启用 `GL_EXT_depth_clamp` 的代码；不能说 Metal 不支持它。应以手机扩展列表及实际 draw 语义验证。当前报告没有完整扩展 dump。
- Geometry shader：GLES 3.0 本身不保证此功能；当前 Metal 路线没有本次可用的功能验收。需要 shader-stage、输出限制和执行测试，而不是只检查 GLSL 数值。
- Texture buffer：需要检查 host 扩展、VirGL 的 `max_tbo_size`、Mesa 暴露状态及真实采样。当前 App 摘要没有展示完整这组数据，不能用摘要代替全面审计。
- Timer query：锁定 Metal backend 显式不暴露 disjoint timer query，时间戳精度设为 0。需要与基础 Minecraft 要求分开，见代码发现 F2。
- FBO、VAO、instancing、sync：Host GLES 3.0 提供相关基础，但 VirGL 翻译、格式、错误路径及跨 API 同步仍要执行验证。

来源仍为上述锁定 ANGLE/VirGL/Mesa 源码。这里区分“可用代码”“被声明支持”和“真机执行正确”，不把推断写成测试 PASS。

### 4.4 samples 的 1/8 差异有出处

用户报告中 capset 2 是 1，capset 1 是 8。锁定 UTM fork 在 v2 的 ANGLE/Metal 路径对最大 samples 做兼容降级，目的是触发 Mesa 的 fake-SW-MSAA 处理。不是 App 固定偏移读错的证据，也不证明 MSAA 所有格式正确。

同一 fork 还存在能力兼容调整。应审计其实际执行路径，不应把 fork 的 capability 声明视为自动通过完整 GL conformance；RemoteGPU 自身也不能再靠覆盖字符串或无实现支撑地升高 cap 值“修复”。

## 5. 哪些替代路线值得试

| 路线 | 是否保留用户目标 | 审计判断 | 成本/主要风险 |
| --- | --- | --- | --- |
| 当前 VirGL + ANGLE Metal 不变 | 是 | 当前 gate 不通过，不能直接用于目标版本 | 继续做网络或缓存不会补齐图形能力 |
| 在现有 ANGLE/VirGL 补齐桌面能力 | 是 | 理论可研究，不应当作小补丁 | shader 翻译、功能仿真、测试维护成本很高；仅补 Vanilla 子集不保证 Mods |
| VirGL → 手机端 OpenGL/Vulkan 兼容层 → MoltenVK | 是，且有机会保留旧 vtest | 候选；要先证明手机本地能力 | iOS 的 Mesa/Zink 或 ANGLE Vulkan 集成不是现成替换；仍受 Vulkan 特性约束 |
| Ubuntu Zink → Venus → 网络 → MoltenVK | 是 | 有潜力，但比原计划所述更难 | FD/shared-memory/blob/ring/mapped-memory 语义必须改造，现有 protocol 0 bridge 不能直接承载 |
| 复用 MobileGlues / MobileGL | 是，但需新增集成设计 | 值得做定向评估，不是已验证方案 | 项目宣称或 Android 测试不等于 A19 + ANGLE Metal；也不自动提供 Gallium/vtest 接口 |
| GL4ES 或 macOS CoreGL | 前者不足、后者不适用目标设备 | 不作为直接解法 | GL4ES 官方主要目标是桌面 GL 2.x；UTM 的 CoreGL 4.1 路径仅 macOS |

### 5.1 Vulkan 路线不是“版本更高，所以必然成功”

Zink 官方 GL 3.2 要求包含 `geometryShader`、`depthClamp`、相关 point-size 功能与 depth-clip 扩展，且还继承更低 GL 等级的要求。必须检查整个需求集合，不是单测三角形或只看到 Vulkan 1.3/1.4。

审计当日读取的 Khronos MoltenVK `MVKDevice.mm` 从清零的 features 开始，没有在该初始化路径启用 `geometryShader`。因此不能认为换成标准 MoltenVK 就自动解决 Zink 的 geometry 要求。

UTM 锁定 MoltenVK fork 不同：它声明 geometryShader，并加入 transform-feedback 处理；源码也有明确的兼容性 FIXME。因此这个 fork 是具体候选，但必须在 A19 真机执行 geometry、transform-feedback、间接绘制和同步测试。UTM v5.0.2 发布说明还记录了 geometry 间接绘制方面的已知限制；“声明为 true”不等于满足 Zink/目标 Mod 的全部组合。

来源：[Zink 官方要求](https://docs.mesa3d.org/drivers/zink.html)、[Khronos MoltenVK feature 初始化](https://github.com/KhronosGroup/MoltenVK/blob/main/MoltenVK/MoltenVK/GPUObjects/MVKDevice.mm)、[UTM 锁定 MoltenVK fork](https://github.com/utmapp/MoltenVK/blob/2974cbbbd42593eeeaf993d954702f74ae09a239/MoltenVK/MoltenVK/GPUObjects/MVKDevice.mm)、[UTM v5.0.2 发布说明](https://github.com/utmapp/UTM/releases/tag/v5.0.2)。

ANGLE 官方将 iOS 的 Metal 路径列为支持平台，但没有将 iOS Vulkan backend 列为受支持组合。ANGLE Vulkan → MoltenVK 可以列入研究，不应写成可直接切换的已支持 backend。

### 5.2 Venus 的问题不仅是封包

Venus 有官方 vtest 测试模式，不一定需要把 Minecraft 放入完整 VM；但其 host-visible 内存、共享 ring、映射及外部内存假设不能跨网络自动成立。需要明确上传/flush/invalidate/下载的所有权和可见性，重建同步语义。

UTM 在 Apple 上的 Venus 适配是重要参考，但本地 guest/host 能共享 backing，Ubuntu 与 iPhone 不能共享地址空间或 Unix FD。即使 Apple renderer 可用，也不能把本地虚拟化支持当成网络 transport 已完成。

来源：[Venus 官方文档](https://docs.mesa3d.org/drivers/venus.html)。

### 5.3 兼容子集可能运行游戏，不等于完整 OpenGL

MobileGlues 官方描述支持最低 GLES 3.0 并面向 Minecraft，说明“GLES 3.0 必然不可能运行现代 Minecraft”这个泛化判断不成立。MobileGL 的官方 README 则明确其 GL 3.3 Core 为开发目标，仍有未完成部分。

这种已有兼容层可作为候选，必须检查 exact commit、真实实现、目标 shader/Mod 运行结果及 iOS 移植成本。若选择只实现 Vanilla 实际使用子集，应明确修改验收口径，而不是宣称完整 GL 3.2 或数百 Mod 通用兼容。将这些库放在 VirGL 后端也不只是替换一个 dylib，需要解决 context、函数加载及资源呈现接口。

来源：[MobileGlues 官方项目](https://github.com/MobileGL-Dev/MobileGlues)、[MobileGL 官方项目](https://github.com/MobileGL-Dev/MobileGL)、[GL4ES 官方说明](https://ptitseb.github.io/gl4es/)。

## 6. 仓库审计发现

以下是只读审计发现，**本轮没有实施修复**。优先级按对目标的阻塞程度排序，而非 CVSS 安全评分。

### F1 — 阻塞：当前 renderer 组合没有通过现代 Minecraft 能力门槛

证据：第 3/4 节的真机报告与锁定源码。影响：原计划的 Minecraft 菜单/世界阶段应保持暂停。修复标准：真实 guest context、shader、渲染及功能验收；禁止版本伪造。

### F2 — 高：能力 gate 把额外要求标为 Minecraft 基础必需

位置：`tests/gl_capability.c:42`。

测试强制要求 `GLEW_ARB_timer_query`，但锁定 Mesa 的 version.c 把 timer-query 列入 GL 3.3 条件，不是 GL 3.2 条件。Mojang 的 21w10a 公告说明基础切换到 GL 3.2 Core，不能用该公告证明此扩展是每个目标 Minecraft 路径的硬性必需。

因此存在误拒绝风险：修复其他功能后，基础 GL 3.2 可用的 renderer 仍可能被当前测试一票否决。现在不能断言目标 Vanilla 永远不使用它，应检查 1.21.1 实际代码/trace 和 fallback。

建议把“GL 3.2/GLSL 150 + 实际渲染”“可选诊断功能”“Sodium/Flywheel backend 要求”分成独立结果。这不会解决当前 GLSL 130 阻塞，也不授权降低既定门槛。

来源：[Mojang 21w10a 技术变更](https://www.minecraft.net/en-us/article/minecraft-snapshot-21w10a)、锁定 Mesa version.c、本仓库测试。

### F3 — 阻塞：正式 iOS PRESENT 适配器尚不存在

位置：`ios/App/NativeCapabilityConnection.swift:70`、`ios/RemoteGPU/RenderCoordinator.swift:49`、`ios/Renderer/RGPUIOSurfaceProbe.mm:162`。

真实联网入口有意拒绝 PRESENT；本地三角形不读取 VirGL resource。Coordinator 只是骨架，当前仅在网络事件后尝试 drain，没有独立的 GPU fence completion 驱动。若直接用于正式呈现，最后一帧可能在没有后续网络事件时一直不显示。

正式 adapter 还需：在有序 PRESENT 处取得真实资源，在后续写入前记录 GPU snapshot/copy，保留资源至 GL 与 Metal 消费完成，异步回收、resize、方向/格式/颜色处理及后台/断线清理。已有 pinning 只保持对象活着，不冻结帧内容。

锁定 VirGL 有 GL texture info 和条件性的 Metal native-handle 支持，说明 GPU-only interop 有实现基础；但 native-handle 依赖构建选项、初始化 flags 和 scanout 资源条件，不能假定 protocol 0 的每个 FBO 都可直接取 MTLTexture。现有 IOSurface 显示方案仍是合理候选。

### F4 — 高：当前同步模型仍可能导致 RTT 放大

位置：`ios/Renderer/RGPUVTestSession.cpp::execute`、Mesa vtest winsys 的 transfer/busy-wait 路径。

每个 SUBMIT 后创建 implicit fence；BUSY_WAIT 可在串行 renderer queue 上轮询最多 5 秒。command batching 能减少写入/封包开销，但不会自动删除应用或 winsys 的等待语义。实际等待次数、shader 编译和 buffer mapping 路径尚未有 Minecraft 真机 trace。

例：若每帧有一个必须完成的 40 ms 网络往返，光此等待就限制串行帧吞吐约 25 fps；两个约 12.5 fps，尚未计渲染。它是说明风险的计算，不是实测性能。输入送到 Ubuntu、再将视角更新命令送回手机也至少包含一次往返链路。

### F5 — 高：有单消息限制，没有完整会话预算/背压验收

位置：`ios/App/NativeCapabilityConnection.swift:32`、`ios/RemoteGPU/Protocol.swift::enqueuePresent`、`ios/Renderer/RGPUVTestSession.cpp`。

原生 parser 有 16 MiB 单消息限制，这是必要保护，但 Swift 网络回调仍可持续向 renderer queue 投递 Data，未来 waiting-present 集合和 GPU resources 也需要会话级预算。慢 GPU/同步等待时可能积压；QUIT/stop 排在已有工作后面不能瞬间清空全部任务。

建议后续明确网络接收背压、待执行命令/上传字节预算、帧队列上限、GPU 内存预算和取消语义。可以丢弃已正确渲染的旧呈现结果，不能随意丢弃仍影响 GPU 状态的 draw/resource 命令。

### F6 — 高：串行 proxy 的握手/等待本地客户端阶段缺乏明确超时

位置：`internal/proxy/bridge.go:66`、`:75`、`:83`。

Serve 串行处理连接；认证等待 HELLO 的读取没有显式应用阶段 deadline。认证后 `unix.Accept()` 等待本地应用，未与已断开的 QUIC 会话建立明确的取消联动。

源码可推导风险（未做运行攻击或复现）：连接长时间不发完整 HELLO，或手机认证后、Ubuntu demo 尚未连接就断开，可能阻塞下一会话接受或使下一本地应用先落入旧会话。不能仅凭 bridge worker 的断线清理代码声称所有连接阶段都可重连。

建议增加阶段超时和 QUIC disconnect/本地 accept 的取消机制，测试认证失败、断网、无本地应用、重连、后台切换。正常 TLS 和 pairing 不能替代这些生命周期限制。

### F7 — 中：诊断只统计流量/命令，缺少性能因果指标

位置：`internal/diagnostics/collector.go`。

已有命令、上传/下载字节和 PRESENT 计数；尚无可归因的 RTT wait、GPU wait、每帧关联、资源驻留/增量、shader compilation、帧积压及 phone thermal 统计。不能据总流量预测 720p/30 或整合包可玩性。

### F8 — 中：文档的进度描述已落后于实现与真机反馈

`README.md:48` 仍说原生模块没有连接 QUIC，但 capability-only 入口已连接。`docs/architecture.md:144` 仍将 native diagnostic 真机执行写为 pending；用户已有执行证据。

两处应更新为：本地 triangle/caps 有真机证据；QUIC capability-only 已实现但尚无本次端到端运行证据；正式 PRESENT、guest GL gate 和 Minecraft 未完成。不能把前两项更新成远程游戏 PASS。

## 7. Minecraft / Mods / 网络与硬件边界

### 7.1 Mod 兼容性不能从“JVM 在 Ubuntu”推导

Java/加载器兼容和 graphics backend 兼容是两条轴。Sodium 0.6.7（目标 MC 1.21.1）的官方 README 对 translation layers 不提供支持；这不是数学上不可能运行，但表示需要项目自己验证/维护，不能宣传为上游保证。

Flywheel 的 `1.21.1/dev` 分支（审计读取 commit `9189ad50d1b7bf59873043ebf06c21894b551573`）区分 instancing 与 indirect。前者检查 GL 3.3 或对应 shader-bit-encoding；后者检查 compute、SSBO、image load/store、multi-draw-indirect 等一组扩展，不是“GL 3.2 通过就全通过”。应锁具体 Create/Flywheel 发行版本；这里的分支证据不替代整合包版本清单。

可以把较低 backend 或关闭优化作为兼容策略，但必须明确性能损失并由用户接受，不能直接宣称完整支持。AE2/Mekanism 的实际包版本、客户端依赖、资源及 graphics 调用也需逐项测，当前未做运行验收。

来源：[Sodium 0.6.7 README](https://github.com/CaffeineMC/sodium/blob/mc1.21.1-0.6.7/README.md)、[Flywheel 1.21.1 GlCompat](https://github.com/Engine-Room/Flywheel/blob/9189ad50d1b7bf59873043ebf06c21894b551573/common/src/backend/java/dev/engine_room/flywheel/backend/gl/GlCompat.java)。

### 7.2 缓存能减少重复资源，不能解决能力或所有动态流量

常规 OpenGL 上传经过解码的像素/缓冲区，不直接保留原始 PNG 文件语义；cache key 需要包含内容、格式、维度、mip/subresource 等解释信息，并把磁盘内容缓存与本会话 GPU resource ID 分开。

动态 chunk mesh、实体和 shader variant 仍产生流量。所谓每帧一次批量发送也不等于一个网络包：超过 MTU 的 batch 会被传输层拆分。多 stream 上传时必须定义资源依赖/barrier；有序 GPU stream 仍可能被大上传阻塞。已有单 stream 先保正确性是合理选择。

掉线后 GPU context/resource state 不会凭磁盘 cache 自动恢复；第一版可以明确要求重新启动客户端会话，透明恢复需要额外状态重建设计。

### 7.3 输入丢包必须按事件语义处理

鼠标运动、陀螺仪和高频状态可以采用 datagram；按键按下/释放不能只容忍随意丢包，否则会出现卡键。需要可靠边沿或带序号的完整状态/重同步。相对 delta 丢包也会丢失位移，应明确是否接受或用累计量修复。

### 7.4 当前机器只是受限测试环境

本次只读观察：`nproc=2`，内存约 3.8 GiB，无 `/dev/dri`；当时 available 约 1.0 GiB，1.4 GiB swap 几乎用满。它只表示审计时点状态，不能推断所有占用由本项目造成，也未更改其他服务。

此状态下运行 JVM 可能被换页干扰，不能作为 GPU 架构性能判断。400 Mod 目标不能用本机配置承诺；未来更大服务器的 RAM、CPU、JVM native/RSS/GC、chunk meshing 和网络仍需实测。增加 Ubuntu RAM 不会修复 ANGLE 能力，增加手机 GPU 能力也不消除网络同步与手机热降频。

## 8. 建议的下一步及 Go/No-Go

以下是建议，未在本轮执行、未替换现有 ADR。

1. **冻结“Minecraft 即将可用”的进度预期，保留已验证主线作为基准。** 在 App 报告增加 build/source 标识、完整 extensions/capset 功能摘要以及实际功能测试，拒绝任何版本覆盖。
2. **先做手机本地候选能力实验，不先增加网络复杂度。** 优先比较当前 ANGLE 基准与 UTM 锁定 MoltenVK fork；所有编译仍在 Actions。dump Vulkan features/extensions/limits，然后真实执行 geometry、transform feedback、同步及适用的间接绘制等测试。遇到缺失或错误必须停止该候选，不接受 capability bit 单独 PASS。
3. **选定有真实证据的 OpenGL 兼容实现，再决定桥接位置。** 在手机本地真实创建 desktop GL 3.2 Core、编译 GLSL 150、验证纹理/FBO/VAO/instancing/sync 和必要语义。若找不到可移植且合理维护的实现，不进入新的远程后端工程。MobileGlues/MobileGL 可列入此阶段，但不能预先保证 iOS 可用。
4. **只有后端能力成立后再确定传输路线。** 能保留 VirGL/vtest 就优先复用；若要采用 Venus，先设计并测试网络内存/同步模型，再改架构。保持单一选定主线，不并行建设多个完整 renderer。
5. **远程执行/显示验收独立进行。** Ubuntu Mesa 必须通过手机 renderer 创建相同 Core context；随后远程 triangle 连续 10 分钟，GPU-only 呈现、0 正常显示 framebuffer readback、明确 frame ordering/资源回收。合法应用 readback 单测保留；不得把“所有 readback 禁用”当成通用 OpenGL 兼容。
6. **再测 Vanilla → multiplayer → 输入/音频 → 锁版本 Mods。** 720p/30 是性能目标，不是当前事实；先在 Wi-Fi 下测 RTT/等待/带宽/内存/thermal，再测 5G。大型 Modpack 必须作为后续独立验收，而不是 Vanilla PASS 的推论。

**停止条件**：候选仅有伪造版本/未实现特性声明，或只能在 macOS/Android 运行而无合理 iOS 移植路径；映射共享内存必须依赖跨机器 FD；为运行 Vanilla 要求重写 Minecraft 客户端或把 JVM 搬回手机。任一成立，都应回到选型而不是继续堆叠 transport 优化。

**时间判断**：当前无法负责任地给第一版完成日期。关键路径是“真机后端能力是否可成立”，不是待完成 UI 数量。若存在合适可复用实现，后续可以进入兼容性工程；若需实质补齐 graphics backend，就仍是研究型工作。不能把这些不确定性压缩成几天或几周的承诺。

## 9. 建议同步的文档大纲（待用户确认）

- `docs/architecture.md`：证据等级、现阶段 GL 阻塞、各 gate 当前状态、graph backend 选型前置条件。
- `docs/iphone-capability-probe.md`：本地/远程 capability 区别、GL 基础与诊断/Mod 能力分层。
- `ios/DEVICE-TEST.md`：当前真机结果、未通过项目、需要完整 extension/feature 和持续运行证据。
- `README.md`：已实现的 capability-only QUIC 与未实现的正式 PRESENT 分开描述。
- ADR 只在新候选通过且用户批准切换后更新；本轮不改 ANGLE/IOSurface 决策。

审计产生的是风险与实验建议，不是新 backend 已可用的保证。
