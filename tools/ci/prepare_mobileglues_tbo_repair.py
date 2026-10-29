#!/usr/bin/env python3
"""Opt-in existing B1.2d TBO repair AFTER base + strict-error adaptation.

No Geometry implementation, capability override, backend or formal renderer change.
"""
import argparse
import hashlib
import json
from pathlib import Path
from prepare_mobileglues_probe import MOBILEGLUES, replace_once

HASHES = {
    "gl/buffer.cpp": "0677cf42b81d0b129374d8aa378f40bf77c00b69a0d7b806f6a365ba8e8fc898",
    "gl/texture.cpp": "36b0a9569ece03974f26303f6346fd93b653ce13200264600c49d942374cd0d4",
    "gl/glsl/glsl_for_es.cpp": "dfd4740a29c23d0f125e7ed37562353d31f6c696dce86f2d16cfc85c3db4f4d3",
}
OVERLAYS = {"TBOAttachments.hpp": "rgpu_tbo_attachments.hpp",
            "TBOSamplers.hpp": "rgpu_tbo_samplers.hpp", "TBOUpload.inc": "rgpu_tbo_upload.inc"}


def section(source, start, end, replacement):
    if source.count(start) != 1 or source.count(end) != 1:
        raise ValueError("Missing/ambiguous TBO source section")
    begin = source.index(start)
    finish = source.index(end, begin)
    return source[:begin] + replacement + source[finish:]


def transform(sources, overlays):
    for name, expected in HASHES.items():
        if hashlib.sha256(sources[name].encode()).hexdigest() != expected:
            raise ValueError(f"Unexpected pinned TBO source: {name}")
    result = dict(sources)
    buffer = replace_once(sources["gl/buffer.cpp"], '#include "buffer.h"',
                          '#include "buffer.h"\n#include "../rgpu_tbo_attachments.hpp"')
    buffer = replace_once(buffer, "struct buffer_group_state_t { // shared across a share group",
                          "struct buffer_group_state_t { // shared across a share group\n    rgpu::tbo::Attachments tboAttachments;")
    buffer = section(buffer,"// Todo: any glGet* related to this function?\nvoid glTexBuffer(",
                     "void glTexBufferRange(", '#include "../rgpu_tbo_upload.inc"\n\n')
    buffer = replace_once(buffer,"        remove_buffer(buffers[i]);",
                          "        g_bg->tboAttachments.eraseBuffer(buffers[i]);\n        remove_buffer(buffers[i]);")
    buffer = replace_once(buffer,"    set_buffer_data_size(find_bound_buffer_by_target(target), size);\n    CHECK_GL_ERROR\n}",
                          "    if (size >= 0) {\n        set_buffer_data_size(find_bound_buffer_by_target(target), size);\n        refreshTBOs(target,true);\n    }\n    CHECK_GL_ERROR\n}")
    buffer = replace_once(buffer,"    GLES.glBufferSubData(t.target, offset, size, data);\n    CHECK_GL_ERROR",
                          "    GLES.glBufferSubData(t.target, offset, size, data);\n    if (data && size > 0) refreshTBOs(target,false,offset,size);\n    CHECK_GL_ERROR")
    result["gl/buffer.cpp"] = buffer
    texture = replace_once(sources["gl/texture.cpp"], '#include "texture.h"',
                           '#include "texture.h"\nvoid rgpu_tbo_forget_texture(GLuint texture);')
    result["gl/texture.cpp"] = replace_once(texture,"        MarkTextureObjectForDeletion(textures[i]);",
                                            "        rgpu_tbo_forget_texture(textures[i]);\n        MarkTextureObjectForDeletion(textures[i]);")
    glsl = replace_once(sources["gl/glsl/glsl_for_es.cpp"], '#include "glsl_for_es.h"',
                        '#include "glsl_for_es.h"\n#include "../../rgpu_tbo_samplers.hpp"')
    result["gl/glsl/glsl_for_es.cpp"] = section(glsl,"void process_sampler_buffer(std::string& source)",
        "static void inject_textureQueryLod(",
        "void process_sampler_buffer(std::string& source) {\n"
        "    source = rgpu::tbo::lowerSamplers(source,find_insertion_point(source));\n}\n\n")
    result.update({destination: overlays[name] for name, destination in OVERLAYS.items()})
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("source", "overlay", "manifest"):
        parser.add_argument("--"+name,type=Path,required=True)
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    if manifest["mobileglues_sha"] != MOBILEGLUES or not manifest.get("diagnostic_repair") or "tbo_repair" in manifest:
        raise ValueError("Require pinned base + strict adaptation; apply TBO repair exactly once")
    root = args.source / "MobileGlues-cpp"
    sources = {name: (root/name).read_text() for name in HASHES}
    overlays = {name: (args.overlay/name).read_text() for name in OVERLAYS}
    result = transform(sources,overlays)
    for name, value in result.items():
        (root/name).write_text(value)
    adapted = {name: hashlib.sha256(value.encode()).hexdigest() for name,value in result.items()}
    manifest["tbo_repair"] = {
        "scope": "B1.2d repair revision: typed scalar TBO lowering + same-context BufferData/SubData attachment propagation; NOT full TBO/Geometry conformance",
        "recipe_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "upstream_sha256": HASHES, "adapted_sha256": adapted,
    }
    manifest["upstream_sha256"].update(HASHES)
    manifest["adapted_sha256"].update(adapted)
    manifest["scope"] = "B1.2d TBO repair retest; strict errors retained; Geometry remains BLOCKED; device acceptance pending"
    args.manifest.write_text(json.dumps(manifest,indent=2,sort_keys=True)+"\n")


if __name__ == "__main__":
    main()
