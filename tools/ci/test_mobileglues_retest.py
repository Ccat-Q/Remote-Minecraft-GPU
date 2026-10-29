"""Opt-in repair mutation guards, not device/graphics acceptance."""
import unittest
from pathlib import Path

from prepare_mobileglues_b12d_retest import HASHES, NATIVE_DRAW, repair_draw, repair_getter, adapt
from mobileglues_provenance import experiment_scope, verify_repair_scope, B12D_FAILURE, ACCEPTED_B12C

ROOT = Path(__file__).resolve().parents[2]
PROBE = ROOT / "ios/Experiments/MobileGluesProbe"


class RetestRepairTests(unittest.TestCase):
    def test_getter_no_longer_returns_fabricated_zero(self):
        source = "prefix\nGLenum glGetError() {\nreturn GL_NO_ERROR;\n}\n\nstatic std::string es_ext;\n"
        result = repair_getter(source)
        self.assertIn("rgpu::diagnostic::takeError(g_frontend_error", result)
        self.assertIn("GLES.glGetError()", result)
        self.assertNotIn("return GL_NO_ERROR", result)
        for invalid in ("", source.replace("return GL_NO_ERROR;", "return backend;"), source + source):
            with self.assertRaises(ValueError):
                repair_getter(invalid)

    def test_arrays_prepare_without_duplicate_native_export(self):
        native, drawing = repair_draw(NATIVE_DRAW, "void glDrawElementsInstanced(dummy)")
        self.assertNotIn(NATIVE_DRAW, native)
        self.assertEqual(drawing.count("void glDrawArrays("), 1)
        self.assertLess(drawing.index("prepareForDraw();"),drawing.index("GLES.glDrawArrays("))
        for bad in ("", NATIVE_DRAW + NATIVE_DRAW):
            with self.assertRaises(ValueError):
                repair_draw(bad,"void glDrawElementsInstanced(dummy)")
        with self.assertRaises(ValueError):
            repair_draw(NATIVE_DRAW, "")

    def test_source_hash_guards_reject_unpinned_input(self):
        self.assertEqual(len(HASHES), 3)
        with self.assertRaisesRegex(ValueError, "Unexpected B1.2d retest source"):
            adapt({name: "not pinned" for name in HASHES}, "policy")

    def test_retest_preserves_failure_not_accepted_b12d(self):
        scope = experiment_scope("b12d1")
        self.assertEqual(scope["b12d_failure_sha"], B12D_FAILURE)
        self.assertEqual(scope["accepted_b12c_device_sha"], ACCEPTED_B12C)
        self.assertNotIn("accepted_b12d_device_sha", scope)
        self.assertIn("DEVICE_PENDING", scope["capability_status"])
        verify_repair_scope("b12d", {})
        with self.assertRaises(ValueError):
            verify_repair_scope("b12d1", {})
        recipe = {"diagnostic_repair": {"upstream_sha256": HASHES,
                  "adapted_sha256": dict.fromkeys((*HASHES, "rgpu_diagnostic_errors.hpp"),"0"*64)}}
        verify_repair_scope("b12d1", recipe)
        for scope in ("b11","b12a","b12b","b12c","b12d"):
            with self.assertRaises(ValueError):
                verify_repair_scope(scope, recipe)
        del recipe["diagnostic_repair"]["adapted_sha256"]["rgpu_diagnostic_errors.hpp"]
        with self.assertRaises(ValueError):
            verify_repair_scope("b12d1", recipe)

    def test_independent_opt_in_target_and_cache_policy(self):
        project = (PROBE / "project.yml").read_text()
        self.assertIn("org.remotegpu.experiments.mobileglues.capabilities.retest",project)
        self.assertEqual(project.count("RGPU_B12_STRICT_RETEST=1"),1)
        workflow = (ROOT / ".github/workflows/build-ios-compatibility-probe.yml").read_text()
        self.assertIn("experiment/b12d1-mobileglues-retest",workflow)
        self.assertIn('if [ "$PROBE_SCOPE" = b12d1 ]; then',workflow)
        self.assertIn("b11-framework-v2-${{ env.CANDIDATE_POLICY }}",workflow)
        self.assertIn("tools/ci/prepare_mobileglues_b12d_retest.py',",workflow)
        self.assertIn('has("accepted_b12d_device_sha") | not',workflow)

    def test_negative_control_and_raw_observation_never_substitute(self):
        app = (PROBE / "App/Probe.mm").read_text()
        self.assertLess(app.index("B12D1_ERROR_CONTROL"),app.index("B11_STAGE shared_gpu_content"))
        self.assertIn("observed == GL_INVALID_ENUM && drained == GL_NO_ERROR",app)
        self.assertIn("remainingRaw == GL_NO_ERROR",app)
        source = (PROBE / "Shader/ShaderProbe.mm").read_text()
        control = source.split("// Raw creation is a separate diagnostic",1)[1].split("#endif",1)[0]
        self.assertIn("rawCreate(GL_GEOMETRY_SHADER)",control)
        self.assertIn("rawDelete(rawObject)",control)
        self.assertNotIn("geometryShader =",control)
        self.assertIn("NOT_FRONTEND_SUBSTITUTION",control)
        self.assertIn('"uBuffer","u_BufferTexWidth","u_BufferTexHeight"',source)
        self.assertIn("rawUniform(resources.program,location,&value)",source)
        self.assertNotIn("rawUniform1i",source)


if __name__ == "__main__":
    unittest.main()
