# Remote Minecraft GPU 当前状态与真机验证总结

更新日期：2026-10-29。最新设备：iPhone18,3，iOS 27.0.1（24A446）。

本文依据已交付构建、仓库记录及用户提供的真机完整报告汇总，不是原始日志全文，
也不把 CI、源码推断或版本字符串当成设备能力验收。

## 1. 当前结论

**本轮 TBO 修复的代表用例已在真机通过；Geometry 仍被当前后端拒绝，
所以 B1.2d 整体仍为 BLOCKED，不能进入完整 B1.2／guest GL 验收。**

| 项目 | 当前结论 | 边界 |
| --- | --- | --- |
| A 路线：远程 PRESENT | 已通过 A3.2 基础真机门槛 | 不等于持续吞吐、GPU 在途取消或十分钟性能通过。 |
| B1.1 | provider／context、共享内容、独占线程迁移及返回已验证 | 不是完整桌面 GL 语义或跨 context fence 验收。 |
| B1.2a／b／c | 着色器、实例化／同 context fence、深度／模板／混合的代表用例已通过 | 不是所有 API、格式、限制及错误语义的完整一致性验证。 |
| B1.2d：R8I TBO | 本轮初始绑定、无重绑 SubData 更新、显式重绑三例均 PASS | 单个有符号 TBO、四个 texel 的代表用例。 |
| B1.2d：RGBA32F TBO | 本轮真实翻译／编译／链接及相同三例均 PASS | 浮点存储与取样路径通过本用例，不证明任意浮点数值精度或所有格式。 |
| B1.2d：Geometry | BLOCKED | 前端与独立原始后端创建均返回对象 0、错误 0x500；编译／链接／绘制未执行。 |
| 完整 B1.2／OpenGL 3.2 Core | 未接受 | 不能把局部 PASS 合并成完整 GL3.2 能力。 |
| B1.3、VirGL／Ubuntu guest GL3.2、Minecraft | 未验收 | 本轮未替换正式 renderer，未运行 Minecraft／Mods／输入／音频验收。 |

## 2. 两条路线不能混为一个结论

### A：远程 GPU 内容与显示链路

既有验收基线包括 Ubuntu 来源的实际绘制，经 vtest／QUIC 到 iPhone 执行、
GPU 快照／IOSurface／Metal 显示，以及有界资源生命周期。

- A2.1 已有单帧和 7／12 帧变化图像的真机证据；PRESENT 路径 GET=0。
- A3.1 基础单槽异步路径已验证，保留其指定的重连／清理边界。
- A3.2 基础双槽路径基线 `6dd8b04`：正常及独立 750ms 退休／背压场景，
  各 13 次正确 PRESENT，超过 30 秒保活；两次分配、十一次复用，两槽最终释放。
- 这些结果不证明持续重叠吞吐、所有断连时机的 GPU 在途取消、内存预算或长时间性能。

证据见 [A3.2 双槽记录](evidence/a32-double-slot-2026-10-28/README.md)。

### B：图形能力兼容性

本轮 B 实验在独立 iOS App 内运行 MobileGlues → 已固定的 ANGLE Metal，
不连接 Ubuntu，也不是 VirGL／guest 集成验证。A 路线已经可显示远程内容，
不意味着 B 路线已经提供 Minecraft 所需的完整桌面 GL 能力。

前端报告的 GL 4.0／GLSL 4.00 是未验证元数据；请求得到的“3.2 Core”查询值
部分来自请求 bookkeeping／固定 profile 位，不能用作能力证明。
后端实际报告 GLES 3.0、ESSL 3.00、ANGLE Metal／Apple A19 GPU。

## 3. 本轮构建与来源

| 字段 | 实际值 |
| --- | --- |
| 运行代码 SHA | `b234149c917661e499c156b3107c7cd90370181e` |
| 分支 | `experiment/b12d1-mobileglues-retest` |
| 目标／App | `MobileGluesRetestProbe`／RemoteGPU B1.2d.1 |
| Bundle | `org.remotegpu.experiments.mobileglues.capabilities.retest` |
| CI | [40907010085](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40907010085)，通过 |
| iOS 构建 | [40907010084](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40907010084)，通过 |
| MobileGlues 固定源码 | `97558a69157b033b890958b1e49258c5b51a80c6` |
| ANGLE 制品基线 | run `40636888480`，未重建／替换 |
| 原 B1.2d 失败基线 | `528ab1ea3485241ea5c0399e9b35245a80e273c3` |
| 严格错误重测基线 | `18400ad4e41995e995e3807ac2c96da745ad0a89`，当时三项总体仍 BLOCKED |

交付物：

- [可自签名 IPA](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40907010084/artifacts/12912825757)：
  `MobileGluesRetestProbe-unsigned.ipa`，SHA256
  `7da59e9b273e77fec99dba311ec2a0a9852cdc272f2207a8e953d46dbb57183c`。
