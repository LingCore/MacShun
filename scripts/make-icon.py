#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 生成程序图标：一笔画成的 ⌘，圈画成 Windows 那样的圆角方环，四种 Windows 颜色沿着线渐变过渡；
# 右上角的环外角收成叶尖、里面一条短叶脉，像一片叶子从 ⌘ 中心长出来；
# 32px 以下太小看不清，右上角整个画成一片实心叶子，叶尖再往外伸一点。
#
#   Resources/AppIcon.svg          大图（1024），128px 以上的尺寸都从它缩放
#   Resources/AppIcon-{16,24,32,48}.svg
#                                  小尺寸单独绘制：⌘ 的每条线都落在整像素上
#   Resources/AppIcon.icns         打包用，由 scripts/build-app.sh 放进 .app
#   Resources/AppGlyph.svg         只有 ⌘ 标志、没有底板的矢量图，程序里（“拾穗计划”页）直接用
#
# 用法：scripts/make-icon.py      （只需要 Command Line Tools：swiftc、iconutil）

import os
import subprocess
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Resources")

PLATE = ("#FFFFFF", "#E9EDF4")
RIM = "#D5DBE5"
COLORS = ("#FF5A4A", "#33C463", "#2D86FF", "#FFBA26")   # 左上、右上、左下、右下
TINT = 0.16                                              # 环里面的淡色填充
LEAF_RL = 1.25                                           # 方叶两侧的圆角半径，是环半边长 R 的倍数
LEAF_SLIM = 0.9                                          # 实心叶子的胖瘦：弧线控制点在叶柄→外角之间的位置，1 最胖
MIDRIB = (0.34, 0.62)                                    # 叶脉：沿叶柄到叶尖的对角线，从 34% 画到 62%


def cmd_path(cx, cy, h, R, r, leaf):
    """一笔画成的 ⌘：中间方框的四条边（x=±h、y=±h）延伸出去，在四个角绕成边长 2R、圆角 r 的环再回来。
    右上角的环是叶子，叶柄就是它和中间方框相接的角：
      leaf = ("square", 0)：方叶，外角不圆（叶尖），两侧圆角放大到 LEAF_RL×R；
      leaf = ("solid", t)：整片叶子，两侧都是从叶柄到叶尖的整段弧线（胖瘦由 LEAF_SLIM 决定），叶尖往外伸 t。"""
    E = h + 2 * R
    kind, t = leaf
    T = E + t                                    # 叶尖的位置
    rl = LEAF_RL * R if kind == "square" else T - h
    if kind == "square":
        b1, b2 = (T, -h), (h, -T)                # 弧线的控制点就在两个外角上
    else:
        k = LEAF_SLIM
        b1 = (h + k * (T - h), -h - (1 - k) * (T - h))
        b2 = (h + (1 - k) * (T - h), -h - k * (T - h))

    def p(x, y):
        return f"{cx + x:g} {cy + y:g}"

    def corner(a, b, c):   # 直线走到 a，以 b 为角点圆角转到 c
        return f" L{p(*a)} Q{p(*b)} {p(*c)}"

    return ("M" + p(-h, -h)
            + corner((-h, -E + r), (-h, -E), (-h - r, -E))
            + corner((-E + r, -E), (-E, -E), (-E, -E + r))
            + corner((-E, -h - r), (-E, -h), (-E + r, -h))
            + corner((T - rl, -h), b1, (T, -h - rl))          # 叶子下沿扫到叶尖
            + corner((T, -T), (T, -T), (T, -T))               # 叶尖
            + corner((h + rl, -T), b2, (h, -T + rl))          # 叶子上沿扫回叶柄
            + corner((h, E - r), (h, E), (h + r, E))
            + corner((E - r, E), (E, E), (E, E - r))
            + corner((E, h + r), (E, h), (E - r, h))
            + corner((-E + r, h), (-E, h), (-E, h + r))
            + corner((-E, E - r), (-E, E), (-E + r, E))
            + corner((-h - r, E), (-h, E), (-h, E - r)) + " Z")


