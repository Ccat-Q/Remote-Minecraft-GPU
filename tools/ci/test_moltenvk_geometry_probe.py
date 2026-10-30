#!/usr/bin/env python3
"""Source/fixture guards. These tests do not claim Vulkan or device execution."""
import importlib.util
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location("prepare",Path(__file__).with_name("prepare_moltenvk_geometry_probe.py"))
prepare=importlib.util.module_from_spec(spec); spec.loader.exec_module(prepare)

class GeometryGuards(unittest.TestCase):
    def test_pin_and_no_adaptation(self):
        self.assertEqual(prepare.PIN,"2974cbbbd42593eeeaf993d954702f74ae09a239")
        self.assertEqual(len(prepare.HASHES),5)

    def test_real_stage_fixtures(self):
        self.assertEqual(len(prepare.VARIANTS),9)
        body=(ROOT/"ios/Experiments/MoltenVKGeometryProbe/Shaders/geometry.glsl").read_text()
        for token in ("EmitVertex()","EndPrimitive()","gl_in[0]","gl_PrimitiveIDIn","gl_InvocationID"):
            self.assertIn(token,body)

    def test_full_dump_rejects_unknown_members(self):
        with self.assertRaises(ValueError):
            prepare.dump_function("typedef struct Bad { void *pNext; } Bad;","Bad")

    def test_execution_gates_and_isolation(self):
        text=(ROOT/"ios/Experiments/MoltenVKGeometryProbe/App/Probe.mm").read_text()
        for token in ("VK_SHADER_STAGE_GEOMETRY_BIT","maxGeometryTotalOutputComponents", "vkGetFenceStatus",
                      "vkWaitForFences", "vkInvalidateMappedMemoryRanges", "PASS_DEVICE_EXECUTED",
                      "vkCmdDrawIndexedIndirect", "TRANSFORM_FEEDBACK_WRITE", "pipeline/submit/readback NOT_RUN"):
            self.assertIn(token,text)
        self.assertNotIn("vkDeviceWaitIdle(",text)
        self.assertNotIn("vkQueueWaitIdle(",text)
        for token in ("RTLD_DEFAULT", "eglMakeCurrent(", "glDrawArrays(", "quic"):
            self.assertNotIn(token,text)

if __name__=="__main__":
    unittest.main()
