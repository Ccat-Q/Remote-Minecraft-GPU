"""Source mutation/provenance guards only, not simulated device acceptance."""
from pathlib import Path
import unittest
from prepare_mobileglues_tbo_repair import HASHES, OVERLAYS, section, transform
from mobileglues_provenance import verify_tbo_scope

ROOT = Path(__file__).resolve().parents[2]
OVERLAY = ROOT / "ios/Experiments/MobileGluesProbe/Overlay"

class TBORepairTests(unittest.TestCase):
    def test_reject_wrong_pin_missing_duplicate_sections(self):
        with self.assertRaises(ValueError):
            transform(dict.fromkeys(HASHES,"not pinned"),{})
        self.assertEqual(section("abcend","a","end","new"),"newend")
        for source in ("end","aendend","aaend"):
            with self.assertRaises(ValueError):
                section(source,"a","end","new")

    def test_upload_has_no_reattach_readback_or_error_swallow(self):
        source = (OVERLAY / "TBOUpload.inc").read_text()
        refresh = source.split("void refreshTBOs(",1)[1].split("void glTexBuffer(",1)[0]
        self.assertIn("g_bg->tboAttachments.forBuffer(buffer)",refresh)
        self.assertIn("uploadTBO(edge,allocate,offset,count)",refresh)
        self.assertNotIn("glTexBuffer(",refresh)
        for forbidden in ("glGetError(","glReadPixels(","glFinish(","glMapBuffer("):
            self.assertNotIn(forbidden,source)
        self.assertIn("GL_UNPACK_ALIGNMENT,1",source)
        self.assertIn("GL_UNPACK_ALIGNMENT,alignment",source)
        self.assertIn("glBindTexture(GL_TEXTURE_2D,texture)",source)
        self.assertIn("glActiveTexture(active)",source)
        script = (ROOT / "tools/ci/prepare_mobileglues_tbo_repair.py").read_text()
        self.assertIn("refreshTBOs(target,false,offset,size)",script)
        self.assertIn("refreshTBOs(target,true)",script)
        self.assertIn("eraseBuffer(buffers[i])",script)
        self.assertIn("rgpu_tbo_forget_texture(textures[i])",script)

    def test_scope_requires_full_source_coverage_only_on_retest(self):
        verify_tbo_scope("b12d",{})
        with self.assertRaises(ValueError):
            verify_tbo_scope("b12d1",{})
        recipe = {"tbo_repair": {"upstream_sha256": HASHES,
                  "adapted_sha256":dict.fromkeys((*HASHES,*OVERLAYS.values()),"0"*64)}}
        verify_tbo_scope("b12d1",recipe)
        with self.assertRaises(ValueError):
            verify_tbo_scope("b12c",recipe)
        recipe["tbo_repair"]["upstream_sha256"] = {}
        with self.assertRaises(ValueError):
            verify_tbo_scope("b12d1",recipe)

if __name__ == "__main__":
    unittest.main()
