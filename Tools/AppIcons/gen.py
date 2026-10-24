"""Astra 应用图标：用 SVG 手绘，再用 Chromium 渲染成 1024 PNG。

    python3 gen.py [名字...]          # 生成 <名字>.svg（默认全部）
    NODE_PATH=<含 playwright 的 node_modules> node render.cjs . astra buddy ...   # 渲染 PNG 和预览图

渲染结果放进 Resources/Assets.xcassets：astra 是默认图标 AppIcon，其余是 AppIcon-<名字>，
设置页预览用 IconPreview-<名字>（240px）。"""
import math, os, sys

OUT = os.path.dirname(os.path.abspath(__file__))
S = 1024


def fmt(v):
    return f"{v:.1f}".rstrip("0").rstrip(".")


def rounded_poly(points, r):
    """多边形每个角按半径 r 倒圆（凸角凹角都适用）"""
    n = len(points)
    segs = []
    for i in range(n):
        px, py = points[i]
        ax, ay = points[i - 1]
        bx, by = points[(i + 1) % n]
        la = math.hypot(ax - px, ay - py)
        lb = math.hypot(bx - px, by - py)
        ta = min(r / la, 0.5)
        tb = min(r / lb, 0.5)
        p1 = (px + (ax - px) * ta, py + (ay - py) * ta)
        p2 = (px + (bx - px) * tb, py + (by - py) * tb)
        segs.append((p1, (px, py), p2))
    d = f"M{fmt(segs[0][2][0])},{fmt(segs[0][2][1])} "
    for i in range(1, n + 1):
        p1, p, p2 = segs[i % n]
        d += f"L{fmt(p1[0])},{fmt(p1[1])} Q{fmt(p[0])},{fmt(p[1])} {fmt(p2[0])},{fmt(p2[1])} "
    return d + "Z"


def star5(cx, cy, R, ratio=0.55, rot=0, r=40):
    pts = []
    for i in range(10):
        a = math.radians(rot - 90 + i * 36)
        rr = R if i % 2 == 0 else R * ratio
        pts.append((cx + rr * math.cos(a), cy + rr * math.sin(a)))
    return rounded_poly(pts, r)


def sparkle(cx, cy, R, pinch=0.16, rot=0, tip=0.0):
    """四角星芒：四条内凹的二次曲线；tip>0 时尖角略圆"""
    k = R * pinch
    pts = [(0, -R), (R, 0), (0, R), (-R, 0)]
    ctrl = [(k, -k), (k, k), (-k, k), (-k, -k)]
    a = math.radians(rot)

    def tr(x, y):
        return (cx + x * math.cos(a) - y * math.sin(a), cy + x * math.sin(a) + y * math.cos(a))

    if tip <= 0:
        d = "M{},{} ".format(*map(fmt, tr(*pts[0])))
        for i in range(4):
            c = tr(*ctrl[i])
            p = tr(*pts[(i + 1) % 4])
            d += f"Q{fmt(c[0])},{fmt(c[1])} {fmt(p[0])},{fmt(p[1])} "
        return d + "Z"
    # 圆角尖：每个尖端前后各退一点，用二次曲线连过尖点
    d = ""
    for i in range(4):
        p = pts[i]
        prev_c = ctrl[i - 1]
        next_c = ctrl[i]
        t = tip
        before = (p[0] + (prev_c[0] - p[0]) * t, p[1] + (prev_c[1] - p[1]) * t)
        after = (p[0] + (next_c[0] - p[0]) * t, p[1] + (next_c[1] - p[1]) * t)
        b = tr(*before); pp = tr(*p); af = tr(*after)
        if i == 0:
            d += f"M{fmt(b[0])},{fmt(b[1])} "
        else:
            d += f"Q{fmt(prevctrl[0])},{fmt(prevctrl[1])} {fmt(b[0])},{fmt(b[1])} "
        d += f"Q{fmt(pp[0])},{fmt(pp[1])} {fmt(af[0])},{fmt(af[1])} "
        prevctrl = tr(*next_c)
    b0 = tr(pts[0][0] + (ctrl[3][0] - pts[0][0]) * tip, pts[0][1] + (ctrl[3][1] - pts[0][1]) * tip)
    d += f"Q{fmt(prevctrl[0])},{fmt(prevctrl[1])} {fmt(b0[0])},{fmt(b0[1])} Z"
    return d


