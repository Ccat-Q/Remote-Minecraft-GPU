"""Source guards and experiment-isolation tests, not simulated device results."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from prepare_mobileglues_probe import HASHES, MOBILEGLUES, diagnostic_apple_errors, replace_once
from mobileglues_provenance import verify_bundle, experiment_scope, ACCEPTED_B11, ACCEPTED_B12A, ACCEPTED_B12B, ACCEPTED_B12C

ROOT = Path(__file__).resolve().parents[2]
PROBE = ROOT / "ios/Experiments/MobileGluesProbe"


class MobileGluesProbeTests(unittest.TestCase):
    def test_immutable_pin_and_guard_coverage(self):
        self.assertEqual(MOBILEGLUES, "97558a69157b033b890958b1e49258c5b51a80c6")
        self.assertEqual(len(HASHES), 9)
        for value in HASHES.values():
            self.assertRegex(value, r"^[0-9a-f]{64}$")

    def test_transform_rejects_missing_duplicate_anchors(self):
        self.assertEqual(replace_once("before", "before", "after"), "after")
        for source in ("", "beforebefore"):
            with self.assertRaises(ValueError):
                replace_once(source, "before", "after")

    def test_no_constructor_or_global_provider_lookup_in_overlay(self):
        source = (PROBE / "Overlay/Bootstrap.cpp").read_text()
        self.assertNotIn("RTLD_DEFAULT", source)
        self.assertNotIn("static_block_t", source)
        self.assertIn("frontBase == eglBase", source)
        self.assertIn("checked(p, base, name)", source)
        self.assertIn("if (attempted) return -2", source)

    def test_error_policy_targets_only_apple_branch(self):
        apple = "    global_settings.angle_supported = false;\n    global_settings.ignore_error = IgnoreErrorLevel::Partial;"
        android = "    global_settings.ignore_error = IgnoreErrorLevel::Partial;"
        result = diagnostic_apple_errors(apple + "\n#else\n" + android)
        self.assertIn("IgnoreErrorLevel::None; // B1.1 diagnostic", result)
        self.assertTrue(result.endswith(android))
        with self.assertRaises(ValueError):
            diagnostic_apple_errors(android)

    def test_separate_target_no_formal_renderer_or_framework_link(self):
        project = (PROBE / "project.yml").read_text()
        formal = (ROOT / "ios/project.yml").read_text()
        self.assertNotIn("MobileGlues", formal)
        self.assertNotIn("virglrenderer", project)
        self.assertNotIn("epoxy", project)
        self.assertEqual(project.count("link: false"), 3)
        self.assertIn("org.remotegpu.experiments.mobileglues", project)
        include = PROBE / "../../../_deps/mobileglues/MobileGlues-cpp/include"
        self.assertEqual(include.resolve(), ROOT / "_deps/mobileglues/MobileGlues-cpp/include")
        self.assertNotIn("../../../../", project)

    def test_packaged_binary_identity_and_isolation(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory)
            hashes = {}
            for name in ("MobileGluesProbe", "EGL", "GLESv2"):
                binary = app / "Frameworks" / (name + ".framework") / name
                binary.parent.mkdir(parents=True)
                binary.write_bytes(name.encode())
                hashes[name] = hashlib.sha256(name.encode()).hexdigest()
            (app / "B11Provenance.json").write_text(json.dumps({
                "candidate_framework_sha256": hashes["MobileGluesProbe"],
                "angle_artifact": {"framework_sha256": {name: hashes[name] for name in ("EGL", "GLESv2")}},
            }))
            self.assertEqual(verify_bundle(app), hashes)
            (app / "Frameworks/EGL.framework/EGL").write_bytes(b"wrong artifact")
            with self.assertRaisesRegex(ValueError, "hash mismatch"):
                verify_bundle(app)
            (app / "Frameworks/epoxy.0.framework").mkdir()
            with self.assertRaisesRegex(ValueError, "unexpected/missing"):
                verify_bundle(app)

    def test_runtime_checks_are_not_version_string_gates(self):
        source = (PROBE / "App/Probe.mm").read_text()
        self.assertIn("RTLD_NOW | RTLD_LOCAL | RTLD_FIRST", source)
        self.assertIn("Cross-context GPU clear content mismatch", source)
        self.assertIn("worker.join()", source)
        self.assertIn("NOT GL semantic conformance evidence", source)
        self.assertIn("B1.2 GLSL 150 shaders/features NOT TESTED", source)
        self.assertNotIn('setenv("MESA_GL_VERSION_OVERRIDE"', source)
        self.assertNotIn('setenv("MG_GL_VERSION"', source)

    def test_bootstrap_and_app_share_checked_platform_resolver(self):
        source = (PROBE / "App/Probe.mm").read_text()
        overlay = (PROBE / "Overlay/Bootstrap.cpp").read_text()
        policy = (PROBE / "Overlay/Bootstrap.h").read_text()
        self.assertIn("acquireDisplay(&display, &platformImplementation, &route)", source)
        self.assertNotIn('symbol<PFNEGLGETPLATFORMDISPLAYEXTPROC>', source)
        self.assertIn("ANGLE_PROC_TABLE (direct export absent)", source)
        self.assertIn("rgpu::b11::selectPlatform", overlay)
        self.assertIn("void *value = rgpu_mg_metal_display();", overlay)
        self.assertIn("!bootstrapped", overlay)
        self.assertIn("if (display) *display = nullptr", overlay)
        self.assertIn("if (!address) { address = proc();", policy)
        self.assertIn("Wrong ANGLE platform implementation provider", policy)
        self.assertIn("B11_STAGE create_frontend_contexts", source)
        self.assertIn('"dlsym "', source)

    def test_context_metadata_uses_correct_api_without_capability_gate(self):
        source = (PROBE / "App/Probe.mm").read_text()
        plan = (PROBE / "App/ContextMetadata.hpp").read_text()
        self.assertIn("rgpu::b11::queryContextMetadata", source)
        self.assertIn("f.eglQueryContext(s.display, s.root, attribute, &value)", source)
        self.assertIn("f.glGetIntegerv(token, &value)", source)
        self.assertNotRegex(source, r"eglQueryContext\([^\n]*EGL_CONTEXT_(?:MAJOR|MINOR|OPENGL_PROFILE)")
        self.assertIn("egl(eglContextClientType), egl(eglConfigId)", plan)
        self.assertIn("gl(glMajorVersion), gl(glMinorVersion), gl(glContextProfileMask)", plan)
        self.assertIn("NOT capability proof", source)
        self.assertIn("granted request bookkeeping", source)
        self.assertIn("B11_STAGE shared_gpu_content_and_migration", source)

    def test_shader_stage_scope_and_independent_target(self):
        self.assertNotIn("accepted_b11_device_sha", experiment_scope("b11"))
        self.assertEqual(experiment_scope("b12a")["accepted_b11_device_sha"], ACCEPTED_B11)
        self.assertIn("DEVICE_PENDING", experiment_scope("b12a")["capability_status"])
        with self.assertRaises(ValueError):
            experiment_scope("unknown")
        project = (PROBE / "project.yml").read_text()
        self.assertIn("org.remotegpu.experiments.mobileglues.shader", project)
        self.assertIn("RGPU_B12_SHADER_PROBE=1", project)
        self.assertIn("dependencies: *probeProviders", project)
        workflow = (ROOT / ".github/workflows/build-ios-compatibility-probe.yml").read_text()
        self.assertIn("experiment/b12-mobileglues-shader-probe", workflow)
        self.assertIn('--scope "$PROBE_SCOPE"', workflow)
        self.assertIn('-scheme "$PROBE_APP"', workflow)

    def test_shader_probe_has_real_backend_status_source_and_pixel_oracle(self):
        source = (PROBE / "Shader/ShaderProbe.mm").read_text()
        fixture = (PROBE / "Shader/DrawFixtures.hpp").read_text()
        self.assertEqual(fixture.count("#version 150"), 2)
        self.assertNotIn("#version 300", fixture)
        for entry in ("backend.glGetShaderSource", "backend.glGetShaderiv(shader,GL_COMPILE_STATUS",
                      "backend.glGetProgramiv(resources.program,GL_LINK_STATUS", "gl.glDrawArrays",
                      "gl.glReadPixels", "expectedPixel(input,x,y)", "mismatches == 0"):
            self.assertIn(entry, source)
        self.assertIn("resources.close(); throw;", source)
        self.assertIn("NOT full B1.2 or guest GL acceptance", source)
        self.assertIn("Instancing/Depth/Stencil/Blending/TextureBuffer/Sync/Geometry NOT TESTED", source)

    def test_instancing_sync_is_separate_bounded_device_pending_scope(self):
        self.assertEqual(experiment_scope("b12b")["accepted_b12a_device_sha"], ACCEPTED_B12A)
        self.assertIn("DEVICE_PENDING", experiment_scope("b12b")["capability_status"])
        project = (PROBE / "project.yml").read_text()
        self.assertIn("org.remotegpu.experiments.mobileglues.features", project)
        self.assertIn("RGPU_B12_FEATURE_PROBE=1", project)
        source = (PROBE / "Shader/ShaderProbe.mm").read_text()
        self.assertIn("features.glDrawArraysInstanced(GL_TRIANGLES,0,6,instanceCounts[index])", source)
        self.assertLess(source.index("completeFence(features,gl,report,index)"), source.index("gl.glReadPixels(0,0,width,height"))
        self.assertIn("sync.glClientWaitSync(lease.object,0,0)", source)
        self.assertIn("std::chrono::seconds(5)", source)
        self.assertIn("~Lease() { if (object) api.glDeleteSync(object); }", source)
        self.assertIn("expectedInstancePixel(index,x,y)", source)
        self.assertNotIn("glFinish(", source)
        self.assertIn("NOT cross-context ordering", source)


    def test_raster_scope_retains_regressions_and_accepted_sources(self):
        scope = experiment_scope("b12c")
        self.assertEqual(scope["accepted_b12b_device_sha"], ACCEPTED_B12B)
        self.assertEqual(scope["accepted_b12a_device_sha"], ACCEPTED_B12A)
        self.assertIn("DEVICE_PENDING", scope["capability_status"])
        project = (PROBE / "project.yml").read_text()
        self.assertIn("org.remotegpu.experiments.mobileglues.raster", project)
        self.assertIn("RGPU_B12_RASTER_PROBE=1", project)
        app = (PROBE / "App/Probe.mm").read_text()
        self.assertLess(app.index("RGPURunInstancingSyncProbe(report"), app.index("RGPURunRasterProbe(report"))
        self.assertIn("TextureBuffer/Geometry, full B1.2", app)
        workflow = (ROOT / ".github/workflows/build-ios-compatibility-probe.yml").read_text()
        self.assertIn("experiment/b12c-mobileglues-raster-probe", workflow)
        self.assertIn("MobileGluesRasterProbe", workflow)
        self.assertIn(".accepted_b12b_device_sha", workflow)

    def test_raster_draws_use_real_attachment_state_and_full_pixel_oracle(self):
        source = (PROBE / "Shader/ShaderProbe.mm").read_text()
        for operation in ("GL_DEPTH24_STENCIL8", "GL_DEPTH_STENCIL_ATTACHMENT",
                          "state.glDepthFunc(GL_LESS)", "test == 0 ? GL_TRUE : GL_FALSE",
                          "state.glStencilMask(0x0f)", "state.glStencilMask(0)",
                          "state.glStencilFunc(GL_EQUAL,5,0xff)", "GL_INCR",
                          "state.glBlendFuncSeparate(GL_SRC_ALPHA,GL_ONE_MINUS_SRC_ALPHA,GL_ONE,GL_ONE_MINUS_SRC_ALPHA)",
                          'resolver("glClearDepth")', "glDeleteRenderbuffers(1,&depthStencil)",
                          "expectedRasterPixel(index,x,y)", "B12C_CASE case=%d"):
            self.assertIn(operation, source)
        self.assertNotIn("glFinish(", source)
        fixture = (PROBE / "Shader/RasterFixtures.hpp").read_text()
        self.assertIn("#version 150", fixture)
        self.assertNotIn("#version 300", fixture)
        self.assertIn("rasterCases = 4", fixture)


    def test_buffer_geometry_scope_target_and_full_accepted_chain(self):
        scope = experiment_scope("b12d")
        self.assertEqual(scope["accepted_b12c_device_sha"], ACCEPTED_B12C)
        self.assertEqual(scope["accepted_b12b_device_sha"], ACCEPTED_B12B)
        self.assertIn("DEVICE_PENDING", scope["capability_status"])
        project = (PROBE / "project.yml").read_text()
        self.assertIn("org.remotegpu.experiments.mobileglues.capabilities", project)
        self.assertIn("RGPU_B12_CORE_PROBE=1", project)
        workflow = (ROOT / ".github/workflows/build-ios-compatibility-probe.yml").read_text()
        self.assertIn("experiment/b12d-mobileglues-core-probe", workflow)
        self.assertIn("MobileGluesCoreProbe", workflow)
        self.assertIn(".accepted_b12c_device_sha", workflow)

    def test_buffer_live_update_is_not_waived_by_diagnostic_reattach(self):
        source = (PROBE / "Shader/ShaderProbe.mm").read_text()
        loop = source.split("for (int test = 0; test < bufferCases; ++test) {",1)[1]
        update = loop.split("} else if (test == 2)",1)[0]
        self.assertIn("subData(GL_ARRAY_BUFFER,0,sizeof(signedUpdated)", update)
        self.assertIn("subData(GL_ARRAY_BUFFER,0,sizeof(floatUpdated)", update)
        self.assertNotIn("texBuffer(", update)
        self.assertIn("EXPLICIT_REATTACH_DIAGNOSTIC", loop)
        self.assertIn("mismatches += capabilityPixels", loop)
        self.assertIn("require(mismatches == 0", source)
        fixture = (PROBE / "Shader/CapabilityFixtures.hpp").read_text()
        self.assertIn("isamplerBuffer uBuffer", fixture)
        self.assertIn("samplerBuffer uBuffer", fixture)
        self.assertEqual(fixture.count("#version 150"), 5)
        self.assertNotIn("#version 300", fixture)
        self.assertNotIn("glFinish(", source)

    def test_geometry_is_actual_stage_and_failures_are_independent_contexts(self):
        source = (PROBE / "Shader/ShaderProbe.mm").read_text()
        self.assertIn("gl.glCreateShader(GL_GEOMETRY_SHADER)", source)
        self.assertIn("gl.glAttachShader(resources.program,geometry)", source)
        self.assertIn('compile(gl,backend,report,geometryShader,geometrySource,"geometry")', source)
        self.assertIn("expectedGeometryPixel(test,x,y)", source)
        self.assertIn("Geometry shader creation rejected; compilation/link/draw NOT RUN", source)
        app = (PROBE / "App/Probe.mm").read_text()
        self.assertIn("f.eglCreateContext(s.display,config,EGL_NO_CONTEXT,core)", app)
        self.assertLess(app.index("RGPURunRasterProbe(report"),app.index("RGPURunCapabilityProbe(report"))
        self.assertIn("f.eglDestroyContext(s.display,isolated)", app)
        self.assertIn("capabilityVerdicts[index] = rgpu::b12::Verdict::Blocked", app)
        self.assertIn("rgpu::b12::allCapabilitiesPassed(capabilityVerdicts)", app)
        self.assertIn("B12D_CONTEXT_CLEANUP", app)


if __name__ == "__main__":
    unittest.main()
