# B2: truthful Geometry limits audit — 2026-11-10

Status: **READ_ONLY_AUDIT_COMPLETE; LIMITS_REPAIR_NOT_APPROVED**.
Pinned UTM MoltenVK: `2974cbbbd42593eeeaf993d954702f74ae09a239`.
Archive: `dist/geometry-28ba404/diagnostics/MoltenVK-complete-source.tar.gz`, SHA256
`f014767b58a7f9afa85ccc249eb542597d6ef8253679abee9bc6b2521d47b496`.
Line references below are inside that complete source archive, not system headers.
The teammate read the archive in memory only; no patch, shader generation, test,
compilation, Actions build or device execution was performed for B2.

## Decision

The fixed source contains a real VS-object / GS-mesh bridge, but does not establish
truthful positive values for the five Geometry limits. Do not fill constants,
change advertised capabilities, adopt Zink/MobileGL, or claim Apple hardware cannot
implement Geometry. The [device report](evidence/moltenvk-device-2026-11-10/README.md)
proves basic C0 execution; all GS-related cases were blocked before execution.

## Proof obligations and stopping conditions

### 1. Shared payload ABI and input capacity

`moltenvk/External/SPIRV-Cross/spirv_msl.cpp:1937–1943` constructs object payload
from VS stage_out times topology vertex count; `2182–2208` independently constructs
mesh payload from GS stage_in parent types.
`moltenvk/MoltenVK/MoltenVK/GPUObjects/MVKPipeline.mm:1324–1331,1819,2613–2630`
actually transfers reflected locations/components/builtins/types. Thus the stages
are not wholly unrelated, but reflection does not prove common byte offsets,
strides, alignment or sizeof. Descriptor construction `1292–1347` supplies no
complete payload byte-budget proof.
Required: common ABI and device object-payload capacity, with input vertex count
× aligned stride + overhead within capacity. Vulkan component counts are not bytes.
Stop: without that proof, do not set maxGeometryInputComponents.

### 2. Invocation execution mapping

`spirv_parser.cpp:367–368` parses invocation count. In `spirv_msl.cpp:2174` the
wrapper dispatches one mesh group; `2229` declares lid/tid but `2261–2280` calls
one GS body with stage input/resources, without a proven invocation expansion.
Draw dispatch uses one thread in each object/mesh group (`MVKCmdDraw.mm:395–397`).
Parsing a qualifier does not implement invocation count or InvocationID semantics.
Stop: do not promote maxGeometryShaderInvocations, including a misleading value
of one presented as complete Vulkan GS support, without semantics/range isolation.

### 3. Output bytes and primitive capacity

`spirv_msl.cpp:2551–2557` reads shader output declarations; `2561–2577` derives
point/line/triangle primitive capacity V, V−1 or V−2. `2580–2581` emits template
capacities and `6805–6809` uses them directly in metal::mesh.
`6835–6837` resets primitive-local count; `6840–6858` writes/increments emitted
vertices/indices/primitives. These are not a device-wide byte/component limit proof.
`MVKPipeline.mm:3418–3429` creates the pipeline and checks compilation outcome;
compiler rejection cannot substitute for honest queried limits.
Required: establish vertex/primitive capacities and
V × aligned vertex bytes + P × aligned primitive bytes + index/overhead capacity,
then map consistently to Vulkan output vertices/components/total components.
Stop: no positive three output limits until that capacity proof and boundary tests exist.

### 4. Triangle-list assembly: static candidate, not device failure

`spirv_msl.cpp:1995–1999` uses startingIndex=positionInGrid.x for triangles, multiplying
by three only for topoStrip; `2024–2026,2028–2045,2050` uses startingIndex+i for vertices.
`MVKCmdDraw.mm:370–397` clears DrawInfo, uploads it at 372, dispatches triangle-list
vertexCount/3 groups without strip flag. Static reasoning suggests the second group
reads 1/2/3 instead of 3/4/5. Upload ordering versus later strip flag changes is another
unvalidated candidate, not a separate confirmed runtime bug.
Next isolated shape: nonindexed vkCmdDraw(6,1,0,0), TRIANGLE_LIST, two differently
positioned/colored triangles; GS emits from gl_in[0]/color[0] only. No PrimitiveID
or InvocationID, to isolate assembly. Verify generated MSL before any driver change,
then actual output only if a separately approved truthful implementation allows it.
Stop: do not extrapolate single-primitive passes to general input assembly.

### 5. Remaining legal draw semantics

`MVKPipeline.mm:1764–1772,1809–1817` maps only point/triangle/triangle-strip for
object/mesh setup; line/adjacency are not complete.
`MVKCmdDraw.mm:392–393` logs unsupported firstVertex/firstInstance, and
`803–805,1103–1105` rejects GS indirect/indexed-indirect.
Limits cannot encode away all missing legal topology, offset and invocation behavior.
A narrowly isolated experiment is not a compliant full Geometry feature declaration.
Stop: no limits-only patch or formal GL/VirGL provider replacement.

## Next separately authorized work

First isolate translation/assembly and design shared payload ABI/invocation mapping;
obtain target device Metal object/mesh capacity evidence; define byte-to-component
bounds and legal topology/draw scope. Only after these obligations close should a
limited implementation repair and Actions-built strict device re-test be proposed.
No architecture migration or dependency pin change follows from this audit.