def shadow_filter(fid, dx=0, dy=24, blur=28, color="#000", opacity=0.3):
    return f"""<filter id="{fid}" x="-40%" y="-40%" width="180%" height="180%">
  <feGaussianBlur in="SourceAlpha" stdDeviation="{blur}"/>
  <feOffset dx="{dx}" dy="{dy}" result="o"/>
  <feFlood flood-color="{color}" flood-opacity="{opacity}"/>
  <feComposite in2="o" operator="in"/>
  <feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge>
</filter>"""


def blur_filter(fid, std):
    return f'<filter id="{fid}" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="{std}"/></filter>'


def svg(defs, body):
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}"><defs>{defs}</defs>{body}</svg>'


ICONS = {}


def icon(name):
    def deco(fn):
        ICONS[name] = fn
        return fn
    return deco


# ---------------------------------------------------------------- 1 星芒（默认）
@icon("astra")
def astra():
    cx, cy, R = 430, 455, 292
    star = sparkle(cx, cy, R, pinch=0.17, tip=0.06)
    k = R * 0.17
    tips = [(cx, cy - R), (cx + R, cy), (cx, cy + R), (cx - R, cy)]
    ctrls = [(cx + k, cy - k), (cx + k, cy + k), (cx - k, cy + k), (cx - k, cy - k)]
    facet = lambda i: f"M{cx},{cy} L{fmt(tips[i][0])},{fmt(tips[i][1])} Q{fmt(ctrls[i][0])},{fmt(ctrls[i][1])} {fmt(tips[(i+1)%4][0])},{fmt(tips[(i+1)%4][1])} Z"
    mini1 = sparkle(786, 236, 50, pinch=0.2, tip=0.08)
    mini2 = sparkle(196, 830, 34, pinch=0.2, tip=0.08)
    mini3 = sparkle(860, 476, 22, pinch=0.2, tip=0.08)
    defs = f"""
<linearGradient id="bg" x1="0.15" y1="0" x2="0.85" y2="1">
  <stop offset="0" stop-color="#5B47F5"/><stop offset="0.55" stop-color="#8A6EFF"/><stop offset="1" stop-color="#B89CFF"/>
</linearGradient>
<radialGradient id="glow" cx="0.95" cy="0.98" r="0.6">
  <stop offset="0" stop-color="#FFC6E6" stop-opacity="1"/><stop offset="1" stop-color="#FFC6E6" stop-opacity="0"/>
</radialGradient>
<linearGradient id="band" x1="0" y1="0" x2="0.6" y2="1">
  <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.55"/><stop offset="0.7" stop-color="#F6E9FF" stop-opacity="0.32"/><stop offset="1" stop-color="#FFE0F2" stop-opacity="0.22"/>
</linearGradient>
<linearGradient id="band2" x1="0" y1="0" x2="0.6" y2="1">
  <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.6"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0.12"/>
</linearGradient>
<clipPath id="starClip"><path d="{star}"/></clipPath>
{shadow_filter("sh", 12, 34, 32, "#2A1896", 0.45)}
"""
    body = f"""
<rect width="1024" height="1024" fill="url(#bg)"/>
<rect width="1024" height="1024" fill="url(#glow)"/>
<path d="M470,420 C720,470 900,720 990,1090 L690,1090 C640,860 540,650 400,520 Z" fill="url(#band)"/>
<path d="M450,470 C660,540 790,760 850,1090 L770,1090 C720,830 620,640 430,520 Z" fill="url(#band2)" opacity="0.7"/>
<g filter="url(#sh)"><path d="{star}" fill="#FFFFFF"/></g>
<g clip-path="url(#starClip)">
  <path d="{facet(3)}" fill="#FFFFFF"/>
  <path d="{facet(0)}" fill="#F4F0FF"/>
  <path d="{facet(2)}" fill="#E6DEFF"/>
  <path d="{facet(1)}" fill="#D3C5FF"/>
</g>
<path d="{star}" fill="none" stroke="#FFFFFF" stroke-width="4" stroke-opacity="0.9"/>
<path d="{mini1}" fill="#FFFFFF" opacity="0.9"/>
<path d="{mini2}" fill="#FFFFFF" opacity="0.55"/>
<path d="{mini3}" fill="#FFFFFF" opacity="0.65"/>
"""
    return svg(defs, body)


