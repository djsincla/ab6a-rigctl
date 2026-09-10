#!/usr/bin/env python3
"""Render RigCtl.icns. Build-time only - the app itself needs no third-party modules.

Requires Pillow:  python3 -m pip install pillow
"""

import os
import shutil
import subprocess
import sys

try:
    from PIL import Image, ImageDraw
except ImportError:
    sys.exit("this script needs Pillow: python3 -m pip install pillow")

SS = 4            # supersample factor - Pillow's arc/rect drawing is not antialiased
SIZE = 1024
S = SIZE * SS

BG_TOP = (34, 48, 66)
BG_BOTTOM = (13, 21, 30)
MAST = (240, 245, 250)
WAVE = [(255, 191, 79), (255, 160, 60), (255, 130, 55)]


def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def rounded_mask(size, radius):
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1],
                                           radius=radius, fill=255)
    return mask


def render():
    # vertical gradient background
    bg = Image.new("RGB", (S, S))
    px = bg.load()
    for y in range(S):
        row = lerp(BG_TOP, BG_BOTTOM, y / (S - 1))
        for x in range(S):
            px[x, y] = row

    icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    icon.paste(bg, (0, 0), rounded_mask(S, int(0.2237 * S)))

    d = ImageDraw.Draw(icon)
    cx = S // 2
    apex = int(0.375 * S)         # top of the mast - waves radiate from here
    base_y = int(0.790 * S)

    # radiating arcs - outermost stays inside a ~9% margin
    for i, radius_f in enumerate((0.135, 0.213, 0.291)):
        r = int(radius_f * S)
        w = int((0.023 + 0.005 * i) * S)
        d.arc([cx - r, apex - r, cx + r, apex + r],
              start=212, end=328, fill=WAVE[i], width=w)

    # mast
    mw = int(0.027 * S)
    d.rounded_rectangle([cx - mw, apex, cx + mw, base_y],
                        radius=mw, fill=MAST)

    # splayed legs
    leg_w = int(0.022 * S)
    spread = int(0.112 * S)
    top_y = int(0.610 * S)
    for dx in (-spread, spread):
        d.line([(cx, top_y), (cx + dx, base_y - int(0.004 * S))],
               fill=MAST, width=leg_w)

    # ground bar
    gb = int(0.163 * S)
    gh = int(0.016 * S)
    d.rounded_rectangle([cx - gb, base_y - gh, cx + gb, base_y + gh],
                        radius=gh, fill=MAST)

    # feed point
    fp = int(0.034 * S)
    d.ellipse([cx - fp, apex - fp, cx + fp, apex + fp], fill=MAST)

    return icon.resize((SIZE, SIZE), Image.LANCZOS)


def build_icns(img, out_path):
    iconset = out_path.replace(".icns", ".iconset")
    shutil.rmtree(iconset, ignore_errors=True)
    os.makedirs(iconset)
    for base in (16, 32, 128, 256, 512):
        img.resize((base, base), Image.LANCZOS).save(
            os.path.join(iconset, "icon_%dx%d.png" % (base, base)))
        img.resize((base * 2, base * 2), Image.LANCZOS).save(
            os.path.join(iconset, "icon_%dx%d@2x.png" % (base, base)))
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out_path], check=True)
    shutil.rmtree(iconset, ignore_errors=True)


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "RigCtl.icns"
    image = render()
    image.save(out.replace(".icns", "-preview.png"))
    build_icns(image, out)
    print("wrote %s" % out)
