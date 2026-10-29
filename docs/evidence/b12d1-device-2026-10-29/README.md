# B1.2d.1 actual device retest — partial repair, aggregate BLOCKED

Summary of the user-submitted full report, not reconstructed raw output.
iPhone18,3, iOS27.0.1 (24A446), code
`18400ad4e41995e995e3807ac2c96da745ad0a89`, Actions `40901304444`, unsigned
candidate `df6ba87d320adbe1c89dc803f8c684068c9866470825bc55b089f2b01cdbcfd5`.
The delivered manifest matches the report and retains `528ab1e...` as the B1.2d
failure baseline, not an accepted capability. Original build provenance stays intact.

Actual provider/bootstrap checks passed with 384 entries and the checked ANGLE
Metal proc-table route. The deliberate invalid depth-function enum returned
`0x500`, then frontend/raw queries returned zero: strict error observability is
now demonstrated by this negative control. No general error conformance claimed.

B1.1 sharing/migration/return contents matched; B1.2a/b/c checked 768/768/1024
pixels with zero mismatches under the strict getter. Fences completed before
pixel reads and were retired. 1.288/1.258/1.276ms are local polling observations,
not GPU timestamps or a performance verdict. Reported cleanup calls returned
success, not proof of absent driver leaks.

| Feature | Actual evidence / verdict |
| --- | --- |
| R8I initial | 256 pixels, zero mismatches. Sampler=15, width=4. Missing arrays draw preparation is repaired for this representative case. |
| R8I SubData WITHOUT reattach | 256 mismatches. Quadrant red values 64/128/255/0 equal the ORIGINAL data with bias=1, not updated data. Same sampler=15, width=4, no observed GL error. Stale copied texture contents remain BLOCKED. |
| R8I explicit reattach | Zero mismatches; updated red values 160/224/32/96. Diagnostic success cannot waive the failed live update; feature remains BLOCKED. |
| RGBA32F | Frontend/raw fragment compile statuses 0: GL_EXT_texture_buffer unsupported and samplerBuffer reserved/syntax error. Link/attachment/draw NOT RUN. BLOCKED. |
| Geometry | Frontend object=0, error=0x500; subsequent raw error=0. Separate raw creation also object=0, error=0x500; control cleanup=0. Compile/link/draw NOT RUN. Current backend rejects this stage. BLOCKED. |

Height uniform location=-1 is consistent with the captured shader not using it;
it does not establish a second upload failure. All features used fresh unshared
contexts and recovered to root; all three final feature summaries and aggregate
remained BLOCKED. No full B1.2/GL3.2, cross-context sync, VirGL/guest/Minecraft,
performance, streaming or leak acceptance follows. Geometry is not silently
bypassed or replaced by a raw backend shader.

Pinned source matches the remaining R8I behavior: glTexBuffer copies GPU buffer
contents into a 2D texture, while glBufferSubData changes only the buffer. Typed
lowering processes only isamplerBuffer, leaving float samplerBuffer unsupported.
Next repair targets same-context BufferData/SubData dependency propagation and
typed scalar TBO translation. Geometry requires a separately approved larger
solution, not a string edit, extension override or automatic backend migration.
