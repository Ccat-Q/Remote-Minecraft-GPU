"""Source guards and experiment-isolation tests, not simulated device results."""
import hashlib
from pathlib import Path
import unittest

from prepare_mobileglues_probe import HASHES, MOBILEGLUES, diagnostic_apple_errors, replace_once

ROOT = Path(__file__).resolve().parents[2]
PROBE = ROOT / "ios/Experiments/MobileGluesProbe"


class MobileGluesProbeTests(unittest.TestCase):
    def test_immutable_pin_and_guard_coverage(self):
        self.assertEqual(MOBILEGLUES, "97558a69157b033b890958b1e49258c5b51a80c6")
        self.assertEqual(len(HASHES), 7)
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

    def test_runtime_checks_are_not_version_string_gates(self):
        source = (PROBE / "App/Probe.mm").read_text()
        self.assertIn("RTLD_NOW | RTLD_LOCAL | RTLD_FIRST", source)
        self.assertIn("Cross-context GPU clear content mismatch", source)
        self.assertIn("worker.join()", source)
        self.assertIn("NOT GL semantic conformance evidence", source)
        self.assertIn("B1.2 GLSL 150 shaders/features NOT TESTED", source)
        self.assertNotIn('setenv("MESA_GL_VERSION_OVERRIDE"', source)
        self.assertNotIn('setenv("MG_GL_VERSION"', source)


if __name__ == "__main__":
    unittest.main()
