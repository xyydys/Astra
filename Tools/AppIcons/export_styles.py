#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""导出选定的风格版本：每款 1024 满版 PNG（无透明、无圆角）、圆角预览 PNG、SVG 源文件，外加总览图。
用法：python3 export_styles.py [输出目录]      默认输出到 ./Astra-icons"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

from astra_icon import masked
from render import render_svgs
from styles import STYLES, build

SELECTED = [  # (编号文件名, 风格键)
    ("01_chroma", "chroma"), ("02_glow", "glow"), ("03_sticker", "sticker"), ("04_blueprint", "blueprint"),
    ("05_white", "white"), ("06_black", "black"), ("07_black_gold", "gold"),
    ("08_klein_orange", "klein"), ("09_lemon_violet", "lemon"), ("10_red_yellow", "redyellow"),
]
NAMES = {k: name for k, name, *_ in STYLES}
FONT_DIR = "/usr/share/fonts/opentype/noto"
FALLBACK_FONT = "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc"


def main(out):
    for sub in ("png", "preview", "svg"):
        os.makedirs(os.path.join(out, sub), exist_ok=True)
    jobs = []
    for fname, key in SELECTED:
        svg = build(key)
        with open(os.path.join(out, "svg", fname + ".svg"), "w", encoding="utf-8") as f:
            f.write(svg)
        jobs.append((svg, os.path.join(out, "png", fname + "_1024.png"), {"opaque": True}))
        jobs.append((masked(svg), os.path.join(out, "preview", fname + "_preview.png"), {}))
    render_svgs(jobs)
    overview(out)


def overview(out):
    try:
        fb = ImageFont.truetype(os.path.join(FONT_DIR, "NotoSansCJK-Bold.ttc"), 30, index=2)
        fr = ImageFont.truetype(os.path.join(FONT_DIR, "NotoSansCJK-Regular.ttc"), 20, index=2)
    except OSError:
        try:
            fb, fr = ImageFont.truetype(FALLBACK_FONT, 30), ImageFont.truetype(FALLBACK_FONT, 20)
        except OSError:
            fb = fr = ImageFont.load_default()
    size, gx, gy, cols = 300, 40, 84, 4
    rows = (len(SELECTED) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * size + (cols + 1) * gx, rows * (size + gy) + gx), (243, 242, 247))
    d = ImageDraw.Draw(sheet)
    for i, (fname, key) in enumerate(SELECTED):
        x, y = gx + (i % cols) * (size + gx), gx + (i // cols) * (size + gy)
        im = Image.open(os.path.join(out, "preview", fname + "_preview.png")).resize((size, size), Image.LANCZOS)
        sheet.paste(im, (x, y), im)
        d.text((x + 6, y + size + 14), NAMES[key], fill=(28, 26, 43), font=fb)
        w = d.textlength(NAMES[key], font=fb)
        d.text((x + 6 + w + 12, y + size + 24), fname[:2], fill=(94, 90, 115), font=fr)
    sheet.save(os.path.join(out, "overview.png"), optimize=True)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "Astra-icons"))
