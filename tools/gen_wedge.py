#!/usr/bin/env python3
"""Generate the four directional wedge textures for the SnakeSays HUD.

Each wedge is a white, anti-aliased 90-degree pie slice of a circle, pointing
in one cardinal direction (N/E/S/W). White RGB so the addon can vertex-color a
wedge to its assigned marker's colour at runtime; the alpha channel carries the
shape. A small center hub hole and diagonal gaps separate the four wedges so
they read as a classic "Simon Says" board once assembled.

The textures are deliberately pre-oriented (one file per direction) so the addon
never has to rotate them in-game, which avoids any SetRotation sign ambiguity.

WoW needs uncompressed 32-bit TGA with power-of-two dimensions; PIL's default
TGA writer produces exactly that.

Run from the repo root:  python tools/gen_wedge.py
"""

import os
from PIL import Image

SIZE = 256          # final texture size (power of two)
SS = 4              # supersample factor for anti-aliasing
OUTER_R = 125.0     # outer radius, final px
INNER_R = 18.0      # center hub hole radius, final px
GAP = 6.0           # half-gap along the diagonal seams, final px

OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "Media")

# direction -> predicate on (dx, dy) with y pointing DOWN (image space).
# Each selects one 90-degree wedge bounded by the two diagonals.
DIRS = {
    "n": lambda dx, dy: -dy >= abs(dx) + GAP,   # up
    "e": lambda dx, dy:  dx >= abs(dy) + GAP,   # right
    "s": lambda dx, dy:  dy >= abs(dx) + GAP,   # down
    "w": lambda dx, dy: -dx >= abs(dy) + GAP,   # left
}


def render(direction, predicate):
    big = SIZE * SS
    img = Image.new("RGBA", (big, big), (255, 255, 255, 0))
    px = img.load()
    cx = cy = (big - 1) / 2.0
    outer2 = (OUTER_R * SS) ** 2
    inner2 = (INNER_R * SS) ** 2
    for y in range(big):
        dy = y - cy
        for x in range(big):
            dx = x - cx
            d2 = dx * dx + dy * dy
            if d2 > outer2 or d2 < inner2:
                continue
            if predicate(dx, dy * 1.0):
                px[x, y] = (255, 255, 255, 255)
    # Downsample -> box-filter anti-aliasing on the alpha edges.
    img = img.resize((SIZE, SIZE), Image.LANCZOS)
    out = os.path.join(OUT_DIR, "wedge-%s.tga" % direction)
    img.save(out)
    print("wrote", os.path.normpath(out))


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    # GAP/INNER_R/OUTER_R are in final px; scale predicate inputs to render px.
    for direction, pred in DIRS.items():
        scaled = (lambda p: (lambda dx, dy: p(dx / SS, dy / SS)))(pred)
        render(direction, scaled)


if __name__ == "__main__":
    main()