# ---------------------------------------------------------------- 2 星灵（奶白底 + 贴纸小星星）
@icon("buddy")
def buddy():
    body_star = star5(512, 548, 352, ratio=0.6, rot=-10, r=84)
    defs = f"""
<radialGradient id="bg" cx="0.5" cy="0.35" r="0.8">
  <stop offset="0" stop-color="#FFFDF8"/><stop offset="1" stop-color="#F6F0E4"/>
</radialGradient>
<linearGradient id="fill" x1="0.3" y1="0" x2="0.6" y2="1">
  <stop offset="0" stop-color="#8F7CFF"/><stop offset="0.5" stop-color="#FF9DB4"/><stop offset="1" stop-color="#FFD36B"/>
</linearGradient>
<radialGradient id="hi" cx="0.38" cy="0.2" r="0.5">
  <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.55"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
</radialGradient>
<clipPath id="clip"><path d="{body_star}"/></clipPath>
{shadow_filter("sh", 0, 26, 26, "#6B4E2E", 0.22)}
"""
    body = f"""
<rect width="1024" height="1024" fill="url(#bg)"/>
<g filter="url(#sh)">
  <path d="{body_star}" fill="url(#fill)" stroke="#2C2233" stroke-width="34" stroke-linejoin="round"/>
</g>
<g clip-path="url(#clip)">
  <rect x="0" y="0" width="1024" height="1024" fill="url(#hi)"/>
  <path d="{body_star}" fill="none" stroke="#FFFFFF" stroke-opacity="0.35" stroke-width="24" transform="translate(-8,-10)"/>
</g>
<path d="{body_star}" fill="none" stroke="#2C2233" stroke-width="34" stroke-linejoin="round"/>
<ellipse cx="530" cy="512" rx="25" ry="38" fill="#2C2233" transform="rotate(-10 530 512)"/>
<ellipse cx="626" cy="496" rx="25" ry="38" fill="#2C2233" transform="rotate(-10 626 496)"/>
<ellipse cx="538" cy="498" rx="7" ry="9" fill="#FFFFFF"/>
<ellipse cx="634" cy="482" rx="7" ry="9" fill="#FFFFFF"/>
<path d="M540,598 Q590,644 646,590" stroke="#2C2233" stroke-width="20" fill="none" stroke-linecap="round"/>
<ellipse cx="488" cy="590" rx="28" ry="17" fill="#FF6F91" opacity="0.45"/>
<ellipse cx="672" cy="566" rx="26" ry="16" fill="#FF6F91" opacity="0.45"/>
"""
    return svg(defs, body)


