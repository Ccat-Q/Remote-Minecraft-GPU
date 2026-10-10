import unittest

from prepare_utm_renderer import fix_renderer, prepare_script

RENDERER_CONTEXT = '''angle_done:

   /* glamor reject llvmpipe, and since the renderer string is
    * composed of "virgl" and this renderer string we have to
    * hide the "llvmpipe" part */
   char *llvmpipe_string = strstr(caps->v2.renderer, "llvmpipe");'''


class UTMCompatibilityTests(unittest.TestCase):
    def test_c11_label_requires_statement(self):
        self.assertEqual(
            fix_renderer(RENDERER_CONTEXT),
            RENDERER_CONTEXT.replace("angle_done:", "angle_done: ;"),
        )

    def test_changed_renderer_fails_closed(self):
        with self.assertRaises(ValueError):
            fix_renderer("int unrelated;\n")

    def test_duplicate_renderer_context_fails_closed(self):
        with self.assertRaises(ValueError):
            fix_renderer(RENDERER_CONTEXT * 2)

    def test_build_hook_runs_before_renderer_build(self):
        source = (
            "    meson_darwin_build $VIRGLRENDERER_REPO -Dtests=false\n"
            "export CC\nexport CPP\nexport CXX\nexport OBJCC\n"
        )
        result = prepare_script(source)
        self.assertLess(result.index("--renderer"), result.index("meson_darwin_build"))
        self.assertIn('CC="ccache $CC"', result)
        self.assertIn('CXX="ccache $CXX"', result)
        self.assertTrue(result.endswith("export CC\nexport CPP\nexport CXX\nexport OBJCC\n"))

    def test_changed_build_entry_fails_closed(self):
        with self.assertRaises(ValueError):
            prepare_script("echo changed\n")


if __name__ == "__main__":
    unittest.main()
