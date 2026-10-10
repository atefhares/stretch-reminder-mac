#!/usr/bin/env python3
"""Draws the app icon: a white figure stretching, arms up, on a green tile.

Only needed if you want to change the icon. Needs Pillow (pip install pillow).

    python3 tools/make_icon.py        # rewrites assets/icon-1024.png
"""
import os

from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "assets", "icon-1024.png")

S = 2048            # drawn at double size, then scaled down for smooth edges
k = S / 1024
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# Rounded-square tile (macOS icon grid: an 824 pt tile on a 1024 pt canvas).
plate = int(824 * k)
off = (S - plate) // 2
rad = int(186 * k)
top, bot = (72, 214, 114), (22, 140, 72)
grad = Image.new("RGBA", (plate, plate))
gd = ImageDraw.Draw(grad)
for y in range(plate):
    t = y / (plate - 1)
    gd.line([(0, y), (plate, y)], fill=tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3)) + (255,))
mask = Image.new("L", (plate, plate), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, plate - 1, plate - 1], radius=rad, fill=255)

# Soft shadow under the tile.
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sm = Image.new("L", (S, S), 0)
sm.paste(mask, (off, off + int(12 * k)))
shadow.putalpha(sm.filter(ImageFilter.GaussianBlur(int(14 * k))).point(lambda v: int(v * 0.35)))
img = Image.alpha_composite(img, shadow)
img.paste(grad, (off, off), mask)

# The figure.
d = ImageDraw.Draw(img)
WHITE = (255, 255, 255, 255)


def limb(a, b, w):
    d.line([(a[0] * k, a[1] * k), (b[0] * k, b[1] * k)], fill=WHITE, width=int(w * k))
    for (x, y) in (a, b):
        r = w / 2
        d.ellipse([(x - r) * k, (y - r) * k, (x + r) * k, (y + r) * k], fill=WHITE)


cx = 512
hr, hy = 62, 318
d.ellipse([(cx - hr) * k, (hy - hr) * k, (cx + hr) * k, (hy + hr) * k], fill=WHITE)   # head
w = 58
shoulder, hip = (cx, 430), (cx, 640)
limb(shoulder, hip, w + 10)                                                          # torso
limb(shoulder, (cx - 118, 318), w); limb((cx - 118, 318), (cx - 150, 196), w)        # left arm, up
limb(shoulder, (cx + 118, 318), w); limb((cx + 118, 318), (cx + 150, 196), w)        # right arm, up
limb(hip, (cx - 92, 836), w)                                                         # left leg
limb(hip, (cx + 92, 836), w)                                                         # right leg

img.resize((1024, 1024), Image.LANCZOS).save(OUT)
print("wrote", os.path.normpath(OUT))