# ---------------------------------------------------------------- 3 夜空（深色网格 + 玻璃星）
@icon("night")
def night():
    cx, cy, R = 512, 500, 300
    star = sparkle(cx, cy, R, pinch=0.2, tip=0.07)
    k = R * 0.2
    tips = [(cx, cy - R), (cx + R, cy), (cx, cy + R), (cx - R, cy)]
    ctrls = [(cx + k, cy - k), (cx + k, cy + k), (cx - k, cy + k), (cx - k, cy - k)]
    facet = lambda i: f"M{cx},{cy} L{fmt(tips[i][0])},{fmt(tips[i][1])} Q{fmt(ctrls[i][0])},{fmt(ctrls[i][1])} {fmt(tips[(i+1)%4][0])},{fmt(tips[(i+1)%4][1])} Z"
    grid = "".join(
        f'<line x1="{x}" y1="0" x2="{x}" y2="1024"/><line x1="0" y1="{x}" x2="1024" y2="{x}"/>'
        for x in range(64, 1024, 128)
    )
    defs = f"""
<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
  <stop offset="0" stop-color="#2A2B31"/><stop offset="1" stop-color="#17171B"/>
</linearGradient>
<radialGradient id="vig" cx="0.5" cy="0.5" r="0.7">
  <stop offset="0.6" stop-color="#000" stop-opacity="0"/><stop offset="1" stop-color="#000" stop-opacity="0.45"/>
</radialGradient>
<linearGradient id="side" x1="0" y1="0" x2="1" y2="1">
  <stop offset="0" stop-color="#2F6BFF"/><stop offset="1" stop-color="#6A3BD9"/>
</linearGradient>
<linearGradient id="face" x1="0.1" y1="0.05" x2="0.9" y2="0.95">
  <stop offset="0" stop-color="#7BEBFF"/><stop offset="0.45" stop-color="#4E9BFF"/><stop offset="1" stop-color="#B386FF"/>
</linearGradient>
<linearGradient id="rim" x1="0" y1="0" x2="1" y2="1">
  <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.95"/><stop offset="0.5" stop-color="#DFF7FF" stop-opacity="0.5"/><stop offset="1" stop-color="#F3D9FF" stop-opacity="0.9"/>
</linearGradient>
<radialGradient id="hi" cx="0.4" cy="0.3" r="0.4">
  <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.85"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
</radialGradient>
<radialGradient id="glow" cx="0.5" cy="0.5" r="0.5">
  <stop offset="0" stop-color="#5CC8FF" stop-opacity="0.55"/><stop offset="1" stop-color="#5CC8FF" stop-opacity="0"/>
</radialGradient>
<clipPath id="clip"><path d="{star}"/></clipPath>
"""
    body = f"""
<rect width="1024" height="1024" fill="url(#bg)"/>
<g stroke="#FFFFFF" stroke-opacity="0.06" stroke-width="3">{grid}</g>
<rect width="1024" height="1024" fill="url(#vig)"/>
<circle cx="512" cy="520" r="430" fill="url(#glow)"/>
{"".join(f'<path d="{star}" fill="url(#side)" transform="translate(0,{d})"/>' for d in range(22, 0, -2))}
<path d="{star}" fill="url(#face)"/>
<g clip-path="url(#clip)">
  <path d="{facet(3)}" fill="#FFFFFF" opacity="0.28"/>
  <path d="{facet(0)}" fill="#FFFFFF" opacity="0.1"/>
  <path d="{facet(1)}" fill="#1A1F7A" opacity="0.22"/>
  <path d="{facet(2)}" fill="#1A1F7A" opacity="0.08"/>
  <ellipse cx="430" cy="400" rx="150" ry="150" fill="url(#hi)" opacity="0.7"/>
</g>
<path d="{star}" fill="none" stroke="url(#rim)" stroke-width="10"/>
<circle cx="770" cy="250" r="9" fill="#FFFFFF" opacity="0.7"/>
<circle cx="250" cy="800" r="6" fill="#FFFFFF" opacity="0.5"/>
<circle cx="820" cy="760" r="5" fill="#FFFFFF" opacity="0.4"/>
"""
    return svg(defs, body)


