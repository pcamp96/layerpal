"""LayerPal app icon: a print growing inside a progress ring (concept 4).

Renders at 4x and downsamples for clean edges. Outputs:
  icon.png        default (dark gradient background, full bleed; iOS applies the mask)
  icon-dark.png   iOS dark appearance: transparent background, system supplies the backdrop
  icon-tinted.png iOS tinted appearance: grayscale on transparent, system recolors it
"""
import math
import pathlib
import sys

from PIL import Image, ImageDraw

out = pathlib.Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
S = 4096  # supersampled canvas
F = S / 100  # concept was drawn on a 100-unit grid

GREEN = (18, 165, 148)  # LayerPal teal #12A594
GREEN_LIGHT = (30, 190, 171)
TRACK = (42, 50, 55)
WHITE = (236, 236, 236)


def vertical_gradient(top, bottom):
    img = Image.new("RGBA", (S, S))
    px = ImageDraw.Draw(img)
    for y in range(S):
        t = y / (S - 1)
        c = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,)
        px.line([(0, y), (S, y)], fill=c)
    return img


def ring_arc(draw, color, start_deg, sweep_deg, cx, cy, r, w, caps=True):
    box = [cx - r - w / 2, cy - r - w / 2, cx + r + w / 2, cy + r + w / 2]
    draw.arc(box, start=start_deg, end=start_deg + sweep_deg, fill=color, width=int(w))
    if caps:  # PIL arcs have flat ends; add round caps
        for a in (start_deg, start_deg + sweep_deg):
            x = cx + r * math.cos(math.radians(a))
            y = cy + r * math.sin(math.radians(a))
            draw.ellipse([x - w / 2, y - w / 2, x + w / 2, y + w / 2], fill=color)


def bar(draw, x, y, w, h, color):
    draw.rounded_rectangle([x * F, y * F, (x + w) * F, (y + h) * F], radius=h * F / 2, fill=color)


def draw_mark(img, ring, track, bars):
    d = ImageDraw.Draw(img)
    cx = cy = S / 2
    r, w = 30 * F, 8.5 * F
    ring_arc(d, track, 0, 360, cx, cy, r, w, caps=False)
    ring_arc(d, ring, -90, 270, cx, cy, r, w)  # 75%, clockwise from 12 o'clock
    # the print growing inside: widest layer at the bottom, fading toward the top
    for (x, y, bw), alpha in zip([(36.5, 56, 27), (38.5, 47.5, 23), (41.5, 39, 17)], (1.0, 0.72, 0.45)):
        c = bars[:3] + (round(255 * alpha),)
        layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        bar(ImageDraw.Draw(layer), x, y, bw, 5.5, c)
        img.alpha_composite(layer)


def save(img, name):
    img.resize((1024, 1024), Image.LANCZOS).save(out / name)


# Default: brand gradient background.
base = vertical_gradient((30, 36, 39), (17, 21, 23))
draw_mark(base, GREEN, TRACK, WHITE)
save(base.convert("RGB"), "icon.png")  # App Store icon must be opaque

# Dark: transparent, slightly brighter ring so it pops on the system's dark backdrop.
dark = Image.new("RGBA", (S, S), (0, 0, 0, 0))
draw_mark(dark, GREEN_LIGHT, (70, 70, 70, 255), WHITE)
save(dark, "icon-dark.png")

# Tinted: grayscale luminance only; iOS tints it.
tinted = Image.new("RGBA", (S, S), (0, 0, 0, 0))
draw_mark(tinted, (255, 255, 255), (90, 90, 90, 255), (200, 200, 200))
save(tinted, "icon-tinted.png")

# Preview strip (default / dark on black / tinted on a sample tint), masked to the iOS shape.
def masked(img, bg=None):
    im = img.resize((360, 360), Image.LANCZOS).convert("RGBA")
    if bg is not None:
        b = Image.new("RGBA", im.size, bg)
        b.alpha_composite(im)
        im = b
    m = Image.new("L", im.size, 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, 359, 359], radius=81, fill=255)
    im.putalpha(m)
    return im

strip = Image.new("RGBA", (360 * 3 + 80, 400), (250, 250, 250, 255))
for i, (img, bg) in enumerate([(base, None), (dark, (0, 0, 0, 255)), (tinted, (60, 90, 140, 255))]):
    strip.alpha_composite(masked(img, bg), (20 + i * 380, 20))
strip.convert("RGB").save(out / "preview.png")
print("ok")