- [诊断与完整 LGPL 对应源码](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/40907010084/artifacts/12912825770)：
  包含修改后的候选及依赖、适配记录、编译／链接／导出记录和来源 manifest。
- 候选 framework SHA256：
  `4fe62e6542354ff4106a359b705d891312f5e4bc469b82f409747b4910ff7ff4`。
- EGL／GLESv2 实际打包哈希与既有 ANGLE 制品一致；App 只嵌入
  MobileGluesProbe、EGL、GLESv2 三个 framework，不嵌入 VirGL／epoxy。

以上哈希描述外部签名前的 unsigned 字节；iOS 重签可能改变二进制字节。
用户报告的来源字段与交付 manifest 一致，不等于对已重签设备文件重新计算了哈希。
构建时 `DEVICE_PENDING` 字段保留不改；本文按新真机报告更新结论，
不回写／伪造历史 manifest，也不新增完整 `accepted_b12d_device_sha`。

## 4. 最新真机结果

### 4.1 回归与错误可观测性

- 显式 provider、逐入口归属检查及 Metal 平台 resolver 通过；bootstrap 成功，
  解析 384 个后端入口。系统预载 OpenGLES 镜像存在，但未被选作 Probe provider。
- 故意传入无效 depth function：实际返回 `0x500`，下一次前端及原始后端查询均为 0。
  这证明本负向对照的错误返回／清零生效，不等于所有 GL 错误语义均已符合规范。
- B1.1 共享、迁移、返回的三个 1×1 内容检查通过。蓝色实际 229、期望 230，
  在既定容差内；不是宣称逐字节完全一致。
- B1.2a：3×256=768 像素，零差异计数；真实前端／后端编译、链接状态均成功。
- B1.2b：4／2／0 实例三例共 768 像素，零差异计数；fence 实际由 pending 到完成，
  在像素读取前确认并删除。1.279／1.258／1.272ms 是本地轮询观察时间，非 GPU 时间或性能指标。
- B1.2c：四例共 1024 像素，零差异计数；实际 D24S8 附件及深度／模板／混合输出通过。

### 4.2 两项 TBO 均通过原用例

| 特性 | 初始绑定 | SubData 更新、不重绑 | 显式重绑诊断 | 该代表特性结论 |
| --- | --- | --- | --- | --- |
| R8I | 256 像素，0 mismatch | 256 像素，0 mismatch | 256 像素，0 mismatch | PASS |
| RGBA32F | 256 像素，0 mismatch | 256 像素，0 mismatch | 256 像素，0 mismatch | PASS |

两项共 1536 像素；连同 B1.2a／b／c，合计 16 次 16×16 图像读取、
4096 个像素检查，另有 B1.1 三个 1×1 检查。
RGB 容差仍为 ±1，alpha 必须完全匹配；未放宽判定。

关键证据：

- 原始桌面 GLSL150 的 `isamplerBuffer`／`samplerBuffer` 分别翻译为
  ESSL300 的 `isampler2D`／`sampler2D` 加类型明确的取样辅助函数。
- 浮点路径不再依赖本后端不支持的 `GL_EXT_texture_buffer`；实际前端及
  后端编译／链接状态均为 1，日志为空。
- 六次绘制观察到 sampler=15、width=4，查询无错误。
  height location=-1 与 shader 未使用该 uniform 相符，不是这批用例的失败证据。
- 无重绑更新已产生新数据对应的实际图像，不再读取旧副本。
  显式重绑仅是后续独立诊断，没有被用于豁免更新失败。
- 每项新特性使用 fresh unshared context。资源释放及 context 恢复／销毁返回成功，
  但没有做 driver leak profiling。

### 4.3 Geometry 仍阻塞整体门槛

本轮实际记录：

```text
B12D_CREATE_GEOMETRY object=0 frontend_GL=0x500 backend_GL=0x0
B12D1_RAW_GEOMETRY_CONTROL object=0 actual_GL=0x500 NOT_FRONTEND_SUBSTITUTION
B12D_SUMMARY feature=TBO_R8I result=PASS
B12D_SUMMARY feature=TBO_RGBA32F result=PASS
B12D_SUMMARY feature=GEOMETRY_GLSL150 result=BLOCKED
```

前端严格 getter 已读取错误，所以随后原始查询为 0 并不推翻失败。
独立原始 ANGLE 创建也得到对象 0／0x500，证明当前后端路径未接受 Geometry 阶段。
这不等于断言 Apple GPU 硬件物理上无法执行任何等价计算。

Geometry 的 shader 源码虽已打印，但创建未成功，编译／链接／绘制均为 **NOT RUN**。
没有替换为原始后端对象，没有绕过 Geometry，也没有修改总门槛来强行 PASS。
在本批三个新增特性中只剩 Geometry 失败；这不等于“完整 GL3.2 只差 Geometry”。