# ---------------------------------------------------------------- 4 百宝箱（收纳盒 + 各种内容）
@icon("tray")
def tray():
    st = star5(748, 318, 128, ratio=0.52, rot=14, r=24)
    sp = sparkle(872, 178, 42, pinch=0.2, tip=0.1)
    front = "M160,600 Q160,566 194,566 L322,566 Q344,566 344,588 L344,596 Q344,628 376,628 L648,628 Q680,628 680,596 L680,588 Q680,566 702,566 L830,566 Q864,566 864,600 L864,800 Q864,872 792,872 L232,872 Q160,872 160,800 Z"
    lip = "M160,600 Q160,566 194,566 L322,566 Q344,566 344,588 L344,596 Q344,628 376,628 L648,628 Q680,628 680,596 L680,588 Q680,566 702,566 L830,566 Q864,566 864,600"
    defs = f"""
<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
  <stop offset="0" stop-color="#F8F8FA"/><stop offset="1" stop-color="#EAEAEF"/>
</linearGradient>
<linearGradient id="card" x1="0" y1="0" x2="1" y2="1">
  <stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="#EDEFFF"/>
</linearGradient>
<linearGradient id="book" x1="0" y1="0" x2="1" y2="1">
  <stop offset="0" stop-color="#62B6FF"/><stop offset="1" stop-color="#2D69F3"/>
</linearGradient>
<linearGradient id="starG" x1="0" y1="0" x2="1" y2="1">
  <stop offset="0" stop-color="#FFE485"/><stop offset="1" stop-color="#FFAA36"/>
</linearGradient>
<linearGradient id="box" x1="0" y1="0" x2="0" y2="1">
  <stop offset="0" stop-color="#6C7083"/><stop offset="1" stop-color="#3D404D"/>
</linearGradient>
<linearGradient id="boxIn" x1="0" y1="0" x2="0" y2="1">
  <stop offset="0" stop-color="#2B2D36"/><stop offset="1" stop-color="#454856"/>
</linearGradient>
<linearGradient id="mint" x1="0" y1="0" x2="1" y2="1">
  <stop offset="0" stop-color="#A6EFD8"/><stop offset="1" stop-color="#5ACDAA"/>
</linearGradient>
{shadow_filter("sh", 0, 16, 18, "#1B1D29", 0.2)}
{shadow_filter("shBox", 0, 34, 34, "#1B1D29", 0.3)}
"""
    body = f"""
<rect width="1024" height="1024" fill="url(#bg)"/>
<path d="M186,566 L838,566 L838,640 L186,640 Z" fill="url(#boxIn)"/>
<path d="M196,570 C150,470 200,370 290,380 C300,290 420,260 470,340 L470,570 Z" fill="url(#mint)"/>
<g transform="rotate(-13 370 430)" filter="url(#sh)">
  <rect x="250" y="262" width="240" height="320" rx="38" fill="url(#card)"/>
  <rect x="284" y="300" width="170" height="22" rx="11" fill="#CFC8FF"/>
  <rect x="284" y="340" width="110" height="22" rx="11" fill="#E3DEFF"/>
  <path d="{rounded_poly([(330, 420), (440, 486), (330, 552)], 20)}" fill="#FF5C88"/>
</g>
<g transform="rotate(11 610 420)" filter="url(#sh)">
  <rect x="500" y="250" width="220" height="330" rx="34" fill="url(#book)"/>
  <rect x="524" y="250" width="20" height="330" fill="#FFFFFF" opacity="0.22"/>
  <path d="M628,250 L628,372 L660,346 L692,372 L692,250 Z" fill="#FFFFFF"/>
</g>
<g filter="url(#sh)"><path d="{st}" fill="url(#starG)"/></g>
<path d="{sp}" fill="#FFB547"/>
<g filter="url(#shBox)"><path d="{front}" fill="url(#box)"/></g>
<path d="{lip}" fill="none" stroke="#9195A8" stroke-width="10" stroke-linecap="round" opacity="0.9"/>
<rect x="412" y="730" width="200" height="38" rx="19" fill="#E7E8EF"/>
<rect x="412" y="730" width="200" height="17" rx="8.5" fill="#FFFFFF" opacity="0.6"/>
"""
    return svg(defs, body)


# ---------------------------------------------------------------- 5 软糖（粉底 + 白团子）
@icon("mochi")
def mochi():
    sp = sparkle(806, 300, 118, pinch=0.2, tip=0.12, rot=12)
    tuft = star5(548, 548, 78, ratio=0.55, rot=-12, r=22)
    defs = f"""
<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
  <stop offset="0" stop-color="#FF8FBE"/><stop offset="1" stop-color="#FF6CA2"/>
</linearGradient>
<linearGradient id="band" x1="0" y1="0" x2="1" y2="0">
  <stop offset="0" stop-color="#FFB1D0"/><stop offset="1" stop-color="#FF8FBE"/>
</linearGradient>
<linearGradient id="blob" x1="0.2" y1="0" x2="0.8" y2="1">
  <stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="#FFE9F3"/>
</linearGradient>
<linearGradient id="spG" x1="0" y1="0" x2="1" y2="1">
  <stop offset="0" stop-color="#FFE47E"/><stop offset="1" stop-color="#FFB547"/>
</linearGradient>
{shadow_filter("sh", -16, 24, 28, "#B11F5C", 0.32)}
{shadow_filter("sh2", 0, 14, 14, "#B11F5C", 0.28)}
"""
    blob = "M110,1110 C90,800 280,590 550,584 C800,578 990,700 1090,900 L1090,1110 Z"
    body = f"""
<rect width="1024" height="1024" fill="url(#bg)"/>
<path d="M0,0 L290,0 C220,320 220,700 320,1024 L0,1024 Z" fill="url(#band)" opacity="0.55"/>
<g filter="url(#sh)">
  <path d="{tuft}" fill="url(#blob)"/>
  <path d="{blob}" fill="url(#blob)"/>
</g>
<ellipse cx="456" cy="800" rx="50" ry="64" fill="#FF7DB3" transform="rotate(-10 456 800)"/>
<ellipse cx="676" cy="772" rx="50" ry="64" fill="#FF7DB3" transform="rotate(-10 676 772)"/>
<ellipse cx="442" cy="778" rx="13" ry="17" fill="#FFFFFF" opacity="0.9"/>
<ellipse cx="662" cy="750" rx="13" ry="17" fill="#FFFFFF" opacity="0.9"/>
<g filter="url(#sh2)">
  <path d="{sp}" fill="#FFFFFF" stroke="#FFFFFF" stroke-width="44" stroke-linejoin="round"/>
  <path d="{sp}" fill="url(#spG)"/>
</g>
"""
    return svg(defs, body)