def ramps(cx, cy, b, size):
    """四个渐变遮罩：左/右、上/下各一个，在中心两侧 b 的范围内从 1 过渡到 0。
    两两相乘得到四个象限的权重，加起来处处为 1，所以颜色沿着线平滑过渡。只用线性渐变，不用滤镜。"""
    out = ""
    for name, (x1, y1, x2, y2) in {
        "L": (cx - b, 0, cx + b, 0), "R": (cx + b, 0, cx - b, 0),
        "T": (0, cy - b, 0, cy + b), "B": (0, cy + b, 0, cy - b),
    }.items():
        out += (f'    <linearGradient id="g{name}" gradientUnits="userSpaceOnUse" x1="{x1:g}" y1="{y1:g}" x2="{x2:g}" y2="{y2:g}">'
                f'<stop offset="0" stop-color="#FFF"/><stop offset="1" stop-color="#000"/></linearGradient>\n'
                f'    <mask id="m{name}" maskUnits="userSpaceOnUse" x="0" y="0" width="{size}" height="{size}">'
                f'<rect width="{size}" height="{size}" fill="url(#g{name})"/></mask>\n')
    return out


def glyph(cx, cy, h, R, r, w, midrib_w, leaf):
    path = cmd_path(cx, cy, h, R, r, leaf)
    E = h + 2 * R
    kind, t = leaf
    T = E + t
    rl = LEAF_RL * R if kind == "square" else T - h
    if kind == "square":
        b1, b2 = (T, -h), (h, -T)
    else:
        k = LEAF_SLIM
        b1 = (h + k * (T - h), -h - (1 - k) * (T - h))
        b2 = (h + (1 - k) * (T - h), -h - k * (T - h))
    loops = [(cx - E, cy - E), (cx - E, cy + h), (cx + h, cy + h)]

    def p(x, y):
        return f"{cx + x:g} {cy + y:g}"

    leaf_d = f"M{p(h, -h)} L{p(T - rl, -h)} Q{p(*b1)} {p(T, -h - rl)} L{p(T, -T)} L{p(h + rl, -T)} Q{p(*b2)} {p(h, -T + rl)} Z"
    leaf_op = TINT if kind == "square" else 1     # 实心叶子填满颜色
    k0, k1 = MIDRIB
    rib = f"M{p(h + 2 * R * k0, -h - 2 * R * k0)} L{p(h + 2 * R * k1, -h - 2 * R * k1)}"
    out = ""
    for (mx, my), color in zip((("L", "T"), ("R", "T"), ("L", "B"), ("R", "B")), COLORS):
        out += f'  <g mask="url(#m{mx})"><g mask="url(#m{my})">\n'
        out += "".join(f'    <rect x="{x:g}" y="{y:g}" width="{2 * R:g}" height="{2 * R:g}" rx="{r:g}" fill="{color}" fill-opacity="{TINT}"/>\n'
                       for x, y in loops)
        out += f'    <path d="{leaf_d}" fill="{color}" fill-opacity="{leaf_op:g}"/>\n'
        if midrib_w:
            out += f'    <path d="{rib}" stroke="{color}" stroke-width="{midrib_w:g}" stroke-linecap="round"/>\n'
        out += f'    <path d="{path}" fill="none" stroke="{color}" stroke-width="{w:g}" stroke-linejoin="round"/>\n'
        out += "  </g></g>\n"
    return out


def svg(size, plate, rim_w, g, blend, midrib_w, leaf=("square", 0)):
    """plate = (x, 宽, 圆角)；g = (h, R, r, 线宽)；midrib_w 是叶脉线宽（0 表示不画）；
    leaf 见 cmd_path。长度都以本尺寸的像素为单位。"""
    x, w, rx = plate
    c = size / 2
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {size} {size}" width="{size}" height="{size}">
  <!-- Mac顺 app icon: ⌘ drawn as one stroke, its loops squared off like Windows tiles, in the four Windows colours;
       the top-right loop comes to a leaf tip -->
  <defs>
    <linearGradient id="plate" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{PLATE[0]}"/><stop offset="1" stop-color="{PLATE[1]}"/></linearGradient>
{ramps(c, c, blend, size)}  </defs>
  <rect x="{x:g}" y="{x:g}" width="{w:g}" height="{w:g}" rx="{rx:g}" fill="url(#plate)"/>
  <rect x="{x + rim_w / 2:g}" y="{x + rim_w / 2:g}" width="{w - rim_w:g}" height="{w - rim_w:g}" rx="{rx - rim_w / 2:g}" fill="none" stroke="{RIM}" stroke-width="{rim_w:g}"/>
{glyph(c, c, *g, midrib_w, leaf)}</svg>
'''


def glyph_only_svg(size, g, blend, midrib_w, leaf=("square", 0)):
    """只有 ⌘ 标志、没有底板和描边的矢量图，画布裁到标志的外框（含线宽）。"""
    h, R, r, w = g
    c = size / 2
    reach = h + 2 * R + w / 2
    box = f"{c - reach:g} {c - reach:g} {2 * reach:g} {2 * reach:g}"
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="{box}" width="{2 * reach:g}" height="{2 * reach:g}">
  <!-- Mac顺 mark without the plate: one-stroke ⌘ in the four Windows colours, the top-right loop is a leaf -->
  <defs>
{ramps(c, c, blend, size)}  </defs>
{glyph(c, c, *g, midrib_w, leaf)}</svg>
'''


