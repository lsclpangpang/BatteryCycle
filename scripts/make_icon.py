"""生成 App 图标：绿色圆角方块 + 白色电池 + 循环箭头。
用法: python3 scripts/make_icon.py  → app/Resources/AppIcon.png (1024) 与 AppIcon.icns
"""
import math
from pathlib import Path
from PIL import Image, ImageDraw

SS = 4                      # 超采样倍数，最后缩小抗锯齿
S = 1024 * SS
OUT = Path(__file__).resolve().parent.parent / "app" / "Resources"


def u(v):
    return int(v * SS)


def gradient(size, top, bottom):
    w, h = size
    g = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / (h - 1)
        g.putpixel((0, y), tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return g.resize((w, h))


def main():
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # macOS 风格的圆角底板（1024 画布中留 100 边距）
    x0, x1 = u(100), u(924)
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([x0, x0, x1, x1], radius=u(185), fill=255)
    bg = gradient((S, S), (72, 219, 135), (16, 150, 104))
    img.paste(bg, (0, 0), mask)

    d = ImageDraw.Draw(img)
    white = (255, 255, 255, 255)
    green = (22, 160, 108, 255)

    # 电池外框
    bw, bh, stroke = 560, 320, 34
    bx0, by0 = 512 - bw / 2 - 20, 512 - bh / 2
    bx1, by1 = bx0 + bw, by0 + bh
    d.rounded_rectangle([u(bx0), u(by0), u(bx1), u(by1)], radius=u(70), outline=white, width=u(stroke))
    # 正极
    d.rounded_rectangle([u(bx1 + 18), u(512 - 62), u(bx1 + 58), u(512 + 62)], radius=u(18), fill=white)

    # 电量 75%
    pad = stroke + 22
    fx0, fy0, fy1 = bx0 + pad, by0 + pad, by1 - pad
    fx1_full = bx1 - pad
    fx1 = fx0 + (fx1_full - fx0) * 0.75
    d.rounded_rectangle([u(fx0), u(fy0), u(fx1), u(fy1)], radius=u(30), fill=white)

    # 电量块上镂空的循环箭头
    cx, cy = (fx0 + fx1) / 2, 512
    r, ring = 92, 30
    for start, end in ((200, 340), (20, 160)):
        d.arc([u(cx - r), u(cy - r), u(cx + r), u(cy + r)], start=start, end=end, fill=green, width=u(ring))
        # 箭头：放在弧线末端，沿切线方向
        a = math.radians(end)
        px, py = cx + r * math.cos(a) - ring / 2 * math.cos(a), cy + r * math.sin(a) - ring / 2 * math.sin(a)
        tx, ty = -math.sin(a), math.cos(a)          # 顺时针切线
        nx, ny = math.cos(a), math.sin(a)           # 法线（向外）
        size = 46
        tip = (px + tx * size, py + ty * size)
        left = (px + nx * size * 0.95, py + ny * size * 0.95)
        right = (px - nx * size * 0.95, py - ny * size * 0.95)
        d.polygon([(u(x), u(y)) for x, y in (tip, left, right)], fill=green)

    icon = img.resize((1024, 1024), Image.LANCZOS)
    OUT.mkdir(parents=True, exist_ok=True)
    icon.save(OUT / "AppIcon.png")
    icon.save(OUT / "AppIcon.icns", sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])
    print("已生成", OUT / "AppIcon.png", OUT / "AppIcon.icns")


if __name__ == "__main__":
    main()