# ---------------------------------------------------------------- 6 晴空（蓝底 + 玻璃卡片）
@icon("sky")
def sky():
    sp = sparkle(770, 270, 70, pinch=0.2, tip=0.1)
    tri = rounded_poly([(470, 430), (610, 512), (470, 594)], 26)
    defs = f"""
<linearGradient id="bg" x1="0.2" y1="0" x2="0.8" y2="1">
  <stop offset="0" stop-color="#0E8BFF"/><stop offset="1" stop-color="#8ED2FF"/>
</linearGradient>
<linearGradient id="beam" x1="0" y1="0" x2="1" y2="1">
  <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.35"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
</linearGradient>
<linearGradient id="glass" x1="0" y1="0" x2="1" y2="1">
  <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.55"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0.18"/>
</linearGradient>
<linearGradient id="card" x1="0" y1="0" x2="1" y2="1">
  <stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="#E4F1FF"/>
</linearGradient>
<linearGradient id="tri" x1="0" y1="0" x2="1" y2="1">
  <stop offset="0" stop-color="#45A6FF"/><stop offset="1" stop-color="#1B6FF0"/>
</linearGradient>
{shadow_filter("sh", 0, 28, 30, "#0A4FB8", 0.35)}
"""
    body = f"""
<rect width="1024" height="1024" fill="url(#bg)"/>
<path d="M0,620 L1024,180 L1024,420 L0,880 Z" fill="url(#beam)" opacity="0.5"/>
<g transform="rotate(16 600 520)">
  <rect x="380" y="250" width="420" height="520" rx="70" fill="url(#glass)" stroke="#FFFFFF" stroke-opacity="0.75" stroke-width="8"/>
</g>
<g transform="rotate(-10 470 540)" filter="url(#sh)">
  <rect x="250" y="270" width="440" height="540" rx="76" fill="url(#card)"/>
</g>
<g transform="rotate(-10 470 540)">
  <rect x="300" y="330" width="170" height="28" rx="14" fill="#BFDCFF"/>
  <rect x="300" y="700" width="260" height="26" rx="13" fill="#D6E8FF"/>
  <path d="{tri}" fill="url(#tri)"/>
</g>
<path d="{sp}" fill="#FFFFFF"/>
<circle cx="190" cy="230" r="12" fill="#FFFFFF" opacity="0.7"/>
"""
    return svg(defs, body)


