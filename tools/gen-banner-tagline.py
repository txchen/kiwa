"""Rewrites the two tagline lines of docs/assets/kiwa.svg as outlined text.

Usage: python3 tools/gen-banner-tagline.py "First line." "Second line."

The banner keeps no font: each glyph is a path outlined from Noto Sans CJK
JP Regular (SIL OFL 1.1), placed by its advance width without kerning, as
the original artwork was. Needs fontTools and the font, for example
/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc; set NOTO_CJK_REGULAR to
use another path.
"""
import os
import re
import sys

from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.ttLib import TTCollection

SVG = os.path.join(os.path.dirname(__file__), "..", "docs", "assets", "kiwa.svg")
FONT = os.environ.get("NOTO_CJK_REGULAR", "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc")
X = 284.0
BASELINES = (207, 235)
SCALE = 0.019
FILL = "#67716a"


def japanese_face(path):
    for font in TTCollection(path).fonts:
        if font["name"].getDebugName(1) == "Noto Sans CJK JP":
            return font
    sys.exit(f"{path} has no Noto Sans CJK JP face")


def line_group(font, text, baseline):
    cmap = font.getBestCmap()
    glyphs = font.getGlyphSet()
    advances = font["hmtx"].metrics
    paths = []
    x = X
    for ch in text:
        name = cmap[ord(ch)]
        if ch != " ":
            pen = SVGPathPen(glyphs)
            glyphs[name].draw(pen)
            paths.append(f'<path transform="translate({x:.3f} {baseline}) scale({SCALE} -{SCALE})" d="{pen.getCommands()}"/>')
        x += advances[name][0] * SCALE
    return f'<g fill="{FILL}">' + "".join(paths) + "</g>"


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    font = japanese_face(FONT)
    svg = open(SVG).read()
    groups = list(re.finditer(rf'<g fill="{FILL}">.*?</g>', svg))
    if len(groups) != len(BASELINES):
        sys.exit(f"expected {len(BASELINES)} tagline groups in {SVG}, found {len(groups)}")
    for group, text, baseline in reversed(list(zip(groups, sys.argv[1:], BASELINES))):
        svg = svg[: group.start()] + line_group(font, text, baseline) + svg[group.end() :]
    with open(SVG, "w") as f:
        f.write(svg)


if __name__ == "__main__":
    main()