## 5. 三轮修复演进

| 真机代码 | R8I 三例 mismatch（初始／无重绑更新／重绑） | RGBA32F | Geometry |
| --- | --- | --- | --- |
| `528ab1e` | 192／256／256，输出恒定 | 真实片元编译失败 | 对象 0；旧 getter 吞错误，不能从 GL0 推断错误原因。 |
| `18400ad` | 0／256／0，明确定位旧副本问题 | 真实片元编译仍失败 | 前端及独立原始后端均对象 0／0x500。 |
| `b234149` | 0／0／0 | 三例均 0 mismatch，真实编译／链接通过 | 仍对象 0／0x500，整体 BLOCKED。 |

第一步修复 `glGetError` 无条件返回零和 `glDrawArrays` 缺少绘制准备的问题。
第二步在兼容层内维护 texture→buffer 附着依赖，BufferSubData 写入后通过 GPU
只上传受影响 texel；BufferData 分配路径同步更新附着纹理，并处理删除／名称复用。
上传保存恢复实际 unpack／纹理状态；类型翻译不再只处理有符号 samplerBuffer。

实现与 CPU 验证细节见 [TBO 修复说明](b12d-tbo-repair.md)。
CPU 辅助代码／状态记录后端／glslang 语法检查通过不能替代这里的真机结果。

## 6. 已验证范围与尚未覆盖项

本批可记录为通过的是：**同 context、单个 R8I 或 RGBA32F TBO 的代表性初始绑定、
完整数据 SubData 更新及显式重绑，以及既有 B1.1／a／b／c 回归。**

以下不能顺带宣称通过：

- 所有 TBO 格式、最小限制、范围绑定、多个同时使用的 TBO，以及 TBO 与普通纹理混用。
- uint TBO、sampler 数组／参数、宏别名、一般化 shader 翻译或所有 GLSL150 语义。
- 跨行／非 texel 对齐更新、后附着 BufferData 重新分配、删除／名称复用的完整真机覆盖。
  实现及 CPU 检查涉及其中部分路径，但本批三例没有完成这些设备验收。
- map／unmap／flush、持久映射、buffer copy、shader／transform feedback 写入后的同步。
- 跨 context fence 排序、并发共享资源、完整生命周期／错误语义、driver 泄漏与性能。
- Geometry、完整 B1.2／GL3.2 Core、B1.3 VirGL 集成、Ubuntu guest 以及 Minecraft／Mods。

早期前端 GL0 曾受上游吞错影响；历史像素／原始编译状态证据保留，
但不把旧 GL0 当作无错误证明。本轮严格负向对照及回归结果提供了新的有界证据。

## 7. 下一步建议与决策边界

1. 固化 `b234149` 的两项 TBO 代表用例 PASS 和 Geometry BLOCKED，保留三轮失败／修复记录。
   不把代码提交、CI 通过或局部 PASS 写成完整 B1.2 接受。
2. 在现有兼容实现内补充 TBO 边界用例，可进一步提高资源一致性与状态恢复的可信度；
   这不能解决 Geometry 门槛，也不能代替真实 guest 测试。
3. 对 Geometry 先做有范围的路线评估，再决定是否批准更大的实现：

| 选项 | 复杂度／成本与风险 | 当前建议 |
| --- | --- | --- |
| 保留现有后端和明确能力边界 | 变更最小，保留已验证成果；不能声称完整 GL3.2／推进当前完整能力门槛。 | 作为可信基线保留。 |
| 在兼容层实现完整 Geometry 等价执行 | 高复杂度，需覆盖拓扑、接口、输出、限制、状态及生命周期；不是字符串改写。 | 先评估，未经批准不直接实现。 |
| 调整兼容实现／后端路线 | 影响依赖、shader、provider、打包及验收基线，迁移与维护成本大。 | 需单独比较和批准，不自动迁移。 |

没有依据给出可靠完成日期或性能数字。后续若变更架构／后端，应先明确范围，
再按既有 docs 门槛实施；不得跳过 Geometry、伪造 GL 版本／扩展／capset，
或在门槛未满足时直接宣称 Minecraft 可运行。

## 8. 本阶段未改变的系统与资料

所有编译仍在 GitHub Actions；本地只做源码／文档和制品完整性检查。
正式 `ios/Renderer`、`ios/App`、`ios/RemoteGPU`、基础 provider 适配、ANGLE、ADR、
传输与服务器均未因这轮修复而替换或部署。

相关资料：

- [原 B1.2d 失败记录](evidence/b12d-device-2026-10-29/README.md)。
- [严格错误／绘制准备重测记录](evidence/b12d1-device-2026-10-29/README.md)。
- [阻塞分析及历史交付](b12d-blockers-and-retest.md)。
- [本轮 TBO 实现、构建及交付说明](b12d-tbo-repair.md)。
- [阶段计划与验收边界](next-stage-plan.md)。
