#!/usr/bin/env python3
"""Apply checked compatibility adjustments to the pinned UTM build in CI."""

import argparse
from pathlib import Path

DOWNLOAD_RENDERER = '''download_all () {
    [ -d "$BUILD_DIR" ] || mkdir -p "$BUILD_DIR"
    download $PKG_CONFIG_SRC
    download $FFI_SRC
    download $ICONV_SRC
    download $GETTEXT_SRC
    download $GLIB_SRC
    clone $WEBKIT_REPO $WEBKIT_COMMIT "$WEBKIT_SUBDIRS"
    clone $EPOXY_REPO $EPOXY_COMMIT
    clone $VIRGLRENDERER_REPO $VIRGLRENDERER_COMMIT
}

'''

BUILD_RENDERER = '''build_qemu_dependencies () {
    # Keep upstream's function name, but build only RemoteGPU's GL renderer.
    build $FFI_SRC
    build $ICONV_SRC
    gl_cv_onwards_func_strchrnul=future build $GETTEXT_SRC --disable-java
    meson_build $GLIB_SRC -Dtests=false -Ddtrace=disabled
    build_angle
    meson_build $EPOXY_REPO -Dtests=false -Dglx=no -Degl=yes
    python3 "$REMOTEGPU_UTM_COMPAT" --renderer "$BUILD_DIR/virglrenderer.git/src/vrend/vrend_renderer.c"
    meson_darwin_build $VIRGLRENDERER_REPO -Dtests=false -Dcheck-gl-errors=false -Dvenus=false -Dneptune=false -Dvulkan-dload=false -Drender-server-mode=thread
}

'''


def replace_function(source: str, name: str, following: str, replacement: str) -> str:
    start = name + " () {\n"
    end = following + "() {\n"
    # Most upstream functions put a space between the name and parentheses.
    if end not in source:
        end = following + " () {\n"
    if source.count(start) != 1 or source.count(end) != 1:
        raise ValueError(f"Pinned UTM function boundary changed: {name}")
    first, last = source.index(start), source.index(end)
    if last <= first:
        raise ValueError(f"Pinned UTM function order changed: {name}")
    return source[:first] + replacement + source[last:]


def fix_renderer(source: str) -> str:
    # C11 requires a statement after a label; a declaration is not a statement.
    # TODO: remove when the pinned UTM virglrenderer includes the upstream fix.
    context = '''angle_done:

   /* glamor reject llvmpipe, and since the renderer string is
    * composed of "virgl" and this renderer string we have to
    * hide the "llvmpipe" part */
   char *llvmpipe_string = strstr(caps->v2.renderer, "llvmpipe");'''
    if source.count(context) != 1 or source.count("angle_done:\n") != 1:
        raise ValueError("Pinned virglrenderer label/declaration context changed")
    return source.replace(context, context.replace("angle_done:", "angle_done: ;", 1))


def prepare_script(source: str) -> str:
    anchor = "    meson_darwin_build $VIRGLRENDERER_REPO "
    if source.count(anchor) != 1:
        raise ValueError("Pinned UTM virglrenderer build entry changed")
    angle_link = "GCC_TREAT_WARNINGS_AS_ERRORS=NO \\\n"
    if source.count(angle_link) != 1:
        raise ValueError("Pinned UTM ANGLE build settings changed")
    source = source.replace(angle_link, angle_link + '                                         LD_DYLIB_ALLOWABLE_CLIENTS="" \\\n')
    source = replace_function(source, "download_all", "copy_private_headers", DOWNLOAD_RENDERER)
    source = replace_function(source, "build_qemu_dependencies", "build_spice_client", BUILD_RENDERER)
    tail = '''build_qemu_dependencies
build $QEMU_DIR --cross-prefix="" $QEMU_PLATFORM_BUILD_FLAGS $QEMU_DEBUG_FLAGS
build_spice_client
build_vulkan_drivers
build_d3d_drivers
fixup_all
remove_shared_gst_plugins # another hack...'''
    if source.count(tail) != 1:
        raise ValueError("Pinned UTM build dispatch changed")
    source = source.replace(
        tail,
        'build_qemu_dependencies\nmkdir -p "$PREFIX/libexec"\nfixup_all',
    )
    compiler_anchor = "export CC\nexport CPP\nexport CXX\nexport OBJCC\n"
    if source.count(compiler_anchor) != 1:
        raise ValueError("Pinned UTM compiler export block changed")
    # Explicit cross compilers otherwise bypass Meson's automatic ccache use.
    return source.replace(
        compiler_anchor,
        'CC="ccache $CC"\nCXX="ccache $CXX"\nOBJCC="ccache $OBJCC"\n'
        + compiler_anchor,
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--script", type=Path)
    group.add_argument("--renderer", type=Path)
    args = parser.parse_args()
    path = args.script or args.renderer
    transform = prepare_script if args.script else fix_renderer
    path.write_text(transform(path.read_text()))


if __name__ == "__main__":
    main()
