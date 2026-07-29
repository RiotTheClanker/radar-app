#!/usr/bin/env python3
"""Draw the app icon once, render it everywhere it is needed.

The artwork lives here as geometry, not as a pile of exported PNGs, so a
tweak to the sweep angle or the storm colors reaches Android, Windows and
Linux in one run:

    pip install pillow cairosvg
    python3 branding/make_icons.py

Writes the three master SVGs next to this file, then the platform assets.
"""

import io
import math
import os

import cairosvg
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RES = os.path.join(ROOT, "app/android/app/src/main/res")

C = 512.0  # center of the 1024 canvas

# Night sky, the same family as the app's dark chrome.
BG0, BG1 = "#0E1626", "#1E3255"
SWEEP = "#38E1FF"
RING = "#4C74A8"
# Reflectivity, low to high.
STORM = ["#2FBF4E", "#F5D30A", "#E8342C"]

# The sweep leads at up-right and trails 90 degrees back over the top.
TH0, TH1 = math.radians(-50), math.radians(-140)
R_OUT = 390.0


def polar(r, th):
    return C + r * math.cos(th), C + r * math.sin(th)


X0, Y0 = polar(R_OUT, TH0)
X1, Y1 = polar(R_OUT, TH1)


def artwork(mono=False):
    """The icon proper, minus any background plate."""
    if mono:
        # Themed icons get tinted a single color, so opacity is the only
        # contrast available. A stack of translucent ellipses just smears;
        # the cell has to be one solid shape.
        ring, sweep, dot = "#FFFFFF", "#FFFFFF", "#FFFFFF"
        cells_spec = [((618, 644, 110, 84), "#FFFFFF", 1.0)]
        ring_op = 0.9
    else:
        ring, sweep, dot = RING, SWEEP, SWEEP
        cells_spec = list(zip(
            [(612, 648, 134, 104), (624, 640, 86, 64), (632, 634, 44, 32)],
            STORM,
            (0.95, 0.95, 0.95),
        ))
        ring_op = 0.75

    rings = "\n".join(
        f'    <circle cx="{C}" cy="{C}" r="{r}" fill="none" stroke="{ring}"'
        f' stroke-width="{w}" opacity="{ring_op * o:.2f}"/>'
        for r, w, o in ((130, 7, 1.0), (260, 7, 0.8), (390, 9, 0.6))
    )

    # Storm cell in the lower right: green shoulder, yellow, hot core.
    cells = "\n".join(
        f'    <ellipse cx="{cx}" cy="{cy}" rx="{rx}" ry="{ry}" fill="{c}"'
        f' opacity="{o}" transform="rotate(-25 {cx} {cy})"/>'
        for (cx, cy, rx, ry), c, o in cells_spec
    )

    return f"""  <g>
{rings}
{cells}
    <path d="M {C} {C} L {X0:.1f} {Y0:.1f}
             A {R_OUT} {R_OUT} 0 0 0 {X1:.1f} {Y1:.1f} Z"
          fill="url(#sweep)"/>
    <path d="M {C} {C} L {X0:.1f} {Y0:.1f}" stroke="{sweep}"
          stroke-width="11" stroke-linecap="round" opacity="0.95"/>
    <circle cx="{C}" cy="{C}" r="26" fill="{dot}"/>
  </g>"""


def sweep_gradient(mono=False):
    c = "#FFFFFF" if mono else SWEEP
    return f"""    <linearGradient id="sweep" gradientUnits="userSpaceOnUse"
        x1="{X0:.1f}" y1="{Y0:.1f}" x2="{X1:.1f}" y2="{Y1:.1f}">
      <stop offset="0" stop-color="{c}" stop-opacity="0.85"/>
      <stop offset="0.45" stop-color="{c}" stop-opacity="0.22"/>
      <stop offset="1" stop-color="{c}" stop-opacity="0"/>
    </linearGradient>"""


def svg(body, defs=""):
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024"'
        f' viewBox="0 0 1024 1024">\n  <defs>\n{defs}\n  </defs>\n{body}\n</svg>\n'
    )


# Adaptive icons crop the outer 18 of 108dp and mask what is left, and the
# mask can be a circle only 72dp across. The 390-unit outer ring has to land
# inside that with room to spare: 390 * 0.80 = 312 units = 32.9dp radius,
# against a 36dp mask. At 0.89 the ring was clipped.
SAFE = 0.80
INSET = f'  <g transform="translate({C} {C}) scale({SAFE}) translate({-C} {-C})">\n{{}}\n  </g>'

MASTER = svg(
    f"""  <defs/>
  <rect width="1024" height="1024" rx="224" fill="url(#plate)"/>
{artwork()}""",
    f"""    <linearGradient id="plate" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="{BG0}"/>
      <stop offset="1" stop-color="{BG1}"/>
    </linearGradient>
{sweep_gradient()}""",
)

FOREGROUND = svg(INSET.format(artwork()), sweep_gradient())
MONOCHROME = svg(INSET.format(artwork(mono=True)), sweep_gradient(mono=True))


def render(source, size):
    png = cairosvg.svg2png(
        bytestring=source.encode(), output_width=size, output_height=size
    )
    return Image.open(io.BytesIO(png)).convert("RGBA")


def write(img, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path)
    print(f"  {os.path.relpath(path, ROOT)}  {img.width}px")


def main():
    for name, source in (
        ("icon.svg", MASTER),
        ("icon-foreground.svg", FOREGROUND),
        ("icon-monochrome.svg", MONOCHROME),
    ):
        with open(os.path.join(HERE, name), "w") as f:
            f.write(source)
        print(f"  branding/{name}")

    # Android. Legacy launcher icons are 48dp, adaptive layers are 108dp.
    print("android")
    densities = (("mdpi", 1), ("hdpi", 1.5), ("xhdpi", 2), ("xxhdpi", 3), ("xxxhdpi", 4))
    for d, s in densities:
        out = os.path.join(RES, f"mipmap-{d}")
        write(render(MASTER, round(48 * s)), os.path.join(out, "ic_launcher.png"))
        write(render(FOREGROUND, round(108 * s)),
              os.path.join(out, "ic_launcher_foreground.png"))
        write(render(MONOCHROME, round(108 * s)),
              os.path.join(out, "ic_launcher_monochrome.png"))

    # Windows: one .ico carrying every size the shell asks for.
    print("windows")
    ico = os.path.join(ROOT, "app/windows/runner/resources/app_icon.ico")
    sizes = [16, 24, 32, 48, 64, 128, 256]
    imgs = [render(MASTER, s) for s in sizes]
    imgs[-1].save(ico, sizes=[(s, s) for s in sizes],
                  append_images=imgs[:-1], format="ICO")
    print(f"  {os.path.relpath(ico, ROOT)}  {sizes}")

    # Linux: hicolor tree, picked up by the .deb and by `flutter run -d linux`.
    print("linux")
    for s in (16, 24, 32, 48, 64, 128, 256, 512):
        write(render(MASTER, s), os.path.join(
            ROOT, f"packaging/icons/hicolor/{s}x{s}/apps/radar-app.png"))

    print("\nregenerated. commit the PNGs alongside the SVGs.")


if __name__ == "__main__":
    main()
