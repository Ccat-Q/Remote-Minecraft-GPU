#!/usr/bin/env python3
"""Opt-in B1.2d.1 minimal repair, AFTER the accepted base Apple adaptation.

Never run on the formal renderer sysroot. This script is not enabled by the
baseline workflow. A separate retest branch/target must explicitly invoke it.
It does not implement float TBO, live storage updates or Geometry Shaders.
"""
import argparse
import hashlib
import json
from pathlib import Path

from prepare_mobileglues_probe import MOBILEGLUES, replace_once

HASHES = {
    "gl/getter.cpp": "1f7272e42e6ecfb4d601cef882295cd7167a1925a3bcc8cbd260406122c7e288",
    "gl/gl_native.cpp": "56dec4f2228668b76da8d04d3a8bd6305d2c0e141916b35d87b93031f29f834b",
    "gl/drawing.cpp": "ee5d2523174aada84cbeb465efd91a98356e1784fc279377a578da5387dc5192",
}
STRICT_GETTER = '''GLenum glGetError() {
    LOG()
    // B1.2d.1 diagnostics: upstream always returned zero, even with
    // ignore_error=None. Do not consume or hide the backend error here.
    return rgpu::diagnostic::takeError(g_frontend_error, [] {
        return static_cast<unsigned>(GLES.glGetError());
    });
}
'''
NATIVE_DRAW = "NATIVE_FUNCTION_HEAD(void, glDrawArrays, GLenum mode, GLint first, GLsizei count) NATIVE_FUNCTION_END_NO_RETURN(void, glDrawArrays, mode,first,count)"
PREPARED_DRAW = '''// B1.2d.1: arrays must prepare emulated TBO samplers/dimensions too.
void glDrawArrays(GLenum mode, GLint first, GLsizei count) {
    LOG()
    prepareForDraw();
    GLES.glDrawArrays(mode, first, count);
    CHECK_GL_ERROR
}

'''


def repair_getter(source):
    start = source.index("GLenum glGetError() {\n")
    end = source.index("\nstatic std::string es_ext;", start)
    if source.count("GLenum glGetError() {\n") != 1:
        raise ValueError("Ambiguous glGetError definition")
    if "return GL_NO_ERROR;" not in source[start:end]:
        raise ValueError("Expected pinned always-zero error behavior")
    return '#include "../rgpu_diagnostic_errors.hpp"\n' + source[:start] + STRICT_GETTER + source[end:]


def repair_draw(native, drawing):
    native = replace_once(native, NATIVE_DRAW,
                          "// B1.2d.1 glDrawArrays is defined in gl/drawing.cpp with prepareForDraw.")
    drawing = replace_once(drawing, "void glDrawElementsInstanced(",
                           PREPARED_DRAW + "void glDrawElementsInstanced(")
    return native, drawing


def adapt(sources, policy):
    for name, expected in HASHES.items():
        if hashlib.sha256(sources[name].encode()).hexdigest() != expected:
            raise ValueError(f"Unexpected B1.2d retest source: {name}")
    result = dict(sources)
    result["gl/getter.cpp"] = repair_getter(sources["gl/getter.cpp"])
    result["gl/gl_native.cpp"], result["gl/drawing.cpp"] = repair_draw(
        sources["gl/gl_native.cpp"], sources["gl/drawing.cpp"])
    result["rgpu_diagnostic_errors.hpp"] = policy
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--overlay", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    if manifest["mobileglues_sha"] != MOBILEGLUES or "diagnostic_repair" in manifest:
        raise ValueError("Require pinned base adaptation, exactly one retest repair")
    root = args.source / "MobileGlues-cpp"
    sources = {name: (root / name).read_text() for name in HASHES}
    result = adapt(sources, (args.overlay / "DiagnosticErrors.hpp").read_text())
    for name, content in result.items():
        (root / name).write_text(content)
    adapted = {name: hashlib.sha256(content.encode()).hexdigest() for name, content in result.items()}
    manifest["diagnostic_repair"] = {
        "scope": "B1.2d.1 strict error observability and non-indexed draw preparation ONLY; NOT full TBO/Geometry repair",
        "recipe_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "upstream_sha256": HASHES, "adapted_sha256": adapted,
    }
    manifest["upstream_sha256"].update(HASHES)
    manifest["adapted_sha256"].update(adapted)
    manifest["scope"] = "B1.2d.1 isolated diagnostic repair; required capability gate still BLOCKED pending actual retest"
    args.manifest.write_text(json.dumps(manifest,indent=2,sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