# 大图：底板 100..924，⌘ 占底板约 63%
MASTER = dict(size=1024, plate=(100, 824, 186), rim_w=3, g=(80, 80, 48, 40), blend=140, midrib_w=14)

# 小尺寸：线宽为奇数时线的中心落在半像素上，为偶数时落在整像素上，保证每条线的两边都是整像素；
# 16、24、32px 右上角画成实心叶子，48px 和大图是方叶
SMALL = {
    16: dict(plate=(1, 14, 3), rim_w=1, g=(1.5, 1, 0.5, 1), blend=2.5, midrib_w=0, leaf=("solid", 0)),     # 中框内 2px、环内 1px
    24: dict(plate=(1, 22, 5), rim_w=1, g=(1.5, 2, 1, 1), blend=3.5, midrib_w=0, leaf=("solid", 0)),       # 中框内 2px、环内 3px
    32: dict(plate=(2, 28, 7), rim_w=1, g=(3, 2.5, 1.5, 2), blend=4.5, midrib_w=0, leaf=("solid", 0)),     # 中框内 4px、环内 3px
    48: dict(plate=(3, 42, 10), rim_w=1, g=(4.5, 4, 2.5, 3), blend=6.5, midrib_w=1),    # 中框内 6px、环内 5px
}

# 64px 也偏小：用大图的画法，但右上角换成实心叶子
MASTER_SOLID = dict(MASTER, midrib_w=0, leaf=("solid", 0))

# iconset 文件名 → (来源, 像素尺寸)；16/32 用专门绘制的小图，64 用 MASTER_SOLID，其余从大图缩放
ICONSET = {
    "icon_16x16.png": (16, 16), "icon_16x16@2x.png": (32, 32),
    "icon_32x32.png": (32, 32), "icon_32x32@2x.png": ("solid", 64),
    "icon_128x128.png": (None, 128), "icon_128x128@2x.png": (None, 256),
    "icon_256x256.png": (None, 256), "icon_256x256@2x.png": (None, 512),
    "icon_512x512.png": (None, 512), "icon_512x512@2x.png": (None, 1024),
}


def main():
    paths = {None: os.path.join(OUT, "AppIcon.svg")}
    with open(paths[None], "w") as f:
        f.write(svg(**MASTER))
    with open(os.path.join(OUT, "AppGlyph.svg"), "w") as f:
        f.write(glyph_only_svg(1024, MASTER["g"], MASTER["blend"], MASTER["midrib_w"]))
    for size, spec in SMALL.items():
        paths[size] = os.path.join(OUT, f"AppIcon-{size}.svg")
        with open(paths[size], "w") as f:
            f.write(svg(size, **spec))

    with tempfile.TemporaryDirectory() as tmp:
        paths["solid"] = os.path.join(tmp, "AppIcon-solid.svg")
        with open(paths["solid"], "w") as f:
            f.write(svg(**MASTER_SOLID))
        # qlmanage 渲染的缩略图带白底、16px 会坏，所以用 NSImage 自己渲染
        renderer = os.path.join(tmp, "svg2png")
        subprocess.run(["swiftc", "-O", os.path.join(ROOT, "scripts", "svg2png.swift"), "-o", renderer], check=True)
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.mkdir(iconset)
        for name, (src, px) in ICONSET.items():
            subprocess.run([renderer, paths[src], str(px), os.path.join(iconset, name)], check=True)
        subprocess.run(["iconutil", "-c", "icns", "-o", os.path.join(OUT, "AppIcon.icns"), iconset], check=True)
    print("已生成：Resources/AppIcon.svg、AppIcon-{16,24,32,48}.svg、AppIcon.icns、AppGlyph.svg")


if __name__ == "__main__":
    main()
