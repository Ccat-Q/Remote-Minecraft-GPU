#!/usr/bin/env python3
"""Immutable, non-patching MoltenVK probe preparation. Run builds ONLY in Actions."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

PIN = "2974cbbbd42593eeeaf993d954702f74ae09a239"
HASHES = {
    "fetchDependencies": "f0b1f513e772cf6e4a1ee752946278b5897185c61d2ef8a21983f2433ae51dff",
    "MoltenVK/MoltenVK/GPUObjects/MVKDevice.mm": "b1065484cf8cd566fa85f4543cb86b574d075735f9cb3eef7bf95f6ef87eaba8",
    "MoltenVK/MoltenVK/GPUObjects/MVKPipeline.mm": "5812a65b985bbf68b7f70c5e5ce5d30dcec1209b1e842ff3b4387d48222914f5",
    "MoltenVK/MoltenVK/Commands/MVKCmdDraw.mm": "63b825221c736cbc73c8abcc78486abfdc4444858350c4e580c87aaa264439f5",
    "MoltenVKShaderConverter/MoltenVKShaderConverter/SPIRVToMSLConverter.cpp": "1cb1527cf5a012c5f2bab4e950a13f7f7883246e8d3c5a9a926664216e9e03bd",
}
VARIANTS = {
    "triangles": ("triangles", "triangle_strip", 8, ["OUTPUT_COPIES 2"]),
    "lines": ("lines", "triangle_strip", 8, ["OUTPUT_COPIES 2"]),
    "points": ("points", "triangle_strip", 8, ["OUTPUT_COPIES 2"]),
    "line_output": ("points", "line_strip", 4, ["OUTPUT_COPIES 2", "LINE_OUTPUT"]),
    "point_output": ("points", "points", 2, ["OUTPUT_COPIES 2", "POINT_OUTPUT"]),
    "primitive_id": ("triangles", "triangle_strip", 4, ["OUTPUT_COPIES 1", "PRIMITIVE_ID"]),
    "invocations": ("points, invocations=2", "triangle_strip", 4,
                    ["OUTPUT_COPIES 1", "INVOCATIONS"]),
    "gradient": ("triangles", "triangle_strip", 8, ["OUTPUT_COPIES 2", "GRADIENT"]),
    "capture": ("triangles", "triangle_strip", 8, ["OUTPUT_COPIES 2", "CAPTURE"]),
}

def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def git(source, *args):
    return subprocess.check_output(["git", "-C", str(source), *args], text=True).strip()

def checked_source(source):
    if git(source, "rev-parse", "HEAD") != PIN:
        raise ValueError("MoltenVK commit differs from audited immutable pin")
    for path, expected in HASHES.items():
        if sha(source / path) != expected:
            raise ValueError(f"Unreviewed source change: {path}")
    # Never repair feature/limit declarations in the experiment preparation.
    return {p.stem: p.read_text().strip() for p in sorted((source / "ExternalRevisions").glob("*_repo_revision"))}

def dump_function(header, name):
    match = re.search(r"typedef struct " + name + r"\s*\{(.*?)\}\s*" + name + ";", header, re.S)
    if not match:
        raise ValueError(f"Missing pinned Vulkan structure: {name}")
    lines = [f"static NSDictionary *dump{name}(const {name}& v) {{", "    NSMutableDictionary *d=[NSMutableDictionary dictionary];"]
    count = 0
    for declaration in match[1].split(";"):
        declaration = re.sub(r"//[^\n]*", "", declaration).strip()
        if not declaration:
            continue
        m = re.fullmatch(r"(\w+)\s+(\w+)(?:\[(\w+)\])?", declaration)
        if not m:
            raise ValueError(f"Unhandled Vulkan member: {declaration}")
        typ, field, array = m.groups()
        if field == "sType":
            continue
        if array:
            lines += [f"    {{ NSMutableArray *a=[NSMutableArray array]; for(auto x:v.{field}) [a addObject:@(x)]; d[@\"{field}\"]=a; }}"]
        else:
            lines += [f"    d[@\"{field}\"]=@(v.{field});"]
        count += 1
    if count < 10:
        raise ValueError("Incomplete capability dump")
    return "\n".join(lines + ["    return d;", "}"])

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--generated", type=Path, required=True)
    parser.add_argument("--framework", type=Path)
    parser.add_argument("--compile-shaders", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    probe = root / "ios/Experiments/MoltenVKGeometryProbe"
    revisions = checked_source(args.source)
    args.generated.mkdir(parents=True, exist_ok=True)
    headers = args.source / "External/Vulkan-Headers/include/vulkan/vulkan_core.h"
    if headers.exists():
        text = headers.read_text()
        (args.generated / "CapabilityDump.inc").write_text("\n".join(
            dump_function(text, s) for s in ("VkPhysicalDeviceFeatures", "VkPhysicalDeviceLimits")))
    shaders = args.generated / "Shaders"
    shaders.mkdir(exist_ok=True)
    for name in ("input.vert", "output.frag"):
        shutil.copy2(probe / "Shaders" / name, shaders / name)
    body = (probe / "Shaders/geometry.glsl").read_text()
    for name, (input_topology, output, vertices, defines) in VARIANTS.items():
        shader = "#version 450\n" + "".join(f"#define {d}\n" for d in defines)
        shader += f"layout({input_topology}) in;\nlayout({output},max_vertices={vertices}) out;\n" + body
        (shaders / f"{name}.geom").write_text(shader)
    tools = {}
    if args.compile_shaders:
        for tool in ("glslangValidator", "spirv-val", "spirv-dis"):
            tools[tool] = subprocess.check_output([tool, "--version"], text=True)
        for file in sorted(shaders.iterdir()):
            if file.suffix not in (".vert", ".frag", ".geom"):
                continue
            output = file.with_suffix(file.suffix + ".spv")
            subprocess.run(["glslangValidator", "-V", "--target-env", "vulkan1.1", "-g",
                            "-o", str(output), str(file)], check=True)
            subprocess.run(["spirv-val", "--target-env", "vulkan1.1", str(output)], check=True)
            dis = subprocess.check_output(["spirv-dis", str(output)], text=True)
            if file.suffix == ".geom" and "OpEntryPoint Geometry" not in dis:
                raise ValueError("Geometry stage missing from actual SPIR-V")
            output.with_suffix(output.suffix + ".txt").write_text(dis)
    manifest = {
        "experiment": "Isolated UTM MoltenVK Geometry Probe v1; strict reported-limit gates",
        "source_sha": git(root, "rev-parse", "HEAD"),
        "actions_run": os.environ.get("GITHUB_RUN_ID", "LOCAL_SOURCE_PREPARATION_ONLY"),
        "actions_url": f"https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/{os.environ.get('GITHUB_RUN_ID', '')}",
        "moltenvk_repository": "https://github.com/utmapp/MoltenVK", "moltenvk_sha": PIN,
        "upstream_sha256": HASHES, "adaptations": [], "external_revisions": revisions,
        "shader_tools": tools, "shader_sha256": {p.name: sha(p) for p in sorted(shaders.iterdir())},
        "capability_status": "DEVICE_PENDING; no GL/Zink/VirGL/guest acceptance",
        "known_source_blockers": ["Geometry limits are zero despite geometryShader=true",
            "Geometry indirect draws explicitly return without drawing",
            "geometryStreams advertised with upstream FIXME"],
        "accepted_a32_sha": "6dd8b04c049da999b9dbd91e4c341f4a8b6d5e31",
        "mobileglues_tbo_device_sha": "b234149c917661e499c156b3107c7cd90370181e",
    }
    if args.framework:
        manifest["framework_sha256"] = sha(args.framework / "MoltenVK")
        manifest["framework_hash_scope"] = "unsigned before external IPA signing"
    (args.generated / "Provenance.json").write_text(json.dumps(manifest, indent=2) + "\n")

if __name__ == "__main__":
    main()
