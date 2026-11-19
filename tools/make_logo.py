"""Draw the RareCodex logo (an open codex with a dotted patrol route and a rare star) as
docs/media/logo.png. Original artwork, no game assets.

    uv run --with pillow python tools/make_logo.py
"""

from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
SIZE = 400
SS = 4  # supersampling factor for smooth edges
S = SIZE * SS

GOLD = (232, 186, 92)
GOLD_LIGHT = (255, 224, 150)
PARCHMENT = (238, 222, 186)
PARCHMENT_SHADE = (206, 184, 140)
INK = (120, 30, 18)
BG_INNER = (38, 30, 52)
BG_OUTER = (12, 10, 18)


def px(value: float) -> int:
    return round(value * SS)


def radial_background() -> Image.Image:
    img = Image.new("RGB", (S, S))
    draw = ImageDraw.Draw(img)
    steps = 120
    for i in range(steps, 0, -1):
        t = i / steps
        color = tuple(round(BG_INNER[c] * (1 - t) + BG_OUTER[c] * t) for c in range(3))
        r = S * 0.72 * t
        draw.ellipse((S / 2 - r, S / 2 - r, S / 2 + r, S / 2 + r), fill=color)
    return img


def bezier(points: list[tuple[float, float]], n: int = 200) -> list[tuple[float, float]]:
    (x0, y0), (x1, y1), (x2, y2), (x3, y3) = points
    out = []
    for i in range(n + 1):
        t = i / n
        a, b, c, d = (1 - t) ** 3, 3 * t * (1 - t) ** 2, 3 * t * t * (1 - t), t**3
        out.append((a * x0 + b * x1 + c * x2 + d * x3, a * y0 + b * y1 + c * y2 + d * y3))
    return out


def star(cx: float, cy: float, outer: float, inner: float) -> list[tuple[float, float]]:
    pts = []
    for k in range(10):
        r = outer if k % 2 == 0 else inner
        a = -math.pi / 2 + k * math.pi / 5
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts


def draw_book(draw: ImageDraw.ImageDraw) -> None:
    cx, top, bottom, half = 200, 130, 300, 125
    for side in (-1, 1):
        outer = cx + side * half
        page = [
            (px(cx), px(top + 14)),
            (px(cx + side * half * 0.55), px(top - 6)),
            (px(outer), px(top + 6)),
            (px(outer), px(bottom - 8)),
            (px(cx + side * half * 0.55), px(bottom - 22)),
            (px(cx), px(bottom)),
        ]
        draw.polygon(page, fill=PARCHMENT, outline=GOLD, width=px(4))
        # Text lines on the left page, map hint on the right page.
        if side == -1:
            for i in range(5):
                y = top + 40 + i * 22
                draw.line(
                    (px(cx - 100), px(y), px(cx - 24), px(y + 6)), fill=PARCHMENT_SHADE, width=px(5)
                )
    draw.line((px(cx), px(top + 14), px(cx), px(bottom)), fill=GOLD, width=px(5))


def draw_route(draw: ImageDraw.ImageDraw) -> None:
    curve = bezier([(222, 268), (250, 210), (330, 250), (300, 176)])
    step, acc = 15, 0.0
    for (x0, y0), (x1, y1) in zip(curve, curve[1:], strict=False):
        acc += math.hypot(x1 - x0, y1 - y0)
        if acc >= step:
            acc = 0.0
            r = 4.2
            draw.ellipse((px(x1 - r), px(y1 - r), px(x1 + r), px(y1 + r)), fill=INK)


def draw_star(img: Image.Image) -> Image.Image:
    cx, cy = 300, 150
    glow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse(
        (px(cx - 46), px(cy - 46), px(cx + 46), px(cy + 46)), fill=(*GOLD_LIGHT, 150)
    )
    glow = glow.filter(ImageFilter.GaussianBlur(px(16)))
    img = Image.alpha_composite(img.convert("RGBA"), glow)
    draw = ImageDraw.Draw(img)
    outline = [(px(x), px(y)) for x, y in star(cx, cy, 40, 17)]
    draw.polygon(outline, fill=(70, 20, 10))
    draw.polygon([(px(x), px(y)) for x, y in star(cx, cy, 33, 13)], fill=GOLD_LIGHT)
    return img


def main() -> None:
    img = radial_background().convert("RGBA")
    draw = ImageDraw.Draw(img)
    ring = 14
    draw.ellipse((px(ring), px(ring), px(SIZE - ring), px(SIZE - ring)), outline=GOLD, width=px(7))
    draw.ellipse(
        (px(ring + 12), px(ring + 12), px(SIZE - ring - 12), px(SIZE - ring - 12)),
        outline=(*GOLD, 110),
        width=px(2),
    )
    draw_book(draw)
    draw_route(draw)
    img = draw_star(img)
    out = ROOT / "docs" / "media" / "logo.png"
    out.parent.mkdir(parents=True, exist_ok=True)
    img.resize((SIZE, SIZE), Image.LANCZOS).convert("RGB").save(out, optimize=True)
    print(f"Wrote {out}")


if __name__ == "__main__":
    main()
