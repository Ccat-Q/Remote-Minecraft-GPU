import unittest

from prepare_utm_renderer import fix_renderer, prepare_script

RENDERER_CONTEXT = '''angle_done:

   /* glamor reject llvmpipe, and since the renderer string is
    * composed of "virgl" and this renderer string we have to
    * hide the "llvmpipe" part */
   char *llvmpipe_string = strstr(caps->v2.renderer, "llvmpipe");'''

BUILD_CONTEXT = '''download_all () {
    download $QEMU_SRC
}
copy_private_headers() {
}
build_qemu_dependencies () {
    meson_darwin_build $VIRGLRENDERER_REPO -Dtests=false
}
build_spice_client () {
}
export CC
export CPP
export CXX
export OBJCC
build_qemu_dependencies
build $QEMU_DIR --cross-prefix="" $QEMU_PLATFORM_BUILD_FLAGS $QEMU_DEBUG_FLAGS
build_spice_client
build_vulkan_drivers
build_d3d_drivers
fixup_all
remove_shared_gst_plugins # another hack...
'''
BUILD_CONTEXT += "GCC_TREAT_WARNINGS_AS_ERRORS=NO \\\n"


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
        result = prepare_script(BUILD_CONTEXT)
        self.assertLess(result.index("--renderer"), result.index("meson_darwin_build"))
        self.assertIn('CC="ccache $CC"', result)
        self.assertIn('CXX="ccache $CXX"', result)
        self.assertNotIn("download $QEMU_SRC", result)
        self.assertNotIn("build $QEMU_DIR", result)
        self.assertIn("-Dvenus=false -Dneptune=false", result)
        self.assertIn('ANGLE_ALLOWABLE_CLIENTS=""', result)
        self.assertIn("fixup_all", result)

    def test_changed_build_entry_fails_closed(self):
        with self.assertRaises(ValueError):
            prepare_script("echo changed\n")


if __name__ == "__main__":
    unittest.main()
