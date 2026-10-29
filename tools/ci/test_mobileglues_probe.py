"""Source guards and experiment-isolation tests, not simulated device results."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from prepare_mobileglues_probe import HASHES, MOBILEGLUES, diagnostic_apple_errors, replace_once
from mobileglues_provenance import verify_bundle

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


if __name__ == "__main__":
    unittest.main()
