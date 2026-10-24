#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Astra App 图标生成器 —— 规则驱动，没有手调数值
=================================================
所有几何、颜色、光照都由下面 4 条母规则推导。改动任何一条，整套图标会自动重算。

  R1 尺寸   黄金模数阶梯  m(k) = 1024 / φ^k （k = 1…10）
  R2 角度   θ0 = arctan(1/φ²) ≈ 20.905°
            = 光轴偏离竖直的角度 = 星轨倾角；光轴与星轨长轴互相垂直
  R3 曲线   只用三种解析曲线：星形线（astroid）、椭圆、圆
  R4 颜色   在 OKLCH 空间做两端点插值；所有渐变共用同一条光轴

运行：python3 export.py  → export/（SVG、PNG、构造图、spec.json）；python3 astra_icon.py 只打印关键数值
"""
import json
import math
import os

import numpy as np
from scipy.optimize import brentq

S = 1024.0
PHI = (1 + 5 ** 0.5) / 2


def m(k):
    """R1 黄金模数阶梯第 k 档：1024 / φ^k"""
    return S / PHI ** k


INV1, INV2, INV3 = 1 / PHI, 1 / PHI ** 2, 1 / PHI ** 3   # 不透明度 / 混合比例只用这三档：0.618 / 0.382 / 0.236


def fmt(v):
    s = f"{v:.2f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


# =====================================================================
# R4 颜色工具：OKLCH ↔ sRGB
# =====================================================================


def _lin2srgb(c):
    c = np.clip(c, 0.0, 1.0)
    return np.where(c <= 0.0031308, 12.92 * c, 1.055 * np.power(c, 1 / 2.4) - 0.055)


def _srgb2lin(c):
    c = np.asarray(c, dtype=float)
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def _oklab2lin(L, a, b):
    l_ = L + 0.3963377774 * a + 0.2158037573 * b
    m_ = L - 0.1055613458 * a - 0.0638541728 * b
    s_ = L - 0.0894841775 * a - 1.2914855480 * b
    l, mm, s = l_ ** 3, m_ ** 3, s_ ** 3
    return np.array([4.0767416621 * l - 3.3077115913 * mm + 0.2309699292 * s,
                     -1.2684380046 * l + 2.6097574011 * mm - 0.3413193965 * s,
                     -0.0041960863 * l - 0.7034186147 * mm + 1.7076147010 * s])


def _lin2oklab(rgb):
    r, g, b = rgb
    l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
    mm = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
    s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
    l_, m_, s_ = np.cbrt(l), np.cbrt(mm), np.cbrt(s)
    return (0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
            1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
            0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_)


def oklch_to_rgb(L, Cc, h):
    """OKLCH → sRGB(0–1)。超出 sRGB 色域时只降彩度，明度与色相不变。"""
    def lin(cc):
        return _oklab2lin(L, cc * math.cos(math.radians(h)), cc * math.sin(math.radians(h)))
    v = lin(Cc)
    if np.all(v >= -1e-7) and np.all(v <= 1 + 1e-7):
        return _lin2srgb(v)
    lo, hi = 0.0, Cc
    for _ in range(40):
        mid = (lo + hi) / 2
        vv = lin(mid)
        lo, hi = (mid, hi) if (np.all(vv >= -1e-7) and np.all(vv <= 1 + 1e-7)) else (lo, mid)
    return _lin2srgb(lin(lo))


def rgb_to_hex(rgb):
    r, g, b = (int(round(float(x) * 255)) for x in rgb)
    return f"#{r:02X}{g:02X}{b:02X}"


def oklch_hex(c):
    return rgb_to_hex(oklch_to_rgb(*c))


def hex_to_oklch(hx):
    L, a, b = _lin2oklab(_srgb2lin([int(hx[i:i + 2], 16) / 255 for i in (1, 3, 5)]))
    return (float(L), float(math.hypot(a, b)), float(math.degrees(math.atan2(b, a)) % 360))


def oklch_mix(c0, c1, t, dh=None):
    """OKLCH 线性插值；dh 为带符号的色相差（指定走向），默认走短弧。"""
    if dh is None:
        dh = ((c1[2] - c0[2] + 180) % 360) - 180
    return (c0[0] + (c1[0] - c0[0]) * t, c0[1] + (c1[1] - c0[1]) * t, (c0[2] + dh * t) % 360)


def ramp(c0, c1, n=17, dh=None):
    """OKLCH 插值采样成 n 个色标（SVG 在相邻色标间做 sRGB 插值，色标足够密时与 OKLCH 插值一致）。"""
    return [(i / (n - 1), oklch_hex(oklch_mix(c0, c1, i / (n - 1), dh))) for i in range(n)]


# =====================================================================
# 曲线工具：三次贝塞尔拟合（Schneider 最小二乘 + Newton 重参数化）
# =====================================================================


def _bern(u):
    v = 1 - u
    return v ** 3, 3 * u * v ** 2, 3 * u ** 2 * v, u ** 3


def bez(P, u):
    B = _bern(u)
    return sum(B[i][:, None] * P[i] for i in range(4))


def fit_cubic(f, df, t0, t1):
    ts = np.linspace(t0, t1, 96)
    pts = f(ts)
    P0, P3 = pts[0], pts[-1]
    T0 = df(np.array([t0]))[0]
    T0 = T0 / np.linalg.norm(T0)
    T1 = df(np.array([t1]))[0]
    T1 = T1 / np.linalg.norm(T1)
    d = np.r_[0, np.cumsum(np.linalg.norm(np.diff(pts, axis=0), axis=1))]
    u = d / d[-1]
    P = None
    for _ in range(40):
        B0, B1, B2, B3 = _bern(u)
        A1, A2 = B1[:, None] * T0, -B2[:, None] * T1
        rr = pts - (B0 + B1)[:, None] * P0 - (B2 + B3)[:, None] * P3
        M = np.array([[np.sum(A1 * A1), np.sum(A1 * A2)], [np.sum(A1 * A2), np.sum(A2 * A2)]])
        al, be = np.linalg.solve(M, [np.sum(A1 * rr), np.sum(A2 * rr)])
        P = [P0, P0 + al * T0, P3 - be * T1, P3]
        Q = bez(P, u)
        d1 = [3 * (P[i + 1] - P[i]) for i in range(3)]
        v = 1 - u
        Q1 = (v ** 2)[:, None] * d1[0] + (2 * u * v)[:, None] * d1[1] + (u ** 2)[:, None] * d1[2]
        d2 = [2 * (d1[i + 1] - d1[i]) for i in range(2)]
        Q2 = v[:, None] * d2[0] + u[:, None] * d2[1]
        diff = Q - pts
        u = np.clip(u - np.sum(diff * Q1, 1) / (np.sum(Q1 * Q1, 1) + np.sum(diff * Q2, 1)), 0, 1)
        u[0], u[-1] = 0.0, 1.0
    dense = bez(P, np.linspace(0, 1, 3000))
    err = max(np.min(np.linalg.norm(dense - p, axis=1)) for p in pts)
    return P, err


def fit_adaptive(f, df, t0, t1, tol):
    P, err = fit_cubic(f, df, t0, t1)
    if err <= tol:
        return [(P, err)]
    tm = (t0 + t1) / 2
    return fit_adaptive(f, df, t0, tm, tol) + fit_adaptive(f, df, tm, t1, tol)


# =====================================================================
# 图标本体
# =====================================================================
DEFAULTS = dict(
    star_h=("m", 1),          # 星的构造框高 = m1 = 1024/φ
    star_w=("m", 2),          # 星的构造框宽 = m2 → 高:宽 = φ
    tip_r=("m", 10),          # 圆头笔半径 = m10：星 = 骨架星 ⊕ 半径 m10 的圆（尖端圆头，长度不损失）
    curve_e=4,                # 骨架曲线 (a·cos^e t, b·sin^e t)：e=4 抛物线（二次贝塞尔，控制点=星心）；e=3 星形线
    ring_rx=("m", 2), ring_ry=("m", 4), ring_w=("m", 7),
    gap=("m", 9), lift=("m", 9), depth_u=("m", 9),
    sat_k=PHI ** -4,          # 卫星星骨架 = 主星骨架 × φ⁻⁴，再用同一支 m10 圆头笔描出
    far_mix=INV1,             # 星轨远端向背景混合的比例（空气透视）
    # ---- 配色种子：每套配色只换这几项，其余颜色全部由 R4 推导 ----
    h_sky=280.0,              # 夜空色相
    h_light=90.0,             # 星光色相（星的受光端）
    h_ring=210.0,             # 星轨色相（近端）
    sky_l=0.52, sky_c=0.20,   # 夜空受光端的明度、彩度（一般不动）
)

# 预设配色：(夜空色相, 星光色相, 星轨色相) + 可选的夜空明度/彩度
PALETTES = {
    "indigo":   dict(h_sky=280.0, h_light=90.0, h_ring=210.0),                     # 靛夜（原版）
    "abyss":    dict(h_sky=235.0, h_light=75.0, h_ring=170.0),                     # 深海
    "amethyst": dict(h_sky=320.0, h_light=85.0, h_ring=230.0),                     # 紫晶
    "aurora":   dict(h_sky=200.0, h_light=345.0, h_ring=140.0),                    # 极光
    "glacier":  dict(h_sky=255.0, h_light=200.0, h_ring=165.0),                    # 冰川
    "jade":     dict(h_sky=160.0, h_light=340.0, h_ring=200.0),                    # 翡翠
    "crimson":  dict(h_sky=10.0, h_light=200.0, h_ring=75.0),                      # 绯夜
    "neon":     dict(h_sky=265.0, h_light=330.0, h_ring=185.0,                     # 霓虹：夜空套用深色规则
                     sky_l=0.52 * INV1, sky_c=0.20 * INV1),
    "obsidian": dict(h_sky=280.0, h_light=90.0, h_ring=210.0,                      # 曜石：中性夜空 + 深色规则
                     sky_l=0.52 * INV1, sky_c=0.20 * INV1 ** 4),
}

YELLOW_GREEN = (100.0, 160.0)   # 黄绿带：中低明度下发脏（橄榄色），星的渐变不经过这里


def hue_delta(h0, h1, frac=1.0, band=YELLOW_GREEN):
    """从 h0 转向 h1 的带符号色相差。两个方向里，取实际走过的那一段（frac 倍）不经过黄绿带的方向；
    两个方向都不经过时取较短的。"""
    d = (h1 - h0) % 360
    cands = [d, d - 360]

    def crosses(dh):
        hs = (h0 + np.linspace(0, dh * frac, 721)) % 360
        return bool(np.any((hs > band[0]) & (hs < band[1])))
    ok = [c for c in cands if not crosses(c)]
    return min(ok or cands, key=abs)


def shade_path(h_light, h_sky):
    """暗部色相 = 星光色相朝夜空色相转一半（返回带符号的转角，即星渐变的色相走向）。"""
    return hue_delta(h_light, h_sky, 0.5) / 2


def _val(spec):
    kind, k = spec
    if kind == "m":
        return m(k)
    if kind == "abs":
        return k
    raise ValueError(spec)


class Astra:
    def __init__(self, **over):
        p = dict(DEFAULTS, **over)
        self.p = p
        # ---------- R2 光轴 ----------
        self.theta0 = math.atan(1 / PHI ** 2)
        self.LIGHT = np.array([math.sin(self.theta0), math.cos(self.theta0)])     # 光的行进方向：左上 → 右下
        self.MAJOR = np.array([math.cos(self.theta0), -math.sin(self.theta0)])    # 星轨长轴：右端上扬
        assert abs(float(self.LIGHT @ self.MAJOR)) < 1e-12
        # ---------- R1 尺寸 ----------
        self.H, self.W = _val(p["star_h"]), _val(p["star_w"])
        self.tip_r = _val(p["tip_r"])
        self.rx, self.ry, self.rw = _val(p["ring_rx"]), _val(p["ring_ry"]), _val(p["ring_w"])
        self.gap = _val(p["gap"])
        self.lift, self.u = _val(p["lift"]), _val(p["depth_u"])
        self.sat_k = p["sat_k"]
        self.e = p["curve_e"]
        self.C = np.array([S / 2, S / 2 - self.lift])
        # ---------- R3 曲线 ----------
        self._solve_star()
        self.r_in = self.r_in_skel + self.tip_r                  # 可见星的腰部内切圆 = 骨架内切圆 + r
        self.tri_R = self.r_in / PHI                            # 播放三角外接圆 = 内切圆 / φ
        self.tri_corner = self.tri_R * INV3                     # 三角圆角 = 外接圆 × 1/φ³（随三角等比）
        self.quad = self._side_segments()
        self.star_d, self.star_info = self.star_outline(self.C, 1.0)
        self.tri_d, self.tri_info = self.rounded_triangle(self.C, self.tri_R, self.tri_corner)
        self.th_zenith = -math.pi / 4                            # tanθ0 = ry/rx ⇒ 椭圆最高点恰在 θ = −45°
        self.zenith = self.ring_pt(self.th_zenith)
        self._check_zenith()
        self.sat_d, self.sat_info = self.star_outline(self.zenith, self.sat_k)
        self.th_a = self._gap_end(+1)
        self.th_b = self._gap_end(-1) + 2 * math.pi
        cxf = lambda th: self.ring_pt(th)[0] - self.C[0]
        self.th_back = brentq(cxf, math.pi * 1.25, math.pi * 1.75)     # 星轨在上臂后方经过
        self.th_front = brentq(cxf, math.pi * 0.25, math.pi * 0.75)    # 星轨压过下臂
        self.ring_front_d = self.ring_arc_d(self.th_a, self.th_back)
        self.ring_back_d = self.ring_arc_d(self.th_back, self.th_b)
        self.knock_d = self.ring_arc_d(self.th_front - math.radians(52), self.th_front + math.radians(52))
        self._colors(p)
        self._spans()

    # ---------------- 星形线 ----------------
    def _ast(self, t):
        e = self.e
        return np.stack([self.a * np.cos(t) ** e, self.b * np.sin(t) ** e], -1)

    def _ast_d(self, t):
        e = self.e
        return np.stack([-e * self.a * np.cos(t) ** (e - 1) * np.sin(t), e * self.b * np.sin(t) ** (e - 1) * np.cos(t)], -1)

    def _side_segments(self):
        """第一象限一条边（右尖 → 上尖）的三次贝塞尔。e=4 时是精确的二次贝塞尔（控制点 = 星心）。"""
        a, b = self.a, self.b
        if self.e == 4:
            P = [np.array([a, 0.0]), np.array([a / 3, 0.0]), np.array([0.0, b / 3]), np.array([0.0, b])]
            return [(P, 0.0)]
        return fit_adaptive(self._ast, self._ast_d, 1e-6, math.pi / 2 - 1e-6, tol=0.05)

    def _solve_star(self):
        r, e = self.tip_r, self.e
        self.a, self.b = self.W / 2 - r, self.H / 2 - r           # 骨架外接框 = 构造框四边各内缩 r
        self.vis_w, self.vis_h = self.W, self.H                     # 外扩 r 之后正好回到构造框
        ts = np.linspace(1e-4, math.pi / 2 - 1e-4, 20001)
        self.r_in_skel = float(np.min(np.hypot(self.a * np.cos(ts) ** e, self.b * np.sin(ts) ** e)))

    def star_outline(self, center, k=1.0):
        """骨架星的闭合路径（尖端为尖点）。可见星 = 骨架 ⊕ 半径 k·r 的圆 —— SVG 里用“同色描边 2r + 圆角连接”实现。"""
        cx, cy = center
        to = lambda p: (cx + k * p[0], cy - k * p[1])          # 数学坐标(y 上) → 屏幕坐标(y 下)
        q1 = [[np.array(pt) for pt in P] for P, _ in self.quad]   # 右尖 → 上尖

        def mir(segs, sx, sy, rev):
            out = [[np.array([pt[0] * sx, pt[1] * sy]) for pt in P] for P in segs]
            return [list(reversed(P)) for P in reversed(out)] if rev else out

        quads = [q1, mir(q1, -1, 1, True), mir(q1, -1, -1, False), mir(q1, 1, -1, True)]
        st = to(q1[0][0])
        d = [f"M{fmt(st[0])} {fmt(st[1])}"]
        anchors, handles = [], []
        for quad in quads:
            for P in quad:
                p0, p1, p2, p3 = to(P[0]), to(P[1]), to(P[2]), to(P[3])
                d.append(f"C{fmt(p1[0])} {fmt(p1[1])} {fmt(p2[0])} {fmt(p2[1])} {fmt(p3[0])} {fmt(p3[1])}")
                anchors.append(p0)
                handles += [(p0, p1), (p3, p2)]
        d.append("Z")
        return " ".join(d), dict(anchors=anchors, handles=handles, tip_r=k * self.tip_r)

    def rounded_triangle(self, center, R_apex, corner):
        """等边、指向右、形心对准星心；圆角后的三个顶点恰好落在半径 R_apex 的圆上。"""
        R0 = R_apex + corner        # 60° 角做半径 r 的圆角，顶点内缩 r → 基础三角外接圆 = R_apex + r
        cx, cy = center
        V = [np.array([cx + R0 * math.cos(math.radians(t)), cy + R0 * math.sin(math.radians(t))]) for t in (0, 120, 240)]
        O = np.array([cx, cy])
        pts = []
        for i in range(3):
            v, vp, vn = V[i], V[i - 1], V[(i + 1) % 3]
            oc = v + (O - v) * (2 * corner / R0)      # 圆角圆心：沿角平分线距顶点 2r
            foot = lambda p, q: p + np.dot(oc - p, q - p) / np.dot(q - p, q - p) * (q - p)
            pts.append((foot(vp, v), foot(v, vn)))
        d = [f"M{fmt(pts[0][1][0])} {fmt(pts[0][1][1])}"]
        for i in (1, 2, 0):
            a_in, a_out = pts[i]
            d.append(f"L{fmt(a_in[0])} {fmt(a_in[1])}")
            d.append(f"A{fmt(corner)} {fmt(corner)} 0 0 1 {fmt(a_out[0])} {fmt(a_out[1])}")
        d.append("Z")
        return " ".join(d), dict(R0=R0, vertices=V)

    # ---------------- 星轨椭圆 ----------------
    def ring_pt(self, th):
        """E(θ) = C + rx·cosθ·MAJOR + ry·sinθ·LIGHT；θ 增大 = 视觉顺时针；sinθ>0 为近端"""
        return self.C + self.rx * math.cos(th) * self.MAJOR + self.ry * math.sin(th) * self.LIGHT

    def ring_arc_d(self, th0, th1):
        n = max(1, int(math.ceil((th1 - th0) / (math.pi / 2))))
        rot = -math.degrees(self.theta0)
        p = self.ring_pt(th0)
        d = [f"M{fmt(p[0])} {fmt(p[1])}"]
        for i in range(1, n + 1):
            q = self.ring_pt(th0 + (th1 - th0) * i / n)
            d.append(f"A{fmt(self.rx)} {fmt(self.ry)} {fmt(rot)} 0 1 {fmt(q[0])} {fmt(q[1])}")
        return " ".join(d)

    def _check_zenith(self):
        ths = np.linspace(-math.pi, math.pi, 72001)
        ys = np.array([self.ring_pt(t)[1] for t in ths])
        assert abs(ths[np.argmin(ys)] - self.th_zenith) < 1e-3, "天顶推导不成立"

    def sat_poly(self):
        pts = []
        k, Z = self.sat_k, self.zenith
        for P, _ in self.quad:
            Pk = [np.array(pt) * k for pt in P]
            for q in bez(Pk, np.linspace(0, 1, 400)):
                for sx, sy in ((1, 1), (-1, 1), (-1, -1), (1, -1)):
                    pts.append(Z + np.array([sx * q[0], -sy * q[1]]))
        return np.array(pts)

    def _gap_end(self, direction):
        """沿星轨从天顶向一侧走，直到圆头端点与卫星星外轮廓的净距 = gap。"""
        poly, need = self.sat_poly(), self.rw / 2 + self.gap + self.tip_r
        f = lambda th: np.min(np.linalg.norm(poly - self.ring_pt(th), axis=1)) - need
        far = self.th_zenith + direction * math.radians(60)
        return brentq(f, min(self.th_zenith, far), max(self.th_zenith, far))

    # ---------------- 颜色 ----------------
    def _colors(self, p):
        """R4：所有颜色由 3 个色相种子 + 固定规则推导。"""
        hs, hl, hr, sl, sc = p["h_sky"], p["h_light"], p["h_ring"], p["sky_l"], p["sky_c"]
        self.H_AMB, self.H_LIGHT, self.H_RING = hs, hl, hr
        self.STAR_DH = shade_path(hl, hs)                          # 星渐变的色相走向（带符号）
        self.H_SHADE = (hl + self.STAR_DH) % 360                    # 暗部色相：星光朝夜空转一半
        self.BG_TOP = (sl, sc, hs)                                  # 夜空受光端
        self.BG_BOTTOM = (sl * INV2, sc * INV2, hs)                 # 背光端：L、C 同乘 1/φ²
        self.STAR_LIT = (0.96, 0.06, hl)                            # 星受光端：高明度、低彩度
        self.STAR_SHADE = (0.66, 0.20, self.H_SHADE)                # 星背光端：明度 −0.30，彩度升高
        star_mid = oklch_mix(self.STAR_LIT, self.STAR_SHADE, 0.5, self.STAR_DH)
        self.RING_NEAR = (star_mid[0], 0.10, hr)                    # 星轨近端：明度 = 星渐变中点（星永远比星轨亮）
        ring_dh = hue_delta(hr, hs, p["far_mix"])
        self.RING_FAR = oklch_mix(self.RING_NEAR, self.BG_TOP, p["far_mix"], ring_dh)   # 远端：向夜空混合 1/φ（空气透视）
        self.BLOOM = (sl + INV3, sc * INV1, hs)                     # 辉光：夜空色提亮 1/φ³
        self.SHADOW = (0.14, sc * 0.3, hs)                          # 投影：夜空色的最暗端
        self.CORE = (0.66 - 0.20, 0.20, self.H_SHADE)               # 星的核心暗部
        self.DARK_TOP = (sl * INV1, sc * INV1, hs)                  # 深色外观：夜空 L、C × 1/φ
        self.DARK_BOTTOM = (sl * INV2 * INV1, sc * INV2 * INV1, hs)

    def _spans(self):
        L, C = self.LIGHT, self.C
        tb = (S / 2) * (abs(L[0]) + abs(L[1]))                      # 背景：整块画布在光轴上的投影
        ctr = np.array([S / 2, S / 2])
        self.bg_span = (ctr - tb * L, ctr + tb * L)
        ts = max(self.vis_h / 2 * L[1], self.vis_w / 2 * L[0])     # 星：可见尖端在光轴上的投影
        self.star_span = (C - ts * L, C + ts * L)
        self.ring_span = (C - self.ry * L, C + self.ry * L)         # 星轨：短轴 ∥ 光轴 → 范围 ±ry（远 → 近）

    # ---------------- SVG ----------------
    @staticmethod
    def lin_grad(gid, span, stops):
        (x1, y1), (x2, y2) = span
        s = "".join(f'<stop offset="{fmt(o)}" stop-color="{c}"/>' for o, c in stops)
        return (f'<linearGradient id="{gid}" gradientUnits="userSpaceOnUse" x1="{fmt(x1)}" y1="{fmt(y1)}" '
                f'x2="{fmt(x2)}" y2="{fmt(y2)}">{s}</linearGradient>')

    def bloom_grad(self, gid, peak):
        hx = oklch_hex(self.BLOOM)
        stops = "".join(f'<stop offset="{fmt(i / 12)}" stop-color="{hx}" stop-opacity="{peak * (1 - (i / 12) ** 2) ** 2:.4f}"/>'
                        for i in range(13))
        return (f'<radialGradient id="{gid}" gradientUnits="userSpaceOnUse" cx="{fmt(self.C[0])}" '
                f'cy="{fmt(self.C[1])}" r="{fmt(m(1))}">{stops}</radialGradient>')

    def lit_filter(self, fid, dz, rim_d, rim_a, core_d=None, core_a=None):
        """投影 + 受光边 + 背光内暗部。所有偏移都沿光轴 LIGHT。"""
        sx, sy = dz * self.u * self.LIGHT
        rx, ry = rim_d * self.LIGHT
        f = [f'<filter id="{fid}" filterUnits="userSpaceOnUse" x="-512" y="-512" width="2560" height="2560" '
             f'color-interpolation-filters="sRGB">',
             f'<feGaussianBlur in="SourceAlpha" stdDeviation="{fmt(dz * self.u)}" result="sb"/>',
             f'<feOffset in="sb" dx="{fmt(sx)}" dy="{fmt(sy)}" result="so"/>',
             f'<feFlood flood-color="{oklch_hex(self.SHADOW)}" flood-opacity="{INV2:.4f}"/>',
             '<feComposite in2="so" operator="in" result="shadow"/>',
             f'<feOffset in="SourceAlpha" dx="{fmt(rx)}" dy="{fmt(ry)}" result="ro"/>',
             '<feComposite in="SourceAlpha" in2="ro" operator="out" result="rb"/>',
             f'<feGaussianBlur in="rb" stdDeviation="{fmt(rim_d * INV1)}" result="rbb"/>',
             '<feComposite in="rbb" in2="SourceAlpha" operator="in" result="rbc"/>',
             f'<feFlood flood-color="#FFFFFF" flood-opacity="{rim_a:.4f}"/>',
             '<feComposite in2="rbc" operator="in" result="rim"/>']
        merge = ['<feMergeNode in="shadow"/>', '<feMergeNode in="SourceGraphic"/>']
        if core_d:
            cx_, cy_ = -core_d * self.LIGHT
            f += [f'<feOffset in="SourceAlpha" dx="{fmt(cx_)}" dy="{fmt(cy_)}" result="co"/>',
                  '<feComposite in="SourceAlpha" in2="co" operator="out" result="cb"/>',
                  f'<feGaussianBlur in="cb" stdDeviation="{fmt(core_d * INV1)}" result="cbb"/>',
                  '<feComposite in="cbb" in2="SourceAlpha" operator="in" result="cbc"/>',
                  f'<feFlood flood-color="{oklch_hex(self.CORE)}" flood-opacity="{core_a:.4f}"/>',
                  '<feComposite in2="cbc" operator="in" result="core"/>']
            merge.append('<feMergeNode in="core"/>')
        merge.append('<feMergeNode in="rim"/>')
        f.append(f'<feMerge>{"".join(merge)}</feMerge></filter>')
        return "".join(f)

    def defs(self, dark=False):
        top, bot = (self.DARK_TOP, self.DARK_BOTTOM) if dark else (self.BG_TOP, self.BG_BOTTOM)
        Sx = fmt(S)
        return "".join([
            self.lin_grad("gBg", self.bg_span, ramp(top, bot)),
            self.bloom_grad("gBloom", INV3 * (INV1 if dark else 1)),
            self.lin_grad("gStar", self.star_span, ramp(self.STAR_LIT, self.STAR_SHADE, dh=self.STAR_DH)),
            self.lin_grad("gRing", self.ring_span, ramp(self.RING_FAR, self.RING_NEAR)),
            f'<clipPath id="upper"><rect x="0" y="0" width="{Sx}" height="{fmt(self.C[1])}"/></clipPath>',
            # 星轨在星后经过：挖掉“星外扩 gap”的区域（只在上半区，下半区星轨在星前）
            f'<mask id="mRing" maskUnits="userSpaceOnUse" x="0" y="0" width="{Sx}" height="{Sx}">'
            f'<rect width="{Sx}" height="{Sx}" fill="#FFFFFF"/><g clip-path="url(#upper)">'
            f'<path d="{self.star_d}" fill="#000000" stroke="#000000" stroke-width="{fmt(2 * (self.tip_r + self.gap))}" '
            f'stroke-linejoin="round"/></g></mask>',
            # 星轨压在星前：在星上挖出“星轨线宽 + 2×gap”的退让带
            f'<mask id="mStar" maskUnits="userSpaceOnUse" x="0" y="0" width="{Sx}" height="{Sx}">'
            f'<rect width="{Sx}" height="{Sx}" fill="#FFFFFF"/><path d="{self.knock_d}" fill="none" '
            f'stroke="#000000" stroke-width="{fmt(self.rw + 2 * self.gap)}"/>'
            f'<path d="{self.tri_d}" fill="#000000"/></mask>',
            # 只挖播放三角（构造图用）
            f'<mask id="mTri" maskUnits="userSpaceOnUse" x="0" y="0" width="{Sx}" height="{Sx}">'
            f'<rect width="{Sx}" height="{Sx}" fill="#FFFFFF"/><path d="{self.tri_d}" fill="#000000"/></mask>',
        ])

    def l_bg(self, bloom=True):
        Sx = fmt(S)
        return (f'<rect width="{Sx}" height="{Sx}" fill="url(#gBg)"/>' +
                (f'<rect width="{Sx}" height="{Sx}" fill="url(#gBloom)"/>' if bloom else ""))

    def l_back(self, fill="url(#gRing)", op=1.0):
        return (f'<g mask="url(#mRing)" opacity="{op:.4f}"><path d="{self.ring_back_d}" fill="none" '
                f'stroke="{fill}" stroke-width="{fmt(self.rw)}" stroke-linecap="round"/></g>')

    def l_star(self, fill="url(#gStar)", mask="mStar"):
        return (f'<g mask="url(#{mask})"><path d="{self.star_d}" fill="{fill}" stroke="{fill}" '
                f'stroke-width="{fmt(2 * self.tip_r)}" stroke-linejoin="round"/></g>')

    def l_front(self, fill="url(#gRing)", op=1.0):
        return (f'<g mask="url(#mRing)" opacity="{op:.4f}"><path d="{self.ring_front_d}" fill="none" '
                f'stroke="{fill}" stroke-width="{fmt(self.rw)}" stroke-linecap="round"/></g>')

    def l_sat(self, fill="url(#gStar)"):
        return (f'<path d="{self.sat_d}" fill="{fill}" stroke="{fill}" '
                f'stroke-width="{fmt(2 * self.tip_r)}" stroke-linejoin="round"/>')

    @staticmethod
    def doc(body, defs="", vb=(0, 0, S, S)):
        x, y, w, h = vb
        return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{fmt(x)} {fmt(y)} {fmt(w)} {fmt(h)}" '
                f'width="{fmt(w)}" height="{fmt(h)}"><defs>{defs}</defs>{body}</svg>')

    def lit_defs(self, dark=False):
        return self.defs(dark) + "".join([
            self.lit_filter("fStar", 2, m(10), INV1, core_d=m(9), core_a=INV2),
            self.lit_filter("fRing", 1, m(10) * INV1, INV2),
            self.lit_filter("fSat", 1, m(10) * INV1, INV1),
        ])

    def lit_fg(self):
        return (f'<g filter="url(#fRing)">{self.l_back()}</g>'
                f'<g filter="url(#fStar)">{self.l_star()}</g>'
                f'<g filter="url(#fRing)">{self.l_front()}</g>'
                f'<g filter="url(#fSat)">{self.l_sat()}</g>')

    def svg_lit(self, dark=False):
        return self.doc(self.l_bg() + self.lit_fg(), self.lit_defs(dark))

    def svg_flat(self, dark=False, parts=("bg", "back", "star", "front", "sat")):
        fn = dict(bg=self.l_bg, back=self.l_back, star=self.l_star, front=self.l_front, sat=self.l_sat)
        return self.doc("".join(fn[q]() for q in parts), self.defs(dark))

    def svg_mono(self, bg=None, fg="#FFFFFF", ring_op=INV1, parts=("back", "star", "front", "sat")):
        fn = dict(back=lambda: self.l_back(fg, ring_op), star=lambda: self.l_star(fg),
                  front=lambda: self.l_front(fg, ring_op), sat=lambda: self.l_sat(fg))
        body = (f'<rect width="{fmt(S)}" height="{fmt(S)}" fill="{bg}"/>' if bg else "")
        return self.doc(body + "".join(fn[q]() for q in parts), self.defs())

    # Android：108dp = 1536px，中央 72dp 可视区 = 1024px，iOS 画面原样放入
    def svg_android_bg(self):
        return self.doc('<rect x="-256" y="-256" width="1536" height="1536" fill="url(#gBg)"/>'
                        '<rect x="-256" y="-256" width="1536" height="1536" fill="url(#gBloom)"/>',
                        self.defs(), vb=(-256, -256, 1536, 1536))

    def svg_android_fg(self):
        return self.doc(self.lit_fg(), self.lit_defs(), vb=(-256, -256, 1536, 1536))

    def svg_android_mono(self):
        fg = "#FFFFFF"
        body = self.l_back(fg) + self.l_star(fg) + self.l_front(fg) + self.l_sat(fg)
        return self.doc(body, self.defs(), vb=(-256, -256, 1536, 1536))


# =====================================================================
# 预览遮罩：超椭圆 n = 5（与星形线同一个公式族 |x/a|ⁿ+|y/b|ⁿ=1；系统实际遮罩以平台为准）
# =====================================================================


def superellipse_d(cx, cy, a, n=5.0, N=720):
    pts = []
    for i in range(N):
        t = 2 * math.pi * i / N
        c, s = math.cos(t), math.sin(t)
        pts.append(f"{fmt(cx + a * math.copysign(abs(c) ** (2 / n), c))} {fmt(cy + a * math.copysign(abs(s) ** (2 / n), s))}")
    return "M" + " L".join(pts) + " Z"


def masked(svg_text, shape="squircle", size=S, offset=0):
    inner = svg_text.split(">", 1)[1].rsplit("</svg>", 1)[0]
    if shape == "squircle":
        clip = f'<path d="{superellipse_d(offset + size / 2, offset + size / 2, size / 2)}"/>'
    else:
        clip = f'<circle cx="{fmt(offset + size / 2)}" cy="{fmt(offset + size / 2)}" r="{fmt(size / 2)}"/>'
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{fmt(offset)} {fmt(offset)} {fmt(size)} {fmt(size)}" '
            f'width="{fmt(size)}" height="{fmt(size)}"><defs><clipPath id="iconMask">{clip}</clipPath></defs>'
            f'<g clip-path="url(#iconMask)">{inner}</g></svg>')


if __name__ == "__main__":
    A = Astra()
    print("skeleton a,b", round(A.a, 2), round(A.b, 2), "visible", round(A.vis_w, 1), round(A.vis_h, 1),
          "r_in", round(A.r_in, 1), "tri_R", round(A.tri_R, 1), "tri_corner", round(A.tri_corner, 1))
