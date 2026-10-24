#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""风格版本：几何与构造规则完全不变，只换"材质 + 配色"。
每个图标最多 4 种颜色：背景、星轨、主星、卫星星（两色风格就是背景 + 一种元素色）。
渐变只做同一颜色的深浅，方向仍沿光轴 L（左上 → 右下）；星轨远端向背景色轻混（空气透视）。"""
import math

import numpy as np

from astra_icon import INV1, INV2, INV3, S, Astra, fmt, hue_delta, m, oklch_mix, ramp

W8 = "#FFFFFF"


def tone(c, up=0.06, down=-0.05):
    """同一色相的受光端 / 背光端：只改明度。"""
    L, C, h = c
    return (min(L + up, 0.995), C, h), (max(L + down, 0.0), C, h)


def fx_filter(A, fid, dz=0, sh_color=None, sh_op=0.0, rims=(), core=None):
    """投影（沿 L 平移 dz·u，模糊 σ = dz·u）+ 受光边（可叠两层）+ 背光内暗部。"""
    L = A.LIGHT
    f = [f'<filter id="{fid}" filterUnits="userSpaceOnUse" x="-512" y="-512" width="2560" height="2560" '
         f'color-interpolation-filters="sRGB">']
    merge = []
    if dz and sh_op:
        sx, sy = dz * A.u * L
        f += [f'<feGaussianBlur in="SourceAlpha" stdDeviation="{fmt(dz * A.u)}" result="sb"/>',
              f'<feOffset in="sb" dx="{fmt(sx)}" dy="{fmt(sy)}" result="so"/>',
              f'<feFlood flood-color="{sh_color}" flood-opacity="{sh_op:.3f}"/>',
              '<feComposite in2="so" operator="in" result="shadow"/>']
        merge.append("shadow")
    merge.append("SourceGraphic")
    if core:
        cw, cc, co = core
        dx, dy = -cw * L
        f += [f'<feOffset in="SourceAlpha" dx="{fmt(dx)}" dy="{fmt(dy)}" result="co"/>',
              '<feComposite in="SourceAlpha" in2="co" operator="out" result="cb"/>',
              f'<feGaussianBlur in="cb" stdDeviation="{fmt(cw * INV1)}" result="cbb"/>',
              '<feComposite in="cbb" in2="SourceAlpha" operator="in" result="cbc"/>',
              f'<feFlood flood-color="{cc}" flood-opacity="{co:.3f}"/>',
              '<feComposite in2="cbc" operator="in" result="core"/>']
        merge.append("core")
    for i, (rw, rop) in enumerate(rims):
        dx, dy = rw * L
        f += [f'<feOffset in="SourceAlpha" dx="{fmt(dx)}" dy="{fmt(dy)}" result="ro{i}"/>',
              f'<feComposite in="SourceAlpha" in2="ro{i}" operator="out" result="rb{i}"/>',
              f'<feGaussianBlur in="rb{i}" stdDeviation="{fmt(rw * INV1)}" result="rbb{i}"/>',
              f'<feComposite in="rbb{i}" in2="SourceAlpha" operator="in" result="rbc{i}"/>',
              f'<feFlood flood-color="#FFFFFF" flood-opacity="{rop:.3f}"/>',
              f'<feComposite in2="rbc{i}" operator="in" result="rim{i}"/>']
        merge.append(f"rim{i}")
    f.append("<feMerge>" + "".join(f'<feMergeNode in="{n}"/>' for n in merge) + "</feMerge></filter>")
    return "".join(f)


def grads(A, st):
    """背景、主星、星轨、卫星星的渐变（全部沿光轴）。"""
    from astra_icon import oklch_hex  # noqa
    bg0, bg1 = st["bg"]
    star_lit, star_sh = st.get("star_ends") or tone(st["star"], *st.get("star_tone", (0.06, -0.05)))
    bg_span = ((S / 2, 0.0), (S / 2, S)) if st.get("bg_vertical") else A.bg_span
    out = [A.lin_grad("zBg", bg_span, ramp(bg0, bg1, 9)),
           A.lin_grad("zStar", A.star_span, ramp(star_lit, star_sh, 9))]
    sat = st.get("sat")
    if sat is not None and sat != st["star"]:
        s0, s1 = tone(sat, *st.get("sat_tone", (0.04, -0.04)))
        out.append(A.lin_grad("zSat", A.star_span, ramp(s0, s1, 9)))
    bg_mid = oklch_mix(bg0, bg1, 0.5)
    if st.get("split"):
        for gid, c in (("zRingN", st["ring"]), ("zRingF", st["ring_far"])):
            c0, c1 = tone(c, *st.get("split_tone", (0.05, -0.04)))
            out.append(A.lin_grad(gid, A.ring_span, ramp(c0, c1, 9)))
    elif st.get("ring_tone"):
        r0, r1 = tone(st["ring"], *st["ring_tone"])
        out.append(A.lin_grad("zRing", A.ring_span, ramp(r0, r1, 9)))
    else:
        near = st["ring"]
        k = st.get("far_mix", INV3)
        # 星轨远端 = 近端向背景中段色混合 k（空气透视）；无彩色背景时色相保持不变
        if bg_mid[1] < 0.02:
            far = (near[0] + (bg_mid[0] - near[0]) * k, near[1] * (1 - k), near[2])
        else:
            far = oklch_mix(near, bg_mid, k, hue_delta(near[2], bg_mid[2], k))
        out.append(A.lin_grad("zRing", A.ring_span, ramp(far, near, 9)))
    return "".join(out)


def blueprint(op=0.42, w=2.6, disc=0.12):
    """开发者蓝图网格（参考系统图标模板）：画布等分 8×8 的网格线、两条对角线、
    三个同心圆（半径 0.40 / 0.25 / 0.105 画布），最大的圆整块提亮。"""
    c = S / 2
    line = 'stroke="#BFEAFF" stroke-opacity="{op}" stroke-width="{w}" fill="none"'.format(op=op, w=w)
    parts = [f'<circle cx="{fmt(c)}" cy="{fmt(c)}" r="{fmt(S * 0.40)}" fill="#FFFFFF" fill-opacity="{disc}"/>']
    for i in range(1, 8):
        v = S * i / 8
        parts.append(f'<line x1="{fmt(v)}" y1="0" x2="{fmt(v)}" y2="{fmt(S)}" {line}/>')
        parts.append(f'<line x1="0" y1="{fmt(v)}" x2="{fmt(S)}" y2="{fmt(v)}" {line}/>')
    parts.append(f'<line x1="0" y1="0" x2="{fmt(S)}" y2="{fmt(S)}" {line}/>')
    parts.append(f'<line x1="{fmt(S)}" y1="0" x2="0" y2="{fmt(S)}" {line}/>')
    for r in (0.40, 0.25, 0.105):
        parts.append(f'<circle cx="{fmt(c)}" cy="{fmt(c)}" r="{fmt(S * r)}" {line}/>')
    return "".join(parts)


def split_ring_layers(A):
    """多彩风：星轨在两个端点（θ = 0° 与 180°）处分成近半圈与远半圈两种颜色。"""
    eps = math.radians(1.2)        # 远半圈多画一点，压在近半圈下面，避免接缝
    w = fmt(A.rw)
    def path(d, gid):
        return f'<path d="{d}" fill="none" stroke="url(#{gid})" stroke-width="{w}" stroke-linecap="butt"/>'
    pa, pb = A.ring_pt(A.th_a), A.ring_pt(A.th_b)
    cap = lambda p: f'<circle cx="{fmt(p[0])}" cy="{fmt(p[1])}" r="{fmt(A.rw / 2)}" fill="url(#zRingF)"/>'
    back = f'<g mask="url(#mRing)">{path(A.ring_arc_d(A.th_back, A.th_b), "zRingF")}{cap(pb)}</g>'
    front = (f'<g mask="url(#mRing)">{path(A.ring_arc_d(A.th_a, eps), "zRingF")}{cap(pa)}'
             f'{path(A.ring_arc_d(math.pi - eps, A.th_back), "zRingF")}'
             f'{path(A.ring_arc_d(0.0, math.pi), "zRingN")}</g>')
    return back, front


def svg_flat_style(A, st):
    """平面风格（多彩 / 白 / 黑 / 撞色 / 开发者蓝图 / 柔光）。"""
    defs = [A.defs(), grads(A, st)]
    sat_fill = "url(#zSat)" if (st.get("sat") is not None and st["sat"] != st["star"]) else "url(#zStar)"
    fx = st.get("fx")
    if fx:
        defs.append(fx_filter(A, "xStar", **fx["star"]))
        defs.append(fx_filter(A, "xRing", **fx["ring"]))
    wrap = lambda body, fid: f'<g filter="url(#{fid})">{body}</g>' if fx else body
    body = [f'<rect width="{fmt(S)}" height="{fmt(S)}" fill="url(#zBg)"/>', st.get("overlay", "")]
    if st.get("glow"):
        body.append(glow_layers(A, st["glow"]))
    if st.get("split"):
        back, front = split_ring_layers(A)
    else:
        back, front = A.l_back("url(#zRing)"), A.l_front("url(#zRing)")
    body += [wrap(back, "xRing"), wrap(A.l_star("url(#zStar)"), "xStar"), wrap(front, "xRing"),
             wrap(A.l_sat(sat_fill), "xRing")]
    return A.doc("".join(body), "".join(defs))


def glow_layers(A, g):
    """柔光：主星轮廓的两团模糊光晕，分别沿光轴向左上、右下错开。"""
    from astra_icon import oklch_hex
    out = []
    for color, off, op in g:
        dx, dy = off * A.LIGHT
        out.append(f'<g transform="translate({fmt(dx)} {fmt(dy)})" opacity="{op}" filter="url(#zBlur)">'
                   f'<path d="{A.star_d}" fill="{oklch_hex(color)}" stroke="{oklch_hex(color)}" '
                   f'stroke-width="{fmt(2 * A.tip_r)}" stroke-linejoin="round"/></g>')
    blur = (f'<filter id="zBlur" filterUnits="userSpaceOnUse" x="-512" y="-512" width="2560" height="2560">'
            f'<feGaussianBlur stdDeviation="{fmt(m(6))}"/></filter>')
    return f'<defs>{blur}</defs>' + "".join(out)


def svg_sticker(A, st):
    """糖纸风（参考 Arc Search）：粗圆头形 + 白色贴纸描边。
    立体关系：星轨远半圈（θ 不在 0~π）从主星后面经过、被主星挡住；近半圈（0~π）压在主星前面。
    每一层各带自己的白描边和投影，前后层的描边自然把彼此隔开。"""
    from astra_icon import oklch_hex
    o = st["outline"]
    star_c, ring_c, sat_c = (oklch_hex(st[k]) for k in ("star", "ring", "sat"))
    eps = math.radians(0.8)        # 远半圈多画一点压在近半圈下面，避免接缝
    back_d = [A.ring_arc_d(A.th_a, eps), A.ring_arc_d(math.pi - eps, A.th_b)]
    front_d = A.ring_arc_d(0.0, math.pi)
    halo_w, ring_hw = fmt(2 * (A.tip_r + o)), fmt(A.rw + 2 * o)
    rw, tw = fmt(A.rw), fmt(2 * A.tip_r)

    def ring_layer(paths, cap):
        halo = "".join(f'<path d="{d}" fill="none" stroke="#FFFFFF" stroke-width="{ring_hw}" stroke-linecap="{cap}"/>' for d in paths)
        body = "".join(f'<path d="{d}" fill="none" stroke="{ring_c}" stroke-width="{rw}" stroke-linecap="{cap}"/>' for d in paths)
        return f'<g filter="url(#xHalo)">{halo}</g>{body}'

    star_halo = f'<path d="{A.star_d}" fill="#FFFFFF" stroke="#FFFFFF" stroke-width="{halo_w}" stroke-linejoin="round"/>'
    sat_halo = f'<path d="{A.sat_d}" fill="#FFFFFF" stroke="#FFFFFF" stroke-width="{halo_w}" stroke-linejoin="round"/>'
    defs = [A.defs(), A.lin_grad("zBg", A.bg_span, ramp(*st["bg"], 9)),
            fx_filter(A, "xHalo", dz=1, sh_color=oklch_hex(st["shadow"]), sh_op=st["shadow_op"])]
    body = (f'<rect width="{fmt(S)}" height="{fmt(S)}" fill="url(#zBg)"/>'
            + ring_layer(back_d, "round")
            + f'<g filter="url(#xHalo)">{star_halo}</g>'
            f'<g mask="url(#mTri)"><path d="{A.star_d}" fill="{star_c}" stroke="{star_c}" stroke-width="{tw}" stroke-linejoin="round"/></g>'
            + ring_layer([front_d], "butt")
            + f'<g filter="url(#xHalo)">{sat_halo}</g>'
            f'<path d="{A.sat_d}" fill="{sat_c}" stroke="{sat_c}" stroke-width="{tw}" stroke-linejoin="round"/>')
    return A.doc(body, "".join(defs))


# ---------------------------------------------------------------------
# 风格表：颜色全部以 OKLCH 给出（L, C, h）
# ---------------------------------------------------------------------
# Google 品牌色：#4285F4 / #EA4335 / #FBBC05 / #34A853（由 hex 换算成 OKLCH）
GOOGLE = dict(blue=(0.6304, 0.1800, 259.96), red=(0.6257, 0.2058, 29.08), yellow=(0.8304, 0.1698, 83.99),
              green=(0.6475, 0.1603, 148.50))
NAVY = (0.30, 0.06, 264.0)
WHITE_PART = (0.95, 0.008, 255.0)      # 蓝图风的白色立体件（略带冷调）

STYLES = [
    ("chroma", "多彩", "CHROMA", "白底，四种品牌色各占一个元素：大星红、小星蓝、星轨前黄后绿", dict(
        kind="flat", bg=((1.0, 0, 0), (0.962, 0.004, 260)), star=GOOGLE["red"], star_tone=(0.025, -0.025),
        sat=GOOGLE["blue"], sat_tone=(0.02, -0.02), ring=GOOGLE["yellow"], ring_far=GOOGLE["green"],
        split=True, split_tone=(0.02, -0.02))),
    ("glow", "柔光", "GLOW", "白底，绿到蓝的通透渐变，身后两团柔光", dict(
        kind="flat", bg=((1.0, 0, 0), (0.965, 0.006, 230)), star=(0.75, 0.18, 198),
        star_ends=((0.87, 0.19, 138), (0.63, 0.18, 257)), sat=(0.86, 0.19, 140), ring=(0.68, 0.16, 245), far_mix=INV2,
        glow=[((0.86, 0.19, 140), -m(6), 0.72), ((0.66, 0.17, 250), m(6), 0.58)],
        fx=dict(star=dict(rims=((m(10), 0.6),)), ring=dict(rims=((m(10) * INV1, 0.5),))))),
    ("sticker", "糖纸", "STICKER", "粗圆头 + 白色贴纸描边，星轨叠底穿过主星", dict(
        kind="sticker", geo=dict(tip_r=("m", 8), ring_w=("m", 6), sat_k=1 / (1.6180339887498949 ** 3)),
        bg=((0.975, 0.004, 297), (0.945, 0.006, 297)), star=(0.675, 0.159, 19.0), ring=(0.504, 0.236, 267.8),
        sat=(0.787, 0.098, 17.9), outline=m(8), shadow=(0.40, 0.03, 290), shadow_op=0.18)),
    ("blueprint", "蓝图", "BLUEPRINT", "开发者风：蓝底网格，白色立体件", dict(
        kind="flat", geo=dict(tip_r=("m", 9)), bg=((0.76, 0.13, 236), (0.56, 0.22, 262)), bg_vertical=True,
        overlay=blueprint(),
        star=WHITE_PART, star_tone=(0.05, -0.07), ring=WHITE_PART, ring_tone=(0.05, -0.06),
        fx=dict(star=dict(dz=2, sh_color="#0B2F7A", sh_op=0.38, core=(m(9), "#6F86B5", 0.55)),
                ring=dict(dz=1, sh_color="#0B2F7A", sh_op=0.38, core=(m(10), "#6F86B5", 0.45))))),
    ("white", "白", "WHITE", "白底黑件，两色", dict(
        kind="flat", bg=((1.0, 0, 0), (0.955, 0.004, 265)), star=(0.24, 0.005, 265), star_tone=(0.10, -0.10),
        ring=(0.24, 0.005, 265))),
    ("black", "黑", "BLACK", "黑底白件，两色", dict(
        kind="flat", bg=((0.25, 0.004, 265), (0.10, 0.004, 265)), star=(0.93, 0.004, 265), star_tone=(0.07, -0.07),
        ring=(0.95, 0.004, 265))),
    ("gold", "黑金", "BLACK GOLD", "撞色：暖黑底，金色件", dict(
        kind="flat", bg=((0.22, 0.012, 70), (0.09, 0.006, 70)), star=(0.80, 0.14, 80),
        star_ends=((0.90, 0.11, 92), (0.68, 0.15, 62)), ring=(0.82, 0.13, 82))),
    ("klein", "克莱因橙", "KLEIN × ORANGE", "撞色：克莱因蓝底，橙色件", dict(
        kind="flat", bg=((0.48, 0.26, 266), (0.38, 0.23, 268)), star=(0.77, 0.17, 55),
        star_ends=((0.85, 0.14, 70), (0.69, 0.20, 42)), ring=(0.80, 0.16, 60))),
    ("lemon", "柠檬紫", "LEMON × VIOLET", "撞色：柠檬黄底，深紫件", dict(
        kind="flat", bg=((0.95, 0.17, 106), (0.89, 0.18, 98)), star=(0.47, 0.22, 292),
        star_ends=((0.56, 0.22, 296), (0.39, 0.22, 288)), ring=(0.48, 0.22, 292))),
    ("redyellow", "红黄", "RED × YELLOW", "撞色：正红底（#E60012 附近），正黄件（#FFD500 附近），轻微立体", dict(
        kind="flat", bg=((0.63, 0.235, 30), (0.52, 0.215, 27)), star=(0.88, 0.18, 94),
        star_ends=((0.94, 0.15, 99), (0.81, 0.18, 84)), ring=(0.88, 0.18, 93), ring_tone=(0.04, -0.06),
        fx=dict(star=dict(dz=2, sh_color="#5C0008", sh_op=0.34, rims=((m(10), 0.55),), core=(m(9), "#C9661A", 0.30)),
                ring=dict(dz=1, sh_color="#5C0008", sh_op=0.30, rims=((m(10) * INV1, 0.45),))))),
    ("pink", "粉青柠", "PINK × LIME", "撞色：桃粉底，青柠件", dict(
        kind="flat", bg=((0.71, 0.21, 356), (0.61, 0.24, 359)), star=(0.90, 0.21, 128),
        star_ends=((0.95, 0.19, 122), (0.85, 0.22, 136)), ring=(0.91, 0.21, 128))),
]


def build(key):
    for k, name, en, desc, st in STYLES:
        if k == key:
            A = Astra(**st.get("geo", {}))
            return svg_sticker(A, st) if st["kind"] == "sticker" else svg_flat_style(A, st)
    raise KeyError(key)


def palette_hex(st):
    """卡片上展示的颜色（每个图标 ≤ 4 种）。"""
    from astra_icon import oklch_hex
    cols = [("背景", st["bg"][0])]
    if st.get("split"):
        cols += [("主星", st["star"]), ("星轨近", st["ring"]), ("星轨远", st["ring_far"]), ("卫星", st["sat"])]
    else:
        cols += [("主星", st.get("star_ends", (st["star"],))[0] if st.get("star_ends") else st["star"])]
        if st["ring"] != st["star"]:
            cols.append(("星轨", st["ring"]))
        if st.get("sat") is not None and st["sat"] != st["star"]:
            cols.append(("卫星", st["sat"]))
    return [(n, oklch_hex(c)) for n, c in cols]
