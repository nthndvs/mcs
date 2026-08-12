#!/usr/bin/env python3
"""Render the Model Compare Studio app icon and build AppIcon.icns."""
import os
import subprocess
import sys

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(ROOT, "assets")
S = 1024

def render_master() -> Image.Image:
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # Squircle-ish mask (macOS icon grid: content area inset from the canvas).
    mask = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle([100, 100, 924, 924], radius=210, fill=255)

    # Warm dark vertical gradient background, echoing the app's palette.
    top = (43, 42, 38)
    bottom = (24, 23, 21)
    bg = Image.new("RGBA", (S, S))
    bgd = ImageDraw.Draw(bg)
    for y in range(S):
        t = y / S
        c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,)
        bgd.line([(0, y), (S, y)], fill=c)
    img.paste(bg, (0, 0), mask)

    dd = ImageDraw.Draw(img)

    # Three side-by-side "response columns": the comparison metaphor.
    warm = (242, 239, 230, 255)
    warm_dim = (190, 185, 172, 255)
    accent = (219, 101, 65, 255)

    centers = [352, 512, 672]
    heights = [300, 440, 370]
    colors = [warm_dim, accent, warm]
    width = 118
    baseline = 730
    for x, h, c in zip(centers, heights, colors):
        dd.rounded_rectangle(
            [x - width // 2, baseline - h, x + width // 2, baseline],
            radius=width // 2,
            fill=c,
        )

    # "Text lines" inside the tallest column to suggest a written answer.
    line_color = (43, 42, 38, 255)
    for i, lw in enumerate([62, 74, 48]):
        y = baseline - heights[1] + 78 + i * 54
        dd.rounded_rectangle(
            [512 - lw // 2, y, 512 + lw // 2, y + 16],
            radius=8,
            fill=line_color,
        )
    return img


def build_icns(master: Image.Image) -> None:
    iconset = os.path.join(ASSETS, "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)
    specs = {
        "icon_16x16.png": 16,
        "icon_16x16@2x.png": 32,
        "icon_32x32.png": 32,
        "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128,
        "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256,
        "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512,
        "icon_512x512@2x.png": 1024,
    }
    for name, size in specs.items():
        master.resize((size, size), Image.LANCZOS).save(os.path.join(iconset, name))
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(ASSETS, "AppIcon.icns")], check=True)
    print(f"Wrote {os.path.join(ASSETS, 'AppIcon.icns')}")


if __name__ == "__main__":
    os.makedirs(ASSETS, exist_ok=True)
    master = render_master()
    master.save(os.path.join(ASSETS, "AppIcon-1024.png"))
    build_icns(master)
