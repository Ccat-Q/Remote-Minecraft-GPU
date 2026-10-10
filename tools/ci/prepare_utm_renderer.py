#!/usr/bin/env python3
"""Apply checked compatibility adjustments to the pinned UTM build in CI."""

import argparse
from pathlib import Path
import re


def fix_renderer(source: str) -> str:
    # C11 requires a statement after a label; a declaration is not a statement.
    # TODO: remove when the pinned UTM virglrenderer includes the upstream fix.
    pattern = r"(?m)^([ \t]*[A-Za-z_]\w*:)([ \t]*\n[ \t]*char \*llvmpipe_string = strstr\(caps->v2.renderer, \"llvmpipe\"\);)"
    fixed, count = re.subn(pattern, r"\1 ;\2", source)
    if count != 1:
        raise ValueError("Pinned virglrenderer label/declaration context changed")
    return fixed


def prepare_script(source: str) -> str:
    anchor = "    meson_darwin_build $VIRGLRENDERER_REPO "
    if source.count(anchor) != 1:
        raise ValueError("Pinned UTM virglrenderer build entry changed")
    source = source.replace(
        anchor,
        '    python3 "$REMOTEGPU_UTM_COMPAT" --renderer '
        '"$BUILD_DIR/virglrenderer.git/src/vrend/vrend_renderer.c"\n' + anchor,
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