# ---------------------------------------------------------------- 7 电视精灵（青柠底）
@icon("tv")
def tv():
    defs = f"""
<linearGradient id="bg" x1="1" y1="0" x2="0" y2="1">
  <stop offset="0" stop-color="#A4F23E"/><stop offset="0.6" stop-color="#CBFA86"/><stop offset="1" stop-color="#EFFFC4"/>
</linearGradient>
<radialGradient id="lav" cx="0.1" cy="0.9" r="0.5">
  <stop offset="0" stop-color="#B9B4FF" stop-opacity="0.8"/><stop offset="1" stop-color="#B9B4FF" stop-opacity="0"/>
</radialGradient>
<linearGradient id="body" x1="0" y1="0" x2="0" y2="1">
  <stop offset="0" stop-color="#3A3B42"/><stop offset="1" stop-color="#121216"/>
</linearGradient>
<radialGradient id="pupil" cx="0.4" cy="0.35" r="0.7">
  <stop offset="0" stop-color="#6B4537"/><stop offset="1" stop-color="#2A1610"/>
</radialGradient>
{shadow_filter("sh", 0, 26, 26, "#4A7A10", 0.35)}
"""
    body = f"""
<rect width="1024" height="1024" fill="url(#bg)"/>
<rect width="1024" height="1024" fill="url(#lav)"/>
<g transform="rotate(-7 512 560)">
  <g filter="url(#sh)">
    <g stroke="#F5F4FF" stroke-width="64" stroke-linecap="round" stroke-linejoin="round" fill="#F5F4FF">
      <path d="M430,330 L360,220" fill="none"/><path d="M594,330 L664,220" fill="none"/>
      <rect x="232" y="330" width="560" height="440" rx="120"/>
    </g>
  </g>
  <g stroke="url(#body)" stroke-width="30" stroke-linecap="round" fill="none">
    <path d="M430,330 L360,220"/><path d="M594,330 L664,220"/>
  </g>
  <circle cx="360" cy="220" r="26" fill="#2A2B31"/><circle cx="664" cy="220" r="26" fill="#2A2B31"/>
  <rect x="232" y="330" width="560" height="440" rx="120" fill="url(#body)"/>
  <path d="M290,420 L290,520" stroke="#FFFFFF" stroke-opacity="0.22" stroke-width="22" stroke-linecap="round"/>
  <path d="M290,560 L290,580" stroke="#FFFFFF" stroke-opacity="0.22" stroke-width="22" stroke-linecap="round"/>
  <circle cx="440" cy="520" r="92" fill="#FFFFFF"/>
  <circle cx="630" cy="520" r="92" fill="#FFFFFF"/>
  <circle cx="460" cy="534" r="54" fill="url(#pupil)"/>
  <circle cx="650" cy="534" r="54" fill="url(#pupil)"/>
  <circle cx="440" cy="512" r="16" fill="#FFFFFF"/>
  <circle cx="630" cy="512" r="16" fill="#FFFFFF"/>
  <path d="M500,672 Q540,700 582,668" stroke="#F5F4FF" stroke-width="16" fill="none" stroke-linecap="round"/>
</g>
"""
    return svg(defs, body)


