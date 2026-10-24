#!/usr/bin/env python3
"""用无头 Chromium 把 SVG 渲染成 PNG：先按 2× 渲染，再用预乘 alpha 的 Lanczos 缩回目标尺寸。"""
import io
import os
import re

from PIL import Image
from playwright.sync_api import sync_playwright

os.environ.setdefault("PLAYWRIGHT_BROWSERS_PATH", "/opt/pw-browsers")
SCALE = 2


def render_svgs(jobs):
    """jobs: [(svg_text, out_png, {"sizes": [...], "opaque": bool})]"""
    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page(device_scale_factor=SCALE, viewport={"width": 1024, "height": 1024})
        for svg, out_png, opt in jobs:
            head = svg[:600]
            w = int(float(re.search(r'width="([\d.]+)"', head).group(1)))
            h = int(float(re.search(r'height="([\d.]+)"', head).group(1)))
            page.set_viewport_size({"width": w, "height": h})
            page.set_content('<!doctype html><html><head><style>html,body{margin:0;background:transparent}'
                             'svg{display:block}</style></head><body>' + svg + '</body></html>')
            page.wait_for_timeout(30)
            buf = page.screenshot(clip={"x": 0, "y": 0, "width": w, "height": h}, omit_background=True)
            big = Image.open(io.BytesIO(buf)).convert("RGBA").convert("RGBa")
            os.makedirs(os.path.dirname(out_png), exist_ok=True)
            out_w = opt.get("out_w", w)
            img = big.resize((out_w, round(out_w * h / w)), Image.LANCZOS).convert("RGBA")
            (img.convert("RGB") if opt.get("opaque") else img).save(out_png, optimize=True)
            stem, ext = os.path.splitext(out_png)
            for s in opt.get("sizes", []):
                small = big.resize((s, round(s * h / w)), Image.LANCZOS).convert("RGBA")
                (small.convert("RGB") if opt.get("opaque") else small).save(f"{stem}@{s}{ext}", optimize=True)
        browser.close()