# ---------------------------------------------------------------- 8 小白（深灰底 + 白色软糖小怪，右上角是五种内容）
@icon("boo")
def boo():
    play = rounded_poly([(0, -40), (52, 0), (0, 40)], 13)
    defs = f"""
<linearGradient id="rim" x1="0" y1="0" x2="1" y2="1">
  <stop offset="0" stop-color="#8E8E93"/><stop offset="0.35" stop-color="#4A4A4F"/><stop offset="1" stop-color="#1C1C1F"/>
</linearGradient>
<linearGradient id="panel" x1="0.2" y1="0" x2="0.8" y2="1">
  <stop offset="0" stop-color="#3A3A3F"/><stop offset="1" stop-color="#1E1E22"/>
</linearGradient>
<radialGradient id="blob" cx="0.36" cy="0.2" r="0.85">
  <stop offset="0" stop-color="#FFFFFF"/><stop offset="0.45" stop-color="#F1F1F3"/>
  <stop offset="0.8" stop-color="#C9C9CE"/><stop offset="1" stop-color="#8F8F96"/>
</radialGradient>
<radialGradient id="shine" cx="0.5" cy="0.5" r="0.5">
  <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.95"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
</radialGradient>
<linearGradient id="eye" x1="0" y1="0" x2="0" y2="1">
  <stop offset="0" stop-color="#2E2E33"/><stop offset="1" stop-color="#0B0B0D"/>
</linearGradient>
<linearGradient id="tile" x1="0.2" y1="0" x2="0.8" y2="1">
  <stop offset="0" stop-color="#FFFFFF"/><stop offset="0.6" stop-color="#E9E9EC"/><stop offset="1" stop-color="#BDBDC3"/>
</linearGradient>
<linearGradient id="glyph" x1="0" y1="0" x2="0" y2="1">
  <stop offset="0" stop-color="#3A3A40"/><stop offset="1" stop-color="#141417"/>
</linearGradient>
<linearGradient id="gloss" x1="0" y1="0" x2="0" y2="1">
  <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.75"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
</linearGradient>
<clipPath id="inner"><rect x="44" y="44" width="936" height="936" rx="200"/></clipPath>
<clipPath id="blobClip"><path d="BLOB"/></clipPath>
{shadow_filter("sh", -10, 34, 40, "#000", 0.55)}
{shadow_filter("tsh", 0, 16, 18, "#000", 0.5)}
{blur_filter("soft", 18)}
{blur_filter("hair", 2.5)}
"""

    def tile(x, y, rot, glyph):
        """一块白色圆角小方块，中心 (x, y)，里面放深色图标"""
        return f"""
<g transform="translate({x} {y}) rotate({rot}) scale(1.08)">
  <g filter="url(#tsh)"><rect x="-82" y="-82" width="164" height="164" rx="46" fill="url(#tile)"/></g>
  <rect x="-70" y="-74" width="140" height="62" rx="30" fill="url(#gloss)"/>
  {glyph}
</g>"""

    play_glyph = f'<path d="{play}" fill="url(#glyph)" transform="translate(-12 0)"/>'
    note_glyph = """
<g fill="url(#glyph)">
  <ellipse cx="-30" cy="34" rx="24" ry="18" transform="rotate(-22 -30 34)"/>
  <ellipse cx="34" cy="20" rx="24" ry="18" transform="rotate(-22 34 20)"/>
  <rect x="-12" y="-44" width="13" height="80" rx="6"/>
  <rect x="52" y="-58" width="13" height="80" rx="6"/>
  <path d="M-12,-44 L65,-58 L65,-34 L-12,-20 Z"/>
</g>"""
    # 描边加粗：渲染用的字体没有粗体
    book_glyph = '<text x="0" y="40" text-anchor="middle" font-size="108" font-weight="700" ' \
                 'font-family="PingFang SC, Noto Sans CJK SC, Source Han Sans SC, WenQuanYi Zen Hei, sans-serif" ' \
                 'fill="url(#glyph)" stroke="#1E1E22" stroke-width="7" stroke-linejoin="round">书</text>'
    # 漫画：带尾巴的对话框，里面一个感叹号
    comic_glyph = """
<path d="M-50,-46 Q-50,-56 -40,-56 L44,-56 Q56,-56 56,-44 L56,18 Q56,30 44,30 L-4,30 L-30,54 L-24,30 L-40,30 Q-52,30 -52,18 Z" fill="url(#glyph)"/>
<rect x="-1" y="-42" width="16" height="44" rx="8" fill="#FFFFFF" transform="translate(-6 0)"/>
<circle cx="2" cy="16" r="8.5" fill="#FFFFFF"/>"""

    blob = "M-40,1100 L-40,640 C-40,470 130,390 330,392 C560,394 760,470 900,610 C990,700 1060,800 1080,900 L1080,1100 Z"
    defs = defs.replace("BLOB", blob)
    body = f"""
<rect width="1024" height="1024" fill="url(#rim)"/>
<rect x="44" y="44" width="936" height="936" rx="200" fill="url(#panel)"/>
<rect x="44" y="44" width="936" height="936" rx="200" fill="none" stroke="#000" stroke-opacity="0.45" stroke-width="10"/>
<g clip-path="url(#inner)">
  <g filter="url(#sh)"><path d="{blob}" fill="url(#blob)"/></g>
  <g clip-path="url(#blobClip)">
    <path d="{blob}" fill="none" stroke="#6E6E76" stroke-width="90" opacity="0.55" filter="url(#soft)"/>
    <path d="{blob}" fill="none" stroke="#FFFFFF" stroke-width="8" opacity="0.45" transform="translate(0 7)" filter="url(#hair)"/>
  </g>
  <ellipse cx="290" cy="520" rx="190" ry="62" fill="url(#shine)" transform="rotate(-10 290 520)" filter="url(#soft)"/>
  <g transform="rotate(-14 500 660)">
    <rect x="388" y="572" width="78" height="168" rx="39" fill="url(#eye)"/>
    <rect x="560" y="552" width="78" height="168" rx="39" fill="url(#eye)"/>
    <ellipse cx="414" cy="604" rx="12" ry="20" fill="#FFFFFF" opacity="0.35"/>
    <ellipse cx="586" cy="584" rx="12" ry="20" fill="#FFFFFF" opacity="0.35"/>
  </g>
  {tile(632, 190, -8, play_glyph)}
  {tile(830, 210, 7, note_glyph)}
  {tile(660, 392, 5, book_glyph)}
  {tile(856, 414, -6, comic_glyph)}
</g>
"""
    return svg(defs, body)


if __name__ == "__main__":
    names = sys.argv[1:] or list(ICONS)
    for name in names:
        with open(os.path.join(OUT, f"{name}.svg"), "w") as f:
            f.write(ICONS[name]())
    print(" ".join(names))
